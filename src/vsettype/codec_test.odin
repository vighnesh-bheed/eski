package vsettype

import "core:fmt"
import "core:testing"

expect_same_sets :: proc(t: ^testing.T, a: Vset, b: Vset, r: ^Test_Rng, sc: ^Scratch) -> bool {
	if !testing.expect_value(t, card(b), card(a)) {
		return false
	}
	ia := info(a)
	ib := info(b)
	testing.expect(t, ia.quant == ib.quant && ia.m == ib.m && ia.dim == ib.dim && ia.projection_input_dim == ib.projection_input_dim)
	testing.expect(t, ia.size == ib.size && ia.attributes_count == ib.attributes_count && ia.max_node_uid == ib.max_node_uid)
	testing.expect(t, ia.vset_uid != ib.vset_uid)
	it := element_iterator(a)
	same := true
	for slot in next_element(&it) {
		name := element_name(a, slot)
		other, ok := find(b, name)
		if !testing.expectf(t, ok, "element %q lost", string(name)) {
			return false
		}
		ra := raw_embedding(a, slot)
		rb := raw_embedding(b, other)
		ta, ha := element_attribute(a, slot)
		tb, hb := element_attribute(b, other)
		ok = string(ra.data) == string(rb.data) && transmute(u32)ra.norm == transmute(u32)rb.norm && transmute(u32)ra.range == transmute(u32)rb.range
		ok = ok && ha == hb && ta == tb && element_seq(a, slot) == element_seq(b, other)
		if !testing.expectf(t, ok, "element %q differs after the round trip", string(name)) {
			same = false
		}
	}
	q := make([]f32, a.input_dim if a.input_dim > 0 else a.dim, context.temp_allocator)
	for _ in 0 ..< 8 {
		random_vector(r, q)
		req := Search_Request{kind = .Vector, vector = q, count = 7, truth = true}
		ha, hb: [dynamic]Hit
		testing.expect_value(t, search(a, &req, sc, &ha).err, Error.None)
		testing.expect_value(t, search(b, &req, sc, &hb).err, Error.None)
		testing.expect_value(t, len(hb), len(ha))
		for h, i in ha {
			if i < len(hb) {
				testing.expect(t, string(element_name(a, h.slot)) == string(element_name(b, hb[i].slot)) && transmute(u64)h.score == transmute(u64)hb[i].score)
			}
		}
		if card(a) <= 64 {
			ga, gb: [dynamic]Hit
			wide := Search_Request{kind = .Vector, vector = q, count = card(a), ef = 500}
			search(a, &wide, sc, &ga)
			search(b, &wide, sc, &gb)
			testing.expect_value(t, len(gb), len(ga))
			for h, i in ga {
				if i < len(gb) {
					testing.expect(t, string(element_name(a, h.slot)) == string(element_name(b, gb[i].slot)))
				}
			}
			delete(ga)
			delete(gb)
		}
		delete(ha)
		delete(hb)
	}
	return same
}

random_round_trip_set :: proc(t: ^testing.T, r: ^Test_Rng, quant: Quant, dim: int, reduce: int, n: int, sc: ^Scratch) -> Vset {
	s := new_set(t, dim, quant, 0, reduce)
	x := make([]f32, dim)
	defer delete(x)
	for i in 0 ..< n {
		random_vector(r, x)
		name := fmt.tprintf("k%d", test_below(r, n * 2))
		attr := ""
		set := test_below(r, 2) == 0
		if set {
			attr = fmt.tprintf(`{{"i":%d}}`, i)
		}
		req := Add_Request{name = bytes_of(name), vector = x, quant = quant, reduce = reduce, attr = bytes_of(attr), set_attr = set}
		_, f := add(s, &req, sc)
		testing.expect_value(t, f.err, Error.None)
		if test_below(r, 9) == 0 && card(s) > 1 {
			remove(s, bytes_of(fmt.tprintf("k%d", test_below(r, n * 2))), sc)
		}
	}
	return s
}

@(test)
codec_round_trips_are_lossless :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	Shape :: struct {
		quant:  Quant,
		dim:    int,
		reduce: int,
		n:      int,
	}
	shapes := []Shape{{.Q8, 3, 0, 40}, {.NOQUANT, 17, 0, 60}, {.BIN, 70, 0, 50}, {.BIN, 64, 0, 30}, {.Q8, 9, 4, 40}, {.NOQUANT, 1, 0, 10}, {.Q8, 300, 0, 20}}
	r := Test_Rng{state = 0xC0DEC}
	for shape in shapes {
		s := random_round_trip_set(t, &r, shape.quant, shape.dim, shape.reduce, shape.n, &sc)
		blob, err := serialize_bytes(s)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, len(blob), serialized_size(s))
		back, derr := deserialize(blob, &sc)
		if testing.expect_value(t, derr, Decode_Error.None) {
			expect_same_sets(t, s, back, &r, &sc)
			check_invariants(t, back)
			again, _ := serialize_bytes(back)
			testing.expect_value(t, string(again), string(blob))
			delete(again)
			destroy(back)
		}
		delete(blob)
		destroy(s)
		free_all(context.temp_allocator)
	}
}

expect_decode_safe :: proc(t: ^testing.T, data: []u8, sc: ^Scratch) -> bool {
	s, err := deserialize(data, sc)
	if err != .None {
		testing.expect(t, s == nil)
		return false
	}
	check_invariants(t, s)
	again, _ := serialize_bytes(s)
	back, berr := deserialize(again, sc)
	testing.expect_value(t, berr, Decode_Error.None)
	if back != nil {
		testing.expect_value(t, card(back), card(s))
		destroy(back)
	}
	delete(again)
	destroy(s)
	return true
}

