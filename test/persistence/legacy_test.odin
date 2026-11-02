package persistence

import "base:runtime"
import "core:strings"
import "core:testing"
import j "../../src"
import lp "../../src/listpack"
import "../../src/rdb"

Zl_Item :: struct {
	text:   string,
	value:  i64,
	is_int: bool,
}

zs :: proc(s: string) -> Zl_Item {
	return Zl_Item{text = s}
}

zi :: proc(v: i64) -> Zl_Item {
	return Zl_Item{value = v, is_int = true}
}

put_le :: proc(out: ^[dynamic]u8, v: u64, width: int) {
	for i in 0 ..< width {
		append(out, u8(v >> (8 * uint(i))))
	}
}

zl_entry_body :: proc(out: ^[dynamic]u8, item: Zl_Item) {
	if !item.is_int {
		n := len(item.text)
		switch {
		case n < 64:
			append(out, u8(n))
		case n < 16384:
			append(out, u8(0x40 | n >> 8), u8(n & 0xFF))
		case:
			append(out, 0x80, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n))
		}
		append(out, item.text)
		return
	}
	v := item.value
	switch {
	case v >= 0 && v <= 12:
		append(out, u8(0xF1 + v))
	case v >= -128 && v <= 127:
		append(out, 0xFE)
		put_le(out, u64(v), 1)
	case v >= -32768 && v <= 32767:
		append(out, 0xC0)
		put_le(out, u64(v), 2)
	case v >= -(1 << 23) && v < 1 << 23:
		append(out, 0xF0)
		put_le(out, u64(v), 3)
	case v >= i64(min(i32)) && v <= i64(max(i32)):
		append(out, 0xD0)
		put_le(out, u64(v), 4)
	case:
		append(out, 0xE0)
		put_le(out, u64(v), 8)
	}
}

zl_build :: proc(items: []Zl_Item, declared: int = -1) -> []u8 {
	out: [dynamic]u8
	out.allocator = context.temp_allocator
	for _ in 0 ..< 10 {
		append(&out, 0)
	}
	prev := 0
	tail := 10
	for item in items {
		start := len(out)
		tail = start
		if prev < 254 {
			append(&out, u8(prev))
		} else {
			append(&out, 0xFE)
			put_le(&out, u64(prev), 4)
		}
		zl_entry_body(&out, item)
		prev = len(out) - start
	}
	append(&out, 0xFF)
	total := len(out)
	for i in 0 ..< 4 {
		out[i] = u8(total >> (8 * uint(i)))
		out[4 + i] = u8(tail >> (8 * uint(i)))
	}
	count := len(items) if declared < 0 else declared
	out[8] = u8(count)
	out[9] = u8(count >> 8)
	return out[:]
}

zl_collect :: proc(t: ^testing.T, zl: []u8) -> (items: [dynamic]string, failed: bool) {
	items.allocator = context.temp_allocator
	if !rdb.ziplist_check_header(zl) {
		return items, true
	}
	it := rdb.ziplist_iter(zl)
	e: rdb.Zl_Entry
	for rdb.ziplist_next(&it, &e) {
		buf: [24]u8
		append(&items, strings.clone(string(rdb.zl_entry_bytes(&e, &buf)), context.temp_allocator))
	}
	return items, it.failed
}

