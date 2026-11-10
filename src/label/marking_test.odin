package label

import "core:log"
import "core:strings"
import "core:testing"

Marking_Case :: struct {
	text:   string,
	error:  Parse_Error,
	offset: int,
	length: int,
}

MARKING_CASES := [?]Marking_Case {
	{"SECRET", .None, 0, 0},
	{"  secret\t", .None, 0, 0},
	{"Top   Secret//si/TK", .None, 0, 0},
	{"TOP SECRET // SI / TK ", .None, 0, 0},
	{"", .Empty, 0, 0},
	{" \t ", .Empty, 0, 0},
	{"//SI", .Empty_Level, 0, 0},
	{"  //SI", .Empty_Level, 0, 0},
	{"SECRT", .Unknown_Level, 0, 5},
	{"  SECRT  //SI", .Unknown_Level, 2, 5},
	{"TOPSECRET", .Unknown_Level, 0, 9},
	{"SECRET/SI", .Bad_Separator, 6, 1},
	{"SECRET/", .Bad_Separator, 6, 1},
	{"SECRET / /SI", .Bad_Separator, 7, 1},
	{"SECRET//", .Empty_Compartment, 8, 0},
	{"SECRET// ", .Empty_Compartment, 8, 0},
	{"SECRET//SI/", .Empty_Compartment, 11, 0},
	{"SECRET///SI", .Empty_Compartment, 8, 0},
	{"SECRET//SI//TK", .Empty_Compartment, 11, 0},
	{"SECRET//SI/ XYZ /TK", .Unknown_Compartment, 12, 3},
	{"SECRET//SI/si", .Duplicate_Compartment, 11, 2},
	{"SECRET//TK/ tk ", .Duplicate_Compartment, 12, 2},
	{"SECRET\x00", .Invalid_Byte, 6, 1},
	{"SECRET//S\nI", .Invalid_Byte, 9, 1},
	{"SECRET\x7f", .Invalid_Byte, 6, 1},
	{"SECR\xc3\x89T", .Invalid_Byte, 4, 1},
	{"SECRET;TRUSTED", .None, 0, 0},
	{"SECRET//SI ; vetted ", .None, 0, 0},
	{"SECRET;", .Empty_Trust, 7, 0},
	{"SECRET; \t", .Empty_Trust, 7, 0},
	{";TRUSTED", .Empty_Level, 0, 0},
	{" ;TRUSTED", .Empty_Level, 0, 0},
	{"SECRET;TRUSTY", .Unknown_Trust, 7, 6},
	{"SECRET; trusted;web", .Unknown_Trust, 8, 11},
	{"SECRET;TRUSTED//SI", .Unknown_Trust, 7, 11},
	{"SECRET//;WEB", .Empty_Compartment, 8, 0},
	{"SECRT;WEB", .Unknown_Level, 0, 5},
}

@(test)
markings_report_precise_errors :: proc(t: ^testing.T) {
	c: Config
	us_config(t, &c)
	defer config_destroy(&c)
	for mc in MARKING_CASES {
		_, f := parse(&c, mc.text)
		testing.expectf(t, f.error == mc.error && f.offset == mc.offset && f.length == mc.length, "%q: got %v at %d+%d, want %v at %d+%d", mc.text, f.error, f.offset, f.length, mc.error, mc.offset, mc.length)
	}
	l, f := parse(&c, "Top   Secret//tk/si")
	testing.expect_value(t, f.error, Parse_Error.None)
	testing.expect_value(t, label_text(&c, l), "TOP SECRET//SI/TK")
	long := strings.repeat(" ", MARKING_MAX + 1, context.temp_allocator)
	_, f = parse(&c, long)
	testing.expect(t, f.error == .Too_Long && f.offset == MARKING_MAX && f.length == 1)
	_, f = parse(&c, long[1:])
	testing.expect_value(t, f.error, Parse_Error.Empty)
}

