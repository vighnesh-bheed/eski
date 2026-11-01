package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import ks "keyspace"
import ht "hashtype"

VERSION :: "proof-harness"
REDIS_COMPAT_VERSION :: "7.4.0"

proof_number :: proc(s: string) -> i64 {
	n, ok := strconv.parse_i64(s, 10)
	assert(ok)
	return n
}

proof_bytes :: proc(s: string) -> []u8 { return transmute([]u8)s }

proof_hex :: proc(b: []u8) {
	for n in b { fmt.printf("%02x", n) }
}

proof_hash_state :: proc(h: ht.Hash, live: bool = false) {
	for f in 0 ..< 8 {
		buf: [24]u8
		n := format_i64(raw_data(buf[:]), i64(f))
		v, deadline, found := ht.get_raw(h, buf[:n])
		if !found { continue }
		if live {
			_, status := ht.get(h, buf[:n], u64(srv.now_ms), false)
			if status != .Ok { continue }
		}
		vb: [21]u8
		if deadline == ht.EB_EXPIRE_TIME_INVALID { deadline = 0 }
		fmt.printf("%d=%s@%d,", f, ht.value_bytes(v, &vb), deadline)
	}
}

proof_record :: proc(r: ^ks.Record) {
	fmt.printf("%s:%t:%d:%t:%t:%t:%d:%d:%d:%t:%d", ks.value_data(r.value), r.exists, r.clock, r.changed, r.value_changed, r.string_copy, r.expire_at, r.encoding, r.kind, r.touched, r.hash_minimum)
}

proof_rollback :: proc(mode: int) {
	assert(ks.memory_used(&keyspace_pool) == 0)
	r0 := ks.record_new(&keyspace_pool, 0, proof_bytes("0"), 0, true, proof_bytes("old0"), 71)
	r1 := ks.record_new(&keyspace_pool, 0, proof_bytes("1"), 0, true, proof_bytes("old1"), 72)
	assert(r0 != nil && r1 != nil)
	r0.expire_at = 9000; r0.string_copy = true; r0.encoding = 1; r0.touched = true; r0.hash_minimum = 123
	r1.expire_at = 10000; r1.changed = true; r1.value_changed = true; r1.encoding = 2; r1.hash_minimum = 456
	records := []^ks.Record{r0, r1, r0}
	argv := [][]u8{proof_bytes("MSET"), proof_bytes("0"), proof_bytes("a"), proof_bytes("1"), proof_bytes("b"), proof_bytes("0"), proof_bytes("c")}
	values: [3]^ks.Value
	results: [3]^ks.Value
	events: [32]Keyspace_Event
	poststates: [8]Keyspace_Poststate
	task := Keyspace_Task{op = .Mset, argv = argv, records = records, values = values[:], results = results[:], capture_poststate = true, event_storage = events[:], poststate_storage = poststates[:], now = 1000, limit = 1 << 20}
	job := ks.Job{data = &task}
	base := ks.memory_used(&keyspace_pool)
	budget := 0 if mode == 0 else len(records) * size_of(Keyspace_Undo) + 512 if mode == 1 else 2 << 20
	remaining := keyspace_pool.memory_limit - base - budget
	assert(ks.reserve_external(&keyspace_pool, remaining))
	keyspace_capture_execute(&job)
	ks.release_external(&keyspace_pool, remaining)
	if mode == 0 { assert(task.failed && !task.rolled_back) }
	if mode == 1 { assert(task.failed && task.rolled_back) }
	if mode == 2 { assert(!task.failed && !task.rolled_back) }
	if task.rolled_back {
		assert(task.dirty == 0 && len(task.events) == 0 && len(task.poststates) == 0)
		assert(task.hits == 0 && task.misses == 0 && task.expired == 0 && task.subexpired == 0 && task.sanitized == 0)
		assert(task.hash_expired == nil && task.hash_expired_count == 0 && !task.hash_aof_ready)
	}
	fmt.printf("K%d|%t|%t|", mode, task.failed, task.rolled_back)
	proof_record(r0); fmt.print(";"); proof_record(r1)
	fmt.printf("|%d|%d|%d\n", task.dirty, len(task.events), len(task.poststates))
	for value in task.values { ks.value_release(value) }
	for value in task.results { ks.value_release(value) }
	for state in task.poststates { ks.value_release(state.payload) }
	assert(ks.record_free(&keyspace_pool, r0) && ks.record_free(&keyspace_pool, r1))
	assert(ks.memory_used(&keyspace_pool) == 0)
}

