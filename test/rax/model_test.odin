package rax_test

import rx "../../src/rax"
import "core:fmt"
import "core:math/rand"
import "core:testing"

@(private = "file")
pick_existing :: proc(ref: ^Reference, src: ^Key_Source, kind: Key_Kind) -> string {
	if len(ref.items) > 0 && rand.int_max(3) > 0 {
		return ref.items[rand.int_max(len(ref.items))].key
	}
	return gen_key(src, kind)
}

@(private = "file")
neighbour_of :: proc(ref: ^Reference, src: ^Key_Source, kind: Key_Kind, last: string) -> string {
	if len(ref.items) == 0 {
		return gen_key(src, kind)
	}
	idx, _ := ref_lower(ref, last)
	idx += rand.int_max(3) - 1
	idx = clamp(idx, 0, len(ref.items) - 1)
	return ref.items[idx].key
}

model_run :: proc(t: ^testing.T, seed: u64, kinds: []Key_Kind, ops: int, check_every: int) -> bool {
	state := seeded(seed)
	context.random_generator = rand.default_random_generator(&state)
	src: Key_Source
	defer key_source_destroy(&src)
	shared := 1 << 40
	r := rx.create(&shared)
	baseline := rx.memory(r)
	ref: Reference
	defer ref_destroy(&ref)
	it: rx.Iterator
	rx.start(&it, r)
	last_buf: [dynamic]u8
	defer delete(last_buf)
	last := ""
	ok := true
	for step in 0 ..< ops {
		kind := kinds[rand.int_max(len(kinds))]
		grow := step < ops / 2
		action := rand.int_max(20)
		key: string
		if rand.int_max(4) == 0 {
			key = neighbour_of(&ref, &src, kind, last)
		} else if action < 8 && grow {
			key = gen_key(&src, kind)
		} else {
			key = pick_existing(&ref, &src, kind)
		}
		key = fmt.tprintf("%s", key)
		value := uintptr(1 + rand.int_max(1 << 30))
		if rand.int_max(12) == 0 {
			value = 0
		}
		where_ := fmt.tprintf("seed %d step %d", seed, step)
		insert_cut := 10 if grow else 4
		switch {
		case action < insert_cut:
			old := rawptr(uintptr(0xdead))
			_, had := ref_find(&ref, key)
			res := rx.insert(r, bytes_of(key), rawptr(value), &old)
			was_new, prev := ref_insert(&ref, key, value)
			if res != was_new || (had && uintptr(old) != prev) {
				testing.expectf(t, false, "%s: insert %s returned %v old %x", where_, quote(key), res, uintptr(old))
				ok = false
			}
		case action < insert_cut + 2:
			old := rawptr(uintptr(0xdead))
			prev, had := ref_find(&ref, key)
			res := rx.try_insert(r, bytes_of(key), rawptr(value), &old)
			if had {
				if res || uintptr(old) != prev {
					testing.expectf(t, false, "%s: try_insert on existing %s", where_, quote(key))
					ok = false
				}
			} else {
				if !res || uintptr(old) != 0xdead {
					testing.expectf(t, false, "%s: try_insert on new %s", where_, quote(key))
					ok = false
				}
				ref_insert(&ref, key, value)
			}
		case action < 17:
			old := rawptr(uintptr(0xdead))
			res := rx.remove(r, bytes_of(key), &old)
			had, prev := ref_remove(&ref, key)
			if res != had || (had && uintptr(old) != prev) || (!had && uintptr(old) != 0xdead) {
				testing.expectf(t, false, "%s: remove %s returned %v", where_, quote(key), res)
				ok = false
			}
		case:
			v, found := rx.find(r, bytes_of(key))
			want, had := ref_find(&ref, key)
			if found != had || (had && uintptr(v) != want) {
				testing.expectf(t, false, "%s: find %s", where_, quote(key))
				ok = false
			}
		}
		clear(&last_buf)
		append(&last_buf, ..bytes_of(key))
		last = string(last_buf[:])
		if r.stored != u64(len(ref.items)) {
			testing.expectf(t, false, "%s: stored %d want %d", where_, r.stored, len(ref.items))
			ok = false
		}
		if shared - (1 << 40) != rx.memory(r) || rx.memory(r) < baseline {
			testing.expectf(t, false, "%s: shared counter drifted", where_)
			ok = false
		}
		if ok && (step % check_every == 0 || step == ops - 1) {
			ok = check_walks(t, r, &ref, where_)
			for _ in 0 ..< 12 {
				if !ok {
					break
				}
				op_table := SEEK_OPS
				op := op_table[rand.int_max(len(op_table))]
				probe := pick_existing(&ref, &src, kind)
				if rand.int_max(4) == 0 {
					probe = fmt.tprintf("%s\x00", probe)
				} else if rand.int_max(4) == 0 && len(probe) > 0 {
					probe = probe[:len(probe) - 1]
				}
				ok = check_seek_walk(t, &it, &ref, op, probe, 24, where_)
			}
		}
		if !ok {
			break
		}
		if step % 64 == 0 {
			free_all(context.temp_allocator)
		}
	}
	rx.stop(&it)
	for len(ref.items) > 0 && ok {
		e := ref.items[rand.int_max(len(ref.items))]
		k := fmt.tprintf("%s", e.key)
		if !rx.remove(r, bytes_of(k)) {
			testing.expectf(t, false, "seed %d: final remove failed", seed)
			ok = false
		}
		ref_remove(&ref, k)
	}
	if ok {
		testing.expect_value(t, r.stored, u64(0))
		testing.expect_value(t, rx.memory(r), baseline)
	}
	rx.destroy(r)
	testing.expect_value(t, shared, 1 << 40)
	free_all(context.temp_allocator)
	return ok
}

