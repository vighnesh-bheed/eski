package hashtype

import rdb "../rdb"
import "core:testing"

#assert(size_of(Hfe_Meta) == 32)
#assert(size_of(Reg_Item) == 16)
#assert(size_of(Registry) == 64)

expiry_make :: proc(table: bool) -> Hash {
	h := create()
	if table {
		convert(h, 24)
		ensure_meta(h)
	} else {
		convert_to_ex(h)
	}
	return h
}

expiry_set :: proc(t: ^testing.T, h: Hash, field: []u8, deadline: u64) {
	minimum := EB_EXPIRE_TIME_INVALID
	deleted, updated: int
	result := set_ex_field(h, field, deadline, .None, 0, &minimum, &deleted, &updated)
	testing.expect_value(t, result, i64(HSETEX_OK))
}

expiry_check_registry :: proc(t: ^testing.T, reg: ^Registry) {
	for i in 0 ..< reg.len {
		h := reg.items[i].h
		testing.expect(t, h.hfe != nil && h.hfe.reg == reg && h.hfe.reg_index == i)
		testing.expect_value(t, registered_expire(h), reg.items[i].expire)
		if i > 0 {
			testing.expect(t, reg.items[(i - 1) / 2].expire <= reg.items[i].expire)
		}
	}
}

expiry_check_vol :: proc(t: ^testing.T, table: ^Table) {
	for i in 0 ..< table.vol_len {
		testing.expect_value(t, table.vol[i].blob.hidx, u32(i + 1))
		testing.expect_value(t, table_field_expire(table, table.vol[i].blob), table.vol[i].expire)
		if i > 0 {
			testing.expect(t, table.vol[(i - 1) / 2].expire <= table.vol[i].expire)
		}
	}
}

@(test)
expiry_registry_membership_and_resize_generation :: proc(t: ^testing.T) {
	ordinary_cleanup()
	reg, destination: Registry
	defer registry_destroy(&destination)
	defer registry_destroy(&reg)
	hashes: [21]Hash
	defer {
		for h in hashes {
			destroy(h)
		}
		ordinary_cleanup()
	}
	for i in 0 ..< len(hashes) {
		hashes[i] = expiry_make(false)
		registry_add(&reg, hashes[i], u64(300 - i * 7))
		expiry_check_registry(t, &reg)
	}
	testing.expect_value(t, registry_len(&reg), len(hashes))
	registry_add(&reg, hashes[3], 4)
	testing.expect_value(t, registry_len(&reg), len(hashes))
	testing.expect_value(t, registry_next_expire(&reg), u64(4))
	registry_remove(hashes[3])
	testing.expect(t, !is_registered(hashes[3]) && hashes[3].hfe.reg_index == -1)
	registry_add(&destination, hashes[3], 9)
	expiry_check_registry(t, &reg)
	expiry_check_registry(t, &destination)
	for i := 0; i < len(hashes); i += 2 {
		registry_remove(hashes[i])
		expiry_check_registry(t, &reg)
	}
	h := hashes[1]
	convert(h, 24)
	set(h, ordinary_bytes("f"), ordinary_bytes("v"))
	table_resize(h.table, h.table.cap * 2)
	maintenance_bind(h, &reg)
	prior_epoch := reg.resize_epoch
	testing.expect_value(t, reg.resize_count, 1)
	registry_destroy(&reg)
	testing.expect(t, reg.resize_epoch != prior_epoch)
	testing.expect_value(t, reg.resize_count, 0)
	testing.expect(t, h.table.resize != nil)
	for item in hashes {
		if item != hashes[3] {
			testing.expect(t, !is_registered(item))
		}
	}
}

