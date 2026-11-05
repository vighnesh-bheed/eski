package hyperloglog_test

import "core:testing"
import hll "../../src/hll"

@(private = "file")
EMPTY_HEADER :: "48594c4c010000000000000000000000"

@(private = "file")
set_reg :: proc(t: ^testing.T, d: ^[dynamic]u8, index: int, count: u8, limit := hll.HLL_SPARSE_MAX_BYTES_DEFAULT) -> bool {
	changed, err := hll.hll_dyn_set(d, index, count, limit)
	testing.expect_value(t, err, hll.Error.None)
	return changed
}

@(private = "file")
expect_body :: proc(t: ^testing.T, d: []u8, body_hex: string, decoded: string, loc := #caller_location) {
	got_hex := hex_encode(d[hll.HLL_HDR_SIZE:])
	defer delete(got_hex)
	got_decoded := decode_string(d)
	defer delete(got_decoded)
	testing.expect_value(t, got_hex, body_hex, loc = loc)
	testing.expect_value(t, got_decoded, decoded, loc = loc)
}

@(test)
sparse_single_register_boundaries :: proc(t: ^testing.T) {
	Case :: struct {
		index:   int,
		count:   u8,
		body:    string,
		decoded: string,
	}
	cases := [?]Case {
		{0, 1, "807ffe", "v:1,1 Z:16383"},
		{16383, 32, "7ffefc", "Z:16383 v:32,1"},
		{1, 1, "00807ffd", "z:1 v:1,1 Z:16382"},
		{63, 1, "3e807fbf", "z:63 v:1,1 Z:16320"},
		{64, 1, "3f807fbe", "z:64 v:1,1 Z:16319"},
		{65, 1, "4040807fbd", "Z:65 v:1,1 Z:16318"},
		{16320, 1, "7fbf803e", "Z:16320 v:1,1 z:63"},
		{16319, 1, "7fbe803f", "Z:16319 v:1,1 z:64"},
		{16318, 1, "7fbd804040", "Z:16318 v:1,1 Z:65"},
		{8000, 17, "5f3fc060be", "Z:8000 v:17,1 Z:8383"},
	}
	for c in cases {
		d := dyn_from(hll.HLL_EMPTY_SPARSE[:])
		testing.expect(t, set_reg(t, &d, c.index, c.count))
		expect_body(t, d[:], c.body, c.decoded)
		testing.expect(t, !set_reg(t, &d, c.index, c.count))
		testing.expect(t, !set_reg(t, &d, c.index, 1))
		value, found := hll.sparse_register_at(d[:], c.index)
		testing.expect(t, found)
		testing.expect_value(t, value, int(c.count))
		delete(d)
	}
	empty := decode_string(hll.HLL_EMPTY_SPARSE[:])
	defer delete(empty)
	testing.expect_value(t, empty, "Z:16384")
	header_only := hex_decode(EMPTY_HEADER)
	defer delete(header_only)
	nothing := decode_string(header_only)
	defer delete(nothing)
	testing.expect_value(t, nothing, "")
	invalid := false
	testing.expect_value(t, hll.hll_estimate(header_only, &invalid), 0)
	testing.expect(t, invalid)
}

