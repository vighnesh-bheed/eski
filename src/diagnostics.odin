package main

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:sys/linux"
import "sysclock"

when .Address in ODIN_SANITIZER_FLAGS {
	foreign import diagnostic_native { "../.build/diagnostics/address/libeski-diagnostics.a", "../.build/diagnostics/libunwind.so", "system:dl" }
} else when .Thread in ODIN_SANITIZER_FLAGS {
	foreign import diagnostic_native { "../.build/diagnostics/thread/libeski-diagnostics.a", "../.build/diagnostics/libunwind.so", "system:dl" }
} else {
	foreign import diagnostic_native { "../.build/diagnostics/release/libeski-diagnostics.a", "../.build/diagnostics/libunwind.so", "system:dl" }
}

foreign diagnostic_native {
	eski_diag_symbols_init :: proc() -> i32 ---
	eski_diag_runtime_init :: proc() -> i32 ---
	eski_diag_symbol :: proc(pc: uintptr, name: ^cstring, length: ^c.size_t, offset: ^uintptr) -> i32 ---
	eski_diag_capture :: proc(opaque: rawptr, frames: ^uintptr, capacity: i32) -> i32 ---
	eski_diag_capture_current :: proc(frames: ^uintptr, capacity: i32) -> i32 ---
	eski_diag_is_timer :: proc(info: rawptr) -> i32 ---
	eski_diag_install :: proc(handler: proc "c" (signal: i32, info, opaque: rawptr), fatal: i32) -> i32 ---
	eski_diag_default :: proc(signal: i32) -> ! ---
	eski_diag_timer_create :: proc(tid: i32, timer: ^i32) -> i32 ---
	eski_diag_timer_arm :: proc(timer: i32, milliseconds: u64) -> i32 ---
	eski_diag_timer_delete :: proc(timer: i32) ---
	eski_diag_mask_alarm :: proc(block: i32) ---
	eski_diag_thread_enter :: proc() -> i32 ---
	eski_diag_thread_leave :: proc() ---
	eski_diag_scratch_check :: proc() -> i32 ---
	eski_diag_memory :: proc() -> c.size_t ---
	eski_diag_shutdown :: proc() ---
	eski_diag_log_open :: proc(fd: i32) -> i32 ---
	eski_diag_segfault :: proc() -> ! ---
	eski_diag_abort :: proc() -> ! ---
}

DIAGNOSTIC_LOG :: u32(1)
DIAGNOSTIC_MEMORY :: u32(2)
DIAGNOSTIC_EXIT :: u32(4)
DIAGNOSTIC_HIDE :: u32(8)

diagnostic_initialized: i32
diagnostic_main_tid: i32
diagnostic_report_guard: i32
diagnostic_assert_tid: i32
diagnostic_flags: u32
diagnostic_period: u64
diagnostic_working: i32
diagnostic_deadline: i64
diagnostic_timer: i32 = -1
diagnostic_fd: i32 = -1
diagnostic_sequence: u64
diagnostic_command_size: i32
diagnostic_command_bytes: [48]u8
diagnostic_argument_count: i64
diagnostic_argument_lengths: [16]i64

diagnostics_line_end :: proc "contextless" (line: ^Log_Line) {
	line.buf[line.n] = '\n'
	line.n += 1
	remaining := line.buf[:line.n]
	for len(remaining) > 0 {
		n, err := linux.write(linux.Fd(diagnostic_fd), remaining)
		if err == .EINTR { continue }
		if err != .NONE || n <= 0 { return }
		remaining = remaining[n:]
	}
}

diagnostics_hex :: proc "contextless" (line: ^Log_Line, value: uintptr) {
	alphabet := "0123456789abcdef"
	buffer: [2 * size_of(uintptr)]u8
	for index in 0 ..< len(buffer) { buffer[len(buffer) - 1 - index] = alphabet[(value >> uint(index * 4)) & 15] }
	ll_str(line, "0x")
	ll_bytes(line, buffer[:])
}

