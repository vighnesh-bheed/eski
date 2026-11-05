package lua_runtime

import "base:runtime"
import "core:c"
import "core:testing"

Native_Test_State :: struct {
	latest: [^]u8,
	calls: int,
	frees: int,
	busy_calls: int,
	abort_after: int,
	mode: int,
	valid: bool,
	observed_write: bool,
}

native_arg :: proc(text: string) -> Arg {
	return Arg{raw_data(transmute([]u8)text), c.size_t(len(text))}
}

native_options :: proc() -> Options {
	return Options{memory_limit = 4*1024*1024, output_limit = 4096, max_depth = 32, hook_count = 100, instruction_limit = 10_000_000}
}

native_eval :: proc(source: string, resp: i32 = 2, options: ^Options = nil, callbacks: ^Callbacks = nil) -> Result {
	defaults := native_options()
	selected := options if options != nil else &defaults
	defer reset()
	result := eval(native_arg(source), 0, nil, 0, nil, resp, selected, callbacks)
	return result
}

native_finish :: proc(t: ^testing.T, result: ^Result, status: i32, frame: string = "") {
	testing.expect_value(t, result.status, status)
	testing.expect(t, result.stats.current_bytes <= result.stats.peak_bytes)
	if len(frame) > 0 {
		testing.expect(t, result.data != nil)
		if result.data != nil {
			testing.expect_value(t, string(result.data[:int(result.len)]), frame)
		}
	}
	free_result(result)
	testing.expect(t, result.data == nil && result.len == 0 && result.write_effect == 0 && result.stats.peak_bytes == 0 && result.errors == nil && result.error_count == 0 && result.forwarded_error == 0)
}

native_state_close :: proc(state: ^Native_Test_State) {
	if state.latest != nil {
		runtime.heap_free(state.latest)
		state.latest = nil
		state.frees += 1
	}
}

native_fixed :: proc(frame: string, status: i32 = OK, wrote: i32 = 0) -> Result {
	return Result{data = raw_data(transmute([]u8)frame), len = c.size_t(len(frame)), status = status, write_effect = wrote}
}

native_command :: proc "c" (opaque: rawptr, resp: i32, argc: c.size_t, args: [^]Arg, stats: ^Stats) -> Result {
	context = runtime.default_context()
	state := cast(^Native_Test_State)opaque
	native_state_close(state)
	state.calls += 1
	state.valid = state.valid && (resp == 2 || resp == 3) && argc > 0 && args != nil && stats != nil
	if !state.valid {
		return native_fixed("-ERR invalid native callback input\r\n", BRIDGE)
	}
	state.valid = state.valid && stats.current_bytes > 0 && stats.peak_bytes >= stats.current_bytes
	if state.mode == 1 {
		return native_fixed("$4\r\nx\r\n")
	}
	if state.mode == 2 {
		return native_fixed("-ERR host resource failure\r\n", LIMIT, 1)
	}
	if state.mode == 3 {
		state.valid = state.valid && argc == 8001 && string(args[0].data[:int(args[0].len)]) == "lpush" && string(args[8000].data[:int(args[8000].len)]) == "1"
		return native_fixed(":7999\r\n")
	}
	if state.mode == 4 {
		state.valid = state.valid && argc == 2 && string(args[1].data[:int(args[1].len)]) == "9007199254740991"
		return native_fixed("+OK\r\n")
	}
	if state.mode == 5 {
		return native_fixed("|1\r\n+meta\r\n*2\r\n:1\r\n:2\r\n|0\r\n$2\r\nok\r\n")
	}
	if state.mode == 6 {
		return native_fixed("|0\r\n-WRONGTYPE attributed\r\n")
	}
	if state.mode == 7 {
		return native_fixed("|1\r\n+meta\r\n:1\r\n")
	}
	command := string(args[0].data[:int(args[0].len)])
	if command == "FAIL" {
		return native_fixed("-ERR planned callback failure\r\n")
	}
	if command == "WRITE" {
		return native_fixed("+OK\r\n", OK, 1)
	}
	if command == "WRONGTYPE" {
		return native_fixed("-WRONGTYPE planned type failure\r\n")
	}
	if command == "DENIED" {
		return native_fixed("-NOPERM planned permission failure\r\n")
	}
	if command == "OOM" {
		return native_fixed("-OOM planned memory failure\r\n")
	}
	if command == "ARGUMENTS" {
		expected := []string{"2", "2.0", "0", "0", "2", "2.5", "-2", "-0", "-0.0"}
		state.valid = state.valid && int(argc) == len(expected)+1
		if state.valid {
			for text, index in expected {
				argument := args[index+1]
				state.valid = state.valid && string(argument.data[:int(argument.len)]) == text
			}
		}
		return native_fixed("+OK\r\n")
	}
	if command != "ROUND" {
		state.valid = false
		return native_fixed("-ERR unexpected native command\r\n", BRIDGE)
	}
	state.latest = cast([^]u8)runtime.heap_alloc(14, false)
	if state.latest == nil {
		return native_fixed("-ERR native callback allocation failed\r\n", MEMORY)
	}
	copy(state.latest[:14], "$8\r\nitem0000\r\n")
	value := state.calls
	for digit in 0..<4 {
		state.latest[11-digit] = u8('0'+value%10)
		value /= 10
	}
	return Result{data = state.latest, len = 14}
}

native_busy :: proc "c" (opaque: rawptr, wrote: i32, stats: ^Stats) -> i32 {
	context = runtime.default_context()
	state := cast(^Native_Test_State)opaque
	state.busy_calls += 1
	state.observed_write = state.observed_write || wrote != 0
	state.valid = state.valid && stats != nil
	if stats != nil {
		state.valid = state.valid && stats.current_bytes > 0 && stats.instructions > 0
	}
	if state.abort_after > 0 && state.busy_calls >= state.abort_after {
		return ABORT
	}
	return KILL_READONLY
}

@(test)
ffi_compile_source_only_and_binary_arguments :: proc(t: ^testing.T) {
	options := native_options()
	valid := compile(native_arg("return 7"), &options)
	native_finish(t, &valid, OK, "+OK\r\n")
	for source in ([]string{"local = 7", "\x1bLua\x55\x00binary"}) {
		result := compile(native_arg(source), &options)
		native_finish(t, &result, ERROR)
	}
	key := native_arg("k\x00:\xff")
	argument := native_arg("v\x00:\xfe")
	result := eval(native_arg("return {KEYS[1],ARGV[1]}"), 1, &key, 1, &argument, 2, &options, nil)
	native_finish(t, &result, OK, "*2\r\n$4\r\nk\x00:\xff\r\n$4\r\nv\x00:\xfe\r\n")
	empty := Arg{}
	result = eval(native_arg("return ARGV[1]"), 0, nil, 1, &empty, 2, &options, nil)
	native_finish(t, &result, OK, "$0\r\n\r\n")
}

@(test)
ffi_invalid_arguments_and_failed_initialization_release :: proc(t: ^testing.T) {
	options := native_options()
	bad_source := Arg{len = 3}
	result := eval(bad_source, 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &result, ARGUMENT)
	result = eval(native_arg("return 1"), 1, nil, 0, nil, 2, &options, nil)
	native_finish(t, &result, ARGUMENT)
	result = eval(native_arg("return 1"), 0, nil, 0, nil, 9, &options, nil)
	native_finish(t, &result, ARGUMENT)
	options.memory_limit = 64
	result = native_eval("return 1", options = &options)
	native_finish(t, &result, MEMORY)
	free_result(&result)
	free_result(nil)
}

