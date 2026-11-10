package main

import "core:sys/linux"

INST_SAMPLES :: 16

Inst_Metric_Kind :: enum {
	Command,
	Net_Input,
	Net_Output,
	El_Cycle,
	El_Duration,
}

@(private = "file")
Inst_Metric :: struct {
	idx:               int,
	last_sample_base:  i64,
	last_sample_value: i64,
	samples:           [INST_SAMPLES]i64,
}

Info_Section :: enum {
	Server,
	Clients,
	Memory,
	Persistence,
	Stats,
	Replication,
	Cpu,
	Modules,
	Commandstats,
	Errorstats,
	Latencystats,
	Cluster,
	Keyspace,
	Debug,
	Owners,
}

@(private = "file")
info_section_names := [Info_Section]string {
	.Server       = "server",
	.Clients      = "clients",
	.Memory       = "memory",
	.Persistence  = "persistence",
	.Stats        = "stats",
	.Replication  = "replication",
	.Cpu          = "cpu",
	.Modules      = "modules",
	.Commandstats = "commandstats",
	.Errorstats   = "errorstats",
	.Latencystats = "latencystats",
	.Cluster      = "cluster",
	.Keyspace     = "keyspace",
	.Debug        = "debug",
	.Owners       = "owners",
}

INFO_DEFAULT :: bit_set[Info_Section]{.Server, .Clients, .Memory, .Persistence, .Stats, .Replication, .Cpu, .Modules, .Errorstats, .Cluster, .Keyspace, .Owners}
INFO_ALL :: bit_set[Info_Section]{.Server, .Clients, .Memory, .Persistence, .Stats, .Replication, .Cpu, .Modules, .Commandstats, .Errorstats, .Latencystats, .Cluster, .Keyspace, .Owners}

stat_net_input_bytes: i64
stat_net_output_bytes: i64
stat_reads_processed: i64
stat_writes_processed: i64
stat_reply_buffer_shrinks: i64
stat_reply_buffer_expands: i64
stat_expired_stale_perc: f64
stat_expired_time_cap_reached: i64
stat_expire_cycle_us: i64
stat_dump_sanitizations: i64

el_cycles: i64
el_sum_ticks: u64
el_max_ticks: u64
el_aof_sum: i64
el_cron_sum: i64
el_cmd_per_cycle_max: i64
el_start: u64
el_cmd_start: i64

@(private = "file")
inst: [Inst_Metric_Kind]Inst_Metric
@(private = "file")
inst_last_ms: i64
@(private = "file")
info_executable: string
@(private = "file")
info_uname: linux.UTS_Name
@(private = "file")
info_uname_done: bool

info_absolute_path :: proc(filename: string) -> string {
	rel := filename
	for len(rel) > 0 && (rel[0] == ' ' || rel[0] == '\r' || rel[0] == '\n' || rel[0] == '\t') {
		rel = rel[1:]
	}
	for len(rel) > 0 {
		last := rel[len(rel) - 1]
		if last != ' ' && last != '\r' && last != '\n' && last != '\t' {
			break
		}
		rel = rel[:len(rel) - 1]
	}
	if len(rel) > 0 && rel[0] == '/' {
		return rel
	}
	buf: [4096]u8
	cwd := persist_cwd(buf[:])
	abs := make([dynamic]u8)
	sb_str(&abs, cwd)
	if len(abs) > 0 && abs[len(abs) - 1] != '/' {
		sb_byte(&abs, '/')
	}
	for len(rel) >= 3 && rel[0] == '.' && rel[1] == '.' && rel[2] == '/' {
		rel = rel[3:]
		if len(abs) > 1 {
			p := len(abs) - 2
			for abs[p] != '/' {
				p -= 1
			}
			resize(&abs, p + 1)
		}
	}
	sb_str(&abs, rel)
	return string(abs[:])
}

