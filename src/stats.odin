package main

import "core:slice"
import "hdr"

foreign import libc_stats "system:c"

@(private = "file")
@(default_calling_convention = "c")
foreign libc_stats {
	@(link_name = "snprintf")
	stats_snprintf :: proc(buf: [^]u8, size: uint, format: cstring, #c_vararg args: ..any) -> i32 ---
}

STAT_SMALL :: 64
HIST_MIN_VALUE :: 1
HIST_MAX_VALUE :: 1_000_000_000
HIST_PRECISION :: 2
STAT_US_SANE :: i64(1) << 40

Stat_Flag :: enum u8 {
	Fast,
	Skip_Slowlog,
	Cold,
}

Cmd_Stats :: struct {
	calls:    i64,
	usec:     i64,
	rejected: i64,
	failed:   i64,
	hist:     ^hdr.Histogram,
	name:     string,
	flags:    bit_set[Stat_Flag;u8],
	arity:    i32,
	acl_id:   i32,
	subs:     []Sub_Stats,
}

Sub_Stats :: struct {
	short: string,
	stats: Cmd_Stats,
}

Cmd_Hot :: struct {
	using stats: Cmd_Stats,
	limit_ticks: u64,
	small:       [STAT_SMALL]u64,
}

@(private = "file")
Stat_Blocked :: struct {
	target: ^Cmd_Stats,
	carry:  i64,
	bytes:  [dynamic]u8,
	spans:  [dynamic][2]int,
}

stat_cur: ^Cmd_Stats
stat_total_error_replies: i64
stat_unexpected_error_replies: i64
stat_el_cmd_sum: i64

@(private = "file")
stat_errors: map[string]i64
@(private = "file")
stat_sub_pool: [dynamic]Sub_Stats
@(private = "file")
stat_cmds: []Cmd_Hot
@(private = "file")
stat_by_cmd: map[^Command]^Cmd_Hot
@(private = "file")
stat_blocked: map[^Conn]Stat_Blocked
@(private = "file")
stat_saved_argv: [dynamic][]u8

@(private = "file")
stat_spec_flags :: proc(f: Cmd_Flags) -> bit_set[Stat_Flag;u8] {
	out: bit_set[Stat_Flag;u8]
	if .Fast in f {
		out += {.Fast}
	}
	if .Skip_Slowlog in f {
		out += {.Skip_Slowlog}
	}
	if .Blocking in f {
		out += {.Cold}
	}
	return out
}

@(private = "file")
stat_spec_by_name :: proc(name: string) -> ^Cmd_Spec {
	for &s in cmd_specs {
		if s.name == name {
			return &s
		}
	}
	return nil
}

stats_init :: proc() {
	clear(&stat_sub_pool)
	Range :: struct {
		st:    ^Cmd_Hot,
		first: int,
		count: int,
	}
	ranges := make([dynamic]Range, context.temp_allocator)
	stat_cmds = make([]Cmd_Hot, cmd_count)
	next := 0
	for &slot in cmd_table {
		cmd := slot.cmd
		if cmd == nil {
			continue
		}
		st := &stat_cmds[next]
		next += 1
		slot.stats = st
		stat_by_cmd[cmd] = st
		st.name = cmd.name
		st.arity = i32(cmd.arity)
		st.acl_id = acl_command_id(cmd.name)
		if spec := stat_spec_by_name(cmd.name); spec != nil {
			st.flags = stat_spec_flags(spec.flags)
		}
		if cmd.handler == cmd_flushall || cmd.handler == cmd_flushdb || cmd.handler == cmd_debug {
			st.flags += {.Cold}
		}
		first := len(stat_sub_pool)
		n := len(cmd.name)
		for &s, si in cmd_specs {
			if len(s.name) <= n + 1 || s.name[n] != '|' || s.name[:n] != cmd.name {
				continue
			}
			append(&stat_sub_pool, Sub_Stats{short = s.name[n + 1:], stats = {name = s.name, arity = s.arity, acl_id = i32(si), flags = stat_spec_flags(s.flags)}})
		}
		if len(stat_sub_pool) > first {
			st.flags += {.Cold}
			append(&ranges, Range{st, first, len(stat_sub_pool) - first})
		}
	}
	for r in ranges {
		r.st.subs = stat_sub_pool[r.first:][:r.count]
	}
	stats_limits()
}

stat_of :: proc(cmd: ^Command) -> ^Cmd_Hot {
	return stat_by_cmd[cmd]
}

stat_each :: proc() -> []Cmd_Hot {
	return stat_cmds
}

stats_limits :: proc() {
	lim: i64 = STAT_SMALL if cfg.latency_tracking else 0
	if cfg.slowlog_log_slower_than >= 0 && cfg.slowlog_max_len > 0 {
		lim = min(lim, cfg.slowlog_log_slower_than)
	}
	if cfg.latency_monitor_threshold > 0 {
		lim = min(lim, cfg.latency_monitor_threshold * 1000)
	}
	for &st in stat_cmds {
		st.limit_ticks = 0 if .Cold in st.flags else u64(lim) * mono_ticks_per_us
	}
}

config_apply_stat_limits :: proc() -> string {
	stats_limits()
	return ""
}

stat_target :: proc(st: ^Cmd_Stats, argv: [][]u8) -> ^Cmd_Stats {
	if st == nil || len(st.subs) == 0 || len(argv) < 2 {
		return st
	}
	for &s in st.subs {
		if eq_nocase(argv[1], s.short) {
			return &s.stats
		}
	}
	return nil
}

container_precheck :: proc(c: ^Conn, argv: [][]u8, name: string, upper: string) -> bool {
	slot := lookup_entry(transmute([]u8)name)
	if slot == nil || slot.stats == nil || len(argv) < 2 {
		return false
	}
	for &s in slot.stats.subs {
		if eq_nocase(argv[1], s.short) {
			if !arity_ok(int(s.stats.arity), len(argv)) {
				reply_wrong_args(c, s.stats.name)
				return true
			}
			return false
		}
	}
	reply_unknown_subcommand(c, argv[1], upper)
	return true
}

stat_lookup_name :: proc(name: []u8) -> ^Cmd_Stats {
	for b, i in name {
		if b == '|' {
			parent := lookup_entry(name[:i])
			if parent == nil || parent.stats == nil {
				return nil
			}
			for &s in parent.stats.subs {
				if eq_nocase(name[i + 1:], s.short) {
					return &s.stats
				}
			}
			return nil
		}
	}
	slot := lookup_entry(name)
	if slot == nil || slot.stats == nil {
		return nil
	}
	return &slot.stats.stats
}

@(private = "file")
stat_hist_record :: proc(st: ^Cmd_Stats, us: i64, count: i64) {
	if st.hist == nil {
		st.hist = hdr.init(HIST_MIN_VALUE, HIST_MAX_VALUE, HIST_PRECISION)
	}
	v := clamp(us * 1000, HIST_MIN_VALUE, HIST_MAX_VALUE)
	hdr.record_values(st.hist, v, count)
}

@(private = "file")
stat_record :: proc(st: ^Cmd_Stats, us: i64) {
	st.calls += 1
	st.usec += us
	if cfg.latency_tracking {
		stat_hist_record(st, us, 1)
	}
}

@(private = "file")
stat_latency_sample :: proc(st: ^Cmd_Stats, us: i64) {
	if cfg.latency_monitor_threshold > 0 && us / 1000 >= cfg.latency_monitor_threshold {
		latency_add_sample("fast-command" if .Fast in st.flags else "command", us / 1000)
	}
}

@(private = "file")
stat_slowlog :: proc(c: ^Conn, st: ^Cmd_Stats, argv: [][]u8, us: i64) {
	if .Skip_Slowlog in st.flags || cfg.slowlog_log_slower_than < 0 || cfg.slowlog_max_len == 0 {
		return
	}
	slowlog_push(c, st, argv, us)
}

@(private = "file")
stat_take_carry :: proc(c: ^Conn) -> i64 {
	if len(stat_blocked) == 0 {
		return 0
	}
	e, ok := stat_blocked[c]
	if !ok {
		return 0
	}
	delete_key(&stat_blocked, c)
	delete(e.bytes)
	delete(e.spans)
	return e.carry
}

@(private = "file")
stat_block_note :: proc(c: ^Conn, st: ^Cmd_Stats, us: i64, argv: [][]u8) {
	e, found := stat_blocked[c]
	if !found {
		e = {}
	}
	e.target = st
	e.carry += us
	if c.blocked == .Lazyfree {
		clear(&e.bytes)
		clear(&e.spans)
		for a in argv {
			append(&e.spans, [2]int{len(e.bytes), len(a)})
			append(&e.bytes, ..a)
		}
	}
	stat_blocked[c] = e
}

@(private = "file")
stat_sane_us :: #force_inline proc(raw: u64) -> i64 {
	us := i64(raw)
	if us < 0 || us >= STAT_US_SANE {
		return 0
	}
	return us
}

