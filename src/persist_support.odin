package main
import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"
import "rdb"

foreign import libc_persist_signals "system:c"

foreign libc_persist_signals {
	@(link_name = "signal")
	persist_libc_signal :: proc "c" (sig: linux.Signal, handler: linux.Sig_Handler_Fn) -> linux.Sig_Handler_Fn ---
}

PERSIST_LOADING_EVENTS_BYTES :: 2 * 1024 * 1024

PERSIST_PATH_MAX :: 4096

LOG_DEBUG :: '.'

LOG_VERBOSE :: '-'

LOG_NOTICE :: '*'

LOG_WARNING :: '#'

persist_policy_lru :: #force_inline proc "contextless" () -> bool {
	return maxmemory_policy == .Volatile_Lru || maxmemory_policy == .Allkeys_Lru
}

persist_policy_lfu :: #force_inline proc "contextless" () -> bool {
	return maxmemory_policy == .Volatile_Lfu || maxmemory_policy == .Allkeys_Lfu
}

persist_sig_pending: i32

persist_sig_last: i32

persist_signal_temp: [80]u8
persist_signal_saving: i32

#assert(intrinsics.atomic_type_is_lock_free(i32))

Log_Line :: struct {
	buf:  [4096]u8,
	n:    int,
	skip: bool,
	level: u8,
}

log_level_rank :: proc "contextless" (level: u8) -> u8 {
	switch level {
	case '.':
		return 0
	case '-':
		return 1
	case '#':
		return 3
	}
	return 2
}

ll_str :: proc "contextless" (l: ^Log_Line, s: string) {
	k := min(len(s), len(l.buf) - 1 - l.n)
	for i in 0 ..< k {
		l.buf[l.n + i] = s[i]
	}
	l.n += k
}

ll_bytes :: proc "contextless" (l: ^Log_Line, s: []u8) {
	ll_str(l, string(s))
}

ll_int :: proc "contextless" (l: ^Log_Line, v: i64) {
	tmp: [24]u8
	n := format_i64(&tmp[0], v)
	ll_str(l, string(tmp[:n]))
}

ll_pad :: proc "contextless" (l: ^Log_Line, v: i64, width: int) {
	tmp: [24]u8
	n := format_i64(&tmp[0], v)
	for _ in n ..< width {
		ll_str(l, "0")
	}
	ll_str(l, string(tmp[:n]))
}

ll_fixed :: proc "contextless" (l: ^Log_Line, v: f64, decimals: int) {
	scale: i64 = 1
	for _ in 0 ..< decimals {
		scale *= 10
	}
	x := v
	neg := x < 0
	if neg {
		x = -x
		ll_str(l, "-")
	}
	r := i64(x * f64(scale) + 0.5)
	ll_int(l, r / scale)
	if decimals > 0 {
		ll_str(l, ".")
		ll_pad(l, r % scale, decimals)
	}
}

ll_hex :: proc "contextless" (l: ^Log_Line, v: u64) {
	digits := "0123456789abcdef"
	tmp: [16]u8
	i := 16
	x := v
	for {
		i -= 1
		tmp[i] = digits[x & 15]
		x >>= 4
		if x == 0 {
			break
		}
	}
	ll_str(l, string(tmp[i:]))
}