diagnostics_capture_command :: proc(name: string, arguments: [][]u8) {
	if intrinsics.atomic_load_explicit(&diagnostic_initialized, .Acquire) == 0 { return }
	sequence := intrinsics.atomic_load_explicit(&diagnostic_sequence, .Relaxed)
	intrinsics.atomic_store_explicit(&diagnostic_sequence, sequence + 1, .Relaxed)
	intrinsics.atomic_thread_fence(.Release)
	n := min(len(name), len(diagnostic_command_bytes))
	for index in 0 ..< n {
		value := name[index]
		if value < 32 || value > 126 { value = '?' }
		intrinsics.atomic_store_explicit(&diagnostic_command_bytes[index], value, .Relaxed)
	}
	intrinsics.atomic_store_explicit(&diagnostic_command_size, i32(n), .Relaxed)
	intrinsics.atomic_store_explicit(&diagnostic_argument_count, i64(len(arguments)), .Relaxed)
	for index in 0 ..< min(len(arguments), len(diagnostic_argument_lengths)) {
		intrinsics.atomic_store_explicit(&diagnostic_argument_lengths[index], i64(len(arguments[index])), .Relaxed)
	}
	intrinsics.atomic_store_explicit(&diagnostic_sequence, sequence + 2, .Release)
}

diagnostics_command_line :: proc "contextless" (flags: u32) {
	sequence := intrinsics.atomic_load_explicit(&diagnostic_sequence, .Acquire)
	if sequence & 1 != 0 { return }
	name: [48]u8
	n := clamp(int(intrinsics.atomic_load_explicit(&diagnostic_command_size, .Relaxed)), 0, len(name))
	for index in 0 ..< n { name[index] = intrinsics.atomic_load_explicit(&diagnostic_command_bytes[index], .Relaxed) }
	count := intrinsics.atomic_load_explicit(&diagnostic_argument_count, .Relaxed)
	lengths: [16]i64
	for index in 0 ..< min(max(int(count), 0), len(lengths)) { lengths[index] = intrinsics.atomic_load_explicit(&diagnostic_argument_lengths[index], .Relaxed) }
	intrinsics.atomic_thread_fence(.Acquire)
	if sequence != intrinsics.atomic_load_explicit(&diagnostic_sequence, .Relaxed) { return }
	line: Log_Line
	ll_str(&line, "Coordinator command: argv[0]=")
	ll_bytes(&line, name[:n])
	ll_str(&line, " argc="); ll_int(&line, count)
	for index in 1 ..< min(max(int(count), 0), len(lengths)) {
		ll_str(&line, " argv["); ll_int(&line, i64(index)); ll_str(&line, "]=")
		if flags & DIAGNOSTIC_HIDE != 0 { ll_str(&line, "<redacted>") } else {
			ll_str(&line, "<"); ll_int(&line, lengths[index]); ll_str(&line, " bytes>")
		}
	}
	diagnostics_line_end(&line)
}

diagnostics_report :: proc "contextless" (signal: i32, opaque: rawptr, title: string) {
	flags := intrinsics.atomic_load_explicit(&diagnostic_flags, .Acquire)
	if flags & DIAGNOSTIC_LOG == 0 || diagnostic_fd < 0 { return }
	if intrinsics.atomic_exchange_explicit(&diagnostic_report_guard, 1, .Acquire) != 0 { return }
	defer intrinsics.atomic_store_explicit(&diagnostic_report_guard, 0, .Release)
	line: Log_Line
	ll_str(&line, "ESKI "); ll_str(&line, title)
	ll_str(&line, " signal="); ll_int(&line, i64(signal))
	ll_str(&line, " pid="); ll_int(&line, i64(linux.getpid()))
	ll_str(&line, " tid="); ll_int(&line, i64(linux.gettid()))
	diagnostics_line_end(&line)
	diagnostics_command_line(flags)
	line = {}; ll_str(&line, "STACK TRACE - native Eski frames"); diagnostics_line_end(&line)
	frames: [64]uintptr
	count := eski_diag_capture(opaque, &frames[0], i32(len(frames))) if opaque != nil else eski_diag_capture_current(&frames[0], i32(len(frames)))
	for index in 0 ..< clamp(int(count), 0, len(frames)) {
		line = {}; ll_str(&line, "#"); ll_int(&line, i64(index)); ll_str(&line, " ")
		diagnostics_hex(&line, frames[index])
		name: cstring; length: c.size_t; offset: uintptr
		if eski_diag_symbol(frames[index], &name, &length, &offset) != 0 {
			ll_str(&line, " "); ll_bytes(&line, ([^]u8)(name)[:min(int(length), 192)])
			ll_str(&line, "+"); diagnostics_hex(&line, offset)
		} else { ll_str(&line, " <native symbol unavailable>") }
		diagnostics_line_end(&line)
	}
	if flags & DIAGNOSTIC_MEMORY != 0 && signal != i32(linux.Signal.SIGALRM) {
		line = {}; ll_str(&line, "Diagnostic scratch check: ")
		result := eski_diag_scratch_check()
		if result == 1 { ll_str(&line, "16384 owned read-only bytes match expected pattern; dataset and heap not scanned") }
		else if result == 0 { ll_str(&line, "owned scratch pattern mismatch; dataset and heap not scanned") }
		else { ll_str(&line, "unavailable; no memory validation claimed") }
		diagnostics_line_end(&line)
	}
	line = {}; ll_str(&line, "STACK TRACE DONE"); diagnostics_line_end(&line)
}

