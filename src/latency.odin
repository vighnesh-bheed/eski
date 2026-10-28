package main

import "base:runtime"
import "core:sys/linux"
import "hdr"

LATENCY_TS_LEN :: 160
LATENCY_GRAPH_COLS :: 80

@(private = "file")
Latency_Sample :: struct {
	time:    i32,
	latency: u32,
}

@(private = "file")
Latency_Series :: struct {
	name:    string,
	idx:     int,
	max:     u32,
	samples: [LATENCY_TS_LEN]Latency_Sample,
}

@(private = "file")
Latency_Stats :: struct {
	all_time_high: u32,
	avg:           u32,
	min:           u32,
	max:           u32,
	mad:           u32,
	samples:       u32,
	period:        i64,
}

@(private = "file")
latency_events: [dynamic]^Latency_Series

stat_fork_rate: f64

@(private = "file")
latency_now :: proc() -> i64 {
	sec, _ := now_realtime()
	return sec
}

@(private = "file")
latency_find :: proc(name: []u8) -> ^Latency_Series {
	for ts in latency_events {
		if ts.name == string(name) {
			return ts
		}
	}
	return nil
}

latency_add_sample :: proc(event: string, latency: i64) {
	ts := latency_find(transmute([]u8)event)
	now := i32(latency_now())
	if ts == nil {
		ts = new(Latency_Series)
		ts.name = event
		append(&latency_events, ts)
	}
	lat := u32(clamp(latency, 0, i64(max(u32))))
	if lat > ts.max {
		ts.max = lat
	}
	prev := (ts.idx + LATENCY_TS_LEN - 1) % LATENCY_TS_LEN
	if ts.samples[prev].time == now {
		if lat > ts.samples[prev].latency {
			ts.samples[prev].latency = lat
		}
		return
	}
	ts.samples[ts.idx] = {now, lat}
	ts.idx += 1
	if ts.idx == LATENCY_TS_LEN {
		ts.idx = 0
	}
}

latency_add_if_needed :: #force_inline proc(event: string, ms: i64) {
	if cfg.latency_monitor_threshold != 0 && ms >= cfg.latency_monitor_threshold {
		latency_add_sample(event, ms)
	}
}

latency_start :: #force_inline proc() -> i64 {
	if cfg.latency_monitor_threshold != 0 {
		return now_ns()
	}
	return 0
}

latency_end :: #force_inline proc(event: string, start: i64) {
	if cfg.latency_monitor_threshold != 0 && start != 0 {
		latency_add_if_needed(event, (now_ns() - start) / 1_000_000)
	}
}

@(cold)
latency_note_expire_del :: #force_no_inline proc "contextless" (start: i64) {
	context = runtime.default_context()
	latency_add_if_needed("expire-del", (now_ns() - start) / 1_000_000)
}

latency_note_fork :: proc(fork_usec: i64) {
	if fork_usec > 0 {
		stat_fork_rate = f64(mem_used()) * 1_000_000 / f64(fork_usec) / (1024 * 1024 * 1024)
	}
	latency_add_if_needed("fork", fork_usec / 1000)
}

@(private = "file")
latency_reset_event :: proc(name: []u8) -> int {
	resets := 0
	for i := 0; i < len(latency_events); {
		ts := latency_events[i]
		if name == nil || eq_nocase(name, ts.name) {
			ordered_remove(&latency_events, i)
			free(ts)
			resets += 1
			continue
		}
		i += 1
	}
	return resets
}

@(private = "file")
latency_analyze :: proc(ts: ^Latency_Series) -> (ls: Latency_Stats) {
	ls.all_time_high = ts.max
	sum: u64 = 0
	for s in ts.samples {
		if s.time == 0 {
			continue
		}
		ls.samples += 1
		if ls.samples == 1 {
			ls.min = s.latency
			ls.max = s.latency
		} else {
			ls.min = min(ls.min, s.latency)
			ls.max = max(ls.max, s.latency)
		}
		sum += u64(s.latency)
		if ls.period == 0 || i64(s.time) < ls.period {
			ls.period = i64(s.time)
		}
	}
	if ls.samples > 0 {
		ls.avg = u32(sum / u64(ls.samples))
		ls.period = latency_now() - ls.period
		if ls.period == 0 {
			ls.period = 1
		}
	}
	sum = 0
	for s in ts.samples {
		if s.time == 0 {
			continue
		}
		delta := i64(ls.avg) - i64(s.latency)
		if delta < 0 {
			delta = -delta
		}
		sum += u64(delta)
	}
	if ls.samples > 0 {
		ls.mad = u32(sum / u64(ls.samples))
	}
	return
}

