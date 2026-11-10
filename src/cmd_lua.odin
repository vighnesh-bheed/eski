package main

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:sys/linux"
import lr "lua_runtime"

LUA_MAX_CALL_ARGS :: 1_048_576
LUA_ERR_BUSY :: "BUSY Eski is busy running a script. You can only call SCRIPT KILL or SHUTDOWN NOSAVE."
LUA_ERR_BUSY_FUNCTION :: "BUSY Eski is busy running a script. You can only call FUNCTION KILL or SHUTDOWN NOSAVE."
LUA_ERR_NOSCRIPT :: "NOSCRIPT No matching script. Please use EVAL."
LUA_ERR_UNKILLABLE :: "UNKILLABLE Sorry the script already executed write commands against the dataset. You can either wait the script termination or kill the server in a hard way using the SHUTDOWN NOSAVE command."

Lua_Invocation :: struct {
	source: ^Conn,
	capture: Conn,
	retained: []u8,
	host_bytes: int,
	temporary_bytes: int,
	capture_limit: int,
	capture_failed: bool,
	vm_bytes: int,
	vm_peak: int,
	readonly: bool,
	wrote: bool,
	killed: bool,
	start: u64,
	frozen_ms: i64,
	busy: Lua_Busy_State,
	debug: Lua_Debug_State,
	identifier: []u8,
	argv: [][]u8,
	function: bool,
	db: ^Db,
	allow_oom: bool,
	loading: bool,
	propagation: i32,
	rejected: bool,
	kill_logged: bool,
}

lua_active: ^Lua_Invocation
lua_vm_peak: int
lua_deny_scripts_disabled: bool

lua_options :: proc() -> lr.Options {
	return lr.Options{
		memory_limit = c.size_t(lua_max_memory),
		output_limit = c.size_t(lua_max_output),
		busy_threshold_ms = u64(cfg.busy_reply_threshold),
		max_depth = 0,
		hook_count = 1000,
		enable_deprecated_api = 1 if lua_enable_deprecated_api else 0,
		isolate = 1 if labels_on else 0,
	}
}

lua_scope_load :: proc(client: ^Conn, body: []u8, pinned: bool) -> ^Lua_Source {
	digest := lua_digest(body)
	if !lua_scope_room(digest, body) {
		reply_error(client, ERR_OWNER_QUOTA_OOM)
		return nil
	}
	fresh := lua_cache_find(digest) == nil
	if fresh && !lua_source_prepare(client, body, digest) {
		return nil
	}
	entry := lua_cache_hold(body, digest, pinned)
	if entry == nil {
		if fresh {
			key := lua_digest_key(digest[:])
			lr.eval_forget(lua_arg(key[:]))
		}
		reply_error(client, "OOM Lua source cache limit exceeded")
	}
	return entry
}

lua_arg :: proc(bytes: []u8) -> lr.Arg {
	return lr.Arg{raw_data(bytes), c.size_t(len(bytes))}
}

lua_is_eval :: proc "contextless" (cmd: ^Command) -> bool {
	return cmd != nil && (cmd.handler == cmd_eval || cmd.handler == cmd_evalsha || cmd.handler == cmd_eval_ro || cmd.handler == cmd_evalsha_ro || cmd.handler == cmd_fcall || cmd.handler == cmd_fcall_ro)
}

lua_outer_readonly :: proc(cmd: ^Command, argv: [][]u8) -> bool {
	if cmd == nil || len(argv) < 2 {
		return false
	}
	if cmd.handler == cmd_eval_ro || cmd.handler == cmd_evalsha_ro || cmd.handler == cmd_fcall_ro {
		return true
	}
	if cmd.handler == cmd_fcall {
		library, _, info := lua_function_find(argv[1])
		return library != nil && info.flags & LUA_FLAG_NO_WRITES != 0
	}
	if cmd.handler == cmd_eval {
		_, flags, _, err := lua_source_plan(argv[1])
		return err == "" && flags & LUA_FLAG_NO_WRITES != 0
	}
	if cmd.handler == cmd_evalsha && !labels_on {
		digest, good := lua_digest_parse(argv[1])
		if good {
			if entry := lua_cache_lookup(digest); entry != nil {
				_, flags, _, err := lua_source_plan(entry.body)
				return err == "" && flags & LUA_FLAG_NO_WRITES != 0
			}
		}
	}
	return false
}

