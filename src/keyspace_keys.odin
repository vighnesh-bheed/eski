package main

import ks "keyspace"
import "rdb"
import ht "hashtype"
import lt "listtype"
import st "settype"
import zt "zsettype"
import sm "streamtype"

keyspace_key_target :: proc(name: string, argv: [][]u8, source_db: int) -> (target: int, replace, ok: bool) {
	target = source_db
	if name == "move" {
		id, parsed := parse_i64(argv[2])
		return int(id), false, parsed && id >= 0 && id < i64(len(dbs))
	}
	if name != "copy" { return target, false, true }
	for at := 3; at < len(argv); at += 1 {
		if eq_nocase(argv[at], "replace") { replace = true } else if eq_nocase(argv[at], "db") && at + 1 < len(argv) {
			id, parsed := parse_i64(argv[at + 1]); if !parsed || id < 0 || id >= i64(len(dbs)) { return target, replace, false }
			target = int(id); at += 1
		} else { return target, replace, false }
	}
	return target, replace, true
}

keyspace_key_execute :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	defer job.abort = task.failed
	name := task.command_name
	if name == "dump" {
		r := task.records[0]; keyspace_expire(task, r); keyspace_read(task, r)
		if !r.exists { task.null = true; return }
		task.results[0] = keyspace_record_payload(task, r)
		if task.results[0] != nil { task.bulk = true }; return
	}
	if name == "restore" { keyspace_restore_execute(task); return }
	source, destination := task.records[0], task.records[1]
	_, replace, valid := keyspace_key_target(name, task.argv, task.client.db.id)
	if !valid { task.failed = true; return }
	if source == destination {
		if name == "copy" || name == "move" { task.failed = true; return }
		keyspace_expire(task, source); keyspace_touch(task, source)
		if !source.exists { task.failed = true; return }; task.ok = name == "rename"; return
	}
	keyspace_expire(task, source); keyspace_touch(task, source)
	if !source.exists { if name == "rename" || name == "renamenx" { task.failed = true }; return }
	keyspace_expire(task, destination); keyspace_touch(task, destination)
	if destination.exists && (name == "move" || name == "renamenx" || name == "copy" && !replace) { return }
	if name == "copy" {
		if source.kind == u8(Obj_Type.String) {
			keyspace_save(task, destination, source.value, source.expire_at)
			destination.encoding = source.encoding; destination.string_copy = true
		} else {
			work, ok := keyspace_object_work(task, source, Obj_Type(source.kind))
			if !ok { return }; defer keyspace_object_discard(&work)
			if !keyspace_object_commit(task, destination, &work, true) { return }
			destination.expire_at = source.expire_at
		}
	} else {
		if name == "rename" || !destination.exists { keyspace_notify(task, destination, .New, "new") }
		ks.record_object_clear(destination); ks.value_release(destination.value)
		destination.value = source.value; source.value = nil
		destination.object = source.object; source.object = nil
		destination.hash_minimum = source.hash_minimum; source.hash_minimum = 0
		destination.object_charge = source.object_charge; source.object_charge = 0
		destination.object_destroy = source.object_destroy
		destination.kind = source.kind; destination.encoding = source.encoding
		destination.string_copy = source.string_copy
		destination.exists = true; destination.changed = true; destination.value_changed = true
		destination.expire_at = source.expire_at
		source.exists = false; source.changed = true; source.value_changed = true; source.expire_at = 0
	}
	destination.clock = memory_worker_access_touch(&task.access, destination.clock, true); destination.touched = true
	task.integer = 1; task.ok = name == "rename"; task.dirty = 1
	if name == "copy" { keyspace_changed(task, destination, .Generic, "copy_to") } else if name == "move" {
		keyspace_changed(task, source, .Generic, "move_from"); keyspace_changed(task, destination, .Generic, "move_to")
	} else {
		keyspace_invalidate(task, source); keyspace_invalidate(task, destination)
		keyspace_notify(task, source, .Generic, "rename_from"); keyspace_notify(task, destination, .Generic, "rename_to")
	}
	keyspace_key_wake(task, destination)
}

