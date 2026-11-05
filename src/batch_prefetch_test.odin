package main

import "core:testing"
import request_parser "request_parser"

batch_test_bytes :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

batch_test_positions :: proc(slot: ^Cmd_Slot, argc: int, out: ^[dynamic]int) {
	clear(out)
	if slot.keys.first <= 0 {
		return
	}
	last := key_range_last(slot.keys, argc)
	for i := int(slot.keys.first); i <= last && i < argc; i += int(slot.keys.step) {
		append(out, i)
	}
}

@(test)
batch_key_positions_agree_with_the_command_registry :: proc(t: ^testing.T) {
	cases := [?]struct {
		argv: []string,
		want: []int,
	} {
		{{"get", "a"}, {1}},
		{{"SET", "a", "v", "EX", "10"}, {1}},
		{{"mget", "a", "b", "c"}, {1, 2, 3}},
		{{"mset", "a", "1", "b", "2"}, {1, 3}},
		{{"del", "a", "b"}, {1, 2}},
		{{"rename", "a", "b"}, {1, 2}},
		{{"lmove", "a", "b", "LEFT", "RIGHT"}, {1, 2}},
		{{"bitop", "AND", "d", "a", "b"}, {2, 3, 4}},
		{{"zunionstore", "d", "2", "a", "b"}, {1}},
		{{"hset", "h", "f", "v"}, {1}},
		{{"ping"}, {}},
		{{"eval", "return 1", "1", "a"}, {}},
		{{"object", "encoding", "a"}, {}},
		{{"xread", "STREAMS", "s", "0"}, {}},
	}
	positions := make([dynamic]int, context.temp_allocator)
	refs := make([dynamic]Key_Ref, context.temp_allocator)
	for e in cases {
		argv := make([][]u8, len(e.argv), context.temp_allocator)
		for s, i in e.argv {
			argv[i] = batch_test_bytes(s)
		}
		slot := lookup_entry(argv[0])
		testing.expectf(t, slot != nil, "%s is not registered", e.argv[0])
		if slot == nil {
			continue
		}
		batch_test_positions(slot, len(argv), &positions)
		testing.expectf(t, len(positions) == len(e.want), "%v gives key positions %v, want %v", e.argv, positions[:], e.want)
		for p, i in positions {
			if i < len(e.want) {
				testing.expectf(t, p == e.want[i], "%v gives key positions %v, want %v", e.argv, positions[:], e.want)
			}
		}
		spec: ^Cmd_Spec
		for &candidate in cmd_specs {
			if candidate.name == slot.cmd.name {
				spec = &candidate
			}
		}
		if spec == nil || len(positions) == 0 {
			continue
		}
		find_keys(spec, argv, &refs)
		for p in positions {
			found := false
			for r in refs {
				if r.pos == p {
					found = true
				}
			}
			testing.expectf(t, found, "%v prefetches position %d, which the registry does not report as a key", e.argv, p)
		}
	}
}

@(test)
batch_key_range_is_stored_for_every_command :: proc(t: ^testing.T) {
	ranged := 0
	for &slot in cmd_table {
		if slot.cmd == nil {
			testing.expect(t, slot.keys == Key_Range{})
			continue
		}
		testing.expectf(t, slot.keys == command_key_range(slot.cmd), "stored key range of %s differs from the registry", slot.key)
		if slot.keys.first > 0 {
			ranged += 1
			testing.expectf(t, slot.keys.step > 0, "%s has key range step %d", slot.key, slot.keys.step)
		}
	}
	testing.expect(t, ranged > 150 && ranged < cmd_count)
	get := lookup_entry(batch_test_bytes("get"))
	set := lookup_entry(batch_test_bytes("set"))
	testing.expect(t, get != nil && set != nil)
	if get != nil && set != nil {
		testing.expect(t, !get.keys.write)
		testing.expect(t, set.keys.write)
	}
}

Batch_Test_Table :: struct {
	ctrl:  [GROUP_SLOTS]u8,
	metas: [GROUP_SLOTS]Slot_Meta,
	keys:  [GROUP_SLOTS]Key_Handle,
	vals:  [GROUP_SLOTS]Val_Handle,
}

batch_test_keys :: proc(t: ^testing.T, input: string, db: ^Db) -> int {
	b: Batch
	batch_test_scan(t, input, 0, db, &b)
	return b.keys
}

