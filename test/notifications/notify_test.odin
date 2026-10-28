package notifications

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import m "../../src"

Grammar_Case :: struct {
	input:  string,
	output: string,
}

@(private)
grammar_cases := [?]Grammar_Case {
	{"KEA", "AKE"},
	{"AKE", "AKE"},
	{"g$lshzxeKEtmdn", "AKEm"},
	{"Kg", "gK"},
	{"E$", "$E"},
	{"x", "x"},
	{"Ke", "eK"},
	{"n", "n"},
	{"m", "m"},
	{"d", "d"},
	{"t", "t"},
	{"KEAz", "AKE"},
	{"KEAn$", "AKE"},
	{"", ""},
	{"glshz", "glshz"},
	{"Kn", "nK"},
	{"Etm", "tEm"},
}

pmessage :: proc(pattern: string, channel: string, payload: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "*4\r\n")
	bulk(&b, "pmessage")
	bulk(&b, pattern)
	bulk(&b, channel)
	bulk(&b, payload)
	return strings.to_string(b)
}

event_pair :: proc(b: ^strings.Builder, pattern: string, db: int, key: string, event: string) {
	strings.write_string(b, pmessage(pattern, fmt.tprintf("__keyspace@%d__:%s", db, key), event))
	strings.write_string(b, pmessage(pattern, fmt.tprintf("__keyevent@%d__:%s", db, event), key))
}

@(test)
test_notify_parse_and_format :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_setup()
	for gc in grammar_cases {
		flags, ok := m.notify_parse(transmute([]u8)gc.input)
		testing.expectf(t, ok, "parse %q", gc.input)
		buf: [32]u8
		n := m.notify_format(flags, buf[:])
		testing.expect_value(t, string(buf[:n]), gc.output)
	}
	all, ok := m.notify_parse(transmute([]u8)string("A"))
	testing.expect(t, ok)
	testing.expect_value(t, all, m.NOTIFY_ALL)
	testing.expect(t, .Key_Miss not_in all && .New not_in all && .Keyspace not_in all)
	for bad in ([]string{"B", "KEAB", "a", "KE ", "M", "N", "*"}) {
		_, good := m.notify_parse(transmute([]u8)bad)
		testing.expectf(t, !good, "expected %q to be rejected", bad)
	}
	small: [2]u8
	n := m.notify_format(m.NOTIFY_ALL + {.Keyspace, .Keyevent, .Key_Miss}, small[:])
	testing.expect_value(t, string(small[:n]), "AK")
}

@(test)
test_notify_config_bytes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_setup()
	defer env_reset()
	w := client_open()
	defer client_close(w)
	for gc in grammar_cases {
		if gc.input == "" {
			continue
		}
		expect_bytes(t, run(w, fmt.tprintf("CONFIG SET notify-keyspace-events %s", gc.input)), "+OK\r\n")
		want := strings.concatenate({"*2\r\n$22\r\nnotify-keyspace-events\r\n", fmt.tprintf("$%d\r\n%s\r\n", len(gc.output), gc.output)}, context.temp_allocator)
		expect_bytes(t, run(w, "CONFIG GET notify-keyspace-events"), want)
	}
	expect_bytes(t, run(w, "CONFIG SET notify-keyspace-events KEA"), "+OK\r\n")
	expect_bytes(t, run(w, "CONFIG SET notify-keyspace-events B"), "-ERR CONFIG SET failed (possibly related to argument 'notify-keyspace-events') - Invalid event class character. Use 'Ag$lshzxeKEtmdn'.\r\n")
	expect_bytes(t, run(w, "CONFIG GET notify-keyspace-events"), "*2\r\n$22\r\nnotify-keyspace-events\r\n$3\r\nAKE\r\n")
	testing.expect_value(t, m.notify_config, m.NOTIFY_ALL + {.Keyspace, .Keyevent})
	empty := [][]u8{transmute([]u8)string("CONFIG"), transmute([]u8)string("SET"), transmute([]u8)string("notify-keyspace-events"), nil}
	expect_bytes(t, run_argv(w, empty), "+OK\r\n")
	expect_bytes(t, run(w, "CONFIG GET notify-keyspace-events"), "*2\r\n$22\r\nnotify-keyspace-events\r\n$0\r\n\r\n")
	testing.expect_value(t, m.notify_config, m.Notify_Set{})
	testing.expect_value(t, m.notify_active, m.Notify_Set{})
}

