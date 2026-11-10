package vsetargs

import "core:log"
import "core:strings"
import "core:testing"

@(rodata)
FUZZ_WORDS := [?]string {
	"VALUES",
	"values",
	"FP32",
	"fp32",
	"ELE",
	"REDUCE",
	"CAS",
	"NOQUANT",
	"Q8",
	"BIN",
	"EF",
	"SETATTR",
	"M",
	"m",
	"WITHSCORES",
	"withattribs",
	"COUNT",
	"EPSILON",
	"FILTER",
	"FILTER-EF",
	"TRUTH",
	"NOTHREAD",
	"RAW",
	"raw",
	"BOGUS",
	"VALUES\x00x",
	"COUNT\x00",
	"FILTER\x00",
	"0",
	"1",
	"2",
	"3",
	"4",
	"-1",
	"16",
	"4096",
	"4097",
	"1000000",
	"1000001",
	"65536",
	"65537",
	"9223372036854775807",
	"9223372036854775808",
	"4294967297",
	"-0",
	"+1",
	"1.5",
	"0.5",
	"nan",
	"inf",
	"1e400",
	"1e-400",
	"0x10",
	"",
	" ",
	"-",
	"+",
	"[a",
	"(b",
	"[",
	"(",
	"a",
	"a\x00b",
	".n > 1",
	".n >",
	"1 == 1",
	"(1\r\n == 1",
	"foo\n",
	"\x00",
	"\r\n",
	"{\"a\":1}",
}

@(rodata)
FUZZ_NUMBER_BYTES := [?]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '.', 'e', 'E', '+', '-', 'x'}

@(rodata)
FUZZ_COUNTS := [?]string{"0", "1", "2", "3", "4"}

@(rodata)
FUZZ_COMPONENTS := [?]string{"1", "-0.5", "2e3", "0", "inf", ".25"}

Parser_Fuzz :: struct {
	state: u64,
}

parser_fuzz_next :: proc(r: ^Parser_Fuzz) -> u64 {
	x := r.state
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	r.state = x
	return x * 0x2545F4914F6CDD1D
}

parser_fuzz_below :: proc(r: ^Parser_Fuzz, n: int) -> int {
	return int(parser_fuzz_next(r) % u64(n))
}

parser_fuzz_arg :: proc(r: ^Parser_Fuzz) -> []u8 {
	switch parser_fuzz_below(r, 10) {
	case 0:
		n := parser_fuzz_below(r, 18)
		out := make([]u8, n, context.temp_allocator)
		for &c in out {
			c = u8(parser_fuzz_next(r))
		}
		return out
	case 1:
		n := 1 + parser_fuzz_below(r, 25)
		out := make([]u8, n, context.temp_allocator)
		for &c in out {
			c = FUZZ_NUMBER_BYTES[parser_fuzz_below(r, len(FUZZ_NUMBER_BYTES))]
		}
		return out
	}
	word := FUZZ_WORDS[parser_fuzz_below(r, len(FUZZ_WORDS))]
	return transmute([]u8)strings.clone(word, context.temp_allocator)
}

@(rodata)
FUZZ_VADD_OPTIONS := [?]string{"CAS", "NOQUANT", "Q8", "BIN", "EF", "SETATTR", "M"}

@(rodata)
FUZZ_VSIM_OPTIONS := [?]string{"WITHSCORES", "WITHATTRIBS", "TRUTH", "NOTHREAD", "COUNT", "EPSILON", "EF", "FILTER", "FILTER-EF"}

@(rodata)
FUZZ_SMALL := [?]string{"1", "2", "4", "8", "16", "64", "100", "1000"}

@(rodata)
FUZZ_EXPRESSIONS := [?]string{".n > 1", "1 == 1", ".s == \"x\" and .n < 3", ".n >", "", "(1\r\n == 1", "[1,2]", ".a in [1, 2]"}

@(rodata)
FUZZ_STARTS := [?]string{"-", "[a", "(a", "[", "+", "a", "[\x00"}

@(rodata)
FUZZ_ENDS := [?]string{"+", "[z", "(z", "-", "z", "(", "[a"}

fuzz_text :: proc(out: ^[dynamic][]u8, text: string) {
	append(out, transmute([]u8)strings.clone(text, context.temp_allocator))
}

fuzz_pick :: proc(r: ^Parser_Fuzz, out: ^[dynamic][]u8, list: []string) {
	fuzz_text(out, list[parser_fuzz_below(r, len(list))])
}

