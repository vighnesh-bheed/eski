package sortwork

sort_flush_sections := []string{"BY patterns", "STORE", "types of sort input against encodings"}

stale_range_state := []Override {
	{"numeric sort of a list", "SORT bad7", `["1", "2", "0x10"]`},
	{"numeric sort of a list", "SORT bad10", `["+1", "01", "1", "1.0", "1.00", "1e0"]`},
	{"numeric sort of a list", "SORT bad10 DESC", `["1e0", "1.00", "1.0", "1", "01", "+1"]`},
	{"numeric sort of a list", "SORT hex", `["1", "2", "0x1A"]`},
	{"numeric sort of a list", "SORT longnum", `["1", "9223372036854775808", "1e19", "12345678901234567890"]`},
	{"numeric sort of a list", "SORT prec", `["9007199254740992", "9007199254740992.5", "9007199254740993", "9007199254740994"]`},
	{"numeric sort of a list", "SORT prec DESC", `["9007199254740994", "9007199254740993", "9007199254740992.5", "9007199254740992"]`},
	{"sets", "SORT s", `["1", "2", "3", "10"]`},
	{"sets", "SORT s DESC", `["10", "3", "2", "1"]`},
	{"sets", "SORT s LIMIT 1 2", `["2", "3"]`},
	{"sets", "SORT sbig LIMIT 0 5", `["1", "2", "3", "4", "5"]`},
}

copy_timing_lines := []string{"SET e3 v PX 1", "COPY e3 e4", "COPY hx hx3"}

copy_lfu_lines := []string{"OBJECT FREQ lfu"}

sort_rules :: proc() -> Replay_Rules {
	return Replay_Rules{events = "KEA", flush_at = sort_flush_sections, overrides = stale_range_state}
}

copy_rules :: proc() -> Replay_Rules {
	return Replay_Rules{events = "KEA", loose = copy_timing_lines, freq_slack = copy_lfu_lines}
}

acl_rules :: proc() -> Replay_Rules {
	return Replay_Rules{}
}
