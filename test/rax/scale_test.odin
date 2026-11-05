package rax_test

import rx "../../src/rax"
import "core:math/rand"
import "core:strings"
import "core:testing"

@(test)
million_sequential_ids :: proc(t: ^testing.T) {
	N :: 1_000_000
	state := seeded(21)
	context.random_generator = rand.default_random_generator(&state)
	shared := 0
	r := rx.create(&shared)
	baseline := rx.memory(r)
	for i in 0 ..< N {
		k := id_key(1_700_000_000_000 + u64(i / 3), u64(i % 3))
		if !rx.insert(r, k[:], rawptr(uintptr(i + 1))) {
			testing.expectf(t, false, "insert %d reported existing", i)
			return
		}
	}
	testing.expect_value(t, r.stored, u64(N))
	per_key := f64(rx.memory(r)) / f64(N)
	testing.expectf(t, per_key < 30, "bytes per key %.1f", per_key)
	testing.expect_value(t, shared, rx.memory(r))
	for i in 0 ..< N {
		k := id_key(1_700_000_000_000 + u64(i / 3), u64(i % 3))
		v, found := rx.find(r, k[:])
		if !found || uintptr(v) != uintptr(i + 1) {
			testing.expectf(t, false, "find %d failed", i)
			return
		}
	}
	it: rx.Iterator
	rx.start(&it, r)
	defer rx.stop(&it)
	rx.seek(&it, "^")
	n := 0
	for rx.next(&it) {
		if uintptr(it.data) != uintptr(n + 1) {
			testing.expectf(t, false, "forward order broken at %d", n)
			return
		}
		n += 1
	}
	testing.expect_value(t, n, N)
	rx.seek(&it, "$")
	n = N
	for rx.prev(&it) {
		if uintptr(it.data) != uintptr(n) {
			testing.expectf(t, false, "reverse order broken at %d", n)
			return
		}
		n -= 1
	}
	testing.expect_value(t, n, 0)
	for _ in 0 ..< 20_000 {
		i := rand.int_max(N)
		k := id_key(1_700_000_000_000 + u64(i / 3), u64(i % 3))
		rx.seek(&it, ">=", k[:])
		if rx.eof(&it) || uintptr(it.data) != uintptr(i + 1) {
			testing.expectf(t, false, "seek >= %d", i)
			return
		}
		rx.next(&it)
		ok := rx.next(&it)
		testing.expect(t, ok == (i + 1 < N))
		gap := id_key(1_700_000_000_000 + u64(i / 3), u64(i % 3) * 100 + 7)
		rx.seek(&it, "<", gap[:])
		want := min(3 * (i / 3) + 3, N)
		if rx.eof(&it) || uintptr(it.data) != uintptr(want) {
			testing.expectf(t, false, "seek < gap after %d", i)
			return
		}
	}
	for i in 0 ..< N / 2 {
		k := id_key(1_700_000_000_000 + u64(i / 3), u64(i % 3))
		testing.expect(t, rx.remove(r, k[:]))
		rx.seek(&it, ">=", k[:])
		if rx.eof(&it) || uintptr(it.data) != uintptr(i + 2) {
			testing.expectf(t, false, "trim reseek after %d", i)
			return
		}
	}
	for i := N - 1; i >= N / 2; i -= 1 {
		k := id_key(1_700_000_000_000 + u64(i / 3), u64(i % 3))
		if !rx.remove(r, k[:]) {
			testing.expectf(t, false, "reverse remove %d", i)
			return
		}
	}
	testing.expect_value(t, r.stored, u64(0))
	testing.expect_value(t, rx.memory(r), baseline)
	rx.destroy(r)
	testing.expect_value(t, shared, 0)
}

