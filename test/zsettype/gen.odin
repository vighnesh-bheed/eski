package zsettype_harness

import zt "../../src/zsettype"
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

pick :: proc(r: ^Rng, opts: []string) -> string {
	return opts[rng_below(r, len(opts))]
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
	g_cmd(g, "ZCARD", key)
}

g_write :: proc(g: ^Gen, key: string, args: ..string) {
	g_cmd(g, ..args)
	g_state(g, key)
}

g_reads :: proc(g: ^Gen, key: string) {
	g_cmd(g, "ZRANGE", key, "0", "-1", "WITHSCORES")
	g_cmd(g, "ZRANGE", key, "0", "-1", "REV")
	g_cmd(g, "ZSCAN", key, "0")
}

tp :: proc(args: ..any) -> string {
	return fmt.tprint(..args, sep = "")
}

rep :: proc(c: u8, n: int) -> string {
	b := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		b[i] = c
	}
	return string(b)
}

d2s :: proc(v: f64) -> string {
	buf: [zt.D2STRING_MAX]u8
	n := zt.d2string(buf[:], v)
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

g17 :: proc(v: f64) -> string {
	buf: [zt.G17_MAX]u8
	n := zt.format_g17(buf[:], v)
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

random_double :: proc(r: ^Rng) -> f64 {
	for {
		bits := rng_next(r)
		k := rng_below(r, 10)
		switch {
		case k < 6:
			e := u64(1023 - 30 + rng_below(r, 70))
			bits = (bits & 0x800F_FFFF_FFFF_FFFF) | (e << 52)
		case k < 8:
			e := u64(1 + rng_below(r, 2045))
			bits = (bits & 0x800F_FFFF_FFFF_FFFF) | (e << 52)
		case k < 9:
			bits = bits & 0x800F_FFFF_FFFF_FFFF
		case:
		}
		v := transmute(f64)bits
		if v == v {
			return v
		}
	}
}

SCORE_FIXED := [?]string{"0", "-0", "1", "-1", "1.5", "-1.5", "0.1", "0.2", "0.30000000000000004", "inf", "-inf", "+inf", "Inf", "INFINITY", "-Infinity", "1e10", "1E-5", "123456789012345678", "9007199254740993", "4611686018427387904", "4611686018427388928", "-4611686018427387904", "9223372036854775807", "1e300", "-1e300", "1.7976931348623157e308", "2.2250738585072014e-308", "4.9e-324", "5e-324", "1e-310", "0x1p3", "0X1.8P1", "0x.8", "0x10", ".5", "5.", "00012", "+7", "1e+2", "17179869184", "2.675", "1000000000000000.25", "0.500003814697265625", "3.0000000000000004", "100", "-100", "42"}

SCORE_BAD := [?]string{"nan", "NaN", "-nan", "", " 1", "1 ", "abc", "1e400", "-1e400", "1e-400", "0x", "1.5.5", "1e", "+", "-", ".", "1,5", "\t2", "inf ", "infinit", "0x1p", "1e5000", "nan(123)", "(1", "[1"}

gen_score :: proc(g: ^Gen) -> string {
	r := &g.rng
	k := rng_below(r, 100)
	switch {
	case k < 30:
		return SCORE_FIXED[rng_below(r, len(SCORE_FIXED))]
	case k < 55:
		return tp(rng_below(r, 41) - 20)
	case k < 70:
		return d2s(random_double(r))
	case k < 80:
		return g17(random_double(r))
	case k < 90:
		return tp(rng_below(r, 2000) - 1000, ".", rng_below(r, 1000))
	case:
		return tp(rng_below(r, 100), "e", rng_below(r, 40) - 20)
	}
}

MEMBER_FIXED := [?]string{"a", "b", "c", "A", "", "0", "1", "-1", "10", "007", "-0", "12345678901234567890", "9223372036854775807", "-9223372036854775808", "foo", "bar", "baz", "ab", "abc", "\x00", "\xff", "a\x00b", "x y"}

gen_member :: proc(g: ^Gen) -> string {
	r := &g.rng
	k := rng_below(r, 100)
	switch {
	case k < 15:
		return MEMBER_FIXED[rng_below(r, len(MEMBER_FIXED))]
	case k < 30:
		return tp(rng_below(r, 200) - 50)
	case k < 35:
		lens := [?]int{63, 64, 65}
		return rep(u8('a' + rng_below(r, 26)), lens[rng_below(r, 3)])
	case k < 40:
		n := rng_below(r, 10)
		b := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			b[i] = u8(rng_next(r))
		}
		return string(b)
	case:
		return tp("m", rng_below(r, 60))
	}
}

gen_range_bound :: proc(g: ^Gen) -> string {
	r := &g.rng
	k := rng_below(r, 100)
	s: string
	switch {
	case k < 15:
		s = SCORE_FIXED[rng_below(r, len(SCORE_FIXED))]
	case k < 20:
		bounds := [?]string{"-inf", "+inf", "inf", "(inf", "(-inf", "", "(", "nan", "(nan", "abc", " 5", "5 ", "1e400", "-1e400", "(1e-400"}
		return bounds[rng_below(r, len(bounds))]
	case k < 70:
		s = tp(rng_below(r, 41) - 20)
	case:
		s = tp(rng_below(r, 400) - 200, ".", rng_below(r, 10))
	}
	if rng_chance(r, 35) {
		return tp("(", s)
	}
	return s
}

gen_lex_bound :: proc(g: ^Gen) -> string {
	r := &g.rng
	k := rng_below(r, 100)
	switch {
	case k < 12:
		return "-"
	case k < 24:
		return "+"
	case k < 30:
		bad := [?]string{"a", "", "-a", "+a", "(", "[", "--", "++"}
		return bad[rng_below(r, len(bad))]
	}
	m := gen_member(g)
	if rng_chance(r, 50) {
		return tp("(", m)
	}
	return tp("[", m)
}

Score_Mode :: enum {
	Ints,
	Random,
	Zero,
}

fill_zset :: proc(g: ^Gen, key: string, n: int, mode: Score_Mode, member_prefix: string = "") {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "ZADD", key)
	for i in 0 ..< n {
		s: string
		switch mode {
		case .Ints:
			s = tp(rng_below(&g.rng, 2 * n + 1) - n)
		case .Random:
			s = gen_score(g)
		case .Zero:
			s = "0"
		}
		for {
			if _, ok := zt.parse_score(transmute([]u8)s); ok {
				break
			}
			s = gen_score(g)
		}
		append(&args, s)
		if member_prefix != "" {
			append(&args, tp(member_prefix, i))
		} else {
			append(&args, gen_member(g))
		}
	}
	g_cmds(g, args[:])
	g_state(g, key)
}