info_preserve_executable :: proc(start, end: uintptr) {
	address := uintptr(raw_data(info_executable))
	if address >= start && address < end {
		owned := make([]u8, len(info_executable))
		copy(owned, info_executable)
		info_executable = string(owned)
	}
}

info_startup :: proc(argv0: string) {
	info_executable = info_absolute_path(argv0)
}

info_init :: proc() {
	replication_ids()
	mono_init()
}

el_before_sleep :: #force_inline proc() {
	dur := mono_now() - el_start
	el_cycles += 1
	el_sum_ticks += dur
	if dur > el_max_ticks {
		el_max_ticks = dur
	}
	cmds := srv.stat_commands
	n := cmds - el_cmd_start
	el_cmd_start = cmds
	if n > el_cmd_per_cycle_max {
		el_cmd_per_cycle_max = n
	}
}

el_after_sleep :: #force_inline proc() {
	el_start = mono_now()
}

@(private = "file")
el_ticks_us :: proc(ticks: u64) -> i64 {
	us := i64(mono_ticks_us(ticks))
	if us < 0 || us >= STAT_US_SANE {
		return 0
	}
	return us
}

@(private = "file")
inst_track :: proc(k: Inst_Metric_Kind, value: i64, base: i64, factor: i64) {
	m := &inst[k]
	if m.last_sample_base > 0 {
		b := base - m.last_sample_base
		v := value - m.last_sample_value
		avg := v * factor / b if b > 0 else 0
		m.samples[m.idx] = avg
		m.idx = (m.idx + 1) % INST_SAMPLES
	}
	m.last_sample_base = base
	m.last_sample_value = value
}

@(private = "file")
inst_get :: proc(k: Inst_Metric_Kind) -> i64 {
	sum: i64 = 0
	for v in inst[k].samples {
		sum += v
	}
	return sum / INST_SAMPLES
}

stats_cron :: proc() {
	if srv.now_ms - inst_last_ms >= 100 {
		inst_last_ms = srv.now_ms
		now_us := i64(mono_us())
		inst_track(.Command, srv.stat_commands, now_us, 1_000_000)
		inst_track(.Net_Input, stat_net_input_bytes, now_us, 1_000_000)
		inst_track(.Net_Output, stat_net_output_bytes, now_us, 1_000_000)
		inst_track(.El_Cycle, el_cycles, now_us, 1_000_000)
		inst_track(.El_Duration, el_ticks_us(el_sum_ticks), el_cycles, 1)
	}
}

el_note_cron :: #force_inline proc(start: u64) {
	el_cron_sum += i64(mono_ticks_us(mono_now() - start))
}

el_note_aof :: #force_inline proc(start: u64) {
	el_aof_sum += i64(mono_ticks_us(mono_now() - start))
}

stats_reset_server :: proc() {
	stats_reset()
	stat_net_input_bytes = 0
	stat_net_output_bytes = 0
	stat_reads_processed = 0
	stat_writes_processed = 0
	stat_reply_buffer_shrinks = 0
	stat_reply_buffer_expands = 0
	stat_expired_stale_perc = 0
	stat_expired_time_cap_reached = 0
	stat_expire_cycle_us = 0
	stat_dump_sanitizations = 0
	el_cycles = 0
	el_sum_ticks = 0
	el_max_ticks = 0
	el_aof_sum = 0
	el_cron_sum = 0
	el_cmd_per_cycle_max = 0
	inst = {}
	inst_last_ms = 0
}

info_line_int :: proc(b: ^[dynamic]u8, name: string, v: i64) {
	sb_str(b, name)
	sb_byte(b, ':')
	sb_int(b, v)
	sb_str(b, "\r\n")
}

info_line_str :: proc(b: ^[dynamic]u8, name: string, v: string) {
	sb_str(b, name)
	sb_byte(b, ':')
	sb_str(b, v)
	sb_str(b, "\r\n")
}

