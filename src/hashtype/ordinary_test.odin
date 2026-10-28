package hashtype

import "base:runtime"
import ld "../ldfloat"
import lp "../listpack"
import rdb "../rdb"
import "core:testing"

#assert(size_of(Hash_Object) == 40)
#assert(size_of(Table) == 64)
#assert(size_of(Slot) == 16)
#assert(size_of(Blob) == 12)
#assert(size_of(Vol_Item) == 16)

ordinary_bytes :: proc "contextless" (s: string) -> []u8 {
	return transmute([]u8)s
}

ordinary_key :: proc "contextless" (i: int, buf: ^[21]u8) -> []u8 {
	n := lp.ll2string(raw_data(buf[:]), i64(i))
	return buf[:n]
}

ordinary_cleanup :: proc "contextless" () {
	for maintenance_release() != 0 {}
}

@(test)
ordinary_binary_ownership :: proc(t: ^testing.T) {
	h := create()
	defer destroy(h)
	fields := [4][]u8{ordinary_bytes(""), ordinary_bytes("a\x00b"), ordinary_bytes("7"), ordinary_bytes("-0")}
	values := [4][]u8{ordinary_bytes(""), ordinary_bytes("v\x00x"), ordinary_bytes("-9223372036854775808"), ordinary_bytes("00")}
	for field, i in fields {
		testing.expect(t, !set(h, field, values[i]))
	}
	testing.expect_value(t, length(h), 4)
	for field, i in fields {
		v, res := get(h, field, 0)
		testing.expect_value(t, res, Get_Result.Ok)
		testing.expect(t, value_eq(v, values[i]))
	}
	d, expiry := duplicate(h)
	defer destroy(d)
	testing.expect_value(t, expiry, EB_EXPIRE_TIME_INVALID)
	set(h, fields[1], ordinary_bytes("changed"))
	v, _, found := get_raw(d, fields[1])
	testing.expect(t, found && value_eq(v, values[1]))
	convert(h)
	testing.expect_value(t, h.encoding, Encoding.Hashtable)
	for field, i in fields {
		converted, _, present := get_raw(h, field)
		if i != 1 {
			testing.expect(t, present && value_eq(converted, values[i]))
		}
	}
	reset(h)
	testing.expect_value(t, h.encoding, Encoding.Listpack)
	testing.expect_value(t, length(h), 0)
	testing.expect(t, h.table == nil && h.lp != nil)
}

@(test)
ordinary_distinct_batch_and_thresholds :: proc(t: ^testing.T) {
	old_entries, old_value := hash_max_listpack_entries, hash_max_listpack_value
	defer hash_max_listpack_entries = old_entries
	defer hash_max_listpack_value = old_value
	hash_max_listpack_entries = 3
	hash_max_listpack_value = 4
	h := create()
	defer destroy(h)
	args := [6][]u8{ordinary_bytes("f"), ordinary_bytes("1"), ordinary_bytes("f"), ordinary_bytes("2"), ordinary_bytes("g"), ordinary_bytes("3")}
	testing.expect_value(t, hset(h, args[:]), 2)
	testing.expect_value(t, h.encoding, Encoding.Listpack)
	testing.expect(t, set(h, ordinary_bytes("f"), ordinary_bytes("4")))
	set(h, ordinary_bytes("h"), ordinary_bytes("5"))
	set(h, ordinary_bytes("i"), ordinary_bytes("6"))
	testing.expect_value(t, h.encoding, Encoding.Hashtable)
	reset(h)
	set(h, ordinary_bytes("f"), ordinary_bytes("12345"))
	testing.expect_value(t, h.encoding, Encoding.Hashtable)
	fields := [3][]u8{ordinary_bytes("f"), ordinary_bytes("f"), ordinary_bytes("missing")}
	deleted, empty := hdel(h, fields[:])
	testing.expect_value(t, deleted, 1)
	testing.expect(t, empty)
}

@(test)
ordinary_collision_delete :: proc(t: ^testing.T) {
	table := table_make(10)
	defer ordinary_cleanup()
	defer table_free(table)
	for i in 0 ..< 8 {
		buf: [21]u8
		f := ordinary_key(i, &buf)
		b := blob_new(table, f, f)
		table_place(table, 15, b)
	}
	testing.expect_value(t, table.count, 8)
	for i in ([4]int{0, 3, 7, 2}) {
		buf: [21]u8
		s := slots_find(table.slots, table.cap, ordinary_key(i, &buf), 15)
		testing.expect(t, s != nil)
		if s != nil {
			table_delete_at(table, s)
		}
	}
	for i in ([4]int{1, 4, 5, 6}) {
		buf: [21]u8
		testing.expect(t, slots_find(table.slots, table.cap, ordinary_key(i, &buf), 15) != nil)
	}
	testing.expect_value(t, table.count, 4)
}

ordinary_check_fields :: proc(t: ^testing.T, h: Hash, start, end: int) {
	testing.expect_value(t, length(h), end - start)
	for i in start ..< end {
		buf: [21]u8
		f := ordinary_key(i, &buf)
		v, _, ok := get_raw(h, f)
		testing.expect(t, ok && value_eq(v, f))
	}
	seen := make([]bool, end)
	defer delete(seen)
	it := iterator(h)
	n := 0
	for next(&it) {
		buf: [21]u8
		field := value_bytes(current_field(&it), &buf)
		idx, err := parse_incrby_increment(field)
		testing.expect_value(t, err, Error.None)
		testing.expect(t, idx >= i64(start) && idx < i64(end))
		if idx >= i64(start) && idx < i64(end) {
			testing.expect(t, !seen[idx])
			seen[idx] = true
		}
		n += 1
	}
	testing.expect_value(t, n, end - start)
}

