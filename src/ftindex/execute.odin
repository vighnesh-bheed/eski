package ftindex

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import ftq "../ftquery"
import "../bm25std"
import "../doctable"
import "../label"
import "../numindex"
import "../postings"
import "../prefix"
import "../retrieve"
import "../roaring"
import "../tagindex"
import "../termdict"
import "../termstats"
import "../text"

Matcher_Kind :: enum u8 {
	Prefix,
	Suffix,
	Infix,
	Wildcard,
	Fuzzy_1,
	Fuzzy_2,
	Fuzzy_3,
}

Matchers :: [Matcher_Kind]^termdict.Matcher

Execute_Options :: struct {
	scorer:        ^retrieve.Scorer,
	slop:          Maybe(int),
	in_order:      bool,
	limit:         Maybe(int),
	visibility:    ^label.Visibility,
	unscored_tags: bool,
	matchers:      ^Matchers,
	expansions:    Maybe(int),
}

Hit :: struct {
	doc:      u32,
	score:    f64,
	distance: f64,
}

Yield :: struct {
	alias: string,
	field: int,
	hits:  []Vector_Hit,
}

Result :: struct {
	hits:      [dynamic]Hit,
	total:     int,
	knn:       bool,
	knn_field: int,
	knn_alias: string,
	yields:    [dynamic]Yield,
	truncated: bool,
	arena:     mem.Dynamic_Arena,
	allocator: runtime.Allocator,
}

result_destroy :: proc(r: ^Result) {
	delete(r.hits)
	delete(r.yields)
	mem.dynamic_arena_destroy(&r.arena)
	r^ = {}
}

Built :: struct {
	cursor:     ^retrieve.Cursor,
	positional: bool,
}

NONE_BUILT :: Built{}

Builder :: struct {
	ix:        ^Index,
	q:         ^ftq.Query,
	parsed:    ^ftq.Parsed,
	opts:      ^Execute_Options,
	scorer:    ^retrieve.Scorer,
	a:         mem.Allocator,
	deleted:   ^roaring.Bitmap,
	err:       Error,
	query_err: ftq.Error,
	result:    ^Result,
	knn:       ^Knn_Cursor,
	slop:      int,
	limit:     int,
	expand:    int,
}

fail :: proc(b: ^Builder, e: Error) {
	if b.err == .None {
		b.err = e
	}
}

mask_fields :: proc "contextless" (mask: ftq.Field_Mask) -> postings.Fields {
	if mask == ftq.ALL_FIELDS {
		return 0
	}
	return postings.Fields(mask)
}

term_count :: proc(b: ^Builder, id: termdict.Id) -> u64 {
	if b.opts.visibility != nil {
		return termstats.term_visible(&b.ix.stats, u32(id), b.opts.visibility)
	}
	return termstats.term_total(&b.ix.stats, u32(id))
}

term_built :: proc(b: ^Builder, id: termdict.Id, mask: ftq.Field_Mask, weight: f64) -> Built {
	if int(id) >= len(b.ix.lists) || b.ix.lists[id] == nil {
		return NONE_BUILT
	}
	if mask != ftq.ALL_FIELDS && b.ix.term_fields[id] & mask_fields(mask) == 0 {
		return NONE_BUILT
	}
	n := term_count(b, id)
	if b.opts.visibility != nil && n == 0 {
		return NONE_BUILT
	}
	tc := new(retrieve.Term_Cursor, b.a)
	retrieve.term_cursor_init(tc, b.ix.lists[id], b.deleted, mask_fields(mask), retrieve.leaf(.Term, weight), postings.ALL_FIELDS, b.a)
	retrieve.prepare(b.scorer, &tc.leaf, n)
	return Built{cursor = tc, positional = true}
}

term_lookup :: proc(b: ^Builder, s: string, mask: ftq.Field_Mask, weight: f64) -> Built {
	id, found := termdict.lookup(&b.ix.terms, s)
	if !found {
		return NONE_BUILT
	}
	return term_built(b, id, mask, weight)
}

all_docs :: proc(b: ^Builder, kind: retrieve.Leaf_Kind) -> Built {
	bc := new(retrieve.Bitmap_Cursor, b.a)
	retrieve.bitmap_cursor_init(bc, &b.ix.docs.live, nil, retrieve.leaf(kind))
	retrieve.prepare(b.scorer, &bc.leaf, 0)
	return Built{cursor = bc}
}

tag_count :: proc(b: ^Builder, t: ^Tag_Index, id: termdict.Id) -> u64 {
	if b.opts.visibility != nil {
		return termstats.term_visible(&t.stats, u32(id), b.opts.visibility)
	}
	return termstats.term_total(&t.stats, u32(id))
}

