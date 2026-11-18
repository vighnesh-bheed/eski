package jsondoc

import "core:math"
import "core:mem"
import "core:unicode/utf8"

eval_call :: proc(ev: ^Evaluation, node: ^Value, expr: ^Expr) -> Eval_Result {
	n := len(expr.args)
	if n < 1 || n > 2 {
		return {}
	}
	a := evaluate(ev, node, expr.args[0])
	defer delete(a.matches)
	v := one(a)
	name := expr.name
	if n == 1 {
		switch name {
		case "count":
			if a.selector {
				return eval_value(ev, i64(len(a.matches)))
			}
		case "value":
			return {value = v}
		case "length":
			if l, ok := value_length(v, true); ok {
				return eval_value(ev, i64(l))
			}
		case "keys":
			if v != nil {
				if o := as_object(v); o != nil {
					return eval_keys(ev, o)
				}
			}
		case "abs", "floor", "ceiling":
			return eval_round(ev, name, v)
		case "min", "max", "avg", "sum", "stddev":
			return eval_aggregate(ev, name, a)
		case "first", "last":
			if v != nil {
				if array := as_array(v); array != nil && len(array.items) > 0 {
					return {value = array.items[0 if name == "first" else len(array.items) - 1]}
				}
			}
		}
		return {}
	}
	b := evaluate(ev, node, expr.args[1])
	defer delete(b.matches)
	w := one(b)
	if v == nil || w == nil {
		return {}
	}
	switch name {
	case "index":
		a := as_array(v)
		i, ok := w.data.(i64)
		if a != nil && ok {
			p := relative_index(i, len(a.items))
			if p < len(a.items) {
				return {value = a.items[p]}
			}
		}
	case "append":
		if as_array(v) != nil {
			array := clone(v, ev.allocator)
			item := clone(w, ev.allocator)
			if array == nil || item == nil {
				ev.error = OUT_OF_MEMORY
			} else if err := array_add(array, item); err != "" {
				ev.error = err
			} else {
				return {value = array, unpack = true}
			}
		}
	case "concat", "match", "search":
		x, x_ok := v.data.(string)
		y, y_ok := w.data.(string)
		if x_ok && y_ok {
			if name != "concat" {
				return eval_value(ev, regex_match(x, y, name == "match"))
			}
			s, err := concat_text(x, y, ev.allocator)
			if err != "" {
				ev.error = err
				return {}
			}
			return eval_value(ev, s)
		}
	}
	return {}
}

concat_text :: proc(a, b: string, allocator: mem.Allocator) -> (string, string) {
	if len(b) > MAX_TEXT_BYTES - len(a) {
		return "", SIZE_LIMIT
	}
	if len(a) + len(b) == 0 {
		return "", ""
	}
	buf, err := make([]u8, len(a) + len(b), allocator)
	if err != nil {
		return "", OUT_OF_MEMORY
	}
	copy(buf, a)
	copy(buf[len(a):], b)
	return string(buf), ""
}

eval_keys :: proc(ev: ^Evaluation, object: ^Object) -> Eval_Result {
	array := make_array(ev.allocator)
	if array == nil {
		ev.error = OUT_OF_MEMORY
		return {}
	}
	for member in object.members {
		s, ok := copy_text(member.name, ev.allocator)
		if !ok {
			ev.error = OUT_OF_MEMORY
			return {}
		}
		item := new_value(s, ev.allocator)
		if item == nil {
			ev.error = OUT_OF_MEMORY
			return {}
		}
		if err := array_add(array, item); err != "" {
			ev.error = err
			return {}
		}
	}
	return {value = array, unpack = true}
}

eval_round :: proc(ev: ^Evaluation, name: string, v: ^Value) -> Eval_Result {
	n, ok := number(v)
	if !ok {
		return {}
	}
	if i, is_int := v.data.(i64); is_int && (name != "abs" || i != min(i64)) {
		return eval_value(ev, abs(i) if name == "abs" else i)
	}
	switch name {
	case "abs": return eval_value(ev, abs(n))
	case "floor": n = math.floor(n)
	case "ceiling": n = math.ceil(n)
	}
	if f64(min(i64)) <= n && n < 9223372036854775808.0 {
		return eval_value(ev, i64(n))
	}
	return {}
}

