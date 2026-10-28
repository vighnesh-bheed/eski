package hyperloglog_test

import "core:math/rand"
import "core:testing"
import hll "../../src/hll"

@(private = "file")
build :: proc(prefix: string, from, to: int, limit := hll.HLL_SPARSE_MAX_BYTES_DEFAULT) -> []u8 {
	buf := hll.hll_new_sparse()
	name_buf: [32]u8
	for n in from ..< to {
		elems := [1][]u8{elem_name(name_buf[:], prefix, n)}
		hll.hll_pfadd(&buf, elems[:], false, limit)
	}
	return buf
}

@(private = "file")
build_names :: proc(names: ..string) -> []u8 {
	buf := hll.hll_new_sparse()
	for name in names {
		elems := [1][]u8{transmute([]u8)name}
		hll.hll_pfadd(&buf, elems[:], false)
	}
	return buf
}

@(test)
merge_sparse_results_match_observed_bytes :: proc(t: ^testing.T) {
	s1 := build_names("x")
	s2 := build_names("y")
	defer hll.hll_free(s1)
	defer hll.hll_free(s2)
	s3: []u8
	srcs := [2][]u8{s1, s2}
	testing.expect_value(t, hll.hll_merge(&s3, false, srcs[:]), hll.Error.None)
	defer hll.hll_free(s3)
	got := hex_encode(s3)
	testing.expect_value(t, got, "48594c4c0100000000000000000000807a538845a08408")
	delete(got)
	only_s2 := [1][]u8{s2}
	testing.expect_value(t, hll.hll_merge(&s1, true, only_s2[:]), hll.Error.None)
	invalid := false
	testing.expect_value(t, hll.hll_count(s1, &invalid), 2)
	got = hex_encode(s1)
	testing.expect_value(t, got, "48594c4c0100000002000000000000007a538845a08408")
	delete(got)

	u1 := build_names("a", "b", "c")
	u2 := build_names("b", "c", "d")
	u3 := build_names("c", "d", "e")
	defer hll.hll_free(u1)
	defer hll.hll_free(u2)
	defer hll.hll_free(u3)
	u: []u8
	us := [3][]u8{u1, u2, u3}
	testing.expect_value(t, hll.hll_merge(&u, false, us[:]), hll.Error.None)
	defer hll.hll_free(u)
	testing.expect_value(t, hll.hll_count(u, &invalid), 5)
	got = hex_encode(u)
	testing.expect_value(t, got, "48594c4c0100000005000000000000005c7b8044768050b184498c80426d80425a")
	delete(got)

	empty: []u8
	testing.expect_value(t, hll.hll_merge(&empty, false, nil), hll.Error.None)
	defer hll.hll_free(empty)
	got = hex_encode(empty)
	testing.expect_value(t, got, "48594c4c0100000000000000000000807fff")
	delete(got)

	missing: []u8
	with_missing := [3][]u8{nil, u1, nil}
	testing.expect_value(t, hll.hll_merge(&missing, false, with_missing[:]), hll.Error.None)
	defer hll.hll_free(missing)
	testing.expect_value(t, hll.hll_count(missing, &invalid), 3)

	self2 := build_names("a", "b", "c")
	defer hll.hll_free(self2)
	testing.expect_value(t, hll.hll_merge(&self2, true, nil), hll.Error.None)
	got = hex_encode(self2)
	testing.expect_value(t, got, "48594c4c01000000000000000000008060f38050b1844bfb80425a")
	delete(got)
}

@(test)
merge_encoding_choice :: proc(t: ^testing.T) {
	sp := build_names("1")
	ds := build_names("2")
	defer hll.hll_free(sp)
	defer hll.hll_free(ds)
	hll.hll_to_dense(&ds)
	dense_src := [1][]u8{ds}
	testing.expect_value(t, hll.hll_merge(&sp, true, dense_src[:]), hll.Error.None)
	testing.expect_value(t, hll.hll_encoding_name(sp), "dense")
	sp2 := build_names("1")
	defer hll.hll_free(sp2)
	fresh: []u8
	mixed := [2][]u8{sp2, ds}
	testing.expect_value(t, hll.hll_merge(&fresh, false, mixed[:]), hll.Error.None)
	defer hll.hll_free(fresh)
	testing.expect_value(t, hll.hll_encoding_name(fresh), "dense")
	header := hex_encode(fresh[:16])
	testing.expect_value(t, header, "48594c4c000000000000000000000080")
	delete(header)

	a1 := build("u", 0, 900)
	a2 := build("w", 0, 900)
	defer hll.hll_free(a1)
	defer hll.hll_free(a2)
	testing.expect_value(t, hll.hll_encoding_name(a1), "sparse")
	testing.expect_value(t, len(a1), 1713)
	testing.expect_value(t, hll.hll_encoding_name(a2), "sparse")
	testing.expect_value(t, len(a2), 1735)
	a3: []u8
	pair := [2][]u8{a1, a2}
	testing.expect_value(t, hll.hll_merge(&a3, false, pair[:]), hll.Error.None)
	defer hll.hll_free(a3)
	testing.expect_value(t, len(a3), hll.HLL_DENSE_SIZE)
	invalid := false
	testing.expect_value(t, hll.hll_count(a3, &invalid), 1784)

	a := build("a", 0, 1000)
	b := build("b", 0, 1500)
	defer hll.hll_free(a)
	defer hll.hll_free(b)
	name_buf: [32]u8
	for n in 0 ..< 500 {
		elems := [1][]u8{elem_name(name_buf[:], "a", n)}
		hll.hll_pfadd(&b, elems[:], false)
	}
	testing.expect_value(t, hll.hll_count(a, &invalid), 999)
	testing.expect_value(t, hll.hll_count(b, &invalid), 2006)
	both := [3][]u8{a, b, nil}
	card, err := hll.hll_count_union(both[:])
	testing.expect_value(t, err, hll.Error.None)
	testing.expect_value(t, card, 2503)
	m: []u8
	testing.expect_value(t, hll.hll_merge(&m, false, both[:2]), hll.Error.None)
	defer hll.hll_free(m)
	testing.expect_value(t, hll.hll_count(m, &invalid), 2503)
	testing.expect_value(t, hll.hll_encoding_name(m), "dense")
}

