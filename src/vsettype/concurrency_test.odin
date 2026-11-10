package vsettype

import "base:intrinsics"
import "core:fmt"
import "core:slice"
import "core:testing"
import "core:thread"

Worker_State :: struct {
	seed:  u64,
	gate:  ^u32,
	uids:  [dynamic]u64,
	fails: int,
}

worker_run :: proc(data: rawptr) {
	w := (^Worker_State)(data)
	for intrinsics.atomic_load_explicit(w.gate, .Acquire) == 0 {
		thread.yield()
	}
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = w.seed}
	x := make([]f32, 8)
	defer delete(x)
	for round in 0 ..< 12 {
		s, err := create(Params{quant = Quant(round % 3), dim = 8, m = 8})
		if err != .None {
			w.fails += 1
			continue
		}
		append(&w.uids, s.uid)
		for i in 0 ..< 60 {
			random_vector(&r, x)
			req := Add_Request{name = transmute([]u8)fmt.tprintf("w%d", i % 40), vector = x, quant = Quant(round % 3), m = 8}
			if _, f := add(s, &req, &sc); f.err != .None {
				w.fails += 1
			}
		}
		hits: [dynamic]Hit
		q := Search_Request{kind = .Vector, vector = x, count = 5}
		if search(s, &q, &sc, &hits).err != .None || len(hits) != 5 {
			w.fails += 1
		}
		delete(hits)
		random_member(s)
		blob, _ := serialize_bytes(s)
		back, derr := deserialize(blob, &sc)
		if derr != .None || card(back) != card(s) {
			w.fails += 1
		} else {
			append(&w.uids, back.uid)
		}
		delete(blob)
		destroy(back)
		destroy(s)
		free_all(context.temp_allocator)
	}
}

@(test)
independent_sets_on_worker_threads_share_only_atomic_counters :: proc(t: ^testing.T) {
	gate: u32
	states: [4]Worker_State
	workers: [4]^thread.Thread
	for &st, i in states {
		st.seed = u64(0x7000 + i)
		st.gate = &gate
		workers[i] = thread.create_and_start_with_data(&st, worker_run)
	}
	intrinsics.atomic_store_explicit(&gate, 1, .Release)
	all: [dynamic]u64
	defer delete(all)
	for w, i in workers {
		thread.join(w)
		thread.destroy(w)
		testing.expect_value(t, states[i].fails, 0)
		append(&all, ..states[i].uids[:])
		delete(states[i].uids)
	}
	slice.sort(all[:])
	for i in 1 ..< len(all) {
		testing.expect(t, all[i] != all[i - 1])
	}
	testing.expect_value(t, len(all), 4 * 24)
}