batch_test_scan :: proc(t: ^testing.T, input: string, rpos: int, db: ^Db, b: ^Batch = nil) -> int {
	buffer := make([]u8, len(input) + 1, context.temp_allocator)
	copy(buffer, input)
	buffer[len(input)] = '*'
	c := Conn{fd = -1, db = db, kind = .Redis, rbuf = raw_data(buffer), rpos = rpos, rlen = len(input), rcap = len(buffer)}
	saved_argc := argc
	saved_args := raw_data(argv_buf)
	local: Batch
	scan := b if b != nil else &local
	scan.next = 7
	batch_scan(&c, scan)
	testing.expect_value(t, c.rpos, rpos)
	testing.expect_value(t, c.rlen, len(input))
	testing.expect_value(t, string(buffer[:len(input)]), input)
	testing.expect_value(t, argc, saved_argc)
	testing.expect(t, raw_data(argv_buf) == saved_args)
	testing.expect_value(t, scan.next, 0)
	testing.expect(t, scan.count >= 0 && scan.count <= BATCH_AHEAD_COMMANDS)
	at := rpos
	for i in 0 ..< scan.count {
		testing.expect(t, scan.commands[i].start >= at && scan.commands[i].start < scan.ahead)
		at = scan.commands[i].start + 1
	}
	testing.expect_value(t, scan.count > 0, scan.ahead > rpos + 1)
	return scan.ahead
}

@(test)
batch_scan_stops_at_the_first_frame_it_cannot_finish :: proc(t: ^testing.T) {
	storage: Batch_Test_Table
	db := Db{rehash_idx = -1}
	db.t[0] = Table{ctrl = &storage.ctrl[0], slots = soa_zip(meta = storage.metas[:], key = storage.keys[:], val = storage.vals[:]), groups = 1, cap = GROUP_SLOTS}
	get :: "*2\r\n$3\r\nGET\r\n$1\r\na\r\n"
	set :: "*3\r\n$3\r\nset\r\n$1\r\nb\r\n$1\r\nv\r\n"
	ping :: "*1\r\n$4\r\nPING\r\n"
	three :: get + set + ping
	testing.expect_value(t, batch_test_scan(t, three, 0, &db), len(three))
	testing.expect_value(t, batch_test_scan(t, three, len(get), &db), len(three))
	testing.expect_value(t, batch_test_scan(t, three + "*2\r\n$3\r\nGET\r\n$1", 0, &db), len(three))
	testing.expect_value(t, batch_test_scan(t, three + "*2\r\n$3\r\nGET\r\n$5\r\nab", 0, &db), len(three))
	testing.expect_value(t, batch_test_scan(t, three + "*2\r\n$3\r\nGET\r\n$1\r\n", 0, &db), len(three))
	testing.expect_value(t, batch_test_scan(t, three + "*2\r\n$3\r\nGET\r\n$1\r\na", 0, &db), len(three))
	testing.expect_value(t, batch_test_scan(t, three + "*2\r\n$3\r\nGET\r\n$1\r\na\r", 0, &db), len(three))
	testing.expect_value(t, batch_test_scan(t, three + "*", 0, &db), len(three))
	testing.expect_value(t, batch_test_scan(t, "PING\r\n" + three, 0, &db), 1)
	testing.expect_value(t, batch_test_scan(t, get + "PING\r\n" + three, 0, &db), len(get))
	testing.expect_value(t, batch_test_scan(t, get + "*-1\r\n" + three, 0, &db), len(get))
	testing.expect_value(t, batch_test_scan(t, get + "*2\r\n+3\r\nGET\r\n$1\r\na\r\n", 0, &db), len(get))
	testing.expect_value(t, batch_test_scan(t, get + "*2\r\n$03\r\nGET\r\n$1\r\na\r\n", 0, &db), len(get))
	testing.expect_value(t, batch_test_scan(t, get + "*2\r\n$9223372036854775807\r\nGET\r\n", 0, &db), len(get))
	empty :: "*0\r\n"
	testing.expect_value(t, batch_test_scan(t, empty + get, 0, &db), len(empty) + len(get))
	unknown :: "*2\r\n$7\r\nNOTACMD\r\n$1\r\na\r\n"
	testing.expect_value(t, batch_test_scan(t, get + unknown + get, 0, &db), 2 * len(get) + len(unknown))
	recorded: Batch
	testing.expect_value(t, batch_test_scan(t, get + unknown + three, 0, &db, &recorded), 2 * len(get) + len(unknown) + len(set) + len(ping))
	testing.expect_value(t, recorded.count, 5)
	starts := [?]int{0, len(get), len(get) + len(unknown), 2 * len(get) + len(unknown), 2 * len(get) + len(unknown) + len(set)}
	names := [?]string{"get", "", "get", "set", "ping"}
	for i in 0 ..< len(starts) {
		testing.expect_value(t, recorded.commands[i].start, starts[i])
		slot := recorded.commands[i].slot
		if names[i] == "" {
			testing.expect(t, slot == nil)
		} else {
			testing.expect(t, slot != nil && slot == lookup_entry(batch_test_bytes(names[i])))
		}
	}
	idle := Db{rehash_idx = -1}
	testing.expect_value(t, batch_test_scan(t, three, len(get), &idle), len(get) + 1)
	testing.expect_value(t, batch_test_scan(t, three, 0, nil), 1)
}

