package transactions

import "core:fmt"
import "core:strings"
import "core:testing"
import j "../../src"

@(test)
multi_queues_and_exec_runs_in_order :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	expect_call(t, a, "MULTI", "+OK\r\n")
	testing.expect(t, .Multi in a.c.txf)
	testing.expect(t, j.tx_multi_count >= 1)
	testing.expect(t, j.cmd_hooks)
	expect_call(t, a, "SET k 1", "+QUEUED\r\n")
	expect_call(t, a, "INCR k", "+QUEUED\r\n")
	expect_call(t, a, "GET k", "+QUEUED\r\n")
	st := a.c.tx
	testing.expect_value(t, len(st.cmds), 3)
	testing.expect_value(t, len(st.spans), 7)
	testing.expect_value(t, string(st.bytes[:]), "SETk1INCRkGETk")
	testing.expect_value(t, st.cmds[1].first, 3)
	testing.expect_value(t, st.cmds[1].argc, 2)
	testing.expect_value(t, st.cmds[1].cmd, j.lookup_command(transmute([]u8)string("incr")))
	expect_call(t, a, "EXEC", "*3\r\n+OK\r\n:2\r\n$1\r\n2\r\n")
	testing.expect(t, .Multi not_in a.c.txf)
	testing.expect_value(t, len(st.cmds), 0)
	testing.expect_value(t, len(st.bytes), 0)
	expect_call(t, a, "GET k", "$1\r\n2\r\n")
}

@(test)
nested_multi_and_watch_inside_multi_do_not_abort :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "MULTI", "-ERR MULTI calls can not be nested\r\n")
	expect_call(t, a, "WATCH k", "-ERR WATCH inside MULTI is not allowed\r\n")
	testing.expect(t, .Dirty_Exec not_in a.c.txf)
	expect_call(t, a, "SET k 1", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*1\r\n+OK\r\n")
}

@(test)
exec_and_discard_without_multi :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	expect_call(t, a, "EXEC", "-ERR EXEC without MULTI\r\n")
	expect_call(t, a, "DISCARD", "-ERR DISCARD without MULTI\r\n")
	expect_call(t, a, "MULTI x", "-ERR wrong number of arguments for 'multi' command\r\n")
	expect_call(t, a, "UNWATCH x", "-ERR wrong number of arguments for 'unwatch' command\r\n")
	expect_call(t, a, "WATCH", "-ERR wrong number of arguments for 'watch' command\r\n")
}

@(test)
queue_time_errors_mark_the_transaction :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	call(a, "SET", "k", "2")
	cases := [?][2]string {
		{"SET k", "-ERR wrong number of arguments for 'set' command\r\n"},
		{"BOGUSCMD x", "-ERR unknown command 'BOGUSCMD', with args beginning with: 'x' \r\n"},
		{"CONFIG BOGUS", "-ERR unknown subcommand 'BOGUS'. Try CONFIG HELP.\r\n"},
		{"XGROUP CREATE x", "-ERR wrong number of arguments for 'xgroup|create' command\r\n"},
		{"SHUTDOWN ABORT", "-ERR Command not allowed inside a transaction\r\n"},
		{"DISCARD x", "-ERR wrong number of arguments for 'discard' command\r\n"},
		{"MULTI x", "-ERR wrong number of arguments for 'multi' command\r\n"},
	}
	for tc in cases {
		expect_call(t, a, "MULTI", "+OK\r\n")
		expect_call(t, a, tc[0], tc[1])
		testing.expectf(t, .Dirty_Exec in a.c.txf, "%s should mark the transaction", tc[0])
		expect_call(t, a, "SET k 9", "+QUEUED\r\n")
		expect_call(t, a, "EXEC", "-EXECABORT Transaction discarded because of previous errors.\r\n")
		testing.expect(t, .Multi not_in a.c.txf)
		testing.expect(t, a.c.txf == {})
		testing.expect_value(t, len(a.c.tx.cmds), 0)
	}
	expect_call(t, a, "GET k", "$1\r\n2\r\n")
}

