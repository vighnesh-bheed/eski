package dumping

import "core:strconv"
import "core:sys/linux"
import "core:testing"
import eski "../../src"

NOKEY_REPLY :: "+NOKEY\r\n"
KEYS_REPLY :: "-ERR When using MIGRATE KEYS option, the key argument must be set to the empty string\r\n"
CONNECT_REPLY :: "-IOERR error or timeout connecting to the client\r\n"
WRITE_REPLY :: "-IOERR error or timeout writing to target instance\r\n"
READ_REPLY :: "-IOERR error or timeout reading to target instance\r\n"
TARGET_PREFIX :: "-ERR Target instance replied with error: "

target_reply :: proc(msg: string) -> string {
	return concat(concat(TARGET_PREFIX, msg), "\r\n")
}

migrate :: proc(c: ^eski.Conn, ft: ^Fake_Target, key: string, db: string, timeout: string, opts: ..string) -> string {
	argv := make([dynamic][]u8, heap())
	defer delete(argv)
	append(&argv, bytes("migrate"), bytes("127.0.0.1"), bytes(ft.port_str), bytes(key), bytes(db), bytes(timeout))
	for o in opts {
		append(&argv, bytes(o))
	}
	return run_argv(c, argv[:])
}

closed_port :: proc() -> string {
	fd, port, ok := listen_local(1)
	if !ok {
		return "1"
	}
	linux.close(fd)
	buf := make([]u8, 24, heap())
	return itoa(buf, i64(port))
}

@(test)
migrate_argument_errors :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	ft := fake_start(t)
	if ft == nil {
		return
	}
	defer fake_stop(ft)
	run(c, "set", "s", "hello")
	testing.expect_value(t, migrate(c, ft, "nokey", "0", "100"), NOKEY_REPLY)
	testing.expect_value(t, migrate(c, ft, "", "0", "100", "KEYS", "nokey1", "nokey2"), NOKEY_REPLY)
	testing.expect_value(t, migrate(c, ft, "", "0", "100", "KEYS"), NOKEY_REPLY)
	testing.expect_value(t, migrate(c, ft, "", "0", "100"), NOKEY_REPLY)
	testing.expect_value(t, migrate(c, ft, "nokey", "abc", "x", "COPY"), NOT_INT_REPLY)
	testing.expect_value(t, fake_accepted(ft), 0)
	testing.expect_value(t, eski.migrate_cached_count(), 0)
	testing.expect_value(t, migrate(c, ft, "key", "0", "100", "KEYS", "a"), KEYS_REPLY)
	testing.expect_value(t, migrate(c, ft, "s", "0", "100", "KEYS"), KEYS_REPLY)
	testing.expect_value(t, migrate(c, ft, "nokey", "0", "100", "KEYS", "nokey"), KEYS_REPLY)
	testing.expect_value(t, migrate(c, ft, "s", "0", "100", "BOGUS"), SYNTAX_REPLY)
	testing.expect_value(t, migrate(c, ft, "s", "0", "100", "BOGUS", "KEYS", "s"), SYNTAX_REPLY)
	testing.expect_value(t, migrate(c, ft, "s", "0", "100", "AUTH"), SYNTAX_REPLY)
	testing.expect_value(t, migrate(c, ft, "s", "0", "100", "AUTH2", "u"), SYNTAX_REPLY)
	testing.expect_value(t, migrate(c, ft, "s", "abc", "100"), NOT_INT_REPLY)
	testing.expect_value(t, migrate(c, ft, "s", "0", "x"), NOT_INT_REPLY)
	testing.expect_value(t, migrate(c, ft, "s", "0", "1.5"), NOT_INT_REPLY)
	testing.expect_value(t, run(c, "migrate", "127.0.0.1", ft.port_str, "s", "0"), "-ERR wrong number of arguments for 'migrate' command\r\n")
	testing.expect_value(t, run(c, "migrate"), "-ERR wrong number of arguments for 'migrate' command\r\n")
	testing.expect_value(t, fake_accepted(ft), 0)
	testing.expect_value(t, run(c, "exists", "s"), ":1\r\n")
}

