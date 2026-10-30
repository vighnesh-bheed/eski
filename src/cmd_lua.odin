package main

import "base:intrinsics"
import "base:runtime"
import "core:c"
import lr "lua_runtime"

LUA_MAX_CALL_ARGS :: 4096
LUA_ERR_BUSY :: "BUSY Eski is busy running a script. You can only call SCRIPT KILL or SHUTDOWN NOSAVE."
LUA_ERR_NOSCRIPT :: "NOSCRIPT No matching script. Please use EVAL."
LUA_ERR_UNKILLABLE :: "UNKILLABLE Sorry the script already executed write commands against the dataset. You can either wait the script termination or kill the server with SHUTDOWN NOSAVE."

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
}

lua_active: ^Lua_Invocation
lua_vm_peak: int

lua_options :: proc() -> lr.Options {
	return lr.Options{
		memory_limit = c.size_t(lua_max_memory),
		output_limit = c.size_t(lua_max_output),
		busy_threshold_ms = u64(cfg.busy_reply_threshold),
		max_depth = 64,
		hook_count = 1000,
	}
}

lua_arg :: proc(bytes: []u8) -> lr.Arg {
	return lr.Arg{raw_data(bytes), c.size_t(len(bytes))}
}

lua_is_eval :: proc "contextless" (cmd: ^Command) -> bool {
	return cmd != nil && (cmd.handler == cmd_eval || cmd.handler == cmd_evalsha || cmd.handler == cmd_eval_ro || cmd.handler == cmd_evalsha_ro)
}

lua_memory_used :: proc "contextless" () -> int {
	total := lua_cache_bytes + lua_retired_bytes
	if run := lua_active; run != nil {
		total += size_of(Lua_Invocation) + run.host_bytes + run.temporary_bytes + run.vm_bytes + run.capture.wcap + lua_busy_memory(&run.busy)
	}
	return total
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
	if bytes[0] == '-' {
		end := len(bytes)-2 if len(bytes) >= 2 else len(bytes)
		stat_error_reply(client, bytes[1:end])
	}
	output := wb_reserve(client, len(bytes))
	intrinsics.mem_copy_non_overlapping(output, raw_data(bytes), len(bytes))
	client.wlen += len(bytes)
}

lua_source_text :: proc(body: []u8) -> (text: []u8, readonly: bool, err: string) {
	if len(body) < 2 || body[0] != '#' || body[1] != '!' {
		return body, false, ""
	}
	end := len(body)
	for byte, i in body {
		if byte == '\n' {
			end = i
			break
		}
	}
	words: [dynamic][]u8
	defer delete(words)
	if !split_args(body[:end], &words, context.temp_allocator) || len(words) == 0 || string(words[0]) != "#!lua" {
		return nil, false, "ERR Unsupported script language"
	}
	if len(words) > 2 || (len(words) == 2 && string(words[1]) != "flags=no-writes") {
		return nil, false, "ERR Unsupported Lua script flags"
	}
	return body[end:], len(words) == 2, ""
}

lua_source_compile :: proc(client: ^Conn, body: []u8) -> bool {
	text, _, err := lua_source_text(body)
	if err != "" {
		reply_error(client, err)
		return false
	}
	options := lua_options()
	result := lr.compile(lua_arg(text), &options)
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
	if spec == nil || spec.flags & {.Noscript, .Admin, .Blocking, .Touches_Arbitrary_Keys} != {} {
		return false
	}
	for key in spec.specs {
		if .Incomplete in key.flags {
			return false
		}
	}
	switch cmd.name {
	case "sort", "sort_ro", "migrate", "flushall", "flushdb", "swapdb", "select", "keys", "scan", "randomkey", "dump", "pfdebug", "pfselftest":
		return false
	case "ping", "echo", "time", "dbsize", "publish", "spublish":
		return true
	}
	id := acl_command_id(spec.name)
	if id >= 0 {
		#partial switch cmd_docs[id].group {
		case .String, .Generic, .Hash, .List, .Set, .Sorted_Set, .Bitmap, .Hyperloglog, .Geo, .Stream:
			return true
		}
	}
	return false
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