@(test)
codec_rejects_malformed_input_without_crashing :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0xF422}
	accepted := 0
	rejected := 0
	for shape in 0 ..< 6 {
		quant := Quant(shape % 3)
		s := random_round_trip_set(t, &r, quant, 2 + shape * 13, 1 if shape == 4 else 0, 12, &sc)
		blob, _ := serialize_bytes(s)
		for cut in 0 ..< len(blob) {
			_, err := deserialize(blob[:cut], &sc)
			testing.expectf(t, err != .None, "prefix of %d bytes was accepted", cut)
			rejected += 1
		}
		mutated := make([]u8, len(blob) + 16)
		for round in 0 ..< 1500 {
			n := len(blob)
			copy(mutated, blob)
			switch round % 5 {
			case 0:
				at := test_below(&r, n)
				mutated[at] ~= u8(1) << uint(test_below(&r, 8))
			case 1:
				for _ in 0 ..< 1 + test_below(&r, 6) {
					mutated[test_below(&r, n)] = u8(test_next(&r))
				}
			case 2:
				at := test_below(&r, min(n, 16))
				specials := []u8{0, 1, 0x7F, 0x80, 0xFF}
				mutated[at] = specials[test_below(&r, 5)]
			case 3:
				for i in n ..< n + 16 {
					mutated[i] = u8(test_next(&r))
				}
				n += 1 + test_below(&r, 16)
			case 4:
				at := test_below(&r, n)
				span := 1 + test_below(&r, 8)
				for i in at ..< min(n, at + span) {
					mutated[i] = 0xFF
				}
			}
			if expect_decode_safe(t, mutated[:n], &sc) {
				accepted += 1
			} else {
				rejected += 1
			}
		}
		for _ in 0 ..< 300 {
			n := test_below(&r, 64)
			for i in 0 ..< n {
				mutated[i] = u8(test_next(&r))
			}
			if n >= 3 {
				mutated[0], mutated[1], mutated[2] = 'E', 'V', 'S'
			}
			if n >= 4 {
				mutated[3] = CODEC_VERSION
			}
			if expect_decode_safe(t, mutated[:n], &sc) {
				accepted += 1
			} else {
				rejected += 1
			}
		}
		delete(mutated)
		delete(blob)
		destroy(s)
	}
	testing.expect(t, rejected > 0 && accepted > 0)
}

@(test)
codec_bounds_allocation_by_input :: proc(t: ^testing.T) {
	header := []u8{'E', 'V', 'S', CODEC_VERSION, 0, 0x80, 0x80, 0x20, 0, 16, 0xFF, 0xFF, 0xFF, 0xFF, 0x07, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F}
	_, err := deserialize(header)
	testing.expect_value(t, err, Decode_Error.Truncated)
	big_m := []u8{'E', 'V', 'S', CODEC_VERSION, 0, 2, 0, 0xFF, 0xFF, 0x02, 1, 1}
	_, err = deserialize(big_m)
	testing.expect_value(t, err, Decode_Error.Bad_Header)
	empty := []u8{'E', 'V', 'S', CODEC_VERSION, 0, 2, 0, 16, 0, 0}
	_, err = deserialize(empty)
	testing.expect_value(t, err, Decode_Error.Empty)
	overlong := []u8{'E', 'V', 'S', CODEC_VERSION, 0, 0x82, 0x00, 0, 16, 1, 1}
	_, err = deserialize(overlong)
	testing.expect_value(t, err, Decode_Error.Bad_Header)
	_, err = deserialize([]u8{'E', 'V', 'X', CODEC_VERSION})
	testing.expect_value(t, err, Decode_Error.Bad_Magic)
	_, err = deserialize([]u8{'E', 'V', 'S', 9, 0})
	testing.expect_value(t, err, Decode_Error.Bad_Version)
}

@(test)
codec_rejects_dirty_binary_padding_and_duplicates :: proc(t: ^testing.T) {
	s := new_set(t, 3, .BIN)
	defer destroy(s)
	add_values(t, s, "a", {1, -1, 1}, quant = .BIN)
	add_values(t, s, "b", {-1, 1, 1}, quant = .BIN)
	blob, _ := serialize_bytes(s)
	defer delete(blob)
	dirty := make([]u8, len(blob))
	defer delete(dirty)
	copy(dirty, blob)
	at := header_size(s) + 1 + 1 + 1
	dirty[at] |= 0x80
	_, err := deserialize(dirty)
	testing.expect_value(t, err, Decode_Error.Bad_Element)
	copy(dirty, blob)
	second := header_size(s) + element_encoded_size(s, s.order[0])
	dirty[second + 2] = 'a'
	_, err = deserialize(dirty)
	testing.expect_value(t, err, Decode_Error.Duplicate_Name)
	q8 := new_set(t, 2)
	defer destroy(q8)
	add_values(t, q8, "a", {1, -1})
	qblob, _ := serialize_bytes(q8)
	defer delete(qblob)
	qblob[header_size(q8) + 3] = 0x80
	_, err = deserialize(qblob)
	testing.expect_value(t, err, Decode_Error.Bad_Element)
	copy(dirty, blob)
	norm_at := header_size(s) + 1 + 1 + 1 + 8
	dirty[norm_at + 3] |= 0x80
	_, err = deserialize(dirty)
	testing.expect_value(t, err, Decode_Error.Bad_Element)
}
