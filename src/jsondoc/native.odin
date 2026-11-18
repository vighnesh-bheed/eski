package jsondoc

import "core:math"
import "core:mem"
import "core:strconv"
import "core:unicode/utf8"
import "../rdb"

Native_Kind :: enum u8 {
	Null, False, True, Signed, Unsigned, Double, Text, Array, Object,
}

native_measure :: proc(v: ^Value, nodes: ^int) -> int {
	nodes^ += 1
	size := 1
	#partial switch data in v.data {
	case i64, u64, f64:
		size += 8
	case string:
		size += 8 + len(data)
	case ^Array:
		size += 8
		for child in data.items {
			size += native_measure(child, nodes)
		}
	case ^Object:
		size += 8
		for member in data.members {
			size += 8 + len(member.name) + native_measure(member.value, nodes)
		}
	}
	return size
}

Native_Sink :: struct {
	data: rawptr,
	write: proc (data: rawptr, bytes: []u8),
}

native_write_tag :: proc (sink: Native_Sink, kind: Native_Kind, format := Float_Format.Normal) {
	tag := [1]u8{u8(kind) | (u8(format) << 4)}
	sink.write(sink.data, tag[:])
}

native_write_word :: proc (sink: Native_Sink, word: u64) {
	bytes: [8]u8
	for &byte, i in bytes {
		byte = u8(word >> (8 * uint(i)))
	}
	sink.write(sink.data, bytes[:])
}

native_write_text :: proc (sink: Native_Sink, text: string) {
	native_write_word(sink, u64(len(text)))
	sink.write(sink.data, transmute([]u8)text)
}

native_write :: proc (sink: Native_Sink, v: ^Value) {
	switch data in v.data {
	case Null:
		native_write_tag(sink, .Null)
	case bool:
		native_write_tag(sink, .True if data else .False)
	case i64:
		native_write_tag(sink, .Signed)
		native_write_word(sink, u64(data))
	case u64:
		native_write_tag(sink, .Unsigned)
		native_write_word(sink, data)
	case f64:
		native_write_tag(sink, .Double, v.narrow)
		native_write_word(sink, transmute(u64)data)
	case string:
		native_write_tag(sink, .Text)
		native_write_text(sink, data)
	case ^Array:
		native_write_tag(sink, .Array, v.narrow)
		native_write_word(sink, u64(len(data.items)))
		for child in data.items {
			native_write(sink, child)
		}
	case ^Object:
		native_write_tag(sink, .Object)
		native_write_word(sink, u64(len(data.members)))
		for member in data.members {
			native_write_text(sink, member.name)
			native_write(sink, member.value)
		}
	}
}

Native_Reader :: struct {
	rdb: ^rdb.Reader,
	end: i64,
	allocator: mem.Allocator,
}

native_remaining :: proc(r: ^Native_Reader) -> i64 {
	return r.end - rdb.reader_offset(r.rdb)
}

native_read_text :: proc(r: ^Native_Reader) -> (string, bool) {
	if native_remaining(r) < 8 {
		return "", false
	}
	size, ok := rdb.get_ms(r.rdb)
	if !ok || size < 0 || size > MAX_TEXT_BYTES || size > native_remaining(r) {
		return "", false
	}
	if size == 0 {
		return "", true
	}
	bytes, err := make([]u8, int(size), r.allocator)
	if err != nil {
		return "", false
	}
	if !rdb.take_into(r.rdb, raw_data(bytes), len(bytes)) || !utf8.valid_string(string(bytes)) {
		delete(bytes, r.allocator)
		return "", false
	}
	return string(bytes), true
}

native_read_node :: proc(r: ^Native_Reader, depth: int) -> ^Value {
	if native_remaining(r) < 1 {
		return nil
	}
	tag, read := rdb.get_u8(r.rdb)
	kind := Native_Kind(tag & 15)
	format := Float_Format(tag >> 4)
	if !read || kind > .Object || format > .FP64 || (format != .Normal && kind != .Array && kind != .Double) {
		return nil
	}
	if kind == .Array || kind == .Object {
		return native_read_container(r, kind, format, depth)
	}
	data: Data
	switch kind {
	case .Null:
		data = Null{}
	case .False, .True:
		data = kind == .True
	case .Signed, .Unsigned, .Double:
		if native_remaining(r) < 8 {
			return nil
		}
		bits, ok := rdb.get_ms(r.rdb)
		if !ok {
			return nil
		}
		#partial switch kind {
		case .Signed:
			data = bits
		case .Unsigned:
			if bits >= 0 {
				return nil
			}
			data = u64(bits)
		case .Double:
			number := transmute(f64)bits
			if math.is_inf(number) || math.is_nan(number) || transmute(i64)round_narrow(number, format) != bits {
				return nil
			}
			data = number
		case:
		}
	case .Text:
		value, ok := native_read_text(r)
		if !ok {
			return nil
		}
		data = value
	case .Array, .Object:
	}
	v := new_value(data, r.allocator)
	if v == nil {
		release_data(data, r.allocator)
		return nil
	}
	v.narrow = format
	return v
}

native_read_container :: proc(r: ^Native_Reader, kind: Native_Kind, format: Float_Format, depth: int) -> ^Value {
	if depth >= MAX_DEPTH || native_remaining(r) < 8 {
		return nil
	}
	count, ok := rdb.get_ms(r.rdb)
	minimum := i64(9) if kind == .Object else 1
	if !ok || count < 0 || count > MAX_ITEMS || count > native_remaining(r) / minimum {
		return nil
	}
	v := make_object(r.allocator) if kind == .Object else make_array(r.allocator)
	if v == nil {
		return nil
	}
	v.narrow = format
	success := false
	defer if !success {
		release(v, r.allocator)
	}
	for _ in 0 ..< count {
		name: string
		if kind == .Object {
			name, ok = native_read_text(r)
			if !ok {
				return nil
			}
			if object_index(as_object(v), name) >= 0 {
				free_text(name, r.allocator)
				return nil
			}
		}
		child := native_read_node(r, depth + 1)
		if child == nil {
			free_text(name, r.allocator)
			return nil
		}
		err := object_add(v, name, child, r.allocator) if kind == .Object else array_add(v, child)
		if err != "" {
			free_text(name, r.allocator)
			release(child, r.allocator)
			return nil
		}
	}
	success = true
	return v
}

native_read :: proc(r: ^rdb.Reader, size: u64, allocator: mem.Allocator) -> ^Value {
	remaining := rdb.reader_remaining(r)
	offset := rdb.reader_offset(r)
	if size == 0 || remaining < 0 || size > u64(remaining) || size > u64(max(i64) - offset) {
		return nil
	}
	reader := Native_Reader{r, offset + i64(size), allocator}
	v := native_read_node(&reader, 0)
	if native_remaining(&reader) != 0 {
		release(v, allocator)
		return nil
	}
	return v
}

text_preserves_value :: proc(v: ^Value) -> bool {
	if v.narrow != .Normal {
		return false
	}
	#partial switch data in v.data {
	case f64:
		buffer: [64]u8
		value, ok := strconv.parse_f64(json_double(buffer[:], data))
		return ok && transmute(u64)value == transmute(u64)data
	case ^Array:
		for child in data.items {
			if !text_preserves_value(child) {
				return false
			}
		}
	case ^Object:
		for member in data.members {
			if !text_preserves_value(member.value) {
				return false
			}
		}
	}
	return true
}