@(test)
ordinary_resize_and_scan :: proc(t: ^testing.T) {
	h := create()
	defer ordinary_cleanup()
	defer destroy(h)
	convert(h)
	for i in 0 ..< 240 {
		buf: [21]u8
		f := ordinary_key(i, &buf)
		set(h, f, f)
	}
	ordinary_check_fields(t, h, 0, 240)
	for h.table.resize != nil {
		table_step(h.table, 64, 4)
	}
	table_resize(h.table, h.table.cap * 2)
	testing.expect(t, h.table.resize != nil)
	out := make([dynamic]Value)
	defer delete(out)
	seen := make([]bool, 240)
	defer delete(seen)
	cursor := u64(0)
	calls := 0
	for {
		clear(&out)
		cursor = scan(h, cursor, Scan_Options{count = 1, no_values = true}, &out, 0)
		for value in out {
			idx, err := parse_incrby_increment(value.str)
			testing.expect_value(t, err, Error.None)
			if idx >= 0 && idx < 240 {
				seen[idx] = true
			}
		}
		table_step(h.table, 3, 1)
		calls += 1
		if cursor == 0 || calls > 4096 {
			break
		}
	}
	testing.expect(t, cursor == 0)
	for found in seen {
		testing.expect(t, found)
	}
	for i in 0 ..< 220 {
		buf: [21]u8
		testing.expect(t, delete_field(h, ordinary_key(i, &buf)))
	}
	ordinary_check_fields(t, h, 220, 240)
	for h.table.resize != nil {
		table_step(h.table, 64, 4)
	}
	clear(&out)
	cursor = 0
	for i in 0 ..< len(seen) {
		seen[i] = false
	}
	for {
		clear(&out)
		cursor = scan(h, cursor, Scan_Options{count = 2, no_values = true}, &out, 0)
		for v in out {
			i, _ := parse_incrby_increment(v.str)
			seen[i] = true
		}
		if cursor == 0 {
			break
		}
	}
	for i in 220 ..< 240 {
		testing.expect(t, seen[i])
	}
}

@(test)
ordinary_expiry_and_increments :: proc(t: ^testing.T) {
	for table in ([2]bool{false, true}) {
		reg: Registry
		defer registry_destroy(&reg)
		defer ordinary_cleanup()
		h := create()
		defer destroy(h)
		set(h, ordinary_bytes("f"), ordinary_bytes("7"))
		set(h, ordinary_bytes("g"), ordinary_bytes("9"))
		if table {
			convert(h)
		} else {
			convert_to_ex(h)
		}
		minf := EB_EXPIRE_TIME_INVALID
		deleted, changed: int
		testing.expect_value(t, set_ex_field(h, ordinary_bytes("f"), 100, .None, 0, &minf, &deleted, &changed), i64(1))
		registry_add(&reg, h, 100)
		v, expiry, ok := get_raw(h, ordinary_bytes("f"))
		testing.expect(t, ok && expiry == 100 && value_eq(v, ordinary_bytes("7")))
		n, err := incrby(h, ordinary_bytes("f"), 2, 100)
		testing.expect_value(t, n, i64(9))
		testing.expect_value(t, err, Error.None)
		_, expiry, ok = get_raw(h, ordinary_bytes("f"))
		testing.expect(t, ok && expiry == 100)
		d, minexp := duplicate(h)
		testing.expect_value(t, minexp, u64(100))
		_, res := get(h, ordinary_bytes("f"), 101)
		testing.expect_value(t, res, Get_Result.Expired)
		testing.expect_value(t, length(h), 1)
		testing.expect(t, is_registered(h))
		testing.expect_value(t, registered_expire(h), u64(100))
		if !table {
			minimum, header_ok := ordinary_saved_minimum(h)
			testing.expect(t, header_ok && minimum == 100)
		}
		_, dexp, dfound := get_raw(d, ordinary_bytes("f"))
		testing.expect(t, dfound && dexp == 100)
		destroy(d)
		set(h, ordinary_bytes("g"), ordinary_bytes("9223372036854775807"))
		_, err = incrby(h, ordinary_bytes("g"), 1, 0)
		testing.expect_value(t, err, Error.Increment_Overflow)
		v, _, _ = get_raw(h, ordinary_bytes("g"))
		testing.expect(t, value_eq(v, ordinary_bytes("9223372036854775807")))
		set(h, ordinary_bytes("g"), ordinary_bytes("00"))
		_, err = incrby(h, ordinary_bytes("g"), 1, 0)
		testing.expect_value(t, err, Error.Hash_Value_Not_Integer)
		set(h, ordinary_bytes("g"), ordinary_bytes("1.25"))
		increment, valid := ld.parse(ordinary_bytes("0.5"))
		testing.expect(t, valid)
		buf: [ld.MAX_LONG_DOUBLE_CHARS]u8
		result, ferr := incrbyfloat(h, ordinary_bytes("g"), increment, buf[:], 0)
		testing.expect_value(t, ferr, Error.None)
		testing.expect(t, bytes_equal(result, ordinary_bytes("1.75")))
	}
}

@(test)
ordinary_random_pairing :: proc(t: ^testing.T) {
	for table in ([2]bool{false, true}) {
		h := create()
		defer destroy(h)
		defer ordinary_cleanup()
		for i in 0 ..< 47 {
			buf: [21]u8
			f := ordinary_key(i, &buf)
			set(h, f, f)
		}
		if table {
			convert(h)
			table_resize(h.table, h.table.cap * 2)
			table_step(h.table, 3, 2)
		}
		fields, values := make([dynamic]Value), make([dynamic]Value)
		defer delete(fields)
		defer delete(values)
		random_unique(h, 29, true, &fields, &values)
		testing.expect_value(t, len(fields), 29)
		seen: [47]bool
		for f, i in fields {
			fb, vb: [21]u8
			idx, err := parse_incrby_increment(value_bytes(f, &fb))
			testing.expect_value(t, err, Error.None)
			testing.expect(t, !seen[idx])
			seen[idx] = true
			testing.expect(t, value_eq(values[i], value_bytes(f, &fb)))
			_ = vb
		}
		clear(&fields)
		clear(&values)
		random_with_repeats(h, 2003, true, &fields, &values)
		testing.expect_value(t, len(fields), 2003)
		for f, i in fields {
			buf: [21]u8
			testing.expect(t, value_eq(values[i], value_bytes(f, &buf)))
		}
	}
}