info_line_human :: proc(b: ^[dynamic]u8, name: string, v: i64) {
	sb_str(b, name)
	sb_byte(b, ':')
	sb_human(b, v)
	sb_str(b, "\r\n")
}

info_line_fixed :: proc(b: ^[dynamic]u8, name: string, v: f64) {
	sb_str(b, name)
	sb_byte(b, ':')
	sb_fixed(b, v)
	sb_str(b, "\r\n")
}

info_section_header :: proc(b: ^[dynamic]u8, title: string) {
	if len(b) > 0 {
		sb_str(b, "\r\n")
	}
	sb_str(b, "# ")
	sb_str(b, title)
	sb_str(b, "\r\n")
}

@(private = "file")
info_cstr :: proc(a: []u8) -> string {
	for ch, i in a {
		if ch == 0 {
			return string(a[:i])
		}
	}
	return string(a)
}

@(private = "file")
info_server :: proc(b: ^[dynamic]u8) {
	if !info_uname_done {
		linux.uname(&info_uname)
		info_uname_done = true
	}
	sec, usec := now_realtime()
	uptime := (srv.now_ms - srv.start_ms) / 1000
	info_section_header(b, "Server")
	info_line_str(b, "redis_version", REDIS_COMPAT_VERSION)
	info_line_str(b, "eski_version", VERSION)
	info_line_str(b, "redis_git_sha1", "00000000")
	info_line_str(b, "redis_git_dirty", "0")
	info_line_str(b, "redis_build_id", "0")
	info_line_str(b, "redis_mode", "standalone")
	sb_str(b, "os:")
	sb_str(b, info_cstr(info_uname.sysname[:]))
	sb_byte(b, ' ')
	sb_str(b, info_cstr(info_uname.release[:]))
	sb_byte(b, ' ')
	sb_str(b, info_cstr(info_uname.machine[:]))
	sb_str(b, "\r\n")
	info_line_int(b, "arch_bits", 64)
	info_line_str(b, "monotonic_clock", mono_info)
	info_line_str(b, "multiplexing_api", "epoll")
	info_line_str(b, "atomicvar_api", "c11-builtin")
	info_line_str(b, "gcc_version", "0.0.0")
	info_line_int(b, "process_id", srv.pid)
	info_line_str(b, "process_supervised", runtime_supervised_name())
	sb_str(b, "run_id:")
	sb_bytes(b, srv.run_id[:])
	sb_str(b, "\r\n")
	info_line_int(b, "tcp_port", i64(srv.port) if srv.port != 0 else cfg.tls_port)
	info_line_int(b, "server_time_usec", sec * 1_000_000 + usec)
	info_line_int(b, "uptime_in_seconds", uptime)
	info_line_int(b, "uptime_in_days", uptime / 86400)
	info_line_int(b, "hz", config_hz_current)
	info_line_int(b, "configured_hz", cfg.hz)
	info_line_int(b, "lru_clock", i64(access_seconds_now))
	info_line_str(b, "executable", info_executable)
	info_line_str(b, "config_file", config_file)
	info_line_int(b, "io_threads_active", 0)
	compute_info(b)
	keyspace_info(b)
	if srv.nlfd > 0 {
		sb_str(b, "listener0:name=tcp")
		for a in config_bind {
			if len(a) > 0 && a[0] == '-' {
				continue
			}
			sb_str(b, ",bind=")
			sb_str(b, a)
		}
		sb_str(b, ",port=")
		sb_int(b, i64(srv.port))
		sb_str(b, "\r\n")
	}
}

