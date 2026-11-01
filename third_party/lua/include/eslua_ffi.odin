package lua_runtime

import "core:c"

Arg :: struct {
	data: [^]u8,
	len: c.size_t,
}

Stats :: struct {
	current_bytes: c.size_t,
	peak_bytes: c.size_t,
	instructions: u64,
	elapsed_ns: u64,
}

Error_Event :: struct {
	offset: c.size_t,
	len: c.size_t,
	forwarded: i32,
}

Result :: struct {
	data: [^]u8,
	len: c.size_t,
	write_effect: i32,
	status: i32,
	stats: Stats,
	forwarded_error: i32,
	errors: [^]Error_Event,
	error_count: c.size_t,
}

OK :: 0
ERROR :: 1
MEMORY :: 2
LIMIT :: 3
KILLED :: 4
ARGUMENT :: 5
BRIDGE :: 6

CONTINUE :: 0
KILL_READONLY :: 1
ABORT :: 2

Options :: struct {
	memory_limit: c.size_t,
	output_limit: c.size_t,
	instruction_limit: u64,
	busy_threshold_ms: u64,
	max_depth: u32,
	hook_count: u32,
	identifier: Arg,
	function_mode: i32,
	debug_mode: i32,
	enable_deprecated_api: i32,
}

Command_Fn :: #type proc "c" (opaque: rawptr, resp: i32, argc: c.size_t, args: [^]Arg, stats: ^Stats) -> Result
Busy_Fn :: #type proc "c" (opaque: rawptr, wrote: i32, stats: ^Stats) -> i32
Log_Fn :: #type proc "c" (opaque: rawptr, level: i32, argc: c.size_t, args: [^]Arg)

ACL_Fn :: #type proc "c" (opaque: rawptr, argc: c.size_t, args: [^]Arg) -> Result
Propagation_Fn :: #type proc "c" (opaque: rawptr, mask: i32) -> i32

Library_Load_Result :: struct {
	library: rawptr,
	result: Result,
}

Function_Info :: struct {
	name: Arg,
	description: Arg,
	flags: u32,
}

Debug_Read_Fn :: #type proc "c" (opaque: rawptr) -> Result
Debug_Write_Fn :: #type proc "c" (opaque: rawptr, frame: Arg) -> i32

Callbacks :: struct {
	command: Command_Fn,
	busy: Busy_Fn,
	log: Log_Fn,
	opaque: rawptr,
	acl_check: ACL_Fn,
	propagation: Propagation_Fn,
	debug_read: Debug_Read_Fn,
	debug_write: Debug_Write_Fn,
}

when .Address in ODIN_SANITIZER_FLAGS {
	foreign import runtime_library {
		"../../.build/lua/address/libeslua-runtime.a",
		"system:m",
	}
} else when .Thread in ODIN_SANITIZER_FLAGS {
	foreign import runtime_library {
		"../../.build/lua/thread/libeslua-runtime.a",
		"system:m",
	}
} else {
	foreign import runtime_library {
		"../../.build/lua/release/libeslua-runtime.a",
		"system:m",
	}
}

@(default_calling_convention = "c", link_prefix = "eslua_")
foreign runtime_library {
	library_load :: proc(source: Arg, options: ^Options) -> Library_Load_Result ---
	library_count :: proc(library: rawptr) -> c.size_t ---
	library_info :: proc(library: rawptr, index: c.size_t) -> Function_Info ---
	library_call :: proc(library: rawptr, index: c.size_t, numkeys: c.size_t, keys: [^]Arg, argc: c.size_t, args: [^]Arg, client_resp: i32, options: ^Options, callbacks: ^Callbacks) -> Result ---
	library_free :: proc(library: rawptr) ---
	library_stats :: proc(library: rawptr) -> Stats ---
	eval :: proc(source: Arg, numkeys: c.size_t, keys: [^]Arg, argc: c.size_t, args: [^]Arg, client_resp: i32, options: ^Options, callbacks: ^Callbacks) -> Result ---
	compile :: proc(source: Arg, options: ^Options) -> Result ---
	free_result :: proc(result: ^Result) ---
	version :: proc() -> cstring ---
	reset :: proc() ---
	functions_reset :: proc() ---
	functions_stats :: proc() -> Stats ---
	functions_active_stats :: proc() -> Stats ---
	eval_stats :: proc() -> Stats ---
	detached_memory :: proc() -> c.size_t ---
}
