package aofwork

import "base:runtime"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import j "../../src"

env_ready: bool

env_root: string

env_log_fd: linux.Fd = -1

env_saved_log_fd: linux.Fd = 1

env_init :: proc(t: ^testing.T) {
	if !env_ready {
		env_ready = true
		j.config_init()
		j.db_init()
		j.commands_init()
		j.update_clock()
		env_saved_log_fd = j.log_fd
	}
	if len(env_root) > 0 {
		return
	}
	pid := linux.getpid()
	root := strings.concatenate({"/tmp/eski-aofwork-", int_text(i64(pid))}, runtime.heap_allocator())
	remove_tree(root)
	make_dir(root)
	env_root = root
	testing.cleanup(t, env_release, nil)
	log_path := path_join({root, "server.log"})
	fd, err := linux.open(cstr(log_path), {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR})
	if err == .NONE {
		env_log_fd = fd
		j.log_fd = fd
	}
}

env_release :: proc(_: rawptr) {
	if env_log_fd >= 0 {
		linux.close(env_log_fd)
		env_log_fd = -1
	}
	j.log_fd = env_saved_log_fd
	remove_tree(env_root)
	delete(env_root, runtime.heap_allocator())
	env_root = ""
}

int_text :: proc(v: i64) -> string {
	buf: [24]u8
	n := j.format_i64(&buf[0], v)
	return strings.clone(string(buf[:n]), runtime.heap_allocator())
}

cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

path_join :: proc(parts: []string) -> string {
	return strings.join(parts, "/", runtime.heap_allocator())
}

make_dir :: proc(path: string) {
	linux.mkdir(cstr(path), {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH})
}

fresh_dir :: proc(name: string) -> string {
	assert(len(env_root) > 0)
	dir := path_join({env_root, name})
	remove_tree(dir)
	make_dir(dir)
	return dir
}

remove_tree :: proc(path: string) {
	fd, err := linux.open(cstr(path), {.DIRECTORY, .CLOEXEC})
	if err != .NONE {
		linux.unlink(cstr(path))
		return
	}
	buf: [8192]u8
	names: [dynamic]string
	defer delete(names)
	for {
		n, gerr := linux.getdents(fd, buf[:])
		if gerr != .NONE || n <= 0 {
			break
		}
		off := 0
		for off < n {
			reclen := int(u16(buf[off + 16]) | u16(buf[off + 17]) << 8)
			name_start := off + 19
			name_end := name_start
			for name_end < off + reclen && buf[name_end] != 0 {
				name_end += 1
			}
			name := string(buf[name_start:name_end])
			if name != "." && name != ".." {
				append(&names, strings.clone(name, context.temp_allocator))
			}
			off += reclen
		}
	}
	linux.close(fd)
	for name in names {
		child := path_join({path, name})
		if linux.unlink(cstr(child)) != .NONE {
			remove_tree(child)
		}
	}
	linux.rmdir(cstr(path))
}

read_file :: proc(path: string) -> (data: []u8, ok: bool) {
	fd, err := linux.open(cstr(path), {.CLOEXEC})
	if err != .NONE {
		return nil, false
	}
	defer linux.close(fd)
	out: [dynamic]u8
	out.allocator = runtime.heap_allocator()
	chunk: [65536]u8
	for {
		n, rerr := linux.read(fd, chunk[:])
		if rerr == .EINTR {
			continue
		}
		if rerr != .NONE || n <= 0 {
			break
		}
		append(&out, ..chunk[:n])
	}
	return out[:], true
}

write_file :: proc(path: string, data: []u8) -> bool {
	fd, err := linux.open(cstr(path), {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
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

file_size :: proc(path: string) -> i64 {
	sb: linux.Stat
	if linux.stat(cstr(path), &sb) != .NONE {
		return -1
	}
	return i64(sb.size)
}

file_exists :: proc(path: string) -> bool {
	sb: linux.Stat
	return linux.stat(cstr(path), &sb) == .NONE
}

log_text :: proc() -> string {
	data, ok := read_file(path_join({env_root, "server.log"}))
	if !ok {
		return ""
	}
	return string(data)
}

new_client :: proc(db: int = 0) -> ^j.Conn {
	c := new(j.Conn, runtime.heap_allocator())
	c.fd = -1
	c.id = 1_000_000 + i64(db)
	c.resp = j.RESP2
	c.kind = .Redis
	c.authed = true
	c.ever_authed = true
	c.db = &j.dbs[db]
	return c
}

reply_of :: proc(c: ^j.Conn, from: int) -> string {
	if c.wbuf == nil || from > c.wlen {
		return ""
	}
	return strings.clone(string(c.wbuf[from:c.wlen]), context.temp_allocator)
}

run :: proc(c: ^j.Conn, args: ..string) -> string {
	argv := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		argv[i] = transmute([]u8)strings.clone(a, context.temp_allocator)
	}
	return run_argv(c, argv)
}

run_argv :: proc(c: ^j.Conn, argv: [][]u8) -> string {
	cmd := j.lookup_command(argv[0])
	if cmd == nil {
		return "-ERR unknown command"
	}
	j.db_cur = c.db
	pending := c.wlen
	j.aof_cmd_begin(c, cmd, argv)
	cmd.handler(c, argv)
	j.aof_after_command(c, cmd, j.persist_cmd_flags(cmd), argv, pending)
	out := reply_of(c, pending)
	c.wlen = 0
	c.wpos = 0
	j.pst.dirty_explicit = false
	return out
}

@(test)
env_smoke :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	c := new_client()
	testing.expect_value(t, run(c, "SET", "smoke", "1"), "+OK\r\n")
	testing.expect_value(t, run(c, "GET", "smoke"), "$1\r\n1\r\n")
	testing.expect_value(t, run(c, "DEL", "smoke"), ":1\r\n")
}

main :: proc() {
}
