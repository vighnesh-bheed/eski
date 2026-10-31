package main

import "base:runtime"
import "core:os"
import "core:sys/posix"
import "core:testing"

process_title_environment_digest :: proc() -> (count: int, digest: u64) {
	digest = 0xcbf29ce484222325
	if posix.environ != nil {
		for posix.environ[count] != nil {
			for byte in transmute([]u8)string(posix.environ[count]) {
				digest = (digest ~ u64(byte)) * 0x100000001b3
			}
			digest *= 0x100000001b3
			count += 1
		}
	}
	return
}

@(test)
process_title_preserves_arguments_environment_and_real_cmdline :: proc(t: ^testing.T) {
	key := "ESKI_PROCESS_TITLE_LIFETIME_TEST"
	known := "preserved-after-repeated-title-updates"
	testing.expect(t, os.set_env(key, known) == nil)
	defer os.unset_env(key)
	count, digest := process_title_environment_digest()
	arguments := make([]string, len(os.args), runtime.heap_allocator())
	defer {
		for value in arguments {
			delete(value, runtime.heap_allocator())
		}
		delete(arguments, runtime.heap_allocator())
	}
	for value, i in os.args {
		owned := make([]u8, len(value), runtime.heap_allocator())
		copy(owned, value)
		arguments[i] = string(owned)
	}
	if !testing.expect(t, process_title_prepare()) {
		return
	}
	original := make([]u8, len(process_title_region), runtime.heap_allocator())
	copy(original, process_title_region)
	defer {
		copy(process_title_region, original)
		delete(original, runtime.heap_allocator())
	}
	for round in 0 ..< 100 {
		process_title_write("eski title longer than the Linux thread-name limit")
		cmdline, err := os.read_entire_file("/proc/self/cmdline", runtime.heap_allocator())
		if testing.expect(t, err == nil) {
			length := 0
			for length < len(cmdline) && cmdline[length] != 0 {
				length += 1
			}
			testing.expect_value(t, string(cmdline[:length]), "eski title longer than the Linux thread-name limit")
		}
		delete(cmdline, runtime.heap_allocator())
		process_title_write("short")
		testing.expect_value(t, process_title_region[5], u8(0))
		_ = round
	}
	large := make([]u8, len(process_title_region) + 1024, runtime.heap_allocator())
	defer delete(large, runtime.heap_allocator())
	for &byte in large {
		byte = 'L'
	}
	process_title_write(string(large))
	testing.expect_value(t, process_title_region[len(process_title_region) - 1], u8(0))
	process_title_write("final")
	environment_value := os.get_env(key, runtime.heap_allocator())
	defer delete(environment_value, runtime.heap_allocator())
	testing.expect_value(t, environment_value, known)
	for value, i in arguments {
		testing.expect(t, os.args[i] == value)
		testing.expect(t, string(runtime.args__[i]) == value)
	}
	after_count, after_digest := process_title_environment_digest()
	testing.expect_value(t, after_count, count)
	testing.expect_value(t, after_digest, digest)
}