@(test)
container_subcommands_queue_and_fail_at_runtime :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "CLIENT LIST TYPE", "+QUEUED\r\n")
	testing.expect_value(t, a.c.last_cmd, "client|list")
	expect_call(t, a, "EXEC", "*1\r\n-ERR syntax error\r\n")
}

@(test)
exec_with_wrong_arity_aborts_with_prefix :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(a)
	expect_call(t, a, "WATCH k", "+OK\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET k 1", "+QUEUED\r\n")
	expect_call(t, a, "EXEC x", "-EXECABORT Transaction discarded because of: wrong number of arguments for 'exec' command\r\n")
	testing.expect(t, a.c.txf == {})
	testing.expect_value(t, len(a.c.tx.watched), 0)
	testing.expect_value(t, len(a.c.tx.cmds), 0)
	expect_call(t, a, "EXEC", "-ERR EXEC without MULTI\r\n")
	expect_call(t, w, "EXISTS k", ":0\r\n")
}

@(test)
discard_drops_queue_and_watches :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(a)
	call(a, "SET", "k", "2")
	expect_call(t, a, "WATCH k other", "+OK\r\n")
	expect_call(t, w, "SET k 3", "+OK\r\n")
	testing.expect(t, .Dirty_Cas in a.c.txf)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET k 5", "+QUEUED\r\n")
	expect_call(t, a, "DISCARD", "+OK\r\n")
	testing.expect(t, a.c.txf == {})
	testing.expect_value(t, len(a.c.tx.cmds), 0)
	testing.expect_value(t, len(a.c.tx.watched), 0)
	testing.expect_value(t, j.tx_multi_mem(a.c), 0)
	expect_call(t, a, "GET k", "$1\r\n3\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "GET k", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*1\r\n$1\r\n3\r\n")
}

@(test)
queued_memory_is_accounted :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	base_total := j.tx_mem_total
	testing.expect_value(t, j.tx_multi_mem(a.c), 0)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "PING", "+QUEUED\r\n")
	expect_call(t, a, "PING", "+QUEUED\r\n")
	testing.expect_value(t, j.tx_multi_mem(a.c), 24)
	expect_call(t, a, "SET key value", "+QUEUED\r\n")
	want := 24 + (3 + 8) + (3 + 8) + (5 + 8)
	testing.expect_value(t, j.tx_multi_mem(a.c), want)
	testing.expect_value(t, a.c.tx.mem, want)
	testing.expect_value(t, j.tx_mem_total, base_total + want)
	line := client_line(a, w)
	testing.expect_value(t, client_field(line, "multi-mem"), "59")
	expect_call(t, a, "EXEC", "*3\r\n+PONG\r\n+PONG\r\n+OK\r\n")
	testing.expect_value(t, j.tx_multi_mem(a.c), 0)
	testing.expect_value(t, j.tx_mem_total, base_total)
}

@(test)
large_queue_buffers_are_released :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	big := strings.repeat("x", j.TX_SHRINK_BYTES / 4, context.temp_allocator)
	expect_call(t, a, "MULTI", "+OK\r\n")
	for i in 0 ..< 5 {
		_ = i
		testing.expect_value(t, call(a, "SET", "big", big), "+QUEUED\r\n")
	}
	testing.expect(t, cap(a.c.tx.bytes) > j.TX_SHRINK_BYTES)
	reply := call(a, "EXEC")
	testing.expect_value(t, reply, "*5\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n")
	testing.expect_value(t, cap(a.c.tx.bytes), 0)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET small 1", "+QUEUED\r\n")
	expect_call(t, a, "DISCARD", "+OK\r\n")
	testing.expect(t, cap(a.c.tx.bytes) > 0)
	testing.expect(t, cap(a.c.tx.bytes) <= j.TX_SHRINK_BYTES)
	expect_call(t, a, "STRLEN big", ":262144\r\n")
}

