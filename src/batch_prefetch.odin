package main

import "base:intrinsics"
import request_parser "request_parser"

BATCH_AHEAD_COMMANDS :: 32
BATCH_AHEAD_ARGS :: 256
BATCH_AHEAD_KEYS :: 32
BATCH_AHEAD_KEY_BYTES :: 512

Batch_Command :: struct {
	start: int,
	slot:  ^Cmd_Slot,
}

Batch :: struct {
	ahead:    int,
	count:    int,
	next:     int,
	keys:     int,
	owned:    int,
	commands: [BATCH_AHEAD_COMMANDS]Batch_Command,
	hashes:   [BATCH_AHEAD_KEYS]u64,
}

Key_Range :: struct {
	first: i8,
	last:  i8,
	step:  i8,
	write: bool,
}

#assert(size_of(Key_Range) == 4)

command_key_range :: proc "contextless" (cmd: ^Command) -> Key_Range {
	if cmd == nil {
		return {}
	}
	for &s in cmd_specs {
		if s.name != cmd.name {
			continue
		}
		if s.first <= 0 || s.first > 127 || s.step <= 0 || s.step > 127 || s.last < -128 || s.last > 127 {
			return {}
		}
		return Key_Range{first = i8(s.first), last = i8(s.last), step = i8(s.step), write = .Write in s.flags}
	}
	return {}
}

key_range_last :: #force_inline proc "contextless" (r: Key_Range, argc: int) -> int {
	if r.last >= 0 {
		return int(r.first) + int(r.last)
	}
	return argc + int(r.last)
}

batch_prefetch_key :: #force_inline proc "contextless" (b: ^Batch, db: ^Db, key: []u8, write, table, directory: bool) #no_bounds_check {
	h := hash_bytes(key)
	if table {
		table_prefetch_home(&db.t[0], h, write)
		if db.rehash_idx >= 0 {
			table_prefetch_home(&db.t[1], h, write)
		}
	}
	if directory {
		owned := h ~ (u64(db.id) * WY_P1)
		slots := keyspace_index_slots()
		intrinsics.prefetch_read_data(&slots[owned & u64(len(slots) - 1)], 3)
		b.hashes[b.owned] = owned
		b.owned += 1
	}
}

batch_slot :: #force_inline proc(b: ^Batch, start: int, name: []u8) -> ^Cmd_Slot #no_bounds_check {
	for b.next < b.count && b.commands[b.next].start < start {
		b.next += 1
	}
	if b.next < b.count && b.commands[b.next].start == start {
		slot := b.commands[b.next].slot
		b.next += 1
		if slot != nil && eq_nocase(name, slot.key) {
			return slot
		}
	}
	return lookup_entry(name)
}

batch_scan :: proc(c: ^Conn, b: ^Batch) #no_bounds_check {
	from := c.rpos
	b.count, b.next, b.keys, b.owned = 0, 0, 0, 0
	b.ahead = from + 1
	db := c.db
	if db == nil || c.partial_owner != nil {
		return
	}
	table := db.t[0].groups != 0
	directory := keyspace_records > 0
	if !table && !directory {
		return
	}
	input := c.rbuf[:c.rlen]
	end := c.rlen
	at := from
	args := 0
	seen: []u8
	seen_slot: ^Cmd_Slot
	scan: for b.count < BATCH_AHEAD_COMMANDS && at < end {
		count, cursor, ok := request_parser.read_nonnegative_header(input, at, '*')
		if !ok || count > i64(BATCH_AHEAD_ARGS - args) {
			break
		}
		args += int(count)
		slot: ^Cmd_Slot
		next, last, step, write := 0, -1, 1, false
		for i in 0 ..< int(count) {
			length, payload, valid := request_parser.read_nonnegative_header(input, cursor, '$')
			if !valid || length > i64(end - payload - 2) {
				break scan
			}
			cursor = payload + int(length) + 2
			if i == 0 {
				name := input[payload:cursor - 2]
				slot = seen_slot
				if !batch_same_name(name, seen) {
					slot = lookup_entry(name)
					seen, seen_slot = name, slot
				}
				if slot != nil && slot.keys.first > 0 && b.count > 0 {
					next, last, step, write = int(slot.keys.first), key_range_last(slot.keys, int(count)), int(slot.keys.step), slot.keys.write
				}
			} else if i == next && i <= last {
				if b.keys < BATCH_AHEAD_KEYS && length <= BATCH_AHEAD_KEY_BYTES {
					batch_prefetch_key(b, db, input[payload:cursor - 2], write, table, directory)
					b.keys += 1
				}
				next += step
			}
		}
		b.commands[b.count] = Batch_Command{start = at, slot = slot}
		b.count += 1
		at = cursor
	}
	if at > from {
		b.ahead = at
	}
	if b.owned > 0 {
		keyspace_index_prefetch(b.hashes[:b.owned])
	}
}

batch_same_name :: #force_inline proc "contextless" (a, b: []u8) -> bool #no_bounds_check {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
