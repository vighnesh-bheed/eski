package bitmap_harness

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Gen :: struct {
	r:         Rng,
	buf:       [dynamic]u8,
	count:     int,
	argv:      [dynamic][]u8,
	srv:       [dynamic]u8,
	srv_count: int,
	written:   map[string]bool,
	writes:    int,
	dumps:     int,
	periodic:  bool,
}

DUMP_EVERY :: 8

written_key :: proc(argv: [][]u8) -> ([]u8, bool) {
	if len(argv) < 2 {
		return nil, false
	}
	for name in ([]string{"setbit", "bitfield", "set", "setrange", "append", "incr", "incrby", "decr", "decrby", "getset", "setnx", "del"}) {
		if equal_ascii_fold(argv[0], name) {
			return argv[1], true
		}
	}
	if equal_ascii_fold(argv[0], "bitop") && len(argv) >= 3 {
		return argv[2], true
	}
	return nil, false
}

srv_dump :: proc(g: ^Gen, key: []u8) {
	argv := [2][]u8{transmute([]u8)string("DUMP"), key}
	cmd_append(&g.srv, argv[:])
	g.srv_count += 1
	g.dumps += 1
}

track_write :: proc(g: ^Gen, argv: [][]u8) {
	key, ok := written_key(argv)
	if !ok {
		return
	}
	if !(string(key) in g.written) {
		g.written[strings.clone(string(key))] = true
	}
	g.writes += 1
	if g.periodic && g.writes % DUMP_EVERY == 0 {
		srv_dump(g, key)
	}
}

dump_written :: proc(g: ^Gen) {
	names := make([dynamic]string, context.temp_allocator)
	for k in g.written {
		append(&names, k)
	}
	slice.sort(names[:])
	for k in names {
		srv_dump(g, transmute([]u8)k)
	}
	for k in g.written {
		delete(k)
	}
	delete(g.written)
}

server_command :: proc(argv: [][]u8) -> bool {
	return len(argv) == 0 || !equal_ascii_fold(argv[0], "lpush")
}

equal_ascii_fold :: proc(a: []u8, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x := a[i]
		if x >= 'A' && x <= 'Z' {
			x += 32
		}
		if x != b[i] {
			return false
		}
	}
	return true
}

g_arg :: proc(a: any) -> []u8 {
	switch v in a {
	case string:
		return transmute([]u8)strings.clone(v, context.temp_allocator)
	case []u8:
		return v
	case i64:
		return transmute([]u8)fmt.tprintf("%d", v)
	case int:
		return transmute([]u8)fmt.tprintf("%d", v)
	case i128:
		return transmute([]u8)fmt.tprintf("%d", v)
	case u64:
		return transmute([]u8)fmt.tprintf("%d", v)
	}
	return transmute([]u8)fmt.tprint(a)
}

g_cmd :: proc(g: ^Gen, args: ..any) {
	clear(&g.argv)
	for a in args {
		append(&g.argv, g_arg(a))
	}
	cmd_append(&g.buf, g.argv[:])
	g.count += 1
	if server_command(g.argv[:]) {
		cmd_append(&g.srv, g.argv[:])
		g.srv_count += 1
		track_write(g, g.argv[:])
	}
}

g_cmdv :: proc(g: ^Gen, argv: [][]u8) {
	cmd_append(&g.buf, argv)
	g.count += 1
	if server_command(argv) {
		cmd_append(&g.srv, argv)
		g.srv_count += 1
		track_write(g, argv)
	}
}

g_pick :: proc(g: ^Gen, items: []string) -> string {
	return items[rng_below(&g.r, len(items))]
}

g_unit :: proc(g: ^Gen, bit: bool) -> string {
	if bit {
		return g_pick(g, {"BIT", "bit", "Bit", "bIT"})
	}
	return g_pick(g, {"BYTE", "byte", "Byte", "bytE"})
}

g_case_word :: proc(g: ^Gen, word: string) -> string {
	switch rng_below(&g.r, 3) {
	case 0:
		return strings.to_upper(word, context.temp_allocator)
	case 1:
		return strings.to_lower(word, context.temp_allocator)
	}
	b := transmute([]u8)strings.clone(word, context.temp_allocator)
	for i in 0 ..< len(b) {
		if rng_chance(&g.r, 50) {
			c := b[i]
			if c >= 'a' && c <= 'z' {
				b[i] = c - 32
			} else if c >= 'A' && c <= 'Z' {
				b[i] = c + 32
			}
		}
	}
	return string(b)
}

Case_Proc :: proc(g: ^Gen)

Case_Entry :: struct {
	name: string,
	p:    Case_Proc,
}

CASES := [?]Case_Entry {
	{"setbit_getbit", case_setbit},
	{"bitcount", case_bitcount},
	{"bitpos", case_bitpos},
	{"bitop", case_bitop},
	{"bitfield", case_bitfield},
	{"errors", case_errors},
	{"intenc", case_intenc},
	{"mixed", case_mixed},
	{"large", case_large},
}

run_gen :: proc(dir: string) -> int {
	names := strings.builder_make()
	defer strings.builder_destroy(&names)
	total := 0
	total_dumps := 0
	for c, idx in CASES {
		g := Gen{r = rng_make(0xb17f1e1d + u64(idx) * 7919), periodic = c.name != "large"}
		g_cmd(&g, "FLUSHALL")
		c.p(&g)
		dump_written(&g)
		path := path_in(dir, fmt.tprintf("%s.script", c.name))
		if err := os.write_entire_file(path, g.buf[:]); err != nil {
			fmt.eprintfln("cannot write %s: %v", path, err)
			return 1
		}
		strings.write_string(&names, c.name)
		strings.write_byte(&names, '\n')
		srv_path := path_in(dir, fmt.tprintf("%s.srv.script", c.name))
		if err := os.write_entire_file(srv_path, g.srv[:]); err != nil {
			fmt.eprintfln("cannot write %s: %v", srv_path, err)
			return 1
		}
		fmt.printfln("generated %-14s %7s commands %10s bytes, %7s for the server profile (%s of them DUMP)", c.name, num(g.count), num(len(g.buf)), num(g.srv_count), num(g.dumps))
		total += g.count
		total_dumps += g.dumps
		delete(g.buf)
		delete(g.srv)
		delete(g.argv)
		free_all(context.temp_allocator)
	}
	list := path_in(dir, "cases.txt")
	if err := os.write_entire_file(list, transmute([]u8)strings.to_string(names)); err != nil {
		fmt.eprintfln("cannot write %s: %v", list, err)
		return 1
	}
	fmt.printfln("generated %d commands in %d cases, %d DUMP commands in the server profile", total, len(CASES), total_dumps)
	return 0
}

