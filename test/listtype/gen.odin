package listtype_harness

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
	g_cmd(g, "DEBUG", "OBJECT", key)
}

g_write :: proc(g: ^Gen, key: string, args: ..string) {
	g_cmd(g, ..args)
	g_state(g, key)
}

g_full :: proc(g: ^Gen, key: string) {
	g_cmd(g, "LLEN", key)
	g_cmd(g, "LRANGE", key, "0", "-1")
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

INT_EDGES := [?]string{"0", "1", "12", "127", "128", "-1", "-128", "-129", "4095", "4096", "-4096", "-4097", "32767", "-32768", "32768", "-32769", "8388607", "-8388608", "8388608", "2147483647", "-2147483648", "2147483648", "9223372036854775807", "-9223372036854775808"}
NONCANON := [?]string{"007", "+1", "-0", "1.0", "9223372036854775808", "-9223372036854775809", "00", "-", " 11", "11 ", "0x10", "1e3", "abc", ""}
STR_LENS := [?]int{0, 1, 11, 12, 63, 64, 65, 4095, 4096, 4097}

gen_value :: proc(g: ^Gen) -> string {
	r := &g.rng
	switch rng_below(r, 12) {
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
		b := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			b[i] = u8(rng_next(r))
		}
		return string(b)
	case:
		return gen_small(g)
	}
}

gen_small :: proc(g: ^Gen) -> string {
	r := &g.rng
	pool := [?]string{"a", "b", "c", "d", "x", "y", "1", "2", "10", "-1", "hello", ""}
	return pool[rng_below(r, len(pool))]
}

gen_large :: proc(g: ^Gen) -> string {
	r := &g.rng
	lens := [?]int{4096, 8180, 8184, 8185, 8188, 8191, 8192, 8193, 9000, 16384, 16385, 20000, 32768, 65536, 70000}
	return rep(u8('A' + rng_below(r, 4)), lens[rng_below(r, len(lens))])
}

INDEX_SHAPES :: proc(n: int) -> [16]string {
	return [16]string {
		"0",
		"1",
		"-1",
		"-2",
		tp(n - 1),
		tp(n),
		tp(n + 1),
		tp(-n),
		tp(-n - 1),
		tp(-n + 1),
		tp(n / 2),
		tp(-n / 2),
		"9223372036854775807",
		"-9223372036854775808",
		"100000",
		"-100000",
	}
}

build_list :: proc(g: ^Gen, key: string, n: int, large: bool) {
	g_cmd(g, "DEL", key)
	if n == 0 {
		return
	}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "RPUSH", key)
	for i in 0 ..< n {
		if large && i == n / 2 {
			append(&args, gen_large(g))
		} else if i % 3 == 0 {
			append(&args, tp(i))
		} else {
			append(&args, tp("e", i))
		}
	}
	g_cmds(g, args[:])
	g_state(g, key)
}