@(test)
ffi_resource_failures_then_fresh_vm_release :: proc(t: ^testing.T) {
	cases := []struct{source: string, memory, output: c.size_t, depth: u32, status: i32}{
		{"local a={} for i=1,100000 do a[i]=string.rep('x',64) end return a", 128*1024, 4096, 32, MEMORY},
		{"return pcall(function() return string.rep('x',1000000) end)", 128*1024, 4096, 32, MEMORY},
		{"return xpcall(function() return string.rep('x',1000000) end,function() while true do end end)", 128*1024, 4096, 32, MEMORY},
		{"return string.rep('r',512)", 4*1024*1024, 128, 32, LIMIT},
		{"return {{{{{{1}}}}}}", 4*1024*1024, 4096, 4, LIMIT},
		{"local a={} a[1]=a return a", 4*1024*1024, 4096, 32, LIMIT},
	}
	for _ in 0..<8 {
		for item in cases {
			options := native_options()
			options.memory_limit, options.output_limit, options.max_depth = item.memory, item.output, item.depth
			result := native_eval(item.source, options = &options)
			testing.expect(t, result.stats.peak_bytes <= item.memory)
			native_finish(t, &result, item.status)
			fresh := native_eval("return 17")
			native_finish(t, &fresh, OK, ":17\r\n")
		}
	}
}

@(test)
ffi_boolean_protocol_matrix_and_codec_values :: proc(t: ^testing.T) {
	for item in ([]struct{source: string, resp: i32, frame: string}{
		{"return false", 2, "$-1\r\n"},
		{"return true", 2, ":1\r\n"},
		{"return false", 3, "_\r\n"},
		{"return true", 3, ":1\r\n"},
		{"redis.setresp(3) return false", 2, ":0\r\n"},
		{"redis.setresp(3) return true", 2, ":1\r\n"},
		{"redis.setresp(3) return false", 3, "#f\r\n"},
		{"redis.setresp(3) return true", 3, "#t\r\n"},
		{"return cjson.decode([[ [null,\"\\u0000\"] ]])[2]", 2, "$1\r\n\x00\r\n"},
		{"return cmsgpack.unpack('')", 2, "$-1\r\n"},
		{"return cmsgpack.unpack(string.char(146,1,2))", 2, "*2\r\n:1\r\n:2\r\n"},
		{"return bit.bnot(0)", 2, ":-1\r\n"},
		{"return redis.sha1hex('')", 2, "$40\r\nda39a3ee5e6b4b0d3255bfef95601890afd80709\r\n"},
	}) {
		result := native_eval(item.source, item.resp)
		native_finish(t, &result, OK, item.frame)
	}
}

@(test)
ffi_latest_borrowed_callback_response_is_copied :: proc(t: ^testing.T) {
	state := Native_Test_State{valid = true}
	defer native_state_close(&state)
	callbacks := Callbacks{command = native_command, opaque = &state}
	result := native_eval("local a={} for i=1,200 do a[i]=redis.call('ROUND') end return {a[1],a[200]}", callbacks = &callbacks)
	testing.expect(t, state.valid && state.calls == 200 && state.frees == 199)
	native_finish(t, &result, OK, "*2\r\n$8\r\nitem0001\r\n$8\r\nitem0200\r\n")
	native_state_close(&state)
	testing.expect(t, state.latest == nil && state.frees == 200)
}

@(test)
ffi_host_errors_and_malformed_resp_do_not_escape :: proc(t: ^testing.T) {
	for mode in ([]int{1, 2}) {
		state := Native_Test_State{valid = true, mode = mode}
		callbacks := Callbacks{command = native_command, opaque = &state}
		result := native_eval("local ok=pcall(function() redis.call('ROUND') end) return ok", callbacks = &callbacks)
		testing.expect(t, state.valid && state.calls == 1)
		testing.expect_value(t, result.write_effect, i32(1) if mode == 2 else i32(0))
		native_finish(t, &result, BRIDGE)
		native_state_close(&state)
		fresh := native_eval("return 'fresh'")
		native_finish(t, &fresh, OK, "$5\r\nfresh\r\n")
	}
	state := Native_Test_State{valid = true}
	defer native_state_close(&state)
	callbacks := Callbacks{command = native_command, opaque = &state}
	result := native_eval("return redis.pcall('FAIL').err", callbacks = &callbacks)
	native_finish(t, &result, OK, "$28\r\nERR planned callback failure\r\n")
}

@(test)
ffi_readonly_kill_is_sticky_through_pcall_and_xpcall :: proc(t: ^testing.T) {
	for source in ([]string{
		"while true do pcall(function() while true do end end) end",
		"while true do xpcall(function() while true do end end,function() while true do end end) end",
	}) {
		state := Native_Test_State{valid = true}
		callbacks := Callbacks{busy = native_busy, opaque = &state}
		options := native_options()
		options.busy_threshold_ms = 1
		result := native_eval(source, options = &options, callbacks = &callbacks)
		testing.expect(t, state.valid && state.busy_calls > 0 && !state.observed_write)
		native_finish(t, &result, KILLED)
		fresh := native_eval("return 31")
		native_finish(t, &fresh, OK, ":31\r\n")
	}
}

@(test)
ffi_write_effect_blocks_readonly_kill_until_explicit_abort :: proc(t: ^testing.T) {
	state := Native_Test_State{valid = true, abort_after = 2}
	defer native_state_close(&state)
	callbacks := Callbacks{command = native_command, busy = native_busy, opaque = &state}
	options := native_options()
	options.busy_threshold_ms = 1
	result := native_eval("redis.call('WRITE') while true do end", options = &options, callbacks = &callbacks)
	testing.expect(t, state.valid && state.calls == 1 && state.busy_calls >= 2 && state.observed_write)
	testing.expect_value(t, result.write_effect, i32(1))
	native_finish(t, &result, KILLED)
}

@(test)
ffi_fresh_globals_and_sandbox_rejection_release :: proc(t: ^testing.T) {
	for _ in 0..<8 {
		first := native_eval("math.saved=99 return 1")
		native_finish(t, &first, ERROR)
		fresh := native_eval("return math.saved")
		native_finish(t, &fresh, OK, "$-1\r\n")
		metatable := native_eval("return setmetatable({}, {__index=function() return 9 end}).x")
		native_finish(t, &metatable, OK, ":9\r\n")
		for source in ([]string{"return loadfile('file')", "return require('io')", "return collectgarbage('invalid-option')", "rawset(math,'abs',1)"}) {
			result := native_eval(source)
			native_finish(t, &result, ERROR)
		}
	}
}

