package main

import "core:sys/linux"

RUNTIME_CPU_LIMIT :: 8192
Runtime_CPU_Mask :: [RUNTIME_CPU_LIMIT / 64]u64

Runtime_CPU_Role :: enum {
	Server,
	Bio,
	Rdb,
	Aof_Rewrite,
}

runtime_tuning_number :: proc "contextless" (text: string, at: ^int) -> (value: int, ok: bool) {
	start := at^
	for at^ < len(text) {
		ch := text[at^]
		if ch < '0' || ch > '9' { break }
		digit := int(ch - '0')
		if value > (max(int) - digit) / 10 { return 0, false }
		value = value * 10 + digit
		at^ += 1
	}
	return value, at^ > start
}

runtime_tuning_cpu_list :: proc "contextless" (text: string) -> (mask: Runtime_CPU_Mask, ok: bool) {
	if len(text) == 0 { return {}, true }
	at := 0
	for at < len(text) {
		first, valid := runtime_tuning_number(text, &at)
		if !valid || first >= RUNTIME_CPU_LIMIT { return {}, false }
		last, step := first, 1
		range := false
		if at < len(text) && text[at] == '-' {
			range = true
			at += 1
			last, valid = runtime_tuning_number(text, &at)
			if !valid || last >= RUNTIME_CPU_LIMIT || last < first { return {}, false }
		}
		if at < len(text) && text[at] == ':' {
			if !range { return {}, false }
			at += 1
			step, valid = runtime_tuning_number(text, &at)
			if !valid || step == 0 { return {}, false }
		}
		for cpu := first; cpu <= last; {
			mask[cpu / 64] |= u64(1) << uint(cpu % 64)
			if step > last - cpu { break }
			cpu += step
		}
		if at == len(text) { return mask, true }
		if text[at] != ',' { return {}, false }
		at += 1
		if at == len(text) { return {}, false }
	}
	return {}, false
}

runtime_tuning_cpu_contains :: proc "contextless" (mask: ^Runtime_CPU_Mask, cpu: int) -> bool {
	return cpu >= 0 && cpu < RUNTIME_CPU_LIMIT && mask[cpu / 64] & (u64(1) << uint(cpu % 64)) != 0
}

runtime_tuning_allowed :: proc "contextless" () -> (mask: Runtime_CPU_Mask, err: linux.Errno) {
	_, err = linux.sched_getaffinity(0, size_of(Runtime_CPU_Mask), &mask)
	return
}

runtime_tuning_apply :: proc "contextless" (mask: ^Runtime_CPU_Mask) -> linux.Errno {
	_, err := linux.sched_setaffinity(0, size_of(Runtime_CPU_Mask), mask)
	return err
}

runtime_tuning_enter :: proc(role: Runtime_CPU_Role) -> bool {
	text, name: string
	switch role {
	case .Server: text, name = cfg.server_cpulist, "server-cpulist"
	case .Bio: text, name = cfg.bio_cpulist, "bio-cpulist"
	case .Rdb: text, name = cfg.bgsave_cpulist, "bgsave-cpulist"
	case .Aof_Rewrite: text, name = cfg.aof_rewrite_cpulist, "aof-rewrite-cpulist"
	}
	if len(text) == 0 { return true }
	mask, valid := runtime_tuning_cpu_list(text)
	if !valid {
		plog(LOG_WARNING, "Ignoring invalid ", name, " CPU list; retaining inherited affinity")
		return false
	}
	err := runtime_tuning_apply(&mask)
	if err != .NONE {
		buffer: [24]u8
		n := format_i64(raw_data(buffer[:]), i64(err))
		plog(LOG_WARNING, "Cannot apply ", name, " CPU affinity: ", errno_text(err), " (errno ", string(buffer[:n]), "); retaining inherited affinity")
		return false
	}
	return true
}
