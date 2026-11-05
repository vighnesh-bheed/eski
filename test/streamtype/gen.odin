package streamtype_harness

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
	g_cmd(g, "XINFO", "STREAM", key)
}

g_full :: proc(g: ^Gen, key: string) {
	g_cmd(g, "XLEN", key)
	g_cmd(g, "XRANGE", key, "-", "+")
	g_cmd(g, "XINFO", "STREAM", key, "FULL")
	g_cmd(g, "DUMP", key)
}

pick :: proc(r: ^Rng, opts: []string) -> string {
	return opts[rng_below(r, len(opts))]
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

MAXU :: "18446744073709551615"

INT_EDGES := [?]string{"0", "1", "12", "127", "128", "-1", "-128", "-129", "4095", "4096", "-4096", "-4097", "32767", "-32768", "32768", "-32769", "8388607", "-8388608", "8388608", "2147483647", "-2147483648", "2147483648", "9223372036854775807", "-9223372036854775808"}
NONCANON := [?]string{"007", "+1", "-0", "1.0", "9223372036854775808", "-9223372036854775809", "00", "-", " 11", "11 ", "0x10", "1e3", "abc", ""}
STR_LENS := [?]int{0, 1, 11, 12, 63, 64, 65, 127, 128, 4095, 4096, 4097}

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
		return rep(u8('a' + rng_below(r, 26)), STR_LENS[rng_below(r, len(STR_LENS))])
	case 5:
		n := rng_below(r, 12)
		bb := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			bb[i] = u8(rng_next(r))
		}
		return string(bb)
	case:
		pool := [?]string{"a", "b", "c", "hello", "world", "1", "2", "10", "-1", "", "value"}
		return pool[rng_below(r, len(pool))]
	}
}

gen_field :: proc(g: ^Gen) -> string {
	r := &g.rng
	pool := [?]string{"f", "g", "item", "name", "1", "-5", "007", "", "otherfield", "x"}
	if rng_chance(r, 10) {
		return gen_value(g)
	}
	return pool[rng_below(r, len(pool))]
}

gen_fields :: proc(g: ^Gen, same: bool) -> []string {
	r := &g.rng
	out := make([dynamic]string, context.temp_allocator)
	if same {
		append(&out, "item", gen_value(g))
		if rng_chance(r, 30) {
			append(&out, "other", gen_value(g))
		}
		return out[:]
	}
	n := 1 + rng_below(r, 4)
	if rng_chance(r, 3) {
		n = 20 + rng_below(r, 20)
	}
	for _ in 0 ..< n {
		append(&out, gen_field(g), gen_value(g))
	}
	return out[:]
}

xadd :: proc(g: ^Gen, key: string, id: string, fields: []string, opts: ..string) {
	a := make([dynamic]string, context.temp_allocator)
	append(&a, "XADD", key)
	append(&a, ..opts)
	append(&a, id)
	append(&a, ..fields)
	g_cmds(g, a[:])
}

config_nodes :: proc(g: ^Gen, entries: string, bytes: string) {
	g_cmd(g, "CONFIG", "SET", "stream-node-max-entries", entries)
	g_cmd(g, "CONFIG", "SET", "stream-node-max-bytes", bytes)
}

section_basic :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	config_nodes(g, "100", "4096")
	g_cmd(g, "XADD", "s", "1-1", "a", "1")
	g_state(g, "s")
	g_cmd(g, "XADD", "s", "1-2", "a", "2", "b", "3")
	g_cmd(g, "XADD", "s", "2", "a", "4")
	g_cmd(g, "XADD", "s", "2-*", "a", "5")
	g_cmd(g, "XADD", "s", "3-*", "x", "y")
	g_cmd(g, "XADD", "s", "3-0", "dup", "1")
	g_cmd(g, "XADD", "s", "2-*", "past", "1")
	g_cmd(g, "XADD", "s", "0-0", "x", "y")
	g_cmd(g, "XADD", "s", "0", "x", "y")
	g_state(g, "s")
	g_full(g, "s")
	g_cmd(g, "XREVRANGE", "s", "+", "-")
	g_cmd(g, "XINFO", "STREAM", "s", "FULL", "COUNT", "2")
	g_cmd(g, "XINFO", "STREAM", "s", "FULL", "COUNT", "0")
	g_cmd(g, "XINFO", "STREAM", "s", "FULL", "COUNT", "-5")
	g_cmd(g, "XADD", "z", "0-*", "a", "b")
	g_cmd(g, "XADD", "z", "0-*", "a", "b")
	g_state(g, "z")
	g_cmd(g, "XDEL", "s", "1-2")
	g_state(g, "s")
	g_cmd(g, "XDEL", "s", "1-1")
	g_state(g, "s")
	g_cmd(g, "XADD", "e", "MAXLEN", "0", "5-5", "a", "b")
	g_state(g, "e")
	g_cmd(g, "XRANGE", "e", "-", "+")
	g_cmd(g, "XADD", "e", "5-5", "a", "b")
	g_cmd(g, "XADD", "e", "5-6", "a", "b")
	g_state(g, "e")
	g_cmd(g, "XDEL", "e", "5-6")
	g_state(g, "e")
	g_cmd(g, "XADD", "e", "5-*", "a", "b")
	g_state(g, "e")
	g_cmd(g, "TYPE", "s")
	g_cmd(g, "OBJECT", "ENCODING", "s")
	g_cmd(g, "DEBUG", "OBJECT", "s")
	g_cmd(g, "MEMORY", "USAGE", "s")
	g_cmd(g, "EXISTS", "s", "e", "nokey")
}

ID_FORMS := [?]string {
	"1",
	"1-1",
	"0-1",
	"0-*",
	"5-*",
	"18446744073709551615-18446744073709551614",
	"18446744073709551615-18446744073709551615",
	"18446744073709551615-*",
	"1-18446744073709551615",
	"-05",
	"0--05",
	" 7",
	"\t7-1",
	"+7",
	"007",
	"7-007",
	"5\x00junk",
	"6-1\x00-2",
	"-",
	"+",
	"*",
	"abc",
	"1-2-3",
	"1-",
	"-1",
	"1--1",
	"-0",
	"1.5",
	"0x10",
	"",
	"18446744073709551616",
	"1-18446744073709551616",
	"-18446744073709551615",
	"7 ",
	"*-1",
	"1-**",
	"1-+",
	"(1",
}

section_ids :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	for form, i in ID_FORMS {
		key := tp("id:", i)
		g_cmd(g, "XADD", key, form, "f", "v")
		g_cmd(g, "XADD", key, form, "f", "v")
		g_cmd(g, "XADD", key, "*", "f", "v")
		g_cmd(g, "XADD", key, "1-*", "f", "v")
		g_cmd(g, "XRANGE", key, "-", "+")
		g_state(g, key)
	}
	long_ok := strings.concatenate({rep('0', 126), "1"}, context.temp_allocator)
	long_bad := strings.concatenate({rep('0', 127), "1"}, context.temp_allocator)
	g_cmd(g, "XADD", "id:long", long_ok, "f", "v")
	g_cmd(g, "XADD", "id:long", long_bad, "f", "v")
	g_cmd(g, "XADD", "id:long", rep('0', 127), "f", "v")
	g_state(g, "id:long")
	g_cmd(g, "XADD", "id:max", MAXU + "-" + MAXU, "a", "b")
	g_cmd(g, "XADD", "id:max", "*", "c", "d")
	g_cmd(g, "XADD", "id:max", MAXU + "-*", "c", "d")
	g_state(g, "id:max")
	g_cmd(g, "XADD", "id:seq", "1-" + MAXU, "a", "b")
	g_cmd(g, "XADD", "id:seq", "1-*", "c", "d")
	g_cmd(g, "XADD", "id:seq", "2-*", "c", "d")
	g_cmd(g, "XADD", "id:seq", "*", "c", "d")
	g_state(g, "id:seq")
	g_cmd(g, "XADD", "id:edge", "2577343934890-" + MAXU, "f", "v")
	g_cmd(g, "XADD", "id:edge", "*", "f2", "v2")
	g_cmd(g, "XRANGE", "id:edge", "-", "+")
	g_state(g, "id:edge")
	ids := [?]string{"0-1", "0-" + MAXU, "1-0", "42-0", "42-42", MAXU + "-18446744073709551614", MAXU + "-" + MAXU}
	for id in ids {
		g_cmd(g, "XADD", "vip", id, "foo", "bar")
	}
	g_state(g, "vip")
	g_cmd(g, "XRANGE", "vip", "(0-1", "+")
	g_cmd(g, "XRANGE", "vip", "-", "(" + MAXU + "-" + MAXU)
	g_cmd(g, "XRANGE", "vip", "(0-1", "(1-0")
	g_cmd(g, "XRANGE", "vip", "(1-0", "(42-42")
	g_cmd(g, "XRANGE", "vip", "(-", "+")
	g_cmd(g, "XRANGE", "vip", "-", "(+")
	g_cmd(g, "XRANGE", "vip", "(" + MAXU + "-" + MAXU, "+")
	g_cmd(g, "XRANGE", "vip", "-", "(0-0")
	g_cmd(g, "XREVRANGE", "vip", "(" + MAXU + "-" + MAXU, "-")
	g_cmd(g, "XREVRANGE", "vip", "+", "(0-0")
	g_cmd(g, "XREAD", "STREAMS", "vip", MAXU + "-18446744073709551614")
	g_cmd(g, "XREAD", "STREAMS", "vip", "+")
	g_cmd(g, "XREAD", "STREAMS", "vip", "$")
	g_cmd(g, "XREAD", "STREAMS", "vip", "0-" + MAXU)
}

