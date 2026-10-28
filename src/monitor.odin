package main

import "base:intrinsics"

ERR_MONITOR_DENY_BLOCKING :: "ERR MONITOR isn't allowed for DENY BLOCKING client"
ERR_REPLICA_KEYSPACE :: "ERR Replica can't interact with the keyspace"
REDACTED :: "(redacted)"

monitors: [dynamic]^Conn

@(private = "file")
monitor_buf: [dynamic]u8
@(private = "file")
monitor_redact: [dynamic]int

cmd_monitor :: proc(c: ^Conn, argv: [][]u8) {
	if deny_blocking {
		reply_error(c, ERR_MONITOR_DENY_BLOCKING)
		return
	}
	if .Monitor in c.flags {
		return
	}
	c.flags += {.Monitor}
	append(&monitors, c)
	hooks_update()
	reply_ok(c)
}

@(cold)
monitor_remove :: #force_no_inline proc(c: ^Conn) {
	c.flags -= {.Monitor}
	for m, i in monitors {
		if m == c {
			ordered_remove(&monitors, i)
			break
		}
	}
	hooks_update()
}

@(cold)
monitor_rejects :: #force_no_inline proc(c: ^Conn, cmd: ^Command, argv: [][]u8) -> bool {
	spec := cmd_spec_lookup(cmd, argv)
	if spec == nil || spec.flags & {.Readonly, .Write, .May_Replicate} == {} {
		return false
	}
	reply_error(c, ERR_REPLICA_KEYSPACE)
	tx_flag(c)
	return true
}

@(private = "file")
monitor_skips :: proc(cmd: ^Command, argv: [][]u8) -> bool {
	if block_in_reexecution() {
		return true
	}
	spec := cmd_spec_lookup(cmd, argv)
	if spec == nil {
		return len(argv) >= 2 && cmd_spec_lookup(cmd, argv[:1]) != nil
	}
	if spec.flags & {.Admin, .Skip_Monitor} != {} {
		return true
	}
	return !arity_ok(int(spec.arity), len(argv))
}

@(cold)
monitor_feed :: #force_no_inline proc(c: ^Conn, cmd: ^Command, argv: [][]u8) {
	if monitor_skips(cmd, argv) {
		return
	}
	command_redactions(cmd, argv, &monitor_redact)
	monitor_emit(c, argv, monitor_redact[:])
}

@(cold)
monitor_feed_raw :: #force_no_inline proc(c: ^Conn, argv: [][]u8) {
	if len(monitors) == 0 {
		return
	}
	monitor_emit(c, argv, nil)
}

@(private = "file")
monitor_emit :: proc(c: ^Conn, argv: [][]u8, redacted: []int) {
	b := &monitor_buf
	clear(b)
	sec, usec := now_realtime()
	sb_byte(b, '+')
	sb_int(b, sec)
	sb_byte(b, '.')
	for div := i64(100000); div > 0; div /= 10 {
		sb_byte(b, u8('0' + (usec / div) % 10))
	}
	sb_str(b, " [")
	sb_int(b, i64(c.db.id))
	sb_byte(b, ' ')
	sb_bytes(b, c.addr[:c.addr_len])
	sb_str(b, "] ")
	r := 0
	for a, i in argv {
		if i > 0 {
			sb_byte(b, ' ')
		}
		if r < len(redacted) && redacted[r] == i {
			sds_repr(b, transmute([]u8)string(REDACTED))
			r += 1
		} else {
			sds_repr(b, a)
		}
	}
	sb_str(b, "\r\n")
	n := len(b)
	for m in monitors {
		if m.close_after || m.reply & {.Off, .Held} != {} {
			continue
		}
		p := wb_reserve(m, n)
		intrinsics.mem_copy_non_overlapping(p, raw_data(b^), n)
		m.wlen += n
		if m != c && !m.want_write {
			epoll_set(m.fd, .MOD, true, m.id)
			m.want_write = true
		}
		if client_buckets_on {
			client_bucket_track(m)
		}
	}
}

@(private = "file")
SENSITIVE_CONFIGS := [?]string{"masterauth", "masteruser", "requirepass", "tls-key-file-pass", "tls-client-key-file-pass"}

@(private = "file")
config_is_sensitive :: proc(name: []u8) -> bool {
	for s in SENSITIVE_CONFIGS {
		if eq_nocase(name, s) {
			return true
		}
	}
	return false
}

command_redactions :: proc(cmd: ^Command, argv: [][]u8, out: ^[dynamic]int) {
	clear(out)
	n := len(argv)
	switch cmd.handler {
	case cmd_auth:
		if n > 3 {
			return
		}
		append(out, 1)
		if n == 3 {
			append(out, 2)
		}
	case cmd_hello:
		if n < 2 {
			return
		}
		ver, ok := parse_i64(argv[1])
		if !ok || ver < RESP2 || ver > RESP3 {
			return
		}
		for j := 2; j < n; j += 1 {
			more := n - 1 - j
			if eq_nocase(argv[j], "auth") && more >= 2 {
				append(out, j + 1, j + 2)
				j += 2
			} else if eq_nocase(argv[j], "setname") && more >= 1 {
				if !valid_client_name(argv[j + 1]) {
					return
				}
				j += 1
			} else {
				return
			}
		}
	case cmd_migrate:
		for j := 6; j < n; j += 1 {
			more := n - 1 - j
			a := argv[j]
			switch {
			case eq_nocase(a, "copy"), eq_nocase(a, "replace"):
			case eq_nocase(a, "auth"):
				if more == 0 {
					return
				}
				j += 1
				append(out, j)
			case eq_nocase(a, "auth2"):
				if more < 2 {
					return
				}
				append(out, j + 1, j + 2)
				j += 2
			case:
				return
			}
		}
	case cmd_config:
		if n < 4 || n % 2 != 0 || !eq_nocase(argv[1], "set") {
			return
		}
		for j := 2; j + 1 < n; j += 2 {
			if config_is_sensitive(argv[j]) {
				append(out, j + 1)
			}
		}
	}
}

@(private = "file")
monitor_commands := [?]Command{{"monitor", cmd_monitor, 1}}

@(init)
register_monitor_commands :: proc "contextless" () {
	register_commands(monitor_commands[:])
}