lua_outer_persistence_write :: proc(cmd: ^Command, argv: [][]u8) -> bool {
	if cmd == nil || len(argv) < 2 || lua_outer_readonly(cmd, argv) {
		return false
	}
	if cmd.handler == cmd_fcall {
		library, _, _ := lua_function_find(argv[1])
		return library != nil
	}
	body: []u8
	if cmd.handler == cmd_eval {
		body = argv[1]
	} else if cmd.handler == cmd_evalsha {
		digest, good := lua_digest_parse(argv[1])
		if !good {
			return false
		}
		entry := lua_cache_lookup(digest)
		if entry == nil {
			return false
		}
		body = entry.body
	} else {
		return false
	}
	_, _, flagged, err := lua_source_plan(body)
	return flagged && err == ""
}

lua_memory_used :: proc "contextless" () -> int {
	return lua_host_memory_used() + lua_vm_memory_used()
}

lua_host_memory_used :: #force_inline proc "contextless" () -> int {
	total := lua_cache_bytes + lua_retired_bytes + lua_scope_bytes + lua_library_host_memory()
	if run := lua_active; run != nil {
		total += size_of(Lua_Invocation) + run.host_bytes + run.temporary_bytes + run.capture.wcap + lua_busy_memory(&run.busy) + cap(run.debug.input) + cap(run.debug.frame) + len(run.debug.parser.args)*size_of([]u8)
	}
	return total
}

lua_vm_memory_used :: proc "contextless" () -> int {
	return int(lr.functions_stats().current_bytes) + int(lr.eval_stats().current_bytes) + int(lr.detached_memory())
}

lua_note_runtime :: proc(run: ^Lua_Invocation, stats: ^lr.Stats) {
	if stats != nil {
		run.vm_bytes = int(stats.current_bytes)
		run.vm_peak = max(run.vm_peak, int(stats.peak_bytes))
		lua_vm_peak = max(lua_vm_peak, run.vm_peak)
	}
	mem_note_peak()
}

lua_capture_capacity :: proc "contextless" (client: ^Conn) -> int {
	return lua_active.capture_limit if lua_active != nil && client == &lua_active.capture else max(int)
}

lua_capture_allow :: proc "contextless" (client: ^Conn, size: int) -> bool {
	run := lua_active
	if run == nil || client != &run.capture {
		return true
	}
	if run.capture_failed || size < 0 || size > run.capture_limit-client.wlen {
		run.capture_failed = true
		return false
	}
	return true
}

lua_fixed :: proc(text: string, status: i32 = lr.OK, wrote: bool = false) -> lr.Result {
	return lr.Result{data = raw_data(transmute([]u8)text), len = c.size_t(len(text)), write_effect = 1 if wrote else 0, status = status}
}

lua_result_reply :: proc(client: ^Conn, result: ^lr.Result) {
	if result.data == nil || result.len == 0 || result.len > c.size_t(lua_max_output) {
		reply_error(client, "ERR Lua runtime could not produce a bounded reply")
		return
	}
	bytes := result.data[:int(result.len)]
	if result.error_count != 0 {
		if result.errors == nil || result.error_count > result.len/3 {
			reply_error(client, "ERR Lua runtime returned invalid error metadata")
			return
		}
		events := result.errors[:int(result.error_count)]
		for event in events {
			if event.offset == 0 || event.offset > result.len || result.len-event.offset < 2 || event.len > result.len-event.offset-2 {
				reply_error(client, "ERR Lua runtime returned invalid error metadata")
				return
			}
			start, end := int(event.offset), int(event.offset+event.len)
			if bytes[start-1] != '-' || bytes[end] != '\r' || bytes[end+1] != '\n' {
				reply_error(client, "ERR Lua runtime returned invalid error metadata")
				return
			}
		}
		for event in events {
			stat_error_reply(client, bytes[int(event.offset):int(event.offset+event.len)], event.forwarded == 0)
		}
	} else if bytes[0] == '-' {
		end := len(bytes)-2 if len(bytes) >= 2 else len(bytes)
		stat_error_reply(client, bytes[1:end], result.forwarded_error == 0)
	}
	output := wb_reserve(client, len(bytes))
	intrinsics.mem_copy_non_overlapping(output, raw_data(bytes), len(bytes))
	client.wlen += len(bytes)
}

