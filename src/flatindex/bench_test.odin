package flatindex

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "../roaring"
import "../vmath"

BENCH_ENV :: "ESKI_FLATINDEX_BENCH"
BENCH_DIMS :: [?]int{128, 384, 768, 1536}
BENCH_DRAM_BYTES :: 64 * 1024 * 1024
BENCH_CACHE_BYTES :: 2 * 1024 * 1024
BENCH_BUDGET_NS :: 40_000_000
BENCH_QUERIES :: 8

bench_sink: f64

bench_enabled :: proc() -> bool {
	_, ok := os.lookup_env(BENCH_ENV, context.temp_allocator)
	return ok
}

bench_median5 :: proc(runs: ^[5]f64) -> f64 {
	for i in 1 ..< len(runs) {
		for j := i; j > 0 && runs[j] < runs[j - 1]; j -= 1 {
			runs[j], runs[j - 1] = runs[j - 1], runs[j]
		}
	}
	return runs[2]
}

bench_fill :: proc(ix: ^Index, n: int, seed: u64) {
	r: vmath.Rng
	vmath.rng_seed(&r, seed)
	for i in 0 ..< n {
		add(ix, u32(i), random_blob(&r, ix.spec.elem, ix.spec.dim, false))
		if i & 1023 == 1023 {
			free_all(context.temp_allocator)
		}
	}
	free_all(context.temp_allocator)
}

bench_queries :: proc(ix: ^Index, seed: u64) -> [BENCH_QUERIES]Query {
	r: vmath.Rng
	vmath.rng_seed(&r, seed)
	qs: [BENCH_QUERIES]Query
	for &q in qs {
		query_for(&q, ix, random_blob(&r, ix.spec.elem, ix.spec.dim, false), runtime.heap_allocator())
	}
	return qs
}

bench_time :: proc(ix: ^Index, qs: ^[BENCH_QUERIES]Query, k: int, filter: Filter, radius := -1.0) -> (ns_per_query: f64) {
	out := make([dynamic]Hit, 0, max(k, 16), runtime.heap_allocator())
	defer delete(out)
	runs: [5]f64
	for &run in runs {
		iterations := 0
		start := time.tick_now()
		for {
			clear(&out)
			q := &qs[iterations % BENCH_QUERIES]
			if radius >= 0 {
				range_search(ix, q, radius, &out, filter)
			} else {
				knn(ix, q, k, &out, filter)
			}
			if len(out) > 0 {
				bench_sink += out[0].dist
			}
			iterations += 1
			if time.duration_nanoseconds(time.tick_since(start)) >= BENCH_BUDGET_NS / 5 {
				break
			}
		}
		run = f64(time.duration_nanoseconds(time.tick_since(start))) / f64(iterations)
	}
	return bench_median5(&runs)
}

bench_cell :: proc(b: ^strings.Builder, text: string, width := 11) {
	for _ in len(text) ..< width {
		strings.write_byte(b, ' ')
	}
	strings.write_string(b, text)
}

bench_scan_table :: proc(budget_bytes: int, title: string) {
	b := strings.builder_make(runtime.heap_allocator())
	defer strings.builder_destroy(&b)
	strings.write_string(&b, title)
	strings.write_string(&b, "\n  type     metric")
	for dim in BENCH_DIMS {
		bench_cell(&b, fmt.tprintf("dim %d", dim), 22)
	}
	strings.write_byte(&b, '\n')
	for elem in ALL_ELEMS {
		for metric in ALL_METRICS {
			strings.write_string(&b, fmt.tprintf("  %-8s %-6s", vmath.search_type_name(elem), vmath.metric_name(metric)))
			for dim in BENCH_DIMS {
				spec := spec_default(elem, metric, dim)
				n := max(budget_bytes / slot_bytes(spec), 256)
				ix: Index
				init(&ix, spec, runtime.heap_allocator())
				bench_fill(&ix, n, u64(dim) * 31 + u64(elem) * 7 + u64(metric))
				qs := bench_queries(&ix, 77)
				ns := bench_time(&ix, &qs, 10, {})
				vps := f64(n) / (ns / 1e9)
				gbs := f64(n * ix.stride) / ns
				bench_cell(&b, fmt.tprintf("%.1fM/s %.1fGB/s", vps / 1e6, gbs), 22)
				for &q in qs {
					query_destroy(&q)
				}
				destroy(&ix)
			}
			strings.write_byte(&b, '\n')
		}
	}
	log.info(strings.to_string(b))
}

