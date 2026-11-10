package retrieve

import "core:log"
import "core:os"
import "core:testing"
import "core:time"
import "../postings"
import "../sorted"

BENCH_ENV :: "ESKI_RETRIEVE_BENCH"

bench_sink: u64

bench_list :: proc(r: ^Rng, l: ^postings.List, n: int, universe: int) -> []u32 {
	postings.init(l, postings.Layout{field_words = 1})
	docs := make([dynamic]u32)
	seen := make(map[u32]bool, n)
	defer delete(seen)
	for len(seen) < n {
		seen[u32(1 + rng_below(r, universe))] = true
	}
	for d in seen {
		append(&docs, d)
	}
	sort_u32_fast(docs[:])
	for d in docs {
		postings.append_posting(l, postings.Posting{doc = d, frequency = 1, fields = 1})
	}
	return docs[:]
}

sort_u32_fast :: proc(a: []u32) {
	if len(a) < 2 {
		return
	}
	tmp := make([]u32, len(a))
	defer delete(tmp)
	for shift := uint(0); shift < 32; shift += 8 {
		count: [257]int
		for x in a {
			count[(x >> shift & 0xFF) + 1] += 1
		}
		for i in 1 ..< 257 {
			count[i] += count[i - 1]
		}
		for x in a {
			k := x >> shift & 0xFF
			tmp[count[k]] = x
			count[k] += 1
		}
		copy(a, tmp)
	}
}

bench_pair :: proc(r: ^Rng, name: string, na, nb, universe: int) {
	la, lb: postings.List
	da := bench_list(r, &la, na, universe)
	db := bench_list(r, &lb, nb, universe)
	defer {
		postings.destroy(&la)
		postings.destroy(&lb)
		delete(da)
		delete(db)
	}
	out := make([]u32, min(na, nb))
	defer delete(out)
	start := time.tick_now()
	rounds := 0
	common := 0
	for time.tick_since(start) < 300 * time.Millisecond {
		common = sorted.intersect_reference(da, db, out)
		rounds += 1
	}
	reference := time.duration_seconds(time.tick_since(start)) / f64(rounds)
	strategies := [?]Strategy{.Leapfrog, .Block}
	timing: [2]f64
	for s, si in strategies {
		rounds = 0
		start = time.tick_now()
		for time.tick_since(start) < 300 * time.Millisecond {
			ta, tb: Term_Cursor
			term_cursor_init(&ta, &la, nil, 0, leaf(.Term))
			term_cursor_init(&tb, &lb, nil, 0, leaf(.Term))
			ix: Intersection
			intersection_init(&ix, {&ta, &tb}, nil, 1, s)
			n := 0
			for d := next(&ix); d != END; d = next(&ix) {
				n += 1
			}
			bench_sink += u64(n)
			assert(n == common)
			intersection_destroy(&ix)
			term_cursor_destroy(&ta)
			term_cursor_destroy(&tb)
			rounds += 1
		}
		timing[si] = time.duration_seconds(time.tick_since(start)) / f64(rounds)
	}
	log.infof("cursor intersection %s (%d x %d, %d common): scalar merge over decoded arrays %.0f M postings/s, leapfrog with galloping %.0f M postings/s, block merge with the simd kernel %.0f M postings/s", name, na, nb, common, f64(na + nb) / reference / 1e6, f64(na + nb) / timing[0] / 1e6, f64(na + nb) / timing[1] / 1e6)
}

@(test)
bench_cursor_intersections :: proc(t: ^testing.T) {
	if _, enabled := os.lookup_env(BENCH_ENV, context.temp_allocator); !enabled {
		return
	}
	r := Rng{0x1A7E}
	bench_pair(&r, "similar sizes", 500_000, 500_000, 2_000_000)
	bench_pair(&r, "skewed 1:20", 25_000, 500_000, 2_000_000)
	bench_pair(&r, "skewed 1:500", 1_000, 500_000, 2_000_000)
}