section_basic :: proc(g: ^Gen) {
	cmds := [?][]string {
		{"FLUSHALL"},
		{"LPUSH", "l", "a", "b", "c"},
		{"RPUSH", "l", "1", "2", "-3", "9223372036854775807", ""},
		{"LPUSHX", "l", "x"},
		{"RPUSHX", "l", "y", "z"},
		{"LPUSHX", "nokey", "x"},
		{"RPUSHX", "nokey", "x"},
		{"EXISTS", "nokey"},
		{"LRANGE", "l", "0", "-1"},
		{"LLEN", "l"},
		{"LLEN", "nokey"},
		{"LINDEX", "l", "0"},
		{"LINDEX", "l", "-1"},
		{"LINDEX", "l", "100"},
		{"LINDEX", "l", "abc"},
		{"LINDEX", "nokey", "abc"},
		{"LINDEX", "nokey", "0"},
		{"LPOP", "l"},
		{"RPOP", "l"},
		{"LPOP", "l", "2"},
		{"RPOP", "l", "2"},
		{"LPOP", "l", "0"},
		{"LPOP", "nokey", "0"},
		{"LPOP", "nokey"},
		{"RPOP", "nokey", "3"},
		{"LPOP", "l", "-1"},
		{"LPOP", "l", "abc"},
		{"LPOP", "l", "1", "2"},
		{"RPOP", "l", "1", "2"},
		{"LSET", "l", "0", "x"},
		{"LSET", "l", "-1", "tail"},
		{"LSET", "l", "10", "x"},
		{"LSET", "l", "-10", "x"},
		{"LSET", "nokey", "0", "x"},
		{"LSET", "l", "abc", "x"},
		{"LINSERT", "l", "BEFORE", "x", "y"},
		{"LINSERT", "l", "after", "x", "z"},
		{"LINSERT", "l", "AfTeR", "tail", "end"},
		{"LINSERT", "l", "middle", "x", "z"},
		{"LINSERT", "l", "before", "nopivot", "z"},
		{"LINSERT", "nokey", "before", "a", "b"},
		{"LINSERT", "nokey", "middle", "a", "b"},
		{"LRANGE", "l", "0", "-1"},
		{"RPUSH", "p", "a", "b", "c", "1", "2", "3", "c", "c", "a"},
		{"LPOS", "p", "c"},
		{"LPOS", "p", "c", "RANK", "1"},
		{"LPOS", "p", "c", "RANK", "2"},
		{"LPOS", "p", "c", "RANK", "4"},
		{"LPOS", "p", "c", "RANK", "-1"},
		{"LPOS", "p", "c", "RANK", "-2"},
		{"LPOS", "p", "c", "RANK", "0"},
		{"LPOS", "p", "c", "RANK", "-9223372036854775808"},
		{"LPOS", "p", "c", "RANK", "9223372036854775807"},
		{"LPOS", "p", "c", "RANK", "abc"},
		{"LPOS", "p", "c", "COUNT", "0"},
		{"LPOS", "p", "c", "COUNT", "1"},
		{"LPOS", "p", "c", "COUNT", "2"},
		{"LPOS", "p", "c", "COUNT", "100"},
		{"LPOS", "p", "c", "COUNT", "-1"},
		{"LPOS", "p", "c", "COUNT", "abc"},
		{"LPOS", "p", "c", "COUNT", "0", "RANK", "2"},
		{"LPOS", "p", "c", "COUNT", "2", "RANK", "-1"},
		{"LPOS", "p", "a", "COUNT", "0", "MAXLEN", "1"},
		{"LPOS", "p", "c", "COUNT", "0", "MAXLEN", "1"},
		{"LPOS", "p", "c", "COUNT", "0", "MAXLEN", "3"},
		{"LPOS", "p", "c", "COUNT", "0", "MAXLEN", "3", "RANK", "-1"},
		{"LPOS", "p", "c", "COUNT", "0", "MAXLEN", "7", "RANK", "2"},
		{"LPOS", "p", "c", "MAXLEN", "-1"},
		{"LPOS", "p", "c", "MAXLEN", "abc"},
		{"LPOS", "p", "1"},
		{"LPOS", "p", "01"},
		{"LPOS", "p", "x", "COUNT", "2", "RANK", "-1"},
		{"LPOS", "p", "x", "RANK", "-1"},
		{"LPOS", "p", "c", "FOO"},
		{"LPOS", "p", "c", "RANK"},
		{"LPOS", "p", "c", "COUNT"},
		{"LPOS", "p", "c", "rank", "1", "count", "1", "maxlen", "0"},
		{"LPOS", "nokey", "c", "COUNT", "0", "RANK", "2"},
		{"LPOS", "nokey", "c"},
		{"LPOS", "nokey", "c", "RANK", "0"},
		{"RPUSH", "r", "a", "b", "a", "c", "a", "d", "a", "1", "01", "1"},
		{"LREM", "r", "2", "a"},
		{"LREM", "r", "-1", "a"},
		{"LREM", "r", "0", "a"},
		{"LREM", "r", "0", "1"},
		{"LREM", "r", "0", "zz"},
		{"LREM", "r", "abc", "a"},
		{"LREM", "r", "-9223372036854775808", "a"},
		{"LREM", "r", "9223372036854775807", "b"},
		{"LREM", "nokey", "1", "a"},
		{"LRANGE", "r", "0", "-1"},
		{"LTRIM", "r", "0", "0"},
		{"LTRIM", "r", "5", "1"},
		{"EXISTS", "r"},
		{"LTRIM", "nokey", "0", "1"},
		{"LTRIM", "p", "abc", "1"},
		{"LTRIM", "p", "1", "abc"},
		{"LRANGE", "p", "abc", "1"},
		{"LRANGE", "p", "1", "abc"},
		{"LRANGE", "nokey", "abc", "1"},
		{"LRANGE", "nokey", "0", "-1"},
		{"RPUSH", "m", "1", "2", "3", "4", "5"},
		{"LMOVE", "m", "m", "LEFT", "RIGHT"},
		{"LMOVE", "m", "m", "RIGHT", "LEFT"},
		{"LMOVE", "m", "m", "LEFT", "LEFT"},
		{"LMOVE", "m", "m", "RIGHT", "RIGHT"},
		{"LRANGE", "m", "0", "-1"},
		{"LMOVE", "m", "n", "LEFT", "RIGHT"},
		{"LMOVE", "m", "n", "RIGHT", "LEFT"},
		{"LMOVE", "m", "n", "LEFT", "LEFT"},
		{"LMOVE", "m", "n", "RIGHT", "RIGHT"},
		{"LRANGE", "m", "0", "-1"},
		{"LRANGE", "n", "0", "-1"},
		{"RPOPLPUSH", "m", "n"},
		{"RPOPLPUSH", "nokey", "n"},
		{"LMOVE", "nokey", "n", "LEFT", "RIGHT"},
		{"EXISTS", "m"},
		{"LMOVE", "n", "m", "up", "down"},
		{"LMOVE", "n", "m", "LEFT", "down"},
		{"LMOVE", "nokey", "m", "up", "LEFT"},
		{"SET", "s", "str"},
		{"LMOVE", "n", "s", "LEFT", "RIGHT"},
		{"LMOVE", "s", "n", "LEFT", "RIGHT"},
		{"RPOPLPUSH", "n", "s"},
		{"RPOPLPUSH", "s", "n"},
		{"RPOPLPUSH", "n", "n"},
		{"RPUSH", "a1", "1", "2", "3"},
		{"RPUSH", "a2", "4", "5", "6"},
		{"LMPOP", "2", "nokey", "a1", "LEFT"},
		{"LMPOP", "2", "nokey", "a1", "RIGHT", "COUNT", "10"},
		{"EXISTS", "a1"},
		{"LMPOP", "2", "a1", "a2", "RIGHT", "COUNT", "2"},
		{"LMPOP", "3", "nokey", "s", "a2", "LEFT"},
		{"LMPOP", "3", "nokey", "a2", "s", "LEFT"},
		{"LMPOP", "2", "nokey", "nokey2", "LEFT"},
		{"LMPOP", "2", "nokey", "nokey2", "LEFT", "COUNT", "5"},
		{"LMPOP", "0", "a", "LEFT"},
		{"LMPOP", "-1", "a", "LEFT"},
		{"LMPOP", "abc", "a", "LEFT"},
		{"LMPOP", "9223372036854775807", "a", "LEFT"},
		{"LMPOP", "1", "a", "LEFT", "COUNT", "0"},
		{"LMPOP", "1", "a", "LEFT", "COUNT", "-1"},
		{"LMPOP", "1", "a", "LEFT", "COUNT", "abc"},
		{"LMPOP", "5", "a", "LEFT"},
		{"LMPOP", "2", "a", "LEFT"},
		{"LMPOP", "1", "a2", "LEFT", "COUNT", "1", "COUNT", "2"},
		{"LMPOP", "1", "a2", "LEFT", "FOO"},
		{"LMPOP", "1", "a2", "LEFT", "COUNT"},
		{"LMPOP", "1", "a2", "MIDDLE"},
		{"LMPOP", "1", "a2", "left", "count", "1"},
		{"LMPOP", "1", "a2", "LEFT"},
		{"LMPOP", "1", "a2"},
		{"LPUSHX", "a2", "x", "y"},
		{"RPUSHX", "a2", "z"},
		{"LRANGE", "a2", "0", "-1"},
		{"LPUSH", "s", "a"},
		{"COPY", "a2", "a3"},
		{"LRANGE", "a3", "0", "-1"},
		{"COPY", "a2", "a3"},
		{"TYPE", "a2"},
		{"TYPE", "s"},
		{"TYPE", "nokey"},
		{"DEBUG", "LISTPACK", "a2"},
		{"DEBUG", "LISTPACK", "s"},
		{"DEBUG", "LISTPACK", "nokey"},
		{"DEBUG", "OBJECT", "nokey"},
	}
	for c in cmds {
		g_cmds(g, c)
		if len(c) > 1 && c[0] != "LRANGE" && c[0] != "LINDEX" && c[0] != "LPOS" && c[0] != "LLEN" {
			g_state(g, c[1])
		}
	}
}