BAD_OFFSETS := [?]string{"-1", "4294967296", "a", "", "#3", "1.5", "-0", "+5", "00", "18446744073709551616", " 1", "1 ", "9223372036854775807", "-9223372036854775808", "0x10", "1\x00"}
BAD_BITS := [?]string{"2", "-1", "a", "", "01", "1 ", "+1", "true", "9223372036854775808", "3", "-0", "1\x00"}

case_setbit :: proc(g: ^Gen) {
	keys := [?]string{"k0", "k1", "k2", "k3", "k4", "k5", "k6"}
	g_cmd(g, "SET", "k1", rng_bytes(&g.r, 40, 0, context.temp_allocator))
	g_cmd(g, "SET", "k2", "")
	g_cmd(g, "SET", "k3", "1234567")
	g_cmd(g, "SET", "k4", rng_bytes(&g.r, 300, 3, context.temp_allocator))
	g_cmd(g, "SET", "k5", "-42")
	g_cmd(g, "LPUSH", "list", "a", "b")
	for i in 0 ..< 6000 {
		k := keys[rng_below(&g.r, len(keys))]
		switch rng_below(&g.r, 20) {
		case 0 ..= 7:
			off: i64
			switch rng_below(&g.r, 10) {
			case 0 ..= 6:
				off = rng_range(&g.r, 0, 400)
			case 7, 8:
				off = rng_range(&g.r, 0, 3000)
			case:
				off = rng_range(&g.r, 0, 8 * 70000)
			}
			v := "1" if rng_chance(&g.r, 55) else "0"
			g_cmd(g, "SETBIT", k, off, v)
		case 8 ..= 13:
			off: i64
			switch rng_below(&g.r, 10) {
			case 0 ..= 7:
				off = rng_range(&g.r, 0, 3200)
			case 8:
				off = rng_range(&g.r, 0, 8 * 80000)
			case:
				off = rng_range(&g.r, 0, (i64(1) << 32) - 1)
			}
			g_cmd(g, "GETBIT", k, off)
		case 14:
			g_cmd(g, "SETBIT", k, BAD_OFFSETS[rng_below(&g.r, len(BAD_OFFSETS))], "1")
		case 15:
			g_cmd(g, "SETBIT", k, rng_range(&g.r, 0, 100), BAD_BITS[rng_below(&g.r, len(BAD_BITS))])
		case 16:
			g_cmd(g, "GETBIT", k, BAD_OFFSETS[rng_below(&g.r, len(BAD_OFFSETS))])
		case 17:
			g_cmd(g, "GET", k)
		case 18:
			g_cmd(g, "STRLEN", k)
		case 19:
			if rng_chance(&g.r, 30) {
				g_cmd(g, "DEL", k)
			} else {
				g_cmd(g, "BITCOUNT", k)
			}
		}
		if i % 500 == 0 {
			free_all(context.temp_allocator)
		}
	}
	g_cmd(g, "SETBIT", "list", "0", "1")
	g_cmd(g, "SETBIT", "list", "-1", "1")
	g_cmd(g, "SETBIT", "list", "0", "2")
	g_cmd(g, "GETBIT", "list", "0")
	g_cmd(g, "GETBIT", "list", "a")
	g_cmd(g, "GETBIT", "missing", "100")
	g_cmd(g, "GETBIT", "missing", "4294967295")
	g_cmd(g, "SETBIT", "edge", "4294967296", "1")
	g_cmd(g, "SETBIT", "Edge", "7", "1")
	g_cmd(g, "SETBIT", "Edge", "7", "0")
	g_cmd(g, "GET", "Edge")
	g_cmd(g, "SETBIT", "Edge", "8", "0")
	g_cmd(g, "GET", "Edge")
	g_cmd(g, "SETBIT", "Edge", "0", "0")
	g_cmd(g, "EXISTS", "Edge")
	g_cmd(g, "SETBIT", "zero", "0", "0")
	g_cmd(g, "GET", "zero")
	for k in keys {
		g_cmd(g, "GET", k)
	}
	free_all(context.temp_allocator)
}

LENGTHS := [?]int{0, 1, 2, 3, 5, 7, 8, 9, 15, 16, 17, 24, 31, 32, 33, 40, 63, 64, 65, 100, 127, 128, 129, 200, 255, 256, 299, 300}