lua_source_plan :: proc(body: []u8) -> (text: []u8, flags: u32, flagged: bool, err: string) {
	if len(body) < 2 || body[0] != '#' || body[1] != '!' {
		return body, 0, false, ""
	}
	end := -1
	for byte, i in body {
		if byte == '\n' {
			end = i
			break
		}
	}
	if end < 0 {
		return nil, 0, true, "ERR Invalid script shebang"
	}
	words: [dynamic][]u8
	defer delete(words)
	if !split_args(body[:end], &words, context.temp_allocator) || len(words) == 0 {
		return nil, 0, true, "ERR Invalid engine in script shebang"
	}
	if string(words[0]) != "#!lua" {
		return nil, 0, true, fmt.tprintf("ERR Unexpected engine in script shebang: %s", string(words[0]))
	}
	for word in words[1:] {
		if len(word) < 6 || string(word[:6]) != "flags=" {
			return nil, 0, true, fmt.tprintf("ERR Unknown lua shebang option: %s", string(word))
		}
		if len(word) == 6 {
			continue
		}
		start := 6
		for i := 6; i <= len(word); i += 1 {
			if i != len(word) && word[i] != ',' {
				continue
			}
			switch string(word[start:i]) {
			case "no-writes": flags |= LUA_FLAG_NO_WRITES
			case "allow-oom": flags |= LUA_FLAG_ALLOW_OOM
			case "allow-stale": flags |= LUA_FLAG_ALLOW_STALE
			case "no-cluster": flags |= LUA_FLAG_NO_CLUSTER
			case "allow-cross-slot-keys": flags |= LUA_FLAG_CROSS_SLOT
			case: return nil, 0, true, fmt.tprintf("ERR Unexpected flag in script shebang: %s", string(word[start:i]))
			}
			start = i+1
		}
	}
	return body[end:], flags, true, ""
}

lua_source_text :: proc(body: []u8) -> (text: []u8, readonly: bool, err: string) {
	parsed_text, flags, _, parsed_err := lua_source_plan(body)
	return parsed_text, flags & LUA_FLAG_NO_WRITES != 0, parsed_err
}

lua_source_prepare :: proc(client: ^Conn, body: []u8, digest: [40]u8) -> bool {
	text, _, err := lua_source_text(body)
	if err != "" {
		lua_function_error(client, err)
		return false
	}
	options := lua_options()
	defer mem_registry_changed()
	hex := digest
	key := lua_digest_key(hex[:])
	result := lr.eval_prepare(lua_arg(text), lua_arg(key[:]), &options)
	defer lr.free_result(&result)
	lua_connection_time_floor = max(lua_connection_time_floor, lua_wallclock_ms())
	client.atime_ms = max(client.atime_ms, lua_connection_clock())
	lua_vm_peak = max(lua_vm_peak, int(result.stats.peak_bytes))
	if result.status != lr.OK {
		lua_result_reply(client, &result)
		return false
	}
	return true
}

lua_handler_allowed :: proc(cmd: ^Command, spec: ^Cmd_Spec) -> bool {
	return spec != nil && (lua_deny_scripts_disabled || .Noscript not_in spec.flags)
}

lua_command_writes :: proc(cmd: ^Command, spec: ^Cmd_Spec, argv: [][]u8) -> bool {
	if cmd.name == "bitfield" {
		keys: [dynamic]Key_Ref
		defer delete(keys)
		find_keys(spec, argv, &keys)
		for key in keys {
			if key.flags & {.Rw, .Ow, .Rm, .Update, .Insert, .Delete} != {} {
				return true
			}
		}
		return false
	}
	return .Write in spec.flags || is_write_command(cmd.name, argv)
}

lua_mutation_returns_values :: proc(cmd: ^Command, argv: [][]u8) -> bool {
	switch cmd.name {
	case "getdel", "getex", "getset", "lpop", "rpop", "lmove", "rpoplpush", "lmpop", "spop", "zpopmin", "zpopmax", "zmpop", "xclaim", "xautoclaim", "georadius", "georadiusbymember":
		return true
	case "set":
		for arg in argv[3:] {
			if eq_nocase(arg, "get") {
				return true
			}
		}
	}
	return false
}

lua_inner_reject :: proc(run: ^Lua_Invocation, text: string) {
	reply_error(&run.capture, text)
	run.rejected = true
}