tag_value_built :: proc(b: ^Builder, t: ^Tag_Index, id: termdict.Id, weight: f64) -> Built {
	bm := tagindex.bitmap(&t.values, id)
	if bm == nil || roaring.is_empty(bm) {
		return NONE_BUILT
	}
	n := tag_count(b, t, id)
	if b.opts.visibility != nil && n == 0 {
		return NONE_BUILT
	}
	kind := retrieve.Leaf_Kind.Filter if b.opts.unscored_tags else retrieve.Leaf_Kind.Tag
	bc := new(retrieve.Bitmap_Cursor, b.a)
	retrieve.bitmap_cursor_init(bc, bm, b.deleted, retrieve.leaf(kind, weight))
	retrieve.prepare(b.scorer, &bc.leaf, n)
	return Built{cursor = bc}
}

matcher_for :: proc(b: ^Builder, kind: ftq.Node_Kind, distance: int, stats: ^termstats.Stats) -> ^termdict.Matcher {
	mk: Matcher_Kind
	#partial switch kind {
	case .Prefix:
		mk = .Prefix
	case .Suffix:
		mk = .Suffix
	case .Infix:
		mk = .Infix
	case .Wildcard_Pattern:
		mk = .Wildcard
	case .Fuzzy:
		mk = .Fuzzy_1 if distance <= 1 else (.Fuzzy_2 if distance == 2 else .Fuzzy_3)
	}
	if b.opts.matchers != nil && b.opts.matchers[mk] != nil {
		return b.opts.matchers[mk]
	}
	if mk == .Prefix {
		p := new(prefix.Params, b.a)
		p^ = prefix.params_default()
		if b.opts.visibility != nil {
			p^ = prefix.params_visible(stats, b.opts.visibility)
		}
		m := new(termdict.Matcher, b.a)
		m^ = prefix.matcher(p)
		return m
	}
	return nil
}

expand_pattern :: proc(b: ^Builder, n: ^ftq.Node, dict: ^termdict.Dictionary, stats: ^termstats.Stats) -> []termdict.Id {
	m := matcher_for(b, n.kind, n.distance, stats)
	if m == nil {
		fail(b, .Unsupported)
		return nil
	}
	ids := make([dynamic]termdict.Id, b.a)
	truncated, e := termdict.expand(m, dict, n.text, b.expand, &ids)
	if e != .None {
		fail(b, .Out_Of_Memory)
		return nil
	}
	if truncated {
		b.result.truncated = true
	}
	return ids[:]
}

trie_matches :: proc(b: ^Builder, term: string) -> bool {
	buf := make([dynamic]u8, 0, len(term), b.a)
	text.trie_form(transmute([]u8)term, &buf)
	return string(buf[:]) == term
}

union_built :: proc(b: ^Builder, parts: []^retrieve.Cursor, weight: f64, mode: retrieve.Union_Mode, positional: bool) -> Built {
	if len(parts) == 0 {
		return NONE_BUILT
	}
	if len(parts) == 1 {
		return Built{cursor = parts[0], positional = positional}
	}
	u := new(retrieve.Union, b.a)
	if retrieve.union_init(u, parts, weight, mode, b.a) != .None {
		fail(b, .Out_Of_Memory)
		return NONE_BUILT
	}
	return Built{cursor = u, positional = positional}
}

text_pattern :: proc(b: ^Builder, n: ^ftq.Node) -> Built {
	ids := expand_pattern(b, n, &b.ix.terms, &b.ix.stats)
	parts := make([dynamic]^retrieve.Cursor, b.a)
	for id in ids {
		t, _ := termdict.text(&b.ix.terms, id)
		if !trie_matches(b, t) {
			continue
		}
		built := term_built(b, id, n.mask, 1)
		if built.cursor != nil {
			append(&parts, built.cursor)
		}
	}
	return union_built(b, parts[:], n.weight, .First, true)
}

tag_text :: proc(b: ^Builder, id: ftq.Node_Id) -> (value: string, ok: bool) {
	n := ftq.node_get(b.q, id)
	#partial switch n.kind {
	case .Token:
		return n.text, true
	case .Intersect:
		sb := strings.builder_make(b.a)
		for child, i in n.children {
			s, sok := tag_text(b, child)
			if !sok {
				return "", false
			}
			if i > 0 {
				strings.write_byte(&sb, ' ')
			}
			strings.write_string(&sb, s)
		}
		return strings.to_string(sb), true
	}
	return "", false
}