case_bitcount :: proc(g: ^Gen) {
	for l, idx in LENGTHS {
		key := fmt.tprintf("s%d", idx)
		g_cmd(g, "SET", key, rng_bytes(&g.r, l, idx % 7, context.temp_allocator))
		g_cmd(g, "BITCOUNT", key)
		offs := interesting_offsets(i64(l))
		for a in offs {
			for b in offs {
				g_cmd(g, "BITCOUNT", key, a, b)
				g_cmd(g, "BITCOUNT", key, a, b, g_unit(g, true))
				if rng_chance(&g.r, 50) {
					g_cmd(g, "BITCOUNT", key, a, b, g_unit(g, false))
				}
			}
		}
		free_all(context.temp_allocator)
	}
	for i in 0 ..< 3 {
		key := fmt.tprintf("big%d", i)
		n := 1024 * 1024 + i * 13
		g_cmd(g, "SET", key, rng_bytes(&g.r, n, i, context.temp_allocator))
		g_cmd(g, "BITCOUNT", key)
		l := i64(n)
		sub := [?]i64{min(i64), -8 * l - 1, -8 * l, -l - 1, -l, -9, -1, 0, 1, 7, 9, l / 3, l - 1, l, 8 * l / 5, 8 * l - 1, 8 * l, max(i64)}
		for a in sub {
			for b in sub {
				g_cmd(g, "BITCOUNT", key, a, b, g_unit(g, true))
				g_cmd(g, "BITCOUNT", key, a, b)
			}
		}
		free_all(context.temp_allocator)
	}
	for _ in 0 ..< 4000 {
		idx := rng_below(&g.r, len(LENGTHS))
		key := fmt.tprintf("s%d", idx)
		l := i64(LENGTHS[idx])
		a := rng_range(&g.r, -8 * l - 20, 8 * l + 20)
		b := rng_range(&g.r, -8 * l - 20, 8 * l + 20)
		switch rng_below(&g.r, 3) {
		case 0:
			g_cmd(g, "BITCOUNT", key, a, b)
		case 1:
			g_cmd(g, "BITCOUNT", key, a, b, g_unit(g, true))
		case:
			g_cmd(g, "BITCOUNT", key, a, b, g_unit(g, false))
		}
	}
	free_all(context.temp_allocator)
	for k in ([?]string{"s3", "nokey"}) {
		g_cmd(g, "BITCOUNT", k, "0")
		g_cmd(g, "BITCOUNT", k, "0", "1", "BITS")
		g_cmd(g, "BITCOUNT", k, "0", "1", "bit", "extra")
		g_cmd(g, "BITCOUNT", k, "0", "1", "hello", "hello2")
		g_cmd(g, "BITCOUNT", k, "a", "1")
		g_cmd(g, "BITCOUNT", k, "1", "a")
		g_cmd(g, "BITCOUNT", k, "a", "b", "BITS")
		g_cmd(g, "BITCOUNT", k, "0", "1", "bit\x00junk")
		g_cmd(g, "BITCOUNT", k, "0", "1", "")
		g_cmd(g, "BITCOUNT", k, "0", "4294967296")
		g_cmd(g, "BITCOUNT", k, "-0", "1")
		g_cmd(g, "BITCOUNT", k, "9223372036854775808", "1")
		g_cmd(g, "BITCOUNT", k, "0", " 1")
		g_cmd(g, "BITCOUNT", k, "-6", "-7")
		g_cmd(g, "BITCOUNT", k, "-6", "-15", "bit")
		g_cmd(g, "BITCOUNT", k, "0", "1000", "bit")
		g_cmd(g, "BITCOUNT", k, "-9223372036854775808", "9223372036854775807", "BIT")
	}
	g_cmd(g, "LPUSH", "mylist", "a", "b", "c")
	g_cmd(g, "BITCOUNT", "mylist")
	g_cmd(g, "BITCOUNT", "mylist", "0", "100")
	g_cmd(g, "BITCOUNT", "mylist", "-6", "-7")
	g_cmd(g, "BITCOUNT", "mylist", "-6", "-15", "bit")
	g_cmd(g, "BITCOUNT", "mylist", "a", "b")
	g_cmd(g, "BITCOUNT", "mylist", "0")
	g_cmd(g, "BITCOUNT", "mylist", "0", "1", "hello")
	g_cmd(g, "BITCOUNT")
	free_all(context.temp_allocator)
}

bitpos_key_data :: proc(g: ^Gen, l: int, style: int) -> []u8 {
	switch style {
	case 7:
		b := rng_bytes(&g.r, l, 6, context.temp_allocator)
		if l > 0 {
			p := rng_below(&g.r, l * 8)
			b[p >> 3] &= ~(u8(0x80) >> u8(p & 7))
		}
		return b
	case 8:
		b := rng_bytes(&g.r, l, 5, context.temp_allocator)
		if l > 0 {
			p := rng_below(&g.r, l * 8)
			b[p >> 3] |= u8(0x80) >> u8(p & 7)
		}
		return b
	}
	return rng_bytes(&g.r, l, style, context.temp_allocator)
}

