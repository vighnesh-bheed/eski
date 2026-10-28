package settype_harness

import "core:fmt"
import "core:os"

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
	g_cmd(g, "SCARD", key)
	g_cmd(g, "SMEMBERS", key)
	g_cmd(g, "SSCAN", key, "0")
}

g_config :: proc(g: ^Gen, intset, entries, value: int) {
	g_cmd(g, "CONFIG", "SET", "set-max-intset-entries", tp(intset))
	g_cmd(g, "CONFIG", "SET", "set-max-listpack-entries", tp(entries))
	g_cmd(g, "CONFIG", "SET", "set-max-listpack-value", tp(value))
}

g_defaults :: proc(g: ^Gen) {
	g_config(g, 512, 128, 64)
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

INT_EDGES := [?]string{"0", "1", "-1", "127", "128", "-128", "-129", "255", "256", "32767", "-32768", "32768", "-32769", "65535", "65536", "8388607", "-8388608", "2147483647", "-2147483648", "2147483648", "-2147483649", "4294967295", "4294967296", "9223372036854775807", "-9223372036854775808"}
NONCANON := [?]string{"007", "+1", "-0", "1.0", "9223372036854775808", "-9223372036854775809", "00", "-", " 11", "11 ", "0x10", "1e3", "12345678901234567890", "213244124402402314402033402", "abc", ""}

gen_member :: proc(g: ^Gen) -> string {
	r := &g.rng
	switch rng_below(r, 16) {
	case 0:
		return INT_EDGES[rng_below(r, len(INT_EDGES))]
	case 1:
		return NONCANON[rng_below(r, len(NONCANON))]
	case 2, 3, 4:
		return tp(rng_below(r, 60) - 20)
	case 5:
		return tp(i64(rng_next(r) >> uint(rng_below(r, 64))) * (1 if rng_chance(r, 50) else -1))
	case 6:
		lens := [?]int{7, 8, 9, 62, 63, 64, 65, 66}
		return rep(u8('a' + rng_below(r, 26)), lens[rng_below(r, len(lens))])
	case 7:
		n := rng_below(r, 10)
		b := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			b[i] = u8(rng_next(r))
		}
		return string(b)
	case:
		return tp("m", rng_below(r, 40))
	}
}

gen_int_member :: proc(g: ^Gen) -> string {
	r := &g.rng
	switch rng_below(r, 6) {
	case 0:
		return INT_EDGES[rng_below(r, len(INT_EDGES))]
	case 1:
		return tp(i64(rng_next(r) >> uint(rng_below(r, 64))) * (1 if rng_chance(r, 50) else -1))
	case:
		return tp(rng_below(r, 80) - 30)
	}
}

ALL_SET_CMDS := [?]string{"SADD", "SREM", "SMOVE", "SISMEMBER", "SMISMEMBER", "SCARD", "SPOP", "SRANDMEMBER", "SMEMBERS", "SINTER", "SINTERCARD", "SINTERSTORE", "SUNION", "SUNIONSTORE", "SDIFF", "SDIFFSTORE", "SSCAN"}