lua_inner :: proc(run: ^Lua_Invocation, argv: [][]u8) {
	client := &run.capture
	slot := lookup_entry(argv[0])
	if slot == nil {
		lua_inner_reject(run, "ERR Unknown Redis command called from script")
		return
	}
	cmd, hot := slot.cmd, slot.stats
	spec := cmd_spec_lookup(cmd, argv)
	if !arity_ok(cmd.arity, len(argv)) || (spec != nil && !arity_ok(int(spec.arity), len(argv))) {
		lua_inner_reject(run, "ERR Wrong number of args calling Redis command from script")
		stat_reject(hot, argv)
		return
	}
	if !lua_handler_allowed(cmd, spec) || label_script_denied(cmd, argv) {
		lua_inner_reject(run, "ERR This command is not allowed from script")
		stat_reject(hot, argv)
		return
	}
	id := acl_command_id(spec.name)
	if id < 0 {
		lua_inner_reject(run, "ERR Script command has no ACL metadata")
		return
	}
	permission, position := acl_check_user(run.source.user, int(id), argv)
	if permission != .Allowed {
		acl_log_add(run.source, permission, .Lua, argv, position, nil, transmute([]u8)spec.name if permission == .Command_Denied else nil)
		message := make([dynamic]u8, context.temp_allocator)
		sb_str(&message, "ERR ACL failure in script: ")
		acl_error_message(&message, permission, run.source.user, spec.name, nil)
		lua_inner_reject(run, string(message[:]))
		stat_reject(hot, argv)
		return
	}
	if labels_on {
		if refusal := access_command_refusal(cmd, argv); refusal != "" {
			lua_inner_reject(run, refusal)
			stat_reject(hot, argv)
			return
		}
	}
	writing := lua_command_writes(cmd, spec, argv)
	if run.readonly && writing {
		lua_inner_reject(run, "ERR Write commands are not allowed from read-only scripts.")
		stat_reject(hot, argv)
		return
	}
	if writing {
		bound := u128(128) + u128(len(argv))*32
		if lua_mutation_returns_values(cmd, argv) {
			keys: [dynamic]int
			command_keys(spec, argv, &keys)
			for key_position in keys {
				if key_position >= 0 && key_position < len(argv) {
					bound += u128(len(argv[key_position])) + lua_store_reply_bound(run.db, argv[key_position])
				}
			}
			delete(keys)
		}
		if bound > u128(run.capture_limit) {
			run.capture_failed = true
			return
		}
	}
	if .Denyoom in spec.flags && !run.wrote && !run.allow_oom && maxmemory_bytes > 0 && u64(max(0, mem_used()-mem_not_counted())) > maxmemory_bytes {
		lua_inner_reject(run, ERR_OOM)
		stat_reject(hot, argv)
		return
	}
	if !run.loading && persist_gate(client, cmd, argv) {
		run.rejected = true
		stat_reject(hot, argv)
		return
	}
	saved_feed := aof.feed
	if run.propagation & 1 == 0 {
		aof.feed = false
	}
	defer aof.feed = saved_feed
	saved_db, saved_touch, saved_stat, saved_deny := db_cur, store_no_touch, stat_cur, deny_blocking
	defer {
		db_cur, store_no_touch, stat_cur, deny_blocking = saved_db, saved_touch, saved_stat, saved_deny
	}
	db_cur, store_no_touch, deny_blocking = run.db, .No_Touch in run.source.flags && cmd.handler != cmd_touch, true
	if labels_on {
		if refusal := label_step(run.db, cmd, argv); refusal != "" {
			lua_inner_reject(run, refusal)
			stat_reject(hot, argv)
			return
		}
	}
	client.last_cmd = cmd.name
	dirty := pst.dirty
	if aof.feed {
		aof_cmd_begin(client, cmd, argv)
	}
	stat_cur = &hot.stats
	pst.dirty_explicit = false
	start := mono_now()
	cmd.handler(client, argv)
	run.db = client.db
	stat_call_slow(client, cmd, hot, argv, mono_now()-start)
	if client.blocked != .None || client.compute != nil || client.keyspace_inflight > 0 {
		store_fatal("Lua inner dispatcher deferred execution invariant")
	}
	persist_note(client, cmd, argv, 0, dirty)
	if pst.dirty != dirty || cmd.name == "publish" || cmd.name == "spublish" || cmd.name == "pfcount" {
		run.wrote = true
	}
	if .Tracking in run.source.ps {
		tracking_remember_keys(run.source, cmd, argv)
	}
	if len(monitors) > 0 {
		monitor_feed(client, cmd, argv)
	}
}