section_trim_errors :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	config_nodes(g, "100", "4096")
	for i in 1 ..= 20 {
		g_cmd(g, "XADD", "t", tp(i), "f", tp(i))
	}
	g_cmd(g, "SET", "str", "v")
	cases := [][]string {
		{"XTRIM", "t"},
		{"XTRIM", "t", "MAXLEN"},
		{"XTRIM", "t", "MAXLEN", "abc"},
		{"XTRIM", "t", "MAXLEN", "-1"},
		{"XTRIM", "t", "MAXLEN", "~"},
		{"XTRIM", "t", "MAXLEN", "="},
		{"XTRIM", "t", "MAXLEN", "~", "abc"},
		{"XTRIM", "t", "MINID", "abc"},
		{"XTRIM", "t", "MINID", "-"},
		{"XTRIM", "t", "MINID", "+"},
		{"XTRIM", "t", "MINID", "5-*"},
		{"XTRIM", "t", "MAXLEN", "1", "MINID", "1"},
		{"XTRIM", "t", "MINID", "1", "MAXLEN", "1"},
		{"XTRIM", "t", "MAXLEN", "1", "LIMIT", "10"},
		{"XTRIM", "t", "MAXLEN", "=", "1", "LIMIT", "10"},
		{"XTRIM", "t", "LIMIT", "10"},
		{"XTRIM", "t", "LIMIT", "0"},
		{"XTRIM", "t", "LIMIT", "-1"},
		{"XTRIM", "t", "LIMIT", "abc"},
		{"XTRIM", "t", "MAXLEN", "~", "1", "LIMIT", "-1"},
		{"XTRIM", "t", "MAXLEN", "~", "1", "LIMIT", "abc"},
		{"XTRIM", "t", "MAXLEN", "=", "1", "FOO"},
		{"XTRIM", "t", "FOO"},
		{"XTRIM", "t", "NOMKSTREAM", "MAXLEN", "1"},
		{"XTRIM", "t", "*"},
		{"XTRIM", "nokey", "MAXLEN", "1"},
		{"XTRIM", "nokey", "MAXLEN", "abc"},
		{"XTRIM", "str", "MAXLEN", "1"},
		{"XTRIM", "str", "MAXLEN", "x"},
		{"XTRIM", "t", "maxlen", "~", "1", "limit", "0"},
		{"XTRIM", "t", "MAXLEN", "~", "1", "LIMIT", "1", "LIMIT", "0"},
		{"XTRIM", "t", "MAXLEN", "~", "18"},
		{"XTRIM", "t", "MAXLEN", "19"},
		{"XTRIM", "t", "MINID", "=", "3"},
		{"XTRIM", "t", "MINID", "~", "15"},
		{"XTRIM", "t", "MAXLEN\x00x", "17"},
		{"XADD", "t", "MAXLEN", "1", "MINID", "1", "*", "f", "v"},
		{"XADD", "t", "LIMIT", "5", "*", "f", "v"},
		{"XADD", "t", "MAXLEN", "1", "LIMIT", "5", "*", "f", "v"},
		{"XADD", "t", "*", "f"},
		{"XADD", "t", "*", "f", "v", "g"},
		{"XADD", "t", "MAXLEN", "1", "f", "v"},
		{"XADD", "t", "MAXLEN", "5", "21"},
		{"XADD", "t", "NOMKSTREAM", "f", "v"},
		{"XADD", "t", "MAXLEN", "-5", "*", "f", "v"},
		{"XADD", "t", "MAXLEN", "abc", "*", "f", "v"},
		{"XADD", "t", "MINID", "abc", "*", "f", "v"},
		{"XADD", "t", "LIMIT", "-5", "*", "f", "v"},
		{"XADD", "t", "FOO", "f", "v"},
		{"XADD", "t", "0-0", "f", "v", "g"},
		{"XADD", "t", "0-0", "f", "v"},
		{"XADD", "nokey", "NOMKSTREAM", "*", "f", "v"},
		{"XADD", "nokey", "NOMKSTREAM", "0-0", "f", "v"},
		{"XADD", "nokey", "nomkstream", "MAXLEN", "1", "1-1", "f", "v"},
		{"XADD", "str", "*", "f", "v"},
		{"XADD", "str", "NOMKSTREAM", "*", "f", "v"},
		{"XADD", "str", "0-0", "f", "v"},
		{"XADD", "str", "abc", "f", "v"},
		{"XADD", "t", "*\x00x", "f", "v"},
		{"XADD", "t", "NOMKSTREAM", "MAXLEN", "~", "15", "LIMIT", "3", "100", "f", "v"},
		{"XADD", "t", "MINID", "~", "18", "LIMIT", "0", "101", "f", "v"},
		{"XADD", "t", "MAXLEN", "=", "3", "102", "f", "v"},
		{"XADD", "t", "MINID", "=", "102", "103", "f", "v"},
		{"XADD", "t", "MINID", "200", "104", "f", "v"},
		{"XADD", "t", "MAXLEN", "~", "0", "105", "f", "v"},
		{"XADD", "t", "MAXLEN", "0", "106", "f", "v"},
	}
	for c in cases {
		g_cmds(g, c)
	}
	g_state(g, "t")
	g_cmd(g, "XRANGE", "t", "-", "+")
	g_cmd(g, "EXISTS", "nokey")
}

build_stream :: proc(g: ^Gen, key: string, n: int, start_ms: int, varied: int) {
	r := &g.rng
	g_cmd(g, "DEL", key)
	for i in 0 ..< n {
		same := !rng_chance(r, varied)
		fields := []string{"item", tp(i)} if same else []string{"item", tp(i), "otherfield", "foo"}
		xadd(g, key, tp(start_ms + i, "-", i % 3), fields)
	}
}

section_trim :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	Cfg :: struct {
		entries: string,
		bytes:   string,
		n:       int,
	}
	cfgs := [?]Cfg {
		{"100", "4096", 1000},
		{"1", "4096", 102},
		{"2", "4096", 50},
		{"3", "4096", 40},
		{"10", "4096", 120},
		{"0", "4096", 300},
		{"100", "1", 30},
		{"100", "50", 60},
		{"100", "100", 80},
		{"100", "300", 120},
		{"100", "0", 400},
		{"0", "0", 300},
		{"7", "200", 150},
	}
	for c in cfgs {
		config_nodes(g, c.entries, c.bytes)
		build_stream(g, "t", c.n, 1000, 10)
		g_state(g, "t")
		g_cmd(g, "XTRIM", "t", "MAXLEN", "~", tp(c.n * 3 / 4))
		g_state(g, "t")
		g_cmd(g, "XTRIM", "t", "MAXLEN", tp(c.n * 2 / 3))
		g_state(g, "t")
		g_cmd(g, "XTRIM", "t", "MINID", "~", tp(1000 + c.n / 2))
		g_state(g, "t")
		g_cmd(g, "XTRIM", "t", "MINID", "=", tp(1000 + c.n / 2 + 3, "-1"))
		g_state(g, "t")
		g_cmd(g, "XTRIM", "t", "MAXLEN", "~", "0", "LIMIT", "1")
		g_state(g, "t")
		g_cmd(g, "XTRIM", "t", "MAXLEN", "~", "0", "LIMIT", tp(c.n / 8))
		g_state(g, "t")
		g_cmd(g, "XADD", "t", "MAXLEN", "~", tp(c.n / 10), "LIMIT", "30", tp(5000), "item", "x")
		g_state(g, "t")
		g_cmd(g, "XADD", "t", "MINID", tp(1000 + c.n), tp(5001), "item", "y")
		g_state(g, "t")
		g_cmd(g, "XTRIM", "t", "MAXLEN", "1")
		g_state(g, "t")
		g_cmd(g, "XTRIM", "t", "MAXLEN", "0")
		g_state(g, "t")
		g_cmd(g, "XADD", "t", "MAXLEN", "~", "5", tp(5002), "item", "z")
		g_state(g, "t")
		build_stream(g, "u", c.n, 1, 30)
		for d := 1; d < c.n; d += 7 {
			g_cmd(g, "XDEL", "u", tp(1 + d, "-", d % 3))
		}
		g_state(g, "u")
		g_cmd(g, "XTRIM", "u", "MAXLEN", "~", tp(c.n / 2))
		g_state(g, "u")
		g_cmd(g, "XTRIM", "u", "MINID", tp(c.n / 2 + 4))
		g_state(g, "u")
		g_cmd(g, "XTRIM", "u", "MAXLEN", "~", "0")
		g_state(g, "u")
		g_cmd(g, "XRANGE", "u", "-", "+", "COUNT", "20")
	}
	config_nodes(g, "100", "4096")
}

section_boundaries :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	for limit in ([]string{"1", "2", "5", "16"}) {
		config_nodes(g, limit, "4096")
		g_cmd(g, "DEL", "b")
		for i in 1 ..= 40 {
			g_cmd(g, "XADD", "b", tp(i), "f", "v")
			if i % 3 == 0 {
				g_cmd(g, "XDEL", "b", tp(i - 1))
			}
			g_state(g, "b")
		}
	}
	for bytes in ([]string{"30", "64", "100", "128", "256", "500"}) {
		config_nodes(g, "1000", bytes)
		g_cmd(g, "DEL", "b")
		for i in 1 ..= 60 {
			g_cmd(g, "XADD", "b", tp(i), "f", rep('v', (i * 7) % 90))
			g_state(g, "b")
		}
		g_cmd(g, "DEL", "b")
		for i in 1 ..= 30 {
			g_cmd(g, "XADD", "b", tp(i), "field", rep('w', i))
		}
		g_state(g, "b")
	}
	config_nodes(g, "100", "4096")
	g_cmd(g, "DEL", "big")
	for i in 1 ..= 30 {
		g_cmd(g, "XADD", "big", tp(i), "f", rep('x', STR_LENS[i % len(STR_LENS)] * (1 + i % 3)))
	}
	g_state(g, "big")
	g_cmd(g, "XRANGE", "big", "10", "12")
	config_nodes(g, "100", "100")
	g_cmd(g, "XADD", "big", "31", "f", rep('y', 5000))
	g_cmd(g, "XADD", "big", "32", "f", "small")
	g_state(g, "big")
	config_nodes(g, "100", "4096")
}

section_encoding :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	config_nodes(g, "100", "4096")
	i := 1
	for v in INT_EDGES {
		g_cmd(g, "XADD", "enc", tp(i), v, v)
		i += 1
	}
	for v in NONCANON {
		g_cmd(g, "XADD", "enc", tp(i), v, v)
		i += 1
	}
	g_state(g, "enc")
	g_cmd(g, "XRANGE", "enc", "-", "+")
	for n in STR_LENS {
		g_cmd(g, "XADD", "enc2", tp(i), rep('k', n % 70), rep('v', n))
		i += 1
		g_state(g, "enc2")
	}
	for k in 0 ..< 40 {
		g_cmd(g, "XADD", "enc3", tp(i, "-", k), gen_field(g), gen_value(g), gen_field(g), gen_value(g))
		i += 1
	}
	g_state(g, "enc3")
	g_cmd(g, "XRANGE", "enc3", "-", "+")
	g_cmd(g, "XADD", "same", "1", "a", "1", "b", "2")
	g_cmd(g, "XADD", "same", "2", "a", "3", "b", "4")
	g_cmd(g, "XADD", "same", "3", "b", "3", "a", "4")
	g_cmd(g, "XADD", "same", "4", "a", "5")
	g_cmd(g, "XADD", "same", "5", "a", "5", "b", "6", "c", "7")
	g_cmd(g, "XADD", "same", "6", "a", "x", "b", "y")
	g_cmd(g, "XADD", "same", "7", "1", "x", "b", "y")
	g_cmd(g, "XADD", "same2", "1", "1", "x")
	g_cmd(g, "XADD", "same2", "2", "1", "y")
	g_cmd(g, "XADD", "same2", "3", "01", "y")
	g_cmd(g, "XADD", "same2", "4", "", "y")
	g_state(g, "same")
	g_state(g, "same2")
	g_cmd(g, "XRANGE", "same", "-", "+")
	g_cmd(g, "XREVRANGE", "same", "+", "-")
	g_cmd(g, "XADD", "rev", "1234567891230", "key1", "value1")
	g_cmd(g, "XADD", "rev", "1234567891240", "key2", "value2")
	g_cmd(g, "XADD", "rev", "1234567891250", "key3", "value3")
	g_cmd(g, "XADD", "rev2", "1234567891230", "key1", "value1")
	g_cmd(g, "XADD", "rev2", "1234567891240", "key1", "value2")
	g_cmd(g, "XADD", "rev2", "1234567891250", "key1", "value3")
	g_cmd(g, "XREVRANGE", "rev", "1234567891245", "-")
	g_cmd(g, "XREVRANGE", "rev2", "1234567891245", "-")
	g_state(g, "rev2")
	g_cmd(g, "XADD", "delta", "1", "f", "v")
	g_cmd(g, "XADD", "delta", "1641544570597-0", "f", "v")
	g_cmd(g, "XADD", "delta", "1641544570597-1", "f", "v")
	g_cmd(g, "XADD", "delta", "1641544570598-0", "f", "v")
	g_cmd(g, "XADD", "delta", MAXU + "-3", "f", "v")
	g_state(g, "delta")
	g_cmd(g, "XTRIM", "delta", "MINID", "1641544570597-0")
	g_state(g, "delta")
	g_cmd(g, "XRANGE", "delta", "-", "+")
	g_cmd(g, "XADD", "wrap", "5-10", "f", "v")
	g_cmd(g, "XADD", "wrap", "6-0", "f", "v")
	g_cmd(g, "XADD", "wrap", "6-3", "f", "v")
	g_cmd(g, "XADD", "wrap", "7-" + MAXU, "f", "v")
	g_state(g, "wrap")
	g_cmd(g, "XRANGE", "wrap", "-", "+")
	g_cmd(g, "XREVRANGE", "wrap", "+", "-")
	g_cmd(g, "XTRIM", "wrap", "MINID", "6-1")
	g_state(g, "wrap")
	g_cmd(g, "XRANGE", "wrap", "6", "6")
}

BOUNDS := [?]string{"-", "+", "0", "0-0", "3", "3-1", "(3-1", "(3", "(0-0", "10", "(10", "25-2", "(25-2", MAXU, "(" + MAXU, "(-", "(+", "(" + MAXU + "-" + MAXU, "(", "((5", "abc", "5-", "5-*", "(5-*", "999999", " 4", "(" + MAXU + "-0"}