@(test)
ziplist_every_encoding :: proc(t: ^testing.T) {
	long := strings.repeat("L", 300, context.temp_allocator)
	huge := strings.repeat("H", 20000, context.temp_allocator)
	items := []Zl_Item {
		zs(""), zs("a"), zs(strings.repeat("s", 63, context.temp_allocator)), zs(strings.repeat("m", 64, context.temp_allocator)), zs(long), zs("after-long"), zs(huge), zs("after-huge"),
		zi(0), zi(12), zi(13), zi(-1), zi(127), zi(-128), zi(128), zi(-32768), zi(32767), zi(40000), zi(-8388608), zi(8388607),
		zi(8388608), zi(i64(min(i32))), zi(i64(max(i32))), zi(i64(max(i32)) + 1), zi(min(i64)), zi(max(i64)),
	}
	zl := zl_build(items)
	got, failed := zl_collect(t, zl)
	testing.expect(t, !failed)
	testing.expect_value(t, len(got), len(items))
	for item, i in items {
		if i >= len(got) {
			break
		}
		want := item.text
		if item.is_int {
			buf: [24]u8
			want = strings.clone(itoa(buf[:], item.value), context.temp_allocator)
		}
		testing.expectf(t, got[i] == want, "entry %d: %q vs %q", i, got[i][:min(len(got[i]), 20)], want[:min(len(want), 20)])
	}
	it := rdb.ziplist_iter(zl)
	e: rdb.Zl_Entry
	ints := 0
	for rdb.ziplist_next(&it, &e) {
		if e.is_int {
			ints += 1
		}
	}
	testing.expect_value(t, ints, 18)
	testing.expect(t, it.done && !it.failed)
	testing.expect_value(t, it.count, u32(len(items)))
	unknown := zl_build(items, 0xFFFF)
	_, ufailed := zl_collect(t, unknown)
	testing.expect(t, !ufailed)
	empty := zl_build({})
	testing.expect_value(t, len(empty), 11)
	eitems, efailed := zl_collect(t, empty)
	testing.expect(t, !efailed && len(eitems) == 0)
}

@(test)
ziplist_rejections :: proc(t: ^testing.T) {
	base := zl_build({zs("a"), zi(5), zs("hello"), zi(1000)})
	Mutation :: struct {
		at:    int,
		value: u8,
	}
	mutations := []Mutation {
		{0, 0x10},
		{4, 0x40},
		{8, 9},
		{10, 3},
		{len(base) - 1, 0x00},
		{13, 0xFF},
		{14, 0x81},
		{15, 0x81},
	}
	for m in mutations {
		bad := make([]u8, len(base), context.temp_allocator)
		copy(bad, base)
		bad[m.at] = m.value
		_, failed := zl_collect(t, bad)
		testing.expectf(t, failed, "mutation at %d not detected", m.at)
	}
	truncated := base[:len(base) - 3]
	_, tfailed := zl_collect(t, truncated)
	testing.expect(t, tfailed)
	testing.expect(t, !rdb.ziplist_check_header(nil))
	testing.expect(t, !rdb.ziplist_check_header(base[:10]))
	short_entry := zl_build({zs("abcdef")})
	short_entry[11] = 40
	_, sfailed := zl_collect(t, short_entry)
	testing.expect(t, sfailed)
	wrong_tail := zl_build({zs("a"), zs("b")})
	wrong_tail[4] = 10
	_, wfailed := zl_collect(t, wrong_tail)
	testing.expect(t, wfailed)
}

@(test)
ziplist_listpack_conversion :: proc(t: ^testing.T) {
	pairs := zl_build({zs("f1"), zs("v1"), zs("f2"), zi(42), zs("f3"), zs("")})
	packed, good := rdb.ziplist_to_listpack(pairs, true)
	testing.expect(t, good)
	testing.expect_value(t, lp.lp_length(packed), u64(6))
	testing.expect(t, rdb.lp_validate_dups(lp.lp_view(packed), true, 2))
	p := lp.lp_first(packed)
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	want := []string{"f1", "v1", "f2", "42", "f3", ""}
	for w in want {
		testing.expect(t, p != nil && string(lp.lp_get_bytes(p, &buf)) == w)
		p = lp.lp_next(packed, p)
	}
	lp.lp_free(packed)
	dup := zl_build({zs("f1"), zs("v1"), zs("f1"), zs("v2")})
	_, dgood := rdb.ziplist_to_listpack(dup, true)
	testing.expect(t, !dgood)
	plain, pgood := rdb.ziplist_to_listpack(dup, false)
	testing.expect(t, pgood)
	lp.lp_free(plain)
	odd := zl_build({zs("a"), zs("b"), zs("c")})
	_, ogood := rdb.ziplist_to_listpack(odd, true)
	testing.expect(t, !ogood)
	ints := zl_build({zi(1), zs("x"), zs("1"), zs("y")})
	_, igood := rdb.ziplist_to_listpack(ints, true)
	testing.expect(t, !igood)
	many: [dynamic]Zl_Item
	many.allocator = context.temp_allocator
	for i in 0 ..< 300 {
		buf2: [24]u8
		append(&many, zs(strings.concatenate({"item", itoa(buf2[:], i64(i))}, context.temp_allocator)))
	}
	big, bgood := rdb.ziplist_to_listpack(zl_build(many[:]), false)
	testing.expect(t, bgood)
	testing.expect_value(t, lp.lp_length(big), u64(300))
	lp.lp_free(big)
	broken := zl_build({zs("a"), zs("b")})
	broken[8] = 3
	_, bkgood := rdb.ziplist_to_listpack(broken, false)
	testing.expect(t, !bkgood)
}

