package main

import "base:runtime"
import "core:sys/linux"

foreign import libc_operations "system:c"

foreign libc_operations {
	@(link_name = "openlog")
	runtime_openlog :: proc "c" (ident: cstring, options, facility: i32) ---
	@(link_name = "syslog")
	runtime_syslog :: proc "c" (priority: i32, format: cstring, #c_vararg args: ..any) ---
	@(link_name = "closelog")
	runtime_closelog :: proc "c" () ---
	@(link_name = "getenv")
	runtime_getenv :: proc "c" (name: cstring) -> cstring ---
}

runtime_syslog_ident: []u8
runtime_syslog_open: bool
runtime_supervised_mode: u8
runtime_notify_address: linux.Sock_Addr_Un
runtime_notify_length: int
runtime_supervised_started: bool

runtime_supervised_requested :: proc() -> bool {
	runtime_supervised_mode = 0
	mode := cfg.supervised
	upstart := runtime_getenv("UPSTART_JOB")
	notify := runtime_getenv("NOTIFY_SOCKET")
	if mode == 3 {
		mode = 1 if upstart != nil && len(upstart) > 0 else 2
	}
	if mode == 1 && upstart != nil && len(upstart) > 0 {
		runtime_supervised_mode = 1
	} else if mode == 2 && notify != nil {
		name := string(notify)
		fits := len(name) < len(runtime_notify_address.sun_path) || (len(name) == len(runtime_notify_address.sun_path) && name[0] == '@')
		if len(name) > 1 && fits && (name[0] == '/' || name[0] == '@') {
			runtime_notify_address = {}
			runtime_notify_address.sun_family = .UNIX
			copy(runtime_notify_address.sun_path[:], name)
			if name[0] == '@' { runtime_notify_address.sun_path[0] = 0 }
			runtime_notify_length = 2 + len(name)
			if name[0] == '/' { runtime_notify_length += 1 }
			runtime_supervised_mode = 2
		}
	}
	return runtime_supervised_mode != 0
}

runtime_operations_init :: proc() {
	if cfg.syslog_enabled {
		runtime_syslog_ident = make([]u8, len(cfg.syslog_ident) + 1, runtime.heap_allocator())
		copy(runtime_syslog_ident, cfg.syslog_ident)
		runtime_openlog(cstring(raw_data(runtime_syslog_ident)), 1 | 8, i32(cfg.syslog_facility))
		runtime_syslog_open = true
	}
	if cfg.disable_thp {
		if problem := linux.prctl(41, 1, 0, 0, 0); problem != .NONE {
			plog(LOG_WARNING, "Unable to disable transparent huge pages for this process: ", errno_text(problem))
		}
	}
	if cfg.supervised != 0 && runtime_supervised_mode == 0 {
		plog(LOG_WARNING, "Supervision requested without a valid supervisor environment; continuing unsupervised")
	}
}

runtime_log_syslog :: proc "contextless" (level: u8, message: []u8) {
	if !runtime_syslog_open { return }
	priority: i32 = 5
	switch level {
	case LOG_DEBUG: priority = 7
	case LOG_VERBOSE: priority = 6
	case LOG_WARNING: priority = 4
	}
	runtime_syslog(priority, "%.*s", i32(len(message)), raw_data(message))
}

runtime_operations_shutdown :: proc() {
	lazyfree_before_fork()
	aof_bio_before_fork()
	if runtime_syslog_open {
		runtime_syslog_open = false
		runtime_closelog()
	}
	if runtime_syslog_ident != nil {
		delete(runtime_syslog_ident, runtime.heap_allocator())
		runtime_syslog_ident = nil
	}
}

runtime_supervised_name :: proc "contextless" () -> string {
	switch runtime_supervised_mode {
	case 1: return "upstart"
	case 2: return "systemd"
	}
	return "no"
}

runtime_notify :: proc(message: string) -> bool {
	fd, problem := linux.socket(.UNIX, .DGRAM, {.CLOEXEC, .NONBLOCK}, .HOPOPT)
	if problem != .NONE { return false }
	defer linux.close(fd)
	result := linux.syscall(linux.SYS_sendto, fd, raw_data(message), len(message), 0, &runtime_notify_address, runtime_notify_length)
	return result == len(message)
}

runtime_supervised_ready :: proc() {
	if runtime_supervised_mode == 1 {
		linux.kill(linux.getpid(), .SIGSTOP)
		runtime_supervised_started = true
	} else if runtime_supervised_mode == 2 {
		runtime_supervised_started = runtime_notify("READY=1\nSTATUS=Ready to accept connections")
		if !runtime_supervised_started { plog(LOG_WARNING, "Unable to notify supervisor of readiness") }
	}
}

runtime_supervised_stopping :: proc() {
	if runtime_supervised_mode == 2 && runtime_supervised_started {
		runtime_notify("STOPPING=1\nSTATUS=Shutting down")
		runtime_supervised_started = false
	}
}

runtime_logo :: proc() {
	if cfg.always_show_logo {
		plog(LOG_NOTICE, "\n  EEEEE  SSSS  K  K  III\n  E     S      K K    I\n  EEEE   SSS   KK     I\n  E         S  K K    I\n  EEEEE SSSS   K  K  III\n  Eski ", VERSION)
	}
}

runtime_socket_mark :: proc(fd: linux.Fd) -> linux.Errno {
	if cfg.socket_mark_id == 0 { return .NONE }
	mark := u32(cfg.socket_mark_id)
	problem := linux.setsockopt(fd, linux.SOL_SOCKET, linux.Socket_Option.MARK, &mark)
	if problem != .NONE { plog(LOG_WARNING, "Unable to set socket mark: ", errno_text(problem)) }
	return problem
}