fuzz_vector :: proc(r: ^Parser_Fuzz, out: ^[dynamic][]u8) {
	n := 1 + parser_fuzz_below(r, 4)
	if parser_fuzz_below(r, 2) == 0 {
		fuzz_text(out, "FP32")
		blob := make([]u8, 4 * n + (1 if parser_fuzz_below(r, 10) == 0 else 0), context.temp_allocator)
		for &c in blob {
			c = u8(parser_fuzz_next(r))
		}
		append(out, blob)
		return
	}
	fuzz_text(out, "VALUES")
	fuzz_text(out, FUZZ_COUNTS[n])
	for _ in 0 ..< n {
		if parser_fuzz_below(r, 10) == 0 {
			append(out, parser_fuzz_arg(r))
		} else {
			fuzz_pick(r, out, FUZZ_COMPONENTS[:])
		}
	}
}

parser_fuzz_structured :: proc(r: ^Parser_Fuzz, cmd: Command, out: ^[dynamic][]u8) {
	fuzz_text(out, "key")
	#partial switch cmd {
	case .Vadd:
		if parser_fuzz_below(r, 4) == 0 {
			fuzz_text(out, "REDUCE")
			fuzz_pick(r, out, FUZZ_COUNTS[:])
		}
		fuzz_vector(r, out)
		fuzz_text(out, "element")
		for _ in 0 ..< parser_fuzz_below(r, 5) {
			if parser_fuzz_below(r, 10) == 0 {
				append(out, parser_fuzz_arg(r))
				continue
			}
			option := FUZZ_VADD_OPTIONS[parser_fuzz_below(r, len(FUZZ_VADD_OPTIONS))]
			fuzz_text(out, option)
			switch option {
			case "EF":
				fuzz_pick(r, out, FUZZ_SMALL[:])
			case "M":
				fuzz_pick(r, out, FUZZ_SMALL[2:])
			case "SETATTR":
				append(out, parser_fuzz_arg(r))
			}
		}
	case .Vsim:
		if parser_fuzz_below(r, 3) == 0 {
			fuzz_text(out, "ELE")
			append(out, parser_fuzz_arg(r))
		} else {
			fuzz_vector(r, out)
		}
		for _ in 0 ..< parser_fuzz_below(r, 5) {
			if parser_fuzz_below(r, 10) == 0 {
				append(out, parser_fuzz_arg(r))
				continue
			}
			option := FUZZ_VSIM_OPTIONS[parser_fuzz_below(r, len(FUZZ_VSIM_OPTIONS))]
			fuzz_text(out, option)
			switch option {
			case "COUNT", "EF", "FILTER-EF":
				fuzz_pick(r, out, FUZZ_SMALL[:])
			case "EPSILON":
				fuzz_pick(r, out, FUZZ_COMPONENTS[:])
			case "FILTER":
				fuzz_pick(r, out, FUZZ_EXPRESSIONS[:])
			}
		}
	case .Vrange:
		fuzz_pick(r, out, FUZZ_STARTS[:])
		fuzz_pick(r, out, FUZZ_ENDS[:])
		if parser_fuzz_below(r, 2) == 0 {
			fuzz_pick(r, out, FUZZ_SMALL[:])
		}
	case:
		for _ in 0 ..< parser_fuzz_below(r, 5) {
			append(out, parser_fuzz_arg(r))
		}
	}
}

@(rodata)
KNOWN_TEXTS := [?]string {
	ERR_VECTOR_SPEC,
	ERR_OPTION_AFTER_ELEMENT,
	ERR_EF,
	ERR_M,
	ERR_COUNT,
	ERR_EPSILON,
	ERR_FILTER_EF,
	ERR_VSIM_SYNTAX,
	ERR_FILTER_MEMORY,
	ERR_OPTION,
	ERR_COUNT_NOT_INTEGER,
	ERR_START_RANGE,
	ERR_END_RANGE,
	ERR_INFINITY_ORDER,
	ERR_COUNT_VALUE,
	ERR_MEMORY,
}

known_text :: proc(cmd: Command, err: Error) -> bool {
	if err.kind == .Arity {
		return err.text == ARITY_TEXTS[cmd]
	}
	if err.kind == .Filter_Syntax {
		return err.text == "ERR syntax error in FILTER expression near: "
	}
	for text in KNOWN_TEXTS {
		if err.text == text {
			return err.near == ""
		}
	}
	return false
}

Fuzz_Tally :: struct {
	accepted: [Command]int,
	rejected: [Command]int,
}

