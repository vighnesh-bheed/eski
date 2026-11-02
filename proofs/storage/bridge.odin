package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import ks "@KEYSPACE@"

Slab :: struct { base: [^]u8 }
SLAB_UNIT :: 8
storage_table_bytes: int
storage_table_mapped: int
store_rehashing: int
store_no_touch: bool

Storage_Kind :: enum { Table }
Db :: struct {
	t: [2]Table,
	slab: Slab,
	rehash_idx: i64,
	expires: int,
}

store_fatal :: proc "contextless" (message: string) -> ! { context = runtime.default_context(); panic(message) }
slab_ptr :: proc "contextless" (s: ^Slab, off: u32) -> [^]u8 { return s.base[int(off) * SLAB_UNIT:] }
graveyard_push :: proc "contextless" (base: [^]u8, size: int, kind: Storage_Kind) {
	context = runtime.default_context()
	assert(kind == .Table)
	assert(posix.munmap(base, uint(size)) == .OK)
}

number :: proc(s: string) -> int {
	v, ok := strconv.parse_i64(s, 10)
	assert(ok)
	return int(v)
}
unsigned :: proc(s: string) -> u64 {
	v, ok := strconv.parse_u64(s, 10)
	assert(ok)
	return v
}

key_text :: proc(id: int) -> string { return fmt.aprintf("%07d", id) }

show_slot :: proc(t: ^Table, i: int) {
	k := t.slots[i].key.bits & 0x00FF_FFFF_FFFF_FFFF
	bytes := ([^]u8)(&k)[:7]
	id, ok := strconv.parse_i64(string(bytes), 10)
	assert(ok)
	fmt.printf("%d:%d:%d:%d", id, t.slots[i].val.bits, t.slots[i].meta.expire_at, t.slots[i].meta.stamp)
}
show_table :: proc(t: ^Table) {
	fmt.printf("%d,%d,%d,%d;", t.cap, t.live, t.tombs, t.growth)
	for i in 0 ..< t.cap {
		if i > 0 { fmt.print(",") }
		switch t.ctrl[i] {
		case CTRL_EMPTY: fmt.print("-")
		case CTRL_DELETED: fmt.print("x"); assert(t.slots[i].meta.expire_at == 0 && t.slots[i].meta.stamp == 0)
		case: show_slot(t, i)
		}
	}
}

Charge :: struct { id: int, bytes: int, region: []u8 }

main :: proc() {
	assert(size_of(int) == 8)
	assert(len(os.args) == 2)
	input, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	defer delete(input)
	lines := strings.split(string(input), "\n")
	defer delete(lines)
	db: Db
	db.rehash_idx = -1
	pool: ks.Pool
	charges: [dynamic]Charge
	defer delete(charges)
	for line in lines {
		if len(line) == 0 { continue }
		fields := strings.split(line, " ")
		defer delete(fields)
		code := fields[0]
		if code == "A" {
			assert(ks.memory_used(&pool) == 0 && len(charges) == 0)
			pool = {}
			pool.initialized = fields[2] == "1"
			pool.configured = 1
			pool.memory_limit = number(fields[1])
			continue
		}
		if code == "E" || code == "P" || code == "L" || code == "F" || code == "N" || code == "W" || code == "Z" {
			ok := false
			if code == "N" {
				before := ks.memory_used(&pool)
				assert(before == 0)
				saved_limit := pool.memory_limit
				pool.memory_limit = size_of(ks.Record) + 32 + 3
				r := ks.record_new(&pool, 0, transmute([]u8)string("key"), 0, true, transmute([]u8)string("seed"), 0)
				assert(r == nil && ks.memory_used(&pool) == before)
				pool.memory_limit = saved_limit
			} else {
				id := number(fields[1])
				at := -1
				for charge, i in charges { if charge.id == id { at = i; break } }
				if code == "E" || code == "P" {
					assert(at < 0)
					bytes := number(fields[2])
					region: []u8
					if code == "E" { ok = ks.reserve_external(&pool, bytes) } else {
						region = ks.allocate(&pool, bytes)
						ok = len(region) > 0
					}
					if ok { append(&charges, Charge{id, bytes, region}) }
				} else if (code == "W" || code == "Z") && at >= 0 {
					charge := charges[at]
					assert(len(charge.region) > 1)
					other: ks.Pool
					if code == "W" { ok = ks.free(&other, charge.region) } else { ok = ks.free(&pool, charge.region[:len(charge.region) - 1]) }
					assert(!ok)
				} else if at >= 0 {
					charge := charges[at]
					if code == "L" {
						assert(len(charge.region) == 0)
						ks.release_external(&pool, charge.bytes)
						ok = true
					} else { ok = ks.free(&pool, charge.region) }
					ordered_remove(&charges, at)
				}
			}
			fmt.printf("K|%d|%d\n", 1 if ok else 0, ks.memory_used(&pool))
			continue
		}
		if code == "R" {
			for &t in db.t { table_detach(&t) }
			db = {}
			db.t[0] = table_alloc(number(fields[1]))
			db.rehash_idx = -1
			continue
		}
		reply := 0
		query := false
		found_table: ^Table
		found_index := -1
		switch code {
		case "G":
			assert(db.rehash_idx < 0)
			db.t[1] = table_alloc(number(fields[1]))
			db.rehash_idx = 0
			store_rehashing += 1
		case "M":
			if db.rehash_idx >= 0 { db_rehash_groups(&db, number(fields[1]), number(fields[2])) }
		case "I", "D", "Q":
			id := number(fields[1])
			key := key_text(id)
			defer delete(key)
			l := lookup_make(transmute([]u8)key)
			assert(l.hash == unsigned(fields[2]))
			t, i := db_locate(&db, &l)
			if code == "Q" {
				query = true
				found_table, found_index = t, i
			} else if code == "D" {
				if i >= 0 { table_erase(t, i, true); reply = 1 }
			} else {
				if i < 0 {
					t = &db.t[1] if db.rehash_idx >= 0 else &db.t[0]
					exists: bool
					i, exists = table_find_slot(t, &db.slab, &l, true)
					assert(!exists && i >= 0)
					table_place(t, i, l.hash)
					reply = 1
				}
				t.slots[i].key.bits = l.packed
				t.slots[i].val.bits = unsigned(fields[3])
				t.slots[i].meta = Slot_Meta{expire_at = unsigned(fields[4]), stamp = u16(number(fields[5]))}
			}
		case: panic("invalid trace")
		}
		fmt.print("T|")
		if query {
			if found_index >= 0 { show_slot(found_table, found_index) } else { fmt.print("n") }
		} else { fmt.print(reply) }
		fmt.printf("|%d|", db.rehash_idx)
		show_table(&db.t[0])
		fmt.print("|")
		show_table(&db.t[1])
		fmt.println()
	}
	assert(ks.memory_used(&pool) == 0 && len(charges) == 0)
	for &t in db.t { table_detach(&t) }
}
