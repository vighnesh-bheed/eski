package vsetargs

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"

@(rodata)
HEX_DIGITS := [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

as_args :: proc(args: []string, allocator := context.temp_allocator) -> [][]u8 {
	out := make([][]u8, len(args), allocator)
	for arg, i in args {
		out[i] = transmute([]u8)arg
	}
	return out
}

write_hex :: proc(b: ^strings.Builder, bytes: []u8) {
	for c in bytes {
		strings.write_byte(b, HEX_DIGITS[c >> 4])
		strings.write_byte(b, HEX_DIGITS[c & 15])
	}
}

write_words :: proc(b: ^strings.Builder, vector: []f32) {
	for v, i in vector {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, "%08x", transmute(u32)v)
	}
}

flag_digit :: proc(v: bool) -> int {
	return 1 if v else 0
}

describe_vadd :: proc(b: ^strings.Builder, req: ^Vadd_Request) {
	strings.write_string(b, "key=")
	write_hex(b, req.key)
	strings.write_string(b, " element=")
	write_hex(b, req.element)
	strings.write_string(b, " vector=")
	write_words(b, req.vector)
	fmt.sbprintf(b, " reduce=%d quant=%v m=%d ef=%d cas=%d setattr=", req.reduce, req.quant, req.m, req.ef, flag_digit(req.cas))
	if req.set_attributes {
		strings.write_byte(b, '+')
		write_hex(b, req.attributes)
	} else {
		strings.write_byte(b, '-')
	}
}

describe_vsim :: proc(b: ^strings.Builder, req: ^Vsim_Request) {
	strings.write_string(b, "key=")
	write_hex(b, req.key)
	switch req.query {
	case .Element:
		strings.write_string(b, " query=ele:")
		write_hex(b, req.element)
	case .Vector:
		strings.write_string(b, " query=vec:")
		write_words(b, req.vector)
	}
	fmt.sbprintf(b, " count=%d ef=%d epsilon=%016x filter=", req.count, req.ef, transmute(u64)req.epsilon)
	if req.has_filter {
		strings.write_byte(b, '+')
		write_hex(b, req.filter_text)
	} else {
		strings.write_byte(b, '-')
	}
	fmt.sbprintf(b, " filter_ef=%d flags=%d%d%d%d", req.filter_ef, flag_digit(req.with_scores), flag_digit(req.with_attribs), flag_digit(req.truth), flag_digit(req.nothread))
}

describe_bound :: proc(b: ^strings.Builder, bound: Lex_Bound) {
	fmt.sbprintf(b, "%v:", bound.kind)
	write_hex(b, bound.value)
}

Outcome :: struct {
	err:    Error,
	fields: string,
}

run_parser :: proc(cmd: Command, args: [][]u8, allocator := context.allocator) -> (out: Outcome) {
	b := strings.builder_make(context.temp_allocator)
	switch cmd {
	case .Vadd:
		req, err := parse_vadd(args, allocator)
		defer vadd_request_destroy(&req)
		out.err = err
		if err.kind == .None {
			describe_vadd(&b, &req)
		}
	case .Vsim:
		req, err := parse_vsim(args, allocator)
		defer vsim_request_destroy(&req)
		out.err = err
		if err.kind == .None {
			describe_vsim(&b, &req)
		}
	case .Vcard, .Vdim, .Vinfo:
		req, err := parse_key_command(cmd, args)
		out.err = err
		if err.kind == .None {
			strings.write_string(&b, "key=")
			write_hex(&b, req.key)
		}
	case .Vrem, .Vgetattr, .Vismember:
		req, err := parse_element_command(cmd, args)
		out.err = err
		if err.kind == .None {
			strings.write_string(&b, "key=")
			write_hex(&b, req.key)
			strings.write_string(&b, " element=")
			write_hex(&b, req.element)
		}
	case .Vsetattr:
		req, err := parse_vsetattr(args)
		out.err = err
		if err.kind == .None {
			strings.write_string(&b, "key=")
			write_hex(&b, req.key)
			strings.write_string(&b, " element=")
			write_hex(&b, req.element)
			strings.write_string(&b, " attributes=")
			write_hex(&b, req.attributes)
		}
	case .Vemb:
		req, err := parse_vemb(args)
		out.err = err
		if err.kind == .None {
			strings.write_string(&b, "key=")
			write_hex(&b, req.key)
			strings.write_string(&b, " element=")
			write_hex(&b, req.element)
			fmt.sbprintf(&b, " raw=%d", flag_digit(req.raw))
		}
	case .Vlinks:
		req, err := parse_vlinks(args)
		out.err = err
		if err.kind == .None {
			strings.write_string(&b, "key=")
			write_hex(&b, req.key)
			strings.write_string(&b, " element=")
			write_hex(&b, req.element)
			fmt.sbprintf(&b, " withscores=%d", flag_digit(req.with_scores))
		}
	case .Vrandmember:
		req, err := parse_vrandmember(args)
		out.err = err
		if err.kind == .None {
			strings.write_string(&b, "key=")
			write_hex(&b, req.key)
			if req.has_count {
				fmt.sbprintf(&b, " count=%d", req.count)
			} else {
				strings.write_string(&b, " count=-")
			}
		}
	case .Vrange:
		req, err := parse_vrange(args)
		out.err = err
		if err.kind == .None {
			strings.write_string(&b, "key=")
			write_hex(&b, req.key)
			strings.write_string(&b, " start=")
			describe_bound(&b, req.start)
			strings.write_string(&b, " end=")
			describe_bound(&b, req.end)
			if req.has_count {
				fmt.sbprintf(&b, " count=%d", req.count)
			} else {
				strings.write_string(&b, " count=-")
			}
		}
	}
	out.fields = strings.to_string(b)
	return
}

