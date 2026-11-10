package stem_english

import "core:testing"

Rng :: struct {
	state: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E37_79B9_7F4A_7C15
	z := r.state
	z = (z ~ z >> 30) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ z >> 27) * 0x94D0_49BB_1331_11EB
	return z ~ z >> 31
}

rng_below :: proc(r: ^Rng, n: int) -> int {
	return int(rng_next(r) % u64(n))
}

@(test)
probe_edge_words :: proc(t: ^testing.T) {
	cases := [?][2]string {
		{"'skies", "ski"},
		{"skies", "sky"},
		{"it's", "it"},
		{"don't", "don't"},
		{"'apostrophe", "apostroph"},
		{"ayy", "ayi"},
		{"yyy", "yyy"},
		{"\xc3\xa9ies", "\xc3\xa9ie"},
		{"\xc3\xa9y", "\xc3\xa9y"},
		{"a\xc3\xa9s", "a\xc3\xa9"},
		{"na\xc3\xafvely", "na\xc3\xafv"},
		{"\xc3\xa9bbed", "\xc3\xa9bbed"},
		{"a1ing", "a1e"},
		{"e2ed", "e2e"},
		{"eedly", "eed"},
		{"feedly", "feed"},
		{"vying", "vy"},
		{"ebbed", "eb"},
		{"added", "ad"},
		{"evening", "even"},
		{"generalization", "general"},
		{"communism", "communism"},
		{"arsenal", "arsenal"},
		{"under_scoring", "under_scor"},
		{"\xf0\x90\x90\xa8ings", "\xf0\x90\x90\xa8ing"},
		{"a\xf0\x9f\x98\x80s", "a\xf0\x9f\x98\x80"},
		{"''", "''"},
		{"'''", "'"},
		{"'s'", "s"},
		{"y", "y"},
		{"", ""},
	}
	buf: [64]u8
	for c in cases {
		got, ok := stem(transmute([]u8)c[0], buf[:])
		testing.expect(t, ok)
		testing.expectf(t, string(got) == c[1], "%q: stem %q, want %q", c[0], string(got), c[1])
	}
}

@(test)
output_must_hold_the_word :: proc(t: ^testing.T) {
	buf: [4]u8
	_, ok := stem(transmute([]u8)string("running"), buf[:])
	testing.expect(t, !ok)
	got: []u8
	got, ok = stem(transmute([]u8)string("runs"), buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, string(got), "run")
}

@(test)
fuzz_stemmer_is_safe :: proc(t: ^testing.T) {
	r := Rng{0x57E1_0000_0000_0004}
	alphabet := "aeiouybcdfglmnprstvwxyz'_1\xc3\xa9\xf0\x9f\x98\x80Y"
	word := make([dynamic]u8, 0, 64)
	defer delete(word)
	one := make([]u8, 128)
	defer delete(one)
	two := make([]u8, 128)
	defer delete(two)
	for _ in 0 ..< 200_000 {
		clear(&word)
		n := rng_below(&r, 24)
		random := rng_below(&r, 4) == 0
		for _ in 0 ..< n {
			if random {
				append(&word, u8(rng_next(&r)))
			} else {
				append(&word, alphabet[rng_below(&r, len(alphabet))])
			}
		}
		a, ok_a := stem(word[:], one)
		b, ok_b := stem(word[:], two)
		testing.expect(t, ok_a && ok_b)
		testing.expect(t, string(a) == string(b))
		testing.expect(t, len(a) <= len(word))
		exact, ok_exact := stem(word[:], one[:len(word)])
		testing.expect(t, ok_exact)
		testing.expect(t, string(exact) == string(b))
	}
}
