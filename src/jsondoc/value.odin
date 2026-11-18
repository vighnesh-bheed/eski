package jsondoc

import "core:mem"

MAX_TEXT_BYTES :: 512 * 1024 * 1024
MAX_ITEMS :: 16 * 1024 * 1024
MAX_DEPTH :: 127
MAX_PATH_STEPS :: 1024

OUT_OF_MEMORY :: "ERR out of memory"
SIZE_LIMIT :: "ERR JSON size limit exceeded"
DEPTH_LIMIT :: "ERR recursion limit exceeded"

Null :: struct {}

Array :: struct {
	items: [dynamic]^Value,
}

Member :: struct {
	name: string,
	value: ^Value,
}

Object :: struct {
	members: [dynamic]Member,
	by_name: map[string]int,
}

Data :: union {
	Null,
	bool,
	i64,
	u64,
	f64,
	string,
	^Array,
	^Object,
}

Value :: struct {
	parent: ^Value,
	using metadata: bit_field u64 {
		charge: int | 56,
		narrow: Float_Format | 3,
		detached: bool | 1,
	},
	data: Data,
}

Document :: struct {
	root: ^Value,
	allocator: mem.Allocator,
}

init :: proc(allocator := context.allocator) -> Document {
	return {allocator = allocator}
}

destroy :: proc(doc: ^Document) {
	release(doc.root, doc.allocator)
	doc.root = nil
}

replace_root :: proc(doc: ^Document, v: ^Value) {
	release(doc.root, doc.allocator)
	doc.root = v
}

charge :: proc(v: ^Value) -> int {
	return 0 if v == nil else v.charge
}

content_memory :: proc(v: ^Value) -> int {
	if v == nil {
		return 0
	}
	total := local_charge(v.data)
	#partial switch node in v.data {
	case ^Array:
		for child in node.items {
			total += content_memory(child)
		}
	case ^Object:
		for member in node.members {
			total += member_charge(member.name) + content_memory(member.value)
		}
	case:
	}
	return total
}

local_charge :: proc(data: Data) -> int {
	#partial switch v in data {
	case string:
		return 8 + len(v)
	case u64, f64:
		return 16
	case:
		return 8
	}
}

member_charge :: proc(name: string) -> int {
	return 8 + len(name)
}

adjust_charge :: proc(v: ^Value, delta: int) {
	for node := v; node != nil; node = node.parent {
		node.charge += delta
	}
}

new_value :: proc(data: Data, allocator: mem.Allocator) -> ^Value {
	value, err := new(Value, allocator)
	if err != nil {
		return nil
	}
	value.charge = local_charge(data)
	value.data = data
	return value
}

copy_text :: proc(s: string, allocator: mem.Allocator) -> (string, bool) {
	if len(s) == 0 {
		return "", true
	}
	buf, err := make([]u8, len(s), allocator)
	if err != nil {
		return "", false
	}
	copy(buf, s)
	return string(buf), true
}

free_text :: proc(s: string, allocator: mem.Allocator) {
	if len(s) > 0 {
		delete(s, allocator)
	}
}

make_array :: proc(allocator: mem.Allocator) -> ^Value {
	v := new_value(nil, allocator)
	if v == nil {
		return nil
	}
	a, err := new(Array, allocator)
	if err != nil {
		free(v, allocator)
		return nil
	}
	a.items.allocator = allocator
	v.data = a
	return v
}

make_object :: proc(allocator: mem.Allocator) -> ^Value {
	v := new_value(nil, allocator)
	if v == nil {
		return nil
	}
	o, err := new(Object, allocator)
	if err != nil {
		free(v, allocator)
		return nil
	}
	o.members.allocator = allocator
	v.data = o
	return v
}

release_data :: proc(data: Data, allocator: mem.Allocator) {
	#partial switch v in data {
	case string:
		free_text(v, allocator)
	case ^Array:
		for item in v.items {
			release(item, allocator)
		}
		delete(v.items)
		free(v, allocator)
	case ^Object:
		delete(v.by_name)
		for member in v.members {
			free_text(member.name, allocator)
			release(member.value, allocator)
		}
		delete(v.members)
		free(v, allocator)
	case:
	}
}

release :: proc(v: ^Value, allocator: mem.Allocator) {
	if v != nil {
		release_data(v.data, allocator)
		free(v, allocator)
	}
}

clone :: proc(v: ^Value, allocator: mem.Allocator) -> ^Value {
	if v == nil {
		return nil
	}
	#partial switch data in v.data {
	case string:
		s, ok := copy_text(data, allocator)
		if !ok {
			return nil
		}
		out := new_value(s, allocator)
		if out == nil {
			free_text(s, allocator)
		}
		return out
	case ^Array:
		out := make_array(allocator)
		if out == nil {
			return nil
		}
		out.narrow = v.narrow
		for child in data.items {
			item := clone(child, allocator)
			if item == nil || array_add(out, item) != "" {
				release(item, allocator)
				release(out, allocator)
				return nil
			}
		}
		return out
	case ^Object:
		out := make_object(allocator)
		if out == nil {
			return nil
		}
		for member in data.members {
			item := clone(member.value, allocator)
			name, ok := copy_text(member.name, allocator)
			if item == nil || !ok || object_add(out, name, item, allocator) != "" {
				free_text(name, allocator)
				release(item, allocator)
				release(out, allocator)
				return nil
			}
		}
		return out
	case:
		out := new_value(v.data, allocator)
		if out != nil {
			out.narrow = v.narrow
		}
		return out
	}
}