@(test)
sparse_value_runs_merge_locally :: proc(t: ^testing.T) {
	up := dyn_from(hll.HLL_EMPTY_SPARSE[:])
	defer delete(up)
	ascending := [?]string{"09807ff4", "09817ff3", "09827ff2", "09837ff1", "0983807ff0"}
	for want, i in ascending {
		set_reg(t, &up, 10 + i, 1)
		got := hex_encode(up[hll.HLL_HDR_SIZE:])
		testing.expect_value(t, got, want)
		delete(got)
	}
	down := dyn_from(hll.HLL_EMPTY_SPARSE[:])
	defer delete(down)
	descending := [?]string{"0d807ff0", "0c817ff0", "0b827ff0", "0a837ff0", "0980837ff0"}
	for want, i in descending {
		set_reg(t, &down, 14 - i, 1)
		got := hex_encode(down[hll.HLL_HDR_SIZE:])
		testing.expect_value(t, got, want)
		delete(got)
	}
	expect_body(t, down[:], "0980837ff0", "z:10 v:1,1 v:1,4 Z:16369")

	split := dyn_from(hll.HLL_EMPTY_SPARSE[:])
	defer delete(split)
	for i in 10 ..< 14 {
		set_reg(t, &split, i, 1)
	}
	testing.expect(t, set_reg(t, &split, 11, 3))
	expect_body(t, split[:], "098088817ff1", "z:10 v:1,1 v:3,1 v:1,2 Z:16370")
	testing.expect(t, !set_reg(t, &split, 11, 3))
	testing.expect(t, set_reg(t, &split, 12, 2))
	expect_body(t, split[:], "09808884807ff1", "z:10 v:1,1 v:3,1 v:2,1 v:1,1 Z:16370")

	gap := dyn_from(hll.HLL_EMPTY_SPARSE[:])
	defer delete(gap)
	for i in ([?]int{0, 2, 3, 4, 5}) {
		set_reg(t, &gap, i, 1)
	}
	expect_body(t, gap[:], "8000837ff9", "v:1,1 z:1 v:1,4 Z:16378")
	set_reg(t, &gap, 1, 1)
	expect_body(t, gap[:], "81837ff9", "v:1,2 v:1,4 Z:16378")

	inplace := dyn_from(hll.HLL_EMPTY_SPARSE[:])
	defer delete(inplace)
	set_reg(t, &inplace, 20, 2)
	set_reg(t, &inplace, 22, 2)
	set_reg(t, &inplace, 21, 1)
	expect_body(t, inplace[:], "138480847fe8", "z:20 v:2,1 v:1,1 v:2,1 Z:16361")
	set_reg(t, &inplace, 21, 2)
	expect_body(t, inplace[:], "13867fe8", "z:20 v:2,3 Z:16361")
}

@(test)
sparse_value_limit_promotes :: proc(t: ^testing.T) {
	d := dyn_from(hll.HLL_EMPTY_SPARSE[:])
	defer delete(d)
	set_reg(t, &d, 5, 32)
	expect_body(t, d[:], "04fc7ff9", "z:5 v:32,1 Z:16378")
	testing.expect(t, set_reg(t, &d, 7, 33))
	testing.expect_value(t, len(d), hll.HLL_DENSE_SIZE)
	testing.expect_value(t, d[4], hll.HLL_DENSE)
	regs := d[hll.HLL_HDR_SIZE:]
	testing.expect_value(t, hll.dense_get(regs, 5), 32)
	testing.expect_value(t, hll.dense_get(regs, 7), 33)
	testing.expect_value(t, hll.dense_get(regs, 6), 0)
}

