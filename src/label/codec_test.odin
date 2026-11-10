package label

import "core:testing"

codec_fixture :: proc(t: ^testing.T, c: ^Config, tb: ^Table, labels: int, seed: u64) {
	us_config(t, c)
	testing.expect_value(t, table_init(tb), Error.None)
	r := Rng{seed}
	for _ in 0 ..< labels {
		table_intern(tb, random_label(&r, len(US_LEVELS), len(US_COMPARTMENTS), 3, len(US_TRUSTS)))
	}
}

same_state :: proc(a: ^Config, ta: ^Table, b: ^Config, tb: ^Table) -> bool {
	if config_level_count(a) != config_level_count(b) || config_compartment_count(a) != config_compartment_count(b) || len(a.trusts) != len(b.trusts) || table_count(ta) != table_count(tb) {
		return false
	}
	for i in 0 ..< len(a.trusts) {
		if config_trust_name(a, i) != config_trust_name(b, i) {
			return false
		}
	}
	for i in 0 ..< config_level_count(a) {
		if config_level_name(a, i) != config_level_name(b, i) {
			return false
		}
	}
	for i in 0 ..< config_compartment_count(a) {
		if config_compartment_name(a, i) != config_compartment_name(b, i) {
			return false
		}
	}
	for i in 0 ..< table_count(ta) {
		if ta.labels[i] != tb.labels[i] {
			return false
		}
	}
	return true
}

@(test)
encoding_round_trips_and_is_canonical :: proc(t: ^testing.T) {
	c: Config
	tb: Table
	codec_fixture(t, &c, &tb, 60, 0xC0DEC)
	defer config_destroy(&c)
	defer table_destroy(&tb)
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect_value(t, encode(&c, &tb, &out), Codec_Error.None)
	testing.expect_value(t, len(out), encoded_size(&c, &tb))
	testing.expect_value(t, string(out[:4]), CODEC_MAGIC)
	dc: Config
	dt: Table
	testing.expect_value(t, decode(out[:], &dc, &dt), Codec_Error.None)
	testing.expect(t, same_state(&c, &tb, &dc, &dt))
	again := make([dynamic]u8)
	defer delete(again)
	testing.expect_value(t, encode(&dc, &dt, &again), Codec_Error.None)
	testing.expect(t, string(again[:]) == string(out[:]))
	config_destroy(&dc)
	table_destroy(&dt)
	for cut in 0 ..< len(out) {
		e := decode(out[:cut], &dc, &dt)
		testing.expectf(t, e == .Truncated, "prefix %d decoded as %v", cut, e)
	}
	append(&out, 0)
	testing.expect_value(t, decode(out[:], &dc, &dt), Codec_Error.Trailing)
}

