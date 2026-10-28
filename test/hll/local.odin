package hll_harness

import "base:runtime"
import "core:time"
import eski "../../src"

Local :: struct {
	keys:       map[string][]u8,
	sparse_max: int,
	seed:       u64,
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

local_make :: proc() -> Local {
	inproc_open()
	inproc_command("FLUSHALL")
	return Local{sparse_max = eski.hll_sparse_max_bytes}
}

local_forget_all :: proc(l: ^Local) {
	for name, v in l.keys {
		delete(name)
		delete(v)
	}
	clear(&l.keys)
}

local_destroy :: proc(l: ^Local) {
	local_forget_all(l)
	delete(l.keys)
	if inproc_conn != nil {
		inproc_command("FLUSHALL")
	}
	l^ = {}
}

local_refresh :: proc(l: ^Local, key: []u8) -> (value: []u8, found: bool) {
	e := eski.db_find_in(inproc_conn.db, key)
	if e == nil {
		if string(key) in l.keys {
			name, old := delete_key(&l.keys, string(key))
			delete(name)
			delete(old)
		}
		return nil, false
	}
	fresh: []u8
	if eski.entry_type(e) == .String {
		fresh = make([]u8, len(e.val))
		copy(fresh, e.val)
	}
	if string(key) in l.keys {
		delete(l.keys[string(key)])
		l.keys[string(key)] = fresh
	} else {
		name := make([]u8, len(key))
		copy(name, key)
		l.keys[string(name)] = fresh
	}
	return fresh, true
}

local_resync :: proc(l: ^Local) {
	local_forget_all(l)
	reply := inproc_command("KEYS", "*")
	head, at := local_line(reply, 0)
	if len(head) < 2 || head[0] != '*' {
		return
	}
	for at < len(reply) && reply[at] == '$' {
		size_line, body := local_line(reply, at)
		n := 0
		for d in size_line[1:] {
			n = n * 10 + int(d - '0')
		}
		if body + n > len(reply) {
			break
		}
		local_refresh(l, reply[body:body + n])
		at = body + n + 2
	}
}

local_line :: proc(b: []u8, from: int) -> (line: []u8, next: int) {
	i := from
	for i + 1 < len(b) {
		if b[i] == '\r' && b[i + 1] == '\n' {
			return b[from:i], i + 2
		}
		i += 1
	}
	return b[from:], len(b)
}

local_name_is :: proc(a: []u8, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for c, i in a {
		l := c + 32 if c >= 'A' && c <= 'Z' else c
		if l != b[i] {
			return false
		}
	}
	return true
}

lookup :: proc(l: ^Local, key: []u8) -> ([]u8, bool) {
	return local_refresh(l, key)
}

exec :: proc(l: ^Local, argv: [][]u8, out: ^[dynamic]u8) {
	if len(argv) == 0 {
		return
	}
	append(out, ..inproc_call(argv))
	l.sparse_max = eski.hll_sparse_max_bytes
	whole := false
	for name in ([?]string{"flushall", "flushdb", "select", "swapdb"}) {
		whole ||= local_name_is(argv[0], name)
	}
	if whole {
		local_resync(l)
		return
	}
	for a in argv[1:] {
		local_refresh(l, a)
	}
}
