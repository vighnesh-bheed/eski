package bits_test

import "core:fmt"
import "core:strings"
import "core:testing"
import bm "../../src/bitmap"

WRONGTYPE :: "WRONGTYPE Operation against a key holding the wrong kind of value"

Emu_Kind :: enum u8 {
	String,
	List,
}

Emu_Value :: struct {
	kind:  Emu_Kind,
	data:  []u8,
	cap:   int,
	items: int,
}

Emu :: struct {
	keys:   map[string]Emu_Value,
	out:    [dynamic]u8,
	prog:   bm.Bitfield_Program,
	srcs:   [dynamic][]u8,
	dirty:  i64,
	events: [dynamic]u8,
}

emu_destroy :: proc(e: ^Emu) {
	emu_flush(e)
	delete(e.keys)
	delete(e.out)
	delete(e.srcs)
	delete(e.events)
	bm.bitfield_program_destroy(&e.prog)
}

emu_changed :: proc(e: ^Emu, event: string) {
	e.dirty += 1
	append(&e.events, event)
	append(&e.events, ";")
}

emu_flush :: proc(e: ^Emu) {
	for k, &v in e.keys {
		bm.free_bytes(&v.data, bm.RAW_HEAP_ALLOCATOR, &v.cap)
		delete(k)
	}
	clear(&e.keys)
}

emu_delete :: proc(e: ^Emu, key: []u8) -> bool {
	k, v, found := emu_entry(e, key)
	if !found {
		return false
	}
	data := v.data
	capacity := v.cap
	bm.free_bytes(&data, bm.RAW_HEAP_ALLOCATOR, &capacity)
	delete_key(&e.keys, k)
	delete(k)
	return true
}

emu_entry :: proc(e: ^Emu, key: []u8) -> (k: string, v: ^Emu_Value, found: bool) {
	for name, &value in e.keys {
		if name == string(key) {
			return name, &value, true
		}
	}
	return "", nil, false
}

emu_lookup :: proc(e: ^Emu, key: []u8) -> ^Emu_Value {
	return &e.keys[string(key)] if string(key) in e.keys else nil
}

emu_create :: proc(e: ^Emu, key: []u8, kind: Emu_Kind) -> ^Emu_Value {
	e.keys[strings.clone(string(key))] = Emu_Value{kind = kind}
	return &e.keys[string(key)]
}

emu_int :: proc(e: ^Emu, v: i64) {
	fmt.sbprintf((^strings.Builder)(&e.out), ":%d\r\n", v)
}

emu_error :: proc(e: ^Emu, msg: string) {
	fmt.sbprintf((^strings.Builder)(&e.out), "-%s\r\n", msg)
}

emu_bitmap_error :: proc(e: ^Emu, err: bm.Error) {
	fmt.sbprintf((^strings.Builder)(&e.out), "-ERR %s\r\n", bm.error_message(err))
}

emu_bulk :: proc(e: ^Emu, s: []u8) {
	fmt.sbprintf((^strings.Builder)(&e.out), "$%d\r\n", len(s))
	append(&e.out, ..s)
	append(&e.out, "\r\n")
}

emu_null :: proc(e: ^Emu) {
	append(&e.out, "$-1\r\n")
}

Arity :: struct {
	name:  string,
	arity: int,
}

ARITIES := [?]Arity {
	{"setbit", 4},
	{"getbit", 3},
	{"bitcount", -2},
	{"bitpos", -3},
	{"bitop", -4},
	{"bitfield", -2},
	{"bitfield_ro", -2},
	{"set", -3},
	{"get", 2},
	{"del", -2},
	{"exists", -2},
	{"strlen", 2},
	{"lpush", -3},
	{"append", 3},
	{"flushall", -1},
}

emu_string_arg :: proc(e: ^Emu, key: []u8) -> (v: ^Emu_Value, wrong: bool) {
	v = emu_lookup(e, key)
	if v != nil && v.kind != .String {
		return v, true
	}
	return v, false
}