@(test)
migrate_moves_a_key_and_caches_the_connection :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	ft := fake_start(t)
	if ft == nil {
		return
	}
	defer fake_stop(ft)
	run(c, "set", "k1", "hello")
	payload := dump_of(c, "k1")
	sub := subscribe_events(c, "KEA")
	before := eski.pst.dirty
	testing.expect_value(t, migrate(c, ft, "k1", "0", "5000"), OK_REPLY)
	testing.expect_value(t, eski.pst.dirty, before + 1)
	testing.expect_value(t, take_events(sub), event_frame("del", "k1"))
	testing.expect_value(t, run(c, "exists", "k1"), ":0\r\n")
	cmds := fake_commands(ft)
	testing.expect_value(t, len(cmds), 2)
	if len(cmds) == 2 {
		testing.expect(t, args_equal(cmds[0].args, "SELECT", "0"))
		testing.expect_value(t, len(cmds[1].args), 4)
		testing.expect(t, string(cmds[1].args[0]) == "RESTORE" && string(cmds[1].args[1]) == "k1" && string(cmds[1].args[2]) == "0")
		testing.expect_value(t, hex_encode(cmds[1].args[3]), hex_encode(payload))
	}
	testing.expect_value(t, eski.migrate_cached_count(), 1)
	info := run(c, "info", "stats")
	testing.expect(t, contains(info, "migrate_cached_sockets:1\r\n"))
	testing.expect_value(t, migrate(c, ft, "k1", "0", "5000"), NOKEY_REPLY)
	run(c, "set", "k2", "again")
	fake_clear_log(ft)
	testing.expect_value(t, migrate(c, ft, "k2", "0", "5000"), OK_REPLY)
	testing.expect_value(t, command_names(fake_commands(ft)), "RESTORE")
	testing.expect_value(t, fake_accepted(ft), 1)
	testing.expect_value(t, eski.migrate_cached_count(), 1)
}

@(test)
migrate_copy_replace_and_ttl :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	ft := fake_start(t)
	if ft == nil {
		return
	}
	defer fake_stop(ft)
	run(c, "set", "ttl", "v", "PX", "500000")
	run(c, "set", "plain", "v")
	sub := subscribe_events(c, "KEA")
	before := eski.pst.dirty
	testing.expect_value(t, migrate(c, ft, "ttl", "3", "5000", "COPY"), OK_REPLY)
	testing.expect_value(t, migrate(c, ft, "", "3", "5000", "COPY", "COPY", "REPLACE", "KEYS", "ttl", "plain", "nokey"), OK_REPLY)
	testing.expect_value(t, eski.pst.dirty, before)
	testing.expect_value(t, take_events(sub), "")
	testing.expect_value(t, run(c, "exists", "ttl", "plain"), ":2\r\n")
	cmds := fake_commands(ft)
	testing.expect_value(t, command_names(cmds), "SELECT RESTORE RESTORE RESTORE")
	if len(cmds) == 4 {
		testing.expect(t, args_equal(cmds[0].args, "SELECT", "3"))
		testing.expect_value(t, len(cmds[1].args), 4)
		ttl, _ := strconv.parse_i64(string(cmds[1].args[2]), 10)
		testing.expectf(t, ttl > 499000 && ttl <= 500000, "migrated ttl %d", ttl)
		testing.expect_value(t, len(cmds[2].args), 5)
		testing.expect_value(t, string(cmds[2].args[1]), "ttl")
		testing.expect_value(t, string(cmds[2].args[4]), "REPLACE")
		testing.expect_value(t, string(cmds[3].args[1]), "plain")
		testing.expect_value(t, string(cmds[3].args[2]), "0")
		testing.expect_value(t, string(cmds[3].args[4]), "REPLACE")
	}
}