@(test)
ordinary_rdb_roundtrip_and_partial_reads :: proc(t: ^testing.T) {
	for table in ([2]bool{false, true}) {
		h := create()
		defer destroy(h)
		defer ordinary_cleanup()
		set(h, ordinary_bytes(""), ordinary_bytes(""))
		set(h, ordinary_bytes("bin\x00field"), ordinary_bytes("val\x00ue"))
		set(h, ordinary_bytes("number"), ordinary_bytes("-9223372036854775808"))
		if table {
			convert(h)
		}
		w: rdb.Writer
		rdb.writer_init_mem(&w, false, false)
		defer rdb.writer_destroy(&w)
		rdb_save(&w, h)
		blob := rdb.writer_bytes(&w)
		for size in 0 ..= len(blob) {
			r: rdb.Reader
			rdb.reader_init_mem(&r, blob[:size], false)
			d := rdb_load(&r, int(rdb_type(h)), true)
			if size == len(blob) {
				testing.expect(t, d != nil && r.status == .Ok)
				if d != nil {
					testing.expect_value(t, length(d), 3)
					v, _, ok := get_raw(d, ordinary_bytes("bin\x00field"))
					testing.expect(t, ok && value_eq(v, ordinary_bytes("val\x00ue")))
				}
			} else {
				testing.expect(t, d == nil && r.status != .Ok)
			}
			destroy(d)
			rdb.reader_destroy(&r)
		}
	}
}

@(test)
ordinary_cursor_and_options :: proc(t: ^testing.T) {
	valid := [12]string{"0", "00", "01", "-0", "+0", " 0", "\t1", "18446744073709551615", "-18446744073709551615", "1\x00junk", " -1\x00junk", "-01\x00junk"}
	for spelling in valid {
		_, ok := parse_scan_cursor(ordinary_bytes(spelling))
		testing.expect(t, ok)
	}
	invalid := [10]string{"", "-1", "-2", "-9223372036854775808", "18446744073709551616", "1 ", "\x00", "-1\x00junk", "-2\x00junk", "-9223372036854775808\x00junk"}
	for spelling in invalid {
		_, ok := parse_scan_cursor(ordinary_bytes(spelling))
		testing.expect(t, !ok)
	}
	args := [7][]u8{ordinary_bytes("COUNT"), ordinary_bytes("1"), ordinary_bytes("count"), ordinary_bytes("7"), ordinary_bytes("match"), ordinary_bytes("*"), ordinary_bytes("NOVALUES")}
	opts, err := parse_scan_options(args[:], true)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, opts.count == 7 && opts.no_values && !opts.use_pattern)
	_, range_err := parse_hrandfield_args([][]u8{ordinary_bytes("-9223372036854775808")})
	testing.expect_value(t, range_err, Error.Hrandfield_Count_Range)
	_, with_err := parse_hrandfield_args([][]u8{ordinary_bytes("-4611686018427387904"), ordinary_bytes("WITHVALUES")})
	testing.expect_value(t, with_err, Error.Value_Out_Of_Range)
}

@(test)
ordinary_resize_queue_ownership :: proc(t: ^testing.T) {
	ordinary_cleanup()
	baseline := resize_jobs
	reg: Registry
	defer registry_destroy(&reg)
	defer ordinary_cleanup()
	h := create()
	convert(h)
	for i in 0 ..< 40 {
		buf: [21]u8
		f := ordinary_key(i, &buf)
		set(h, f, f)
	}
	for h.table.resize != nil {
		table_step(h.table, 64, 4)
	}
	table_resize(h.table, 512)
	testing.expect_value(t, resize_jobs, baseline)
	maintenance_bind(h, &reg)
	testing.expect_value(t, resize_jobs, baseline + 1)
	testing.expect_value(t, reg.resize_count, 1)
	for reg.resize_count > 0 {
		_, work := maintenance_step(&reg, 64, 4)
		testing.expect(t, work.scanned <= 64 && work.moved <= 4)
	}
	testing.expect_value(t, resize_jobs, baseline)
	table_resize(h.table, cap_for(40))
	maintenance_bind(h, &reg)
	out := make([dynamic]Value)
	defer delete(out)
	seen: [40]bool
	cursor := u64(0)
	for {
		clear(&out)
		cursor = scan(h, cursor, Scan_Options{count = 1, no_values = true}, &out, 0)
		for value in out {
			i, err := parse_incrby_increment(value.str)
			testing.expect_value(t, err, Error.None)
			seen[i] = true
		}
		maintenance_step(&reg, 3, 1)
		if cursor == 0 {
			break
		}
	}
	for found in seen {
		testing.expect(t, found)
	}
	destroy(h)
	testing.expect_value(t, reg.resize_count, 0)
	testing.expect_value(t, resize_jobs, baseline)
}

@(test)
ordinary_raw_allocator_contract :: proc(t: ^testing.T) {
	features: runtime.Allocator_Mode_Set
	_, query_err := raw_heap_allocator_proc(nil, .Query_Features, 0, 0, &features, 0)
	testing.expect_value(t, query_err, runtime.Allocator_Error.None)
	testing.expect(t, .Alloc in features && .Resize in features && .Free in features)
	data := make([dynamic]u64, 0, 1, raw_heap_allocator())
	for i in 0 ..< 40 {
		append(&data, u64(i) * 123)
	}
	for v, i in data {
		testing.expect_value(t, v, u64(i) * 123)
	}
	delete(data)
	p := mem_alloc(24)
	p[0] = 37
	failed, failure := raw_heap_allocator_proc(nil, .Resize, -1, 8, p, 24)
	testing.expect_value(t, failure, runtime.Allocator_Error.Invalid_Argument)
	testing.expect(t, failed == nil && p[0] == 37)
	mem_free(p)
	mem_free(nil)
	testing.expect_value(t, mem_usable_size(nil), 0)
}

@(test)
ordinary_rdb_duplicate_validation :: proc(t: ^testing.T) {
	old_limit := hash_max_listpack_entries
	defer hash_max_listpack_entries = old_limit
	for deep in ([2]bool{false, true}) {
		for limit in ([2]int{1, 512}) {
			hash_max_listpack_entries = limit
			w: rdb.Writer
			rdb.writer_init_mem(&w, false, false)
			rdb.put_len(&w, 2)
			rdb.put_string(&w, ordinary_bytes("a"))
			rdb.put_string(&w, ordinary_bytes("1"))
			rdb.put_string(&w, ordinary_bytes("a"))
			rdb.put_string(&w, ordinary_bytes("2"))
			r: rdb.Reader
			rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
			h := rdb_load_plain(&r, deep)
			if limit == 512 && !deep {
				testing.expect(t, h != nil && r.status == .Ok)
				testing.expect_value(t, length(h), 2)
				v, _, ok := get_raw(h, ordinary_bytes("a"))
				testing.expect(t, ok && value_eq(v, ordinary_bytes("1")))
			} else {
				testing.expect(t, h == nil && r.status == .Corrupt)
				reason := "Duplicate hash fields detected"
				if limit == 512 {
					reason = "Hash with dup elements"
				}
				testing.expect_value(t, rdb.reader_reason(&r), reason)
			}
			destroy(h)
			rdb.reader_destroy(&r)
			rdb.writer_destroy(&w)
		}
	}
	hash_max_listpack_entries = 1
	packed := lp.lp_new(0)
	packed = lp.lp_append(packed, ordinary_bytes("a"))
	packed = lp.lp_append(packed, ordinary_bytes("1"))
	packed = lp.lp_append(packed, ordinary_bytes("a"))
	packed = lp.lp_append(packed, ordinary_bytes("2"))
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	rdb.put_string(&w, lp.lp_view(packed))
	r: rdb.Reader
	rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
	h := rdb_load_blob(&r, rdb.TYPE_HASH_LISTPACK, false)
	testing.expect(t, h == nil && r.status == .Corrupt)
	testing.expect_value(t, rdb.reader_reason(&r), "Hash listpack integrity check failed.")
	destroy(h)
	rdb.reader_destroy(&r)
	rdb.writer_destroy(&w)
	lp.lp_free(packed)
}