tag_node :: proc(b: ^Builder, n: ^ftq.Node) -> Built {
	if n.field < 0 {
		return NONE_BUILT
	}
	slot := &b.ix.slots[n.field]
	t := slot.tag
	if t == nil {
		return NONE_BUILT
	}
	parts := make([dynamic]^retrieve.Cursor, b.a)
	for child in n.children {
		c := ftq.node_get(b.q, child)
		#partial switch c.kind {
		case .Token, .Intersect:
			value, ok := tag_text(b, child)
			if !ok {
				continue
			}

			_, vid, found := tagindex.lookup(&t.values, value)
			if !found {
				continue
			}
			built := tag_value_built(b, t, vid, n.weight)
			if built.cursor != nil {
				append(&parts, built.cursor)
			}
		case .Prefix, .Suffix, .Infix, .Wildcard_Pattern, .Fuzzy:
			ids := expand_pattern(b, c, &t.values.values, &t.stats)
			if b.err != .None {
				return NONE_BUILT
			}
			group := make([dynamic]^retrieve.Cursor, b.a)
			for vid in ids {
				built := tag_value_built(b, t, vid, n.weight)
				if built.cursor != nil {
					append(&group, built.cursor)
				}
			}
			g := union_built(b, group[:], 1, .First, false)
			if g.cursor != nil {
				append(&parts, g.cursor)
			}
		}
	}
	return union_built(b, parts[:], n.weight, .Sum, false)
}

INDEXEMPTY_MESSAGE :: "Use `INDEXEMPTY` in field creation in order to index and query for empty strings"

numeric_node :: proc(b: ^Builder, n: ^ftq.Node) -> Built {
	if n.field < 0 || b.ix.slots[n.field].numbers == nil {
		return NONE_BUILT
	}
	lo, hi := range_bounds(n.min, n.max, n.min_open, n.max_open)
	docs := make([dynamic]u32, b.a)
	if numindex.range_docs(b.ix.slots[n.field].numbers, lo, hi, &docs) != .None {
		fail(b, .Out_Of_Memory)
		return NONE_BUILT
	}
	if len(docs) == 0 {
		return NONE_BUILT
	}
	ac := new(retrieve.Array_Cursor, b.a)
	retrieve.array_cursor_init(ac, docs[:], b.deleted, retrieve.leaf(.Filter))
	return Built{cursor = ac}
}

missing_node :: proc(b: ^Builder, n: ^ftq.Node) -> Built {
	if n.field < 0 {
		return NONE_BUILT
	}
	bm := &b.ix.slots[n.field].missing
	if roaring.is_empty(bm) {
		return NONE_BUILT
	}
	bc := new(retrieve.Bitmap_Cursor, b.a)
	retrieve.bitmap_cursor_init(bc, bm, b.deleted, retrieve.leaf(.Filter))
	return Built{cursor = bc}
}

phrase_node :: proc(b: ^Builder, n: ^ftq.Node) -> Built {
	parts := make([dynamic]^retrieve.Cursor, b.a)
	for child in n.children {
		c := ftq.node_get(b.q, child)
		if c.kind != .Token {
			return NONE_BUILT
		}
		built := term_lookup(b, c.text, c.mask, c.weight)
		if built.cursor == nil {
			return NONE_BUILT
		}
		append(&parts, built.cursor)
	}
	if len(parts) == 0 {
		return NONE_BUILT
	}
	if len(parts) == 1 && n.weight == 1 {
		return Built{cursor = parts[0], positional = true}
	}
	slop := n.slop if n.slop >= 0 else 0
	p := new(retrieve.Phrase, b.a)
	if retrieve.phrase_init(p, parts[:], slop, true, n.weight, false, b.a) != .None {
		fail(b, .Out_Of_Memory)
		return NONE_BUILT
	}
	return Built{cursor = p, positional = true}
}

Window :: struct {
	using base: retrieve.Cursor,
	inner:      ^retrieve.Cursor,
	parts:      []^retrieve.Cursor,
	slop:       int,
	in_order:   bool,
	lists:      [][dynamic]u32,
	views:      [][]u32,
	heads:      []int,
	merged:     [dynamic]u32,
}

window_accepts :: proc(w: ^Window, d: u32) -> bool {
	k := 0
	for p in w.parts {
		if p.doc != d {
			continue
		}
		clear(&w.lists[k])
		if !retrieve.positions(p, &w.lists[k]) || len(w.lists[k]) == 0 {
			continue
		}
		w.views[k] = w.lists[k][:]
		k += 1
	}
	if k < 2 {
		return true
	}
	if w.in_order {
		return retrieve.ordered_window(w.views[:k], w.slop)
	}
	return retrieve.unordered_window(w.views[:k], w.slop, w.heads[:k])
}

window_settle :: proc(w: ^Window, d: u32) -> u32 {
	d := d
	for d != retrieve.END {
		if window_accepts(w, d) {
			w.doc = d
			return d
		}
		d = retrieve.next(w.inner)
	}
	w.doc = retrieve.END
	return retrieve.END
}