lua_command_callback :: proc "c" (opaque: rawptr, resp: i32, count: c.size_t, arguments: [^]lr.Arg, stats: ^lr.Stats) -> lr.Result {
	context = runtime.default_context()
	run := cast(^Lua_Invocation)opaque
	saved_stat := stat_cur
	stat_cur = nil
	defer stat_cur = saved_stat
	lua_note_runtime(run, stats)
	mem_free(raw_data(run.retained))
	run.retained, run.host_bytes = nil, 0
	if run.killed || run.capture_failed {
		return lua_fixed("-ERR Script aborted\r\n", lr.KILLED, run.wrote)
	}
	if count == 0 || count > LUA_MAX_CALL_ARGS || (resp != 2 && resp != 3) {
		return lua_fixed("-ERR Invalid script command argument count or protocol\r\n")
	}
	header_bytes := int(count)*size_of([]u8)
	remaining := int(lua_max_bridge_memory)-run.host_bytes-run.temporary_bytes
	if header_bytes > remaining {
		run.capture_failed = true
		return lua_fixed("-ERR Script bridge memory limit exceeded\r\n", lr.LIMIT, run.wrote)
	}
	argv := make([][]u8, int(count))
	run.temporary_bytes += header_bytes
	defer {
		delete(argv)
		run.temporary_bytes -= header_bytes
	}
	for arg, i in arguments[:int(count)] {
		if arg.len > c.size_t(max(int)) || (arg.data == nil && arg.len != 0) {
			return lua_fixed("-ERR Invalid script command argument\r\n", lr.BRIDGE, run.wrote)
		}
		argv[i] = arg.data[:int(arg.len)]
	}
	run.capture = Conn{fd = -1, resp = u8(resp), db = run.db, user = run.source.user, authed = true, ever_authed = true, flags = run.source.flags}
	copy(run.capture.addr[:], "lua")
	run.capture.addr_len = 3
	run.capture_limit = min(int(lua_max_output), int(lua_max_bridge_memory)-run.host_bytes-run.temporary_bytes)
	run.rejected = false
	lua_inner(run, argv)
	result := lr.Result{data = run.capture.wbuf, len = c.size_t(run.capture.wlen), write_effect = 1 if run.wrote else 0, rejected = 1 if run.rejected else 0}
	if run.capture.wbuf != nil {
		run.retained = run.capture.wbuf[:run.capture.wcap]
		run.host_bytes = run.capture.wcap
	}
	run.capture.wbuf, run.capture.wcap, run.capture.wlen = nil, 0, 0
	if run.capture_failed {
		return lua_fixed("-ERR Script command reply limit exceeded\r\n", lr.LIMIT, run.wrote)
	}
	if result.len == 0 {
		return lua_fixed("-ERR Script command returned no reply\r\n", lr.BRIDGE, run.wrote)
	}
	return result
}

lua_acl_callback :: proc "c" (opaque: rawptr, count: c.size_t, arguments: [^]lr.Arg) -> lr.Result {
	context = runtime.default_context()
	run := cast(^Lua_Invocation)opaque
	mem_free(raw_data(run.retained))
	run.retained, run.host_bytes = nil, 0
	if count == 0 || count > LUA_MAX_CALL_ARGS {
		return lua_fixed("-ERR Invalid command passed to redis.acl_check_cmd()\r\n")
	}
	if count > c.size_t(int(lua_max_bridge_memory)/size_of([]u8)) {
		return lua_fixed("-ERR Script bridge memory limit exceeded\r\n", lr.LIMIT, run.wrote)
	}
	argv := make([][]u8, int(count))
	defer delete(argv)
	for arg, i in arguments[:int(count)] {
		if arg.len > c.size_t(max(int)) || (arg.data == nil && arg.len != 0) {
			return lua_fixed("-ERR Invalid script command argument\r\n", lr.BRIDGE, run.wrote)
		}
		argv[i] = arg.data[:int(arg.len)]
	}
	cmd := lookup_command(argv[0])
	if cmd == nil {
		return lua_fixed("-ERR Invalid command passed to redis.acl_check_cmd()\r\n")
	}
	if !arity_ok(cmd.arity, len(argv)) {
		return lua_fixed("-ERR Wrong number of args for redis.acl_check_cmd()\r\n")
	}
	spec := cmd_spec_lookup(cmd, argv)
	if spec == nil {
		return lua_fixed("-ERR Invalid command passed to redis.acl_check_cmd()\r\n")
	}
	if !arity_ok(int(spec.arity), len(argv)) {
		return lua_fixed("-ERR Wrong number of args for redis.acl_check_cmd()\r\n")
	}
	id := acl_command_id(spec.name)
	if id < 0 {
		return lua_fixed("-ERR Invalid command passed to redis.acl_check_cmd()\r\n")
	}
	permission, _ := acl_check_user(run.source.user, int(id), argv)
	return lua_fixed(":1\r\n" if permission == .Allowed else ":0\r\n")
}

lua_propagation_callback :: proc "c" (opaque: rawptr, mask: i32) -> i32 {
	context = runtime.default_context()
	if mask < 0 || mask > 3 {
		return 0
	}
	run := cast(^Lua_Invocation)opaque
	run.propagation = mask
	return 1
}