bench_topk :: proc() {
	b := strings.builder_make(runtime.heap_allocator())
	defer strings.builder_destroy(&b)
	spec := spec_default(.F32, .L2, 128)
	n := 4096
	ix: Index
	init(&ix, spec, runtime.heap_allocator())
	defer destroy(&ix)
	bench_fill(&ix, n, 5)
	qs := bench_queries(&ix, 6)
	defer for &q in qs {
		query_destroy(&q)
	}
	base := bench_time(&ix, &qs, 0, {})
	strings.write_string(&b, fmt.tprintf("top-k selection, FLOAT32 L2 dim 128, %d cached vectors: scoring only %.1f ns per vector\n", n, base / f64(n)))
	for k in ([]int{1, 10, 100, 1000}) {
		ns := bench_time(&ix, &qs, k, {})
		strings.write_string(&b, fmt.tprintf("  k %4d: %.2f ns per vector, selection adds %.2f ns per vector\n", k, ns / f64(n), (ns - base) / f64(n)))
	}
	worst: Index
	init(&worst, spec_default(.F32, .L2, 1), runtime.heap_allocator())
	defer destroy(&worst)
	m := 1 << 16
	for i in 0 ..< m {
		v := [1]f32{f32(m - i)}
		add(&worst, u32(i), mem.slice_to_bytes(v[:]))
	}
	z := [1]f32{0}
	wq: [BENCH_QUERIES]Query
	for &q in wq {
		query_for(&q, &worst, mem.slice_to_bytes(z[:]), runtime.heap_allocator())
	}
	defer for &q in wq {
		query_destroy(&q)
	}
	wbase := bench_time(&worst, &wq, 0, {})
	for k in ([]int{10, 1000}) {
		ns := bench_time(&worst, &wq, k, {})
		strings.write_string(&b, fmt.tprintf("  descending input, every vector enters the heap, dim 1, k %4d: selection %.2f ns per vector\n", k, (ns - wbase) / f64(m)))
	}
	log.info(strings.to_string(b))
}

Bench_Set :: struct {
	set:     roaring.Bitmap,
	ids:     [dynamic]u32,
	salt:    u64,
	percent: u64,
}

bench_accept :: proc(ctx: rawptr, id: u32) -> bool {
	s := (^Bench_Set)(ctx)
	return hash_id(id, s.salt) % 100 < s.percent
}

bench_time_filters :: proc(ix: ^Index, qs: ^[BENCH_QUERIES]Query, k: int, filters: []Filter) -> f64 {
	out := make([dynamic]Hit, 0, max(k, 16), runtime.heap_allocator())
	defer delete(out)
	runs: [5]f64
	for &run in runs {
		iterations := 0
		start := time.tick_now()
		for {
			clear(&out)
			knn(ix, &qs[iterations % BENCH_QUERIES], k, &out, filters[iterations % len(filters)])
			if len(out) > 0 {
				bench_sink += out[0].dist
			}
			iterations += 1
			if time.duration_nanoseconds(time.tick_since(start)) >= BENCH_BUDGET_NS / 5 {
				break
			}
		}
		run = f64(time.duration_nanoseconds(time.tick_since(start))) / f64(iterations)
	}
	return bench_median5(&runs)
}

BENCH_FILTER_BYTES :: 256 * 1024 * 1024
BENCH_FILTER_SETS :: 8