@(test)
ordinary_metadata_copy_and_reset_accounting :: proc(t: ^testing.T) {
	for table in ([2]bool{false, true}) {
		for volatile in ([2]bool{false, true}) {
			reg: Registry
			defer registry_destroy(&reg)
			source_reg: Registry
			defer registry_destroy(&source_reg)
			defer ordinary_cleanup()
			h := create()
			defer destroy(h)
			set(h, ordinary_bytes("f"), ordinary_bytes("value"))
			if table {
				convert(h)
				ensure_meta(h)
			} else {
				convert_to_ex(h)
			}
			testing.expect(t, h.hfe != nil)
			if volatile {
				minf := EB_EXPIRE_TIME_INVALID
				deleted, updated: int
				set_ex_field(h, ordinary_bytes("f"), 100, .None, 0, &minf, &deleted, &updated)
				registry_add(&source_reg, h, 100)
			}
			source_ref, copy_ref: u8
			set_key_ref(h, &source_ref)
			d, expiry := duplicate(h)
			testing.expect(t, d.hfe != nil && d.hfe != h.hfe)
			testing.expect(t, key_ref(d) == nil && !is_registered(d))
			accounted := memory_usage(d)
			if d.encoding == .Hashtable {
				testing.expect_value(t, accounted, mem_usable_size(d) + table_memory(d.table) + mem_usable_size(d.hfe))
			} else {
				testing.expect_value(t, accounted, mem_usable_size(d) + lp.lp_malloc_size(d.lp) + mem_usable_size(d.hfe))
			}
			d.acct = accounted
			set_key_ref(d, &copy_ref)
			testing.expect_value(t, key_ref(d), rawptr(&copy_ref))
			if volatile {
				testing.expect_value(t, expiry, u64(100))
				registry_add(&reg, d, expiry)
				testing.expect_value(t, registry_len(&reg), 1)
			}
			testing.expect_value(t, memory_usage(d), accounted)
			testing.expect_value(t, d.acct, accounted)
			reset(d)
			testing.expect(t, d.hfe == nil && key_ref(d) == nil)
			testing.expect_value(t, registry_len(&reg), 0)
			empty := create()
			testing.expect_value(t, memory_usage(d), memory_usage(empty))
			testing.expect_value(t, d.acct, accounted)
			destroy(empty)
			destroy(d)
		}
	}
}

@(test)
ordinary_loaded_metadata_precedes_attachment :: proc(t: ^testing.T) {
	old_limit := hash_max_listpack_entries
	defer hash_max_listpack_entries = old_limit
	h := create()
	defer destroy(h)
	defer ordinary_cleanup()
	set(h, ordinary_bytes("f"), ordinary_bytes("v"))
	convert_to_ex(h)
	minf := EB_EXPIRE_TIME_INVALID
	deleted, updated: int
	set_ex_field(h, ordinary_bytes("f"), 100, .None, 0, &minf, &deleted, &updated)
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	defer rdb.writer_destroy(&w)
	rdb_save(&w, h)
	for limit in ([2]int{512, 0}) {
		hash_max_listpack_entries = limit
		reg: Registry
		defer registry_destroy(&reg)
		r: rdb.Reader
		rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
		d := rdb_load_blob(&r, rdb.TYPE_HASH_LISTPACK_EX, true)
		testing.expect(t, d != nil && r.status == .Ok)
		if d != nil {
			testing.expect(t, d.hfe != nil && !is_registered(d))
			accounted := memory_usage(d)
			d.acct = accounted
			ref: u8
			set_key_ref(d, &ref)
			registry_add(&reg, d, 100)
			testing.expect_value(t, key_ref(d), rawptr(&ref))
			testing.expect_value(t, memory_usage(d), accounted)
			testing.expect_value(t, registry_len(&reg), 1)
			destroy(d)
			testing.expect_value(t, registry_len(&reg), 0)
		}
		rdb.reader_destroy(&r)
	}
}

@(test)
ordinary_small_table_samples_and_retry_rollback :: proc(t: ^testing.T) {
	h := create()
	defer ordinary_cleanup()
	defer destroy(h)
	convert(h)
	for i in 0 ..< 120 {
		buf: [21]u8
		f := ordinary_key(i, &buf)
		set(h, f, f)
	}
	for h.table.resize != nil {
		table_step(h.table, 64, 4)
	}
	table_resize(h.table, h.table.cap * 2)
	table_step(h.table, 8, 4)
	fields, values := make([dynamic]Value), make([dynamic]Value)
	defer delete(fields)
	defer delete(values)
	append(&fields, Value{str = ordinary_bytes("prefix")})
	append(&values, Value{str = ordinary_bytes("prefix-value")})
	testing.expect(t, !random_unique_try_table(h.table, 2, 1, true, &fields, &values))
	testing.expect_value(t, len(fields), 1)
	testing.expect_value(t, len(values), 1)
	testing.expect(t, value_eq(fields[0], ordinary_bytes("prefix")))
	testing.expect(t, value_eq(values[0], ordinary_bytes("prefix-value")))
	for count in ([3]int{1, 7, 39}) {
		clear(&fields)
		clear(&values)
		random_unique(h, count, true, &fields, &values)
		testing.expect_value(t, len(fields), count)
		seen: [120]bool
		for field, i in fields {
			idx, err := parse_incrby_increment(field.str)
			testing.expect_value(t, err, Error.None)
			testing.expect(t, idx >= 0 && idx < 120)
			if idx >= 0 && idx < 120 {
				testing.expect(t, !seen[idx])
				seen[idx] = true
			}
			testing.expect(t, value_eq(values[i], field.str))
		}
	}
	clear(&fields)
	clear(&values)
	random_with_repeats(h, 1, true, &fields, &values)
	testing.expect_value(t, len(fields), 1)
	testing.expect(t, value_eq(values[0], fields[0].str))
}

