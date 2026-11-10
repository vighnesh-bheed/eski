package ftindex

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import ftq "../ftquery"

BENCH_ENV :: "ESKI_FTINDEX_BENCH"

BENCH_VOCABULARY :: 2000

bench_word :: proc(r: ^Rng) -> string {
	x := rng_below(r, BENCH_VOCABULARY)
	y := rng_below(r, BENCH_VOCABULARY)
	return fmt.tprintf("w%d", min(x, y))
}

@(test)
bench_index_and_query :: proc(t: ^testing.T) {
	if len(os.get_env(BENCH_ENV, context.temp_allocator)) == 0 {
		return
	}
	docs := 50_000
	fields := [?]Field {
		{name = "title", source = "title", kind = .Text, weight = 2, separator = ','},
		{name = "body", source = "body", kind = .Text, weight = 1, separator = ','},
		{name = "tag", source = "tag", kind = .Tag, weight = 1, separator = ','},
		{name = "year", source = "year", kind = .Numeric, weight = 1, separator = ','},
		{name = "v", source = "v", kind = .Vector, weight = 1, separator = ',', vector = {method = .Hnsw, elem = .F32, metric = .Cosine, dim = 32, m = 16, ef_construction = 100, ef_runtime = 64}},
	}
	ix: Index
	testing.expect_value(t, init(&ix, definition_default(fields[:])), Error.None)
	defer destroy(&ix)
	r := Rng{0xBE_7C4}
	start := time.tick_now()
	for i in 0 ..< docs {
		title := strings.builder_make(context.temp_allocator)
		body := strings.builder_make(context.temp_allocator)
		for k in 0 ..< 4 {
			if k > 0 {
				strings.write_byte(&title, ' ')
			}
			strings.write_string(&title, bench_word(&r))
		}
		for k in 0 ..< 40 {
			if k > 0 {
				strings.write_byte(&body, ' ')
			}
			strings.write_string(&body, bench_word(&r))
		}
		vec: [32]f32
		for &x in vec {
			x = f32(rng_below(&r, 2001) - 1000) / 1000
		}
		values := []Value{{"title", strings.to_string(title)}, {"body", strings.to_string(body)}, {"tag", fmt.tprintf("t%d", rng_below(&r, 50))}, {"year", fmt.tprintf("%d", 1990 + rng_below(&r, 35))}, {"v", string(([^]u8)(&vec)[:128])}}
		add(&ix, fmt.tprintf("doc:%d", i), values)
		free_all(context.temp_allocator)
	}
	build := time.duration_seconds(time.tick_since(start))
	log.infof("indexed %d documents in %.2f s (%.0f documents/s), %d terms, %d records", docs, build, f64(docs) / build, info(&ix).num_terms, info(&ix).num_records)
	qv: [32]f32
	for &x in qv {
		x = f32(rng_below(&r, 2001) - 1000) / 1000
	}
	params := []ftq.Param{{name = "q", value = string(([^]u8)(&qv)[:128])}}
	queries := [?]string{"w3", "w3 w7", "w3 | w7 | w11", "\"w1 w2\"", "w1*", "@tag:{t7} w5", "@year:[2000 2010] w2", "-w1 w9", "*=>[KNN 10 @v $q AS d]", "(@tag:{t3})=>[KNN 10 @v $q AS d]"}
	for q in queries {
		parsed, _ := parse(&ix, q, Query_Options{dialect = 2, params = params})
		rounds := 0
		total := 0
		s := time.tick_now()
		for time.tick_since(s) < 300 * time.Millisecond {
			res, _, _ := execute(&ix, parsed, Execute_Options{limit = 10})
			total = res.total
			result_destroy(&res)
			rounds += 1
		}
		per := time.duration_seconds(time.tick_since(s)) / f64(rounds)
		log.infof("%s: %v matches, %.1f us per query", q, total, per * 1e6)
		ftq.parsed_destroy(parsed)
	}
	cs := time.tick_now()
	for i in 0 ..< docs / 10 {
		remove(&ix, fmt.tprintf("doc:%d", i * 10))
		free_all(context.temp_allocator)
	}
	removed, _ := collect(&ix)
	log.infof("removed and collected %d documents in %.2f s", removed, time.duration_seconds(time.tick_since(cs)))
}
