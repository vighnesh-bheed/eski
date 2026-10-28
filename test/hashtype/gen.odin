package hashtype_harness

import "core:fmt"
import "core:os"
import "core:strings"

Rng :: struct {
	s: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.s += 0x9e3779b97f4a7c15
	z := r.s
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

rng_below :: proc(r: ^Rng, n: int) -> int {
	if n <= 0 {
		return 0
	}
	return int(rng_next(r) % u64(n))
}

rng_chance :: proc(r: ^Rng, percent: int) -> bool {
	return rng_below(r, 100) < percent
}

Gen :: struct {
	buf: [dynamic]u8,
	n:   int,
	rng: Rng,
}

g_cmd :: proc(g: ^Gen, args: ..string) {
	parts := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		parts[i] = transmute([]u8)a
	}
	cmd_append(&g.buf, parts)
	g.n += 1
}

g_cmds :: proc(g: ^Gen, args: []string) {
	g_cmd(g, ..args)
}

g_state :: proc(g: ^Gen, key: string) {
	g_cmd(g, "DUMP", key)
	g_cmd(g, "OBJECT", "ENCODING", key)
}

g_write :: proc(g: ^Gen, key: string, args: ..string) {
	g_cmd(g, ..args)
	g_state(g, key)
}

g_reads :: proc(g: ^Gen, key: string) {
	g_cmd(g, "HLEN", key)
	g_cmd(g, "HGETALL", key)
	g_cmd(g, "HKEYS", key)
	g_cmd(g, "HVALS", key)
	g_cmd(g, "HSCAN", key, "0")
}

rep :: proc(c: u8, n: int) -> string {
	b := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		b[i] = c
	}
	return string(b)
}

tp :: proc(args: ..any) -> string {
	return fmt.tprint(..args, sep = "")
}

INT_EDGES := [?]string{"0", "1", "127", "128", "-1", "-4096", "4095", "4096", "-4097", "32767", "-32768", "32768", "-32769", "8388607", "-8388608", "8388608", "2147483647", "-2147483648", "2147483648", "9223372036854775807", "-9223372036854775808"}
NONCANON := [?]string{"007", "+1", "-0", "1.0", "9223372036854775808", "-9223372036854775809", "00", "-", " 11", "11 ", "0x10", "1e3", "12345678901234567890", "abc", ""}

gen_value :: proc(g: ^Gen) -> string {
	r := &g.rng
	switch rng_below(r, 14) {
	case 0:
		return INT_EDGES[rng_below(r, len(INT_EDGES))]
	case 1:
		return NONCANON[rng_below(r, len(NONCANON))]
	case 2:
		return tp(rng_below(r, 300) - 150)
	case 3:
		return tp(i64(rng_next(r) >> uint(rng_below(r, 64))) * (1 if rng_chance(r, 50) else -1))
	case 4:
		lens := [?]int{62, 63, 64, 65, 66}
		return rep(u8('a' + rng_below(r, 26)), lens[rng_below(r, 5)])
	case 5:
		n := rng_below(r, 12)
		b := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			b[i] = u8(rng_next(r))
		}
		return string(b)
	case 6:
		return ""
	case 7:
		return tp(rng_below(r, 1000) - 500, ".", rng_below(r, 1000))
	case:
		n := 1 + rng_below(r, 20)
		alphabet := "abcdefghijklmnopqrstuvwxyz0123456789:_-"
		b := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			b[i] = alphabet[rng_below(r, len(alphabet))]
		}
		return string(b)
	}
}

gen_field :: proc(g: ^Gen) -> string {
	r := &g.rng
	switch rng_below(r, 20) {
	case 0:
		return tp(rng_below(r, 30) - 5)
	case 1:
		return NONCANON[rng_below(r, len(NONCANON))]
	case 2:
		lens := [?]int{63, 64, 65}
		return rep('F', lens[rng_below(r, 3)])
	case 3:
		return INT_EDGES[rng_below(r, len(INT_EDGES))]
	case:
		return tp("f", rng_below(r, 40))
	}
}

FLOAT_FIXED := [?]string{"0", "-0", "1", "-1", "1.23", "0.77", "-0.1", "inf", "-inf", "Infinity", "+inf", "nan", "NaN", "", "+", "-", ".", " 1", "1 ", "1e", "1e5000", "-1e5000", "1e-5000", "3.6e-4951", "1.18973149535723176502e+4932", "0x1p-3", "0X1P3", "0x", "0x.8", "1.", "+.5", ".5e1", "00012", "123456789012345678901234567890", "9223372036854775807", "-9223372036854775808", "1e20", "5e-18", "0.000005", "0.0000005", "3.0e3", "17179869184", "1.5", "2.5", "1e300", "1.7976931348623157e308", "1e70", "-1e70", "1e-17", "0.000000000000000015", "abc", "1,5", "0x1p16383", "0x1p16384"}

gen_float :: proc(g: ^Gen) -> string {
	r := &g.rng
	k := rng_below(r, 100)
	switch {
	case k < 20:
		return FLOAT_FIXED[rng_below(r, len(FLOAT_FIXED))]
	case k < 40:
		return tp(i64(rng_next(r) >> uint(rng_below(r, 64))) * (1 if rng_chance(r, 50) else -1))
	case k < 70:
		sb := strings.builder_make(context.temp_allocator)
		if rng_chance(r, 40) {
			strings.write_byte(&sb, '-')
		}
		for _ in 0 ..< 1 + rng_below(r, 12) {
			strings.write_byte(&sb, u8('0' + rng_below(r, 10)))
		}
		if rng_chance(r, 80) {
			strings.write_byte(&sb, '.')
			for _ in 0 ..< rng_below(r, 18) {
				strings.write_byte(&sb, u8('0' + rng_below(r, 10)))
			}
		}
		if rng_chance(r, 30) {
			fmt.sbprintf(&sb, "e%d", rng_below(r, 80) - 40)
		}
		return strings.to_string(sb)
	case k < 80:
		return tp("0x", rng_next(r) % 0xffffff, "p", rng_below(r, 160) - 80)
	case:
		return tp(rng_below(r, 100000), ".", rng_below(r, 1000))
	}
}