section_errors :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "SET", "s", "v")
	g_cmd(g, "RPUSH", "l", "a", "b")
	arity := [?][]string {
		{"LPUSH"},
		{"LPUSH", "k"},
		{"RPUSH", "k"},
		{"LPUSHX", "k"},
		{"RPUSHX", "k"},
		{"LINSERT", "k", "before", "a"},
		{"LINSERT", "k", "before", "a", "b", "c"},
		{"LLEN"},
		{"LLEN", "k", "x"},
		{"LINDEX", "k"},
		{"LINDEX", "k", "0", "1"},
		{"LSET", "k", "0"},
		{"LSET", "k", "0", "a", "b"},
		{"LPOP"},
		{"RPOP"},
		{"LPOP", "k", "1", "1"},
		{"RPOP", "k", "2", "2"},
		{"LMPOP", "1", "k"},
		{"LMPOP", "1"},
		{"LRANGE", "k", "0"},
		{"LRANGE", "k", "0", "1", "2"},
		{"LTRIM", "k", "0"},
		{"LPOS", "k"},
		{"LREM", "k", "0"},
		{"LMOVE", "a", "b", "LEFT"},
		{"LMOVE", "a", "b", "LEFT", "RIGHT", "x"},
		{"RPOPLPUSH", "a"},
		{"RPOPLPUSH", "a", "b", "c"},
	}
	for c in arity {
		g_cmds(g, c)
	}
	wrong := [?][]string {
		{"LPUSH", "s", "a"},
		{"RPUSH", "s", "a"},
		{"LPUSHX", "s", "a"},
		{"RPUSHX", "s", "a"},
		{"LINSERT", "s", "before", "a", "b"},
		{"LINSERT", "s", "middle", "a", "b"},
		{"LLEN", "s"},
		{"LINDEX", "s", "0"},
		{"LINDEX", "s", "abc"},
		{"LSET", "s", "0", "a"},
		{"LSET", "s", "abc", "a"},
		{"LPOP", "s"},
		{"RPOP", "s"},
		{"LPOP", "s", "0"},
		{"LPOP", "s", "abc"},
		{"RPOP", "s", "3"},
		{"LMPOP", "1", "s", "LEFT"},
		{"LMPOP", "2", "l", "s", "LEFT"},
		{"LMPOP", "2", "s", "l", "RIGHT"},
		{"LRANGE", "s", "0", "-1"},
		{"LRANGE", "s", "a", "-1"},
		{"LTRIM", "s", "0", "-1"},
		{"LPOS", "s", "a"},
		{"LPOS", "s", "a", "RANK", "0"},
		{"LPOS", "s", "a", "COUNT", "1"},
		{"LREM", "s", "0", "a"},
		{"LREM", "s", "x", "a"},
		{"LMOVE", "s", "l", "LEFT", "RIGHT"},
		{"LMOVE", "l", "s", "LEFT", "RIGHT"},
		{"LMOVE", "s", "nokey", "LEFT", "RIGHT"},
		{"LMOVE", "nokey", "s", "LEFT", "RIGHT"},
		{"RPOPLPUSH", "s", "l"},
		{"RPOPLPUSH", "l", "s"},
		{"GET", "l"},
		{"GET", "s"},
		{"LRANGE", "l", "0", "-1"},
	}
	for c in wrong {
		g_cmds(g, c)
	}
	g_state(g, "l")
}