lua_inner :: proc(run: ^Lua_Invocation, argv: [][]u8) {
	client := &run.capture
	slot := lookup_entry(argv[0])
	if slot == nil {
		reply_error(client, "ERR Unknown command called from script")
		return
	}
	cmd, hot := slot.cmd, slot.stats
	spec := cmd_spec_lookup(cmd, argv)
	if !arity_ok(cmd.arity, len(argv)) || (spec != nil && !arity_ok(int(spec.arity), len(argv))) {
		reply_wrong_args(client, cmd.name)
		stat_reject(hot, argv)
		return
	}
	if !lua_handler_allowed(cmd, spec) {
		reply_error(client, "ERR This command is not allowed from this script")
		stat_reject(hot, argv)
		return
	}
	id := acl_command_id(spec.name)
	if id < 0 {
		reply_error(client, "ERR Script command has no ACL metadata")
		return
	}
	permission, position := acl_check_user(run.source.user, int(id), argv)
	if permission != .Ok {
		acl_log_add(run.source, permission, .Lua, argv, position, nil, transmute([]u8)spec.name if permission == .Cmd else nil)
		reply_error(client, "NOPERM This user has no permissions to run the command or access its keys or channels from a script")
		stat_reject(hot, argv)
		return
	}
	writing := lua_command_writes(cmd, spec, argv)
	if run.readonly && writing {
		reply_error(client, "ERR Write commands are not allowed from read-only scripts")
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
					bound += u128(len(argv[key_position])) + lua_store_reply_bound(run.source.db, argv[key_position])
				}
			}
			delete(keys)
		}
		if bound > u128(run.capture_limit) {
			run.capture_failed = true
			return
		}
	}
	if .Denyoom in spec.flags && !run.wrote && maxmemory_bytes > 0 && u64(max(0, mem_used()-mem_not_counted())) > maxmemory_bytes {
		reply_error(client, ERR_OOM)
		stat_reject(hot, argv)
		return
	}
	if persist_gate(client, cmd) {
		stat_reject(hot, argv)
		return
	}
	saved_db, saved_touch, saved_stat, saved_deny := db_cur, store_no_touch, stat_cur, deny_blocking
	defer {
		db_cur, store_no_touch, stat_cur, deny_blocking = saved_db, saved_touch, saved_stat, saved_deny
	}
	db_cur, store_no_touch, deny_blocking = run.source.db, .No_Touch in run.source.flags && cmd.handler != cmd_touch, true
	client.last_cmd = cmd.name
	dirty := pst.dirty
	if aof.feed {
		aof_cmd_begin(client, cmd, argv)
	}
	stat_cur = &hot.stats
	pst.dirty_explicit = false
	start := mono_now()
	cmd.handler(client, argv)
	stat_call_slow(client, cmd, hot, argv, mono_now()-start)
	if client.blocked != .None || client.compute != nil || client.keyspace != nil {
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
	run.capture = Conn{fd = -1, resp = u8(resp), db = run.source.db, user = run.source.user, authed = true, ever_authed = true, flags = run.source.flags}
	copy(run.capture.addr[:], "lua")
	run.capture.addr_len = 3
	run.capture_limit = min(int(lua_max_output), int(lua_max_bridge_memory)-run.host_bytes-run.temporary_bytes)
	lua_inner(run, argv)
	result := lr.Result{data = run.capture.wbuf, len = c.size_t(run.capture.wlen), write_effect = 1 if run.wrote else 0}
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
			entry = lua_cache_find(digest)
		}
		if entry == nil {
			reply_error(client, LUA_ERR_NOSCRIPT)
			return
		}
	} else {
		if !lua_source_compile(client, argv[1]) {
			return
		}
		entry = lua_cache_store(argv[1], false)
		if entry == nil {
			reply_error(client, "OOM Lua source cache limit exceeded")
			return
		}
	}
	keyspace_fence()
	text, header_readonly, header_err := lua_source_text(entry.body)
	if header_err != "" {
		reply_error(client, header_err)
		return
	}
	run := Lua_Invocation{source = client, readonly = readonly || header_readonly, start = mono_now(), frozen_ms = srv.now_ms}
	run.temporary_bytes = (len(argv)-3)*size_of(lr.Arg)
	if run.temporary_bytes > int(lua_max_bridge_memory) {
		reply_error(client, "OOM Lua bridge argument limit exceeded")
		return
	}
	arguments := make([]lr.Arg, len(argv)-3)
	for value, i in argv[3:] {
		arguments[i] = lua_arg(value)
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
		delete(arguments)
		lua_busy_destroy(&run.busy)
	}
	options := lua_options()
	callbacks := lr.Callbacks{command = lua_command_callback, busy = lua_busy_callback, log = lua_log_callback, opaque = &run}
	keys := raw_data(arguments)
	args := raw_data(arguments[int(numkeys):])
	argument_count := len(arguments)-int(numkeys)
	result := lr.eval(lua_arg(text), c.size_t(numkeys), keys, c.size_t(argument_count), args, i32(client.resp), &options, &callbacks)
	defer lr.free_result(&result)
	lua_note_runtime(&run, &result.stats)
	client.atime_ms = max(client.atime_ms, lua_connection_clock())
	lua_result_reply(client, &result)
}