@(test)
expiry_volatile_heap_relocation_and_equal_deadlines :: proc(t: ^testing.T) {
	h := expiry_make(true)
	defer ordinary_cleanup()
	defer destroy(h)
	for i in 0 ..< 20 {
		buf: [21]u8
		field := ordinary_key(i, &buf)
		set(h, field, field)
		expiry_set(t, h, field, u64(100 + (i % 7)))
		expiry_check_vol(t, h.table)
	}
	testing.expect_value(t, h.table.vol_len, 20)
	testing.expect_value(t, vol_min(h.table), u64(100))
	set(h, ordinary_bytes("7"), ordinary_bytes("much larger replacement"), true)
	expiry_check_vol(t, h.table)
	_, deadline, found := get_raw(h, ordinary_bytes("7"))
	testing.expect(t, found && deadline == 100)
	for i := 0; i < 20; i += 3 {
		buf: [21]u8
		delete_field(h, ordinary_key(i, &buf))
		expiry_check_vol(t, h.table)
	}
	slot := table_find(h.table, ordinary_bytes("7"), hash_field(ordinary_bytes("7")))
	vol_set(h.table, slot.blob, 90)
	testing.expect_value(t, vol_min(h.table), u64(90))
	vol_set(h.table, slot.blob, 900)
	expiry_check_vol(t, h.table)
	vol_remove(h.table, slot.blob)
	testing.expect_value(t, slot.blob.hidx, u32(0))
	expiry_check_vol(t, h.table)
}

@(test)
expiry_conditions_duplicates_and_cache_threshold :: proc(t: ^testing.T) {
	for table in ([2]bool{false, true}) {
		reg: Registry
		defer registry_destroy(&reg)
		defer ordinary_cleanup()
		h := expiry_make(table)
		defer destroy(h)
		set(h, ordinary_bytes("a"), ordinary_bytes("1"))
		set(h, ordinary_bytes("b"), ordinary_bytes("2"))
		out := make([dynamic]i64)
		defer delete(out)
		fields := [][]u8{ordinary_bytes("a"), ordinary_bytes("a"), ordinary_bytes("b"), ordinary_bytes("missing")}
		testing.expect(t, !expire_fields(&reg, nil, h, fields, 10000, .NX, 0, &out))
		expected := [4]i64{1, 0, 1, -2}
		for value, i in out {
			testing.expect_value(t, value, expected[i])
		}
		testing.expect_value(t, registered_expire(h), u64(10000))
		if !table {
			it := iterator(h)
			testing.expect(t, next(&it) && value_eq(current_field(&it), ordinary_bytes("b")))
			testing.expect(t, next(&it) && value_eq(current_field(&it), ordinary_bytes("a")))
		}
		clear(&out)
		expire_fields(&reg, nil, h, fields[:1], 13999, .GT, 0, &out)
		testing.expect_value(t, out[0], i64(1))
		testing.expect_value(t, registered_expire(h), u64(10000))
		clear(&out)
		expire_fields(&reg, nil, h, [][]u8{ordinary_bytes("b")}, 14000, .GT, 0, &out)
		testing.expect_value(t, registered_expire(h), u64(10000))
		clear(&out)
		testing.expect(t, expire_fields(&reg, nil, h, fields, 0, .XX, 1, &out))
		testing.expect_value(t, out[0], i64(2))
		testing.expect_value(t, out[1], i64(-2))
		testing.expect_value(t, out[2], i64(2))
		testing.expect(t, !is_registered(h))
		set(h, ordinary_bytes("one"), ordinary_bytes("v"))
		clear(&out)
		expire_fields(&reg, nil, h, [][]u8{ordinary_bytes("one")}, 10000, .None, 0, &out)
		clear(&out)
		expire_fields(&reg, nil, h, [][]u8{ordinary_bytes("one")}, 14000, .GT, 0, &out)
		testing.expect_value(t, registered_expire(h), u64(14000))
		set(h, ordinary_bytes("new"), ordinary_bytes("noTTL"))
		clear(&out)
		expire_fields(&reg, nil, h, [][]u8{ordinary_bytes("new")}, 5000, .NX, 0, &out)
		testing.expect_value(t, registered_expire(h), u64(5000))
	}
}

