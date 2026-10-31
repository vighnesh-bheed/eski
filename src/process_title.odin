package main

import "base:runtime"
import "core:os"
import "core:sys/posix"

process_title_region: []u8
process_title_memory: []u8
process_title_original: string

process_title_prepare :: proc() -> bool {
	if len(process_title_region) > 0 {
		return true
	}
	if len(runtime.args__) == 0 || runtime.args__[0] == nil {
		return false
	}
	start := uintptr(rawptr(runtime.args__[0]))
	end := start
	contiguous := true
	total := 0
	for arg in runtime.args__ {
		n := len(arg) + 1
		total += n
		if contiguous && uintptr(rawptr(arg)) == end {
			end += uintptr(n)
		} else {
			contiguous = false
		}
	}
	environment_count := 0
	if posix.environ != nil {
		for posix.environ[environment_count] != nil {
			entry := posix.environ[environment_count]
			n := len(entry) + 1
			total += n
			if contiguous && uintptr(rawptr(entry)) == end {
				end += uintptr(n)
			} else {
				contiguous = false
			}
			environment_count += 1
		}
	}
	if end <= start + 1 {
		return false
	}
	config_address := uintptr(raw_data(config_file))
	preserve_config := config_address >= start && config_address < end
	if preserve_config {
		total += len(config_file) + 1
	}
	memory := make([]u8, total, runtime.heap_allocator())
	arguments := make([]cstring, len(runtime.args__), runtime.heap_allocator())
	defer delete(arguments, runtime.heap_allocator())
	environment := make([]cstring, environment_count, runtime.heap_allocator())
	defer delete(environment, runtime.heap_allocator())
	used := 0
	for arg, i in runtime.args__ {
		n := len(arg)
		copy(memory[used:used + n], string(arg))
		arguments[i] = cstring(&memory[used])
		used += n + 1
	}
	for i in 0 ..< environment_count {
		entry := posix.environ[i]
		n := len(entry)
		copy(memory[used:used + n], string(entry))
		environment[i] = cstring(&memory[used])
		used += n + 1
	}
	if preserve_config {
		n := len(config_file)
		copy(memory[used:used + n], config_file)
		config_file = string(memory[used:used + n])
	}
	info_preserve_executable(start, end)
	for arg, i in arguments {
		runtime.args__[i] = arg
		if i < len(os.args) {
			os.args[i] = string(arg)
		}
	}
	for entry, i in environment {
		posix.environ[i] = entry
	}
	process_title_memory = memory
	process_title_original = string(arguments[0])
	process_title_region = ([^]u8)(rawptr(start))[:int(end - start)]
	return true
}

process_title_write :: proc(title: string) {
	if len(process_title_region) == 0 {
		return
	}
	n := min(len(title), len(process_title_region) - 1)
	for i in 0 ..< n {
		if title[i] == 0 {
			n = i
			break
		}
	}
	for &byte in process_title_region {
		byte = 0
	}
	copy(process_title_region[:n], title[:n])
}

process_title_init :: proc() {
	if cfg.set_proc_title && process_title_prepare() {
		process_title_refresh()
	}
}

process_title_refresh :: proc() {
	if !cfg.set_proc_title || len(process_title_region) == 0 {
		return
	}
	title := make([dynamic]u8, context.temp_allocator)
	if proc_title_expand(&title, transmute([]u8)cfg.proc_title_template, process_title_original) {
		process_title_write(trim_set(string(title[:]), " "))
	}
}

config_apply_proc_title :: proc() -> string {
	process_title_refresh()
	return ""
}
