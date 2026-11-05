package sortwork

import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:testing"

Record :: struct {
	section: string,
	command: string,
	args:    [dynamic]string,
	reply:   string,
	events:  string,
	line:    int,
}

Replay_Rules :: struct {
	events:     string,
	flush_at:   []string,
	loose:      []string,
	overrides:  []Override,
	freq_slack: []string,
}

Override :: struct {
	section: string,
	command: string,
	reply:   string,
}

@(private)
split_tokens :: proc(command: string) -> [dynamic]string {
	out := make([dynamic]string, 0, 8)
	i := 0
	for i < len(command) {
		if command[i] == ' ' {
			i += 1
			continue
		}
		if command[i] == '"' {
			close := i + 1
			for close < len(command) && !(command[close] == '"' && (close + 1 == len(command) || command[close + 1] == ' ')) {
				close += 1
			}
			append(&out, command[i + 1:close])
			i = close + 1
			continue
		}
		start := i
		for i < len(command) && command[i] != ' ' {
			i += 1
		}
		token := command[start:i]
		if decoded, ok := decode_hex_token(token); ok {
			append(&out, decoded)
			continue
		}
		expand_token(&out, token)
	}
	return out
}

@(private)
decode_hex_token :: proc(token: string) -> (text: string, ok: bool) {
	if !strings.has_prefix(token, "hex[") {
		return
	}
	close := strings.index(token, "]=")
	if close < 0 {
		return
	}
	count, count_ok := strconv.parse_int(token[4:close], 10)
	digits := token[close + 2:]
	if !count_ok || len(digits) != 2 * count {
		return
	}
	out := make([]u8, count)
	for i in 0 ..< count {
		out[i] = hex_value(digits[2 * i]) << 4 | hex_value(digits[2 * i + 1])
	}
	return string(out), true
}

@(private)
Span :: struct {
	prefix: string,
	suffix: string,
	from:   int,
	to:     int,
}

@(private)
find_span :: proc(token: string) -> (sp: Span, ok: bool) {
	open := strings.index(token, "{")
	if open < 0 {
		return
	}
	close := strings.index(token[open:], "}")
	if close < 0 {
		return
	}
	inner := token[open + 1:][:close - 1]
	dots := strings.index(inner, "..")
	if dots < 0 {
		return
	}
	from, from_ok := strconv.parse_int(inner[:dots], 10)
	to, to_ok := strconv.parse_int(inner[dots + 2:], 10)
	if !from_ok || !to_ok {
		return
	}
	return Span{prefix = token[:open], suffix = token[open + close + 1:], from = from, to = to}, true
}

@(private)
span_item :: proc(sp: Span, i: int) -> string {
	step := 1 if sp.to >= sp.from else -1
	return strings.concatenate({sp.prefix, itoa(sp.from + step * i), sp.suffix})
}

@(private)
span_len :: proc(sp: Span) -> int {
	return abs(sp.to - sp.from) + 1
}

@(private)
expand_token :: proc(out: ^[dynamic]string, token: string) {
	if tilde := strings.index_byte(token, '~'); tilde > 0 {
		a, a_ok := find_span(token[:tilde])
		b, b_ok := find_span(token[tilde + 1:])
		if a_ok && b_ok && span_len(a) == span_len(b) {
			for i in 0 ..< span_len(a) {
				append(out, span_item(a, i), span_item(b, i))
			}
			return
		}
	}
	if sp, ok := find_span(token); ok {
		for i in 0 ..< span_len(sp) {
			append(out, span_item(sp, i))
		}
		return
	}
	append(out, token)
}

expand_reply :: proc(reply: string) -> string {
	if strings.index(reply, "..") < 0 {
		return reply
	}
	b: strings.Builder
	strings.builder_init(&b)
	i := 0
	for i < len(reply) {
		if reply[i] == '"' {
			close := strings.index_byte(reply[i + 1:], '"')
			if close >= 0 {
				inner := reply[i + 1:][:close]
				if sp, ok := find_span(inner); ok {
					for k in 0 ..< span_len(sp) {
						if k > 0 {
							strings.write_string(&b, ", ")
						}
						strings.write_byte(&b, '"')
						strings.write_string(&b, span_item(sp, k))
						strings.write_byte(&b, '"')
					}
					i += close + 2
					continue
				}
			}
		}
		strings.write_byte(&b, reply[i])
		i += 1
	}
	return strings.to_string(b)
}