stage_consistent :: proc(cmd: Command, err: Error) -> bool {
	if cmd != .Vsim {
		return err.stage == .Before_Key
	}
	#partial switch err.kind {
	case .Arity, .Memory:
		return err.stage == .Before_Key
	case .Vector_Spec:
		return err.stage == .After_Key
	}
	return err.stage == .After_Query
}

Replay_Verdict :: enum u8 {
	Error_Text,
	Accepted,
	Deferred,
}

replay_one :: proc(c: Replay_Case) -> (verdict: Replay_Verdict, ok: bool, detail: string) {
	args := as_args(c.args)
	out := run_parser(c.command, args)
	composed, _ := error_string(out.err, context.temp_allocator)
	if c.error != "" {
		if out.err.kind == .None {
			return .Error_Text, false, fmt.tprintf("accepted with %s, want %q", out.fields, c.error)
		}
		if composed != c.error {
			return .Error_Text, false, fmt.tprintf("error %q, want %q", composed, c.error)
		}
		if !stage_consistent(c.command, out.err) {
			return .Error_Text, false, fmt.tprintf("error %q has stage %v", composed, out.err.stage)
		}
		return .Error_Text, true, ""
	}
	wrongtype := strings.has_prefix(c.reply, "-WRONGTYPE")
	state_error := strings.has_prefix(c.reply, "-") && !wrongtype
	if c.command == .Vsim && out.err.kind != .None {
		if c.key == .Missing || c.key == .Other_Type || wrongtype {
			if out.err.stage != .Before_Key {
				return .Deferred, true, ""
			}
			return .Deferred, false, fmt.tprintf("error %q before the key check on a %v key", composed, c.key)
		}
		if state_error && out.err.stage == .After_Query {
			return .Deferred, true, ""
		}
	}
	if out.err.kind != .None {
		return .Accepted, false, fmt.tprintf("error %q, want acceptance (reply %q)", composed, c.reply)
	}
	if c.fields != "" && out.fields != c.fields {
		return .Accepted, false, fmt.tprintf("fields\n  got  %s\n  want %s", out.fields, c.fields)
	}
	return .Accepted, true, ""
}

@(test)
replay_recorded_and_probed_cases :: proc(t: ^testing.T) {
	Tally :: struct {
		total, matched, errors, accepted, deferred: int,
	}
	tallies: [Replay_Source]Tally
	for c in REPLAY_CASES {
		verdict, ok, detail := replay_one(c)
		tally := &tallies[c.source]
		tally.total += 1
		if ok {
			tally.matched += 1
			switch verdict {
			case .Error_Text:
				tally.errors += 1
			case .Accepted:
				tally.accepted += 1
			case .Deferred:
				tally.deferred += 1
			}
		} else {
			testing.expectf(t, false, "%v case %d (RESP%d) %v %q: %s", c.source, c.id, c.proto, c.command, c.args, detail)
		}
		free_all(context.temp_allocator)
	}
	for tally, source in tallies {
		log.infof("%v: %d of %d matched (%d error texts, %d accepted requests, %d deferred to the key or set checks)", source, tally.matched, tally.total, tally.errors, tally.accepted, tally.deferred)
	}
}

@(test)
replay_cases_are_present :: proc(t: ^testing.T) {
	counts: [Replay_Source]int
	commands: [Command]int
	for c in REPLAY_CASES {
		counts[c.source] += 1
		commands[c.command] += 1
	}
	testing.expect(t, counts[.Capture] > 900)
	testing.expect(t, counts[.Probe] > 800)
	testing.expect(t, counts[.Lua] > 20)
	for n, cmd in commands {
		testing.expectf(t, n > 0, "no recorded case for %v", cmd)
	}
}
