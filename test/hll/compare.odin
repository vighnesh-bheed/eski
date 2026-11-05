package hll_harness

import hll "../../src/hll"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Gen :: struct {
	dir:    string,
	names:  [dynamic]string,
	mirror: Local,
	load:   [dynamic]u8,
	script: [dynamic]u8,
	name:   string,
	synced: int,
}

gen_elements :: proc(tag: string, n: int, seed: u64) -> [][]u8 {
	rng := seed
	out := make([][]u8, n)
	for i in 0 ..< n {
		out[i] = transmute([]u8)fmt.aprintf("%s:%d:%x", tag, i, hll.splitmix64(&rng))
	}
	return out
}

gen_begin :: proc(g: ^Gen, name: string) {
	g.name = name
	g.synced = 0
	clear(&g.load)
	clear(&g.script)
}

gen_sync :: proc(g: ^Gen) {
	cmds, _ := parse_commands(g.script[g.synced:], context.temp_allocator)
	sink := make([dynamic]u8, context.temp_allocator)
	for c in cmds {
		exec(&g.mirror, c, &sink)
	}
	g.synced = len(g.script)
}

emit_copy :: proc(g: ^Gen, src, dst: string) {
	gen_sync(g)
	v, _ := lookup(&g.mirror, transmute([]u8)src)
	cmd_with(&g.script, {"SET", dst}, {v})
}

emit_overwrite :: proc(g: ^Gen, key: string, offset: int, patch: []u8) {
	gen_sync(g)
	v, _ := lookup(&g.mirror, transmute([]u8)key)
	nv := make([]u8, max(len(v), offset + len(patch)), context.temp_allocator)
	copy(nv, v)
	copy(nv[offset:], patch)
	cmd_with(&g.script, {"SET", key}, {nv})
}

gen_end :: proc(g: ^Gen) -> bool {
	file, _ := strings.replace_all(g.name, ":", "_")
	gen_sync(g)
	gen_dump_keys(g)
	if os.write_entire_file(fmt.tprintf("%s/%s.load", g.dir, file), g.load[:]) != nil {
		return false
	}
	if os.write_entire_file(fmt.tprintf("%s/%s.script", g.dir, file), g.script[:]) != nil {
		return false
	}
	append(&g.names, file)
	free_all(context.temp_allocator)
	return true
}

gen_dump_keys :: proc(g: ^Gen) {
	names := make([dynamic]string, context.temp_allocator)
	for k in g.mirror.keys {
		append(&names, k)
	}
	slice.sort(names[:])
	for k in names {
		cmd(&g.script, "DUMP", k)
	}
	gen_sync(g)
}

gen_load_pfadd :: proc(g: ^Gen, key: string, elems: [][]u8, batch: int) {
	sink := make([dynamic]u8, context.temp_allocator)
	head := []string{"PFADD", key}
	if len(elems) == 0 {
		before := len(g.load)
		cmd(&g.load, ..head)
		cmds, _ := parse_commands(g.load[before:], context.temp_allocator)
		for c in cmds {
			exec(&g.mirror, c, &sink)
		}
		return
	}
	i := 0
	for i < len(elems) {
		j := min(i + batch, len(elems))
		before := len(g.load)
		cmd_with(&g.load, head, elems[i:j])
		cmds, _ := parse_commands(g.load[before:], context.temp_allocator)
		for c in cmds {
			exec(&g.mirror, c, &sink)
		}
		i = j
	}
}

probe :: proc(g: ^Gen, key: string) {
	s := &g.script
	cp := fmt.tprintf("%s:copy", key)
	cmd(s, "STRLEN", key)
	cmd(s, "GET", key)
	cmd(s, "PFDEBUG", "ENCODING", key)
	cmd(s, "PFDEBUG", "DECODE", key)
	cmd(s, "PFCOUNT", key)
	cmd(s, "GET", key)
	cmd(s, "PFCOUNT", key)
	emit_copy(g, key, cp)
	cmd(s, "PFDEBUG", "GETREG", cp)
	cmd(s, "GET", cp)
	cmd(s, "PFDEBUG", "ENCODING", cp)
	cmd(s, "PFDEBUG", "TODENSE", key)
	cmd(s, "PFDEBUG", "TODENSE", key)
	cmd(s, "GET", key)
	cmd(s, "PFCOUNT", key)
}