@(test)
model_tiny_alphabet_prefix_chains :: proc(t: ^testing.T) {
	kinds := [?]Key_Kind{.Tiny}
	for seed in 1 ..= 6 {
		if !model_run(t, u64(seed), kinds[:], 6000, 150) {
			return
		}
	}
}

@(test)
model_stream_ids :: proc(t: ^testing.T) {
	random := [?]Key_Kind{.Id_Random}
	sequential := [?]Key_Kind{.Id_Sequential}
	both := [?]Key_Kind{.Id_Random, .Id_Sequential}
	for seed in 1 ..= 3 {
		if !model_run(t, u64(100 + seed), random[:], 12_000, 400) {
			return
		}
		if !model_run(t, u64(200 + seed), sequential[:], 12_000, 400) {
			return
		}
		if !model_run(t, u64(300 + seed), both[:], 12_000, 400) {
			return
		}
	}
}

@(test)
model_names :: proc(t: ^testing.T) {
	kinds := [?]Key_Kind{.Name}
	for seed in 1 ..= 4 {
		if !model_run(t, u64(400 + seed), kinds[:], 10_000, 400) {
			return
		}
	}
}

@(test)
model_long_keys :: proc(t: ^testing.T) {
	long := [?]Key_Kind{.Long}
	chain := [?]Key_Kind{.Long_Chain, .Long}
	for seed in 1 ..= 2 {
		if !model_run(t, u64(500 + seed), long[:], 1500, 100) {
			return
		}
		if !model_run(t, u64(600 + seed), chain[:], 1500, 100) {
			return
		}
	}
}

@(test)
model_pattern_width_boundaries :: proc(t: ^testing.T) {
	w63 := [?]Key_Kind{.Width_63}
	w64 := [?]Key_Kind{.Width_64}
	w65 := [?]Key_Kind{.Width_65}
	all := [?]Key_Kind{.Width_63, .Width_64, .Width_65, .Id_Random}
	for seed in 1 ..= 2 {
		if !model_run(t, u64(800 + seed), w63[:], 6000, 300) {
			return
		}
		if !model_run(t, u64(810 + seed), w64[:], 6000, 300) {
			return
		}
		if !model_run(t, u64(820 + seed), w65[:], 6000, 300) {
			return
		}
		if !model_run(t, u64(830 + seed), all[:], 6000, 300) {
			return
		}
	}
}

@(test)
model_mixed_shapes :: proc(t: ^testing.T) {
	kinds := [?]Key_Kind{.Tiny, .Id_Random, .Id_Sequential, .Name, .Long, .Long_Chain, .Width_64, .Width_65}
	for seed in 1 ..= 4 {
		if !model_run(t, u64(700 + seed), kinds[:], 8000, 300) {
			return
		}
	}
}