@(test)
sparse_cumulative_observed_bytes :: proc(t: ^testing.T) {
	steps := [?]string {
		"48594c4c01000000000000000000008071a6844e57",
		"48594c4c01000000000000000000008071a6844bfb80425a",
		"48594c4c01000000000000000000008060f38050b1844bfb80425a",
		"48594c4c0100000000000000000000805c7b8044768050b1844bfb80425a",
		"48594c4c0100000000000000000000805c7b8044768050b184498c80426d80425a",
		"48594c4c010000000000000000000080466d80560c8044768050b184498c80426d80425a",
		"48594c4c010000000000000000000080466d80560c80443c84388050b184498c80426d80425a",
		"48594c4c010000000000000000000080466d80560c80443c8438804dc28042ed84498c80426d80425a",
		"48594c4c010000000000000000000080466d8049e8804c2280443c8438804dc28042ed84498c80426d80425a",
		"48594c4c010000000000000000000080466d8049e8804c2280443c843880423d804b838042ed84498c80426d80425a",
	}
	names := "abcdefghij"
	buf := hll.hll_new_sparse()
	defer hll.hll_free(buf)
	for want, i in steps {
		elems := [1][]u8{transmute([]u8)names[i:i + 1]}
		updated, err := hll.hll_pfadd(&buf, elems[:], false)
		testing.expect_value(t, err, hll.Error.None)
		testing.expect_value(t, updated, 1)
		got := hex_encode(buf)
		testing.expect_value(t, got, want)
		delete(got)
	}
	invalid := false
	testing.expect_value(t, hll.hll_count(buf, &invalid), 10)
	header := hex_encode(buf[:16])
	defer delete(header)
	testing.expect_value(t, header, "48594c4c010000000a00000000000000")
	again := [1][]u8{transmute([]u8)string("a")}
	updated, _ := hll.hll_pfadd(&buf, again[:], false)
	testing.expect_value(t, updated, 0)
	none: [][]u8
	updated, _ = hll.hll_pfadd(&buf, none, false)
	testing.expect_value(t, updated, 0)
	decoded := decode_string(buf)
	defer delete(decoded)
	testing.expect_value(t, decoded, "Z:1646 v:1,1 Z:2537 v:1,1 Z:3107 v:1,1 Z:1085 v:2,1 z:57 v:1,1 Z:574 v:1,1 Z:2948 v:1,1 Z:750 v:2,1 Z:2445 v:1,1 Z:622 v:1,1 Z:603")
	regs: [hll.HLL_REGISTERS]u8
	testing.expect_value(t, hll.hll_get_registers(buf, &regs), hll.Error.None)
	expected := [?][2]int{{1646, 1}, {4184, 1}, {7292, 1}, {8378, 2}, {8436, 1}, {9011, 1}, {11960, 1}, {12711, 2}, {15157, 1}, {15780, 1}}
	nonzero := 0
	for v in regs {
		if v != 0 {
			nonzero += 1
		}
	}
	testing.expect_value(t, nonzero, len(expected))
	for pair in expected {
		testing.expect_value(t, int(regs[pair[0]]), pair[1])
		value, err := hll.hll_get_register(buf, pair[0])
		testing.expect_value(t, err, hll.Error.None)
		testing.expect_value(t, int(value), pair[1])
	}
}

@(test)
sparse_truncated_two_byte_opcode :: proc(t: ^testing.T) {
	tr := hex_decode("48594c4c010000000000000000000080803f3f3f3d7f")
	defer delete(tr)
	decoded := decode_string(tr)
	defer delete(decoded)
	testing.expect_value(t, decoded, "v:1,1 z:64 z:64 z:64 z:62 Z:16129")
	invalid := false
	testing.expect_value(t, hll.hll_count(tr, &invalid), 1)
	testing.expect(t, !invalid)
	converted, err := hll.hll_to_dense(&tr)
	testing.expect(t, converted)
	testing.expect_value(t, err, hll.Error.None)
	testing.expect_value(t, hll.dense_get(tr[hll.HLL_HDR_SIZE:], 0), 1)

	tr2 := hex_decode("48594c4c010000000000000000000080803f3f3f3d7f")
	defer delete(tr2)
	steps := [?]string {
		"48594c4c010000000000000000000080803f3f3f3d6d798451",
		"48594c4c010000000000000000000080803f3f3f3d43de8869998451",
		"48594c4c010000000000000000000080803f3f3f3d43de8865a38043f48451",
		"48594c4c010000000000000000000080803f3f3f3d43de8865a38040808043728451",
	}
	names := [?]string{"t0", "t1", "t2", "t3"}
	for want, i in steps {
		elems := [1][]u8{transmute([]u8)names[i]}
		updated, add_err := hll.hll_pfadd(&tr2, elems[:], false)
		testing.expect_value(t, add_err, hll.Error.None)
		testing.expect_value(t, updated, 1)
		got := hex_encode(tr2)
		testing.expect_value(t, got, want)
		delete(got)
	}
	testing.expect_value(t, hll.hll_count(tr2, &invalid), 0)
	testing.expect(t, invalid)
}

