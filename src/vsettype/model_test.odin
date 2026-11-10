package vsettype

import "core:slice"
import "core:testing"
import "../vmath"

Model_Element :: struct {
	name:     string,
	vector:   []f32,
	attr:     string,
	has_attr: bool,
	seq:      int,
}

Model :: struct {
	quant:    Quant,
	dim:      int,
	reduce:   int,
	m:        int,
	items:    [dynamic]Model_Element,
	next_seq: int,
}

model_find :: proc(m: ^Model, name: string) -> int {
	for e, i in m.items {
		if e.name == name {
			return i
		}
	}
	return -1
}

model_destroy :: proc(m: ^Model) {
	for e in m.items {
		delete(e.name)
		delete(e.vector)
		delete(e.attr)
	}
	delete(m.items)
}

random_name :: proc(r: ^Test_Rng) -> string {
	n := test_below(r, 4)
	buf := make([]u8, n)
	alphabet := "ab\x00\xffz"
	for &c in buf {
		c = alphabet[test_below(r, len(alphabet))]
	}
	return string(buf)
}

stored_model_vector :: proc(m: ^Model, x: []f32, out: []f32) -> []f32 {
	if m.reduce == 0 {
		return x
	}
	p: vmath.Projection
	vmath.projection_init(&p, m.dim, m.reduce)
	defer vmath.projection_destroy(&p)
	vmath.projection_project(&p, x, out)
	return out[:m.reduce]
}

expect_encoding :: proc(t: ^testing.T, s: Vset, m: ^Model, e: ^Model_Element) -> bool {
	slot, ok := find(s, bytes_of(e.name))
	if !testing.expectf(t, ok, "element %q missing", e.name) {
		return false
	}
	tmp := make([]f32, max(m.dim, 1), context.temp_allocator)
	x := stored_model_vector(m, e.vector, tmp)
	elem := quant_elem(m.quant)
	want := make([]u8, vmath.elem_vector_bytes(elem, len(x)), context.temp_allocator)
	norm, range := vmath.encode(elem, x, want)
	raw := raw_embedding(s, slot)
	same := string(raw.data) == string(want) && transmute(u32)raw.norm == transmute(u32)vmath.stored_norm(norm)
	if elem == .Int8 {
		same = same && transmute(u32)raw.range == transmute(u32)range
	}
	testing.expectf(t, same, "element %q stored encoding differs", e.name)
	text, has := get_attribute(s, bytes_of(e.name))
	testing.expectf(t, has == e.has_attr && (!has || text == e.attr), "element %q attribute %q against %q", e.name, text, e.attr)
	return same
}

Truth_Row :: struct {
	name:  string,
	score: f64,
	seq:   int,
}

model_truth :: proc(m: ^Model, query: []f32, k: int) -> []Truth_Row {
	elem := quant_elem(m.quant)
	stored_dim := m.reduce if m.reduce > 0 else m.dim
	a: vmath.Arena
	vmath.arena_init(&a, elem, .Cosine, stored_dim, context.temp_allocator)
	tmp := make([]f32, max(m.dim, 1), context.temp_allocator)
	for &e in m.items {
		vmath.arena_insert(&a, stored_model_vector(m, e.vector, tmp))
	}
	buf, _ := vmath.query_alloc(&a, context.temp_allocator)
	qx := query
	if m.reduce > 0 && len(query) == m.dim && m.dim != m.reduce {
		qx = stored_model_vector(m, query, tmp)
	}
	q, _ := vmath.query_encode(&a, qx, buf)
	rows := make([]Truth_Row, len(m.items), context.temp_allocator)
	for &e, i in m.items {
		rows[i] = Truth_Row{name = e.name, score = vmath.arena_query_score(&a, q, u32(i)), seq = e.seq}
	}
	slice.sort_by(rows, proc(x, y: Truth_Row) -> bool {
		if x.score != y.score {
			return x.score > y.score
		}
		return x.seq < y.seq
	})
	return rows[:min(k, len(rows))]
}

model_add :: proc(t: ^testing.T, s: Vset, m: ^Model, r: ^Test_Rng, sc: ^Scratch, name: string, cas: bool) {
	x := make([]f32, m.dim)
	random_vector(r, x)
	if test_below(r, 10) == 0 {
		for &v in x {
			v = f32(test_below(r, 3) - 1)
		}
	}
	set_attr := test_below(r, 3) == 0
	attr := ""
	if set_attr && test_below(r, 4) != 0 {
		choices := []string{`{"n":1}`, `{"n":2,"s":"x"}`, "not json", `{"a":[1,2,3]}`}
		attr = choices[test_below(r, 4)]
	}
	req := Add_Request{name = bytes_of(name), vector = x, quant = m.quant, reduce = m.reduce, m = m.m, attr = bytes_of(attr), set_attr = set_attr}
	added: bool
	f: Failure
	if cas {
		plan: Cas_Plan
		f = cas_prepare(s, &req, &plan, sc)
		if f.err == .None {
			added, f = cas_commit(s, &plan, sc)
		}
		cas_discard(&plan)
	} else {
		added, f = add(s, &req, sc)
	}
	testing.expect_value(t, f.err, Error.None)
	at := model_find(m, name)
	testing.expect_value(t, added, at < 0)
	m.next_seq += 1
	if at < 0 {
		append(&m.items, Model_Element{name = name, vector = x, attr = string_clone(attr), has_attr = set_attr, seq = m.next_seq})
		return
	}
	delete(name)
	e := &m.items[at]
	delete(e.vector)
	e.vector = x
	e.seq = m.next_seq
	if set_attr {
		delete(e.attr)
		e.attr = string_clone(attr)
		e.has_attr = attr != ""
	}
}