section_basic :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "PING")
	g_write(g, "i", "SADD", "i", "17")
	g_write(g, "i", "SADD", "i", "16", "16", "-3")
	g_write(g, "i", "SADD", "i", "16")
	g_reads(g, "i")
	for m in ([?]string{"16", "17", "18", "-3", "a", "", "016", "+16", "16.0", "9223372036854775808"}) {
		g_cmd(g, "SISMEMBER", "i", m)
	}
	g_cmd(g, "SMISMEMBER", "i", "16", "18", "17", "x")
	g_cmd(g, "SMISMEMBER", "nokey", "a", "b")
	g_cmd(g, "SISMEMBER", "nokey", "a")
	g_cmd(g, "SCARD", "nokey")
	g_cmd(g, "SMEMBERS", "nokey")
	g_write(g, "l", "SADD", "l", "foo", "bar", "1", "", "-0", "007", "12")
	g_write(g, "l", "SADD", "l", "bar", "baz")
	g_reads(g, "l")
	for m in ([?]string{"foo", "bar", "1", "", "-0", "007", "7", "12", "012", "nope"}) {
		g_cmd(g, "SISMEMBER", "l", m)
	}
	g_cmd(g, "SMISMEMBER", "l", "foo", "nope", "", "12")
	g_write(g, "l", "SREM", "l", "nope")
	g_write(g, "l", "SREM", "l", "foo", "foo", "12", "x")
	g_reads(g, "l")
	g_write(g, "i", "SREM", "i", "18", "a")
	g_write(g, "i", "SREM", "i", "16")
	g_write(g, "i", "SREM", "i", "17", "-3", "99")
	g_cmd(g, "EXISTS", "i")
	g_cmd(g, "TYPE", "i")
	g_write(g, "v", "SADD", "v", "a", "b", "c")
	g_write(g, "v", "SADD", "v", "A", "a", "b", "c", "B")
	g_reads(g, "v")
	g_write(g, "v", "SREM", "v", "a", "b", "c", "A", "B", "zz")
	g_cmd(g, "EXISTS", "v")
	g_write(g, "big", "SADD", "big", "213244124402402314402033402")
	g_cmd(g, "SISMEMBER", "big", "213244124402402314402033402")
	g_cmd(g, "SMISMEMBER", "big", "213244124402402314402033402")
	g_cmd(g, "SET", "str", "value")
	for c in ALL_SET_CMDS {
		switch c {
		case "SADD", "SREM", "SISMEMBER":
			g_cmd(g, c, "str", "a")
		case "SMOVE":
			g_cmd(g, c, "str", "l", "a")
			g_cmd(g, c, "l", "str", "bar")
			g_cmd(g, c, "nokey", "str", "a")
		case "SMISMEMBER":
			g_cmd(g, c, "str", "a", "b")
		case "SCARD", "SMEMBERS":
			g_cmd(g, c, "str")
		case "SPOP":
			g_cmd(g, c, "str")
			g_cmd(g, c, "str", "2")
			g_cmd(g, c, "str", "0")
			g_cmd(g, c, "str", "-1")
		case "SRANDMEMBER":
			g_cmd(g, c, "str")
			g_cmd(g, c, "str", "2")
			g_cmd(g, c, "str", "0")
			g_cmd(g, c, "str", "x")
		case "SINTERCARD":
			g_cmd(g, c, "1", "str")
			g_cmd(g, c, "2", "l", "str")
			g_cmd(g, c, "2", "str", "nokey")
			g_cmd(g, c, "1", "str", "LIMIT", "x")
		case "SINTER", "SUNION", "SDIFF":
			g_cmd(g, c, "str")
			g_cmd(g, c, "l", "str")
			g_cmd(g, c, "nokey", "str")
			g_cmd(g, c, "str", "nokey")
		case "SINTERSTORE", "SUNIONSTORE", "SDIFFSTORE":
			g_cmd(g, c, "dst", "str")
			g_cmd(g, c, "dst", "l", "str")
			g_cmd(g, c, "dst", "nokey", "str")
			g_cmd(g, c, "str", "l")
			g_cmd(g, "TYPE", "str")
			g_cmd(g, "SET", "str", "value")
		case "SSCAN":
			g_cmd(g, c, "str", "0")
			g_cmd(g, c, "str", "abc")
			g_cmd(g, c, "str", "0", "COUNT", "0")
		}
	}
	g_cmd(g, "EXISTS", "dst")
	g_cmd(g, "TYPE", "str")
	ar := [?][]string {
		{"SADD"},
		{"SADD", "k"},
		{"SREM", "k"},
		{"SMOVE", "a", "b"},
		{"SMOVE", "a", "b", "c", "d"},
		{"SISMEMBER", "k"},
		{"SISMEMBER", "k", "a", "b"},
		{"SMISMEMBER", "k"},
		{"SCARD"},
		{"SCARD", "a", "b"},
		{"SPOP"},
		{"SPOP", "l", "1", "2"},
		{"SPOP", "nokey", "1", "2"},
		{"SRANDMEMBER"},
		{"SRANDMEMBER", "l", "1", "2"},
		{"SRANDMEMBER", "nokey", "1", "2"},
		{"SMEMBERS"},
		{"SMEMBERS", "a", "b"},
		{"SINTER"},
		{"SINTERCARD"},
		{"SINTERCARD", "1"},
		{"SINTERSTORE", "d"},
		{"SUNION"},
		{"SUNIONSTORE", "d"},
		{"SDIFF"},
		{"SDIFFSTORE", "d"},
		{"SSCAN", "k"},
	}
	for c in ar {
		g_cmds(g, c)
	}
	errs := [?][]string {
		{"SPOP", "l", "abc"},
		{"SPOP", "l", "-1"},
		{"SPOP", "l", "1.5"},
		{"SPOP", "l", ""},
		{"SPOP", "nokey", "-5"},
		{"SPOP", "l", "9223372036854775808"},
		{"SPOP", "nokey", "0"},
		{"SPOP", "nokey", "3"},
		{"SPOP", "nokey"},
		{"SRANDMEMBER", "l", "abc"},
		{"SRANDMEMBER", "l", "-9223372036854775808"},
		{"SRANDMEMBER", "l", "9223372036854775808"},
		{"SRANDMEMBER", "nokey", "-9223372036854775808"},
		{"SRANDMEMBER", "nokey", "5"},
		{"SRANDMEMBER", "nokey", "-5"},
		{"SRANDMEMBER", "nokey", "0"},
		{"SRANDMEMBER", "nokey"},
		{"SINTERCARD", "0", "l"},
		{"SINTERCARD", "a", "l"},
		{"SINTERCARD", "-1", "l"},
		{"SINTERCARD", "2", "l"},
		{"SINTERCARD", "3", "l", "l2"},
		{"SINTERCARD", "1", "l", "l2"},
		{"SINTERCARD", "1", "l", "LIMIT"},
		{"SINTERCARD", "1", "l", "LIMIT", "-1"},
		{"SINTERCARD", "1", "l", "LIMIT", "a"},
		{"SINTERCARD", "1", "l", "limit", "2", "LIMIT", "0"},
		{"SINTERCARD", "1", "l", "LIMIT", "2", "x"},
		{"SINTERCARD", "1", "nokey", "LIMIT", "x"},
		{"SINTERCARD", "9223372036854775808", "l"},
		{"SSCAN", "l", "abc"},
		{"SSCAN", "l", "-1"},
		{"SSCAN", "l", "0", "COUNT", "0"},
		{"SSCAN", "l", "0", "COUNT", "-1"},
		{"SSCAN", "l", "0", "COUNT", "abc"},
		{"SSCAN", "l", "0", "COUNT"},
		{"SSCAN", "l", "0", "MATCH"},
		{"SSCAN", "l", "0", "FOO"},
		{"SSCAN", "l", "0", "TYPE", "set"},
		{"SSCAN", "l", "0", "NOVALUES"},
		{"SSCAN", "nokey", "0", "NOVALUES"},
		{"SSCAN", "nokey", "abc"},
		{"SSCAN", "nokey", "18446744073709551616"},
	}
	for c in errs {
		g_cmds(g, c)
	}
	g_state(g, "l")
}

