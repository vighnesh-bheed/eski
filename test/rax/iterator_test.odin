package rax_test

import rx "../../src/rax"
import "core:math/rand"
import "core:strings"
import "core:testing"

Seek_Row :: struct {
	op:     string,
	key:    string,
	states: [5]uintptr,
}

SEEK_TABLE :: [?]Seek_Row{
	{"=", "", {0, 0, 0, 0, 0}},
	{"=", "\x00", {0, 0, 0, 0, 0}},
	{"=", "a", {1, 1, 2, 1, 0}},
	{"=", "aa", {2, 2, 3, 2, 1}},
	{"=", "aaa", {0, 0, 0, 0, 0}},
	{"=", "ab", {3, 3, 4, 3, 2}},
	{"=", "abb", {0, 0, 0, 0, 0}},
	{"=", "abc", {4, 4, 5, 4, 3}},
	{"=", "abcd", {0, 0, 0, 0, 0}},
	{"=", "abd", {5, 5, 6, 5, 4}},
	{"=", "abe", {0, 0, 0, 0, 0}},
	{"=", "b", {6, 6, 7, 6, 5}},
	{"=", "ba", {0, 0, 0, 0, 0}},
	{"=", "bz", {7, 7, 8, 7, 6}},
	{"=", "c", {0, 0, 0, 0, 0}},
	{"=", "\xfe", {8, 8, 0, 8, 7}},
	{"=", "\xff", {0, 0, 0, 0, 0}},
	{">", "", {1, 1, 2, 1, 0}},
	{">", "\x00", {1, 1, 2, 1, 0}},
	{">", "a", {2, 2, 3, 2, 1}},
	{">", "aa", {3, 3, 4, 3, 2}},
	{">", "aaa", {3, 3, 4, 3, 2}},
	{">", "ab", {4, 4, 5, 4, 3}},
	{">", "abb", {4, 4, 5, 4, 3}},
	{">", "abc", {5, 5, 6, 5, 4}},
	{">", "abcd", {5, 5, 6, 5, 4}},
	{">", "abd", {6, 6, 7, 6, 5}},
	{">", "abe", {6, 6, 7, 6, 5}},
	{">", "b", {7, 7, 8, 7, 6}},
	{">", "ba", {7, 7, 8, 7, 6}},
	{">", "bz", {8, 8, 0, 8, 7}},
	{">", "c", {8, 8, 0, 8, 7}},
	{">", "\xfe", {0, 0, 0, 0, 0}},
	{">", "\xff", {0, 0, 0, 0, 0}},
	{">=", "", {1, 1, 2, 1, 0}},
	{">=", "\x00", {1, 1, 2, 1, 0}},
	{">=", "a", {1, 1, 2, 1, 0}},
	{">=", "aa", {2, 2, 3, 2, 1}},
	{">=", "aaa", {3, 3, 4, 3, 2}},
	{">=", "ab", {3, 3, 4, 3, 2}},
	{">=", "abb", {4, 4, 5, 4, 3}},
	{">=", "abc", {4, 4, 5, 4, 3}},
	{">=", "abcd", {5, 5, 6, 5, 4}},
	{">=", "abd", {5, 5, 6, 5, 4}},
	{">=", "abe", {6, 6, 7, 6, 5}},
	{">=", "b", {6, 6, 7, 6, 5}},
	{">=", "ba", {7, 7, 8, 7, 6}},
	{">=", "bz", {7, 7, 8, 7, 6}},
	{">=", "c", {8, 8, 0, 8, 7}},
	{">=", "\xfe", {8, 8, 0, 8, 7}},
	{">=", "\xff", {0, 0, 0, 0, 0}},
	{"<", "", {0, 0, 0, 0, 0}},
	{"<", "\x00", {0, 0, 0, 0, 0}},
	{"<", "a", {0, 0, 0, 0, 0}},
	{"<", "aa", {1, 1, 2, 1, 0}},
	{"<", "aaa", {2, 2, 3, 2, 1}},
	{"<", "ab", {2, 2, 3, 2, 1}},
	{"<", "abb", {3, 3, 4, 3, 2}},
	{"<", "abc", {3, 3, 4, 3, 2}},
	{"<", "abcd", {4, 4, 5, 4, 3}},
	{"<", "abd", {4, 4, 5, 4, 3}},
	{"<", "abe", {5, 5, 6, 5, 4}},
	{"<", "b", {5, 5, 6, 5, 4}},
	{"<", "ba", {6, 6, 7, 6, 5}},
	{"<", "bz", {6, 6, 7, 6, 5}},
	{"<", "c", {7, 7, 8, 7, 6}},
	{"<", "\xfe", {7, 7, 8, 7, 6}},
	{"<", "\xff", {8, 8, 0, 8, 7}},
	{"<=", "", {0, 0, 0, 0, 0}},
	{"<=", "\x00", {0, 0, 0, 0, 0}},
	{"<=", "a", {1, 1, 2, 1, 0}},
	{"<=", "aa", {2, 2, 3, 2, 1}},
	{"<=", "aaa", {2, 2, 3, 2, 1}},
	{"<=", "ab", {3, 3, 4, 3, 2}},
	{"<=", "abb", {3, 3, 4, 3, 2}},
	{"<=", "abc", {4, 4, 5, 4, 3}},
	{"<=", "abcd", {4, 4, 5, 4, 3}},
	{"<=", "abd", {5, 5, 6, 5, 4}},
	{"<=", "abe", {5, 5, 6, 5, 4}},
	{"<=", "b", {6, 6, 7, 6, 5}},
	{"<=", "ba", {6, 6, 7, 6, 5}},
	{"<=", "bz", {7, 7, 8, 7, 6}},
	{"<=", "c", {7, 7, 8, 7, 6}},
	{"<=", "\xfe", {8, 8, 0, 8, 7}},
	{"<=", "\xff", {8, 8, 0, 8, 7}},
	{"^", "", {1, 1, 2, 1, 0}},
	{"$", "", {8, 8, 0, 8, 7}},
}