@(test)
merge_error_order :: proc(t: ^testing.T) {
	good := build_names("a")
	defer hll.hll_free(good)
	not_hll := make([]u8, 3)
	defer delete(not_hll)
	copy(not_hll, "bar")
	corrupt := hex_decode("48594c4c01000000000000000000008060f38050b1844bfb80425a68656c6c6f")
	defer delete(corrupt)
	dest := build_names("z")
	defer hll.hll_free(dest)
	before := hex_encode(dest)
	defer delete(before)
	srcs := [3][]u8{good, corrupt, not_hll}
	testing.expect_value(t, hll.hll_merge(&dest, true, srcs[:]), hll.Error.Corrupted)
	swapped := [3][]u8{good, not_hll, corrupt}
	testing.expect_value(t, hll.hll_merge(&dest, true, swapped[:]), hll.Error.Wrong_Type)
	after := hex_encode(dest)
	defer delete(after)
	testing.expect(t, before == after)
	testing.expect_value(t, hll.hll_merge(&not_hll, true, srcs[:1]), hll.Error.Wrong_Type)
	_, union_err := hll.hll_count_union(srcs[:])
	testing.expect_value(t, union_err, hll.Error.Corrupted)
	_, union_err = hll.hll_count_union(swapped[:])
	testing.expect_value(t, union_err, hll.Error.Wrong_Type)
}

@(test)
merge_cursor_matches_register_by_register :: proc(t: ^testing.T) {
	r := rand.create(0x7e57_c0de)
	gen := rand.default_random_generator(&r)
	for trial in 0 ..< 300 {
		limit := 1 << 20
		if trial % 3 == 1 {
			limit = 200 + int(rand.uint32(gen) % 2000)
		}
		dest := dyn_from(hll.HLL_EMPTY_SPARSE[:])
		base := int(rand.uint32(gen) % hll.HLL_REGISTERS)
		for _ in 0 ..< int(rand.uint32(gen) % 400) {
			index := (base + int(rand.uint32(gen) % 900)) % hll.HLL_REGISTERS
			count := u8(1 + rand.uint32(gen) % 4)
			hll.hll_dyn_set(&dest, index, count, 1 << 20)
		}
		regs: [hll.HLL_REGISTERS]u8
		hll.hll_merge_into(&regs, dest[:])
		for _ in 0 ..< int(rand.uint32(gen) % 600) {
			index := (base + int(rand.uint32(gen) % 1200)) % hll.HLL_REGISTERS
			count := u8(1 + rand.uint32(gen) % 5)
			if rand.uint32(gen) % 97 == 0 {
				count = 33 + u8(rand.uint32(gen) % 8)
			}
			regs[index] = max(regs[index], count)
		}
		fast := dyn_from(dest[:])
		slow := dyn_from(dest[:])
		fast_err := hll.sparse_store_registers(&fast, &regs, limit)
		slow_err := hll.Error.None
		for index in 0 ..< hll.HLL_REGISTERS {
			if regs[index] != 0 {
				_, set_err := hll.hll_dyn_set(&slow, index, regs[index], limit)
				if set_err != .None {
					slow_err = set_err
					break
				}
			}
		}
		testing.expect_value(t, fast_err, slow_err)
		if !testing.expectf(t, string(fast[:]) == string(slow[:]), "trial %d: cursor result differs (%d vs %d bytes)", trial, len(fast), len(slow)) {
			break
		}
		check: [hll.HLL_REGISTERS]u8
		testing.expect_value(t, hll.hll_get_registers(fast[:], &check), hll.Error.None)
		testing.expect(t, check == regs)
		delete(fast)
		delete(slow)
		delete(dest)
	}
}