keyspace_record_payload :: proc(task: ^Keyspace_Task, r: ^ks.Record) -> ^ks.Value {
	size := u128(keyspace_object_memory(Obj_Type(r.kind), r.object)) * 4 + u128(keyspace_object_length(Obj_Type(r.kind), r.object)) * 128 + u128(len(ks.value_data(r.value))) * 4 + 2 * rdb.LZF_CONTEXT_BYTES + 8192
	if size > u128(max(int)) || !ks.reserve_external(&keyspace_pool, int(size)) { task.failed = true; return nil }
	defer ks.release_external(&keyspace_pool, int(size))
	registry: ht.Registry
	defer ht.registry_destroy(&registry)
	hash: ht.Hash
	if r.kind == u8(Obj_Type.Hash) {
		hash = cast(ht.Hash)r.object
		minimum := keyspace_hash_binding_minimum(hash, r.hash_minimum)
		if minimum != ht.EB_EXPIRE_TIME_INVALID { ht.registry_add(&registry, hash, minimum) }
	}
	defer { if hash != nil { keyspace_hash_detach(hash) } }
	writer: rdb.Writer
	rdb.writer_init_mem(&writer, pst.compression, false)
	defer rdb.writer_destroy(&writer)
	value := Slot_Value{str = ks.value_data(r.value), obj = r.object, type = Obj_Type(r.kind)}
	dump_payload(&writer, transmute([]u8)r.key, value)
	if writer.failed { task.failed = true; return nil }
	result := ks.value_new(&keyspace_pool, rdb.writer_bytes(&writer))
	if result == nil { task.failed = true }
	return result
}

Keyspace_Restore :: struct {
	replace, absolute: bool,
	idle, freq: i64,
}

keyspace_restore_options :: proc "contextless" (argv: [][]u8) -> (options: Keyspace_Restore, ok: bool) {
	options.idle = -1; options.freq = -1
	for at := 4; at < len(argv); at += 1 {
		word := argv[at]
		switch {
		case eq_nocase(word, "replace"): options.replace = true
		case eq_nocase(word, "absttl"): options.absolute = true
		case at + 1 < len(argv) && options.freq < 0 && eq_nocase(word, "idletime"):
			value, parsed := parse_i64(argv[at + 1]); if !parsed || value < 0 { return options, false }; options.idle = value; at += 1
		case at + 1 < len(argv) && options.idle < 0 && eq_nocase(word, "freq"):
			value, parsed := parse_i64(argv[at + 1]); if !parsed || value < 0 || value > 255 { return options, false }; options.freq = value; at += 1
		case: return options, false
		}
	}
	return options, true
}