@(test)
client_list_fields :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	b: [dynamic]u8
	b.allocator = context.temp_allocator
	j.tx_client_fields(&b, a.c)
	testing.expect_value(t, string(b[:]), " multi=-1 watch=0")
	expect_call(t, a, "WATCH i1 i2", "+OK\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "PING", "+QUEUED\r\n")
	expect_call(t, a, "PING", "+QUEUED\r\n")
	clear(&b)
	j.tx_client_fields(&b, a.c)
	testing.expect_value(t, string(b[:]), " multi=2 watch=2")
	line := client_line(a, w)
	testing.expect(t, strings.contains(line, " ssub=0 multi=2 watch=2 qbuf="), line)
	testing.expect_value(t, client_field(line, "multi-mem"), "24")
	testing.expect_value(t, client_field(line, "cmd"), "ping")
	other := client_line(w, w)
	testing.expect_value(t, client_field(other, "multi"), "-1")
	testing.expect_value(t, client_field(other, "watch"), "0")
	testing.expect_value(t, client_field(other, "multi-mem"), "0")
	expect_call(t, a, "DISCARD", "+OK\r\n")
	line = client_line(a, w)
	testing.expect_value(t, client_field(line, "multi"), "-1")
	testing.expect_value(t, client_field(line, "watch"), "0")
	testing.expect_value(t, client_field(line, "multi-mem"), "0")
}

@(test)
client_list_inside_exec :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "CLIENT INFO", "+QUEUED\r\n")
	reply := call(a, "EXEC")
	testing.expect(t, strings.has_prefix(reply, "*1\r\n$"), reply)
	testing.expect_value(t, client_field(reply, "argv-mem"), "4")
	testing.expect_value(t, client_field(reply, "multi"), "1")
	testing.expect_value(t, client_field(reply, "cmd"), "exec")
	testing.expect(t, j.tx_exec_conn == nil)
	testing.expect_value(t, j.tx_exec_argv_mem, 0)
	testing.expect(t, !j.deny_blocking)
	testing.expect_value(t, a.c.last_cmd, "exec")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "PING", "+QUEUED\r\n")
	expect_call(t, a, "CLIENT LIST", "+QUEUED\r\n")
	reply = call(a, "EXEC")
	own := ""
	rest := reply
	for line in strings.split_lines_iterator(&rest) {
		if strings.contains(line, fmt.tprintf("id=%d ", a.c.id)) {
			own = line
		}
	}
	testing.expect_value(t, client_field(own, "flags"), "x")
	testing.expect_value(t, client_field(own, "multi"), "2")
	testing.expect_value(t, client_field(own, "multi-mem"), "38")
	testing.expect_value(t, client_field(own, "argv-mem"), "4")
	testing.expect_value(t, client_field(own, "cmd"), "exec")
}

@(test)
may_replicate_and_flag_resolution :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	testing.expect(t, !j.tx_may_replicate(a.c))
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "GET k", "+QUEUED\r\n")
	testing.expect(t, !j.tx_may_replicate(a.c))
	expect_call(t, a, "PUBLISH ch m", "+QUEUED\r\n")
	testing.expect(t, j.tx_may_replicate(a.c))
	expect_call(t, a, "DISCARD", "+OK\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET k v", "+QUEUED\r\n")
	testing.expect(t, j.tx_may_replicate(a.c))
	expect_call(t, a, "DISCARD", "+OK\r\n")
	set := j.lookup_command(transmute([]u8)string("set"))
	get := j.lookup_command(transmute([]u8)string("get"))
	shutdown := j.lookup_command(transmute([]u8)string("shutdown"))
	config := j.lookup_command(transmute([]u8)string("config"))
	testing.expect(t, .Denyoom in j.command_flags(set, argv_of({"SET", "k", "v"})))
	testing.expect(t, .Readonly in j.command_flags(get, argv_of({"GET", "k"})))
	testing.expect(t, .No_Multi in j.command_flags(shutdown, argv_of({"SHUTDOWN"})))
	testing.expect(t, .Admin in j.command_flags(config, argv_of({"CONFIG", "SET", "a", "b"})))
	testing.expect(t, j.tx_immediate(j.lookup_command(transmute([]u8)string("exec"))))
	testing.expect(t, j.tx_immediate(j.lookup_command(transmute([]u8)string("quit"))))
	testing.expect(t, j.tx_immediate(j.lookup_command(transmute([]u8)string("reset"))))
	testing.expect(t, j.tx_immediate(j.lookup_command(transmute([]u8)string("watch"))))
	testing.expect(t, !j.tx_immediate(j.lookup_command(transmute([]u8)string("unwatch"))))
	testing.expect(t, !j.tx_immediate(set))
}

