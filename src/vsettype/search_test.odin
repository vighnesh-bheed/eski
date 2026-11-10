package vsettype

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:testing"

build_random_set :: proc(t: ^testing.T, r: ^Test_Rng, n: int, dim: int, quant: Quant, sc: ^Scratch, m := 0, seed: u64 = 0) -> Vset {
	s := new_set(t, dim, quant, m, 0, seed)
	x := make([]f32, dim)
	defer delete(x)
	for i in 0 ..< n {
		random_vector(r, x)
		name := fmt.tprintf("e%d", i)
		req := Add_Request{name = bytes_of(name), vector = x, quant = quant, m = m}
		_, f := add(s, &req, sc)
		testing.expect_value(t, f.err, Error.None)
	}
	return s
}

recall_of :: proc(t: ^testing.T, s: Vset, r: ^Test_Rng, queries: int, k: int, ef: int, sc: ^Scratch) -> f64 {
	q := make([]f32, s.dim)
	defer delete(q)
	found := 0
	total := 0
	exact: [dynamic]Hit
	approx: [dynamic]Hit
	defer delete(exact)
	defer delete(approx)
	for _ in 0 ..< queries {
		random_vector(r, q)
		clear(&exact)
		clear(&approx)
		tr := Search_Request{kind = .Vector, vector = q, count = k, truth = true}
		gr := Search_Request{kind = .Vector, vector = q, count = k, ef = ef}
		testing.expect_value(t, search(s, &tr, sc, &exact).err, Error.None)
		testing.expect_value(t, search(s, &gr, sc, &approx).err, Error.None)
		floor := exact[len(exact) - 1].score
		for h in approx {
			if h.score >= floor {
				found += 1
			}
		}
		total += len(exact)
		for i in 1 ..< len(approx) {
			testing.expect(t, !hit_better(approx[i], approx[i - 1]))
		}
	}
	return f64(found) / f64(total)
}

@(test)
graph_search_recall_against_truth :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	Case :: struct {
		quant: Quant,
		dim:   int,
		n:     int,
		floor: f64,
	}
	cases := []Case{{.Q8, 16, 500, 0.95}, {.NOQUANT, 8, 400, 0.95}, {.BIN, 64, 300, 0.8}, {.Q8, 64, 1000, 0.9}}
	for c, i in cases {
		r := Test_Rng{state = u64(0x7E57 + i)}
		s := build_random_set(t, &r, c.n, c.dim, c.quant, &sc, seed = u64(11 + i))
		recall := recall_of(t, s, &r, 40, 10, 0, &sc)
		testing.expectf(t, recall >= c.floor, "%v dim %d n %d recall %v", c.quant, c.dim, c.n, recall)
		wide := recall_of(t, s, &r, 20, 10, 400, &sc)
		log.infof("recall at COUNT 10: %v dim %d n %d default EF %.3f, EF 400 %.3f", c.quant, c.dim, c.n, recall, wide)
		testing.expectf(t, wide >= recall - 0.02, "wider EF lowered recall: %v against %v", wide, recall)
		destroy(s)
	}
}

@(test)
search_semantics :: proc(t: ^testing.T) {
	s := new_set(t, 2)
	defer destroy(s)
	add_values(t, s, "a", {1, 0}, attr = `{"n":1,"s":"x"}`, set_attr = true)
	add_values(t, s, "b", {0, 1}, attr = `{"n":2}`, set_attr = true)
	add_values(t, s, "c", {1, 1}, attr = "notjson", set_attr = true)
	add_values(t, s, "d", {-1, 0})
	hits: [dynamic]Hit
	defer delete(hits)
	run :: proc(s: Vset, req: Search_Request, hits: ^[dynamic]Hit) -> (names: string, f: Failure) {
		clear(hits)
		r := req
		f = search(s, &r, nil, hits)
		out := ""
		for h in hits {
			out = fmt.tprintf("%s%s", out, name_text(s, h.slot))
		}
		return out, f
	}
	names, f := run(s, Search_Request{kind = .Vector, vector = {1, 0}, use_filter = true, filter = "1 == 1"}, &hits)
	testing.expect_value(t, names, "acb")
	names, f = run(s, Search_Request{kind = .Vector, vector = {1, 0}, use_filter = true, filter = ".n > 1"}, &hits)
	testing.expect_value(t, names, "b")
	names, f = run(s, Search_Request{kind = .Vector, vector = {1, 0}, use_filter = true, filter = ".n >= 1", truth = true}, &hits)
	testing.expect_value(t, names, "ab")
	names, f = run(s, Search_Request{kind = .Vector, vector = {1, 0}, use_epsilon = true, epsilon = 0.5}, &hits)
	testing.expect_value(t, names, "acb")
	names, f = run(s, Search_Request{kind = .Vector, vector = {1, 0}, use_epsilon = true, epsilon = 0.1464466}, &hits)
	testing.expect_value(t, names, "a")
	names, f = run(s, Search_Request{kind = .Vector, vector = {1, 0}, use_epsilon = true, epsilon = 0.1464467}, &hits)
	testing.expect_value(t, names, "ac")
	names, f = run(s, Search_Request{kind = .Element, element = bytes_of("b"), count = 2}, &hits)
	testing.expect_value(t, names, "bc")
	names, f = run(s, Search_Request{kind = .Element, element = bytes_of("zz")}, &hits)
	testing.expect_value(t, f.err, Error.Element_Not_Found)
	names, f = run(s, Search_Request{kind = .Vector, vector = {1, 0, 0}}, &hits)
	testing.expect(t, f.err == .Dimension_Mismatch && f.got == 3 && f.expected == 2)
	names, f = run(s, Search_Request{kind = .Vector, vector = {1, 0}, use_filter = true, filter = ".n = 1"}, &hits)
	testing.expect(t, f.err == .Filter_Syntax && f.near == " 1")
	text, _ := failure_text(f, context.temp_allocator)
	testing.expect_value(t, text, "ERR syntax error in FILTER expression near:  1")
	names, f = run(s, Search_Request{kind = .Vector, vector = {1, 0}, count = 99999999999}, &hits)
	testing.expect_value(t, names, "acbd")
	deep := "1"
	for _ in 0 ..< 70 {
		deep = fmt.tprintf("(1 + %s)", deep)
	}
	deep_compare := fmt.tprintf("(%s > 0) and .n == 1", deep)
	names, f = run(s, Search_Request{kind = .Vector, vector = {1, 0}, use_filter = true, filter = deep_compare}, &hits)
	testing.expect_value(t, f.err, Error.None)
	testing.expect_value(t, names, "a")
	deep_constant := fmt.tprintf("%s > 70", deep)
	names, f = run(s, Search_Request{kind = .Vector, vector = {1, 0}, use_filter = true, filter = deep_constant}, &hits)
	testing.expect_value(t, names, "acb")
}

