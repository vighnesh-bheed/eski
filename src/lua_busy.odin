package main

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:sys/linux"
import lr "lua_runtime"
import rp "request_parser"

LUA_BUSY_BUFFER :: 64 * 1024
LUA_BUSY_TEMP :: 1024 * 1024
LUA_BUSY_COMMANDS :: 16

lua_connection_time_floor: i64

Lua_Busy_State :: struct {
	scratch: rp.Scratch,
	temporary: []u8,
	arena: mem.Arena,
	next_client: int,
}

lua_wallclock_ms :: proc "contextless" () -> i64 {
	time, err := linux.clock_gettime(.REALTIME)
	if err != .NONE {
		return srv.now_ms
	}
	return i64(time.time_sec)*1000 + i64(time.time_nsec/1_000_000)
}

lua_connection_clock :: proc "contextless" () -> i64 {
	if lua_active != nil {
		lua_connection_time_floor = max(lua_connection_time_floor, lua_wallclock_ms())
	}
	return max(srv.now_ms, lua_connection_time_floor)
}

lua_busy_memory :: proc "contextless" (state: ^Lua_Busy_State) -> int {
	return len(state.temporary) + len(state.scratch.args)*size_of([]u8)
}

lua_busy_destroy :: proc(state: ^Lua_Busy_State) {
	rp.destroy(&state.scratch)
	delete(state.temporary)
	state^ = {}
}

lua_busy_authorize :: proc(client: ^Conn, cmd: ^Command, argv: [][]u8) -> bool {
	if client.acl_gate && acl_reject(client, cmd, stat_of(cmd), argv) {
		return false
	}
	return true
}

lua_busy_dispatch :: proc(client: ^Conn, argv: [][]u8) {
	if .Skip_Next in client.reply {
		client.reply = client.reply - {.Skip_Next} + {.Skip}
	}
	pending := client.wlen-client.wpos
	lua_busy_dispatch_inner(client, argv)
	if client.reply & {.Off, .Skip, .Held} != {} {
		client.wlen = client.wpos+pending
	}
	client.reply -= {.Skip}
}

lua_busy_dispatch_inner :: proc(client: ^Conn, argv: [][]u8) {
	saved := stat_cur
	stat_cur = nil
	defer stat_cur = saved
	if len(argv) == 0 {
		return
	}
	slot := lookup_entry(argv[0])
	if slot == nil {
		reply_unknown_command(client, argv)
		tx_flag(client)
		return
	}
	cmd, hot := slot.cmd, slot.stats
	if !arity_ok(cmd.arity, len(argv)) {
		execute_bad_arity(client, cmd)
		stat_reject(hot, argv)
		return
	}
	spec := cmd_spec_lookup(cmd, argv)
	if len(argv) >= 2 && len(hot.subs) > 0 {
		if spec == nil {
			upper := make([]u8, len(cmd.name), context.temp_allocator)
			for byte, i in transmute([]u8)cmd.name {
				upper[i] = byte-('a'-'A') if byte >= 'a' && byte <= 'z' else byte
			}
			reply_unknown_subcommand(client, argv[1], string(upper))
			tx_flag(client)
			stat_reject(hot, argv)
			return
		}
		if !arity_ok(int(spec.arity), len(argv)) {
			reply_wrong_args(client, spec.name)
			tx_flag(client)
			stat_reject(hot, argv)
			return
		}
	}
	if !lua_busy_authorize(client, cmd, argv) {
		tx_flag(client)
		return
	}
	if lua_active.loading && persist_gate(client, cmd, argv) {
		stat_reject(hot, argv)
		return
	}
	if spec == nil || .Allow_Busy not_in spec.flags {
		if cmd.handler == cmd_exec && .Multi in client.txf {
			tx_exec_abort(client, lua_busy_error())
		} else {
			reply_error(client, lua_busy_error())
			tx_flag(client)
		}
		stat_reject(hot, argv)
		return
	}
	if .Multi in client.txf && !tx_immediate(cmd) {
		tx_queue(client, cmd, argv)
		return
	}
	stat_cur = &hot.stats
	start := mono_now()
	client.last_cmd = cmd.name
	switch {
	case cmd.handler == cmd_script:
		lua_kill(client, false)
	case cmd.handler == cmd_function && eq_nocase(argv[1], "kill"):
		lua_kill(client, true)
	case cmd.handler == cmd_function:
		if lua_active.function {
			lua_function_stats(client)
		} else {
			stat_cur = nil
			reply_error(client, lua_busy_error())
			stat_reject(hot, argv)
			return
		}
	case cmd.handler == cmd_shutdown:
		lua_busy_shutdown(client, argv)
	case:
		cmd.handler(client, argv)
	}
	stat_call_slow(client, cmd, hot, argv, mono_now()-start)
}

