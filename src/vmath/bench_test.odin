package vmath

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

BENCH_ENV :: "VMATH_BENCH"
BENCH_DIMS :: [?]int{8, 32, 128, 300, 768, 1536}
BENCH_POOL :: 64
BENCH_L1_BYTES :: 32 * 1024
BENCH_BUDGET_NS :: 60_000_000
BENCH_DRAM_BYTES :: 64 * 1024 * 1024
BENCH_BATCH :: 32

Bench_Kernel :: struct {
	name:  string,
	elem:  Elem,
	f32:   Dot_F32_Proc,
	i8:    Dot_I8_Proc,
	u8:    Dot_U8_Proc,
	bin:   Hamming_Proc,
	slice: proc(a: []f32, b: []f32) -> f32,
}

Bench_Dram :: struct {
	seq:   [Level]f64,
	batch: [Level]f64,
}

bench_sink: f64

bench_ref_f32 :: proc(a: []f32, b: []f32) -> f32 {
	return dot_f32_ref(a, b)
}

bench_pool :: proc(elem: Elem, dim: int) -> int {
	return clamp(BENCH_L1_BYTES / elem_vector_bytes(elem, dim), 2, BENCH_POOL)
}

bench_cell :: proc(b: ^strings.Builder, text: string) {
	for _ in len(text) ..< 10 {
		strings.write_byte(b, ' ')
	}
	strings.write_string(b, text)
}

bench_pad :: proc(b: ^strings.Builder, text: string, width: int) {
	strings.write_string(b, text)
	for _ in len(text) ..< width {
		strings.write_byte(b, ' ')
	}
}

bench_header :: proc(b: ^strings.Builder, title: string) {
	strings.write_string(b, title)
	bench_pad(b, "\n", 31)
	for dim in BENCH_DIMS {
		bench_cell(b, fmt.tprint(dim))
	}
	strings.write_byte(b, '\n')
}

bench_median5 :: proc(runs: ^[5]f64) -> f64 {
	for i in 1 ..< len(runs) {
		for j := i; j > 0 && runs[j] < runs[j - 1]; j -= 1 {
			runs[j], runs[j - 1] = runs[j - 1], runs[j]
		}
	}
	return runs[2]
}

bench_run :: proc(k: Bench_Kernel, dim: int, data: [][]u8) -> f64 {
	iterations := 0
	pool := len(data)
	start := time.tick_now()
	for {
		for i in 0 ..< pool {
			a := data[i]
			b := data[(i + 1) % pool]
			#partial switch k.elem {
			case .F32:
				if k.slice != nil {
					bench_sink += f64(k.slice(f32_view(a), f32_view(b)))
				} else {
					bench_sink += f64(k.f32(([^]f32)(raw_data(a)), ([^]f32)(raw_data(b)), dim))
				}
			case .Int8:
				bench_sink += f64(k.i8(([^]i8)(raw_data(a)), ([^]i8)(raw_data(b)), dim))
			case .U8:
				bench_sink += f64(k.u8(raw_data(a), raw_data(b), dim))
			case .Bin:
				bench_sink += f64(k.bin(([^]u64)(raw_data(a)), ([^]u64)(raw_data(b)), bin_words(dim)))
			}
		}
		iterations += pool
		if time.duration_nanoseconds(time.tick_since(start)) >= BENCH_BUDGET_NS {
			break
		}
	}
	return f64(time.duration_nanoseconds(time.tick_since(start))) / f64(iterations)
}

bench_blob :: proc(r: ^Rng, elem: Elem, dim: int) -> []u8 {
	return search_random_blob(r, elem, dim, false)
}

bench_fill :: proc(a: ^Arena, r: ^Rng, count: int) {
	if a.family == .Vector_Set {
		x := test_raw_vector(r, a.dim)
		for i in 0 ..< count {
			if i % 64 == 0 {
				x = test_raw_vector(r, a.dim)
			}
			x[i % a.dim] += 1
			arena_insert(a, x)
		}
		return
	}
	pool := make([][]u8, 64, context.temp_allocator)
	for &p in pool {
		p = bench_blob(r, a.elem, a.dim)
	}
	for i in 0 ..< count {
		arena_insert_blob(a, pool[i % 64])
	}
}

bench_query :: proc(a: ^Arena, r: ^Rng) -> Query {
	buf, _ := query_alloc(a, context.temp_allocator)
	if a.family == .Vector_Set {
		q, _ := query_encode(a, test_raw_vector(r, a.dim), buf)
		return q
	}
	q, _ := query_encode_blob(a, bench_blob(r, a.elem, a.dim), buf)
	return q
}

bench_bind :: proc(a: ^Arena, level: Level) {
	k := kernels_for(level, a.family)
	a.distance = k.distance[a.elem][a.metric]
	a.batch = k.batch[a.elem][a.metric]
}