@(private = "file")
state_of :: proc(it: ^rx.Iterator) -> uintptr {
	if rx.eof(it) {
		return 0
	}
	return uintptr(it.data)
}

@(private = "file")
seek_table_tree :: proc() -> ^rx.Rax {
	r := rx.create()
	keys := [?]string{"a", "aa", "ab", "abc", "abd", "b", "bz", "\xfe"}
	for k, i in keys {
		rx.insert(r, bytes_of(k), rawptr(uintptr(i + 1)))
	}
	return r
}

@(test)
seek_operators_match_expected_table :: proc(t: ^testing.T) {
	r := seek_table_tree()
	defer rx.destroy(r)
	it: rx.Iterator
	rx.start(&it, r)
	defer rx.stop(&it)
	table := SEEK_TABLE
	for row in table {
		got: [5]uintptr
		testing.expect(t, rx.seek(&it, row.op, bytes_of(row.key)))
		got[0] = state_of(&it)
		ok1 := rx.next(&it)
		got[1] = state_of(&it)
		ok2 := rx.next(&it)
		got[2] = state_of(&it)
		testing.expect(t, ok1 == (got[1] != 0) && ok2 == (got[2] != 0))
		testing.expect(t, rx.seek(&it, row.op, bytes_of(row.key)))
		ok3 := rx.prev(&it)
		got[3] = state_of(&it)
		ok4 := rx.prev(&it)
		got[4] = state_of(&it)
		testing.expect(t, ok3 == (got[3] != 0) && ok4 == (got[4] != 0))
		testing.expectf(t, got == row.states, "seek %s %q: got %v want %v", row.op, row.key, got, row.states)
	}
}