@(test)
batch_scan_is_bounded_by_commands_and_arguments :: proc(t: ^testing.T) {
	storage: Batch_Test_Table
	db := Db{rehash_idx = -1}
	db.t[0] = Table{ctrl = &storage.ctrl[0], slots = soa_zip(meta = storage.metas[:], key = storage.keys[:], val = storage.vals[:]), groups = 1, cap = GROUP_SLOTS}
	get :: "*2\r\n$3\r\nGET\r\n$1\r\na\r\n"
	many := ""
	for _ in 0 ..< BATCH_AHEAD_COMMANDS + 8 {
		many = batch_test_concat(many, get)
	}
	testing.expect_value(t, batch_test_scan(t, many, 0, &db), BATCH_AHEAD_COMMANDS * len(get))
	testing.expect_value(t, batch_test_scan(t, many, 4 * len(get), &db), (BATCH_AHEAD_COMMANDS + 4) * len(get))
	wide := "*300\r\n"
	for _ in 0 ..< 300 {
		wide = batch_test_concat(wide, "$1\r\nk\r\n")
	}
	testing.expect_value(t, batch_test_scan(t, batch_test_concat(wide, get), 0, &db), 1)
	testing.expect_value(t, batch_test_scan(t, batch_test_concat(get, wide), 0, &db), len(get))
	testing.expect_value(t, batch_test_scan(t, batch_test_concat(wide, get), len(wide), &db), len(wide) + len(get))
	mset := "*129\r\n$4\r\nMSET\r\n"
	for _ in 0 ..< 64 {
		mset = batch_test_concat(mset, "$1\r\nk\r\n$1\r\nv\r\n")
	}
	testing.expect_value(t, batch_test_scan(t, batch_test_concat(batch_test_concat(mset, mset), mset), 0, &db), len(mset))
	testing.expect_value(t, batch_test_scan(t, batch_test_concat(batch_test_concat(get, mset), mset), 0, &db), len(get) + len(mset))
}

