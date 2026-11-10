package vfilter

import "core:c/libc"
import "core:strings"

Value_Kind :: enum u8 {
	Number,
	String,
	Array,
	Null,
}

Item :: struct {
	num:  f64,
	off:  u32,
	len:  u32,
	kind: Value_Kind,
}

Value :: struct {
	kind:  Value_Kind,
	num:   f64,
	str:   string,
	items: []Item,
	base:  [^]u8,
}

number_value :: #force_inline proc "contextless" (num: f64) -> Value {
	return Value{kind = .Number, num = num}
}

bool_value :: #force_inline proc "contextless" (truth: bool) -> Value {
	return Value{kind = .Number, num = 1 if truth else 0}
}

value_truthy :: #force_inline proc "contextless" (value: Value) -> bool {
	switch value.kind {
	case .Number:
		return value.num != 0
	case .String:
		return len(value.str) > 0
	case .Array:
		return true
	case .Null:
		return false
	}
	return false
}

item_text :: #force_inline proc "contextless" (item: Item, base: [^]u8) -> string {
	return string(base[item.off:][:item.len])
}

value_equal :: #force_inline proc "contextless" (a, b: Value) -> bool {
	if a.kind == .Null || b.kind == .Null {
		return a.kind == b.kind
	}
	if a.kind == .String && b.kind == .String {
		return a.str == b.str
	}
	return a.num == b.num
}

value_item_equal :: #force_inline proc "contextless" (value: Value, item: Item, base: [^]u8) -> bool {
	if value.kind == .Null || item.kind == .Null {
		return value.kind == item.kind
	}
	if value.kind == .String && item.kind == .String {
		return value.str == item_text(item, base)
	}
	return value.num == item.num
}

value_contains :: proc(needle, haystack: Value) -> bool {
	#partial switch haystack.kind {
	case .Array:
		for item in haystack.items {
			if value_item_equal(needle, item, haystack.base) {
				return true
			}
		}
	case .String:
		return needle.kind == .String && strings.contains(haystack.str, needle.str)
	}
	return false
}

apply_binary :: proc(op: Op, a, b: Value) -> Value {
	#partial switch op {
	case .Add:
		return number_value(a.num + b.num)
	case .Sub:
		return number_value(a.num - b.num)
	case .Mul:
		return number_value(a.num * b.num)
	case .Div:
		return number_value(a.num / b.num)
	case .Mod:
		return number_value(libc.fmod(a.num, b.num))
	case .Pow:
		return number_value(libc.pow(a.num, b.num))
	case .Eq:
		return bool_value(value_equal(a, b))
	case .Ne:
		return bool_value(!value_equal(a, b))
	case .Gt:
		return bool_value(a.num > b.num)
	case .Ge:
		return bool_value(a.num >= b.num)
	case .Lt:
		return bool_value(a.num < b.num)
	case .Le:
		return bool_value(a.num <= b.num)
	case .In:
		return bool_value(value_contains(a, b))
	case .And:
		return bool_value(value_truthy(a) && value_truthy(b))
	case .Or:
		return bool_value(value_truthy(a) || value_truthy(b))
	}
	return bool_value(false)
}
