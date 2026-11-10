package vsettype

import "core:fmt"
import "core:log"
import "core:testing"

Reference_Row :: struct {
	quant:     Quant,
	dim:       int,
	usage:     [3]int,
}

REFERENCE_MEMORY :: [9]Reference_Row {
	{.NOQUANT, 8, {2530, 73290, 716490}},
	{.NOQUANT, 32, {2634, 82890, 812490}},
	{.NOQUANT, 300, {3706, 190090, 1884490}},
	{.Q8, 8, {2506, 70882, 692482}},
	{.Q8, 32, {2530, 73282, 716482}},
	{.Q8, 300, {2798, 100082, 984482}},
	{.BIN, 8, {2506, 70882, 692482}},
	{.BIN, 32, {2506, 70882, 692482}},
	{.BIN, 300, {2538, 74082, 724490}},
}

@(test)
memory_usage_against_the_reference_table :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	sizes := [3]int{1, 100, 1000}
	rows := REFERENCE_MEMORY
	r := Test_Rng{state = 0x3E3}
	for row in rows {
		ours: [3]int
		for n, i in sizes {
			s := new_set(t, row.dim, row.quant)
			x := make([]f32, row.dim)
			for k in 0 ..< n {
				random_vector(&r, x)
				name := fmt.tprintf("e%d", k)
				req := Add_Request{name = bytes_of(name), vector = x, quant = row.quant}
				_, f := add(s, &req, &sc)
				testing.expect_value(t, f.err, Error.None)
			}
			ours[i] = memory_usage(s)
			testing.expect_value(t, ledger_balance(s), 0)
			testing.expectf(t, ours[i] < row.usage[i], "%v dim %d n %d uses %d bytes, reference %d", row.quant, row.dim, n, ours[i], row.usage[i])
			delete(x)
			destroy(s)
			free_all(context.temp_allocator)
		}
		slope := f64(ours[2] - ours[1]) / 900
		ref_slope := f64(row.usage[2] - row.usage[1]) / 900
		log.infof("memory %v dim %d: ours %v reference %v, bytes per vector %.1f against %.1f (%.2f)", row.quant, row.dim, ours, row.usage, slope, ref_slope, slope / ref_slope)
	}
}

@(test)
memory_usage_tracks_every_allocation :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x3E4}
	s := new_set(t, 16, .Q8)
	defer destroy(s)
	x := make([]f32, 16)
	defer delete(x)
	before := memory_usage(s)
	for i in 0 ..< 600 {
		random_vector(&r, x)
		name := fmt.tprintf("n%d", test_below(&r, 400))
		attr := fmt.tprintf(`{{"long":"%s"}}`, name)
		req := Add_Request{name = bytes_of(name), vector = x, attr = bytes_of(attr), set_attr = i % 3 == 0}
		add(s, &req, &sc)
		if i % 5 == 0 {
			remove(s, bytes_of(fmt.tprintf("n%d", test_below(&r, 400))), &sc)
		}
		if i % 50 == 0 {
			testing.expect_value(t, ledger_balance(s), 0)
		}
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, ledger_balance(s), 0)
	testing.expect(t, memory_usage(s) > before)
	it := element_iterator(s)
	names := make([dynamic]string)
	defer {
		for n in names {
			delete(n)
		}
		delete(names)
	}
	for slot in next_element(&it) {
		append(&names, string_clone(name_text(s, slot)))
	}
	for n in names {
		remove(s, bytes_of(n), &sc)
	}
	testing.expect_value(t, card(s), 0)
	testing.expect_value(t, ledger_balance(s), 0)
}