ll_begin :: proc "contextless" (l: ^Log_Line, level: u8) {
	l.n = 0
	l.level = level
	l.skip = log_level_rank(level) < intrinsics.atomic_load_explicit(&cfg.loglevel, .Relaxed)
	ll_int(l, i64(linux.getpid()))
	ll_str(l, ":C " if pst.in_child else ":M ")
	ts, _ := linux.clock_gettime(.REALTIME)
	secs := i64(ts.time_sec)
	ms := i64(ts.time_nsec) / 1_000_000
	days := secs / 86400
	rem := secs % 86400
	z := days + 719468
	era := z / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	y := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d := doy - (153 * mp + 2) / 5 + 1
	m := mp + 3 if mp < 10 else mp - 9
	if m <= 2 {
		y += 1
	}
	ll_pad(l, d, 2)
	ll_str(l, " ")
	ll_str(l, MONTHS[m - 1])
	ll_str(l, " ")
	ll_int(l, y)
	ll_str(l, " ")
	ll_pad(l, rem / 3600, 2)
	ll_str(l, ":")
	ll_pad(l, (rem / 60) % 60, 2)
	ll_str(l, ":")
	ll_pad(l, rem % 60, 2)
	ll_str(l, ".")
	ll_pad(l, ms, 3)
	ll_str(l, " ")
	b := [1]u8{level}
	ll_bytes(l, b[:])
	ll_str(l, " ")
}

ll_end :: proc "contextless" (l: ^Log_Line) {
	if l.skip {
		return
	}
	runtime_log_syslog(l.level, l.buf[:l.n])
	l.buf[l.n] = '\n'
	l.n += 1
	b := l.buf[:l.n]
	for len(b) > 0 {
		n, err := linux.write(log_fd, b)
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			return
		}
		b = b[n:]
	}
}

plog :: proc "contextless" (level: u8, parts: ..string) {
	l: Log_Line
	ll_begin(&l, level)
	for p in parts {
		ll_str(&l, p)
	}
	ll_end(&l)
}

errno_text :: proc "contextless" (e: linux.Errno) -> string {
	#partial switch e {
	case .ENOENT:
		return "No such file or directory"
	case .EACCES:
		return "Permission denied"
	case .EPERM:
		return "Operation not permitted"
	case .ENOSPC:
		return "No space left on device"
	case .ENOTDIR:
		return "Not a directory"
	case .EROFS:
		return "Read-only file system"
	case .EIO:
		return "Input/output error"
	case .EEXIST:
		return "File exists"
	case .EISDIR:
		return "Is a directory"
	case .EMFILE:
		return "Too many open files"
	case .ENOMEM:
		return "Cannot allocate memory"
	case .EINVAL:
		return "Invalid argument"
	case .EAGAIN:
		return "Resource temporarily unavailable"
	case .EDQUOT:
		return "Disk quota exceeded"
	case .ENAMETOOLONG:
		return "File name too long"
	case .EBUSY:
		return "Device or resource busy"
	case .EXDEV:
		return "Invalid cross-device link"
	}
	return "Unknown error"
}

persist_unix_now :: #force_inline proc "contextless" () -> i64 {
	ts, _ := linux.clock_gettime(.REALTIME)
	return i64(ts.time_sec)
}

persist_cwd :: proc "contextless" (buf: []u8) -> string {
	n, err := linux.getcwd(buf)
	if err != .NONE || n <= 0 {
		return "unknown"
	}
	end := n
	for end > 0 && buf[end - 1] == 0 {
		end -= 1
	}
	return string(buf[:end])
}

persist_cstr :: proc "contextless" (s: string, buf: []u8) -> cstring {
	n := min(len(s), len(buf) - 1)
	for i in 0 ..< n {
		buf[i] = s[i]
	}
	buf[n] = 0
	return cstring(raw_data(buf))
}

persist_temp_name :: proc "contextless" (pid: linux.Pid, buf: []u8) -> string {
	n := 0
	prefix := "temp-"
	for i in 0 ..< len(prefix) {
		buf[n] = prefix[i]
		n += 1
	}
	n += format_i64(&buf[n], i64(pid))
	suffix := ".rdb"
	for i in 0 ..< len(suffix) {
		buf[n] = suffix[i]
		n += 1
	}
	return string(buf[:n])
}

