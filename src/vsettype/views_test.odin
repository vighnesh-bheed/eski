package vsettype

import "core:fmt"
import "core:log"
import "core:math"
import "core:testing"
import "../hnsw"

@(test)
random_sampling_is_uniform :: proc(t: ^testing.T) {
	s := new_set(t, 2)
	defer destroy(s)
	n := 10
	for i in 0 ..< n {
		add_values(t, s, fmt.tprintf("m%d", i), {f32(i) + 1, 1})
	}
	big := new_set(t, 2)
	defer destroy(big)
	for i in 0 ..< 40 {
		add_values(t, big, fmt.tprintf("m%d", i), {f32(i) + 1, 1})
	}
	chi :: proc(counts: []int, expected: f64) -> f64 {
		x := 0.0
		for c in counts {
			d := f64(c) - expected
			x += d * d / expected
		}
		return x
	}
	index_of :: proc(s: Vset, slot: u32) -> int {
		name := name_text(s, slot)
		v, _ := strconv_atoi(name[1:])
		return v
	}
	counts := make([]int, 40)
	defer delete(counts)
	for _ in 0 ..< 50000 {
		slot, ok := random_member(s)
		testing.expect(t, ok)
		counts[index_of(s, slot)] += 1
	}
	testing.expectf(t, chi(counts[:n], 5000) < 40, "single draws chi-square %v", chi(counts[:n], 5000))
	out: [dynamic]u32
	defer delete(out)
	Draw :: struct {
		set:   Vset,
		count: int,
	}
	draws := []Draw{{s, 3}, {s, 5}, {s, 9}, {big, 5}, {big, 10}, {big, 25}}
	for d in draws {
		size := card(d.set)
		for &c in counts {
			c = 0
		}
		rounds := 20000
		for _ in 0 ..< rounds {
			clear(&out)
			testing.expect_value(t, random_distinct(d.set, d.count, &out), nil)
			testing.expect_value(t, len(out), d.count)
			seen: [40]bool
			for slot in out {
				i := index_of(d.set, slot)
				testing.expect(t, !seen[i])
				seen[i] = true
				counts[i] += 1
			}
		}
		expected := f64(rounds * d.count) / f64(size)
		x := chi(counts[:size], expected)
		testing.expectf(t, x < f64(size) * 3 + 30, "distinct %d of %d chi-square %v", d.count, size, x)
	}
	clear(&out)
	random_distinct(s, 1000, &out)
	testing.expect_value(t, len(out), n)
	clear(&out)
	random_repeats(s, 1000, &out)
	testing.expect_value(t, len(out), 1000)
	for &c in counts {
		c = 0
	}
	for _ in 0 ..< 50 {
		clear(&out)
		random_repeats(s, 1000, &out)
		for slot in out {
			counts[index_of(s, slot)] += 1
		}
	}
	testing.expectf(t, chi(counts[:n], 5000) < 40, "repeated draws chi-square %v", chi(counts[:n], 5000))
	clear(&out)
	random_distinct(s, 0, &out)
	random_repeats(s, 0, &out)
	testing.expect_value(t, len(out), 0)
}

strconv_atoi :: proc(s: string) -> (int, bool) {
	v := 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v * 10 + int(c - '0')
	}
	return v, true
}