lua_log_callback :: proc "c" (opaque: rawptr, level: i32, count: c.size_t, args: [^]lr.Arg) {
	context = runtime.default_context()
	if count > LUA_MAX_CALL_ARGS {
		return
	}
	line: [1024]u8
	used := 0
	for arg, i in args[:int(count)] {
		if i != 0 && used < len(line) {
			line[used] = ' '
			used += 1
		}
		n := min(int(min(arg.len, c.size_t(len(line)-used))), len(line)-used)
		if n > 0 {
			copy(line[used:used+n], arg.data[:n])
			used += n
		}
	}
	severity: u8 = LOG_WARNING
	switch level {
	case 0: severity = LOG_DEBUG
	case 1: severity = LOG_VERBOSE
	case 2: severity = LOG_NOTICE
	}
	plog(severity, string(line[:used]))
}

lua_effect_owner :: proc "contextless" (client: ^Conn) -> bool {
	return lua_active != nil && client == &lua_active.capture
}

lua_eval_common :: proc(client: ^Conn, argv: [][]u8, digest_only, readonly: bool) {
	pst.dirty_explicit = true
	if digest_only && client.lua_debug_mode != 0 {
		reply_error(client, "ERR Please use EVAL instead of EVALSHA for debugging")
		return
	}
	if lua_active != nil {
		reply_error(client, LUA_ERR_BUSY)
		return
	}
	numkeys, valid := parse_i64(argv[2])
	if !valid {
		reply_error(client, ERR_NOT_INT)
		return
	}
	if numkeys < 0 {
		reply_error(client, "ERR Number of keys can't be negative")
		return
	}
	if numkeys > i64(len(argv)-3) {
		reply_error(client, "ERR Number of keys can't be greater than number of args")
		return
	}
	if len(argv)-3 > LUA_MAX_CALL_ARGS {
		reply_error(client, "ERR Script argument count exceeds the configured bridge boundary")
		return
	}
	entry: ^Lua_Source
	if digest_only {
		digest, ok := lua_digest_parse(argv[1])
		if ok {
			entry = lua_cache_lookup(digest, true)
		}
		if entry == nil {
			reply_error(client, LUA_ERR_NOSCRIPT)
			return
		}
	} else if labels_on {
		entry = lua_scope_load(client, argv[1], false)
		if entry == nil {
			return
		}
	} else {
		digest := lua_digest(argv[1])
		entry = lua_cache_find(digest, true)
		if entry == nil {
			if !lua_source_prepare(client, argv[1], digest) {
				return
			}
			entry = lua_cache_store(argv[1], digest, false)
			if entry == nil {
				key := lua_digest_key(digest[:])
				lr.eval_forget(lua_arg(key[:]))
				reply_error(client, "OOM Lua source cache limit exceeded")
				return
			}
		}
	}
	text, flags, flagged, header_err := lua_source_plan(entry.body)
	if header_err != "" {
		lua_function_error(client, header_err)
		return
	}
	lua_invoke(client, argv, int(numkeys), text, readonly || flags & LUA_FLAG_NO_WRITES != 0, flags, flagged, nil, 0, entry.digest[:])
}