section_basic :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "PING")
	g_write(g, "z", "ZADD", "z", "1", "a", "2", "b", "3", "c")
	g_reads(g, "z")
	g_write(g, "z", "ZADD", "z", "1.5", "d", "-inf", "e", "+inf", "f", "0", "g", "0", "aa", "0", "", "-0", "h")
	g_reads(g, "z")
	for m in ([?]string{"a", "b", "e", "f", "g", "", "h", "nope"}) {
		g_cmd(g, "ZSCORE", "z", m)
		g_cmd(g, "ZRANK", "z", m)
		g_cmd(g, "ZREVRANK", "z", m)
		g_cmd(g, "ZRANK", "z", m, "WITHSCORE")
		g_cmd(g, "ZREVRANK", "z", m, "withscore")
	}
	g_cmd(g, "ZMSCORE", "z", "a", "nope", "e", "f")
	g_cmd(g, "ZMSCORE", "nokey", "a", "b")
	g_cmd(g, "ZCARD", "z")
	g_cmd(g, "ZCARD", "nokey")
	g_cmd(g, "ZSCORE", "nokey", "a")
	g_cmd(g, "ZRANK", "nokey", "a")
	g_cmd(g, "ZRANK", "nokey", "a", "WITHSCORE")
	g_cmd(g, "ZRANK", "z", "a", "WITHSCORES")
	g_cmd(g, "ZRANK", "z", "a", "WITHSCORE", "x")
	g_write(g, "z", "ZINCRBY", "z", "2.5", "a")
	g_write(g, "z", "ZINCRBY", "z", "1", "newm")
	g_write(g, "z", "ZINCRBY", "z", "-inf", "f")
	g_write(g, "z", "ZREM", "z", "a", "nope", "b")
	g_write(g, "z", "ZREM", "z", "a")
	g_cmd(g, "TYPE", "z")
	g_cmd(g, "EXISTS", "z")
	g_write(g, "z1", "ZADD", "z1", "1", "only")
	g_write(g, "z1", "ZREM", "z1", "only", "other")
	g_cmd(g, "EXISTS", "z1")
	g_cmd(g, "TYPE", "z1")
}

section_zadd_options :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	opts := [?]string{"NX", "XX", "CH", "INCR", "GT", "LT"}
	for mask in 0 ..< 64 {
		for variant in 0 ..< 4 {
			key := "zo"
			g_cmd(g, "DEL", key)
			if variant != 3 {
				g_cmd(g, "ZADD", key, "5", "a", "10", "b", "inf", "c", "-inf", "d")
			}
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "ZADD", key)
			for o, i in opts {
				if mask & (1 << uint(i)) != 0 {
					append(&args, o if rng_chance(&g.rng, 70) else strings.to_lower(o, context.temp_allocator))
				}
			}
			switch variant {
			case 0:
				append(&args, "7", "a")
			case 1:
				append(&args, "3", "b", "20", "new")
			case 2:
				vals := [?]string{"5", "inf", "-inf", "0", "-7"}
				append(&args, vals[rng_below(&g.rng, len(vals))], pick(&g.rng, []string{"a", "c", "d", "new"}))
			case 3:
				append(&args, "1", "x")
			}
			g_cmds(g, args[:])
			g_state(g, key)
			g_cmd(g, "ZRANGE", key, "0", "-1", "WITHSCORES")
		}
	}
	g_cmd(g, "DEL", "zo")
	g_cmd(g, "ZADD", "zo", "1", "a")
	g_cmd(g, "ZADD", "zo", "NX")
	g_cmd(g, "ZADD", "zo", "NX", "1")
	g_cmd(g, "ZADD", "zo", "1", "a", "2")
	g_cmd(g, "ZADD", "zo", "CH", "CH", "1", "a")
	g_cmd(g, "ZADD", "zo", "nan", "a")
	g_cmd(g, "ZADD", "zo", "1", "a", "nan", "b")
	g_cmd(g, "ZADD", "zo", "INCR", "nan", "a")
	g_cmd(g, "ZINCRBY", "zo", "nan", "a")
	g_cmd(g, "ZINCRBY", "zo", "1", "a", "x")
	g_cmd(g, "ZINCRBY", "zo", "nx", "a")
	g_cmd(g, "ZINCRBY", "zo", "incr", "incr")
	g_write(g, "zo", "ZADD", "zo", "inf", "big")
	g_write(g, "zo", "ZINCRBY", "zo", "-inf", "big")
	g_write(g, "zo", "ZADD", "zo", "INCR", "-inf", "big")
	g_write(g, "zo", "ZINCRBY", "zo", "+inf", "big")
	g_write(g, "zo", "ZADD", "zo", "INCR", "GT", "-1", "a")
	g_write(g, "zo", "ZADD", "zo", "INCR", "LT", "-1", "a")
	g_write(g, "zo", "ZADD", "zo", "INCR", "XX", "1", "nope")
	g_write(g, "zo", "ZADD", "zo", "INCR", "NX", "1", "a")
	g_write(g, "zxx", "ZADD", "zxx", "XX", "1", "a")
	g_cmd(g, "EXISTS", "zxx")
	g_write(g, "zxx", "ZADD", "zxx", "INCR", "XX", "1", "a")
	g_cmd(g, "EXISTS", "zxx")
	g_write(g, "zgt", "ZADD", "zgt", "GT", "CH", "1", "a", "2", "b")
	g_write(g, "zgt", "ZADD", "zgt", "GT", "CH", "0", "a", "3", "b", "1", "c")
	g_write(g, "zgt", "ZADD", "zgt", "LT", "CH", "0", "a", "3", "b", "1", "c")
	g_write(g, "zgt", "ZADD", "zgt", "XX", "LT", "CH", "-5", "a", "30", "b", "1", "zzz")
	for s in SCORE_FIXED {
		g_write(g, "zs", "ZADD", "zs", s, tp("m", s))
	}
	for s in SCORE_BAD {
		g_cmd(g, "ZADD", "zs", s, "bad")
		g_cmd(g, "ZINCRBY", "zs", s, "bad")
	}
	g_reads(g, "zs")
}

section_scores :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	for round in 0 ..< 40 {
		key := tp("sc", round % 4)
		if round % 8 == 0 {
			g_cmd(g, "DEL", key)
		}
		n := 1 + rng_below(&g.rng, 12)
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "ZADD", key)
		for _ in 0 ..< n {
			v := random_double(&g.rng)
			s := d2s(v) if rng_chance(&g.rng, 50) else g17(v)
			append(&args, s, tp("e", rng_below(&g.rng, 30)))
		}
		g_cmds(g, args[:])
		g_state(g, key)
		g_cmd(g, "ZRANGE", key, "0", "-1", "WITHSCORES")
		g_cmd(g, "ZSCAN", key, "0")
		g_cmd(g, "ZINCRBY", key, d2s(random_double(&g.rng)), tp("e", rng_below(&g.rng, 30)))
		g_cmd(g, "ZSCORE", key, tp("e", rng_below(&g.rng, 30)))
		g_cmd(g, "ZMSCORE", key, "e1", "e2", "e3", "e4")
		g_state(g, key)
	}
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "0")
	for round in 0 ..< 20 {
		key := tp("scs", round % 3)
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "ZADD", key)
		for _ in 0 ..< 1 + rng_below(&g.rng, 20) {
			v := random_double(&g.rng)
			append(&args, d2s(v), tp("e", rng_below(&g.rng, 40)))
		}
		g_cmds(g, args[:])
		g_state(g, key)
		g_cmd(g, "ZRANGE", key, "0", "-1", "WITHSCORES")
		g_cmd(g, "ZSCAN", key, "0", "COUNT", "5")
	}
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
	g_write(g, "neg0", "ZADD", "neg0", "-0", "a", "0", "b", "-0.0", "c")
	g_cmd(g, "ZSCORE", "neg0", "a")
	g_cmd(g, "ZSCAN", "neg0", "0")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "0")
	g_write(g, "neg0s", "ZADD", "neg0s", "-0", "a", "0", "b", "-0.0", "c")
	g_cmd(g, "ZSCORE", "neg0s", "a")
	g_cmd(g, "ZSCAN", "neg0s", "0")
	g_cmd(g, "ZRANGE", "neg0s", "0", "-1", "WITHSCORES")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
}

