package label

import "base:runtime"
import "core:log"
import "core:os"
import "core:testing"
import "core:time"
import hn "../hnsw"

BENCH_ENV :: "ESKI_LABEL_BENCH"

BENCH_SLOTS :: 1 << 20

BENCH_ROUNDS :: 20

bench_table :: proc(tb: ^Table, r: ^Rng, n: int) {
	table_init(tb)
	for table_count(tb) < n {
		l := random_label(r, 4, 16, 6)
		l.compartments[1] = u64(table_count(tb))
		table_intern(tb, l)
	}
}

bench_checks :: proc(accept: hn.Accept_Proc, ctx: rawptr, order: []u32) -> (hits: int, per_check: f64) {
	start := time.tick_now()
	for _ in 0 ..< BENCH_ROUNDS {
		for slot in order {
			if accept(ctx, slot) {
				hits += 1
			}
		}
	}
	elapsed := time.duration_nanoseconds(time.tick_since(start))
	return hits, f64(elapsed) / f64(BENCH_ROUNDS * len(order))
}

Direct :: struct {
	reader: Label,
	table:  ^Table,
	labels: []Id,
}

direct_accept :: proc(ctx: rawptr, slot: u32) -> bool {
	d := (^Direct)(ctx)
	if int(slot) >= len(d.labels) {
		return false
	}
	return dominates(d.reader, d.table.labels[d.labels[slot]])
}

bench_size :: proc(t: ^testing.T, n: int) {
	r := Rng{0xBE7C_0000 + u64(n)}
	tb: Table
	bench_table(&tb, &r, n)
	defer table_destroy(&tb)
	reader := Label{level = 2, compartments = {0x0FFF, max(u64), 0, 0}}
	builds :: 200
	v: Visibility
	start := time.tick_now()
	for _ in 0 ..< builds {
		visibility_destroy(&v)
		visibility_build(&v, &tb, reader)
	}
	build := f64(time.duration_nanoseconds(time.tick_since(start))) / builds
	defer visibility_destroy(&v)
	refreshes :: 100_000
	last := n - 1
	start = time.tick_now()
	for _ in 0 ..< refreshes {
		v.built = last
		v.words[last >> 6] &~= u64(1) << uint(last & 63)
		visibility_refresh(&v, &tb)
	}
	incremental := f64(time.duration_nanoseconds(time.tick_since(start))) / refreshes
	batch := min(64, n - 1)
	start = time.tick_now()
	for _ in 0 ..< refreshes / 10 {
		v.built = n - batch
		for i in n - batch ..< n {
			v.words[i >> 6] &~= u64(1) << uint(i & 63)
		}
		visibility_refresh(&v, &tb)
	}
	batched := f64(time.duration_nanoseconds(time.tick_since(start))) / (refreshes / 10)
	labels := make([]Id, BENCH_SLOTS)
	defer delete(labels)
	for &id in labels {
		id = Id(rng_below(&r, n))
	}
	sequential := make([]u32, BENCH_SLOTS)
	defer delete(sequential)
	shuffled := make([]u32, BENCH_SLOTS)
	defer delete(shuffled)
	for i in 0 ..< BENCH_SLOTS {
		sequential[i] = u32(i)
		shuffled[i] = u32(i)
	}
	for i := BENCH_SLOTS - 1; i > 0; i -= 1 {
		j := rng_below(&r, i + 1)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	}
	g := gate_make(&v, labels)
	fg := filter_gate_make(g, nil, nil, nil)
	d := Direct{reader, &tb, labels}
	hits_seq, gate_seq := bench_checks(gate_accept, &g, sequential)
	hits_rand, gate_rand := bench_checks(gate_accept, &g, shuffled)
	hits_filter, filter_rand := bench_checks(filter_gate_accept, &fg, shuffled)
	hits_direct, direct_rand := bench_checks(direct_accept, &d, shuffled)
	testing.expect(t, hits_seq == hits_rand && hits_rand == hits_filter && hits_filter == hits_direct)
	log.infof("labels %d: visibility build %.0f ns (%.2f ns per label); refresh %.1f ns for one new label, %.1f ns for %d new labels; %d of %d visible; per check over %d slots: gate %.2f ns sequential, %.2f ns random, filter gate without program %.2f ns random, direct dominance %.2f ns random; %.1f%% accepted", n, build, build / f64(n), incremental, batched, batch, visible_count(&v), n, BENCH_SLOTS, gate_seq, gate_rand, filter_rand, direct_rand, 100 * f64(hits_rand) / f64(BENCH_ROUNDS * BENCH_SLOTS))
}

@(test)
bench_visibility_and_checks :: proc(t: ^testing.T) {
	value := os.get_env(BENCH_ENV, runtime.heap_allocator())
	defer delete(value, runtime.heap_allocator())
	if value == "" {
		return
	}
	bench_size(t, 16)
	bench_size(t, 1_024)
	bench_size(t, LABEL_LIMIT)
}
