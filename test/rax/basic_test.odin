package rax_test

import rx "../../src/rax"
import "core:testing"

@(test)
empty_tree_behaviour :: proc(t: ^testing.T) {
	r := rx.create()
	defer rx.destroy(r)
	testing.expect_value(t, r.stored, u64(0))
	v, found := rx.find(r, bytes_of("a"))
	testing.expect(t, v == nil && !found)
	old := rawptr(uintptr(99))
	testing.expect(t, !rx.remove(r, bytes_of("a"), &old))
	testing.expect_value(t, uintptr(old), uintptr(99))
	it: rx.Iterator
	rx.start(&it, r)
	defer rx.stop(&it)
	for op in SEEK_OPS {
		testing.expect(t, rx.seek(&it, op, bytes_of("a")))
		testing.expect(t, rx.eof(&it))
		testing.expect(t, !rx.next(&it))
		testing.expect(t, !rx.prev(&it))
		testing.expect(t, rx.eof(&it))
	}
}

@(test)
insert_overwrite_and_try_insert :: proc(t: ^testing.T) {
	r := rx.create()
	defer rx.destroy(r)
	old: rawptr
	testing.expect(t, rx.insert(r, bytes_of("abc"), rawptr(uintptr(1))))
	testing.expect_value(t, r.stored, u64(1))
	testing.expect(t, !rx.insert(r, bytes_of("abc"), rawptr(uintptr(2)), &old))
	testing.expect_value(t, uintptr(old), uintptr(1))
	testing.expect_value(t, r.stored, u64(1))
	v, found := rx.find(r, bytes_of("abc"))
	testing.expect(t, found && uintptr(v) == 2)
	old = nil
	testing.expect(t, !rx.try_insert(r, bytes_of("abc"), rawptr(uintptr(3)), &old))
	testing.expect_value(t, uintptr(old), uintptr(2))
	v, found = rx.find(r, bytes_of("abc"))
	testing.expect(t, found && uintptr(v) == 2)
	testing.expect(t, rx.try_insert(r, bytes_of("abd"), rawptr(uintptr(4))))
	testing.expect_value(t, r.stored, u64(2))
	testing.expect(t, !rx.try_insert(r, bytes_of("abd"), rawptr(uintptr(5))))
	testing.expect(t, rx.insert(r, nil, rawptr(uintptr(5))))
	v, found = rx.find(r, nil)
	testing.expect(t, found && uintptr(v) == 5)
	v, found = rx.find(r, bytes_of(""))
	testing.expect(t, found && uintptr(v) == 5)
	testing.expect(t, rx.insert(r, bytes_of("x"), nil))
	v, found = rx.find(r, bytes_of("x"))
	testing.expect(t, found && v == nil)
	ref: Reference
	defer ref_destroy(&ref)
	ref_insert(&ref, "", 5)
	ref_insert(&ref, "abc", 2)
	ref_insert(&ref, "abd", 4)
	ref_insert(&ref, "x", 0)
	check_walks(t, r, &ref, "after inserts")
	old = nil
	testing.expect(t, rx.remove(r, bytes_of("abc"), &old))
	testing.expect_value(t, uintptr(old), uintptr(2))
	testing.expect_value(t, r.stored, u64(3))
	old = rawptr(uintptr(77))
	testing.expect(t, !rx.remove(r, bytes_of("abc"), &old))
	testing.expect_value(t, uintptr(old), uintptr(77))
	testing.expect(t, rx.remove(r, bytes_of(""), &old))
	testing.expect_value(t, uintptr(old), uintptr(5))
	testing.expect_value(t, r.stored, u64(2))
	ref_remove(&ref, "abc")
	ref_remove(&ref, "")
	check_walks(t, r, &ref, "after removals")
}

@(test)
byte_order_with_prefixes :: proc(t: ^testing.T) {
	r := rx.create()
	defer rx.destroy(r)
	keys := [?]string{
		"b",
		"a",
		"ab",
		"abc",
		"abd",
		"aa",
		"",
		"b\x00",
		"ba",
		"\xff",
		"\x00",
		"abcdefghijklmnopqrstuvwxyz0123456789",
		"abcdefghijklmnopqrstuvwxyz",
	}
	ref: Reference
	defer ref_destroy(&ref)
	for k, i in keys {
		testing.expect(t, rx.insert(r, bytes_of(k), rawptr(uintptr(i + 1))))
		ref_insert(&ref, k, uintptr(i + 1))
	}
	testing.expect_value(t, r.stored, u64(len(keys)))
	expected := [?]string{
		"",
		"\x00",
		"a",
		"aa",
		"ab",
		"abc",
		"abcdefghijklmnopqrstuvwxyz",
		"abcdefghijklmnopqrstuvwxyz0123456789",
		"abd",
		"b",
		"b\x00",
		"ba",
		"\xff",
	}
	for k, i in expected {
		testing.expect_value(t, ref.items[i].key, k)
	}
	check_walks(t, r, &ref, "ordering")
}