bench_filtered :: proc() {
	b := strings.builder_make(runtime.heap_allocator())
	defer strings.builder_destroy(&b)
	spec := spec_default(.F32, .Cosine, 384)
	n := BENCH_FILTER_BYTES / slot_bytes(spec)
	ix: Index
	init(&ix, spec, runtime.heap_allocator())
	defer destroy(&ix)
	bench_fill(&ix, n, 9)
	qs := bench_queries(&ix, 10)
	defer for &q in qs {
		query_destroy(&q)
	}
	full := bench_time(&ix, &qs, 10, {})
	strings.write_string(&b, fmt.tprintf("filtered knn k 10, FLOAT32 COSINE dim 384, %d vectors (%d MB), %d candidate sets rotated per query: unfiltered %.2f ms per query (%.1f M vectors per second)\n", n, n * ix.stride >> 20, BENCH_FILTER_SETS, full / 1e6, f64(n) / full * 1e3))
	for pct in ([]u64{1, 10, 50}) {
		sets: [BENCH_FILTER_SETS]Bench_Set
		total := 0
		for &s, si in sets {
			s.salt = u64(si) * 1000 + pct
			s.percent = pct
			roaring.init(&s.set, runtime.heap_allocator())
			s.ids = make([dynamic]u32, runtime.heap_allocator())
			for id in 0 ..< u32(n) {
				if hash_id(id, s.salt) % 100 < pct {
					roaring.add(&s.set, id)
					append(&s.ids, id)
				}
			}
			roaring.run_optimize(&s.set)
			total += len(s.ids)
		}
		per := f64(total) / f64(BENCH_FILTER_SETS)
		fa, fl, fb: [BENCH_FILTER_SETS]Filter
		for &s, si in sets {
			fa[si] = filter_accept(bench_accept, &s)
			fl[si] = filter_ids(s.ids[:])
			fb[si] = filter_bitmap(&s.set)
		}
		acc := bench_time_filters(&ix, &qs, 10, fa[:])
		lst := bench_time_filters(&ix, &qs, 10, fl[:])
		bit := bench_time_filters(&ix, &qs, 10, fb[:])
		strings.write_string(&b, fmt.tprintf("  %2d%% selective (about %.0f candidates): accept %.3f ms, sorted ids %.3f ms, bitmap %.3f ms per query; %.1f, %.1f, %.1f ns per candidate\n", pct, per, acc / 1e6, lst / 1e6, bit / 1e6, acc / per, lst / per, bit / per))
		for &s in sets {
			roaring.destroy(&s.set)
			delete(s.ids)
		}
	}
	rad := bench_time(&ix, &qs, 0, {}, 0.8)
	strings.write_string(&b, fmt.tprintf("  range radius 0.8 over the same index: %.2f ms per query\n", rad / 1e6))
	log.info(strings.to_string(b))
}

bench_footprint :: proc() {
	b := strings.builder_make(runtime.heap_allocator())
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "memory per vector (bytes, index total divided by count; vector bytes in brackets)\n")
	for n in ([]int{1, 10, 300, 100_000}) {
		strings.write_string(&b, fmt.tprintf("  %7d vectors:", n))
		for dim in ([]int{128, 1536}) {
			for elem in ([]vmath.Elem{.F32, .Int8}) {
				spec := spec_default(elem, .Cosine, dim)
				ix: Index
				init(&ix, spec, runtime.heap_allocator())
				bench_fill(&ix, n, 3)
				strings.write_string(&b, fmt.tprintf("  %s dim %d %.1f [%d]", vmath.search_type_name(elem), dim, f64(memory(&ix)) / f64(n), ix.stride))
				destroy(&ix)
			}
		}
		strings.write_byte(&b, '\n')
	}
	log.info(strings.to_string(b))
}

@(test)
bench_flatindex :: proc(t: ^testing.T) {
	if !bench_enabled() {
		return
	}
	log.infof("kernel level %v", vmath.search_kernels.level)
	bench_footprint()
	bench_topk()
	bench_filtered()
	bench_scan_table(BENCH_CACHE_BYTES, "full scan, k 10, 2 MB of vectors (cache resident): vectors per second and bytes per second")
	bench_scan_table(BENCH_DRAM_BYTES, "full scan, k 10, 64 MB of vectors (memory resident): vectors per second and bytes per second")
}