eval_aggregate :: proc(ev: ^Evaluation, name: string, res: Eval_Result) -> Eval_Result {
	matches: []Match
	values: []^Value
	if v := one(res); v != nil && as_array(v) != nil {
		values = as_array(v).items[:]
	} else {
		matches = res.matches[:]
	}
	count := len(values) + len(matches)
	if count == 0 {
		return {}
	}
	lo, hi, total, mean, m2 := max(f64), -max(f64), 0.0, 0.0, 0.0
	for i in 0 ..< count {
		num, ok := number(values[i] if len(values) != 0 else matches[i].value)
		if !ok {
			return {}
		}
		lo, hi = min(lo, num), max(hi, num)
		total += num
		delta := num - mean
		mean += delta / f64(i + 1)
		m2 += delta * (num - mean)
	}
	n: f64
	switch name {
	case "min": n = lo
	case "max": n = hi
	case "avg": n = total / f64(count)
	case "sum": n = total
	case "stddev": n = math.sqrt(m2 / f64(count))
	}
	if math.is_inf(n) || math.is_nan(n) {
		return {}
	}
	return eval_value(ev, n)
}

Regex_Atom :: struct {
	text: string,
	literal: rune,
	repeat: u8,
	any, class, inverted: bool,
}

regex_match :: proc(input, pattern: string, whole: bool) -> bool {
	if len(pattern) > 1024 {
		return false
	}
	source := pattern
	ignore_case := len(source) >= 4 && source[:4] == "(?i)"
	if ignore_case {
		source = source[4:]
	}
	at_start := whole
	at_end := whole
	if len(source) > 0 && source[0] == '^' {
		at_start = true
		source = source[1:]
	}
	atoms: [128]Regex_Atom
	count := 0
	for len(source) > 0 {
		if source == "$" {
			at_end = true
			break
		}
		if count == len(atoms) {
			return false
		}
		a := Regex_Atom{}
		c, width := utf8.decode_rune_in_string(source)
		source = source[width:]
		switch c {
		case '.': a.any = true
		case '[':
			a.class = true
			a.inverted = len(source) > 0 && source[0] == '^'
			if a.inverted {
				source = source[1:]
			}
			end := 0
			for end < len(source) && source[end] != ']' {
				end += 1
			}
			if end == 0 || end == len(source) {
				return false
			}
			a.text = source[:end]
			source = source[end+1:]
		case '\\':
			if len(source) == 0 {
				return false
			}
			a.literal, width = utf8.decode_rune_in_string(source)
			source = source[width:]
		case '(', ')', '|', '*', '+', '?', '{', '}', '^', '$':
			return false
		case:
			a.literal = c
		}
		if len(source) > 0 && (source[0] == '*' || source[0] == '+' || source[0] == '?') {
			a.repeat = source[0]
			source = source[1:]
		}
		atoms[count] = a
		count += 1
	}
	matched: [129]bool
	matched[0] = true
	regex_empty(atoms[:count], matched[:count+1])
	if matched[count] && !at_end {
		return true
	}
	for c in input {
		next: [129]bool
		next[0] = !at_start
		for a, i in atoms[:count] {
			if matched[i] && regex_accept(a, c, ignore_case) {
				next[i+1] = true
				if a.repeat == '*' || a.repeat == '+' {
					next[i] = true if a.repeat == '*' else next[i]
				}
			}
			if a.repeat == '+' && matched[i+1] && regex_accept(a, c, ignore_case) {
				next[i+1] = true
			}
		}
		regex_empty(atoms[:count], next[:count+1])
		if next[count] && !at_end {
			return true
		}
		matched = next
	}
	return matched[count]
}

regex_empty :: proc(atoms: []Regex_Atom, matched: []bool) {
	for atom, i in atoms {
		if matched[i] && (atom.repeat == '*' || atom.repeat == '?') {
			matched[i+1] = true
		}
	}
}

regex_fold :: proc(c: rune, fold: bool) -> rune {
	return c + ('a' - 'A') if fold && 'A' <= c && c <= 'Z' else c
}

regex_accept :: proc(a: Regex_Atom, c: rune, case_fold: bool) -> bool {
	if a.any {
		return c != '\n'
	}
	ch := regex_fold(c, case_fold)
	if !a.class {
		return ch == regex_fold(a.literal, case_fold)
	}
	s := a.text
	for len(s) > 0 {
		lower, width := utf8.decode_rune_in_string(s)
		s = s[width:]
		upper := lower
		if len(s) > 1 && s[0] == '-' {
			upper, width = utf8.decode_rune_in_string(s[1:])
			s = s[1+width:]
		}
		if regex_fold(lower, case_fold) <= ch && ch <= regex_fold(upper, case_fold) {
			return !a.inverted
		}
	}
	return a.inverted
}