section_ranges :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	config_nodes(g, "4", "4096")
	build_stream(g, "r", 40, 1, 25)
	for d in ([]string{"3-0", "4-1", "10-0", "11-1", "12-2", "13-0", "25-0", "26-1"}) {
		g_cmd(g, "XDEL", "r", d)
	}
	g_state(g, "r")
	counts := [][]string{{}, {"COUNT", "0"}, {"COUNT", "1"}, {"COUNT", "3"}, {"COUNT", "-1"}, {"COUNT", "abc"}, {"count", "2", "COUNT", "1"}, {"COUNT"}, {"LIMIT", "1"}, {"COUNT", "9223372036854775807"}}
	for s in BOUNDS {
		for e in BOUNDS {
			c := counts[rng_below(&g.rng, len(counts))]
			a := make([dynamic]string, context.temp_allocator)
			append(&a, "XRANGE", "r", s, e)
			append(&a, ..c)
			g_cmds(g, a[:])
			clear(&a)
			append(&a, "XREVRANGE", "r", e, s)
			append(&a, ..c)
			g_cmds(g, a[:])
		}
	}
	for c in counts {
		a := make([dynamic]string, context.temp_allocator)
		append(&a, "XRANGE", "r", "-", "+")
		append(&a, ..c)
		g_cmds(g, a[:])
		clear(&a)
		append(&a, "XRANGE", "nokey", "-", "+")
		append(&a, ..c)
		g_cmds(g, a[:])
	}
	g_cmd(g, "SET", "str", "x")
	g_cmd(g, "XRANGE", "str", "-", "+")
	g_cmd(g, "XRANGE", "str", "abc", "+")
	g_cmd(g, "XREVRANGE", "str", "+", "-", "COUNT", "0")
	g_cmd(g, "XRANGE", "r", "-")
	cursor := "-"
	for _ in 0 ..< 30 {
		g_cmd(g, "XRANGE", "r", cursor, "+", "COUNT", "3")
		cursor = tp("(", rng_below(&g.rng, 45))
	}
	config_nodes(g, "100", "4096")
}

section_xdel :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	config_nodes(g, "5", "4096")
	build_stream(g, "d", 30, 1, 20)
	g_state(g, "d")
	g_cmd(g, "XDEL", "d", "1-0")
	g_state(g, "d")
	g_cmd(g, "XDEL", "d", "2-1", "3-2", "99-0", "2-1")
	g_state(g, "d")
	g_cmd(g, "XDEL", "d", "4-0", "abc", "5-1")
	g_cmd(g, "XDEL", "d", "-")
	g_cmd(g, "XDEL", "d", "+")
	g_cmd(g, "XDEL", "d", "5-*")
	g_cmd(g, "XDEL", "d", "6")
	g_cmd(g, "XDEL", "nokey", "abc")
	g_cmd(g, "XDEL", "nokey", "1-1")
	g_cmd(g, "SET", "str", "x")
	g_cmd(g, "XDEL", "str", "abc")
	g_state(g, "d")
	for i in 0 ..< 30 {
		g_cmd(g, "XDEL", "d", tp(1 + i, "-", i % 3))
		if i % 4 == 0 {
			g_state(g, "d")
			g_cmd(g, "XREAD", "STREAMS", "d", "+")
		}
	}
	g_state(g, "d")
	g_cmd(g, "XLEN", "d")
	g_cmd(g, "XRANGE", "d", "-", "+")
	g_cmd(g, "XREAD", "STREAMS", "d", "0")
	g_cmd(g, "XREAD", "STREAMS", "d", "+")
	g_cmd(g, "XADD", "d", "30-2", "f", "v")
	g_cmd(g, "XADD", "d", "30-3", "f", "v")
	g_state(g, "d")
	g_cmd(g, "XADD", "x", "1-0", "data", "a")
	g_cmd(g, "XADD", "x", "2-0", "data", "b")
	g_cmd(g, "XADD", "x", "3-0", "data", "c")
	g_cmd(g, "XDEL", "x", "2-0")
	g_cmd(g, "XINFO", "STREAM", "x", "FULL")
	g_cmd(g, "XDEL", "x", "1-0")
	g_cmd(g, "XINFO", "STREAM", "x", "FULL")
	g_cmd(g, "XADD", "x", "4-0", "data", "d")
	g_cmd(g, "XADD", "x", "5-0", "data", "e")
	g_cmd(g, "XTRIM", "x", "MAXLEN", "=", "2")
	g_cmd(g, "XINFO", "STREAM", "x", "FULL")
	g_state(g, "x")
	config_nodes(g, "100", "4096")
}

section_xsetid :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "SET", "str", "x")
	g_cmd(g, "XADD", "s", "5-1", "a", "1")
	g_cmd(g, "XADD", "s", "5-2", "a", "2")
	g_cmd(g, "XADD", "s", "5-3", "a", "3")
	cases := [][]string {
		{"XSETID", "nokey", "1-1"},
		{"XSETID", "nokey", "abc"},
		{"XSETID", "str", "1-1"},
		{"XSETID", "s", "abc"},
		{"XSETID", "s", "-"},
		{"XSETID", "s", "+"},
		{"XSETID", "s", "5-*"},
		{"XSETID", "s", "1-1", "0"},
		{"XSETID", "s", "1-1", "0-0"},
		{"XSETID", "s", "1-1", "ENTRIESADDED"},
		{"XSETID", "s", "1-1", "ENTRIESADDED", "abc"},
		{"XSETID", "s", "1-1", "ENTRIESADDED", "-1", "MAXDELETEDID", "0-0"},
		{"XSETID", "s", "1-1", "MAXDELETEDID", "2-0"},
		{"XSETID", "s", "1-1", "MAXDELETEDID", "abc"},
		{"XSETID", "s", "1-1", "MAXDELETEDID"},
		{"XSETID", "nokey", "1-1", "MAXDELETEDID", "2-0"},
		{"XSETID", "s", "5-2"},
		{"XSETID", "s", "5-3", "ENTRIESADDED", "2"},
		{"XSETID", "s", "5-3", "ENTRIESADDED", "3"},
		{"XSETID", "s", "5-3"},
		{"XSETID", "s", "6", "ENTRIESADDED", "10", "MAXDELETEDID", "5-9"},
		{"XSETID", "s", "6", "entriesadded", "11", "maxdeletedid", "5-9", "ENTRIESADDED", "12"},
		{"XSETID", "s", "5-8"},
		{"XSETID", "s", "5-9"},
		{"XADD", "s", "5-9", "a", "b"},
		{"XADD", "s", "6-*", "a", "b"},
		{"XDEL", "s", "6-0"},
		{"XSETID", "s", "6-0"},
		{"XSETID", "s", "5-3"},
		{"XSETID", "s", "6-0", "MAXDELETEDID", "6-1"},
		{"XSETID", "s", "7-0", "MAXDELETEDID", "0-0"},
		{"XSETID", "s", "7-0", "MAXDELETEDID", "7-0"},
		{"XSETID", "s", "7-0", "ENTRIESADDED", "9223372036854775807"},
		{"XSETID", "s", "7-0", "ENTRIESADDED", "9223372036854775808"},
		{"XADD", "s", "MAXLEN", "0", "8-0", "a", "b"},
		{"XSETID", "s", "0-0"},
		{"XSETID", "s", "7-0", "MAXDELETEDID", "6-5"},
		{"XSETID", "s", "0-0", "ENTRIESADDED", "0"},
		{"XADD", "s", "*", "a", "b"},
		{"XSETID", "s", MAXU + "-" + MAXU},
		{"XADD", "s", "*", "a", "b"},
		{"XSETID", "s", "1-1", "FOO", "bar"},
	}
	for c in cases {
		g_cmds(g, c)
		if c[0] != "XSETID" || len(c) < 2 || c[1] == "s" {
			g_cmd(g, "XINFO", "STREAM", "s")
		}
	}
	g_state(g, "s")
	g_cmd(g, "XADD", "mystream", "MAXLEN", "0", "*", "a", "b")
	g_cmd(g, "XSETID", "mystream", "200-0")
	g_cmd(g, "XINFO", "STREAM", "mystream")
	g_cmd(g, "XADD", "mystream", "*", "a", "b")
	g_cmd(g, "XSETID", "mystream", "1-1")
	g_cmd(g, "XADD", "mystream", "MAXLEN", "0", "*", "a", "b")
	g_state(g, "mystream")
	g_cmd(g, "XADD", "x", "1-1", "a", "1")
	g_cmd(g, "XADD", "x", "1-2", "b", "2")
	g_cmd(g, "XADD", "x", "1-3", "c", "3")
	g_cmd(g, "XDEL", "x", "1-2")
	g_cmd(g, "XDEL", "x", "1-3")
	g_cmd(g, "XINFO", "STREAM", "x")
	g_cmd(g, "XSETID", "x", "1-2")
	g_state(g, "x")
}

section_xread :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	config_nodes(g, "3", "4096")
	build_stream(g, "a", 12, 1, 30)
	build_stream(g, "b", 5, 100, 0)
	g_cmd(g, "XADD", "empty", "MAXLEN", "0", "1-1", "f", "v")
	g_cmd(g, "SET", "str", "x")
	cases := [][]string {
		{"XREAD", "STREAMS", "a", "0"},
		{"XREAD", "COUNT", "2", "STREAMS", "a", "b", "c", "0", "0", "0"},
		{"XREAD", "STREAMS", "a", "b", "$", "$"},
		{"XREAD", "STREAMS", "a", "b", "+", "+"},
		{"XREAD", "COUNT", "3", "STREAMS", "a", "b", "+", "+"},
		{"XREAD", "STREAMS", "nokey", "+"},
		{"XREAD", "STREAMS", "nokey", "$"},
		{"XREAD", "STREAMS", "empty", "+"},
		{"XREAD", "STREAMS", "empty", "0"},
		{"XREAD", "STREAMS", "empty", "$"},
		{"XREAD", "COUNT", "0", "STREAMS", "a", "0"},
		{"XREAD", "COUNT", "-5", "STREAMS", "a", "5"},
		{"XREAD", "COUNT", "abc", "STREAMS", "a", "0"},
		{"XREAD", "COUNT", "1", "COUNT", "2", "STREAMS", "a", "0"},
		{"XREAD", "STREAMS", "a", "b", "0"},
		{"XREAD", "STREAMS", "a", "b", "c"},
		{"XREAD", "a", "b", "c"},
		{"XREAD", "COUNT", "1", "a", "STREAMS", "a", "0"},
		{"XREAD", "COUNT", "1", "STREAMS"},
		{"XREAD", "BLOCK", "abc", "STREAMS", "a", "0"},
		{"XREAD", "BLOCK", "-1", "STREAMS", "a", "0"},
		{"XREAD", "BLOCK", "1.5", "STREAMS", "a", "0"},
		{"XREAD", "BLOCK", "9223372036854775807", "STREAMS", "a", "0"},
		{"XREAD", "BLOCK", "100", "STREAMS", "a", "0"},
		{"XREAD", "BLOCK", "0", "STREAMS", "a", "b", "0", "+"},
		{"XREAD", "BLOCK", "1", "STREAMS", "a", "$"},
		{"XREAD", "GROUP", "g", "c", "STREAMS", "a", "0"},
		{"XREAD", "GROUP", "g", "STREAMS", "a", "0"},
		{"XREAD", "NOACK", "STREAMS", "a", "0"},
		{"XREAD", "STREAMS", "a", ">"},
		{"XREAD", "STREAMS", "nokey", ">"},
		{"XREAD", "STREAMS", "a", "abc"},
		{"XREAD", "STREAMS", "a", "-"},
		{"XREAD", "STREAMS", "a", "(1-1"},
		{"XREAD", "STREAMS", "a", "5-*"},
		{"XREAD", "STREAMS", "str", "0"},
		{"XREAD", "STREAMS", "a", "str", "0", "abc"},
		{"XREAD", "STREAMS", "a", "str", "abc", "0"},
		{"XREAD", "STREAMS", "nokey", "str", "abc", "0"},
		{"XREAD", "STREAMS", "a", "a", "0", "5-1"},
		{"XREAD", "STREAMS", "a", "nokey", "b", "10", "0", "101"},
		{"XREAD", "STREAMS", "a", "12-2"},
		{"XREAD", "STREAMS", "a", "11-2"},
		{"XREAD", "STREAMS", "a", "11"},
		{"XREAD", "streams", "a", "11"},
		{"XREAD", "COUNT", "1", "BLOCK", "5", "STREAMS", "b", "100-2"},
		{"XREAD", "STREAMS", "a", "$\x00x"},
		{"XREAD", "STREAMS", "a", "0", "STREAMS", "0"},
		{"XREAD", "STREAMS", "STREAMS", "0"},
	}
	for c in cases {
		g_cmds(g, c)
	}
	g_cmd(g, "XDEL", "a", "12-2")
	g_cmd(g, "XREAD", "STREAMS", "a", "+")
	g_cmd(g, "XREAD", "STREAMS", "a", "11-1")
	g_cmd(g, "XREAD", "STREAMS", "a", "$")
	for i in 0 ..< 30 {
		k1 := pick(&g.rng, {"a", "b", "nokey", "empty"})
		k2 := pick(&g.rng, {"a", "b", "nokey", "empty"})
		id1 := pick(&g.rng, {"0", "$", "+", "5", "100-1", "(5", "3-2"})
		id2 := pick(&g.rng, {"0", "$", "+", "5", "100-1", "12", "3-2"})
		if i % 2 == 0 {
			g_cmd(g, "XREAD", "COUNT", tp(rng_below(&g.rng, 4)), "STREAMS", k1, k2, id1, id2)
		} else {
			g_cmd(g, "XREAD", "STREAMS", k1, id1)
		}
	}
	config_nodes(g, "100", "4096")
}