diagnostics_now :: proc "contextless" () -> i64 {
	value, err := sysclock.monotonic()
	return i64(value.time_sec) * 1_000_000_000 + i64(value.time_nsec) if err == .NONE else 0
}

diagnostics_signal_handler :: proc "c" (signal: i32, info, opaque: rawptr) {
	tid := i32(linux.gettid())
	if signal == i32(linux.Signal.SIGALRM) {
		main_tid := intrinsics.atomic_load_explicit(&diagnostic_main_tid, .Acquire)
		if main_tid != 0 && tid != main_tid {
			linux.syscall(linux.SYS_tgkill, linux.getpid(), main_tid, linux.Signal.SIGALRM)
			return
		}
		timer := eski_diag_is_timer(info) != 0
		if timer {
			deadline := intrinsics.atomic_load_explicit(&diagnostic_deadline, .Acquire)
			if deadline == 0 || intrinsics.atomic_load_explicit(&diagnostic_working, .Acquire) == 0 || diagnostics_now() < deadline { return }
			intrinsics.atomic_store_explicit(&diagnostic_deadline, 0, .Release)
		}
		diagnostics_report(signal, opaque, "WATCHDOG TIMER EXPIRED" if timer else "SIGALRM DIAGNOSTIC")
		return
	}
	if signal != i32(linux.Signal.SIGABRT) || intrinsics.atomic_load_explicit(&diagnostic_assert_tid, .Acquire) != tid {
		diagnostics_report(signal, opaque, "FATAL SIGNAL")
	}
	eski_diag_default(signal)
}

diagnostics_assertion_failure :: proc(prefix, message: string, location: runtime.Source_Code_Location) -> ! {
	_ = prefix; _ = message; _ = location
	intrinsics.atomic_store_explicit(&diagnostic_assert_tid, i32(linux.gettid()), .Release)
	diagnostics_report(i32(linux.Signal.SIGABRT), nil, "ASSERTION FAILED")
	if intrinsics.atomic_load_explicit(&diagnostic_flags, .Acquire) & DIAGNOSTIC_EXIT != 0 { linux.exit_group(1) }
	eski_diag_abort()
}

diagnostics_thread_enter :: proc() {
	if intrinsics.atomic_load_explicit(&diagnostic_initialized, .Acquire) == 0 { return }
	if error := eski_diag_thread_enter(); error != 0 { plog(LOG_WARNING, "Unable to install diagnostic alternate stack: ", errno_text(linux.Errno(error))) }
	eski_diag_mask_alarm(0 if i32(linux.gettid()) == intrinsics.atomic_load_explicit(&diagnostic_main_tid, .Acquire) else 1)
}

diagnostics_thread_leave :: proc() {
	eski_diag_mask_alarm(1)
	eski_diag_thread_leave()
}

config_apply_diagnostics :: proc() -> string {
	flags: u32
	if cfg.crash_log_enabled { flags |= DIAGNOSTIC_LOG }
	if cfg.crash_memcheck_enabled { flags |= DIAGNOSTIC_MEMORY }
	if cfg.use_exit_on_panic { flags |= DIAGNOSTIC_EXIT }
	if cfg.hide_user_data_from_log { flags |= DIAGNOSTIC_HIDE }
	intrinsics.atomic_store_explicit(&diagnostic_flags, flags, .Release)
	intrinsics.atomic_store_explicit(&diagnostic_period, u64(cfg.watchdog_period), .Release)
	if intrinsics.atomic_load_explicit(&diagnostic_initialized, .Acquire) == 0 { return "" }
	if cfg.watchdog_period > 0 && diagnostic_timer < 0 {
		if error := eski_diag_timer_create(i32(linux.gettid()), &diagnostic_timer); error != 0 { return "Unable to create watchdog timer" }
	}
	if diagnostic_timer >= 0 && cfg.watchdog_period == 0 { eski_diag_timer_arm(diagnostic_timer, 0); intrinsics.atomic_store_explicit(&diagnostic_deadline, 0, .Release) }
	if cfg.watchdog_period > 0 && intrinsics.atomic_load_explicit(&diagnostic_working, .Acquire) != 0 { diagnostics_work_begin() }
	return ""
}

