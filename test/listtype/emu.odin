package listtype_harness

import "base:runtime"
import "core:time"
import eski "../../src"
import lt "../../src/listtype"

Key_Kind :: enum u8 {
	String,
	List,
}

Key :: struct {
	kind: Key_Kind,
	str:  []u8,
	list: lt.List,
}

Model :: struct {
	db:        map[string]Key,
	resp:      int,
	out:       [dynamic]u8,
	positions: [dynamic]int,
	movebuf:   [dynamic]u8,
}

@(private = "file")
inproc_booted: bool

@(private = "file")
inproc_temp: runtime.Default_Temp_Allocator

@(private = "file")
inproc_conn: ^eski.Conn

inproc_boot :: proc() {
	if inproc_booted {
		return
	}
	eski.mono_init()
	eski.config_table_init()
	eski.config_init()
	eski.commands_init()
	eski.stats_init()
	eski.acl_init()
	eski.db_init()
	eski.block_init()
	eski.mem_init()
	eski.info_init()
	eski.hash_store_init()
	eski.persist_init_commands()
	eski.argv_init()
	eski.config_load_string("enable-debug-command yes\nsave \"\"\nappendonly no\n")
	runtime.default_temp_allocator_init(&inproc_temp, 1 << 20, runtime.heap_allocator())
	inproc_booted = true
}

inproc_open :: proc() {
	inproc_boot()
	c := new(eski.Conn, runtime.heap_allocator())
	c.fd = -1
	c.resp = eski.RESP2
	c.db = &eski.dbs[0]
	eski.acl_conn_init(c)
	inproc_conn = c
}

inproc_settle :: proc(c: ^eski.Conn) {
	for spins := 0; c.blocked == .Lazyfree && spins < 100000; spins += 1 {
		eski.lazyfree_drain()
		if c.blocked == .Lazyfree {
			time.sleep(100 * time.Microsecond)
		}
	}
	if c.blocked != .None && c.blocked != .Lazyfree {
		eski.block_unblock_timeout(c)
	}
}

inproc_call :: proc(argv: [][]u8) -> []u8 {
	context.temp_allocator = runtime.default_temp_allocator(&inproc_temp)
	defer free_all(context.temp_allocator)
	c := inproc_conn
	eski.update_clock()
	c.wlen = 0
	eski.db_cur = c.db
	eski.execute(c, argv)
	inproc_settle(c)
	return c.wbuf[:c.wlen]
}

inproc_command :: proc(args: ..string) -> []u8 {
	argv := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		argv[i] = transmute([]u8)a
	}
	return inproc_call(argv)
}

inproc_clone :: proc(s: []u8) -> []u8 {
	out := make([]u8, len(s))
	copy(out, s)
	return out
}

model_make :: proc() -> Model {
	inproc_open()
	inproc_command("FLUSHALL")
	inproc_command("CONFIG", "SET", "rdbcompression", "no")
	return Model{resp = int(inproc_conn.resp)}
}

model_views_clear :: proc(m: ^Model) {
	for name, k in m.db {
		delete(name)
		delete(k.str)
	}
	clear(&m.db)
}

model_destroy :: proc(m: ^Model) {
	model_views_clear(m)
	delete(m.db)
	delete(m.out)
	delete(m.positions)
	delete(m.movebuf)
	if inproc_conn != nil {
		inproc_command("FLUSHALL")
	}
	m^ = {}
}

lookup :: proc(m: ^Model, key: []u8) -> ^Key {
	model_views_clear(m)
	e := eski.db_find_in(inproc_conn.db, key)
	if e == nil {
		return nil
	}
	k: Key
	switch eski.entry_type(e) {
	case .List:
		k.kind = .List
		k.list = lt.List(eski.entry_object(e, .List))
	case .String:
		k.kind = .String
		k.str = inproc_clone(e.val)
	case .Set, .Zset, .Hash, .Stream:
		k.kind = .String
	}
	name := string(inproc_clone(key))
	m.db[name] = k
	return &m.db[name]
}

lower_name :: proc(s: []u8, allocator := context.temp_allocator) -> string {
	out := make([]u8, len(s), allocator)
	for b, i in s {
		out[i] = b + 32 if b >= 'A' && b <= 'Z' else b
	}
	return string(out)
}

arity_of :: proc(name: string) -> (int, bool) {
	inproc_boot()
	cmd := eski.lookup_command(transmute([]u8)name)
	if cmd == nil {
		return 0, false
	}
	return cmd.arity, true
}

exec :: proc(m: ^Model, args: [][]u8) -> []u8 {
	clear(&m.out)
	if len(args) == 0 {
		return m.out[:]
	}
	append(&m.out, ..inproc_call(args))
	m.resp = int(inproc_conn.resp)
	return m.out[:]
}
