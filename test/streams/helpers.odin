package streams_test

import rdb "../../src/rdb"
import st "../../src/streamtype"
import "core:strconv"

RDB_DUMP_VERSION :: 12

hex_decode :: proc(s: string, allocator := context.allocator) -> []u8 {
	out := make([]u8, len(s) / 2, allocator)
	for i in 0 ..< len(out) {
		v, _ := strconv.parse_u64_of_base(s[2 * i:2 * i + 2], 16)
		out[i] = u8(v)
	}
	return out
}

bytes_of :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

args_of :: proc(parts: ..string, allocator := context.temp_allocator) -> [][]u8 {
	out := make([][]u8, len(parts), allocator)
	for p, i in parts {
		out[i] = transmute([]u8)p
	}
	return out
}

dump_payload :: proc(s: st.Stream, allocator := context.allocator) -> []u8 {
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	rdb.put_type(&w, st.rdb_type(s))
	st.rdb_save(&w, s)
	body := rdb.writer_bytes(&w)
	out := make([dynamic]u8, 0, len(body) + 10, allocator)
	append(&out, ..body)
	rdb.writer_destroy(&w)
	append(&out, u8(RDB_DUMP_VERSION), 0)
	rdb.crc64_init()
	crc := rdb.crc64(0, out[:])
	for i in 0 ..< 8 {
		append(&out, u8(crc >> uint(8 * i)))
	}
	return out[:]
}

load_payload :: proc(payload: []u8, deep: bool) -> (s: st.Stream, consumed: int) {
	r: rdb.Reader
	rdb.reader_init_mem(&r, payload[1:], false)
	s = st.rdb_load(&r, int(payload[0]), deep)
	consumed = int(rdb.reader_offset(&r)) + 1
	rdb.reader_destroy(&r)
	return
}

new_stream_from :: proc(entries: [][]string) -> st.Stream {
	s := st.create()
	for e in entries {
		argv := make([][]u8, len(e), context.temp_allocator)
		for p, i in e {
			argv[i] = transmute([]u8)p
		}
		spec, err := st.parse_xadd(argv)
		assert(err == .None)
		_, aerr := st.xadd_apply(s, &spec, argv[spec.fields_at:], 1)
		assert(aerr == .None)
		if spec.trim.rule != .Off {
			st.trim(s, &spec.trim)
		}
	}
	return s
}

main :: proc() {}