section_basic :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "PING")
	g_write(g, "h", "HSET", "h", "a", "1", "b", "hello", "c", "-5", "d", "")
	g_reads(g, "h")
	for f in ([?]string{"a", "b", "c", "d", "missing", "", "A"}) {
		g_cmd(g, "HGET", "h", f)
		g_cmd(g, "HEXISTS", "h", f)
		g_cmd(g, "HSTRLEN", "h", f)
	}
	g_cmd(g, "HMGET", "h", "a", "missing", "b", "c", "d")
	g_cmd(g, "HMGET", "nokey", "a", "b")
	g_write(g, "h", "HSET", "h", "a", "2", "e", "5", "a", "3")
	g_write(g, "h", "HMSET", "h", "f", "6", "g", "7")
	g_write(g, "h", "HSETNX", "h", "a", "999")
	g_write(g, "h", "HSETNX", "h", "z", "26")
	g_write(g, "hnx", "HSETNX", "hnx", "only", "field")
	g_write(g, "h", "HDEL", "h", "missing")
	g_write(g, "h", "HDEL", "h", "a", "b", "missing", "b")
	g_reads(g, "h")
	g_write(g, "h2", "HMSET", "h2", "a", "1", "b", "2", "c", "3")
	g_write(g, "h2", "HDEL", "h2", "x", "y")
	g_write(g, "h2", "HDEL", "h2", "a", "c", "f")
	g_cmd(g, "HGETALL", "h2")
	g_write(g, "h3", "HMSET", "h3", "a", "1", "b", "2", "c", "3")
	g_write(g, "h3", "HDEL", "h3", "a", "b", "c", "d", "e")
	g_cmd(g, "EXISTS", "h3")
	g_cmd(g, "TYPE", "h3")
	g_cmd(g, "HGETALL", "h3")
	g_cmd(g, "HKEYS", "h3")
	g_cmd(g, "HVALS", "h3")
	g_cmd(g, "HLEN", "h3")
	g_cmd(g, "HGET", "h3", "a")
	g_cmd(g, "HSCAN", "h3", "0")
	g_cmd(g, "HRANDFIELD", "h3")
	g_cmd(g, "HRANDFIELD", "h3", "5")
	g_cmd(g, "HRANDFIELD", "h3", "-5", "WITHVALUES")
	g_cmd(g, "OBJECT", "ENCODING", "h3")
	g_cmd(g, "DUMP", "h3")
	g_cmd(g, "SET", "wrongtype", "somevalue")
	wt := [?][]string {
		{"HMGET", "wrongtype", "field1", "field2"},
		{"HRANDFIELD", "wrongtype"},
		{"HRANDFIELD", "wrongtype", "3"},
		{"HRANDFIELD", "wrongtype", "3", "WITHVALUES"},
		{"HGET", "wrongtype", "field1"},
		{"HGETALL", "wrongtype"},
		{"HDEL", "wrongtype", "field1"},
		{"HINCRBY", "wrongtype", "field1", "2"},
		{"HINCRBYFLOAT", "wrongtype", "field1", "2.5"},
		{"HSTRLEN", "wrongtype", "field1"},
		{"HVALS", "wrongtype"},
		{"HKEYS", "wrongtype"},
		{"HEXISTS", "wrongtype", "field1"},
		{"HSET", "wrongtype", "field1", "val1"},
		{"HMSET", "wrongtype", "field1", "val1", "field2", "val2"},
		{"HSETNX", "wrongtype", "field1", "val1"},
		{"HLEN", "wrongtype"},
		{"HSCAN", "wrongtype", "0"},
		{"HSCAN", "wrongtype", "0", "COUNT", "0"},
		{"HSCAN", "wrongtype", "abc"},
		{"HINCRBY", "wrongtype", "field1", "x"},
		{"HINCRBYFLOAT", "wrongtype", "field1", "inf"},
		{"HRANDFIELD", "wrongtype", "x"},
	}
	for c in wt {
		g_cmds(g, c)
	}
	g_cmd(g, "TYPE", "wrongtype")
	ar := [?][]string {
		{"HSET", "h"},
		{"HSET", "h", "f"},
		{"HSET", "h", "f", "v", "g"},
		{"HMSET", "h", "f", "v", "g"},
		{"HMSET", "h", "f"},
		{"HSETNX", "h", "f"},
		{"HSETNX", "h", "f", "v", "x"},
		{"HGET", "h"},
		{"HGET", "h", "a", "b"},
		{"HMGET", "h"},
		{"HGETALL", "h", "x"},
		{"HKEYS"},
		{"HVALS", "h", "x"},
		{"HLEN", "h", "x"},
		{"HEXISTS", "h"},
		{"HSTRLEN", "h", "a", "b"},
		{"HDEL", "h"},
		{"HINCRBY", "h", "a"},
		{"HINCRBYFLOAT", "h", "a", "1", "2"},
		{"HRANDFIELD"},
		{"HSCAN", "h"},
	}
	for c in ar {
		g_cmds(g, c)
	}
	g_state(g, "h")
}

section_conversions :: proc(g: ^Gen, entries: int, value: int) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "CONFIG", "SET", "hash-max-listpack-entries", tp(entries))
	g_cmd(g, "CONFIG", "SET", "hash-max-listpack-value", tp(value))
	for i in 0 ..< entries + 1 {
		g_write(g, "grow", "HSET", "grow", tp("field:", i), tp(i * 3))
	}
	g_reads(g, "grow")
	for i in 0 ..< entries + 1 {
		g_write(g, "grow", "HDEL", "grow", tp("field:", i))
		if i % 7 == 0 {
			g_cmd(g, "HLEN", "grow")
		}
	}
	g_cmd(g, "EXISTS", "grow")
	pairs := make([dynamic]string, context.temp_allocator)
	append(&pairs, "HSET", "multi_eq")
	for i in 0 ..< entries {
		append(&pairs, tp("m", i), tp(i))
	}
	g_write(g, "multi_eq", ..pairs[:])
	g_reads(g, "multi_eq")
	clear(&pairs)
	append(&pairs, "HSET", "multi_over")
	for i in 0 ..< entries + 1 {
		append(&pairs, tp("m", i), tp(i))
	}
	g_write(g, "multi_over", ..pairs[:])
	g_reads(g, "multi_over")
	clear(&pairs)
	append(&pairs, "HSET", "multi_dup")
	for i in 0 ..< entries + 1 {
		append(&pairs, "same", tp(i))
	}
	g_write(g, "multi_dup", ..pairs[:])
	g_cmd(g, "HLEN", "multi_dup")
	g_write(g, "val_eq", "HSET", "val_eq", "f", rep('v', value))
	g_write(g, "val_over", "HSET", "val_over", "f", rep('v', value + 1))
	g_write(g, "field_eq", "HSET", "field_eq", rep('k', value), "v")
	g_write(g, "field_over", "HSET", "field_over", rep('k', value + 1), "v")
	g_write(g, "upd", "HSET", "upd", "a", "1", "b", "2")
	g_write(g, "upd", "HSET", "upd", "a", rep('u', value + 1))
	g_write(g, "upd", "HDEL", "upd", "a")
	g_reads(g, "upd")
	g_write(g, "nx", "HSET", "nx", "a", "1")
	g_write(g, "nx", "HSETNX", "nx", "b", rep('n', value + 1))
	g_write(g, "nx2", "HSET", "nx2", "a", "1")
	g_write(g, "nx2", "HSETNX", "nx2", rep('n', value + 1), "x")
	g_write(g, "nx3", "HSET", "nx3", "a", "1")
	g_write(g, "nx3", "HSETNX", "nx3", "a", rep('n', value + 1))
	g_write(g, "ib", "HSET", "ib", "a", "1")
	g_write(g, "ib", "HINCRBY", "ib", rep('i', value + 1), "5")
	g_write(g, "ib2", "HINCRBY", "ib2", rep('i', value), "5")
	g_write(g, "ibf", "HSET", "ibf", "a", "1")
	g_write(g, "ibf", "HINCRBYFLOAT", "ibf", "a", "1e70")
	g_write(g, "ibf2", "HINCRBYFLOAT", "ibf2", "a", "0.0000005")
	g_write(g, "ibf3", "HINCRBYFLOAT", "ibf3", rep('i', value + 1), "1")
	g_write(g, "lenmix", "HSET", "lenmix", "a", "1", "b", rep('x', value + 1), "c", "3")
	g_reads(g, "lenmix")
	g_write(g, "intlen", "HSET", "intlen", "f", "12345678901234567890")
	g_write(g, "intlen2", "HSET", "intlen2", "f", "-9223372036854775808")
	g_write(g, "emptyfv", "HSET", "emptyfv", "", "")
}