section_conversions :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	for n in ([?]int{127, 128, 129}) {
		key := tp("cv", n)
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "ZADD", key)
		for i in 0 ..< n {
			append(&args, tp(i % 17), tp("k", i))
		}
		g_cmds(g, args[:])
		g_state(g, key)
		g_write(g, key, "ZADD", key, "1", "extra")
		g_write(g, key, "ZREM", key, "extra", "k0")
		g_reads(g, key)
	}
	g_write(g, "cvv", "ZADD", "cvv", "1", rep('v', 64))
	g_write(g, "cvv", "ZADD", "cvv", "2", rep('w', 65))
	g_write(g, "cvv2", "ZADD", "cvv2", "1", rep('w', 65))
	g_write(g, "cvv3", "ZADD", "cvv3", "1", "short", "2", rep('w', 65))
	g_write(g, "cvv4", "ZINCRBY", "cvv4", "1", rep('q', 65))
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "4")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-value", "8")
	g_write(g, "small", "ZADD", "small", "1", "a", "2", "b", "3", "c", "4", "d")
	g_write(g, "small", "ZADD", "small", "5", "e")
	g_write(g, "small2", "ZADD", "small2", "1", "a", "2", "b", "3", "c", "4", "d", "5", "e")
	g_write(g, "small3", "ZADD", "small3", "1", "abcdefgh")
	g_write(g, "small3", "ZADD", "small3", "1", "abcdefghi")
	g_write(g, "small4", "ZADD", "small4", "1", "abcdefghi", "2", "x")
	g_write(g, "u1", "ZUNIONSTORE", "u1", "1", "small")
	g_write(g, "u2", "ZRANGESTORE", "u2", "small", "0", "2")
	g_write(g, "u3", "ZRANGESTORE", "u3", "small", "0", "-1")
	g_write(g, "u4", "ZRANGESTORE", "u4", "small", "-inf", "+inf", "BYSCORE")
	g_write(g, "u5", "ZINTERSTORE", "u5", "2", "small", "small2", "WEIGHTS", "1", "2")
	g_write(g, "u6", "ZDIFFSTORE", "u6", "2", "small2", "small")
	g_write(g, "u7", "ZUNIONSTORE", "u7", "2", "small3", "small4")
	g_write(g, "u8", "ZRANGESTORE", "u8", "small4", "[a", "+", "BYLEX")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-value", "64")
	g_write(g, "u9", "ZUNIONSTORE", "u9", "1", "small")
	g_write(g, "u10", "ZUNIONSTORE", "u10", "2", "small", "small3")
	g_write(g, "u11", "ZRANGESTORE", "u11", "small", "0", "-1")
	g_write(g, "u12", "ZUNIONSTORE", "u12", "1", "cvv")
	g_write(g, "u13", "ZINTERSTORE", "u13", "1", "cv129")
	g_write(g, "u14", "ZRANGESTORE", "u14", "cv129", "0", "127")
	g_write(g, "u15", "ZRANGESTORE", "u15", "cv129", "0", "128")
	g_write(g, "u16", "ZRANGESTORE", "u16", "cv129", "0", "+inf", "BYSCORE", "LIMIT", "0", "128")
	g_write(g, "u17", "ZRANGESTORE", "u17", "cv129", "0", "+inf", "BYSCORE", "LIMIT", "0", "129")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "0")
	g_write(g, "e0", "ZADD", "e0", "1", "a")
	g_write(g, "e1", "ZRANGESTORE", "e1", "small", "0", "0")
	g_write(g, "e2", "ZRANGESTORE", "e2", "small", "(1", "2", "BYSCORE")
	g_write(g, "e3", "ZUNIONSTORE", "e3", "1", "small")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "1")
	g_write(g, "e4", "ZRANGESTORE", "e4", "small", "0", "1")
	g_write(g, "e5", "ZRANGESTORE", "e5", "small", "0", "0")
	g_write(g, "e6", "ZRANGESTORE", "e6", "small", "-inf", "+inf", "BYSCORE")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-value", "0")
	g_write(g, "v0", "ZADD", "v0", "1", "", "2", "a")
	g_write(g, "v1", "ZADD", "v1", "1", "")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-value", "64")
	g_write(g, "cp", "COPY", "cv129", "cpdst")
	g_state(g, "cpdst")
	g_write(g, "cp", "COPY", "cvv", "cpdst2")
	g_state(g, "cpdst2")
	g_cmd(g, "COPY", "cvv", "cpdst2")
	g_cmd(g, "COPY", "cv127", "cpdst2", "REPLACE")
	g_state(g, "cpdst2")
	g_cmd(g, "ZRANGE", "cpdst2", "0", "-1", "WITHSCORES")
}

random_range_cmd :: proc(g: ^Gen, key: string, lex_ok: bool) {
	r := &g.rng
	k := rng_below(r, 12)
	for !lex_ok && (k == 4 || k == 5 || k == 7 || k == 10) {
		k = rng_below(r, 12)
	}
	switch k {
	case 0, 1:
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "ZRANGE", key, tp(rng_below(r, 40) - 20), tp(rng_below(r, 40) - 20))
		if rng_chance(r, 30) {
			append(&args, "REV")
		}
		if rng_chance(r, 50) {
			append(&args, "WITHSCORES")
		}
		if rng_chance(r, 5) {
			append(&args, "LIMIT", "0", "1")
		}
		g_cmds(g, args[:])
	case 2, 3:
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "ZRANGE", key, gen_range_bound(g), gen_range_bound(g), "BYSCORE")
		if rng_chance(r, 40) {
			append(&args, "REV")
		}
		if rng_chance(r, 50) {
			append(&args, "WITHSCORES")
		}
		if rng_chance(r, 50) {
			append(&args, "LIMIT", tp(rng_below(r, 25) - 2), tp(rng_below(r, 12) - 2))
		}
		g_cmds(g, args[:])
	case 4, 5:
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "ZRANGE", key, gen_lex_bound(g), gen_lex_bound(g), "BYLEX")
		if rng_chance(r, 40) {
			append(&args, "REV")
		}
		if rng_chance(r, 50) {
			append(&args, "LIMIT", tp(rng_below(r, 25) - 2), tp(rng_below(r, 12) - 2))
		}
		if rng_chance(r, 5) {
			append(&args, "WITHSCORES")
		}
		g_cmds(g, args[:])
	case 6:
		args := make([dynamic]string, context.temp_allocator)
		cmd := pick(r, []string{"ZRANGEBYSCORE", "ZREVRANGEBYSCORE"})
		append(&args, cmd, key, gen_range_bound(g), gen_range_bound(g))
		if rng_chance(r, 50) {
			append(&args, "WITHSCORES")
		}
		if rng_chance(r, 40) {
			append(&args, "LIMIT", tp(rng_below(r, 25) - 2), tp(rng_below(r, 12) - 2))
		}
		g_cmds(g, args[:])
	case 7:
		args := make([dynamic]string, context.temp_allocator)
		cmd := pick(r, []string{"ZRANGEBYLEX", "ZREVRANGEBYLEX"})
		append(&args, cmd, key, gen_lex_bound(g), gen_lex_bound(g))
		if rng_chance(r, 40) {
			append(&args, "LIMIT", tp(rng_below(r, 25) - 2), tp(rng_below(r, 12) - 2))
		}
		g_cmds(g, args[:])
	case 8:
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "ZREVRANGE", key, tp(rng_below(r, 40) - 20), tp(rng_below(r, 40) - 20))
		if rng_chance(r, 50) {
			append(&args, "WITHSCORES")
		}
		g_cmds(g, args[:])
	case 9:
		g_cmd(g, "ZCOUNT", key, gen_range_bound(g), gen_range_bound(g))
	case 10:
		g_cmd(g, "ZLEXCOUNT", key, gen_lex_bound(g), gen_lex_bound(g))
	case 11:
		m := gen_member(g)
		if rng_chance(r, 50) {
			g_cmd(g, "ZRANK", key, m, "WITHSCORE")
		} else {
			g_cmd(g, "ZREVRANK", key, m)
		}
	}
}