WINDOW_OPS := retrieve.Ops {
	next = proc(c: ^retrieve.Cursor) -> u32 {
		w := (^Window)(c)
		if w.doc == retrieve.END {
			return retrieve.END
		}
		return window_settle(w, retrieve.next(w.inner))
	},
	advance = proc(c: ^retrieve.Cursor, target: u32) -> u32 {
		w := (^Window)(c)
		if w.doc != 0 && w.doc >= target {
			return w.doc
		}
		return window_settle(w, retrieve.advance(w.inner, target))
	},
	score = proc(c: ^retrieve.Cursor, s: ^retrieve.Scoring) -> f64 {
		w := (^Window)(c)
		return retrieve.score(w.inner, s)
	},
	positions = proc(c: ^retrieve.Cursor, out: ^[dynamic]u32) -> bool {
		w := (^Window)(c)
		return merged_positions(w.parts, w.doc, out)
	},
}

merged_positions :: proc(parts: []^retrieve.Cursor, d: u32, out: ^[dynamic]u32) -> bool {
	start := len(out)
	found := false
	for p in parts {
		if p.doc != d {
			continue
		}
		if retrieve.positions(p, out) {
			found = true
		}
	}
	if !found {
		return false
	}
	tail := out[start:]
	retrieve.sort_u32(tail)
	n := 0
	for i in 0 ..< len(tail) {
		if i == 0 || tail[i] != tail[n - 1] {
			tail[n] = tail[i]
			n += 1
		}
	}
	resize(out, start + n)
	return true
}

Merged :: struct {
	using base: retrieve.Cursor,
	inner:      ^retrieve.Cursor,
	parts:      []^retrieve.Cursor,
}

MERGED_OPS := retrieve.Ops {
	next = proc(c: ^retrieve.Cursor) -> u32 {
		m := (^Merged)(c)
		m.doc = retrieve.next(m.inner)
		return m.doc
	},
	advance = proc(c: ^retrieve.Cursor, target: u32) -> u32 {
		m := (^Merged)(c)
		m.doc = retrieve.advance(m.inner, target)
		return m.doc
	},
	score = proc(c: ^retrieve.Cursor, s: ^retrieve.Scoring) -> f64 {
		m := (^Merged)(c)
		return retrieve.score(m.inner, s)
	},
	positions = proc(c: ^retrieve.Cursor, out: ^[dynamic]u32) -> bool {
		m := (^Merged)(c)
		return merged_positions(m.parts, m.doc, out)
	},
}

window_make :: proc(b: ^Builder, inner: ^retrieve.Cursor, parts: []^retrieve.Cursor, slop: int, in_order: bool) -> ^Window {
	w := new(Window, b.a)
	w.base = retrieve.Cursor{doc = 0, cost = inner.cost, ops = &WINDOW_OPS}
	w.inner = inner
	w.parts = parts
	w.slop = slop
	w.in_order = in_order
	w.lists = make([][dynamic]u32, len(parts), b.a)
	for &l in w.lists {
		l = make([dynamic]u32, 0, 8, b.a)
	}
	w.views = make([][]u32, len(parts), b.a)
	w.heads = make([]int, len(parts), b.a)
	return w
}

intersect_node :: proc(b: ^Builder, id: ftq.Node_Id) -> Built {
	n := ftq.node_get(b.q, id)
	required := make([dynamic]^retrieve.Cursor, b.a)
	optional := make([dynamic]^retrieve.Cursor, b.a)
	negative := make([dynamic]^retrieve.Cursor, b.a)
	positional := make([dynamic]^retrieve.Cursor, b.a)
	for child in n.children {
		c := ftq.node_get(b.q, child)
		#partial switch c.kind {
		case .Not:
			if len(c.children) == 0 {
				continue
			}
			built := build(b, c.children[0])
			if b.err != .None {
				return NONE_BUILT
			}
			if built.cursor != nil {
				append(&negative, built.cursor)
			}
		case .Optional:
			if len(c.children) == 0 {
				continue
			}
			built := build(b, c.children[0])
			if b.err != .None {
				return NONE_BUILT
			}
			if built.cursor != nil {
				append(&optional, built.cursor)
				if built.positional {
					append(&positional, built.cursor)
				}
			}
		case:
			built := build(b, child)
			if b.err != .None {
				return NONE_BUILT
			}
			if built.cursor == nil {
				return NONE_BUILT
			}
			append(&required, built.cursor)
			if built.positional {
				append(&positional, built.cursor)
			}
		}
	}
	if len(required) == 0 {
		base := all_docs(b, .Filter)
		append(&required, base.cursor)
	}
	core: ^retrieve.Cursor
	if len(required) == 1 && len(optional) == 0 {
		core = required[0]
	} else {
		ix := new(retrieve.Intersection, b.a)
		if retrieve.intersection_init(ix, required[:], optional[:], n.weight, .Auto, b.a) != .None {
			fail(b, .Out_Of_Memory)
			return NONE_BUILT
		}
		core = ix
	}
	slop := n.slop if n.slop >= 0 else b.slop
	in_order := n.in_order || b.opts.in_order
	if len(positional) >= 2 && (slop >= 0 || in_order) {
		core = window_make(b, core, positional[:], slop, in_order)
	} else if len(positional) >= 1 && core.ops.positions == nil {
		m := new(Merged, b.a)
		m.base = retrieve.Cursor{doc = 0, cost = core.cost, ops = &MERGED_OPS}
		m.inner = core
		m.parts = positional[:]
		core = m
	}
	if len(negative) > 0 {
		exclude := negative[0]
		if len(negative) > 1 {
			u := new(retrieve.Union, b.a)
			if retrieve.union_init(u, negative[:], 1, .Sum, b.a) != .None {
				fail(b, .Out_Of_Memory)
				return NONE_BUILT
			}
			exclude = u
		}
		x := new(retrieve.Difference, b.a)
		retrieve.difference_init(x, core, exclude)
		return Built{cursor = x, positional = len(positional) > 0}
	}
	return Built{cursor = core, positional = len(positional) > 0}
}