@(test)
migrate_reports_target_errors_and_keeps_keys :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	ft := fake_start(t)
	if ft == nil {
		return
	}
	defer fake_stop(ft)
	run(c, "set", "busy", "2")
	before := eski.pst.dirty
	fake_script(ft, "+OK", "-BUSYKEY Target key name already exists.")
	testing.expect_value(t, migrate(c, ft, "busy", "0", "5000"), target_reply("BUSYKEY Target key name already exists."))
	testing.expect_value(t, run(c, "exists", "busy"), ":1\r\n")
	testing.expect_value(t, eski.pst.dirty, before)
	testing.expect_value(t, eski.migrate_cached_count(), 1)
	fake_clear_log(ft)
	testing.expect_value(t, migrate(c, ft, "busy", "0", "5000"), OK_REPLY)
	testing.expect_value(t, command_names(fake_commands(ft)), "SELECT RESTORE")
	run(c, "set", "busy", "2")
	run(c, "set", "busy2", "2")
	sub := subscribe_events(c, "KEA")
	before = eski.pst.dirty
	fake_script(ft, "-BUSYKEY Target key name already exists.", "+OK")
	testing.expect_value(t, migrate(c, ft, "", "0", "5000", "KEYS", "busy", "busy2"), target_reply("BUSYKEY Target key name already exists."))
	testing.expect_value(t, run(c, "exists", "busy"), ":1\r\n")
	testing.expect_value(t, run(c, "exists", "busy2"), ":0\r\n")
	testing.expect_value(t, eski.pst.dirty, before + 1)
	testing.expect_value(t, take_events(sub), event_frame("del", "busy2"))
}

@(test)
migrate_select_error_blocks_deletion_and_resets_db :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	ft := fake_start(t)
	if ft == nil {
		return
	}
	defer fake_stop(ft)
	run(c, "set", "z", "1")
	fake_script(ft, "-ERR DB index is out of range", "+OK")
	testing.expect_value(t, migrate(c, ft, "z", "99999", "100"), target_reply("ERR DB index is out of range"))
	testing.expect_value(t, run(c, "exists", "z"), ":1\r\n")
	testing.expect_value(t, command_names(fake_commands(ft)), "SELECT RESTORE")
	fake_clear_log(ft)
	fake_script(ft, "-BUSYKEY Target key name already exists.")
	testing.expect_value(t, migrate(c, ft, "z", "-1", "100"), target_reply("BUSYKEY Target key name already exists."))
	testing.expect_value(t, command_names(fake_commands(ft)), "RESTORE")
	fake_clear_log(ft)
	fake_script(ft, "+OK", "-BUSYKEY Target key name already exists.")
	testing.expect_value(t, migrate(c, ft, "z", "0", "0"), target_reply("BUSYKEY Target key name already exists."))
	testing.expect_value(t, command_names(fake_commands(ft)), "SELECT RESTORE")
	fake_clear_log(ft)
	testing.expect_value(t, migrate(c, ft, "z", "0", "-5"), OK_REPLY)
	testing.expect_value(t, command_names(fake_commands(ft)), "SELECT RESTORE")
	testing.expect_value(t, run(c, "exists", "z"), ":0\r\n")
}

@(test)
migrate_sends_auth_and_reports_auth_errors :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	ft := fake_start(t)
	if ft == nil {
		return
	}
	defer fake_stop(ft)
	run(c, "set", "au", "1")
	testing.expect_value(t, migrate(c, ft, "au", "0", "5000", "AUTH", "secret"), OK_REPLY)
	cmds := fake_commands(ft)
	testing.expect_value(t, command_names(cmds), "AUTH SELECT RESTORE")
	if len(cmds) == 3 {
		testing.expect(t, args_equal(cmds[0].args, "AUTH", "secret"))
	}
	fake_clear_log(ft)
	run(c, "set", "au2", "1")
	testing.expect_value(t, migrate(c, ft, "au2", "0", "5000", "AUTH", "first", "AUTH2", "default", "secret"), OK_REPLY)
	cmds = fake_commands(ft)
	testing.expect_value(t, command_names(cmds), "AUTH RESTORE")
	if len(cmds) == 2 {
		testing.expect(t, args_equal(cmds[0].args, "AUTH", "default", "secret"))
	}
	fake_clear_log(ft)
	run(c, "set", "au3", "1")
	fake_script(ft, "-WRONGPASS invalid username-password pair or user is disabled.", "+OK")
	testing.expect_value(t, migrate(c, ft, "au3", "0", "5000", "AUTH", "wrong"), target_reply("WRONGPASS invalid username-password pair or user is disabled."))
	testing.expect_value(t, run(c, "exists", "au3"), ":1\r\n")
	testing.expect_value(t, command_names(fake_commands(ft)), "AUTH RESTORE")
	fake_clear_log(ft)
	testing.expect_value(t, migrate(c, ft, "au3", "0", "5000"), OK_REPLY)
	testing.expect_value(t, command_names(fake_commands(ft)), "SELECT RESTORE")
}

