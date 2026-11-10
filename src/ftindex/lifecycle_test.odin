package ftindex

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import ftq "../ftquery"
import "../label"

run_query :: proc(t: ^testing.T, ix: ^Index, query: string, opts: Execute_Options = {}, dialect := 2) -> Result {
	parsed, perr := parse(ix, query, Query_Options{dialect = dialect, verbatim = true})
	defer ftq.parsed_destroy(parsed)
	testing.expectf(t, perr.code == .None, "%s: %v", query, perr)
	res, err, _ := execute(ix, parsed, opts)
	testing.expectf(t, err == .None, "%s: %v", query, err)
	return res
}

check_gc_stage :: proc(t: ^testing.T, ix: ^Index, file: string, stage: string) {
	checked := 0
	for p in GC_PROBES {
		if p.file != file || p.stage != stage {
			continue
		}
		res := run_query(t, ix, p.query)
		defer result_destroy(&res)
		testing.expectf(t, res.total == p.total, "%s %s: total %d, want %d", stage, p.query, res.total, p.total)
		for k, i in p.keys {
			if i >= len(res.hits) {
				break
			}
			h := res.hits[i]
			testing.expectf(t, doc_key(ix, h.doc) == k, "%s %s rank %d: %s, want %s", stage, p.query, i, doc_key(ix, h.doc), k)
			if i < len(p.scores) {
				want, _ := strconv.parse_f64(p.scores[i])
				testing.expectf(t, h.score == want, "%s %s rank %d: %.17g, want %s", stage, p.query, i, h.score, p.scores[i])
			}
		}
		checked += 1
	}
	testing.expectf(t, checked > 0, "no probes for %s %s", file, stage)
}

@(test)
collection_follows_the_recorded_lifecycle :: proc(t: ^testing.T) {
	fields := [?]Field{{name = "t", source = "t", kind = .Text, weight = 1, separator = ','}, {name = "g", source = "g", kind = .Tag, weight = 1, separator = ','}}
	ix: Index
	testing.expect_value(t, init(&ix, definition_default(fields[:])), Error.None)
	defer destroy(&ix)
	for i in 0 ..< 5 {
		add(&ix, fmt.tprintf("gc:%d", i + 1), []Value{{"t", "same words here"}, {"g", "x" if i % 2 == 0 else "y"}})
	}
	add(&ix, "gc:6", []Value{{"t", "lonely"}, {"g", "z"}})
	check_gc_stage(t, &ix, "probe1.json", "initial")
	add(&ix, "gc:1", []Value{{"t", "same words here again"}, {"g", "x"}})
	check_gc_stage(t, &ix, "probe1.json", "after rewriting gc:1")
	remove(&ix, "gc:2")
	remove(&ix, "gc:6")
	check_gc_stage(t, &ix, "probe1.json", "after DEL gc:2 and gc:6")
	check_gc_stage(t, &ix, "probe2.json", "before collection")
	before := info(&ix)
	removed, err := collect(&ix)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, removed, 3)
	check_gc_stage(t, &ix, "probe2.json", "after collection")
	after := info(&ix)
	testing.expect_value(t, before.num_terms, 7)
	testing.expect_value(t, after.num_terms, 5)
	testing.expect_value(t, after.num_docs, 4)
	testing.expect_value(t, after.max_doc_id, 7)
	testing.expect(t, after.num_records < before.num_records)
	again, _ := collect(&ix)
	testing.expect_value(t, again, 0)
	check_gc_stage(t, &ix, "probe2.json", "after collection")
	free_all(context.temp_allocator)
}

Labelled_Index :: struct {
	table:  label.Table,
	open:   label.Id,
	secret: label.Id,
	reader: label.Visibility,
}

labelled_setup :: proc(l: ^Labelled_Index) {
	label.table_init(&l.table)
	low, _ := label.label_make(0)
	high, _ := label.label_make(2, 3)
	l.open, _ = label.table_intern(&l.table, low)
	l.secret, _ = label.table_intern(&l.table, high)
	label.visibility_build(&l.reader, &l.table, low)
}

labelled_teardown :: proc(l: ^Labelled_Index) {
	label.visibility_destroy(&l.reader)
	label.table_destroy(&l.table)
}

label_fields :: proc() -> [4]Field {
	return [4]Field {
		{name = "t", source = "t", kind = .Text, weight = 1, separator = ','},
		{name = "g", source = "g", kind = .Tag, weight = 1, separator = ','},
		{name = "n", source = "n", kind = .Numeric, weight = 1, separator = ','},
		{name = "v", source = "v", kind = .Vector, weight = 1, separator = ',', vector = {method = .Flat, elem = .F32, metric = .L2, dim = 2}},
	}
}

