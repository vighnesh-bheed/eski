package main

import "core:sys/linux"
import "core:testing"

@(test)
runtime_socket_mark_has_native_effect_or_permission_error :: proc(t: ^testing.T) {
	previous := cfg.socket_mark_id
	defer cfg.socket_mark_id = previous
	fd, problem := linux.socket(.INET, .STREAM, {.CLOEXEC}, .TCP)
	if !testing.expect_value(t, problem, linux.Errno.NONE) { return }
	defer linux.close(fd)
	cfg.socket_mark_id = 0
	testing.expect_value(t, runtime_socket_mark(fd), linux.Errno.NONE)
	cfg.socket_mark_id = 0x45734b69
	problem = runtime_socket_mark(fd)
	if problem == .EPERM || problem == .EACCES { return }
	if !testing.expect_value(t, problem, linux.Errno.NONE) { return }
	mark: u32
	_, problem = linux.getsockopt(fd, int(linux.SOL_SOCKET), linux.Socket_Option.MARK, &mark)
	testing.expect_value(t, problem, linux.Errno.NONE)
	testing.expect_value(t, mark, u32(0x45734b69))
}