@(test)
ffi_host_error_origins_and_thrown_tagged_values :: proc(t: ^testing.T) {
	state := Native_Test_State{valid = true}
	defer native_state_close(&state)
	callbacks := Callbacks{command = native_command, opaque = &state}
	cases := []struct{source, frame: string, status: i32}{
		{"return redis.call('FAIL')", "-ERR planned callback failure\r\n", ERROR},
		{"return redis.call('WRONGTYPE')", "-WRONGTYPE planned type failure\r\n", ERROR},
		{"return redis.call('DENIED')", "-NOPERM planned permission failure\r\n", ERROR},
		{"return redis.call('OOM')", "-OOM planned memory failure\r\n", ERROR},
		{"local ok,x=pcall(function() return redis.call('FAIL') end) return {ok,type(x),x}", "*3\r\n$-1\r\n$6\r\nstring\r\n$28\r\nERR planned callback failure\r\n", OK},
		{"local _,x=pcall(function() return redis.call('FAIL') end) error(x,0)", "-ERR ERR planned callback failure\r\n", ERROR},
		{"xpcall(function() redis.call('FAIL') end,function(x) return x end) error('ERR after',0)", "-ERR ERR after\r\n", ERROR},
		{"error('ERR plain',0)", "-ERR ERR plain\r\n", ERROR},
		{"error('WRONGTYPE ordinary',0)", "-ERR WRONGTYPE ordinary\r\n", ERROR},
		{"error(redis.error_reply('CUSTOM tagged'),0)", "-CUSTOM tagged\r\n", ERROR},
		{"error(redis.error_reply('ERR first\\r\\n+second'),0)", "-ERR first  +second\r\n", ERROR},
		{"error(redis.error_reply('ERR left\\0right'),0)", "-ERR left\r\n", ERROR},
		{"error(redis.error_reply(''),0)", "-ERR \r\n", ERROR},
		{"return redis.error_reply('')", "-ERR \r\n", OK},
		{"return {err=''}", "-\r\n", OK},
		{"return redis.error_reply('custom message')", "-custom message\r\n", OK},
		{"return redis.error_reply('-hello')", "-ERR hello\r\n", OK},
		{"return redis.error_reply('-hello world')", "-hello world\r\n", OK},
		{"error({},0)", "-ERR unknown error\r\n", ERROR},
		{"error(nil,0)", "-ERR nil\r\n", ERROR},
		{"error(false,0)", "-ERR false\r\n", ERROR},
		{"error(123,0)", "-ERR 123\r\n", ERROR},
		{"error({err=123},0)", "-123\r\n", ERROR},
	}
	for item in cases {
		result := native_eval(item.source, callbacks = &callbacks)
		native_finish(t, &result, item.status, item.frame)
	}
	testing.expect(t, state.valid)
}

@(test)
ffi_numeric_arguments_preserve_explicit_string_bytes :: proc(t: ^testing.T) {
	state := Native_Test_State{valid = true}
	defer native_state_close(&state)
	callbacks := Callbacks{command = native_command, opaque = &state}
	result := native_eval("return redis.call('ARGUMENTS',2.0,'2.0',tonumber('-0.0'),0.0,2,2.5,-2.0,'-0','-0.0')", callbacks = &callbacks)
	native_finish(t, &result, OK, "+OK\r\n")
	testing.expect(t, state.valid && state.calls == 1)
}

@(test)
ffi_fresh_random_sequences_and_explicit_seed_repeatability :: proc(t: ^testing.T) {
	source := "return {math.random(1,1000000000),math.random(1,1000000000),math.random(1,1000000000),math.random(1,1000000000)}"
	initial := native_eval(source)
	different := false
	for _ in 0..<8 {
		result := native_eval(source)
		if initial.data != nil && result.data != nil {
			different = different || string(initial.data[:int(initial.len)]) != string(result.data[:int(result.len)])
		}
		native_finish(t, &result, OK)
	}
	native_finish(t, &initial, OK)
	testing.expect(t, different)
	seeded_source := "math.randomseed(317,29) return {math.random(1,1000000000),math.random(1,1000000000),math.random(1,1000000000)}"
	seeded := native_eval(seeded_source)
	for _ in 0..<8 {
		result := native_eval(seeded_source)
		testing.expect(t, seeded.data != nil && result.data != nil)
		if seeded.data != nil && result.data != nil {
			testing.expect_value(t, string(result.data[:int(result.len)]), string(seeded.data[:int(seeded.len)]))
		}
		native_finish(t, &result, OK)
	}
	native_finish(t, &seeded, OK)
}

@(test)
ffi_persistent_library_closure_and_metadata :: proc(t: ^testing.T) {
	functions_reset()
	defer functions_reset()
	options := native_options()
	loaded := library_load(native_arg("\nlocal n=0; redis.register_function{function_name='counter', description='persistent', flags={'no-writes'}, callback=function(keys,args) n=n+1; return {n,keys[1],args[1]} end}"), &options)
	testing.expect_value(t, loaded.result.status, OK)
	free_result(&loaded.result)
	testing.expect(t, loaded.library != nil)
	if loaded.library == nil { return }
	defer library_free(loaded.library)
	testing.expect_value(t, library_count(loaded.library), c.size_t(1))
	info := library_info(loaded.library, 0)
	testing.expect_value(t, string(info.name.data[:int(info.name.len)]), "counter")
	testing.expect_value(t, string(info.description.data[:int(info.description.len)]), "persistent")
	testing.expect_value(t, info.flags, u32(1))
	key, argument := native_arg("key"), native_arg("arg")
	for expected in ([]string{"*3\r\n:1\r\n$3\r\nkey\r\n$3\r\narg\r\n", "*3\r\n:2\r\n$3\r\nkey\r\n$3\r\narg\r\n", "*3\r\n:3\r\n$3\r\nkey\r\n$3\r\narg\r\n"}) {
		result := library_call(loaded.library, 0, 1, &key, 1, &argument, 2, &options, nil)
		testing.expect_value(t, result.status, OK)
		testing.expect(t, result.stats.current_bytes > 0 && result.data != nil)
		if result.data != nil { testing.expect_value(t, string(result.data[:int(result.len)]), expected) }
		free_result(&result)
	}
	testing.expect(t, library_stats(loaded.library).current_bytes > 0)
}

@(test)
ffi_library_load_isolation_and_failed_registration :: proc(t: ^testing.T) {
	functions_reset()
	defer functions_reset()
	options := native_options()
	for source in ([]string{
		"return math.random()",
		"redis.call('PING')",
		"redis.register_function('x',function() return 1 end); redis.register_function('x',function() return 2 end)",
		"redis.register_function{function_name='x',callback=function() return 1 end,unknown=1}",
		"return 1",
	}) {
		loaded := library_load(native_arg(source), &options)
		testing.expect_value(t, loaded.result.status, ERROR)
		testing.expect(t, loaded.library == nil)
		free_result(&loaded.result)
	}
}

@(test)
ffi_recursive_reply_uses_lua_stack_limit :: proc(t: ^testing.T) {
	options := native_options()
	options.max_depth = 0
	options.output_limit = 128*1024
	result := native_eval("local a={} a[1]=a return a", options = &options)
	testing.expect_value(t, result.status, OK)
	testing.expect(t, result.data != nil && result.len > 30)
	if result.data != nil && result.len > 30 {
		frame := result.data[:int(result.len)]
		testing.expect_value(t, string(frame[:4]), "*1\r\n")
		tail := "-ERR reached lua stack limit\r\n"
		testing.expect_value(t, string(frame[len(frame)-len(tail):]), tail)
	}
	native_finish(t, &result, OK)
}

@(test)
ffi_eval_engine_configuration_persists_and_resets :: proc(t: ^testing.T) {
	reset()
	defer reset()
	options := native_options()
	first := eval(native_arg("cjson.encode_number_precision(3);return cjson.encode(1/3)"), 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &first, OK, "$5\r\n0.333\r\n")
	second := eval(native_arg("return cjson.encode_number_precision()"), 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &second, OK, ":3\r\n")
	failed := eval(native_arg("error('expected')"), 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &failed, ERROR)
	third := eval(native_arg("return cjson.encode_number_precision()"), 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &third, OK, ":3\r\n")
	testing.expect(t, eval_stats().current_bytes > 0)
	reset()
	testing.expect_value(t, eval_stats().current_bytes, c.size_t(0))
	fresh := eval(native_arg("return cjson.encode_number_precision()"), 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &fresh, OK, ":14\r\n")
}