@(test)
decoding_rejects_every_malformed_field :: proc(t: ^testing.T) {
	c: Config
	tb: Table
	config_init(&c)
	defer config_destroy(&c)
	config_add_level(&c, "LOW")
	config_add_level(&c, "HIGH")
	config_add_compartment(&c, "A")
	config_add_compartment(&c, "B")
	config_add_trust(&c, "LO")
	config_add_trust(&c, "LP")
	testing.expect_value(t, table_init(&tb), Error.None)
	defer table_destroy(&tb)
	ab, _ := label_make(1, 0, 1)
	ab.trust = 1
	table_intern(&tb, ab)
	good := make([dynamic]u8)
	defer delete(good)
	testing.expect_value(t, encode(&c, &tb, &good), Codec_Error.None)
	want := []u8{'E', 'S', 'L', 'T', 2, 2, 0, 3, 'L', 'O', 'W', 4, 'H', 'I', 'G', 'H', 2, 0, 1, 'A', 1, 'B', 2, 0, 2, 'L', 'O', 2, 'L', 'P', 2, 0, 0, 0, 0, 0, 1, 1, 2, 0, 0, 1}
	testing.expect(t, string(good[:]) == string(want))
	Mutant :: struct {
		at:    int,
		value: u8,
		error: Codec_Error,
	}
	mutants := []Mutant {
		{0, 'X', .Bad_Magic},
		{4, 3, .Bad_Version},
		{4, 1, .Bad_Level},
		{5, 0, .Bad_Level_Count},
		{6, 1, .Bad_Level_Count},
		{8, 'l', .Bad_Name},
		{7, 0, .Bad_Name},
		{7, 200, .Truncated},
		{12, ' ', .Bad_Name},
		{8, '-', .Bad_Name},
		{9, 'o', .Bad_Name},
		{15, ' ', .Bad_Name},
		{18, 'L', .Truncated},
		{21, 'A', .Duplicate_Name},
		{17, 1, .Bad_Compartment_Count},
		{23, 1, .Bad_Trust_Count},
		{25, 'l', .Bad_Name},
		{29, 'O', .Duplicate_Name},
		{24, 0, .Bad_Name},
		{30, 0, .Bad_Label_Count},
		{32, 1, .Not_Bottom},
		{33, 1, .Not_Bottom},
		{36, 2, .Bad_Level},
		{37, 2, .Bad_Trust},
		{38, 3, .Bad_Compartment},
		{41, 0, .Bad_Compartment},
		{41, 2, .Bad_Compartment},
		{39, 1, .Bad_Compartment},
		{38, 1, .Trailing},
	}
	for m in mutants {
		bytes := make([]u8, len(good), context.temp_allocator)
		copy(bytes, good[:])
		bytes[m.at] = m.value
		dc: Config
		dt: Table
		e := decode(bytes, &dc, &dt)
		testing.expectf(t, e == m.error, "byte %d = %d: got %v, want %v", m.at, m.value, e, m.error)
		if e == .None {
			config_destroy(&dc)
			table_destroy(&dt)
		}
	}
	Crafted :: struct {
		bytes: []u8,
		error: Codec_Error,
	}
	crafted := []Crafted {
		{{'E', 'S', 'L', 'T', 1, 2, 0, 3, 'L', 'O', 'W', 4, 'H', 'I', 'G', 'H', 2, 0, 1, 'A', 1, 'B', 3, 0, 0, 0, 0, 1, 2, 0, 0, 1, 1, 2, 0, 0, 1}, .Duplicate_Label},
		{{'E', 'S', 'L', 'T', 1, 1, 0, 1, 'A', 1, 0, 1, 'A', 1, 0, 0, 0, 0}, .Duplicate_Name},
		{{'E', 'S', 'L', 'T', 1, 1, 0, 1, 'A', 1, 0, 1, 'B', 2, 0, 0, 0, 0, 0, 0, 0}, .Duplicate_Label},
		{{'E', 'S', 'L', 'T', 1, 1, 0, 1, 'A', 1, 0, 1, 'B', 1, 0, 0, 0, 0}, .None},
		{{'E', 'S', 'L', 'T', 1, 0, 0}, .Bad_Level_Count},
		{{'E', 'S', 'L', 'T', 1, 0, 1}, .Truncated},
		{{'E', 'S', 'L', 'T', 1, 1, 1}, .Bad_Level_Count},
		{{'E', 'S', 'L', 'T', 1, 1, 0, 1, 'A', 1, 1}, .Bad_Compartment_Count},
		{{'E', 'S', 'L', 'T', 1, 1, 0, 1, 'A', 0, 1}, .Truncated},
		{{'E', 'S', 'L'}, .Truncated},
		{{'E', 'S', 'L', 'X'}, .Bad_Magic},
		{{'E', 'S', 'L', 'T'}, .Truncated},
		{{'E', 'S', 'L', 'T', 2, 1, 0, 1, 'A', 0, 0, 1, 0, 1, 'A', 1, 0, 0, 0, 0, 0}, .None},
		{{'E', 'S', 'L', 'T', 2, 1, 0, 1, 'A', 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 1, 0, 0}, .Bad_Trust},
		{{'E', 'S', 'L', 'T', 2, 1, 0, 1, 'A', 0, 0, 1, 1}, .Bad_Trust_Count},
		{{'E', 'S', 'L', 'T', 2, 1, 0, 1, 'A', 0, 0, 1}, .Truncated},
		{{'E', 'S', 'L', 'T', 2, 1, 0, 1, 'A', 0, 0, 1, 0, 1, 'A', 1, 0, 0, 0}, .Truncated},
	}
	for cr in crafted {
		dc: Config
		dt: Table
		e := decode(cr.bytes, &dc, &dt)
		testing.expectf(t, e == cr.error, "crafted %v: got %v, want %v", cr.bytes, e, cr.error)
		if e == .None {
			config_destroy(&dc)
			table_destroy(&dt)
		}
	}
	bogus: Table
	testing.expect_value(t, table_init(&bogus), Error.None)
	defer table_destroy(&bogus)
	outside, _ := label_make(0, 2)
	table_intern(&bogus, outside)
	scratch := make([dynamic]u8)
	defer delete(scratch)
	testing.expect_value(t, encode(&c, &bogus, &scratch), Codec_Error.Invalid_Label)
	testing.expect_value(t, len(scratch), 0)
	untrusted: Table
	testing.expect_value(t, table_init(&untrusted), Error.None)
	defer table_destroy(&untrusted)
	high := Label{trust = 2}
	table_intern(&untrusted, high)
	testing.expect_value(t, encode(&c, &untrusted, &scratch), Codec_Error.Invalid_Label)
}

