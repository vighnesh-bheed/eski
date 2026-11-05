package main

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"
import "core:c"
import lr "lua_runtime"
import rp "request_parser"

Lua_Debug_State :: struct {
	input: [dynamic]u8,
	frame: [dynamic]u8,
	parser: rp.Scratch,
	initialized: bool,
	failed: bool,
	child: bool,
	mode: u8,
}

lua_debug_children: [dynamic]linux.Pid

lua_debug_reap :: proc() {
	for i := 0; i < len(lua_debug_children); {
		status: u32
		pid, err := linux.wait4(lua_debug_children[i], &status, {.WNOHANG}, nil)
		if pid > 0 || err == .ECHILD {
			lua_debug_children[i] = lua_debug_children[len(lua_debug_children)-1]
			pop(&lua_debug_children)
		} else {
			i += 1
		}
	}
}

lua_debug_shutdown :: proc() {
	for pid in lua_debug_children {
		line: Log_Line
		ll_begin(&line, LOG_NOTICE)
		ll_str(&line, "Killing debugging session ")
		ll_int(&line, i64(pid))
		ll_end(&line)
		linux.kill(pid, .SIGTERM)
		keyspace_signal_owed()
		status: u32
		for {
			_, err := linux.wait4(pid, &status, {}, nil)
			if err != .EINTR {
				break
			}
		}
	}
	clear(&lua_debug_children)
}

lua_debug_fork :: proc(client: ^Conn) -> (proceed, child: bool) {
	if client.lua_debug_mode != 1 {
		return true, false
	}
	keyspace_before_fork()
	compute_before_fork()
	pid, err := runtime_fork()
	if err != .NONE {
		reply_error(client, "ERR Could not fork for debugging session")
		return false, false
	}
	if pid != 0 {
		append(&lua_debug_children, pid)
		client.lua_debug_detached = true
		client.close_after = true
		client.wlen, client.wpos = 0, 0
		pst.dirty_explicit = true
		return false, false
	}
	pst.in_child = true
	config_oom_child_apply()
	pst.progress = nil
	pst.save_params = nil
	persist_set_signal(.SIGTERM, nil)
	persist_set_signal(.SIGINT, nil)
	transport_close_listeners(false)
	if mc_lfd >= 0 {
		linux.close(mc_lfd)
	}
	linux.close(srv.epfd)
	for other in srv.conns {
		if other != nil && other != client {
			linux.close(other.fd)
		}
	}
	aof.feed = false
	plog(LOG_NOTICE, "Eski forked for debugging eval")
	return true, true
}

lua_debug_destroy :: proc(state: ^Lua_Debug_State) {
	rp.destroy(&state.parser)
	delete(state.input)
	delete(state.frame)
	state^ = {}
}

lua_debug_send :: proc(run: ^Lua_Invocation, bytes: []u8) -> bool {
	client := run.source
	position := 0
	for position < len(bytes) {
		written, err := conn_net_write(client, bytes[position:])
		if err == .EINTR {
			continue
		}
		if err == .EAGAIN {
			_, problem := conn_net_wait(client, true, 250)
			if problem == .NONE || problem == .EINTR {
				continue
			}
		}
		if err != .NONE || written <= 0 {
			run.debug.failed = true
			return false
		}
		position += written
		stat_net_output_bytes += i64(written)
		stat_writes_processed += 1
		client.atime_ms = max(client.atime_ms, lua_connection_clock())
	}
	return true
}

lua_debug_flush :: proc(run: ^Lua_Invocation) -> bool {
	client := run.source
	if client.wlen > client.wpos && !lua_debug_send(run, client.wbuf[client.wpos:client.wlen]) {
		return false
	}
	client.wlen, client.wpos = 0, 0
	return true
}

lua_debug_write_callback :: proc "c" (opaque: rawptr, frame: lr.Arg) -> i32 {
	context = runtime.default_context()
	run := cast(^Lua_Invocation)opaque
	if run.debug.failed || frame.len > c.size_t(max(int)) || (frame.data == nil && frame.len != 0) {
		return 0
	}
	if !lua_debug_flush(run) {
		return 0
	}
	return 1 if lua_debug_send(run, frame.data[:int(frame.len)]) else 0
}

lua_debug_read_callback :: proc "c" (opaque: rawptr) -> lr.Result {
	context = runtime.default_context()
	run := cast(^Lua_Invocation)opaque
	state := &run.debug
	client := run.source
	if !conn_protected_ready(client) {
		state.failed = true
		return {}
	}
	if !state.initialized {
		state.initialized = true
		if client.rlen > client.rpos {
			append(&state.input, ..client.rbuf[client.rpos:client.rlen])
		}
	}
	clear(&state.frame)
	limits := rp.Limits{bulk_max = cfg.proto_max_bulk_len}
	for !state.failed {
		if len(state.input) > 0 {
			if state.input[0] != '*' {
				state.failed = true
				break
			}
			parsed := rp.parse_array(state.input[:], &state.parser, limits)
			if parsed.kind == .Error {
				state.failed = true
				break
			}
			if parsed.kind == .Command {
				append(&state.frame, ..state.input[:parsed.consumed])
				remaining := len(state.input)-parsed.consumed
				if remaining > 0 {
					intrinsics.mem_copy(raw_data(state.input), &state.input[parsed.consumed], remaining)
				}
				resize(&state.input, remaining)
				return lr.Result{data = raw_data(state.frame), len = c.size_t(len(state.frame))}
			}
		}
		if persist_signal_pending() && !run.wrote {
			break
		}
		buffer: [16*1024]u8
		read, err := conn_net_read(client, buffer[:])
		if err == .EINTR {
			continue
		}
		if err == .EAGAIN {
			_, problem := conn_net_wait(client, false, 250)
			if problem == .NONE || problem == .EINTR {
				continue
			}
		}
		if err != .NONE || read <= 0 || len(state.input) > int(cfg.client_query_buffer_limit)-read {
			state.failed = true
			break
		}
		append(&state.input, ..buffer[:read])
		stat_net_input_bytes += i64(read)
		stat_reads_processed += 1
		client.atime_ms = max(client.atime_ms, lua_connection_clock())
	}
	return lua_fixed("", lr.KILLED, run.wrote)
}
