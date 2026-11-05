package main

import "core:sys/linux"
import "core:sys/posix"

foreign import libc_runtime_fork "system:c"

foreign libc_runtime_fork {
	@(link_name = "fork")
	runtime_libc_fork :: proc "c" () -> linux.Pid ---
}

runtime_fork_last_usec: i64

runtime_fork :: proc() -> (linux.Pid, linux.Errno) {
	keyspace_signal_owed()
	lazyfree_before_fork()
	aof_bio_before_fork()
	blocked, saved: linux.Sig_Set
	blocked[0] = uint(1) << uint(i32(linux.Signal.SIGALRM) - 1)
	if problem := linux.rt_sigprocmask(.SIG_BLOCK, &blocked, &saved); problem != .NONE {
		return -1, problem
	}
	start := now_ns()
	pid := runtime_libc_fork()
	if pid < 0 {
		problem := linux.Errno(posix.errno())
		runtime_fork_last_usec = max((now_ns() - start) / 1000, 0)
		linux.rt_sigprocmask(.SIG_SETMASK, &saved, nil)
		return pid, problem
	}
	if pid == 0 {
		lazyfree_after_fork()
		aof_bio_after_fork()
		diagnostics_after_fork()
	} else {
		runtime_fork_last_usec = max((now_ns() - start) / 1000, 0)
	}
	linux.rt_sigprocmask(.SIG_SETMASK, &saved, nil)
	return pid, .NONE
}
