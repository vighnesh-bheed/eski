package main

import "core:mem"
import "core:testing"

dispatch_test_bytes :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

dispatch_test_class :: proc(name: string) -> (Keyspace_Op, bool) {
	slot := lookup_entry(dispatch_test_bytes(name))
	if slot == nil {
		return {}, false
	}
	op, ok := slot.keyspace.?
	return op, ok
}

dispatch_test_classes_match :: proc(t: ^testing.T) -> (seen: int, classified: int) {
	for &slot in cmd_table {
		if slot.cmd == nil {
			testing.expectf(t, slot.keyspace == nil, "an empty command slot carries keyspace class %v", slot.keyspace)
			continue
		}
		seen += 1
		want, want_ok := keyspace_operation(slot.cmd)
		got, got_ok := slot.keyspace.?
		testing.expectf(t, got_ok == want_ok && got == want, "stored keyspace class of %s is %v %v but the switch gives %v %v", slot.key, got, got_ok, want, want_ok)
		if got_ok {
			classified += 1
		}
	}
	testing.expect_value(t, seen, cmd_count)
	return
}

@(test)
dispatch_stored_keyspace_class_matches_switch_for_every_command :: proc(t: ^testing.T) {
	seen, classified := dispatch_test_classes_match(t)
	testing.expect(t, seen > 200)
	testing.expect(t, classified > 150 && classified < seen)
	expected := [?]struct {
		name: string,
		op:   Keyspace_Op,
	}{{"get", .Get}, {"set", .Set}, {"substr", .Getrange}, {"getrange", .Getrange}, {"mset", .Mset}, {"hset", .Hset}, {"hpersist", .Hpersist}, {"sadd", .Sadd}, {"lpush", .Lpush}, {"setbit", .Setbit}, {"pfadd", .Pfadd}, {"zadd", .Zset}, {"geoadd", .Geo}, {"xread", .Stream}, {"xadd", .Stream}, {"copy", .Key}, {"restore", .Key}}
	for e in expected {
		op, ok := dispatch_test_class(e.name)
		testing.expectf(t, ok && op == e.op, "%s is classified %v %v", e.name, op, ok)
	}
	for name in ([?]string{"ping", "echo", "eval", "fcall", "multi", "exec", "info", "scan", "keys", "flushall", "blpop", "subscribe"}) {
		_, ok := dispatch_test_class(name)
		testing.expectf(t, !ok, "%s must stay on the coordinator", name)
	}
}

@(test)
dispatch_rename_command_keeps_stored_keyspace_class :: proc(t: ^testing.T) {
	saved := cmd_table
	saved_count := cmd_count
	defer {
		cmd_table = saved
		cmd_count = saved_count
	}
	buffer: [2048]u8
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	context.allocator = mem.arena_allocator(&arena)
	renames := [?][2]string{{"get", "eski-test-get"}, {"set", "eski-test-set"}, {"xread", "eski-test-xread"}, {"copy", "eski-test-copy"}, {"ping", "eski-test-ping"}, {"zadd", "eski-test-zadd"}}
	for pair in renames {
		testing.expect_value(t, rename_command(dispatch_test_bytes(pair[0]), dispatch_test_bytes(pair[1])), "")
	}
	dispatch_test_classes_match(t)
	for pair in renames {
		testing.expectf(t, lookup_entry(dispatch_test_bytes(pair[0])) == nil, "%s is still registered", pair[0])
		renamed := lookup_entry(dispatch_test_bytes(pair[1]))
		testing.expectf(t, renamed != nil && renamed.cmd.name == pair[0], "%s does not resolve to %s", pair[1], pair[0])
	}
	op, ok := dispatch_test_class("eski-test-get")
	testing.expect(t, ok && op == .Get)
	op, ok = dispatch_test_class("eski-test-set")
	testing.expect(t, ok && op == .Set)
	op, ok = dispatch_test_class("eski-test-xread")
	testing.expect(t, ok && op == .Stream)
	op, ok = dispatch_test_class("eski-test-copy")
	testing.expect(t, ok && op == .Key)
	_, ok = dispatch_test_class("eski-test-ping")
	testing.expect(t, !ok)
	removed := lookup_entry(dispatch_test_bytes("del"))
	testing.expect(t, removed != nil)
	if removed == nil {
		return
	}
	del := removed.cmd
	testing.expect_value(t, rename_command(dispatch_test_bytes("del"), nil), "")
	testing.expect_value(t, rename_command(dispatch_test_bytes("eski-test-zadd"), nil), "")
	testing.expect(t, lookup_entry(dispatch_test_bytes("del")) == nil)
	dispatch_test_classes_match(t)
	for pair in renames[:5] {
		testing.expect_value(t, rename_command(dispatch_test_bytes(pair[1]), dispatch_test_bytes(pair[0])), "")
	}
	register_command(del)
	dispatch_test_classes_match(t)
	op, ok = dispatch_test_class("del")
	testing.expect(t, ok && op == .Del)
	op, ok = dispatch_test_class("get")
	testing.expect(t, ok && op == .Get)
	_, ok = dispatch_test_class("zadd")
	testing.expect(t, !ok)
	testing.expect_value(t, cmd_count, saved_count - 1)
}

@(test)
dispatch_keyspace_candidate_reads_only_the_stored_class :: proc(t: ^testing.T) {
	saved_threads := keyspace_threads
	defer keyspace_threads = saved_threads
	get := lookup_entry(dispatch_test_bytes("get"))
	ping := lookup_entry(dispatch_test_bytes("ping"))
	xread := lookup_entry(dispatch_test_bytes("xread"))
	testing.expect(t, get != nil && ping != nil && xread != nil)
	if get == nil || ping == nil || xread == nil {
		return
	}
	key_read := [][]u8{dispatch_test_bytes("get"), dispatch_test_bytes("key")}
	ping_arg := [][]u8{dispatch_test_bytes("ping"), dispatch_test_bytes("hello")}
	stream_read := [][]u8{dispatch_test_bytes("xread"), dispatch_test_bytes("streams"), dispatch_test_bytes("s"), dispatch_test_bytes("0")}
	stream_block := [][]u8{dispatch_test_bytes("xread"), dispatch_test_bytes("block"), dispatch_test_bytes("0"), dispatch_test_bytes("streams"), dispatch_test_bytes("s"), dispatch_test_bytes("0")}
	marked := ping^
	marked.keyspace = Keyspace_Op.Get
	keyspace_threads = 0
	testing.expect(t, !keyspace_candidate(get, key_read))
	testing.expect(t, !keyspace_candidate(xread, stream_read))
	testing.expect(t, !keyspace_candidate(&marked, ping_arg))
	keyspace_threads = 2
	testing.expect(t, keyspace_candidate(get, key_read))
	testing.expect(t, !keyspace_candidate(get, key_read[:1]))
	testing.expect(t, !keyspace_candidate(nil, key_read))
	testing.expect(t, !keyspace_candidate(ping, ping_arg))
	testing.expect(t, keyspace_candidate(xread, stream_read))
	testing.expect(t, !keyspace_candidate(xread, stream_block))
	testing.expect(t, keyspace_candidate(&marked, ping_arg))
	cleared := get^
	cleared.keyspace = nil
	testing.expect(t, !keyspace_candidate(&cleared, key_read))
}
