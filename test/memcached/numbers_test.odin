package memcached

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import j "../../src"

OBSERVED_ITEM_FIXED_BYTES :: 59
OBSERVED_ITEM_FLAGS_BYTES :: 4
OBSERVED_ITEM_SIZE_DEFAULT :: 1048576
TOO_LARGE_REPLY :: "SERVER_ERROR object too large for cache\r\n"

Wire_Case :: struct {
	name:    string,
	request: string,
	reply:   string,
}

Unsigned_Case :: struct {
	text:  string,
	value: u64,
	ok:    bool,
}

Signed_Case :: struct {
	text:  string,
	value: i64,
	ok:    bool,
}

UNSIGNED_CASES := [?]Unsigned_Case {
	{"0", 0, true},
	{"5", 5, true},
	{"\t5", 5, true},
	{" \x0b\x0c\r\n5", 5, true},
	{"+5", 5, true},
	{"\t+5", 5, true},
	{"-0", 0, true},
	{"5\t", 5, true},
	{"5\x00z", 5, true},
	{"5 z", 5, true},
	{"5\t-", 5, true},
	{"18446744073709551615", max(u64), true},
	{"0000000000000000000000000018446744073709551615", max(u64), true},
	{"9223372036854775808", 1 << 63, true},
	{"9223372036854775807 -", 1 << 63 - 1, true},
	{"9223372036854775808\x00-", 1 << 63, true},
	{"-9223372036854775809", 1 << 63 - 1, true},
	{"-18446744073709551615", 1, true},
	{"", 0, false},
	{"+", 0, false},
	{"-", 0, false},
	{"+-5", 0, false},
	{"-+5", 0, false},
	{"+\t5", 0, false},
	{"\x005", 0, false},
	{"5z", 0, false},
	{"1-", 0, false},
	{"0x10", 0, false},
	{"1e3", 0, false},
	{"1.0", 0, false},
	{"\xd9\xa5", 0, false},
	{"5\xa0", 0, false},
	{"18446744073709551616", 0, false},
	{"-1", 0, false},
	{"\t-1", 0, false},
	{"-9223372036854775808", 0, false},
	{"-18446744073709551616", 0, false},
	{"9223372036854775808 -", 0, false},
	{"18446744073709551615\t-", 0, false},
}

SIGNED_CASES := [?]Signed_Case {
	{"0", 0, true},
	{"-0", 0, true},
	{"+0", 0, true},
	{"-1", -1, true},
	{"\t-1", -1, true},
	{"5\t-", 5, true},
	{"5\x00z", 5, true},
	{"4294967295", 4294967295, true},
	{"00000000000000000000000000000005", 5, true},
	{"9223372036854775807", max(i64), true},
	{"9223372036854775807\t-", max(i64), true},
	{"-9223372036854775808", min(i64), true},
	{"", 0, false},
	{"-", 0, false},
	{"+", 0, false},
	{"+-1", 0, false},
	{"5a", 0, false},
	{"1.5", 0, false},
	{"0x10", 0, false},
	{"9223372036854775808", 0, false},
	{"-9223372036854775809", 0, false},
	{"18446744073709551615", 0, false},
}

booted: bool

boot :: proc() {
	if booted {
		return
	}
	j.mono_init()
	j.config_table_init()
	j.config_init()
	j.commands_init()
	j.stats_init()
	j.acl_init()
	j.db_init()
	j.block_init()
	j.mem_init()
	j.info_init()
	j.hash_store_init()
	j.persist_init_commands()
	j.argv_init()
	booted = true
}

fresh :: proc() {
	boot()
	j.update_clock()
	j.db_flush_all()
	j.mc_flush_at = 0
	j.mc_item_size_max = OBSERVED_ITEM_SIZE_DEFAULT
}

exchange :: proc(request: string) -> string {
	held_conn_mem := j.conn_mem
	c := new(j.Conn)
	c.fd = -1
	c.db = &j.dbs[0]
	c.kind = .Memcached
	c.resp = j.RESP2
	j.acl_conn_init(c)
	c.rcap = max(len(request), j.RBUF_INIT)
	c.rbuf = j.mem_alloc(c.rcap)
	runtime.mem_copy_non_overlapping(c.rbuf, raw_data(request), len(request))
	c.rlen = len(request)
	j.update_clock()
	j.mc_process_input(c)
	reply := strings.clone(string(c.wbuf[:c.wlen]))
	j.mem_free(c.rbuf)
	runtime.heap_free(c.wbuf)
	free(c)
	j.conn_mem = held_conn_mem
	return reply
}

