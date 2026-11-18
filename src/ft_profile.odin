package main

import "base:runtime"
import "core:strings"
import fq "ftquery"

Search_Profile_Iterator :: struct {
	kind, term, query_type: string,
	count: int,
	children: []Search_Profile_Iterator,
}

Search_Profile_Stage :: struct {
	name: string,
	count: int,
	elapsed: f64,
}

Search_Profile :: struct {
	iterator: Search_Profile_Iterator,
	stages: [dynamic]Search_Profile_Stage,
	total, count, vector_count, fused_count: int,
	warn, distance, full, limited, ranged: bool,
}

search_profile_note :: proc(c: ^Conn, query: ^fq.Query, size, matched: int, warning, distance, full: bool) {
	if c.search_profile != nil {
		profile := c.search_profile
		profile.count, profile.total, profile.warn, profile.distance, profile.full = size, matched, warning, distance, full
		profile.iterator = {kind = "EMPTY"}
		if distance {
			profile.iterator = {kind = "VECTOR", count = matched}
		} else if query != nil && query.root != fq.NO_NODE && matched > 0 {
			profile.iterator = search_profile_node(query, query.root, matched, profile.limited)
		}
	}
}

FT_PROFILE_ITERATOR := [fq.Node_Kind]string{
	.Null = "EMPTY", .Token = "TEXT", .Phrase = "INTERSECT", .Union = "UNION", .Intersect = "INTERSECT",
	.Not = "NOT", .Optional = "OPTIONAL", .Prefix = "UNION", .Suffix = "UNION", .Infix = "UNION",
	.Wildcard_Pattern = "UNION", .Fuzzy = "UNION", .Numeric = "NUMERIC", .Geo = "GEO", .Tag = "TAG",
	.Wildcard = "WILDCARD", .Missing = "MISSING", .Vector = "VECTOR", .Geoshape = "GEOSHAPE",
}

search_profile_node :: proc(q: ^fq.Query, id: fq.Node_Id, count: int, limited: bool) -> Search_Profile_Iterator {
	node := fq.node_get(q, id)
	a := context.temp_allocator
	if node.kind == .Tag && len(node.children) == 1 {
		value := fq.node_get(q, node.children[0])
		if value.kind == .Token {
			return {kind = "TAG", term = strings.clone(value.text, a), count = count}
		}
	}
	out := Search_Profile_Iterator{kind = FT_PROFILE_ITERATOR[node.kind], count = count}
	if node.kind == .Token {
		out.term = strings.clone(node.text, a)
	}
	#partial switch node.kind {
	case .Union: out.query_type = "UNION"
	case .Prefix: out.query_type = "PREFIX"
	case .Suffix, .Infix: out.query_type = "CONTAINS"
	case .Fuzzy: out.query_type = "FUZZY"
	case .Wildcard_Pattern: out.query_type = "WILDCARD"
	}
	if len(node.children) > 0 && !(limited && out.kind == "UNION") {
		out.children = make([]Search_Profile_Iterator, len(node.children), a)
		for child, i in node.children {
			out.children[i] = search_profile_node(q, child, count, limited)
		}
	}
	return out
}

cmd_ft_profile :: proc(c: ^Conn, argv: [][]u8) {
	search := eq_nocase(argv[2], "search")
	aggregate := eq_nocase(argv[2], "aggregate")
	hybrid := eq_nocase(argv[2], "hybrid")
	if !search && !aggregate && !hybrid {
		reply_error(c, "No `SEARCH`, `AGGREGATE`, or `HYBRID` provided")
		return
	}
	at := 3
	limited := eq_nocase(argv[at], "limited")
	if limited {
		at += 1
	}
	if at >= len(argv) || !eq_nocase(argv[at], "query") {
		reply_error(c, "The QUERY keyword is expected")
		return
	}
	at += 1
	if at >= len(argv) {
		reply_error(c, "ERR wrong number of arguments for 'FT.PROFILE' command")
		return
	}
	if search_query_index(c, string(argv[1]), search_scope()) == nil {
		return
	}
	profile := Search_Profile{iterator = {kind = "EMPTY"}, limited = limited}
	fake := Conn{fd = -1, db = c.db, user = c.user, resp = c.resp, search_profile = &profile}
	defer runtime.heap_free(fake.wbuf)
	args := make([dynamic][]u8, context.temp_allocator)
	command := "FT.SEARCH" if search else ("FT.AGGREGATE" if aggregate else "FT.HYBRID")
	append(&args, transmute([]u8)command, argv[1])
	append(&args, ..argv[at:])
	started := mono_posix_ns()
	if search {
		cmd_ft_search(&fake, args[:])
	} else if aggregate {
		cmd_ft_aggregate(&fake, args[:])
	} else if len(args) < 7 {
		reply_error(&fake, "SEARCH_SYNTAX Invalid subqueries count: expected an unsigned integer")
	} else {
		cmd_ft_hybrid(&fake, args[:])
	}
	if fake.wlen == 0 {
		reply_error(c, "ERR profile reply unavailable")
		return
	}
	payload := fake.wbuf[:fake.wlen]
	if payload[0] == '-' || hybrid {
		reply_raw(c, payload)
		return
	}
	if c.resp >= RESP3 {
		reply_map(c, 2)
		reply_simple(c, "Results")
	} else {
		reply_array(c, 2)
	}
	reply_raw(c, payload)
	if c.resp >= RESP3 {
		reply_simple(c, "Profile")
	}
	reply_map(c, 2)
	reply_simple(c, "Shards")
	reply_array(c, 1)
	search_profile_shard(c, &profile, search, search_profile_elapsed(started))
	reply_simple(c, "Coordinator")
	reply_map(c, 0)
}