section_xinfo :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "SET", "str", "x")
	g_cmd(g, "XADD", "s", "1-1", "a", "1")
	g_cmd(g, "XADD", "s", "1-2", "b", "2")
	g_cmd(g, "XADD", "e", "MAXLEN", "0", "1-1", "a", "1")
	cases := [][]string {
		{"XINFO"},
		{"XINFO", "HELP"},
		{"XINFO", "help"},
		{"XINFO", "HELP", "x"},
		{"XINFO", "STREAM"},
		{"XINFO", "STREAM", "nokey"},
		{"XINFO", "STREAM", "str"},
		{"XINFO", "STREAM", "s"},
		{"XINFO", "STREAM", "e"},
		{"XINFO", "STREAM", "e", "FULL"},
		{"XINFO", "stream", "s", "full"},
		{"XINFO", "STREAM", "s", "FULL", "COUNT"},
		{"XINFO", "STREAM", "s", "FULL", "COUNT", "abc"},
		{"XINFO", "STREAM", "s", "FULL", "COUNT", "-1"},
		{"XINFO", "STREAM", "s", "FULL", "COUNT", "0"},
		{"XINFO", "STREAM", "s", "FULL", "COUNT", "1"},
		{"XINFO", "STREAM", "s", "FULLX"},
		{"XINFO", "STREAM", "s", "FULL", "COUNTX", "1"},
		{"XINFO", "STREAM", "s", "FULL", "1", "2"},
		{"XINFO", "STREAM", "s", "x"},
		{"XINFO", "STREAM", "s", "FULL", "COUNT", "1", "x"},
		{"XINFO", "STREAM", "nokey", "FULL", "bad"},
		{"XINFO", "STREAM", "str", "FULL", "bad"},
		{"XINFO", "GROUPS", "s"},
		{"XINFO", "GROUPS", "s", "x"},
		{"XINFO", "GROUPS"},
		{"XINFO", "GROUPS", "nokey"},
		{"XINFO", "GROUPS", "str"},
		{"XINFO", "CONSUMERS", "s", "g"},
		{"XINFO", "CONSUMERS", "s", "g\r\nx"},
		{"XINFO", "CONSUMERS", "s"},
		{"XINFO", "CONSUMERS", "nokey", "g"},
		{"XINFO", "CONSUMERS", "str", "g"},
		{"XINFO", "FOO"},
		{"XINFO", "FOO", "s"},
		{"XINFO", "STREAMS", "s"},
	}
	for c in cases {
		g_cmds(g, c)
	}
}

section_wrongtype :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "SET", "str", "v")
	g_cmd(g, "XADD", "s", "1-1", "a", "1")
	cases := [][]string {
		{"XADD", "str", "1-1", "a", "b"},
		{"XLEN", "str"},
		{"XRANGE", "str", "-", "+"},
		{"XREVRANGE", "str", "+", "-"},
		{"XDEL", "str", "1-1"},
		{"XTRIM", "str", "MAXLEN", "1"},
		{"XSETID", "str", "1-1"},
		{"XINFO", "STREAM", "str"},
		{"XREAD", "STREAMS", "str", "0"},
		{"GET", "s"},
		{"TYPE", "s"},
		{"TYPE", "str"},
		{"OBJECT", "ENCODING", "s"},
		{"DEBUG", "OBJECT", "s"},
		{"MEMORY", "USAGE", "s"},
		{"MEMORY", "USAGE", "nokey"},
		{"XLEN", "nokey"},
		{"COPY", "s", "s2"},
		{"COPY", "s", "s2"},
		{"COPY", "s", "s"},
		{"XRANGE", "s2", "-", "+"},
		{"XADD", "s2", "2-2", "c", "d"},
		{"XRANGE", "s", "-", "+"},
		{"XRANGE", "s2", "-", "+"},
		{"XINFO", "STREAM", "s2"},
		{"DUMP", "s2"},
		{"DUMP", "s"},
		{"DEL", "s"},
		{"EXISTS", "s", "s2"},
		{"XADD", "s", "1-1", "x", "y"},
		{"SET", "s", "now a string"},
		{"XLEN", "s"},
		{"DUMP", "str"},
	}
	for c in cases {
		g_cmds(g, c)
	}
	config_nodes(g, "2", "4096")
	build_stream(g, "c", 25, 1, 40)
	g_cmd(g, "XDEL", "c", "5-1", "6-2")
	g_cmd(g, "COPY", "c", "c2")
	g_state(g, "c2")
	g_cmd(g, "XADD", "c2", "100", "x", "y")
	g_state(g, "c")
	g_state(g, "c2")
	config_nodes(g, "100", "4096")
}

section_auto :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	config_nodes(g, "10", "4096")
	for i in 0 ..< 60 {
		g_cmd(g, "XADD", "auto", "*", "n", tp(i))
		if i % 10 == 0 {
			g_state(g, "auto")
		}
	}
	g_cmd(g, "XADD", "auto", "MAXLEN", "~", "25", "*", "n", "x")
	g_state(g, "auto")
	g_cmd(g, "XADD", "auto", "99999999999999-*", "n", "future")
	g_cmd(g, "XADD", "auto", "*", "n", "after")
	g_cmd(g, "XADD", "auto", "*", "n", "after2")
	g_cmd(g, "XADD", "auto", "99999999999999-*", "n", "again")
	g_state(g, "auto")
	g_cmd(g, "XREAD", "COUNT", "2", "STREAMS", "auto", "0")
	g_cmd(g, "XREVRANGE", "auto", "+", "-", "COUNT", "3")
	g_cmd(g, "XADD", "auto2", "NOMKSTREAM", "*", "a", "b")
	g_cmd(g, "XADD", "auto2", "*", "a", "b")
	g_cmd(g, "XADD", "auto2", "MINID", "~", "0", "*", "c", "d")
	g_state(g, "auto2")
	config_nodes(g, "100", "4096")
}

Fuzz_Key :: struct {
	ms:   u64,
	seq:  u64,
	ids:  [dynamic][2]u64,
	used: bool,
}

section_fuzz :: proc(g: ^Gen, ops: int) {
	g_cmd(g, "FLUSHALL")
	r := &g.rng
	keys := [?]string{"fz:a", "fz:b", "fz:c", "fz:d"}
	state: [len(keys)]Fuzz_Key
	for &s in state {
		s.ids = make([dynamic][2]u64, context.temp_allocator)
	}
	entries_opts := [?]string{"1", "2", "3", "5", "10", "100", "0"}
	bytes_opts := [?]string{"60", "200", "500", "4096", "0"}
	for op in 0 ..< ops {
		if op % 400 == 0 {
			config_nodes(g, entries_opts[rng_below(r, len(entries_opts))], bytes_opts[rng_below(r, len(bytes_opts))])
		}
		ki := rng_below(r, len(keys))
		key := keys[ki]
		s := &state[ki]
		roll := rng_below(r, 100)
		switch {
		case roll < 45:
			idform: string
			if s.used && rng_chance(r, 40) {
				if rng_chance(r, 20) {
					idform = tp(s.ms, "-*")
					s.seq += 1
				} else {
					s.seq += 1 + u64(rng_below(r, 3))
					idform = tp(s.ms, "-", s.seq)
				}
			} else {
				gap := u64(1 + rng_below(r, 3))
				if rng_chance(r, 3) {
					gap = u64(1) << uint(rng_below(r, 40))
				}
				s.ms += gap
				switch rng_below(r, 6) {
				case 0:
					s.seq = 0
					idform = tp(s.ms)
				case 1:
					s.seq = 0
					idform = tp(s.ms, "-*")
				case:
					s.seq = u64(rng_below(r, 3))
					idform = tp(s.ms, "-", s.seq)
				}
			}
			s.used = true
			opts := make([dynamic]string, context.temp_allocator)
			if rng_chance(r, 15) {
				t := rng_below(r, 6)
				switch t {
				case 0:
					append(&opts, "MAXLEN", tp(rng_below(r, 60)))
				case 1:
					append(&opts, "MAXLEN", "~", tp(rng_below(r, 60)))
				case 2:
					append(&opts, "MAXLEN", "~", tp(rng_below(r, 60)), "LIMIT", tp(rng_below(r, 20)))
				case 3:
					append(&opts, "MINID", tp(s.ms - u64(rng_below(r, 20))))
				case 4:
					append(&opts, "MINID", "~", tp(s.ms - u64(rng_below(r, 20))))
				case 5:
					append(&opts, "NOMKSTREAM")
				}
			}
			xadd(g, key, idform, gen_fields(g, rng_chance(r, 70)), ..opts[:])
			append(&s.ids, [2]u64{s.ms, s.seq})
		case roll < 55:
			n := 1 + rng_below(r, 3)
			a := make([dynamic]string, context.temp_allocator)
			append(&a, "XDEL", key)
			for _ in 0 ..< n {
				if len(s.ids) > 0 && rng_chance(r, 80) {
					p := s.ids[rng_below(r, len(s.ids))]
					append(&a, tp(p[0], "-", p[1]))
				} else {
					append(&a, tp(rng_below(r, 1000), "-", rng_below(r, 3)))
				}
			}
			g_cmds(g, a[:])
		case roll < 62:
			switch rng_below(r, 5) {
			case 0:
				g_cmd(g, "XTRIM", key, "MAXLEN", tp(rng_below(r, 80)))
			case 1:
				g_cmd(g, "XTRIM", key, "MAXLEN", "~", tp(rng_below(r, 80)))
			case 2:
				g_cmd(g, "XTRIM", key, "MAXLEN", "~", tp(rng_below(r, 80)), "LIMIT", tp(rng_below(r, 30)))
			case 3:
				g_cmd(g, "XTRIM", key, "MINID", tp(s.ms - u64(rng_below(r, 30)), "-", rng_below(r, 3)))
			case 4:
				g_cmd(g, "XTRIM", key, "MINID", "~", tp(s.ms - u64(rng_below(r, 30))))
			}
		case roll < 80:
			lo := s.ms - u64(rng_below(r, 40))
			hi := lo + u64(rng_below(r, 40))
			sb := pick(r, {"-", tp(lo), tp("(", lo, "-", rng_below(r, 3)), tp(lo, "-", rng_below(r, 3))})
			eb := pick(r, {"+", tp(hi), tp("(", hi), tp(hi, "-", rng_below(r, 3))})
			if rng_chance(r, 50) {
				g_cmd(g, "XRANGE", key, sb, eb, "COUNT", tp(rng_below(r, 6)))
			} else if rng_chance(r, 50) {
				g_cmd(g, "XREVRANGE", key, eb, sb)
			} else {
				g_cmd(g, "XRANGE", key, sb, eb)
			}
		case roll < 87:
			k2 := keys[rng_below(r, len(keys))]
			g_cmd(g, "XREAD", "COUNT", tp(rng_below(r, 5)), "STREAMS", key, k2, tp(s.ms - u64(rng_below(r, 10))), pick(r, {"$", "+", "0"}))
		case roll < 93:
			if rng_chance(r, 30) {
				g_cmd(g, "XINFO", "STREAM", key, "FULL", "COUNT", tp(rng_below(r, 5)))
			} else {
				g_cmd(g, "XINFO", "STREAM", key)
			}
		case roll < 95:
			g_cmd(g, "XLEN", key)
		case roll < 96:
			if rng_chance(r, 20) {
				g_cmd(g, "DEL", key)
				s.used = false
				s.ms = 0
				s.seq = 0
				clear(&s.ids)
			}
		case:
			g_cmd(g, "DUMP", key)
		}
	}
	for k in keys {
		g_full(g, k)
	}
	config_nodes(g, "100", "4096")
}