persist_slot_value :: #force_inline proc "contextless" (db: ^Db, kp: ^Key_Handle, vp: ^Val_Handle) -> (v: Slot_Value) {
	form := kp.small.tag.val_form
	switch {
	case form == FORM_OBJECT:
		v.obj = rawptr(vp.ref.addr)
		v.type = vp.slab.info.type
	case form == FORM_SLAB:
		v.str = slab_ptr(&db.slab, vp.slab.offset)[:vp.slab.len]
	case form == FORM_HEAP:
		bs := (^Big_Str)(vp.ref.addr)
		v.str = bs.data[:bs.len]
	case form >= FORM_INLINE && form <= FORM_INLINE + INLINE_BYTES:
		v.str = ([^]u8)(vp)[:int(form) - FORM_INLINE]
	}
	return
}

persist_debug_delay :: proc "contextless" (usec: i64) {
	u := usec
	if u < 0 {
		u = 1 if rng_next() % u64(-u) == 0 else 0
	}
	if u > 0 {
		ts := linux.Time_Spec {
			time_sec  = uint(u / 1_000_000),
			time_nsec = uint((u % 1_000_000) * 1000),
		}
		rem: linux.Time_Spec
		for linux.nanosleep(&ts, &rem) == .EINTR {
			ts = rem
		}
	}
}

persist_child_setup :: proc() {
	pst.in_child = true
	config_oom_child_apply()
	persist_set_signal(.SIGTERM, nil)
	persist_set_signal(.SIGINT, nil)
	server_close_listeners()
	if mc_lfd >= 0 {
		linux.close(mc_lfd)
	}
	linux.close(srv.epfd)
	for c in srv.conns {
		if c != nil {
			linux.close(c.fd)
		}
	}
}

persist_private_dirty :: proc "contextless" () -> i64 {
	fd, err := linux.open("/proc/self/smaps_rollup", {.CLOEXEC})
	if err != .NONE {
		return 0
	}
	defer linux.close(fd)
	buf: [4096]u8
	n, rerr := linux.read(fd, buf[:])
	if rerr != .NONE || n <= 0 {
		return 0
	}
	key := "Private_Dirty:"
	for i := 0; i + len(key) <= n; i += 1 {
		if string(buf[i:i + len(key)]) != key {
			continue
		}
		j := i + len(key)
		for j < n && buf[j] == ' ' {
			j += 1
		}
		v: i64 = 0
		for j < n && buf[j] >= '0' && buf[j] <= '9' {
			v = v * 10 + i64(buf[j] - '0')
			j += 1
		}
		return v * 1024
	}
	return 0
}

persist_sample_cow :: proc "contextless" () {
	p := pst.progress
	if p == nil {
		return
	}
	cow := persist_private_dirty()
	ts, _ := linux.clock_gettime(.MONOTONIC)
	intrinsics.volatile_store(&p.cow, cow)
	if cow > intrinsics.volatile_load(&p.cow_peak) {
		intrinsics.volatile_store(&p.cow_peak, cow)
	}
	p.cow_sum += cow
	p.cow_samples += 1
	intrinsics.volatile_store(&p.cow_ms, i64(ts.time_sec) * 1000 + i64(ts.time_nsec) / 1_000_000)
}

persist_total_keys :: proc "contextless" () -> i64 {
	n: i64 = 0
	for &d in dbs {
		n += i64(db_size_of(&d))
	}
	return n
}

persist_progress_prepare :: proc() {
	if pst.progress == nil {
		p, merr := linux.mmap(0, 4096, {.READ, .WRITE}, {.SHARED, .ANONYMOUS}, -1, 0)
		if merr == .NONE {
			pst.progress = (^Persist_Progress)(p)
		}
	}
	if pst.progress != nil {
		pst.progress^ = {}
		pst.progress.total = persist_total_keys()
		pst.progress.cow_ms = now_ns() / 1_000_000
	}
}

persist_log_cow :: proc(prefix: string) {
	p := pst.progress
	if p == nil {
		return
	}
	l: Log_Line
	ll_begin(&l, LOG_NOTICE)
	ll_str(&l, prefix)
	ll_int(&l, p.cow >> 20)
	ll_str(&l, " MB, peak ")
	ll_int(&l, p.cow_peak >> 20)
	ll_str(&l, " MB, average ")
	ll_int(&l, (p.cow_sum / max(p.cow_samples, 1)) >> 20)
	ll_str(&l, " MB")
	ll_end(&l)
}