@(test)
links_report_layers_top_first_and_twins_through_their_head :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x11AE}
	s := build_random_set(t, &r, 300, 8, .NOQUANT, &sc, m = 4, seed = 99)
	defer destroy(s)
	buf: [dynamic]u32
	defer delete(buf)
	multi := 0
	it := element_iterator(s)
	for slot in next_element(&it) {
		layers := link_layers(s, slot)
		testing.expect(t, layers >= 1)
		if layers > 1 {
			multi += 1
		}
		for i in 0 ..< layers {
			links := layer_links(s, slot, i, &buf)
			limit := 8 if i == layers - 1 else 4
			testing.expectf(t, len(links) <= limit, "layer %d of %d holds %d links", i, layers, len(links))
			for other in links {
				testing.expect(t, other != slot && hnsw.is_live(&s.graph, other))
				score := link_score(s, slot, other)
				testing.expect(t, score == link_score(s, other, slot))
			}
		}
	}
	testing.expect(t, multi > 30 && multi < 150)
	dup := new_set(t, 3, .NOQUANT, 16, 0, 5)
	defer destroy(dup)
	for i in 0 ..< 5 {
		add_values(t, dup, fmt.tprintf("d%d", i), {1, 2, 3}, quant = .NOQUANT, sc = &sc)
	}
	add_values(t, dup, "other", {-1, 0, 0}, quant = .NOQUANT, sc = &sc)
	twins := 0
	for i in 0 ..< 5 {
		slot, _ := find(dup, bytes_of(fmt.tprintf("d%d", i)))
		if hnsw.is_twin(&dup.graph, slot) {
			twins += 1
			testing.expect_value(t, link_layers(dup, slot), 1)
			links := layer_links(dup, slot, 0, &buf)
			testing.expect_value(t, len(links), 1)
			testing.expect(t, !hnsw.is_twin(&dup.graph, links[0]))
			score := link_score(dup, slot, links[0])
			testing.expectf(t, abs(score - 1) < 1e-6, "twin edge score %v", score)
		}
	}
	testing.expect_value(t, twins, 3)
	testing.expect_value(t, info(dup).size, 6)
	req := Search_Request{kind = .Vector, vector = {1, 2, 3}, count = 6}
	hits: [dynamic]Hit
	defer delete(hits)
	search(dup, &req, &sc, &hits)
	testing.expect_value(t, len(hits), 6)
	for h, i in hits[:5] {
		testing.expectf(t, name_text(dup, h.slot) == fmt.tprintf("d%d", i), "tie order %d: %s", i, name_text(dup, h.slot))
	}
	for i in 0 ..< 4 {
		removed, _, _ := remove(dup, bytes_of(fmt.tprintf("d%d", i)), &sc)
		testing.expect(t, removed)
		check_invariants(t, dup)
	}
	testing.expect_value(t, card(dup), 2)
}

@(test)
failure_texts_match_the_reference :: proc(t: ^testing.T) {
	Case :: struct {
		f:    Failure,
		text: string,
	}
	cases := []Case {
		{failure(.Dimension_Mismatch, 3, 2), "ERR Vector dimension mismatch - got 3 but set has 2"},
		{failure(.Projection_Input_Mismatch, 5, 8), "ERR Input dimension mismatch for projection - got 5 but projection expects 8"},
		{failure(.Quantization_Mismatch), "ERR asked quantization mismatch with existing vector set"},
		{failure(.M_Mismatch), "ERR asked M value mismatch with existing vector set"},
		{failure(.Projection_Not_Allowed), "ERR cannot add projection to existing set without projection"},
		{failure(.Element_Not_Found), "ERR element not found in set"},
		{Failure{err = .Filter_Syntax, near = ".n &\r\n .b\r\n"}, "ERR syntax error in FILTER expression near: .n &   .b"},
	}
	for c in cases {
		text, err := failure_text(c.f, context.temp_allocator)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, text, c.text)
	}
	s := new_set(t, 2)
	defer destroy(s)
	add_values(t, s, "a", {1, 0})
	check :: proc(t: ^testing.T, s: Vset, req: Add_Request, want: Error, got := 0, expected := 0) {
		r := req
		added, f := add(s, &r)
		testing.expect(t, !added)
		testing.expectf(t, f.err == want && f.got == got && f.expected == expected, "%v against %v", f, want)
	}
	check(t, s, Add_Request{name = bytes_of("e"), vector = {1, 0, 0}, quant = .BIN}, .Quantization_Mismatch)
	check(t, s, Add_Request{name = bytes_of("e"), vector = {1, 0, 0}, m = 32}, .M_Mismatch)
	check(t, s, Add_Request{name = bytes_of("e"), vector = {1, 0}, reduce = 1}, .Projection_Not_Allowed)
	check(t, s, Add_Request{name = bytes_of("e"), vector = {1, 0, 0}, reduce = 1}, .Dimension_Mismatch, 3, 2)
	check(t, s, Add_Request{name = bytes_of("e"), vector = {1, 0, 0}}, .Dimension_Mismatch, 3, 2)
	rd := new_set(t, 8, .Q8, 0, 3)
	defer destroy(rd)
	eight := []f32{1, 2, 3, 4, 5, 6, 7, 8}
	testing.expect(t, add_values(t, rd, "a", eight, reduce = 3))
	check(t, rd, Add_Request{name = bytes_of("c"), vector = eight}, .Dimension_Mismatch, 8, 3)
	check(t, rd, Add_Request{name = bytes_of("c"), vector = eight, reduce = 4}, .Dimension_Mismatch, 8, 3)
	check(t, rd, Add_Request{name = bytes_of("c"), vector = {1, 1, 1}, reduce = 3}, .Projection_Input_Mismatch, 3, 8)
	check(t, rd, Add_Request{name = bytes_of("c"), vector = {1, 1, 1}}, .Dimension_Mismatch, 3, 3)
	testing.expect_value(t, card(rd), 1)
	testing.expect(t, !contains(s, bytes_of("e")))
}