parse_records :: proc(text: string) -> [dynamic]Record {
	out := make([dynamic]Record, 0, 256)
	lines := strings.split(text, "\n")
	section := ""
	i := 0
	for i < len(lines) {
		line := lines[i]
		number := i + 1
		i += 1
		switch {
		case len(line) == 0:
			continue
		case strings.has_prefix(line, "## "):
			section = line[3:]
			continue
		case strings.has_prefix(line, "# "):
			continue
		case strings.has_prefix(line, "    events: "):
			if len(out) > 0 {
				out[len(out) - 1].events = line[len("    events: "):]
			}
			continue
		}
		joined := line
		for strings.index(joined, " => ") < 0 && i < len(lines) {
			joined = strings.concatenate({joined, "\n", lines[i]})
			i += 1
		}
		arrow := strings.index(joined, " => ")
		if arrow < 0 {
			continue
		}
		reply := joined[arrow + 4:]
		if note := strings.index(reply, "    ; "); note >= 0 {
			reply = reply[:note]
		}
		rec := Record {
			section = section,
			command = joined[:arrow],
			reply   = expand_reply(reply),
			line    = number,
		}
		rec.args = split_tokens(rec.command)
		append(&out, rec)
	}
	return out
}

@(private)
event_is_expiry :: proc(event: string) -> bool {
	space := strings.index_byte(event, ' ')
	if space < 0 {
		return false
	}
	channel := event[:space]
	message := event[space + 1:]
	if message == "expired" || message == "hexpired" {
		return true
	}
	return strings.has_suffix(channel, ":expired") || strings.has_suffix(channel, ":hexpired")
}

@(private)
drop_expiry :: proc(events: string) -> string {
	if events == "" {
		return events
	}
	kept := make([dynamic]string, 0, 4, context.temp_allocator)
	for part in strings.split(events, " | ", context.temp_allocator) {
		if !event_is_expiry(part) {
			append(&kept, part)
		}
	}
	return strings.join(kept[:], " | ", context.temp_allocator)
}

@(private)
contains :: proc(list: []string, s: string) -> bool {
	for x in list {
		if x == s {
			return true
		}
	}
	return false
}

@(private)
upper_eq :: proc(s: string, want: string) -> bool {
	return strings.to_upper(s, context.temp_allocator) == want
}

@(private)
needs_pause :: proc(args: []string) -> int {
	if len(args) >= 3 && upper_eq(args[0], "HPEXPIRE") && args[2] == "1" {
		return 60
	}
	if len(args) >= 5 && upper_eq(args[0], "SET") && upper_eq(args[3], "PX") && args[4] == "1" {
		return 30
	}
	return 0
}

replay :: proc(t: ^testing.T, name: string, text: string, resp: u8, rules: Replay_Rules) -> (checked: int) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		testing.fail_now(t, "arena")
	}
	defer virtual.arena_destroy(&arena)
	records: [dynamic]Record
	{
		context.allocator = virtual.arena_allocator(&arena)
		records = parse_records(text)
	}
	testing.expectf(t, len(records) > 0, "%s: no records", name)
	s := open_session(resp, rules.events)
	defer close_session(&s)
	section := ""
	for &rec in records {
		if rec.section != section {
			section = rec.section
			if contains(rules.flush_at, section) {
				call(&s, "FLUSHALL")
				take_events(&s)
			}
		}
		got := call(&s, ..rec.args[:])
		events := take_events(&s)
		if ms := needs_pause(rec.args[:]); ms > 0 {
			pause(ms)
		}
		want := rec.reply
		for o in rules.overrides {
			if o.section == rec.section && o.command == rec.command {
				want = o.reply
			}
		}
		node, used, parsed := resp_parse(got)
		if !testing.expectf(t, parsed && used == len(got), "%s:%d %s: unparsable reply %q", name, rec.line, rec.command, got) {
			continue
		}
		expected, expected_ok := note_parse(want)
		if !testing.expectf(t, expected_ok, "%s:%d %s: unparsable expectation %q", name, rec.line, rec.command, want) {
			continue
		}
		if expected.kind == .Range {
			testing.expectf(t, node.kind == .Int && node.num >= expected.num && node.num <= expected.hi, "%s:%d %s: got %s want %s", name, rec.line, rec.command, render(node), want)
		} else if contains(rules.freq_slack, rec.command) && expected.kind == .Int {
			testing.expectf(t, node.kind == .Int && node.num >= expected.num && node.num <= expected.num + 2, "%s:%d %s: got %s want about %s", name, rec.line, rec.command, render(node), want)
		} else {
			normalize(rec.args[:], &node)
			normalize(rec.args[:], &expected)
			a := render(node)
			b := render(expected)
			testing.expectf(t, a == b, "%s:%d %s: got %s want %s", name, rec.line, rec.command, a, b)
		}
		want_events := rec.events
		if contains(rules.loose, rec.command) {
			want_events = drop_expiry(want_events)
			events = drop_expiry(events)
		}
		if rules.events != "" {
			testing.expectf(t, events == want_events, "%s:%d %s: events %q want %q", name, rec.line, rec.command, events, want_events)
		}
		checked += 1
		free_all(context.temp_allocator)
	}
	return
}