@(test)
test_notify_active_set_and_gate :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_setup()
	defer env_reset()
	m.notify_apply({.Generic, .String})
	testing.expect_value(t, m.notify_config, m.Notify_Set{.Generic, .String})
	testing.expect_value(t, m.notify_active, m.Notify_Set{})
	testing.expect_value(t, m.key_hooks, false)
	m.notify_apply({.Keyevent, .String})
	testing.expect_value(t, m.notify_active, m.Notify_Set{.Keyevent, .String})
	testing.expect_value(t, m.key_hooks, true)
	m.notify_apply({.Key_Miss})
	testing.expect_value(t, m.notify_active, m.Notify_Set{})
	testing.expect_value(t, m.key_hooks, false)
	w := client_open()
	x := client_open()
	defer client_close(w)
	defer client_close(x)
	expect_bytes(t, run(x, "WATCH gate:w"), "+OK\r\n")
	testing.expect_value(t, m.key_hooks, true)
	expect_bytes(t, run(x, "MULTI"), "+OK\r\n")
	expect_bytes(t, run(x, "GET gate:w"), "+QUEUED\r\n")
	expect_bytes(t, run(w, "SET gate:w 1"), "+OK\r\n")
	expect_bytes(t, run(x, "EXEC"), "*-1\r\n")
	testing.expect_value(t, m.key_hooks, false)
	m.signal_key(transmute([]u8)string("gate:none"))
	m.signal_key_in(transmute([]u8)string("gate:none"), &m.dbs[1])
	m.signal_key_expired(transmute([]u8)string("gate:none"), &m.dbs[0])
	m.notify(.String, "set", transmute([]u8)string("gate:none"))
	m.notify_in(.String, "set", transmute([]u8)string("gate:none"), &m.dbs[0])
	expect_bytes(t, take(w), "")
	expect_bytes(t, take(x), "")
}

@(test)
test_notify_channels_and_payloads :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_setup()
	defer env_reset()
	w := client_open()
	s := client_open()
	p := client_open(3)
	defer client_close(w)
	defer client_close(s)
	defer client_close(p)
	expect_bytes(t, run(s, "SUBSCRIBE __keyspace@0__:chan:k __keyevent@0__:set"), "*3\r\n$9\r\nsubscribe\r\n$21\r\n__keyspace@0__:chan:k\r\n:1\r\n*3\r\n$9\r\nsubscribe\r\n$18\r\n__keyevent@0__:set\r\n:2\r\n")
	expect_bytes(t, run(p, "PSUBSCRIBE __key*@1__:*"), ">3\r\n$10\r\npsubscribe\r\n$12\r\n__key*@1__:*\r\n:1\r\n")
	m.notify_apply({.Keyspace, .Keyevent, .String, .Generic})
	expect_bytes(t, run(w, "SET chan:k v"), "+OK\r\n")
	expect_bytes(t, take(s), strings.concatenate({frame('*', "message", "__keyspace@0__:chan:k", "set"), frame('*', "message", "__keyevent@0__:set", "chan:k")}, context.temp_allocator))
	expect_bytes(t, take(p), "")
	m.notify_apply({.Keyspace, .String})
	expect_bytes(t, run(w, "SET chan:k v2"), "+OK\r\n")
	expect_bytes(t, take(s), frame('*', "message", "__keyspace@0__:chan:k", "set"))
	m.notify_apply({.Keyevent, .String})
	expect_bytes(t, run(w, "SET chan:k v3"), "+OK\r\n")
	expect_bytes(t, take(s), frame('*', "message", "__keyevent@0__:set", "chan:k"))
	m.notify_apply({.Keyspace, .Keyevent, .Hash})
	expect_bytes(t, run(w, "SET chan:k v4"), "+OK\r\n")
	expect_bytes(t, take(s), "")
	m.notify_apply({.Keyspace, .Keyevent, .String, .Generic})
	m.notify_in(.Generic, "del", transmute([]u8)string("x\r\ny"), &m.dbs[1])
	want := strings.concatenate({
		">4\r\n$8\r\npmessage\r\n$12\r\n__key*@1__:*\r\n$19\r\n__keyspace@1__:x\r\ny\r\n$3\r\ndel\r\n",
		">4\r\n$8\r\npmessage\r\n$12\r\n__key*@1__:*\r\n$18\r\n__keyevent@1__:del\r\n$4\r\nx\r\ny\r\n",
	}, context.temp_allocator)
	expect_bytes(t, take(p), want)
	expect_bytes(t, take(s), "")
	m.notify_in(.Generic, "del", transmute([]u8)string("k"), &m.dbs[12])
	expect_bytes(t, take(p), "")
	m.notify_apply({.Keyspace, .Keyevent, .Generic})
	m.notify(.Loaded, "loaded", transmute([]u8)string("chan:k"))
	m.notify(.Key_Miss, "keymiss", transmute([]u8)string("chan:k"))
	expect_bytes(t, take(s), "")
}

@(test)
test_notify_expired_event :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_setup()
	defer env_reset()
	e := client_open()
	defer client_close(e)
	expect_bytes(t, run(e, "PSUBSCRIBE __keyevent@3__:*"), "*3\r\n$10\r\npsubscribe\r\n$16\r\n__keyevent@3__:*\r\n:1\r\n")
	m.notify_apply({.Keyevent, .Expired})
	m.key_expired_event(transmute([]u8)string("gone"), &m.dbs[3])
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, pmessage("__keyevent@3__:*", "__keyevent@3__:expired", "gone"))
	expect_bytes(t, take(e), strings.to_string(b))
	m.notify_apply({.Keyevent, .Generic})
	m.key_expired_event(transmute([]u8)string("gone"), &m.dbs[3])
	expect_bytes(t, take(e), "")
}