@(test)
ffi_library_recovers_after_repeated_codec_allocation_failures :: proc(t: ^testing.T) {
	functions_reset()
	defer functions_reset()
	options := native_options()
	options.memory_limit = 128*1024
	options.output_limit = 128*1024
	source := "\nredis.register_function('f',function(keys,args) if args[1]=='oom' then return cjson.encode({string.rep('x',40000)}) elseif args[1]=='msg' then return cmsgpack.unpack(string.char(0xdb,0xff,0xff,0xff,0xff)) else return 17 end end)"
	loaded := library_load(native_arg(source), &options)
	testing.expect_value(t, loaded.result.status, OK)
	free_result(&loaded.result)
	testing.expect(t, loaded.library != nil)
	if loaded.library == nil {
		return
	}
	defer library_free(loaded.library)
	for _ in 0..<64 {
		for mode in ([]string{"oom", "msg"}) {
			argument := native_arg(mode)
			failed := library_call(loaded.library, 0, 0, nil, 1, &argument, 2, &options, nil)
			testing.expect_value(t, failed.status, MEMORY if mode == "oom" else ERROR)
			testing.expect(t, failed.stats.peak_bytes <= options.memory_limit)
			free_result(&failed)
			argument = native_arg("ok")
			recovered := library_call(loaded.library, 0, 0, nil, 1, &argument, 2, &options, nil)
			native_finish(t, &recovered, OK, ":17\r\n")
		}
	}
}

@(test)
ffi_function_runtime_globals_and_coroutine_callbacks :: proc(t: ^testing.T) {
	functions_reset()
	defer functions_reset()
	options := native_options()
	source := "\nlocal function shared() return redis.call('ROUND') end; redis.register_function('probe',function() local co=coroutine.create(function() local f=assert(loadstring('return cjson.encode({1,2})')); return {shared(),f()} end); local ok,value=coroutine.resume(co); if not ok then error(value) end; return value end)"
	loaded := library_load(native_arg(source), &options)
	testing.expect_value(t, loaded.result.status, OK)
	free_result(&loaded.result)
	testing.expect(t, loaded.library != nil)
	if loaded.library == nil {
		return
	}
	defer library_free(loaded.library)
	state := Native_Test_State{valid = true}
	defer native_state_close(&state)
	callbacks := Callbacks{command = native_command, opaque = &state}
	result := library_call(loaded.library, 0, 0, nil, 0, nil, 2, &options, &callbacks)
	native_finish(t, &result, OK, "*2\r\n$8\r\nitem0001\r\n$5\r\n[1,2]\r\n")
	testing.expect(t, state.valid && state.calls == 1)
	coroutine_error := native_eval("local co=coroutine.create(function() return cjson.decode('[') end); return coroutine.resume(co)")
	native_finish(t, &coroutine_error, OK, "$-1\r\n")
	loader := native_eval("local fn=loadstring(string.char(27)..'Lua'); return type(fn)")
	native_finish(t, &loader, OK, "$3\r\nnil\r\n")
}

Native_Debug_State :: struct {
	reads, writes, ends: int,
	mode: int,
	command_calls: int,
	value, logged, timeout, protected, malformed, many_args, eval_value: bool,
}

native_debug_has :: proc(frame: Arg, needle: string) -> bool {
	if frame.data == nil || frame.len < c.size_t(len(needle)) {
		return false
	}
	bytes := frame.data[:int(frame.len)]
	for i in 0..=len(bytes)-len(needle) {
		if string(bytes[i:i+len(needle)]) == needle {
			return true
		}
	}
	return false
}

native_debug_read :: proc "c" (opaque: rawptr) -> Result {
	context = runtime.default_context()
	state := cast(^Native_Debug_State)opaque
	index := state.reads
	state.reads += 1
	if state.mode == 3 {
		return native_fixed("*2\r\n$4\r\neval\r\n$17\r\nwhile true do end\r\n") if index == 0 else native_fixed("*1\r\n$8\r\ncontinue\r\n")
	}
	if state.mode == 5 {
		return native_fixed("*2\r\n$4\r\neval\r\n$66\r\nlocal stop=os.clock()+0.02; while os.clock()<stop do end; return 7\r\n") if index == 0 else native_fixed("*1\r\n$8\r\ncontinue\r\n")
	}
	if state.mode == 4 {
		if index == 0 {
			return native_fixed("*1\r\n$11\r\nhello\x00world\r\n")
		}
		if index == 1 {
			frame := "*101\r\n$5\r\nredis\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n$4\r\ntest\r\n"
			return native_fixed(frame)
		}
		return native_fixed("*1\r\n$8\r\ncontinue\r\n")
	}
	if state.mode == 1 {
		return native_fixed("*1\r\n$8\r\ncontinue\r\n") if index == 0 else native_fixed("*1\r\n$5\r\nabort\r\n")
	}
	switch index {
	case 0:
		return native_fixed("*1\r\n$4\r\nstep\r\n")
	case 1:
		return native_fixed("*2\r\n$5\r\nprint\r\n$1\r\nx\r\n")
	case 2:
		return native_fixed("*2\r\n$4\r\neval\r\n$11\r\nmath.abs=12\r\n")
	case:
		return native_fixed("*1\r\n$8\r\ncontinue\r\n")
	}
}

native_debug_write :: proc "c" (opaque: rawptr, frame: Arg) -> i32 {
	context = runtime.default_context()
	state := cast(^Native_Debug_State)opaque
	state.writes += 1
	state.value = state.value || native_debug_has(frame, "<value> 7")
	state.eval_value = state.eval_value || native_debug_has(frame, "<retval> 7")
	state.logged = state.logged || native_debug_has(frame, "<debug> line 2: 7")
	state.timeout = state.timeout || native_debug_has(frame, "timeout reached") || native_debug_has(frame, "debugger eval timed out")
	state.malformed = state.malformed || native_debug_has(frame, "Unknown Redis Lua debugger command")
	state.many_args = state.many_args || native_debug_has(frame, "Unknown Redis command called from script")
	state.protected = state.protected || native_debug_has(frame, "readonly table")
	if native_debug_has(frame, "<endsession>") {
		state.ends += 1
	}
	return 0 if state.mode == 2 else 1
}

@(test)
ffi_debugger_inspects_steps_and_protects_eval :: proc(t: ^testing.T) {
	state: Native_Debug_State
	callbacks := Callbacks{opaque = &state, debug_read = native_debug_read, debug_write = native_debug_write}
	options := native_options()
	options.debug_mode = 2
	result := native_eval("local x=7\nredis.debug(x)\nreturn x+1", options = &options, callbacks = &callbacks)
	native_finish(t, &result, OK, ":8\r\n")
	testing.expect(t, state.reads == 4 && state.writes >= 5 && state.ends == 1)
	testing.expect(t, state.value && state.logged && state.protected)
}

@(test)
ffi_debugger_infinite_loop_prompts_and_aborts :: proc(t: ^testing.T) {
	state := Native_Debug_State{mode = 1}
	callbacks := Callbacks{opaque = &state, debug_read = native_debug_read, debug_write = native_debug_write}
	options := native_options()
	options.debug_mode = 2
	options.instruction_limit = 0
	options.busy_threshold_ms = 1
	options.identifier = native_arg("debugtest")
	result := native_eval("while true do end", options = &options, callbacks = &callbacks)
	testing.expect(t, state.timeout && state.ends == 1 && state.reads == 2)
	testing.expect(t, native_debug_has(Arg{result.data, result.len}, "script aborted for user request script: debugtest"))
	native_finish(t, &result, KILLED)
}

@(test)
ffi_debugger_disconnect_preserves_sync_and_stops_forked :: proc(t: ^testing.T) {
	for mode in 1..=2 {
		state := Native_Debug_State{mode = 2}
		callbacks := Callbacks{opaque = &state, debug_read = native_debug_read, debug_write = native_debug_write}
		options := native_options()
		options.debug_mode = i32(mode)
		result := native_eval("return 19", options = &options, callbacks = &callbacks)
		if mode == 1 {
			native_finish(t, &result, KILLED)
		} else {
			native_finish(t, &result, OK, ":19\r\n")
		}
		testing.expect(t, state.writes == 1 && state.reads == 0)
	}
}