SIZES :: [?]int{1, 10, 100, 500, 1000, 1500, 2000, 2500, 3000, 5000, 10000, 100000}

run_gen :: proc(dir: string) -> bool {
	g := Gen {
		dir    = dir,
		mirror = local_make(),
	}
	g.names = make([dynamic]string)
	g.load = make([dynamic]u8)
	g.script = make([dynamic]u8)

	for n in SIZES {
		key := fmt.aprintf("size:%d", n)
		gen_begin(&g, key)
		gen_load_pfadd(&g, key, gen_elements(fmt.tprintf("s%d", n), n, u64(n) * 7919), 1000)
		probe(&g, key)
		gen_end(&g) or_return
	}

	{
		gen_begin(&g, "dup")
		pool := gen_elements("pool", 2500, 42)
		rng: u64 = 4242
		picks := make([][]u8, 30000)
		for i in 0 ..< len(picks) {
			picks[i] = pool[hll.splitmix64(&rng) % u64(len(pool))]
		}
		gen_load_pfadd(&g, "dup", picks, 700)
		gen_load_pfadd(&g, "dup", pool[:500], 500)
		probe(&g, "dup")
		cmd_with(&g.script, {"PFADD", "dup"}, pool[:100])
		cmd_with(&g.script, {"PFADD", "dup"}, picks[:1000])
		cmd(&g.script, "GET", "dup")
		cmd(&g.script, "PFCOUNT", "dup")
		gen_end(&g) or_return
	}

	{
		gen_begin(&g, "tails")
		elems := make([dynamic][]u8)
		rng: u64 = 99
		for length in 0 ..= 40 {
			for _ in 0 ..< 6 {
				e := make([]u8, length)
				for k in 0 ..< length {
					e[k] = u8(hll.splitmix64(&rng) & 0xff)
				}
				append(&elems, e)
			}
		}
		for b in 0 ..< 256 {
			e := make([]u8, 1)
			e[0] = u8(b)
			append(&elems, e)
		}
		gen_load_pfadd(&g, "tails", elems[:], 97)
		probe(&g, "tails")
		gen_end(&g) or_return
	}

	{
		gen_begin(&g, "replies")
		s := &g.script
		cmd(s, "PFADD", "r:hll")
		cmd(s, "EXISTS", "r:hll")
		cmd(s, "PFCOUNT", "r:hll")
		cmd(s, "GET", "r:hll")
		cmd(s, "PFADD", "r:hll")
		cmd(s, "PFADD", "r:hll", "a", "b", "c")
		cmd(s, "PFADD", "r:hll", "a", "b", "c")
		cmd(s, "PFADD", "r:hll", "")
		cmd(s, "PFADD", "r:hll", "a", "a", "a")
		cmd(s, "GET", "r:hll")
		cmd(s, "PFCOUNT", "r:hll")
		cmd(s, "GET", "r:hll")
		cmd(s, "PFADD", "r:h5", "1", "2", "3", "4", "5")
		cmd(s, "PFCOUNT", "r:h5")
		cmd(s, "PFADD", "r:h5", "6", "7", "8", "8", "9", "10")
		cmd(s, "PFCOUNT", "r:h5")
		cmd(s, "GET", "r:h5")
		cmd(s, "PFADD", "r:c", "a", "b", "c")
		cmd(s, "PFCOUNT", "r:c")
		cmd(s, "GET", "r:c")
		cmd(s, "PFADD", "r:c", "a", "b", "c")
		cmd(s, "GET", "r:c")
		cmd(s, "PFADD", "r:c", "1", "2", "3")
		cmd(s, "GET", "r:c")
		cmd(s, "PFCOUNT", "r:c")
		cmd(s, "GET", "r:c")
		cmd(s, "PFDEBUG", "DECODE", "r:c")
		gen_end(&g) or_return
	}

	{
		gen_begin(&g, "signals")
		s := &g.script
		cmd(s, "PFADD", "w:hll", "a", "b", "c")
		for step in ([?][]string{{"PFCOUNT", "w:hll"}, {"PFCOUNT", "w:hll"}, {"PFADD", "w:hll", "a"}, {"PFADD", "w:hll", "zz"}, {"PFCOUNT", "w:hll"}, {"PFCOUNT", "w:hll", "w:hll"}, {"PFADD", "w:hll", "zz"}, {"PFCOUNT", "w:none"}}) {
			cmd(s, "WATCH", "w:hll")
			cmd(s, ..step)
			cmd(s, "MULTI")
			cmd(s, "PING")
			cmd(s, "EXEC")
		}
		gen_end(&g) or_return
	}

	for max_bytes in ([]int{3000, 500, 100}) {
		key := fmt.aprintf("growth:%d", max_bytes)
		gen_begin(&g, key)
		s := &g.script
		cmd(s, "CONFIG", "SET", "hll-sparse-max-bytes", fmt.tprintf("%d", max_bytes))
		cmd(s, "PFADD", key)
		limit := 3000 if max_bytes == 3000 else 600
		elems := gen_elements(fmt.tprintf("g%d", max_bytes), limit, u64(max_bytes) + 17)
		for i in 0 ..< len(elems) {
			cmd_with(s, {"PFADD", key}, elems[i:i + 1])
			cmd(s, "STRLEN", key)
			if i % 250 == 249 {
				cmd(s, "GET", key)
				cmd(s, "PFDEBUG", "DECODE", key)
			}
		}
		cmd(s, "GET", key)
		cmd(s, "PFDEBUG", "ENCODING", key)
		cmd(s, "PFCOUNT", key)
		cmd(s, "CONFIG", "SET", "hll-sparse-max-bytes", "3000")
		gen_end(&g) or_return
	}

	{
		gen_begin(&g, "maxchange")
		s := &g.script
		cmd(s, "CONFIG", "SET", "hll-sparse-max-bytes", "3000")
		cmd(s, "PFADD", "cm", "a", "b", "c", "d", "e", "d", "g", "h", "i", "j", "k")
		cmd(s, "PFDEBUG", "ENCODING", "cm")
		cmd(s, "GET", "cm")
		cmd(s, "CONFIG", "SET", "hll-sparse-max-bytes", "30")
		cmd(s, "PFADD", "cm", "a")
		cmd(s, "PFDEBUG", "ENCODING", "cm")
		cmd(s, "PFADD", "cm", "new_element")
		cmd(s, "PFDEBUG", "ENCODING", "cm")
		cmd(s, "GET", "cm")
		cmd(s, "PFCOUNT", "cm")
		cmd(s, "CONFIG", "SET", "hll-sparse-max-bytes", "3000")
		gen_end(&g) or_return
	}

	{
		gen_begin(&g, "merge")
		gen_load_pfadd(&g, "ma", gen_elements("ma", 300, 1), 1000)
		gen_load_pfadd(&g, "mb", gen_elements("mb", 800, 2), 1000)
		gen_load_pfadd(&g, "mc", gen_elements("mc", 1200, 3), 1000)
		gen_load_pfadd(&g, "md", gen_elements("md", 20000, 4), 1000)
		gen_load_pfadd(&g, "mx", gen_elements("mx", 1000, 5), 1000)
		gen_load_pfadd(&g, "my", gen_elements("my", 1000, 6), 1000)
		gen_load_pfadd(&g, "mz", gen_elements("mz", 1000, 7), 1000)
		shared := gen_elements("ma", 300, 1)
		gen_load_pfadd(&g, "mo", shared[:150], 1000)
		s := &g.script
		for k in ([]string{"ma", "mb", "mc", "md", "mx", "my", "mz", "mo"}) {
			cmd(s, "STRLEN", k)
			cmd(s, "PFDEBUG", "ENCODING", k)
		}
		cmd(s, "PFMERGE", "m:ab", "ma", "mb")
		cmd(s, "GET", "m:ab")
		cmd(s, "PFDEBUG", "ENCODING", "m:ab")
		cmd(s, "PFCOUNT", "m:ab")
		cmd(s, "GET", "m:ab")
		cmd(s, "PFMERGE", "m:abc", "ma", "mb", "mc")
		cmd(s, "GET", "m:abc")
		cmd(s, "PFDEBUG", "ENCODING", "m:abc")
		cmd(s, "PFCOUNT", "m:abc")
		cmd(s, "PFMERGE", "m:xyz", "mx", "my", "mz")
		cmd(s, "STRLEN", "m:xyz")
		cmd(s, "GET", "m:xyz")
		cmd(s, "PFDEBUG", "ENCODING", "m:xyz")
		cmd(s, "PFCOUNT", "m:xyz")
		cmd(s, "PFMERGE", "m:dense", "ma", "md", "mb")
		cmd(s, "GET", "m:dense")
		cmd(s, "PFCOUNT", "m:dense")
		cmd(s, "PFMERGE", "m:ao", "ma", "mo")
		cmd(s, "GET", "m:ao")
		cmd(s, "PFCOUNT", "m:ao")
		cmd(s, "PFCOUNT", "ma", "mb", "mc")
		cmd(s, "PFCOUNT", "ma", "mb", "mc", "md")
		cmd(s, "PFCOUNT", "mx", "my", "mz")
		cmd(s, "PFCOUNT", "ma", "nosuch", "mb")
		cmd(s, "PFCOUNT", "nosuch", "nosuch2")
		cmd(s, "PFADD", "m:exist", "x", "y", "z")
		cmd(s, "PFMERGE", "m:exist", "ma")
		cmd(s, "GET", "m:exist")
		cmd(s, "PFCOUNT", "m:exist")
		cmd(s, "PFADD", "m:existd", "x", "y", "z")
		cmd(s, "PFDEBUG", "TODENSE", "m:existd")
		cmd(s, "PFMERGE", "m:existd", "ma", "mb")
		cmd(s, "GET", "m:existd")
		cmd(s, "PFCOUNT", "m:existd")
		cmd(s, "PFMERGE", "m:empty")
		cmd(s, "GET", "m:empty")
		cmd(s, "PFCOUNT", "m:empty")
		cmd(s, "PFMERGE", "m:missing", "nosuch1", "nosuch2")
		cmd(s, "EXISTS", "m:missing")
		cmd(s, "GET", "m:missing")
		cmd(s, "PFMERGE", "m:self", "mb", "m:self", "mb")
		cmd(s, "GET", "m:self")
		cmd(s, "PFADD", "m:self2", "a", "b", "c")
		cmd(s, "PFMERGE", "m:self2")
		cmd(s, "GET", "m:self2")
		cmd(s, "PFCOUNT", "m:self2")
		cmd(s, "PFADD", "u1", "a", "b", "c")
		cmd(s, "PFADD", "u2", "b", "c", "d")
		cmd(s, "PFADD", "u3", "c", "d", "e")
		cmd(s, "PFMERGE", "u", "u1", "u2", "u3")
		cmd(s, "PFCOUNT", "u")
		cmd(s, "GET", "u")
		emit_copy(&g, "m:abc", "m:abc:copy")
		cmd(s, "PFDEBUG", "GETREG", "m:abc:copy")
		emit_copy(&g, "m:dense", "m:dense:copy")
		cmd(s, "PFDEBUG", "GETREG", "m:dense:copy")
		gen_end(&g) or_return
	}

	gen_errors(&g) or_return
	gen_fuzz(&g) or_return

	{
		gen_begin(&g, "selftest")
		cmd(&g.script, "PFSELFTEST")
		gen_end(&g) or_return
	}

	sb := strings.builder_make()
	for n in g.names {
		strings.write_string(&sb, n)
		strings.write_byte(&sb, '\n')
	}
	return os.write_entire_file(fmt.tprintf("%s/cases.txt", dir), transmute([]u8)strings.to_string(sb)) == nil
}

