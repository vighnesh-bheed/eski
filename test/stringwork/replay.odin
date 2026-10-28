package stringwork

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"

Step :: struct {
	line:    int,
	section: string,
	args:    [dynamic][]u8,
	expect:  string,
	events:  [dynamic]string,
	approx:  bool,
	lo:      i64,
	hi:      i64,
}

EVENTS_PREFIX :: "    events: "

APPROX_PREFIX :: "integer within ["

UNCHECKED :: "?"

FAILURE_REPORT_MAX :: 40

parse_steps :: proc(text: string, resp: u8) -> [dynamic]Step {
	steps: [dynamic]Step
	section := ""
	number := 0
	dropped := false
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		number += 1
		line := raw
		if strings.has_prefix(line, "## ") {
			section = line[3:]
			continue
		}
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		if strings.has_prefix(line, EVENTS_PREFIX) {
			if dropped || len(steps) == 0 {
				continue
			}
			last := &steps[len(steps) - 1]
			for ev in strings.split(line[len(EVENTS_PREFIX):], " | ") {
				append(&last.events, ev)
			}
			continue
		}
		if len(line) > 3 && (line[0] == '2' || line[0] == '3') && line[1] == '|' && line[2] == ' ' {
			dropped = line[0] - '0' != resp
			if dropped {
				continue
			}
			line = line[3:]
		} else {
			dropped = false
		}
		at := strings.index(line, " => ")
		if at < 0 {
			continue
		}
		step := Step {
			line    = number,
			section = section,
			args    = parse_args(line[:at]),
			expect  = line[at + 4:],
		}
		if strings.has_prefix(step.expect, APPROX_PREFIX) {
			bounds := step.expect[len(APPROX_PREFIX):len(step.expect) - 1]
			comma := strings.index(bounds, ", ")
			step.lo, _ = strconv.parse_i64(bounds[:comma])
			step.hi, _ = strconv.parse_i64(bounds[comma + 2:])
			step.approx = true
		}
		append(&steps, step)
	}
	return steps
}

parse_args :: proc(text: string) -> [dynamic][]u8 {
	out: [dynamic][]u8
	i := 0
	for i < len(text) {
		if text[i] == ' ' {
			i += 1
			continue
		}
		if text[i] == '"' {
			k := i + 1
			for k < len(text) && !(text[k] == '"' && (k + 1 == len(text) || text[k + 1] == ' ')) {
				k += 1
			}
			append(&out, bytes_of(text[i + 1:k]))
			i = k + 1
			continue
		}
		k := i
		for k < len(text) && text[k] != ' ' {
			k += 1
		}
		tok := text[i:k]
		if strings.has_prefix(tok, "hex[") {
			append(&out, hex_decode(tok[strings.index_byte(tok, '=') + 1:]))
		} else {
			append(&out, bytes_of(tok))
		}
		i = k
	}
	return out
}

Cursor :: struct {
	text: string,
	at:   int,
}

render_reply :: proc(notation: string, resp: u8) -> (string, bool) {
	b: [dynamic]u8
	if len(notation) == 0 {
		return "", false
	}
	if notation[0] == '+' || notation[0] == '-' {
		append(&b, notation)
		append(&b, "\r\n")
		return string(b[:]), true
	}
	cur := Cursor{notation, 0}
	if !render_value(&cur, &b, resp) || cur.at != len(notation) {
		return "", false
	}
	return string(b[:]), true
}

put_bulk :: proc(b: ^[dynamic]u8, data: []u8) {
	buf: [24]u8
	append(b, '$')
	append(b, strconv.write_int(buf[:], i64(len(data)), 10))
	append(b, "\r\n")
	append(b, ..data)
	append(b, "\r\n")
}

put_header :: proc(b: ^[dynamic]u8, kind: u8, count: int) {
	buf: [24]u8
	append(b, kind)
	append(b, strconv.write_int(buf[:], i64(count), 10))
	append(b, "\r\n")
}

scalar_end :: proc(s: string, from: int) -> int {
	k := from
	for k < len(s) && s[k] != ',' && s[k] != ']' && s[k] != '}' {
		k += 1
	}
	return k
}

closes_string :: proc(s: string, k: int) -> bool {
	return k == len(s) || s[k] == ',' || s[k] == ']' || s[k] == '}' || s[k] == ':'
}