section_hincrby :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_write(g, "c", "HINCRBY", "c", "n", "2")
	g_write(g, "c", "HINCRBY", "c", "n", "-5")
	g_write(g, "c", "HINCRBY", "c", "m", "0")
	g_write(g, "c", "HSET", "c", "s", " 11", "t", "11 ", "u", "abc", "big", "17179869184", "neg", "-9223372036854775484", "max", "9223372036854775807", "min", "-9223372036854775808", "nc", "007", "f", "1.5", "e", "")
	for f in ([?]string{"s", "t", "u", "nc", "f", "e"}) {
		g_write(g, "c", "HINCRBY", "c", f, "1")
	}
	g_write(g, "c", "HINCRBY", "c", "big", "1")
	g_write(g, "c", "HINCRBY", "c", "big", "17179869184")
	g_write(g, "c", "HINCRBY", "c", "neg", "-1")
	g_write(g, "c", "HINCRBY", "c", "neg", "-10000")
	g_write(g, "c", "HINCRBY", "c", "max", "1")
	g_write(g, "c", "HINCRBY", "c", "max", "0")
	g_write(g, "c", "HINCRBY", "c", "max", "-1")
	g_write(g, "c", "HINCRBY", "c", "min", "-1")
	g_write(g, "c", "HINCRBY", "c", "min", "1")
	g_write(g, "c", "HINCRBY", "c", "min", "9223372036854775807")
	g_write(g, "c", "HINCRBY", "c", "n", "9223372036854775807")
	g_write(g, "c", "HINCRBY", "c", "n", "9223372036854775807")
	for inc in ([?]string{"", "abc", "1.5", "9223372036854775808", "-9223372036854775809", " 1", "1 ", "+1", "-0", "0x10", "007", "-9223372036854775808"}) {
		g_write(g, "c", "HINCRBY", "c", "m", inc)
	}
	g_cmd(g, "HINCRBY", "fresh", "f", "x")
	g_cmd(g, "EXISTS", "fresh")
	for _ in 0 ..< 300 {
		f := tp("k", rng_below(&g.rng, 8))
		inc := tp(i64(rng_next(&g.rng) >> uint(rng_below(&g.rng, 64))) * (1 if rng_chance(&g.rng, 50) else -1))
		if rng_chance(&g.rng, 30) {
			inc = INT_EDGES[rng_below(&g.rng, len(INT_EDGES))]
		}
		g_write(g, "r", "HINCRBY", "r", f, inc)
	}
	g_reads(g, "r")
}

section_hincrbyfloat :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_write(g, "x", "HINCRBYFLOAT", "x", "float", "1.23")
	g_write(g, "x", "HINCRBYFLOAT", "x", "float", "0.77")
	g_write(g, "x", "HINCRBYFLOAT", "x", "float", "-0.1")
	g_write(g, "x", "HSET", "x", "s", " 11", "t", "11 ", "u", "abc", "big", "17179869184", "inf", "inf", "ninf", "-inf", "nan", "nan", "hex", "0x10", "e", "", "int", "100", "zero", "-0", "nul", "1\x002", "ld", "1.18973149535723176502e+4932")
	for f in ([?]string{"s", "t", "u", "inf", "ninf", "nan", "hex", "e", "int", "zero", "nul", "big", "ld"}) {
		g_write(g, "x", "HINCRBYFLOAT", "x", f, "1")
	}
	g_write(g, "x", "HINCRBYFLOAT", "x", "big", "17179869184")
	g_write(g, "x", "HINCRBYFLOAT", "x", "ld", "1e4932")
	g_write(g, "x", "HINCRBYFLOAT", "x", "zero", "-0")
	for inc in FLOAT_FIXED {
		g_write(g, "y", "HINCRBYFLOAT", "y", "acc", inc)
		g_write(g, "z", "HINCRBYFLOAT", "z", inc, inc)
	}
	g_cmd(g, "HINCRBYFLOAT", "hfoo", "field", "+inf")
	g_cmd(g, "EXISTS", "hfoo")
	g_write(g, "big", "HINCRBYFLOAT", "big", "f", "1e4000")
	g_write(g, "big", "HINCRBYFLOAT", "big", "f", "-1e4000")
	g_write(g, "big", "HINCRBYFLOAT", "big", "g", "1.18973149535723176502e+4932")
	g_write(g, "big", "HINCRBYFLOAT", "big", "g", "1e4932")
	g_write(g, "tiny", "HINCRBYFLOAT", "tiny", "f", "3.6e-4951")
	g_write(g, "tiny", "HINCRBYFLOAT", "tiny", "f", "-3.6e-4951")
	for i in 0 ..< 1500 {
		key := tp("fl", rng_below(&g.rng, 3))
		f := tp("v", rng_below(&g.rng, 6))
		g_write(g, key, "HINCRBYFLOAT", key, f, gen_float(g))
		if i % 50 == 0 {
			g_write(g, key, "HSET", key, f, gen_float(g))
		}
	}
	g_reads(g, "fl0")
}

section_hstrlen :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	vals := [?]string{"-9223372036854775808", "9223372036854775807", "9223372036854775808", "", "0", "-1", "x", "007", "1.5", "-4096", "4095", "127", "128", "-0", rep('s', 100)}
	for v in vals {
		g_write(g, "sl", "HMSET", "sl", "field", v)
		g_cmd(g, "HSTRLEN", "sl", "field")
		g_cmd(g, "HGET", "sl", "field")
	}
	for v in vals {
		g_write(g, "slb", "HMSET", "slb", "field", v, rep('b', 70), "x")
		g_cmd(g, "HSTRLEN", "slb", "field")
		g_cmd(g, "HGET", "slb", "field")
	}
	g_cmd(g, "HSTRLEN", "sl", "nofield")
	g_cmd(g, "HSTRLEN", "nokey", "field")
}

hrandfield_shapes :: proc(g: ^Gen, key: string) {
	g_cmd(g, "HRANDFIELD", key)
	for c in ([?]string{"0", "1", "-1", "2", "5", "8", "9", "10", "11", "20", "-5", "-20", "-1001", "1000", "4611686018427387903"}) {
		g_cmd(g, "HRANDFIELD", key, c)
		g_cmd(g, "HRANDFIELD", key, c, "WITHVALUES")
	}
	g_cmd(g, "HRANDFIELD", key, "3", "withvalues")
	g_cmd(g, "HRANDFIELD", key, "-3", "WithValues")
	errs := [?][]string {
		{"HRANDFIELD", key, "abc"},
		{"HRANDFIELD", key, "1.5"},
		{"HRANDFIELD", key, ""},
		{"HRANDFIELD", key, "-9223372036854775808"},
		{"HRANDFIELD", key, "-9223372036854775808", "WITHVALUES"},
		{"HRANDFIELD", key, "-9223372036854770000", "WITHVALUES"},
		{"HRANDFIELD", key, "9223372036854775807", "WITHVALUES"},
		{"HRANDFIELD", key, "-4611686018427387904", "WITHVALUES"},
		{"HRANDFIELD", key, "4611686018427387904", "WITHVALUES"},
		{"HRANDFIELD", key, "9223372036854775808"},
		{"HRANDFIELD", key, "5", "WITHVALUE"},
		{"HRANDFIELD", key, "5", "WITHVALUES", "x"},
		{"HRANDFIELD", key, "5", "x", "WITHVALUES"},
		{"HRANDFIELD", key, "x", "WITHVALUES"},
	}
	for e in errs {
		g_cmds(g, e)
	}
	for _ in 0 ..< 40 {
		c := rng_below(&g.rng, 30) - 15
		if rng_chance(&g.rng, 50) {
			g_cmd(g, "HRANDFIELD", key, tp(c), "WITHVALUES")
		} else {
			g_cmd(g, "HRANDFIELD", key, tp(c))
		}
	}
}

section_hrandfield :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_write(g, "lp", "HSET", "lp", "a", "1", "b", "2", "c", "3", "d", "4", "e", "5", "6", "f", "7", "g", "8", "h", "9", "i", "10", "j")
	g_write(g, "hti", "HSET", "hti", "a", "1", "b", "2", "c", "3", "d", "4", "e", "5", "6", "f", "7", "g", "8", "h", "9", "i", rep('r', 80), "10")
	g_write(g, "one", "HSET", "one", "only", "1")
	pairs := make([dynamic]string, context.temp_allocator)
	append(&pairs, "HSET", "bigh")
	for i in 0 ..< 300 {
		append(&pairs, tp("bf", i), tp("bv", i * i))
	}
	g_write(g, "bigh", ..pairs[:])
	for k in ([?]string{"lp", "hti", "one", "bigh", "nokey"}) {
		hrandfield_shapes(g, k)
	}
	g_cmd(g, "CONFIG", "SET", "hash-max-listpack-entries", "4")
	g_write(g, "small", "HSET", "small", "a", "1", "b", "2", "c", "3")
	hrandfield_shapes(g, "small")
	g_write(g, "small", "HSET", "small", "d", "4", "e", "5")
	hrandfield_shapes(g, "small")
	g_cmd(g, "CONFIG", "SET", "hash-max-listpack-entries", "128")
}