crafted_header :: proc(buf: ^[dynamic]u8, encoding: u8, invalid_cache: bool) {
	append(buf, "HYLL")
	append(buf, encoding, 0, 0, 0)
	for i in 0 ..< 8 {
		append(buf, 0x80 if invalid_cache && i == 7 else 0)
	}
}

gen_errors :: proc(g: ^Gen) -> bool {
	gen_begin(g, "errors")
	s := &g.script
	cmd(s, "SET", "foo", "bar")
	cmd(s, "PFADD", "foo", "1")
	cmd(s, "PFCOUNT", "foo")
	cmd(s, "PFMERGE", "bar", "foo")
	cmd(s, "EXISTS", "bar")
	cmd(s, "PFMERGE", "foo", "bar")
	cmd(s, "PFCOUNT", "foo", "nosuch")
	cmd(s, "PFADD", "e:ok", "a", "b", "c")
	cmd(s, "PFCOUNT", "e:ok", "foo")
	cmd(s, "PFDEBUG", "ENCODING", "nosuch")
	cmd(s, "PFDEBUG", "FOO", "nosuch")
	cmd(s, "PFDEBUG", "FOO", "e:ok")
	cmd(s, "PFDEBUG", "encoding", "e:ok", "extra")
	cmd(s, "PFDEBUG", "GetReg", "e:ok", "extra")
	cmd(s, "PFDEBUG", "decode", "e:ok", "x", "y")
	cmd(s, "PFDEBUG", "todense", "e:ok", "extra")
	cmd(s, "PFDEBUG", "encoding", "foo")
	cmd(s, "PFDEBUG", "ENCODING")
	cmd(s, "SET", "num", "12345")
	cmd(s, "PFCOUNT", "num")
	cmd(s, "PFADD", "num", "x")
	cmd(s, "SET", "short", "HYLL")
	cmd(s, "PFCOUNT", "short")
	cmd(s, "SET", "empty", "")
	cmd(s, "PFCOUNT", "empty")
	cmd(s, "PFMERGE", "empty", "e:ok")
	cmd(s, "PFADD", "e:d", "a", "b", "c")
	cmd(s, "PFDEBUG", "TODENSE", "e:d")
	cmd(s, "PFDEBUG", "DECODE", "e:d")
	cmd(s, "PFDEBUG", "TODENSE", "e:d")

	cmd(s, "PFADD", "c1", "a", "b", "c")
	cmd(s, "APPEND", "c1", "hello")
	cmd(s, "PFCOUNT", "c1")
	cmd(s, "PFCOUNT", "c1", "e:ok")
	cmd(s, "PFMERGE", "c1m", "c1")
	cmd(s, "PFDEBUG", "DECODE", "c1")
	cmd(s, "PFADD", "c1", "zz1", "zz2")
	cmd(s, "GET", "c1")
	cmd(s, "PFDEBUG", "GETREG", "c1")
	cmd(s, "PFDEBUG", "TODENSE", "c1")
	cmd(s, "PFCOUNT", "c1")

	cmd(s, "PFADD", "c2", "a", "b", "c")
	emit_overwrite(g, "c2", 0, transmute([]u8)string("0123"))
	cmd(s, "PFCOUNT", "c2")
	cmd(s, "PFADD", "c3", "a", "b", "c")
	emit_overwrite(g, "c3", 4, transmute([]u8)string("x"))
	cmd(s, "PFCOUNT", "c3")
	cmd(s, "PFADD", "c4", "a", "b", "c")
	emit_overwrite(g, "c4", 4, {0})
	cmd(s, "PFCOUNT", "c4")
	cmd(s, "PFADD", "c4", "q")
	cmd(s, "PFDEBUG", "GETREG", "c4")

	big := make([dynamic]u8)
	crafted_header(&big, 1, false)
	for _ in 0 ..< 131072 + 1000 {
		append(&big, 0x40 | u8((16383 >> 8) & 0x3f), u8(16383 & 0xff))
	}
	append(&big, 0xff)
	cmd_with(s, {"SET", "ov:x"}, {big[:]})
	cmd(s, "PFCOUNT", "ov:x", "ov:x")
	cmd(s, "PFDEBUG", "GETREG", "ov:x")
	cmd(s, "PFCOUNT", "ov:x")
	cmd(s, "PFADD", "ov:x", "a")
	cmd(s, "STRLEN", "ov:x")

	zero := make([dynamic]u8)
	crafted_header(&zero, 1, false)
	for _ in 0 ..< 300 {
		append(&zero, 0x3f)
	}
	append(&zero, 0xff)
	cmd_with(s, {"SET", "ov:z"}, {zero[:]})
	cmd(s, "PFCOUNT", "ov:z", "ov:z")
	cmd(s, "PFDEBUG", "GETREG", "ov:z")
	cmd(s, "PFCOUNT", "ov:z")

	trunc := make([dynamic]u8)
	crafted_header(&trunc, 1, true)
	append(&trunc, 0x80, 0x3f, 0x3f, 0x3f, 0x3d, 0x7f)
	cmd_with(s, {"SET", "tr"}, {trunc[:]})
	cmd(s, "PFCOUNT", "tr")
	cmd(s, "PFDEBUG", "DECODE", "tr")
	cmd(s, "PFCOUNT", "tr", "tr")
	emit_copy(g, "tr", "tr:copy")
	cmd(s, "PFDEBUG", "GETREG", "tr:copy")
	cmd(s, "GET", "tr:copy")

	trunc2 := make([dynamic]u8)
	crafted_header(&trunc2, 1, true)
	append(&trunc2, 0x80, 0x3f, 0x3f, 0x3f, 0x3d, 0x7f)
	cmd_with(s, {"SET", "tr2"}, {trunc2[:]})
	for i in 0 ..< 40 {
		cmd(s, "PFADD", "tr2", fmt.tprintf("t%d", i))
		cmd(s, "GET", "tr2")
	}
	cmd(s, "PFCOUNT", "tr2")

	all63 := make([dynamic]u8)
	crafted_header(&all63, 0, true)
	for _ in 0 ..< hll.HLL_DENSE_SIZE - hll.HLL_HDR_SIZE {
		append(&all63, 0xff)
	}
	cmd_with(s, {"SET", "d63"}, {all63[:]})
	cmd(s, "PFCOUNT", "d63")
	cmd(s, "GET", "d63")
	cmd(s, "PFCOUNT", "d63", "d63")
	cmd(s, "PFADD", "d63", "a")
	cmd(s, "PFMERGE", "d63m", "d63")
	cmd(s, "PFCOUNT", "d63m")

	half := make([dynamic]u8)
	crafted_header(&half, 0, true)
	rng: u64 = 777
	for _ in 0 ..< hll.HLL_DENSE_SIZE - hll.HLL_HDR_SIZE {
		append(&half, u8(hll.splitmix64(&rng) & 0xff))
	}
	cmd_with(s, {"SET", "drand"}, {half[:]})
	cmd(s, "PFCOUNT", "drand")
	cmd(s, "PFCOUNT", "drand", "e:ok")
	cmd(s, "PFADD", "drand", "a", "b", "c")
	cmd(s, "GET", "drand")
	cmd(s, "PFMERGE", "drandm", "e:ok", "drand")
	cmd(s, "GET", "drandm")

	notused := make([dynamic]u8)
	crafted_header(&notused, 1, false)
	notused[5] = 7
	notused[8] = 3
	append(&notused, 0x7f, 0xff)
	cmd_with(s, {"SET", "nu"}, {notused[:]})
	cmd(s, "PFCOUNT", "nu")
	cmd(s, "PFADD", "nu", "a")
	cmd(s, "GET", "nu")
	cmd(s, "PFDEBUG", "TODENSE", "nu")
	cmd(s, "GET", "nu")
	return gen_end(g)
}