@(test)
expiry_exact_now_read_persist_and_active_contracts :: proc(t: ^testing.T) {
	for table in ([2]bool{false, true}) {
		reg: Registry
		defer registry_destroy(&reg)
		defer ordinary_cleanup()
		h := expiry_make(table)
		defer destroy(h)
		set(h, ordinary_bytes("f"), ordinary_bytes("v"))
		expiry_set(t, h, ordinary_bytes("f"), 100)
		registry_add(&reg, h, 100)
		out := make([dynamic]i64)
		defer delete(out)
		fields := [][]u8{ordinary_bytes("f")}
		ttl_fields(h, fields, .Pttl, 100, &out)
		if table {
			testing.expect_value(t, out[0], i64(0))
		} else {
			testing.expect_value(t, out[0], i64(-2))
		}
		_, res := get(h, fields[0], 100)
		testing.expect_value(t, res, Get_Result.Ok)
		testing.expect(t, !expire_if_needed(h, 100))
		clear(&out)
		testing.expect(t, persist_fields(h, fields, 100, &out))
		testing.expect_value(t, out[0], i64(1))
		testing.expect_value(t, registered_expire(h), u64(100))
		expiry_set(t, h, fields[0], 100)
		quota := 1
		next_deadline, removed := hash_type_expire(h, 100, &quota, true)
		testing.expect(t, next_deadline == 0 && removed == 1 && quota == 0)
		testing.expect(t, !is_registered(h))
	}
}

@(test)
expiry_large_borrowed_pack_values_and_reordering :: proc(t: ^testing.T) {
	old_value := hash_max_listpack_value
	defer hash_max_listpack_value = old_value
	hash_max_listpack_value = 4096
	h := expiry_make(false)
	defer destroy(h)
	field := make([]u8, 257)
	value := make([]u8, 1024)
	defer delete(field)
	defer delete(value)
	for i in 0 ..< len(field) {
		field[i] = u8(i * 13)
	}
	for i in 0 ..< len(value) {
		value[i] = u8(i * 7)
	}
	set(h, field, value)
	set(h, ordinary_bytes("other"), ordinary_bytes("small"))
	expiry_set(t, h, field, 500)
	expiry_set(t, h, ordinary_bytes("other"), 300)
	it := iterator(h)
	testing.expect(t, next(&it) && value_eq(current_field(&it), ordinary_bytes("other")))
	fp, vp, _, ok := lpex_locate(h, field)
	testing.expect(t, ok)
	borrowed_field := value_from_lp(fp).str
	borrowed_value := value_from_lp(vp).str
	lpex_add_new(h, borrowed_value, borrowed_field, 400)
	copy_value, expiry, found := get_raw(h, value)
	testing.expect(t, found && expiry == 400 && value_eq(copy_value, field))
	fp, vp, _, ok = lpex_locate(h, field)
	testing.expect(t, ok)
	borrowed_field = value_from_lp(fp).str
	borrowed_value = value_from_lp(vp).str
	testing.expect(t, set(h, borrowed_field, borrowed_value[1:], true))
	updated_value, updated_deadline, updated_found := get_raw(h, field)
	testing.expect(t, updated_found && updated_deadline == 500 && value_eq(updated_value, value[1:]))
	fp, vp, _, _ = lpex_locate(h, field)
	lpex_update_expiry(h, value_from_lp(fp).str, fp, vp, 0)
	last := iterator(h)
	last_deadline := u64(0)
	seen_zero := false
	for next(&last) {
		d := current_expire(&last)
		if d == EB_EXPIRE_TIME_INVALID {
			seen_zero = true
		} else {
			testing.expect(t, !seen_zero && d >= last_deadline)
			last_deadline = d
		}
	}
}

expiry_pack_order :: proc(t: ^testing.T, h: Hash, want: []string, deadlines: []u64) {
	it := iterator(h)
	for name, i in want {
		testing.expect(t, next(&it))
		testing.expect(t, value_eq(current_field(&it), ordinary_bytes(name)))
		testing.expect_value(t, current_expire(&it), deadlines[i])
	}
	testing.expect(t, !next(&it))
}

