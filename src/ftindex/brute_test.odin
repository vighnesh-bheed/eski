package ftindex

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:testing"
import ftq "../ftquery"
import "../bm25std"

BRUTE_WORDS := [?]string{"ant", "bee", "cat", "dog", "elk", "fox", "gnu", "hen", "ape", "bat"}

BRUTE_TAGS := [?]string{"red", "blue", "green", "light blue"}

Brute_Version :: struct {
	key:       string,
	t:         []string,
	u:         []string,
	tags:      []string,
	number:    f64,
	numbered:  bool,
	live:      bool,
	collected: bool,
}

Brute :: struct {
	versions: [dynamic]Brute_Version,
}

brute_live :: proc(m: ^Brute) -> (n: int, total: u64) {
	for v in m.versions {
		if v.live {
			n += 1
			total += u64(len(v.t) + 2 * len(v.u))
		}
	}
	return
}

brute_term_count :: proc(m: ^Brute, term: string) -> u64 {
	n := u64(0)
	for v in m.versions {
		if !v.collected && (slice.contains(v.t, term) || slice.contains(v.u, term)) {
			n += 1
		}
	}
	return n
}

brute_tag_count :: proc(m: ^Brute, tag: string) -> u64 {
	n := u64(0)
	for v in m.versions {
		if !v.collected && slice.contains(v.tags, tag) {
			n += 1
		}
	}
	return n
}

Brute_Ctx :: struct {
	m:     ^Brute,
	q:     ^ftq.Query,
	docs:  int,
	avg:   f64,
	terms: []string,
}

brute_bm25 :: proc(ctx: ^Brute_Ctx, weight: f64, idf: f64, f: u32, dl: u32) -> f64 {
	p := bm25std.Params{k1 = bm25std.K1, b = bm25std.B, documents = u64(ctx.docs), average_length = ctx.avg}
	return bm25std.contribution(&p, weight, idf, f, dl)
}

brute_in_mask :: proc(v: ^Brute_Version, term: string, mask: ftq.Field_Mask) -> bool {
	if mask & 1 != 0 && slice.contains(v.t, term) {
		return true
	}
	return mask & 2 != 0 && slice.contains(v.u, term)
}

brute_frequency :: proc(v: ^Brute_Version, term: string) -> u32 {
	f := u32(0)
	for w in v.t {
		if w == term {
			f += 1
		}
	}
	for w in v.u {
		if w == term {
			f += 2
		}
	}
	return f
}

brute_length :: proc(v: ^Brute_Version) -> u32 {
	return u32(len(v.t) + 2 * len(v.u))
}

brute_term :: proc(ctx: ^Brute_Ctx, v: ^Brute_Version, term: string, mask: ftq.Field_Mask, weight: f64) -> (bool, f64) {
	if !brute_in_mask(v, term, mask) {
		return false, 0
	}
	n := brute_term_count(ctx.m, term)
	idf := bm25std.idf(u64(ctx.docs), n)
	return true, brute_bm25(ctx, weight, idf, brute_frequency(v, term), brute_length(v))
}

brute_positions :: proc(v: ^Brute_Version, term: string) -> [dynamic]u32 {
	out := make([dynamic]u32, context.temp_allocator)
	for w, i in v.t {
		if w == term {
			append(&out, u32(i + 1))
		}
	}
	for w, i in v.u {
		if w == term {
			append(&out, u32(len(v.t) + i + 1))
		}
	}
	return out
}

