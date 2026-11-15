package main

import "core:crypto/siphash"
import "core:sys/linux"
import lb "label"
import ow "owner"
import "rdb"
import "vmath"
import vt "vsettype"

VSET_RDB_MODULE_ID_V1 :: u64(0x7ac922fafb1eb401)
VSET_RDB_MODULE_ID :: u64(0x7ac922fafb1eb402)
VSET_RDB_TYPE_NAME :: "eski-vset"
VSET_MODULE_OPCODE_STRING :: 5
VSET_PAYLOAD_SLOT :: 2
VSET_DUMP_TRAILER :: 10
VSET_SEED_TWEAK :: u64(0x7f4a_7c15_9e37_79b9)
VSET_SEED_ATTEMPTS :: 16

Vset_Rdb_Sink :: struct {
	w:   ^rdb.Writer,
	crc: u64,
	sum: bool,
}

vset_seed: u64
vset_seed_held: bool
vset_seed_drawn: proc(seed: u64)
vset_restore_refusal: string

@(init)
vset_persist_init :: proc "contextless" () {
	vt.seed_hook = vset_partition_seed
	vset_seed_drawn = aof_seed_drawn
}

vset_seed_get :: proc "contextless" () -> (seed: u64, held: bool) {
	return vset_seed, vset_seed_held
}

vset_seed_put :: proc "contextless" (seed: u64) {
	vset_seed = seed
	vset_seed_held = true
}

vset_seed_clear :: proc "contextless" () {
	vset_seed = 0
	vset_seed_held = false
}

vset_seed_random :: proc() -> u64 {
	for _ in 0 ..< VSET_SEED_ATTEMPTS {
		b: [8]u8
		n, err := linux.getrandom(b[:], {})
		if err == .EINTR {
			continue
		}
		if err != .NONE || n != len(b) {
			continue
		}
		if v := u64(transmute(u64le)b); v != 0 {
			return v
		}
	}
	store_fatal("the system random source failed; Eski cannot draw the vector set dataset seed")
}

vset_seed_current :: proc() -> u64 {
	if !vset_seed_held {
		v: u64
		if label_stream_seed != 0 {
			v = label_mix(u64(label_stream_seed) ~ VSET_SEED_TWEAK) | 1
		} else {
			v = vset_seed_random()
		}
		vset_seed_put(v)
		if vset_seed_drawn != nil {
			vset_seed_drawn(v)
		}
	}
	return vset_seed
}

vset_creation_seed :: proc(dbi: int, key: []u8, label: lb.Id, owner: vt.Owner) -> u64 {
	seed := vset_seed_current()
	k: [16]u8
	for i in 0 ..< 8 {
		k[i] = u8(seed >> (8 * uint(i)))
		k[8 + i] = u8((seed ~ VSET_SEED_TWEAK) >> (8 * uint(i)))
	}
	ctx: siphash.Context
	siphash.init(&ctx, k[:], 2, 4)
	head: [16]u8
	for i in 0 ..< 8 {
		head[i] = u8(u64(dbi) >> (8 * uint(i)))
		head[8 + i] = u8(u64(len(key)) >> (8 * uint(i)))
	}
	siphash.update(&ctx, head[:])
	siphash.update(&ctx, key)
	mark: [2 + 8 * lb.COMPARTMENT_WORDS]u8
	if l, found := lb.table_label(&label_table, label); found && labels_on {
		mark[0] = l.level
		mark[1] = l.trust
		for w in 0 ..< lb.COMPARTMENT_WORDS {
			for i in 0 ..< 8 {
				mark[2 + 8 * w + i] = u8(l.compartments[w] >> (8 * uint(i)))
			}
		}
	}
	siphash.update(&ctx, mark[:])
	text := ""
	if owner != vt.SHARED {
		text, _ = owner_text(ow.Owner(owner))
	}
	size: [8]u8
	for i in 0 ..< 8 {
		size[i] = u8(u64(len(text)) >> (8 * uint(i)))
	}
	siphash.update(&ctx, size[:])
	siphash.update(&ctx, transmute([]u8)text)
	out: u64
	siphash.final(&ctx, &out)
	return out | 1
}

