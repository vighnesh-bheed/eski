package main

import "base:runtime"
import "core:testing"
import ht "hashtype"
import ks "keyspace"

Keyspace_Hash_Encoding_Case :: struct {
	argv:       []string,
	op:         Keyspace_Op,
	dictionary: bool,
	reply:      string,
	committed:  bool,
}

keyspace_hash_encoding_build :: proc(dictionary: bool) -> ht.Hash {
	h := ht.create()
	ht.set(h, transmute([]u8)string("a"), transmute([]u8)string("1"))
	ht.set(h, transmute([]u8)string("b"), transmute([]u8)string("2"))
	if dictionary { ht.convert(h) }
	return h
}

keyspace_hash_encoding_coordinator :: proc(c: Keyspace_Hash_Encoding_Case, argv: [][]u8, now: u64) -> ht.Hash {
	h := keyspace_hash_encoding_build(c.dictionary)
	values: [dynamic]i64
	defer delete(values)
	if c.op == .Hpersist {
		fields, err := ht.parse_fields_args(argv)
		if err == .None { ht.persist_fields(h, fields, now, &values) }
		return h
	}
	base := now if c.op == .Hexpire || c.op == .Hpexpire else 0
	args, err := ht.parse_expire_args(argv, c.op == .Hexpire || c.op == .Hexpireat, base)
	if err != .None { return h }
	registry: ht.Registry
	defer ht.registry_destroy(&registry)
	ht.expire_fields(&registry, nil, h, args.fields, args.expire_at, args.cond, now, &values)
	keyspace_hash_detach(h)
	return h
}

@(test)
private_hash_worker_expiry_without_field_changes_keeps_coordinator_encoding :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect(t, !keyspace_initialized && !keyspace_pool.initialized)
	if keyspace_initialized || keyspace_pool.initialized { return }
	saved := keyspace_pool
	defer keyspace_pool = saved
	keyspace_pool = ks.Pool{initialized = true, configured = 1, paused = true, memory_limit = 1 << 20, fd = -1}
	cases := []Keyspace_Hash_Encoding_Case{
		{argv = {"HEXPIRE", "key", "100", "FIELDS", "1", "missing"}, op = .Hexpire, reply = "*1\r\n:-2\r\n", committed = true},
		{argv = {"HPEXPIREAT", "key", "4102444800000", "XX", "FIELDS", "1", "a"}, op = .Hpexpireat, reply = "*1\r\n:0\r\n", committed = true},
		{argv = {"HEXPIREAT", "key", "4102444818", "GT", "FIELDS", "2", "a", "missing"}, op = .Hexpireat, dictionary = true, reply = "*2\r\n:0\r\n:-2\r\n", committed = true},
		{argv = {"HPEXPIRE", "key", "5000", "NX", "FIELDS", "1", "missing"}, op = .Hpexpire, dictionary = true, reply = "*1\r\n:-2\r\n", committed = true},
		{argv = {"HPERSIST", "key", "FIELDS", "2", "a", "missing"}, op = .Hpersist, reply = "*2\r\n:-1\r\n:-2\r\n"},
		{argv = {"HPERSIST", "key", "FIELDS", "1", "b"}, op = .Hpersist, dictionary = true, reply = "*1\r\n:-1\r\n"},
	}
	now := i64(1000)
	for c in cases {
		argv := make([][]u8, len(c.argv))
		defer delete(argv)
		for text, i in c.argv { argv[i] = transmute([]u8)text }
		expected := keyspace_hash_encoding_coordinator(c, argv, u64(now))
		defer ht.destroy(expected)
		h := keyspace_hash_encoding_build(c.dictionary)
		original := h.encoding
		r := ks.record_new(&keyspace_pool, 0, transmute([]u8)string("key"), 0, false, nil, 0)
		testing.expect(t, r != nil)
		if r == nil { ht.destroy(h); continue }
		r.exists = true
		r.kind = u8(Obj_Type.Hash)
		r.object = h
		r.encoding = keyspace_object_encoding(.Hash, h)
		r.object_destroy = keyspace_hash_destroy
		records := []^ks.Record{r}
		values: [1]^ks.Value
		results: [1]^ks.Value
		db := Db{id = 0}
		task := Keyspace_Task{op = c.op, argv = argv, records = records, values = values[:], results = results[:], now = now, limit = 1 << 20}
		task.client = Conn{fd = -1, db = &db, resp = RESP2}
		task.job.data = &task
		keyspace_hash_execute(&task.job)
		testing.expect(t, !task.failed)
		testing.expect_value(t, task.dirty, 0)
		testing.expect_value(t, task.subexpired, 0)
		testing.expect_value(t, len(task.events), 0)
		testing.expect_value(t, string(ks.value_data(task.results[0])), c.reply)
		worker := cast(ht.Hash)r.object
		testing.expect(t, r.exists && worker != nil)
		if worker != nil {
			testing.expect_value(t, worker.encoding, expected.encoding)
			testing.expect_value(t, worker.hfe != nil, expected.hfe != nil)
			testing.expect_value(t, ht.length(worker), ht.length(expected))
			testing.expect_value(t, r.encoding, keyspace_object_encoding(.Hash, expected))
		}
		testing.expect_value(t, r.changed, c.committed)
		testing.expect_value(t, worker == h, !c.committed)
		if c.committed && !c.dictionary {
			testing.expect_value(t, original, ht.Encoding.Listpack)
			testing.expect_value(t, expected.encoding, ht.Encoding.Listpack_Ex)
		}
		for value in task.results { ks.value_release(value) }
		testing.expect(t, ks.record_free(&keyspace_pool, r))
		testing.expect_value(t, ks.memory_used(&keyspace_pool), 0)
	}
}