render_value :: proc(cur: ^Cursor, b: ^[dynamic]u8, resp: u8) -> bool {
	rest := cur.text[cur.at:]
	if len(rest) == 0 {
		return false
	}
	switch {
	case strings.has_prefix(rest, "nil"):
		append(b, "_\r\n" if resp == 3 else "$-1\r\n")
		cur.at += 3
	case strings.has_prefix(rest, "hex["):
		eq := strings.index_byte(rest, '=')
		end := eq + 1
		for end < len(rest) && is_hex_digit(rest[end]) {
			end += 1
		}
		put_bulk(b, hex_decode(rest[eq + 1:end]))
		cur.at += end
	case rest[0] == '"':
		k := 1
		for k < len(rest) && !(rest[k] == '"' && closes_string(rest, k + 1)) {
			k += 1
		}
		put_bulk(b, bytes_of(rest[1:k]))
		cur.at += k + 1
	case rest[0] == ':' || rest[0] == ',':
		k := scalar_end(rest, 1)
		append(b, rest[0])
		append(b, rest[1:k])
		append(b, "\r\n")
		cur.at += k
	case rest[0] == '[' || strings.has_prefix(rest, "~[") || strings.has_prefix(rest, "%{"):
		return render_aggregate(cur, b, resp)
	case:
		return false
	}
	return true
}

render_aggregate :: proc(cur: ^Cursor, b: ^[dynamic]u8, resp: u8) -> bool {
	rest := cur.text[cur.at:]
	kind: u8 = '*'
	close: u8 = ']'
	pairs := false
	if rest[0] == '[' {
		cur.at += 1
	} else if rest[0] == '~' {
		kind = '~' if resp == 3 else '*'
		cur.at += 2
	} else {
		kind = '%' if resp == 3 else '*'
		close = '}'
		pairs = true
		cur.at += 2
	}
	inner: [dynamic]u8
	defer delete(inner)
	count := 0
	if cur.at < len(cur.text) && cur.text[cur.at] == close {
		cur.at += 1
		put_header(b, kind, 0)
		return true
	}
	for {
		if !render_value(cur, &inner, resp) {
			return false
		}
		if pairs {
			if !strings.has_prefix(cur.text[cur.at:], ": ") {
				return false
			}
			cur.at += 2
			if !render_value(cur, &inner, resp) {
				return false
			}
		}
		count += 1
		if strings.has_prefix(cur.text[cur.at:], ", ") {
			cur.at += 2
			continue
		}
		if cur.at < len(cur.text) && cur.text[cur.at] == close {
			cur.at += 1
			break
		}
		return false
	}
	put_header(b, kind, count * 2 if pairs && resp != 3 else count)
	append(b, ..inner[:])
	return true
}

Replay :: struct {
	session:      Session,
	label:        string,
	base_ms:      i64,
	check_events: bool,
	want_expired: [dynamic]string,
	got_expired:  [dynamic]string,
	failures:     int,
	executed:     int,
}

Replay_Hook :: #type proc(r: ^Replay, steps: []Step, i: int)

replay_open :: proc(label: string, resp: u8, events: bool) -> Replay {
	return Replay{session = open_session(resp, events), label = label, check_events = events}
}

replay_close :: proc(r: ^Replay) {
	close_session(&r.session)
}

is_command :: proc(step: ^Step, name: string) -> bool {
	return len(step.args) > 0 && fold_eq(step.args[0], name)
}

in_probe_window :: proc(v: i64, seconds: bool) -> bool {
	if seconds {
		return v > 1_000_000_000 && v < 100_000_000_000
	}
	return v > 1_000_000_000_000 && v < 100_000_000_000_000
}

prepare_args :: proc(r: ^Replay, steps: []Step, i: int) -> [dynamic][]u8 {
	step := &steps[i]
	out: [dynamic][]u8
	append(&out, ..step.args[:])
	for k in 0 ..< len(out) - 1 {
		seconds := fold_eq(out[k], "exat")
		if !seconds && !fold_eq(out[k], "pxat") {
			continue
		}
		tok := string(out[k + 1])
		now := now_ms()
		buf := make([]u8, 24)
		if len(tok) > 1 && tok[0] == '@' {
			offset, _ := strconv.parse_i64(tok[1:])
			v := now / 1000 + offset if seconds else now + offset
			out[k + 1] = bytes_of(strconv.write_int(buf, v, 10))
			continue
		}
		v, parsed := strconv.parse_i64(tok)
		if !parsed || !in_probe_window(v, seconds) {
			continue
		}
		v_ms := v * 1000 if seconds else v
		if i + 1 < len(steps) && steps[i + 1].approx {
			unit := i64(1) if is_command(&steps[i + 1], "pttl") else 1000
			r.base_ms = v_ms - steps[i + 1].hi * unit
		}
		offset := v_ms - r.base_ms
		moved := (now + offset) / 1000 if seconds else now + offset
		out[k + 1] = bytes_of(strconv.write_int(buf, moved, 10))
	}
	return out
}