string_clone :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}

model_check_truth :: proc(t: ^testing.T, s: Vset, m: ^Model, r: ^Test_Rng, sc: ^Scratch) {
	q := make([]f32, m.dim, context.temp_allocator)
	random_vector(r, q)
	k := 1 + test_below(r, 12)
	want := model_truth(m, q, k)
	req := Search_Request{kind = .Vector, vector = q, count = k, truth = true}
	hits: [dynamic]Hit
	defer delete(hits)
	f := search(s, &req, sc, &hits)
	testing.expect_value(t, f.err, Error.None)
	if !testing.expect_value(t, len(hits), len(want)) {
		return
	}
	for h, i in hits {
		testing.expectf(t, name_text(s, h.slot) == want[i].name && transmute(u64)h.score == transmute(u64)want[i].score, "truth position %d: %q %v against %q %v", i, name_text(s, h.slot), h.score, want[i].name, want[i].score)
	}
}

model_check_range :: proc(t: ^testing.T, s: Vset, m: ^Model, r: ^Test_Rng) {
	names := make([]string, len(m.items), context.temp_allocator)
	for e, i in m.items {
		names[i] = e.name
	}
	slice.sort(names)
	lo := random_name(r)
	defer delete(lo)
	hi := random_name(r)
	defer delete(hi)
	start := Lex_Bound{kind = Lex_Kind(test_below(r, 4)), value = bytes_of(lo)}
	end := Lex_Bound{kind = Lex_Kind(test_below(r, 4)), value = bytes_of(hi)}
	count := test_below(r, 6) - 1
	want := make([dynamic]string, context.temp_allocator)
	if start.kind != .Max && end.kind != .Min && count != 0 {
		for n in names {
			if start.kind == .Inclusive && n < lo || start.kind == .Exclusive && n <= lo {
				continue
			}
			if end.kind == .Inclusive && n > hi || end.kind == .Exclusive && n >= hi {
				continue
			}
			append(&want, n)
			if count > 0 && len(want) == count {
				break
			}
		}
	}
	got := make([dynamic]u32, context.temp_allocator)
	lex_range(s, start, end, count, &got)
	if !testing.expectf(t, len(got) == len(want), "range returned %d names, model %d", len(got), len(want)) {
		return
	}
	for slot, i in got {
		testing.expectf(t, name_text(s, slot) == want[i], "range position %d: %q against %q", i, name_text(s, slot), want[i])
	}
}

run_model :: proc(t: ^testing.T, seed: u64, quant: Quant, dim: int, reduce: int, m_links: int, steps: int) {
	r := Test_Rng{state = seed}
	m := Model{quant = quant, dim = dim, reduce = reduce, m = m_links}
	defer model_destroy(&m)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	s := new_set(t, dim, quant, m_links, reduce, seed)
	defer destroy(s)
	for step in 0 ..< steps {
		op := test_below(&r, 100)
		switch {
		case op < 55 || len(m.items) == 0:
			model_add(t, s, &m, &r, &sc, random_name_unique(&r), test_below(&r, 4) == 0)
		case op < 70:
			e := &m.items[test_below(&r, len(m.items))]
			model_add(t, s, &m, &r, &sc, string_clone(e.name), test_below(&r, 2) == 0)
		case op < 85:
			at := test_below(&r, len(m.items))
			if len(m.items) == 1 {
				continue
			}
			removed, _, f := remove(s, bytes_of(m.items[at].name), &sc)
			testing.expect(t, removed && f.err == .None)
			e := m.items[at]
			delete(e.name)
			delete(e.vector)
			delete(e.attr)
			ordered_remove(&m.items, at)
		case op < 95:
			e := &m.items[test_below(&r, len(m.items))]
			choices := []string{"", `{"n":3}`, "{bad"}
			text := choices[test_below(&r, 3)]
			found, err := set_attribute(s, bytes_of(e.name), bytes_of(text))
			testing.expect(t, found && err == .None)
			delete(e.attr)
			e.attr = string_clone(text)
			e.has_attr = text != ""
		case:
			missing := "zzzz-missing"
			testing.expect(t, !contains(s, bytes_of(missing)))
			removed, _, _ := remove(s, bytes_of(missing), &sc)
			testing.expect(t, !removed)
		}
		testing.expect_value(t, card(s), len(m.items))
		if step % 7 == 0 {
			check_invariants(t, s)
			for &e in m.items {
				expect_encoding(t, s, &m, &e)
			}
			model_check_truth(t, s, &m, &r, &sc)
			model_check_range(t, s, &m, &r)
			info := info(s)
			testing.expect_value(t, info.size, len(m.items))
		}
		free_all(context.temp_allocator)
	}
	check_invariants(t, s)
}

random_name_unique :: proc(r: ^Test_Rng) -> string {
	return random_name(r)
}

@(test)
model_q8_random_operations :: proc(t: ^testing.T) {
	run_model(t, 0x51, .Q8, 8, 0, 16, 400)
}

@(test)
model_noquant_random_operations :: proc(t: ^testing.T) {
	run_model(t, 0x52, .NOQUANT, 5, 0, 4, 400)
}

@(test)
model_bin_random_operations :: proc(t: ^testing.T) {
	run_model(t, 0x53, .BIN, 70, 0, 8, 300)
}

@(test)
model_reduce_random_operations :: proc(t: ^testing.T) {
	run_model(t, 0x54, .Q8, 12, 5, 16, 300)
	run_model(t, 0x55, .NOQUANT, 7, 7, 4, 200)
}
