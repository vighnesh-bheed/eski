package main

import "rdb"
import vt "vsettype"

VSET_RDB_MODULE_ID :: u64(0x7ac922fafb1eb401)
VSET_RDB_TYPE_NAME :: "eski-vset"
VSET_MODULE_OPCODE_STRING :: 5
VSET_PAYLOAD_SLOT :: 2
VSET_DUMP_TRAILER :: 10

Vset_Rdb_Sink :: struct {
	w:   ^rdb.Writer,
	crc: u64,
	sum: bool,
}

vset_rdb_sink_write :: proc(ctx: rawptr, data: []u8) {
	sink := (^Vset_Rdb_Sink)(ctx)
	if sink.sum {
		sink.crc = rdb.crc64(sink.crc, data)
	}
	rdb.put_raw(sink.w, data)
}

vset_len_size :: proc "contextless" (n: u64) -> int {
	switch {
	case n < 1 << 6:
		return 1
	case n < 1 << 14:
		return 2
	case n <= u64(max(u32)):
		return 5
	}
	return 9
}

vset_len_bytes :: proc "contextless" (out: ^[9]u8, n: u64) -> []u8 {
	switch {
	case n < 1 << 6:
		out[0] = u8(n)
		return out[:1]
	case n < 1 << 14:
		out[0] = u8(n >> 8) | (rdb.LEN_14BIT << 6)
		out[1] = u8(n)
		return out[:2]
	case n <= u64(max(u32)):
		out[0] = rdb.LEN_32BIT
		for i in 0 ..< 4 {
			out[1 + i] = u8(n >> (8 * uint(3 - i)))
		}
		return out[:5]
	}
	out[0] = rdb.LEN_64BIT
	for i in 0 ..< 8 {
		out[1 + i] = u8(n >> (8 * uint(7 - i)))
	}
	return out[:9]
}

vset_payload_module :: proc "contextless" (payload: []u8) -> bool {
	return len(payload) > 0 && payload[0] == rdb.TYPE_MODULE_2
}

vset_value_length :: proc "contextless" (s: vt.Vset) -> int {
	n := vt.serialized_size(s)
	return vset_len_size(VSET_RDB_MODULE_ID) + 1 + vset_len_size(u64(n)) + n + 1
}

vset_serialized_length :: proc "contextless" (obj: rawptr) -> int {
	return vset_value_length(cast(vt.Vset)obj)
}

vset_rdb_save :: proc(w: ^rdb.Writer, s: vt.Vset) {
	rdb.put_len(w, VSET_RDB_MODULE_ID)
	rdb.put_len(w, VSET_MODULE_OPCODE_STRING)
	rdb.put_len(w, u64(vt.serialized_size(s)))
	sink := Vset_Rdb_Sink{w = w}
	vt.serialize(s, vt.Sink{ctx = &sink, write = vset_rdb_sink_write})
	rdb.put_len(w, rdb.MODULE_OPCODE_EOF)
}

vset_decode_reason :: proc "contextless" (err: vt.Decode_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Truncated:
		return "holds a truncated vector set"
	case .Bad_Magic:
		return "holds a vector set with an unknown signature"
	case .Bad_Version:
		return "holds a vector set in an unknown encoding version"
	case .Bad_Header:
		return "holds a vector set with an invalid header"
	case .Bad_Element:
		return "holds a vector set with an invalid element"
	case .Duplicate_Name:
		return "holds a vector set with a repeated element"
	case .Trailing_Bytes:
		return "holds a vector set followed by unexpected bytes"
	case .Empty:
		return "holds an empty vector set"
	case .Out_Of_Memory:
		return "holds a vector set that does not fit in memory"
	}
	return "holds a malformed vector set"
}

vset_rdb_load :: proc(r: ^rdb.Reader) -> vt.Vset {
	opcode := rdb.get_len(r)
	if !rdb.ok(r) {
		return nil
	}
	if opcode != VSET_MODULE_OPCODE_STRING {
		rdb.corrupt(r, "holds vector set data with module opcode ", opcode, true)
		return nil
	}
	data, good := rdb.get_string(r, VSET_PAYLOAD_SLOT)
	if !good {
		if rdb.ok(r) {
			rdb.corrupt(r, "holds vector set data that is not a string")
		}
		return nil
	}
	s, err := vt.deserialize(data, vset_scratch_get())
	if err != .None {
		rdb.corrupt(r, vset_decode_reason(err))
		return nil
	}
	tail := rdb.get_len(r)
	if !rdb.ok(r) {
		vt.destroy(s)
		return nil
	}
	if tail != rdb.MODULE_OPCODE_EOF {
		vt.destroy(s)
		rdb.corrupt(r, "holds vector set data without its end marker")
		return nil
	}
	return s
}

vset_aof_rewrite :: proc(w: ^rdb.Writer, key: []u8, s: vt.Vset) {
	payload := 1 + vset_value_length(s) + VSET_DUMP_TRAILER
	aof_w_header(w, 4)
	aof_w_str(w, "RESTORE")
	aof_w_arg(w, key)
	aof_w_str(w, "0")
	head: [24]u8
	head[0] = '$'
	k := 1 + format_i64(&head[1], i64(payload))
	head[k] = '\r'
	head[k + 1] = '\n'
	rdb.put_raw(w, head[:k + 2])
	sink := Vset_Rdb_Sink{w = w, sum = true}
	enc: [9]u8
	prefix: [32]u8
	n := 0
	prefix[n] = rdb.TYPE_MODULE_2
	n += 1
	n += copy(prefix[n:], vset_len_bytes(&enc, VSET_RDB_MODULE_ID))
	n += copy(prefix[n:], vset_len_bytes(&enc, VSET_MODULE_OPCODE_STRING))
	n += copy(prefix[n:], vset_len_bytes(&enc, u64(vt.serialized_size(s))))
	vset_rdb_sink_write(&sink, prefix[:n])
	vt.serialize(s, vt.Sink{ctx = &sink, write = vset_rdb_sink_write})
	trailer: [3]u8
	trailer[0] = rdb.MODULE_OPCODE_EOF
	trailer[1] = u8(rdb.RDB_VERSION & 0xff)
	trailer[2] = u8((rdb.RDB_VERSION >> 8) & 0xff)
	vset_rdb_sink_write(&sink, trailer[:])
	sum: [8]u8
	for i in 0 ..< 8 {
		sum[i] = u8(sink.crc >> (8 * uint(i)))
	}
	rdb.put_raw(w, sum[:])
	rdb.put_raw(w, transmute([]u8)string("\r\n"))
}