section_ranges :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	for fill in ([?]string{"-2", "3"}) {
		g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", fill)
		for n in ([?]int{0, 1, 2, 3, 5, 8, 17}) {
			for large in ([?]bool{false, true}) {
				if n == 0 && large {
					continue
				}
				build_list(g, "rl", n, large)
				shapes := INDEX_SHAPES(n)
				for s in shapes {
					g_cmd(g, "LINDEX", "rl", s)
				}
				for a in shapes {
					for b in shapes {
						g_cmd(g, "LRANGE", "rl", a, b)
					}
				}
				picks := [?]int{0, 2, 4, 5, 7, 8, 12, 13}
				for i in picks {
					for j in picks {
						g_cmd(g, "DEL", "rt")
						g_cmd(g, "COPY", "rl", "rt")
						g_write(g, "rt", "LTRIM", "rt", shapes[i], shapes[j])
						g_full(g, "rt")
					}
				}
				for s in shapes {
					g_cmd(g, "DEL", "rt")
					g_cmd(g, "COPY", "rl", "rt")
					g_write(g, "rt", "LSET", "rt", s, "set")
					g_full(g, "rt")
				}
				for c in ([?]string{"0", "1", "2", "3", "100"}) {
					for cmd in ([?]string{"LPOP", "RPOP"}) {
						g_cmd(g, "DEL", "rt")
						g_cmd(g, "COPY", "rl", "rt")
						g_write(g, "rt", cmd, "rt", c)
						g_full(g, "rt")
					}
				}
			}
		}
	}
	g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", "-2")
}