case_bitpos :: proc(g: ^Gen) {
	key_lens := make([dynamic]int, context.temp_allocator)
	idx := 0
	for l in LENGTHS {
		for _ in 0 ..< 2 {
			key := fmt.tprintf("p%d", idx)
			style := (idx * 5 + l) % 9
			g_cmd(g, "SET", key, bitpos_key_data(g, l, style))
			append(&key_lens, l)
			idx += 1
		}
	}
	nkeys := idx
	for k in 0 ..< nkeys {
		key := fmt.tprintf("p%d", k)
		l := i64(key_lens[k])
		all := interesting_offsets(l)
		sub := make([dynamic]i64, context.temp_allocator)
		for v, i in all {
			if i % 2 == 0 || v == 0 || v == -1 || v == l || v == 8 * l {
				append(&sub, v)
			}
		}
		for bit in 0 ..< 2 {
			g_cmd(g, "BITPOS", key, bit)
			for a in all {
				g_cmd(g, "BITPOS", key, bit, a)
			}
			for a in sub {
				for b in sub {
					g_cmd(g, "BITPOS", key, bit, a, b)
					g_cmd(g, "BITPOS", key, bit, a, b, g_unit(g, true))
					g_cmd(g, "BITPOS", key, bit, a, b, g_unit(g, false))
				}
			}
		}
		free_all(context.temp_allocator)
	}
	for i in 0 ..< 4 {
		key := fmt.tprintf("bigp%d", i)
		n := 1024 * 1024 + i * 5
		b := rng_bytes(&g.r, n, 6 if i % 2 == 0 else 5, context.temp_allocator)
		p := n * 8 - 1 - rng_below(&g.r, 4000) if i < 2 else rng_below(&g.r, n * 8)
		if i % 2 == 0 {
			b[p >> 3] &= ~(u8(0x80) >> u8(p & 7))
		} else {
			b[p >> 3] |= u8(0x80) >> u8(p & 7)
		}
		g_cmd(g, "SET", key, b)
		l := i64(n)
		sub := [?]i64{-8 * l - 1, -l - 1, -2, -1, 0, 1, 9, i64(p >> 3) - 1, i64(p >> 3), i64(p >> 3) + 1, i64(p) - 1, i64(p), i64(p) + 1, l - 1, l, 8 * l - 1}
		for bit in 0 ..< 2 {
			g_cmd(g, "BITPOS", key, bit)
			for a in sub {
				g_cmd(g, "BITPOS", key, bit, a)
				for c in sub {
					g_cmd(g, "BITPOS", key, bit, a, c)
					g_cmd(g, "BITPOS", key, bit, a, c, g_unit(g, true))
				}
			}
		}
		free_all(context.temp_allocator)
	}
	for _ in 0 ..< 4000 {
		k := rng_below(&g.r, nkeys)
		key := fmt.tprintf("p%d", k)
		l := i64(key_lens[k])
		bit := rng_below(&g.r, 2)
		a := rng_range(&g.r, -8 * l - 20, 8 * l + 20)
		b := rng_range(&g.r, -8 * l - 20, 8 * l + 20)
		switch rng_below(&g.r, 4) {
		case 0:
			g_cmd(g, "BITPOS", key, bit, a)
		case 1:
			g_cmd(g, "BITPOS", key, bit, a, b)
		case 2:
			g_cmd(g, "BITPOS", key, bit, a, b, g_unit(g, true))
		case:
			g_cmd(g, "BITPOS", key, bit, a, b, g_unit(g, false))
		}
	}
	free_all(context.temp_allocator)
	g_cmd(g, "SET", "empty", "")
	for k in ([?]string{"empty", "nokey"}) {
		for bit in ([?]string{"0", "1"}) {
			g_cmd(g, "BITPOS", k, bit)
			g_cmd(g, "BITPOS", k, bit, "0")
			g_cmd(g, "BITPOS", k, bit, "0", "-1")
			g_cmd(g, "BITPOS", k, bit, "0", "-1", "bit")
			g_cmd(g, "BITPOS", k, bit, "5", "2")
			g_cmd(g, "BITPOS", k, bit, "-5", "100", "byte")
		}
	}
	for k in ([?]string{"p5", "nokey"}) {
		g_cmd(g, "BITPOS", k, "2")
		g_cmd(g, "BITPOS", k, "-1")
		g_cmd(g, "BITPOS", k, "a")
		g_cmd(g, "BITPOS", k, "")
		g_cmd(g, "BITPOS", k, "01")
		g_cmd(g, "BITPOS", k, "1", "a")
		g_cmd(g, "BITPOS", k, "1", "0", "a")
		g_cmd(g, "BITPOS", k, "1", "0", "1", "BITS")
		g_cmd(g, "BITPOS", k, "1", "0", "1", "bit", "x")
		g_cmd(g, "BITPOS", k, "1", "0", "a", "BITS")
		g_cmd(g, "BITPOS", k, "1", "a", "1", "BITS")
		g_cmd(g, "BITPOS", k, "2", "0", "1", "BITS")
		g_cmd(g, "BITPOS", k, "a", "0", "1", "2", "3")
		g_cmd(g, "BITPOS", k, "1", "0", "1", "2", "3", "4")
		g_cmd(g, "BITPOS", k, "1", "0", "1", "byte\x00x")
		g_cmd(g, "BITPOS", k, "0", "a", "b")
		g_cmd(g, "BITPOS", k, "0", "1", "hello", "hello2")
		g_cmd(g, "BITPOS", k, "0", "0", "1", "hello")
	}
	g_cmd(g, "LPUSH", "mylist", "a", "b", "c")
	g_cmd(g, "BITPOS", "mylist", "0")
	g_cmd(g, "BITPOS", "mylist", "1", "10", "100")
	g_cmd(g, "BITPOS", "mylist", "a")
	g_cmd(g, "BITPOS", "mylist", "1", "a", "b")
	g_cmd(g, "BITPOS", "mylist", "2")
	g_cmd(g, "BITPOS", "mylist", "1", "0", "1", "hello")
	g_cmd(g, "BITPOS", "p1")
	g_cmd(g, "BITPOS")
	free_all(context.temp_allocator)
}

case_bitop :: proc(g: ^Gen) {
	src_lens := [?]int{0, 1, 7, 31, 32, 33, 64, 100, 257, 300, 3, 48}
	srcs := make([dynamic]string, context.temp_allocator)
	for l, i in src_lens {
		key := fmt.tprintf("src%d", i)
		g_cmd(g, "SET", key, rng_bytes(&g.r, l, i % 7, context.temp_allocator))
		append(&srcs, key)
	}
	g_cmd(g, "SET", "srcint", "12345")
	append(&srcs, "srcint")
	append(&srcs, "nokey1", "nokey2")
	g_cmd(g, "LPUSH", "lst", "x")
	dests := [?]string{"d0", "d1", "d2", "src3", "src8", "lst", "src0"}
	ops := [?]string{"and", "or", "xor", "not"}
	for i in 0 ..< 2500 {
		op := g_case_word(g, ops[rng_below(&g.r, 4)])
		n := 1 if op[0] == 'n' || op[0] == 'N' else 1 + rng_below(&g.r, 5)
		dest := dests[rng_below(&g.r, len(dests))]
		if rng_chance(&g.r, 20) {
			dest = srcs[rng_below(&g.r, len(srcs))]
		}
		argv := make([dynamic][]u8, context.temp_allocator)
		append(&argv, transmute([]u8)string("BITOP"), transmute([]u8)op, transmute([]u8)dest)
		for _ in 0 ..< n {
			append(&argv, transmute([]u8)srcs[rng_below(&g.r, len(srcs))])
		}
		g_cmdv(g, argv[:])
		g_cmd(g, "GET", dest)
		g_cmd(g, "EXISTS", dest)
		if i % 50 == 0 {
			g_cmd(g, "LPUSH", "lst", "y")
			idx := rng_below(&g.r, len(src_lens))
			g_cmd(g, "SET", fmt.tprintf("src%d", idx), rng_bytes(&g.r, src_lens[idx], rng_below(&g.r, 7), context.temp_allocator))
		}
		if i % 100 == 0 {
			free_all(context.temp_allocator)
			srcs = make([dynamic]string, context.temp_allocator)
			for _, j in src_lens {
				append(&srcs, fmt.tprintf("src%d", j))
			}
			append(&srcs, "srcint", "nokey1", "nokey2")
		}
	}
	free_all(context.temp_allocator)
	g_cmd(g, "SET", "m1", rng_bytes(&g.r, 1024 * 1024, 0, context.temp_allocator))
	g_cmd(g, "SET", "m2", rng_bytes(&g.r, 1024 * 1024 - 3, 3, context.temp_allocator))
	g_cmd(g, "SET", "m3", rng_bytes(&g.r, 4000, 0, context.temp_allocator))
	for op in ([?]string{"AND", "OR", "XOR"}) {
		g_cmd(g, "BITOP", op, "md", "m1", "m2")
		g_cmd(g, "GET", "md")
		g_cmd(g, "BITOP", op, "md", "m2", "m3", "nokey1")
		g_cmd(g, "GET", "md")
		g_cmd(g, "BITOP", op, "md", "m3", "m1")
		g_cmd(g, "BITCOUNT", "md")
		g_cmd(g, "STRLEN", "md")
	}
	g_cmd(g, "BITOP", "NOT", "md", "m2")
	g_cmd(g, "GET", "md")
	g_cmd(g, "BITOP", "NOT", "m1", "m1")
	g_cmd(g, "GET", "m1")
	free_all(context.temp_allocator)
	g_cmd(g, "SET", "z32", string(make([]u8, 32, context.temp_allocator)))
	g_cmd(g, "BITOP", "or", "x", "z32", "nokey9")
	g_cmd(g, "GET", "x")
	g_cmd(g, "SET", "e", "")
	g_cmd(g, "SET", "d9", "hello")
	g_cmd(g, "BITOP", "not", "d9", "e")
	g_cmd(g, "EXISTS", "d9")
	g_cmd(g, "SET", "d9", "hello")
	g_cmd(g, "BITOP", "and", "d9", "nokey1", "nokey2")
	g_cmd(g, "EXISTS", "d9")
	g_cmd(g, "BITOP", "and", "nokey3", "nokey1")
	g_cmd(g, "EXISTS", "nokey3")
	g_cmd(g, "LPUSH", "lst2", "a")
	g_cmd(g, "BITOP", "NOT", "d", "src1", "src2")
	g_cmd(g, "BITOP", "NOT", "d", "lst2", "src2")
	g_cmd(g, "BITOP", "NOT", "d", "lst2")
	g_cmd(g, "BITOP", "AND", "d", "src1", "lst2")
	g_cmd(g, "BITOP", "AND", "d", "lst2", "nokey1")
	g_cmd(g, "BITOP", "FOO", "d", "src1")
	g_cmd(g, "BITOP", "", "d", "src1")
	g_cmd(g, "BITOP", "an", "d", "src1")
	g_cmd(g, "BITOP", "and\x00x", "d", "src1")
	g_cmd(g, "GET", "d")
	g_cmd(g, "BITOP", "not\x00", "d", "src2")
	g_cmd(g, "GET", "d")
	g_cmd(g, "BITOP", "and", "d")
	g_cmd(g, "BITOP", "not", "d")
	g_cmd(g, "BITOP", "foo", "d")
	g_cmd(g, "BITOP", "and", "lst2", "src4")
	g_cmd(g, "GET", "lst2")
	g_cmd(g, "SET", "a{t}", "1")
	g_cmd(g, "SET", "b{t}", "2")
	g_cmd(g, "BITOP", "xor", "dest{t}", "a{t}", "b{t}", "a{t}")
	g_cmd(g, "GET", "dest{t}")
	free_all(context.temp_allocator)
}