@(test)
iterator_state_machine :: proc(t: ^testing.T) {
	r := rx.create()
	defer rx.destroy(r)
	for k, i in ([?]string{"a", "b", "c", "d"}) {
		rx.insert(r, bytes_of(k), rawptr(uintptr(i + 1)))
	}
	fresh: rx.Iterator
	testing.expect(t, rx.eof(&fresh))
	testing.expect(t, !rx.next(&fresh))
	testing.expect(t, !rx.prev(&fresh))
	it: rx.Iterator
	rx.start(&it, r)
	defer rx.stop(&it)
	testing.expect(t, rx.eof(&it))
	testing.expect(t, !rx.next(&it))
	testing.expect(t, rx.eof(&it))
	at :: proc(
		t: ^testing.T,
		it: ^rx.Iterator,
		ok: bool,
		want_ok: bool,
		want: string,
		want_data: uintptr,
		loc := #caller_location,
	) {
		testing.expect_value(t, ok, want_ok, loc)
		if want_ok {
			testing.expect(t, !rx.eof(it), "positioned", loc = loc)
			testing.expect_value(t, string(rx.key(it)), want, loc)
			testing.expect_value(t, uintptr(it.data), want_data, loc)
		} else {
			testing.expect(t, rx.eof(it), "eof", loc = loc)
		}
	}
	at(t, &it, rx.seek(&it, ">=", bytes_of("b")), true, "b", 2)
	at(t, &it, rx.next(&it), true, "b", 2)
	at(t, &it, rx.next(&it), true, "c", 3)
	at(t, &it, rx.prev(&it), true, "b", 2)
	at(t, &it, rx.prev(&it), true, "a", 1)
	at(t, &it, rx.next(&it), true, "b", 2)
	at(t, &it, rx.next(&it), true, "c", 3)
	at(t, &it, rx.next(&it), true, "d", 4)
	at(t, &it, rx.next(&it), false, "", 0)
	at(t, &it, rx.prev(&it), false, "", 0)
	at(t, &it, rx.prev(&it), false, "", 0)
	at(t, &it, rx.seek(&it, "^"), true, "a", 1)
	at(t, &it, rx.prev(&it), true, "a", 1)
	at(t, &it, rx.prev(&it), false, "", 0)
	at(t, &it, rx.next(&it), false, "", 0)
	at(t, &it, rx.seek(&it, "$"), true, "d", 4)
	at(t, &it, rx.prev(&it), true, "d", 4)
	at(t, &it, rx.next(&it), false, "", 0)
	at(t, &it, rx.next(&it), false, "", 0)
	at(t, &it, rx.seek(&it, "=", bytes_of("c")), true, "c", 3)
	at(t, &it, rx.prev(&it), true, "c", 3)
	at(t, &it, rx.prev(&it), true, "b", 2)
	testing.expect(t, rx.seek(&it, "=", bytes_of("zz")))
	testing.expect(t, rx.eof(&it))
	testing.expect(t, !rx.next(&it))
	at(t, &it, rx.seek(&it, "<", bytes_of("zz")), true, "d", 4)
	testing.expect(t, !rx.seek(&it, "!", bytes_of("a")))
	testing.expect(t, rx.eof(&it))
	at(t, &it, rx.seek(&it, ">=", nil), true, "a", 1)
	testing.expect(t, rx.seek(&it, "<", nil))
	testing.expect(t, rx.eof(&it))
	idle: rx.Iterator
	rx.start(&idle, r)
	rx.stop(&idle)
	rx.stop(&idle)
}

@(test)
remove_current_then_seek_successor :: proc(t: ^testing.T) {
	r := rx.create()
	defer rx.destroy(r)
	for i in 1 ..= 10 {
		k := id_key(u64(i), 0)
		rx.insert(r, k[:], rawptr(uintptr(i)))
	}
	it: rx.Iterator
	rx.start(&it, r)
	defer rx.stop(&it)
	rx.seek(&it, "^")
	yielded: [dynamic]uintptr
	defer delete(yielded)
	reseeks: [dynamic]uintptr
	defer delete(reseeks)
	for rx.next(&it) {
		v := uintptr(it.data)
		append(&yielded, v)
		if v == 3 || v == 7 || v == 10 {
			cur := rx.key(&it)
			testing.expect(t, rx.remove(r, cur))
			rx.seek(&it, ">=", rx.key(&it))
			append(&reseeks, state_of(&it))
		}
	}
	testing.expect_value(t, len(yielded), 10)
	for v, i in yielded {
		testing.expect_value(t, v, uintptr(i + 1))
	}
	testing.expect_value(t, len(reseeks), 3)
	testing.expect(t, reseeks[0] == 4 && reseeks[1] == 8 && reseeks[2] == 0)
	testing.expect_value(t, r.numele, u64(7))
	ref: Reference
	defer ref_destroy(&ref)
	for i in ([?]u64{1, 2, 4, 5, 6, 8, 9}) {
		k := id_key(i, 0)
		ref_insert(&ref, string(k[:]), uintptr(i))
	}
	check_walks(t, r, &ref, "after trim walk")
}