@(test)
expiry_pack_value_updates_keep_position :: proc(t: ^testing.T) {
	h := expiry_make(false)
	defer destroy(h)
	for name in ([4]string{"a", "b", "c", "d"}) {
		set(h, ordinary_bytes(name), ordinary_bytes("1"))
	}
	expiry_set(t, h, ordinary_bytes("b"), 300)
	expiry_set(t, h, ordinary_bytes("d"), 300)
	none := EB_EXPIRE_TIME_INVALID
	expiry_pack_order(t, h, {"d", "b", "a", "c"}, {300, 300, none, none})
	testing.expect(t, set(h, ordinary_bytes("a"), ordinary_bytes("plain")))
	expiry_pack_order(t, h, {"d", "b", "a", "c"}, {300, 300, none, none})
	result, err := incrby(h, ordinary_bytes("b"), 4, 0)
	testing.expect(t, err == .None && result == 5)
	expiry_pack_order(t, h, {"d", "b", "a", "c"}, {300, 300, none, none})
	result, err = incrby(h, ordinary_bytes("c"), 2, 0)
	testing.expect(t, err == .None && result == 3)
	expiry_pack_order(t, h, {"d", "b", "a", "c"}, {300, 300, none, none})
	testing.expect(t, set(h, ordinary_bytes("d"), ordinary_bytes("cleared")))
	expiry_pack_order(t, h, {"b", "a", "c", "d"}, {300, none, none, none})
	expiry_set(t, h, ordinary_bytes("c"), 300)
	expiry_pack_order(t, h, {"c", "b", "a", "d"}, {300, 300, none, none})
	value, _, found := get_raw(h, ordinary_bytes("b"))
	testing.expect(t, found && value_eq(value, ordinary_bytes("5")))
	value, _, found = get_raw(h, ordinary_bytes("a"))
	testing.expect(t, found && value_eq(value, ordinary_bytes("plain")))
}

@(test)
expiry_active_quota_and_stale_registry_roots :: proc(t: ^testing.T) {
	reg: Registry
	defer registry_destroy(&reg)
	defer ordinary_cleanup()
	a, b, stale := expiry_make(false), expiry_make(true), expiry_make(false)
	defer destroy(a)
	defer destroy(b)
	defer destroy(stale)
	set(a, ordinary_bytes("due"), ordinary_bytes("1"))
	set(a, ordinary_bytes("future"), ordinary_bytes("2"))
	expiry_set(t, a, ordinary_bytes("due"), 10)
	expiry_set(t, a, ordinary_bytes("future"), 100)
	set(b, ordinary_bytes("due"), ordinary_bytes("3"))
	expiry_set(t, b, ordinary_bytes("due"), 10)
	set(stale, ordinary_bytes("ordinary"), ordinary_bytes("4"))
	registry_add(&reg, a, 1)
	registry_add(&reg, b, 2)
	registry_add(&reg, stale, 3)
	out := make([dynamic]Expired_Hash)
	defer delete(out)
	testing.expect_value(t, active_expire(&reg, 10, 3, &out), 2)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, registered_expire(a), u64(100))
	testing.expect(t, !is_registered(b) && !is_registered(stale))
	testing.expect_value(t, registry_len(&reg), 1)
	clear(&out)
	testing.expect_value(t, active_expire(&reg, max(u64), 0, &out), 0)
	testing.expect_value(t, len(out), 0)
	quota := 1
	deadline, count := hash_type_expire(a, 100, &quota, true)
	testing.expect(t, deadline == 0 && count == 1 && quota == 0)
	testing.expect_value(t, active_expire(&reg, max(u64), 10, &out), 0)
}