@(test)
random_ids_bulk :: proc(t: ^testing.T) {
	N :: 300_000
	state := seeded(22)
	context.random_generator = rand.default_random_generator(&state)
	r := rx.create()
	baseline := rx.memory(r)
	keys := make([][16]u8, N)
	defer delete(keys)
	for i in 0 ..< N {
		keys[i] = id_key(1_700_000_000_000 + rand.uint64() % 50_000_000_000, rand.uint64() % 4)
	}
	inserted := 0
	for i in 0 ..< N {
		if rx.insert(r, keys[i][:], rawptr(uintptr(i + 1))) {
			inserted += 1
		}
	}
	testing.expect_value(t, r.stored, u64(inserted))
	per_key := f64(rx.memory(r)) / f64(r.stored)
	testing.expectf(t, per_key < 45, "bytes per random key %.1f", per_key)
	order := make([]int, N)
	defer delete(order)
	for i in 0 ..< N {
		order[i] = i
	}
	rand.shuffle(order)
	for i in order {
		_, found := rx.find(r, keys[i][:])
		if !found {
			testing.expectf(t, false, "random find %d", i)
			return
		}
	}
	it: rx.Iterator
	rx.start(&it, r)
	defer rx.stop(&it)
	rx.seek(&it, "^")
	prev_key: [16]u8
	n := 0
	for rx.next(&it) {
		k := rx.key(&it)
		if n > 0 && key_compare(string(k), string(prev_key[:])) <= 0 {
			testing.expectf(t, false, "iteration out of order at %d", n)
			return
		}
		copy(prev_key[:], k)
		n += 1
	}
	testing.expect_value(t, n, inserted)
	removed := 0
	for i in order {
		if rx.remove(r, keys[i][:]) {
			removed += 1
		}
	}
	testing.expect_value(t, removed, inserted)
	testing.expect_value(t, rx.memory(r), baseline)
	rx.destroy(r)
}

@(test)
keys_longer_than_page :: proc(t: ^testing.T) {
	state := seeded(23)
	context.random_generator = rand.default_random_generator(&state)
	r := rx.create()
	baseline := rx.memory(r)
	ref: Reference
	defer ref_destroy(&ref)
	big := strings.repeat("q", 1 << 20)
	defer delete(big)
	lengths := [?]int{4097, 5000, 8191, 8192, 70_000, 1 << 20}
	for n, i in lengths {
		rx.insert(r, bytes_of(big[:n]), rawptr(uintptr(i + 1)))
		ref_insert(&ref, big[:n], uintptr(i + 1))
	}
	for i in 0 ..< 300 {
		n := 4097 + rand.int_max(20_000)
		b := make([]u8, n, context.temp_allocator)
		copy(b, big[:n])
		b[rand.int_max(n)] = u8(rand.int_max(256))
		k := string(b)
		rx.insert(r, b, rawptr(uintptr(1000 + i)))
		ref_insert(&ref, k, uintptr(1000 + i))
	}
	free_all(context.temp_allocator)
	testing.expect_value(t, r.stored, u64(len(ref.items)))
	check_walks(t, r, &ref, "long keys")
	for e in ref.items {
		v, found := rx.find(r, bytes_of(e.key))
		testing.expect(t, found && uintptr(v) == e.value)
	}
	it: rx.Iterator
	rx.start(&it, r)
	defer rx.stop(&it)
	ops := SEEK_OPS
	for _ in 0 ..< 400 {
		e := ref.items[rand.int_max(len(ref.items))]
		probe := e.key
		if rand.int_max(2) == 0 {
			probe = strings.concatenate({e.key, "\x00"}, context.temp_allocator)
		}
		if !check_seek_walk(t, &it, &ref, ops[rand.int_max(len(ops))], probe, 8, "long seek") {
			return
		}
	}
	free_all(context.temp_allocator)
	for len(ref.items) > 0 {
		k := strings.clone(ref.items[rand.int_max(len(ref.items))].key, context.temp_allocator)
		testing.expect(t, rx.remove(r, bytes_of(k)))
		ref_remove(&ref, k)
	}
	free_all(context.temp_allocator)
	testing.expect_value(t, rx.memory(r), baseline)
	rx.destroy(r)
}

