package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import ks "@KEYSPACE@"

SLAB_BACKING :: 1 << 22
Slab :: struct {
	base: [^]u8,
	top:  int,
	live: int,
}
Mc_Table :: struct {}
Lazy_Mode :: enum { Off, Async, Server }
Value_Config :: struct { lazyfree_lazy_server_del: bool }
labels_on: bool
lazy_mode: Lazy_Mode
cfg: Value_Config
entry_ring: [ENTRY_RING]Entry
entry_next: uint
slab_backing: [SLAB_BACKING]u8
storage_table_bytes: int
storage_table_mapped: int
store_rehashing: int
store_warming: int
store_no_touch: bool
db_used_memory: int
maxmemory_bytes: u64

Storage_Kind :: enum { Table }
Db :: struct {
	t:             [2]Table,
	slab:          Slab,
	rehash_idx:    i64,
	rehash_credit: int,
	expires:       int,
	heap_objs:     int,
	heap_bytes:    int,
	next:          Table,
	next_warm:     int,
	mc:            ^Mc_Table,
	role:          u8,
}

Scan_Pass :: struct {
	db:       ^Db,
	examined: i64,
	offered:  int,
}

store_fatal :: proc "contextless" (message: string) -> ! { context = runtime.default_context(); panic(message) }
slab_ptr :: proc "contextless" (s: ^Slab, off: u32) -> [^]u8 { return s.base[int(off) * SLAB_UNIT:] }
slab_alloc :: proc "contextless" (s: ^Slab, n: int) -> u32 {
	if s.base == nil {
		s.base = raw_data(slab_backing[:])
		s.top = SLAB_UNIT
	}
	size := (n + SLAB_UNIT - 1) &~ (SLAB_UNIT - 1)
	if s.top + size > SLAB_BACKING { store_fatal("bridge slab exhausted") }
	off := u32(s.top / SLAB_UNIT)
	s.top += size
	s.live += n
	return off
}
slab_free :: proc "contextless" (s: ^Slab, off: u32, n: int) {
	if int(off) * SLAB_UNIT + n > s.top || s.live < n { store_fatal("bridge slab release out of range") }
	s.live -= n
}
graveyard_push :: proc "contextless" (base: [^]u8, size: int, kind: Storage_Kind) {
	context = runtime.default_context()
	assert(kind == .Table)
	assert(posix.munmap(base, uint(size)) == .OK)
	storage_table_mapped -= size
}
mem_used :: proc "contextless" () -> int { store_fatal("bridge has no memory limit") }
no_objects :: proc "contextless" () -> ! { store_fatal("bridge values carry no objects") }
label_vset_release :: proc "contextless" (db: ^Db, obj: rawptr) { no_objects() }
lazyfree_object :: proc "contextless" (type: Obj_Type, obj: rawptr) -> (int, bool) { no_objects() }
set_object_release :: proc "contextless" (obj: rawptr) -> int { no_objects() }
list_object_release :: proc "contextless" (obj: rawptr) -> int { no_objects() }
zset_object_release :: proc "contextless" (obj: rawptr) -> int { no_objects() }
stream_object_release :: proc "contextless" (obj: rawptr) -> int { no_objects() }
object_release :: proc "contextless" (type: Obj_Type, obj: rawptr) -> int { no_objects() }
block_note_removed :: proc "contextless" () { no_objects() }
mc_meta_on_write :: proc "contextless" (db: ^Db, kp: ^Key_Handle) {
	if db.mc != nil || kp == nil { store_fatal("bridge has no memcached metadata") }
}
mc_meta_on_erase :: proc "contextless" (db: ^Db, kp: ^Key_Handle) {
	if db.mc != nil || kp == nil { store_fatal("bridge has no memcached metadata") }
}
mc_meta_rekey :: proc "contextless" (db: ^Db, old_bits: u64, new_bits: u64) {
	if db.mc != nil || old_bits == new_bits { store_fatal("bridge has no memcached metadata") }
}
scan_offer :: proc(pass: ^Scan_Pass, t: ^Table, slot: int, name: []u8) {
	assert(t.ctrl[slot] & 0x80 != 0)
	fmt.print("," if pass.offered > 0 else "", key_id(name), sep = "")
	pass.offered += 1
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

key_text :: proc(id: int) -> string { return fmt.aprintf("%07d", id) if id < 10_000_000 else fmt.aprintf("%012d", id) }
key_id :: proc(name: []u8) -> i64 {
	id, ok := strconv.parse_i64(string(name), 10)
	assert(ok && len(name) == (7 if id < 10_000_000 else 12))
	return id
}

show_slot :: proc(db: ^Db, t: ^Table, i: int) {
	kh := t.slots[i].key
	name := key_bytes(&t.slots[i].key, &db.slab)
	timed := key_timed(kh)
	form := int(kh.small.tag.key_form)
	letter := "i"
	if form == FORM_SLAB {
		letter = "s"
	} else if form == FORM_HEAP {
		letter = "h"
		assert((^int)(kh.heap.addr)^ == len(name) && uintptr(raw_data(name)) == uintptr(kh.heap.addr) + 8)
	} else {
		assert(!timed && form == FORM_INLINE + len(name))
	}
	fmt.printf("%d:%d:%d:%s", key_id(name), t.slots[i].val.bits, t.slots[i].meta.stamp, letter)
	if timed {
		cell := key_deadline_ptr(kh, &db.slab)
		gap := DEADLINE_BYTES if form == FORM_SLAB else DEADLINE_BYTES + 8
		assert(uintptr(cell) + uintptr(gap) == uintptr(raw_data(name)))
		assert(intrinsics.unaligned_load(cell) == u64(key_deadline(kh, &db.slab)))
		fmt.printf("t%d", u64(key_deadline(kh, &db.slab)))
	} else {
		fmt.print("u")
	}
}
show_table :: proc(db: ^Db, t: ^Table) {
	kind := "-"
	if t.region != nil { kind = "h" if t.warm_at < 0 else "m" }
	assert(t.region == nil || t.warm_at >= 0 || uintptr(t.region) % TABLE_HEAP_ALIGN == 0)
	fmt.printf("%d,%d,%d,%d,%s;", t.cap, t.live, t.tombs, t.growth, kind)
	for i in 0 ..< t.cap {
		if i > 0 { fmt.print(",") }
		switch t.ctrl[i] {
		case CTRL_EMPTY: fmt.print("-")
		case CTRL_DELETED: fmt.print("x")
		case: show_slot(db, t, i)
		}
	}
}

start_resize :: proc(db: ^Db, size: int) {
	assert(db.rehash_idx < 0)
	db.t[1] = table_alloc_for(db, size)
	db.rehash_idx = 0
	store_rehashing += 1
}

release_keys :: proc(db: ^Db) {
	for &t in db.t {
		for i in 0 ..< t.cap {
			if t.ctrl[i] & 0x80 != 0 { key_release(db, &t.slots[i].key) }
		}
		table_detach(&t)
	}
	table_detach(&db.next)
	if db.rehash_idx >= 0 { store_rehashing -= 1 }
	assert(db.slab.live == 0 && db.heap_bytes == 0 && db.heap_objs == 0 && db_used_memory == 0)
	assert(storage_table_bytes == 0 && storage_table_mapped == 0 && store_rehashing == 0 && store_warming == 0)
}

Charge :: struct { id: int, bytes: int, region: []u8 }

value_key :: proc(db: ^Db) -> int {
	key := "0000042"
	l := lookup_make(transmute([]u8)key)
	t := &db.t[0]
	i, exists := table_find_slot(t, &db.slab, &l, true)
	assert(!exists && i >= 0)
	table_place(t, i, l.hash)
	key_store(db, &t.slots[i].key, transmute([]u8)key)
	t.slots[i].val.bits = 0
	t.slots[i].meta = {}
	return i
}

show_value :: proc(db: ^Db, slot: int) {
	e := entry_view(db, &db.t[0], slot)
	form := int(e.kp.small.tag.val_form)
	letter := "o"
	empty_block := 0
	switch {
	case form == FORM_NONE: letter = "n"
	case form <= FORM_INLINE + INLINE_BYTES: letter = "i"
	case form == FORM_SLAB: letter = "s"
	case form == FORM_HEAP:
		letter = "h"
		if (^Big_Str)(e.vp.ref.addr).data == nil { empty_block = 1 }
	}
	sum := u64(0xcbf29ce484222325)
	for b in e.val { sum = (sum ~ u64(b)) * 0x100000001b3 }
	assert(db_used_memory == db.heap_bytes)
	fmt.printf("V|%s|%d|%d|%d|%d|%d|%d|%x\n", letter, len(e.val), e.cap, db.heap_objs, db.heap_bytes, db.slab.live, empty_block, sum)
}

values :: proc(path: string) {
	input, err := os.read_entire_file(path, context.allocator)
	assert(err == nil)
	defer delete(input)
	lines := strings.split(string(input), "\n")
	defer delete(lines)
	db: Db
	db.rehash_idx = -1
	slot := -1
	fill: [dynamic]u8
	defer delete(fill)
	ops := 0
	for line in lines {
		if len(line) == 0 { continue }
		fields := strings.split(line, " ")
		defer delete(fields)
		code := fields[0]
		if code == "X" {
			if slot >= 0 { db_erase(&db, &db.t[0], slot) }
			release_keys(&db)
			db = {}
			db.role = u8(number(fields[1]))
			db.t[0] = table_alloc_for(&db, TABLE_MIN_CAP)
			db.rehash_idx = -1
			slot = value_key(&db)
			continue
		}
		if code == "E" {
			db_erase(&db, &db.t[0], slot)
			slot = value_key(&db)
		} else {
			n := number(fields[len(fields) - 1])
			clear(&fill)
			for _ in 0 ..< n { append(&fill, u8('a' + ops % 26)) }
			ops += 1
			e := entry_view(&db, &db.t[0], slot)
			switch code {
			case "S": entry_store(e, fill[:], .Raw if fields[1] == "r" else .Embstr, fields[1] != "r")
			case "A": entry_append(e, fill[:])
			case "G": entry_setrange(e, number(fields[1]), fill[:])
			case "M":
				assert(e.kp.small.tag.val_form == FORM_NONE)
				moved: Val_Handle
				moved.slab.info = Val_Info{type = .String, enc = .Raw}
				e.vp^ = db_move_heap(&db, raw_data(fill[:]), n, moved)
				e.kp.small.tag.val_form = FORM_HEAP
			case: panic("invalid value trace")
			}
		}
		show_value(&db, slot)
	}
	if slot >= 0 { db_erase(&db, &db.t[0], slot) }
	release_keys(&db)
}

main :: proc() {
	assert(size_of(int) == 8)
	if len(os.args) == 3 && os.args[2] == "values" {
		values(os.args[1])
		return
	}
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
			release_keys(&db)
			db = {}
			db.role = u8(number(fields[2]))
			db.t[0] = table_alloc_for(&db, number(fields[1]))
			db.rehash_idx = -1
			continue
		}
		if code == "S" {
			pass := Scan_Pass{db = &db}
			fmt.print("S|")
			next := scan_round(&pass, unsigned(fields[1]))
			fmt.printf("|%d\n", next)
			continue
		}
		reply := 0
		query := false
		found_table: ^Table
		found_index := -1
		switch code {
		case "G":
			start_resize(&db, number(fields[1]))
		case "B":
			assert(db.rehash_idx < 0)
			db_rehash_start(&db, number(fields[1]))
		case "O":
			_ = db_make_room(&db)
		case "U":
			size := db.t[0].cap
			if db.t[0].live > size * 7 / 16 { size = table_grow_cap(size) }
			start_resize(&db, size)
		case "V":
			start_resize(&db, table_round_cap(db.t[0].live * 2))
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
				if i >= 0 { db_erase(&db, t, i); reply = 1 }
			} else {
				deadline := unsigned(fields[4])
				if i < 0 {
					t = &db.t[1] if db.rehash_idx >= 0 else &db.t[0]
					exists: bool
					i, exists = table_find_slot(t, &db.slab, &l, true)
					assert(!exists && i >= 0)
					table_place(t, i, l.hash)
					if deadline != 0 {
						key_store_timed(&db, &t.slots[i].key, transmute([]u8)key, deadline)
						db.expires += 1
					} else {
						key_store(&db, &t.slots[i].key, transmute([]u8)key)
					}
					reply = 1
				} else {
					key_set_deadline(&db, &t.slots[i].key, i64(deadline))
				}
				t.slots[i].val.bits = unsigned(fields[3])
				t.slots[i].meta = Slot_Meta{stamp = u16(number(fields[5]))}
			}
		case: panic("invalid trace")
		}
		fmt.print("T|")
		if query {
			if found_index >= 0 { show_slot(&db, found_table, found_index) } else { fmt.print("n") }
		} else { fmt.print(reply) }
		assert(db_used_memory == db.heap_bytes)
		fmt.printf("|%d|%d|%d,%d,%d,%d|", db.rehash_idx, db.role, db.expires, db.slab.live + db.heap_bytes, storage_table_bytes, storage_table_mapped)
		show_table(&db, &db.t[0])
		fmt.print("|")
		show_table(&db, &db.t[1])
		fmt.println()
	}
	assert(ks.memory_used(&pool) == 0 && len(charges) == 0)
	release_keys(&db)
}