vset_plain_seed :: proc(key: []u8) -> u64 {
	return vset_creation_seed(cur_db().id, key, lb.BOTTOM_ID, vt.SHARED)
}

vset_partition_seed :: proc(a: ^vt.Access) -> u64 {
	return vset_creation_seed(cur_db().id, a.key, a.label, a.owner)
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

vset_rdb_module :: proc "contextless" (id: u64) -> bool {
	return id == VSET_RDB_MODULE_ID || id == VSET_RDB_MODULE_ID_V1
}

Vset_Payload :: struct {
	set:  vt.Vset,
	view: vt.View,
	plan: vt.Plan,
	size: int,
}

vset_payload_plan :: proc(s: vt.Vset) -> (p: Vset_Payload) {
	p.set = s
	if s.lab == nil {
		p.plan = vt.core_plan(s)
		p.size = p.plan.size
		return
	}
	a := label_vt_access()
	v, ok := vset_view(s, &a)
	if ok {
		p.view = v
		p.size = vt.view_serialized_size(&p.view)
	}
	return
}

vset_payload_write :: proc(p: ^Vset_Payload, sink: vt.Sink) {
	if p.set.lab == nil {
		vt.core_write(p.set, &p.plan, sink)
	} else if p.size > 0 {
		vt.view_serialize(&p.view, sink)
	}
}

vset_value_length :: proc(s: vt.Vset) -> int {
	n := vset_payload_plan(s).size
	return vset_len_size(VSET_RDB_MODULE_ID) + 1 + vset_len_size(u64(n)) + n + 1
}

vset_serialized_length :: proc(obj: rawptr) -> int {
	return vset_value_length(cast(vt.Vset)obj)
}

vset_rdb_save :: proc(w: ^rdb.Writer, s: vt.Vset) {
	p := vset_payload_plan(s)
	rdb.put_len(w, VSET_RDB_MODULE_ID)
	rdb.put_len(w, VSET_MODULE_OPCODE_STRING)
	rdb.put_len(w, u64(p.size))
	sink := Vset_Rdb_Sink{w = w}
	vset_payload_write(&p, vt.Sink{ctx = &sink, write = vset_rdb_sink_write})
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
	case .Bad_Capacity:
		return "holds a vector set whose capacities do not match its slots"
	case .Too_Large:
		return "holds a vector set that would reserve far more memory than its size justifies"
	case .Bad_Free_List:
		return "holds a vector set with an invalid list of free slots"
	case .Bad_Slot:
		return "holds a vector set with an element in an invalid slot"
	case .Bad_Sequence:
		return "holds a vector set with an invalid insertion sequence"
	case .Bad_Graph:
		return "holds a vector set with an invalid graph layer"
	case .Bad_Link:
		return "holds a vector set with an invalid graph link"
	case .Asymmetric_Link:
		return "holds a vector set with a graph link that has no reverse link"
	case .Bad_Entry:
		return "holds a vector set with an invalid graph entry point"
	case .Bad_Twin:
		return "holds a vector set with an invalid chain of duplicate vectors"
	case .Bad_Rank:
		return "holds a vector set with an invalid order of copies"
	case .Bad_Scope:
		return "holds a vector set partition that does not fit its scope"
	case .Bad_Padding:
		return "holds a vector set with invalid padding"
	case .Bad_Object:
		return "holds vector set partitions that do not belong together"
	}
	return "holds a malformed vector set"
}