@(test)
expiry_parser_checked_units_and_numfields :: proc(t: ^testing.T) {
	args := [][]u8{ordinary_bytes("HPEXPIRE"), ordinary_bytes("h"), ordinary_bytes("250"), ordinary_bytes("NX"), ordinary_bytes("FIELDS"), ordinary_bytes("2"), ordinary_bytes("a"), ordinary_bytes("b")}
	parsed, err := parse_expire_args(args, false, 1000)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, parsed.expire_at == 1250 && parsed.cond == .NX && len(parsed.fields) == 2)
	for size in 0 ..< len(args) {
		_, prefix_err := parse_expire_args(args[:size], false, 1000)
		testing.expect(t, prefix_err != .None)
	}
	args[2] = ordinary_bytes("-1")
	_, err = parse_expire_args(args, false, 1000)
	testing.expect_value(t, err, Error.Invalid_Expire_Negative)
	args[2] = ordinary_bytes("+1")
	_, err = parse_expire_args(args, false, 1000)
	testing.expect_value(t, err, Error.Value_Not_Integer)
	args[2] = ordinary_bytes("0")
	args[5] = ordinary_bytes("0")
	_, err = parse_expire_args(args, false, 1000)
	testing.expect_value(t, err, Error.Numfields_Expire)
	args[5] = ordinary_bytes("3")
	_, err = parse_expire_args(args, false, 1000)
	testing.expect_value(t, err, Error.Numfields_Mismatch)
	fields_args := [][]u8{ordinary_bytes("HPTTL"), ordinary_bytes("h"), ordinary_bytes("FIELDS"), ordinary_bytes("0")}
	_, err = parse_fields_args(fields_args)
	testing.expect_value(t, err, Error.Numfields_Positive)
	boundary := [][]u8{ordinary_bytes("HEXPIREAT"), ordinary_bytes("h"), nil, ordinary_bytes("FIELDS"), ordinary_bytes("1"), ordinary_bytes("a")}
	buf: [21]u8
	boundary[2] = ordinary_key(int(HFE_MAX_ABS_TIME_MSEC / 1000), &buf)
	_, err = parse_expire_args(boundary, true, 0)
	testing.expect_value(t, err, Error.None)
	boundary[2] = ordinary_key(int(HFE_MAX_ABS_TIME_MSEC / 1000 + 1), &buf)
	_, err = parse_expire_args(boundary, true, 0)
	testing.expect_value(t, err, Error.Invalid_Expire_Time)
	boundary[2] = ordinary_bytes("1")
	_, err = parse_expire_args(boundary, false, HFE_MAX_ABS_TIME_MSEC)
	testing.expect_value(t, err, Error.Invalid_Expire_Time)
}

expiry_fixture :: proc(w: ^rdb.Writer, type: int, duplicate := false) {
	if type == rdb.TYPE_HASH_METADATA {
		rdb.put_ms(w, 100)
	}
	rdb.put_len(w, 2)
	deadline := u64(200)
	if type == rdb.TYPE_HASH_METADATA {
		deadline = 101
	}
	rdb.put_len(w, deadline)
	rdb.put_string(w, ordinary_bytes("a\x00field"))
	rdb.put_string(w, ordinary_bytes("one\x00value"))
	rdb.put_len(w, 0)
	if duplicate {
		rdb.put_string(w, ordinary_bytes("a\x00field"))
	} else {
		rdb.put_string(w, ordinary_bytes("b"))
	}
	rdb.put_string(w, ordinary_bytes(""))
}