field_bounds :: proc(signed: bool, bits: int) -> (minv, maxv: i128) {
	if signed {
		maxv = (i128(1) << uint(bits - 1)) - 1
		minv = -maxv - 1
	} else {
		maxv = (i128(1) << uint(bits)) - 1
	}
	return
}

clamp64 :: proc(v: i128) -> i64 {
	return i64(clamp(v, i128(min(i64)), i128(max(i64))))
}

g_field_value :: proc(g: ^Gen, signed: bool, bits: int) -> i64 {
	minv, maxv := field_bounds(signed, bits)
	q := maxv - (i128(1) << 63)
	switch rng_below(&g.r, 14) {
	case 0:
		return clamp64(minv)
	case 1:
		return clamp64(maxv)
	case 2:
		return clamp64(maxv + 1)
	case 3:
		return clamp64(minv - 1)
	case 4:
		return 0
	case 5:
		return 1
	case 6:
		return -1
	case 7:
		return clamp64(q)
	case 8:
		return clamp64(q + 1)
	case 9:
		return min(i64)
	case 10:
		return max(i64)
	case 11:
		return i64(rng_next(&g.r))
	}
	return clamp64(minv + i128(rng_next(&g.r) % u64(clamp(maxv - minv + 1, 1, i128(max(u64))))))
}

g_field_incr :: proc(g: ^Gen, signed: bool, bits: int) -> i64 {
	minv, maxv := field_bounds(signed, bits)
	rangev := maxv - minv + 1
	k := i128(1 + rng_below(&g.r, 5))
	switch rng_below(&g.r, 14) {
	case 0:
		return 1
	case 1:
		return -1
	case 2:
		return 0
	case 3:
		return clamp64(rangev)
	case 4:
		return clamp64(-rangev)
	case 5:
		return clamp64(k * rangev + 1)
	case 6:
		return clamp64(-k * rangev - 1)
	case 7:
		return clamp64(maxv)
	case 8:
		return clamp64(minv)
	case 9:
		return max(i64)
	case 10:
		return min(i64)
	case 11:
		return i64(rng_next(&g.r))
	case 12:
		return i64(rng_below(&g.r, 300)) - 150
	}
	return clamp64(i128(rng_next(&g.r) % u64(clamp(rangev, 1, i128(max(u64))))) - rangev / 2)
}

g_bitfield :: proc(g: ^Gen, key: string, ro: bool, max_off: int) {
	argv := make([dynamic][]u8, context.temp_allocator)
	append(&argv, transmute([]u8)g_case_word(g, "BITFIELD_RO" if ro else "BITFIELD"), transmute([]u8)key)
	nsub := 1 + rng_below(&g.r, 8)
	for _ in 0 ..< nsub {
		if !ro && rng_chance(&g.r, 20) {
			append(&argv, transmute([]u8)g_case_word(g, "overflow"), transmute([]u8)g_case_word(g, g_pick(g, {"wrap", "sat", "fail"})))
		}
		op := "get"
		if !ro {
			op = g_pick(g, {"get", "set", "incrby", "set", "incrby"})
		}
		signed := rng_chance(&g.r, 55)
		bits := 1 + rng_below(&g.r, 64 if signed else 63)
		if rng_chance(&g.r, 25) {
			common := [?]int{1, 8, 16, 32, 63, 64}
			bits = common[rng_below(&g.r, 6)]
			if !signed && bits == 64 {
				bits = 63
			}
		}
		ty := fmt.tprintf("%s%d", "i" if signed else "u", bits)
		off: string
		if rng_chance(&g.r, 30) {
			off = fmt.tprintf("#%d", rng_below(&g.r, max_off / bits + 2))
		} else {
			off = fmt.tprintf("%d", rng_below(&g.r, max_off))
		}
		append(&argv, transmute([]u8)g_case_word(g, op), transmute([]u8)ty, transmute([]u8)off)
		if op == "set" {
			append(&argv, g_arg(g_field_value(g, signed, bits)))
		} else if op == "incrby" {
			append(&argv, g_arg(g_field_incr(g, signed, bits)))
		}
	}
	g_cmdv(g, argv[:])
}