native_debug_command :: proc "c" (opaque: rawptr, resp: i32, argc: c.size_t, args: [^]Arg, stats: ^Stats) -> Result {
	context = runtime.default_context()
	state := cast(^Native_Debug_State)opaque
	state.command_calls += 1
	if argc != 100 || args == nil || resp != 2 || stats == nil {
		return native_fixed("-ERR Invalid debugger callback arguments\r\n", BRIDGE)
	}
	return native_fixed("-ERR Unknown Redis command called from script\r\n")
}

@(test)
ffi_debugger_eval_timeout_keeps_session_usable :: proc(t: ^testing.T) {
	state := Native_Debug_State{mode = 3}
	callbacks := Callbacks{opaque = &state, debug_read = native_debug_read, debug_write = native_debug_write}
	options := native_options()
	options.debug_mode = 2
	options.busy_threshold_ms = 1
	result := native_eval("return 23", options = &options, callbacks = &callbacks)
	native_finish(t, &result, OK, ":23\r\n")
	testing.expect(t, state.timeout && state.ends == 1 && state.reads == 2)
}

@(test)
ffi_debugger_binary_command_and_many_arguments :: proc(t: ^testing.T) {
	state := Native_Debug_State{mode = 4}
	callbacks := Callbacks{command = native_debug_command, opaque = &state, debug_read = native_debug_read, debug_write = native_debug_write}
	options := native_options()
	options.debug_mode = 2
	result := native_eval("return 29", options = &options, callbacks = &callbacks)
	native_finish(t, &result, OK, ":29\r\n")
	testing.expect(t, state.malformed && state.many_args && state.command_calls == 1 && state.ends == 1)
}

@(test)
ffi_rng_stream_crosses_eval_functions_and_flushes :: proc(t: ^testing.T) {
	reset()
	functions_reset()
	defer reset()
	defer functions_reset()
	options := native_options()
	first := eval(native_arg("math.randomseed(123);return tostring(math.random())"), 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &first, OK, "$16\r\n0.27951200179733\r\n")
	loaded := library_load(native_arg("\nredis.register_function('rng',function()return tostring(math.random())end)"), &options)
	testing.expect_value(t, loaded.result.status, OK)
	free_result(&loaded.result)
	if loaded.library == nil {
		return
	}
	defer library_free(loaded.library)
	second := library_call(loaded.library, 0, 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &second, OK, "$16\r\n0.41452908255836\r\n")
	third := eval(native_arg("return tostring(math.random())"), 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &third, OK, "$15\r\n0.9251758488478\r\n")
	reset()
	functions_reset()
	fourth := eval(native_arg("return tostring(math.random())"), 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &fourth, OK, "$15\r\n0.1295240102939\r\n")
	fifth := library_call(loaded.library, 0, 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &fifth, OK, "$16\r\n0.12416880956114\r\n")
}

@(test)
ffi_functions_share_vm_configuration_and_retire_on_flush :: proc(t: ^testing.T) {
	functions_reset()
	options := native_options()
	handles: [4]rawptr
	defer {
		for handle in handles {
			library_free(handle)
		}
		functions_reset()
	}
	sources := [4]string{
		"\nredis.register_function('cfg_a',function(k,a) if a[1] then cjson.encode_number_precision(tonumber(a[1])) end; return cjson.encode_number_precision() end)",
		"\nredis.register_function('cfg_b',function()return cjson.encode_number_precision()end)",
		"\nredis.register_function('cfg_c',function()return cjson.encode_number_precision()end)",
		"\nredis.register_function('cfg_d',function()return cjson.encode_number_precision()end)",
	}
	for i in 0..<2 {
		loaded := library_load(native_arg(sources[i]), &options)
		testing.expect_value(t, loaded.result.status, OK)
		free_result(&loaded.result)
		handles[i] = loaded.library
		if handles[i] == nil {
			return
		}
	}
	argument := native_arg("3")
	configured := library_call(handles[0], 0, 0, nil, 1, &argument, 2, &options, nil)
	native_finish(t, &configured, OK, ":3\r\n")
	shared := library_call(handles[1], 0, 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &shared, OK, ":3\r\n")
	separate := native_eval("return cjson.encode_number_precision()")
	native_finish(t, &separate, OK, ":14\r\n")
	for i in 0..<2 {
		library_free(handles[i])
		handles[i] = nil
	}
	testing.expect(t, functions_stats().current_bytes > 0)
	loaded_c := library_load(native_arg(sources[2]), &options)
	native_finish(t, &loaded_c.result, OK, "+OK\r\n")
	handles[2] = loaded_c.library
	if handles[2] == nil {
		return
	}
	preserved := library_call(handles[2], 0, 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &preserved, OK, ":3\r\n")
	functions_reset()
	loaded_d := library_load(native_arg(sources[3]), &options)
	native_finish(t, &loaded_d.result, OK, "+OK\r\n")
	handles[3] = loaded_d.library
	if handles[3] == nil {
		return
	}
	fresh := library_call(handles[3], 0, 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &fresh, OK, ":14\r\n")
	retired := library_call(handles[2], 0, 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &retired, OK, ":3\r\n")
}

@(test)
ffi_long_uncaught_eval_error_preserves_message_and_context :: proc(t: ^testing.T) {
	options := native_options()
	options.output_limit = 128*1024
	options.identifier = native_arg("long_eval")
	result := native_eval("error(string.rep('x',10000),0)", options = &options)
	suffix := " script: long_eval, on @user_script:1.\r\n"
	testing.expect_value(t, result.status, ERROR)
	testing.expect_value(t, int(result.len), 5+10000+len(suffix))
	if result.data != nil && result.len == c.size_t(5+10000+len(suffix)) {
		frame := result.data[:int(result.len)]
		testing.expect_value(t, string(frame[:5]), "-ERR ")
		for byte in frame[5:10005] {
			testing.expect_value(t, byte, u8('x'))
		}
		testing.expect_value(t, string(frame[10005:]), suffix)
	}
	native_finish(t, &result, ERROR)
	cases := []struct{source, frame: string}{
		{"error('hello\\0world',0)", "-ERR hello script: long_eval, on @user_script:1.\r\n"},
		{"return redis.error_reply('hello')", "-ERR hello\r\n"},
		{"return redis.error_reply('hello world')", "-hello world\r\n"},
		{"return redis.error_reply('hello\\0 world')", "-ERR hello\r\n"},
		{"return redis.status_reply('hello\\0world')", "+hello\r\n"},
		{"return {err='hello\\0world'}", "-hello\r\n"},
	}
	for item in cases {
		checked := native_eval(item.source, options = &options)
		native_finish(t, &checked, ERROR if item.source[0] == 'e' else OK, item.frame)
	}
}

@(test)
ffi_long_function_error_and_output_limit_recovery :: proc(t: ^testing.T) {
	functions_reset()
	defer functions_reset()
	options := native_options()
	options.output_limit = 128*1024
	options.identifier = native_arg("long_error")
	loaded := library_load(native_arg("\nredis.register_function('long_error',function() error(string.rep('y',10000),0) end)"), &options)
	native_finish(t, &loaded.result, OK, "+OK\r\n")
	if loaded.library == nil {
		return
	}
	defer library_free(loaded.library)
	result := library_call(loaded.library, 0, 0, nil, 0, nil, 2, &options, nil)
	suffix := " script: long_error, on @user_function:2.\r\n"
	testing.expect_value(t, int(result.len), 5+10000+len(suffix))
	if result.data != nil && result.len == c.size_t(5+10000+len(suffix)) {
		frame := result.data[:int(result.len)]
		testing.expect_value(t, string(frame[:5]), "-ERR ")
		for byte in frame[5:10005] {
			testing.expect_value(t, byte, u8('y'))
		}
		testing.expect_value(t, string(frame[10005:]), suffix)
	}
	native_finish(t, &result, ERROR)
	options.output_limit = 128
	limited := library_call(loaded.library, 0, 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &limited, LIMIT, "-ERR script output limit exceeded\r\n")
	options.output_limit = 128*1024
	recovered := library_call(loaded.library, 0, 0, nil, 0, nil, 2, &options, nil)
	testing.expect_value(t, recovered.len, c.size_t(5+10000+len(suffix)))
	native_finish(t, &recovered, ERROR)
}

