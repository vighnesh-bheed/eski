package vsettype

import "core:log"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"

Resp_Node :: struct {
	kind:  u8,
	text:  string,
	items: []Resp_Node,
}

resp_parse :: proc(data: string, at: ^int) -> (node: Resp_Node, ok: bool) {
	if at^ >= len(data) {
		return {}, false
	}
	kind := data[at^]
	end := strings.index(data[at^:], "\r\n")
	if end < 0 {
		return {}, false
	}
	line := data[at^ + 1:at^ + end]
	at^ += end + 2
	node.kind = kind
	switch kind {
	case '+', '-', ':', ',', '#', '_':
		node.text = line
		return node, true
	case '$':
		n, nok := strconv.parse_int(line, 10)
		if !nok {
			return {}, false
		}
		if n < 0 {
			node.kind = '_'
			return node, true
		}
		if at^ + n + 2 > len(data) {
			return {}, false
		}
		node.text = data[at^:at^ + n]
		at^ += n + 2
		return node, true
	case '*', '%', '~':
		n, nok := strconv.parse_int(line, 10)
		if !nok {
			return {}, false
		}
		if n < 0 {
			node.kind = '_'
			return node, true
		}
		count := n * 2 if kind == '%' else n
		items := make([]Resp_Node, count, context.temp_allocator)
		for i in 0 ..< count {
			items[i] = resp_parse(data, at) or_return
		}
		node.items = items
		return node, true
	}
	return {}, false
}

resp_tree :: proc(data: string) -> (Resp_Node, bool) {
	at := 0
	node, ok := resp_parse(data, &at)
	return node, ok && at == len(data)
}

Replay_Stats :: struct {
	package_exact:      int,
	package_shape:      int,
	package_ties:       int,
	errors:             int,
	server_exact:       int,
	args_cases:         int,
	mismatched:         [dynamic]int,
	shape_mismatched:   [dynamic]int,
	server_mismatched:  [dynamic]int,
	args_not_errors:    [dynamic]int,
	commands:           map[string]int,
}

compare_vinfo :: proc(ours: Resp_Node, want: Resp_Node) -> bool {
	if ours.kind != want.kind || len(ours.items) != len(want.items) {
		return false
	}
	for i := 0; i + 1 < len(want.items); i += 2 {
		field := want.items[i].text
		if ours.items[i].text != field {
			return false
		}
		if field == "max-level" || field == "vset-uid" {
			continue
		}
		if ours.items[i + 1].text != want.items[i + 1].text || ours.items[i + 1].kind != want.items[i + 1].kind {
			return false
		}
	}
	return true
}

compare_randmember :: proc(s: Vset, ours: Resp_Node, want: Resp_Node, unique: bool) -> bool {
	if ours.kind != want.kind || len(ours.items) != len(want.items) {
		return false
	}
	if ours.kind == '$' {
		return s != nil && contains(s, transmute([]u8)ours.text)
	}
	seen := make(map[string]bool, 16, context.temp_allocator)
	for item in ours.items {
		if s == nil || !contains(s, transmute([]u8)item.text) {
			return false
		}
		if unique && item.text in seen {
			return false
		}
		seen[item.text] = true
	}
	return true
}

compare_links :: proc(s: Vset, element: string, want: Resp_Node, scores: bool) -> bool {
	if s == nil || want.kind != '*' {
		return false
	}
	slot, found := find(s, transmute([]u8)element)
	if !found {
		return false
	}
	buf: [32]u8
	for layer in want.items {
		step := 2 if scores else 1
		for i := 0; i < len(layer.items); i += step {
			other, ok := find(s, transmute([]u8)layer.items[i].text)
			if !ok {
				return false
			}
			if scores && double_text(buf[:], f64(link_score(s, slot, other))) != layer.items[i + 1].text {
				return false
			}
		}
	}
	return true
}

flatten_pairs :: proc(n: Resp_Node, out: ^[dynamic]string) {
	if n.kind == '*' || n.kind == '%' {
		for item in n.items {
			flatten_pairs(item, out)
		}
		return
	}
	append(out, strings.concatenate({string([]u8{n.kind}), n.text}, context.temp_allocator))
}

compare_unordered :: proc(ours: Resp_Node, want: Resp_Node) -> bool {
	if ours.kind != want.kind || len(ours.items) != len(want.items) {
		return false
	}
	a := make([dynamic]string, context.temp_allocator)
	b := make([dynamic]string, context.temp_allocator)
	flatten_pairs(ours, &a)
	flatten_pairs(want, &b)
	if len(a) != len(b) {
		return false
	}
	slice.sort(a[:])
	slice.sort(b[:])
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}

vsim_names :: proc(n: Resp_Node, proto: int, scores: bool, attribs: bool) -> (names: []string, extras: []Resp_Node) {
	if n.kind == '*' && !scores && !attribs {
		out := make([]string, len(n.items), context.temp_allocator)
		for item, i in n.items {
			out[i] = item.text
		}
		return out, nil
	}
	stride := 2
	if proto < 3 && scores && attribs {
		stride = 3
	}
	count := len(n.items) / stride
	out := make([]string, count, context.temp_allocator)
	rest := make([]Resp_Node, count, context.temp_allocator)
	for i in 0 ..< count {
		out[i] = n.items[i * stride].text
		if stride == 3 {
			rest[i] = n.items[i * stride + 2]
		} else if proto >= 3 && scores && attribs {
			rest[i] = n.items[i * stride + 1].items[1]
		} else if attribs && !scores {
			rest[i] = n.items[i * stride + 1]
		} else {
			rest[i] = {}
		}
	}
	return out, rest
}