dump_payload :: proc(reply: string) -> []u8 {
	nl := strings.index(reply, "\r\n")
	return transmute([]u8)strings.clone(reply[nl + 2:len(reply) - 2], context.temp_allocator)
}

@(test)
test_notify_transcript_sequence :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_setup()
	defer env_reset()
	w := client_open()
	e := client_open()
	defer client_close(w)
	defer client_close(e)
	expect_bytes(t, run(w, "CONFIG SET notify-keyspace-events KEAnm"), "+OK\r\n")
	expect_bytes(t, run(e, "PSUBSCRIBE __key*"), "*3\r\n$10\r\npsubscribe\r\n$6\r\n__key*\r\n:1\r\n")
	want := strings.builder_make(context.temp_allocator)
	ev :: proc(b: ^strings.Builder, db: int, key: string, event: string) {
		event_pair(b, "__key*", db, key, event)
	}
	expect_bytes(t, run(w, "SET sq:n1 v"), "+OK\r\n")
	ev(&want, 0, "sq:n1", "new")
	ev(&want, 0, "sq:n1", "set")
	expect_bytes(t, run(w, "SET sq:n1 w"), "+OK\r\n")
	ev(&want, 0, "sq:n1", "set")
	expect_bytes(t, run(w, "GET sq:missing"), "$-1\r\n")
	ev(&want, 0, "sq:missing", "keymiss")
	expect_bytes(t, run(w, "SET sq:px v PX 1"), "+OK\r\n")
	ev(&want, 0, "sq:px", "new")
	ev(&want, 0, "sq:px", "set")
	ev(&want, 0, "sq:px", "expire")
	time.sleep(5 * time.Millisecond)
	m.update_clock()
	expect_bytes(t, run(w, "GET sq:px"), "$-1\r\n")
	ev(&want, 0, "sq:px", "expired")
	ev(&want, 0, "sq:px", "keymiss")
	expect_bytes(t, run(w, "HSET sq:hx f v"), ":1\r\n")
	ev(&want, 0, "sq:hx", "new")
	ev(&want, 0, "sq:hx", "hset")
	expect_bytes(t, run(w, "HPEXPIRE sq:hx 1 FIELDS 1 f"), "*1\r\n:1\r\n")
	ev(&want, 0, "sq:hx", "hexpire")
	time.sleep(5 * time.Millisecond)
	m.update_clock()
	expect_bytes(t, run(w, "HGET sq:hx f"), "$-1\r\n")
	ev(&want, 0, "sq:hx", "hexpired")
	ev(&want, 0, "sq:hx", "del")
	expect_bytes(t, run(w, "HGET sq:hx f"), "$-1\r\n")
	ev(&want, 0, "sq:hx", "keymiss")
	expect_bytes(t, run(w, "RENAME sq:n1 sq:n2"), "+OK\r\n")
	ev(&want, 0, "sq:n2", "new")
	ev(&want, 0, "sq:n1", "rename_from")
	ev(&want, 0, "sq:n2", "rename_to")
	expect_bytes(t, run(w, "COPY sq:n2 sq:n3"), ":1\r\n")
	ev(&want, 0, "sq:n3", "new")
	ev(&want, 0, "sq:n3", "copy_to")
	expect_bytes(t, run(w, "MOVE sq:n3 1"), ":1\r\n")
	ev(&want, 1, "sq:n3", "new")
	ev(&want, 0, "sq:n3", "move_from")
	ev(&want, 1, "sq:n3", "move_to")
	payload := dump_payload(run(w, "DUMP sq:n2"))
	restore := [][]u8{transmute([]u8)string("RESTORE"), transmute([]u8)string("sq:n4"), transmute([]u8)string("0"), payload}
	expect_bytes(t, run_argv(w, restore), "+OK\r\n")
	ev(&want, 0, "sq:n4", "new")
	ev(&want, 0, "sq:n4", "restore")
	expect_bytes(t, run(w, "SORT sq:n2 STORE sq:n5"), "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n")
	expect_bytes(t, run(w, "PERSIST sq:n2"), ":0\r\n")
	expect_bytes(t, run(w, "EXPIRE sq:n2 100"), ":1\r\n")
	ev(&want, 0, "sq:n2", "expire")
	expect_bytes(t, run(w, "PERSIST sq:n2"), ":1\r\n")
	ev(&want, 0, "sq:n2", "persist")
	expect_bytes(t, take(e), strings.to_string(want))
	m.notify_apply({})
	expect_bytes(t, run(w, "DEL sq:n2 sq:n4"), ":2\r\n")
	w.c.db = &m.dbs[1]
	expect_bytes(t, run(w, "DEL sq:n3"), ":1\r\n")
	w.c.db = &m.dbs[0]
	expect_bytes(t, take(e), "")
}