@(private)
persist_loading_progress :: proc "contextless" (r: ^rdb.Reader) {
	context = runtime.default_context()
	pst.loading_loaded = rdb.reader_offset(r)
	if pst.serve_while_loading {
		persist_serve_events()
	}
}

persist_serve_events :: proc() {
	n, werr := linux.epoll_wait(srv.epfd, &events[0], MAX_EVENTS, 0)
	if werr != .NONE {
		return
	}
	update_clock()
	for i in 0 ..< int(n) {
		ev := events[i]
		fd := linux.Fd(u32(ev.data.u64))
		if u32(ev.data.u64 >> 32) == 0 {
			if fd != mc_lfd && fd != keyspace_event_fd() && fd != compute_event_fd() && fd != lazy_efd {
				accept_clients(fd, .Redis)
			}
			continue
		}
		if int(fd) >= len(srv.conns) {
			continue
		}
		c := srv.conns[fd]
		if c == nil || u32(c.id) != u32(ev.data.u64 >> 32) {
			continue
		}
		handle_event(c, ev.events)
	}
}

persist_signal_handler :: proc "c" (sig: linux.Signal) {
	intrinsics.atomic_store_explicit(&persist_sig_last, i32(sig), .Relaxed)
	pending := intrinsics.atomic_add_explicit(&persist_sig_pending, 1, .Acq_Rel)
	if pending != 0 && sig == .SIGINT {
		if intrinsics.atomic_load_explicit(&persist_signal_saving, .Acquire) != 0 {
			linux.unlink(cstring(raw_data(persist_signal_temp[:])))
		}
		linux.exit_group(1)
	}
}

persist_set_signal :: proc "contextless" (sig: linux.Signal, handler: linux.Sig_Handler_Fn) -> bool {
	previous := persist_libc_signal(sig, handler)
	return transmute(uintptr)previous != ~uintptr(0)
}

persist_signal_pending :: proc "contextless" () -> bool {
	return intrinsics.atomic_load_explicit(&persist_sig_pending, .Acquire) != 0
}

persist_signal_log :: proc(sig: i32) {
	msg := "Received shutdown signal, scheduling shutdown..."
	switch sig {
	case i32(linux.Signal.SIGINT):
		msg = "Received SIGINT scheduling shutdown..."
	case i32(linux.Signal.SIGTERM):
		msg = "Received SIGTERM scheduling shutdown..."
	}
	if pst.loading {
		msg = "Received shutdown signal during loading, scheduling shutdown."
	}
	plog(LOG_WARNING, msg)
}

persist_signal_loading_exit :: proc() {
	persist_signal_log(intrinsics.atomic_load_explicit(&persist_sig_last, .Acquire))
	keyspace_shutdown()
	compute_shutdown()
	plog(LOG_WARNING, "Eski is now ready to exit, bye bye...")
	linux.exit_group(0)
}

persist_install_signals :: proc() {
	name := persist_temp_name(linux.getpid(), persist_signal_temp[:])
	persist_signal_temp[len(name)] = 0
	if !persist_set_signal(.SIGTERM, persist_signal_handler) || !persist_set_signal(.SIGINT, persist_signal_handler) {
		plog(LOG_WARNING, "Cannot install shutdown signal handlers")
		linux.exit_group(1)
	}
}

persist_raw_locate :: proc(db: ^Db, key: []u8) -> (^Table, int) {
	l := lookup_make(key)
	if db.rehash_idx >= 0 {
		i := table_find_slow(&db.t[0], &db.slab, &l, true)
		if i >= 0 {
			return &db.t[0], i
		}
		return &db.t[1], table_find_slow(&db.t[1], &db.slab, &l, true)
	}
	return &db.t[0], table_find(&db.t[0], &db.slab, &l, true)
}