@(test)
ordinary_capacity_arithmetic_and_bounded_reader_count :: proc(t: ^testing.T) {
	for n in ([4]int{0, 1, 4, 4096}) {
		capacity, valid := checked_table_capacity(n)
		testing.expect(t, valid && capacity >= max(n, TABLE_INITIAL_SIZE))
		testing.expect(t, capacity <= TABLE_MAX_CAPACITY && capacity & (capacity - 1) == 0)
	}
	capacity, valid := checked_table_capacity(TABLE_MAX_CAPACITY)
	testing.expect(t, valid && capacity == TABLE_MAX_CAPACITY)
	for n in ([4]int{-1, TABLE_MAX_CAPACITY + 1, max(int) - 1, max(int)}) {
		_, ok := checked_table_capacity(n)
		testing.expect(t, !ok)
		_, count_ok := checked_count_capacity(n)
		testing.expect(t, !count_ok)
	}
	_, too_full := checked_count_capacity(TABLE_MAX_CAPACITY)
	testing.expect(t, !too_full)
	for count in ([3]u64{1 << 31, 1 << 63, max(u64) - 1}) {
		w: rdb.Writer
		rdb.writer_init_mem(&w, false, false)
		rdb.put_len(&w, count)
		r: rdb.Reader
		rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
		h := rdb_load_plain(&r, true)
		testing.expect(t, h == nil && r.status == .Short_Read)
		destroy(h)
		rdb.reader_destroy(&r)
		rdb.writer_destroy(&w)
		ordinary_cleanup()
	}
}

@(test)
ordinary_large_rdb_load_across_resize :: proc(t: ^testing.T) {
	defer ordinary_cleanup()
	count :: 13000
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	defer rdb.writer_destroy(&w)
	rdb.put_len(&w, count)
	for i in 0 ..< count {
		buf: [21]u8
		f := ordinary_key(i, &buf)
		rdb.put_string(&w, f)
		rdb.put_string(&w, f)
	}
	r: rdb.Reader
	rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
	defer rdb.reader_destroy(&r)
	h := rdb_load_plain(&r, true)
	testing.expect(t, h != nil && r.status == .Ok)
	if h == nil {
		return
	}
	defer destroy(h)
	testing.expect(t, h.encoding == .Hashtable && h.table.resize != nil)
	ordinary_check_fields(t, h, 0, count)
	second: rdb.Writer
	rdb.writer_init_mem(&second, false, false)
	defer rdb.writer_destroy(&second)
	rdb_save(&second, h)
	reread: rdb.Reader
	rdb.reader_init_mem(&reread, rdb.writer_bytes(&second), false)
	defer rdb.reader_destroy(&reread)
	d := rdb_load_plain(&reread, true)
	testing.expect(t, d != nil && reread.status == .Ok)
	if d != nil {
		ordinary_check_fields(t, d, 0, count)
		destroy(d)
	}
}

@(test)
ordinary_all_fields_preserves_observed_order :: proc(t: ^testing.T) {
	for encoding in ([3]Encoding{.Listpack, .Listpack_Ex, .Hashtable}) {
		h := create()
		defer ordinary_cleanup()
		defer destroy(h)
		observed_fields := [3]string{"f1", "f2", "f3"}
		observed_values := [3]string{"v1", "2", ""}
		for field, i in observed_fields {
			set(h, ordinary_bytes(field), ordinary_bytes(observed_values[i]))
		}
		if encoding == .Listpack_Ex {
			convert_to_ex(h)
		} else if encoding == .Hashtable {
			convert(h)
			table_resize(h.table, h.table.cap * 2)
			table_step(h.table, 1, 1)
		}
		fields, values := make([dynamic]Value), make([dynamic]Value)
		defer delete(fields)
		defer delete(values)
		for count in ([2]int{3, 100}) {
			for with_values in ([2]bool{false, true}) {
				clear(&fields)
				clear(&values)
				random_unique(h, count, with_values, &fields, &values)
				testing.expect_value(t, len(fields), 3)
				if with_values {
					testing.expect_value(t, len(values), 3)
				} else {
					testing.expect_value(t, len(values), 0)
				}
				it := iterator(h)
				for i in 0 ..< 3 {
					testing.expect(t, next(&it))
					field_buf, value_buf: [21]u8
					testing.expect(t, value_eq(fields[i], value_bytes(current_field(&it), &field_buf)))
					if with_values {
						testing.expect(t, value_eq(values[i], value_bytes(current_value(&it), &value_buf)))
					}
					if encoding == .Listpack {
						testing.expect(t, value_eq(fields[i], ordinary_bytes(observed_fields[i])))
						if with_values {
							testing.expect(t, value_eq(values[i], ordinary_bytes(observed_values[i])))
						}
					}
				}
				testing.expect(t, !next(&it))
			}
		}
	}
}

@(test)
ordinary_destroy_releases_owned_banks_immediately :: proc(t: ^testing.T) {
	ordinary_cleanup()
	defer ordinary_cleanup()
	_, retired_before, _ := maintenance_memory()
	for _ in 0 ..< 40 {
		table := table_make(256)
		testing.expect_value(t, table.cap, 512)
		table_resize(table, 1024)
		table_step(table, 64, 4)
		table_free(table)
	}
	_, retired_after, _ := maintenance_memory()
	testing.expect_value(t, retired_after - retired_before, 40 * 8192)
	ordinary_cleanup()
	_, retired_drained, _ := maintenance_memory()
	testing.expect_value(t, retired_drained, 0)
}