section_intset :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_write(g, "w", "SADD", "w", "5", "-7", "100")
	g_write(g, "w", "SADD", "w", "32767", "-32768")
	g_write(g, "w", "SADD", "w", "32768")
	g_write(g, "w", "SADD", "w", "-32769")
	g_write(g, "w", "SADD", "w", "2147483647", "-2147483648")
	g_write(g, "w", "SADD", "w", "2147483648")
	g_write(g, "w", "SADD", "w", "-9223372036854775808", "9223372036854775807")
	g_write(g, "w", "SREM", "w", "2147483648", "-9223372036854775808", "9223372036854775807", "-32769", "32768")
	g_write(g, "w", "SREM", "w", "9223372036854775807")
	g_reads(g, "w")
	g_write(g, "n", "SADD", "n", "-1")
	g_write(g, "n", "SADD", "n", "-40000")
	g_write(g, "n", "SADD", "n", "-5000000000")
	g_write(g, "n", "SADD", "n", "1", "2", "-2")
	g_write(g, "p", "SADD", "p", "70000")
	g_write(g, "p", "SADD", "p", "1")
	g_write(g, "p", "SADD", "p", "3000000000")
	g_write(g, "p", "SADD", "p", "-1", "0")
	for i in 0 ..< 40 {
		g_write(g, "r", "SADD", "r", gen_int_member(g))
		if i % 5 == 4 {
			g_write(g, "r", "SREM", "r", gen_int_member(g), gen_int_member(g))
		}
	}
	g_reads(g, "r")
	for v in INT_EDGES {
		g_cmd(g, "SISMEMBER", "w", v)
		g_cmd(g, "SISMEMBER", "r", v)
	}
	g_write(g, "x", "SADD", "x", "1", "2", "3")
	g_write(g, "x", "SADD", "x", "a")
	g_write(g, "y", "SADD", "y", "1", "2", "3", "x")
	g_write(g, "y", "SREM", "y", "x")
	g_cmd(g, "SINTER", "x", "y")
	g_write(g, "z", "SADD", "z", "-9223372036854775808", "9223372036854775807", "0")
	g_write(g, "z", "SADD", "z", "abc")
	g_write(g, "z2", "SADD", "z2", "-9223372036854775808", "9223372036854775807", "0")
	g_write(g, "z2", "SADD", "z2", rep('q', 64))
	g_write(g, "z3", "SADD", "z3", "-9223372036854775808", "9223372036854775807", "0")
	g_write(g, "z3", "SADD", "z3", rep('q', 65))
}

section_conversions :: proc(g: ^Gen, intset, entries, value: int) {
	g_cmd(g, "FLUSHALL")
	g_config(g, intset, entries, value)
	for i in 0 ..< intset + 2 {
		g_write(g, "gi", "SADD", "gi", tp(i * 3 - 10))
	}
	g_reads(g, "gi")
	for i in 0 ..< intset + 2 {
		if i % 2 == 0 {
			g_write(g, "gi", "SREM", "gi", tp(i * 3 - 10))
		}
	}
	g_reads(g, "gi")
	args := make([dynamic]string, context.temp_allocator)
	for n in ([?]int{intset - 1, intset, intset + 1}) {
		if n < 1 {
			continue
		}
		key := tp("mi", n)
		clear(&args)
		append(&args, "SADD", key)
		for i in 0 ..< n {
			append(&args, tp(i))
		}
		g_write(g, key, ..args[:])
		g_write(g, key, "SADD", key, tp(n + 1000))
		g_write(g, key, "SADD", key, "str")
	}
	clear(&args)
	append(&args, "SADD", "dupi")
	for _ in 0 ..< intset + 1 {
		append(&args, "7")
	}
	g_write(g, "dupi", ..args[:])
	g_write(g, "dupi2", "SADD", "dupi2", "1")
	g_write(g, "dupi2", ..args[:])
	g_write(g, "gl", "SADD", "gl", "a")
	for i in 0 ..< entries + 2 {
		g_write(g, "gl", "SADD", "gl", tp("e", i))
	}
	g_reads(g, "gl")
	for n in ([?]int{entries - 1, entries, entries + 1}) {
		if n < 1 {
			continue
		}
		key := tp("ml", n)
		clear(&args)
		append(&args, "SADD", key, "a")
		for i in 0 ..< n - 1 {
			append(&args, tp(i))
		}
		g_write(g, key, ..args[:])
		g_write(g, key, "SADD", key, "b")
	}
	clear(&args)
	append(&args, "SADD", "dupl", "a")
	for _ in 0 ..< entries + 1 {
		append(&args, "a")
	}
	g_write(g, "dupl", ..args[:])
	g_write(g, "dupl2", "SADD", "dupl2", "a")
	g_write(g, "dupl2", ..args[:])
	g_write(g, "lv", "SADD", "lv", "a", rep('v', value))
	g_write(g, "lv2", "SADD", "lv2", "a")
	g_write(g, "lv2", "SADD", "lv2", rep('v', value + 1))
	g_write(g, "iv", "SADD", "iv", "1", "2")
	g_write(g, "iv", "SADD", "iv", rep('v', value))
	g_write(g, "iv2", "SADD", "iv2", "1", "2")
	g_write(g, "iv2", "SADD", "iv2", rep('v', value + 1))
	g_write(g, "iw", "SADD", "iw", "-9223372036854775808")
	g_write(g, "iw", "SADD", "iw", "z")
	g_write(g, "ib", "SADD", "ib", "1")
	g_write(g, "ib", "SADD", "ib", "213244124402402314402033402")
	clear(&args)
	append(&args, "SADD", "il")
	for i in 0 ..< min(entries, intset) {
		append(&args, tp(i * 1000))
	}
	g_write(g, "il", ..args[:])
	g_write(g, "il", "SADD", "il", "s")
	g_write(g, "empty", "SADD", "empty", "")
	g_write(g, "first", "SADD", "first", "x", "1", "2")
	g_write(g, "firsti", "SADD", "firsti", "1", "x", "2")
	g_defaults(g)
}