section_ranges :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	for round in 0 ..< 36 {
		key := tp("rg", round)
		big := round % 3 == 2
		mode := Score_Mode(round % 3)
		fill_zset(g, key, 150 if big else 5 + rng_below(&g.rng, 30), mode, "" if round % 4 < 2 else "p")
		for _ in 0 ..< 60 {
			random_range_cmd(g, key, mode == .Zero)
		}
		g_cmd(g, "ZRANGE", key, "0", "-1", "WITHSCORES")
	}
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "ZADD", "lx", "0", "alpha", "0", "bar", "0", "cool", "0", "down", "0", "elephant", "0", "foo", "0", "great", "0", "hill", "0", "omega", "0", "", "0", "a\x00", "0", "1", "0", "10", "0", "2")
	g_state(g, "lx")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "0")
	g_cmd(g, "ZADD", "lxs", "0", "alpha", "0", "bar", "0", "cool", "0", "down", "0", "elephant", "0", "foo", "0", "great", "0", "hill", "0", "omega", "0", "", "0", "a\x00", "0", "1", "0", "10", "0", "2")
	g_state(g, "lxs")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
	for key in ([?]string{"lx", "lxs"}) {
		for _ in 0 ..< 150 {
			r := &g.rng
			switch rng_below(r, 4) {
			case 0:
				g_cmd(g, "ZRANGEBYLEX", key, gen_lex_bound(g), gen_lex_bound(g))
			case 1:
				g_cmd(g, "ZREVRANGEBYLEX", key, gen_lex_bound(g), gen_lex_bound(g), "LIMIT", tp(rng_below(r, 6)), tp(rng_below(r, 6) - 1))
			case 2:
				g_cmd(g, "ZLEXCOUNT", key, gen_lex_bound(g), gen_lex_bound(g))
			case 3:
				g_cmd(g, "ZRANGE", key, gen_lex_bound(g), gen_lex_bound(g), "BYLEX", "REV")
			}
		}
		for b in ([?][2]string{{"-", "+"}, {"+", "-"}, {"-", "-"}, {"+", "+"}, {"[a", "[a"}, {"(a", "[a"}, {"[", "+"}, {"(", "+"}, {"-", "["}, {"-", "("}, {"[alpha", "(alpha"}, {"[b", "[c"}, {"[\x00", "+"}}) {
			g_cmd(g, "ZRANGEBYLEX", key, b[0], b[1])
			g_cmd(g, "ZLEXCOUNT", key, b[0], b[1])
			g_cmd(g, "ZREVRANGEBYLEX", key, b[1], b[0])
		}
	}
	g_cmd(g, "ZADD", "rk", "1", "a", "1", "b", "1", "c", "2", "d", "-inf", "e", "inf", "f")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "0")
	g_cmd(g, "ZADD", "rks", "1", "a", "1", "b", "1", "c", "2", "d", "-inf", "e", "inf", "f")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
	for key in ([?]string{"rk", "rks"}) {
		for m in ([?]string{"a", "b", "c", "d", "e", "f", "x"}) {
			g_cmd(g, "ZRANK", key, m)
			g_cmd(g, "ZREVRANK", key, m, "WITHSCORE")
		}
		for b in ([?][2]string{{"-inf", "+inf"}, {"(-inf", "(+inf"}, {"1", "1"}, {"(1", "1"}, {"1", "(1"}, {"(1", "(2"}, {"2", "1"}, {"-inf", "-inf"}, {"inf", "inf"}, {"(inf", "inf"}, {"", ""}, {"(", "2"}, {"1e400", "-1e400"}, {" 1", "2"}}) {
			g_cmd(g, "ZRANGEBYSCORE", key, b[0], b[1], "WITHSCORES")
			g_cmd(g, "ZCOUNT", key, b[0], b[1])
			g_cmd(g, "ZREVRANGEBYSCORE", key, b[1], b[0])
			g_cmd(g, "ZRANGE", key, b[0], b[1], "BYSCORE", "LIMIT", "1", "2")
		}
	}
	g_cmd(g, "ZRANGE", "rk", "0", "-1", "LIMIT", "0", "1")
	g_cmd(g, "ZRANGE", "rk", "0", "-1", "LIMIT", "0", "-1")
	g_cmd(g, "ZRANGE", "rk", "-", "+", "BYLEX", "WITHSCORES")
	g_cmd(g, "ZRANGEBYLEX", "rk", "-", "+", "WITHSCORES")
	g_cmd(g, "ZRANGE", "rk", "0", "1", "BYSCORE", "BYLEX")
	g_cmd(g, "ZRANGE", "rk", "0", "1", "REV", "REV")
	g_cmd(g, "ZRANGE", "rk", "0", "1", "LIMIT", "1")
	g_cmd(g, "ZRANGE", "rk", "0", "1", "BYSCORE", "LIMIT", "a", "1")
	g_cmd(g, "ZRANGE", "rk", "0", "1", "BYSCORE", "LIMIT", "1", "b")
	g_cmd(g, "ZRANGE", "rk", "a", "1")
	g_cmd(g, "ZRANGE", "rk", "0", "b")
	g_cmd(g, "ZRANGE", "rk", "x", "1", "BYSCORE")
	g_cmd(g, "ZRANGE", "rk", "x", "1", "BYLEX")
	g_cmd(g, "ZREVRANGE", "rk", "0", "1", "BYSCORE")
	g_cmd(g, "ZREVRANGE", "rk", "0", "1", "REV")
	g_cmd(g, "ZRANGEBYSCORE", "rk", "0", "1", "BYLEX")
	g_cmd(g, "ZRANGEBYSCORE", "rk", "0", "1", "REV")
	g_cmd(g, "ZRANGEBYSCORE", "rk", "0", "1", "LIMIT", "0")
	g_cmd(g, "ZRANGE", "nokey", "0", "-1")
	g_cmd(g, "ZRANGE", "nokey", "0", "-1", "BYSCORE")
	g_cmd(g, "ZRANGEBYLEX", "nokey", "-", "+")
	g_cmd(g, "ZCOUNT", "nokey", "0", "1")
	g_cmd(g, "ZCOUNT", "nokey", "a", "1")
	g_cmd(g, "ZLEXCOUNT", "nokey", "-", "+")
	g_cmd(g, "ZLEXCOUNT", "nokey", "a", "+")
}