not_node :: proc(b: ^Builder, n: ^ftq.Node) -> Built {
	base := all_docs(b, .Filter)
	if len(n.children) == 0 {
		return base
	}
	child := build(b, n.children[0])
	if b.err != .None {
		return NONE_BUILT
	}
	if child.cursor == nil {
		return base
	}
	x := new(retrieve.Difference, b.a)
	retrieve.difference_init(x, base.cursor, child.cursor)
	return Built{cursor = x}
}

optional_node :: proc(b: ^Builder, n: ^ftq.Node) -> Built {
	base := all_docs(b, .Filter)
	if len(n.children) == 0 {
		return base
	}
	child := build(b, n.children[0])
	if b.err != .None {
		return NONE_BUILT
	}
	if child.cursor == nil {
		return base
	}
	ix := new(retrieve.Intersection, b.a)
	opt := make([]^retrieve.Cursor, 1, b.a)
	opt[0] = child.cursor
	req := make([]^retrieve.Cursor, 1, b.a)
	req[0] = base.cursor
	if retrieve.intersection_init(ix, req, opt, 1, .Auto, b.a) != .None {
		fail(b, .Out_Of_Memory)
		return NONE_BUILT
	}
	return Built{cursor = ix}
}

union_node :: proc(b: ^Builder, n: ^ftq.Node) -> Built {
	parts := make([dynamic]^retrieve.Cursor, b.a)
	positional := true
	for child in n.children {
		built := build(b, child)
		if b.err != .None {
			return NONE_BUILT
		}
		if built.cursor == nil {
			continue
		}
		append(&parts, built.cursor)
		positional = positional && built.positional
	}
	return union_built(b, parts[:], n.weight, .Sum, positional)
}

build :: proc(b: ^Builder, id: ftq.Node_Id) -> Built {
	if id == ftq.NO_NODE || b.err != .None {
		return NONE_BUILT
	}
	n := ftq.node_get(b.q, id)
	switch n.kind {
	case .Null:
		return NONE_BUILT
	case .Token:
		return term_lookup(b, n.text, n.mask, n.weight)
	case .Phrase:
		return phrase_node(b, n)
	case .Union:
		return union_node(b, n)
	case .Intersect:
		return intersect_node(b, id)
	case .Not:
		return not_node(b, n)
	case .Optional:
		return optional_node(b, n)
	case .Prefix, .Suffix, .Infix, .Wildcard_Pattern, .Fuzzy:
		return text_pattern(b, n)
	case .Numeric:
		return numeric_node(b, n)
	case .Tag:
		return tag_node(b, n)
	case .Wildcard:
		return all_docs(b, .Wildcard)
	case .Missing:
		return missing_node(b, n)
	case .Vector:
		return vector_node(b, id)
	case .Geo, .Geoshape:
		fail(b, .Unsupported)
		return NONE_BUILT
	}
	return NONE_BUILT
}

document_of :: proc(ix: ^Index, id: u32) -> (retrieve.Document, bool) {
	d := doctable.get(&ix.docs, id)
	if d == nil {
		return {}, false
	}
	return retrieve.Document{id = id, length = d.length, max_frequency = d.max_frequency, score = d.score}, true
}

visible_doc :: proc(ix: ^Index, v: ^label.Visibility, id: u32) -> bool {
	if v == nil {
		return true
	}
	d := doctable.get(&ix.docs, id)
	return d != nil && label.visible(v, d.label)
}

collection_of :: proc(ix: ^Index, v: ^label.Visibility) -> retrieve.Collection {
	t := termstats.totals(&ix.stats) if v == nil else termstats.totals_visible(&ix.stats, v)
	return retrieve.Collection{documents = t.documents, total_length = t.total_length}
}

Session :: struct {
	params: bm25std.Params,
	scorer: retrieve.Scorer,
}