section_config :: proc(g: ^Gen) {
	cases := [][]string {
		{"CONFIG", "GET", "stream-node-max-bytes"},
		{"CONFIG", "GET", "stream-node-max-entries"},
		{"CONFIG", "SET", "stream-node-max-entries", "-1"},
		{"CONFIG", "SET", "stream-node-max-entries", "abc"},
		{"CONFIG", "SET", "stream-node-max-entries", "9223372036854775807"},
		{"CONFIG", "GET", "stream-node-max-entries"},
		{"CONFIG", "SET", "stream-node-max-entries", "9223372036854775808"},
		{"CONFIG", "SET", "stream-node-max-bytes", "1x"},
		{"CONFIG", "SET", "stream-node-max-bytes", "-1"},
		{"CONFIG", "SET", "stream-node-max-bytes", "1kb"},
		{"CONFIG", "GET", "stream-node-max-bytes"},
		{"CONFIG", "SET", "stream-node-max-bytes", "2k"},
		{"CONFIG", "GET", "stream-node-max-bytes"},
		{"CONFIG", "SET", "stream-node-max-bytes", "1gb"},
		{"CONFIG", "GET", "stream-node-max-bytes"},
		{"CONFIG", "SET", "stream-node-max-bytes", "9223372036854775808"},
		{"CONFIG", "SET", "stream-node-max-bytes", "4096"},
		{"CONFIG", "SET", "stream-node-max-entries", "100"},
	}
	for c in cases {
		g_cmds(g, c)
	}
}


g_gstate :: proc(g: ^Gen, key: string) {
	g_cmd(g, "DUMP", key)
	g_cmd(g, "XINFO", "STREAM", key, "FULL")
	g_cmd(g, "XINFO", "GROUPS", key)
}

section_groups_basic :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	config_nodes(g, "100", "4096")
	g_cmd(g, "SET", "str", "x")
	for i in 1 ..= 6 {
		g_cmd(g, "XADD", "s", tp(i / 3 + 1, "-", i % 3), "f", tp(i))
	}
	cases := [][]string {
		{"XGROUP", "CREATE", "s", "g1", "0"},
		{"XGROUP", "CREATE", "s", "g1", "0"},
		{"XGROUP", "CREATE", "s", "g2", "$"},
		{"XGROUP", "CREATE", "s", "g3", "1-2", "ENTRIESREAD", "2"},
		{"XGROUP", "CREATE", "s", "g4", "0", "ENTRIESREAD", "-1"},
		{"XGROUP", "CREATE", "s", "g5", "0", "ENTRIESREAD", "-3"},
		{"XGROUP", "CREATE", "s", "g5", "0", "ENTRIESREAD", "abc"},
		{"XGROUP", "CREATE", "s", "g5", "0", "ENTRIESREAD"},
		{"XGROUP", "CREATE", "s", "g5", "0", "MKSTREAM", "ENTRIESREAD", "5"},
		{"XGROUP", "CREATE", "s", "g6", "abc"},
		{"XGROUP", "CREATE", "s", "g6", "-"},
		{"XGROUP", "CREATE", "s", "g6", "+"},
		{"XGROUP", "CREATE", "s", "g6", "5-*"},
		{"XGROUP", "CREATE", "s", "g6", "0", "FOO"},
		{"XGROUP", "CREATE", "s", "g6", "0", "MKSTREAM", "MKSTREAM", "ENTRIESREAD", "1"},
		{"XGROUP", "CREATE", "s", "g6", "$\x00x"},
		{"XGROUP", "CREATE", "nokey", "g", "0"},
		{"XGROUP", "CREATE", "nokey", "g", "$", "MKSTREAM"},
		{"XGROUP", "CREATE", "nokey", "g", "$", "MKSTREAM"},
		{"XGROUP", "CREATE", "str", "g", "0"},
		{"XGROUP", "CREATE", "str", "g", "0", "MKSTREAM"},
		{"XGROUP", "CREATE", "s", "1", "0"},
		{"XGROUP", "CREATE", "s", "", "0"},
		{"XGROUP", "CREATE", "s", "-5", "0"},
		{"XGROUP", "CREATE", "s", "12345678901", "0"},
		{"XGROUP", "CREATE", "s", "40000", "0"},
		{"XGROUP", "SETID", "s", "nog", "0"},
		{"XGROUP", "SETID", "nokey2", "g", "0"},
		{"XGROUP", "SETID", "s", "g1", "1-1"},
		{"XGROUP", "SETID", "s", "g1", "$"},
		{"XGROUP", "SETID", "s", "g2", "-"},
		{"XGROUP", "SETID", "s", "g3", "+", "ENTRIESREAD", "3"},
		{"XGROUP", "SETID", "s", "g3", "abc"},
		{"XGROUP", "SETID", "s", "g3", "5-*"},
		{"XGROUP", "SETID", "s", "g3", "0", "MKSTREAM"},
		{"XGROUP", "SETID", "s", "g3", "0", "ENTRIESREAD"},
		{"XGROUP", "SETID", "s", "g3", "0", "ENTRIESREAD", "1", "x"},
		{"XGROUP", "SETID", "s", "g3", "0", "ENTRIESREAD", "-2"},
		{"XGROUP", "SETID", "s", "g3", "1", "ENTRIESREAD", "1"},
		{"XGROUP", "DESTROY", "s", "nog"},
		{"XGROUP", "DESTROY", "s", "g4"},
		{"XGROUP", "DESTROY", "nokey2", "g"},
		{"XGROUP", "DESTROY", "str", "g"},
		{"XGROUP", "DESTROY", "s"},
		{"XGROUP", "DESTROY", "s", "g4", "x"},
		{"XGROUP", "CREATECONSUMER", "s", "g1", "alice"},
		{"XGROUP", "CREATECONSUMER", "s", "g1", "alice"},
		{"XGROUP", "CREATECONSUMER", "s", "nog", "alice"},
		{"XGROUP", "CREATECONSUMER", "s", "g1", ""},
		{"XGROUP", "CREATECONSUMER", "s", "g1", "42"},
		{"XGROUP", "CREATECONSUMER", "s", "g1"},
		{"XGROUP", "DELCONSUMER", "s", "g1", "alice"},
		{"XGROUP", "DELCONSUMER", "s", "g1", "nobody"},
		{"XGROUP", "DELCONSUMER", "s", "nog", "x"},
		{"XGROUP", "DELCONSUMER", "nokey2", "g", "x"},
		{"XGROUP", "HELP"},
		{"XGROUP", "help", "x"},
		{"XGROUP"},
		{"XGROUP", "FOO"},
		{"XGROUP", "FOO", "s", "g", "0"},
		{"XGROUP", "CREATE", "s", "g"},
		{"XGROUP", "SETID", "s", "g1"},
		{"XINFO", "GROUPS", "s"},
		{"XINFO", "CONSUMERS", "s", "g1"},
		{"XINFO", "CONSUMERS", "s", "nog"},
		{"XINFO", "STREAM", "s"},
		{"XINFO", "STREAM", "nokey"},
	}
	for c in cases {
		g_cmds(g, c)
	}
	g_gstate(g, "s")
	g_gstate(g, "nokey")
}

section_readgroup :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	config_nodes(g, "4", "4096")
	g_cmd(g, "SET", "str", "x")
	for i in 1 ..= 12 {
		if i % 4 == 0 {
			g_cmd(g, "XADD", "q", tp(i), "item", tp(i), "other", "x")
		} else {
			g_cmd(g, "XADD", "q", tp(i), "item", tp(i))
		}
	}
	g_cmd(g, "XGROUP", "CREATE", "q", "g", "0")
	g_cmd(g, "XGROUP", "CREATE", "q", "h", "$")
	g_cmd(g, "XADD", "r", "1-1", "x", "y")
	g_cmd(g, "XADD", "r", "1-2", "x", "z")
	g_cmd(g, "XGROUP", "CREATE", "r", "g", "0")
	cases := [][]string {
		{"XREADGROUP", "GROUP", "g", "c1", "COUNT", "2", "STREAMS", "q", ">"},
		{"XREADGROUP", "GROUP", "g", "c2", "COUNT", "3", "STREAMS", "q", ">"},
		{"XREADGROUP", "GROUP", "g", "c1", "STREAMS", "q", "0"},
		{"XREADGROUP", "GROUP", "g", "c1", "COUNT", "1", "STREAMS", "q", "0"},
		{"XREADGROUP", "GROUP", "g", "c1", "STREAMS", "q", "1-0"},
		{"XREADGROUP", "GROUP", "g", "c2", "STREAMS", "q", "9999"},
		{"XREADGROUP", "GROUP", "g", "c3", "STREAMS", "q", "0"},
		{"XREADGROUP", "GROUP", "g", "c1", "NOACK", "COUNT", "2", "STREAMS", "q", ">"},
		{"XREADGROUP", "GROUP", "g", "c1", "STREAMS", "q", "r", ">", ">"},
		{"XREADGROUP", "GROUP", "g", "c1", "STREAMS", "q", ">"},
		{"XREADGROUP", "GROUP", "g", "c1", "BLOCK", "1", "STREAMS", "q", ">"},
		{"XADD", "q", "13", "item", "13"},
		{"XADD", "q", "14", "item", "14"},
		{"XREADGROUP", "GROUP", "g", "c1", "BLOCK", "100", "STREAMS", "q", ">"},
		{"XREADGROUP", "GROUP", "g", "c1", "BLOCK", "0", "STREAMS", "q", "0"},
		{"XREADGROUP", "GROUP", "h", "c9", "STREAMS", "q", "q", ">", ">"},
		{"XREADGROUP", "GROUP", "g", "c1", "STREAMS", "q", "r", "0", "0"},
		{"XDEL", "q", "3"},
		{"XREADGROUP", "GROUP", "g", "c2", "STREAMS", "q", "0"},
		{"XTRIM", "q", "MAXLEN", "6"},
		{"XREADGROUP", "GROUP", "g", "c1", "COUNT", "5", "STREAMS", "q", "0"},
		{"XREADGROUP", "GROUP", "g", "c2", "STREAMS", "q", "0"},
		{"XREADGROUP", "GROUP", "g", "c1", "STREAMS", "q", "$"},
		{"XREADGROUP", "GROUP", "g", "c1", "STREAMS", "q", "+"},
		{"XREADGROUP", "GROUP", "g", "c1", "STREAMS", "nokey", ">"},
		{"XREADGROUP", "GROUP", "nog", "c1", "STREAMS", "q", ">"},
		{"XREADGROUP", "GROUP", "g", "c1", "STREAMS", "q", "nokey", ">", ">"},
		{"XREADGROUP", "GROUP", "g", "c1", "STREAMS", "str", ">"},
		{"XREADGROUP", "GROUP", "g", "c1", "STREAMS", "q", "abc"},
		{"XREADGROUP", "GROUP", "g", "c1", "STREAMS", "q", "(1"},
		{"XREADGROUP", "COUNT", "1", "STREAMS", "q", ">"},
		{"XREADGROUP", "COUNT", "1", "NOACK", "STREAMS", "q", ">"},
		{"XREADGROUP", "GROUP", "g", "c1", "STREAMS", "q"},
		{"XREADGROUP", "GROUP", "g", "c1", "COUNT", "1", "STREAMS", "q"},
		{"XREADGROUP", "GROUP", "g", "c1", "COUNT", "x", "STREAMS", "q", ">"},
		{"XREADGROUP", "GROUP", "g", "c1", "BLOCK", "-1", "STREAMS", "q", ">"},
		{"XREADGROUP", "GROUP", "g", "c1", "BLOCK", "x", "STREAMS", "q", ">"},
		{"XREADGROUP", "GROUP", "g", "STREAMS", "q", ">"},
		{"XREADGROUP", "NOACK", "GROUP", "g", "c4", "STREAMS", "q", ">"},
		{"XREADGROUP", "GROUP", "g", "c5", "GROUP", "h", "c6", "STREAMS", "q", "0"},
		{"XREADGROUP", "GROUP", "g", "c1", "FOO", "STREAMS", "q", ">"},
		{"XREAD", "GROUP", "g", "c1", "STREAMS", "q", ">"},
		{"XREAD", "STREAMS", "q", ">"},
		{"XREAD", "BLOCK", "1", "STREAMS", "q", "$"},
		{"XREAD", "BLOCK", "1", "STREAMS", "nokey", "+"},
		{"XREAD", "COUNT", "2", "BLOCK", "5", "STREAMS", "q", "0"},
		{"XGROUP", "SETID", "q", "g", "0"},
		{"XREADGROUP", "GROUP", "g", "c7", "COUNT", "3", "STREAMS", "q", ">"},
		{"XGROUP", "SETID", "q", "g", "5", "ENTRIESREAD", "2"},
		{"XREADGROUP", "GROUP", "g", "c7", "COUNT", "2", "STREAMS", "q", ">"},
		{"XPENDING", "q", "g"},
		{"XPENDING", "q", "g", "-", "+", "100"},
		{"XINFO", "CONSUMERS", "q", "g"},
		{"XINFO", "GROUPS", "q"},
	}
	for c in cases {
		g_cmds(g, c)
	}
	g_gstate(g, "q")
	g_gstate(g, "r")
	config_nodes(g, "100", "4096")
}