Failing_State :: struct {
	budget: int,
}

failing_allocator_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	st := (^Failing_State)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if st.budget <= 0 {
			return nil, .Out_Of_Memory
		}
		st.budget -= 1
	}
	return runtime.heap_allocator_proc(nil, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
filter_compile_out_of_memory_is_an_error :: proc(t: ^testing.T) {
	s := new_set(t, 2)
	defer destroy(s)
	add_values(t, s, "a", {1, 0}, attr = `{"n":1}`, set_attr = true)
	saw_oom := false
	for budget in 0 ..< 40 {
		st := Failing_State{budget = 1000}
		sc: Scratch
		scratch_init(&sc, runtime.Allocator{procedure = failing_allocator_proc, data = &st})
		warm := Search_Request{kind = .Vector, vector = {1, 0}}
		warm_hits: [dynamic]Hit
		search(s, &warm, &sc, &warm_hits)
		delete(warm_hits)
		st.budget = budget
		req := Search_Request{kind = .Vector, vector = {1, 0}, use_filter = true, filter = ".n == 1 and .n < 2"}
		hits: [dynamic]Hit
		f := search(s, &req, &sc, &hits)
		if f.err == .Out_Of_Memory {
			saw_oom = true
			testing.expect_value(t, len(hits), 0)
		} else {
			testing.expect_value(t, f.err, Error.None)
			testing.expect_value(t, len(hits), 1)
		}
		delete(hits)
		st.budget = 1000
		scratch_destroy(&sc)
	}
	testing.expect(t, saw_oom)
}

@(test)
deep_filter_programs_reuse_one_stack :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	deep := ".n"
	for _ in 0 ..< 80 {
		deep = fmt.tprintf("(1 + %s)", deep)
	}
	f: Filter
	testing.expect_value(t, filter_compile(&f, fmt.tprintf("%s > 80", deep), &sc).err, Error.None)
	testing.expect(t, f.deep && !f.program.constant && len(f.stack) == f.program.depth && f.program.depth > 64)
	filter_destroy(&f, &sc)
	constant := "1"
	for _ in 0 ..< 80 {
		constant = fmt.tprintf("(1 + %s)", constant)
	}
	testing.expect_value(t, filter_compile(&f, fmt.tprintf("%s == 81", constant), &sc).err, Error.None)
	testing.expect(t, f.deep && f.program.constant && f.result && !filter_never(&f))
	filter_destroy(&f, &sc)
	testing.expect_value(t, filter_compile(&f, "1 == 2", &sc).err, Error.None)
	testing.expect(t, !f.deep && filter_never(&f))
	filter_destroy(&f, &sc)
	s := new_set(t, 2)
	defer destroy(s)
	add_values(t, s, "a", {1, 0}, attr = `{"n":1}`, set_attr = true)
	add_values(t, s, "b", {0, 1}, attr = `{"n":0}`, set_attr = true)
	add_values(t, s, "c", {1, 1})
	hits: [dynamic]Hit
	defer delete(hits)
	req := Search_Request{kind = .Vector, vector = {1, 0}, use_filter = true, filter = fmt.tprintf("%s > 80", deep)}
	testing.expect_value(t, search(s, &req, &sc, &hits).err, Error.None)
	testing.expect_value(t, len(hits), 1)
	testing.expect_value(t, name_text(s, hits[0].slot), "a")
	removed, emptied, _ := remove(s, bytes_of("a"), &sc)
	testing.expect(t, removed && !emptied)
	remove(s, bytes_of("b"), &sc)
	removed, emptied, _ = remove(s, bytes_of("c"), &sc)
	testing.expect(t, removed && emptied && card(s) == 0)
	check_invariants(t, s)
}