@(test)
remove_reseek_pattern_large :: proc(t: ^testing.T) {
	state := seeded(11)
	context.random_generator = rand.default_random_generator(&state)
	for long in ([?]bool{false, true}) {
		r := rx.create()
		ref: Reference
		base := strings.repeat("p", 300)
		for i in 0 ..< 20_000 {
			k := id_key(1_000 + u64(i) * 3, u64(i % 2))
			key := string(k[:])
			if long {
				key = strings.concatenate({base, key}, context.temp_allocator)
			}
			rx.insert(r, bytes_of(key), rawptr(uintptr(i + 1)))
			ref_insert(&ref, key, uintptr(i + 1))
		}
		it: rx.Iterator
		rx.start(&it, r)
		rx.seek(&it, "^")
		count := 0
		removed := 0
		for rx.next(&it) {
			count += 1
			if rand.int_max(3) == 0 {
				key := strings.clone(string(rx.key(&it)), context.temp_allocator)
				ok, _ := ref_remove(&ref, key)
				testing.expect(t, ok)
				testing.expect(t, rx.remove(r, rx.key(&it)))
				removed += 1
				rx.seek(&it, ">=", rx.key(&it))
				idx, _ := ref_lower(&ref, key)
				if idx >= len(ref.items) {
					testing.expect(t, rx.eof(&it))
				} else {
					testing.expect_value(t, string(rx.key(&it)), ref.items[idx].key)
				}
			}
		}
		testing.expect_value(t, count, 20_000)
		testing.expect_value(t, r.numele, u64(20_000 - removed))
		rx.stop(&it)
		check_walks(t, r, &ref, "after random trims")
		rx.destroy(r)
		ref_destroy(&ref)
		delete(base)
		free_all(context.temp_allocator)
	}
}

@(test)
overwrite_while_positioned :: proc(t: ^testing.T) {
	r := rx.create()
	defer rx.destroy(r)
	for i in 1 ..= 5 {
		k := id_key(u64(i), 0)
		rx.insert(r, k[:], rawptr(uintptr(i)))
	}
	it: rx.Iterator
	rx.start(&it, r)
	defer rx.stop(&it)
	rx.seek(&it, "^")
	seen: [dynamic]uintptr
	defer delete(seen)
	for rx.next(&it) {
		v := uintptr(it.data)
		append(&seen, v)
		if v == 2 || v == 4 {
			before := strings.clone(string(rx.key(&it)), context.temp_allocator)
			testing.expect(t, !rx.insert(r, rx.key(&it), rawptr(v * 100)))
			testing.expect_value(t, string(rx.key(&it)), before)
		}
	}
	testing.expect_value(t, len(seen), 5)
	for v, i in seen {
		testing.expect_value(t, v, uintptr(i + 1))
	}
	ref: Reference
	defer ref_destroy(&ref)
	for i in 1 ..= 5 {
		k := id_key(u64(i), 0)
		v := uintptr(i)
		if i == 2 || i == 4 {
			v *= 100
		}
		ref_insert(&ref, string(k[:]), v)
	}
	check_walks(t, r, &ref, "after overwrites")
	big := rx.create()
	defer rx.destroy(big)
	for i in 0 ..< 30_000 {
		k := id_key(u64(i), 0)
		rx.insert(big, k[:], rawptr(uintptr(i)))
	}
	rx.seek(&it, "^")
	rx.stop(&it)
	rx.start(&it, big)
	rx.seek(&it, "^")
	n := 0
	for rx.next(&it) {
		testing.expect(t, !rx.insert(big, rx.key(&it), rawptr(uintptr(n + 1_000_000))))
		n += 1
	}
	testing.expect_value(t, n, 30_000)
	zero := id_key(0, 0)
	v, found := rx.find(big, zero[:])
	testing.expect(t, found && uintptr(v) == 1_000_000)
}

