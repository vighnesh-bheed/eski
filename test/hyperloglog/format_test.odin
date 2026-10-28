package hyperloglog_test

import "core:testing"
import hll "../../src/hll"

@(test)
header_and_cache_rules :: proc(t: ^testing.T) {
	empty := hll.hll_new_sparse()
	defer hll.hll_free(empty)
	hex := hex_encode(empty)
	defer delete(hex)
	testing.expect_value(t, hex, "48594c4c0100000000000000000000807fff")
	testing.expect_value(t, hll.hll_encoding_name(empty), "sparse")
	testing.expect(t, !hll.hll_cache_valid(empty))
	invalid := false
	testing.expect_value(t, hll.hll_count(empty, &invalid), 0)
	testing.expect(t, !invalid)
	testing.expect(t, hll.hll_cache_valid(empty))
	counted := hex_encode(empty)
	defer delete(counted)
	testing.expect_value(t, counted, "48594c4c0100000000000000000000007fff")

	short := hex_decode("48594c4c010000000000000000000000"[:30])
	defer delete(short)
	ok, msg := hll.hll_validate(short)
	testing.expect(t, !ok)
	testing.expect_value(t, msg, hll.HLL_ERR_WRONGTYPE)
	header_only := hex_decode("48594c4c010000000000000000000000")
	defer delete(header_only)
	testing.expect(t, hll.hll_is_valid(header_only))
	bad_magic := hex_decode("3031323301000000000000000000008060f38050b1844bfb80425a")
	defer delete(bad_magic)
	testing.expect(t, !hll.hll_is_valid(bad_magic))
	bad_encoding := hex_decode("48594c4c78000000000000000000008060f38050b1844bfb80425a")
	defer delete(bad_encoding)
	testing.expect(t, !hll.hll_is_valid(bad_encoding))
	two := hex_decode("48594c4c02000000000000000000000000")
	defer delete(two)
	testing.expect(t, !hll.hll_is_valid(two))
	short_dense := hex_decode("48594c4c00000000000000000000008060f38050b1844bfb80425a")
	defer delete(short_dense)
	testing.expect(t, !hll.hll_is_valid(short_dense))
	testing.expect_value(t, hll.hll_encoding_name(short_dense), "")
	dense := make([]u8, hll.HLL_DENSE_SIZE)
	defer delete(dense)
	copy(dense, "HYLL")
	testing.expect(t, hll.hll_is_valid(dense))
	testing.expect_value(t, hll.hll_encoding_name(dense), "dense")
	dense_short := dense[:hll.HLL_DENSE_SIZE - 1]
	testing.expect(t, !hll.hll_is_valid(dense_short))

	value := hex_decode("48594c4c01000000030000000000000060f38050b1844bfb80425a")
	defer delete(value)
	elems := [3][]u8{transmute([]u8)string("1"), transmute([]u8)string("2"), transmute([]u8)string("3")}
	updated, err := hll.hll_pfadd(&value, elems[:], false)
	testing.expect_value(t, err, hll.Error.None)
	testing.expect_value(t, updated, 1)
	after := hex_encode(value)
	defer delete(after)
	testing.expect_value(t, after, "48594c4c0100000003000000000000805d6680438b8049e78046c8844a628c419780425a")
	testing.expect(t, !hll.hll_cache_valid(value))
	testing.expect_value(t, hll.hll_count(value, &invalid), 6)
	testing.expect(t, !invalid)
	cached := hex_encode(value[:16])
	defer delete(cached)
	testing.expect_value(t, cached, "48594c4c010000000600000000000000")
	unchanged, unchanged_err := hll.hll_pfadd(&value, elems[:], false)
	testing.expect_value(t, unchanged_err, hll.Error.None)
	testing.expect_value(t, unchanged, 0)
	testing.expect(t, hll.hll_cache_valid(value))

	crafted := hex_decode("48594c4c0107000003000000000000007fff")
	defer delete(crafted)
	testing.expect_value(t, hll.hll_count(crafted, &invalid), 3)
	add_a := [1][]u8{transmute([]u8)string("a")}
	_, add_err := hll.hll_pfadd(&crafted, add_a[:], false)
	testing.expect_value(t, add_err, hll.Error.None)
	crafted_hex := hex_encode(crafted)
	defer delete(crafted_hex)
	testing.expect_value(t, crafted_hex, "48594c4c01070000030000000000008071a6844e57")
	converted, conv_err := hll.hll_to_dense(&crafted)
	testing.expect(t, converted)
	testing.expect_value(t, conv_err, hll.Error.None)
	testing.expect_value(t, len(crafted), hll.HLL_DENSE_SIZE)
	dense_header := hex_encode(crafted[:16])
	defer delete(dense_header)
	testing.expect_value(t, dense_header, "48594c4c000700000300000000000080")
}

