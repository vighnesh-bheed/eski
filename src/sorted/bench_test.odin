package sorted

import "core:log"
import "core:os"
import "core:testing"
import "core:time"

BENCH_ENV :: "ESKI_SORTED_BENCH"

BENCH_BUDGET :: 200 * time.Millisecond

bench_sink: int

Bench_Kernel :: struct {
	name: string,
	run:  proc(a, b: []u32, out: []u32) -> int,
}

bench_case :: proc(name: string, a, b: []u32) {
	out := make([]u32, min(len(a), len(b)))
	defer delete(out)
	kernels_list := [?]Bench_Kernel {
		{"reference merge", proc(a, b: []u32, out: []u32) -> int {return intersect_reference(a, b, out)}},
		{"branchless merge", proc(a, b: []u32, out: []u32) -> int {return intersect_merge(a, b, out)}},
		{"galloping", proc(a, b: []u32, out: []u32) -> int {
				if len(a) <= len(b) {
					return intersect_gallop(a, b, out)
				}
				return intersect_gallop(b, a, out)
			}},
		{"avx2 block merge", proc(a, b: []u32, out: []u32) -> int {return kernels_for(.Avx2).intersect(a, b, out)}},
		{"dispatch", proc(a, b: []u32, out: []u32) -> int {return intersect(a, b, out)}},
	}
	for k in kernels_list {
		if k.name == "avx2 block merge" && !level_supported(.Avx2) {
			continue
		}
		rounds := 0
		found := 0
		start := time.tick_now()
		for time.tick_since(start) < BENCH_BUDGET {
			found = k.run(a, b, out)
			bench_sink += found
			rounds += 1
		}
		seconds := time.duration_seconds(time.tick_since(start))
		log.infof("intersection %s (%d x %d, %d common), %s: %.0f M input elements/s, %.2f us per call", name, len(a), len(b), found, k.name, f64(rounds * (len(a) + len(b))) / seconds / 1e6, seconds * 1e6 / f64(rounds))
	}
}

bench_set :: proc(r: ^Rng, n: int, universe: u32) -> []u32 {
	return random_set(r, n, universe)
}

@(test)
bench_intersection_throughput :: proc(t: ^testing.T) {
	if _, enabled := os.lookup_env(BENCH_ENV, context.temp_allocator); !enabled {
		return
	}
	r := Rng{0xB1}
	a := bench_set(&r, 100_000, 400_000)
	b := bench_set(&r, 100_000, 400_000)
	bench_case("similar sizes, 25% density", a, b)
	delete(a)
	delete(b)
	a = bench_set(&r, 100_000, 10_000_000)
	b = bench_set(&r, 100_000, 10_000_000)
	bench_case("similar sizes, sparse", a, b)
	delete(a)
	delete(b)
	a = bench_set(&r, 1_000, 10_000_000)
	b = bench_set(&r, 1_000_000, 10_000_000)
	bench_case("skewed 1:1000", a, b)
	delete(a)
	delete(b)
	a = bench_set(&r, 20_000, 1_000_000)
	b = bench_set(&r, 200_000, 1_000_000)
	bench_case("skewed 1:10", a, b)
	delete(a)
	delete(b)
}
