package sortwork

import "core:strconv"
import "core:strings"

Node_Kind :: enum u8 {
	Simple,
	Error,
	Int,
	Bulk,
	Nil,
	Array,
	Set,
	Map,
	Double,
	Push,
	Bool,
	Range,
	Masked,
}

Node :: struct {
	kind:  Node_Kind,
	text:  string,
	num:   i64,
	hi:    i64,
	items: [dynamic]Node,
}

@(private)
read_header_int :: proc(s: string) -> (n: i64, ok: bool) {
	return strconv.parse_i64(s, 10)
}

resp_parse :: proc(s: string) -> (node: Node, used: int, ok: bool) {
	if len(s) < 3 {
		return
	}
	end := strings.index(s, "\r\n")
	if end < 0 {
		return
	}
	head := s[1:end]
	at := end + 2
	switch s[0] {
	case '+':
		return Node{kind = .Simple, text = head}, at, true
	case '-':
		return Node{kind = .Error, text = head}, at, true
	case ':':
		n, good := read_header_int(head)
		return Node{kind = .Int, num = n}, at, good
	case '_':
		return Node{kind = .Nil}, at, true
	case ',':
		return Node{kind = .Double, text = head}, at, true
	case '#':
		return Node{kind = .Bool, text = head}, at, true
	case '(':
		return Node{kind = .Simple, text = head}, at, true
	case '$', '=':
		n, good := read_header_int(head)
		if !good {
			return
		}
		if n < 0 {
			return Node{kind = .Nil}, at, true
		}
		if at + int(n) + 2 > len(s) {
			return
		}
		return Node{kind = .Bulk, text = s[at:][:n]}, at + int(n) + 2, true
	case '*', '~', '>', '%':
		n, good := read_header_int(head)
		if !good {
			return
		}
		if n < 0 {
			return Node{kind = .Nil}, at, true
		}
		kind := Node_Kind.Array
		count := int(n)
		switch s[0] {
		case '~':
			kind = .Set
		case '>':
			kind = .Push
		case '%':
			kind = .Map
			count *= 2
		}
		node = Node{kind = kind}
		node.items = make([dynamic]Node, 0, count, context.temp_allocator)
		for _ in 0 ..< count {
			child, child_used, child_ok := resp_parse(s[at:])
			if !child_ok {
				return
			}
			append(&node.items, child)
			at += child_used
		}
		return node, at, true
	}
	return
}

@(private)
printable :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] < 0x20 || s[i] > 0x7e {
			return false
		}
	}
	return true
}

@(private)
hex_digits := "0123456789abcdef"

format_node :: proc(b: ^strings.Builder, n: Node) {
	switch n.kind {
	case .Simple:
		strings.write_byte(b, '+')
		strings.write_string(b, n.text)
	case .Error:
		strings.write_byte(b, '-')
		strings.write_string(b, n.text)
	case .Int:
		strings.write_byte(b, ':')
		strings.write_i64(b, n.num)
	case .Bulk:
		if printable(n.text) {
			strings.write_byte(b, '"')
			strings.write_string(b, n.text)
			strings.write_byte(b, '"')
		} else {
			strings.write_string(b, "hex[")
			strings.write_int(b, len(n.text))
			strings.write_string(b, "]=")
			for i in 0 ..< len(n.text) {
				strings.write_byte(b, hex_digits[n.text[i] >> 4])
				strings.write_byte(b, hex_digits[n.text[i] & 15])
			}
		}
	case .Nil:
		strings.write_string(b, "nil")
	case .Array, .Set, .Push:
		switch n.kind {
		case .Set:
			strings.write_string(b, "~[")
		case .Push:
			strings.write_string(b, ">[")
		case .Simple, .Error, .Int, .Bulk, .Nil, .Array, .Map, .Double, .Bool, .Range, .Masked:
			strings.write_byte(b, '[')
		}
		for item, i in n.items {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			format_node(b, item)
		}
		strings.write_byte(b, ']')
	case .Map:
		strings.write_string(b, "%{")
		for i := 0; i + 1 < len(n.items); i += 2 {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			format_node(b, n.items[i])
			strings.write_string(b, ": ")
			format_node(b, n.items[i + 1])
		}
		strings.write_byte(b, '}')
	case .Double:
		strings.write_byte(b, ',')
		strings.write_string(b, n.text)
	case .Bool:
		strings.write_byte(b, '#')
		strings.write_string(b, n.text)
	case .Range:
		strings.write_string(b, "integer within [")
		strings.write_i64(b, n.num)
		strings.write_string(b, ", ")
		strings.write_i64(b, n.hi)
		strings.write_byte(b, ']')
	case .Masked:
		strings.write_byte(b, '<')
		strings.write_string(b, n.text)
		strings.write_byte(b, '>')
	}
}