make_sets :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_config(g, 16, 8, 12)
	g_write(g, "ia", "SADD", "ia", "1", "2", "3", "4", "5", "-6", "100000")
	g_write(g, "ib", "SADD", "ib", "4", "5", "6", "7", "100000")
	g_write(g, "la", "SADD", "la", "a", "b", "1", "c", "4", "7")
	g_write(g, "lb", "SADD", "lb", "c", "d", "4", "e", "1")
	g_write(g, "lint", "SADD", "lint", "9", "8", "7", "x")
	g_write(g, "lint", "SREM", "lint", "x")
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "SADD", "hs")
	for i in 0 ..< 20 {
		append(&args, tp("h", i))
	}
	append(&args, "1", "4", "a", "c")
	g_write(g, "hs", ..args[:])
	clear(&args)
	append(&args, "SADD", "hi")
	for i in 0 ..< 30 {
		append(&args, tp(i - 5))
	}
	g_write(g, "hi", ..args[:])
	g_write(g, "hl", "SADD", "hl", "1", "2", "3", rep('z', 13))
	g_cmd(g, "SET", "str", "x")
}

ALGEBRA_KEYS := [?]string{"ia", "ib", "la", "lb", "lint", "hs", "hi", "hl", "nokey"}

section_algebra :: proc(g: ^Gen) {
	make_sets(g)
	for a in ALGEBRA_KEYS {
		g_cmd(g, "SMEMBERS", a)
		for b in ALGEBRA_KEYS {
			g_cmd(g, "SINTER", a, b)
			g_cmd(g, "SUNION", a, b)
			g_cmd(g, "SDIFF", a, b)
			g_cmd(g, "SINTERCARD", "2", a, b)
			g_cmd(g, "SINTERCARD", "2", a, b, "LIMIT", "2")
			g_write(g, "res", "SINTERSTORE", "res", a, b)
			g_reads(g, "res")
			g_write(g, "res", "SUNIONSTORE", "res", a, b)
			g_reads(g, "res")
			g_write(g, "res", "SDIFFSTORE", "res", a, b)
			g_reads(g, "res")
		}
	}
	r := &g.rng
	for _ in 0 ..< 300 {
		n := 1 + rng_below(r, 4)
		keys := make([dynamic]string, context.temp_allocator)
		for _ in 0 ..< n {
			append(&keys, ALGEBRA_KEYS[rng_below(r, len(ALGEBRA_KEYS))])
		}
		args := make([dynamic]string, context.temp_allocator)
		switch rng_below(r, 7) {
		case 0:
			append(&args, "SINTER")
		case 1:
			append(&args, "SUNION")
		case 2:
			append(&args, "SDIFF")
		case 3:
			append(&args, "SINTERCARD", tp(n))
		case 4:
			append(&args, "SINTERSTORE", "res")
		case 5:
			append(&args, "SUNIONSTORE", "res")
		case 6:
			append(&args, "SDIFFSTORE", "res")
		}
		append(&args, ..keys[:])
		if args[0] == "SINTERCARD" && rng_chance(r, 50) {
			append(&args, "LIMIT", tp(rng_below(r, 6)))
		}
		g_cmds(g, args[:])
		g_state(g, "res")
	}
	for a in ([?]string{"ia", "la", "hs", "hi"}) {
		g_write(g, a, "SINTERSTORE", a, a, "ib")
		g_reads(g, a)
		g_write(g, a, "SUNIONSTORE", a, a, "lb")
		g_reads(g, a)
		g_write(g, a, "SDIFFSTORE", a, a, "hl")
		g_reads(g, a)
	}
	make_sets(g)
	g_cmd(g, "SINTER", "ia", "ia", "ia")
	g_cmd(g, "SUNION", "ia", "ia", "ia")
	g_cmd(g, "SDIFF", "ia", "ia", "ia")
	g_cmd(g, "SDIFF", "hs", "la", "hs")
	g_cmd(g, "SDIFF", "nokey", "nokey", "ia")
	g_cmd(g, "SDIFF", "ia", "nokey", "nokey")
	g_cmd(g, "SINTER", "hs", "hs")
	g_cmd(g, "SINTERCARD", "3", "ia", "ia", "ib")
	g_cmd(g, "SINTERCARD", "1", "ia", "LIMIT", "0")
	g_cmd(g, "SINTERCARD", "1", "ia", "LIMIT", "3")
	g_cmd(g, "SINTERCARD", "1", "nokey", "LIMIT", "3")
	g_write(g, "str", "SINTERSTORE", "str", "ia", "ib")
	g_cmd(g, "TYPE", "str")
	g_cmd(g, "SET", "str", "x")
	g_write(g, "str", "SUNIONSTORE", "str", "la")
	g_cmd(g, "SET", "str", "x")
	g_write(g, "str", "SDIFFSTORE", "str", "hs", "la")
	g_cmd(g, "SET", "str", "x")
	g_cmd(g, "SINTERSTORE", "str", "ia", "nokey")
	g_cmd(g, "EXISTS", "str")
	g_cmd(g, "SET", "str", "x")
	g_cmd(g, "SUNIONSTORE", "str", "nokey")
	g_cmd(g, "EXISTS", "str")
	g_cmd(g, "SET", "str", "x")
	g_cmd(g, "SDIFFSTORE", "str", "ia", "ia")
	g_cmd(g, "EXISTS", "str")
	g_write(g, "ttl", "SADD", "ttl", "q")
	g_cmd(g, "EXPIRE", "ttl", "1000")
	g_write(g, "ttl", "SUNIONSTORE", "ttl", "ttl", "ia")
	g_cmd(g, "PERSIST", "ttl")
	g_cmd(g, "EXPIRE", "ttl", "1000")
	g_write(g, "ttl", "SADD", "ttl", "zz")
	g_cmd(g, "PERSIST", "ttl")
	g_cmd(g, "EXPIRE", "ttl", "1000")
	g_write(g, "ttl", "SPOP", "ttl", "1")
	g_cmd(g, "PERSIST", "ttl")
	g_write(g, "ttl", "SDIFFSTORE", "ttl", "ttl", "ttl")
	g_cmd(g, "EXISTS", "ttl")
	g_defaults(g)
	g_cmd(g, "FLUSHALL")
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "SADD", "big1")
	for i in 0 ..< 600 {
		append(&args, tp(i))
	}
	g_write(g, "big1", ..args[:])
	g_write(g, "small1", "SADD", "small1", "1", "2", "3")
	g_write(g, "res", "SINTERSTORE", "res", "big1", "small1")
	g_write(g, "res", "SINTERSTORE", "res", "big1", "big1")
	g_write(g, "res", "SDIFFSTORE", "res", "big1", "small1")
	g_write(g, "res", "SDIFFSTORE", "res", "small1", "big1")
	g_write(g, "res", "SDIFFSTORE", "res", "big1", "small1", "small1", "small1")
	clear(&args)
	append(&args, "SADD", "big2")
	for i in 3 ..< 600 {
		append(&args, tp(i))
	}
	g_write(g, "big2", ..args[:])
	g_write(g, "res", "SDIFFSTORE", "res", "big1", "big2")
	g_reads(g, "res")
	g_write(g, "res", "SDIFFSTORE", "res", "big1", "small1", "big2")
	g_write(g, "res", "SUNIONSTORE", "res", "small1", "big2")
	g_write(g, "res", "SINTERSTORE", "res", "big2", "big1", "small1")
	clear(&args)
	append(&args, "SADD", "hstr")
	for i in 0 ..< 200 {
		append(&args, tp("s", i))
	}
	append(&args, "1", "2", "3")
	g_write(g, "hstr", ..args[:])
	g_write(g, "res", "SINTERSTORE", "res", "hstr", "big1")
	g_write(g, "res", "SINTERSTORE", "res", "big1", "hstr")
	g_write(g, "res", "SDIFFSTORE", "res", "hstr", "big1")
	g_write(g, "res", "SUNIONSTORE", "res", "small1", "hstr")
}