@(private = "file")
info_clients :: proc(b: ^[dynamic]u8) {
	maxin, maxout: i64
	for c in srv.conns {
		if c == nil {
			continue
		}
		maxin = max(maxin, i64(max(c.rpeak, c.rlen - c.rpos)))
		maxout = max(maxout, i64(c.wlen - c.wpos))
	}
	in_timeout := 0
	for c in block_clients {
		if c.bstate != nil && c.bstate.deadline != 0 {
			in_timeout += 1
		}
	}
	info_section_header(b, "Clients")
	info_line_int(b, "connected_clients", i64(srv.nconns))
	info_line_int(b, "cluster_connections", 0)
	info_line_int(b, "maxclients", cfg.maxclients)
	info_line_int(b, "client_recent_max_input_buffer", maxin)
	info_line_int(b, "client_recent_max_output_buffer", maxout)
	info_line_int(b, "blocked_clients", i64(srv.held_count + block_count() + lazy_blocked))
	info_line_int(b, "tracking_clients", i64(tracking_clients))
	info_line_int(b, "pubsub_clients", i64(len(ps_conns)))
	info_line_int(b, "watching_clients", i64(watch_clients))
	info_line_int(b, "clients_in_timeout_table", i64(in_timeout))
	info_line_int(b, "total_watched_keys", i64(watch_total))
	info_line_int(b, "total_blocking_keys", i64(block_total_keys()))
	info_line_int(b, "total_blocking_keys_on_nokey", i64(block_total_nokey_keys()))
}

@(private = "file")
info_stats :: proc(b: ^[dynamic]u8) {
	stats_fold()
	info_section_header(b, "Stats")
	info_line_int(b, "total_connections_received", srv.stat_conns)
	info_line_int(b, "total_commands_processed", srv.stat_commands)
	info_line_int(b, "instantaneous_ops_per_sec", inst_get(.Command))
	info_line_int(b, "total_net_input_bytes", stat_net_input_bytes)
	info_line_int(b, "total_net_output_bytes", stat_net_output_bytes)
	info_line_int(b, "total_net_repl_input_bytes", 0)
	info_line_int(b, "total_net_repl_output_bytes", 0)
	info_line_fixed(b, "instantaneous_input_kbps", f64(f32(inst_get(.Net_Input)) / 1024))
	info_line_fixed(b, "instantaneous_output_kbps", f64(f32(inst_get(.Net_Output)) / 1024))
	info_line_fixed(b, "instantaneous_input_repl_kbps", 0)
	info_line_fixed(b, "instantaneous_output_repl_kbps", 0)
	info_line_int(b, "rejected_connections", srv.stat_rejected_conns)
	info_line_int(b, "sync_full", 0)
	info_line_int(b, "sync_partial_ok", 0)
	info_line_int(b, "sync_partial_err", 0)
	info_line_int(b, "expired_subkeys", stat_expired_subkeys)
	info_line_int(b, "expired_keys", srv.stat_expired)
	info_line_fixed(b, "expired_stale_perc", stat_expired_stale_perc * 100)
	info_line_int(b, "expired_time_cap_reached_count", stat_expired_time_cap_reached)
	info_line_int(b, "expire_cycle_cpu_milliseconds", stat_expire_cycle_us / 1000)
	info_line_int(b, "evicted_keys", stat_evicted_keys)
	info_line_int(b, "evicted_clients", stat_evicted_clients)
	info_line_int(b, "evicted_scripts", lua_cache_evictions)
	info_line_int(b, "total_eviction_exceeded_time", eviction_exceeded_total_us() / 1000)
	info_line_int(b, "current_eviction_exceeded_time", eviction_exceeded_current_us() / 1000)
	info_line_int(b, "keyspace_hits", srv.stat_hits)
	info_line_int(b, "keyspace_misses", srv.stat_misses)
	info_line_int(b, "pubsub_channels", i64(len(ps_maps[.Channel])))
	info_line_int(b, "pubsub_patterns", i64(len(ps_maps[.Pattern])))
	info_line_int(b, "pubsubshard_channels", i64(len(ps_maps[.Shard])))
	info_line_int(b, "latest_fork_usec", pst.latest_fork_usec)
	info_line_int(b, "total_forks", pst.total_forks)
	info_line_int(b, "migrate_cached_sockets", i64(migrate_cached_count()))
	info_line_int(b, "slave_expires_tracked_keys", 0)
	info_line_int(b, "active_defrag_hits", 0)
	info_line_int(b, "active_defrag_misses", 0)
	info_line_int(b, "active_defrag_key_hits", 0)
	info_line_int(b, "active_defrag_key_misses", 0)
	info_line_int(b, "total_active_defrag_time", 0)
	info_line_int(b, "current_active_defrag_time", 0)
	tracking_info_stats(b)
	info_line_int(b, "unexpected_error_replies", stat_unexpected_error_replies)
	info_line_int(b, "total_error_replies", stat_total_error_replies)
	info_line_int(b, "dump_payload_sanitizations", stat_dump_sanitizations)
	info_line_int(b, "total_reads_processed", stat_reads_processed)
	info_line_int(b, "total_writes_processed", stat_writes_processed)
	info_line_int(b, "io_threaded_reads_processed", 0)
	info_line_int(b, "io_threaded_writes_processed", 0)
	info_line_int(b, "client_query_buffer_limit_disconnections", stat_qbuf_limit_disconnections)
	info_line_int(b, "client_output_buffer_limit_disconnections", stat_obuf_disconnections)
	info_line_int(b, "reply_buffer_shrinks", stat_reply_buffer_shrinks)
	info_line_int(b, "reply_buffer_expands", stat_reply_buffer_expands)
	info_line_int(b, "eventloop_cycles", el_cycles)
	info_line_int(b, "eventloop_duration_sum", el_ticks_us(el_sum_ticks))
	info_line_int(b, "eventloop_duration_cmd_sum", stat_el_cmd_sum)
	info_line_int(b, "instantaneous_eventloop_cycles_per_sec", inst_get(.El_Cycle))
	info_line_int(b, "instantaneous_eventloop_duration_usec", inst_get(.El_Duration))
	info_line_int(b, "acl_access_denied_auth", acl_denied[.Auth_Failed])
	info_line_int(b, "acl_access_denied_cmd", acl_denied[.Command_Denied])
	info_line_int(b, "acl_access_denied_key", acl_denied[.Key_Denied])
	info_line_int(b, "acl_access_denied_channel", acl_denied[.Channel_Denied])
}