emu_run :: proc(e: ^Emu, argv: [][]u8) {
	name := strings.to_lower(string(argv[0]), context.temp_allocator)
	arity := 0
	for a in ARITIES {
		if a.name == name {
			arity = a.arity
		}
	}
	if (arity > 0 && len(argv) != arity) || (arity < 0 && len(argv) < -arity) || arity == 0 {
		emu_error(e, fmt.tprintf("ERR wrong number of arguments for '%s' command", name))
		return
	}
	switch name {
	case "flushall":
		emu_flush(e)
		append(&e.out, "+OK\r\n")
	case "set":
		emu_delete(e, argv[1])
		v := emu_create(e, argv[1], .String)
		bm.grow_zero(&v.data, len(argv[2]), bm.RAW_HEAP_ALLOCATOR, nil)
		v.cap = len(v.data)
		copy(v.data, argv[2])
		emu_changed(e, "set")
		append(&e.out, "+OK\r\n")
	case "get":
		v, wrong := emu_string_arg(e, argv[1])
		switch {
		case wrong:
			emu_error(e, WRONGTYPE)
		case v == nil:
			emu_null(e)
		case:
			emu_bulk(e, v.data)
		}
	case "del", "exists":
		n := 0
		for key in argv[1:] {
			if name == "del" {
				n += int(emu_delete(e, key))
			} else {
				n += int(emu_lookup(e, key) != nil)
			}
		}
		emu_int(e, i64(n))
	case "strlen":
		v, wrong := emu_string_arg(e, argv[1])
		switch {
		case wrong:
			emu_error(e, WRONGTYPE)
		case v == nil:
			emu_int(e, 0)
		case:
			emu_int(e, i64(len(v.data)))
		}
	case "lpush":
		v := emu_lookup(e, argv[1])
		if v != nil && v.kind != .List {
			emu_error(e, WRONGTYPE)
			return
		}
		if v == nil {
			v = emu_create(e, argv[1], .List)
		}
		v.items += len(argv) - 2
		emu_int(e, i64(v.items))
	case "append":
		v, wrong := emu_string_arg(e, argv[1])
		if wrong {
			emu_error(e, WRONGTYPE)
			return
		}
		if v == nil {
			v = emu_create(e, argv[1], .String)
		}
		at := len(v.data)
		bm.grow_zero(&v.data, at + len(argv[2]), bm.RAW_HEAP_ALLOCATOR, &v.cap)
		copy(v.data[at:], argv[2])
		emu_int(e, i64(len(v.data)))
	case "setbit":
		emu_setbit(e, argv)
	case "getbit":
		offset, err := bm.parse_bit_offset(argv[2])
		if err != .None {
			emu_bitmap_error(e, err)
			return
		}
		v, wrong := emu_string_arg(e, argv[1])
		switch {
		case wrong:
			emu_error(e, WRONGTYPE)
		case v == nil:
			emu_int(e, 0)
		case:
			emu_int(e, i64(bm.getbit(v.data, i64(offset))))
		}
	case "bitcount":
		args, err := bm.parse_bitcount_args(argv[2:])
		if err != .None {
			emu_bitmap_error(e, err)
			return
		}
		v, wrong := emu_string_arg(e, argv[1])
		switch {
		case wrong:
			emu_error(e, WRONGTYPE)
		case v == nil:
			emu_int(e, 0)
		case:
			emu_int(e, bm.bitcount_args(v.data, args))
		}
	case "bitpos":
		args, err := bm.parse_bitpos_args(argv[2:])
		if err != .None {
			emu_bitmap_error(e, err)
			return
		}
		v, wrong := emu_string_arg(e, argv[1])
		switch {
		case wrong:
			emu_error(e, WRONGTYPE)
		case v == nil:
			emu_int(e, bm.bitpos_args(nil, false, args))
		case:
			emu_int(e, bm.bitpos_args(v.data, true, args))
		}
	case "bitop":
		emu_bitop(e, argv)
	case "bitfield":
		emu_bitfield(e, argv, false)
	case "bitfield_ro":
		emu_bitfield(e, argv, true)
	}
}

emu_setbit :: proc(e: ^Emu, argv: [][]u8) {
	offset, err := bm.parse_bit_offset(argv[2])
	if err != .None {
		emu_bitmap_error(e, err)
		return
	}
	on: bool
	on, err = bm.parse_bit_value(argv[3])
	if err != .None {
		emu_bitmap_error(e, err)
		return
	}
	v, wrong := emu_string_arg(e, argv[1])
	if wrong {
		emu_error(e, WRONGTYPE)
		return
	}
	created := v == nil
	if created {
		v = emu_create(e, argv[1], .String)
	}
	before := len(v.data)
	old: bool
	old, err = bm.setbit(&v.data, i64(offset), on, bm.RAW_HEAP_ALLOCATOR, &v.cap)
	if err != .None {
		emu_bitmap_error(e, err)
		return
	}
	if created || len(v.data) > before || old != on {
		emu_changed(e, "setbit")
	}
	emu_int(e, i64(old))
}