section_conversions :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	fills := [?]string{"-1", "-2", "-3", "-4", "-5", "-6", "-100", "0", "1", "2", "3", "4", "16", "128", "32767", "40000"}
	for fill in fills {
		g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", fill)
		g_cmd(g, "DEL", "c")
		for i in 0 ..< 60 {
			r := &g.rng
			v: string
			switch rng_below(r, 6) {
			case 0:
				v = rep('v', 50 + rng_below(r, 400))
			case 1:
				v = rep('w', 1000 + rng_below(r, 3000))
			case 2:
				v = tp(rng_below(r, 100000))
			case:
				v = gen_small(g)
			}
			if rng_chance(r, 50) {
				g_write(g, "c", "RPUSH", "c", v)
			} else {
				g_write(g, "c", "LPUSH", "c", v, gen_small(g))
			}
			_ = i
		}
		for _ in 0 ..< 70 {
			r := &g.rng
			switch rng_below(r, 6) {
			case 0:
				g_write(g, "c", "RPOP", "c")
			case 1:
				g_write(g, "c", "LPOP", "c", tp(1 + rng_below(r, 3)))
			case 2:
				g_write(g, "c", "LREM", "c", tp(rng_below(r, 3) - 1), gen_small(g))
			case 3:
				g_write(g, "c", "LTRIM", "c", tp(rng_below(r, 3)), tp(-1 - rng_below(r, 3)))
			case 4:
				g_write(g, "c", "LSET", "c", tp(rng_below(r, 6) - 3), gen_small(g))
			case:
				g_write(g, "c", "RPOP", "c", "2")
			}
		}
		g_full(g, "c")
		g_cmd(g, "DEL", "h")
		for k in 0 ..< 40 {
			g_write(g, "h", "RPUSH", "h", tp("item", k), "1")
		}
		for _ in 0 ..< 45 {
			g_write(g, "h", "LPOP", "h")
		}
		g_cmd(g, "DEL", "z")
		g_write(g, "z", "RPUSH", "z", "a", "b", "c")
		g_write(g, "z", "RPUSH", "z", rep('Z', 8190))
		g_write(g, "z", "LINSERT", "z", "after", "b", rep('Y', 9000))
		g_write(g, "z", "LINSERT", "z", "after", "nopivot", rep('Y', 70000))
		g_write(g, "z", "LSET", "z", "0", rep('X', 9000))
		g_write(g, "z", "LSET", "z", "100", rep('X', 70000))
		g_write(g, "z", "RPOP", "z", "3")
		g_write(g, "z", "LSET", "z", "-1", "c")
	}
	g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", "-2")
}