hscan_shapes :: proc(g: ^Gen, key: string) {
	g_cmd(g, "HSCAN", key, "0")
	for c in ([?]string{"1", "3", "10", "1000"}) {
		g_cmd(g, "HSCAN", key, "0", "COUNT", c)
		g_cmd(g, "HSCAN", key, "0", "COUNT", c, "NOVALUES")
	}
	for p in ([?]string{"*", "f1*", "*[0-9]", "nomatch", "f?", "*1*", "[a-c]*", "\\*", "f[^1]*", "*f*f*", "", "**", "f[", "[]", "f\\1*"}) {
		g_cmd(g, "HSCAN", key, "0", "MATCH", p)
		g_cmd(g, "HSCAN", key, "0", "MATCH", p, "NOVALUES", "COUNT", "2")
	}
	g_cmd(g, "HSCAN", key, "0", "novalues")
	g_cmd(g, "HSCAN", key, "0", "MATCH", "*", "MATCH", "f1*")
	errs := [?][]string {
		{"HSCAN", key, "abc"},
		{"HSCAN", key, "-1"},
		{"HSCAN", key, "18446744073709551616"},
		{"HSCAN", key, ""},
		{"HSCAN", key, "0", "COUNT", "0"},
		{"HSCAN", key, "0", "COUNT", "-1"},
		{"HSCAN", key, "0", "COUNT", "abc"},
		{"HSCAN", key, "0", "COUNT"},
		{"HSCAN", key, "0", "MATCH"},
		{"HSCAN", key, "0", "FOO"},
		{"HSCAN", key, "0", "TYPE", "hash"},
		{"HSCAN", key, "0", "NOVALUES", "x"},
	}
	for e in errs {
		g_cmds(g, e)
	}
}

section_hscan :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_write(g, "slp", "HSET", "slp", "f1", "1", "f2", "two", "f10", "10", "g1", "x", "11", "eleven", "", "empty", "*", "star", "f\\1", "bs")
	hscan_shapes(g, "slp")
	g_cmd(g, "HSCAN", "slp", "5")
	g_cmd(g, "HSCAN", "slp", " 7")
	g_cmd(g, "HSCAN", "slp", "+7")
	g_cmd(g, "HSCAN", "slp", "-0")
	g_cmd(g, "HSCAN", "slp", "007")
	g_cmd(g, "HSCAN", "slp", "18446744073709551615")
	g_cmd(g, "HSCAN", "slp", "-18446744073709551615")
	pairs := make([dynamic]string, context.temp_allocator)
	append(&pairs, "HSET", "sht")
	for i in 0 ..< 200 {
		append(&pairs, tp("f", i), tp(i))
	}
	append(&pairs, "", "empty", "*", "star")
	g_write(g, "sht", ..pairs[:])
	hscan_shapes(g, "sht")
	for _ in 0 ..< 60 {
		g_write(g, "sht", "HDEL", "sht", tp("f", rng_below(&g.rng, 200)), tp("f", rng_below(&g.rng, 200)), tp("f", rng_below(&g.rng, 200)))
	}
	hscan_shapes(g, "sht")
	g_cmd(g, "HSCAN", "nokey", "0")
	g_cmd(g, "HSCAN", "nokey", "0", "COUNT", "0")
	g_cmd(g, "HSCAN", "nokey", "abc")
	g_cmd(g, "HSCAN", "nokey", "12345", "FOO")
}

section_resp3 :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_write(g, "r3", "HSET", "r3", "a", "1", "b", "bee", "c", "-3")
	pairs := make([dynamic]string, context.temp_allocator)
	append(&pairs, "HSET", "r3h")
	for i in 0 ..< 150 {
		append(&pairs, tp("x", i), tp(i))
	}
	g_write(g, "r3h", ..pairs[:])
	g_cmd(g, "HELLO", "3")
	for k in ([?]string{"r3", "r3h", "nokey"}) {
		g_cmd(g, "HGETALL", k)
		g_cmd(g, "HKEYS", k)
		g_cmd(g, "HVALS", k)
		g_cmd(g, "HGET", k, "a")
		g_cmd(g, "HGET", k, "x1")
		g_cmd(g, "HMGET", k, "a", "zz", "x2")
		g_cmd(g, "HRANDFIELD", k)
		for c in ([?]string{"0", "1", "2", "3", "-3", "200", "-200", "5"}) {
			g_cmd(g, "HRANDFIELD", k, c)
			g_cmd(g, "HRANDFIELD", k, c, "WITHVALUES")
		}
		g_cmd(g, "HSCAN", k, "0")
		g_cmd(g, "HSCAN", k, "0", "NOVALUES")
		g_cmd(g, "HLEN", k)
		g_cmd(g, "HEXISTS", k, "a")
		g_cmd(g, "HSTRLEN", k, "c")
		g_cmd(g, "OBJECT", "ENCODING", k)
	}
	g_write(g, "r3", "HINCRBYFLOAT", "r3", "a", "1.5")
	g_write(g, "r3", "HINCRBY", "r3", "c", "10")
	g_write(g, "r3", "HDEL", "r3", "b")
	g_cmd(g, "HINCRBY", "r3", "b", "x")
	g_cmd(g, "HELLO", "2")
}

section_fuzz :: proc(g: ^Gen, ops: int) {
	g_cmd(g, "FLUSHALL")
	keys := [?]string{"z0", "z1", "z2", "z3"}
	entries_opts := [?]int{0, 1, 2, 4, 8, 16, 128, 128, 128, 128}
	value_opts := [?]int{0, 1, 4, 8, 16, 64, 64, 64, 64}
	r := &g.rng
	for i in 0 ..< ops {
		if i % 300 == 0 {
			g_cmd(g, "DEL", keys[rng_below(r, len(keys))], keys[rng_below(r, len(keys))])
			g_cmd(g, "CONFIG", "SET", "hash-max-listpack-entries", tp(entries_opts[rng_below(r, len(entries_opts))]))
			g_cmd(g, "CONFIG", "SET", "hash-max-listpack-value", tp(value_opts[rng_below(r, len(value_opts))]))
		}
		k := keys[rng_below(r, len(keys))]
		switch rng_below(r, 22) {
		case 0, 1, 2, 3:
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "HSET" if rng_chance(r, 80) else "HMSET", k)
			for _ in 0 ..< 1 + rng_below(r, 5) {
				append(&args, gen_field(g), gen_value(g))
			}
			g_write(g, k, ..args[:])
		case 4:
			g_write(g, k, "HSETNX", k, gen_field(g), gen_value(g))
		case 5, 6:
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "HDEL", k)
			for _ in 0 ..< 1 + rng_below(r, 4) {
				append(&args, gen_field(g))
			}
			g_write(g, k, ..args[:])
		case 7:
			inc := tp(rng_below(r, 2000) - 1000)
			if rng_chance(r, 10) {
				inc = gen_value(g)
			}
			g_write(g, k, "HINCRBY", k, gen_field(g), inc)
		case 8:
			g_write(g, k, "HINCRBYFLOAT", k, gen_field(g), gen_float(g))
		case 9:
			g_cmd(g, "HGET", k, gen_field(g))
		case 10:
			g_cmd(g, "HMGET", k, gen_field(g), gen_field(g), gen_field(g))
		case 11:
			g_cmd(g, "HEXISTS", k, gen_field(g))
		case 12:
			g_cmd(g, "HSTRLEN", k, gen_field(g))
		case 13:
			g_cmd(g, "HLEN", k)
		case 14:
			g_cmd(g, "HGETALL", k)
		case 15:
			g_cmd(g, "HKEYS", k)
		case 16:
			g_cmd(g, "HVALS", k)
		case 17:
			c := rng_below(r, 50) - 25
			if rng_chance(r, 50) {
				g_cmd(g, "HRANDFIELD", k, tp(c), "WITHVALUES")
			} else if rng_chance(r, 50) {
				g_cmd(g, "HRANDFIELD", k, tp(c))
			} else {
				g_cmd(g, "HRANDFIELD", k)
			}
		case 18:
			pats := [?]string{"*", "f1*", "*[0-9]*", "f?", "x*"}
			pat := pats[rng_below(r, len(pats))]
			if rng_chance(r, 50) {
				g_cmd(g, "HSCAN", k, "0", "MATCH", pat, "COUNT", tp(1 + rng_below(r, 20)))
			} else {
				g_cmd(g, "HSCAN", k, "0", "NOVALUES", "COUNT", tp(1 + rng_below(r, 20)))
			}
		case 19:
			g_cmd(g, "DEL", k)
		case 20:
			g_cmd(g, "EXISTS", k)
		case 21:
			g_state(g, k)
		}
	}
	g_cmd(g, "CONFIG", "SET", "hash-max-listpack-entries", "128")
	g_cmd(g, "CONFIG", "SET", "hash-max-listpack-value", "64")
	for k in keys {
		g_state(g, k)
		g_reads(g, k)
	}
}