@(private = "file")
info_replication :: proc(b: ^[dynamic]u8) {
	info_section_header(b, "Replication")
	info_line_str(b, "role", "master")
	info_line_int(b, "connected_slaves", 0)
	info_line_str(b, "master_failover_state", "no-failover")
	id, id2 := replication_ids()
	sb_str(b, "master_replid:")
	sb_bytes(b, id)
	sb_str(b, "\r\nmaster_replid2:")
	sb_bytes(b, id2)
	sb_str(b, "\r\n")
	info_line_int(b, "master_repl_offset", 0)
	info_line_int(b, "second_repl_offset", -1)
	info_line_int(b, "repl_backlog_active", 0)
	info_line_int(b, "repl_backlog_size", cfg.repl_backlog_size)
	info_line_int(b, "repl_backlog_first_byte_offset", 0)
	info_line_int(b, "repl_backlog_histlen", 0)
}

@(private = "file")
info_rusage_line :: proc(b: ^[dynamic]u8, name: string, tv: linux.Time_Val) {
	sb_str(b, name)
	sb_byte(b, ':')
	sb_int(b, i64(tv.seconds))
	sb_byte(b, '.')
	us := i64(tv.microseconds)
	digits: [6]u8
	for i := 5; i >= 0; i -= 1 {
		digits[i] = u8('0' + us % 10)
		us /= 10
	}
	sb_bytes(b, digits[:])
	sb_str(b, "\r\n")
}