@(test)
ordinary_duplicate_add_preserves_both_banks_and_expiry :: proc(t: ^testing.T) {
	h := create()
	defer ordinary_cleanup()
	defer destroy(h)
	convert(h, 20)
	for i in 0 ..< 12 {
		buf: [21]u8
		f := ordinary_key(i, &buf)
		testing.expect(t, table_add_new(h.table, f, f) != nil)
	}
	table_resize(h.table, h.table.cap * 2)
	table_step(h.table, h.table.resize.old_cap, 1)
	testing.expect(t, h.table.resize != nil)
	for bank in 0 ..< 2 {
		slots, capacity := table_bank(h.table, bank)
		b: ^Blob
		for i in 0 ..< capacity {
			if blob_live(slots[i].blob) {
				b = slots[i].blob
				break
			}
		}
		testing.expect(t, b != nil)
		if b == nil {
			continue
		}
		vol_set(h.table, b, 200)
		bytes_before := memory_usage(h)
		count_before := h.table.count
		cursor_before := h.table.resize.cursor
		old_count_before := h.table.resize.old_count
		added := table_add_new(h.table, blob_field(b), ordinary_bytes("replacement"))
		testing.expect(t, added == nil)
		testing.expect_value(t, memory_usage(h), bytes_before)
		testing.expect_value(t, h.table.count, count_before)
		testing.expect_value(t, h.table.resize.cursor, cursor_before)
		testing.expect_value(t, h.table.resize.old_count, old_count_before)
		testing.expect_value(t, table_field_expire(h.table, b), u64(200))
		testing.expect(t, bytes_equal(blob_field(b), blob_value(b)))
	}
}

@(test)
ordinary_metadata_load_duplicate_rejected :: proc(t: ^testing.T) {
	old_limit := hash_max_listpack_entries
	defer hash_max_listpack_entries = old_limit
	hash_max_listpack_entries = 1
	defer ordinary_cleanup()
	for deep in ([2]bool{false, true}) {
		w: rdb.Writer
		rdb.writer_init_mem(&w, false, false)
		rdb.put_ms(&w, 100)
		rdb.put_len(&w, 2)
		rdb.put_len(&w, 1)
		rdb.put_string(&w, ordinary_bytes("f"))
		rdb.put_string(&w, ordinary_bytes("first"))
		rdb.put_len(&w, 0)
		rdb.put_string(&w, ordinary_bytes("f"))
		rdb.put_string(&w, ordinary_bytes("second"))
		r: rdb.Reader
		rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
		h := rdb_load(&r, rdb.TYPE_HASH_METADATA, deep)
		testing.expect(t, h == nil && r.status == .Corrupt)
		testing.expect_value(t, rdb.reader_reason(&r), "Duplicate hash fields detected")
		destroy(h)
		rdb.reader_destroy(&r)
		rdb.writer_destroy(&w)
	}
}

@(test)
ordinary_batch_threshold_counts_supplied_pairs :: proc(t: ^testing.T) {
	old_limit := hash_max_listpack_entries
	defer hash_max_listpack_entries = old_limit
	hash_max_listpack_entries = 2
	defer ordinary_cleanup()
	for count in ([2]int{2, 3}) {
		h := create()
		defer destroy(h)
		args := [6][]u8{ordinary_bytes("f"), ordinary_bytes("1"), ordinary_bytes("f"), ordinary_bytes("2"), ordinary_bytes("f"), ordinary_bytes("3")}
		testing.expect_value(t, hset(h, args[:count * 2]), 1)
		testing.expect_value(t, length(h), 1)
		if count == 2 {
			testing.expect_value(t, h.encoding, Encoding.Listpack)
		} else {
			testing.expect_value(t, h.encoding, Encoding.Hashtable)
		}
		value, _, found := get_raw(h, ordinary_bytes("f"))
		testing.expect(t, found && value_eq(value, args[count * 2 - 1]))
	}
}

ordinary_saved_minimum :: proc(h: Hash) -> (i64, bool) {
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	defer rdb.writer_destroy(&w)
	rdb_save(&w, h)
	r: rdb.Reader
	rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
	defer rdb.reader_destroy(&r)
	return rdb.get_ms(&r)
}

@(test)
ordinary_persistence_minimum_header_by_encoding :: proc(t: ^testing.T) {
	for table in ([2]bool{false, true}) {
		reg: Registry
		defer registry_destroy(&reg)
		defer ordinary_cleanup()
		h := create()
		defer destroy(h)
		set(h, ordinary_bytes("f"), ordinary_bytes("v"))
		set(h, ordinary_bytes("g"), ordinary_bytes("w"))
		if table {
			convert(h)
			ensure_meta(h)
		} else {
			convert_to_ex(h)
			minimum, ok := ordinary_saved_minimum(h)
			testing.expect(t, ok && minimum == 0)
		}
		minf := EB_EXPIRE_TIME_INVALID
		deleted, updated: int
		set_ex_field(h, ordinary_bytes("f"), 200, .None, 0, &minf, &deleted, &updated)
		set_ex_field(h, ordinary_bytes("g"), 900, .None, 0, &minf, &deleted, &updated)
		for registered in ([2]u64{100, 300}) {
			registry_add(&reg, h, registered)
			minimum, ok := ordinary_saved_minimum(h)
			testing.expect(t, ok && minimum == (200 if table else i64(registered)))
			w: rdb.Writer
			rdb.writer_init_mem(&w, false, false)
			rdb_save(&w, h)
			r: rdb.Reader
			rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
			d := rdb_load(&r, int(rdb_type(h)), true)
			testing.expect(t, d != nil && r.status == .Ok)
			if d != nil {
				_, fexp, ffound := get_raw(d, ordinary_bytes("f"))
				_, gexp, gfound := get_raw(d, ordinary_bytes("g"))
				testing.expect(t, ffound && fexp == 200 && gfound && gexp == 900)
			}
			destroy(d)
			rdb.reader_destroy(&r)
			rdb.writer_destroy(&w)
		}
	}
}

@(test)
ordinary_scan_progresses_past_empty_buckets :: proc(t: ^testing.T) {
	h := create()
	defer ordinary_cleanup()
	defer destroy(h)
	convert(h, 10)
	testing.expect_value(t, h.table.cap, 16)
	found := false
	for i in 0 ..< 4096 {
		buf: [21]u8
		f := ordinary_key(i, &buf)
		if hash_field(f) & 15 == 8 {
			set(h, f, ordinary_bytes("value"))
			found = true
			break
		}
	}
	testing.expect(t, found)
	out := make([dynamic]Value)
	defer delete(out)
	scan(h, 0, Scan_Options{count = 1}, &out, 0)
	testing.expect_value(t, len(out), 2)
	if len(out) == 2 {
		testing.expect(t, value_eq(out[1], ordinary_bytes("value")))
	}
	clear(&out)
	cursor := scan(h, 0, Scan_Options{count = max(int)}, &out, 0)
	testing.expect_value(t, cursor, u64(0))
	testing.expect_value(t, len(out), 2)
}