T0 :: i64(4102444800000)
T0S :: i64(4102444800)

g_sleep :: proc(g: ^Gen, ms: int) {
	g_cmd(g, "__SLEEP__", tp(ms))
}

g_ttls :: proc(g: ^Gen, key: string, fields: ..string) {
	n := tp(len(fields))
	for c in ([?]string{"HTTL", "HPTTL", "HEXPIRETIME", "HPEXPIRETIME"}) {
		args := make([dynamic]string, context.temp_allocator)
		append(&args, c, key, "FIELDS", n)
		append(&args, ..fields)
		g_cmds(g, args[:])
	}
}

hfe_mode :: proc(g: ^Gen, table_mode: bool) {
	g_cmd(g, "CONFIG", "SET", "hash-max-listpack-entries", "0" if table_mode else "128")
	g_cmd(g, "CONFIG", "SET", "hash-max-listpack-value", "64")
}

section_hfe_commands :: proc(g: ^Gen, table_mode: bool) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "DEBUG", "SET-ACTIVE-EXPIRE", "0")
	hfe_mode(g, table_mode)
	g_cmd(g, "HEXPIRE", "nokey", "1000", "FIELDS", "1", "a")
	g_cmd(g, "HEXPIREAT", "nokey", "1000", "FIELDS", "1", "a")
	g_cmd(g, "HPEXPIRE", "nokey", "1000", "FIELDS", "2", "a", "b")
	g_cmd(g, "HPEXPIREAT", "nokey", "1000", "NX", "FIELDS", "2", "a", "b")
	g_ttls(g, "nokey", "a", "b")
	g_cmd(g, "HPERSIST", "nokey", "FIELDS", "2", "a", "b")
	g_cmd(g, "EXISTS", "nokey")
	g_write(g, "e", "HSET", "e", "f1", "v1", "f2", "v2")
	errs := [?][]string {
		{"HEXPIRE", "e", "-1", "FIELDS", "1", "f1"},
		{"HEXPIRE", "e", "-9223372036854775808", "FIELDS", "1", "f1"},
		{"HEXPIRE", "e", "281474976710", "FIELDS", "1", "f1"},
		{"HEXPIRE", "e", "70368744178", "FIELDS", "1", "f1"},
		{"HEXPIREAT", "e", "283000000000", "FIELDS", "1", "f1"},
		{"HEXPIREAT", "e", "70368744178", "FIELDS", "1", "f1"},
		{"HPEXPIRE", "e", "281474976710656", "FIELDS", "1", "f1"},
		{"HPEXPIRE", "e", "70368744177663", "FIELDS", "1", "f1"},
		{"HPEXPIREAT", "e", "300000000000000", "FIELDS", "1", "f1"},
		{"HPEXPIREAT", "e", "70368744177664", "FIELDS", "1", "f1"},
		{"HPEXPIREAT", "e", "9223372036854775807", "FIELDS", "1", "f1"},
		{"HEXPIRE", "e", "abc", "FIELDS", "1", "f1"},
		{"HEXPIRE", "e", "1.5", "FIELDS", "1", "f1"},
		{"HEXPIRE", "e", "", "FIELDS", "1", "f1"},
		{"HPEXPIRE", "e", "1000", "NX", "FIELDS", "0", "f1", "f2", "f3"},
		{"HPEXPIRE", "e", "1000", "NX", "FIELDS", "4", "f1", "f2", "f3"},
		{"HPEXPIRE", "e", "1000", "NX", "FIELDS", "2", "f1", "f2", "f3"},
		{"HPEXPIRE", "e", "1000", "FIELDS", "abc", "f1"},
		{"HPEXPIRE", "e", "1000", "FIELDS", "-1", "f1"},
		{"HPEXPIRE", "e", "1000", "FIELD", "1", "f1"},
		{"HPEXPIRE", "e", "1000", "NX", "NX", "FIELDS", "1", "f1"},
		{"HPEXPIRE", "e", "1000", "FIELDS", "NX", "1", "f1"},
		{"HPEXPIRE", "e", "1000", "XX", "1", "f1"},
		{"HPEXPIRE", "e", "1000", "FIELDS", "1"},
		{"HPEXPIRE", "e", "1000", "FIELDS"},
		{"HEXPIRE", "e"},
		{"HTTL", "e", "FIELDS", "1"},
		{"HTTL", "e", "FIELD", "1", "f1"},
		{"HTTL", "e", "FIELDS", "0", "f1"},
		{"HTTL", "e", "FIELDS", "x", "f1"},
		{"HPTTL", "e", "FIELDS", "2", "f1"},
		{"HPTTL", "e", "FIELDS", "1", "f1", "f2"},
		{"HEXPIRETIME", "e", "FIELDS", "3", "f1", "f2"},
		{"HPEXPIRETIME", "e", "fields", "1", "f1"},
		{"HPERSIST", "e"},
		{"HPERSIST", "e", "FIELDS", "1"},
		{"HPERSIST", "e", "FIELDS", "2", "f1", "f2", "f3"},
		{"HPERSIST", "e", "FIELDS", "0", "f1"},
		{"HPERSIST", "e", "FIELDS", "abc", "f1"},
		{"HPERSIST", "e", "XFIELDS", "1", "f1"},
	}
	for c in errs {
		g_cmds(g, c)
	}
	g_state(g, "e")
	g_write(g, "e", "HPEXPIREAT", "e", "70368744177663", "FIELDS", "1", "f1")
	g_write(g, "e", "HEXPIREAT", "e", "70368744177", "FIELDS", "1", "f2")
	g_write(g, "e", "HPEXPIRE", "e", "60000000000000", "FIELDS", "1", "f1")
	g_ttls(g, "e", "f1", "f2", "nope")
	g_cmd(g, "SET", "s", "x")
	wt := [?][]string {
		{"HEXPIRE", "s", "10", "FIELDS", "1", "a"},
		{"HEXPIRE", "s", "-1", "FIELDS", "1", "a"},
		{"HPEXPIREAT", "s", "1", "FIELDS", "9", "a"},
		{"HTTL", "s", "FIELDS", "1", "a"},
		{"HTTL", "s", "FIELD", "1", "a"},
		{"HPTTL", "s", "FIELDS", "1", "a"},
		{"HEXPIRETIME", "s", "FIELDS", "1", "a"},
		{"HPEXPIRETIME", "s", "FIELDS", "1", "a"},
		{"HPERSIST", "s", "FIELDS", "1", "a"},
	}
	for c in wt {
		g_cmds(g, c)
	}
	g_write(g, "c", "HSET", "c", "field1", "value1", "field2", "value2", "field3", "value3")
	g_write(g, "c", "HPEXPIREAT", "c", tp(T0 + 1000), "NX", "FIELDS", "1", "field1")
	g_write(g, "c", "HPEXPIREAT", "c", tp(T0 + 1000), "NX", "FIELDS", "2", "field1", "field2")
	g_write(g, "c", "HPEXPIREAT", "c", tp(T0 + 5000), "XX", "FIELDS", "2", "field1", "field3")
	g_write(g, "c", "HPEXPIREAT", "c", tp(T0 + 1500), "GT", "FIELDS", "3", "field1", "field2", "field3")
	g_write(g, "c", "HPEXPIREAT", "c", tp(T0 + 1200), "LT", "FIELDS", "3", "field1", "field2", "field3")
	g_write(g, "c", "HPEXPIREAT", "c", tp(T0 + 1200), "lt", "fields", "2", "field1", "nofield")
	g_write(g, "c", "HPEXPIREAT", "c", tp(T0 + 1200), "gt", "FIELDS", "1", "field1")
	g_write(g, "c", "HPEXPIREAT", "c", tp(T0 + 7000), "FIELDS", "2", "field2", "field2")
	g_write(g, "c", "HEXPIREAT", "c", tp(T0S + 9), "XX", "FIELDS", "1", "field3")
	g_reads(g, "c")
	g_ttls(g, "c", "field1", "field2", "field3", "nofield")
	g_write(g, "c", "HPERSIST", "c", "FIELDS", "3", "field1", "nofield", "field2")
	g_write(g, "c", "HPERSIST", "c", "FIELDS", "2", "field1", "field2")
	g_ttls(g, "c", "field1", "field2", "field3")
	g_write(g, "c", "HPEXPIRE", "c", "0", "FIELDS", "1", "field3")
	g_write(g, "c", "HEXPIRE", "c", "0", "NX", "FIELDS", "1", "field2")
	g_write(g, "c", "HEXPIRE", "c", "0", "XX", "FIELDS", "1", "field1")
	g_write(g, "d", "HSET", "d", "f1", "v1", "f2", "v2", "f4", "v4")
	g_write(g, "d", "HEXPIREAT", "d", tp(T0S + 1000), "NX", "FIELDS", "1", "f4")
	g_write(g, "d", "HPEXPIREAT", "d", "1000", "NX", "FIELDS", "4", "f1", "f2", "f3", "f4")
	g_cmd(g, "HEXISTS", "d", "f1")
	g_write(g, "d", "HEXPIREAT", "d", "1", "FIELDS", "1", "f4")
	g_cmd(g, "EXISTS", "d")
	g_write(g, "z", "HSET", "z", "a", "1", "b", "2")
	g_write(g, "z", "HEXPIRE", "z", "0", "FIELDS", "3", "a", "zz", "b")
	g_cmd(g, "EXISTS", "z")
	g_write(g, "th", "HSET", "th", "a", "1", "b", "2", "c", "3", "d", "4")
	g_write(g, "th", "HPEXPIREAT", "th", tp(T0 + 100000), "FIELDS", "1", "a")
	g_write(g, "th", "HPEXPIREAT", "th", tp(T0 + 99000), "FIELDS", "1", "b")
	g_write(g, "th", "HPEXPIREAT", "th", tp(T0 + 90000), "FIELDS", "1", "c")
	g_write(g, "th", "HPERSIST", "th", "FIELDS", "1", "c")
	g_write(g, "th", "HDEL", "th", "b")
	g_write(g, "th", "HDEL", "th", "a")
	g_write(g, "th", "HPEXPIREAT", "th", tp(T0 + 50000), "FIELDS", "1", "d")
	g_write(g, "th", "HPEXPIREAT", "th", tp(T0 + 52000), "GT", "FIELDS", "1", "d")
	g_write(g, "th", "HPEXPIREAT", "th", tp(T0 + 60000), "GT", "FIELDS", "1", "d")
	g_write(g, "th", "HPEXPIREAT", "th", tp(T0 + 59000), "FIELDS", "1", "c")
	g_write(g, "th", "HPEXPIREAT", "th", tp(T0 + 40000), "LT", "FIELDS", "2", "c", "d")
	g_write(g, "th", "HSET", "th", "d", "newvalue")
	g_write(g, "th", "HSET", "th", "e", "5")
	g_ttls(g, "th", "a", "b", "c", "d", "e")
	g_write(g, "k2", "HSET", "k2", "n", "10", "m", "1.5", "p", "x")
	g_write(g, "k2", "HPEXPIREAT", "k2", tp(T0 + 3000), "FIELDS", "2", "n", "m")
	g_write(g, "k2", "HINCRBY", "k2", "n", "5")
	g_write(g, "k2", "HINCRBYFLOAT", "k2", "m", "1.25")
	g_ttls(g, "k2", "n", "m", "p")
	g_write(g, "k2", "HSET", "k2", "n", "1")
	g_write(g, "k2", "HSETNX", "k2", "q", "9")
	g_write(g, "k2", "HSETNX", "k2", "m", "9")
	g_write(g, "k2", "HMSET", "k2", "r", "7", "s", "8")
	g_ttls(g, "k2", "n", "m", "q", "r")
	g_reads(g, "k2")
	g_cmd(g, "HSTRLEN", "k2", "m")
	g_cmd(g, "HMGET", "k2", "n", "m", "zz")
	hrandfield_shapes(g, "k2")
	hscan_shapes(g, "k2")
	g_write(g, "cv", "HSET", "cv", "a", "1")
	g_write(g, "cv", "HEXPIRE", "cv", "100", "FIELDS", "1", "nofield")
	g_write(g, "cv", "HPEXPIREAT", "cv", tp(T0), "XX", "FIELDS", "1", "a")
	g_cmd(g, "OBJECT", "ENCODING", "cv")
	if !table_mode {
		g_cmd(g, "CONFIG", "SET", "hash-max-listpack-entries", "4")
		g_write(g, "cw", "HSET", "cw", "a", "1", "b", "2")
		g_write(g, "cw", "HPEXPIREAT", "cw", tp(T0 + 1000), "FIELDS", "1", "a")
		g_write(g, "cw", "HPEXPIREAT", "cw", tp(T0 + 500), "FIELDS", "1", "b")
		g_write(g, "cw", "HSET", "cw", "c", "3", "d", "4", "e", "5")
		g_ttls(g, "cw", "a", "b", "c")
		g_write(g, "cw", "HPERSIST", "cw", "FIELDS", "1", "a")
		g_write(g, "cw", "HPERSIST", "cw", "FIELDS", "1", "b")
		g_write(g, "cw", "HPEXPIREAT", "cw", tp(T0 + 2000), "NX", "FIELDS", "3", "a", "c", "zz")
		g_cmd(g, "CONFIG", "SET", "hash-max-listpack-entries", "128")
		g_write(g, "cx", "HSET", "cx", "a", "1", "b", "2")
		g_write(g, "cx", "HPEXPIREAT", "cx", tp(T0 + 1000), "FIELDS", "1", "b")
		g_write(g, "cx", "HSET", "cx", "c", rep('L', 70))
		g_ttls(g, "cx", "a", "b", "c")
		g_write(g, "cy", "HSET", "cy", "a", "1")
		g_write(g, "cy", "HPEXPIREAT", "cy", tp(T0 + 1000), "FIELDS", "1", "a")
		pairs := make([dynamic]string, context.temp_allocator)
		append(&pairs, "HSET", "cy")
		for i in 0 ..< 130 {
			append(&pairs, tp("m", i), tp(i))
		}
		g_write(g, "cy", ..pairs[:])
		g_ttls(g, "cy", "a", "m1")
		g_cmd(g, "CONFIG", "SET", "hash-max-listpack-value", "2048")
		big1 := rep('w', 1500)
		big2 := rep('u', 700)
		g_write(g, "lv", "HSET", "lv", "f1", big2, "f2", "v2", "f3", big1, "f4", "v4")
		g_write(g, "lv", "HPEXPIREAT", "lv", tp(T0 + 100000), "FIELDS", "1", "f3")
		g_write(g, "lv", "HPERSIST", "lv", "FIELDS", "1", "f3")
		g_write(g, "lv", "HPEXPIREAT", "lv", tp(T0 + 10), "FIELDS", "2", "f1", "f3")
		g_write(g, "lv", "HPEXPIREAT", "lv", tp(T0 + 5), "FIELDS", "1", "f4")
		g_cmd(g, "CONFIG", "SET", "hash-max-listpack-value", "64")
	}
	g_cmd(g, "HELLO", "3")
	g_ttls(g, "c", "field1", "field2", "nofield")
	g_write(g, "c", "HPEXPIREAT", "c", tp(T0 + 4000), "FIELDS", "2", "field1", "zz")
	g_cmd(g, "HPERSIST", "c", "FIELDS", "1", "field1")
	g_cmd(g, "HGETALL", "c")
	g_cmd(g, "HELLO", "2")
}