brute_eval :: proc(ctx: ^Brute_Ctx, v: ^Brute_Version, id: ftq.Node_Id) -> (bool, f64) {
	n := ftq.node_get(ctx.q, id)
	#partial switch n.kind {
	case .Null:
		return false, 0
	case .Token:
		return brute_term(ctx, v, n.text, n.mask, n.weight)
	case .Phrase:
		total := 0.0
		lists := make([dynamic][dynamic]u32, context.temp_allocator)
		for child in n.children {
			c := ftq.node_get(ctx.q, child)
			ok, s := brute_term(ctx, v, c.text, c.mask, c.weight)
			if !ok {
				return false, 0
			}
			total += s
			append(&lists, brute_positions(v, c.text))
		}
		for first in lists[0] {
			prev := first
			good := true
			for k in 1 ..< len(lists) {
				found := false
				for x in lists[k] {
					if x >= prev {
						prev = x
						found = true
						break
					}
				}
				if !found {
					good = false
					break
				}
			}
			if good && i64(prev) - i64(first) - i64(len(lists) - 1) <= 0 {
				return true, total
			}
		}
		return false, 0
	case .Union:
		hit := false
		total := 0.0
		for child in n.children {
			ok, s := brute_eval(ctx, v, child)
			if ok {
				hit = true
				total += s
			}
		}
		return hit, total
	case .Intersect:
		total := 0.0
		for child in n.children {
			c := ftq.node_get(ctx.q, child)
			#partial switch c.kind {
			case .Not:
				if ok, _ := brute_eval(ctx, v, c.children[0]); ok {
					return false, 0
				}
			case .Optional:
				if ok, s := brute_eval(ctx, v, c.children[0]); ok {
					total += s
				}
			case:
				ok, s := brute_eval(ctx, v, child)
				if !ok {
					return false, 0
				}
				total += s
			}
		}
		return true, total
	case .Not:
		ok, _ := brute_eval(ctx, v, n.children[0])
		return !ok, 0
	case .Optional:
		ok, s := brute_eval(ctx, v, n.children[0])
		return true, s if ok else 0
	case .Prefix:
		for term in ctx.terms {
			if strings.has_prefix(term, n.text) && len(n.text) >= 2 {
				if ok, s := brute_term(ctx, v, term, n.mask, 1); ok {
					return true, s
				}
			}
		}
		return false, 0
	case .Tag:
		hit := false
		total := 0.0
		for child in n.children {
			value := brute_tag_text(ctx.q, child)
			if slice.contains(v.tags, value) {
				hit = true
				idf := bm25std.idf(u64(ctx.docs), brute_tag_count(ctx.m, value))
				total += brute_bm25(ctx, 1, idf, 1, brute_length(v))
			}
		}
		return hit, total
	case .Numeric:
		if !v.numbered {
			return false, 0
		}
		x := v.number
		lo := x > n.min || (!n.min_open && x == n.min)
		hi := x < n.max || (!n.max_open && x == n.max)
		return lo && hi, 0
	case .Wildcard:
		return true, brute_bm25(ctx, 1, 1, 1, brute_length(v))
	}
	return false, 0
}

brute_tag_text :: proc(q: ^ftq.Query, id: ftq.Node_Id) -> string {
	n := ftq.node_get(q, id)
	if n.kind != .Intersect {
		return n.text
	}
	parts := make([dynamic]string, context.temp_allocator)
	for child in n.children {
		append(&parts, brute_tag_text(q, child))
	}
	return strings.join(parts[:], " ", context.temp_allocator)
}

brute_word :: proc(r: ^Rng) -> string {
	return BRUTE_WORDS[rng_below(r, len(BRUTE_WORDS))]
}

brute_query :: proc(r: ^Rng, sb: ^strings.Builder, depth: int) {
	pick := rng_below(r, 12 if depth > 0 else 8)
	switch pick {
	case 0, 1:
		strings.write_string(sb, brute_word(r))
	case 2:
		fields := [?]string{"@t:", "@u:", "@t|u:"}
		strings.write_string(sb, fields[rng_below(r, 3)])
		strings.write_string(sb, brute_word(r))
	case 3:
		fmt.sbprintf(sb, "\"%s %s\"", brute_word(r), brute_word(r))
	case 4:
		w := brute_word(r)
		fmt.sbprintf(sb, "%s*", w[:2])
	case 5:
		a := BRUTE_TAGS[rng_below(r, len(BRUTE_TAGS))]
		b := BRUTE_TAGS[rng_below(r, len(BRUTE_TAGS))]
		if rng_below(r, 2) == 0 {
			fmt.sbprintf(sb, "@g:{%s}", a)
		} else {
			fmt.sbprintf(sb, "@g:{%s | %s}", a, b)
		}
	case 6:
		lo := rng_below(r, 6)
		fmt.sbprintf(sb, "@n:[%s%d %s%d]", "(" if rng_below(r, 3) == 0 else "", lo, "(" if rng_below(r, 3) == 0 else "", lo + rng_below(r, 4))
	case 7:
		fmt.sbprintf(sb, "%s=>{$weight: %d}", brute_word(r), 1 + rng_below(r, 3))
	case 8:
		strings.write_string(sb, "-")
		brute_query(r, sb, depth - 1)
	case 9:
		strings.write_string(sb, "~")
		brute_query(r, sb, depth - 1)
	case 10, 11:
		strings.write_byte(sb, '(')
		parts := 2 + rng_below(r, 2)
		or := pick == 11
		for i in 0 ..< parts {
			if i > 0 {
				strings.write_string(sb, " | " if or else " ")
			}
			brute_query(r, sb, depth - 1)
		}
		strings.write_byte(sb, ')')
	}
}

brute_doc :: proc(r: ^Rng, key: string) -> (v: Brute_Version, values: [dynamic]Value) {
	v.key = key
	values = make([dynamic]Value, context.allocator)
	words :: proc(r: ^Rng) -> []string {
		n := rng_below(r, 5)
		out := make([]string, n)
		for i in 0 ..< n {
			out[i] = brute_word(r)
		}
		return out
	}
	v.t = words(r)
	v.u = words(r)
	if len(v.t) > 0 || rng_below(r, 2) == 0 {
		append(&values, Value{"t", strings.join(v.t, " ")})
	}
	if len(v.u) > 0 {
		append(&values, Value{"u", strings.join(v.u, " ")})
	}
	tags := make([dynamic]string)
	for _ in 0 ..< rng_below(r, 3) {
		tg := BRUTE_TAGS[rng_below(r, len(BRUTE_TAGS))]
		if !slice.contains(tags[:], tg) {
			append(&tags, tg)
		}
	}
	v.tags = tags[:]
	if len(tags) > 0 {
		append(&values, Value{"g", strings.join(tags[:], ",")})
	}
	if rng_below(r, 4) != 0 {
		v.numbered = true
		v.number = f64(rng_below(r, 8))
		append(&values, Value{"n", fmt.aprintf("%d", int(v.number))})
	}
	v.live = true
	return
}