emu_bitop :: proc(e: ^Emu, argv: [][]u8) {
	op, err := bm.parse_bitop(argv[1])
	if err != .None {
		emu_bitmap_error(e, err)
		return
	}
	err = bm.check_bitop_arity(op, len(argv) - 3)
	if err != .None {
		emu_bitmap_error(e, err)
		return
	}
	clear(&e.srcs)
	for key in argv[3:] {
		v, wrong := emu_string_arg(e, key)
		if wrong {
			emu_error(e, WRONGTYPE)
			return
		}
		append(&e.srcs, v.data if v != nil else nil)
	}
	out: []u8
	n: int
	n, err = bm.bitop(op, e.srcs[:], &out)
	if err != .None {
		emu_bitmap_error(e, err)
		return
	}
	deleted := emu_delete(e, argv[2])
	if n > 0 {
		v := emu_create(e, argv[2], .String)
		v.data = out
		v.cap = n
		emu_changed(e, "set")
	} else if deleted {
		emu_changed(e, "del")
	}
	emu_int(e, i64(n))
}

emu_bitfield :: proc(e: ^Emu, argv: [][]u8, read_only: bool) {
	err := bm.bitfield_parse(&e.prog, argv[2:], read_only)
	if err != .None {
		emu_bitmap_error(e, err)
		return
	}
	v, wrong := emu_string_arg(e, argv[1])
	if wrong {
		emu_error(e, WRONGTYPE)
		return
	}
	if e.prog.readonly {
		view: []u8
		if v != nil {
			view = v.data
		}
		_, err = bm.bitfield_execute(&view, &e.prog)
	} else {
		if v == nil {
			v = emu_create(e, argv[1], .String)
		}
		changes: int
		changes, err = bm.bitfield_execute(&v.data, &e.prog, bm.RAW_HEAP_ALLOCATOR, &v.cap)
		if err == .None && changes > 0 {
			emu_changed(e, "setbit")
		}
	}
	if err != .None {
		emu_bitmap_error(e, err)
		return
	}
	fmt.sbprintf((^strings.Builder)(&e.out), "*%d\r\n", len(e.prog.replies))
	for r in e.prog.replies {
		if r.null {
			emu_null(e)
		} else {
			emu_int(e, r.value)
		}
	}
}

Change_Check :: struct {
	words:  []string,
	reply:  string,
	delta:  i64,
	events: string,
}