@(test)
format_is_canonical_and_round_trips :: proc(t: ^testing.T) {
	c: Config
	wide_config(t, &c, LEVEL_LIMIT, COMPARTMENT_LIMIT, TRUST_LIMIT)
	defer config_destroy(&c)
	top, _ := config_top(&c)
	top.trust = 2
	text, ok := format(&c, top)
	defer delete(text)
	testing.expect(t, ok)
	testing.expect_value(t, len(text), format_length(&c, top))
	back, f := parse(&c, text)
	testing.expect(t, f.error == .None && back == top)
	r := Rng{0xF0_4A7}
	for _ in 0 ..< 5_000 {
		l := random_label(&r, LEVEL_LIMIT, COMPARTMENT_LIMIT, 20, TRUST_LIMIT)
		s := label_text(&c, l)
		testing.expect_value(t, len(s), format_length(&c, l))
		parsed, pf := parse(&c, s)
		testing.expect(t, pf.error == .None && parsed == l)
	}
	us: Config
	us_config(t, &us)
	defer config_destroy(&us)
	bad: Label
	bad.level = 4
	_, ok = format(&us, bad)
	testing.expect(t, !ok)
	bad.level = 0
	bad.trust = 3
	testing.expect_value(t, format_length(&us, bad), -1)
	bad.trust = 0
	compartment_add(&bad, 5)
	testing.expect_value(t, format_length(&us, bad), -1)
}

reference_normal :: proc(raw: string) -> string {
	words := strings.fields(raw, context.temp_allocator)
	joined := strings.join(words, " ", context.temp_allocator)
	return strings.to_upper(joined, context.temp_allocator)
}

reference_find :: proc(names: []string, raw: string) -> int {
	want := reference_normal(raw)
	for name, i in names {
		if name == want {
			return i
		}
	}
	return -1
}

reference_span :: proc(text: string, from, to: int) -> (int, int) {
	token := text[from:to]
	left := strings.trim_left(token, " \t")
	if len(left) == 0 {
		return from, 0
	}
	inner := strings.trim_right(left, " \t")
	return from + len(token) - len(left), len(inner)
}

reference_parse :: proc(c: ^Config, text: string) -> (l: Label, f: Parse_Failure) {
	levels := make([]string, config_level_count(c), context.temp_allocator)
	for i in 0 ..< len(levels) {
		levels[i] = config_level_name(c, i)
	}
	compartments := make([]string, config_compartment_count(c), context.temp_allocator)
	for i in 0 ..< len(compartments) {
		compartments[i] = config_compartment_name(c, i)
	}
	trusts := make([]string, len(c.trusts), context.temp_allocator)
	for i in 0 ..< len(trusts) {
		trusts[i] = config_trust_name(c, i)
	}
	if len(text) > MARKING_MAX {
		return {}, {.Too_Long, MARKING_MAX, len(text) - MARKING_MAX}
	}
	for b, i in transmute([]u8)text {
		if b != 9 && (b < 32 || b > 126) {
			return {}, {.Invalid_Byte, i, 1}
		}
	}
	semi := strings.index_byte(text, ';')
	if semi < 0 {
		return reference_secrecy(levels, compartments, text, false)
	}
	l, f = reference_secrecy(levels, compartments, text[:semi], true)
	if f.error != .None {
		return {}, f
	}
	at, n := reference_span(text, semi + 1, len(text))
	if n == 0 {
		return {}, {.Empty_Trust, at, 0}
	}
	k := reference_find(trusts, text[semi + 1:])
	if k < 0 {
		return {}, {.Unknown_Trust, at, n}
	}
	l.trust = u8(k)
	return l, {}
}

reference_secrecy :: proc(levels, compartments: []string, text: string, suffixed: bool) -> (l: Label, f: Parse_Failure) {
	parts := strings.split(text, "/", context.temp_allocator)
	starts := make([]int, len(parts), context.temp_allocator)
	for i in 1 ..< len(parts) {
		starts[i] = starts[i - 1] + len(parts[i - 1]) + 1
	}
	at, n := reference_span(text, 0, len(parts[0]))
	if n == 0 {
		return {}, {.Empty if len(parts) == 1 && !suffixed else .Empty_Level, at, 0}
	}
	level := reference_find(levels, parts[0])
	if level < 0 {
		return {}, {.Unknown_Level, at, n}
	}
	l.level = u8(level)
	if len(parts) == 1 {
		return l, {}
	}
	if len(parts) == 2 || len(parts[1]) != 0 {
		return {}, {.Bad_Separator, len(parts[0]), 1}
	}
	for i in 2 ..< len(parts) {
		at, n = reference_span(text, starts[i], starts[i] + len(parts[i]))
		if n == 0 {
			return {}, {.Empty_Compartment, at, 0}
		}
		k := reference_find(compartments, parts[i])
		if k < 0 {
			return {}, {.Unknown_Compartment, at, n}
		}
		if compartment_has(l, k) {
			return {}, {.Duplicate_Compartment, at, n}
		}
		compartment_add(&l, k)
	}
	return l, {}
}

