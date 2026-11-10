package vmath

import "core:strconv"
import "core:strings"
import "core:testing"

Named_Vector :: struct {
	name:   string,
	values: []string,
}

resp_line :: proc(s: string) -> (line: string, rest: string, ok: bool) {
	i := strings.index(s, "\r\n")
	if i < 0 {
		return
	}
	return s[:i], s[i + 2:], true
}

resp_parse :: proc(s: string, out: ^[dynamic]string) -> (rest: string, ok: bool) {
	if len(s) == 0 {
		return
	}
	kind := s[0]
	line, after := resp_line(s[1:]) or_return
	switch kind {
	case '*', '~', '%':
		n := strconv.parse_int(line) or_return
		if kind == '%' {
			n *= 2
		}
		rest = after
		for _ in 0 ..< n {
			rest = resp_parse(rest, out) or_return
		}
		return rest, true
	case '$':
		n := strconv.parse_int(line) or_return
		if n < 0 {
			return after, true
		}
		if len(after) < n + 2 {
			return
		}
		append(out, after[:n])
		return after[n + 2:], true
	case '+', ',', ':':
		append(out, line)
		return after, true
	case '_':
		return after, true
	}
	return
}

observed_leaves :: proc(t: ^testing.T, id: int) -> []string {
	for c in OBSERVED_CASES {
		if c.id == id {
			out := make([dynamic]string, context.temp_allocator)
			rest, ok := resp_parse(c.reply, &out)
			testing.expectf(t, ok && len(rest) == 0, "case %d reply does not parse", id)
			return out[:]
		}
	}
	testing.expectf(t, false, "case %d is not in the observed data", id)
	return nil
}

parse_vector :: proc(values: []string, allocator := context.temp_allocator) -> []f32 {
	out := make([]f32, len(values), allocator)
	for s, i in values {
		v, ok := strconv.parse_f64(s)
		assert(ok)
		out[i] = f32(v)
	}
	return out
}

parse_reply_f64 :: proc(t: ^testing.T, text: string) -> f64 {
	v, ok := strconv.parse_f64(text)
	testing.expectf(t, ok, "reply number %q does not parse", text)
	return v
}

same_f64 :: proc(a: f64, b: f64) -> bool {
	return transmute(u64)a == transmute(u64)b
}

f32_ulps :: proc(a: f32, b: f32) -> int {
	x := i64(transmute(i32)a)
	y := i64(transmute(i32)b)
	if x < 0 {
		x = i64(min(i32)) - x
	}
	if y < 0 {
		y = i64(min(i32)) - y
	}
	return int(abs(x - y))
}

build_arena :: proc(t: ^testing.T, a: ^Arena, elem: Elem, vectors: []Named_Vector) {
	dim := len(vectors[0].values)
	testing.expect_value(t, arena_init(a, elem, .Cosine, dim), nil)
	for v in vectors {
		_, err := arena_insert(a, parse_vector(v.values))
		testing.expect_value(t, err, nil)
	}
}

arena_slot_of :: proc(vectors: []Named_Vector, name: string) -> u32 {
	for v, i in vectors {
		if v.name == name {
			return u32(i)
		}
	}
	return NIL_SLOT
}

test_unit_vector :: proc(r: ^Rng, dim: int, allocator := context.temp_allocator) -> []f32 {
	x := make([]f32, dim, allocator)
	for &v in x {
		v = f32(2 * rng_f64(r) - 1)
	}
	normalise(x, x)
	return x
}

test_raw_vector :: proc(r: ^Rng, dim: int, allocator := context.temp_allocator) -> []f32 {
	x := make([]f32, dim, allocator)
	for &v in x {
		v = f32((2 * rng_f64(r) - 1) * 100)
	}
	return x
}