section_pending_claim :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "SET", "str", "x")
	for i in 1 ..= 9 {
		g_cmd(g, "XADD", "p", tp(i), "f", tp(i))
	}
	g_cmd(g, "XGROUP", "CREATE", "p", "g", "0")
	g_cmd(g, "XREADGROUP", "GROUP", "g", "alice", "COUNT", "3", "STREAMS", "p", ">")
	g_cmd(g, "XREADGROUP", "GROUP", "g", "bob", "COUNT", "3", "STREAMS", "p", ">")
	pending := [][]string {
		{"XPENDING", "p", "g"},
		{"XPENDING", "p", "g", "-", "+", "10"},
		{"XPENDING", "p", "g", "-", "+", "10", "alice"},
		{"XPENDING", "p", "g", "-", "+", "10", "nobody"},
		{"XPENDING", "p", "g", "2", "5", "10"},
		{"XPENDING", "p", "g", "(2", "(5", "10"},
		{"XPENDING", "p", "g", "-", "+", "0"},
		{"XPENDING", "p", "g", "-", "+", "-1"},
		{"XPENDING", "p", "g", "-", "+", "2"},
		{"XPENDING", "p", "g", "-", "+", "abc"},
		{"XPENDING", "p", "g", "abc", "+", "10"},
		{"XPENDING", "p", "g", "-", "abc", "10"},
		{"XPENDING", "p", "g", "(" + MAXU + "-" + MAXU, "+", "10"},
		{"XPENDING", "p", "g", "-", "(0-0", "10"},
		{"XPENDING", "p", "g", "IDLE", "0", "-", "+", "10"},
		{"XPENDING", "p", "g", "IDLE", "99999999", "-", "+", "10"},
		{"XPENDING", "p", "g", "IDLE", "99999999", "-", "+", "10", "alice"},
		{"XPENDING", "p", "g", "IDLE", "abc", "-", "+", "10"},
		{"XPENDING", "p", "g", "IDLE", "10", "-", "+"},
		{"XPENDING", "p", "g", "-", "+"},
		{"XPENDING", "p", "g", "-"},
		{"XPENDING", "p", "g", "-", "+", "10", "alice", "extra"},
		{"XPENDING", "p", "g", "IDLE", "0", "-", "+", "10", "alice", "extra"},
		{"XPENDING", "p", "nog"},
		{"XPENDING", "p", "nog", "-", "+", "10"},
		{"XPENDING", "nokey", "g"},
		{"XPENDING", "str", "g"},
		{"XPENDING", "str", "g", "-", "+", "x"},
	}
	for c in pending {
		g_cmds(g, c)
	}
	g_cmd(g, "__SLEEP__", "300")
	g_cmd(g, "XPENDING", "p", "g", "IDLE", "200", "-", "+", "10")
	g_cmd(g, "XREADGROUP", "GROUP", "g", "carol", "COUNT", "1", "STREAMS", "p", ">")
	g_cmd(g, "XPENDING", "p", "g", "IDLE", "200", "-", "+", "10")
	claims := [][]string {
		{"XCLAIM", "p", "g", "dave", "200", "1-0", "2-0", "7-0"},
		{"XCLAIM", "p", "g", "dave", "0", "3-0", "JUSTID"},
		{"XCLAIM", "p", "g", "dave", "0", "4-0", "IDLE", "5000", "RETRYCOUNT", "9"},
		{"XCLAIM", "p", "g", "dave", "0", "5-0", "TIME", "1000"},
		{"XCLAIM", "p", "g", "dave", "0", "6-0", "TIME", "99999999999999"},
		{"XCLAIM", "p", "g", "dave", "0", "6-0", "IDLE", "-5"},
		{"XCLAIM", "p", "g", "dave", "0", "8-0", "FORCE"},
		{"XCLAIM", "p", "g", "dave", "0", "9-0", "FORCE", "JUSTID"},
		{"XCLAIM", "p", "g", "dave", "0", "99-0", "FORCE"},
		{"XCLAIM", "p", "g", "dave", "0", "1-0", "LASTID", "50-0"},
		{"XCLAIM", "p", "g", "dave", "0", "1-0", "LASTID", "abc"},
		{"XCLAIM", "p", "g", "dave", "0", "1-0", "IDLE", "abc"},
		{"XCLAIM", "p", "g", "dave", "0", "1-0", "TIME", "x"},
		{"XCLAIM", "p", "g", "dave", "0", "1-0", "RETRYCOUNT", "x"},
		{"XCLAIM", "p", "g", "dave", "0", "1-0", "RETRYCOUNT", "-3"},
		{"XCLAIM", "p", "g", "dave", "0", "1-0", "FOO"},
		{"XCLAIM", "p", "g", "dave", "0", "1-0", "IDLE"},
		{"XCLAIM", "p", "g", "dave", "abc", "1-0"},
		{"XCLAIM", "p", "g", "dave", "-5", "1-0"},
		{"XCLAIM", "p", "g", "dave", "0", "abc"},
		{"XCLAIM", "p", "g", "dave", "0", "a\r\nb"},
		{"XCLAIM", "p", "g", "dave", "0", "1-0", "1-0"},
		{"XCLAIM", "p", "g", "erin", "0", "1-0", "1-0", "JUSTID"},
		{"XCLAIM", "p", "nog", "x", "0", "1-0"},
		{"XCLAIM", "nokey", "g", "x", "0", "1-0"},
		{"XCLAIM", "str", "g", "x", "0", "1-0"},
		{"XCLAIM", "p", "g", "dave", "99999999", "1-0", "2-0", "3-0"},
		{"XDEL", "p", "2-0"},
		{"XCLAIM", "p", "g", "erin", "0", "2-0", "3-0"},
		{"XPENDING", "p", "g", "-", "+", "20"},
		{"XPENDING", "p", "g"},
		{"XAUTOCLAIM", "p", "g", "frank", "0", "-", "COUNT", "2"},
		{"XAUTOCLAIM", "p", "g", "frank", "0", "5", "COUNT", "2", "JUSTID"},
		{"XAUTOCLAIM", "p", "g", "frank", "99999999", "-"},
		{"XAUTOCLAIM", "p", "g", "frank", "0", "(1-0"},
		{"XAUTOCLAIM", "p", "g", "frank", "0", "(" + MAXU + "-" + MAXU},
		{"XAUTOCLAIM", "p", "g", "frank", "0", "-", "COUNT", "0"},
		{"XAUTOCLAIM", "p", "g", "frank", "0", "-", "COUNT", "abc"},
		{"XAUTOCLAIM", "p", "g", "frank", "0", "-", "COUNT", "576460752303423488"},
		{"XAUTOCLAIM", "p", "g", "frank", "0", "-", "COUNT"},
		{"XAUTOCLAIM", "p", "g", "frank", "0", "-", "FOO"},
		{"XAUTOCLAIM", "p", "g", "frank", "abc", "-"},
		{"XAUTOCLAIM", "p", "g", "frank", "0", "abc"},
		{"XAUTOCLAIM", "p", "nog", "frank", "0", "-"},
		{"XAUTOCLAIM", "nokey", "g", "frank", "0", "-"},
		{"XAUTOCLAIM", "str", "g", "frank", "0", "-"},
		{"XAUTOCLAIM", "str", "g", "frank", "x", "-"},
		{"XDEL", "p", "4-0", "6-0"},
		{"XAUTOCLAIM", "p", "g", "gina", "0", "-", "COUNT", "1"},
		{"XAUTOCLAIM", "p", "g", "gina", "0", "-", "COUNT", "100000"},
		{"XAUTOCLAIM", "p", "g", "gina", "0", "0", "JUSTID"},
		{"XACK", "p", "g", "1-0", "3-0", "99-0"},
		{"XACK", "p", "g", "1-0"},
		{"XACK", "p", "g", "abc"},
		{"XACK", "p", "g", "5-0", "abc"},
		{"XACK", "p", "nog", "1-0"},
		{"XACK", "p", "nog", "abc"},
		{"XACK", "nokey", "g", "1-0"},
		{"XACK", "str", "g", "1-0"},
		{"XACK", "p", "g"},
		{"XINFO", "CONSUMERS", "p", "g"},
		{"XINFO", "STREAM", "p", "FULL"},
		{"XINFO", "STREAM", "p", "FULL", "COUNT", "1"},
		{"XINFO", "STREAM", "p", "FULL", "COUNT", "0"},
	}
	for c in claims {
		g_cmds(g, c)
	}
	g_gstate(g, "p")
	g_cmd(g, "__SLEEP__", "300")
	g_cmd(g, "XAUTOCLAIM", "p", "g", "hank", "200", "-", "COUNT", "3")
	g_cmd(g, "XCLAIM", "p", "g", "ivan", "200", "1-0", "5-0", "7-0", "8-0", "9-0")
	g_cmd(g, "XPENDING", "p", "g", "IDLE", "200", "-", "+", "10")
	g_cmd(g, "XGROUP", "DELCONSUMER", "p", "g", "dave")
	g_cmd(g, "XGROUP", "DELCONSUMER", "p", "g", "frank")
	g_gstate(g, "p")
	g_cmd(g, "XGROUP", "DESTROY", "p", "g")
	g_gstate(g, "p")
}