section_packed :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	thresholds := [?]string{"1b", "5b", "10b", "100b", "1kb", "0"}
	sizes := [?]int{1, 4, 5, 9, 10, 11, 99, 100, 101, 1023, 1024, 1025}
	pivots := [?]string{"a", "aaaa", "aaaaa", "bbbbbbbbbb", "9", "ccccccccccc"}
	for thr in thresholds {
		for fill in ([?]string{"-2", "1", "4"}) {
			g_cmd(g, "DEBUG", "QUICKLIST-PACKED-THRESHOLD", thr)
			g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", fill)
			g_cmd(g, "DEL", "pk")
			for _ in 0 ..< 80 {
				r := &g.rng
				v := rep(u8('a' + rng_below(r, 3)), sizes[rng_below(r, len(sizes))])
				if rng_chance(r, 20) {
					v = tp(rng_below(r, 2000) - 1000)
				}
				pv := pivots[rng_below(r, len(pivots))]
				switch rng_below(r, 10) {
				case 0:
					g_write(g, "pk", "LPUSH", "pk", v)
				case 1:
					g_write(g, "pk", "RPUSH", "pk", v, v)
				case 2:
					g_write(g, "pk", "LPOP", "pk")
				case 3:
					g_write(g, "pk", "RPOP", "pk", tp(1 + rng_below(r, 2)))
				case 4:
					g_write(g, "pk", "LSET", "pk", tp(rng_below(r, 8) - 4), v)
				case 5:
					g_write(g, "pk", "LINSERT", "pk", "BEFORE" if rng_chance(r, 50) else "AFTER", pv, v)
				case 6:
					g_write(g, "pk", "LREM", "pk", tp(rng_below(r, 5) - 2), pv)
				case 7:
					g_write(g, "pk", "LTRIM", "pk", tp(rng_below(r, 3) - 1), tp(rng_below(r, 20) - 2))
				case 8:
					g_write(g, "pk", "LMOVE", "pk", "pk", "LEFT" if rng_chance(r, 50) else "RIGHT", "LEFT" if rng_chance(r, 50) else "RIGHT")
				case:
					g_cmd(g, "LPOS", "pk", pv, "RANK", tp(rng_below(r, 2) + 1), "COUNT", tp(rng_below(r, 3)))
				}
				g_full(g, "pk")
			}
		}
	}
	g_cmd(g, "DEBUG", "QUICKLIST-PACKED-THRESHOLD", "0")
	g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", "-2")
	for thr in ([?]string{"abc", "-1", "5gb", "4gb", "4095mb", "4294967295", "4293918720", "4293918721", "b", "18446744073709551615", "1k", "1KB", "0"}) {
		g_cmd(g, "DEBUG", "QUICKLIST-PACKED-THRESHOLD", thr)
	}
}

section_lmove :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	dirs := [?]string{"LEFT", "RIGHT"}
	for fill in ([?]string{"-2", "2"}) {
		g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", fill)
		for from in dirs {
			for to in dirs {
				for dst_kind in 0 ..< 4 {
					g_cmd(g, "DEL", "src", "dst")
					g_write(g, "src", "RPUSH", "src", "1", "two", "3", rep('L', 9000), "five", "6")
					switch dst_kind {
					case 1:
						g_write(g, "dst", "RPUSH", "dst", "d1", "d2")
					case 2:
						g_write(g, "dst", "RPUSH", "dst", "d1", rep('D', 8100))
					case 3:
						g_cmd(g, "SET", "dst", "str")
					}
					for _ in 0 ..< 8 {
						g_cmd(g, "LMOVE", "src", "dst", from, to)
						g_state(g, "src")
						g_state(g, "dst")
						g_full(g, "src")
						g_full(g, "dst")
					}
					for _ in 0 ..< 3 {
						g_cmd(g, "LMOVE", "dst", "dst", from, to)
						g_state(g, "dst")
						g_full(g, "dst")
					}
				}
			}
		}
	}
	g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", "-2")
	g_cmd(g, "DEL", "src", "dst")
	g_write(g, "dst", "RPUSH", "dst", rep('d', 8150))
	g_write(g, "src", "RPUSH", "src", "12345", "67890", "abcde")
	g_write(g, "dst", "LMOVE", "src", "dst", "LEFT", "RIGHT")
	g_cmd(g, "DEL", "src", "dst")
	g_write(g, "dst", "RPUSH", "dst", rep('d', 8173))
	g_write(g, "src", "RPUSH", "src", "12345", "-1", rep('s', 9000))
	g_write(g, "src", "RPOP", "src")
	g_write(g, "dst", "LMOVE", "src", "dst", "LEFT", "RIGHT")
	g_write(g, "dst", "LMOVE", "src", "dst", "LEFT", "RIGHT")
	g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", "3")
	g_cmd(g, "DEL", "src", "dst")
	g_write(g, "src", "RPUSH", "src", "1", "2", "3", "4", "5", "6", "7")
	for _ in 0 ..< 4 {
		g_write(g, "dst", "RPOPLPUSH", "src", "dst")
		g_state(g, "src")
	}
	g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", "-2")
}