render :: proc(n: Node) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	format_node(&b, n)
	return strings.to_string(b)
}

@(private)
Note_Reader :: struct {
	s:  string,
	at: int,
}

@(private)
note_has :: proc(r: ^Note_Reader, prefix: string) -> bool {
	return strings.has_prefix(r.s[r.at:], prefix)
}

@(private)
note_until :: proc(r: ^Note_Reader, nested: bool) -> string {
	start := r.at
	if !nested {
		r.at = len(r.s)
		return r.s[start:]
	}
	for r.at < len(r.s) {
		if r.s[r.at] == ']' || r.s[r.at] == '}' || note_has(r, ", ") {
			break
		}
		r.at += 1
	}
	return r.s[start:r.at]
}

@(private)
note_value :: proc(r: ^Note_Reader, nested: bool) -> (n: Node, ok: bool) {
	if r.at >= len(r.s) {
		return
	}
	switch {
	case note_has(r, "integer within ["):
		r.at += len("integer within [")
		comma := strings.index(r.s[r.at:], ", ")
		close := strings.index(r.s[r.at:], "]")
		if comma < 0 || close < comma {
			return
		}
		lo, lo_ok := strconv.parse_i64(r.s[r.at:][:comma], 10)
		hi, hi_ok := strconv.parse_i64(r.s[r.at + comma + 2:][:close - comma - 2], 10)
		r.at += close + 1
		return Node{kind = .Range, num = lo, hi = hi}, lo_ok && hi_ok
	case note_has(r, "nil"):
		r.at += 3
		return Node{kind = .Nil}, true
	case note_has(r, "hex["):
		r.at += 4
		close := strings.index(r.s[r.at:], "]=")
		if close < 0 {
			return
		}
		count, count_ok := strconv.parse_int(r.s[r.at:][:close], 10)
		if !count_ok {
			return
		}
		r.at += close + 2
		if r.at + 2 * count > len(r.s) {
			return
		}
		out := make([]u8, count, context.temp_allocator)
		for i in 0 ..< count {
			hi := hex_value(r.s[r.at + 2 * i])
			lo := hex_value(r.s[r.at + 2 * i + 1])
			out[i] = hi << 4 | lo
		}
		r.at += 2 * count
		return Node{kind = .Bulk, text = string(out)}, true
	case note_has(r, "~["):
		r.at += 2
		return note_list(r, .Set)
	case note_has(r, ">["):
		r.at += 2
		return note_list(r, .Push)
	case note_has(r, "["):
		r.at += 1
		return note_list(r, .Array)
	case note_has(r, "%{"):
		r.at += 2
		return note_map(r)
	}
	switch r.s[r.at] {
	case '+':
		r.at += 1
		return Node{kind = .Simple, text = note_until(r, nested)}, true
	case '-':
		r.at += 1
		return Node{kind = .Error, text = note_until(r, nested)}, true
	case ':':
		r.at += 1
		text := note_until(r, true)
		v, good := strconv.parse_i64(text, 10)
		return Node{kind = .Int, num = v}, good
	case ',':
		r.at += 1
		start := r.at
		for r.at < len(r.s) && r.s[r.at] != ',' && r.s[r.at] != ']' && r.s[r.at] != '}' {
			r.at += 1
		}
		return Node{kind = .Double, text = r.s[start:r.at]}, true
	case '"':
		r.at += 1
		close := strings.index_byte(r.s[r.at:], '"')
		if close < 0 {
			return
		}
		text := r.s[r.at:][:close]
		r.at += close + 1
		return Node{kind = .Bulk, text = text}, true
	}
	return
}