@(private = "file")
stat_resolve :: proc(parent: ^Cmd_Stats, argv: [][]u8, charged: bool) -> ^Cmd_Stats {
	st := stat_target(parent, argv)
	if st != parent && charged && parent.failed > 0 {
		parent.failed -= 1
		if st != nil {
			st.failed += 1
		}
	}
	return st
}

@(cold)
stat_call_slow :: #force_no_inline proc(c: ^Conn, cmd: ^Command, parent: ^Cmd_Hot, argv: [][]u8, ticks: u64) {
	us := stat_sane_us(mono_ticks_us(ticks))
	charged := stat_cur != &parent.stats
	stat_cur = nil
	st := stat_resolve(&parent.stats, argv, charged)
	if st == nil {
		return
	}
	if charged && ((cmd.handler == cmd_debug && !debug_allowed(c)) || (st != &parent.stats && !arity_ok(int(st.arity), len(argv)))) {
		st.failed -= 1
		st.rejected += 1
		return
	}
	stat_el_cmd_sum += us
	stat_latency_sample(st, us)
	if c.blocked != .None {
		stat_block_note(c, st, us, argv)
		return
	}
	srv.stat_commands += 1
	total := us + stat_take_carry(c)
	stat_record(st, total)
	stat_slowlog(c, st, argv, total)
}