zm_len :: proc(out: ^[dynamic]u8, n: int) {
	if n < rdb.ZIPMAP_BIGLEN {
		append(out, u8(n))
	} else {
		append(out, u8(rdb.ZIPMAP_BIGLEN))
		put_le(out, u64(n), 4)
	}
}

zm_build :: proc(pairs: []string, free: int = 0, declared: int = -1) -> []u8 {
	out: [dynamic]u8
	out.allocator = context.temp_allocator
	count := len(pairs) / 2 if declared < 0 else declared
	append(&out, u8(min(count, 254)))
	for i := 0; i + 1 < len(pairs); i += 2 {
		zm_len(&out, len(pairs[i]))
		append(&out, pairs[i])
		zm_len(&out, len(pairs[i + 1]))
		append(&out, u8(free))
		append(&out, pairs[i + 1])
		for _ in 0 ..< free {
			append(&out, '#')
		}
	}
	append(&out, u8(rdb.ZIPMAP_END))
	return out[:]
}

@(test)
zipmap_validation_and_iteration :: proc(t: ^testing.T) {
	big := strings.repeat("z", 300, context.temp_allocator)
	pairs := []string{"name", "eski", "empty", "", big, "big-key", "k", big}
	for free in ([]int{0, 3}) {
		zm := zm_build(pairs, free)
		testing.expect(t, rdb.zipmap_validate(zm))
		it := rdb.Zipmap_Iter {
			zm = zm,
			p  = 1,
		}
		k, v: []u8
		i := 0
		for rdb.zipmap_next(&it, &k, &v) {
			testing.expect(t, string(k) == pairs[i] && string(v) == pairs[i + 1])
			i += 2
		}
		testing.expect_value(t, i, len(pairs))
	}
	testing.expect(t, rdb.zipmap_validate(zm_build({}, 0)))
	padded_key := []u8{1, 0xFE, 4, 0, 0, 0, 'k', 'e', 'y', '1', 1, 0, 'v', 0xFF}
	testing.expect(t, !rdb.zipmap_validate(padded_key))
	padded_value := []u8{1, 1, 'k', 0xFE, 4, 0, 0, 0, 0, 'v', 'a', 'l', '1', 0xFF}
	testing.expect(t, !rdb.zipmap_validate(padded_value))
	padded_it := rdb.Zipmap_Iter {
		zm = padded_value,
		p  = 1,
	}
	pk, pv: []u8
	testing.expect(t, !rdb.zipmap_next(&padded_it, &pk, &pv))
	boundary := []u8{1, 0xFE, 0xFE, 0, 0, 0}
	testing.expect(t, !rdb.zipmap_validate(boundary))
	testing.expect(t, !load_value(t, "zm:padded", rdb.TYPE_HASH_ZIPMAP, string_payload(padded_key), false))
	good := zm_build(pairs)
	testing.expect(t, !rdb.zipmap_validate(good[:len(good) - 1]))
	testing.expect(t, !rdb.zipmap_validate(zm_build(pairs, 0, 3)))
	testing.expect(t, rdb.zipmap_validate(zm_build(pairs, 0, 254)))
	cut := make([]u8, 8, context.temp_allocator)
	copy(cut, good[:7])
	cut[7] = rdb.ZIPMAP_END
	testing.expect(t, !rdb.zipmap_validate(cut))
	over := make([]u8, len(good), context.temp_allocator)
	copy(over, good)
	over[1] = 200
	testing.expect(t, !rdb.zipmap_validate(over))
	testing.expect(t, !rdb.zipmap_validate(nil))
}