lazy_key :: proc(g: ^Gen, key: string, set_args: []string, expire_fields: []string) {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "HSET", key)
	append(&args, ..set_args)
	g_cmds(g, args[:])
	clear(&args)
	append(&args, "HPEXPIRE", key, "1200", "FIELDS", tp(len(expire_fields)))
	append(&args, ..expire_fields)
	g_cmds(g, args[:])
}

section_hfe_lazy :: proc(g: ^Gen, table_mode: bool) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "DEBUG", "SET-ACTIVE-EXPIRE", "0")
	hfe_mode(g, table_mode)
	lazy_key(g, "l1", {"f1", "v1", "f2", "v2", "f3", "v3"}, {"f1", "f2", "f3"})
	lazy_key(g, "l2", {"01", "01", "02", "02", "03", "03", "04", "04"}, {"01", "03", "04"})
	lazy_key(g, "l3", {"f1", "v1", "f2", "v2", "f3", "v3", "f4", "v4", "f5", "v5"}, {"f1", "f2"})
	lazy_key(g, "l4", {"f1", "10", "f2", "2"}, {"f1"})
	lazy_key(g, "l5", {"f1", "10"}, {"f1"})
	lazy_key(g, "l6", {"a", "1"}, {"a"})
	lazy_key(g, "l7", {"a", "1", "b", "2"}, {"a"})
	lazy_key(g, "l8", {"f1", "v1", "f2", "v2", "f3", "v3"}, {"f2", "f3"})
	g_cmd(g, "HPEXPIREAT", "l8", tp(T0), "FIELDS", "1", "f1")
	lazy_key(g, "l9", {"f1", "v1", "f2", "v2", "f3", "v3"}, {"f1", "f2", "f3"})
	lazy_key(g, "l10", {"a", "1", "b", "2"}, {"a"})
	lazy_key(g, "l11", {"a", "1", "b", "2"}, {"a"})
	lazy_key(g, "l12", {"a", "1", "b", "2"}, {"a"})
	lazy_key(g, "l12b", {"a", "1", "b", "2"}, {"a"})
	lazy_key(g, "l13", {"f1", "v1", "f2", "v2", "f3", "v3", "f4", "v4", "f5", "v5", "f6", "v6"}, {"f2", "f4", "f6"})
	lazy_key(g, "l14", {"a", "1", "b", "2"}, {"a", "b"})
	lazy_key(g, "l15", {"f1", "10", "f2", "2"}, {"f1"})
	lazy_key(g, "l16", {"a", "1", "b", "2", "c", "3"}, {"a"})
	g_cmd(g, "HPEXPIREAT", "l16", tp(T0), "FIELDS", "1", "b")
	lazy_key(g, "l17", {"a", "1", "b", "2"}, {"a", "b"})
	lazy_key(g, "l18", {"a", "1", "b", "2", "c", "3"}, {"a"})
	lazy_key(g, "l19", {"a", "1", "b", "2", "c", "3"}, {"a", "b", "c"})
	lazy_key(g, "l20", {"a", "1", "b", "2", "c", "3"}, {"a", "b"})
	g_cmd(g, "HEXISTS", "l1", "f1")
	g_cmd(g, "HLEN", "l1")
	g_ttls(g, "l1", "f1", "f2", "nofield")
	g_cmd(g, "OBJECT", "ENCODING", "l1")
	g_sleep(g, 2500)
	g_cmd(g, "EXISTS", "l1")
	g_cmd(g, "HLEN", "l1")
	g_cmd(g, "HEXISTS", "l1", "f1")
	g_cmd(g, "HLEN", "l1")
	g_cmd(g, "HGET", "l1", "f2")
	g_cmd(g, "HLEN", "l1")
	g_cmd(g, "HSTRLEN", "l1", "f3")
	g_cmd(g, "HLEN", "l1")
	g_cmd(g, "EXISTS", "l1")
	g_cmd(g, "HSCAN", "l2", "0", "COUNT", "10")
	g_cmd(g, "HSCAN", "l2", "0", "NOVALUES")
	g_cmd(g, "HLEN", "l2")
	g_reads(g, "l2")
	g_state(g, "l2")
	g_cmd(g, "HRANDFIELD", "l3", "5")
	g_cmd(g, "HLEN", "l3")
	g_state(g, "l3")
	g_cmd(g, "HINCRBY", "l4", "f1", "1")
	g_cmd(g, "HGET", "l4", "f1")
	g_ttls(g, "l4", "f1", "f2")
	g_state(g, "l4")
	g_cmd(g, "HINCRBY", "l5", "f1", "1")
	g_state(g, "l5")
	g_cmd(g, "HSETNX", "l6", "a", "9")
	g_state(g, "l6")
	g_cmd(g, "HGETALL", "l6")
	g_cmd(g, "HSETNX", "l7", "a", "9")
	g_state(g, "l7")
	g_cmd(g, "HMGET", "l8", "f1", "f2", "f3")
	g_cmd(g, "HLEN", "l8")
	g_cmd(g, "HMGET", "l9", "f1", "f2", "f3")
	g_cmd(g, "EXISTS", "l9")
	g_cmd(g, "HSET", "l10", "a", "5")
	g_ttls(g, "l10", "a")
	g_cmd(g, "HGET", "l10", "a")
	g_state(g, "l10")
	g_cmd(g, "HDEL", "l11", "a")
	g_cmd(g, "HLEN", "l11")
	g_state(g, "l11")
	g_cmd(g, "HPEXPIREAT", "l12", tp(T0), "GT", "FIELDS", "1", "a")
	g_cmd(g, "HGET", "l12", "a")
	g_ttls(g, "l12", "a", "b")
	g_state(g, "l12")
	g_cmd(g, "HPEXPIREAT", "l12b", tp(T0), "NX", "FIELDS", "2", "a", "b")
	g_cmd(g, "HPEXPIREAT", "l12b", "1000", "LT", "FIELDS", "1", "a")
	g_state(g, "l12b")
	g_reads(g, "l13")
	g_cmd(g, "HLEN", "l13")
	g_cmd(g, "HRANDFIELD", "l13", "-10", "WITHVALUES")
	g_cmd(g, "HLEN", "l13")
	g_state(g, "l13")
	g_ttls(g, "l14", "a", "b")
	g_cmd(g, "HPERSIST", "l14", "FIELDS", "2", "a", "b")
	g_cmd(g, "HLEN", "l14")
	g_cmd(g, "EXISTS", "l14")
	g_state(g, "l14")
	g_cmd(g, "HINCRBYFLOAT", "l15", "f1", "1.5")
	g_state(g, "l15")
	g_state(g, "l16")
	g_cmd(g, "HGET", "l16", "c")
	g_cmd(g, "HGET", "l16", "a")
	g_state(g, "l16")
	g_cmd(g, "HRANDFIELD", "l17", "-5")
	g_cmd(g, "EXISTS", "l17")
	g_cmd(g, "HRANDFIELD", "l18")
	g_cmd(g, "HLEN", "l18")
	g_cmd(g, "HRANDFIELD", "l19")
	g_cmd(g, "EXISTS", "l19")
	g_cmd(g, "HRANDFIELD", "l20", "0")
	g_cmd(g, "HLEN", "l20")
	g_cmd(g, "DEBUG", "SET-ACTIVE-EXPIRE", "1")
}