@(test)
rewrite_forms_and_their_exactness :: proc(t: ^testing.T) {
	r := Test_Rng{state = 0xA0F}
	for quant in Quant {
		original := new_set(t, 24, quant)
		replayed := new_set(t, 24, quant)
		x := make([]f32, 24)
		y := make([]f32, 24)
		codes, norms, ranges, total := 0, 0, 0, 400
		for i in 0 ..< total {
			random_vector(&r, x)
			if i % 4 == 0 {
				for &v in x {
					v *= 1000
				}
			}
			name := fmt.tprintf("r%d", i)
			add_values(t, original, name, x, quant = quant)
			slot, _ := find(original, bytes_of(name))
			embedding(original, slot, y)
			add_values(t, replayed, name, y, quant = quant)
			other, _ := find(replayed, bytes_of(name))
			a := raw_embedding(original, slot)
			b := raw_embedding(replayed, other)
			if string(a.data) == string(b.data) {
				codes += 1
			}
			if a.norm == b.norm {
				norms += 1
			}
			if a.range == b.range {
				ranges += 1
			}
		}
		log.infof("rewrite through VEMB values, %v: stored codes %d of %d, norms %d, ranges %d", quant, codes, total, norms, ranges)
		if quant == .BIN {
			testing.expect_value(t, codes, total)
		}
		delete(x)
		delete(y)
		destroy(original)
		destroy(replayed)
		free_all(context.temp_allocator)
	}
	_ = math.PI
}

@(test)
empty_attribute_on_a_new_element_is_kept :: proc(t: ^testing.T) {
	s := new_set(t, 2)
	defer destroy(s)
	testing.expect(t, add_values(t, s, "a", {1, 0}, attr = "", set_attr = true))
	text, has := get_attribute(s, bytes_of("a"))
	testing.expect(t, has && text == "")
	testing.expect_value(t, info(s).attributes_count, 1)
	hits: [dynamic]Hit
	defer delete(hits)
	req := Search_Request{kind = .Vector, vector = {1, 0}, use_filter = true, filter = "1 == 1"}
	search(s, &req, nil, &hits)
	testing.expect_value(t, len(hits), 1)
	clear(&hits)
	field := Search_Request{kind = .Vector, vector = {1, 0}, use_filter = true, filter = ".x == 1"}
	search(s, &field, nil, &hits)
	testing.expect_value(t, len(hits), 0)
	blob, _ := serialize_bytes(s)
	back, err := deserialize(blob)
	delete(blob)
	testing.expect_value(t, err, Decode_Error.None)
	text, has = get_attribute(back, bytes_of("a"))
	testing.expect(t, has && text == "")
	testing.expect_value(t, info(back).attributes_count, 1)
	destroy(back)
	testing.expect(t, !add_values(t, s, "a", {0, 1}, attr = "", set_attr = true))
	_, has = get_attribute(s, bytes_of("a"))
	testing.expect(t, !has)
	testing.expect_value(t, info(s).attributes_count, 0)
	add_values(t, s, "b", {0, 1}, attr = "", set_attr = true)
	found, aerr := set_attribute(s, bytes_of("b"), nil)
	testing.expect(t, found && aerr == .None)
	_, has = get_attribute(s, bytes_of("b"))
	testing.expect(t, !has)
	testing.expect_value(t, info(s).attributes_count, 0)
	testing.expect_value(t, repeat_total(min(i64)), u64(1) << 63)
	testing.expect_value(t, repeat_total(-12), u64(12))
	testing.expect_value(t, repeat_total(5), u64(0))
	check_invariants(t, s)
}