@(test)
stream_access_patterns :: proc(t: ^testing.T) {
	state := seeded(24)
	context.random_generator = rand.default_random_generator(&state)
	shared := 0
	r := rx.create(&shared)
	baseline := rx.memory(r)
	head := 0
	tail := 0
	it: rx.Iterator
	rx.start(&it, r)
	defer rx.stop(&it)
	for round in 0 ..< 400 {
		adds := 1 + rand.int_max(400)
		for _ in 0 ..< adds {
			k := id_key(1_000_000 + u64(tail / 2), u64(tail % 2))
			testing.expect(t, rx.insert(r, k[:], rawptr(uintptr(tail + 1))))
			tail += 1
		}
		last := id_key(1_000_000 + u64((tail - 1) / 2), u64((tail - 1) % 2))
		rx.seek(&it, ">", last[:])
		testing.expect(t, rx.eof(&it))
		rx.seek(&it, "$")
		testing.expect(t, !rx.eof(&it) && uintptr(it.data) == uintptr(tail))
		if tail - head > 3 {
			start := head + rand.int_max(tail - head - 2)
			sk := id_key(1_000_000 + u64(start / 2), u64(start % 2))
			rx.seek(&it, ">=", sk[:])
			for j in 0 ..< 3 {
				if !rx.next(&it) || uintptr(it.data) != uintptr(start + j + 1) {
					testing.expectf(t, false, "range read round %d", round)
					return
				}
			}
		}
		for j in head ..< min(head + 50, tail) {
			k := id_key(1_000_000 + u64(j / 2), u64(j % 2))
			v, found := rx.find(r, k[:])
			if !found || uintptr(v) != uintptr(j + 1) {
				testing.expectf(t, false, "in-order find %d", j)
				return
			}
		}
		trims := rand.int_max(min(300, tail - head) + 1)
		rx.seek(&it, "^")
		for _ in 0 ..< trims {
			if !rx.next(&it) || uintptr(it.data) != uintptr(head + 1) {
				testing.expectf(t, false, "trim walk round %d", round)
				return
			}
			testing.expect(t, rx.remove(r, rx.key(&it)))
			head += 1
			rx.seek(&it, ">=", rx.key(&it))
		}
		testing.expect_value(t, r.stored, u64(tail - head))
		testing.expect_value(t, shared, rx.memory(r))
	}
	for tail > head {
		tail -= 1
		k := id_key(1_000_000 + u64(tail / 2), u64(tail % 2))
		if !rx.remove(r, k[:]) {
			testing.expectf(t, false, "tail remove %d", tail)
			return
		}
	}
	testing.expect_value(t, rx.memory(r), baseline)
	rx.destroy(r)
	testing.expect_value(t, shared, 0)
}

@(test)
every_small_size_round_trips :: proc(t: ^testing.T) {
	state := seeded(25)
	context.random_generator = rand.default_random_generator(&state)
	src: Key_Source
	defer key_source_destroy(&src)
	kinds := [?]Key_Kind{.Tiny, .Id_Random, .Name}
	for kind in kinds {
		for size in 0 ..< 160 {
			r := rx.create()
			baseline := rx.memory(r)
			ref: Reference
			for len(ref.items) < size {
				k := gen_key(&src, kind)
				v := uintptr(len(ref.items) + 1)
				rx.insert(r, bytes_of(k), rawptr(v))
				ref_insert(&ref, k, v)
			}
			if !check_walks(t, r, &ref, "small size") {
				rx.destroy(r)
				ref_destroy(&ref)
				return
			}
			for len(ref.items) > 0 {
				k := strings.clone(ref.items[len(ref.items) / 2].key, context.temp_allocator)
				testing.expect(t, rx.remove(r, bytes_of(k)))
				ref_remove(&ref, k)
			}
			testing.expect_value(t, rx.memory(r), baseline)
			rx.destroy(r)
			ref_destroy(&ref)
			free_all(context.temp_allocator)
		}
	}
}