bench_l1 :: proc(family: Family, elem: Elem, metric: Metric, level: Level, dim: int, r: ^Rng) -> (single: f64, batch: f64) {
	a: Arena
	pool := bench_pool(elem, dim)
	arena_init(&a, elem, metric, dim, runtime.heap_allocator(), pool, family)
	defer arena_destroy(&a)
	bench_bind(&a, level)
	bench_fill(&a, r, pool)
	q := bench_query(&a, r)
	iterations := 0
	start := time.tick_now()
	for {
		for i in 0 ..< pool {
			bench_sink += f64(arena_query_distance(&a, q, u32(i)))
		}
		iterations += pool
		if time.duration_nanoseconds(time.tick_since(start)) >= BENCH_BUDGET_NS {
			break
		}
	}
	single = f64(time.duration_nanoseconds(time.tick_since(start))) / f64(iterations)
	ids: [BENCH_BATCH]u32
	for &id, i in ids {
		id = u32(i % pool)
	}
	out: [BENCH_BATCH]f32
	batches := 0
	start = time.tick_now()
	for {
		for _ in 0 ..< 16 {
			arena_query_distances(&a, &q, ids[:], out[:])
			bench_sink += f64(out[7])
			batches += 1
		}
		if time.duration_nanoseconds(time.tick_since(start)) >= BENCH_BUDGET_NS {
			break
		}
	}
	batch = f64(time.duration_nanoseconds(time.tick_since(start))) / f64(batches)
	return
}

bench_dram :: proc(family: Family, elem: Elem, metric: Metric, dim: int, r: ^Rng, levels: []Level) -> (out: Bench_Dram) {
	a: Arena
	slots := max(4096, BENCH_DRAM_BYTES / slot_bytes(elem, dim, family))
	arena_init(&a, elem, metric, dim, runtime.heap_allocator(), slots, family)
	defer arena_destroy(&a)
	bench_fill(&a, r, slots)
	q := bench_query(&a, r)
	ids := make([]u32, 1 << 16, runtime.heap_allocator())
	defer delete(ids, runtime.heap_allocator())
	for &id in ids {
		id = u32(rng_next(r) % u64(slots))
	}
	res: [BENCH_BATCH]f32
	for level in levels {
		bench_bind(&a, level)
		for mode in 0 ..< 2 {
			runs: [5]f64
			off := 0
			for &run in runs {
				batches := 0
				start := time.tick_now()
				for {
					for _ in 0 ..< 64 {
						b := ids[off:][:BENCH_BATCH]
						if mode == 0 {
							for s in b {
								bench_sink += f64(arena_query_distance(&a, q, s))
							}
						} else {
							arena_query_distances(&a, &q, b, res[:])
							bench_sink += f64(res[5])
						}
						off = (off + BENCH_BATCH) & (len(ids) - 1)
						batches += 1
					}
					if time.duration_nanoseconds(time.tick_since(start)) >= BENCH_BUDGET_NS / 2 {
						break
					}
				}
				run = f64(time.duration_nanoseconds(time.tick_since(start))) / f64(batches)
			}
			if mode == 0 {
				out.seq[level] = bench_median5(&runs)
			} else {
				out.batch[level] = bench_median5(&runs)
			}
		}
	}
	return
}

bench_levels :: proc(family: Family, elem: Elem, allocator: runtime.Allocator) -> []Level {
	out := make([dynamic]Level, allocator)
	cpu := cpu_detect()
	for level in Level {
		if level_supported(level, cpu) && (level < .Avx_Vnni || elem == .Int8 || elem == .U8) {
			append(&out, level)
		}
	}
	return out[:]
}

bench_tag :: proc(family: Family, elem: Elem, metric: Metric, level: Level) -> string {
	return fmt.tprintf("%s %s %s %v", "vset" if family == .Vector_Set else "search", elem_name(elem), metric_name(metric), level)
}