@(cold)
stat_nested :: #force_no_inline proc(c: ^Conn, parent: ^Cmd_Hot, argv: [][]u8, t0: u64) {
	us := stat_sane_us(mono_ticks_us(mono_now() - t0))
	charged := stat_cur != &parent.stats
	stat_cur = nil
	srv.stat_commands += 1
	st := stat_resolve(&parent.stats, argv, charged)
	if st == nil {
		return
	}
	stat_latency_sample(st, us)
	stat_record(st, us)
	stat_slowlog(c, st, argv, us)
}

@(cold)
stat_reject :: #force_no_inline proc(parent: ^Cmd_Hot, argv: [][]u8) {
	if st := stat_target(&parent.stats, argv); st != nil {
		st.rejected += 1
	}
}

@(cold)
stats_unblocked :: #force_no_inline proc(c: ^Conn, argv: [][]u8, failed: bool) {
	e, ok := stat_blocked[c]
	if !ok {
		return
	}
	delete_key(&stat_blocked, c)
	args := argv
	if args == nil && len(e.spans) > 0 {
		clear(&stat_saved_argv)
		for sp in e.spans {
			append(&stat_saved_argv, e.bytes[sp[0]:][:sp[1]])
		}
		args = stat_saved_argv[:]
	}
	if failed {
		e.target.failed += 1
	}
	stat_record(e.target, e.carry)
	if args != nil {
		stat_slowlog(c, e.target, args, e.carry)
	}
	delete(e.bytes)
	delete(e.spans)
}

stats_conn_closed :: proc(c: ^Conn) {
	if len(stat_blocked) == 0 {
		return
	}
	if e, ok := stat_blocked[c]; ok {
		delete_key(&stat_blocked, c)
		delete(e.bytes)
		delete(e.spans)
	}
}

@(private = "file")
stat_error_prefix :: proc(msg: []u8) -> []u8 {
	lim := min(len(msg), 31)
	for i in 0 ..< lim {
		if msg[i] == ' ' {
			return msg[:i]
		}
	}
	return transmute([]u8)string("ERR")
}

@(cold)
stat_error_reply :: #force_no_inline proc(c: ^Conn, msg: []u8) {
	stat_total_error_replies += 1
	if st := stat_cur; st != nil {
		st.failed += 1
		stat_cur = nil
	}
	if c.fd < 0 && c == aof.fake {
		stat_unexpected_error_replies += 1
	}
	prefix := stat_error_prefix(msg)
	if p, ok := &stat_errors[string(prefix)]; ok {
		p^ += 1
		return
	}
	stat_errors[clone_key(prefix)] = 1
}

@(private = "file")
stat_fold_one :: proc(st: ^Cmd_Hot) #no_bounds_check {
	for i in 0 ..< STAT_SMALL {
		n := st.small[i]
		if n == 0 {
			continue
		}
		st.small[i] = 0
		st.calls += i64(n)
		st.usec += i64(i) * i64(n)
		stat_el_cmd_sum += i64(i) * i64(n)
		stat_hist_record(&st.stats, i64(i), i64(n))
	}
}