@(test)
ffi_long_compile_error_stays_protected_and_bounded :: proc(t: ^testing.T) {
	source := make([]u8, 10009)
	defer delete(source)
	copy(source[:9], "return 1 ")
	for i in 9..<len(source) {
		source[i] = 'a'
	}
	options := native_options()
	options.output_limit = 128*1024
	result := compile(Arg{raw_data(source), c.size_t(len(source))}, &options)
	testing.expect(t, result.data != nil && result.len > 10000)
	native_finish(t, &result, ERROR)
	options.output_limit = 128
	limited := compile(Arg{raw_data(source), c.size_t(len(source))}, &options)
	native_finish(t, &limited, LIMIT, "-ERR script output limit exceeded\r\n")
}

@(test)
ffi_cjson_new_coroutine_allocation_failure_and_recovery :: proc(t: ^testing.T) {
	functions_reset()
	defer functions_reset()
	options := native_options()
	options.memory_limit = 128*1024
	options.output_limit = 128*1024
	source := "\nlocal json;redis.register_function('newjson',function(k,a) if not json then json=cjson.new();json.encode_number_precision(3) end; local co=coroutine.create(function() if a[1]=='oom' then return json.encode({string.rep('x',40000)}) elseif a[1]=='msg' then return json.decode('[') else return json.encode(1/3) end end);local ok,value=coroutine.resume(co);if not ok then return false end;return value end)"
	loaded := library_load(native_arg(source), &options)
	native_finish(t, &loaded.result, OK, "+OK\r\n")
	if loaded.library == nil {
		return
	}
	defer library_free(loaded.library)
	for _ in 0..<32 {
		for mode in ([]string{"msg", "oom", "ok"}) {
			argument := native_arg(mode)
			result := library_call(loaded.library, 0, 0, nil, 1, &argument, 2, &options, nil)
			testing.expect(t, result.stats.peak_bytes <= options.memory_limit)
			if mode == "oom" {
				native_finish(t, &result, MEMORY)
			} else {
				native_finish(t, &result, OK, "$-1\r\n" if mode == "msg" else "$5\r\n0.333\r\n")
			}
		}
	}
}

@(test)
ffi_debugger_default_eval_runs_beyond_prompt_threshold :: proc(t: ^testing.T) {
	state := Native_Debug_State{mode = 5}
	callbacks := Callbacks{opaque = &state, debug_read = native_debug_read, debug_write = native_debug_write}
	options := native_options()
	options.debug_mode = 2
	options.instruction_limit = 0
	options.busy_threshold_ms = 1
	result := native_eval("return 31", options = &options, callbacks = &callbacks)
	native_finish(t, &result, OK, ":31\r\n")
	testing.expect(t, state.eval_value && !state.timeout && state.ends == 1 && state.reads == 2)
}

@(test)
ffi_reference_fields_dump_and_internal_error_descriptor :: proc(t: ^testing.T) {
	cases := []struct{source, frame: string}{
		{"return {redis.REPL_SLAVE,type(string.dump),type(rawget(_G,'__redis__err__handler'))}", "*3\r\n:2\r\n$8\r\nfunction\r\n$8\r\nfunction\r\n"},
		{"local bytes=string.dump(function()return 1 end);local fn=loadstring(bytes);return {type(bytes),string.byte(bytes,1),type(fn)}", "*3\r\n$6\r\nstring\r\n:27\r\n$3\r\nnil\r\n"},
		{"return __redis__err__handler('hello').err", "$9\r\nERR hello\r\n"},
		{"return __redis__err__handler('a\\0b').err", "$7\r\nERR a\x00b\r\n"},
		{"return __redis__err__handler({}).err", "$-1\r\n"},
		{"local t={err='CUSTOM hi',extra=7};local r=__redis__err__handler(t);return {r==t,r.err,r.source,r.line,r.extra}", "*5\r\n:1\r\n$9\r\nCUSTOM hi\r\n$12\r\n@user_script\r\n:1\r\n:7\r\n"},
	}
	for item in cases {
		result := native_eval(item.source)
		native_finish(t, &result, OK, item.frame)
	}
	functions_reset()
	defer functions_reset()
	options := native_options()
	loaded := library_load(native_arg("\nredis.register_function('fields',function()return {type(rawget(_G,'__redis__err__handler')),type(string.dump),redis.REPL_SLAVE}end)"), &options)
	native_finish(t, &loaded.result, OK, "+OK\r\n")
	if loaded.library == nil {
		return
	}
	defer library_free(loaded.library)
	called := library_call(loaded.library, 0, 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &called, OK, "*3\r\n$3\r\nnil\r\n$8\r\nfunction\r\n:2\r\n")
}

@(test)
ffi_helper_errors_preserve_call_site_names_and_loaded_sources :: proc(t: ^testing.T) {
	cases := []struct{source, frame: string}{
		{"return cjson.encode()", "-ERR user_script:1: bad argument #1 to 'encode' (expected 1 argument)\r\n"},
		{"return cjson.decode('[')", "-ERR user_script:1: Expected value but found T_END at character 2\r\n"},
		{"return cmsgpack.unpack()", "-ERR user_script:1: bad argument #1 to 'unpack' (string expected, got no value)\r\n"},
		{"return bit.band()", "-ERR user_script:1: bad argument #1 to 'band' (number expected, got no value)\r\n"},
		{"return struct.pack()", "-ERR user_script:1: bad argument #1 to 'pack' (string expected, got no value)\r\n"},
		{"local f=cjson.encode;return f()", "-ERR user_script:1: bad argument #1 to 'f' (expected 1 argument)\r\n"},
	}
	for item in cases {
		result := native_eval(item.source)
		native_finish(t, &result, ERROR, item.frame)
	}
	options := native_options()
	options.identifier = native_arg("loaded_error")
	loaded := native_eval("local f=loadstring([[error('x',0)]],'@loaded');return f()", options = &options)
	native_finish(t, &loaded, ERROR, "-ERR x script: loaded_error, on @loaded:1.\r\n")
	compiled := compile(native_arg("return = 1"), &options)
	native_finish(t, &compiled, ERROR, "-ERR Error compiling script (new function): user_script:1: unexpected symbol near '='\r\n")
}

@(test)
ffi_unpack_range_checks_preserve_vm_liveness :: proc(t: ^testing.T) {
	for source in ([]string{
		"return {unpack({1,2,3}, -2, 2147483647)}",
		"return {unpack({1,2,3}, 0, 2147483647)}",
		"return {unpack({1,2,3}, -2147483648, -2)}",
	}) {
		result := native_eval(source)
		native_finish(t, &result, ERROR)
	}
	for source in ([]string{
		"return select('#',unpack({},2147483647,2147483647))",
		"return select('#',unpack({},-2147483648,-2147483648))",
	}) {
		result := native_eval(source)
		native_finish(t, &result, OK, ":1\r\n")
	}
	valid := native_eval("return {unpack({1,2,3},1,3)}")
	native_finish(t, &valid, OK, "*3\r\n:1\r\n:2\r\n:3\r\n")
}