section_lmpop :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	for fill in ([?]string{"-2", "2"}) {
		g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", fill)
		g_write(g, "k1", "RPUSH", "k1", "a", "b", "c", "d", "e")
		g_write(g, "k2", "RPUSH", "k2", "1", "2", rep('q', 9000), "4")
		for cnt in ([?]string{"1", "2", "3", "10"}) {
			for dir in ([?]string{"LEFT", "RIGHT"}) {
				g_cmd(g, "LMPOP", "3", "k0", "k1", "k2", dir, "COUNT", cnt)
				g_state(g, "k1")
				g_state(g, "k2")
			}
		}
		g_cmd(g, "LMPOP", "3", "k0", "k1", "k2", "LEFT")
		g_cmd(g, "LMPOP", "1", "k2", "RIGHT")
	}
	g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", "-2")
}

section_fuzz :: proc(g: ^Gen, ops: int) {
	g_cmd(g, "FLUSHALL")
	keys := [?]string{"f1", "f2", "f3"}
	dirs := [?]string{"LEFT", "RIGHT"}
	fills := [?]string{"-2", "-1", "1", "2", "4", "8", "-5"}
	fuzz_thresholds := [?]string{"0", "0", "50b", "1kb"}
	ranks := [?]int{1, 2, -1, -2, 3}
	for i in 0 ..< ops {
		r := &g.rng
		if i % 400 == 0 {
			g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", fills[rng_below(r, len(fills))])
		}
		if i % 900 == 450 {
			g_cmd(g, "DEBUG", "QUICKLIST-PACKED-THRESHOLD", fuzz_thresholds[rng_below(r, len(fuzz_thresholds))])
		}
		k := keys[rng_below(r, len(keys))]
		k2 := keys[rng_below(r, len(keys))]
		v := gen_value(g)
		if rng_chance(r, 4) {
			v = gen_large(g)
		}
		switch rng_below(r, 17) {
		case 0:
			n := 1 + rng_below(r, 4)
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "LPUSH" if rng_chance(r, 50) else "RPUSH", k)
			for _ in 0 ..< n {
				append(&args, gen_value(g))
			}
			g_cmds(g, args[:])
		case 1:
			g_cmd(g, "RPUSH", k, v)
		case 2:
			g_cmd(g, "LPUSHX" if rng_chance(r, 50) else "RPUSHX", k, v)
		case 3:
			if rng_chance(r, 50) {
				g_cmd(g, "LPOP" if rng_chance(r, 50) else "RPOP", k)
			} else {
				g_cmd(g, "LPOP" if rng_chance(r, 50) else "RPOP", k, tp(rng_below(r, 5)))
			}
		case 4:
			g_cmd(g, "LSET", k, tp(rng_below(r, 12) - 6), v)
		case 5:
			g_cmd(g, "LINSERT", k, "BEFORE" if rng_chance(r, 50) else "AFTER", gen_small(g), v)
		case 6:
			g_cmd(g, "LREM", k, tp(rng_below(r, 7) - 3), gen_small(g))
		case 7:
			g_cmd(g, "LTRIM", k, tp(rng_below(r, 9) - 4), tp(rng_below(r, 40) - 5))
		case 8:
			g_cmd(g, "LMOVE", k, k2, dirs[rng_below(r, 2)], dirs[rng_below(r, 2)])
		case 9:
			g_cmd(g, "RPOPLPUSH", k, k2)
		case 10:
			g_cmd(g, "LMPOP", "2", k, k2, dirs[rng_below(r, 2)], "COUNT", tp(1 + rng_below(r, 4)))
		case 11:
			g_cmd(g, "LPOS", k, gen_small(g), "RANK", tp(ranks[rng_below(r, len(ranks))]), "COUNT", tp(rng_below(r, 4)), "MAXLEN", tp(rng_below(r, 20)))
		case 12:
			g_cmd(g, "LINDEX", k, tp(rng_below(r, 30) - 15))
		case 13:
			g_cmd(g, "LRANGE", k, tp(rng_below(r, 30) - 15), tp(rng_below(r, 30) - 15))
		case 14:
			g_cmd(g, "LPOS", k, gen_small(g))
		case 15:
			g_cmd(g, "DEL", k)
			g_cmd(g, "COPY", k2, k)
		case:
			g_cmd(g, "LRANGE", k, "0", "-1")
		}
		g_state(g, k)
		if k2 != k {
			g_state(g, k2)
		}
	}
	g_cmd(g, "DEBUG", "QUICKLIST-PACKED-THRESHOLD", "0")
	g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", "-2")
}