srand_shapes :: proc(g: ^Gen, key: string, size: int) {
	g_cmd(g, "SRANDMEMBER", key)
	counts := [?]int{0, 1, -1, 2, -2, 3, 5, -5, size - 1, size, size + 1, -size, -(size * 3), size / 3 + 1, size / 2, size * 2, 1000, -1001, -2500}
	for c in counts {
		g_cmd(g, "SRANDMEMBER", key, tp(c))
	}
	for _ in 0 ..< 20 {
		g_cmd(g, "SRANDMEMBER", key, tp(rng_below(&g.rng, size * 2 + 4) - size - 2))
	}
}

fill_set :: proc(g: ^Gen, key: string, kind: int, n: int) {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "SADD", key)
	for i in 0 ..< n {
		switch kind {
		case 0:
			append(&args, tp(i * 7 - 50))
		case 1:
			append(&args, tp("p", i))
		case 2:
			append(&args, tp("element:", i * 13))
		case 3:
			append(&args, tp(i * 5 + 1))
		}
	}
	g_write(g, key, ..args[:])
}

section_random :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_config(g, 64, 32, 64)
	fill_set(g, "ri", 0, 40)
	fill_set(g, "rl", 1, 25)
	fill_set(g, "rh", 2, 150)
	fill_set(g, "rhi", 3, 100)
	g_write(g, "rli", "SADD", "rli", "1", "2", "3", "4", "5", "6", "7", "x")
	g_write(g, "rli", "SREM", "rli", "x")
	g_write(g, "one", "SADD", "one", "solo")
	for k in ([?]string{"ri", "rl", "rh", "rhi", "rli", "one", "nokey"}) {
		size := 0
		switch k {
		case "ri":
			size = 40
		case "rl":
			size = 25
		case "rh":
			size = 150
		case "rhi":
			size = 100
		case "rli":
			size = 7
		case "one":
			size = 1
		}
		srand_shapes(g, k, max(size, 3))
	}
	plans := [?][]int{{2, 1, 0, 3, 30}, {20, 1, 1}, {1, 1, 1, 1}, {7, 7, 7, 7, 7, 7}, {33}, {39}, {41}}
	kinds := [?]int{0, 1, 2, 3}
	sizes := [?]int{40, 25, 150, 100}
	for kind, ki in kinds {
		for plan, pi in plans {
			key := tp("sp", ki, "_", pi)
			fill_set(g, key, kind, sizes[ki])
			for c in plan {
				g_write(g, key, "SPOP", key, tp(c))
				g_reads(g, key)
			}
		}
	}
	for kind, ki in kinds {
		key := tp("ss", ki)
		fill_set(g, key, kind, sizes[ki])
		for _ in 0 ..< sizes[ki] + 2 {
			g_write(g, key, "SPOP", key)
		}
	}
	fill_set(g, "case3", 2, 150)
	g_write(g, "case3", "SPOP", "case3", "130")
	g_reads(g, "case3")
	g_write(g, "case3", "SADD", "case3", "new")
	g_reads(g, "case3")
	fill_set(g, "case3i", 3, 100)
	g_write(g, "case3i", "SPOP", "case3i", "90")
	g_reads(g, "case3i")
	g_cmd(g, "CONFIG", "SET", "set-max-intset-entries", "4")
	fill_set(g, "lowi", 0, 3)
	g_cmd(g, "CONFIG", "SET", "set-max-intset-entries", "2")
	g_write(g, "lowi", "SPOP", "lowi", "1")
	g_write(g, "lowi", "SADD", "lowi", "1000")
	g_cmd(g, "CONFIG", "SET", "set-max-intset-entries", "64")
	fill_set(g, "lowl", 1, 30)
	g_cmd(g, "CONFIG", "SET", "set-max-listpack-entries", "3")
	g_write(g, "lowl", "SPOP", "lowl", "26")
	g_write(g, "lowl", "SPOP", "lowl", "1")
	g_cmd(g, "CONFIG", "SET", "set-max-listpack-entries", "32")
	g_cmd(g, "HELLO", "3")
	fill_set(g, "r3", 1, 20)
	g_write(g, "r3", "SPOP", "r3", "3")
	g_write(g, "r3", "SPOP", "r3", "15")
	g_write(g, "r3", "SPOP", "r3", "5")
	g_cmd(g, "SPOP", "r3", "0")
	g_cmd(g, "SPOP", "nokey", "3")
	g_cmd(g, "SPOP", "nokey")
	g_cmd(g, "SRANDMEMBER", "nokey", "3")
	fill_set(g, "r3h", 2, 100)
	g_write(g, "r3h", "SPOP", "r3h", "90")
	g_cmd(g, "SRANDMEMBER", "r3h", "-5")
	g_cmd(g, "SRANDMEMBER", "r3h", "5")
	g_cmd(g, "SRANDMEMBER", "r3h", "50")
	g_cmd(g, "HELLO", "2")
	g_defaults(g)
}