@(test)
version_one_encodings_decode_at_the_lowest_trust :: proc(t: ^testing.T) {
	old := []u8{'E', 'S', 'L', 'T', 1, 2, 0, 3, 'L', 'O', 'W', 4, 'H', 'I', 'G', 'H', 2, 0, 1, 'A', 1, 'B', 2, 0, 0, 0, 0, 1, 2, 0, 0, 1}
	dc: Config
	dt: Table
	testing.expect_value(t, decode(old, &dc, &dt), Codec_Error.None)
	defer config_destroy(&dc)
	defer table_destroy(&dt)
	testing.expect_value(t, len(dc.trusts), 0)
	testing.expect_value(t, config_trust_count(&dc), 1)
	testing.expect_value(t, table_count(&dt), 2)
	ab, _ := label_make(1, 0, 1)
	testing.expect(t, dt.labels[1] == ab && dt.labels[1].trust == 0)
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect_value(t, encode(&dc, &dt, &out), Codec_Error.None)
	want := []u8{'E', 'S', 'L', 'T', 2, 2, 0, 3, 'L', 'O', 'W', 4, 'H', 'I', 'G', 'H', 2, 0, 1, 'A', 1, 'B', 0, 0, 2, 0, 0, 0, 0, 0, 1, 0, 2, 0, 0, 1}
	testing.expect(t, string(out[:]) == string(want))
	for cut in 0 ..< len(old) {
		pc: Config
		pt: Table
		testing.expect_value(t, decode(old[:cut], &pc, &pt), Codec_Error.Truncated)
	}
}

@(test)
mutated_encodings_never_decode_to_a_different_encoding :: proc(t: ^testing.T) {
	c: Config
	tb: Table
	codec_fixture(t, &c, &tb, 25, 0xBADC0DE)
	defer config_destroy(&c)
	defer table_destroy(&tb)
	good := make([dynamic]u8)
	defer delete(good)
	encode(&c, &tb, &good)
	r := Rng{0x5EED}
	accepted := 0
	for _ in 0 ..< 20_000 {
		bytes := make([dynamic]u8, len(good), context.temp_allocator)
		copy(bytes[:], good[:])
		for _ in 0 ..< 1 + rng_below(&r, 3) {
			switch rng_below(&r, 4) {
			case 0:
				bytes[rng_below(&r, len(bytes))] = u8(rng_next(&r))
			case 1:
				bytes[rng_below(&r, len(bytes))] ~= u8(1) << uint(rng_below(&r, 8))
			case 2:
				ordered_remove(&bytes, rng_below(&r, len(bytes)))
			case 3:
				inject_at(&bytes, rng_below(&r, len(bytes) + 1), u8(rng_next(&r)))
			}
		}
		dc: Config
		dt: Table
		if decode(bytes[:], &dc, &dt) == .None {
			accepted += 1
			back := make([dynamic]u8, context.temp_allocator)
			testing.expect_value(t, encode(&dc, &dt, &back), Codec_Error.None)
			if bytes[4] == CODEC_VERSION {
				testing.expect(t, string(back[:]) == string(bytes[:]))
			} else {
				rc: Config
				rt: Table
				testing.expect_value(t, decode(back[:], &rc, &rt), Codec_Error.None)
				testing.expect(t, same_state(&dc, &dt, &rc, &rt))
				config_destroy(&rc)
				table_destroy(&rt)
			}
			config_destroy(&dc)
			table_destroy(&dt)
		}
		free_all(context.temp_allocator)
	}
	testing.expect(t, accepted > 0)
}