section_middle :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	pivots := [?]string{"p0", "p1", "p2", "p3", "7"}
	for fill in ([?]string{"4", "-1", "1", "-2"}) {
		g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", fill)
		g_cmd(g, "DEL", "mid")
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "RPUSH", "mid")
		for i in 0 ..< 240 {
			if i % 7 == 0 {
				append(&args, pivots[(i / 7) % len(pivots)])
			} else {
				append(&args, tp("m", i, rep('.', i % 37)))
			}
		}
		g_cmds(g, args[:])
		g_state(g, "mid")
		for _ in 0 ..< 220 {
			r := &g.rng
			v := gen_value(g)
			if rng_chance(r, 10) {
				v = gen_large(g)
			}
			pv := pivots[rng_below(r, len(pivots))]
			switch rng_below(r, 6) {
			case 0, 1:
				g_write(g, "mid", "LINSERT", "mid", "BEFORE" if rng_chance(r, 50) else "AFTER", pv, v)
			case 2:
				g_write(g, "mid", "LSET", "mid", tp(rng_below(r, 200) - 100), v)
			case 3:
				g_write(g, "mid", "LREM", "mid", tp(rng_below(r, 5) - 2), pv)
			case 4:
				g_write(g, "mid", "RPUSH", "mid", pv, v)
			case:
				g_write(g, "mid", "LMOVE", "mid", "mid", "LEFT" if rng_chance(r, 50) else "RIGHT", "LEFT" if rng_chance(r, 50) else "RIGHT")
			}
			g_cmd(g, "LRANGE", "mid", tp(rng_below(r, 100)), tp(rng_below(r, 100) + 100))
			g_cmd(g, "LINDEX", "mid", tp(rng_below(r, 300) - 150))
			g_cmd(g, "LPOS", "mid", pv, "RANK", tp(-1 - rng_below(r, 3)), "COUNT", "0")
		}
		g_full(g, "mid")
	}
	g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", "-2")
}

section_config :: proc(g: ^Gen) {
	for v in ([?]string{"abc", "99999999999", "-2147483649", "2147483648", "2147483647", "-2147483648", " 5", "+5", "05", "-2"}) {
		g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", v)
		g_cmd(g, "CONFIG", "SET", "list-max-ziplist-size", v)
	}
	for v in ([?]string{"-1", "abc", "2147483648", "3", "0"}) {
		g_cmd(g, "CONFIG", "SET", "list-compress-depth", v)
	}
	g_cmd(g, "CONFIG", "SET", "list-compress-depth", "2")
	g_write(g, "cq", "RPUSH", "cq", "a", rep('x', 9000), "b")
	g_cmd(g, "CONFIG", "SET", "list-compress-depth", "0")
	g_write(g, "cq", "RPUSH", "cq", "c")
	g_cmd(g, "CONFIG", "SET", "list-max-listpack-size", "-2")
}

run_gen :: proc(dir: string) -> bool {
	g := Gen {
		buf = make([dynamic]u8),
		rng = Rng{s = 0x1157_7e57_0033},
	}
	defer delete(g.buf)
	section_basic(&g)
	section_errors(&g)
	section_config(&g)
	section_ranges(&g)
	section_conversions(&g)
	section_packed(&g)
	section_lmove(&g)
	section_lmpop(&g)
	section_middle(&g)
	section_fuzz(&g, 6000)
	g_cmd(&g, "HELLO", "3")
	section_basic(&g)
	section_errors(&g)
	section_lmpop(&g)
	section_fuzz(&g, 1500)
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