section_removals :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	for round in 0 ..< 90 {
		slot := round % 6
		key := tp("rm", slot)
		lex_ok := slot >= 3
		if round % 6 == 0 || rng_chance(&g.rng, 20) {
			if round % 12 >= 6 {
				g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "0")
			}
			mode := Score_Mode.Zero if lex_ok else (Score_Mode.Ints if rng_chance(&g.rng, 50) else Score_Mode.Random)
			fill_zset(g, key, 5 + rng_below(&g.rng, 40), mode, "" if rng_chance(&g.rng, 50) else "q")
			g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
		}
		r := &g.rng
		op := rng_below(r, 5)
		for !lex_ok && op == 2 {
			op = rng_below(r, 5)
		}
		switch op {
		case 0:
			g_write(g, key, "ZREMRANGEBYRANK", key, tp(rng_below(r, 30) - 15), tp(rng_below(r, 30) - 15))
		case 1:
			g_write(g, key, "ZREMRANGEBYSCORE", key, gen_range_bound(g), gen_range_bound(g))
		case 2:
			g_write(g, key, "ZREMRANGEBYLEX", key, gen_lex_bound(g), gen_lex_bound(g))
		case 3:
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "ZREM", key)
			for _ in 0 ..< 1 + rng_below(r, 6) {
				append(&args, gen_member(g) if rng_chance(r, 50) else tp("q", rng_below(r, 40)))
			}
			g_cmds(g, args[:])
			g_state(g, key)
		case 4:
			g_cmd(g, "ZRANGE", key, "0", "-1", "WITHSCORES")
		}
		g_cmd(g, "EXISTS", key)
	}
	g_cmd(g, "ZREMRANGEBYRANK", "nokey", "0", "-1")
	g_cmd(g, "ZREMRANGEBYRANK", "rm0", "a", "1")
	g_cmd(g, "ZREMRANGEBYRANK", "rm0", "0", "1.5")
	g_cmd(g, "ZREMRANGEBYSCORE", "rm0", "a", "1")
	g_cmd(g, "ZREMRANGEBYSCORE", "nokey", "a", "1")
	g_cmd(g, "ZREMRANGEBYLEX", "rm0", "a", "+")
	g_cmd(g, "ZREMRANGEBYLEX", "nokey", "-", "+")
	g_write(g, "rmall", "ZADD", "rmall", "1", "a", "2", "b")
	g_write(g, "rmall", "ZREMRANGEBYSCORE", "rmall", "-inf", "+inf")
	g_write(g, "rmall", "ZADD", "rmall", "1", "a", "2", "b")
	g_write(g, "rmall", "ZREMRANGEBYRANK", "rmall", "0", "-1")
	g_write(g, "rmall", "ZADD", "rmall", "1", "a", "2", "b")
	g_write(g, "rmall", "ZREMRANGEBYLEX", "rmall", "-", "+")
}

section_pops :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	for round in 0 ..< 40 {
		skip := round % 4 >= 2
		if skip {
			g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "0")
		}
		fill_zset(g, "pa", 3 + rng_below(&g.rng, 12), .Ints if rng_chance(&g.rng, 50) else .Random)
		fill_zset(g, "pb", 3 + rng_below(&g.rng, 12), .Ints if rng_chance(&g.rng, 50) else .Random)
		g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
		r := &g.rng
		for _ in 0 ..< 6 {
			switch rng_below(r, 6) {
			case 0:
				g_write(g, "pa", "ZPOPMIN", "pa")
			case 1:
				g_write(g, "pa", "ZPOPMAX", "pa", tp(rng_below(r, 8)))
			case 2:
				g_write(g, "pb", "ZPOPMIN", "pb", tp(rng_below(r, 30)))
			case 3:
				g_cmd(g, "ZMPOP", "2", "pa", "pb", "MIN" if rng_chance(r, 50) else "max")
			case 4:
				g_cmd(g, "ZMPOP", "3", "nokey", "pb", "pa", "MAX", "COUNT", tp(1 + rng_below(r, 10)))
			case 5:
				g_cmd(g, "ZMPOP", "1", "nokey", "MIN")
			}
		}
		g_state(g, "pa")
		g_state(g, "pb")
		g_cmd(g, "DEL", "pa", "pb")
	}
	g_cmd(g, "ZPOPMIN", "nokey")
	g_cmd(g, "ZPOPMIN", "nokey", "3")
	g_cmd(g, "ZADD", "pz", "1", "a")
	g_cmd(g, "ZPOPMIN", "pz", "0")
	g_cmd(g, "ZPOPMIN", "pz", "-1")
	g_cmd(g, "ZPOPMIN", "pz", "a")
	g_cmd(g, "ZPOPMIN", "pz", "1", "2")
	g_cmd(g, "ZPOPMAX", "pz", "1.5")
	g_cmd(g, "ZMPOP", "0", "pz", "MIN")
	g_cmd(g, "ZMPOP", "-1", "pz", "MIN")
	g_cmd(g, "ZMPOP", "a", "pz", "MIN")
	g_cmd(g, "ZMPOP", "1", "pz", "MIDDLE")
	g_cmd(g, "ZMPOP", "2", "pz", "MIN")
	g_cmd(g, "ZMPOP", "1", "pz", "MIN", "COUNT")
	g_cmd(g, "ZMPOP", "1", "pz", "MIN", "COUNT", "0")
	g_cmd(g, "ZMPOP", "1", "pz", "MIN", "COUNT", "-1")
	g_cmd(g, "ZMPOP", "1", "pz", "MIN", "COUNT", "1", "COUNT", "2")
	g_cmd(g, "ZMPOP", "1", "pz", "MIN", "foo")
	g_cmd(g, "ZMPOP", "5", "pz", "MIN")
	g_cmd(g, "ZMPOP", "9223372036854775807", "pz", "MIN")
	g_cmd(g, "ZMPOP", "1", "pz", "max", "count", "10")
	g_cmd(g, "EXISTS", "pz")
}

section_random :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	for round in 0 ..< 8 {
		key := tp("rd", round)
		if round >= 4 {
			g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "0")
		}
		fill_zset(g, key, 1 + rng_below(&g.rng, 25) if round % 2 == 0 else 60, .Ints if rng_chance(&g.rng, 50) else .Random)
		g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
		counts := [?]string{"0", "1", "-1", "2", "-2", "5", "-5", "10", "-10", "20", "-20", "25", "100", "-100", "1000", "-1500", "59", "60", "61", "19", "21"}
		for c in counts {
			g_cmd(g, "ZRANDMEMBER", key, c)
			g_cmd(g, "ZRANDMEMBER", key, c, "WITHSCORES")
		}
		g_cmd(g, "ZRANDMEMBER", key)
		g_cmd(g, "ZRANDMEMBER", key)
	}
	g_cmd(g, "ZRANDMEMBER", "nokey")
	g_cmd(g, "ZRANDMEMBER", "nokey", "5")
	g_cmd(g, "ZRANDMEMBER", "nokey", "-5", "WITHSCORES")
	g_cmd(g, "ZRANDMEMBER", "rd0", "abc")
	g_cmd(g, "ZRANDMEMBER", "rd0", "1", "WITHSCORE")
	g_cmd(g, "ZRANDMEMBER", "rd0", "1", "WITHSCORES", "x")
	g_cmd(g, "ZRANDMEMBER", "rd0", "-9223372036854775808")
	g_cmd(g, "ZRANDMEMBER", "rd0", "-9223372036854775808", "WITHSCORES")
	g_cmd(g, "ZRANDMEMBER", "rd0", "-9223372036854770000", "WITHSCORES")
	g_cmd(g, "ZRANDMEMBER", "rd0", "9223372036854770000", "WITHSCORES")
	g_cmd(g, "ZRANDMEMBER", "nokey", "abc")
}