@(private = "file")
info_cpu :: proc(b: ^[dynamic]u8) {
	self, children, thread: linux.RUsage
	linux.getrusage(.SELF, &self)
	linux.getrusage(.CHILDREN, &children)
	linux.getrusage(.THREAD, &thread)
	info_section_header(b, "CPU")
	info_rusage_line(b, "used_cpu_sys", self.stime)
	info_rusage_line(b, "used_cpu_user", self.utime)
	info_rusage_line(b, "used_cpu_sys_children", children.stime)
	info_rusage_line(b, "used_cpu_user_children", children.utime)
	info_rusage_line(b, "used_cpu_sys_main_thread", thread.stime)
	info_rusage_line(b, "used_cpu_user_main_thread", thread.utime)
}

@(private = "file")
info_keyspace :: proc(b: ^[dynamic]u8) {
	info_section_header(b, "Keyspace")
	if labels_on {
		for i in 0 ..< len(dbs) {
			keys, expires, avg_ttl, subexpiry := label_keyspace_line(i)
			if keys <= 0 {
				continue
			}
			sb_str(b, "db")
			sb_int(b, i64(i))
			sb_str(b, ":keys=")
			sb_int(b, i64(keys))
			sb_str(b, ",expires=")
			sb_int(b, i64(expires))
			sb_str(b, ",avg_ttl=")
			sb_int(b, avg_ttl)
			sb_str(b, ",subexpiry=")
			sb_int(b, i64(subexpiry))
			sb_str(b, "\r\n")
		}
		return
	}
	for &d in dbs {
		keys := db_size_of(&d)
		if keys == 0 {
			continue
		}
		sb_str(b, "db")
		sb_int(b, i64(d.id))
		sb_str(b, ":keys=")
		sb_int(b, i64(keys))
		sb_str(b, ",expires=")
		sb_int(b, i64(d.expires))
		sb_str(b, ",avg_ttl=")
		sb_int(b, d.avg_ttl)
		sb_str(b, ",subexpiry=")
		sb_int(b, i64(hash_subexpiry(&d)))
		sb_str(b, "\r\n")
	}
}

@(private = "file")
info_debug :: proc(b: ^[dynamic]u8) {
	info_section_header(b, "Debug")
	info_line_int(b, "eventloop_duration_aof_sum", el_aof_sum)
	info_line_int(b, "eventloop_duration_cron_sum", el_cron_sum)
	info_line_int(b, "eventloop_duration_max", el_ticks_us(el_max_ticks))
	info_line_int(b, "eventloop_cmd_per_cycle_max", el_cmd_per_cycle_max)
	info_line_int(b, "allocator_allocated_lua", 0)
	info_line_int(b, "allocator_active_lua", 0)
	info_line_int(b, "allocator_resident_lua", 0)
	info_line_int(b, "allocator_frag_bytes_lua", 0)
}

info_select :: proc(argv: [][]u8) -> bit_set[Info_Section] {
	if len(argv) == 1 {
		return INFO_DEFAULT
	}
	want: bit_set[Info_Section]
	for i in 1 ..< len(argv) {
		a := argv[i]
		switch {
		case eq_nocase(a, "default"):
			want += INFO_DEFAULT
		case eq_nocase(a, "all"), eq_nocase(a, "everything"):
			want += INFO_ALL
		case eq_nocase(a, "module_list"):
			want += {.Modules}
		case:
			for name, s in info_section_names {
				if eq_nocase(a, name) {
					want += {s}
				}
			}
		}
	}
	return want
}

info_generate :: proc(b: ^[dynamic]u8, want: bit_set[Info_Section]) {
	if .Server in want {
		info_server(b)
	}
	if .Clients in want {
		info_clients(b)
	}
	if .Memory in want {
		info_memory(b)
	}
	if .Persistence in want {
		persist_info(b)
	}
	if .Stats in want {
		info_stats(b)
	}
	if .Replication in want {
		info_replication(b)
	}
	if .Cpu in want {
		info_cpu(b)
	}
	if .Modules in want {
		info_section_header(b, "Modules")
	}
	if .Commandstats in want {
		info_section_header(b, "Commandstats")
		info_commandstats(b)
	}
	if .Errorstats in want {
		info_section_header(b, "Errorstats")
		info_errorstats(b)
	}
	if .Latencystats in want {
		info_section_header(b, "Latencystats")
		if cfg.latency_tracking {
			info_latencystats(b)
		}
	}
	if .Cluster in want {
		info_section_header(b, "Cluster")
		info_line_int(b, "cluster_enabled", 0)
	}
	if .Keyspace in want {
		info_keyspace(b)
	}
	if .Owners in want && owners_on && access.top {
		info_owners(b)
	}
	if .Debug in want {
		info_debug(b)
	}
}