replace :: proc(v, replacement: ^Value, allocator: mem.Allocator) {
	adjust_charge(v, replacement.charge - v.charge)
	release_data(v.data, allocator)
	v.narrow = replacement.narrow
	v.data = replacement.data
	#partial switch data in v.data {
	case ^Array:
		for child in data.items {
			child.parent = v
		}
	case ^Object:
		for member in data.members {
			member.value.parent = v
		}
	case:
	}
	free(replacement, allocator)
}

array_add :: proc(v, item: ^Value) -> string {
	a := as_array(v)
	if len(a.items) >= MAX_ITEMS {
		return SIZE_LIMIT
	}
	_, err := append(&a.items, item)
	if err != nil {
		return OUT_OF_MEMORY
	}
	item.parent = v
	adjust_charge(v, item.charge)
	return ""
}

array_remove :: proc(v: ^Value, index: int) -> ^Value {
	a := as_array(v)
	child := a.items[index]
	ordered_remove(&a.items, index)
	child.parent = nil
	adjust_charge(v, -child.charge)
	return child
}

object_index :: proc(o: ^Object, name: string) -> int {
	if o.by_name != nil {
		index, found := o.by_name[name]
		return index if found else -1
	}
	for member, index in o.members {
		if member.name == name {
			return index
		}
	}
	return -1
}

object_lookup :: proc(o: ^Object, name: string) -> ^Value {
	index := object_index(o, name)
	if index < 0 {
		return nil
	}
	return o.members[index].value
}

object_add :: proc(v: ^Value, name: string, item: ^Value, allocator: mem.Allocator) -> string {
	o := as_object(v)
	index := object_index(o, name)
	if index >= 0 {
		free_text(name, allocator)
		replace(o.members[index].value, item, allocator)
		return ""
	}
	count := len(o.members)
	if count >= MAX_ITEMS {
		return SIZE_LIMIT
	}
	if reserve(&o.members, counts_capacity(count + 1, cap(o.members))) != nil {
		return OUT_OF_MEMORY
	}
	if o.by_name == nil && count >= 8 {
		lookup, err := make(map[string]int, 16, allocator)
		if err != nil {
			return OUT_OF_MEMORY
		}
		for member, pos in o.members {
			if map_insert(&lookup, member.name, pos) == nil {
				delete(lookup)
				return OUT_OF_MEMORY
			}
		}
		o.by_name = lookup
	}
	if o.by_name != nil && map_insert(&o.by_name, name, count) == nil {
		return OUT_OF_MEMORY
	}
	append(&o.members, Member{name, item})
	item.parent = v
	adjust_charge(v, member_charge(name) + item.charge)
	return ""
}

counts_capacity :: proc(need, capacity: int) -> int {
	if need <= capacity {
		return capacity
	}
	return max(need, min(MAX_ITEMS, max(4, capacity * 2)))
}

object_remove :: proc(v: ^Value, index: int, allocator: mem.Allocator) -> ^Value {
	o := as_object(v)
	member := o.members[index]
	if o.by_name != nil {
		delete_key(&o.by_name, member.name)
		if index < len(o.members) - 1 {
			o.by_name[o.members[len(o.members) - 1].name] = index
		}
	}
	unordered_remove(&o.members, index)
	adjust_charge(v, -member_charge(member.name) - member.value.charge)
	free_text(member.name, allocator)
	member.value.parent = nil
	return member.value
}

type_name :: proc(v: ^Value) -> string {
	#partial switch data in v.data {
	case Null:
		return "null"
	case bool:
		return "boolean"
	case i64, u64:
		return "integer"
	case f64:
		return "number"
	case string:
		return "string"
	case ^Array:
		return "array"
	case ^Object:
		return "object"
	case:
		return ""
	}
}

number :: proc(v: ^Value) -> (f64, bool) {
	if v != nil {
		#partial switch n in v.data {
		case i64:
			return f64(n), true
		case u64:
			return f64(n), true
		case f64:
			return n, true
		case:
		}
	}
	return 0, false
}

is_container :: proc(v: ^Value) -> bool {
	return as_array(v) != nil || as_object(v) != nil
}

depth :: proc(v: ^Value) -> int {
	max_child := 0
	#partial switch a in v.data {
	case ^Array:
		for child in a.items {
			max_child = max(max_child, depth(child))
		}
	case ^Object:
		for member in a.members {
			max_child = max(max_child, depth(member.value))
		}
	case:
		return 0
	}
	return 1 + max_child
}

parent_depth :: proc(v: ^Value) -> int {
	n := 0
	for p := v.parent; p != nil; p = p.parent {
		n += 1
	}
	return n
}

as_array :: proc(v: ^Value) -> ^Array {
	if v == nil {
		return nil
	}
	array, _ := v.data.(^Array)
	return array
}

as_object :: proc(v: ^Value) -> ^Object {
	if v == nil {
		return nil
	}
	object, _ := v.data.(^Object)
	return object
}