@(test)
sparse_add_ignores_trailing_garbage :: proc(t: ^testing.T) {
	c1 := hex_decode("48594c4c01000000000000000000008060f38050b1844bfb80425a68656c6c6f")
	defer delete(c1)
	decoded := decode_string(c1)
	defer delete(decoded)
	testing.expect_value(t, decoded, "Z:8436 v:1,1 Z:4274 v:2,1 Z:3068 v:1,1 Z:603 Z:10342 Z:11373 Z:12033")
	invalid := false
	testing.expect_value(t, hll.hll_count(c1, &invalid), 0)
	testing.expect(t, invalid)
	elems := [2][]u8{transmute([]u8)string("zz1"), transmute([]u8)string("zz2")}
	updated, err := hll.hll_pfadd(&c1, elems[:], false)
	testing.expect_value(t, err, hll.Error.None)
	testing.expect_value(t, updated, 1)
	got := hex_encode(c1)
	defer delete(got)
	testing.expect_value(t, got, "48594c4c01000000000000000000008047f68c58fb8041c4804eeb844bfb80425a68656c6c6f")
	regs: [hll.HLL_REGISTERS]u8
	testing.expect_value(t, hll.hll_get_registers(c1, &regs), hll.Error.Corrupted)
	converted, conv_err := hll.hll_to_dense(&c1)
	testing.expect(t, !converted)
	testing.expect_value(t, conv_err, hll.Error.Corrupted)

	long := make([]u8, 16 + 4000)
	defer delete(long)
	copy(long, hll.HLL_EMPTY_SPARSE[:16])
	long[15] = 0
	for i := 16; i < len(long); i += 2 {
		long[i] = 0x7f
		long[i + 1] = 0xff
	}
	before := hex_encode(long)
	defer delete(before)
	add_a := [1][]u8{transmute([]u8)string("a")}
	_, long_err := hll.hll_pfadd(&long, add_a[:], false)
	testing.expect_value(t, long_err, hll.Error.Corrupted)
	after := hex_encode(long)
	defer delete(after)
	testing.expect(t, before == after)
	invalid = false
	testing.expect_value(t, hll.hll_count(long, &invalid), 0)
	testing.expect(t, !invalid)
	long[15] = 0x80
	testing.expect_value(t, hll.hll_count(long, &invalid), 0)
	testing.expect(t, invalid)
	sources := [2][]u8{long, long}
	_, union_err := hll.hll_count_union(sources[:])
	testing.expect_value(t, union_err, hll.Error.Corrupted)

	short := make([]u8, 16 + 4)
	defer delete(short)
	copy(short, hll.HLL_EMPTY_SPARSE[:16])
	short[16], short[17], short[18], short[19] = 0x7f, 0xff, 0x7f, 0xff
	_, short_err := hll.hll_pfadd(&short, add_a[:], false)
	testing.expect_value(t, short_err, hll.Error.None)
	short_decoded := decode_string(short)
	defer delete(short_decoded)
	testing.expect_value(t, short_decoded, "Z:12711 v:2,1 Z:3672 Z:16384")
}

