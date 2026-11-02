package main

import "base:runtime"
import "core:testing"
import ks "keyspace"

hash_publish_float_command := Command{name = "hincrbyfloat"}

@(test)
private_hash_publisher_uses_kernel_deadline_and_actual_suppressed_reply :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect(t, !keyspace_initialized && !keyspace_pool.initialized)
	if keyspace_initialized || keyspace_pool.initialized { return }
	saved_pool, saved_aof := keyspace_pool, aof
	defer { keyspace_pool = saved_pool; aof = saved_aof }
	testing.expect(t, ks.init(&keyspace_pool, 1, 65536))
	defer testing.expect(t, ks.destroy(&keyspace_pool))
	aof = Aof{feed = true, state = .Enabled, in_tx = true, selected_db = -1}
	defer { delete(aof.stage); delete(aof.buf) }
	db := Db{id = 3}
	argv := [][]u8{transmute([]u8)string("HPEXPIRE"), transmute([]u8)string("key"), transmute([]u8)string("250"), transmute([]u8)string("NX"), transmute([]u8)string("FIELDS"), transmute([]u8)string("2"), transmute([]u8)string("old"), transmute([]u8)string("new")}
	result := ks.value_new(&keyspace_pool, transmute([]u8)string("*2\r\n:0\r\n:1\r\n"))
	defer ks.value_release(result)
	task := Keyspace_Task{op = .Hpexpire, command_name = "hpexpire", argv = argv, client = {fd = -1, db = &db, reply = {.Off, .Skip}}, now = 1000000, hash_expire_at = 1234567, dirty = 1, raw = true, results = []^ks.Value{result}}
	aof_keyspace_hash(&task)
	testing.expect_value(t, aof.stage_count, 1)
	aof_tx_end()
	testing.expect_value(t, string(aof.buf[:]), "*2\r\n$6\r\nSELECT\r\n$1\r\n3\r\n*6\r\n$10\r\nHPEXPIREAT\r\n$3\r\nkey\r\n$7\r\n1234567\r\n$6\r\nFIELDS\r\n$1\r\n1\r\n$3\r\nnew\r\n")
	testing.expect_value(t, task.client.wlen, 0)
}

@(test)
private_hash_publisher_keeps_expiry_then_float_write_atomic_without_canonical_lookup :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect(t, !keyspace_initialized && !keyspace_pool.initialized)
	if keyspace_initialized || keyspace_pool.initialized { return }
	saved_pool, saved_aof := keyspace_pool, aof
	defer { keyspace_pool = saved_pool; aof = saved_aof }
	testing.expect(t, ks.init(&keyspace_pool, 1, 65536))
	defer testing.expect(t, ks.destroy(&keyspace_pool))
	aof = Aof{feed = true, state = .Enabled, in_tx = true, selected_db = -1}
	defer { delete(aof.stage); delete(aof.buf) }
	db := Db{id = 3}
	argv := [][]u8{transmute([]u8)string("HINCRBYFLOAT"), transmute([]u8)string("key"), transmute([]u8)string("field"), transmute([]u8)string("3.5")}
	result := ks.value_new(&keyspace_pool, transmute([]u8)string("$3\r\n3.5\r\n"))
	defer ks.value_release(result)
	expired := ks.value_new(&keyspace_pool, transmute([]u8)string("$5\r\nfield\r\n"))
	defer ks.value_release(expired)
	task := Keyspace_Task{op = .Hincrbyfloat, command = &hash_publish_float_command, argv = argv, client = {fd = -1, db = &db, reply = {.Off, .Skip}}, dirty = 1, raw = true, results = []^ks.Value{result}, hash_expired = expired, hash_expired_count = 1}
	aof_keyspace_hash(&task)
	testing.expect_value(t, aof.stage_count, 2)
	aof_tx_end()
	testing.expect_value(t, string(aof.buf[:]), "*1\r\n$5\r\nMULTI\r\n*2\r\n$6\r\nSELECT\r\n$1\r\n3\r\n*3\r\n$4\r\nHDEL\r\n$3\r\nkey\r\n$5\r\nfield\r\n*4\r\n$4\r\nHSET\r\n$3\r\nkey\r\n$5\r\nfield\r\n$3\r\n3.5\r\n*1\r\n$4\r\nEXEC\r\n")
	clear(&aof.buf)
	aof.in_tx = true
	task.hash_expired = nil
	task.hash_expired_count = 0
	task.hash_expire_at = 1234567
	aof_keyspace_hash(&task)
	testing.expect_value(t, aof.stage_count, 2)
	aof_tx_end()
	testing.expect_value(t, string(aof.buf[:]), "*1\r\n$5\r\nMULTI\r\n*4\r\n$4\r\nHSET\r\n$3\r\nkey\r\n$5\r\nfield\r\n$3\r\n3.5\r\n*6\r\n$10\r\nHPEXPIREAT\r\n$3\r\nkey\r\n$7\r\n1234567\r\n$6\r\nFIELDS\r\n$1\r\n1\r\n$5\r\nfield\r\n*1\r\n$4\r\nEXEC\r\n")
	testing.expect_value(t, task.client.wlen, 0)
}