stats_fold :: proc() {
	for &st in stat_cmds {
		stat_fold_one(&st)
	}
}

@(private = "file")
stat_reset_one :: proc(st: ^Cmd_Stats) {
	st.calls = 0
	st.usec = 0
	st.rejected = 0
	st.failed = 0
	if st.hist != nil {
		hdr.close(st.hist)
		st.hist = nil
	}
}

stats_reset :: proc() {
	for &st in stat_cmds {
		st.small = {}
		stat_reset_one(&st.stats)
		for &s in st.subs {
			stat_reset_one(&s.stats)
		}
	}
	for k in stat_errors {
		mem_free(raw_data(k))
	}
	clear(&stat_errors)
	stat_total_error_replies = 0
	stat_unexpected_error_replies = 0
	stat_el_cmd_sum = 0
}

@(private = "file")
stat_visit :: proc(visit: proc(b: ^[dynamic]u8, st: ^Cmd_Stats), b: ^[dynamic]u8) {
	for &st in stat_cmds {
		visit(b, &st.stats)
		for &s in st.subs {
			visit(b, &s.stats)
		}
	}
}

@(private = "file")
sb_float_fmt :: proc(b: ^[dynamic]u8, format: cstring, v: f64) {
	tmp: [128]u8
	n := stats_snprintf(&tmp[0], uint(len(tmp)), format, v)
	if n > 0 {
		sb_bytes(b, tmp[:min(int(n), len(tmp) - 1)])
	}
}

sb_fixed3 :: proc(b: ^[dynamic]u8, v: f64) {
	sb_float_fmt(b, "%.3f", v)
}

@(private = "file")
stat_format_percentile :: proc(b: ^[dynamic]u8, v: f64) {
	tmp: [128]u8
	n := int(stats_snprintf(&tmp[0], uint(len(tmp)), "%f", v))
	n = clamp(n, 0, len(tmp) - 1)
	has_dot := false
	for ch in tmp[:n] {
		if ch == '.' {
			has_dot = true
		}
	}
	if has_dot {
		for n > 0 && tmp[n - 1] == '0' {
			n -= 1
		}
		if n > 0 && tmp[n - 1] == '.' {
			n -= 1
		}
	}
	sb_bytes(b, tmp[:n])
}

info_commandstats :: proc(b: ^[dynamic]u8) {
	stats_fold()
	stat_visit(proc(b: ^[dynamic]u8, st: ^Cmd_Stats) {
		if st.calls == 0 && st.failed == 0 && st.rejected == 0 {
			return
		}
		sb_str(b, "cmdstat_")
		sb_str(b, st.name)
		sb_str(b, ":calls=")
		sb_int(b, st.calls)
		sb_str(b, ",usec=")
		sb_int(b, st.usec)
		sb_str(b, ",usec_per_call=")
		per: f32 = 0
		if st.calls != 0 {
			per = f32(st.usec) / f32(st.calls)
		}
		sb_fixed(b, f64(per))
		sb_str(b, ",rejected_calls=")
		sb_int(b, st.rejected)
		sb_str(b, ",failed_calls=")
		sb_int(b, st.failed)
		sb_str(b, "\r\n")
	}, b)
}

info_errorstats :: proc(b: ^[dynamic]u8) {
	keys := make([dynamic]string, 0, len(stat_errors), context.temp_allocator)
	for k in stat_errors {
		append(&keys, k)
	}
	slice.sort(keys[:])
	for k in keys {
		sb_str(b, "errorstat_")
		sb_str(b, k)
		sb_str(b, ":count=")
		sb_int(b, stat_errors[k])
		sb_str(b, "\r\n")
	}
}

stat_percentiles_line :: proc(b: ^[dynamic]u8, st: ^Cmd_Stats) {
	sb_str(b, "latency_percentiles_usec_")
	sb_str(b, st.name)
	sb_byte(b, ':')
	for p, i in config_percentiles {
		sb_byte(b, 'p')
		stat_format_percentile(b, p)
		sb_byte(b, '=')
		sb_fixed3(b, f64(hdr.value_at_percentile(st.hist, p)) / 1000.0)
		if i != len(config_percentiles) - 1 {
			sb_byte(b, ',')
		}
	}
	sb_str(b, "\r\n")
}

info_latencystats :: proc(b: ^[dynamic]u8) {
	stats_fold()
	stat_visit(proc(b: ^[dynamic]u8, st: ^Cmd_Stats) {
		if st.hist != nil {
			stat_percentiles_line(b, st)
		}
	}, b)
}