@(test)
prefix_split_and_deletion_boundaries :: proc(t: ^testing.T) {
	r := rx.create()
	defer rx.destroy(r)
	baseline := rx.memory(r)
	ref: Reference
	defer ref_destroy(&ref)
	Step :: struct {
		add: bool,
		key: string,
	}
	steps := [?]Step{
		{true, "abcdef"},
		{true, "abc"},
		{true, "abcxyz"},
		{true, "abd"},
		{true, "a"},
		{false, "abc"},
		{true, "abcd"},
		{false, "abcdef"},
		{false, "a"},
		{false, "abd"},
		{false, "abcxyz"},
		{false, "abcd"},
	}
	for s in steps {
		if s.add {
			testing.expect(t, rx.insert(r, bytes_of(s.key), rawptr(uintptr(len(s.key)))))
			ref_insert(&ref, s.key, uintptr(len(s.key)))
		} else {
			old: rawptr
			testing.expect(t, rx.remove(r, bytes_of(s.key), &old))
			testing.expect_value(t, uintptr(old), uintptr(len(s.key)))
			ref_remove(&ref, s.key)
		}
		testing.expect_value(t, r.stored, u64(len(ref.items)))
		if !check_walks(t, r, &ref, s.key) {
			return
		}
		for e in ref.items {
			v, found := rx.find(r, bytes_of(e.key))
			testing.expect(t, found && uintptr(v) == e.value)
		}
	}
	testing.expect_value(t, rx.memory(r), baseline)
}

Callback_Counter :: struct {
	calls: int,
	sum:   uintptr,
}

@(private = "file")
callback_state: Callback_Counter

@(private = "file")
count_callback :: proc "contextless" (data: rawptr) {
	callback_state.calls += 1
	callback_state.sum += uintptr(data)
}

@(test)
destroy_callback_skips_nil_values :: proc(t: ^testing.T) {
	callback_state = {}
	r := rx.create()
	for i in 0 ..< 8 {
		k := [1]u8{u8('a' + i)}
		v := rawptr(uintptr(i + 1)) if i != 3 else nil
		rx.insert(r, k[:], v)
	}
	rx.destroy(r, count_callback)
	testing.expect_value(t, callback_state.calls, 7)
	testing.expect_value(t, callback_state.sum, uintptr(1 + 2 + 3 + 5 + 6 + 7 + 8))
	r2 := rx.create()
	rx.insert(r2, bytes_of("only"), rawptr(uintptr(1)))
	rx.destroy(r2)
	callback_state = {}
	shared := 0
	r3 := rx.create(&shared)
	want_calls := 0
	want_sum: uintptr = 0
	for i in 0 ..< 50_000 {
		k := id_key(u64(i), 0)
		v: rawptr = nil
		if i % 7 != 0 {
			v = rawptr(uintptr(i))
			want_calls += 1
			want_sum += uintptr(i)
		}
		rx.insert(r3, k[:], v)
	}
	rx.destroy(r3, count_callback)
	testing.expect_value(t, callback_state.calls, want_calls)
	testing.expect_value(t, callback_state.sum, want_sum)
	testing.expect_value(t, shared, 0)
}

@(test)
memory_accounting_and_shared_counter :: proc(t: ^testing.T) {
	shared := 12345
	r := rx.create(&shared)
	baseline := rx.memory(r)
	testing.expect(t, baseline > 0)
	testing.expect_value(t, shared - 12345, baseline)
	for i in 0 ..< 5000 {
		k := id_key(1_700_000_000_000 + u64(i) * 1000, 0)
		rx.insert(r, k[:], rawptr(uintptr(i + 1)))
		if shared - 12345 != rx.memory(r) || rx.memory(r) <= 0 {
			testing.expectf(t, false, "shared drift after insert %d", i)
			break
		}
	}
	per_key := f64(rx.memory(r)) / f64(r.stored)
	testing.expectf(t, per_key < 30, "bytes per sequential id key %.1f", per_key)
	for i in 0 ..< 5000 {
		k := id_key(1_700_000_000_000 + u64(i) * 1000, 0)
		testing.expect(t, rx.remove(r, k[:]))
		if shared - 12345 != rx.memory(r) || rx.memory(r) < baseline {
			testing.expectf(t, false, "shared drift after remove %d", i)
			break
		}
	}
	testing.expect_value(t, r.stored, u64(0))
	testing.expect_value(t, rx.memory(r), baseline)
	names := [?]string{"alice", "bob", "carol", "dave", "erin"}
	for n, i in names {
		rx.insert(r, bytes_of(n), rawptr(uintptr(i)))
	}
	testing.expectf(t, rx.memory(r) < 336, "five names cost %d bytes", rx.memory(r))
	for n in names {
		rx.remove(r, bytes_of(n))
	}
	testing.expect_value(t, rx.memory(r), baseline)
	rx.destroy(r)
	testing.expect_value(t, shared, 12345)
}

@(test)
dense_sequential_ids_are_compact :: proc(t: ^testing.T) {
	r := rx.create()
	defer rx.destroy(r)
	for i in 0 ..< 10_000 {
		k := id_key(1_700_000_000_000 + u64(i) * 7, u64(i % 3))
		rx.insert(r, k[:], rawptr(uintptr(i + 1)))
	}
	per_key := f64(rx.memory(r)) / f64(r.stored)
	testing.expectf(t, per_key < 30, "bytes per key %.1f", per_key)
	testing.expect(t, r.nodes < r.stored / 20)
	it: rx.Iterator
	rx.start(&it, r)
	defer rx.stop(&it)
	probe := id_key(1_700_000_000_000 + 4999 * 7 + 1, 0)
	rx.seek(&it, "<=", probe[:])
	want := id_key(1_700_000_000_000 + 4999 * 7, 4999 % 3)
	testing.expect(t, !rx.eof(&it) && string(rx.key(&it)) == string(want[:]) && uintptr(it.data) == 5000)
	rx.seek(&it, ">", probe[:])
	want = id_key(1_700_000_000_000 + 5000 * 7, 5000 % 3)
	testing.expect(t, !rx.eof(&it) && string(rx.key(&it)) == string(want[:]) && uintptr(it.data) == 5001)
}
