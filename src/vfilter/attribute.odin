package vfilter

import "core:mem"
import "core:slice"

Attribute :: struct {
	blob: []u8,
}

Field_Kind :: enum u8 {
	Number,
	String,
	Array,
	Null,
	Missing,
}

Field_Entry :: struct {
	num:      f64,
	hash:     u32,
	name_off: u32,
	name_len: u32,
	data_off: u32,
	data_len: u32,
	kind:     Field_Kind,
}

Attribute_Header :: struct {
	text_len:    u64,
	field_count: u32,
	item_count:  u32,
	object:      bool,
}

ATTRIBUTE_HEADER_SIZE :: size_of(Attribute_Header)
ARRAY_DEPTH_LIMIT :: 1000

Builder :: struct {
	text:         string,
	fields:       []Field_Entry,
	items:        []Item,
	decoded:      []u8,
	field_count:  int,
	item_count:   int,
	decoded_len:  int,
	decoded_base: int,
	text_base:    int,
	filling:      bool,
}

name_hash :: #force_inline proc "contextless" (name: string) -> u32 {
	hash: u32 = 2166136261
	for i in 0 ..< len(name) {
		hash ~= u32(name[i])
		hash *= 16777619
	}
	return hash
}

skip_json_space :: #force_inline proc "contextless" (text: string, at: int) -> int {
	i := at
	for i < len(text) && is_c_space(text[i]) {
		i += 1
	}
	return i
}

json_escape :: #force_inline proc "contextless" (c: u8) -> u8 {
	switch c {
	case 'n':
		return '\n'
	case 't':
		return '\t'
	case 'r':
		return '\r'
	}
	return c
}

scan_json_raw_string :: proc "contextless" (text: string, start: int) -> (end: int, escaped: bool, decoded_len: int, ok: bool) {
	i := start + 1
	for i < len(text) {
		c := text[i]
		if c == '"' {
			return i, escaped, decoded_len, true
		}
		if c == '\\' {
			if i + 1 >= len(text) {
				return len(text), escaped, decoded_len, false
			}
			escaped = true
			i += 2
		} else {
			i += 1
		}
		decoded_len += 1
	}
	return len(text), escaped, decoded_len, false
}

decode_json_string :: proc "contextless" (text: string, start, end: int, out: []u8) {
	i := start
	written := 0
	for i < end {
		c := text[i]
		if c == '\\' {
			out[written] = json_escape(text[i + 1])
			i += 2
		} else {
			out[written] = c
			i += 1
		}
		written += 1
	}
}

is_json_number_start :: #force_inline proc "contextless" (c: u8) -> bool {
	return is_digit(c) || c == '+' || c == '-'
}

is_json_number_byte :: #force_inline proc "contextless" (c: u8) -> bool {
	return is_digit(c) || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-'
}

json_number_end :: proc "contextless" (text: string, start: int) -> int {
	i := start
	for i < len(text) && is_json_number_byte(text[i]) {
		i += 1
	}
	return i
}

json_word :: proc "contextless" (text: string, at: int) -> (kind: Value_Kind, num: f64, end: int, ok: bool) {
	rest := text[at:]
	word: string
	switch {
	case len(rest) >= 4 && rest[:4] == "true":
		word, kind, num = "true", .Number, 1
	case len(rest) >= 5 && rest[:5] == "false":
		word, kind = "false", .Number
	case len(rest) >= 4 && rest[:4] == "null":
		word, kind = "null", .Null
	case:
		return
	}
	end = at + len(word)
	if end < len(text) {
		follower := text[end]
		if !is_c_space(follower) && follower != ',' && follower != '}' && follower != ']' {
			return
		}
	}
	ok = true
	return
}

builder_string :: proc(b: ^Builder, start, end: int, escaped: bool, decoded_len: int) -> (off: u32, length: u32) {
	if !escaped {
		return u32(b.text_base + start), u32(end - start)
	}
	off = u32(b.decoded_base + b.decoded_len)
	if b.filling && b.decoded_len + decoded_len <= len(b.decoded) {
		decode_json_string(b.text, start, end, b.decoded[b.decoded_len:][:decoded_len])
	}
	b.decoded_len += decoded_len
	return off, u32(decoded_len)
}

builder_text :: proc(b: ^Builder, off, length: u32) -> string {
	if int(off) < b.text_base {
		start := int(off) - b.decoded_base
		if start + int(length) > len(b.decoded) {
			return ""
		}
		return string(b.decoded[start:][:length])
	}
	return b.text[int(off) - b.text_base:][:length]
}

Scalar :: struct {
	kind: Value_Kind,
	num:  f64,
	off:  u32,
	len:  u32,
}