vset_payload_shape :: proc "contextless" (data: []u8) -> vt.Decode_Error {
	version, err := vt.payload_version(data)
	if err != .None {
		return err
	}
	d := vt.Decoder{data = data}
	if version == vt.CODEC_VERSION {
		sh: vt.Shape
		if err = vt.shape_read(&d, &sh); err != .None {
			return err
		}
		if sh.flags & (vt.CODEC_SCOPED | vt.CODEC_RANKS) != 0 || sh.mode == .Graph {
			return .Bad_Scope
		}
		if sh.mode == .Flat && sh.rng != 0 {
			return .Bad_Header
		}
		return vt.shape_check(&sh, len(data), vt.decoder_left(&d))
	}
	head, ok := vt.decoder_take(&d, 5)
	if !ok || head[4] > u8(vt.Quant.BIN) {
		return .Bad_Header
	}
	p := vt.Params{quant = vt.Quant(head[4])}
	dim_ok, input_ok, m_ok, count_ok, uid_ok: bool
	count: int
	max_uid: u64
	p.dim, dim_ok = vt.decoder_int(&d, vt.DIM_MAX)
	p.input_dim, input_ok = vt.decoder_int(&d, vt.DIM_MAX)
	p.m, m_ok = vt.decoder_int(&d, vt.CODEC_M_LIMIT)
	count, count_ok = vt.decoder_int(&d, vt.SLOT_MAX)
	max_uid, uid_ok = vt.decoder_varint(&d)
	if !dim_ok || !input_ok || !m_ok || !count_ok || !uid_ok {
		return .Bad_Header
	}
	if !vt.params_valid(p) || max_uid < u64(count) || max_uid >= vt.CODEC_UID_LIMIT {
		return .Bad_Header
	}
	if count == 0 {
		return .Empty
	}
	elem := vt.quant_elem(p.quant)
	if count > vt.decoder_left(&d) / vt.element_bytes_min(vmath.elem_vector_bytes(elem, p.dim), elem == .Int8) {
		return .Truncated
	}
	return .None
}

vset_restore_refused :: proc(data: []u8) -> string {
	if pst.loading || aof.loading {
		return ""
	}
	if vset_payload_shape(data) != .None {
		return ""
	}
	need := vt.payload_reserve(data)
	if maxmemory_bytes != 0 && u64(need) > maxmemory_bytes {
		return ERR_OOM
	}
	if owners_on && owner_user() && access.owner_entry != nil {
		quota := owner_quota_of(access.owner_entry)
		if quota > 0 && i64(need) > quota {
			return ERR_OWNER_QUOTA_OOM
		}
	}
	return ""
}

vset_payload_decode :: proc(data: []u8, id: u64) -> (s: vt.Vset, err: vt.Decode_Error) {
	vset_restore_refusal = ""
	version: u8
	if version, err = vt.payload_version(data); err != .None {
		return nil, err
	}
	if (id == VSET_RDB_MODULE_ID) != (version == vt.CODEC_VERSION) {
		return nil, .Bad_Version
	}
	if refusal := vset_restore_refused(data); refusal != "" {
		vset_restore_refusal = refusal
		return nil, .Too_Large
	}
	if labels_on {
		a := label_vt_access()
		a.key = data
		return vt.deserialize_at(data, &a, vset_scratch_get())
	}
	rebuild: bool
	if s, rebuild, err = vt.decode_unbuilt(data, vset_scratch_get()); err != .None {
		return nil, err
	}
	if rebuild {
		if err = vt.build_graph(s, vset_plain_seed(data), vset_scratch_get()); err != .None {
			vt.destroy(s)
			return nil, err
		}
	}
	return s, .None
}

vset_rdb_value :: proc(r: ^rdb.Reader) -> (data: []u8, good: bool) {
	opcode := rdb.get_len(r)
	if !rdb.ok(r) {
		return nil, false
	}
	if opcode != VSET_MODULE_OPCODE_STRING {
		rdb.corrupt(r, "holds vector set data with module opcode ", opcode, true)
		return nil, false
	}
	kind: rdb.String_Kind
	data, _, kind, good = rdb.get_string_kind(r, VSET_PAYLOAD_SLOT)
	if !good {
		if rdb.ok(r) {
			rdb.corrupt(r, "holds vector set data that is not a string")
		}
		return nil, false
	}
	if kind != .Raw {
		rdb.corrupt(r, "holds a vector set whose payload is not stored as a plain string")
		return nil, false
	}
	return data, true
}

vset_rdb_end :: proc(r: ^rdb.Reader) -> bool {
	tail := rdb.get_len(r)
	if !rdb.ok(r) {
		return false
	}
	if tail != rdb.MODULE_OPCODE_EOF {
		rdb.corrupt(r, "holds vector set data without its end marker")
		return false
	}
	return true
}

