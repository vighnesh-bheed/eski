package main

import "core:testing"

@(test)
private_plain_set_publisher_keeps_immutable_command_and_passive_expiry_order :: proc(t: ^testing.T) {
	saved_aof := aof
	defer aof = saved_aof
	aof = Aof{feed = true, state = .On, in_tx = true, selected_db = -1}
	defer { delete(aof.stage); delete(aof.buf) }
	db := Db{id = 3}
	argv := [][]u8{transmute([]u8)string("set"), transmute([]u8)string("key"), transmute([]u8)string("value")}
	events := []Keyspace_Event{{kind = .Notify, class = .Expired, always = true, db = 3, key = argv[1]}}
	task := Keyspace_Task{op = .Set, argv = argv, client = {fd = -1, db = &db, reply = {.Off, .Skip}}, dirty = 1, ok = true, events = events}
	keyspace_features_aof(&task)
	testing.expect_value(t, aof.stage_count, 2)
	aof_tx_end()
	testing.expect_value(t, string(aof.buf[:]), "*1\r\n$5\r\nMULTI\r\n*2\r\n$6\r\nSELECT\r\n$1\r\n3\r\n*2\r\n$3\r\nDEL\r\n$3\r\nkey\r\n*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n*1\r\n$4\r\nEXEC\r\n")
	clear(&aof.buf)
	aof.in_tx = true
	task.events = nil
	keyspace_features_aof(&task)
	testing.expect_value(t, aof.stage_count, 1)
	aof_tx_end()
	testing.expect_value(t, string(aof.buf[:]), "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n")
	clear(&aof.buf)
	aof.in_tx = true
	task.failed = true
	keyspace_features_aof(&task)
	testing.expect_value(t, aof.stage_count, 0)
	aof_tx_end()
	testing.expect_value(t, len(aof.buf), 0)
}