@(test)
concurrent_iterators_on_one_tree :: proc(t: ^testing.T) {
	r := rx.create()
	defer rx.destroy(r)
	for i in 0 ..< 10_000 {
		k := id_key(u64(i), 0)
		rx.insert(r, k[:], rawptr(uintptr(i + 1)))
	}
	a, b: rx.Iterator
	rx.start(&a, r)
	rx.start(&b, r)
	defer rx.stop(&a)
	defer rx.stop(&b)
	rx.seek(&a, "^")
	rx.seek(&b, "$")
	for i in 0 ..< 10_000 {
		testing.expect(t, rx.next(&a))
		testing.expect(t, rx.prev(&b))
		if uintptr(a.data) != uintptr(i + 1) || uintptr(b.data) != uintptr(10_000 - i) {
			testing.expectf(t, false, "interleaved walk diverged at %d", i)
			return
		}
	}
	testing.expect(t, !rx.next(&a) && !rx.prev(&b))
}

@(test)
iterator_keys_feed_another_tree :: proc(t: ^testing.T) {
	state := seeded(5)
	context.random_generator = rand.default_random_generator(&state)
	src: Key_Source
	defer key_source_destroy(&src)
	a := rx.create()
	b := rx.create()
	defer rx.destroy(a)
	defer rx.destroy(b)
	ref: Reference
	defer ref_destroy(&ref)
	kinds := [?]Key_Kind{.Tiny, .Name, .Id_Random, .Long}
	for i in 0 ..< 3000 {
		k := gen_key(&src, kinds[i % len(kinds)])
		rx.insert(a, bytes_of(k), rawptr(uintptr(i)))
		ref_insert(&ref, k, uintptr(i))
	}
	free_all(context.temp_allocator)
	it: rx.Iterator
	rx.start(&it, a)
	defer rx.stop(&it)
	rx.seek(&it, "^")
	for rx.next(&it) {
		testing.expect(t, rx.insert(b, rx.key(&it), it.data))
	}
	check_walks(t, b, &ref, "copied tree")
}

@(test)
mutation_while_positioned_stays_consistent :: proc(t: ^testing.T) {
	state := seeded(7)
	context.random_generator = rand.default_random_generator(&state)
	src: Key_Source
	defer key_source_destroy(&src)
	for kind in ([?]Key_Kind{.Tiny, .Id_Random, .Name}) {
		r := rx.create()
		ref: Reference
		for i in 0 ..< 4000 {
			k := gen_key(&src, kind)
			rx.insert(r, bytes_of(k), rawptr(uintptr(i)))
			ref_insert(&ref, k, uintptr(i))
		}
		it: rx.Iterator
		rx.start(&it, r)
		rx.seek(&it, "^")
		rx.next(&it)
		for round in 0 ..< 3000 {
			if rx.eof(&it) {
				rx.seek(&it, "^")
				rx.next(&it)
				if rx.eof(&it) {
					break
				}
			}
			cur := strings.clone(string(rx.key(&it)), context.temp_allocator)
			for _ in 0 ..< 1 + rand.int_max(3) {
				k := gen_key(&src, kind)
				if k == cur {
					continue
				}
				if rand.int_max(2) == 0 {
					rx.insert(r, bytes_of(k), rawptr(uintptr(round)))
					ref_insert(&ref, k, uintptr(round))
				} else {
					rx.remove(r, bytes_of(k))
					ref_remove(&ref, k)
				}
			}
			forward := rand.int_max(2) == 0
			ok := rx.next(&it) if forward else rx.prev(&it)
			idx, exact := ref_lower(&ref, cur)
			want := -1
			if forward {
				want = idx + 1 if exact else idx
			} else {
				want = idx - 1
			}
			if want < 0 || want >= len(ref.items) {
				testing.expect(t, !ok && rx.eof(&it))
			} else if !ok || string(rx.key(&it)) != ref.items[want].key {
				testing.expectf(t, false, "step after mutation went to %s want %s", quote(string(rx.key(&it))), quote(ref.items[want].key))
				break
			}
		}
		rx.stop(&it)
		testing.expect_value(t, r.numele, u64(len(ref.items)))
		check_walks(t, r, &ref, "after mutation walk")
		rx.destroy(r)
		ref_destroy(&ref)
		free_all(context.temp_allocator)
	}
}

