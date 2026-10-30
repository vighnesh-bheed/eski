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

Result :: struct {
	data: [^]u8,
	len: c.size_t,
	write_effect: i32,
	status: i32,
	stats: Stats,
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
}

Command_Fn :: #type proc "c" (opaque: rawptr, resp: i32, argc: c.size_t, args: [^]Arg, stats: ^Stats) -> Result
Busy_Fn :: #type proc "c" (opaque: rawptr, wrote: i32, stats: ^Stats) -> i32
Log_Fn :: #type proc "c" (opaque: rawptr, level: i32, argc: c.size_t, args: [^]Arg)

Callbacks :: struct {
	command: Command_Fn,
	busy: Busy_Fn,
	log: Log_Fn,
	opaque: rawptr,
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
	eval :: proc(source: Arg, numkeys: c.size_t, keys: [^]Arg, argc: c.size_t, args: [^]Arg, client_resp: i32, options: ^Options, callbacks: ^Callbacks) -> Result ---
	compile :: proc(source: Arg, options: ^Options) -> Result ---
	free_result :: proc(result: ^Result) ---
	version :: proc() -> cstring ---
}