section_lag :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	info :: proc(g: ^Gen) {
		g_cmd(g, "XINFO", "GROUPS", "x")
		g_cmd(g, "XINFO", "STREAM", "x", "FULL")
	}
	g_cmd(g, "XGROUP", "CREATE", "x", "g1", "0", "MKSTREAM")
	info(g)
	g_cmd(g, "XADD", "x", "1-0", "data", "a")
	g_cmd(g, "XDEL", "x", "1-0")
	info(g)
	g_cmd(g, "DEL", "x")
	for i in 1 ..= 5 {
		g_cmd(g, "XADD", "x", tp(i, "-0"), "data", tp(i))
	}
	g_cmd(g, "XGROUP", "CREATE", "x", "g1", "0")
	info(g)
	g_cmd(g, "XREADGROUP", "GROUP", "g1", "c11", "COUNT", "1", "STREAMS", "x", ">")
	info(g)
	g_cmd(g, "XREADGROUP", "GROUP", "g1", "c12", "COUNT", "10", "STREAMS", "x", ">")
	info(g)
	g_cmd(g, "XADD", "x", "6-0", "data", "f")
	info(g)
	g_cmd(g, "DEL", "x")
	for i in 1 ..= 5 {
		g_cmd(g, "XADD", "x", tp(i, "-0"), "data", tp(i))
	}
	g_cmd(g, "XDEL", "x", "3-0")
	g_cmd(g, "XGROUP", "CREATE", "x", "g1", "0")
	g_cmd(g, "XGROUP", "CREATE", "x", "g2", "0")
	info(g)
	for _ in 0 ..< 4 {
		g_cmd(g, "XREADGROUP", "GROUP", "g1", "c11", "COUNT", "1", "STREAMS", "x", ">")
		info(g)
	}
	g_cmd(g, "XADD", "x", "6-0", "data", "f")
	info(g)
	g_cmd(g, "XTRIM", "x", "MINID", "=", "3-0")
	info(g)
	g_cmd(g, "XTRIM", "x", "MINID", "=", "5-0")
	info(g)
	g_cmd(g, "DEL", "x")
	g_cmd(g, "XGROUP", "CREATE", "x", "g1", "$", "MKSTREAM")
	g_cmd(g, "XADD", "x", "1-0", "data", "a")
	g_cmd(g, "XREADGROUP", "GROUP", "g1", "alice", "STREAMS", "x", ">")
	g_cmd(g, "XADD", "x", "2-0", "data", "c")
	g_cmd(g, "XADD", "x", "3-0", "data", "d")
	g_cmd(g, "XDEL", "x", "2-0")
	info(g)
	g_cmd(g, "XDEL", "x", "1-0")
	info(g)
	g_cmd(g, "XREADGROUP", "GROUP", "g1", "alice", "STREAMS", "x", ">")
	info(g)
	g_cmd(g, "DEL", "x")
	g_cmd(g, "XGROUP", "CREATE", "x", "mygroup", "$", "MKSTREAM")
	for i in 1 ..= 5 {
		g_cmd(g, "XADD", "x", tp(i, "-0"), "data", tp(i))
	}
	g_cmd(g, "XREADGROUP", "GROUP", "mygroup", "alice", "COUNT", "1", "STREAMS", "x", ">")
	info(g)
	g_cmd(g, "XTRIM", "x", "MAXLEN", "1")
	info(g)
	g_cmd(g, "XREADGROUP", "GROUP", "mygroup", "alice", "STREAMS", "x", ">")
	info(g)
	g_cmd(g, "XADD", "x", "6-0", "data", "f")
	info(g)
	g_cmd(g, "XTRIM", "x", "MAXLEN", "0")
	info(g)
	g_cmd(g, "XGROUP", "SETID", "x", "mygroup", "0", "ENTRIESREAD", "0")
	info(g)
	g_cmd(g, "XSETID", "x", "9-0", "ENTRIESADDED", "20", "MAXDELETEDID", "8-0")
	info(g)
	g_cmd(g, "XADD", "x", "10-0", "data", "z")
	g_cmd(g, "XGROUP", "SETID", "x", "mygroup", "2-0")
	info(g)
	g_cmd(g, "XGROUP", "CREATE", "x", "g9", "9-0", "ENTRIESREAD", "19")
	g_cmd(g, "XGROUP", "CREATE", "x", "g10", "10-0")
	g_cmd(g, "XGROUP", "CREATE", "x", "g11", "11-0")
	info(g)
	g_gstate(g, "x")
}

section_group_copy :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	config_nodes(g, "3", "4096")
	g_cmd(g, "XADD", "x", "100", "a", "1")
	g_cmd(g, "XADD", "x", "101", "b", "1")
	g_cmd(g, "XADD", "x", "102", "c", "1")
	g_cmd(g, "XADD", "x", "103", "e", "1")
	g_cmd(g, "XADD", "x", "104", "f", "1")
	g_cmd(g, "XADD", "x", "105", "g", "1")
	g_cmd(g, "XGROUP", "CREATE", "x", "g1", "0")
	g_cmd(g, "XGROUP", "CREATE", "x", "g2", "0")
	g_cmd(g, "XREADGROUP", "GROUP", "g1", "Alice", "COUNT", "1", "STREAMS", "x", ">")
	g_cmd(g, "XREADGROUP", "GROUP", "g1", "Bob", "COUNT", "1", "STREAMS", "x", ">")
	g_cmd(g, "XREADGROUP", "GROUP", "g1", "Bob", "NOACK", "COUNT", "1", "STREAMS", "x", ">")
	g_cmd(g, "XREADGROUP", "GROUP", "g2", "Charlie", "COUNT", "4", "STREAMS", "x", ">")
	g_cmd(g, "XAUTOCLAIM", "x", "g1", "Alice", "0", "0-0", "COUNT", "1")
	g_cmd(g, "XGROUP", "CREATECONSUMER", "x", "g1", "Dave")
	g_cmd(g, "XDEL", "x", "101")
	g_cmd(g, "COPY", "x", "newx")
	g_gstate(g, "x")
	g_gstate(g, "newx")
	g_cmd(g, "XACK", "newx", "g2", "100", "101")
	g_cmd(g, "XGROUP", "DESTROY", "newx", "g1")
	g_gstate(g, "x")
	g_gstate(g, "newx")
	g_cmd(g, "DEL", "x")
	g_gstate(g, "newx")
	g_cmd(g, "RENAME", "newx", "x")
	g_gstate(g, "x")
	config_nodes(g, "100", "4096")
}

section_group_fuzz :: proc(g: ^Gen, ops: int) {
	g_cmd(g, "FLUSHALL")
	r := &g.rng
	keys := [?]string{"fg:a", "fg:b"}
	groups := [?]string{"g1", "g2", "g3"}
	consumers := [?]string{"alice", "bob", "carol", "dave", ""}
	next := [len(keys)]int{1, 1}
	for k in keys {
		g_cmd(g, "XGROUP", "CREATE", k, "g1", "$", "MKSTREAM")
		g_cmd(g, "XGROUP", "CREATE", k, "g2", "0")
	}
	for op in 0 ..< ops {
		if op % 500 == 0 {
			config_nodes(g, pick(r, {"2", "5", "100"}), "4096")
		}
		ki := rng_below(r, len(keys))
		key := keys[ki]
		grp := groups[rng_below(r, len(groups))]
		cons := consumers[rng_below(r, len(consumers))]
		rid :: proc(r: ^Rng, hi: int) -> string {
			return tp(1 + rng_below(r, max(hi, 1)), "-", rng_below(r, 2))
		}
		roll := rng_below(r, 100)
		switch {
		case roll < 30:
			n := 1 + rng_below(r, 3)
			for _ in 0 ..< n {
				next[ki] += 1 + rng_below(r, 2)
				xadd(g, key, tp(next[ki], "-", rng_below(r, 2)), gen_fields(g, rng_chance(r, 80)))
			}
		case roll < 50:
			a := make([dynamic]string, context.temp_allocator)
			append(&a, "XREADGROUP", "GROUP", grp, cons)
			if rng_chance(r, 50) {
				append(&a, "COUNT", tp(rng_below(r, 4)))
			}
			if rng_chance(r, 15) {
				append(&a, "NOACK")
			}
			append(&a, "STREAMS", key, pick(r, {">", ">", ">", "0", rid(r, next[ki])}))
			g_cmds(g, a[:])
		case roll < 58:
			g_cmd(g, "XACK", key, grp, rid(r, next[ki]), rid(r, next[ki]))
		case roll < 65:
			a := make([dynamic]string, context.temp_allocator)
			append(&a, "XCLAIM", key, grp, cons, "0", rid(r, next[ki]), rid(r, next[ki]))
			switch rng_below(r, 5) {
			case 0:
				append(&a, "JUSTID")
			case 1:
				append(&a, "FORCE")
			case 2:
				append(&a, "RETRYCOUNT", tp(rng_below(r, 5)))
			case 3:
				append(&a, "LASTID", rid(r, next[ki]))
			}
			g_cmds(g, a[:])
		case roll < 71:
			a := make([dynamic]string, context.temp_allocator)
			append(&a, "XAUTOCLAIM", key, grp, cons, "0", pick(r, {"-", "0", rid(r, next[ki])}), "COUNT", tp(1 + rng_below(r, 5)))
			if rng_chance(r, 30) {
				append(&a, "JUSTID")
			}
			g_cmds(g, a[:])
		case roll < 75:
			g_cmd(g, "XDEL", key, rid(r, next[ki]), rid(r, next[ki]))
		case roll < 77:
			g_cmd(g, "XTRIM", key, "MAXLEN", pick(r, {"~", "="}), tp(rng_below(r, 30)))
		case roll < 80:
			switch rng_below(r, 4) {
			case 0:
				g_cmd(g, "XGROUP", "SETID", key, grp, pick(r, {"0", "$", rid(r, next[ki])}))
			case 1:
				g_cmd(g, "XGROUP", "CREATECONSUMER", key, grp, cons)
			case 2:
				g_cmd(g, "XGROUP", "DELCONSUMER", key, grp, cons)
			case 3:
				if rng_chance(r, 30) {
					g_cmd(g, "XGROUP", "DESTROY", key, grp)
				} else {
					g_cmd(g, "XGROUP", "CREATE", key, grp, pick(r, {"0", "$", rid(r, next[ki])}))
				}
			}
		case roll < 87:
			switch rng_below(r, 4) {
			case 0:
				g_cmd(g, "XPENDING", key, grp)
			case 1:
				g_cmd(g, "XPENDING", key, grp, "-", "+", tp(rng_below(r, 8)))
			case 2:
				g_cmd(g, "XPENDING", key, grp, "-", "+", "20", cons)
			case 3:
				g_cmd(g, "XPENDING", key, grp, "IDLE", "0", rid(r, next[ki]), "+", "5")
			}
		case roll < 93:
			switch rng_below(r, 3) {
			case 0:
				g_cmd(g, "XINFO", "GROUPS", key)
			case 1:
				g_cmd(g, "XINFO", "CONSUMERS", key, grp)
			case 2:
				g_cmd(g, "XINFO", "STREAM", key, "FULL", "COUNT", tp(rng_below(r, 4)))
			}
		case:
			g_cmd(g, "DUMP", key)
		}
	}
	for k in keys {
		g_gstate(g, k)
		g_cmd(g, "XRANGE", k, "-", "+")
	}
	config_nodes(g, "100", "4096")
}

unhex :: proc(text: string) -> string {
	out := make([]u8, len(text) / 2, context.temp_allocator)
	for i in 0 ..< len(out) {
		hi, lo := text[2 * i], text[2 * i + 1]
		hv := hi - '0' if hi <= '9' else hi - 'a' + 10
		lv := lo - '0' if lo <= '9' else lo - 'a' + 10
		out[i] = hv << 4 | lv
	}
	return string(out)
}

ENTRIES_ADDED_AT_MAX :: "150110000000000000000100000000000000011d1d0000000a0001010001010181660200010201000100018176020401ff0105000101000081ffffffffffffffff010167000081ffffffffffffffff00000c008cb73a1e17e1f3b6"

LENGTH_WITHOUT_NODES :: "15000101010000010101000c00730d14ed424d6af5"