cmd_eval :: proc(client: ^Conn, argv: [][]u8) { lua_eval_common(client, argv, false, false) }
cmd_evalsha :: proc(client: ^Conn, argv: [][]u8) { lua_eval_common(client, argv, true, false) }
cmd_eval_ro :: proc(client: ^Conn, argv: [][]u8) { lua_eval_common(client, argv, false, true) }
cmd_evalsha_ro :: proc(client: ^Conn, argv: [][]u8) { lua_eval_common(client, argv, true, true) }

lua_script_kill :: proc(client: ^Conn) {
	if lua_active == nil {
		reply_error(client, "NOTBUSY No scripts in execution right now.")
	} else if lua_active.wrote {
		reply_error(client, LUA_ERR_UNKILLABLE)
	} else {
		lua_active.killed = true
		reply_ok(client)
	}
}

lua_script_help := [?]string{
	"SCRIPT <subcommand> [arguments]",
	"LOAD <script> -- Compile and cache source without executing it.",
	"EXISTS <sha1> [<sha1> ...] -- Return cache membership for each digest.",
	"FLUSH [SYNC|ASYNC] -- Remove cached source programs.",
	"KILL -- Stop a running script before it has performed writes.",
	"HELP -- Return this help.",
}

cmd_script :: proc(client: ^Conn, argv: [][]u8) {
	sub := argv[1]
	switch {
	case eq_nocase(sub, "load"):
		if len(argv) != 3 {
			reply_wrong_args(client, "script|load")
			return
		}
		if !lua_source_compile(client, argv[2]) {
			return
		}
		entry := lua_cache_store(argv[2], true)
		if entry == nil {
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
			reply_int(client, 1 if ok && lua_cache_find(digest) != nil else 0)
		}
	case eq_nocase(sub, "flush"):
		asynchronous := cfg.lazyfree_lazy_user_flush
		if len(argv) == 3 && (eq_nocase(argv[2], "sync") || eq_nocase(argv[2], "async")) {
			asynchronous = eq_nocase(argv[2], "async")
		} else if len(argv) != 2 {
			reply_error(client, ERR_SYNTAX)
			return
		}
		lua_cache_flush(asynchronous)
		reply_ok(client)
	case eq_nocase(sub, "kill"):
		if len(argv) != 2 {
			reply_wrong_args(client, "script|kill")
			return
		}
		lua_script_kill(client)
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
	{"eval", cmd_eval, -3},
	{"evalsha", cmd_evalsha, -3},
	{"eval_ro", cmd_eval_ro, -3},
	{"evalsha_ro", cmd_evalsha_ro, -3},
	{"script", cmd_script, -2},
}

@(init)
register_lua_commands :: proc "contextless" () {
	register_commands(lua_commands[:])
}