case_bitfield :: proc(g: ^Gen) {
	keys := [?]string{"f0", "f1", "f2", "f3", "f4"}
	g_cmd(g, "SET", "f1", rng_bytes(&g.r, 30, 0, context.temp_allocator))
	g_cmd(g, "SET", "f2", "12345")
	g_cmd(g, "SET", "f3", rng_bytes(&g.r, 3, 0, context.temp_allocator))
	for i in 0 ..< 4000 {
		k := keys[rng_below(&g.r, len(keys))]
		switch rng_below(&g.r, 10) {
		case 0 ..= 6:
			g_bitfield(g, k, false, 300 if rng_chance(&g.r, 90) else 3000)
			g_cmd(g, "GET", k)
		case 7, 8:
			g_bitfield(g, k, rng_chance(&g.r, 50), 400)
			g_cmd(g, "EXISTS", k)
		case:
			if rng_chance(&g.r, 50) {
				g_cmd(g, "DEL", k)
			} else {
				g_cmd(g, "SET", k, rng_bytes(&g.r, rng_below(&g.r, 40), rng_below(&g.r, 7), context.temp_allocator))
			}
		}
		if i % 200 == 0 {
			free_all(context.temp_allocator)
		}
	}
	free_all(context.temp_allocator)
	for signed in ([?]bool{true, false}) {
		top := 64 if signed else 63
		for bits in 1 ..= top {
			ty := fmt.tprintf("%s%d", "i" if signed else "u", bits)
			minv, maxv := field_bounds(signed, bits)
			q := maxv - (i128(1) << 63)
			vals := [?]i128{minv, maxv, maxv + 1, minv - 1, 0, -1, q, q + 1, i128(min(i64)), i128(max(i64))}
			for mode in ([?]string{"WRAP", "SAT", "FAIL"}) {
				for v in vals {
					if v < i128(min(i64)) || v > i128(max(i64)) {
						continue
					}
					g_cmd(g, "BITFIELD", "ov", "OVERFLOW", mode, "SET", ty, "3", i64(v), "GET", ty, "3")
				}
				for start in ([?]i128{minv, maxv, 0}) {
					for inc in ([?]i128{1, -1, maxv - start, maxv - start + 1, minv - start, minv - start - 1, 3 * (maxv - minv + 1) + 1, -3 * (maxv - minv + 1) - 1, i128(max(i64)), i128(min(i64))}) {
						if inc < i128(min(i64)) || inc > i128(max(i64)) {
							continue
						}
						g_cmd(g, "BITFIELD", "ov", "SET", ty, "5", i64(start), "OVERFLOW", mode, "INCRBY", ty, "5", i64(inc), "GET", ty, "5")
					}
				}
			}
			g_cmd(g, "GET", "ov")
			free_all(context.temp_allocator)
		}
	}
	g_cmd(g, "SET", "e1", "hello")
	errs := [][]string {
		{"FOO"},
		{"GET", "u8"},
		{"SET", "u8", "0"},
		{"INCRBY", "u8", "0"},
		{"OVERFLOW"},
		{"GET", "u8", "0", "OVERFLOW"},
		{"OVERFLOW", "BAD", "GET", "u8", "0"},
		{"OVERFLOW", "", "GET", "u8", "0"},
		{"GET", "u64", "0"},
		{"GET", "i65", "0"},
		{"GET", "i0", "0"},
		{"GET", "u0", "0"},
		{"GET", "x8", "0"},
		{"GET", "", "0"},
		{"GET", "I8", "0"},
		{"GET", "U8", "0"},
		{"GET", "i", "0"},
		{"GET", "i08", "0"},
		{"GET", "i-8", "0"},
		{"GET", "i 8", "0"},
		{"GET", "i+8", "0"},
		{"GET", "u8\x00junk", "0"},
		{"GET", "u8", "a"},
		{"GET", "u8", ""},
		{"GET", "u8", "-1"},
		{"GET", "u8", "#-1"},
		{"GET", "u8", "#"},
		{"GET", "u8", "##1"},
		{"GET", "u8", "4294967296"},
		{"GET", "u8", "#536870912"},
		{"GET", "u8", "#536870911"},
		{"GET", "u1", "4294967295"},
		{"GET", "i64", "4294967295"},
		{"GET", "i8", "#2305843009213693953"},
		{"GET", "i16", "#1152921504606846977"},
		{"GET", "i2", "#4611686018427387904"},
		{"GET", "u8", "#0", "GET", "i64", "#0"},
		{"SET", "i8", "#2305843009213693953", "5"},
		{"SET", "u8", "0", "a"},
		{"SET", "u8", "0", ""},
		{"INCRBY", "i8", "0", "x"},
		{"SET", "i64", "0", "9223372036854775808"},
		{"SET", "u8", "0", "1", "GET", "u64", "0"},
		{"SET", "u8", "0", "1", "SET", "u8", "x", "1"},
		{"get\x00x", "u8", "0"},
		{"OVERFLOW", "fail\x00x", "INCRBY", "u2", "0", "100"},
		{"OVERFLOW", "SAT", "SET", "i8", "0", "-9223372036854775808", "GET", "i8", "0"},
		{"OVERFLOW", "SAT", "SET", "i8", "0", "-9223372036854775681", "GET", "i8", "0"},
		{"OVERFLOW", "SAT", "SET", "i8", "0", "-9223372036854775680", "GET", "i8", "0"},
		{"OVERFLOW", "SAT", "SET", "i63", "0", "-9223372036854775808", "GET", "i63", "0"},
		{"OVERFLOW", "SAT", "SET", "u8", "0", "-1", "GET", "u8", "0"},
		{"OVERFLOW", "WRAP", "SET", "i1", "0", "-9223372036854775808", "GET", "i1", "0"},
		{"OVERFLOW", "SAT", "SET", "i1", "0", "-9223372036854775808", "GET", "i1", "0"},
		{"OVERFLOW", "SAT", "SET", "i1", "0", "-9223372036854775807", "GET", "i1", "0"},
	}
	for e in errs {
		for k in ([?]string{"e1", "e2"}) {
			argv := make([dynamic][]u8, context.temp_allocator)
			append(&argv, transmute([]u8)string("BITFIELD"), transmute([]u8)k)
			for a in e {
				append(&argv, transmute([]u8)a)
			}
			g_cmdv(g, argv[:])
			g_cmd(g, "GET", k)
			argv[0] = transmute([]u8)string("BITFIELD_RO")
			g_cmdv(g, argv[:])
			g_cmd(g, "EXISTS", k)
			g_cmd(g, "DEL", "e2")
		}
	}
	g_cmd(g, "LPUSH", "lst", "a")
	g_cmd(g, "BITFIELD", "lst")
	g_cmd(g, "BITFIELD", "lst", "GET", "u8", "0")
	g_cmd(g, "BITFIELD", "lst", "SET", "u8", "0", "1")
	g_cmd(g, "BITFIELD", "lst", "FOO")
	g_cmd(g, "BITFIELD", "lst", "GET", "u64", "0")
	g_cmd(g, "BITFIELD_RO", "lst")
	g_cmd(g, "BITFIELD_RO", "lst", "GET", "u8", "0")
	g_cmd(g, "BITFIELD_RO", "lst", "SET", "u8", "0", "1")
	g_cmd(g, "BITFIELD_RO", "lst", "INCRBY", "u8", "0", "1")
	g_cmd(g, "BITFIELD", "nokey")
	g_cmd(g, "EXISTS", "nokey")
	g_cmd(g, "BITFIELD_RO", "nokey")
	g_cmd(g, "BITFIELD", "nokey", "GET", "u8", "0", "GET", "i64", "100")
	g_cmd(g, "EXISTS", "nokey")
	g_cmd(g, "BITFIELD", "nokey", "OVERFLOW", "FAIL", "SET", "u8", "0", "256")
	g_cmd(g, "GET", "nokey")
	g_cmd(g, "BITFIELD")
	g_cmd(g, "BITFIELD_RO")
	g_cmd(g, "BITFIELD", "big", "SET", "u1", "4294967295", "1", "GET", "u8", "#536870911")
	g_cmd(g, "STRLEN", "big")
	g_cmd(g, "BITCOUNT", "big")
	g_cmd(g, "DEL", "big")
	free_all(context.temp_allocator)
}