proof_object_rollback :: proc() {
	r := ks.record_new(&keyspace_pool, 0, proof_bytes("0"), 0, false, nil, 19)
	h := ht.create()
	ht.set(h, proof_bytes("0"), proof_bytes("original"))
	r.object = h; r.exists = true; r.kind = u8(Obj_Type.Hash); r.object_destroy = keyspace_hash_destroy
	r.object_charge = ht.memory_usage(h); r.hash_minimum = 777; r.expire_at = 8888
	assert(ks.reserve_external(&keyspace_pool, r.object_charge))
	argv := [][]u8{proof_bytes("HSET"), proof_bytes("0"), proof_bytes("0"), proof_bytes("replacement")}
	values: [1]^ks.Value
	results: [1]^ks.Value
	events: [16]Keyspace_Event
	poststates: [2]Keyspace_Poststate
	task := Keyspace_Task{op = .Hset, argv = argv, records = []^ks.Record{r, r}, values = values[:], results = results[:], event_storage = events[:], poststate_storage = poststates[:], capture_poststate = true, now = 1000}
	job := ks.Job{data = &task}
	budget := 2 * size_of(Keyspace_Undo) + ht.memory_usage(h) * 4 + ht.length(h) * 128 + 8192
	remaining := keyspace_pool.memory_limit - ks.memory_used(&keyspace_pool) - budget
	assert(ks.reserve_external(&keyspace_pool, remaining))
	keyspace_capture_execute(&job)
	ks.release_external(&keyspace_pool, remaining)
	assert(task.failed && task.rolled_back && r.object != rawptr(h))
	v, _, found := ht.get_raw(cast(ht.Hash)r.object, proof_bytes("0"))
	assert(found && ht.value_eq(v, proof_bytes("original")))
	assert(r.clock == 19 && r.hash_minimum == 777 && r.expire_at == 8888 && len(task.events) == 0)
	for value in values { ks.value_release(value) }
	for value in results { ks.value_release(value) }
	assert(ks.record_free(&keyspace_pool, r))
	assert(ks.memory_used(&keyspace_pool) == 0)
	fmt.println("OBJECT|restored|aliases|metadata|balanced")
}

proof_key_fixtures :: proc() {
	db_count = 1
	db_init()
	store_reconciling = true
	defer store_reconciling = false
	conn := Conn{fd = -1, db = db_cur}
	for mode in 0 ..< 10 {
		deadline := i64(1250)
		if mode == 1 || mode == 9 { deadline = 1001 }
		if mode == 2 { deadline = 5000 }
		if mode == 3 || mode == 6 || mode == 7 { deadline = 0 }
		if mode == 5 || mode == 8 { deadline = 1000 }
		srv.now_ms = 1
		db_set(proof_bytes("key"), proof_bytes("final"), deadline)
		srv.now_ms = 1000
		aof = Aof{feed = true, state = .On, in_tx = true, selected_db = 0}
		argv := [5][]u8{proof_bytes("SET"), proof_bytes("key"), proof_bytes("final"), proof_bytes("PX"), proof_bytes("250")}
		if mode == 0 || mode == 1 {
			if mode == 1 { argv[4] = proof_bytes("1") }
			aof_tr_set(&conn, argv[:], proof_bytes("+OK\r\n"))
		} else if mode == 2 || mode == 3 {
			argv[3] = proof_bytes("KEEPTTL")
			aof_tr_set(&conn, argv[:4], proof_bytes("+OK\r\n"))
		} else if mode == 4 || mode == 5 {
			argv[0] = proof_bytes("GETEX"); argv[2] = proof_bytes("PXAT"); argv[3] = proof_bytes("1250") if mode == 4 else proof_bytes("1000")
			aof_tr_getex(&conn, argv[:4], proof_bytes("$5\r\nfinal\r\n"))
		} else if mode == 6 {
			argv[0] = proof_bytes("GETEX"); argv[2] = proof_bytes("PERSIST")
			aof_tr_getex(&conn, argv[:3], proof_bytes("$5\r\nfinal\r\n"))
		} else if mode == 7 {
			aof_propagate_as_is(&conn, [][]u8{proof_bytes("DEL"), proof_bytes("key")})
		} else {
			argv[3] = proof_bytes("PXAT"); argv[4] = proof_bytes("1000") if mode == 8 else proof_bytes("1001")
			aof_tr_set(&conn, argv[:], proof_bytes("+OK\r\n"))
		}
		fmt.printf("KEY%d|", mode); proof_hex(aof.stage[:]); fmt.println()
		delete(aof.stage); delete(aof.buf)
	}
	srv.now_ms = 1
	db_set(proof_bytes("key"), proof_bytes("original"), 5000)
	srv.now_ms = 1000
	conn.wlen = 0
	pst.dirty = 0
	cmd_set(&conn, [][]u8{proof_bytes("SET"), proof_bytes("key"), proof_bytes("new"), proof_bytes("PX"), proof_bytes("0")})
	assert(conn.wlen > 0 && conn.wbuf[0] == '-' && pst.dirty == 0)
	exists, deadline, value := aof_key_state(db_cur, proof_bytes("key"))
	assert(exists && deadline == 5000 && string(value.str) == "original")
	fmt.println("COMMAND_ERROR|ERR|value-preserved|deadline-preserved|dirty:0")
	if conn.wbuf != nil { runtime.heap_free(conn.wbuf) }
	db_flush_all()
}