compare_vsim_ties :: proc(rp: ^Replay, s: Vset, argv: []string, proto: int, ours: Resp_Node, want: Resp_Node) -> bool {
	if s == nil || ours.kind != want.kind || len(ours.items) != len(want.items) || rp.truth {
		return false
	}
	scores, attribs := false, false
	for a in argv {
		if fold(a, "WITHSCORES") {
			scores = true
		}
		if fold(a, "WITHATTRIBS") {
			attribs = true
		}
	}
	a, ar := vsim_names(ours, proto, scores, attribs)
	b, br := vsim_names(want, proto, scores, attribs)
	if len(a) != len(b) {
		return false
	}
	for name, i in b {
		sa, oka := rp.scores[a[i]]
		sb, okb := rp.scores[name]
		if !oka || !okb || transmute(u64)sa != transmute(u64)sb {
			return false
		}
		if attribs {
			text, has := get_attribute(s, transmute([]u8)name)
			node := br[i]
			if has != (node.kind == '$') || (has && node.text != text) {
				return false
			}
			_ = ar
		}
	}
	return true
}

KNOWN_SHAPE_GAPS :: []int{}
KNOWN_EXACT_GAPS :: []int{}

contains_id :: proc(ids: []int, id: int) -> bool {
	for x in ids {
		if x == id {
			return true
		}
	}
	return false
}

@(test)
observed_trace_replay :: proc(t: ^testing.T) {
	rp: Replay
	replay_init(&rp)
	defer replay_destroy(&rp)
	stats: Replay_Stats
	defer {
		delete(stats.mismatched)
		delete(stats.shape_mismatched)
		delete(stats.server_mismatched)
		delete(stats.args_not_errors)
		delete(stats.commands)
	}
	for &ev in OBSERVED_TRACE {
		outcome := replay_run(&rp, ev.argv, ev.proto)
		if !ev.recorded {
			continue
		}
		ours := resp_text(&rp.resp)
		name := strings.to_upper(ev.argv[0], context.temp_allocator)
		switch outcome {
		case .Args:
			stats.args_cases += 1
			if len(ev.reply) == 0 || ev.reply[0] != '-' {
				append(&stats.args_not_errors, ev.id)
				log.infof("case %d: harness rejected %v but the reference replied %q", ev.id, ev.argv, ev.reply)
			}
		case .Server:
			if ours == ev.reply {
				stats.server_exact += 1
			} else {
				append(&stats.server_mismatched, ev.id)
				log.infof("case %d %v: server-level reply %q against %q", ev.id, ev.argv, ours, ev.reply)
			}
		case .Package:
			shaped := ev.nondeterministic || name == "VINFO" || (name == "VRANDMEMBER" && len(ev.argv) == 3)
			if !shaped {
				if ours == ev.reply {
					stats.package_exact += 1
					stats.commands[name] += 1
					if len(ours) > 0 && ours[0] == '-' {
						stats.errors += 1
					}
				} else {
					entry, _ := replay_lookup(&rp, ev.proto, ev.argv[1])
					want, wok := resp_tree(ev.reply)
					mine, mok := resp_tree(ours)
					if name == "VSIM" && wok && mok && compare_vsim_ties(&rp, entry.set, ev.argv, ev.proto, mine, want) {
						stats.package_ties += 1
						stats.commands[name] += 1
					} else {
						append(&stats.mismatched, ev.id)
						log.infof("case %d %v: %q against %q", ev.id, ev.argv, ours, ev.reply)
					}
				}
				continue
			}
			want, wok := resp_tree(ev.reply)
			mine, mok := resp_tree(ours)
			same := false
			if wok && mok {
				entry, _ := replay_lookup(&rp, ev.proto, ev.argv[1])
				switch name {
				case "VINFO":
					same = compare_vinfo(mine, want)
				case "VRANDMEMBER":
					unique := true
					if len(ev.argv) == 3 {
						n, _ := parse_int(ev.argv[2])
						unique = n > 0
					}
					same = compare_randmember(entry.set, mine, want, unique)
				case "VLINKS":
					same = compare_links(entry.set, ev.argv[2], want, len(ev.argv) == 4)
				case "VSIM":
					same = ours == ev.reply || compare_unordered(mine, want) || compare_vsim_ties(&rp, entry.set, ev.argv, ev.proto, mine, want)
				case:
					same = ours == ev.reply
				}
			}
			if same {
				stats.package_shape += 1
				stats.commands[name] += 1
			} else {
				append(&stats.shape_mismatched, ev.id)
				log.infof("case %d %v (nondeterministic): %q against %q", ev.id, ev.argv, ours, ev.reply)
			}
		}
	}
	log.infof("replay: package exact %d (state-dependent errors %d), package ties %d, package shape %d, server-level %d, argument-lane %d", stats.package_exact, stats.errors, stats.package_ties, stats.package_shape, stats.server_exact, stats.args_cases)
	log.infof("replay mismatches: exact %v, shape %v, server %v, harness %v", stats.mismatched[:], stats.shape_mismatched[:], stats.server_mismatched[:], stats.args_not_errors[:])
	for k, v in stats.commands {
		log.infof("replay matched %s %d", k, v)
	}
	for id in stats.mismatched {
		testing.expectf(t, contains_id(KNOWN_EXACT_GAPS, id), "case %d differs from the reference", id)
	}
	for id in stats.shape_mismatched {
		testing.expectf(t, contains_id(KNOWN_SHAPE_GAPS, id), "case %d differs in shape from the reference", id)
	}
	testing.expect_value(t, len(stats.server_mismatched), 0)
	testing.expect_value(t, len(stats.args_not_errors), 0)
}