case_errors :: proc(g: ^Gen) {
	g_cmd(g, "SET", "k", "abc")
	g_cmd(g, "SETBIT", "k", "1")
	g_cmd(g, "SETBIT", "k", "1", "1", "1")
	g_cmd(g, "SETBIT")
	g_cmd(g, "GETBIT", "k")
	g_cmd(g, "GETBIT", "k", "1", "2")
	g_cmd(g, "BITCOUNT")
	g_cmd(g, "BITPOS", "k")
	g_cmd(g, "BITOP", "and", "d")
	g_cmd(g, "BITOP", "and")
	g_cmd(g, "BITFIELD")
	g_cmd(g, "BITFIELD_RO")
	g_cmd(g, "setbit", "k", "a", "b")
	g_cmd(g, "setbit", "k", "-1", "b")
	g_cmd(g, "setbit", "k", "1", "b")
	g_cmd(g, "SeTbIt", "k", "1", "1")
	g_cmd(g, "GeTbIt", "k", "1")
	g_cmd(g, "get", "k")
	for o in BAD_OFFSETS {
		g_cmd(g, "SETBIT", "k", o, "1")
		g_cmd(g, "GETBIT", "k", o)
		g_cmd(g, "BITFIELD", "k", "GET", "u8", o)
		g_cmd(g, "BITFIELD", "k", "SET", "u8", o, "1")
		g_cmd(g, "BITCOUNT", "k", o, "1")
		g_cmd(g, "BITCOUNT", "k", "0", o)
		g_cmd(g, "BITPOS", "k", "1", o)
		g_cmd(g, "BITPOS", "k", "0", "0", o)
		g_cmd(g, "BITPOS", "k", o)
	}
	for b in BAD_BITS {
		g_cmd(g, "SETBIT", "k", "3", b)
		g_cmd(g, "BITPOS", "k", b)
		g_cmd(g, "BITFIELD", "k", "SET", "i8", "0", b)
		g_cmd(g, "BITFIELD", "k", "INCRBY", "i8", "0", b)
	}
	g_cmd(g, "GET", "k")
	g_cmd(g, "LPUSH", "l", "x")
	for o in ([?]string{"0", "-1", "a"}) {
		g_cmd(g, "SETBIT", "l", o, "1")
		g_cmd(g, "SETBIT", "l", "0", o)
		g_cmd(g, "GETBIT", "l", o)
		g_cmd(g, "BITCOUNT", "l", o, o)
		g_cmd(g, "BITPOS", "l", o)
		g_cmd(g, "BITPOS", "l", "0", o, o)
		g_cmd(g, "BITOP", "or", "d", "l", o)
		g_cmd(g, "BITOP", "or", "l", "k", o)
		g_cmd(g, "BITFIELD", "l", "GET", "u8", o)
	}
	g_cmd(g, "GET", "l")
	g_cmd(g, "GET", "d")
	free_all(context.temp_allocator)
}