@(test)
promotion_at_limits :: proc(t: ^testing.T) {
	name_buf: [32]u8
	for limit in ([?]int{0, 30, 100, 500, 3000}) {
		buf := hll.hll_new_sparse()
		last_sparse := len(buf)
		promoted_at := -1
		for n in 0 ..< 5000 {
			elem := elem_name(name_buf[:], "e", n)
			index, count := hll.hll_pat_len(elem)
			current, _ := hll.sparse_register_at(buf, index)
			elems := [1][]u8{elem}
			_, err := hll.hll_pfadd(&buf, elems[:], false, limit)
			testing.expect_value(t, err, hll.Error.None)
			if buf[4] == hll.HLL_DENSE {
				promoted_at = n
				testing.expect(t, current < int(count))
				testing.expect(t, last_sparse <= limit || limit < hll.HLL_EMPTY_SPARSE_SIZE)
				break
			}
			testing.expectf(t, len(buf) <= max(limit, hll.HLL_EMPTY_SPARSE_SIZE), "limit %d: sparse length %d", limit, len(buf))
			last_sparse = len(buf)
		}
		testing.expectf(t, promoted_at >= 0, "limit %d never promoted", limit)
		if limit <= hll.HLL_EMPTY_SPARSE_SIZE {
			testing.expect_value(t, promoted_at, 0)
		}
		hll.hll_free(buf)
	}

	cm := hex_decode("48594c4c0100000000000000000000805057804c2280443c843880423d804b838042ed8441fc8c478e80426d80425a")
	defer delete(cm)
	add_a := [1][]u8{transmute([]u8)string("a")}
	updated, err := hll.hll_pfadd(&cm, add_a[:], false, 30)
	testing.expect_value(t, err, hll.Error.None)
	testing.expect_value(t, updated, 0)
	testing.expect_value(t, hll.hll_encoding_name(cm), "sparse")
	add_new := [1][]u8{transmute([]u8)string("new_element")}
	updated, err = hll.hll_pfadd(&cm, add_new[:], false, 30)
	testing.expect_value(t, updated, 1)
	testing.expect_value(t, hll.hll_encoding_name(cm), "dense")
	invalid := false
	testing.expect_value(t, hll.hll_count(cm, &invalid), 11)

	b1 := hll.hll_new_sparse()
	defer hll.hll_free(b1)
	two := [2][]u8{transmute([]u8)string("q"), transmute([]u8)string("r")}
	hll.hll_pfadd(&b1, two[:], false, 100)
	testing.expect_value(t, len(b1), 24)

	for spec in ([?][2]int{{100, 12304}, {200, 12304}, {3000, 698}}) {
		h := hll.hll_new_sparse()
		for n in 0 ..< 300 {
			elems := [1][]u8{elem_name(name_buf[:], "q", n)}
			hll.hll_pfadd(&h, elems[:], false, spec[0])
		}
		testing.expectf(t, len(h) == spec[1], "limit %d: length %d want %d", spec[0], len(h), spec[1])
		hll.hll_free(h)
	}
}

@(test)
sparse_set_allocator_api :: proc(t: ^testing.T) {
	buf := hll.hll_new_sparse()
	defer hll.hll_free(buf)
	changed, err := hll.sparse_set(&buf, 12711, 2, hll.HLL_SPARSE_MAX_BYTES_DEFAULT, context.allocator)
	testing.expect(t, changed)
	testing.expect_value(t, err, hll.Error.None)
	got := hex_encode(buf)
	testing.expect_value(t, got, "48594c4c01000000000000000000008071a6844e57")
	delete(got)
	changed, err = hll.sparse_set(&buf, 12711, 2, hll.HLL_SPARSE_MAX_BYTES_DEFAULT, context.allocator)
	testing.expect(t, !changed)
	changed, err = hll.sparse_set(&buf, 100, 1, 21, context.allocator)
	testing.expect(t, changed)
	testing.expect_value(t, hll.hll_encoding_name(buf), "dense")
	testing.expect_value(t, hll.dense_get(buf[hll.HLL_HDR_SIZE:], 100), 1)
	testing.expect_value(t, hll.dense_get(buf[hll.HLL_HDR_SIZE:], 12711), 2)
	changed, err = hll.sparse_set(&buf, 100, 40, 21, context.allocator)
	testing.expect(t, changed)
	testing.expect_value(t, hll.dense_get(buf[hll.HLL_HDR_SIZE:], 100), 40)

	other := hll.hll_new_sparse()
	defer hll.hll_free(other)
	changed, err = hll.sparse_set(&other, 9, 33, hll.HLL_SPARSE_MAX_BYTES_DEFAULT, context.allocator)
	testing.expect(t, changed)
	testing.expect_value(t, len(other), hll.HLL_DENSE_SIZE)
	not_hll := make([]u8, 4)
	defer delete(not_hll)
	_, err = hll.sparse_set(&not_hll, 0, 1, hll.HLL_SPARSE_MAX_BYTES_DEFAULT, context.allocator)
	testing.expect_value(t, err, hll.Error.Wrong_Type)
}