@(test)
expiry_metadata_codecs_truncation_and_duplicates :: proc(t: ^testing.T) {
	old_limit := hash_max_listpack_entries
	defer hash_max_listpack_entries = old_limit
	defer ordinary_cleanup()
	for type in ([2]int{rdb.TYPE_HASH_METADATA, rdb.TYPE_HASH_METADATA_PRE_GA}) {
		for limit in ([2]int{1, 512}) {
			hash_max_listpack_entries = limit
			w: rdb.Writer
			rdb.writer_init_mem(&w, false, false)
			expiry_fixture(&w, type)
			blob := rdb.writer_bytes(&w)
			for size in 0 ..= len(blob) {
				r: rdb.Reader
				rdb.reader_init_mem(&r, blob[:size], false)
				h := rdb_load_meta(&r, type, true)
				if size == len(blob) {
					testing.expect(t, h != nil && r.status == .Ok)
					if h != nil {
						testing.expect(t, h.hfe != nil && !is_registered(h))
						testing.expect(t, h.hfe.reg_index == -1 && h.hfe.reg_expire == EB_EXPIRE_TIME_INVALID && key_ref(h) == nil)
						testing.expect_value(t, min_expire(h, false), EB_EXPIRE_TIME_INVALID)
						testing.expect_value(t, min_expire(h, true), u64(200))
						v, deadline, found := get_raw(h, ordinary_bytes("a\x00field"))
						testing.expect(t, found && deadline == 200 && value_eq(v, ordinary_bytes("one\x00value")))
						testing.expect_value(t, length(h), 2)
					}
				} else {
					testing.expect(t, h == nil && r.status != .Ok)
					if type == rdb.TYPE_HASH_METADATA && size < 8 {
						testing.expect_value(t, rdb.reader_reason(&r), "Hash failed loading minExpire")
					}
				}
				destroy(h)
				rdb.reader_destroy(&r)
			}
			rdb.writer_destroy(&w)
			rdb.writer_init_mem(&w, false, false)
			expiry_fixture(&w, type, true)
			r: rdb.Reader
			rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
			h := rdb_load_meta(&r, type, true)
			testing.expect(t, h == nil && r.status == .Corrupt)
			message := "Hash with dup elements"
			if limit == 1 {
				message = "Duplicate hash fields detected"
			}
			testing.expect_value(t, rdb.reader_reason(&r), message)
			destroy(h)
			rdb.reader_destroy(&r)
			rdb.writer_destroy(&w)
		}
	}
}

@(test)
expiry_invalid_metadata_boundaries :: proc(t: ^testing.T) {
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	rdb.put_ms(&w, i64(EB_EXPIRE_TIME_INVALID + 1))
	r: rdb.Reader
	rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
	h := rdb_load_meta(&r, rdb.TYPE_HASH_METADATA, true)
	testing.expect(t, h == nil && r.status == .Corrupt)
	testing.expect_value(t, rdb.reader_reason(&r), "Hash read invalid minExpire value")
	destroy(h)
	rdb.reader_destroy(&r)
	rdb.writer_destroy(&w)
	rdb.writer_init_mem(&w, false, false)
	rdb.put_len(&w, 1)
	rdb.put_len(&w, EB_EXPIRE_TIME_INVALID)
	rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
	h = rdb_load_meta(&r, rdb.TYPE_HASH_METADATA_PRE_GA, true)
	testing.expect(t, h == nil && r.status == .Corrupt)
	testing.expect_value(t, rdb.reader_reason(&r), "invalid expireAt time: 281474976710656")
	destroy(h)
	rdb.reader_destroy(&r)
	rdb.writer_destroy(&w)
}

@(test)
expiry_condition_matrix_checks_before_immediate_delete :: proc(t: ^testing.T) {
	defer ordinary_cleanup()
	for table in ([2]bool{false, true}) {
		for volatile in ([2]bool{false, true}) {
			for condition in ([5]Expire_Condition{.None, .NX, .XX, .GT, .LT}) {
				for deadline in ([4]u64{5, 50, 100, 200}) {
					h := expiry_make(table)
					set(h, ordinary_bytes("f"), ordinary_bytes("v"))
					if volatile {
						expiry_set(t, h, ordinary_bytes("f"), 100)
					}
					allowed := condition == .None || (condition == .NX && !volatile) || (condition == .XX && volatile) || (condition == .GT && volatile && deadline > 100) || (condition == .LT && (!volatile || deadline < 100))
					minimum := EB_EXPIRE_TIME_INVALID
					deleted, updated: int
					result := set_ex_field(h, ordinary_bytes("f"), deadline, condition, 10, &minimum, &deleted, &updated)
					_, actual, found := get_raw(h, ordinary_bytes("f"))
					if !allowed {
						testing.expect(t, result == 0 && deleted == 0 && updated == 0 && found)
						if volatile {
							testing.expect_value(t, actual, u64(100))
						} else {
							testing.expect_value(t, actual, EB_EXPIRE_TIME_INVALID)
						}
					} else if deadline <= 10 {
						testing.expect(t, result == 2 && deleted == 1 && updated == 0 && !found)
					} else {
						testing.expect(t, result == 1 && deleted == 0 && updated == 1 && found && actual == deadline)
					}
					destroy(h)
				}
			}
		}
	}
}