lua_busy_shutdown :: proc(client: ^Conn, argv: [][]u8) {
	nosave, valid := false, true
	for arg in argv[1:] {
		switch {
		case eq_nocase(arg, "nosave"):
			nosave = true
		case eq_nocase(arg, "abort"):
			valid = false
		case eq_nocase(arg, "save"), eq_nocase(arg, "now"), eq_nocase(arg, "force"):
		case:
			valid = false
		}
	}
	if valid && !nosave {
		reply_error(client, lua_busy_error())
		return
	}
	cmd_shutdown(client, argv)
}

lua_busy_parse :: proc(state: ^Lua_Busy_State, client: ^Conn) -> (argv: [][]u8, kind: rp.Kind) {
	input := client.rbuf[client.rpos:client.rlen]
	if len(input) == 0 {
		return nil, .Incomplete
	}
	limits := rp.Limits{
		bulk_max = min(cfg.proto_max_bulk_len, LUA_BUSY_BUFFER),
		base_offset = client.rpos,
		unauthenticated = client.mbulk_max == 0,
		unauth_array_max = ACL_UNAUTH_MBULK,
		unauth_bulk_max = ACL_UNAUTH_BULK,
	}
	result: rp.Result
	if input[0] == '*' {
		end := -1
		for byte, i in input[1:min(len(input), 32)] {
			if byte == '\r' {
				end = i+1
				break
			}
		}
		if end < 0 {
			if len(input) >= 32 {
				reply_error(client, "ERR Protocol array header exceeds BUSY service limit")
				client.close_after = true
				return nil, .Error
			}
			return nil, .Incomplete
		}
		count, ok := parse_i64(input[1:end])
		if !ok || count < 0 || count > LUA_MAX_CALL_ARGS {
			reply_error(client, "ERR Protocol array count exceeds BUSY service limit")
			client.close_after = true
			return nil, .Error
		}
		result = rp.parse_array(input, &state.scratch, limits)
	} else {
		before := request_inline_memory(client)
		result = rp.parse_inline(input, &state.scratch, &client.inline_owner, limits)
		conn_mem += request_inline_memory(client)-before
	}
	switch result.kind {
	case .Command:
		client.rpos += result.consumed
		return state.scratch.args[:result.argc], .Command
	case .Incomplete:
		return nil, .Incomplete
	case .Error:
		request_parse_error(client, result.fault, result.error_byte)
		return nil, .Error
	}
	unreachable()
}

lua_busy_flush :: proc(client: ^Conn) {
	if client.lua_busy_bytes <= 0 {
		return
	}
	if client.lua_busy_bytes > client.wlen-client.wpos {
		store_fatal("Lua BUSY output ownership invariant")
	}
	if obuf_normal_limited && obuf_normal_over(client) {
		conn_close(client)
		return
	}
	n, err := conn_net_write(client, client.wbuf[client.wpos:client.wpos+client.lua_busy_bytes])
	if err != .NONE {
		if err != .EAGAIN && err != .EINTR {
			conn_close(client)
		}
		return
	}
	client.wpos += n
	client.lua_busy_bytes -= n
	client.atime_ms = max(client.atime_ms, lua_connection_clock())
	stat_writes_processed += 1
	stat_net_output_bytes += i64(n)
	if client.wpos == client.wlen {
		client.wpos, client.wlen = 0, 0
		if client.close_after {
			conn_close(client)
			return
		}
		if client.want_write {
			epoll_set(client.fd, .MOD, false, client.id)
			client.want_write = false
		}
	}
	if client.wpos < client.wlen && !client.want_write {
		epoll_set(client.fd, .MOD, true, client.id)
		client.want_write = true
	}
}

lua_busy_read :: proc(run: ^Lua_Invocation, client: ^Conn, budget: ^int) {
	if client == run.source || client.compute != nil || client.keyspace != nil || client.keyspace_ready || client.blocked != .None || client.held {
		return
	}
	if !conn_protected_ready(client) {
		if client.close_after {
			conn_flush(client)
		}
		return
	}
	if client.wlen-client.wpos != client.lua_busy_bytes || client.lua_busy_bytes >= LUA_BUSY_BUFFER {
		lua_busy_flush(client)
		return
	}
	if client.rlen >= LUA_BUSY_BUFFER {
		reply_error(client, "ERR Input exceeds BUSY service limit")
		client.close_after = true
		client.lua_busy_bytes = client.wlen-client.wpos
		lua_busy_flush(client)
		return
	}
	if client.rlen == client.rcap {
		capacity := min(LUA_BUSY_BUFFER, max(4096, client.rcap*2))
		client.rbuf = ([^]u8)(runtime.heap_resize(client.rbuf, capacity))
		conn_mem += capacity-client.rcap
		client.rcap = capacity
	}
	eof := false
	n, err := conn_net_read(client, client.rbuf[client.rlen:min(client.rcap, LUA_BUSY_BUFFER)])
	if err != .NONE && err != .EAGAIN && err != .EINTR {
		conn_close(client)
		return
	}
	if err == .NONE {
		if n == 0 {
			eof = true
		} else {
			client.rlen += n
			stat_reads_processed += 1
			stat_net_input_bytes += i64(n)
			client.atime_ms = max(client.atime_ms, lua_connection_clock())
		}
	}
	for budget^ > 0 && !client.close_after && client.rpos < client.rlen && client.wlen-client.wpos < LUA_BUSY_BUFFER-1024 {
		argv, kind := lua_busy_parse(&run.busy, client)
		if kind != .Command {
			break
		}
		budget^ -= 1
		lua_busy_dispatch(client, argv)
	}
	if client.rpos >= client.rlen {
		client.rpos, client.rlen = 0, 0
	} else if client.rpos > 0 {
		remaining := client.rlen-client.rpos
		intrinsics.mem_copy(client.rbuf, &client.rbuf[client.rpos], remaining)
		client.rpos, client.rlen = 0, remaining
	}
	if eof {
		client.close_after = true
	}
	client.lua_busy_bytes = client.wlen-client.wpos
	if client.close_after && client.lua_busy_bytes == 0 {
		conn_close(client)
		return
	}
	lua_busy_flush(client)
}

