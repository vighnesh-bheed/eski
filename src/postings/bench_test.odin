package postings

import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"
import "core:time"

BENCH_ENV :: "ESKI_POSTINGS_BENCH"

BENCH_POSTINGS :: 1_000_000

bench_sink: u64

bench_build :: proc(r: ^Rng, l: ^List, layout: Layout, n: int, gap: int, positions: int) {
	init(l, layout)
	doc := u32(0)
	counts := [1]u32{}
	pos := make([dynamic]u32)
	defer delete(pos)
	for _ in 0 ..< n {
		doc += 1 + u32(rng_below(r, gap))
		p := Posting{doc = doc, frequency = u32(1 + rng_below(r, 3)), fields = 1}
		if layout.positions {
			clear(&pos)
			at := u32(0)
			k := 1 + rng_below(r, 2 * positions - 1)
			for _ in 0 ..< k {
				at += 1 + u32(rng_below(r, 40))
				append(&pos, at)
			}
			counts[0] = u32(k)
			p.counts = counts[:]
			p.positions = pos[:]
		}
		append_posting(l, p)
	}
}

bench_list :: proc(r: ^Rng, name: string, layout: Layout, gap: int, positions: int) {
	l: List
	start := time.tick_now()
	bench_build(r, &l, layout, BENCH_POSTINGS, gap, positions)
	build := time.tick_since(start)
	defer destroy(&l)
	c: Cursor
	cursor_init(&c, &l, nil, 0)
	start = time.tick_now()
	n := 0
	for d := next(&c); d != END; d = next(&c) {
		n += 1
	}
	walk := time.tick_since(start)
	cursor_destroy(&c)
	cursor_init(&c, &l, nil, 0)
	start = time.tick_now()
	for d := next(&c); d != END; d = next(&c) {
		bench_sink += u64(frequency(&c))
	}
	walk_frequency := time.tick_since(start)
	cursor_destroy(&c)
	cursor_init(&c, &l, nil, 0)
	jumps := 0
	start = time.tick_now()
	target := u32(1)
	for {
		d := advance(&c, target)
		if d == END {
			break
		}
		jumps += 1
		target = d + u32(1 + rng_below(r, 64 * gap))
	}
	skip := time.tick_since(start)
	cursor_destroy(&c)
	extra := ""
	if layout.positions {
		cursor_init(&c, &l, nil, 0)
		buf := make([dynamic]u32)
		start = time.tick_now()
		total := 0
		for d := next(&c); d != END; d = next(&c) {
			clear(&buf)
			cursor_positions(&c, ALL_FIELDS, &buf)
			total += len(buf)
		}
		read := time.tick_since(start)
		cursor_destroy(&c)
		delete(buf)
		extra = log_positions(total, read)
	}
	log.infof("postings %s: %d postings, %.2f bytes per posting, build %.0f ns per append, next %.2f ns per posting, next with frequency %.2f ns, %d advances at %.1f ns each%s", name, n, f64(encoded_bytes(&l)) / f64(n), f64(time.duration_nanoseconds(build)) / f64(n), f64(time.duration_nanoseconds(walk)) / f64(n), f64(time.duration_nanoseconds(walk_frequency)) / f64(n), jumps, f64(time.duration_nanoseconds(skip)) / f64(max(jumps, 1)), extra)
}

log_positions :: proc(total: int, read: time.Duration) -> string {
	return fmt.tprintf(", positions %d read at %.2f ns per position", total, f64(time.duration_nanoseconds(read)) / f64(max(total, 1)))
}

@(test)
bench_bytes_and_decode :: proc(t: ^testing.T) {
	if _, enabled := os.lookup_env(BENCH_ENV, context.temp_allocator); !enabled {
		return
	}
	r := Rng{0xBE7C}
	bench_list(&r, "dense gaps 1..4, no positions", Layout{field_words = 1}, 4, 0)
	bench_list(&r, "sparse gaps 1..256, no positions", Layout{field_words = 1}, 256, 0)
	bench_list(&r, "dense gaps 1..4, about 2 positions", Layout{field_words = 1, positions = true}, 4, 2)
	bench_list(&r, "sparse gaps 1..256, about 4 positions", Layout{field_words = 1, positions = true}, 256, 4)
}