gen_fuzz :: proc(g: ^Gen) -> bool {
	gen_begin(g, "fuzz")
	rng: u64 = 0xf022
	gen_load_pfadd(g, "f:base", gen_elements("fb", 50, 9), 1000)
	for it in 0 ..< 300 {
		key := fmt.aprintf("f:%d", it)
		numitems := int(hll.splitmix64(&rng) % 3000)
		if it % 10 == 9 {
			numitems = 3000 + int(hll.splitmix64(&rng) % 17000)
		}
		gen_load_pfadd(g, key, gen_elements(fmt.tprintf("fz%d", it), numitems, u64(it) + 1000), 1000)
		gen_sync(g)
		v, _ := lookup(&g.mirror, transmute([]u8)key)
		length := len(v)
		corrupted := make([]u8, length, context.temp_allocator)
		copy(corrupted, v)
		s := &g.script
		for _ in 0 ..< 5 {
			pos := int(hll.splitmix64(&rng) % u64(length))
			if hll.splitmix64(&rng) % 8 == 0 {
				pos = length - 1
			}
			corrupted[pos] = u8(hll.splitmix64(&rng) & 0xff)
			if hll.splitmix64(&rng) % 2 == 0 {
				break
			}
		}
		cmd_with(s, {"SET", key}, {corrupted})
		cmd(s, "PFCOUNT", key)
		cmd(s, "GET", key)
		cmd(s, "PFDEBUG", "DECODE", key)
		cmd_with(s, {"PFADD", key}, gen_elements(fmt.tprintf("fx%d", it), 5, u64(it) + 5000))
		cmd(s, "GET", key)
		cmd(s, "PFCOUNT", key)
		cmd(s, "PFCOUNT", key, "f:base")
		cmd(s, "PFMERGE", fmt.tprintf("fm:%d", it), key)
		cmd(s, "GET", fmt.tprintf("fm:%d", it))
		cmd(s, "PFDEBUG", "GETREG", key)
		cmd(s, "GET", key)
	}
	return gen_end(g)
}