case_intenc :: proc(g: ^Gen) {
	vals := [?]string{"0", "1", "12345", "-42", "9223372036854775807", "-9223372036854775808", "007", "1e5", "  3"}
	for v, i in vals {
		k := fmt.tprintf("n%d", i)
		g_cmd(g, "SET", k, v)
		g_cmd(g, "GETBIT", k, "0")
		g_cmd(g, "GETBIT", k, "2")
		g_cmd(g, "GETBIT", k, "13")
		g_cmd(g, "GETBIT", k, "1000")
		g_cmd(g, "BITCOUNT", k)
		g_cmd(g, "BITCOUNT", k, "1", "-1")
		g_cmd(g, "BITCOUNT", k, "3", "17", "BIT")
		g_cmd(g, "BITPOS", k, "1")
		g_cmd(g, "BITPOS", k, "0")
		g_cmd(g, "BITPOS", k, "0", "1", "-1")
		g_cmd(g, "BITPOS", k, "1", "9", "30", "bit")
		g_cmd(g, "BITFIELD", k, "GET", "u8", "0", "GET", "i16", "#1", "GET", "u63", "1", "GET", "i64", "0")
		g_cmd(g, "BITFIELD_RO", k, "GET", "u4", "4")
		g_cmd(g, "BITOP", "NOT", fmt.tprintf("r%d", i), k)
		g_cmd(g, "GET", fmt.tprintf("r%d", i))
		g_cmd(g, "BITOP", "XOR", fmt.tprintf("x%d", i), k, "n2")
		g_cmd(g, "GET", fmt.tprintf("x%d", i))
		g_cmd(g, "SETBIT", k, "6", "0")
		g_cmd(g, "GET", k)
		g_cmd(g, "BITFIELD", k, "INCRBY", "u8", "#0", "1", "SET", "i8", "#1", "57")
		g_cmd(g, "GET", k)
		g_cmd(g, "SETBIT", k, "100", "1")
		g_cmd(g, "GET", k)
	}
	g_cmd(g, "SET", "a", "1")
	g_cmd(g, "SET", "b", "2")
	g_cmd(g, "BITOP", "xor", "dest", "a", "b", "a")
	g_cmd(g, "GET", "dest")
	g_cmd(g, "SET", "bits", "1")
	g_cmd(g, "BITFIELD", "bits", "GET", "u1", "0")
	g_cmd(g, "APPEND", "bits", "23")
	g_cmd(g, "BITCOUNT", "bits")
	free_all(context.temp_allocator)
}

case_mixed :: proc(g: ^Gen) {
	keys := [?]string{"m0", "m1", "m2", "m3", "m4", "m5", "lst", "nk"}
	g_cmd(g, "LPUSH", "lst", "a")
	for i in 0 ..< 8000 {
		k := keys[rng_below(&g.r, len(keys))]
		switch rng_below(&g.r, 16) {
		case 0, 1:
			g_cmd(g, "SETBIT", k, rng_below(&g.r, 1200), rng_below(&g.r, 2))
		case 2:
			g_cmd(g, "GETBIT", k, rng_below(&g.r, 1300))
		case 3:
			a := rng_range(&g.r, -200, 200)
			b := rng_range(&g.r, -200, 200)
			switch rng_below(&g.r, 4) {
			case 0:
				g_cmd(g, "BITCOUNT", k)
			case 1:
				g_cmd(g, "BITCOUNT", k, a, b)
			case:
				g_cmd(g, "BITCOUNT", k, a * 8, b * 8 + 3, g_unit(g, rng_chance(&g.r, 50)))
			}
		case 4:
			a := rng_range(&g.r, -200, 200)
			b := rng_range(&g.r, -200, 200)
			bit := rng_below(&g.r, 2)
			switch rng_below(&g.r, 4) {
			case 0:
				g_cmd(g, "BITPOS", k, bit)
			case 1:
				g_cmd(g, "BITPOS", k, bit, a)
			case 2:
				g_cmd(g, "BITPOS", k, bit, a, b)
			case:
				g_cmd(g, "BITPOS", k, bit, a * 8, b * 8 + 5, g_unit(g, rng_chance(&g.r, 50)))
			}
		case 5, 6:
			op := g_pick(g, {"AND", "OR", "XOR", "NOT"})
			n := 1 if op == "NOT" else 1 + rng_below(&g.r, 4)
			argv := make([dynamic][]u8, context.temp_allocator)
			append(&argv, transmute([]u8)string("BITOP"), transmute([]u8)op, transmute([]u8)k)
			for _ in 0 ..< n {
				append(&argv, transmute([]u8)keys[rng_below(&g.r, len(keys))])
			}
			g_cmdv(g, argv[:])
		case 7, 8:
			g_bitfield(g, k, false, 1000)
		case 9:
			g_bitfield(g, k, true, 1000)
		case 10, 11:
			g_cmd(g, "GET", k)
		case 12:
			g_cmd(g, "APPEND", k, rng_bytes(&g.r, rng_below(&g.r, 20), rng_below(&g.r, 7), context.temp_allocator))
		case 13:
			g_cmd(g, "SET", k, rng_bytes(&g.r, rng_below(&g.r, 150), rng_below(&g.r, 7), context.temp_allocator))
		case 14:
			g_cmd(g, "DEL", k)
		case:
			if k == "lst" {
				g_cmd(g, "LPUSH", "lst", "b")
			} else {
				g_cmd(g, "STRLEN", k)
			}
		}
		if i % 300 == 0 {
			free_all(context.temp_allocator)
		}
	}
	for k in keys {
		g_cmd(g, "GET", k)
	}
	free_all(context.temp_allocator)
}

case_large :: proc(g: ^Gen) {
	g_cmd(g, "SETBIT", "big", "4294967295", "1")
	g_cmd(g, "SETBIT", "big", "4294967296", "1")
	g_cmd(g, "GETBIT", "big", "4294967295")
	g_cmd(g, "GETBIT", "big", "4294967294")
	g_cmd(g, "STRLEN", "big")
	g_cmd(g, "BITCOUNT", "big")
	g_cmd(g, "BITCOUNT", "big", "-1", "-1")
	g_cmd(g, "BITCOUNT", "big", "0", "-1", "BIT")
	g_cmd(g, "BITCOUNT", "big", "4294967290", "4294967295", "BIT")
	g_cmd(g, "BITPOS", "big", "1")
	g_cmd(g, "BITPOS", "big", "0")
	g_cmd(g, "BITPOS", "big", "1", "536870911")
	g_cmd(g, "BITPOS", "big", "0", "536870911")
	g_cmd(g, "BITPOS", "big", "0", "536870911", "-1")
	g_cmd(g, "BITPOS", "big", "1", "4294967290", "-1", "BIT")
	g_cmd(g, "BITPOS", "big", "1", "-100", "-2")
	g_cmd(g, "BITFIELD", "big", "GET", "u8", "#536870911", "SET", "u8", "#536870911", "255", "GET", "i8", "4294967288")
	g_cmd(g, "BITFIELD_RO", "big", "GET", "u63", "4294967233")
	g_cmd(g, "BITCOUNT", "big")
	g_cmd(g, "BITPOS", "big", "0", "536870911", "-1")
	g_cmd(g, "BITPOS", "big", "0", "536870911")
	g_cmd(g, "DEL", "big")
	free_all(context.temp_allocator)
}