@(test)
migrate_times_out_reading_a_silent_target :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	ft := fake_start(t)
	if ft == nil {
		return
	}
	defer fake_stop(ft)
	run(c, "set", "slow", "1")
	fake_set_silent(ft, true)
	start := clock_ms()
	testing.expect_value(t, migrate(c, ft, "slow", "0", "200"), READ_REPLY)
	elapsed := clock_ms() - start
	testing.expectf(t, elapsed >= 190 && elapsed < 3000, "silent target took %d ms", elapsed)
	testing.expect_value(t, run(c, "exists", "slow"), ":1\r\n")
	testing.expect_value(t, eski.migrate_cached_count(), 0)
	fake_set_silent(ft, false)
	testing.expect_value(t, migrate(c, ft, "slow", "0", "200"), OK_REPLY)
	testing.expect_value(t, fake_accepted(ft), 2)
}

@(test)
migrate_connection_failures :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	run(c, "set", "z", "1")
	port := closed_port()
	testing.expect_value(t, run(c, "migrate", "127.0.0.1", port, "z", "0", "100"), WRITE_REPLY)
	testing.expect_value(t, run(c, "migrate", "127.0.0.1", port, "z", "0", "0"), WRITE_REPLY)
	testing.expect_value(t, run(c, "migrate", "127.0.0.1", port, "z", "0", "-1"), WRITE_REPLY)
	testing.expect_value(t, run(c, "migrate", "127.0.0.1", "x", "z", "0", "100"), WRITE_REPLY)
	testing.expect_value(t, run(c, "migrate", "no host!", "6379", "z", "0", "100"), CONNECT_REPLY)
	testing.expect_value(t, run(c, "migrate", "-bad-", "6379", "z", "0", "100"), CONNECT_REPLY)
	testing.expect_value(t, run(c, "migrate", "127.0.0.1", "70000", "z", "0", "100"), CONNECT_REPLY)
	testing.expect_value(t, run(c, "migrate", "", "6379", "z", "0", "100"), CONNECT_REPLY)
	testing.expect_value(t, eski.migrate_cached_count(), 0)
	testing.expect_value(t, run(c, "exists", "z"), ":1\r\n")
}

@(test)
migrate_times_out_connecting_to_a_full_backlog :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	run(c, "set", "z", "1")
	fd, port, ok := listen_local(0)
	if !ok {
		return
	}
	defer linux.close(fd)
	fillers: [8]linux.Fd
	for &f in fillers {
		f = -1
		s, err := linux.socket(.INET, .STREAM, {.NONBLOCK, .CLOEXEC}, .TCP)
		if err != .NONE {
			continue
		}
		sa := linux.Sock_Addr_In {
			sin_family = .INET,
			sin_port   = u16be(port),
			sin_addr   = {127, 0, 0, 1},
		}
		linux.connect(s, &sa)
		f = s
	}
	defer for f in fillers {
		if f >= 0 {
			linux.close(f)
		}
	}
	pause_ms(50)
	buf: [24]u8
	start := clock_ms()
	testing.expect_value(t, run(c, "migrate", "127.0.0.1", itoa(buf[:], i64(port)), "z", "0", "300"), CONNECT_REPLY)
	elapsed := clock_ms() - start
	testing.expectf(t, elapsed >= 290 && elapsed < 3000, "connect timeout took %d ms", elapsed)
	testing.expect_value(t, eski.migrate_cached_count(), 0)
}

