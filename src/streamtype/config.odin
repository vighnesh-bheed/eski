package streamtype

Config_Param :: enum u8 {
	None,
	Node_Max_Bytes,
	Node_Max_Entries,
}

CONFIG_NAMES := [Config_Param]string {
	.None             = "",
	.Node_Max_Bytes   = "stream-node-max-bytes",
	.Node_Max_Entries = "stream-node-max-entries",
}

CONFIG_RANGE_ERROR :: "argument must be between 0 and 9223372036854775807 inclusive"

@(private)
CONFIG_NOT_INTEGER :: "argument couldn't be parsed into an integer"

@(private)
CONFIG_NOT_MEMORY :: "argument must be a memory value"

config_param :: proc "contextless" (name: []u8) -> Config_Param {
	if eq_nocase(name, CONFIG_NAMES[.Node_Max_Bytes]) {
		return .Node_Max_Bytes
	}
	if eq_nocase(name, CONFIG_NAMES[.Node_Max_Entries]) {
		return .Node_Max_Entries
	}
	return .None
}

config_value :: proc "contextless" (p: Config_Param) -> i64 {
	switch p {
	case .Node_Max_Bytes:
		return i64(stream_node_max_bytes)
	case .Node_Max_Entries:
		return stream_node_max_entries
	case .None:
	}
	return 0
}

@(private)
memory_units :: proc "contextless" (s: []u8) -> (digits: []u8, mult: u64, ok: bool) {
	n := len(s)
	if n == 0 {
		return
	}
	units := [?]struct {
		suffix: string,
		mult:   u64,
	} {
		{"gb", 1024 * 1024 * 1024},
		{"mb", 1024 * 1024},
		{"kb", 1024},
		{"g", 1000 * 1000 * 1000},
		{"m", 1000 * 1000},
		{"k", 1000},
		{"b", 1},
	}
	for u in units {
		l := len(u.suffix)
		if n > l && eq_nocase(s[n - l:], u.suffix) {
			return s[:n - l], u.mult, true
		}
	}
	return s, 1, true
}

@(private)
parse_memory :: proc "contextless" (s: []u8) -> (v: u64, ok: bool) {
	digits, mult, good := memory_units(s)
	if !good || len(digits) == 0 {
		return
	}
	acc: u64
	for c in digits {
		if c < '0' || c > '9' {
			return
		}
		d := u64(c - '0')
		if acc > (max(u64) - d) / 10 {
			return
		}
		acc = acc * 10 + d
	}
	if mult != 1 && acc > max(u64) / mult {
		return
	}
	return acc * mult, true
}

config_parse :: proc "contextless" (p: Config_Param, s: []u8) -> (v: i64, err: string) {
	switch p {
	case .Node_Max_Bytes:
		m, ok := parse_memory(s)
		if !ok {
			return 0, CONFIG_NOT_MEMORY
		}
		if m > u64(max(i64)) {
			return 0, CONFIG_RANGE_ERROR
		}
		return i64(m), ""
	case .Node_Max_Entries:
		n, ok := parse_ll(s)
		if !ok {
			return 0, CONFIG_NOT_INTEGER
		}
		if n < 0 {
			return 0, CONFIG_RANGE_ERROR
		}
		return n, ""
	case .None:
	}
	return 0, CONFIG_NOT_INTEGER
}

config_apply :: proc "contextless" (p: Config_Param, v: i64) {
	switch p {
	case .Node_Max_Bytes:
		stream_node_max_bytes = int(v)
	case .Node_Max_Entries:
		stream_node_max_entries = v
	case .None:
	}
}