builder_init :: proc(b: ^Builder, ix: ^Index, parsed: ^ftq.Parsed, opts: ^Execute_Options, session: ^Session, result: ^Result) {
	b^ = Builder{ix = ix, parsed = parsed, opts = opts, result = result}
	b.q = &parsed.query if parsed != nil else nil
	b.a = mem.dynamic_arena_allocator(&result.arena)
	if opts.scorer != nil {
		b.scorer = opts.scorer
	} else {
		session.params = bm25std.params_default()
		session.scorer = bm25std.scorer(&session.params)
		b.scorer = &session.scorer
	}
	b.deleted = &ix.docs.deleted
	b.slop = opts.slop.? or_else -1
	b.limit = opts.limit.? or_else -1
	b.expand = opts.expansions.? or_else prefix.LIMIT
	retrieve.begin(b.scorer, collection_of(ix, opts.visibility))
}

result_init :: proc(r: ^Result, allocator: runtime.Allocator) {
	r^ = Result{allocator = allocator, knn_field = -1}
	mem.dynamic_arena_init(&r.arena, allocator, allocator)
	r.hits = make([dynamic]Hit, allocator)
	r.yields = make([dynamic]Yield, allocator)
}

execute :: proc(ix: ^Index, parsed: ^ftq.Parsed, options: Execute_Options, allocator := context.allocator) -> (result: Result, err: Error, query_err: ftq.Error) {
	opts := options
	result_init(&result, allocator)
	if parsed == nil || parsed.query.root == ftq.NO_NODE {
		return result, .None, {}
	}
	session: Session
	b: Builder
	builder_init(&b, ix, parsed, &opts, &session, &result)
	if !validate_tree(&b, parsed.query.root) {
		return result, b.err, b.query_err
	}
	root := build(&b, parsed.query.root)
	if b.err != .None {
		return result, b.err, b.query_err
	}
	if root.cursor == nil {
		return result, .None, {}
	}
	re, rqe := run_root(&b, root.cursor)
	return result, re, rqe
}

run_root :: proc(b: ^Builder, root: ^retrieve.Cursor) -> (err: Error, query_err: ftq.Error) {
	ix := b.ix
	r := b.result
	top: retrieve.Top_K
	keep_all := b.limit < 0
	if !keep_all {
		if retrieve.top_k_init(&top, b.limit, b.a) != .None {
			return .Out_Of_Memory, {}
		}
	}
	s := retrieve.Scoring{scorer = b.scorer}
	total := 0
	for d := retrieve.next(root); d != retrieve.END; d = retrieve.next(root) {
		doc, found := document_of(ix, d)
		if !found || !visible_doc(ix, b.opts.visibility, d) {
			continue
		}
		s.doc = doc
		value := retrieve.finish(&s, retrieve.score(root, &s), root)
		total += 1
		if keep_all {
			if _, e := append(&r.hits, Hit{doc = d, score = value, distance = math.nan_f64()}); e != nil {
				return .Out_Of_Memory, {}
			}
		} else if retrieve.top_k_push(&top, d, value) != .None {
			return .Out_Of_Memory, {}
		}
	}
	r.total = total
	if keep_all {
		sort_result(r.hits[:])
	} else {
		ranked := make([dynamic]retrieve.Ranked, b.a)
		if retrieve.top_k_results(&top, &ranked) != .None {
			return .Out_Of_Memory, {}
		}
		for x in ranked {
			append(&r.hits, Hit{doc = x.doc, score = x.score, distance = math.nan_f64()})
		}
	}
	if b.knn != nil && root == &b.knn.base {
		r.knn = true
		r.knn_field = b.knn.field
		r.knn_alias = b.knn.alias
		for &h in r.hits {
			h.distance = knn_distance(b.knn, h.doc)
		}
	}
	return .None, {}
}

sort_result :: proc(hits: []Hit) {
	n := len(hits)
	if n < 2 {
		return
	}
	ranked := make([]retrieve.Ranked, n, context.temp_allocator)
	for h, i in hits {
		ranked[i] = retrieve.Ranked{doc = h.doc, score = h.score}
	}
	retrieve.sort_ranked(ranked)
	for x, i in ranked {
		hits[i] = Hit{doc = x.doc, score = x.score, distance = math.nan_f64()}
	}
}

Knn_Cursor :: struct {
	using base: retrieve.Cursor,
	docs:       []u32,
	scores:     []f64,
	distances:  []f64,
	index:      int,
	field:      int,
	alias:      string,
}

knn_settle :: proc(k: ^Knn_Cursor) -> u32 {
	if k.index >= len(k.docs) {
		k.doc = retrieve.END
		return retrieve.END
	}
	k.doc = k.docs[k.index]
	return k.doc
}