section_smove :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	setup := proc(g: ^Gen) {
		g_cmd(g, "DEL", "m1", "m2", "m3", "m4")
		g_write(g, "m1", "SADD", "m1", "1", "a", "b")
		g_write(g, "m2", "SADD", "m2", "2", "3", "4")
	}
	setup(g)
	g_write(g, "m2", "SMOVE", "m1", "m2", "a")
	g_reads(g, "m1")
	g_reads(g, "m2")
	setup(g)
	g_write(g, "m2", "SMOVE", "m1", "m2", "1")
	g_reads(g, "m1")
	g_reads(g, "m2")
	setup(g)
	g_write(g, "m1", "SMOVE", "m2", "m1", "2")
	g_reads(g, "m1")
	g_reads(g, "m2")
	setup(g)
	g_cmd(g, "SMOVE", "m1", "m2", "foo")
	g_cmd(g, "SMOVE", "m1", "m1", "foo")
	g_cmd(g, "SMOVE", "m1", "m1", "a")
	g_cmd(g, "SMOVE", "nokey", "m2", "foo")
	g_write(g, "m3", "SMOVE", "m1", "m3", "a")
	g_write(g, "m4", "SMOVE", "m2", "m4", "2")
	g_reads(g, "m3")
	g_reads(g, "m4")
	g_write(g, "m5", "SMOVE", "m4", "m5", "2")
	g_cmd(g, "EXISTS", "m4")
	g_write(g, "m5", "SMOVE", "m3", "m5", "a")
	g_cmd(g, "EXISTS", "m3")
	g_reads(g, "m5")
	g_cmd(g, "SET", "x", "10")
	g_cmd(g, "SMOVE", "x", "m2", "foo")
	g_cmd(g, "SMOVE", "m2", "x", "3")
	g_cmd(g, "SMOVE", "m2", "x", "nope")
	g_cmd(g, "SMOVE", "nokey", "x", "nope")
	g_reads(g, "m2")
	g_cmd(g, "FLUSHALL")
	g_config(g, 4, 4, 6)
	g_write(g, "a", "SADD", "a", "1", "2", "3", "4")
	g_write(g, "b", "SADD", "b", "5", "6", "7", "8", "9")
	g_write(g, "a", "SMOVE", "b", "a", "9")
	g_write(g, "c", "SADD", "c", "x", "y", "z")
	g_write(g, "c", "SMOVE", "a", "c", "1")
	g_write(g, "c", "SMOVE", "a", "c", "2")
	g_write(g, "d", "SADD", "d", "1")
	g_write(g, "d", "SMOVE", "c", "d", "xx")
	g_write(g, "d", "SMOVE", "c", "d", "x")
	g_write(g, "e", "SMOVE", "c", "e", "abcdefgh")
	g_write(g, "e", "SADD", "c", "abcdefgh")
	g_write(g, "e", "SMOVE", "c", "e", "abcdefgh")
	g_reads(g, "e")
	g_defaults(g)
}