@(test)
change_only_rule_matches_reference_observations :: proc(t: ^testing.T) {
	emu: Emu
	defer emu_destroy(&emu)
	checks := []Change_Check {
		{{"setbit", "sb", "3", "1"}, ":0\r\n", 1, "setbit;"},
		{{"setbit", "sb", "3", "1"}, ":1\r\n", 0, ""},
		{{"setbit", "sb", "3", "0"}, ":1\r\n", 1, "setbit;"},
		{{"setbit", "sb", "100", "0"}, ":0\r\n", 1, "setbit;"},
		{{"setbit", "sb", "100", "0"}, ":0\r\n", 0, ""},
		{{"strlen", "sb"}, ":13\r\n", 0, ""},
		{{"setbit", "sb0", "5", "0"}, ":0\r\n", 1, "setbit;"},
		{{"strlen", "sb0"}, ":1\r\n", 0, ""},
		{{"bitfield", "bfr", "GET", "u8", "0"}, "*1\r\n:0\r\n", 0, ""},
		{{"exists", "bfr"}, ":0\r\n", 0, ""},
		{{"bitfield", "bf", "SET", "u8", "0", "5"}, "*1\r\n:0\r\n", 1, "setbit;"},
		{{"bitfield", "bf", "SET", "u8", "0", "5"}, "*1\r\n:5\r\n", 0, ""},
		{{"bitfield", "bf", "OVERFLOW", "FAIL", "INCRBY", "u8", "0", "251"}, "*1\r\n$-1\r\n", 0, ""},
		{{"bitfield", "bf3", "OVERFLOW", "FAIL", "SET", "u8", "100", "300"}, "*1\r\n$-1\r\n", 0, ""},
		{{"strlen", "bf3"}, ":14\r\n", 0, ""},
		{{"bitfield", "bf2", "OVERFLOW", "FAIL", "INCRBY", "u8", "0", "255"}, "*1\r\n:255\r\n", 1, "setbit;"},
		{{"bitfield", "bf", "SET", "u8", "0", "6", "SET", "u8", "0", "6"}, "*2\r\n:5\r\n:6\r\n", 1, "setbit;"},
		{{"bitfield_ro", "bf", "GET", "u8", "0"}, "*1\r\n:6\r\n", 0, ""},
		{{"bitop", "and", "d", "sb", "bf"}, ":13\r\n", 1, "set;"},
		{{"bitop", "and", "d", "nokey1", "nokey2"}, ":0\r\n", 1, "del;"},
		{{"bitop", "and", "d", "nokey1"}, ":0\r\n", 0, ""},
		{{"bitcount", "bf"}, ":2\r\n", 0, ""},
		{{"bitpos", "bf", "1"}, ":5\r\n", 0, ""},
		{{"getbit", "bf", "5"}, ":1\r\n", 0, ""},
		{{"setbit", "bf", "x", "1"}, "-ERR bit offset is not an integer or out of range\r\n", 0, ""},
		{{"bitfield", "bf", "INCRBY", "u8", "0", "256"}, "*1\r\n:6\r\n", 0, ""},
		{{"bitfield", "bf", "INCRBY", "u8", "0", "0"}, "*1\r\n:6\r\n", 0, ""},
		{{"bitfield", "bf", "OVERFLOW", "SAT", "INCRBY", "u8", "0", "1000"}, "*1\r\n:255\r\n", 1, "setbit;"},
		{{"bitfield", "bf", "OVERFLOW", "SAT", "INCRBY", "u8", "0", "1000"}, "*1\r\n:255\r\n", 0, ""},
		{{"setbit", "foo", "0", "0"}, ":0\r\n", 1, "setbit;"},
		{{"setbit", "foo", "0", "0"}, ":0\r\n", 0, ""},
		{{"bitfield", "foo2", "SET", "i5", "0", "0"}, "*1\r\n:0\r\n", 1, "setbit;"},
		{{"bitfield", "foo2", "SET", "i5", "0", "0"}, "*1\r\n:0\r\n", 0, ""},
		{{"bitfield", "foo2", "SET", "i5", "0", "1"}, "*1\r\n:0\r\n", 1, "setbit;"},
		{{"bitfield", "foo2", "SET", "i5", "0", "1"}, "*1\r\n:1\r\n", 0, ""},
		{{"bitfield", "foo2", "INCRBY", "i5", "0", "32"}, "*1\r\n:1\r\n", 0, ""},
		{{"bitfield", "foo2", "INCRBY", "i5", "0", "0"}, "*1\r\n:1\r\n", 0, ""},
		{{"bitfield", "foo2", "OVERFLOW", "FAIL", "INCRBY", "i5", "0", "100"}, "*1\r\n$-1\r\n", 0, ""},
		{{"setbit", "foo", "90", "0"}, ":0\r\n", 1, "setbit;"},
		{{"bitfield", "foo2", "SET", "i5", "90", "0"}, "*1\r\n:0\r\n", 1, "setbit;"},
		{{"bitfield", "foo2", "SET", "i5", "90", "0"}, "*1\r\n:0\r\n", 0, ""},
		{{"strlen", "foo2"}, ":12\r\n", 0, ""},
	}
	argv := make([dynamic][]u8)
	defer delete(argv)
	for c in checks {
		clear(&argv)
		for w in c.words {
			append(&argv, transmute([]u8)w)
		}
		clear(&emu.out)
		clear(&emu.events)
		before := emu.dirty
		emu_run(&emu, argv[:])
		reply := string(emu.out[:])
		events := string(emu.events[:])
		if reply != c.reply || emu.dirty - before != c.delta || events != c.events {
			testing.expectf(t, false, "%v: reply %q delta %d events %q, want %q %d %q", c.words, reply, emu.dirty - before, events, c.reply, c.delta, c.events)
		}
		free_all(context.temp_allocator)
	}
}