section_parity :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	config_nodes(g, "100", "4096")
	g_cmd(g, "XGROUP", "CREATE", "nokey", "g", "badid")
	g_cmd(g, "XGROUP", "SETID", "nokey", "g", "badid")
	g_cmd(g, "XGROUP", "CREATE", "nokey", "g", "badid", "MKSTREAM")
	g_cmd(g, "XGROUP", "CREATE", "nokey", "g", "0", "ENTRIESREAD", "x")
	g_cmd(g, "XCLAIM", "nokey", "g", "c", "notanumber", "0-1")
	g_cmd(g, "XCLAIM", "nokey", "g", "c", "0", "1-1", "BOGUS")
	g_cmd(g, "XADD", "p", "1-1", "f", "v")
	g_cmd(g, "XGROUP", "SETID", "p", "nogroup", "badid")
	g_cmd(g, "XGROUP", "SETID", "p", "nogroup", "0", "ENTRIESREAD", "x")
	g_cmd(g, "XGROUP", "CREATECONSUMER", "p", "nogroup", "c")
	g_cmd(g, "XCLAIM", "p", "nogroup", "c", "notanumber", "0-1")
	g_cmd(g, "XCLAIM", "p", "nogroup", "c", "0", "badid")
	g_cmd(g, "XCLAIM", "p", "nogroup", "c", "0", "1-1", "IDLE", "x")
	g_cmd(g, "XAUTOCLAIM", "p", "nogroup", "c", "notanumber", "0")
	g_cmd(g, "XGROUP", "CREATE", "p", "g", "badid")
	g_cmd(g, "XGROUP", "CREATE", "p", "g", "0")
	g_cmd(g, "XGROUP", "CREATE", "p", "g", "badid")
	g_cmd(g, "XCLAIM", "p", "g", "c", "notanumber", "0-1")
	g_cmd(g, "XCLAIM", "p", "g", "c", "0", "badid")
	g_cmd(g, "XCLAIM", "p", "g", "c", "0", "1-1", "IDLE", "x")
	g_cmd(g, "XCLAIM", "p", "g", "c", "0", "1-1", "LASTID", "x")
	g_cmd(g, "XREADGROUP", "GROUP", "g", "c", "STREAMS", "p", ">")
	for form in ([?][]string{{"IDLE", "abc", "-", "+"}, {"bad", "+", "abc"}, {"bad", "+", "10"}, {"-", "bad", "abc"}, {"IDLE", "10", "bad", "+", "abc"}, {"IDLE", "10", "-", "+"}, {"IDLE", "abc"}, {"bad", "+", "abc", "c", "extra"}, {"(18446744073709551615-18446744073709551615", "+", "abc"}, {"-", "(0-0", "abc"}, {"x", "-", "+"}, {"x", "-", "+", "10"}, {"-", "+", "10", "c", "extra"}}) {
		a := make([dynamic]string, context.temp_allocator)
		append(&a, "XPENDING", "p", "g")
		append(&a, ..form)
		g_cmds(g, a[:])
	}
	g_cmd(g, "XPENDING", "nokey", "g", "IDLE", "abc", "-", "+")
	for i in 2 ..= 6 {
		g_cmd(g, "XADD", "p", tp(i, "-1"), "f", "v")
	}
	g_cmd(g, "XREADGROUP", "GROUP", "g", "c", "STREAMS", "p", ">")
	g_cmd(g, "XCLAIM", "p", "g", "c2", "0", "2-1", "TIME", "-5", "JUSTID")
	g_cmd(g, "XCLAIM", "p", "g", "c2", "0", "3-1", "IDLE", "9999999999999", "JUSTID")
	g_cmd(g, "XCLAIM", "p", "g", "c2", "0", "4-1", "TIME", "9999999999999", "JUSTID")
	g_cmd(g, "XPENDING", "p", "g", "-", "+", "10")
	g_cmd(g, "XPENDING", "p", "g", "IDLE", "1000000", "-", "+", "10")
	watched := [?][]string{{"XSETID", "p", "100-1"}, {"XACK", "p", "g", "1-1"}, {"XCLAIM", "p", "g", "c3", "0", "5-1"}, {"XAUTOCLAIM", "p", "g", "c4", "0", "0"}, {"XGROUP", "CREATECONSUMER", "p", "g", "c9"}, {"XGROUP", "SETID", "p", "g", "0"}, {"XREADGROUP", "GROUP", "g", "c5", "STREAMS", "p", ">"}, {"XGROUP", "CREATE", "p", "g2", "0"}, {"XGROUP", "DELCONSUMER", "p", "g", "c9"}, {"XGROUP", "DESTROY", "p", "g2"}, {"XTRIM", "p", "MAXLEN", "1000"}, {"XGROUP", "CREATE", "fresh", "g", "0", "MKSTREAM"}, {"XDEL", "p", "6-1"}}
	for command in watched {
		g_cmd(g, "WATCH", "p", "fresh")
		g_cmds(g, command)
		g_cmd(g, "MULTI")
		g_cmd(g, "PING")
		g_cmd(g, "EXEC")
	}
	g_cmd(g, "DEL", "s")
	for i in 1 ..= 10 {
		g_cmd(g, "XADD", "s", tp(i, "-1"), "f", "v")
	}
	for form in ([?][]string{{"MAXLEN", "5", "LIMIT", "0"}, {"MAXLEN", "=", "5", "LIMIT", "0"}, {"LIMIT", "0", "MAXLEN", "5"}, {"MAXLEN", "~", "5", "LIMIT", "0", "MAXLEN", "5"}, {"MAXLEN", "9", "MAXLEN", "8"}, {"MAXLEN", "9", "MAXLEN", "9"}, {"MINID", "0", "MAXLEN", "abc"}, {"MINID", "0", "MINID", "3"}, {"MAXLEN", "3", "MAXLEN", "~"}, {"MAXLEN", "3", "MAXLEN"}, {"MAXLEN", "9", "LIMIT", "0", "MAXLEN", "8"}, {"MAXLEN", "9", "MAXLEN", "8", "bogus"}, {"MAXLEN", "abc", "MINID", "0"}, {"MINID", "bad", "MINID", "3"}, {"LIMIT", "0"}, {"LIMIT", "5"}, {"MAXLEN", "5", "LIMIT", "-1"}, {"LIMIT", "0", "MAXLEN", "~", "5"}}) {
		a := make([dynamic]string, context.temp_allocator)
		append(&a, "XTRIM", "s")
		append(&a, ..form)
		g_cmds(g, a[:])
	}
	g_cmd(g, "XADD", "s", "MAXLEN", "5", "LIMIT", "0", "*", "f", "v")
	g_cmd(g, "XADD", "s", "MINID", "3", "LIMIT", "0", "100-1", "f", "v")
	g_cmd(g, "XADD", "s", "MAXLEN", "6", "MAXLEN", "5", "*", "f", "v")
	g_cmd(g, "XADD", "s", "LIMIT", "0", "*", "f", "v")
	g_cmd(g, "XADD", "s", "NOMKSTREAM", "MAXLEN", "6", "NOMKSTREAM", "MAXLEN", "5", "*", "f", "v")
	g_cmd(g, "XADD", "s", "MAXLEN", "6", "LIMIT", "0")
	g_cmd(g, "XADD", "s", "MAXLEN", "~", "6", "LIMIT", "0", "101-1", "f", "v")
	g_cmd(g, "XTRIM", "nokey", "MAXLEN", "5", "LIMIT", "0")
	g_state(g, "s")
	for n in 126 ..= 129 {
		long := tp("(", rep('0', n - 3), "1-1")
		g_cmd(g, "XRANGE", "s", long, "+")
		g_cmd(g, "XRANGE", "s", "-", long)
		g_cmd(g, "XREVRANGE", "s", long, "-")
		g_cmd(g, "XPENDING", "p", "g", long, "+", "10")
		g_cmd(g, "XAUTOCLAIM", "p", "g", "c", "0", long, "COUNT", "1")
	}
	g_cmd(g, "DEL", "t")
	config_nodes(g, "4", "4096")
	for id in ([?]string{"1-1", "2-1", "3-1", "4-1", "11-1", "12-1", "13-1"}) {
		g_cmd(g, "XADD", "t", id, "f", "v")
	}
	g_cmd(g, "XDEL", "t", "4-1")
	g_cmd(g, "XTRIM", "t", "MINID", "=", "4-1")
	g_full(g, "t")
	g_cmd(g, "XADD", "t", "14-1", "f", "v")
	g_cmd(g, "XTRIM", "t", "MINID", "=", "4-1")
	g_full(g, "t")
	g_cmd(g, "XTRIM", "t", "MINID", "=", "12-1")
	g_full(g, "t")
	g_cmd(g, "DEL", "u")
	for id in ([?]string{"1-1", "2-1", "3-1", "4-1"}) {
		g_cmd(g, "XADD", "u", id, "f", "v")
	}
	g_cmd(g, "XDEL", "u", "4-1")
	g_cmd(g, "XTRIM", "u", "MINID", "=", "9-1")
	g_full(g, "u")
	g_cmd(g, "XADD", "u", "10-1", "f", "v")
	g_full(g, "u")
	config_nodes(g, "100", "4096")
	g_cmd(g, "RESTORE", "wrap", "0", unhex(ENTRIES_ADDED_AT_MAX))
	g_cmd(g, "XINFO", "STREAM", "wrap")
	g_cmd(g, "XINFO", "GROUPS", "wrap")
	g_cmd(g, "XREADGROUP", "GROUP", "g", "c", "COUNT", "1", "STREAMS", "wrap", ">")
	g_cmd(g, "XINFO", "GROUPS", "wrap")
	g_cmd(g, "XADD", "wrap", "6-1", "f", "v")
	g_cmd(g, "XINFO", "GROUPS", "wrap")
	g_cmd(g, "XREADGROUP", "GROUP", "g", "c", "STREAMS", "wrap", ">")
	g_cmd(g, "XINFO", "GROUPS", "wrap")
	g_cmd(g, "XGROUP", "CREATE", "wrap", "g2", "0")
	g_cmd(g, "XREADGROUP", "GROUP", "g2", "c", "STREAMS", "wrap", ">")
	g_cmd(g, "XINFO", "GROUPS", "wrap")
	g_cmd(g, "RESTORE", "hollow", "0", unhex(LENGTH_WITHOUT_NODES))
	g_cmd(g, "XLEN", "hollow")
	g_cmd(g, "FLUSHALL")
}

run_gen :: proc(dir: string) -> bool {
	g := Gen {
		buf = make([dynamic]u8),
		rng = Rng{s = 0x5743_2a11_0041},
	}
	defer delete(g.buf)
	section_config(&g)
	section_basic(&g)
	section_ids(&g)
	section_trim_errors(&g)
	section_trim(&g)
	section_boundaries(&g)
	section_encoding(&g)
	section_ranges(&g)
	section_xdel(&g)
	section_xsetid(&g)
	section_xread(&g)
	section_xinfo(&g)
	section_wrongtype(&g)
	section_auto(&g)
	section_fuzz(&g, 12000)
	section_groups_basic(&g)
	section_readgroup(&g)
	section_pending_claim(&g)
	section_lag(&g)
	section_group_copy(&g)
	section_group_fuzz(&g, 8000)
	section_parity(&g)
	g_cmd(&g, "HELLO", "3")
	section_parity(&g)
	section_groups_basic(&g)
	section_readgroup(&g)
	section_pending_claim(&g)
	section_group_fuzz(&g, 2000)
	section_basic(&g)
	section_xread(&g)
	section_xinfo(&g)
	section_xsetid(&g)
	section_auto(&g)
	section_fuzz(&g, 3000)
	g_cmd(&g, "HELLO", "2")
	g_cmd(&g, "FLUSHALL")
	path := fmt.tprintf("%s/script.resp", dir)
	if err := os.write_entire_file(path, g.buf[:]); err != nil {
		fmt.eprintln("cannot write", path)
		return false
	}
	fmt.printfln("generated %d commands (%d bytes)", g.n, len(g.buf))
	free_all(context.temp_allocator)
	return true
}