diagnostics_init :: proc() -> bool {
	if intrinsics.atomic_load_explicit(&diagnostic_initialized, .Acquire) != 0 { return true }
	intrinsics.atomic_store_explicit(&diagnostic_main_tid, i32(linux.gettid()), .Release)
	if diagnostic_fd < 0 { diagnostic_fd = eski_diag_log_open(i32(log_fd)) }
	if diagnostic_fd < 0 { plog(LOG_WARNING, "Diagnostic output unavailable; native fatal behavior retained") }
	if eski_diag_runtime_init() == 0 { return false }
	if eski_diag_symbols_init() == 0 { plog(LOG_NOTICE, "Native symbol cache unavailable; diagnostics will report actual code addresses") }
	fatal := i32(1)
	when .Address in ODIN_SANITIZER_FLAGS || .Thread in ODIN_SANITIZER_FLAGS { fatal = 0 }
	if eski_diag_thread_enter() != 0 || eski_diag_install(diagnostics_signal_handler, fatal) != 0 { return false }
	intrinsics.atomic_store_explicit(&diagnostic_initialized, 1, .Release)
	if config_apply_diagnostics() != "" { diagnostics_shutdown(); return false }
	diagnostics_thread_enter()
	return true
}

diagnostics_work_begin :: proc() {
	if intrinsics.atomic_load_explicit(&diagnostic_initialized, .Acquire) == 0 { return }
	intrinsics.atomic_store_explicit(&diagnostic_working, 1, .Release)
	period := intrinsics.atomic_load_explicit(&diagnostic_period, .Acquire)
	if period != 0 && diagnostic_timer >= 0 {
		intrinsics.atomic_store_explicit(&diagnostic_deadline, diagnostics_now() + i64(period) * 1_000_000, .Release)
		eski_diag_timer_arm(diagnostic_timer, period)
	}
}

diagnostics_work_end :: proc() {
	intrinsics.atomic_store_explicit(&diagnostic_deadline, 0, .Release)
	intrinsics.atomic_store_explicit(&diagnostic_working, 0, .Release)
	if diagnostic_timer >= 0 { eski_diag_timer_arm(diagnostic_timer, 0) }
}

diagnostics_after_fork :: proc() {
	diagnostic_timer = -1
	intrinsics.atomic_store_explicit(&diagnostic_main_tid, i32(linux.gettid()), .Release)
	intrinsics.atomic_store_explicit(&diagnostic_report_guard, 0, .Release)
	intrinsics.atomic_store_explicit(&diagnostic_assert_tid, 0, .Release)
	intrinsics.atomic_store_explicit(&diagnostic_working, 0, .Release)
	intrinsics.atomic_store_explicit(&diagnostic_deadline, 0, .Release)
	if intrinsics.atomic_load_explicit(&diagnostic_initialized, .Acquire) == 0 { return }
	if error := eski_diag_thread_enter(); error != 0 { plog(LOG_WARNING, "Unable to retain child diagnostic alternate stack: ", errno_text(linux.Errno(error))) }
	config_apply_diagnostics()
}

diagnostics_shutdown :: proc() {
	diagnostics_work_end()
	eski_diag_mask_alarm(1)
	if diagnostic_timer >= 0 { eski_diag_timer_delete(diagnostic_timer); diagnostic_timer = -1 }
	eski_diag_shutdown()
	intrinsics.atomic_store_explicit(&diagnostic_initialized, 0, .Release)
}

diagnostics_memory_used :: proc "contextless" () -> int { return int(eski_diag_memory()) }

diagnostics_debug :: proc(c: ^Conn, argv: [][]u8) -> bool {
	if !eq_nocase(argv[1], "segfault") && !eq_nocase(argv[1], "assert") { return false }
	if len(argv) != 2 { reply_subcommand_syntax_error(c, argv[1], "DEBUG"); return true }
	diagnostics_capture_command("DEBUG", argv)
	if eq_nocase(argv[1], "segfault") { eski_diag_segfault() }
	diagnostics_assertion_failure("ASSERTION FAILED", "DEBUG ASSERT requested", {})
}