@(test)
cached_value_is_trusted :: proc(t: ^testing.T) {
	bad4 := hex_decode("48594c4c0100000000000000000000ff"[:30])
	defer delete(bad4)
	crafted := make([dynamic]u8)
	defer delete(crafted)
	append(&crafted, ..bad4)
	append(&crafted, 0, 0xff)
	invalid := false
	testing.expect_value(t, hll.hll_count(crafted[:], &invalid), 0)
	testing.expect(t, !invalid)
	decoded := decode_string(crafted[:])
	defer delete(decoded)
	testing.expect_value(t, decoded, "v:32,4")
	crafted[15] = 0x80
	testing.expect_value(t, hll.hll_count(crafted[:], &invalid), 0)
	testing.expect(t, invalid)
}

@(test)
hashing_matches_recorded_registers :: proc(t: ^testing.T) {
	Case :: struct {
		elem:  string,
		index: int,
		count: u8,
	}
	cases := [?]Case {
		{"a", 12711, 2},
		{"b", 15780, 1},
		{"c", 8436, 1},
		{"hello", 9216, 1},
		{"world", 2742, 3},
		{"1", 7527, 1},
		{"abc", 9474, 1},
		{"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", 2841, 1},
		{"\x00", 8840, 2},
		{"\xff\xfe", 654, 2},
		{"", 5938, 2},
		{"p39094", 2532, 21},
		{"p1090863", 10200, 24},
		{"p1493876", 3845, 20},
	}
	for c in cases {
		index, count := hll.hll_pat_len(transmute([]u8)c.elem)
		testing.expectf(t, index == c.index && count == c.count, "%q: got (%d, %d) want (%d, %d)", c.elem, index, count, c.index, c.count)
	}
	testing.expect_value(t, hll.murmurhash64a(transmute([]u8)string("a"), hll.HLL_HASH_SEED), 0x53d2470a9b43b1a7)
	long_x: [100]u8
	for &b in long_x {
		b = 'x'
	}
	index, count := hll.hll_pat_len(long_x[:])
	testing.expect_value(t, index, 15288)
	testing.expect_value(t, count, 1)
	top_index, top_count := hll.hll_pat_len_from_hash(0x3fff)
	testing.expect_value(t, top_index, 16383)
	testing.expect_value(t, top_count, 51)
	low_index, low_count := hll.hll_pat_len_from_hash(u64(1) << 14)
	testing.expect_value(t, low_index, 0)
	testing.expect_value(t, low_count, 1)
	mid_index, mid_count := hll.hll_pat_len_from_hash(u64(1) << 63)
	testing.expect_value(t, mid_index, 0)
	testing.expect_value(t, mid_count, 50)
}

@(test)
dense_bit_placement :: proc(t: ^testing.T) {
	Case :: struct {
		elem:   string,
		offset: int,
		value:  u8,
	}
	cases := [?]Case{{"a", 9533, 0x08}, {"world", 2056, 0x30}, {"b", 11835, 0x01}, {"\xff\xfe", 490, 0x20}}
	for c in cases {
		buf := hll.hll_new_sparse()
		elems := [1][]u8{transmute([]u8)c.elem}
		hll.hll_pfadd(&buf, elems[:], false)
		hll.hll_to_dense(&buf)
		body := buf[hll.HLL_HDR_SIZE:]
		nonzero := 0
		for v, i in body {
			if v != 0 {
				nonzero += 1
				testing.expectf(t, i == c.offset && v == c.value, "%q: byte %d is %x", c.elem, i, v)
			}
		}
		testing.expect_value(t, nonzero, 1)
		hll.hll_free(buf)
	}
	three := hll.hll_new_sparse()
	defer hll.hll_free(three)
	elems := [3][]u8{transmute([]u8)string("a"), transmute([]u8)string("world"), transmute([]u8)string("b")}
	hll.hll_pfadd(&three, elems[:], false)
	hll.hll_to_dense(&three)
	body := three[hll.HLL_HDR_SIZE:]
	testing.expect_value(t, body[2056], 48)
	testing.expect_value(t, body[9533], 8)
	testing.expect_value(t, body[11835], 1)

	regs := make([]u8, hll.HLL_DENSE_SIZE - hll.HLL_HDR_SIZE)
	defer delete(regs)
	edges := [?]int{0, 1, 2, 3, 4, 5, 16380, 16381, 16382, 16383}
	for index in edges {
		for &b in regs {
			b = 0
		}
		hll.dense_put(regs, index, 63)
		for other in 0 ..< hll.HLL_REGISTERS {
			want := u8(63) if other == index else 0
			if hll.dense_get(regs, other) != want {
				testing.expectf(t, false, "register %d after setting %d", other, index)
				break
			}
		}
		for &b in regs {
			b = 0xff
		}
		hll.dense_put(regs, index, 0)
		for other in 0 ..< hll.HLL_REGISTERS {
			want := u8(0) if other == index else 63
			if hll.dense_get(regs, other) != want {
				testing.expectf(t, false, "register %d after clearing %d", other, index)
				break
			}
		}
	}
	for &b in regs {
		b = 0
	}
	testing.expect(t, hll.dense_set(regs, 16383, 5))
	testing.expect(t, !hll.dense_set(regs, 16383, 5))
	testing.expect(t, !hll.dense_set(regs, 16383, 4))
	testing.expect(t, hll.dense_set(regs, 16383, 6))
	testing.expect_value(t, regs[len(regs) - 1], 6 << 2)
}