@(test)
long_key_iteration_and_aliasing :: proc(t: ^testing.T) {
	r := rx.create()
	defer rx.destroy(r)
	ref: Reference
	defer ref_destroy(&ref)
	base := strings.repeat("k", 70_000)
	defer delete(base)
	lengths := [?]int{0, 1, 127, 128, 129, 300, 4096, 4097, 5000, 65_535, 65_536, 70_000}
	for n, i in lengths {
		rx.insert(r, bytes_of(base[:n]), rawptr(uintptr(i + 1)))
		ref_insert(&ref, base[:n], uintptr(i + 1))
		alt := strings.concatenate({base[:n], "\x00"}, context.temp_allocator)
		rx.insert(r, bytes_of(alt), rawptr(uintptr(100 + i)))
		ref_insert(&ref, alt, uintptr(100 + i))
	}
	check_walks(t, r, &ref, "long chain")
	it: rx.Iterator
	rx.start(&it, r)
	defer rx.stop(&it)
	for n in lengths {
		testing.expect(t, check_seek_walk(t, &it, &ref, ">=", base[:n], 6, "long seek"))
		testing.expect(t, check_seek_walk(t, &it, &ref, "<", base[:n], 6, "long seek"))
	}
	rx.seek(&it, "^")
	for rx.next(&it) {
		cur := strings.clone(string(rx.key(&it)), context.temp_allocator)
		testing.expect(t, rx.remove(r, rx.key(&it)))
		ref_remove(&ref, cur)
		rx.seek(&it, ">=", rx.key(&it))
		idx, _ := ref_lower(&ref, cur)
		if idx < len(ref.items) {
			testing.expect_value(t, string(rx.key(&it)), ref.items[idx].key)
		} else {
			testing.expect(t, rx.eof(&it))
		}
	}
	testing.expect_value(t, r.numele, u64(0))
	free_all(context.temp_allocator)
}

@(test)
seeks_served_from_recent_leaf_walk_across_leaves :: proc(t: ^testing.T) {
	state := seeded(31)
	context.random_generator = rand.default_random_generator(&state)
	r := rx.create()
	defer rx.destroy(r)
	ref: Reference
	defer ref_destroy(&ref)
	for i in 0 ..< 60_000 {
		k := id_key(5_000 + u64(i / 2) * 3, u64(i % 2))
		rx.insert(r, k[:], rawptr(uintptr(i + 1)))
		ref_insert(&ref, string(k[:]), uintptr(i + 1))
	}
	it: rx.Iterator
	rx.start(&it, r)
	defer rx.stop(&it)
	ops := SEEK_OPS
	for round in 0 ..< 3000 {
		i := rand.int_max(len(ref.items))
		anchor := ref.items[i].key
		v, found := rx.find(r, bytes_of(anchor))
		testing.expect(t, found && uintptr(v) == ref.items[i].value)
		probe := anchor
		switch rand.int_max(4) {
		case 1:
			probe = strings.concatenate({anchor, "\x00"}, context.temp_allocator)
		case 2:
			probe = anchor[:15]
		case 3:
			b := transmute([]u8)strings.clone(anchor, context.temp_allocator)
			b[15] = 0x7f
			probe = string(b)
		}
		if !check_seek_walk(t, &it, &ref, ops[rand.int_max(len(ops))], probe, 400, "finger seek") {
			return
		}
		if round % 64 == 0 {
			free_all(context.temp_allocator)
		}
	}
	free_all(context.temp_allocator)
	for round in 0 ..< 200 {
		i := rand.int_max(len(ref.items))
		anchor := strings.clone(ref.items[i].key, context.temp_allocator)
		rx.find(r, bytes_of(anchor))
		rx.seek(&it, ">=", bytes_of(anchor))
		testing.expect(t, rx.next(&it))
		if round % 2 == 0 {
			k := id_key(1, 0)
			rx.insert(r, k[:], nil)
			ref_insert(&ref, string(k[:]), 0)
		} else {
			k := id_key(1, 0)
			rx.remove(r, k[:])
			ref_remove(&ref, string(k[:]))
		}
		idx, _ := ref_lower(&ref, anchor)
		steps := 0
		for rx.next(&it) {
			steps += 1
			idx += 1
			if idx >= len(ref.items) || string(rx.key(&it)) != ref.items[idx].key {
				testing.expectf(t, false, "walk after mutation diverged at step %d", steps)
				return
			}
			if steps == 300 {
				break
			}
		}
	}
	free_all(context.temp_allocator)
}