proof_exact_now_fixtures :: proc() {
	for table in 0 ..< 2 {
		h := ht.create()
		if table == 1 { ht.convert(h) }
		ht.set(h, proof_bytes("0"), proof_bytes("value"))
		reg: ht.Registry
		out: [dynamic]i64
		ht.expire_fields(&reg, nil, h, [][]u8{proof_bytes("0")}, 100, .None, 1, &out)
		_, status := ht.get(h, proof_bytes("0"), 100, false)
		assert(status == .Ok && !ht.expire_if_needed(h, 100))
		clear(&out)
		ht.ttl_fields(h, [][]u8{proof_bytes("0")}, .Pttl, 100, &out)
		ttl := out[0]
		assert(ttl == (0 if table == 1 else -2))
		clear(&out)
		assert(ht.persist_fields(h, [][]u8{proof_bytes("0")}, 100, &out))
		assert(out[0] == 1 && ht.registered_expire(h) == 100)
		clear(&out)
		ht.expire_fields(&reg, nil, h, [][]u8{proof_bytes("0")}, 100, .None, 1, &out)
		expired: [dynamic]ht.Expired_Hash
		assert(ht.active_expire(&reg, 100, 1, &expired) == 1)
		assert(ht.length(h) == 0 && ht.registry_len(&reg) == 0)
		fmt.printf("BOUNDARY%d|live|persist|stale-min|active-removed|ttl:%d\n", table, ttl)
		delete(expired); delete(out); ht.registry_destroy(&reg); ht.destroy(h)
	}
}