bench_dots :: proc(b: ^strings.Builder, r: ^Rng) {
	list := make([dynamic]Bench_Kernel, context.temp_allocator)
	append(&list, Bench_Kernel{name = "f32 ref scalar", elem = .F32, slice = bench_ref_f32})
	append(&list, Bench_Kernel{name = "f32 exact base", elem = .F32, f32 = dot_f32_exact_base})
	append(&list, Bench_Kernel{name = "f32 fast base", elem = .F32, f32 = dot_f32_fast_base})
	append(&list, Bench_Kernel{name = "int8 base", elem = .Int8, i8 = dot_i8_base})
	append(&list, Bench_Kernel{name = "u8 base", elem = .U8, u8 = dot_u8_base})
	append(&list, Bench_Kernel{name = "bin base", elem = .Bin, bin = hamming_base})
	when ODIN_ARCH == .amd64 {
		cpu := cpu_detect()
		if level_supported(.Avx2, cpu) {
			append(&list, Bench_Kernel{name = "f32 exact avx2", elem = .F32, f32 = dot_f32_exact_avx2})
			append(&list, Bench_Kernel{name = "f32 fast avx2", elem = .F32, f32 = dot_f32_fast_avx2})
			append(&list, Bench_Kernel{name = "int8 avx2", elem = .Int8, i8 = dot_i8_avx2})
			append(&list, Bench_Kernel{name = "u8 avx2", elem = .U8, u8 = dot_u8_avx2})
			append(&list, Bench_Kernel{name = "bin avx2", elem = .Bin, bin = hamming_avx2})
		}
		if level_supported(.Avx_Vnni, cpu) {
			append(&list, Bench_Kernel{name = "int8 vnni", elem = .Int8, i8 = dot_i8_vnni})
			append(&list, Bench_Kernel{name = "u8 vnni", elem = .U8, u8 = dot_u8_vnni})
		}
		if level_supported(.Avx_Vnni_Int8, cpu) {
			append(&list, Bench_Kernel{name = "int8 vnni-int8", elem = .Int8, i8 = dot_i8_vnni_int8})
			append(&list, Bench_Kernel{name = "u8 vnni-int8", elem = .U8, u8 = dot_u8_vnni_int8})
		}
	}
	bench_header(b, fmt.tprintf("\nns per dot product, vectors resident in L1, best level %v", best_level(cpu_detect())))
	for k in list {
		bench_pad(b, k.name, 30)
		for dim in BENCH_DIMS {
			a: Arena
			elem := k.elem if k.elem != .U8 else Elem.Int8
			pool := bench_pool(elem, dim)
			arena_init(&a, elem, .Cosine, dim, runtime.heap_allocator(), pool)
			data := make([][]u8, pool, context.temp_allocator)
			for &d in data {
				slot, _ := arena_insert(&a, test_raw_vector(r, dim))
				d = arena_bytes(&a, slot)
			}
			bench_cell(b, fmt.tprintf("%.2f", bench_run(k, dim, data)))
			arena_destroy(&a)
		}
		strings.write_byte(b, '\n')
	}
}

@(test)
bench_kernels :: proc(t: ^testing.T) {
	value := os.get_env(BENCH_ENV, context.temp_allocator)
	if value == "" {
		return
	}
	saved := kernels.level
	defer use_level(saved)
	r: Rng
	rng_seed(&r, 51)
	b := strings.builder_make(context.temp_allocator)
	if value == "1" || value == "all" || value == "dot" {
		bench_dots(&b, &r)
	}
	if value == "all" || value == "l1" {
		bench_header(&b, fmt.tprintf("\nns per arena_query_distance (one) and per arena_query_distances of %d slots (b32), L1-resident", BENCH_BATCH))
		for family in Family {
			for elem in Elem {
				for metric in Metric {
					if !family_supports(family, elem, metric) {
						continue
					}
					for level in bench_levels(family, elem, context.temp_allocator) {
						one: [len(BENCH_DIMS)]f64
						b32: [len(BENCH_DIMS)]f64
						for dim, i in BENCH_DIMS {
							one[i], b32[i] = bench_l1(family, elem, metric, level, dim, &r)
						}
						bench_pad(&b, fmt.tprintf("%s one", bench_tag(family, elem, metric, level)), 30)
						for v in one {
							bench_cell(&b, fmt.tprintf("%.2f", v))
						}
						strings.write_byte(&b, '\n')
						bench_pad(&b, fmt.tprintf("%s b32", bench_tag(family, elem, metric, level)), 30)
						for v in b32 {
							bench_cell(&b, fmt.tprintf("%.1f", v))
						}
						strings.write_byte(&b, '\n')
					}
				}
			}
		}
	}
	if value == "all" || value == "dram" {
		bench_header(&b, fmt.tprintf("\nns per %d random slots from a max(4096, 64 MiB) arena, median of 5: seq = %d arena_query_distance calls, batch = arena_query_distances", BENCH_BATCH, BENCH_BATCH))
		for family in Family {
			for elem in Elem {
				for metric in Metric {
					if !family_supports(family, elem, metric) {
						continue
					}
					levels := bench_levels(family, elem, runtime.heap_allocator())
					defer delete(levels, runtime.heap_allocator())
					res: [len(BENCH_DIMS)]Bench_Dram
					for dim, i in BENCH_DIMS {
						res[i] = bench_dram(family, elem, metric, dim, &r, levels)
					}
					for level in levels {
						bench_pad(&b, fmt.tprintf("%s seq", bench_tag(family, elem, metric, level)), 30)
						for x in res {
							bench_cell(&b, fmt.tprintf("%.1f", x.seq[level]))
						}
						strings.write_byte(&b, '\n')
						bench_pad(&b, fmt.tprintf("%s batch", bench_tag(family, elem, metric, level)), 30)
						for x in res {
							bench_cell(&b, fmt.tprintf("%.1f", x.batch[level]))
						}
						strings.write_byte(&b, '\n')
					}
				}
			}
		}
	}
	log.info(strings.to_string(b))
	if bench_sink == 0.123456789 {
		log.info("sink")
	}
	testing.expect(t, strings.builder_len(b) > 0)
}
