package main

import "core:testing"
import "core:strings"
import "core:sys/linux"

@(test)
aof_retry_refusal_is_reported_once_after_automatic_eligibility :: proc(t: ^testing.T) {
	saved_aof, saved_pst, saved_log := aof, pst, log_fd
	defer { aof = saved_aof; pst = saved_pst; log_fd = saved_log }
	fd, err := linux.memfd_create("eski-aof-retry-test", {})
	testing.expect_value(t, err, linux.Errno.NONE)
	if err != .NONE { return }
	defer linux.close(fd)
	log_fd = fd
	aof = Aof{state = .Enabled, fd = -1, rewrite_start = -1, disable_auto_gc = true}
	pst.child_pid = 0
	pst.progress = nil
	pst.loading = false
	pst.in_child = false
	for _ in 0 ..< 3 { aof_rewrite_done(1, 0) }
	buffer: [8192]u8
	linux.lseek(fd, 0, .SET)
	n, read_err := linux.read(fd, buffer[:])
	testing.expect_value(t, read_err, linux.Errno.NONE)
	testing.expect(t, !strings.contains(string(buffer[:n]), "triggered the limit"))
	linux.lseek(fd, 0, .END)
	aof.auto_pct = 1
	aof.auto_min = 1
	aof.current_size = 4096
	aof.base_size = 1
	for _ in 0 ..< 8 { aof_cron() }
	linux.lseek(fd, 0, .SET)
	n, read_err = linux.read(fd, buffer[:])
	testing.expect_value(t, read_err, linux.Errno.NONE)
	testing.expect_value(t, strings.count(string(buffer[:n]), "triggered the limit"), 1)
	testing.expect_value(t, pst.child_pid, 0)
	testing.expect_value(t, aof.failures, 3)
}