@(test)
duplicate_set :: proc(t: ^testing.T) {
	d: rdb.Dup_Set
	defer rdb.dup_destroy(&d)
	for i in 0 ..< 2000 {
		buf: [24]u8
		testing.expect(t, rdb.dup_add(&d, transmute([]u8)itoa(buf[:], i64(i))))
	}
	for i in 0 ..< 2000 {
		buf: [24]u8
		testing.expect(t, !rdb.dup_add(&d, transmute([]u8)itoa(buf[:], i64(i))))
	}
	testing.expect(t, rdb.dup_add(&d, nil))
	testing.expect(t, !rdb.dup_add(&d, nil))
	testing.expect_value(t, d.count, 2001)
}

lp_of :: proc(items: []string) -> [^]u8 {
	p := lp.lp_new(0)
	for s in items {
		p = lp.lp_append(p, transmute([]u8)s)
	}
	return p
}

@(test)
listpack_duplicate_validation :: proc(t: ^testing.T) {
	Case :: struct {
		items: []string,
		tuple: int,
		deep:  bool,
	}
	cases := []Case {
		{{"a", "b", "c"}, 1, true},
		{{"m", "1.5", "n", "2"}, 2, true},
		{{"f", "v", "5", "g", "w", "7", "h", "x", "0"}, 3, true},
		{{"f", "v", "5", "g", "w", "5"}, 3, true},
		{{"1", "2", "3"}, 1, true},
	}
	for c in cases {
		p := lp_of(c.items)
		testing.expectf(t, rdb.lp_validate_dups(lp.lp_view(p), c.deep, c.tuple), "%v should validate", c.items)
		lp.lp_free(p)
	}
	rejects := []Case {
		{{"a", "b", "a"}, 1, true},
		{{"1", "x", "01", "1"}, 1, true},
		{{"m", "1", "m", "2"}, 2, true},
		{{"m", "1", "n"}, 2, true},
		{{"f", "v", "7", "g", "w", "5"}, 3, true},
		{{"f", "v", "0", "g", "w", "5"}, 3, true},
		{{"f", "v", "abc"}, 3, true},
		{{"f", "v", "-1"}, 3, true},
		{{"f", "v", "281474976710656"}, 3, true},
		{{"f", "v", "1", "f", "w", "2"}, 3, true},
	}
	for c in rejects {
		p := lp_of(c.items)
		ok := rdb.lp_validate_dups(lp.lp_view(p), c.deep, c.tuple)
		testing.expectf(t, !ok, "%v should be rejected", c.items)
		testing.expect(t, rdb.lp_validate_dups(lp.lp_view(p), false, c.tuple))
		lp.lp_free(p)
	}
	broken := lp_of({"a", "b"})
	view := lp.lp_view(broken)
	view[0] += 1
	testing.expect(t, !rdb.lp_validate_dups(view, false, 1))
	view[0] -= 1
	view[len(view) - 1] = 0
	testing.expect(t, !rdb.lp_validate_dups(view, true, 1))
	lp.lp_free(broken)
	testing.expect(t, !rdb.lp_validate_dups(nil, true, 1))
	src := lp_of({"x", "y"})
	dup := rdb.lp_copy(lp.lp_view(src))
	testing.expect(t, string(lp.lp_view(dup)) == string(lp.lp_view(src)))
	testing.expect(t, rdb.lp_copy(nil) == nil)
	lp.lp_free(src)
	lp.lp_free(dup)
}

value_image :: proc(type_byte: u8, payload: []u8) -> []u8 {
	out := make([]u8, len(payload) + 1, context.temp_allocator)
	out[0] = type_byte
	copy(out[1:], payload)
	return out
}

string_payload :: proc(blob: []u8) -> []u8 {
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	rdb.put_string(&w, blob)
	out := strings.clone(string(rdb.writer_bytes(&w)), context.temp_allocator)
	rdb.writer_destroy(&w)
	return transmute([]u8)out
}

load_value :: proc(t: ^testing.T, key: string, type_byte: int, payload: []u8, deep: bool) -> bool {
	context.allocator = runtime.heap_allocator()
	r: rdb.Reader
	rdb.reader_init_mem(&r, payload, false)
	defer rdb.reader_destroy(&r)
	v := j.persist_load_object(&r, type_byte, deep)
	if !rdb.ok(&r) {
		return false
	}
	testing.expect_value(t, rdb.reader_offset(&r), i64(len(payload)))
	e, created := j.db_upsert_in(&j.dbs[0], transmute([]u8)key)
	testing.expect(t, created)
	j.persist_attach(e, transmute([]u8)key, v)
	return true
}