@(test)
ordinary_increments_reset_expired_last_field :: proc(t: ^testing.T) {
	old_limit := hash_max_listpack_entries
	defer hash_max_listpack_entries = old_limit
	for table in ([2]bool{false, true}) {
		for floating in ([2]bool{false, true}) {
			for limit in ([2]int{512, 0}) {
				hash_max_listpack_entries = limit
				reg: Registry
				defer registry_destroy(&reg)
				defer ordinary_cleanup()
				h := create()
				defer destroy(h)
				set(h, ordinary_bytes("f"), ordinary_bytes("7"))
				if table || limit == 0 {
					convert(h)
					ensure_meta(h)
				} else {
					convert_to_ex(h)
				}
				minf := EB_EXPIRE_TIME_INVALID
				deleted, updated: int
				set_ex_field(h, ordinary_bytes("f"), 100, .None, 0, &minf, &deleted, &updated)
				registry_add(&reg, h, 100)
				if floating {
					increment, valid := ld.parse(ordinary_bytes("0.5"))
					testing.expect(t, valid)
					buf: [ld.MAX_LONG_DOUBLE_CHARS]u8
					value, err := incrbyfloat(h, ordinary_bytes("f"), increment, buf[:], 101)
					testing.expect_value(t, err, Error.None)
					testing.expect(t, bytes_equal(value, ordinary_bytes("0.5")))
				} else {
					value, err := incrby(h, ordinary_bytes("f"), 2, 101)
					testing.expect_value(t, err, Error.None)
					testing.expect_value(t, value, i64(2))
				}
				if limit == 0 {
					testing.expect_value(t, h.encoding, Encoding.Hashtable)
				} else {
					testing.expect_value(t, h.encoding, Encoding.Listpack)
				}
				testing.expect(t, h.hfe == nil)
				testing.expect_value(t, registry_len(&reg), 0)
				testing.expect_value(t, length(h), 1)
				_, expiry, found := get_raw(h, ordinary_bytes("f"))
				testing.expect(t, found && expiry == EB_EXPIRE_TIME_INVALID)
			}
		}
	}
}

@(test)
ordinary_copy_preserves_stale_registered_minimum :: proc(t: ^testing.T) {
	for table in ([2]bool{false, true}) {
		reg: Registry
		defer registry_destroy(&reg)
		defer ordinary_cleanup()
		h := create()
		defer destroy(h)
		set(h, ordinary_bytes("f"), ordinary_bytes("v"))
		if table {
			convert(h)
			ensure_meta(h)
		} else {
			convert_to_ex(h)
		}
		minf := EB_EXPIRE_TIME_INVALID
		deleted, updated: int
		set_ex_field(h, ordinary_bytes("f"), 200, .None, 0, &minf, &deleted, &updated)
		registry_add(&reg, h, 100)
		d, minimum := duplicate(h)
		testing.expect_value(t, minimum, u64(100))
		testing.expect(t, d.hfe != nil && d.hfe != h.hfe && !is_registered(d))
		testing.expect(t, key_ref(d) == nil)
		_, expiry, found := get_raw(d, ordinary_bytes("f"))
		testing.expect(t, found && expiry == 200)
		if !table {
			testing.expect(t, d.lp != h.lp && bytes_equal(listpack_bytes(d), listpack_bytes(h)))
		}
		destroy(d)
		set(h, ordinary_bytes("f"), ordinary_bytes("replacement"))
		testing.expect(t, is_registered(h) && registered_expire(h) == 100)
		cleared, stale_minimum := duplicate(h)
		testing.expect_value(t, stale_minimum, u64(100))
		testing.expect(t, cleared.hfe != nil && !is_registered(cleared))
		if !table {
			testing.expect(t, cleared.lp != h.lp && bytes_equal(listpack_bytes(cleared), listpack_bytes(h)))
		}
		destroy(cleared)
	}
}

@(test)
ordinary_registry_transitions_preserve_stale_headers :: proc(t: ^testing.T) {
	for table in ([2]bool{false, true}) {
		reg: Registry
		defer registry_destroy(&reg)
		defer ordinary_cleanup()
		h := create()
		defer destroy(h)
		set(h, ordinary_bytes("a"), ordinary_bytes("1"))
		set(h, ordinary_bytes("b"), ordinary_bytes("2"))
		if table {
			convert(h)
			ensure_meta(h)
		} else {
			convert_to_ex(h)
		}
		minf := EB_EXPIRE_TIME_INVALID
		deleted, updated: int
		set_ex_field(h, ordinary_bytes("a"), 200, .None, 0, &minf, &deleted, &updated)
		registry_add(&reg, h, 100)
		set(h, ordinary_bytes("a"), ordinary_bytes("3"))
		testing.expect(t, is_registered(h) && registered_expire(h) == 100)
		testing.expect(t, !fields_with_expire(h))
		if !table {
			minimum, ok := ordinary_saved_minimum(h)
			testing.expect(t, ok && minimum == 100)
		}
		deleted_count, empty := hdel(h, [][]u8{ordinary_bytes("b")})
		testing.expect(t, deleted_count == 1 && !empty && is_registered(h) && registered_expire(h) == 100)
		set(h, ordinary_bytes("b"), ordinary_bytes("2"))
		minf = EB_EXPIRE_TIME_INVALID
		set_ex_field(h, ordinary_bytes("a"), 200, .None, 0, &minf, &deleted, &updated)
		deleted_count, empty = hdel(h, [][]u8{ordinary_bytes("zz"), ordinary_bytes("a")})
		testing.expect(t, deleted_count == 1 && !empty && !is_registered(h))
		set(h, ordinary_bytes("a"), ordinary_bytes("1"))
		minf = EB_EXPIRE_TIME_INVALID
		set_ex_field(h, ordinary_bytes("a"), 200, .None, 0, &minf, &deleted, &updated)
		registry_add(&reg, h, 100)
		testing.expect(t, delete_field(h, ordinary_bytes("a")))
		testing.expect(t, is_registered(h) && registered_expire(h) == 100)
		deleted_count, empty = hdel(h, [][]u8{ordinary_bytes("b")})
		testing.expect(t, deleted_count == 1 && empty && !is_registered(h))
	}
}