@(private = "file")
info_owners :: proc(b: ^[dynamic]u8) {
	totals := keyspace_owners_totals()
	info_section_header(b, "Owners")
	info_line_int(b, "owners_known", i64(owner_count()))
	info_line_int(b, "owners_holding_data", totals.holding)
	info_line_int(b, "owner_partitions", totals.partitions)
	info_line_int(b, "owner_bytes", totals.bytes)
}

cmd_info :: proc(c: ^Conn, argv: [][]u8) {
	b := &scratch
	clear(b)
	info_generate(b, info_select(argv))
	if labels_on && !access.top {
		info_redact(b)
	}
	reply_verbatim(c, b[:])
}

@(private = "file")
info_redact_value :: proc(out: ^[dynamic]u8, value: []u8) {
	digits, dots, other := 0, 0, 0
	for ch, i in value {
		switch {
		case ch >= '0' && ch <= '9':
			digits += 1
		case ch == '.':
			dots += 1
		case ch == '-' && i == 0:
		case:
			other += 1
		}
	}
	last := value[len(value) - 1] if len(value) > 0 else 0
	switch {
	case digits > 0 && other == 0:
		sb_str(out, "0.00" if dots > 0 else "0")
	case digits > 0 && other == 1 && last == '%':
		sb_str(out, "0.00%")
	case digits > 0 && other == 1 && (last == 'B' || last == 'K' || last == 'M' || last == 'G' || last == 'T' || last == 'P'):
		sb_str(out, "0B")
	case:
		sb_bytes(out, value)
	}
}

info_redact :: proc(b: ^[dynamic]u8) {
	text := make([]u8, len(b), context.temp_allocator)
	copy(text, b[:])
	clear(b)
	section := ""
	clients := 0
	for other in srv.conns {
		if other != nil && access_sees_conn(other) {
			clients += 1
		}
	}
	start := 0
	for start < len(text) {
		stop := start
		for stop < len(text) && text[stop] != '\n' {
			stop += 1
		}
		line := text[start:stop]
		next := min(stop + 1, len(text))
		start = next
		body := line[:len(line) - 1] if len(line) > 0 && line[len(line) - 1] == '\r' else line
		if len(body) > 2 && body[0] == '#' && body[1] == ' ' {
			section = string(body[2:])
			sb_bytes(b, text[stop - len(line):next])
			continue
		}
		colon := -1
		for ch, i in body {
			if ch == ':' {
				colon = i
				break
			}
		}
		switch section {
		case "Clients", "Memory", "Persistence", "Stats", "Replication", "CPU":
		case "Commandstats", "Errorstats", "Latencystats", "Debug":
			if colon >= 0 {
				continue
			}
			sb_bytes(b, text[stop - len(line):next])
			continue
		case:
			sb_bytes(b, text[stop - len(line):next])
			continue
		}
		if colon < 0 {
			sb_bytes(b, text[stop - len(line):next])
			continue
		}
		name := body[:colon]
		sb_bytes(b, body[:colon + 1])
		if string(name) == "connected_clients" {
			sb_int(b, i64(clients))
		} else {
			info_redact_value(b, body[colon + 1:])
		}
		sb_bytes(b, line[len(body):])
		if next > stop {
			sb_byte(b, '\n')
		}
	}
}