lua_invoke :: proc(client: ^Conn, argv: [][]u8, numkeys: int, text: []u8, readonly: bool, flags: u32, flagged: bool, library: ^Lua_Library, index: int, identifier: []u8) {
	defer mem_registry_changed()
	keyspace_fence()
	debug_mode := client.lua_debug_mode if library == nil else 0
	debug_child := false
	loading := aof.loading && client.fd < 0
	allow_oom := loading || readonly || flags & LUA_FLAG_ALLOW_OOM != 0
	if flagged && !allow_oom && maxmemory_bytes > 0 && u64(max(0, mem_used()-mem_not_counted())) > maxmemory_bytes {
		reply_error(client, ERR_OOM)
		return
	}
	run := Lua_Invocation{source = client, readonly = readonly, start = mono_now(), frozen_ms = srv.now_ms, identifier = identifier, argv = argv, function = library != nil, db = client.db, allow_oom = allow_oom, loading = loading, propagation = 3, debug = Lua_Debug_State{mode = debug_mode, child = debug_child}}
	run.temporary_bytes = (len(argv)-3)*size_of(lr.Arg)
	if run.temporary_bytes > int(lua_max_bridge_memory) {
		reply_error(client, "OOM Lua bridge argument limit exceeded")
		return
	}
	arguments := make([]lr.Arg, len(argv)-3)
	for value, i in argv[3:] {
		arguments[i] = lua_arg(value)
	}
	defer delete(arguments)
	if debug_mode != 0 {
		proceed: bool
		proceed, debug_child = lua_debug_fork(client)
		if !proceed {
			return
		}
		run.debug.child = debug_child
	}
	saved_stat, saved_db, saved_touch, saved_ps, saved_deny := stat_cur, db_cur, store_no_touch, ps_exec, deny_blocking
	lua_active = &run
	ps_exec, deny_blocking = client, true
	owned_effect_group := aof.feed && !aof.in_tx
	if owned_effect_group {
		aof_tx_begin(client, nil, nil)
	}
	defer {
		if owned_effect_group {
			aof_tx_end()
		}
		lua_active = nil
		stat_cur, db_cur, store_no_touch, ps_exec, deny_blocking = saved_stat, saved_db, saved_touch, saved_ps, saved_deny
		pst.dirty_explicit = true
		mem_free(raw_data(run.retained))
		lua_busy_destroy(&run.busy)
		lua_debug_destroy(&run.debug)
	}
	options := lua_options()
	options.identifier = lua_arg(identifier)
	options.function_mode = 1 if library != nil else 0
	options.debug_mode = i32(debug_mode)
	callbacks := lr.Callbacks{command = lua_command_callback, busy = lua_busy_callback, log = lua_log_callback, opaque = &run, acl_check = lua_acl_callback, propagation = lua_propagation_callback, debug_read = lua_debug_read_callback, debug_write = lua_debug_write_callback}
	keys := raw_data(arguments)
	args := raw_data(arguments[numkeys:])
	argument_count := len(arguments)-numkeys
	result: lr.Result
	if debug_mode == 2 {
		plog(LOG_NOTICE, "Eski synchronous debugging eval session started")
	}
	home: ^Lua_Scope
	outer_random: u64
	if labels_on {
		home = lua_scope_of(access_scope(), true)
		outer_random = lr.random_exchange(lua_scope_random(home))
	}
	if library == nil {
		key := lua_digest_key(identifier)
		result = lr.eval_cached(lua_arg(text), lua_arg(key[:]), c.size_t(numkeys), keys, c.size_t(argument_count), args, i32(client.resp), &options, &callbacks)
	} else {
		result = lr.library_call(library.handle, c.size_t(index), c.size_t(numkeys), keys, c.size_t(argument_count), args, i32(client.resp), &options, &callbacks)
	}
	if home != nil {
		home.random = lr.random_exchange(outer_random)
	}
	defer lr.free_result(&result)
	lua_note_runtime(&run, &result.stats)
	client.atime_ms = max(client.atime_ms, lua_connection_clock())
	lua_result_reply(client, &result)
	if debug_mode != 0 {
		if !run.debug.failed {
			lua_debug_flush(&run)
		}
		if debug_child {
			plog(LOG_NOTICE, "Lua debugging session child exiting")
			linux.exit_group(0)
		}
		if debug_mode == 2 {
			plog(LOG_NOTICE, "Eski synchronous debugging eval session ended")
		}
		client.close_after = true
	}
}

lua_fcall_common :: proc(client: ^Conn, argv: [][]u8, readonly: bool) {
	pst.dirty_explicit = true
	library, index, info := lua_function_find(argv[1])
	if library == nil {
		reply_error(client, "ERR Function not found")
		return
	}
	numkeys, valid := parse_i64(argv[2])
	if !valid {
		reply_error(client, "ERR Bad number of keys provided")
		return
	}
	if numkeys < 0 {
		reply_error(client, "ERR Number of keys can't be negative")
		return
	}
	if numkeys > i64(len(argv)-3) {
		reply_error(client, "ERR Number of keys can't be greater than number of args")
		return
	}
	if readonly && info.flags & LUA_FLAG_NO_WRITES == 0 {
		reply_error(client, "ERR Can not execute a script with write flag using *_ro command.")
		return
	}
	lua_invoke(client, argv, int(numkeys), nil, readonly || info.flags & LUA_FLAG_NO_WRITES != 0, info.flags, true, library, index, argv[1])
}

cmd_fcall :: proc(client: ^Conn, argv: [][]u8) { lua_fcall_common(client, argv, false) }
cmd_fcall_ro :: proc(client: ^Conn, argv: [][]u8) { lua_fcall_common(client, argv, true) }

cmd_eval :: proc(client: ^Conn, argv: [][]u8) { lua_eval_common(client, argv, false, false) }
cmd_evalsha :: proc(client: ^Conn, argv: [][]u8) { lua_eval_common(client, argv, true, false) }
cmd_eval_ro :: proc(client: ^Conn, argv: [][]u8) { lua_eval_common(client, argv, false, true) }
cmd_evalsha_ro :: proc(client: ^Conn, argv: [][]u8) { lua_eval_common(client, argv, true, true) }

lua_busy_error :: proc "contextless" () -> string {
	return LUA_ERR_BUSY_FUNCTION if lua_active != nil && lua_active.function else LUA_ERR_BUSY
}