@(test)
ffi_function_registration_rejects_case_collisions :: proc(t: ^testing.T) {
	functions_reset()
	defer functions_reset()
	options := native_options()
	loaded := library_load(native_arg("redis.register_function('CaseName',function()end);redis.register_function('casename',function()end)"), &options)
	if loaded.library != nil { library_free(loaded.library) }
	native_finish(t, &loaded.result, ERROR)
}

@(test)
ffi_large_command_argument_stack_and_precision :: proc(t: ^testing.T) {
	large := Native_Test_State{mode = 3, valid = true}
	callbacks := Callbacks{command = native_command, opaque = &large}
	result := native_eval("local a={};for i=1,7999 do a[i]=1 end;return redis.call('lpush','l',unpack(a))", callbacks = &callbacks)
	native_finish(t, &result, OK, ":7999\r\n")
	testing.expect(t, large.valid && large.calls == 1)
	precise := Native_Test_State{mode = 4, valid = true}
	callbacks.opaque = &precise
	result = native_eval("return redis.call('ARGUMENTS',9007199254740991)", callbacks = &callbacks)
	native_finish(t, &result, OK, "+OK\r\n")
	testing.expect(t, precise.valid && precise.calls == 1)
}

@(test)
ffi_attributes_are_ignored_and_attributed_errors_retain_origin :: proc(t: ^testing.T) {
	state := Native_Test_State{mode = 5, valid = true}
	callbacks := Callbacks{command = native_command, opaque = &state}
	result := native_eval("redis.setresp(3);return redis.call('ATTR')", callbacks = &callbacks)
	native_finish(t, &result, OK, "$2\r\nok\r\n")
	state.mode = 6
	result = native_eval("return redis.call('ATTR')", callbacks = &callbacks)
	testing.expect_value(t, result.forwarded_error, i32(1))
	native_finish(t, &result, ERROR, "-WRONGTYPE attributed\r\n")
	result = native_eval("local e=redis.pcall('ATTR');return {e.err,e.ignore_error_stats_update}", callbacks = &callbacks)
	native_finish(t, &result, OK, "*2\r\n$20\r\nWRONGTYPE attributed\r\n:1\r\n")
	state.mode = 7
	result = native_eval("return redis.call('ATTR')", callbacks = &callbacks)
	native_finish(t, &result, BRIDGE)
	result = native_eval("return 17")
	native_finish(t, &result, OK, ":17\r\n")
}

@(test)
ffi_bignum_reply_text_is_sanitized_and_error_stats_flag_is_boolean :: proc(t: ^testing.T) {
	for resp in ([]i32{2, 3}) {
		result := native_eval("return {big_number='123\\r\\n123'}", resp)
		native_finish(t, &result, OK, "$8\r\n123  123\r\n" if resp == 2 else "(123  123\r\n")
		result = native_eval("return {big_number=''}", resp)
		native_finish(t, &result, OK, "$0\r\n\r\n" if resp == 2 else "(\r\n")
	}
	for item in ([]struct{source: string, forwarded: i32}{
		{"return {err='ERR manual',ignore_error_stats_update=true}", 1},
		{"return {err='ERR manual',ignore_error_stats_update=false}", 0},
		{"return {err='ERR manual',ignore_error_stats_update=1}", 0},
		{"return {err='ERR manual',ignore_error_stats_update=0}", 0},
		{"return {err='ERR manual',ignore_error_stats_update=nil}", 0},
	}) {
		result := native_eval(item.source)
		testing.expect_value(t, result.forwarded_error, item.forwarded)
		native_finish(t, &result, OK, "-ERR manual\r\n")
	}
}

@(test)
ffi_deprecated_environment_apis_are_explicitly_enabled :: proc(t: ^testing.T) {
	options := native_options()
	options.enable_deprecated_api = 1
	result := native_eval("local f=function()return value end;local e={value=7};setfenv(f,e);return {f(),getfenv(f)==e,type(newproxy(true))}", options = &options)
	native_finish(t, &result, OK, "*3\r\n:7\r\n:1\r\n$8\r\nuserdata\r\n")
	result = native_eval("return getfenv")
	native_finish(t, &result, ERROR)
}

@(test)
ffi_nested_error_metadata_outlives_function_vm_and_failed_output_cleans_it :: proc(t: ^testing.T) {
	functions_reset()
	defer functions_reset()
	baseline := detached_memory()
	options := native_options()
	loaded := library_load(native_arg("redis.register_function('nested',function()return {redis.error_reply('ERR fresh'),redis.pcall('WRONGTYPE'),{err='CUSTOM ignored',ignore_error_stats_update=true}}end)"), &options)
	native_finish(t, &loaded.result, OK, "+OK\r\n")
	if loaded.library == nil {
		return
	}
	state := Native_Test_State{valid = true}
	defer native_state_close(&state)
	callbacks := Callbacks{command = native_command, opaque = &state}
	result := library_call(loaded.library, 0, 0, nil, 0, nil, 2, &options, &callbacks)
	functions_reset()
	library_free(loaded.library)
	testing.expect_value(t, functions_stats().current_bytes, c.size_t(0))
	testing.expect(t, detached_memory() > baseline)
	testing.expect_value(t, result.error_count, c.size_t(3))
	if result.errors != nil && result.error_count == 3 && result.data != nil {
		messages := []string{"ERR fresh", "WRONGTYPE planned type failure", "CUSTOM ignored"}
		for event, i in result.errors[:3] {
			testing.expect_value(t, string(result.data[int(event.offset):int(event.offset+event.len)]), messages[i])
			testing.expect_value(t, event.forwarded, i32(0 if i == 0 else 1))
		}
	}
	native_finish(t, &result, OK, "*3\r\n-ERR fresh\r\n-WRONGTYPE planned type failure\r\n-CUSTOM ignored\r\n")
	testing.expect_value(t, detached_memory(), baseline)
	result = native_eval("return {{err='ERR partial'},string.rep('x',8192)}")
	testing.expect(t, result.errors == nil && result.error_count == 0)
	native_finish(t, &result, LIMIT)
	testing.expect_value(t, detached_memory(), baseline)
}

native_cached :: proc(source, digest: string, options: ^Options, callbacks: ^Callbacks = nil) -> Result {
	return eval_cached(native_arg(source), native_arg(digest), 0, nil, 0, nil, 2, options, callbacks)
}

native_same :: proc(t: ^testing.T, expected, actual: ^Result) {
	testing.expect_value(t, actual.status, expected.status)
	testing.expect_value(t, actual.forwarded_error, expected.forwarded_error)
	testing.expect(t, expected.data != nil && actual.data != nil)
	if expected.data != nil && actual.data != nil {
		testing.expect_value(t, string(actual.data[:int(actual.len)]), string(expected.data[:int(expected.len)]))
	}
	free_result(expected)
	free_result(actual)
}