@(test)
legacy_types_through_loader :: proc(t: ^testing.T) {
	server_reset()
	list := zl_build({zs("a"), zi(7), zs("c")})
	testing.expect(t, load_value(t, "zl:list", rdb.TYPE_LIST_ZIPLIST, string_payload(list), true))
	expect_reply(t, cmd("LRANGE", "zl:list", "0", "-1"), "*3\r\n$1\r\na\r\n$1\r\n7\r\n$1\r\nc\r\n", "ziplist list")
	zset := zl_build({zs("m1"), zs("1.5"), zs("m2"), zi(3)})
	testing.expect(t, load_value(t, "zl:zset", rdb.TYPE_ZSET_ZIPLIST, string_payload(zset), true))
	expect_reply(t, cmd("ZSCORE", "zl:zset", "m2"), bulk("3"), "ziplist zset")
	hash := zl_build({zs("f"), zs("v"), zs("n"), zi(9)})
	testing.expect(t, load_value(t, "zl:hash", rdb.TYPE_HASH_ZIPLIST, string_payload(hash), true))
	expect_reply(t, cmd("HGET", "zl:hash", "n"), bulk("9"), "ziplist hash")
	zm := zm_build({"field", "value", "other", "x"}, 2)
	testing.expect(t, load_value(t, "zm:hash", rdb.TYPE_HASH_ZIPMAP, string_payload(zm), true))
	expect_reply(t, cmd("HGET", "zm:hash", "field"), bulk("value"), "zipmap hash")
	expect_reply(t, cmd("HLEN", "zm:hash"), integer(2), "zipmap hash")
	quick: [dynamic]u8
	quick.allocator = context.temp_allocator
	append(&quick, 2)
	append(&quick, ..string_payload(zl_build({zs("q1"), zs("q2")})))
	append(&quick, ..string_payload(zl_build({zs("q3")})))
	testing.expect(t, load_value(t, "zl:quick", rdb.TYPE_LIST_QUICKLIST, quick[:], true))
	expect_reply(t, cmd("LRANGE", "zl:quick", "0", "-1"), "*3\r\n$2\r\nq1\r\n$2\r\nq2\r\n$2\r\nq3\r\n", "quicklist")
	intset := []u8{4, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 9, 0, 0, 0}
	testing.expect(t, load_value(t, "is:set", rdb.TYPE_SET_INTSET, string_payload(intset), true))
	expect_reply(t, cmd("SCARD", "is:set"), integer(3), "intset")
	unsorted := []u8{4, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 9, 0, 0, 0, 5, 0, 0, 0}
	testing.expect(t, !load_value(t, "is:bad", rdb.TYPE_SET_INTSET, string_payload(unsorted), true))
	testing.expect(t, load_value(t, "is:shallow", rdb.TYPE_SET_INTSET, string_payload(unsorted), false))
	dupzl := zl_build({zs("f"), zs("v"), zs("f"), zs("w")})
	testing.expect(t, !load_value(t, "zl:dup", rdb.TYPE_HASH_ZIPLIST, string_payload(dupzl), true))
	badzl := zl_build({zs("a")})
	badzl[8] = 2
	testing.expect(t, !load_value(t, "zl:bad", rdb.TYPE_LIST_ZIPLIST, string_payload(badzl), true))
	text_zset := []u8{2, 1, 'a', 3, '1', '.', '5', 1, 'b', 253}
	testing.expect(t, !load_value(t, "z:nan", rdb.TYPE_ZSET, text_zset, true))
	text_zset[len(text_zset) - 1] = 254
	testing.expect(t, load_value(t, "z:text", rdb.TYPE_ZSET, text_zset, true))
	expect_reply(t, cmd("ZRANGE", "z:text", "0", "-1"), "*2\r\n$1\r\na\r\n$1\r\nb\r\n", "text zset")
	old_list := []u8{2, 1, 'x', 0xC0, 5}
	testing.expect(t, load_value(t, "l:old", rdb.TYPE_LIST, old_list, true))
	expect_reply(t, cmd("LRANGE", "l:old", "0", "-1"), "*2\r\n$1\r\nx\r\n$1\r\n5\r\n", "plain list")
	server_reset()
}