@(private)
note_list :: proc(r: ^Note_Reader, kind: Node_Kind) -> (n: Node, ok: bool) {
	n.kind = kind
	n.items = make([dynamic]Node, 0, 4, context.temp_allocator)
	if note_has(r, "]") {
		r.at += 1
		return n, true
	}
	for {
		item, item_ok := note_value(r, true)
		if !item_ok {
			return
		}
		append(&n.items, item)
		if note_has(r, ", ") {
			r.at += 2
			continue
		}
		if note_has(r, "]") {
			r.at += 1
			return n, true
		}
		return
	}
}

@(private)
note_map :: proc(r: ^Note_Reader) -> (n: Node, ok: bool) {
	n.kind = .Map
	n.items = make([dynamic]Node, 0, 4, context.temp_allocator)
	if note_has(r, "}") {
		r.at += 1
		return n, true
	}
	for {
		key, key_ok := note_value(r, true)
		if !key_ok || !note_has(r, ": ") {
			return
		}
		r.at += 2
		value, value_ok := note_value(r, true)
		if !value_ok {
			return
		}
		append(&n.items, key, value)
		if note_has(r, ", ") {
			r.at += 2
			continue
		}
		if note_has(r, "}") {
			r.at += 1
			return n, true
		}
		return
	}
}

@(private)
hex_value :: proc(b: u8) -> u8 {
	switch b {
	case '0' ..= '9':
		return b - '0'
	case 'a' ..= 'f':
		return b - 'a' + 10
	case 'A' ..= 'F':
		return b - 'A' + 10
	}
	return 0
}

note_parse :: proc(text: string) -> (n: Node, ok: bool) {
	r := Note_Reader{s = text}
	n, ok = note_value(&r, false)
	if ok && r.at != len(text) {
		ok = false
	}
	return
}

@(private)
digits_only :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

@(private)
is_clock_id :: proc(s: string) -> bool {
	dash := strings.index_byte(s, '-')
	return dash >= 12 && digits_only(s[:dash]) && digits_only(s[dash + 1:])
}

@(private)
mask :: proc(n: ^Node, label: string) {
	n.kind = .Masked
	n.text = label
	clear(&n.items)
}

@(private)
mask_clock :: proc(n: ^Node) {
	switch n.kind {
	case .Bulk:
		if is_clock_id(n.text) {
			mask(n, "id")
		}
	case .Int:
		if n.num >= 1_000_000_000_000 {
			mask(n, "ms")
		}
	case .Array, .Set, .Map, .Push:
		for &item in n.items {
			mask_clock(&item)
		}
	case .Simple, .Error, .Nil, .Double, .Bool, .Range, .Masked:
	}
}

@(private)
mask_pairs :: proc(n: ^Node, keys: []string) {
	#partial switch n.kind {
	case .Array, .Map:
		for i := 0; i + 1 < len(n.items); i += 2 {
			k := n.items[i]
			v := &n.items[i + 1]
			if k.kind == .Bulk && v.kind == .Int && v.num >= 0 {
				for want in keys {
					if k.text == want {
						mask(v, "ms")
					}
				}
			}
		}
		for &item in n.items {
			mask_pairs(&item, keys)
		}
	}
}

normalize :: proc(args: []string, n: ^Node) {
	mask_clock(n)
	if len(args) == 0 {
		return
	}
	name := strings.to_upper(args[0], context.temp_allocator)
	switch {
	case name == "XINFO" && len(args) >= 2 && strings.to_upper(args[1], context.temp_allocator) == "CONSUMERS":
		mask_pairs(n, {"idle", "inactive"})
	case name == "XPENDING" && len(args) > 3:
		if n.kind == .Array {
			for &entry in n.items {
				if entry.kind == .Array && len(entry.items) == 4 {
					mask(&entry.items[2], "ms")
				}
			}
		}
	case name == "HPTTL" || name == "PTTL":
		normalize_ttl(n)
	}
}

@(private)
normalize_ttl :: proc(n: ^Node) {
	#partial switch n.kind {
	case .Int:
		if n.num > 0 {
			mask(n, "ttl")
		}
	case .Array:
		for &item in n.items {
			normalize_ttl(&item)
		}
	}
}