escape_excerpt :: proc(b: []u8, limit: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c, i in b {
		if i >= limit {
			strings.write_string(&sb, "...")
			break
		}
		if c >= 0x20 && c < 0x7f && c != '\\' {
			strings.write_byte(&sb, c)
		} else {
			fmt.sbprintf(&sb, "\\x%02x", c)
		}
	}
	return strings.to_string(sb)
}

first_diff :: proc(a, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return i
		}
	}
	return n
}

Summary :: struct {
	strlen:       i64,
	encoding:     string,
	count:        i64,
	have_strlen:  bool,
	have_enc:     bool,
	have_count:   bool,
	adds:         int,
	last_sparse:  i64,
	promoted_at:  int,
	promoted_len: i64,
	max_sparse:   i64,
}

report_mismatch :: proc(case_name: string, who: string, idx: int, c: [][]u8, want, got: []u8) {
	d := first_diff(want, got)
	from := max(d - 16, 0)
	label := escape_excerpt(transmute([]u8)strings.join(transmute([]string)c[:min(len(c), 3)], " ", context.temp_allocator), 60)
	fmt.eprintfln("MISMATCH %s %s command %d (%s): redis %d bytes, %s %d bytes, first difference at byte %d", who, case_name, idx, label, len(want), who, len(got), d)
	fmt.eprintfln("  redis: %s", escape_excerpt(want[from:], 120))
	fmt.eprintfln("  %s: %s", who, escape_excerpt(got[from:], 120))
}