FUZZ_PIECES := [?]string {
	"UNCLASSIFIED",
	"confidential",
	"Secret",
	"TOP SECRET",
	"top  secret",
	"TOP\tSECRET",
	"SI",
	"tk",
	"HCS",
	"G",
	"NOFORN",
	"NoForn",
	"XYZ",
	"S I",
	"/",
	"//",
	"//",
	"//",
	"///",
	" ",
	"  ",
	"\t",
	"\x00",
	"\n",
	"\x7f",
	"\xff",
	"-",
	"_",
	"a",
	";",
	";",
	"web",
	"Vetted",
	"TRUSTED",
}

fuzz_marking :: proc(r: ^Rng, b: ^strings.Builder) -> string {
	strings.builder_reset(b)
	pieces := rng_below(r, 9)
	for _ in 0 ..< pieces {
		strings.write_string(b, FUZZ_PIECES[rng_below(r, len(FUZZ_PIECES))])
	}
	return strings.to_string(b^)
}

LEVEL_SEPARATORS := [?]string{"//", "//", "//", "/", " //", "// "}

COMPARTMENT_SEPARATORS := [?]string{"/", "/", "/", "//", " / "}

structured_marking :: proc(r: ^Rng, b: ^strings.Builder) -> string {
	strings.builder_reset(b)
	strings.write_string(b, FUZZ_PIECES[rng_below(r, 6)])
	if rng_below(r, 4) == 0 {
		return strings.to_string(b^)
	}
	strings.write_string(b, LEVEL_SEPARATORS[rng_below(r, len(LEVEL_SEPARATORS))])
	n := 1 + rng_below(r, 4)
	for i in 0 ..< n {
		if i > 0 {
			strings.write_string(b, COMPARTMENT_SEPARATORS[rng_below(r, len(COMPARTMENT_SEPARATORS))])
		}
		strings.write_string(b, FUZZ_PIECES[6 + rng_below(r, 7)])
	}
	if rng_below(r, 3) == 0 {
		strings.write_string(b, ";" if rng_below(r, 2) == 0 else " ; ")
		strings.write_string(b, FUZZ_PIECES[len(FUZZ_PIECES) - 1 - rng_below(r, 4)])
	}
	return strings.to_string(b^)
}

@(test)
fuzzed_markings_match_the_reference_parser_and_round_trip :: proc(t: ^testing.T) {
	c: Config
	us_config(t, &c)
	defer config_destroy(&c)
	r := Rng{0xFA22_ED}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	accepted := 0
	errors: [Parse_Error]int
	for round in 0 ..< 200_000 {
		text := fuzz_marking(&r, &b) if round % 2 == 0 else structured_marking(&r, &b)
		l, f := parse(&c, text)
		rl, rf := reference_parse(&c, text)
		if f != rf || l != rl {
			testing.expectf(t, false, "%q: parse %v %v, reference %v %v", text, l, f, rl, rf)
			break
		}
		errors[f.error] += 1
		if f.error == .None {
			accepted += 1
			testing.expect(t, config_valid(&c, l))
			canonical := label_text(&c, l)
			again, af := parse(&c, canonical)
			testing.expect(t, af.error == .None && again == l)
			testing.expect_value(t, label_text(&c, again), canonical)
		} else {
			testing.expect(t, f.offset >= 0 && f.offset + f.length <= max(len(text), MARKING_MAX + f.length))
		}
		free_all(context.temp_allocator)
	}
	for e in Parse_Error {
		if e != .Too_Long {
			testing.expectf(t, errors[e] > 0, "fuzzing never produced %v", e)
		}
	}
	log.infof("marking fuzz: 200000 inputs, %d accepted, outcomes %v", accepted, errors)
}