lua_busy_callback :: proc "c" (opaque: rawptr, wrote: i32, stats: ^lr.Stats) -> i32 {
	context = runtime.default_context()
	run := cast(^Lua_Invocation)opaque
	if run.debug.mode != 0 {
		return lr.CONTINUE
	}
	run.wrote = run.wrote || wrote != 0
	lua_note_runtime(run, stats)
	if run.killed || (persist_signal_pending() && !run.wrote) {
		return lua_busy_kill(run)
	}
	if len(run.busy.temporary) == 0 {
		line: Log_Line
		ll_begin(&line, LOG_WARNING)
		ll_str(&line, "Slow script detected: still in execution after ")
		ll_int(&line, i64(cfg.busy_reply_threshold))
		ll_str(&line, " milliseconds. You can try killing the script using the ")
		ll_str(&line, "FUNCTION KILL" if run.function else "SCRIPT KILL")
		ll_str(&line, " command. Script name is: ")
		ll_bytes(&line, run.identifier)
		ll_str(&line, ".")
		ll_end(&line)
		run.busy.temporary = make([]u8, LUA_BUSY_TEMP)
		mem.arena_init(&run.busy.arena, run.busy.temporary)
	}
	context.temp_allocator = mem.arena_allocator(&run.busy.arena)
	defer mem.arena_free_all(&run.busy.arena)
	saved_stat, saved_db, saved_touch, saved_ps := stat_cur, db_cur, store_no_touch, ps_exec
	defer {
		stat_cur, db_cur, store_no_touch, ps_exec = saved_stat, saved_db, saved_touch, saved_ps
	}
	ready: [64]linux.EPoll_Event
	count, err := linux.epoll_wait(srv.epfd, &ready[0], i32(len(ready)), 0)
	if err != .NONE {
		return lr.CONTINUE
	}
	budget := LUA_BUSY_COMMANDS
	for _ in 0 ..< min(64, len(srv.conns)) {
		if budget == 0 {
			break
		}
		run.busy.next_client = (run.busy.next_client+1) % len(srv.conns)
		client := srv.conns[run.busy.next_client]
		if client != nil && client != run.source && client.kind == .Redis && (client.rlen > client.rpos || conn_net_pending(client)) {
			lua_busy_read(run, client, &budget)
		}
	}
	for event in ready[:int(count)] {
		fd := linux.Fd(u32(event.data.u64))
		if u32(event.data.u64 >> 32) == 0 {
			if transport_is_listener(fd) {
				accept_clients(fd, .Redis)
			}
			continue
		}
		if int(fd) < 0 || int(fd) >= len(srv.conns) {
			continue
		}
		client := srv.conns[fd]
		if client == nil || client == run.source || u32(client.id) != u32(event.data.u64 >> 32) || client.kind != .Redis {
			continue
		}
		if .ERR in event.events {
			conn_close(client)
			continue
		}
		if .IN in event.events && client.tls != nil && client.tls.write_wants_in {
			lua_busy_flush(client)
			if srv.conns[fd] != client {
				continue
			}
		}
		readable := .IN in event.events || (.OUT in event.events && client.tls != nil && ((!client.tls.ready && client.tls.handshake_out) || client.tls.read_wants_out))
		if readable && budget > 0 {
			lua_busy_read(run, client, &budget)
		} else if .HUP in event.events {
			conn_close(client)
		} else if .OUT in event.events {
			lua_busy_flush(client)
		}
	}
	return lua_busy_kill(run) if run.killed || (persist_signal_pending() && !run.wrote) else lr.CONTINUE
}

lua_busy_kill :: proc(run: ^Lua_Invocation) -> i32 {
	if run.killed && !run.wrote && !run.kill_logged {
		run.kill_logged = true
		plog(LOG_NOTICE, "Lua script killed by user with SCRIPT KILL.")
	}
	return lr.KILL_READONLY
}