section_algebra :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	cmds := [?]string{"ZUNION", "ZINTER", "ZDIFF", "ZINTERCARD", "ZUNIONSTORE", "ZINTERSTORE", "ZDIFFSTORE"}
	weights := [?]string{"1", "2", "0", "-1", "0.5", "inf", "-inf", "1.5", "3", "1e300", "-0"}
	for round in 0 ..< 80 {
		r := &g.rng
		if round % 10 == 0 {
			for k in 0 ..< 4 {
				if rng_chance(r, 30) {
					g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "0")
				}
				key := tp("al", k)
				g_cmd(g, "DEL", key)
				args := make([dynamic]string, context.temp_allocator)
				append(&args, "ZADD", key)
				for _ in 0 ..< 1 + rng_below(r, 15) {
					sc := pick(r, []string{"1", "2", "-3", "inf", "-inf", "0.1", "0.2", "1.5", "7", "1e300", "-1e300", "100"})
					append(&args, sc, tp("x", rng_below(r, 12)))
				}
				g_cmds(g, args[:])
				g_state(g, key)
				g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
			}
		}
		cmd := cmds[rng_below(r, len(cmds))]
		store := strings.has_suffix(cmd, "STORE")
		args := make([dynamic]string, context.temp_allocator)
		append(&args, cmd)
		dst := pick(r, []string{"dst", "al0", "al1", "dst2"})
		if store {
			append(&args, dst)
		}
		n := 1 + rng_below(r, 4)
		append(&args, tp(n))
		for _ in 0 ..< n {
			append(&args, pick(r, []string{"al0", "al1", "al2", "al3", "nokey", "al0"}))
		}
		if cmd != "ZDIFF" && cmd != "ZDIFFSTORE" && cmd != "ZINTERCARD" {
			if rng_chance(r, 50) {
				append(&args, "WEIGHTS")
				for _ in 0 ..< n {
					append(&args, weights[rng_below(r, len(weights))])
				}
			}
			if rng_chance(r, 50) {
				append(&args, "AGGREGATE", pick(r, []string{"SUM", "MIN", "MAX", "sum", "min", "max"}))
			}
		}
		if cmd == "ZINTERCARD" && rng_chance(r, 50) {
			append(&args, "LIMIT", tp(rng_below(r, 5)))
		}
		if !store && cmd != "ZINTERCARD" && rng_chance(r, 60) {
			append(&args, "WITHSCORES")
		}
		g_cmds(g, args[:])
		if store {
			g_state(g, dst)
			g_cmd(g, "ZRANGE", dst, "0", "-1", "WITHSCORES")
		}
	}
	g_cmd(g, "ZADD", "ia", "inf", "x", "-inf", "y", "1", "z")
	g_cmd(g, "ZADD", "ib", "-inf", "x", "inf", "y", "0", "z")
	for agg in ([?]string{"SUM", "MIN", "MAX"}) {
		g_cmd(g, "ZUNION", "2", "ia", "ib", "AGGREGATE", agg, "WITHSCORES")
		g_cmd(g, "ZINTER", "2", "ia", "ib", "AGGREGATE", agg, "WITHSCORES")
		g_cmd(g, "ZUNION", "2", "ia", "ib", "WEIGHTS", "0", "0", "AGGREGATE", agg, "WITHSCORES")
		g_cmd(g, "ZINTER", "2", "ia", "ib", "WEIGHTS", "0", "1", "AGGREGATE", agg, "WITHSCORES")
		g_cmd(g, "ZINTER", "2", "ia", "ib", "WEIGHTS", "1", "0", "AGGREGATE", agg, "WITHSCORES")
		g_cmd(g, "ZINTER", "2", "ia", "ia", "WEIGHTS", "0", "-1", "AGGREGATE", agg, "WITHSCORES")
		g_cmd(g, "ZUNION", "3", "ia", "ib", "ia", "WEIGHTS", "inf", "-inf", "1", "AGGREGATE", agg, "WITHSCORES")
	}
	g_write(g, "ia", "ZUNIONSTORE", "ia", "2", "ia", "ib")
	g_write(g, "ib", "ZINTERSTORE", "ib", "2", "ia", "ib", "WEIGHTS", "2", "3")
	g_write(g, "ia", "ZDIFFSTORE", "ia", "2", "ia", "ia")
	g_write(g, "ib", "ZDIFFSTORE", "ib", "1", "ib")
	g_cmd(g, "SET", "str", "v")
	errs := [?][]string {
		{"ZUNION", "0", "al0"},
		{"ZUNION", "-1", "al0"},
		{"ZUNION", "abc", "al0"},
		{"ZUNION", "3", "al0", "al1"},
		{"ZUNION", "2", "al0", "str"},
		{"ZUNION", "2", "str", "nokey", "WEIGHTS", "x"},
		{"ZUNION", "2", "al0", "al1", "WEIGHTS", "1"},
		{"ZUNION", "2", "al0", "al1", "WEIGHTS", "1", "x"},
		{"ZUNION", "2", "al0", "al1", "WEIGHTS", "1", "nan"},
		{"ZUNION", "2", "al0", "al1", "AGGREGATE", "avg"},
		{"ZUNION", "2", "al0", "al1", "AGGREGATE"},
		{"ZUNION", "2", "al0", "al1", "FOO"},
		{"ZUNION", "1", "al0", "WITHSCORES", "WITHSCORES"},
		{"ZUNIONSTORE", "d", "0", "al0"},
		{"ZUNIONSTORE", "d", "1", "al0", "WITHSCORES"},
		{"ZINTERSTORE", "d", "1", "al0", "WITHSCORES"},
		{"ZDIFFSTORE", "d", "1", "al0", "WITHSCORES"},
		{"ZDIFF", "2", "al0", "al1", "WEIGHTS", "1", "1"},
		{"ZDIFF", "1", "al0", "AGGREGATE", "SUM"},
		{"ZINTERCARD", "0", "al0"},
		{"ZINTERCARD", "1", "al0", "LIMIT", "-1"},
		{"ZINTERCARD", "1", "al0", "LIMIT", "x"},
		{"ZINTERCARD", "1", "al0", "LIMIT"},
		{"ZINTERCARD", "1", "al0", "WITHSCORES"},
		{"ZINTERCARD", "2", "al0", "al0"},
		{"ZINTERCARD", "1", "al0", "al0"},
		{"ZINTERCARD", "1", "al0", "WEIGHTS", "1"},
		{"ZINTERCARD", "2", "al0", "str"},
		{"ZINTER", "1", "al0", "LIMIT", "1"},
		{"ZINTERCARD", "9223372036854775807", "al0"},
		{"ZUNIONSTORE", "str", "1", "al0"},
		{"ZUNIONSTORE", "al3", "1", "nokey"},
	}
	for e in errs {
		g_cmds(g, e)
	}
	g_cmd(g, "TYPE", "str")
	g_cmd(g, "EXISTS", "al3")
}

section_scan :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	for round in 0 ..< 12 {
		key := tp("sn", round)
		if round % 2 == 1 {
			g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "0")
		}
		fill_zset(g, key, 3 + rng_below(&g.rng, 200), .Ints if rng_chance(&g.rng, 50) else .Random, "" if round % 3 == 0 else "s")
		g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
		g_cmd(g, "ZSCAN", key, "0")
		g_cmd(g, "ZSCAN", key, "0", "COUNT", "1")
		g_cmd(g, "ZSCAN", key, "0", "COUNT", "100")
		g_cmd(g, "ZSCAN", key, "0", "MATCH", "s1*")
		g_cmd(g, "ZSCAN", key, "0", "MATCH", "*[0-3]", "COUNT", "7")
		g_cmd(g, "ZSCAN", key, "0", "MATCH", "*")
	}
	g_cmd(g, "ZSCAN", "nokey", "0")
	g_cmd(g, "ZSCAN", "sn0", "abc")
	g_cmd(g, "ZSCAN", "sn0", "-1")
	g_cmd(g, "ZSCAN", "sn0", "18446744073709551615")
	g_cmd(g, "ZSCAN", "sn0", "0", "COUNT", "0")
	g_cmd(g, "ZSCAN", "sn0", "0", "COUNT", "x")
	g_cmd(g, "ZSCAN", "sn0", "0", "NOVALUES")
	g_cmd(g, "ZSCAN", "sn0", "0", "TYPE", "zset")
	g_cmd(g, "ZSCAN", "sn0", "0", "FOO")
	g_cmd(g, "ZSCAN", "sn0", "0", "MATCH")
	g_cmd(g, "ZSCAN", "sn1", "123", "COUNT", "5")
}