lua_kill :: proc(client: ^Conn, function: bool) {
	if lua_active == nil {
		reply_error(client, "NOTBUSY No scripts in execution right now.")
	} else if lua_active.wrote {
		reply_error(client, LUA_ERR_UNKILLABLE)
	} else if lua_active.function != function {
		reply_error(client, lua_busy_error())
	} else {
		lua_active.killed = true
		reply_ok(client)
	}
}

lua_script_help := [?]string{
	"SCRIPT <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"DEBUG (YES|SYNC|NO)",
	"    Set the debug mode for subsequent scripts executed.",
	"EXISTS <sha1> [<sha1> ...]",
	"    Return information about the existence of the scripts in the script cache.",
	"FLUSH [ASYNC|SYNC]",
	"    Flush the Lua scripts cache. Very dangerous on replicas.",
	"    When called without the optional mode argument, the behavior is determined by the",
	"    lazyfree-lazy-user-flush configuration directive. Valid modes are:",
	"    * ASYNC: Asynchronously flush the scripts cache.",
	"    * SYNC: Synchronously flush the scripts cache.",
	"KILL",
	"    Kill the currently executing Lua script.",
	"LOAD <script>",
	"    Load a script into the scripts cache without executing it.",
	"HELP",
	"    Print this help.",
}

cmd_script :: proc(client: ^Conn, argv: [][]u8) {
	sub := argv[1]
	switch {
	case eq_nocase(sub, "debug"):
		if len(argv) != 3 {
			reply_wrong_args(client, "script|debug")
			return
		}
		if .Multi in client.txf {
			reply_error(client, "ERR SCRIPT DEBUG must be called outside a pipeline")
			return
		}
		switch {
		case eq_nocase(argv[2], "yes"): client.lua_debug_mode = 1
		case eq_nocase(argv[2], "sync"): client.lua_debug_mode = 2
		case eq_nocase(argv[2], "no"): client.lua_debug_mode = 0
		case:
			reply_error(client, "ERR Use SCRIPT DEBUG YES/SYNC/NO")
			return
		}
		reply_ok(client)
	case eq_nocase(sub, "load"):
		if len(argv) != 3 {
			reply_wrong_args(client, "script|load")
			return
		}
		if labels_on {
			if entry := lua_scope_load(client, argv[2], true); entry != nil {
				reply_bulk(client, entry.digest[:])
			}
			return
		}
		digest := lua_digest(argv[2])
		if !lua_source_prepare(client, argv[2], digest) {
			return
		}
		entry := lua_cache_store(argv[2], digest, true)
		if entry == nil {
			key := lua_digest_key(digest[:])
			lr.eval_forget(lua_arg(key[:]))
			reply_error(client, "OOM Lua source cache limit exceeded")
			return
		}
		reply_bulk(client, entry.digest[:])
	case eq_nocase(sub, "exists"):
		if len(argv) < 3 {
			reply_wrong_args(client, "script|exists")
			return
		}
		reply_array(client, len(argv)-2)
		for arg in argv[2:] {
			digest, ok := lua_digest_parse(arg)
			reply_int(client, 1 if ok && lua_cache_lookup(digest) != nil else 0)
		}
	case eq_nocase(sub, "flush"):
		asynchronous := cfg.lazyfree_lazy_user_flush
		if len(argv) == 3 && (eq_nocase(argv[2], "sync") || eq_nocase(argv[2], "async")) {
			asynchronous = eq_nocase(argv[2], "async")
		} else if len(argv) != 2 {
			reply_error(client, ERR_SYNTAX)
			return
		}
		lr.reset()
		mem_registry_changed()
		lua_cache_flush(asynchronous)
		reply_ok(client)
	case eq_nocase(sub, "kill"):
		if len(argv) != 2 {
			reply_wrong_args(client, "script|kill")
			return
		}
		lua_kill(client, false)
	case eq_nocase(sub, "help"):
		if len(argv) != 2 {
			reply_wrong_args(client, "script|help")
			return
		}
		reply_array(client, len(lua_script_help))
		for line in lua_script_help {
			reply_simple(client, line)
		}
	case:
		reply_error(client, "ERR Unsupported SCRIPT subcommand")
	}
}

lua_commands := [?]Command{
	{"fcall", cmd_fcall, -3},
	{"fcall_ro", cmd_fcall_ro, -3},
	{"eval", cmd_eval, -3},
	{"evalsha", cmd_evalsha, -3},
	{"eval_ro", cmd_eval_ro, -3},
	{"evalsha_ro", cmd_evalsha_ro, -3},
	{"script", cmd_script, -2},
}

@(init)
register_lua_commands :: proc "contextless" () {
	register_commands(lua_commands[:])
	lr.set_load_log(lua_log_callback)
}