brute_free :: proc(m: ^Brute, values: ^[dynamic][dynamic]Value) {
	for v in m.versions {
		delete(v.t)
		delete(v.u)
		delete(v.tags)
	}
	delete(m.versions)
	for vals in values {
		for x in vals {
			delete(x.value)
		}
		delete(vals)
	}
	delete(values^)
}

@(test)
executor_agrees_with_a_brute_force_evaluator :: proc(t: ^testing.T) {
	r := Rng{0xB2_57E}
	checked := 0
	for round in 0 ..< 30 {
		fields := [?]Field {
			{name = "t", source = "t", kind = .Text, weight = 1, separator = ','},
			{name = "u", source = "u", kind = .Text, weight = 2, separator = ','},
			{name = "g", source = "g", kind = .Tag, weight = 1, separator = ','},
			{name = "n", source = "n", kind = .Numeric, weight = 1, separator = ','},
		}
		ix: Index
		def := definition_default(fields[:])
		def.stop_mode = .None
		testing.expect_value(t, init(&ix, def), Error.None)
		m: Brute
		kept := make([dynamic][dynamic]Value)
		keys := [?]string{"k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7", "k8", "k9", "k10", "k11"}
		for _ in 0 ..< 40 {
			key := keys[rng_below(&r, len(keys))]
			op := rng_below(&r, 10)
			if op < 7 {
				v, values := brute_doc(&r, key)
				for &old in m.versions {
					if old.key == key && old.live {
						old.live = false
					}
				}
				append(&m.versions, v)
				append(&kept, values)
				res, e := add(&ix, key, values[:])
				testing.expect(t, e == .None && res.outcome == .Indexed)
			} else if op < 9 {
				for &old in m.versions {
					if old.key == key && old.live {
						old.live = false
					}
				}
				remove(&ix, key)
			} else {
				collect(&ix)
				for &old in m.versions {
					if !old.live {
						old.collected = true
					}
				}
			}
		}
		docs, total := brute_live(&m)
		terms := make([dynamic]string, context.temp_allocator)
		for v in m.versions {
			if v.collected {
				continue
			}
			for w in v.t {
				if !slice.contains(terms[:], w) {
					append(&terms, w)
				}
			}
			for w in v.u {
				if !slice.contains(terms[:], w) {
					append(&terms, w)
				}
			}
		}
		slice.sort(terms[:])
		for _ in 0 ..< 80 {
			sb := strings.builder_make(context.temp_allocator)
			brute_query(&r, &sb, 3)
			query := strings.to_string(sb)
			parsed, perr := parse(&ix, query, Query_Options{dialect = 2, verbatim = true})
			if perr.code != .None {
				ftq.parsed_destroy(parsed)
				continue
			}
			res, err, _ := execute(&ix, parsed, {})
			if !testing.expectf(t, err == .None, "%s: %v", query, err) {
				ftq.parsed_destroy(parsed)
				result_destroy(&res)
				continue
			}
			ctx := Brute_Ctx{m = &m, q = &parsed.query, docs = docs, avg = f64(total) / f64(docs) if docs > 0 else 0, terms = terms[:]}
			want := make(map[string]f64, 16, context.temp_allocator)
			if parsed.query.root != ftq.NO_NODE {
				for &v in m.versions {
					if !v.live {
						continue
					}
					if ok, s := brute_eval(&ctx, &v, parsed.query.root); ok {
						want[v.key] = s
					}
				}
			}
			testing.expectf(t, res.total == len(want), "round %d %s: %d matches, brute force %d", round, query, res.total, len(want))
			for h in res.hits {
				k := doc_key(&ix, h.doc)
				s, ok := want[k]
				if !testing.expectf(t, ok, "round %d %s: unexpected %s", round, query, k) {
					continue
				}
				close := s == h.score || math.abs(s - h.score) <= 1e-9 * max(math.abs(s), 1e-300)
				testing.expectf(t, close, "round %d %s: %s scored %.17g, brute force %.17g", round, query, k, h.score, s)
				checked += 1
			}
			ftq.parsed_destroy(parsed)
			result_destroy(&res)
		}
		destroy(&ix)
		brute_free(&m, &kept)
		free_all(context.temp_allocator)
	}
	testing.expectf(t, checked > 1000, "only %d hits compared", checked)
}