expiry_hook_calls: int
expiry_hook_bytes: [5]u8
expiry_hook_length: int

expiry_own_hook :: proc(h: Hash, field: []u8) {
	expiry_hook_calls += 1
	expiry_hook_length = len(field)
	copy(expiry_hook_bytes[:], field)
}

@(test)
expiry_hook_observes_live_binary_field_before_delete :: proc(t: ^testing.T) {
	previous := field_expired_hook
	defer field_expired_hook = previous
	field_expired_hook = expiry_own_hook
	for table in ([2]bool{false, true}) {
		h := expiry_make(table)
		defer ordinary_cleanup()
		defer destroy(h)
		field := [5]u8{0, 1, 255, 'x', 0}
		set(h, field[:], ordinary_bytes("v"))
		set(h, ordinary_bytes("future"), ordinary_bytes("v2"))
		expiry_set(t, h, field[:], 100)
		expiry_set(t, h, ordinary_bytes("future"), 200)
		expiry_hook_calls = 0
		expiry_hook_bytes = {}
		testing.expect_value(t, expire_due_fields(h, 100, 1), 1)
		testing.expect_value(t, expiry_hook_calls, 1)
		testing.expect_value(t, expiry_hook_length, len(field))
		testing.expect(t, expiry_hook_bytes == field)
		_, _, found := get_raw(h, field[:])
		testing.expect(t, !found)
		testing.expect_value(t, length(h), 1)
	}
}

@(test)
expiry_elapsed_physical_records_obey_conditions :: proc(t: ^testing.T) {
	for table in ([2]bool{false, true}) {
		for condition in ([5]Expire_Condition{.None, .NX, .XX, .GT, .LT}) {
			h := expiry_make(table)
			defer ordinary_cleanup()
			defer destroy(h)
			set(h, ordinary_bytes("f"), ordinary_bytes("v"))
			expiry_set(t, h, ordinary_bytes("f"), 100)
			deadline := u64(200)
			expected := i64(1)
			if condition == .NX {
				expected = 0
			} else if condition == .LT {
				deadline = 50
				expected = 2
			}
			minimum := EB_EXPIRE_TIME_INVALID
			deleted, updated: int
			result := set_ex_field(h, ordinary_bytes("f"), deadline, condition, 150, &minimum, &deleted, &updated)
			testing.expect_value(t, result, expected)
			_, actual, found := get_raw(h, ordinary_bytes("f"))
			if expected == 0 {
				testing.expect(t, found && actual == 100 && deleted == 0 && updated == 0)
			} else if expected == 2 {
				testing.expect(t, !found && deleted == 1 && updated == 0)
			} else {
				testing.expect(t, found && actual == 200 && deleted == 0 && updated == 1)
			}
		}
	}
}

@(test)
expiry_dry_run_uses_strict_deadline_boundary :: proc(t: ^testing.T) {
	h := expiry_make(false)
	defer destroy(h)
	set(h, ordinary_bytes("earlier"), ordinary_bytes("1"))
	set(h, ordinary_bytes("equal"), ordinary_bytes("2"))
	set(h, ordinary_bytes("persistent"), ordinary_bytes("3"))
	expiry_set(t, h, ordinary_bytes("earlier"), 50)
	expiry_set(t, h, ordinary_bytes("equal"), 100)
	testing.expect_value(t, lpex_dry_run(h.lp, 50), 0)
	testing.expect_value(t, lpex_dry_run(h.lp, 100), 1)
	testing.expect_value(t, lpex_dry_run(h.lp, 101), 2)
	testing.expect_value(t, length(h), 3)
	testing.expect_value(t, min_expire(h, true), u64(50))
}