parse_json_scalar :: proc(b: ^Builder, at: int) -> (scalar: Scalar, end: int, ok: bool) {
	text := b.text
	if at >= len(text) {
		return
	}
	c := text[at]
	switch {
	case c == '"':
		close, escaped, decoded_len, closed := scan_json_raw_string(text, at)
		if !closed {
			return
		}
		scalar.kind = .String
		scalar.off, scalar.len = builder_string(b, at + 1, close, escaped, decoded_len)
		if b.filling {
			scalar.num = string_number(builder_text(b, scalar.off, scalar.len))
		}
		return scalar, close + 1, true
	case is_json_number_start(c):
		stop := json_number_end(text, at)
		value, valid := run_number(text[at:stop])
		if !valid {
			return
		}
		return Scalar{kind = .Number, num = value}, stop, true
	case c == 't' || c == 'f' || c == 'n':
		kind, num, stop, valid := json_word(text, at)
		if !valid {
			return
		}
		return Scalar{kind = kind, num = num}, stop, true
	}
	return
}

parse_json_array :: proc(b: ^Builder, at: int, entry: ^Field_Entry) -> bool {
	text := b.text
	first := b.item_count
	depth := 1
	i := skip_json_space(text, at + 1)
	expect_item := true
	if i < len(text) && text[i] == ']' {
		entry.data_off = u32(first)
		entry.data_len = 0
		return true
	}
	for {
		if expect_item {
			i = skip_json_space(text, i)
			if i >= len(text) {
				return false
			}
			if text[i] == '[' {
				if depth == 1 {
					if b.filling && b.item_count < len(b.items) {
						b.items[b.item_count] = Item{kind = .Array}
					}
					b.item_count += 1
				}
				depth += 1
				if depth >= ARRAY_DEPTH_LIMIT {
					return false
				}
				i = skip_json_space(text, i + 1)
				if i < len(text) && text[i] == ']' {
					depth -= 1
					i += 1
					expect_item = false
				}
				continue
			}
			scalar, end, valid := parse_json_scalar(b, i)
			if !valid {
				return false
			}
			if depth == 1 {
				if b.filling && b.item_count < len(b.items) {
					b.items[b.item_count] = Item{kind = scalar.kind, num = scalar.num, off = scalar.off, len = scalar.len}
				}
				b.item_count += 1
			}
			i = end
			expect_item = false
			continue
		}
		i = skip_json_space(text, i)
		if i >= len(text) {
			return false
		}
		switch text[i] {
		case ',':
			i += 1
			expect_item = true
		case ']':
			i += 1
			depth -= 1
			if depth == 0 {
				entry.data_off = u32(first)
				entry.data_len = u32(b.item_count - first)
				return true
			}
		case:
			return false
		}
	}
}

parse_json_member :: proc(b: ^Builder, at: int, entry: ^Field_Entry) {
	text := b.text
	entry.kind = .Missing
	if at >= len(text) {
		return
	}
	if text[at] == '[' {
		mark, decoded_mark := b.item_count, b.decoded_len
		if parse_json_array(b, at, entry) {
			entry.kind = .Array
		} else {
			b.item_count = mark
			b.decoded_len = decoded_mark
		}
		return
	}
	scalar, _, valid := parse_json_scalar(b, at)
	if !valid {
		return
	}
	entry.num = scalar.num
	entry.data_off = scalar.off
	entry.data_len = scalar.len
	switch scalar.kind {
	case .Number:
		entry.kind = .Number
	case .String:
		entry.kind = .String
	case .Null:
		entry.kind = .Null
	case .Array:
	}
}

skip_json_value :: proc "contextless" (text: string, at: int) -> (end: int, ok: bool) {
	if at >= len(text) {
		return
	}
	c := text[at]
	switch {
	case c == '"':
		close, _, _, closed := scan_json_raw_string(text, at)
		return close + 1, closed
	case c == '{' || c == '[':
		closer: u8 = '}' if c == '{' else ']'
		depth := 0
		i := at
		for i < len(text) {
			d := text[i]
			if d == '"' {
				close, _, _, closed := scan_json_raw_string(text, i)
				if !closed {
					return
				}
				i = close + 1
				continue
			}
			if d == c {
				depth += 1
			} else if d == closer {
				depth -= 1
				if depth == 0 {
					return i + 1, true
				}
			}
			i += 1
		}
		return
	case c == 't' || c == 'f' || c == 'n':
		_, _, stop, valid := json_word(text, at)
		return stop, valid
	case is_json_number_byte(c):
		return json_number_end(text, at), true
	}
	return
}

key_is_selectable :: proc "contextless" (key: string) -> bool {
	if len(key) == 0 {
		return false
	}
	for i in 0 ..< len(key) {
		if !is_name_byte(key[i]) {
			return false
		}
	}
	return true
}

walk_object :: proc(b: ^Builder) -> bool {
	text := b.text
	i := skip_json_space(text, 0)
	if i >= len(text) || text[i] != '{' {
		return false
	}
	i += 1
	for {
		i = skip_json_space(text, i)
		if i >= len(text) || text[i] != '"' {
			return true
		}
		key_close, key_escaped, _, key_closed := scan_json_raw_string(text, i)
		if !key_closed {
			return true
		}
		key := text[i + 1:key_close]
		i = skip_json_space(text, key_close + 1)
		if i >= len(text) || text[i] != ':' {
			return true
		}
		i = skip_json_space(text, i + 1)
		if !key_escaped && key_is_selectable(key) {
			entry := Field_Entry {
				hash     = name_hash(key),
				name_off = u32(b.text_base + key_close - len(key)),
				name_len = u32(len(key)),
			}
			parse_json_member(b, i, &entry)
			if b.filling {
				b.fields[b.field_count] = entry
			}
			b.field_count += 1
		}
		end, skipped := skip_json_value(text, i)
		if !skipped {
			return true
		}
		i = skip_json_space(text, end)
		if i >= len(text) || text[i] != ',' {
			return true
		}
		i += 1
	}
}

