package hyperloglog_test

import "core:math"
import "core:testing"
import hll "../../src/hll"

@(test)
estimator_matches_dataset_counts :: proc(t: ^testing.T) {
	Step :: struct {
		n:      int,
		count:  u64,
		dense:  bool,
		strlen: int,
	}
	steps := [?]Step {
		{1, 1, false, 21},
		{2, 2, false, 24},
		{3, 3, false, 27},
		{5, 5, false, 33},
		{10, 10, false, 48},
		{20, 20, false, 77},
		{50, 50, false, 157},
		{100, 100, false, 285},
		{200, 200, false, 513},
		{500, 506, false, 1068},
		{1000, 1008, false, 1906},
		{2000, 2000, true, 12304},
		{5000, 4968, true, 12304},
		{10000, 9973, true, 12304},
		{20000, 19901, true, 12304},
		{50000, 49978, true, 12304},
		{100000, 100853, true, 12304},
		{200000, 200859, true, 12304},
	}
	buf := hll.hll_new_sparse()
	defer hll.hll_free(buf)
	names := make([][32]u8, 1000)
	defer delete(names)
	elems := make([][]u8, 1000)
	defer delete(elems)
	added := 0
	for step in steps {
		for added < step.n {
			batch := min(1000, step.n - added)
			for k in 0 ..< batch {
				elems[k] = elem_name(names[k][:], "e", added + k)
			}
			_, err := hll.hll_pfadd(&buf, elems[:batch], false)
			testing.expect_value(t, err, hll.Error.None)
			added += batch
		}
		invalid := false
		count := hll.hll_count(buf, &invalid)
		testing.expectf(t, !invalid && count == step.count, "n=%d: count %d want %d", step.n, count, step.count)
		testing.expectf(t, (buf[4] == hll.HLL_DENSE) == step.dense, "n=%d: encoding", step.n)
		testing.expectf(t, len(buf) == step.strlen, "n=%d: strlen %d want %d", step.n, len(buf), step.strlen)
	}
	header := hex_encode(buf[:16])
	testing.expect_value(t, header, "48594c4c000000009b10030000000000")
	delete(header)
	one := [1][]u8{transmute([]u8)string("newone")}
	hll.hll_pfadd(&buf, one[:], false)
	header = hex_encode(buf[:16])
	testing.expect_value(t, header, "48594c4c000000009b10030000000080")
	delete(header)
	invalid := false
	testing.expect_value(t, hll.hll_count(buf, &invalid), 200885)
	header = hex_encode(buf[:16])
	testing.expect_value(t, header, "48594c4c00000000b510030000000000")
	delete(header)
	regs: [hll.HLL_REGISTERS]u8
	hll.hll_get_registers(buf, &regs)
	testing.expect_value(t, hll.hll_estimate_raw(&regs), 200885)
}

@(test)
estimator_helpers :: proc(t: ^testing.T) {
	testing.expect(t, math.is_inf(hll.hll_sigma(1), 1))
	testing.expect_value(t, hll.hll_sigma(0), 0)
	testing.expect_value(t, hll.hll_tau(0), 0)
	testing.expect_value(t, hll.hll_tau(1), 0)
	testing.expect(t, hll.hll_sigma(0.5) > 0.5)
	testing.expect(t, hll.hll_tau(0.5) > 0)
	testing.expect_value(t, hll.HLL_ALPHA_INF, 0.5 / math.ln(f64(2)))
	testing.expect_value(t, hll.llround_to_u64(2.5), 3)
	testing.expect_value(t, hll.llround_to_u64(2.4999999999999996), 2)
	testing.expect_value(t, hll.llround_to_u64(0.49999999999999994), 0)
	testing.expect_value(t, hll.llround_to_u64(-2.5), transmute(u64)i64(-3))
	testing.expect_value(t, hll.llround_to_u64(math.inf_f64(1)), 0x8000000000000000)
	testing.expect_value(t, hll.llround_to_u64(math.nan_f64()), 0x8000000000000000)
	testing.expect_value(t, hll.llround_to_u64(1e19), 0x8000000000000000)

	regs: [hll.HLL_REGISTERS]u8
	testing.expect_value(t, hll.hll_estimate_raw(&regs), 0)
	regs[100] = 1
	testing.expect_value(t, hll.hll_estimate_raw(&regs), 1)
	for &r in regs {
		r = 63
	}
	testing.expect_value(t, hll.hll_estimate_raw(&regs), 0x8000000000000000)

	d63 := make([]u8, hll.HLL_DENSE_SIZE)
	defer delete(d63)
	copy(d63, "HYLL")
	for i in hll.HLL_HDR_SIZE ..< len(d63) {
		d63[i] = 0xff
	}
	d63[15] = 0x80
	invalid := false
	card := hll.hll_count(d63, &invalid)
	testing.expect(t, !invalid)
	testing.expect_value(t, i64(card), min(i64))
	testing.expect(t, !hll.hll_cache_valid(d63))
	header := hex_encode(d63[:16])
	defer delete(header)
	testing.expect_value(t, header, "48594c4c000000000000000000000080")
	add_a := [1][]u8{transmute([]u8)string("a")}
	updated, _ := hll.hll_pfadd(&d63, add_a[:], false)
	testing.expect_value(t, updated, 0)
	both := [2][]u8{d63, d63}
	union_card, err := hll.hll_count_union(both[:])
	testing.expect_value(t, err, hll.Error.None)
	testing.expect_value(t, union_card, 0x8000000000000000)
}