batch_test_concat :: proc(a, b: string) -> string {
	out := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

@(test)
batch_slot_reuses_only_a_record_that_names_the_parsed_command :: proc(t: ^testing.T) {
	get := lookup_entry(batch_test_bytes("get"))
	set := lookup_entry(batch_test_bytes("set"))
	ping := lookup_entry(batch_test_bytes("ping"))
	testing.expect(t, get != nil && set != nil && ping != nil)
	if get == nil || set == nil || ping == nil {
		return
	}
	b: Batch
	b.count = 4
	b.commands[0] = Batch_Command{start = 0, slot = get}
	b.commands[1] = Batch_Command{start = 20, slot = set}
	b.commands[2] = Batch_Command{start = 40, slot = ping}
	b.commands[3] = Batch_Command{start = 60, slot = nil}
	testing.expect(t, batch_slot(&b, 0, batch_test_bytes("GET")) == get)
	testing.expect_value(t, b.next, 1)
	testing.expect(t, batch_slot(&b, 40, batch_test_bytes("get")) == get)
	testing.expect_value(t, b.next, 3)
	testing.expect(t, batch_slot(&b, 50, batch_test_bytes("Set")) == set)
	testing.expect_value(t, b.next, 3)
	testing.expect(t, batch_slot(&b, 60, batch_test_bytes("nosuchcommand")) == nil)
	testing.expect(t, batch_slot(&b, 60, batch_test_bytes("ping")) == ping)
	testing.expect_value(t, b.next, 4)
	testing.expect(t, batch_slot(&b, 80, batch_test_bytes("PING")) == ping)
	empty: Batch
	testing.expect(t, batch_slot(&empty, 0, batch_test_bytes("set")) == set)
	testing.expect(t, batch_slot(&empty, 0, nil) == nil)
}

@(test)
batch_scan_prefetches_registry_keys_of_every_recorded_command_within_its_caps :: proc(t: ^testing.T) {
	storage: Batch_Test_Table
	db := Db{rehash_idx = -1}
	db.t[0] = Table{ctrl = &storage.ctrl[0], slots = soa_zip(meta = storage.metas[:], key = storage.keys[:], val = storage.vals[:]), groups = 1, cap = GROUP_SLOTS}
	get :: "*2\r\n$3\r\nGET\r\n$1\r\na\r\n"
	ping :: "*2\r\n$4\r\nPING\r\n$1\r\na\r\n"
	mset :: "*5\r\n$4\r\nMSET\r\n$1\r\na\r\n$1\r\n1\r\n$1\r\nb\r\n$1\r\n2\r\n"
	bitop :: "*5\r\n$5\r\nBITOP\r\n$3\r\nAND\r\n$1\r\nd\r\n$1\r\na\r\n$1\r\nb\r\n"
	eval :: "*4\r\n$4\r\nEVAL\r\n$8\r\nreturn 1\r\n$1\r\n1\r\n$1\r\na\r\n"
	testing.expect_value(t, batch_test_keys(t, get, &db), 1)
	testing.expect_value(t, batch_test_keys(t, get + get + get, &db), 3)
	testing.expect_value(t, batch_test_keys(t, mset + mset, &db), 4)
	testing.expect_value(t, batch_test_keys(t, get + ping + bitop + eval, &db), 4)
	testing.expect_value(t, batch_test_keys(t, ping + bitop + eval, &db), 3)
	long := batch_test_concat("*2\r\n$3\r\nGET\r\n$513\r\n", batch_test_concat(string(make([]u8, 513, context.temp_allocator)), "\r\n"))
	edge := batch_test_concat("*2\r\n$3\r\nGET\r\n$512\r\n", batch_test_concat(string(make([]u8, 512, context.temp_allocator)), "\r\n"))
	testing.expect_value(t, batch_test_keys(t, batch_test_concat(batch_test_concat(get, long), edge), &db), 2)
	wide := "*65\r\n$4\r\nMSET\r\n"
	for _ in 0 ..< 32 {
		wide = batch_test_concat(wide, "$1\r\nk\r\n$1\r\nv\r\n")
	}
	testing.expect_value(t, batch_test_keys(t, batch_test_concat(batch_test_concat(batch_test_concat(get, wide), wide), get), &db), BATCH_AHEAD_KEYS)
	rehashing := db
	rehashing.rehash_idx = 0
	rehashing.t[1] = db.t[0]
	testing.expect_value(t, batch_test_keys(t, get + get, &rehashing), 2)
}

@(test)
batch_scan_records_directory_hashes_only_while_records_are_owned :: proc(t: ^testing.T) {
	storage: Batch_Test_Table
	db := Db{rehash_idx = -1, id = 3}
	db.t[0] = Table{ctrl = &storage.ctrl[0], slots = soa_zip(meta = storage.metas[:], key = storage.keys[:], val = storage.vals[:]), groups = 1, cap = GROUP_SLOTS}
	get :: "*2\r\n$3\r\nGET\r\n$1\r\na\r\n"
	other :: "*2\r\n$3\r\nGET\r\n$1\r\nb\r\n"
	testing.expect(t, keyspace_records == 0 && len(keyspace_index) == 0)
	if keyspace_records != 0 || len(keyspace_index) != 0 { return }
	b: Batch
	batch_test_scan(t, get + other + get, 0, &db, &b)
	testing.expect_value(t, b.keys, 3)
	testing.expect_value(t, b.owned, 0)
	keyspace_records = 1
	defer keyspace_records = 0
	batch_test_scan(t, get + other + get, 0, &db, &b)
	testing.expect_value(t, b.keys, 3)
	testing.expect_value(t, b.owned, 3)
	testing.expect_value(t, b.hashes[0], hash_bytes(batch_test_bytes("a")) ~ (u64(db.id) * WY_P1))
	testing.expect_value(t, b.hashes[1], hash_bytes(batch_test_bytes("b")) ~ (u64(db.id) * WY_P1))
	testing.expect_value(t, b.hashes[2], hash_bytes(batch_test_bytes("a")) ~ (u64(db.id) * WY_P1))
	empty := Db{rehash_idx = -1, id = 3}
	batch_test_scan(t, get + other, 0, &empty, &b)
	testing.expect_value(t, b.count, 2)
	testing.expect_value(t, b.keys, 2)
	testing.expect_value(t, b.owned, 2)
	testing.expect_value(t, b.hashes[0], hash_bytes(batch_test_bytes("a")) ~ (u64(db.id) * WY_P1))
	testing.expect_value(t, b.hashes[1], hash_bytes(batch_test_bytes("b")) ~ (u64(db.id) * WY_P1))
	keyspace_records = 0
	batch_test_scan(t, get + other, 0, &empty, &b)
	testing.expect_value(t, b.count, 0)
	testing.expect_value(t, b.owned, 0)
}

Batch_Test_Read :: struct {
	scans:    int,
	keys:     int,
	recorded: int,
	looked:   int,
}

batch_test_read :: proc(t: ^testing.T, input: string, db: ^Db) -> Batch_Test_Read {
	buffer := make([]u8, len(input), context.temp_allocator)
	copy(buffer, input)
	c := Conn{fd = -1, db = db, kind = .Redis, rbuf = raw_data(buffer), rlen = len(input), rcap = len(buffer)}
	scratch := request_parser.Scratch{args = make([][]u8, 64, context.temp_allocator)}
	out: Batch_Test_Read
	b: Batch = ---
	b.ahead = c.rpos
	b.count, b.next, b.keys, b.owned = 0, 0, 0, 0
	for c.rpos < c.rlen {
		start := c.rpos
		result := request_parser.parse_array(buffer[c.rpos:c.rlen], &scratch, request_parser.Limits{bulk_max = 1 << 20, base_offset = c.rpos})
		if result.kind != .Command {
			break
		}
		c.rpos += result.consumed
		if result.argc == 0 {
			continue
		}
		name := scratch.args[0]
		ahead := b.ahead
		expected: ^Cmd_Slot
		for i in b.next ..< b.count {
			if b.commands[i].start == start {
				expected = b.commands[i].slot
				break
			}
		}
		slot := batch_command_slot(&c, &b, start, name)
		testing.expect(t, slot == lookup_entry(name))
		if b.ahead != ahead {
			out.scans += 1
			out.keys += b.keys
			testing.expect_value(t, b.next, 0)
			testing.expect(t, b.count == 0 || b.commands[0].start == c.rpos)
			testing.expect(t, b.ahead > c.rpos)
		}
		if expected != nil && slot == expected {
			out.recorded += 1
		} else {
			out.looked += 1
		}
	}
	return out
}

@(test)
batch_scan_skips_a_read_with_one_request_and_runs_again_when_a_read_holds_more :: proc(t: ^testing.T) {
	storage: Batch_Test_Table
	db := Db{rehash_idx = -1}
	db.t[0] = Table{ctrl = &storage.ctrl[0], slots = soa_zip(meta = storage.metas[:], key = storage.keys[:], val = storage.vals[:]), groups = 1, cap = GROUP_SLOTS}
	get :: "*2\r\n$3\r\nGET\r\n$1\r\na\r\n"
	set :: "*3\r\n$3\r\nset\r\n$1\r\nb\r\n$1\r\nv\r\n"
	ping :: "*1\r\n$4\r\nPING\r\n"
	empty :: "*0\r\n"
	single := batch_test_read(t, get, &db)
	testing.expect_value(t, single, Batch_Test_Read{looked = 1})
	testing.expect_value(t, batch_test_read(t, set, &db), Batch_Test_Read{looked = 1})
	testing.expect_value(t, batch_test_read(t, empty + get, &db), Batch_Test_Read{looked = 1})
	testing.expect_value(t, batch_test_read(t, get + set + ping, &db), Batch_Test_Read{scans = 1, keys = 1, recorded = 2, looked = 1})
	testing.expect_value(t, batch_test_read(t, get, &db), single)
	testing.expect_value(t, batch_test_read(t, get + get, &db), Batch_Test_Read{scans = 1, keys = 1, recorded = 1, looked = 1})
	testing.expect_value(t, batch_test_read(t, get + empty + get, &db), Batch_Test_Read{scans = 1, keys = 1, recorded = 1, looked = 1})
	testing.expect_value(t, batch_test_read(t, get + "*2\r\n$3\r\nGET\r\n$1", &db), Batch_Test_Read{scans = 1, looked = 1})
	many := ""
	for _ in 0 ..< BATCH_AHEAD_COMMANDS + 8 {
		many = batch_test_concat(many, get)
	}
	testing.expect_value(t, batch_test_read(t, many, &db), Batch_Test_Read{scans = 2, keys = BATCH_AHEAD_KEYS + 7, recorded = BATCH_AHEAD_COMMANDS + 7, looked = 1})
	idle := Db{rehash_idx = -1}
	testing.expect_value(t, batch_test_read(t, get + set + ping, &idle), Batch_Test_Read{scans = 2, looked = 3})
}