keyspace_restore_execute :: proc(task: ^Keyspace_Task) {
	argv := task.argv
	options, parsed := keyspace_restore_options(argv)
	if !parsed { task.failed = true; return }
	r := task.records[0]
	keyspace_expire(task, r); keyspace_touch(task, r)
	if r.exists && !options.replace { task.failed = true; return }
	ttl, numeric := parse_i64(argv[2])
	if !numeric || ttl < 0 || !dump_verify(argv[3]) { task.failed = true; return }
	payload := argv[3]
	budget := u128(2 << 20) + u128(len(payload)) * (rdb.LZF_DECODE_MAX_RATIO + 64) * 512
	if budget > u128(max(int)) || !ks.reserve_external(&keyspace_pool, int(budget)) { task.failed = true; return }
	reservation := int(budget)
	defer ks.release_external(&keyspace_pool, reservation)
	reader: rdb.Reader
	rdb.reader_init_mem(&reader, payload, false)
	defer rdb.reader_destroy(&reader)
	kind := rdb.get_type(&reader)
	if kind == rdb.TYPE_ZSET || kind == rdb.TYPE_ZSET_2 {
		count := rdb.get_len(&reader)
		if count == rdb.LENERR || count > u64(len(payload)) { task.failed = true; return }
		rdb.reader_destroy(&reader); rdb.reader_init_mem(&reader, payload, false); kind = rdb.get_type(&reader)
	}
	object: rawptr
	object_kind := Obj_Type.String
	string_value: []u8
	switch kind {
	case rdb.TYPE_STRING:
		value, ok := rdb.get_string(&reader, 2); if !ok { task.failed = true; return }; string_value = value
	case rdb.TYPE_LIST, rdb.TYPE_LIST_ZIPLIST, rdb.TYPE_LIST_QUICKLIST, rdb.TYPE_LIST_QUICKLIST_2:
		object = lt.rdb_load(&reader, kind, true); object_kind = .List
	case rdb.TYPE_SET, rdb.TYPE_SET_INTSET, rdb.TYPE_SET_LISTPACK:
		object = st.rdb_load(&reader, kind, true); object_kind = .Set
	case rdb.TYPE_ZSET, rdb.TYPE_ZSET_2, rdb.TYPE_ZSET_ZIPLIST, rdb.TYPE_ZSET_LISTPACK:
		object = zt.rdb_load(&reader, kind, true); object_kind = .Zset
	case rdb.TYPE_HASH, rdb.TYPE_HASH_ZIPMAP, rdb.TYPE_HASH_ZIPLIST, rdb.TYPE_HASH_LISTPACK, rdb.TYPE_HASH_METADATA_PRE_GA, rdb.TYPE_HASH_LISTPACK_EX_PRE_GA, rdb.TYPE_HASH_METADATA, rdb.TYPE_HASH_LISTPACK_EX:
		object = ht.rdb_load(&reader, kind, true); object_kind = .Hash
	case rdb.TYPE_STREAM_LISTPACKS, rdb.TYPE_STREAM_LISTPACKS_2, rdb.TYPE_STREAM_LISTPACKS_3:
		object = sm.rdb_load(&reader, kind, true); object_kind = .Stream
	case: task.failed = true; return
	}
	defer { if object != nil { keyspace_object_destructor(object_kind)(object) } }
	if reader.status != .Ok || (object_kind != .String && object == nil) { task.failed = true; return }
	if task.restore_deep { task.sanitized = 1 }
	at := ttl
	lapsed := false
	if ttl != 0 {
		if options.absolute { lapsed = ttl <= task.now } else if ttl > max(i64) - task.now { lapsed = true } else { at += task.now }
	}
	if lapsed {
		task.dirty = i64(r.exists)
		if r.exists { keyspace_remove(r); keyspace_changed(task, r, .Generic, "del") }; task.ok = true; return
	}
	if object_kind == .String {
		if !keyspace_value(task, string_value) { return }
		rdb.reader_destroy(&reader)
		ks.release_external(&keyspace_pool, reservation); reservation = 0
		keyspace_save(task, r, task.values[0], min(at, MAX_EXPIRE_MS))
	} else {
		rdb.reader_destroy(&reader)
		work := Keyspace_Object_Work{kind = object_kind, object = object, charge = reservation}; object = nil; reservation = 0
		if object_kind == .Hash {
			minimum := ht.min_expire(cast(ht.Hash)work.object, true)
			if minimum != ht.EB_EXPIRE_TIME_INVALID { work.hash_minimum = minimum }
		}
		defer keyspace_object_discard(&work)
		if !keyspace_object_commit(task, r, &work, true) { return }
		r.expire_at = min(at, MAX_EXPIRE_MS)
	}
	r.clock = memory_worker_access_touch(&task.access, r.clock, true); r.touched = true
	if options.idle >= 0 && !task.access.lfu {
		clock := i64(task.job.clock) - options.idle
		if clock < 0 { clock += LRU_CLOCK_MAX }
		r.clock = u32(clock & LRU_CLOCK_MAX); r.touched = true
	}
	if options.freq >= 0 && task.access.lfu { r.clock = u32(task.access.minutes) << 8 | u32(options.freq) }
	task.ok = true; task.dirty = 1
	keyspace_changed(task, r, .Generic, "restore"); keyspace_key_wake(task, r)
}

keyspace_key_wake :: proc(task: ^Keyspace_Task, r: ^ks.Record) {
	if r.exists && (r.kind == u8(Obj_Type.List) || r.kind == u8(Obj_Type.Zset) || r.kind == u8(Obj_Type.Stream)) { keyspace_wake(task, r, Obj_Type(r.kind)) }
}