is_expired_event :: proc(ev: string) -> bool {
	return strings.has_suffix(ev, " expired") || strings.contains(ev, ":expired ")
}

split_events :: proc(events: []string, expired: ^[dynamic]string) -> [dynamic]string {
	kept: [dynamic]string
	for ev in events {
		if is_expired_event(ev) {
			if strings.contains(ev, ":expired ") {
				append(expired, ev)
			}
			continue
		}
		append(&kept, ev)
	}
	return kept
}

same_list :: proc(a, b: []string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}

describe_args :: proc(args: [][]u8) -> string {
	b: strings.Builder
	for a, i in args {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		if len(a) > 48 {
			fmt.sbprintf(&b, "%q...(%d bytes)", string(a[:48]), len(a))
		} else {
			fmt.sbprintf(&b, "%q", string(a))
		}
	}
	return strings.to_string(b)
}

report :: proc(t: ^testing.T, r: ^Replay, step: ^Step, what: string, got: string, want: string) {
	r.failures += 1
	if r.failures > FAILURE_REPORT_MAX {
		return
	}
	g := got if len(got) <= 300 else got[:300]
	w := want if len(want) <= 300 else want[:300]
	testing.expectf(t, false, "%s line %d [%s] %s: %s\n    got  %q\n    want %q", r.label, step.line, step.section, describe_args(step.args[:]), what, g, w)
}

aggregate_prefix :: proc(s: string) -> string {
	at := 0
	for at < len(s) && s[at] == '*' {
		nl := strings.index(s[at:], "\r\n")
		if nl < 0 {
			break
		}
		at += nl + 2
	}
	return s[:at]
}

run_step :: proc(t: ^testing.T, r: ^Replay, steps: []Step, i: int) {
	step := &steps[i]
	args := prepare_args(r, steps, i)
	reply := call_argv(&r.session, args[:])
	got_events := take_events(&r.session)
	r.executed += 1
	if r.check_events {
		want_rest := split_events(step.events[:], &r.want_expired)
		got_rest := split_events(got_events[:], &r.got_expired)
		if !same_list(want_rest[:], got_rest[:]) {
			report(t, r, step, "events", strings.join(got_rest[:], " | "), strings.join(want_rest[:], " | "))
		}
	}
	switch {
	case step.expect == UNCHECKED:
	case step.approx:
		v, ok := int_reply(reply)
		if !ok || v < step.lo || v > step.hi {
			report(t, r, step, "approximate reply", reply, step.expect)
		}
	case is_command(step, "dbsize"):
		want, ok := strconv.parse_i64(step.expect[1:])
		got, got_ok := int_reply(reply)
		want += i64(len(r.want_expired) - len(r.got_expired))
		if !ok || !got_ok || got != want {
			report(t, r, step, "dbsize", reply, fmt.tprintf(":%d", want))
		}
	case:
		want, ok := render_reply(step.expect, r.session.resp)
		if !ok {
			report(t, r, step, "unreadable notation", reply, step.expect)
			return
		}
		if is_command(step, "zrandmember") {
			if aggregate_prefix(reply) != aggregate_prefix(want) {
				report(t, r, step, "reply shape", reply, want)
			}
			return
		}
		if reply != want {
			report(t, r, step, "reply", reply, want)
		}
	}
}

finish_expired :: proc(t: ^testing.T, r: ^Replay) {
	k := 0
	for ev in r.got_expired {
		for k < len(r.want_expired) && r.want_expired[k] != ev {
			k += 1
		}
		if k == len(r.want_expired) {
			testing.expectf(t, false, "%s: expired event %q is not in the observed order %v", r.label, ev, r.want_expired[:])
			return
		}
		k += 1
	}
}

replay_text :: proc(t: ^testing.T, label: string, text: string, resp: u8, events: bool, hook: Replay_Hook = nil) -> int {
	r := replay_open(label, resp, events)
	defer replay_close(&r)
	steps := parse_steps(text, resp)
	for i in 0 ..< len(steps) {
		if hook != nil {
			hook(&r, steps[:], i)
		}
		run_step(t, &r, steps[:], i)
	}
	finish_expired(t, &r)
	testing.expectf(t, r.executed > 0, "%s: no steps were replayed", label)
	testing.expectf(t, r.failures == 0, "%s: %d mismatching steps out of %d", label, r.failures, r.executed)
	return r.executed
}