section_errors :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "SET", "s", "string")
	g_cmd(g, "ZADD", "z", "1", "a")
	wrong := [?][]string {
		{"ZADD", "s", "1", "a"},
		{"ZINCRBY", "s", "1", "a"},
		{"ZREM", "s", "a"},
		{"ZCARD", "s"},
		{"ZSCORE", "s", "a"},
		{"ZMSCORE", "s", "a"},
		{"ZRANK", "s", "a"},
		{"ZREVRANK", "s", "a", "WITHSCORE"},
		{"ZRANGE", "s", "0", "-1"},
		{"ZRANGESTORE", "d", "s", "0", "-1"},
		{"ZRANGESTORE", "s", "z", "0", "-1"},
		{"ZREVRANGE", "s", "0", "-1"},
		{"ZRANGEBYSCORE", "s", "0", "1"},
		{"ZRANGEBYLEX", "s", "-", "+"},
		{"ZCOUNT", "s", "0", "1"},
		{"ZLEXCOUNT", "s", "-", "+"},
		{"ZREMRANGEBYRANK", "s", "0", "1"},
		{"ZREMRANGEBYSCORE", "s", "0", "1"},
		{"ZREMRANGEBYLEX", "s", "-", "+"},
		{"ZPOPMIN", "s"},
		{"ZPOPMAX", "s", "2"},
		{"ZMPOP", "2", "nokey", "s", "MIN"},
		{"ZMPOP", "2", "z", "s", "MIN", "COUNT", "0"},
		{"ZRANDMEMBER", "s"},
		{"ZRANDMEMBER", "s", "2"},
		{"ZSCAN", "s", "0"},
		{"ZUNION", "1", "s"},
		{"ZINTERCARD", "1", "s"},
		{"GET", "z"},
		{"ZCOUNT", "s", "a", "1"},
		{"ZADD", "s", "x", "a"},
		{"ZADD", "s", "XX", "NX", "1", "a"},
	}
	for w in wrong {
		g_cmds(g, w)
	}
	g_cmd(g, "GET", "s")
	g_state(g, "z")
	arity := [?][]string {
		{"ZADD", "k", "1"},
		{"ZINCRBY", "k", "1"},
		{"ZINCRBY", "k", "1", "a", "b"},
		{"ZREM", "k"},
		{"ZCARD"},
		{"ZCARD", "k", "x"},
		{"ZSCORE", "k"},
		{"ZMSCORE", "k"},
		{"ZRANK", "k"},
		{"ZRANK", "k", "a", "WITHSCORE", "x"},
		{"ZRANGE", "k", "0"},
		{"ZRANGESTORE", "d", "k", "0"},
		{"ZREVRANGE", "k", "0"},
		{"ZRANGEBYSCORE", "k", "0"},
		{"ZREVRANGEBYSCORE", "k", "0"},
		{"ZRANGEBYLEX", "k", "-"},
		{"ZREVRANGEBYLEX", "k", "-"},
		{"ZCOUNT", "k", "0"},
		{"ZLEXCOUNT", "k", "-", "+", "x"},
		{"ZREMRANGEBYRANK", "k", "0"},
		{"ZREMRANGEBYSCORE", "k", "0", "1", "2"},
		{"ZREMRANGEBYLEX", "k"},
		{"ZUNIONSTORE", "d", "1"},
		{"ZINTERSTORE", "d"},
		{"ZDIFFSTORE", "d", "1"},
		{"ZUNION", "1"},
		{"ZINTER", "1"},
		{"ZINTERCARD", "1"},
		{"ZDIFF", "1"},
		{"ZSCAN", "k"},
		{"ZPOPMIN"},
		{"ZPOPMAX"},
		{"ZMPOP", "1", "k"},
		{"ZRANDMEMBER"},
	}
	for a in arity {
		g_cmds(g, a)
	}
}

section_duplicates :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	for enc in ([?]string{"128", "0"}) {
		g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", enc)
		g_write(g, "dup", "ZADD", "dup", "1", "a", "2", "a", "3", "b", "0", "a")
		g_write(g, "dup", "ZADD", "dup", "CH", "5", "a", "5", "a", "6", "b")
		g_write(g, "dup", "ZADD", "dup", "NX", "9", "c", "10", "c")
		g_write(g, "dup", "ZADD", "dup", "GT", "CH", "1", "c", "20", "c", "15", "c")
		g_write(g, "dup", "ZADD", "dup", "1", "7", "2", "007", "3", "-0", "4", "0", "5", "+1", "6", "1")
		g_cmd(g, "ZRANGE", "dup", "0", "-1", "WITHSCORES")
		g_cmd(g, "ZMSCORE", "dup", "a", "a", "7", "007", "0", "-0", "1", "+1")
		g_cmd(g, "ZRANK", "dup", "007", "WITHSCORE")
		g_cmd(g, "ZRANK", "dup", "7", "WITHSCORE")
		g_write(g, "dup", "ZREM", "dup", "a", "a", "7", "007", "+1")
		g_write(g, "dup", "ZINCRBY", "dup", "1", "0")
		g_write(g, "dup", "ZINCRBY", "dup", "-1", "-0")
		g_cmd(g, "ZRANGEBYLEX", "dup", "-", "+")
		g_cmd(g, "ZSCAN", "dup", "0")
		g_cmd(g, "DEL", "dup")
	}
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
}

section_fuzz :: proc(g: ^Gen, rounds: int) {
	g_cmd(g, "FLUSHALL")
	mixed := [?]string{"f0", "f1"}
	lexk := [?]string{"f2", "f3"}
	for i in 0 ..< rounds {
		r := &g.rng
		lex_ok := rng_chance(r, 40)
		keys := lexk if lex_ok else mixed
		key := keys[rng_below(r, len(keys))]
		if i % 400 == 0 {
			lims := [?]string{"128", "4", "16", "0", "1", "300"}
			vals := [?]string{"64", "8", "0", "200"}
			g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", lims[rng_below(r, len(lims))])
			g_cmd(g, "CONFIG", "SET", "zset-max-listpack-value", vals[rng_below(r, len(vals))])
		}
		switch rng_below(r, 20) {
		case 0 ..= 5:
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "ZADD", key)
			if rng_chance(r, 25) {
				opts := [?]string{"NX", "XX", "GT", "LT", "CH"}
				append(&args, opts[rng_below(r, len(opts))])
			}
			for _ in 0 ..< 1 + rng_below(r, 6) {
				append(&args, "0" if lex_ok else gen_score(g), gen_member(g))
			}
			g_cmds(g, args[:])
		case 6:
			g_cmd(g, "ZINCRBY", key, "0" if lex_ok else gen_score(g), gen_member(g))
		case 7:
			g_cmd(g, "ZREM", key, gen_member(g), gen_member(g))
		case 8 ..= 10:
			random_range_cmd(g, key, lex_ok)
		case 11:
			g_cmd(g, "ZPOPMIN" if rng_chance(r, 50) else "ZPOPMAX", key, tp(rng_below(r, 4)))
		case 12:
			g_cmd(g, "ZREMRANGEBYSCORE", key, gen_range_bound(g), gen_range_bound(g))
		case 13:
			if lex_ok {
				g_cmd(g, "ZREMRANGEBYLEX", key, gen_lex_bound(g), gen_lex_bound(g))
			} else {
				g_cmd(g, "ZREMRANGEBYSCORE", key, gen_range_bound(g), gen_range_bound(g))
			}
		case 14:
			g_cmd(g, "ZREMRANGEBYRANK", key, tp(rng_below(r, 10) - 5), tp(rng_below(r, 10) - 5))
		case 15:
			cmd := pick(r, []string{"ZUNIONSTORE", "ZINTERSTORE", "ZDIFFSTORE"})
			g_cmd(g, cmd, keys[rng_below(r, 2)], "2", keys[rng_below(r, 2)], keys[rng_below(r, 2)])
		case 16:
			g_cmd(g, "ZRANGESTORE", keys[rng_below(r, 2)], key, gen_range_bound(g), gen_range_bound(g), "BYSCORE")
		case 17:
			g_cmd(g, "ZSCAN", key, "0", "COUNT", tp(1 + rng_below(r, 20)))
		case 18:
			g_cmd(g, "ZRANDMEMBER", key, tp(rng_below(r, 20) - 10), "WITHSCORES")
		case 19:
			g_cmd(g, "ZMSCORE", key, gen_member(g), gen_member(g))
		}
		if i % 5 == 0 {
			g_state(g, key)
		}
	}
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-value", "64")
}