fuzz_check :: proc(t: ^testing.T, cmd: Command, args: [][]u8, tally: ^Fuzz_Tally) {
	first := run_parser(cmd, args)
	second := run_parser(cmd, args)
	testing.expectf(t, first.err == second.err && first.fields == second.fields, "%v %q is not deterministic", cmd, args)
	err := first.err
	if err.kind == .None {
		testing.expectf(t, err.text == "" && err.near == "", "%v %q: success carries text %q", cmd, args, err.text)
		tally.accepted[cmd] += 1
		return
	}
	tally.rejected[cmd] += 1
	testing.expectf(t, known_text(cmd, err), "%v %q: unknown error %v %q %q", cmd, args, err.kind, err.text, err.near)
	testing.expectf(t, stage_consistent(cmd, err), "%v %q: %v at stage %v", cmd, args, err.kind, err.stage)
	text, _ := error_string(err, context.temp_allocator)
	testing.expectf(t, strings.index_any(text, "\r\n\x00") < 0, "%v %q: reply text %q keeps a line break", cmd, args, text)
}

fuzz_vadd_invariants :: proc(t: ^testing.T, args: [][]u8) {
	req, err := parse_vadd(args)
	defer vadd_request_destroy(&req)
	if err.kind != .None {
		testing.expectf(t, req.vector == nil, "VADD %q: vector kept after %v", args, err.kind)
		return
	}
	testing.expectf(t, len(req.vector) >= 1 && len(req.vector) <= MAX_DIM, "VADD %q: %d components", args, len(req.vector))
	testing.expectf(t, int(req.reduce) <= len(req.vector), "VADD %q: reduce %d over %d", args, req.reduce, len(req.vector))
	testing.expectf(t, req.m >= M_MIN && req.m <= M_MAX && req.ef >= 1 && req.ef <= EF_MAX, "VADD %q: m %d ef %d", args, req.m, req.ef)
}

fuzz_vsim_invariants :: proc(t: ^testing.T, args: [][]u8) {
	req, err := parse_vsim(args)
	defer vsim_request_destroy(&req)
	if err.kind != .None && err.stage != .After_Query {
		testing.expectf(t, req.vector == nil && !req.has_filter, "VSIM %q: state kept after %v", args, err.kind)
		return
	}
	testing.expectf(t, !(err.kind != .None && req.has_filter), "VSIM %q: filter kept after %v", args, err.kind)
	testing.expectf(t, (req.query == .Vector) == (req.vector != nil), "VSIM %q: query %v with %d components", args, req.query, len(req.vector))
	if err.kind == .None {
		testing.expectf(t, req.count > 0 && req.ef >= 0 && req.ef <= EF_MAX && req.filter_ef >= 0 && req.epsilon >= 0, "VSIM %q: bad option values", args)
		testing.expect(t, vsim_filter_ef(&req) > 0)
	}
}

@(test)
fuzz_random_argument_vectors :: proc(t: ^testing.T) {
	r := Parser_Fuzz{state = 0xC0FFEE1234567891}
	tally: Fuzz_Tally
	args := make([dynamic][]u8)
	defer delete(args)
	for round in 0 ..< 40_000 {
		cmd := Command(parser_fuzz_below(&r, len(Command)))
		clear(&args)
		if round % 2 == 0 {
			for _ in 0 ..< parser_fuzz_below(&r, 14) {
				append(&args, parser_fuzz_arg(&r))
			}
		} else {
			parser_fuzz_structured(&r, cmd, &args)
		}
		fuzz_check(t, cmd, args[:], &tally)
		#partial switch cmd {
		case .Vadd:
			fuzz_vadd_invariants(t, args[:])
		case .Vsim:
			fuzz_vsim_invariants(t, args[:])
		}
		free_all(context.temp_allocator)
	}
	for cmd in Command {
		log.infof("fuzz %v: %d accepted, %d rejected", cmd, tally.accepted[cmd], tally.rejected[cmd])
		testing.expectf(t, tally.rejected[cmd] > 0, "fuzz never rejected %v", cmd)
	}
	testing.expect(t, tally.accepted[.Vadd] > 100 && tally.accepted[.Vsim] > 100)
}

@(test)
destroy_is_idempotent :: proc(t: ^testing.T) {
	args := as_args({"k", "VALUES", "2", "1", "0", "FILTER", ".n > 1", "COUNT", "0"})
	req, err := parse_vsim(args)
	testing.expect_value(t, err.kind, Error_Kind.Count)
	testing.expect_value(t, err.stage, Stage.After_Query)
	testing.expect(t, len(req.vector) == 2 && !req.has_filter)
	vsim_request_destroy(&req)
	vsim_request_destroy(&req)
	testing.expect(t, req.vector == nil)
	add, add_err := parse_vadd(as_args({"k", "VALUES", "1", "5", "e", "EF", "0"}))
	testing.expect_value(t, add_err.kind, Error_Kind.Ef)
	vadd_request_destroy(&add)
	vadd_request_destroy(&add)
	free_all(context.temp_allocator)
}