run_compare :: proc(dir: string) -> bool {
	names_data, rerr := os.read_entire_file(fmt.tprintf("%s/cases.txt", dir), context.allocator)
	if rerr != nil {
		fmt.eprintfln("cannot read cases.txt in %s", dir)
		return false
	}
	l := local_make()
	total_cmds := 0
	model_bad_total := 0
	server_bad_total := 0
	server_cases := 0
	cases := 0
	dumps := 0
	dump_bytes := 0
	for name in strings.split_lines(strings.trim_space(string(names_data))) {
		load, _ := os.read_entire_file(fmt.tprintf("%s/%s.load", dir, name), context.allocator)
		script, _ := os.read_entire_file(fmt.tprintf("%s/%s.script", dir, name), context.allocator)
		redis, ferr := os.read_entire_file(fmt.tprintf("%s/%s.redis", dir, name), context.allocator)
		if ferr != nil {
			fmt.eprintfln("FAIL %s: missing Redis reply file", name)
			return false
		}
		eski, jerr := os.read_entire_file(fmt.tprintf("%s/%s.eski", dir, name), context.allocator)
		have_eski := jerr == nil
		sink := make([dynamic]u8)
		lcmds, lok := parse_commands(load)
		scmds, sok := parse_commands(script)
		if !lok || !sok {
			fmt.eprintfln("FAIL %s: cannot parse command files", name)
			return false
		}
		for c in lcmds {
			clear(&sink)
			exec(&l, c, &sink)
		}
		pos := 0
		jpos := 0
		model_bad := 0
		server_bad := 0
		sum: Summary
		sum.promoted_at = -1
		for c, idx in scmds {
			clear(&sink)
			exec(&l, c, &sink)
			end, eok := reply_end(redis, pos)
			if !eok {
				fmt.eprintfln("FAIL %s: Redis reply stream ended early at command %d", name, idx)
				return false
			}
			want := redis[pos:end]
			pos = end
			if string(want) != string(sink[:]) {
				model_bad += 1
				if model_bad <= 5 {
					report_mismatch(name, "model", idx, c, want, sink[:])
				}
			}
			if have_eski {
				jend, jok := reply_end(eski, jpos)
				if !jok {
					fmt.eprintfln("FAIL %s: eski reply stream ended early at command %d", name, idx)
					return false
				}
				got := eski[jpos:jend]
				jpos = jend
				if string(want) != string(got) {
					server_bad += 1
					if server_bad <= 5 {
						report_mismatch(name, "eski", idx, c, want, got)
					}
				}
			}
			if strings.equal_fold(string(c[0]), "DUMP") {
				dumps += 1
				if len(want) > 0 && want[0] == '$' && want[1] != '-' {
					dump_bytes += len(want)
				}
			}
			summarize(&sum, c, want)
			free_all(context.temp_allocator)
		}
		if pos != len(redis) {
			fmt.eprintfln("FAIL %s: %d unread bytes in the Redis reply stream", name, len(redis) - pos)
			model_bad += 1
		}
		if have_eski {
			server_cases += 1
			if jpos != len(eski) {
				fmt.eprintfln("FAIL %s: %d unread bytes in the eski reply stream", name, len(eski) - jpos)
				server_bad += 1
			}
		}
		total_cmds += len(scmds)
		model_bad_total += model_bad
		server_bad_total += server_bad
		cases += 1
		status := "ok" if model_bad == 0 else "FAIL"
		server_status := "-"
		if have_eski {
			server_status = "ok" if server_bad == 0 else "FAIL"
		}
		if strings.has_prefix(name, "size_") || name == "dup" || name == "tails" {
			fmt.printfln("%-12s model=%-4s eski=%-4s commands=%-5d strlen=%-6d encoding=%-6s pfcount=%d", name, status, server_status, len(scmds), sum.strlen, sum.encoding, sum.count)
		} else if strings.has_prefix(name, "growth_") {
			fmt.printfln("%-12s model=%-4s eski=%-4s commands=%-5d single-element PFADDs=%d max_sparse_len=%d last_sparse_len=%d promoted_on_add=%d dense_len=%d", name, status, server_status, len(scmds), sum.adds, sum.max_sparse, sum.last_sparse, sum.promoted_at, sum.promoted_len)
		} else {
			fmt.printfln("%-12s model=%-4s eski=%-4s commands=%d", name, status, server_status, len(scmds))
		}
		delete(sink)
	}
	fmt.printfln("compared %d cases, %d commands: model %d mismatches, eski server %d mismatches over %d cases", cases, total_cmds, model_bad_total, server_bad_total, server_cases)
	fmt.printfln("DUMP payloads compared byte for byte against Redis: %d (%d reply bytes), checked against the model and against the eski server", dumps, dump_bytes)
	return model_bad_total == 0 && server_bad_total == 0
}

summarize :: proc(sum: ^Summary, c: [][]u8, reply: []u8) {
	name := strings.to_upper(string(c[0]), context.temp_allocator)
	switch name {
	case "STRLEN":
		v, ok := reply_int(reply)
		if !ok {
			return
		}
		if !sum.have_strlen {
			sum.strlen = v
			sum.have_strlen = true
		}
		if sum.adds > 0 {
			if v == hll.HLL_DENSE_SIZE {
				if sum.promoted_at < 0 {
					sum.promoted_at = sum.adds
					sum.promoted_len = v
				}
			} else {
				sum.last_sparse = v
				sum.max_sparse = max(sum.max_sparse, v)
			}
		}
	case "PFADD":
		if len(c) == 3 {
			sum.adds += 1
		}
	case "PFDEBUG":
		if !sum.have_enc && strings.equal_fold(string(c[1]), "ENCODING") {
			sum.encoding = strings.clone(reply_text(reply))
			sum.have_enc = true
		}
	case "PFCOUNT":
		if !sum.have_count && len(c) == 2 {
			if v, ok := reply_int(reply); ok {
				sum.count = v
				sum.have_count = true
			}
		}
	}
}
