package persistence

import "base:runtime"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import j "../../src"
import "../../src/rdb"

server_ready :: proc() {
	context.allocator = runtime.heap_allocator()
	@(static) done: bool
	if !done {
		done = true
		j.mono_init()
		j.config_init()
		j.db_init()
		j.commands_init()
		j.hash_store_init()
		j.stats_init()
		j.block_init()
		j.info_init()
		j.persist_init_commands()
	}
	j.update_clock()
	j.cfg.enable_debug_command = 1
}

server_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	server_ready()
	j.db_flush_all()
	clear(&j.pst.save_params)
	j.pst.dirty = 0
	j.pst.dirty_explicit = false
	j.pst.lastbgsave_err = false
	j.pst.loading = false
	j.pst.compression = true
	j.pst.checksum = true
	j.pst.stop_writes = true
	j.pst.sanitize = .No
	j.pst.skip_checksum = false
	j.pst.key_save_delay = 0
	j.pst.bgsave_scheduled = false
	j.maxmemory_policy = .Noeviction
	j.evict_policy_changed()
	j.persist_update_gate()
	c := test_conn()
	c.db = &j.dbs[0]
	c.wlen = 0
	c.wpos = 0
}

test_conn :: proc() -> ^j.Conn {
	context.allocator = runtime.heap_allocator()
	@(static) c: ^j.Conn
	if c == nil {
		c = j.aof_fake_conn()
	}
	return c
}

cmd :: proc(args: ..string) -> string {
	argv := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		argv[i] = transmute([]u8)a
	}
	return cmdv(argv)
}

cmdv :: proc(argv: [][]u8) -> string {
	result_allocator := context.temp_allocator
	context.allocator = runtime.heap_allocator()
	c := test_conn()
	c.wlen = 0
	c.wpos = 0
	j.update_clock()
	j.execute(c, argv)
	return strings.clone(string(c.wbuf[:c.wlen]), result_allocator)
}

expect_reply :: proc(t: ^testing.T, got: string, want: string, label: string, loc := #caller_location) {
	testing.expectf(t, got == want, "%s: got %q want %q", label, got, want, loc = loc)
}

unix_ms :: proc() -> i64 {
	ts, _ := linux.clock_gettime(.REALTIME)
	return i64(ts.time_sec) * 1000 + i64(ts.time_nsec) / 1_000_000
}

bulk :: proc(s: string) -> string {
	buf: [24]u8
	return strings.concatenate({"$", itoa(buf[:], i64(len(s))), "\r\n", s, "\r\n"}, context.temp_allocator)
}

integer :: proc(v: i64) -> string {
	buf: [24]u8
	return strings.concatenate({":", itoa(buf[:], v), "\r\n"}, context.temp_allocator)
}

enter_dir :: proc(dir: string) {
	linux.chdir(cstr(dir))
}

leave_dir :: proc() {
	linux.chdir("/tmp")
}

write_file :: proc(path: string, data: []u8) -> bool {
	fd, err := linux.open(cstr(path), {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
	if err != .NONE {
		return false
	}
	defer linux.close(fd)
	rest := data
	for len(rest) > 0 {
		n, werr := linux.write(fd, rest)
		if werr != .NONE || n <= 0 {
			return false
		}
		rest = rest[n:]
	}
	return true
}

load_image :: proc(data: []u8, merge: bool = false) -> j.Load_Result {
	context.allocator = runtime.heap_allocator()
	r: rdb.Reader
	rdb.reader_init_mem(&r, data, true)
	defer rdb.reader_destroy(&r)
	return j.persist_load_stream(&r, merge)
}

run_in_child :: proc(body: proc()) -> (exited: bool, code: int) {
	pid, err := linux.fork()
	if err != .NONE {
		return false, -1
	}
	if pid == 0 {
		devnull, derr := linux.open("/dev/null", {.WRONLY})
		if derr == .NONE {
			j.log_fd = devnull
		}
		body()
		linux.exit_group(77)
	}
	status: u32
	for {
		_, werr := linux.wait4(pid, &status, {}, nil)
		if werr != .EINTR {
			break
		}
	}
	if status & 0x7f != 0 {
		return false, int(status & 0x7f)
	}
	return true, int((status >> 8) & 0xff)
}