@(private = "file")
latency_thp_bytes :: proc() -> i64 {
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
	key := "AnonHugePages:"
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

@(private = "file")
Advice :: enum {
	Better_Vm,
	Slowlog_Enabled,
	Slowlog_Tuning,
	Slowlog_Inspect,
	Disk_Contention,
	Scheduler,
	Data_Writeback,
	No_Appendfsync,
	Local_Disk,
	Ssd,
	Write_Load_Info,
	Hz,
	Large_Objects,
	Mass_Eviction,
	Relax_Fsync_Policy,
	Disable_Thp,
}

@(private = "file")
latency_report :: proc(b: ^[dynamic]u8) {
	if len(latency_events) == 0 && cfg.latency_monitor_threshold == 0 {
		sb_str(b, "I'm sorry, Dave, I can't do that. Latency monitoring is disabled in this Redis instance. You may use \"CONFIG SET latency-monitor-threshold <milliseconds>.\" in order to enable it. If we weren't in a deep space mission I'd suggest to take a look at https://redis.io/topics/latency-monitor.\n")
		return
	}
	adv: bit_set[Advice]
	advices := 0
	eventnum := 0
	for ts in latency_events {
		eventnum += 1
		if eventnum == 1 {
			sb_str(b, "Dave, I have observed latency spikes in this Redis instance. You don't mind talking about it, do you Dave?\n\n")
		}
		ls := latency_analyze(ts)
		sb_int(b, i64(eventnum))
		sb_str(b, ". ")
		sb_str(b, ts.name)
		sb_str(b, ": ")
		sb_int(b, i64(ls.samples))
		sb_str(b, " latency spikes (average ")
		sb_int(b, i64(ls.avg))
		sb_str(b, "ms, mean deviation ")
		sb_int(b, i64(ls.mad))
		sb_str(b, "ms, period ")
		sb_fixed(b, f64(ls.period) / f64(ls.samples))
		sb_str(b, " sec). Worst all time event ")
		sb_int(b, i64(ts.max))
		sb_str(b, "ms.")
		name := transmute([]u8)ts.name
		if eq_nocase(name, "fork") {
			quality: string
			switch {
			case stat_fork_rate < 10:
				quality = "terrible"
				adv += {.Better_Vm}
				advices += 1
			case stat_fork_rate < 25:
				quality = "poor"
				adv += {.Better_Vm}
				advices += 1
			case stat_fork_rate < 100:
				quality = "good"
			case:
				quality = "excellent"
			}
			sb_str(b, " Fork rate is ")
			sb_fixed(b, stat_fork_rate)
			sb_str(b, " GB/sec (")
			sb_str(b, quality)
			sb_str(b, ").")
		}
		if eq_nocase(name, "command") {
			if cfg.slowlog_log_slower_than < 0 || cfg.slowlog_max_len == 0 {
				adv += {.Slowlog_Enabled}
				advices += 1
			} else if cfg.slowlog_log_slower_than / 1000 > cfg.latency_monitor_threshold {
				adv += {.Slowlog_Tuning}
				advices += 1
			}
			adv += {.Slowlog_Inspect, .Large_Objects}
			advices += 2
		}
		if eq_nocase(name, "fast-command") {
			adv += {.Scheduler}
			advices += 1
		}
		if eq_nocase(name, "aof-write-pending-fsync") {
			adv += {.Local_Disk, .Disk_Contention, .Ssd, .Data_Writeback}
			advices += 4
		}
		if eq_nocase(name, "aof-write-active-child") {
			adv += {.No_Appendfsync, .Data_Writeback, .Ssd}
			advices += 3
		}
		if eq_nocase(name, "aof-write-alone") {
			adv += {.Local_Disk, .Data_Writeback, .Ssd}
			advices += 3
		}
		if eq_nocase(name, "aof-fsync-always") {
			adv += {.Relax_Fsync_Policy}
			advices += 1
		}
		if eq_nocase(name, "aof-fstat") || eq_nocase(name, "rdb-unlink-temp-file") {
			adv += {.Disk_Contention, .Local_Disk}
			advices += 2
		}
		if eq_nocase(name, "aof-rewrite-diff-write") || eq_nocase(name, "aof-rename") {
			adv += {.Write_Load_Info, .Data_Writeback, .Ssd, .Local_Disk}
			advices += 4
		}
		if eq_nocase(name, "expire-cycle") {
			adv += {.Hz, .Large_Objects}
			advices += 2
		}
		if eq_nocase(name, "eviction-del") {
			adv += {.Large_Objects}
			advices += 1
		}
		if eq_nocase(name, "eviction-cycle") {
			adv += {.Mass_Eviction}
			advices += 1
		}
		sb_byte(b, '\n')
	}
	if latency_thp_bytes() > 0 {
		adv += {.Disable_Thp}
		advices += 1
	}
	if eventnum == 0 && advices == 0 {
		sb_str(b, "Dave, no latency spike was observed during the lifetime of this Redis instance, not in the slightest bit. I honestly think you ought to sit down calmly, take a stress pill, and think things over.\n")
		return
	}
	if eventnum > 0 && advices == 0 {
		sb_str(b, "\nWhile there are latency events logged, I'm not able to suggest any easy fix. Please use the Redis community to get some help, providing this report in your help request.\n")
		return
	}
	sb_str(b, "\nI have a few advices for you:\n\n")
	if .Better_Vm in adv {
		sb_str(b, "- If you are using a virtual machine, consider upgrading it with a faster one using a hypervisior that provides less latency during fork() calls. Xen is known to have poor fork() performance. Even in the context of the same VM provider, certain kinds of instances can execute fork faster than others.\n")
	}
	if .Slowlog_Enabled in adv {
		sb_str(b, "- There are latency issues with potentially slow commands you are using. Try to enable the Slow Log Redis feature using the command 'CONFIG SET slowlog-log-slower-than ")
		sb_int(b, cfg.latency_monitor_threshold * 1000)
		sb_str(b, "'. If the Slow log is disabled Redis is not able to log slow commands execution for you.\n")
	}
	if .Slowlog_Tuning in adv {
		sb_str(b, "- Your current Slow Log configuration only logs events that are slower than your configured latency monitor threshold. Please use 'CONFIG SET slowlog-log-slower-than ")
		sb_int(b, cfg.latency_monitor_threshold * 1000)
		sb_str(b, "'.\n")
	}
	if .Slowlog_Inspect in adv {
		sb_str(b, "- Check your Slow Log to understand what are the commands you are running which are too slow to execute. Please check https://redis.io/commands/slowlog for more information.\n")
	}
	if .Scheduler in adv {
		sb_str(b, "- The system is slow to execute Redis code paths not containing system calls. This usually means the system does not provide Redis CPU time to run for long periods. You should try to:\n  1) Lower the system load.\n  2) Use a computer / VM just for Redis if you are running other software in the same system.\n  3) Check if you have a \"noisy neighbour\" problem.\n  4) Check with 'redis-cli --intrinsic-latency 100' what is the intrinsic latency in your system.\n  5) Check if the problem is allocator-related by recompiling Redis with MALLOC=libc, if you are using Jemalloc. However this may create fragmentation problems.\n")
	}
	if .Local_Disk in adv {
		sb_str(b, "- It is strongly advised to use local disks for persistence, especially if you are using AOF. Remote disks provided by platform-as-a-service providers are known to be slow.\n")
	}
	if .Ssd in adv {
		sb_str(b, "- SSD disks are able to reduce fsync latency, and total time needed for snapshotting and AOF log rewriting (resulting in smaller memory usage). With extremely high write load SSD disks can be a good option. However Redis should perform reasonably with high load using normal disks. Use this advice as a last resort.\n")
	}
	if .Data_Writeback in adv {
		sb_str(b, "- Mounting ext3/4 filesystems with data=writeback can provide a performance boost compared to data=ordered, however this mode of operation provides less guarantees, and sometimes it can happen that after a hard crash the AOF file will have a half-written command at the end and will require to be repaired before Redis restarts.\n")
	}
	if .Disk_Contention in adv {
		sb_str(b, "- Try to lower the disk contention. This is often caused by other disk intensive processes running in the same computer (including other Redis instances).\n")
	}
	if .No_Appendfsync in adv {
		sb_str(b, "- Assuming from the point of view of data safety this is viable in your environment, you could try to enable the 'no-appendfsync-on-rewrite' option, so that fsync will not be performed while there is a child rewriting the AOF file or producing an RDB file (the moment where there is high disk contention).\n")
	}
	if .Relax_Fsync_Policy in adv && aof.fsync == .Always {
		sb_str(b, "- Your fsync policy is set to 'always'. It is very hard to get good performances with such a setup, if possible try to relax the fsync policy to 'onesec'.\n")
	}
	if .Write_Load_Info in adv {
		sb_str(b, "- Latency during the AOF atomic rename operation or when the final difference is flushed to the AOF file at the end of the rewrite, sometimes is caused by very high write load, causing the AOF buffer to get very large. If possible try to send less commands to accomplish the same work, or use Lua scripts to group multiple operations into a single EVALSHA call.\n")
	}
	if .Hz in adv && config_hz_current < 100 {
		sb_str(b, "- In order to make the Redis keys expiring process more incremental, try to set the 'hz' configuration parameter to 100 using 'CONFIG SET hz 100'.\n")
	}
	if .Large_Objects in adv {
		sb_str(b, "- Deleting, expiring or evicting (because of maxmemory policy) large objects is a blocking operation. If you have very large objects that are often deleted, expired, or evicted, try to fragment those objects into multiple smaller objects.\n")
	}
	if .Mass_Eviction in adv {
		sb_str(b, "- Sudden changes to the 'maxmemory' setting via 'CONFIG SET', or allocation of large objects via sets or sorted sets intersections, STORE option of SORT, Redis Cluster large keys migrations (RESTORE command), may create sudden memory pressure forcing the server to block trying to evict keys. \n")
	}
	if .Disable_Thp in adv {
		sb_str(b, "- I detected a non zero amount of anonymous huge pages used by your process. This creates very serious latency events in different conditions, especially when Redis is persisting on disk. To disable THP support use the command 'echo never > /sys/kernel/mm/transparent_hugepage/enabled', make sure to also add it into /etc/rc.local so that the command will be executed again after a reboot. Note that even if you have already disabled THP, you still need to restart the Redis process to get rid of the huge pages already created.\n")
	}
}

@(private = "file")
Sparkline_Sample :: struct {
	value: f64,
	label: string,
}

@(private = "file")
SPARK_CHARSET_FILL :: "_o#"
@(private = "file")
SPARK_LABEL_MARGIN_TOP :: 1

@(private = "file")
sparkline_render_range :: proc(b: ^[dynamic]u8, seq: []Sparkline_Sample, labels: int, lo: f64, hi: f64, rows: int, offset: int, n: int) {
	relmax := hi - lo
	charset := SPARK_CHARSET_FILL
	charset_len := len(charset)
	steps := charset_len * rows
	row := 0
	chars := make([]u8, n, context.temp_allocator)
	if relmax == 0 {
		relmax = 1
	}
	loop := true
	for loop {
		loop = false
		for j in 0 ..< n {
			chars[j] = ' '
		}
		for j in 0 ..< n {
			s := seq[j + offset]
			relval := s.value - lo
			step := int(f64(int(relval * f64(steps))) / relmax)
			if step < 0 {
				step = 0
			}
			if step >= steps {
				step = steps - 1
			}
			if row < rows {
				charidx := step - ((rows - row - 1) * charset_len)
				loop = true
				if charidx >= 0 && charidx < charset_len {
					chars[j] = charset[charidx]
				} else if charidx >= charset_len {
					chars[j] = '|'
				}
			} else {
				if labels > 0 && row - rows < SPARK_LABEL_MARGIN_TOP {
					loop = true
					break
				}
				if len(s.label) > 0 {
					label_char := row - rows - SPARK_LABEL_MARGIN_TOP
					if len(s.label) > label_char {
						loop = true
						chars[j] = s.label[label_char]
					}
				}
			}
		}
		if loop {
			row += 1
			sb_bytes(b, chars)
			sb_byte(b, '\n')
		}
	}
}

@(private = "file")
latency_graph :: proc(b: ^[dynamic]u8, ts: ^Latency_Series) {
	seq := make([dynamic]Sparkline_Sample, context.temp_allocator)
	lo, hi: u32
	seq_lo, seq_hi: f64
	labels := 0
	now := latency_now()
	for j in 0 ..< LATENCY_TS_LEN {
		s := ts.samples[(ts.idx + j) % LATENCY_TS_LEN]
		if s.time == 0 {
			continue
		}
		if len(seq) == 0 {
			lo = s.latency
			hi = s.latency
		} else {
			hi = max(hi, s.latency)
			lo = min(lo, s.latency)
		}
		elapsed := now - i64(s.time)
		lb := make([dynamic]u8, context.temp_allocator)
		switch {
		case elapsed < 60:
			sb_int(&lb, elapsed)
			sb_byte(&lb, 's')
		case elapsed < 3600:
			sb_int(&lb, elapsed / 60)
			sb_byte(&lb, 'm')
		case elapsed < 3600 * 24:
			sb_int(&lb, elapsed / 3600)
			sb_byte(&lb, 'h')
		case:
			sb_int(&lb, elapsed / (3600 * 24))
			sb_byte(&lb, 'd')
		}
		v := f64(s.latency)
		if len(seq) == 0 {
			seq_lo = v
			seq_hi = v
		} else if v < seq_lo {
			seq_lo = v
		} else if v > seq_hi {
			seq_hi = v
		}
		append(&seq, Sparkline_Sample{v, string(lb[:])})
		labels += 1
	}
	sb_str(b, ts.name)
	sb_str(b, " - high ")
	sb_int(b, i64(hi))
	sb_str(b, " ms, low ")
	sb_int(b, i64(lo))
	sb_str(b, " ms (all time high ")
	sb_int(b, i64(ts.max))
	sb_str(b, " ms)\n")
	for _ in 0 ..< LATENCY_GRAPH_COLS {
		sb_byte(b, '-')
	}
	sb_byte(b, '\n')
	for j := 0; j < len(seq); j += LATENCY_GRAPH_COLS {
		sublen := min(len(seq) - j, LATENCY_GRAPH_COLS)
		if j != 0 {
			sb_byte(b, '\n')
		}
		sparkline_render_range(b, seq[:], labels, seq_lo, seq_hi, 4, j, sublen)
	}
}

@(private = "file")
latency_fill_cdf :: proc(c: ^Conn, h: ^hdr.Histogram) {
	reply_map(c, 2)
	reply_bulk_str(c, "calls")
	reply_int(c, h.total_count)
	reply_bulk_str(c, "histogram_usec")
	pairs := make([dynamic][2]i64, context.temp_allocator)
	it: hdr.Iter
	hdr.iter_log_init(&it, h, 1024, 2)
	previous: i64 = 0
	for hdr.iter_next(&it) {
		micros := it.highest_equivalent_value / 1000
		cumulative := it.cumulative_count
		if cumulative > previous {
			append(&pairs, [2]i64{micros, cumulative})
		}
		previous = cumulative
	}
	reply_map(c, len(pairs))
	for p in pairs {
		reply_int(c, p[0])
		reply_int(c, p[1])
	}
}

@(private = "file")
latency_histogram :: proc(c: ^Conn, argv: [][]u8) {
	stats_fold()
	found := make([dynamic]^Cmd_Stats, context.temp_allocator)
	if len(argv) == 2 {
		for &st in stat_each() {
			if st.hist != nil {
				append(&found, &st)
			}
			for &s in st.subs {
				if s.stats.hist != nil {
					append(&found, &s.stats)
				}
			}
		}
	} else {
		for j in 2 ..< len(argv) {
			st := stat_lookup_name(argv[j])
			if st == nil {
				continue
			}
			if st.hist != nil {
				append(&found, st)
			}
			for &s in st.subs {
				if s.stats.hist != nil {
					append(&found, &s.stats)
				}
			}
		}
	}
	reply_map(c, len(found))
	for st in found {
		reply_bulk_str(c, st.name)
		latency_fill_cdf(c, st.hist)
	}
}

@(private = "file")
latency_help := [?]string {
	"LATENCY <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"DOCTOR",
	"    Return a human readable latency analysis report.",
	"GRAPH <event>",
	"    Return an ASCII latency graph for the <event> class.",
	"HISTORY <event>",
	"    Return time-latency samples for the <event> class.",
	"LATEST",
	"    Return the latest latency samples for all events.",
	"RESET [<event> ...]",
	"    Reset latency data of one or more <event> classes.",
	"    (default: reset all data for all event classes)",
	"HISTOGRAM [COMMAND ...]",
	"    Return a cumulative distribution of latencies in the format of a histogram for the specified command names.",
	"    If no commands are specified then all histograms are replied.",
	"HELP",
	"    Print this help.",
}

cmd_latency :: proc(c: ^Conn, argv: [][]u8) {
	if container_precheck(c, argv, "latency", "LATENCY") {
		return
	}
	sub := argv[1]
	argc := len(argv)
	switch {
	case eq_nocase(sub, "history") && argc == 3:
		ts := latency_find(argv[2])
		if ts == nil {
			reply_array(c, 0)
			return
		}
		n := 0
		for s in ts.samples {
			if s.time != 0 {
				n += 1
			}
		}
		reply_array(c, n)
		for j in 0 ..< LATENCY_TS_LEN {
			s := ts.samples[(ts.idx + j) % LATENCY_TS_LEN]
			if s.time == 0 {
				continue
			}
			reply_array(c, 2)
			reply_int(c, i64(s.time))
			reply_int(c, i64(s.latency))
		}
	case eq_nocase(sub, "graph") && argc == 3:
		ts := latency_find(argv[2])
		if ts == nil {
			clear(&scratch)
			sb_str(&scratch, "ERR No samples available for event '")
			sb_bytes(&scratch, argv[2])
			sb_byte(&scratch, '\'')
			sanitize_scratch()
			reply_error_bytes(c, scratch[:])
			return
		}
		b := make([dynamic]u8, context.temp_allocator)
		latency_graph(&b, ts)
		reply_verbatim(c, b[:])
	case eq_nocase(sub, "latest") && argc == 2:
		reply_array(c, len(latency_events))
		for ts in latency_events {
			last := (ts.idx + LATENCY_TS_LEN - 1) % LATENCY_TS_LEN
			reply_array(c, 4)
			reply_bulk_str(c, ts.name)
			reply_int(c, i64(ts.samples[last].time))
			reply_int(c, i64(ts.samples[last].latency))
			reply_int(c, i64(ts.max))
		}
	case eq_nocase(sub, "doctor") && argc == 2:
		b := make([dynamic]u8, context.temp_allocator)
		latency_report(&b)
		reply_verbatim(c, b[:])
	case eq_nocase(sub, "reset") && argc >= 2:
		if argc == 2 {
			reply_int(c, i64(latency_reset_event(nil)))
			return
		}
		resets := 0
		for j in 2 ..< argc {
			resets += latency_reset_event(argv[j])
		}
		reply_int(c, i64(resets))
	case eq_nocase(sub, "histogram") && argc >= 2:
		latency_histogram(c, argv)
	case eq_nocase(sub, "help") && argc == 2:
		reply_array(c, len(latency_help))
		for line in latency_help {
			reply_simple(c, line)
		}
	case:
		reply_subcommand_syntax_error(c, sub, "LATENCY")
	}
}

@(private = "file")
latency_commands := [?]Command{{"latency", cmd_latency, -2}}

@(init)
register_latency_commands :: proc "contextless" () {
	register_commands(latency_commands[:])
}