sscan_shapes :: proc(g: ^Gen, key: string) {
	g_cmd(g, "SSCAN", key, "0")
	for c in ([?]string{"1", "3", "10", "1000"}) {
		g_cmd(g, "SSCAN", key, "0", "COUNT", c)
	}
	for p in ([?]string{"*", "e1*", "*[0-9]", "nomatch", "e?", "*1*", "[a-c]*", "\\*", "e[^1]*", "*e*e*", "", "**", "e[", "[]", "1*", "-*"}) {
		g_cmd(g, "SSCAN", key, "0", "MATCH", p)
		g_cmd(g, "SSCAN", key, "0", "MATCH", p, "COUNT", "2")
	}
	g_cmd(g, "SSCAN", key, "0", "MATCH", "*", "MATCH", "e1*")
	g_cmd(g, "SSCAN", key, "0", "count", "5", "match", "*2*")
}

section_sscan :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_write(g, "si", "SADD", "si", "1", "12", "-3", "100", "21")
	sscan_shapes(g, "si")
	g_write(g, "sl", "SADD", "sl", "e1", "e2", "e10", "a1", "11", "", "*", "e\\1", "foo")
	sscan_shapes(g, "sl")
	for c in ([?]string{"5", " 7", "+7", "-0", "007", "18446744073709551615", "-18446744073709551615"}) {
		g_cmd(g, "SSCAN", "sl", c)
		g_cmd(g, "SSCAN", "si", c)
	}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "SADD", "sh")
	for i in 0 ..< 300 {
		append(&args, tp("e", i))
	}
	append(&args, "", "*")
	g_write(g, "sh", ..args[:])
	sscan_shapes(g, "sh")
	for _ in 0 ..< 60 {
		g_write(g, "sh", "SREM", "sh", tp("e", rng_below(&g.rng, 300)), tp("e", rng_below(&g.rng, 300)), tp("e", rng_below(&g.rng, 300)), tp("e", rng_below(&g.rng, 300)))
	}
	sscan_shapes(g, "sh")
	clear(&args)
	append(&args, "SADD", "shi")
	for i in 0 ..< 700 {
		append(&args, tp(i))
	}
	g_write(g, "shi", ..args[:])
	sscan_shapes(g, "shi")
	g_cmd(g, "SSCAN", "nokey", "0")
	g_cmd(g, "SSCAN", "nokey", "0", "COUNT", "0")
	g_cmd(g, "SSCAN", "nokey", "12345", "FOO")
}

section_copy :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_write(g, "ci", "SADD", "ci", "1", "2", "3")
	g_write(g, "cl", "SADD", "cl", "1", "2", "3", "a")
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "SADD", "ch", "a")
	for i in 4 ..< 200 {
		append(&args, tp(i))
	}
	g_write(g, "ch", ..args[:])
	for k in ([?]string{"ci", "cl", "ch"}) {
		dst := tp(k, "_copy")
		g_write(g, dst, "COPY", k, dst)
		g_reads(g, dst)
		g_cmd(g, "COPY", k, dst)
		g_write(g, dst, "SADD", dst, "extra")
		g_write(g, k, "SREM", k, "1")
		g_reads(g, k)
		g_reads(g, dst)
		g_write(g, dst, "COPY", k, dst, "REPLACE")
		g_reads(g, dst)
	}
	g_cmd(g, "EXPIRE", "ci", "1000")
	g_write(g, "ci2", "COPY", "ci", "ci2")
	g_cmd(g, "PERSIST", "ci2")
	g_cmd(g, "COPY", "ci", "ci")
	g_cmd(g, "SET", "s", "v")
	g_write(g, "s", "COPY", "cl", "s", "REPLACE")
	g_cmd(g, "TYPE", "s")
}

section_resp3 :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_write(g, "ri", "SADD", "ri", "1", "2", "3")
	g_write(g, "rl", "SADD", "rl", "a", "b", "1")
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "SADD", "rh")
	for i in 0 ..< 150 {
		append(&args, tp("x", i))
	}
	g_write(g, "rh", ..args[:])
	g_cmd(g, "SET", "str", "v")
	g_cmd(g, "HELLO", "3")
	for k in ([?]string{"ri", "rl", "rh", "nokey", "str"}) {
		g_cmd(g, "SMEMBERS", k)
		g_cmd(g, "SINTER", k, "ri")
		g_cmd(g, "SINTER", "rl", k)
		g_cmd(g, "SUNION", k, "ri")
		g_cmd(g, "SDIFF", k, "rl")
		g_cmd(g, "SINTERCARD", "2", k, "rl")
		g_cmd(g, "SISMEMBER", k, "a")
		g_cmd(g, "SMISMEMBER", k, "a", "1")
		g_cmd(g, "SCARD", k)
		g_cmd(g, "SRANDMEMBER", k)
		g_cmd(g, "SRANDMEMBER", k, "0")
		g_cmd(g, "SRANDMEMBER", k, "200")
		g_cmd(g, "SRANDMEMBER", k, "-3")
		g_cmd(g, "SRANDMEMBER", k, "2")
		g_cmd(g, "SSCAN", k, "0")
		g_cmd(g, "OBJECT", "ENCODING", k)
		g_cmd(g, "SPOP", k, "0")
	}
	g_write(g, "ri", "SPOP", "ri", "2")
	g_write(g, "ri", "SPOP", "ri")
	g_cmd(g, "SPOP", "ri")
	g_cmd(g, "SPOP", "ri")
	g_write(g, "rl", "SPOP", "rl", "100")
	g_cmd(g, "SINTERSTORE", "d", "rh", "rh")
	g_cmd(g, "SUNIONSTORE", "d", "nokey")
	g_cmd(g, "HELLO", "2")
}

