package bitmap_harness

import "base:runtime"
import "core:time"
import eski "../../src"

Emu :: struct {
	out: [dynamic]u8,
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

emu_make :: proc() -> Emu {
	inproc_open()
	inproc_command("FLUSHALL")
	return {}
}

emu_destroy :: proc(e: ^Emu) {
	if inproc_conn != nil {
		inproc_command("FLUSHALL")
	}
	delete(e.out)
	e^ = {}
}

emu_exec :: proc(e: ^Emu, argv: [][]u8) -> []u8 {
	clear(&e.out)
	if len(argv) == 0 {
		return e.out[:]
	}
	append(&e.out, ..inproc_call(argv))
	return e.out[:]
}