section_parity :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-entries", "128")
	g_cmd(g, "CONFIG", "SET", "zset-max-listpack-value", "64")
	g_cmd(g, "ZADD", "r", "1", "a", "2", "b", "3", "c", "4", "d")
	for limit in ([?][2]string{{"1", "-1"}, {"5", "-1"}, {"-1", "-1"}, {"3", "-1"}, {"9223372036854775807", "-1"}, {"0", "-1"}, {"0", "-5"}, {"0", "0"}, {"1", "0"}, {"-1", "0"}, {"0", "-2"}, {"0", "2"}, {"1", "-5"}, {"x", "-1"}, {"1", "x"}}) {
		g_cmd(g, "ZRANGE", "r", "0", "-1", "LIMIT", limit[0], limit[1])
		g_cmd(g, "ZRANGE", "r", "1", "2", "REV", "LIMIT", limit[0], limit[1])
	}
	g_cmd(g, "ZRANGE", "r", "1", "2", "LIMIT", "3", "-1", "WITHSCORES")
	g_cmd(g, "ZRANGE", "r", "0", "-1", "LIMIT", "1", "-1", "LIMIT", "0", "2")
	g_cmd(g, "ZRANGE", "r", "0", "-1", "LIMIT", "0", "2", "LIMIT", "1", "-1")
	g_cmd(g, "ZRANGESTORE", "rd", "r", "0", "-1", "LIMIT", "1", "-1")
	g_state(g, "rd")
	g_cmd(g, "ZRANGESTORE", "rd", "r", "1", "2", "REV", "LIMIT", "7", "-1")
	g_state(g, "rd")
	g_cmd(g, "ZADD", "x", "0", "a", "0", "b", "0", "a\x00b")
	for bounds in ([?][2]string{{"-", "+\x00abc"}, {"-\x00x", "+"}, {"-\x00", "+\x00"}, {"+\x00", "-\x00"}, {"-", "+abc"}, {"-x", "+"}, {"\x00", "+"}, {"(a\x00", "+"}, {"[a\x00b", "[a\x00b"}}) {
		g_cmd(g, "ZRANGEBYLEX", "x", bounds[0], bounds[1])
		g_cmd(g, "ZREVRANGEBYLEX", "x", bounds[1], bounds[0])
		g_cmd(g, "ZLEXCOUNT", "x", bounds[0], bounds[1])
		g_cmd(g, "ZRANGE", "x", bounds[0], bounds[1], "BYLEX")
	}
	g_cmd(g, "ZRANGESTORE", "xd", "x", "-\x00", "+\x00", "BYLEX")
	g_state(g, "xd")
	g_cmd(g, "ZREMRANGEBYLEX", "x", "-\x00a", "+\x00")
	g_state(g, "x")
	mixed := [?][]string{{"1", "b", "2", "a", "0", "d", "3", "c", "1", "e", "5", "aa"}, {"0", "b", "1", "z", "2", "c", "3", "a", "4", "d"}, {"0", "b", "1", "a", "2", "c"}, {"0", "c", "1", "a", "2", "b"}, {"0", "b", "1", "z", "2", "c"}}
	queries := [?][]string{{"ZLEXCOUNT", "[b", "+"}, {"ZLEXCOUNT", "-", "[c"}, {"ZLEXCOUNT", "[aa", "[d"}, {"ZLEXCOUNT", "[a", "[d"}, {"ZLEXCOUNT", "[b", "[c"}, {"ZLEXCOUNT", "(a", "+"}, {"ZLEXCOUNT", "[c", "[d"}, {"ZRANGEBYLEX", "[b", "[e"}, {"ZRANGEBYLEX", "-", "[c", "LIMIT", "0", "5"}, {"ZRANGEBYLEX", "[a", "[d"}, {"ZRANGEBYLEX", "[a", "[d", "LIMIT", "1", "5"}, {"ZRANGEBYLEX", "[a", "[d", "LIMIT", "2", "5"}, {"ZRANGEBYLEX", "[c", "[d", "LIMIT", "0", "5"}, {"ZRANGEBYLEX", "[c", "[d", "LIMIT", "1", "5"}, {"ZRANGEBYLEX", "[b", "[c"}, {"ZRANGEBYLEX", "(a", "+"}, {"ZREVRANGEBYLEX", "+", "[b", "LIMIT", "0", "5"}, {"ZREVRANGEBYLEX", "[e", "-", "LIMIT", "0", "5"}, {"ZREVRANGEBYLEX", "[d", "[a"}, {"ZREVRANGEBYLEX", "[d", "[a", "LIMIT", "1", "5"}, {"ZREVRANGEBYLEX", "[d", "[a", "LIMIT", "2", "5"}, {"ZREVRANGEBYLEX", "[c", "[b"}, {"ZREVRANGEBYLEX", "(c", "[a"}, {"ZREVRANGEBYLEX", "[b", "[a"}, {"ZREVRANGEBYLEX", "[bb", "[b", "LIMIT", "0", "5"}, {"ZRANGE", "[b", "[e", "BYLEX"}, {"ZRANGE", "[e", "[b", "BYLEX", "REV", "LIMIT", "0", "5"}, {"ZRANGE", "[a", "[d", "BYLEX", "LIMIT", "2", "5"}}
	for members, i in mixed {
		key := tp("m", i)
		a := make([dynamic]string, context.temp_allocator)
		append(&a, "ZADD", key)
		append(&a, ..members)
		g_cmds(g, a[:])
		for q in queries {
			b := make([dynamic]string, context.temp_allocator)
			append(&b, q[0], key)
			append(&b, ..q[1:])
			g_cmds(g, b[:])
		}
		g_cmd(g, "ZRANGESTORE", "md", key, "[a", "[d", "BYLEX", "LIMIT", "2", "5")
		g_state(g, "md")
		g_cmd(g, "ZREMRANGEBYLEX", key, "[a", "[c")
		g_state(g, key)
	}
	g_cmd(g, "FLUSHALL")
}

run_gen :: proc(dir: string) -> bool {
	g := Gen {
		buf = make([dynamic]u8),
		rng = Rng{s = 0x5EED_2E75},
	}
	for proto in ([?]string{"2", "3"}) {
		g_cmd(&g, "HELLO", proto)
		section_basic(&g)
		section_zadd_options(&g)
		section_scores(&g)
		section_conversions(&g)
		section_ranges(&g)
		section_removals(&g)
		section_pops(&g)
		section_random(&g)
		section_algebra(&g)
		section_scan(&g)
		section_errors(&g)
		section_duplicates(&g)
		section_parity(&g)
		section_fuzz(&g, 9000 if proto == "2" else 3000)
		free_all(context.temp_allocator)
	}
	g_cmd(&g, "HELLO", "2")
	path := fmt.tprintf("%s/script.resp", dir)
	if err := os.write_entire_file(path, g.buf[:]); err != nil {
		fmt.eprintln("cannot write", path)
		return false
	}
	fmt.printfln("generated %d commands, %d bytes", g.n, len(g.buf))
	delete(g.buf)
	return true
}
