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
	return eval(native_arg(source), 0, nil, 0, nil, resp, selected, callbacks)
}

native_finish :: proc(t: ^testing.T, result: ^Result, status: i32, frame: string = "") {
	testing.expect_value(t, result.status, status)
	testing.expect_value(t, result.stats.current_bytes, c.size_t(0))
	if len(frame) > 0 {
		testing.expect(t, result.data != nil)
		if result.data != nil {
			testing.expect_value(t, string(result.data[:int(result.len)]), frame)
		}
	}
	free_result(result)
	testing.expect(t, result.data == nil && result.len == 0 && result.write_effect == 0 && result.stats.peak_bytes == 0)
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
	command := string(args[0].data[:int(args[0].len)])
	if command == "FAIL" {
		return native_fixed("-ERR planned callback failure\r\n")
	}
	if command == "WRITE" {
		return native_fixed("+OK\r\n", OK, 1)
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
		{"local a={} a[1]=a return a", 4*1024*1024, 4096, 32, ERROR},
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
		first := native_eval("math.saved=99 return pcall(function() forbidden_global=3 end)")
		native_finish(t, &first, OK, "$-1\r\n")
		fresh := native_eval("return math.saved")
		native_finish(t, &fresh, OK, "$-1\r\n")
		for source in ([]string{"return load('return 1')", "return getmetatable('x')", "return require('io')", "return collectgarbage()"}) {
			result := native_eval(source)
			native_finish(t, &result, ERROR)
		}
	}
}