FUZZ_KEYS := [?]string{"f0", "f1", "f2", "f3", "f4"}

section_fuzz :: proc(g: ^Gen, ops: int) {
	g_cmd(g, "FLUSHALL")
	intset_opts := [?]int{0, 1, 2, 4, 8, 16, 512, 512, 512}
	entries_opts := [?]int{0, 1, 2, 4, 8, 16, 128, 128, 128, 128}
	value_opts := [?]int{0, 1, 4, 8, 16, 64, 64, 64, 64}
	r := &g.rng
	for i in 0 ..< ops {
		if i % 400 == 0 {
			g_cmd(g, "DEL", FUZZ_KEYS[rng_below(r, len(FUZZ_KEYS))], FUZZ_KEYS[rng_below(r, len(FUZZ_KEYS))])
			g_config(g, intset_opts[rng_below(r, len(intset_opts))], entries_opts[rng_below(r, len(entries_opts))], value_opts[rng_below(r, len(value_opts))])
		}
		k := FUZZ_KEYS[rng_below(r, len(FUZZ_KEYS))]
		k2 := FUZZ_KEYS[rng_below(r, len(FUZZ_KEYS))]
		ints := rng_chance(r, 50)
		switch rng_below(r, 26) {
		case 0, 1, 2, 3, 4, 5:
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "SADD", k)
			for _ in 0 ..< 1 + rng_below(r, 6) {
				append(&args, gen_int_member(g) if ints else gen_member(g))
			}
			g_write(g, k, ..args[:])
		case 6, 7:
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "SREM", k)
			for _ in 0 ..< 1 + rng_below(r, 4) {
				append(&args, gen_int_member(g) if ints else gen_member(g))
			}
			g_write(g, k, ..args[:])
		case 8:
			g_write(g, k2, "SMOVE", k, k2, gen_int_member(g) if ints else gen_member(g))
		case 9:
			g_cmd(g, "SISMEMBER", k, gen_member(g))
		case 10:
			g_cmd(g, "SMISMEMBER", k, gen_member(g), gen_int_member(g), gen_member(g))
		case 11:
			g_cmd(g, "SCARD", k)
		case 12:
			g_cmd(g, "SMEMBERS", k)
		case 13:
			c := rng_below(r, 12)
			if rng_chance(r, 30) {
				g_write(g, k, "SPOP", k)
			} else {
				g_write(g, k, "SPOP", k, tp(c))
			}
		case 14:
			if rng_chance(r, 30) {
				g_cmd(g, "SRANDMEMBER", k)
			} else {
				g_cmd(g, "SRANDMEMBER", k, tp(rng_below(r, 30) - 15))
			}
		case 15:
			g_cmd(g, "SINTER", k, k2)
		case 16:
			g_cmd(g, "SUNION", k, k2, FUZZ_KEYS[rng_below(r, len(FUZZ_KEYS))])
		case 17:
			g_cmd(g, "SDIFF", k, k2, FUZZ_KEYS[rng_below(r, len(FUZZ_KEYS))])
		case 18:
			g_cmd(g, "SINTERCARD", "2", k, k2, "LIMIT", tp(rng_below(r, 4)))
		case 19:
			g_write(g, k, "SINTERSTORE", k, k2, FUZZ_KEYS[rng_below(r, len(FUZZ_KEYS))])
		case 20:
			g_write(g, k, "SUNIONSTORE", k, k2, FUZZ_KEYS[rng_below(r, len(FUZZ_KEYS))])
		case 21:
			g_write(g, k, "SDIFFSTORE", k, k2, FUZZ_KEYS[rng_below(r, len(FUZZ_KEYS))])
		case 22:
			pats := [?]string{"*", "m1*", "*[0-9]*", "m?", "-*"}
			g_cmd(g, "SSCAN", k, "0", "MATCH", pats[rng_below(r, len(pats))], "COUNT", tp(1 + rng_below(r, 20)))
		case 23:
			g_cmd(g, "DEL", k)
		case 24:
			if k != k2 {
				g_write(g, k2, "COPY", k, k2, "REPLACE")
			}
		case 25:
			g_state(g, k)
		}
	}
	g_defaults(g)
	for k in FUZZ_KEYS {
		g_state(g, k)
		g_reads(g, k)
	}
}

run_gen :: proc(dir: string) -> bool {
	g := Gen {
		buf = make([dynamic]u8),
		rng = Rng{s = 0x5E7_7E57},
	}
	defer delete(g.buf)
	g_defaults(&g)
	section_basic(&g)
	section_intset(&g)
	section_conversions(&g, 512, 128, 64)
	section_conversions(&g, 16, 8, 8)
	section_conversions(&g, 4, 4, 2)
	section_conversions(&g, 1, 1, 1)
	section_conversions(&g, 0, 0, 0)
	section_conversions(&g, 0, 128, 64)
	section_conversions(&g, 512, 0, 64)
	section_algebra(&g)
	section_random(&g)
	section_smove(&g)
	section_sscan(&g)
	section_copy(&g)
	section_resp3(&g)
	section_fuzz(&g, 20000)
	g_defaults(&g)
	g_cmd(&g, "FLUSHALL")
	path := fmt.tprintf("%s/script.resp", dir)
	if err := os.write_entire_file(path, g.buf[:]); err != nil {
		fmt.eprintln("cannot write", path)
		return false
	}
	fmt.printfln("generated %d commands (%d bytes) into %s", g.n, len(g.buf), path)
	return true
}
