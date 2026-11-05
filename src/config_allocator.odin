package main

config_check_active_defrag :: proc(v: i64, s: []u8) -> string {
	if v != 0 {
		return "Active defragmentation cannot be enabled: this build uses libc without allocator relocation support."
	}
	return ""
}