@(test)
ordinary_packed_unique_sample_keeps_pack_order :: proc(t: ^testing.T) {
	for extended in ([2]bool{false, true}) {
		h := create()
		defer destroy(h)
		defer ordinary_cleanup()
		for i in 0 ..< 12 {
			buf: [21]u8
			f := ordinary_key(i, &buf)
			set(h, f, f)
		}
		if extended {
			convert_to_ex(h)
			minf := EB_EXPIRE_TIME_INVALID
			deleted, updated: int
			set_ex_field(h, ordinary_bytes("9"), 500, .None, 0, &minf, &deleted, &updated)
			set_ex_field(h, ordinary_bytes("4"), 300, .None, 0, &minf, &deleted, &updated)
		}
		position: [12]int
		it := iterator(h)
		row := 0
		for next(&it) {
			fb: [21]u8
			idx, _ := parse_incrby_increment(value_bytes(current_field(&it), &fb))
			position[idx] = row
			row += 1
		}
		fields, values := make([dynamic]Value), make([dynamic]Value)
		defer delete(fields)
		defer delete(values)
		hits: [12]int
		for count in 2 ..< 12 {
			for _ in 0 ..< 40 {
				clear(&fields)
				clear(&values)
				random_unique(h, count, true, &fields, &values)
				testing.expect_value(t, len(fields), count)
				testing.expect_value(t, len(values), count)
				last := -1
				for f, i in fields {
					fb: [21]u8
					idx, err := parse_incrby_increment(value_bytes(f, &fb))
					testing.expect(t, err == .None && idx >= 0 && idx < 12)
					if err != .None || idx < 0 || idx >= 12 {
						continue
					}
					testing.expect(t, position[idx] > last)
					last = position[idx]
					testing.expect(t, value_eq(values[i], value_bytes(f, &fb)))
					hits[idx] += 1
				}
			}
		}
		for n in hits {
			testing.expect(t, n > 0)
		}
	}
}

@(test)
ordinary_word_comparison_exact_unaligned_slices :: proc(t: ^testing.T) {
	for size in 0 ..= 80 {
		for offset in 0 ..< 8 {
			left_storage := mem_alloc(max(size + offset, 1))
			right_offset := 7 - offset
			right_storage := mem_alloc(max(size + right_offset, 1))
			left := (cast([^]u8)(uintptr(left_storage) + uintptr(offset)))[:size]
			right := (cast([^]u8)(uintptr(right_storage) + uintptr(right_offset)))[:size]
			for i in 0 ..< size {
				left[i] = u8(i * 37 + 11)
				right[i] = left[i]
			}
			testing.expect(t, bytes_equal(left, right))
			for i in 0 ..< size {
				right[i] ~= 0x80
				testing.expect(t, !bytes_equal(left, right))
				right[i] ~= 0x80
			}
			if size > 0 {
				testing.expect(t, !bytes_equal(left, right[:size - 1]))
			}
			mem_free(left_storage)
			mem_free(right_storage)
		}
	}
}

@(test)
ordinary_random_boundaries_and_coverage :: proc(t: ^testing.T) {
	saved_state := random_state
	defer random_state = saved_state
	random_state = 0x92d78269c4ab105f
	testing.expect_value(t, rand_below(0), u64(0))
	testing.expect_value(t, rand_below(1), u64(0))
	for bound in ([8]u64{2, 4, 8, 16, 32, 64, 128, 256}) {
		seen: [256]bool
		for _ in 0 ..< 4096 {
			value := rand_below(bound)
			testing.expect(t, value < bound)
			if value < bound {
				seen[value] = true
			}
		}
		for i in 0 ..< int(bound) {
			testing.expect(t, seen[i])
		}
	}
	for bound in ([8]u64{3, 5, 17, 255, 257, 1 << 32, 1 << 63, max(u64)}) {
		for _ in 0 ..< 129 {
			testing.expect(t, rand_below(bound) < bound)
		}
	}
}

@(test)
ordinary_packed_length_unknown_cache :: proc(t: ^testing.T) {
	for extended in ([2]bool{false, true}) {
		h := create()
		defer destroy(h)
		for i in 0 ..< 27 {
			buf: [21]u8
			f := ordinary_key(i, &buf)
			set(h, f, f)
		}
		if extended {
			convert_to_ex(h)
		}
		lp.lp_set_num_elements(h.lp, lp.LP_HDR_NUMELE_UNKNOWN)
		testing.expect_value(t, length(h), 27)
		lp.lp_set_num_elements(h.lp, lp.LP_HDR_NUMELE_UNKNOWN)
		testing.expect(t, set(h, ordinary_bytes("3"), ordinary_bytes("replacement")))
		testing.expect_value(t, length(h), 27)
		value, _, found := get_raw(h, ordinary_bytes("3"))
		testing.expect(t, found && value_eq(value, ordinary_bytes("replacement")))
	}
}

@(test)
ordinary_blob_replacement_preserves_borrowed_inputs :: proc(t: ^testing.T) {
	h := create()
	defer ordinary_cleanup()
	defer destroy(h)
	convert(h)
	key := ordinary_bytes("binary\x00key")
	set(h, key, ordinary_bytes("field\x00value"))
	value, _, _ := get_raw(h, key)
	testing.expect(t, set(h, key, value.str[1:], true))
	after, expiry, found := get_raw(h, key)
	testing.expect(t, found && expiry == EB_EXPIRE_TIME_INVALID && value_eq(after, ordinary_bytes("ield\x00value")))
	minf := EB_EXPIRE_TIME_INVALID
	deleted, updated: int
	set_ex_field(h, key, 200, .None, 0, &minf, &deleted, &updated)
	borrowed, _, _ := get_raw(h, key)
	set(h, borrowed.str, key)
	set(h, key, ordinary_bytes("resized replacement"), true)
	new_value, new_expiry, present := get_raw(h, key)
	testing.expect(t, present && new_expiry == 200 && value_eq(new_value, ordinary_bytes("resized replacement")))
	independent, no_expiry, exists_new := get_raw(h, ordinary_bytes("ield\x00value"))
	testing.expect(t, exists_new && no_expiry == EB_EXPIRE_TIME_INVALID && value_eq(independent, key))
}