replay_cases :: proc(t: ^testing.T, label: string, cases: []Wire_Case) {
	failures := 0
	for wc in cases {
		fresh()
		got := exchange(wc.request)
		if got != wc.reply {
			failures += 1
			testing.expectf(t, false, "%s %s: got %q want %q", label, wc.name, got, wc.reply)
		}
		delete(got)
	}
	testing.expectf(t, len(cases) > 0 && failures == 0, "%s: %d of %d cases differ", label, failures, len(cases))
}

store_request :: proc(key: string, flags: u64, size: int) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "set %s %d 0 %d\r\n", key, flags, size)
	for _ in 0 ..< size {
		strings.write_byte(&b, 'v')
	}
	strings.write_string(&b, "\r\n")
	return strings.to_string(b)
}

stat_value :: proc(stats: string, name: string) -> (string, bool) {
	rest := stats
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line)
		defer delete(fields)
		if len(fields) == 3 && fields[0] == "STAT" && fields[1] == name {
			return strings.clone(fields[2]), true
		}
	}
	return "", false
}

modelled_size :: proc(key_len: int, value_len: int, flags: u64) -> int {
	return key_len + value_len + OBSERVED_ITEM_FIXED_BYTES + (OBSERVED_ITEM_FLAGS_BYTES if flags != 0 else 0)
}

@(test)
text_unsigned_contract :: proc(t: ^testing.T) {
	for uc in UNSIGNED_CASES {
		value, ok := j.mc_text_unsigned(transmute([]u8)uc.text)
		testing.expectf(t, ok == uc.ok && value == uc.value, "unsigned %q: got %d/%v want %d/%v", uc.text, value, ok, uc.value, uc.ok)
	}
}

@(test)
text_signed_contract :: proc(t: ^testing.T) {
	for sc in SIGNED_CASES {
		value, ok := j.mc_text_signed(transmute([]u8)sc.text)
		testing.expectf(t, ok == sc.ok && value == sc.value, "signed %q: got %d/%v want %d/%v", sc.text, value, ok, sc.value, sc.ok)
	}
}

@(test)
probe_table_matches_reference :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	replay_cases(t, "probe", PROBE_CASES[:])
}

@(test)
held_differences_keep_eski_replies :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	replay_cases(t, "held", HELD_CASES[:])
}

@(test)
item_size_boundary_follows_accounting :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	key_lengths := [?]int{1, 2, 3, 8, 9, 17, 64, 250}
	flag_values := [?]u64{0, 1, 4294967295}
	for key_len in key_lengths {
		key := strings.repeat("b", key_len)
		defer delete(key)
		for flags in flag_values {
			fresh()
			top := OBSERVED_ITEM_SIZE_DEFAULT - modelled_size(key_len, 0, flags)
			fits := store_request(key, flags, top)
			over := store_request(key, flags, top + 1)
			got_fits := exchange(fits)
			got_over := exchange(over)
			testing.expectf(t, got_fits == "STORED\r\n", "key %d flags %d size %d: %q", key_len, flags, top, got_fits)
			testing.expectf(t, got_over == TOO_LARGE_REPLY, "key %d flags %d size %d: %q", key_len, flags, top + 1, got_over)
			delete(fits)
			delete(over)
			delete(got_fits)
			delete(got_over)
		}
	}
}

@(test)
bytes_stat_follows_accounting :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	key_lengths := [?]int{1, 5, 16, 250}
	value_lengths := [?]int{0, 1, 100, 600000}
	flag_values := [?]u64{0, 7}
	for key_len in key_lengths {
		key := strings.repeat("z", key_len)
		defer delete(key)
		for value_len in value_lengths {
			for flags in flag_values {
				fresh()
				request := store_request(key, flags, value_len)
				stored := exchange(request)
				stats := exchange("stats\r\n")
				bytes, found := stat_value(stats, "bytes")
				want := fmt.aprintf("%d", modelled_size(key_len, value_len, flags))
				testing.expectf(t, stored == "STORED\r\n" && found && bytes == want, "key %d value %d flags %d: %q bytes %q want %q", key_len, value_len, flags, stored, bytes, want)
				delete(request)
				delete(stored)
				delete(stats)
				delete(bytes)
				delete(want)
			}
		}
	}
}