@(test)
reader_visibility_matches_an_index_of_the_visible_documents :: proc(t: ^testing.T) {
	l: Labelled_Index
	labelled_setup(&l)
	defer labelled_teardown(&l)
	fields := label_fields()
	both, open_only: Index
	testing.expect_value(t, init(&both, definition_default(fields[:]), test_factory), Error.None)
	testing.expect_value(t, init(&open_only, definition_default(fields[:]), test_factory), Error.None)
	defer destroy(&both)
	defer destroy(&open_only)
	r := Rng{0x1ABE1}
	words := [?]string{"alpha", "beta", "gamma", "delta", "abacus", "abbey", "abyss"}
	tags := [?]string{"red", "blue", "green"}
	for i in 0 ..< 120 {
		sb := strings.builder_make(context.temp_allocator)
		for k in 0 ..< 1 + rng_below(&r, 5) {
			if k > 0 {
				strings.write_byte(&sb, ' ')
			}
			strings.write_string(&sb, words[rng_below(&r, len(words))])
		}
		vec := [2]f32{f32(rng_below(&r, 100)) / 10, f32(rng_below(&r, 100)) / 10}
		values := []Value{{"t", strings.to_string(sb)}, {"g", tags[rng_below(&r, len(tags))]}, {"n", fmt.tprintf("%d", rng_below(&r, 10))}, {"v", string(([^]u8)(&vec)[:8])}}
		key := fmt.tprintf("d%d", i)
		hidden := rng_below(&r, 3) == 0
		if hidden && i % 2 == 0 {
			values[0].value = fmt.tprintf("%s zzhidden", values[0].value)
			values[1].value = "purple"
		}
		add(&both, key, values, l.secret if hidden else l.open)
		if !hidden {
			add(&open_only, key, values)
		}
		if i % 17 == 16 {
			old := fmt.tprintf("d%d", i - 9)
			remove(&both, old)
			remove(&open_only, old)
		}
	}
	q := [2]f32{5, 5}
	params := []ftq.Param{{name = "q", value = string(([^]u8)(&q)[:8])}}
	queries := [?]string{"alpha", "alpha beta", "alpha | gamma", "ab*", "@g:{red}", "@g:{red|blue} beta", "-alpha", "~beta gamma", "*", "@n:[2 5] delta", "\"alpha beta\"", "*=>[KNN 7 @v $q AS d]", "(beta)=>[KNN 5 @v $q AS d]", "@v:[VECTOR_RANGE 4 $q]=>{$YIELD_DISTANCE_AS: d} alpha", "(alpha | zzhidden) => {$weight: 3}", "@g:{red|purple} => {$weight: 2}", "(beta | zz*) => {$weight: 4}"}
	for query in queries {
		p1, e1 := parse(&both, query, Query_Options{dialect = 2, verbatim = true, params = params})
		p2, e2 := parse(&open_only, query, Query_Options{dialect = 2, verbatim = true, params = params})
		testing.expect(t, e1.code == .None && e2.code == .None)
		a, ea, _ := execute(&both, p1, Execute_Options{visibility = &l.reader})
		b, eb, _ := execute(&open_only, p2, {})
		testing.expect(t, ea == .None && eb == .None)
		testing.expectf(t, a.total == b.total, "%s: %d visible matches, %d in the open index", query, a.total, b.total)
		got := make(map[string]f64, 64, context.temp_allocator)
		for h in a.hits {
			got[doc_key(&both, h.doc)] = h.score
		}
		for h in b.hits {
			k := doc_key(&open_only, h.doc)
			s, ok := got[k]
			if !testing.expectf(t, ok, "%s: %s missing under visibility", query, k) {
				continue
			}
			testing.expectf(t, s == h.score || math.abs(s - h.score) <= 1e-12 * math.abs(h.score), "%s: %s scored %.17g, open index %.17g", query, k, s, h.score)
		}
		for h in a.hits {
			testing.expectf(t, visible_doc(&both, &l.reader, h.doc), "%s: hidden %s returned", query, doc_key(&both, h.doc))
		}
		result_destroy(&a)
		result_destroy(&b)
		ftq.parsed_destroy(p1)
		ftq.parsed_destroy(p2)
		free_all(context.temp_allocator)
	}
}