main :: proc() {
	assert(len(os.args) == 2)
	keyspace_pool = ks.Pool{initialized = true, configured = 1, paused = true, memory_limit = 16 << 20, fd = -1}
	proof_rollback(0); proof_rollback(1); proof_rollback(2); proof_object_rollback()
	proof_key_fixtures()
	proof_exact_now_fixtures()
	input, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	defer delete(input)
	lines := strings.split(string(input), "\n")
	defer delete(lines)
	h := ht.create()
	defer ht.destroy(h)
	registry: ht.Registry
	defer ht.registry_destroy(&registry)
	db := Db{id = 3}
	for line in lines {
		if len(line) == 0 { continue }
		args := strings.split(line, " ")
		defer delete(args)
		if args[0] == "T" { srv.now_ms = proof_number(args[1]); continue }
		if args[0] == "R" {
			ht.destroy(h); ht.registry_destroy(&registry); h = ht.create()
			if args[1] == "1" { ht.convert(h) }
			srv.now_ms = proof_number(args[2])
			continue
		}
		aof = Aof{feed = true, state = .On, in_tx = true, selected_db = 3}
		field := proof_bytes(args[1])
		argv: [32][]u8
		argv[1] = proof_bytes("key"); argv[2] = field
		reply: [128]u8
		builder := Keyspace_Builder{bytes = reply[:]}
		task := Keyspace_Task{client = {fd = -1, db = &db}, dirty = 1, raw = true, hash_expire_at = 0}
		command: Command
		count_text: [24]u8
		task.capture_poststate = true
		trace := keyspace_hash_trace_begin(&task, h, &registry)
		registry.owner = &trace
		switch args[0] {
		case "W", "F":
			value := proof_bytes(args[2])
			ht.set(h, field, value)
			argv[0] = proof_bytes("HSET"); argv[3] = value
			task.op = .Hset; command.name = "hset"
			if args[0] == "F" {
				task.op = .Hincrbyfloat; command.name = "hincrbyfloat"; argv[0] = proof_bytes("HINCRBYFLOAT")
				task.hash_expire_at = proof_number(args[3])
				if task.hash_expire_at > 0 {
					out: [dynamic]i64
					ht.expire_fields(&registry, nil, h, [][]u8{field}, u64(task.hash_expire_at), .None, u64(srv.now_ms), &out)
					delete(out)
				}
				keyspace_builder_bulk(&builder, value)
			} else { keyspace_builder_integer(&builder, 1) }
			task.argv = argv[:4]
		case "X", "B":
			deadline_text := args[2] if args[0] == "X" else args[1]
			condition_text := args[3] if args[0] == "X" else args[2]
			deadline := proof_number(deadline_text)
			selected := [][]u8{field}
			if args[0] == "B" {
				selected = make([][]u8, len(args) - 3)
				for f, i in args[3:] { selected[i] = proof_bytes(f) }
			}
			defer { if args[0] == "B" { delete(selected) } }
			condition := ht.Expire_Condition.None
			switch condition_text {
			case "NX": condition = .NX
			case "XX": condition = .XX
			case "GT": condition = .GT
			case "LT": condition = .LT
			}
			out: [dynamic]i64
			ht.expire_fields(&registry, nil, h, selected, u64(deadline), condition, u64(srv.now_ms), &out)
			keyspace_builder_integer(&builder, i64(len(out)), '*')
			task.dirty = 0
			for code in out {
				keyspace_builder_integer(&builder, code)
				if code == 1 || code == 2 { task.dirty += 1 }
			}
			delete(out)
			argv[0] = proof_bytes("HPEXPIREAT"); argv[2] = proof_bytes(deadline_text); argv[3] = proof_bytes("FIELDS"); argv[4] = count_text[:format_i64(raw_data(count_text[:]), i64(len(selected)))]
			for f, i in selected { argv[5 + i] = f }
			task.argv = argv[:5 + len(selected)]; task.op = .Hpexpireat; task.command_name = "hpexpireat"; task.hash_expire_at = deadline
		case "P":
			out: [dynamic]i64
			changed := ht.persist_fields(h, [][]u8{field}, u64(srv.now_ms), &out)
			keyspace_builder_integer(&builder, 1, '*'); keyspace_builder_integer(&builder, out[0]); delete(out)
			task.dirty = 1 if changed else 0
			argv[0] = proof_bytes("HPERSIST"); argv[2] = proof_bytes("FIELDS"); argv[3] = proof_bytes("1"); argv[4] = field
			task.argv = argv[:5]; task.op = .Hpersist; command.name = "hpersist"
		case "G":
			ht.get(h, field, u64(srv.now_ms))
			task.dirty = 0; task.op = .Hget
			task.argv = argv[:3]
		case "D":
			removed := ht.delete_field(h, field)
			keyspace_builder_integer(&builder, 1 if removed else 0)
			task.dirty = 1 if removed else 0
			argv[0] = proof_bytes("HDEL"); task.argv = argv[:3]; task.op = .Hdel; command.name = "hdel"
		case: panic("invalid operation")
		}
		keyspace_hash_trace_finish(&task, &trace)
		assert(!task.failed)
		task.command = &command
		result := ks.value_new(&keyspace_pool, builder.bytes[:builder.used])
		task.results = []^ks.Value{result}
		aof_keyspace_hash(&task)
		proof_hash_state(h); fmt.print("|"); proof_hex(aof.stage[:]); fmt.print("|"); proof_hash_state(h, true); fmt.println()
		ks.value_release(result)
		ks.value_release(task.hash_expired)
		delete(aof.stage); delete(aof.buf)
		assert(ks.memory_used(&keyspace_pool) == 0)
	}
}