@(test)
exec_abort_strips_the_error_code :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "PING", "+QUEUED\r\n")
	before := a.c.wlen
	j.tx_exec_abort(a.c, "ERR something ", "went wrong")
	testing.expect_value(t, string(a.c.wbuf[before:a.c.wlen]), "-EXECABORT Transaction discarded because of: something went wrong\r\n")
	a.c.wlen = before
	testing.expect(t, .Multi not_in a.c.txf)
	j.tx_exec_abort(a.c, "NOPERM no")
	testing.expect_value(t, string(a.c.wbuf[before:a.c.wlen]), "-EXECABORT Transaction discarded because of: NOPERM no\r\n")
	a.c.wlen = before
}

@(test)
doomed_transactions_stop_storing :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	b := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(b)
	defer close_client(w)
	reset_server(w)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET x 1", "+QUEUED\r\n")
	expect_call(t, a, "NOSUCH x", "-ERR unknown command 'NOSUCH', with args beginning with: 'x' \r\n")
	expect_call(t, a, "PING", "+QUEUED\r\n")
	expect_call(t, a, "GET", "-ERR wrong number of arguments for 'get' command\r\n")
	expect_call(t, a, "SET y 2", "+QUEUED\r\n")
	line := client_line(a, w)
	testing.expect_value(t, client_field(line, "multi"), "1")
	testing.expect_value(t, client_field(line, "multi-mem"), "29")
	testing.expect_value(t, len(a.c.tx.cmds), 1)
	expect_call(t, a, "EXEC", "-EXECABORT Transaction discarded because of previous errors.\r\n")
	expect_call(t, w, "EXISTS x y", ":0\r\n")
	expect_call(t, b, "WATCH k", "+OK\r\n")
	expect_call(t, b, "MULTI", "+OK\r\n")
	expect_call(t, b, "SET x 1", "+QUEUED\r\n")
	expect_call(t, w, "SET k 1", "+OK\r\n")
	line = client_line(b, w)
	testing.expect_value(t, client_field(line, "flags"), "xd")
	testing.expect_value(t, client_field(line, "multi"), "1")
	testing.expect_value(t, client_field(line, "watch"), "0")
	testing.expect_value(t, client_field(line, "multi-mem"), "29")
	expect_call(t, b, "SET y 1", "+QUEUED\r\n")
	expect_call(t, b, "PING", "+QUEUED\r\n")
	line = client_line(b, w)
	testing.expect_value(t, client_field(line, "multi"), "1")
	testing.expect_value(t, client_field(line, "multi-mem"), "29")
	expect_call(t, b, "EXEC", "*-1\r\n")
	expect_call(t, w, "EXISTS x y", ":0\r\n")
	keys := j.watch_total
	expect_call(t, b, "WATCH k", "+OK\r\n")
	expect_call(t, w, "SET k 2", "+OK\r\n")
	expect_call(t, b, "WATCH k2 k3", "+OK\r\n")
	testing.expect_value(t, len(b.c.tx.watched), 0)
	testing.expect_value(t, j.watch_total, keys)
	testing.expect_value(t, info_field(w, "clients", "watching_clients"), "0")
	expect_call(t, b, "MULTI", "+OK\r\n")
	expect_call(t, b, "SET z 1", "+QUEUED\r\n")
	testing.expect_value(t, client_field(client_line(b, w), "multi"), "0")
	expect_call(t, b, "EXEC", "*-1\r\n")
	expect_call(t, b, "WATCH k2", "+OK\r\n")
	testing.expect_value(t, len(b.c.tx.watched), 1)
	expect_call(t, b, "UNWATCH", "+OK\r\n")
}