KNN_OPS := retrieve.Ops {
	next = proc(c: ^retrieve.Cursor) -> u32 {
		k := (^Knn_Cursor)(c)
		if k.doc == retrieve.END {
			return retrieve.END
		}
		if k.doc != 0 {
			k.index += 1
		}
		return knn_settle(k)
	},
	advance = proc(c: ^retrieve.Cursor, target: u32) -> u32 {
		k := (^Knn_Cursor)(c)
		if k.doc != 0 && k.doc >= target {
			return k.doc
		}
		for k.index < len(k.docs) && k.docs[k.index] < target {
			k.index += 1
		}
		return knn_settle(k)
	},
	score = proc(c: ^retrieve.Cursor, s: ^retrieve.Scoring) -> f64 {
		k := (^Knn_Cursor)(c)
		return k.scores[k.index]
	},
}

knn_distance :: proc(k: ^Knn_Cursor, doc: u32) -> f64 {
	lo, hi := 0, len(k.docs)
	for lo < hi {
		mid := (lo + hi) / 2
		if k.docs[mid] < doc {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(k.docs) && k.docs[lo] == doc {
		return k.distances[lo]
	}
	return math.nan_f64()
}

Filter_Set :: struct {
	docs:   [dynamic]u32,
	scores: [dynamic]f64,
	ix:     ^Index,
	v:      ^label.Visibility,
	all:    bool,
}

filter_accept :: proc(ctx: rawptr, id: u32) -> bool {
	f := (^Filter_Set)(ctx)
	if f.all {
		if doctable.get(&f.ix.docs, id) == nil {
			return false
		}
		return visible_doc(f.ix, f.v, id)
	}
	lo, hi := 0, len(f.docs)
	for lo < hi {
		mid := (lo + hi) / 2
		if f.docs[mid] < id {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < len(f.docs) && f.docs[lo] == id
}

filter_score :: proc(f: ^Filter_Set, id: u32) -> f64 {
	if f.all {
		return 0
	}
	lo, hi := 0, len(f.docs)
	for lo < hi {
		mid := (lo + hi) / 2
		if f.docs[mid] < id {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(f.docs) && f.docs[lo] == id {
		return f.scores[lo]
	}
	return 0
}

materialize :: proc(b: ^Builder, c: ^retrieve.Cursor, f: ^Filter_Set) {
	f.ix = b.ix
	f.v = b.opts.visibility
	f.docs = make([dynamic]u32, b.a)
	f.scores = make([dynamic]f64, b.a)
	s := retrieve.Scoring{scorer = b.scorer}
	for d := retrieve.next(c); d != retrieve.END; d = retrieve.next(c) {
		doc, found := document_of(b.ix, d)
		if !found || !visible_doc(b.ix, f.v, d) {
			continue
		}
		s.doc = doc
		append(&f.docs, d)
		append(&f.scores, retrieve.score(c, &s))
	}
}

field_vector_bytes :: proc "contextless" (ix: ^Index, field: int) -> int {
	v := ix.definition.fields[field].vector
	return v.dim * vector_elem_size(v.elem)
}

blob_size_error :: proc(got, want: int, allocator: mem.Allocator) -> ftq.Error {
	message := fmt.aprintf("Error parsing vector similarity query: query vector blob size (%d) does not match index's expected size (%d).", got, want, allocator = allocator)
	return ftq.Error{code = .Query_Bad, message = message}
}

validate_tree :: proc(b: ^Builder, id: ftq.Node_Id) -> bool {
	if id == ftq.NO_NODE {
		return true
	}
	n := ftq.node_get(b.q, id)
	#partial switch n.kind {
	case .Tag:
		if n.field >= 0 && b.ix.definition.fields[n.field].kind == .Tag && !b.ix.definition.fields[n.field].index_empty {
			for child in n.children {
				if value, ok := tag_text(b, child); ok && len(value) == 0 {
					b.query_err = ftq.Error{code = .Syntax, message = INDEXEMPTY_MESSAGE}
					fail(b, .Query_Error)
					return false
				}
			}
		}
	case .Vector:
		v := n.vector
		if v.field >= 0 && v.field < len(b.ix.slots) {
			source := b.ix.slots[v.field].vector
			if source != nil && source.count(source.ctx) > 0 && !validate_vector_node(b, id) {
				return false
			}
		}
	}
	for child in n.children {
		if !validate_tree(b, child) {
			return false
		}
	}
	return true
}

validate_vector_node :: proc(b: ^Builder, id: ftq.Node_Id) -> bool {
	p := ftq.Parser {
		q         = b.q,
		schema    = &b.ix.query_schema,
		allocator = b.a,
		dialect   = b.q.dialect,
	}
	ftq.validate_vector(&p, id)
	if p.failed {
		b.query_err = p.err
		fail(b, .Query_Error)
		return false
	}
	return true
}

attribute :: proc(v: ^ftq.Vector_Query, name: string) -> (string, bool) {
	for a in v.attributes {
		if ftq.ascii_equal_fold(a.name, name) {
			return a.value, true
		}
	}
	return "", false
}

vector_query_from :: proc(v: ^ftq.Vector_Query) -> Vector_Query {
	q := Vector_Query{blob = transmute([]u8)v.blob, k = int(min(v.k, u64(max(i32)))), radius = v.radius, accepted = -1}
	if s, ok := attribute(v, "EF_RUNTIME"); ok {
		if x, xok := strconv.parse_int(s); xok {
			q.ef_runtime = x
		}
	}
	if s, ok := attribute(v, "EPSILON"); ok {
		if x, xok := strconv.parse_f64(s); xok {
			q.epsilon = x
		}
	}
	if s, ok := attribute(v, "HYBRID_POLICY"); ok {
		if ftq.ascii_equal_fold(s, "ADHOC_BF") {
			q.policy = .Adhoc_Bf
		} else if ftq.ascii_equal_fold(s, "BATCHES") {
			q.policy = .Batches
		}
	}
	if s, ok := attribute(v, "BATCH_SIZE"); ok {
		if x, xok := strconv.parse_int(s); xok {
			q.batch_size = x
		}
	}
	return q
}

vector_node :: proc(b: ^Builder, id: ftq.Node_Id) -> Built {
	n := ftq.node_get(b.q, id)
	v := n.vector
	if v.field < 0 || v.field >= len(b.ix.slots) {
		return NONE_BUILT
	}
	source := b.ix.slots[v.field].vector
	if source == nil {
		fail(b, .Unsupported)
		return NONE_BUILT
	}
	filter: Built
	has_filter := len(n.children) > 0 && ftq.node_get(b.q, n.children[0]).kind != .Wildcard
	if v.kind == .Knn && has_filter {
		filter = build(b, n.children[0])
		if b.err != .None || filter.cursor == nil {
			return NONE_BUILT
		}
	}
	if source.count(source.ctx) == 0 {
		return NONE_BUILT
	}
	q := vector_query_from(v)
	set := new(Filter_Set, b.a)
	if v.kind == .Knn && has_filter {
		materialize(b, filter.cursor, set)
		if len(set.docs) == 0 {
			return NONE_BUILT
		}
		q.accepted = len(set.docs)
	} else {
		set.all = true
		set.ix = b.ix
		set.v = b.opts.visibility
		q.accepted = -1
	}
	q.accept = filter_accept
	q.accept_ctx = set
	hits := make([dynamic]Vector_Hit, b.a)
	e: Error
	if v.kind == .Knn {
		if q.k <= 0 {
			return NONE_BUILT
		}
		e = source.nearest(source.ctx, &q, &hits)
	} else {
		e = source.within(source.ctx, &q, &hits)
	}
	if e == .Blob_Size {
		b.query_err = blob_size_error(len(q.blob), field_vector_bytes(b.ix, v.field), b.a)
		fail(b, .Query_Error)
		return NONE_BUILT
	}
	if e != .None {
		fail(b, e)
		return NONE_BUILT
	}
	live := make([dynamic]Vector_Hit, 0, len(hits), b.a)
	for h in hits {
		if doctable.get(&b.ix.docs, h.doc) != nil && filter_accept(set, h.doc) {
			append(&live, h)
		}
	}
	if len(live) == 0 {
		return NONE_BUILT
	}
	by_doc := live[:]
	sort_by_doc(by_doc)
	if v.kind == .Range {
		if len(v.score_alias) > 0 {
			append(&b.result.yields, Yield{alias = v.score_alias, field = v.field, hits = by_doc})
		}
		docs := make([]u32, len(by_doc), b.a)
		for h, i in by_doc {
			docs[i] = h.doc
		}
		ac := new(retrieve.Array_Cursor, b.a)
		retrieve.array_cursor_init(ac, docs, b.deleted, retrieve.leaf(.Filter))
		return Built{cursor = ac}
	}
	k := new(Knn_Cursor, b.a)
	k.base = retrieve.Cursor{doc = 0, cost = u64(len(by_doc)), ops = &KNN_OPS}
	k.docs = make([]u32, len(by_doc), b.a)
	k.scores = make([]f64, len(by_doc), b.a)
	k.distances = make([]f64, len(by_doc), b.a)
	for h, i in by_doc {
		k.docs[i] = h.doc
		k.distances[i] = h.distance
		k.scores[i] = filter_score(set, h.doc)
	}
	k.field = v.field
	k.alias = v.score_alias
	b.knn = k
	return Built{cursor = k}
}

sort_by_doc :: proc(hits: []Vector_Hit) {
	slice.sort_by(hits, proc(a, b: Vector_Hit) -> bool {
		return a.doc < b.doc
	})
}
