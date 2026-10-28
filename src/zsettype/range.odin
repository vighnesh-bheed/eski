package zsettype

Range_Spec :: struct {
	min:   f64,
	max:   f64,
	minex: bool,
	maxex: bool,
}

Lex_Bound :: enum u8 {
	Value,
	Min_String,
	Max_String,
}

Lex_Spec :: struct {
	min:      []u8,
	max:      []u8,
	min_kind: Lex_Bound,
	max_kind: Lex_Bound,
	minex:    bool,
	maxex:    bool,
}

parse_range_item :: proc "contextless" (s: []u8) -> (v: f64, ex: bool, ok: bool) {
	text := cstr(s)
	if len(text) > 0 && text[0] == '(' {
		ex = true
		text = text[1:]
	}
	consumed: int
	v, consumed, _ = strtod(text)
	if consumed != len(text) || is_nan(v) {
		return 0, ex, false
	}
	return v, ex, true
}

parse_range :: proc "contextless" (min, max: []u8) -> (r: Range_Spec, ok: bool) {
	a, ae, ag := parse_range_item(min)
	b, be, bg := parse_range_item(max)
	if !ag || !bg {
		return {}, false
	}
	return Range_Spec{a, b, ae, be}, true
}

parse_lex_item :: proc "contextless" (s: []u8) -> (v: []u8, kind: Lex_Bound, ex: bool, ok: bool) {
	if len(s) == 1 && s[0] == '-' {
		return nil, .Min_String, true, true
	}
	if len(s) == 1 && s[0] == '+' {
		return nil, .Max_String, true, true
	}
	if len(s) > 0 && (s[0] == '[' || s[0] == '(') {
		return s[1:], .Value, s[0] == '(', true
	}
	return nil, .Value, false, false
}

parse_lex_range :: proc "contextless" (min, max: []u8) -> (r: Lex_Spec, ok: bool) {
	a, ak, ae, ag := parse_lex_item(min)
	b, bk, be, bg := parse_lex_item(max)
	return Lex_Spec{a, b, ak, bk, ae, be}, ag && bg
}

value_gte_min :: proc "contextless" (v: f64, r: ^Range_Spec) -> bool {
	return v > r.min || v == r.min && !r.minex
}

value_lte_max :: proc "contextless" (v: f64, r: ^Range_Spec) -> bool {
	return v < r.max || v == r.max && !r.maxex
}

lex_cmp :: proc "contextless" (a: []u8, ak: Lex_Bound, b: []u8, bk: Lex_Bound) -> int {
	if ak == bk {
		if ak == .Value {
			return member_cmp(a, b)
		}
		return 0
	}
	if ak == .Min_String || bk == .Max_String {
		return -1
	}
	if ak == .Max_String || bk == .Min_String {
		return 1
	}
	return 0
}

lex_gte_min :: proc "contextless" (v: []u8, r: ^Lex_Spec) -> bool {
	c := lex_cmp(v, .Value, r.min, r.min_kind)
	return c > 0 || c == 0 && !r.minex
}

lex_lte_max :: proc "contextless" (v: []u8, r: ^Lex_Spec) -> bool {
	c := lex_cmp(v, .Value, r.max, r.max_kind)
	return c < 0 || c == 0 && !r.maxex
}

range_empty :: proc "contextless" (r: ^Range_Spec) -> bool {
	return is_nan(r.min) || is_nan(r.max) || r.min > r.max || r.min == r.max && (r.minex || r.maxex)
}

lex_range_empty :: proc "contextless" (r: ^Lex_Spec) -> bool {
	c := lex_cmp(r.min, r.min_kind, r.max, r.max_kind)
	return c > 0 || c == 0 && (r.minex || r.maxex)
}

sl_is_in_range :: proc "contextless" (sl: ^Skiplist, r: ^Range_Spec) -> bool {
	return sl.length > 0 && !range_empty(r) && value_gte_min(sl.tail.score, r) && value_lte_max(sl_first(sl).score, r)
}

sl_nth_in_range :: proc "contextless" (sl: ^Skiplist, r: ^Range_Spec, n: int) -> ^Node {
	if !sl_is_in_range(sl, r) {
		return nil
	}
	x := sl.header
	position: u64
	for level := sl.level - 1; level >= 0; level -= 1 {
		for next := fwd(x, level); next != nil; next = fwd(x, level) {
			skip := n >= 0 ? !value_gte_min(next.score, r) : value_lte_max(next.score, r)
			if !skip {
				break
			}
			position += node_levels(x)[level].span
			x = next
		}
	}
	wanted := i64(position)
	if n >= 0 {
		if n > sl.length {
			return nil
		}
		wanted += i64(n) + 1
	} else {
		if n < -sl.length {
			return nil
		}
		wanted += i64(n) + 1
	}
	if wanted < 1 || wanted > i64(sl.length) {
		return nil
	}
	x = sl_get_by_rank(sl, u64(wanted))
	if !value_gte_min(x.score, r) || !value_lte_max(x.score, r) {
		return nil
	}
	return x
}

sl_is_in_lex_range :: proc "contextless" (sl: ^Skiplist, r: ^Lex_Spec) -> bool {
	return sl.length > 0 && !lex_range_empty(r) && lex_gte_min(node_member(sl.tail), r) && lex_lte_max(node_member(sl_first(sl)), r)
}

sl_nth_in_lex_range :: proc "contextless" (sl: ^Skiplist, r: ^Lex_Spec, n: int) -> ^Node {
	if !sl_is_in_lex_range(sl, r) || n > sl.length || n < -sl.length {
		return nil
	}
	x := sl.header
	position: u64
	for level := sl.level - 1; level >= 0; level -= 1 {
		for next := fwd(x, level); next != nil; next = fwd(x, level) {
			skip := n >= 0 ? !lex_gte_min(node_member(next), r) : lex_lte_max(node_member(next), r)
			if !skip {
				break
			}
			position += node_levels(x)[level].span
			x = next
		}
	}
	wanted := i64(position) + i64(n) + 1
	if wanted < 1 || wanted > i64(sl.length) {
		return nil
	}
	x = sl_get_by_rank(sl, u64(wanted))
	if n >= 0 && !lex_lte_max(node_member(x), r) || n < 0 && !lex_gte_min(node_member(x), r) {
		return nil
	}
	return x
}

sl_delete_range_by_score :: proc "contextless" (sl: ^Skiplist, r: ^Range_Spec) -> int {
	count := 0
	for n := sl_nth_in_range(sl, r, 0); n != nil && value_lte_max(n.score, r); {
		next := sl_next(n)
		sl_remove(sl, n)
		count += 1
		n = next
	}
	return count
}

sl_delete_range_by_lex :: proc "contextless" (sl: ^Skiplist, r: ^Lex_Spec) -> int {
	count := 0
	for n := sl_nth_in_lex_range(sl, r, 0); n != nil && lex_lte_max(node_member(n), r); {
		next := sl_next(n)
		sl_remove(sl, n)
		count += 1
		n = next
	}
	return count
}

sl_delete_range_by_rank :: proc "contextless" (sl: ^Skiplist, start, end: u64) -> int {
	if start < 1 || end < start || start > u64(sl.length) {
		return 0
	}
	last := min(end, u64(sl.length))
	count := 0
	for n := sl_get_by_rank(sl, start); n != nil && u64(count) <= last - start; {
		next := sl_next(n)
		sl_remove(sl, n)
		count += 1
		n = next
	}
	return count
}