@(test)
hidden_terms_do_not_crowd_visible_expansions_or_tag_values :: proc(t: ^testing.T) {
	l: Labelled_Index
	labelled_setup(&l)
	defer labelled_teardown(&l)
	fields := label_fields()
	ix: Index
	testing.expect_value(t, init(&ix, definition_default(fields[:]), test_factory), Error.None)
	defer destroy(&ix)
	for i in 0 ..< 250 {
		add(&ix, fmt.tprintf("h%d", i), []Value{{"t", fmt.tprintf("ab%03d", i)}, {"g", fmt.tprintf("ab%03d", i)}}, l.secret)
	}
	add(&ix, "seen", []Value{{"t", "abzzz"}, {"g", "abzzz"}}, l.open)
	off := run_query(t, &ix, "ab*")
	testing.expect_value(t, off.total, 200)
	testing.expect(t, off.truncated)
	result_destroy(&off)
	on := run_query(t, &ix, "ab*", Execute_Options{visibility = &l.reader})
	testing.expect_value(t, on.total, 1)
	testing.expect(t, !on.truncated)
	if len(on.hits) == 1 {
		testing.expect_value(t, doc_key(&ix, on.hits[0].doc), "seen")
	}
	result_destroy(&on)
	tag := run_query(t, &ix, "@g:{ab*}", Execute_Options{visibility = &l.reader})
	testing.expect_value(t, tag.total, 1)
	result_destroy(&tag)
	tag_off := run_query(t, &ix, "@g:{ab*}")
	testing.expect_value(t, tag_off.total, 200)
	result_destroy(&tag_off)
	values := make([dynamic]string, context.temp_allocator)
	tag_values(&ix, 1, &values, &l.reader)
	testing.expect(t, slice.equal(values[:], []string{"abzzz"}))
	free_all(context.temp_allocator)
}

@(test)
hnsw_source_agrees_with_an_exact_scan :: proc(t: ^testing.T) {
	fields := [?]Field {
		{name = "h", source = "h", kind = .Vector, weight = 1, separator = ',', vector = {method = .Hnsw, elem = .F32, metric = .Cosine, dim = 8, m = 16, ef_construction = 200, ef_runtime = 200}},
		{name = "f", source = "f", kind = .Vector, weight = 1, separator = ',', vector = {method = .Flat, elem = .F32, metric = .Cosine, dim = 8}},
		{name = "g", source = "g", kind = .Tag, weight = 1, separator = ','},
	}
	ix: Index
	testing.expect_value(t, init(&ix, definition_default(fields[:]), test_factory), Error.None)
	defer destroy(&ix)
	r := Rng{0x45_4E5}
	for i in 0 ..< 400 {
		vec: [8]f32
		for &x in vec {
			x = f32(rng_below(&r, 2001) - 1000) / 1000
		}
		blob := string(([^]u8)(&vec)[:32])
		add(&ix, fmt.tprintf("v%d", i), []Value{{"h", blob}, {"f", blob}, {"g", "even" if i % 2 == 0 else "odd"}})
		if i % 13 == 12 {
			remove(&ix, fmt.tprintf("v%d", i - 5))
		}
	}
	found, total := 0, 0
	for round in 0 ..< 40 {
		qv: [8]f32
		for &x in qv {
			x = f32(rng_below(&r, 2001) - 1000) / 1000
		}
		params := []ftq.Param{{name = "q", value = string(([^]u8)(&qv)[:32])}}
		for form in ([?]string{"*=>[KNN 10 @%s $q AS d]", "(@g:{odd})=>[KNN 10 @%s $q AS d]", "(@g:{odd})=>[KNN 10 @%s $q HYBRID_POLICY ADHOC_BF AS d]", "@%s:[VECTOR_RANGE 0.6 $q]=>{$YIELD_DISTANCE_AS: d}"}) {
			if strings.contains(form, "ADHOC") && round % 2 == 0 {
				continue
			}
			hq := strings.clone(fmt.tprintf(form, "h"), context.temp_allocator)
			fq := strings.clone(fmt.tprintf(form, "f"), context.temp_allocator)
			ph, _ := parse(&ix, hq, Query_Options{dialect = 2, params = params})
			pf, _ := parse(&ix, fq, Query_Options{dialect = 2, params = params})
			a, _, _ := execute(&ix, ph, {})
			b, _, _ := execute(&ix, pf, {})
			exact := make(map[u32]f64, 16, context.temp_allocator)
			for h in b.hits {
				d, _ := hit_distance(&ix, &b, "d", h.doc)
				exact[h.doc] = d
			}
			for h in a.hits {
				d, _ := hit_distance(&ix, &a, "d", h.doc)
				if want, ok := exact[h.doc]; ok {
					found += 1
					testing.expectf(t, d == want, "%s: distance %v, exact %v", hq, d, want)
				}
			}
			total += len(b.hits)
			if strings.contains(form, "ADHOC") || strings.contains(form, "RANGE") {
				testing.expectf(t, a.total == b.total, "%s: %d hits, exact %d", hq, a.total, b.total)
			}
			result_destroy(&a)
			result_destroy(&b)
			ftq.parsed_destroy(ph)
			ftq.parsed_destroy(pf)
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, f64(found) >= 0.98 * f64(total), "recall %d of %d", found, total)
}
