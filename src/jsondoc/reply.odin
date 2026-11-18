package jsondoc

import "core:mem"
import "core:mem/virtual"

Workspace :: struct {
	arena: virtual.Arena,
	allocator: mem.Allocator,
}

workspace_init :: proc(space: ^Workspace) -> bool {
	if virtual.arena_init_static(&space.arena, 1024 * 1024 * 1024) != nil {
		return false
	}
	space.allocator = virtual.arena_allocator(&space.arena)
	return true
}

workspace_reset :: proc(space: ^Workspace) {
	virtual.arena_free_all(&space.arena)
}

workspace_destroy :: proc(space: ^Workspace) {
	virtual.arena_destroy(&space.arena)
	space^ = {}
}

Reply_Kind :: enum {
	Nil, Status, Error, String, Integer, Double, Boolean, Array, Map,
}

Reply :: struct {
	kind: Reply_Kind,
	text: string,
	integer: i64,
	double: f64,
	boolean: bool,
	items: []Reply,
}

reply_error :: proc(text: string) -> Reply {
	return {kind = .Error, text = text}
}

reply_status :: proc(text: string) -> Reply {
	return {kind = .Status, text = text}
}

reply_string :: proc(text: string) -> Reply {
	return {kind = .String, text = text}
}

reply_integer :: proc(n: i64) -> Reply {
	return {kind = .Integer, integer = n}
}

reply_array :: proc(items: []Reply) -> Reply {
	return {kind = .Array, items = items}
}

reply_list :: proc(count: int, allocator: mem.Allocator) -> ([]Reply, string) {
	if count > MAX_ITEMS || count < 0 {
		return nil, SIZE_LIMIT
	}
	items, err := make([]Reply, count, allocator)
	return items, "" if err == nil else OUT_OF_MEMORY
}

reply_wrap :: proc(child: Reply, allocator: mem.Allocator) -> Reply {
	items, err := reply_list(1, allocator)
	if err != "" {
		return reply_error(err)
	}
	items[0] = child
	return reply_array(items)
}

Reply_Mode :: enum {
	Resp, Expand1, Expand,
}

number_reply :: proc(v: ^Value) -> Reply {
	#partial switch n in v.data {
	case i64:
		return reply_integer(n)
	case u64:
		return {kind = .Double, double = f64(n)}
	case f64:
		return {kind = .Double, double = n}
	}
	return {}
}

value_reply :: proc(v: ^Value, mode: Reply_Mode, options: Format, allocator: mem.Allocator) -> Reply {
	if v == nil {
		return {}
	}
	switch data in v.data {
	case Null:
		return {}
	case bool:
		if mode == .Resp {
			return reply_status("true" if data else "false")
		}
		return {kind = .Boolean, boolean = data}
	case i64, u64, f64:
		return number_reply(v)
	case string:
		if mode != .Expand1 {
			return reply_string(data)
		}
	case ^Array:
		if mode != .Expand1 {
			offset := int(mode == .Resp)
			list, err := reply_list(len(data.items) + offset, allocator)
			if err != "" {
				return reply_error(err)
			}
			if offset != 0 {
				list[0] = reply_status("[")
			}
			for child, i in data.items {
				list[i+offset] = value_reply(child, mode, options, allocator)
				if list[i+offset].kind == .Error {
					return list[i+offset]
				}
			}
			return reply_array(list)
		}
	case ^Object:
		if mode != .Expand1 {
			offset := int(mode == .Resp)
			list, err := reply_list(len(data.members) * 2 + offset, allocator)
			if err != "" {
				return reply_error(err)
			}
			if offset != 0 {
				list[0] = reply_status("{")
			}
			for member, i in data.members {
				list[2*i+offset] = reply_string(member.name)
				list[2*i+offset+1] = value_reply(member.value, mode, options, allocator)
				if list[2*i+offset+1].kind == .Error {
					return list[2*i+offset+1]
				}
			}
			return {kind = .Array if offset != 0 else .Map, items = list}
		}
	}
	text, err := serialize(v, options, allocator)
	return reply_string(text) if err == "" else reply_error(err)
}

render_reply :: proc(reply: Reply, protocol: int, allocator := context.allocator) -> (string, string) {
	b: Buffer
	buffer_init(&b, allocator)
	defer delete(b.bytes)
	write_reply(&b, reply, protocol)
	if b.error != "" {
		return "", b.error
	}
	text, ok := copy_text(string(b.bytes[:]), allocator)
	return text, "" if ok else OUT_OF_MEMORY
}

write_reply :: proc(b: ^Buffer, reply: Reply, protocol: int) {
	switch reply.kind {
	case .Nil:
		buffer_add(b, "_\r\n" if protocol == 3 else "$-1\r\n")
	case .Status, .Error:
		buffer_byte(b, '+' if reply.kind == .Status else '-')
		buffer_add(b, reply.text)
		buffer_add(b, "\r\n")
	case .String:
		write_bulk(b, reply.text)
	case .Integer:
		buffer_byte(b, ':')
		buffer_integer(b, reply.integer)
		buffer_add(b, "\r\n")
	case .Double:
		buf: [64]u8
		text := resp_double(buf[:], reply.double)
		if protocol == 3 {
			buffer_byte(b, ',')
			buffer_add(b, text)
			buffer_add(b, "\r\n")
		} else {
			write_bulk(b, text)
		}
	case .Boolean:
		buffer_add(b, "#t\r\n" if reply.boolean else "#f\r\n")
	case .Array, .Map:
		is_map := reply.kind == .Map
		buffer_byte(b, '%' if is_map else '*')
		buffer_integer(b, i64(len(reply.items) / (2 if is_map else 1)))
		buffer_add(b, "\r\n")
		for child in reply.items {
			write_reply(b, child, protocol)
		}
	}
}

write_bulk :: proc(b: ^Buffer, text: string) {
	buffer_byte(b, '$')
	buffer_integer(b, i64(len(text)))
	buffer_add(b, "\r\n")
	buffer_add(b, text)
	buffer_add(b, "\r\n")
}