@(test)
expiry_zero_removal_preserves_cached_registry_membership :: proc(t: ^testing.T) {
	for table in ([2]bool{false, true}) {
		reg: Registry
		defer registry_destroy(&reg)
		defer ordinary_cleanup()
		h := expiry_make(table)
		defer destroy(h)
		set(h, ordinary_bytes("volatile"), ordinary_bytes("1"))
		set(h, ordinary_bytes("persistent"), ordinary_bytes("2"))
		expiry_set(t, h, ordinary_bytes("volatile"), 200)
		registry_add(&reg, h, 100)
		quota := 0
		next_deadline, removed := hash_type_expire(h, 1000, &quota, true)
		testing.expect(t, next_deadline == 200 && removed == 0 && quota == 0)
		testing.expect_value(t, registered_expire(h), u64(100))
		testing.expect_value(t, registry_len(&reg), 1)
		quota = 5
		next_deadline, removed = hash_type_expire(h, 199, &quota, true)
		testing.expect(t, next_deadline == 200 && removed == 0 && quota == 5)
		testing.expect_value(t, registered_expire(h), u64(100))
		next_deadline, removed = hash_type_expire(h, 200, &quota, true)
		testing.expect(t, next_deadline == EB_EXPIRE_TIME_INVALID && removed == 1 && quota == 4)
		testing.expect(t, !is_registered(h))
		testing.expect_value(t, length(h), 1)
	}
}

@(test)
expiry_invalid_registration_preserves_membership_and_storage :: proc(t: ^testing.T) {
	source, destination: Registry
	defer registry_destroy(&source)
	defer registry_destroy(&destination)
	h := expiry_make(false)
	defer destroy(h)
	registry_add(&source, h, 100)
	for invalid in ([3]u64{EB_EXPIRE_TIME_INVALID, EB_EXPIRE_TIME_INVALID + 1, max(u64)}) {
		meta := h.hfe
		index := meta.reg_index
		registry_add(&destination, h, invalid)
		testing.expect(t, h.hfe == meta && meta.reg == &source && meta.reg_index == index)
		testing.expect_value(t, registered_expire(h), u64(100))
		testing.expect_value(t, registry_len(&source), 1)
		testing.expect_value(t, registry_len(&destination), 0)
		registry_add(nil, h, invalid)
		testing.expect_value(t, registered_expire(h), u64(100))
	}
	unregistered := create()
	defer destroy(unregistered)
	registry_add(&destination, unregistered, max(u64))
	testing.expect(t, unregistered.hfe == nil)
	testing.expect(t, destination.items == nil && destination.cap == 0)
	registry_add(&destination, unregistered, EB_EXPIRE_TIME_MAX)
	testing.expect_value(t, registered_expire(unregistered), EB_EXPIRE_TIME_MAX)
	expiry_check_registry(t, &source)
	expiry_check_registry(t, &destination)
}

@(test)
expiry_dump_minimum_preserves_table_sentinel :: proc(t: ^testing.T) {
	reg: Registry
	defer registry_destroy(&reg)
	defer ordinary_cleanup()
	h := expiry_make(true)
	defer destroy(h)
	set(h, ordinary_bytes("f"), ordinary_bytes("v"))
	testing.expect_value(t, dump_min_expire(h), EB_EXPIRE_TIME_INVALID)
	expiry_set(t, h, ordinary_bytes("f"), 200)
	registry_add(&reg, h, 100)
	testing.expect_value(t, dump_min_expire(h), u64(200))
	testing.expect_value(t, registered_expire(h), u64(100))
	set(h, ordinary_bytes("f"), ordinary_bytes("noTTL"))
	testing.expect_value(t, dump_min_expire(h), EB_EXPIRE_TIME_INVALID)
	testing.expect_value(t, registered_expire(h), u64(100))
	packed := create()
	defer destroy(packed)
	set(packed, ordinary_bytes("f"), ordinary_bytes("v"))
	testing.expect_value(t, dump_min_expire(packed), u64(0))
	convert_to_ex(packed)
	testing.expect_value(t, dump_min_expire(packed), u64(0))
}