section_hfe_active :: proc(g: ^Gen, table_mode: bool) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "DEBUG", "SET-ACTIVE-EXPIRE", "0")
	hfe_mode(g, table_mode)
	sizes := [?]int{1, 15, 16, 17, 40}
	for h in sizes {
		for i in 1 ..= h {
			g_cmd(g, "HSET", tp("hrand", h), tp("f", i), tp("v", i))
			g_cmd(g, "HPEXPIRE", tp("hrand", h), tp(1000 + (i * 7) % 300), "FIELDS", "1", tp("f", i))
			g_cmd(g, "HSET", tp("same", h), tp("f", i), tp("v", i))
			g_cmd(g, "HPEXPIRE", tp("same", h), "1000", "FIELDS", "1", tp("f", i))
			g_cmd(g, "HSET", tp("mix", h), tp("f", i), tp("v", i), tp("keep", i), tp("v", i))
			g_cmd(g, "HPEXPIRE", tp("mix", h), "1000", "FIELDS", "1", tp("f", i))
		}
	}
	g_cmd(g, "HSET", "thr", "a", "1", "b", "2", "c", "3")
	g_cmd(g, "HPEXPIRE", "thr", "4000", "FIELDS", "1", "a")
	g_cmd(g, "HPEXPIRE", "thr", "2000", "FIELDS", "1", "b")
	g_cmd(g, "DEBUG", "SET-ACTIVE-EXPIRE", "1")
	g_sleep(g, 3000)
	g_cmd(g, "HLEN", "thr")
	for h in sizes {
		g_cmd(g, "EXISTS", tp("hrand", h))
		g_cmd(g, "EXISTS", tp("same", h))
		g_cmd(g, "HLEN", tp("mix", h))
	}
	g_sleep(g, 3000)
	g_cmd(g, "HLEN", "thr")
	g_cmd(g, "HGETALL", "thr")
	g_state(g, "thr")
	for h in sizes {
		g_cmd(g, "HLEN", tp("mix", h))
		g_cmd(g, "HEXISTS", tp("mix", h), "f1")
		g_cmd(g, "HTTL", tp("mix", h), "FIELDS", "2", "f1", "keep1")
		g_state(g, tp("mix", h))
	}
	g_cmd(g, "DEBUG", "SET-ACTIVE-EXPIRE", "0")
}