search_profile_hybrid :: proc(c: ^Conn, p: ^Search_Profile, elapsed: f64, ordered: bool) {
	reply_map(c, 2)
	reply_simple(c, "Shards")
	reply_array(c, 1)
	reply_map(c, 2)
	reply_simple(c, "SEARCH")
	text := p^
	text.full, text.stages = true, nil
	search_profile_shard(c, &text, true, 0)
	reply_simple(c, "VSIM")
	vector := Search_Profile{
		iterator = {kind = "VECTOR", count = p.vector_count},
		total = p.vector_count, count = p.vector_count, distance = true, full = true,
		ranged = p.ranged,
	}
	vector.stages = make([dynamic]Search_Profile_Stage, context.temp_allocator)
	append(&vector.stages, Search_Profile_Stage{name = "Vector Normalizer", count = vector.count})
	search_profile_shard(c, &vector, false, 0)
	reply_simple(c, "Coordinator")
	reply_map(c, 7)
	search_profile_header(c, elapsed, p.warn)
	reply_simple(c, "Result processors profile")
	reply_array(c, 1 + int(ordered) + len(p.stages))
	search_profile_processor(c, "Hybrid Merger", p.fused_count)
	if ordered {
		search_profile_processor(c, "Sorter", p.fused_count)
	}
	for stage in p.stages {
		search_profile_processor(c, stage.name, stage.count, stage.elapsed)
	}
}

search_profile_header :: proc(c: ^Conn, elapsed: f64, warning: bool) {
	search_profile_measure(c, "Total profile time", elapsed)
	search_profile_measure(c, "Parsing time", 0)
	search_profile_measure(c, "Workers queue time", 0)
	search_profile_measure(c, "Pipeline creation time", 0)
	search_profile_measure(c, "Total GIL time", 0)
	reply_simple(c, "Warning")
	reply_array(c, 1)
	reply_simple(c, "Max prefix expansions limit was reached" if warning else "None")
}

search_profile_shard :: proc(c: ^Conn, p: ^Search_Profile, search: bool, elapsed: f64) {
	reply_map(c, 8)
	search_profile_header(c, elapsed, p.warn)
	reply_simple(c, "Iterators profile")
	search_profile_iterator(c, &p.iterator, p.ranged)
	reply_simple(c, "Result processors profile")
	loaded := search && p.full
	reply_array(c, 1 + int(search) * 2 + int(p.distance) + int(loaded) + len(p.stages) +
		int(p.distance && p.full))
	search_profile_processor(c, "Index", p.total)
	if p.distance {
		search_profile_processor(c, "Metrics Applier", p.total)
	}
	if search {
		search_profile_processor(c, "Scorer", p.total)
		search_profile_processor(c, "Sorter", p.count)
	}
	for stage in p.stages {
		search_profile_processor(c, stage.name, stage.count, stage.elapsed)
	}
	if loaded || (p.distance && p.full) {
		search_profile_processor(c, "Threadsafe-Loader", p.count)
	}
}

search_profile_iterator :: proc(c: ^Conn, node: ^Search_Profile_Iterator, ranged: bool) {
	sub := len(node.children) > 0
	term := node.term != ""
	vt := node.kind == "VECTOR"
	reply_map(c, 3 + 2 * int(term) + int(vt) + int(sub) + int(node.query_type != ""))
	reply_simple(c, "Type")
	reply_simple(c, node.kind)
	if term {
		reply_simple(c, "Term")
		reply_bulk_str(c, node.term)
	}
	if node.query_type != "" {
		reply_simple(c, "Query type")
		reply_simple(c, node.query_type)
	}
	search_profile_measure(c, "Time", 0)
	reply_simple(c, "Number of reading operations")
	reply_int(c, i64(node.count))
	if term {
		reply_simple(c, "Estimated number of matches")
		reply_int(c, i64(node.count))
	}
	if vt {
		reply_simple(c, "Vector search mode")
		reply_simple(c, "RANGE_QUERY" if ranged else "STANDARD_KNN")
	}
	if sub {
		single := len(node.children) == 1 && (node.kind == "NOT" || node.kind == "OPTIONAL")
		reply_simple(c, "Child iterator" if single else "Child iterators")
		if !single {
			reply_array(c, len(node.children))
		}
		for &child in node.children {
			search_profile_iterator(c, &child, false)
		}
	}
}

search_profile_stage :: proc(p: ^Search_Profile, step: ^FT_Pipeline_Step, count: int, started: u64) {
	name: string
	switch step.kind {
	case .Load: name = "Threadsafe-Loader"
	case .Apply: name = "Projector"
	case .Filter: name = "Filter"
	case .Group: name = "Grouper"
	case .Sort: name = "Sorter"
	case .Limit: name = "Pager"
	}
	append(&p.stages, Search_Profile_Stage{name, count, search_profile_elapsed(started)})
}

search_profile_elapsed :: proc(started: u64) -> f64 {
	return f64(mono_posix_ns() - started) / 1e6 if !labels_on || access.top else 0
}

search_profile_measure :: proc(c: ^Conn, name: string, value: f64) {
	reply_simple(c, name)
	reply_double(c, value)
}

search_profile_processor :: proc(c: ^Conn, name: string, count: int, elapsed := 0.0) {
	reply_map(c, 3 + int(name == "Threadsafe-Loader"))
	reply_simple(c, "Type")
	reply_simple(c, name)
	if name == "Threadsafe-Loader" {
		search_profile_measure(c, "GIL-Time", 0)
	}
	search_profile_measure(c, "Time", elapsed)
	reply_simple(c, "Results processed")
	reply_int(c, i64(count))
}
