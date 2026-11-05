package persistence

import "core:os"
import "core:strings"
import "core:sys/linux"
import j "../../src"

test_dir :: proc() -> string {
	@(static) counter: int
	counter += 1
	buf: [64]u8
	pid := i64(linux.getpid())
	name := strings.concatenate({"/tmp/eski-persistence-test-", itoa(buf[:32], pid), "-", itoa(buf[32:], i64(counter))})
	cbuf: [256]u8
	linux.mkdir(cstr_into(name, cbuf[:]), {.IRUSR, .IWUSR, .IXUSR})
	return name
}

cleanup_dir :: proc(dir: string) {
	remove_tree(dir)
	delete(dir)
}

remove_tree :: proc(path: string) {
	handle, err := os.open(path)
	if err == nil {
		list, lerr := os.read_dir(handle, -1, context.temp_allocator)
		os.close(handle)
		if lerr == nil {
			for fi in list {
				child := join_path(path, fi.name)
				if fi.type == .Directory {
					remove_tree(child)
				} else {
					os.remove(child)
				}
			}
		}
	}
	os.remove(path)
}

join_path :: proc(dir: string, name: string) -> string {
	return strings.concatenate({dir, "/", name}, context.temp_allocator)
}

itoa :: proc(buf: []u8, v: i64) -> string {
	n := j.format_i64(raw_data(buf), v)
	return string(buf[:n])
}

cstr_into :: proc(s: string, buf: []u8) -> cstring {
	n := min(len(s), len(buf) - 1)
	copy(buf[:n], s[:n])
	buf[n] = 0
	return cstring(raw_data(buf))
}

cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

file_exists :: proc(path: string) -> bool {
	return os.exists(path)
}

main :: proc() {
}