section_hfe_fuzz :: proc(g: ^Gen, ops: int) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "DEBUG", "SET-ACTIVE-EXPIRE", "0")
	keys := [?]string{"x0", "x1", "x2", "x3"}
	entries_opts := [?]int{0, 2, 4, 8, 128, 128, 128}
	value_opts := [?]int{8, 64, 64}
	conds := [?]string{"", "", "NX", "XX", "GT", "LT"}
	r := &g.rng
	for i in 0 ..< ops {
		if i % 250 == 0 {
			g_cmd(g, "CONFIG", "SET", "hash-max-listpack-entries", tp(entries_opts[rng_below(r, len(entries_opts))]))
			g_cmd(g, "CONFIG", "SET", "hash-max-listpack-value", tp(value_opts[rng_below(r, len(value_opts))]))
		}
		k := keys[rng_below(r, len(keys))]
		field :: proc(r: ^Rng) -> string {
			if rng_chance(r, 10) {
				return tp(rng_below(r, 20))
			}
			return tp("f", rng_below(r, 16))
		}
		switch rng_below(r, 20) {
		case 0, 1, 2:
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "HSET", k)
			for _ in 0 ..< 1 + rng_below(r, 3) {
				append(&args, field(r), gen_value(g) if rng_chance(r, 30) else tp("v", rng_below(r, 100)))
			}
			g_write(g, k, ..args[:])
		case 3:
			g_write(g, k, "HDEL", k, field(r), field(r))
		case 4, 5, 6, 7:
			args := make([dynamic]string, context.temp_allocator)
			when_ := T0 + i64(rng_below(r, 40)) * 1000
			if rng_chance(r, 10) {
				when_ = 1000
			}
			secs := rng_chance(r, 30)
			append(&args, "HEXPIREAT" if secs else "HPEXPIREAT", k, tp(when_ / 1000 if secs else when_))
			c := conds[rng_below(r, len(conds))]
			if c != "" {
				append(&args, c)
			}
			n := 1 + rng_below(r, 4)
			append(&args, "FIELDS", tp(n))
			for _ in 0 ..< n {
				append(&args, field(r))
			}
			g_write(g, k, ..args[:])
		case 8:
			g_write(g, k, "HPERSIST", k, "FIELDS", "2", field(r), field(r))
		case 9:
			g_cmd(g, "HPEXPIRETIME" if rng_chance(r, 50) else "HEXPIRETIME", k, "FIELDS", "3", field(r), field(r), field(r))
		case 10:
			g_cmd(g, "HTTL" if rng_chance(r, 50) else "HPTTL", k, "FIELDS", "2", field(r), field(r))
		case 11:
			g_write(g, k, "HINCRBY", k, field(r), tp(rng_below(r, 100) - 50))
		case 12:
			g_write(g, k, "HSETNX", k, field(r), tp(rng_below(r, 100)))
		case 13:
			g_cmd(g, "HGET", k, field(r))
		case 14:
			g_cmd(g, "HMGET", k, field(r), field(r))
		case 15:
			g_cmd(g, "HGETALL", k)
		case 16:
			c := rng_below(r, 30) - 15
			g_cmd(g, "HRANDFIELD", k, tp(c), "WITHVALUES")
		case 17:
			g_cmd(g, "HSCAN", k, "0", "COUNT", tp(1 + rng_below(r, 10)))
		case 18:
			if rng_chance(r, 20) {
				g_cmd(g, "DEL", k)
			} else {
				g_cmd(g, "HLEN", k)
			}
		case 19:
			g_write(g, k, "HINCRBYFLOAT", k, field(r), "0.5")
		}
	}
	g_cmd(g, "CONFIG", "SET", "hash-max-listpack-entries", "128")
	g_cmd(g, "CONFIG", "SET", "hash-max-listpack-value", "64")
	for k in keys {
		g_state(g, k)
		g_reads(g, k)
	}
}

run_gen :: proc(dir: string) -> bool {
	g := Gen {
		buf = make([dynamic]u8),
		rng = Rng{s = 0x11A5_7E57},
	}
	defer delete(g.buf)
	g_cmd(&g, "CONFIG", "SET", "hash-max-listpack-entries", "128")
	g_cmd(&g, "CONFIG", "SET", "hash-max-listpack-value", "64")
	section_basic(&g)
	section_conversions(&g, 128, 64)
	section_conversions(&g, 4, 8)
	section_conversions(&g, 1, 1)
	section_conversions(&g, 0, 0)
	g_cmd(&g, "CONFIG", "SET", "hash-max-listpack-entries", "128")
	g_cmd(&g, "CONFIG", "SET", "hash-max-listpack-value", "64")
	section_hincrby(&g)
	section_hincrbyfloat(&g)
	section_hstrlen(&g)
	section_hrandfield(&g)
	section_hscan(&g)
	section_resp3(&g)
	section_fuzz(&g, 12000)
	for table_mode in ([?]bool{false, true}) {
		section_hfe_commands(&g, table_mode)
		section_hfe_lazy(&g, table_mode)
		section_hfe_active(&g, table_mode)
	}
	section_hfe_fuzz(&g, 6000)
	g_cmd(&g, "DEBUG", "SET-ACTIVE-EXPIRE", "1")
	g_cmd(&g, "CONFIG", "SET", "hash-max-listpack-entries", "128")
	g_cmd(&g, "CONFIG", "SET", "hash-max-listpack-value", "64")
	g_cmd(&g, "FLUSHALL")
	path := fmt.tprintf("%s/script.resp", dir)
	if err := os.write_entire_file(path, g.buf[:]); err != nil {
		fmt.eprintln("cannot write", path)
		return false
	}
	fmt.printfln("generated %d commands (%d bytes) into %s", g.n, len(g.buf), path)
	return true
}