@(test)
ffi_cached_eval_compiles_once_and_runs_until_forgotten :: proc(t: ^testing.T) {
	reset()
	defer reset()
	options := native_options()
	prepared := eval_prepare(native_arg("return 1+1"), native_arg("once"), &options)
	native_finish(t, &prepared, OK, "+OK\r\n")
	testing.expect(t, eval_stats().current_bytes > 0)
	testing.expect(t, eval_active_stats().current_bytes > 0 && eval_active_stats().current_bytes < eval_stats().current_bytes)
	result := native_cached("return 99", "once", &options)
	native_finish(t, &result, OK, ":2\r\n")
	prepared = eval_prepare(native_arg("return 98"), native_arg("once"), &options)
	native_finish(t, &prepared, OK, "+OK\r\n")
	result = native_cached("return 99", "once", &options)
	native_finish(t, &result, OK, ":2\r\n")
	eval_forget(native_arg("once"))
	eval_forget(native_arg("never-stored"))
	result = native_cached("return 99", "once", &options)
	native_finish(t, &result, OK, ":99\r\n")
	result = native_cached("return 100", "once", &options)
	native_finish(t, &result, OK, ":99\r\n")
	for value in ([]string{"first", "second"}) {
		key, argument := native_arg(value), native_arg(value)
		keyed := eval_cached(native_arg("return {KEYS[1],ARGV[1],#KEYS,#ARGV}"), native_arg("keyed"), 1, &key, 1, &argument, 2, &options, nil)
		native_finish(t, &keyed, OK, value == "first" ? "*4\r\n$5\r\nfirst\r\n$5\r\nfirst\r\n:1\r\n:1\r\n" : "*4\r\n$6\r\nsecond\r\n$6\r\nsecond\r\n:1\r\n:1\r\n")
	}
	empty := eval_cached(native_arg("return {#KEYS,#ARGV}"), native_arg("keyed-empty"), 0, nil, 0, nil, 2, &options, nil)
	native_finish(t, &empty, OK, "*2\r\n:0\r\n:0\r\n")
	reset()
	testing.expect_value(t, eval_stats().current_bytes, c.size_t(0))
	testing.expect_value(t, eval_active_stats().current_bytes, c.size_t(0))
	result = native_cached("return 7", "once", &options)
	native_finish(t, &result, OK, ":7\r\n")
}

@(test)
ffi_cached_eval_errors_and_globals_match_uncached_eval :: proc(t: ^testing.T) {
	reset()
	defer reset()
	options := native_options()
	for source in ([]string{"return function(", "local = 7", "\x1bLua\x55\x00binary"}) {
		expected := compile(native_arg(source), &options)
		actual := eval_prepare(native_arg(source), native_arg("broken"), &options)
		native_same(t, &expected, &actual)
		recovered := native_cached("return 5", "broken", &options)
		native_finish(t, &recovered, OK, ":5\r\n")
		eval_forget(native_arg("broken"))
	}
	for source in ([]string{"undeclared=1", "return undeclared", "error('planned')", "error({err='CUSTOM table'})", "math.abs=1", "KEYS[1]='x' return KEYS[1]", "local t={} setmetatable(t,{__index=function() return 4 end}) return t.x"}) {
		prepared := eval_prepare(native_arg(source), native_arg(source), &options)
		native_finish(t, &prepared, OK, "+OK\r\n")
		for _ in 0..<2 {
			expected := eval(native_arg(source), 0, nil, 0, nil, 2, &options, nil)
			actual := native_cached(source, source, &options)
			native_same(t, &expected, &actual)
		}
	}
	healthy := native_cached("return 17", "healthy", &options)
	native_finish(t, &healthy, OK, ":17\r\n")
}

@(test)
ffi_cached_eval_restores_the_function_environment_each_call :: proc(t: ^testing.T) {
	reset()
	defer reset()
	options := native_options()
	options.enable_deprecated_api = 1
	source := "local before=type(redis);setfenv(1,{});return before"
	prepared := eval_prepare(native_arg(source), native_arg("environment"), &options)
	native_finish(t, &prepared, OK, "+OK\r\n")
	for _ in 0..<3 {
		result := native_cached(source, "environment", &options)
		native_finish(t, &result, OK, "$5\r\ntable\r\n")
	}
	result := native_cached("return getfenv(1)==_G", "environment-check", &options)
	native_finish(t, &result, OK, ":1\r\n")
}

@(test)
ffi_forgotten_cached_function_is_reclaimed_by_the_collector :: proc(t: ^testing.T) {
	reset()
	defer reset()
	options := native_options()
	collect := "collectgarbage('collect') return 1"
	result := native_cached(collect, "collect", &options)
	native_finish(t, &result, OK, ":1\r\n")
	body := make([dynamic]u8)
	defer delete(body)
	append(&body, "local t={}\n")
	for _ in 0..<2000 {
		append(&body, "t[#t+1]=#t\n")
	}
	append(&body, "return 3")
	prepared := eval_prepare(Arg{raw_data(body[:]), c.size_t(len(body))}, native_arg("large"), &options)
	native_finish(t, &prepared, OK, "+OK\r\n")
	result = native_cached(collect, "collect", &options)
	native_finish(t, &result, OK, ":1\r\n")
	retained := eval_stats().current_bytes
	eval_forget(native_arg("large"))
	result = native_cached(collect, "collect", &options)
	native_finish(t, &result, OK, ":1\r\n")
	released := eval_stats().current_bytes
	testing.expect(t, released+16*1024 < retained)
	result = native_cached("return 4", "large", &options)
	native_finish(t, &result, OK, ":4\r\n")
}

native_reentrant :: proc "c" (opaque: rawptr, resp: i32, argc: c.size_t, args: [^]Arg, stats: ^Stats) -> Result {
	context = runtime.default_context()
	state := cast(^Native_Test_State)opaque
	state.calls += 1
	options := native_options()
	prepared := eval_prepare(native_arg("return 3"), native_arg("inner"), &options)
	state.valid = state.valid && prepared.status == OK
	free_result(&prepared)
	eval_forget(native_arg("outer"))
	nested := eval_cached(native_arg("return 4"), native_arg("inner"), 0, nil, 0, nil, 2, &options, nil)
	state.valid = state.valid && nested.status == ARGUMENT
	free_result(&nested)
	return native_fixed("+OK\r\n")
}

@(test)
ffi_cached_eval_entry_points_do_not_reenter_a_running_script :: proc(t: ^testing.T) {
	reset()
	defer reset()
	options := native_options()
	state := Native_Test_State{valid = true}
	callbacks := Callbacks{command = native_reentrant, opaque = &state}
	result := native_cached("local r=redis.call('INNER') return {r.ok,8}", "outer", &options, &callbacks)
	native_finish(t, &result, OK, "*2\r\n$2\r\nOK\r\n:8\r\n")
	testing.expect(t, state.valid && state.calls == 1)
	result = native_cached("return 9", "outer", &options, &callbacks)
	native_finish(t, &result, OK, "*2\r\n$2\r\nOK\r\n:8\r\n")
	testing.expect(t, state.valid && state.calls == 2)
	result = native_cached("return 5", "inner", &options)
	native_finish(t, &result, OK, ":5\r\n")
}

@(test)
ffi_cached_eval_allocation_failures_stay_protected :: proc(t: ^testing.T) {
	source := "local t={} for i=1,20 do t[i]=string.rep('x',i) end return #t"
	completed := 0
	for limit := c.size_t(1024); limit <= 160*1024; limit += 2*1024 {
		reset()
		options := native_options()
		options.memory_limit = limit
		prepared := eval_prepare(native_arg(source), native_arg("pressure"), &options)
		testing.expect(t, prepared.status == OK || prepared.status == MEMORY)
		testing.expect(t, prepared.stats.peak_bytes <= limit)
		native_finish(t, &prepared, prepared.status)
		result := native_cached(source, "pressure", &options)
		testing.expect(t, result.status == OK || result.status == MEMORY)
		if result.status == OK {
			completed += 1
		}
		native_finish(t, &result, result.status)
		eval_forget(native_arg("pressure"))
		again := native_cached(source, "pressure", &options)
		testing.expect(t, again.status == OK || again.status == MEMORY)
		native_finish(t, &again, again.status)
	}
	testing.expect(t, completed > 0)
	reset()
	testing.expect_value(t, eval_stats().current_bytes, c.size_t(0))
	fresh := native_eval("return 17")
	native_finish(t, &fresh, OK, ":17\r\n")
}