@(test)
migrate_retries_once_when_the_cached_peer_went_away :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	ft := fake_start(t)
	if ft == nil {
		return
	}
	defer fake_stop(ft)
	run(c, "set", "a", "1")
	testing.expect_value(t, migrate(c, ft, "a", "0", "2000"), OK_REPLY)
	testing.expect(t, fake_drop_clients(ft))
	pause_ms(20)
	fake_clear_log(ft)
	run(c, "set", "b", "1")
	testing.expect_value(t, migrate(c, ft, "b", "0", "2000"), OK_REPLY)
	testing.expect_value(t, fake_accepted(ft), 2)
	testing.expect_value(t, command_names(fake_commands(ft)), "SELECT RESTORE")
	testing.expect_value(t, run(c, "exists", "b"), ":0\r\n")
	testing.expect_value(t, eski.migrate_cached_count(), 1)
}

@(test)
migrate_cron_closes_idle_sockets :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	ft := fake_start(t)
	if ft == nil {
		return
	}
	defer fake_stop(ft)
	run(c, "set", "a", "1")
	testing.expect_value(t, migrate(c, ft, "a", "0", "2000"), OK_REPLY)
	testing.expect_value(t, eski.migrate_cached_count(), 1)
	eski.migrate_cron()
	testing.expect_value(t, eski.migrate_cached_count(), 1)
	cs := eski.migrate_cache[0]
	testing.expect_value(t, string(cs.name[:]), concat("127.0.0.1:", ft.port_str))
	testing.expect_value(t, cs.selected, i64(0))
	cs.idle_since = clock_ms() / 1000 - eski.MIGRATE_POOL_IDLE_SECONDS
	eski.migrate_cron()
	testing.expect_value(t, eski.migrate_cached_count(), 1)
	cs.idle_since -= 1
	eski.migrate_cron()
	testing.expect_value(t, eski.migrate_cached_count(), 0)
	testing.expect(t, contains(run(c, "info", "stats"), "migrate_cached_sockets:0\r\n"))
}

@(test)
migrate_transfers_large_values :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	ft := fake_start(t)
	if ft == nil {
		return
	}
	defer fake_stop(ft)
	value := make([]u8, 3_000_000, heap())
	for &b in value {
		b = 'x'
	}
	run_bytes(c, bytes("set"), bytes("big"), value)
	payload := dump_of(c, "big")
	testing.expect_value(t, migrate(c, ft, "big", "0", "5000"), OK_REPLY)
	cmds := fake_commands(ft)
	testing.expect_value(t, command_names(cmds), "SELECT RESTORE")
	if len(cmds) == 2 {
		testing.expect_value(t, len(cmds[1].args[3]), len(payload))
		testing.expect(t, string(cmds[1].args[3]) == string(payload))
		testing.expect(t, eski.dump_verify(cmds[1].args[3]))
	}
	testing.expect_value(t, run(c, "exists", "big"), ":0\r\n")
}

@(test)
migrate_payloads_restore_locally :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	ft := fake_start(t)
	if ft == nil {
		return
	}
	defer fake_stop(ft)
	seed_types(c)
	testing.expect_value(t, migrate(c, ft, "", "0", "5000", "COPY", "KEYS", "s", "i", "l", "si", "ss", "z", "h", "x"), OK_REPLY)
	cmds := fake_commands(ft)
	testing.expect_value(t, len(cmds), 9)
	for cmd in cmds[1:] {
		key := string(cmd.args[1])
		restored := concat("back:", key)
		testing.expectf(t, restore(c, restored, "0", cmd.args[3]) == OK_REPLY, "payload for %s did not restore", key)
		testing.expect_value(t, hex_encode(dump_of(c, restored)), hex_encode(dump_of(c, key)))
	}
}

contains :: proc(hay: string, needle: string) -> bool {
	if len(needle) > len(hay) {
		return false
	}
	for i in 0 ..= len(hay) - len(needle) {
		if hay[i:i + len(needle)] == needle {
			return true
		}
	}
	return false
}