field_less :: proc(a, b: Field_Entry) -> bool {
	return a.hash < b.hash
}

attribute_make :: proc(text: string, allocator := context.allocator) -> (attribute: Attribute, err: mem.Allocator_Error) {
	counter := Builder{text = text}
	object := walk_object(&counter)
	field_count, item_count, decoded_len := counter.field_count, counter.item_count, counter.decoded_len
	fields_at := ATTRIBUTE_HEADER_SIZE
	items_at := fields_at + field_count * size_of(Field_Entry)
	decoded_at := items_at + item_count * size_of(Item)
	text_at := decoded_at + decoded_len
	size := text_at + len(text)
	if size > int(max(u32)) {
		field_count, item_count, decoded_len = 0, 0, 0
		items_at = fields_at
		decoded_at = fields_at
		text_at = fields_at
		size = text_at + len(text)
	}
	blob := mem.alloc_bytes(size, align_of(Field_Entry), allocator) or_return
	header := (^Attribute_Header)(raw_data(blob))
	header.text_len = u64(len(text))
	header.field_count = u32(field_count)
	header.item_count = u32(item_count)
	header.object = object
	copy(blob[text_at:], text)
	if field_count > 0 {
		filler := Builder {
			text         = string(blob[text_at:]),
			fields       = ([^]Field_Entry)(raw_data(blob[fields_at:]))[:field_count],
			items        = ([^]Item)(raw_data(blob[items_at:]))[:item_count],
			decoded      = blob[decoded_at:][:decoded_len],
			decoded_base = decoded_at,
			text_base    = text_at,
			filling      = true,
		}
		walk_object(&filler)
		slice.stable_sort_by(filler.fields, field_less)
	}
	return Attribute{blob = blob}, nil
}

attribute_destroy :: proc(attribute: ^Attribute, allocator := context.allocator) {
	if attribute.blob != nil {
		mem.free_bytes(attribute.blob, allocator)
	}
	attribute.blob = nil
}

attribute_header :: #force_inline proc "contextless" (blob: []u8) -> ^Attribute_Header {
	return (^Attribute_Header)(raw_data(blob))
}

attribute_text :: proc "contextless" (attribute: Attribute) -> string {
	if len(attribute.blob) < ATTRIBUTE_HEADER_SIZE {
		return ""
	}
	length := int(attribute_header(attribute.blob).text_len)
	return string(attribute.blob[len(attribute.blob) - length:])
}

attribute_is_object :: proc "contextless" (attribute: Attribute) -> bool {
	if len(attribute.blob) < ATTRIBUTE_HEADER_SIZE {
		return false
	}
	return attribute_header(attribute.blob).object
}

attribute_size :: proc "contextless" (attribute: Attribute) -> int {
	return len(attribute.blob)
}

attribute_fields :: #force_inline proc "contextless" (blob: []u8) -> []Field_Entry {
	if len(blob) < ATTRIBUTE_HEADER_SIZE {
		return nil
	}
	count := int(attribute_header(blob).field_count)
	if count == 0 {
		return nil
	}
	return ([^]Field_Entry)(raw_data(blob[ATTRIBUTE_HEADER_SIZE:]))[:count]
}

attribute_items :: #force_inline proc "contextless" (blob: []u8) -> [^]Item {
	header := attribute_header(blob)
	return ([^]Item)(raw_data(blob[ATTRIBUTE_HEADER_SIZE + int(header.field_count) * size_of(Field_Entry):]))
}

attribute_lookup :: proc "contextless" (blob: []u8, ref: Field_Ref) -> (value: Value, found: bool) #no_bounds_check {
	fields := attribute_fields(blob)
	low, high := 0, len(fields)
	for low < high {
		middle := int(uint(low + high) >> 1)
		if fields[middle].hash < ref.hash {
			low = middle + 1
		} else {
			high = middle
		}
	}
	base := raw_data(blob)
	for index := low; index < len(fields) && fields[index].hash == ref.hash; index += 1 {
		entry := &fields[index]
		if int(entry.name_len) != len(ref.name) || string(base[entry.name_off:][:entry.name_len]) != ref.name {
			continue
		}
		switch entry.kind {
		case .Number:
			return Value{kind = .Number, num = entry.num}, true
		case .String:
			return Value{kind = .String, num = entry.num, str = string(base[entry.data_off:][:entry.data_len])}, true
		case .Array:
			items := attribute_items(blob)
			return Value{kind = .Array, items = items[entry.data_off:][:entry.data_len], base = base}, true
		case .Null:
			return Value{kind = .Null}, true
		case .Missing:
			return {}, false
		}
	}
	return {}, false
}