vset_rdb_load :: proc(r: ^rdb.Reader, id: u64 = VSET_RDB_MODULE_ID) -> vt.Vset {
	data, good := vset_rdb_value(r)
	if !good {
		return nil
	}
	s, err := vset_payload_decode(data, id)
	if err != .None {
		rdb.corrupt(r, vset_decode_reason(err))
		return nil
	}
	if !vset_rdb_end(r) {
		vt.destroy(s)
		return nil
	}
	return s
}

vset_rdb_save_part :: proc(w: ^rdb.Writer, ctx: ^vt.Save_Context, s: vt.Vset, label: lb.Id, owner: vt.Owner) -> bool {
	if vt.part_at_scope(s, label, owner) == nil {
		return false
	}
	scope := vt.Scope{label = label, owner = owner}
	plan, _ := vt.scoped_plan(s, scope, vt.save_object(ctx, s))
	rdb.put_len(w, VSET_RDB_MODULE_ID)
	rdb.put_len(w, VSET_MODULE_OPCODE_STRING)
	rdb.put_len(w, u64(plan.size))
	sink := Vset_Rdb_Sink{w = w}
	vt.scoped_write(s, scope, &plan, vt.Sink{ctx = &sink, write = vset_rdb_sink_write})
	rdb.put_len(w, rdb.MODULE_OPCODE_EOF)
	return !w.failed
}

vset_rdb_part_value :: proc(r: ^rdb.Reader, ctx: ^vt.Load_Context, id: u64, db: int, key: []u8, label: lb.Id, owner: vt.Owner, keep: bool) -> (s: vt.Vset, fresh: bool, good: bool) {
	if id != VSET_RDB_MODULE_ID {
		rdb.corrupt(r, vset_decode_reason(.Bad_Version))
		return nil, false, false
	}
	data, read := vset_rdb_value(r)
	if !read {
		return nil, false, false
	}
	err: vt.Decode_Error
	if s, fresh, err = vt.load_part(ctx, data, db, key, vt.Scope{label = label, owner = owner}, keep); err != .None {
		rdb.corrupt(r, vset_decode_reason(err))
		return nil, false, false
	}
	if !vset_rdb_end(r) {
		if fresh {
			vt.load_drop(ctx, s)
		}
		return nil, false, false
	}
	return s, fresh, true
}

vset_rdb_load_part :: proc(r: ^rdb.Reader, ctx: ^vt.Load_Context, id: u64, db: int, key: []u8, label: lb.Id, owner: vt.Owner) -> (s: vt.Vset, fresh: bool) {
	got: bool
	if s, fresh, got = vset_rdb_part_value(r, ctx, id, db, key, label, owner, true); !got {
		return nil, false
	}
	return s, fresh
}

vset_rdb_discard_part :: proc(r: ^rdb.Reader, ctx: ^vt.Load_Context, id: u64, db: int, key: []u8, label: lb.Id, owner: vt.Owner) -> bool {
	_, _, got := vset_rdb_part_value(r, ctx, id, db, key, label, owner, false)
	return got
}

vset_rdb_load_finish :: proc(r: ^rdb.Reader, ctx: ^vt.Load_Context) -> bool {
	if err := vt.load_finish(ctx); err != .None {
		rdb.corrupt(r, vset_decode_reason(err))
		return false
	}
	return true
}

vset_load_context_destroy :: proc(ctx: ^vt.Load_Context) {
	vt.load_context_destroy(ctx)
}

vset_save_context_destroy :: proc(ctx: ^vt.Save_Context) {
	vt.save_context_destroy(ctx)
}

vset_aof_rewrite :: proc(w: ^rdb.Writer, key: []u8, s: vt.Vset) {
	p := vset_payload_plan(s)
	value := vset_len_size(VSET_RDB_MODULE_ID) + 1 + vset_len_size(u64(p.size)) + p.size + 1
	payload := 1 + value + VSET_DUMP_TRAILER
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
	n += copy(prefix[n:], vset_len_bytes(&enc, u64(p.size)))
	vset_rdb_sink_write(&sink, prefix[:n])
	vset_payload_write(&p, vt.Sink{ctx = &sink, write = vset_rdb_sink_write})
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
