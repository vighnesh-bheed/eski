package main

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"
import ht "hashtype"
import st "settype"
import zt "zsettype"
import "sysclock"

Entry :: struct {
	val:       []u8,
	cap:       u32,
	raw_enc:   bool,
	heap_tmp:  bool,
	expire_at: i64,
	db:        ^Db,
	mp:        ^Slot_Meta,
	kp:        ^Key_Handle,
	vp:        ^Val_Handle,
}

Db :: struct {
	t:             [2]Table,
	rehash_idx:    i64,
	slab:          Slab,
	expires:       int,
	heap_objs:     int,
	heap_bytes:    int,
	expire_cursor: int,
	rehash_credit: int,
	next:          Table,
	next_warm:     int,
	id:            int,
	avg_ttl:       i64,
	hreg:          ^ht.Registry,
	mc:            ^Mc_Table,
	sctx:          ^st.Context,
	zctx:          ^zt.Context,
}

Release :: struct {
	base: [^]u8,
	size: int,
	kind: Storage_Kind,
}

Dead :: struct {
	t:   Table,
	pos: int,
}

#assert(size_of(Entry) == 64)
#assert(size_of(Db) == 3 * size_of(Table) + 8 + size_of(Slab) + 12 * 8)
#assert(size_of(Db) == 928)
#assert(offset_of(Db, zctx) == 3 * size_of(Table) + 8 + size_of(Slab) + 11 * 8)
#assert(offset_of(Db, sctx) == 3 * size_of(Table) + 8 + size_of(Slab) + 10 * 8)
#assert(size_of(Release) == 24)
#assert(offset_of(Db, slab) == 2 * size_of(Table) + size_of(i64))
#assert(size_of(Dead) == size_of(Table) + 8)

DB_COUNT :: 16
DB_MAX :: 1024
ENTRY_OVERHEAD :: 96
EMBEDDED_STRING_MAX :: 44
MAX_STRING_LEN :: 512 * 1024 * 1024
ENTRY_RING :: 8
BIG_STR_BYTES :: size_of(Big_Str)
STRING_DOUBLING_LIMIT :: 1 << 20
REHASH_OP_BATCH :: 16
REHASH_OP_CREDIT :: 2
REHASH_OP_URGENT :: 8
REHASH_OP_GROUPS :: 16
REHASH_TICK_SLOTS :: 256
REHASH_TICK_GROUPS :: 64
REHASH_TICK_NS :: 1_000_000
REHASH_BUSY_TICK_NS :: 200_000
REHASH_SYNC_CAP :: 1024
REHASH_PRESSURE_DBS :: 16
REHASH_PRESSURE_MOVES :: 64
EXPIRE_SLOTS_PER_TICK :: 262144
EXPIRE_CHUNK :: 256
EXPIRE_TICK_NS :: 1_000_000
RELEASE_CHUNK :: 2 << 20
WARM_PAGE :: 4096
WARM_CHUNK :: 64 << 10
WARM_TICK_NS :: 1_000_000
WARM_BUSY_TICK_NS :: 150_000
RELEASE_TICK_NS :: 1_000_000
RELEASE_BUSY_TICK_NS :: 250_000
RELEASE_NOW_BYTES :: 1 << 20
GRAVEYARD_MAX :: 64
DEAD_MAX :: 16
DEAD_SCAN_SLOTS :: 65536

dbs: []Db
db_count: int = DB_COUNT
db_cur: ^Db
expire_db_next: int
rehash_db_next: int
pressure_db_next: int
db_used_memory: int
store_rehashing: int
store_warming: int
store_tick_commands: i64
access_seconds_now: u32
entry_ring: [ENTRY_RING]Entry
entry_next: uint
graveyard: [GRAVEYARD_MAX]Release
graveyard_len: int
dead: [DEAD_MAX]Dead
dead_len: int

@(private = "file")
empty_ctrl: Group
@(private = "file")
empty_meta: [GROUP_SLOTS]Slot_Meta
@(private = "file")
empty_keys: [GROUP_SLOTS]Key_Handle
@(private = "file")
empty_vals: [GROUP_SLOTS]Val_Handle

@(private = "file")
table_empty :: proc "contextless" () -> (t: Table) {
	t.ctrl = ([^]u8)(&empty_ctrl)
	t.slots = soa_zip(meta = empty_meta[:], key = empty_keys[:], val = empty_vals[:])
	t.groups = 1
	t.cap = GROUP_SLOTS
	return
}

db_init :: proc() {
	hash_init(rng_next())
	hash_store_init()
	zset_seed()
	p := ([^]Db)(runtime.heap_alloc(db_count * size_of(Db), true))
	regs := ([^]ht.Registry)(runtime.heap_alloc(db_count * size_of(ht.Registry), true))
	sets := ([^]st.Context)(runtime.heap_alloc(db_count * size_of(st.Context), true))
	zsets := ([^]zt.Context)(runtime.heap_alloc(db_count * size_of(zt.Context), true))
	if p == nil || regs == nil || sets == nil || zsets == nil {
		store_fatal("cannot allocate the databases")
	}
	dbs = p[:db_count]
	for &d, i in dbs {
		d.id = i
		d.t[0] = table_empty()
		d.hreg = &regs[i]
		d.hreg.owner = &d
		d.sctx = &sets[i]
		d.sctx.owner = &d
		d.zctx = &zsets[i]
		d.zctx.owner = &d
		d.rehash_idx = -1
	}
	db_cur = &dbs[0]
}

cur_db :: #force_inline proc "contextless" () -> ^Db {
	return db_cur
}

mem_alloc :: #force_inline proc "contextless" (n: int) -> [^]u8 {
	if n <= 0 {
		return nil
	}
	return ([^]u8)(runtime.heap_alloc(n, false))
}

mem_free :: #force_inline proc "contextless" (p: rawptr) {
	if p != nil {
		runtime.heap_free(p)
	}
}

clone_key :: proc "contextless" (key: []u8) -> string {
	n := len(key)
	p := mem_alloc(n)
	if n > 0 {
		intrinsics.mem_copy_non_overlapping(p, raw_data(key), n)
	}
	return transmute(string)p[:n]
}

@(cold)
store_fatal :: #force_no_inline proc "contextless" (msg: string) -> ! {
	linux.write(2, transmute([]u8)string("eski: "))
	linux.write(2, transmute([]u8)msg)
	linux.write(2, transmute([]u8)string("\n"))
	linux.exit_group(1)
}

now_ns :: #force_inline proc "contextless" () -> i64 {
	ts, _ := sysclock.monotonic()
	return i64(ts.time_sec) * 1_000_000_000 + i64(ts.time_nsec)
}

db_size_of :: #force_inline proc "contextless" (db: ^Db) -> int {
	return db.t[0].live + db.t[1].live
}

db_size :: proc "contextless" () -> int {
	return db_size_of(cur_db())
}

db_expire_count :: proc "contextless" () -> int {
	return cur_db().expires
}

@(private = "file")
big_new :: proc "contextless" (db: ^Db, data: [^]u8, n: int, cap: int) -> ^Big_Str {
	bs := (^Big_Str)(mem_alloc(BIG_STR_BYTES))
	if bs == nil {
		store_fatal("out of memory")
	}
	bs.data = data
	bs.len = u32(n)
	bs.cap = u32(cap)
	db.heap_objs += 1
	db.heap_bytes += cap + BIG_STR_BYTES
	db_used_memory += cap + BIG_STR_BYTES
	return bs
}

@(private = "file")
big_attach :: #force_inline proc "contextless" (kp: ^Key_Handle, vp: ^Val_Handle, bs: ^Big_Str, tally: u8) {
	vp.bits = u64(tally) << TALLY_SHIFT
	vp.ref.addr = uintptr(bs)
	kp.small.tag.val_form = FORM_HEAP
}

@(private = "file")
val_release :: proc "contextless" (db: ^Db, kp: ^Key_Handle, vp: ^Val_Handle) {
	switch kp.small.tag.val_form {
	case FORM_SLAB:
		slab_free(&db.slab, vp.slab.offset, int(vp.slab.len))
	case FORM_HEAP:
		bs := (^Big_Str)(vp.ref.addr)
		n := int(bs.cap) + BIG_STR_BYTES
		db.heap_objs -= 1
		db.heap_bytes -= n
		db_used_memory -= n
		mem_free(bs.data)
		mem_free(bs)
	case FORM_OBJECT:
		n: int
		queued := false
		if lazy_mode == .Async || (lazy_mode == .Server && cfg.lazyfree_lazy_server_del) {
			n, queued = lazyfree_object(vp.slab.info.type, rawptr(vp.ref.addr))
		}
		if !queued {
			#partial switch vp.slab.info.type {
			case .Set:
				n = set_object_release(rawptr(vp.ref.addr))
			case .List:
				n = list_object_release(rawptr(vp.ref.addr))
			case .Zset:
				n = zset_object_release(rawptr(vp.ref.addr))
			case .Stream:
				n = stream_object_release(rawptr(vp.ref.addr))
			case:
				n = object_release(vp.slab.info.type, rawptr(vp.ref.addr))
			}
		}
		if vp.slab.info.type == .Stream {
			block_note_removed()
		}
		db.heap_objs -= 1
		db.heap_bytes -= n
		db_used_memory -= n
	}
	kp.small.tag.val_form = FORM_NONE
	vp.bits &= u64(0xFF) << TALLY_SHIFT
}

@(private = "file")
key_store :: proc "contextless" (db: ^Db, kp: ^Key_Handle, key: []u8) #no_bounds_check {
	n := len(key)
	if n <= INLINE_BYTES {
		kp.bits = pack_small(key) | (u64(n + FORM_INLINE) << 56)
		return
	}
	if n <= SLAB_MAX {
		off := slab_alloc(&db.slab, n)
		intrinsics.mem_copy_non_overlapping(slab_ptr(&db.slab, off), raw_data(key), n)
		kp.bits = 0
		kp.slab.offset = off
		kp.slab.len = u16(n)
		kp.small.tag.key_form = FORM_SLAB
		return
	}
	key_store_heap(db, kp, key)
}

@(cold)
key_store_heap :: #force_no_inline proc "contextless" (db: ^Db, kp: ^Key_Handle, key: []u8) {
	n := len(key)
	hp := mem_alloc(n + 8)
	if hp == nil {
		store_fatal("out of memory")
	}
	(^int)(hp)^ = n
	intrinsics.mem_copy_non_overlapping(&hp[8], raw_data(key), n)
	kp.bits = 0
	kp.heap.addr = uintptr(hp)
	kp.small.tag.key_form = FORM_HEAP
	db.heap_objs += 1
	db.heap_bytes += n + 8
	db_used_memory += n + 8
}

@(private = "file")
key_store_timed :: proc "contextless" (db: ^Db, kp: ^Key_Handle, key: []u8, at: u64) #no_bounds_check {
	n := len(key)
	if n + DEADLINE_BYTES <= SLAB_MAX {
		off := slab_alloc(&db.slab, n + DEADLINE_BYTES)
		p := slab_ptr(&db.slab, off)
		(^u64)(p)^ = at
		if n > 0 {
			intrinsics.mem_copy_non_overlapping(&p[DEADLINE_BYTES], raw_data(key), n)
		}
		kp.bits = 0
		kp.slab.offset = off + 1
		kp.slab.len = u16(n)
		kp.slab.timed = KEY_TIMED
		kp.small.tag.key_form = FORM_SLAB
		return
	}
	hp := mem_alloc(n + DEADLINE_BYTES + 8)
	if hp == nil {
		store_fatal("out of memory")
	}
	(^u64)(hp)^ = at
	(^int)(&hp[DEADLINE_BYTES])^ = n
	intrinsics.mem_copy_non_overlapping(&hp[DEADLINE_BYTES + 8], raw_data(key), n)
	kp.bits = 0
	kp.heap.addr = uintptr(&hp[DEADLINE_BYTES])
	kp.heap.timed = KEY_TIMED
	kp.small.tag.key_form = FORM_HEAP
	db.heap_objs += 1
	db.heap_bytes += n + DEADLINE_BYTES + 8
	db_used_memory += n + DEADLINE_BYTES + 8
}

@(private = "file")
key_release :: proc "contextless" (db: ^Db, kp: ^Key_Handle) {
	switch kp.small.tag.key_form {
	case FORM_SLAB:
		if kp.slab.timed != 0 {
			slab_free(&db.slab, kp.slab.offset - 1, int(kp.slab.len) + DEADLINE_BYTES)
		} else {
			slab_free(&db.slab, kp.slab.offset, int(kp.slab.len))
		}
	case FORM_HEAP:
		extra := DEADLINE_BYTES if kp.heap.timed != 0 else 0
		hp := ([^]u8)(kp.heap.addr)
		n := (^int)(hp)^ + 8 + extra
		db.heap_objs -= 1
		db.heap_bytes -= n
		db_used_memory -= n
		mem_free(rawptr(kp.heap.addr - uintptr(extra)))
	}
}

@(private = "file")
key_restore :: proc "contextless" (db: ^Db, kp: ^Key_Handle, at: u64) {
	old := kp^
	key := key_bytes(&old, &db.slab)
	if at != 0 {
		key_store_timed(db, kp, key, at)
	} else {
		key_store(db, kp, key)
	}
	kp.small.tag.val_form = old.small.tag.val_form
	key_release(db, &old)
	if db.mc != nil {
		mc_meta_rekey(db, old.bits, kp.bits)
	}
}

key_set_deadline :: proc "contextless" (db: ^Db, kp: ^Key_Handle, at: i64) {
	if key_timed(kp^) {
		if at != 0 {
			key_deadline_ptr(kp^, &db.slab)^ = u64(at)
			return
		}
		db.expires -= 1
	} else {
		if at == 0 {
			return
		}
		db.expires += 1
	}
	key_restore(db, kp, u64(at))
}

slot_deadline :: #force_inline proc "contextless" (db: ^Db, t: ^Table, i: int) -> i64 #no_bounds_check {
	return key_deadline(t.slots[i].key, &db.slab)
}

@(private = "file")
entry_load :: #force_inline proc "contextless" (e: ^Entry) #no_bounds_check {
	vp := e.vp
	form := e.kp.small.tag.val_form
	switch {
	case form == FORM_NONE || form == FORM_OBJECT:
		e.val = nil
		e.cap = 0
		e.raw_enc = false
	case form <= FORM_INLINE + INLINE_BYTES:
		n := int(form) - FORM_INLINE
		e.val = ([^]u8)(vp)[:n]
		e.cap = u32(n)
		e.raw_enc = false
	case form == FORM_SLAB:
		n := int(vp.slab.len)
		e.val = slab_ptr(&e.db.slab, vp.slab.offset)[:n]
		e.cap = u32(slab_size_of(n))
		e.raw_enc = vp.slab.info.enc == .Raw
	case:
		bs := (^Big_Str)(vp.ref.addr)
		e.val = bs.data[:bs.len]
		e.cap = bs.cap
		e.raw_enc = vp.slab.info.enc == .Raw
	}
}

@(private = "file")
entry_view :: #force_inline proc "contextless" (db: ^Db, t: ^Table, i: int) -> ^Entry #no_bounds_check {
	e := &entry_ring[entry_next & (ENTRY_RING - 1)]
	entry_next += 1
	e.db = db
	e.mp = &t.slots[i].meta
	e.kp = &t.slots[i].key
	e.vp = &t.slots[i].val
	e.expire_at = key_deadline(e.kp^, &db.slab) if db.expires > 0 else 0
	e.heap_tmp = false
	entry_load(e)
	return e
}

@(private = "file")
entry_store :: proc "contextless" (e: ^Entry, v: []u8, enc: Obj_Encoding, inline_ok: bool) #no_bounds_check {
	db := e.db
	kp := e.kp
	vp := e.vp
	n := len(v)
	form := kp.small.tag.val_form
	tally := vp.small.tally
	mc_meta_on_write(db, kp)
	if n <= INLINE_BYTES && inline_ok && enc != .Raw {
		if form >= FORM_SLAB {
			val_release(db, kp, vp)
		}
		vp.bits = pack_small(v) | (u64(tally) << TALLY_SHIFT)
		kp.small.tag.val_form = u8(n + FORM_INLINE)
		e.val = ([^]u8)(vp)[:n]
		e.cap = u32(n)
		e.raw_enc = false
		return
	}
	if n <= SLAB_MAX {
		c := slab_class(n)
		if form != FORM_SLAB || slab_class(int(vp.slab.len)) != c {
			if form >= FORM_SLAB {
				val_release(db, kp, vp)
			}
			off := slab_alloc(&db.slab, n)
			vp.bits = u64(tally) << TALLY_SHIFT
			vp.slab.offset = off
			kp.small.tag.val_form = FORM_SLAB
		}
		vp.slab.len = u16(n)
		vp.slab.info = Val_Info {
			type = .String,
			enc  = enc,
		}
		p := slab_ptr(&db.slab, vp.slab.offset)
		if n > 0 {
			intrinsics.mem_copy_non_overlapping(p, raw_data(v), n)
		}
		e.val = p[:n]
		e.cap = slab_class_size[c]
		e.raw_enc = enc == .Raw
		return
	}
	bs: ^Big_Str
	if form == FORM_HEAP {
		bs = (^Big_Str)(vp.ref.addr)
		if n > int(bs.cap) || int(bs.cap) > 2 * n + 64 {
			mem_free(bs.data)
			db.heap_bytes += n - int(bs.cap)
			db_used_memory += n - int(bs.cap)
			bs.data = mem_alloc(n)
			bs.cap = u32(n)
		}
	} else {
		if form >= FORM_SLAB {
			val_release(db, kp, vp)
		}
		bs = big_new(db, mem_alloc(n), n, n)
		big_attach(kp, vp, bs, tally)
	}
	if bs.data == nil {
		store_fatal("out of memory")
	}
	vp.slab.info = Val_Info {
		type = .String,
		enc  = enc,
	}
	intrinsics.mem_copy_non_overlapping(bs.data, raw_data(v), n)
	bs.len = u32(n)
	e.val = bs.data[:n]
	e.cap = bs.cap
	e.raw_enc = enc == .Raw
}

entry_assign :: proc "contextless" (e: ^Entry, v: []u8) {
	enc := string_encoding_of(v)
	if enc == .Int && evict_no_shared_ints {
		entry_assign_int(e, v)
		return
	}
	entry_store(e, v, enc, true)
}

@(private = "file")
entry_assign_int :: #force_no_inline proc "contextless" (e: ^Entry, v: []u8) {
	entry_store(e, v, .Int, shared_int_ok(v))
}

entry_set_encoding :: proc "contextless" (e: ^Entry, enc: Obj_Encoding) #no_bounds_check {
	form := e.kp.small.tag.val_form
	if form == FORM_SLAB || form == FORM_HEAP {
		e.vp.slab.info.enc = enc
		e.raw_enc = enc == .Raw
		return
	}
	if form == FORM_OBJECT {
		e.vp.slab.info.enc = enc
		return
	}
	if enc != .Raw && small_encoding(e.val) == enc {
		return
	}
	tmp: [INLINE_BYTES]u8
	n := len(e.val)
	if n > 0 {
		intrinsics.mem_copy_non_overlapping(&tmp[0], raw_data(e.val), n)
	}
	entry_store(e, tmp[:n], enc, false)
}

entry_append :: proc "contextless" (e: ^Entry, v: []u8) #no_bounds_check {
	db := e.db
	kp := e.kp
	vp := e.vp
	cur := len(e.val)
	add := len(v)
	newlen := cur + add
	form := kp.small.tag.val_form
	tally := vp.small.tally
	mc_meta_on_write(db, kp)
	if newlen <= SLAB_MAX {
		p: [^]u8
		if form == FORM_SLAB && newlen <= slab_size_of(cur) {
			p = slab_ptr(&db.slab, vp.slab.offset)
		} else {
			off := slab_alloc(&db.slab, newlen)
			p = slab_ptr(&db.slab, off)
			if cur > 0 {
				intrinsics.mem_copy_non_overlapping(p, raw_data(e.val), cur)
			}
			if form >= FORM_SLAB {
				val_release(db, kp, vp)
			}
			vp.bits = u64(tally) << TALLY_SHIFT
			vp.slab.offset = off
			kp.small.tag.val_form = FORM_SLAB
		}
		if add > 0 {
			intrinsics.mem_copy_non_overlapping(&p[cur], raw_data(v), add)
		}
		vp.slab.len = u16(newlen)
		vp.slab.info = Val_Info {
			type = .String,
			enc  = .Raw,
		}
		e.val = p[:newlen]
		e.cap = u32(slab_size_of(newlen))
		e.raw_enc = true
		return
	}
	bs: ^Big_Str
	if form == FORM_HEAP {
		bs = (^Big_Str)(vp.ref.addr)
		if newlen > int(bs.cap) {
			newcap := max(newlen, int(bs.cap) * 2)
			p := ([^]u8)(runtime.heap_resize(bs.data, newcap))
			if p == nil {
				store_fatal("out of memory")
			}
			db.heap_bytes += newcap - int(bs.cap)
			db_used_memory += newcap - int(bs.cap)
			bs.data = p
			bs.cap = u32(newcap)
		}
	} else {
		newcap := max(newlen, int(e.cap) * 2)
		data := mem_alloc(newcap)
		if data == nil {
			store_fatal("out of memory")
		}
		if cur > 0 {
			intrinsics.mem_copy_non_overlapping(data, raw_data(e.val), cur)
		}
		if form >= FORM_SLAB {
			val_release(db, kp, vp)
		}
		bs = big_new(db, data, cur, newcap)
		big_attach(kp, vp, bs, tally)
	}
	intrinsics.mem_copy_non_overlapping(&bs.data[cur], raw_data(v), add)
	bs.len = u32(newlen)
	vp.slab.info = Val_Info {
		type = .String,
		enc  = .Raw,
	}
	e.val = bs.data[:newlen]
	e.cap = bs.cap
	e.raw_enc = true
}

entry_heap_open :: proc "contextless" (e: ^Entry, exact: bool) {
	form := e.kp.small.tag.val_form
	e.heap_tmp = false
	if form == FORM_HEAP {
		bs := (^Big_Str)(e.vp.ref.addr)
		if exact && bs.len > 0 && bs.cap != bs.len {
			p := ([^]u8)(runtime.heap_resize(bs.data, int(bs.len)))
			if p != nil {
				d := int(bs.len) - int(bs.cap)
				e.db.heap_bytes += d
				db_used_memory += d
				bs.data = p
				bs.cap = bs.len
			}
		}
		e.val = bs.data[:bs.len]
		e.cap = bs.cap
		return
	}
	if form == FORM_NONE || form == FORM_OBJECT {
		e.val = nil
		e.cap = 0
		return
	}
	n := len(e.val)
	p := mem_alloc(n)
	if n > 0 {
		if p == nil {
			store_fatal("out of memory")
		}
		intrinsics.mem_copy_non_overlapping(p, raw_data(e.val), n)
	}
	e.val = p[:n]
	e.cap = u32(n)
	e.heap_tmp = true
}

entry_heap_close :: proc "contextless" (e: ^Entry) {
	db := e.db
	kp := e.kp
	vp := e.vp
	n := len(e.val)
	buf := raw_data(e.val)
	cap := max(int(e.cap), n)
	form := kp.small.tag.val_form
	tally := vp.small.tally
	e.heap_tmp = false
	mc_meta_on_write(db, kp)
	if form == FORM_HEAP {
		bs := (^Big_Str)(vp.ref.addr)
		if n > SLAB_MAX {
			d := cap - int(bs.cap)
			db.heap_bytes += d
			db_used_memory += d
			bs.data = buf
			bs.len = u32(n)
			bs.cap = u32(cap)
			vp.slab.info.enc = .Raw
			e.cap = u32(cap)
			e.raw_enc = true
			return
		}
		d := int(bs.cap) + BIG_STR_BYTES
		db.heap_objs -= 1
		db.heap_bytes -= d
		db_used_memory -= d
		mem_free(bs)
		kp.small.tag.val_form = FORM_NONE
		vp.bits = u64(tally) << TALLY_SHIFT
	} else if n > SLAB_MAX {
		if form != FORM_NONE {
			val_release(db, kp, vp)
		}
		bs := big_new(db, buf, n, cap)
		big_attach(kp, vp, bs, tally)
		vp.slab.info = Val_Info {
			type = .String,
			enc  = .Raw,
		}
		e.cap = u32(cap)
		e.raw_enc = true
		return
	}
	entry_store(e, buf[:n], .Raw, false)
	mem_free(buf)
}

string_grown_capacity :: #force_inline proc "contextless" (had: u32, need: int) -> int {
	switch {
	case had == 0:
		return need
	case need >= STRING_DOUBLING_LIMIT:
		return need + STRING_DOUBLING_LIMIT
	}
	return need * 2
}

entry_setrange :: proc "contextless" (e: ^Entry, off: int, v: []u8) {
	entry_heap_open(e, false)
	held := len(e.val)
	reach := off + len(v)
	final := reach if reach > held else held
	base := raw_data(e.val)
	if final > int(e.cap) {
		room := string_grown_capacity(e.cap, final)
		base = ([^]u8)(runtime.heap_resize(base, room))
		if base == nil {
			store_fatal("out of memory")
		}
		e.cap = u32(room)
	}
	if off > held {
		intrinsics.mem_zero(&base[held], off - held)
	}
	if len(v) > 0 {
		intrinsics.mem_copy_non_overlapping(&base[off], raw_data(v), len(v))
	}
	e.val = base[:final]
	entry_heap_close(e)
}

entry_heap_adopt :: proc "contextless" (e: ^Entry, buf: []u8, cap: int) {
	val_release(e.db, e.kp, e.vp)
	e.val = buf
	e.cap = u32(cap)
	entry_heap_close(e)
}

entry_object_attach :: proc "contextless" (e: ^Entry, obj: rawptr, type: Obj_Type, enc: Obj_Encoding, bytes: int) {
	db := e.db
	kp := e.kp
	vp := e.vp
	tally := vp.small.tally
	mc_meta_on_write(db, kp)
	if kp.small.tag.val_form >= FORM_SLAB {
		val_release(db, kp, vp)
	}
	vp.bits = u64(tally) << TALLY_SHIFT
	vp.ref.addr = uintptr(obj)
	vp.slab.info = Val_Info {
		type = type,
		enc  = enc,
	}
	kp.small.tag.val_form = FORM_OBJECT
	db.heap_objs += 1
	db.heap_bytes += bytes
	db_used_memory += bytes
	e.val = nil
	e.cap = 0
	e.raw_enc = false
}

entry_object :: #force_inline proc "contextless" (e: ^Entry, type: Obj_Type) -> rawptr {
	if e.kp.small.tag.val_form != FORM_OBJECT || e.vp.slab.info.type != type {
		return nil
	}
	return rawptr(e.vp.ref.addr)
}

object_account :: #force_inline proc "contextless" (db: ^Db, delta: int) {
	db.heap_bytes += delta
	db_used_memory += delta
}

entry_set_expire :: #force_inline proc "contextless" (e: ^Entry, t: i64) {
	at := clamp(t, 0, MAX_EXPIRE_MS)
	if at == 0 && e.db.expires == 0 {
		e.expire_at = 0
		return
	}
	key_set_deadline(e.db, e.kp, at)
	e.expire_at = at
}

entry_expired :: #force_inline proc "contextless" (e: ^Entry) -> bool {
	return e.expire_at != 0 && e.expire_at <= expire_now()
}

entry_type :: proc "contextless" (e: ^Entry) -> Obj_Type {
	if e.kp.small.tag.val_form == FORM_OBJECT {
		return e.vp.slab.info.type
	}
	return .String
}

entry_encoding :: proc "contextless" (e: ^Entry) -> string {
	if e.kp.small.tag.val_form <= FORM_INLINE + INLINE_BYTES {
		return encoding_name(small_encoding(e.val))
	}
	return encoding_name(e.vp.slab.info.enc)
}

@(private = "file")
db_locate :: #force_inline proc "contextless" (db: ^Db, l: ^Lookup) -> (^Table, int) {
	want_meta := !store_no_touch
	if db.rehash_idx >= 0 {
		i := table_find_slow(&db.t[0], &db.slab, l, want_meta)
		if i >= 0 {
			return &db.t[0], i
		}
		return &db.t[1], table_find_slow(&db.t[1], &db.slab, l, want_meta)
	}
	return &db.t[0], table_find(&db.t[0], &db.slab, l, want_meta)
}

@(private = "file")
db_erase :: proc "contextless" (db: ^Db, t: ^Table, i: int) #no_bounds_check {
	kp := &t.slots[i].key
	mc_meta_on_erase(db, kp)
	val_release(db, kp, &t.slots[i].val)
	if key_timed(kp^) {
		db.expires -= 1
	}
	key_release(db, kp)
	table_erase(t, i, false)
}

db_erase_expired :: proc "contextless" (db: ^Db, t: ^Table, i: int) {
	saved := lazy_set(cfg.lazyfree_lazy_expire)
	start: i64 = 0
	if cfg.latency_monitor_threshold != 0 {
		start = now_ns()
	}
	db_erase(db, t, i)
	if start != 0 {
		latency_note_expire_del(start)
	}
	lazy_mode = saved
	srv.stat_expired += 1
}

@(private = "file")
db_rehash_swap :: proc "contextless" (db: ^Db) {
	table_detach(&db.t[0])
	db.t[0] = db.t[1]
	db.t[1] = {}
	db.rehash_idx = -1
	store_rehashing -= 1
}

@(private = "file")
db_rehash_groups :: proc "contextless" (db: ^Db, max_groups: int, want: int) {
	src := &db.t[0]
	dst := &db.t[1]
	groups := i64(src.groups)
	g := db.rehash_idx
	moved := 0
	visited := 0
	for g < groups && moved < want && visited < max_groups {
		m, done := table_migrate_group(src, dst, &db.slab, u64(g), want - moved)
		moved += m
		if !done {
			break
		}
		g += 1
		visited += 1
	}
	db.rehash_idx = g
	if g >= groups || src.live == 0 {
		db_rehash_swap(db)
	}
}

@(private = "file")
db_rehash_step :: #force_inline proc "contextless" (db: ^Db) {
	if db.rehash_idx >= 0 {
		db.rehash_credit += REHASH_OP_CREDIT if db.t[1].growth >= 2 * db.t[0].live else REHASH_OP_URGENT
		if db.rehash_credit >= REHASH_OP_BATCH {
			db.rehash_credit -= REHASH_OP_BATCH
			db_rehash_groups(db, REHASH_OP_GROUPS, REHASH_OP_BATCH)
		}
	}
}

@(private = "file")
db_rehash_finish :: proc "contextless" (db: ^Db) {
	for db.rehash_idx >= 0 {
		db_rehash_groups(db, max(int), max(int))
	}
}

@(private = "file")
db_rehash_start :: proc "contextless" (db: ^Db, cap: int) {
	db.t[1] = table_alloc(cap)
	db_rehash_begin(db)
}

@(private = "file")
db_rehash_begin :: proc "contextless" (db: ^Db) {
	db.rehash_idx = 0
	db.rehash_credit = 0
	store_rehashing += 1
	if db.t[0].cap <= REHASH_SYNC_CAP {
		db_rehash_finish(db)
	}
}

@(private = "file")
db_drop_next :: proc "contextless" (db: ^Db) {
	if db.next.region != nil {
		if db.next_warm < db.next.size {
			store_warming -= 1
		}
		table_detach(&db.next)
	}
	db.next_warm = 0
}

db_drop_prepared :: proc "contextless" () {
	for &d in dbs {
		db_drop_next(&d)
	}
}

@(cold)
db_prepare_next :: #force_no_inline proc "contextless" (db: ^Db) {
	t := &db.t[0]
	if db.rehash_idx >= 0 || db.next.region != nil || t.cap <= REHASH_SYNC_CAP || t.live <= t.cap * 7 / 16 || maxmemory_bytes != 0 {
		return
	}
	db.next = table_alloc(table_grow_cap(t.cap))
	db.next_warm = 0
	store_warming += 1
}

@(private = "file")
db_warm :: proc "contextless" (db: ^Db, deadline: i64) {
	for db.next_warm < db.next.size {
		end := min(db.next_warm + WARM_CHUNK, db.next.size)
		for off := db.next_warm; off < end; off += WARM_PAGE {
			intrinsics.volatile_store(&db.next.region[off], 0)
		}
		db.next_warm = end
		if end >= db.next.size {
			store_warming -= 1
			break
		}
		if now_ns() >= deadline {
			break
		}
	}
}

@(cold)
db_make_room :: #force_no_inline proc "contextless" (db: ^Db) -> ^Table {
	if db.t[0].region == nil && db.rehash_idx < 0 {
		db.t[0] = table_alloc(TABLE_MIN_CAP)
		return &db.t[0]
	}
	db_rehash_finish(db)
	t := &db.t[0]
	cap := t.cap
	if t.live > cap * 7 / 16 {
		cap = table_grow_cap(cap)
		if maxmemory_bytes != 0 && u64(mem_used() + table_alloc_size(cap)) > maxmemory_bytes {
			cap = table_tight_cap(t.cap)
		}
	}
	if db.next.region != nil && db.next.cap == cap {
		if db.next_warm < db.next.size {
			store_warming -= 1
		}
		db.t[1] = db.next
		db.next = {}
		db.next_warm = 0
		db_rehash_begin(db)
	} else {
		db_drop_next(db)
		db_rehash_start(db, cap)
	}
	if db.rehash_idx >= 0 {
		return &db.t[1]
	}
	return &db.t[0]
}

@(cold)
db_shrink :: #force_no_inline proc "contextless" (db: ^Db) {
	db_drop_next(db)
	cap := table_round_cap(db.t[0].live * 2)
	if cap < db.t[0].cap {
		db_rehash_start(db, cap)
	}
}

@(private = "file")
db_maybe_shrink :: #force_inline proc "contextless" (db: ^Db) {
	if !dict_resizing || db.rehash_idx >= 0 {
		return
	}
	primary := &db.t[0]
	if primary.cap > TABLE_MIN_CAP && primary.live < primary.cap / 8 {
		db_shrink(db)
	}
}

db_resize_all :: proc "contextless" () {
	for &d in dbs {
		db_maybe_shrink(&d)
	}
}

Table_Pressure_Work :: struct {
	visited:        int,
	admitted_bytes: int,
}

db_pressure_shrink :: proc "contextless" (deadline: i64) -> (work: Table_Pressure_Work) {
	over, _ := memory_state_over()
	if !over || len(dbs) == 0 {
		return
	}
	if pressure_db_next >= len(dbs) {
		pressure_db_next = 0
	}
	for work.visited < min(len(dbs), REHASH_PRESSURE_DBS) {
		if now_ns() >= deadline {
			break
		}
		d := &dbs[pressure_db_next]
		pressure_db_next = (pressure_db_next + 1) % len(dbs)
		work.visited += 1
		t := &d.t[0]
		if d.rehash_idx >= 0 {
			if d.t[1].cap < t.cap && t.size <= 2 * RELEASE_NOW_BYTES && d.t[1].size <= RELEASE_NOW_BYTES && now_ns() < deadline {
				db_rehash_groups(d, REHASH_OP_GROUPS, REHASH_PRESSURE_MOVES)
				return
			}
			continue
		}
		if !dict_resizing || d.next.region != nil || t.region == nil || t.cap <= TABLE_MIN_CAP || t.live > t.cap / 4 || t.size > 2 * RELEASE_NOW_BYTES {
			continue
		}
		cap := table_round_cap(t.cap / 2)
		size := table_alloc_size(cap)
		if size > RELEASE_NOW_BYTES || size >= t.size || now_ns() >= deadline {
			continue
		}
		work.admitted_bytes = size
		db_rehash_start(d, cap)
		if d.rehash_idx >= 0 && now_ns() < deadline {
			db_rehash_groups(d, REHASH_OP_GROUPS, REHASH_PRESSURE_MOVES)
		}
		return
	}
	return
}

db_find :: #force_inline proc(key: []u8) -> ^Entry {
	return db_find_in(db_cur, key)
}

db_find_in :: proc(db: ^Db, key: []u8) -> ^Entry #no_bounds_check {
	l := lookup_make(key)
	t, i := db_locate(db, &l)
	if i < 0 {
		return nil
	}
	if db.expires > 0 {
		exp := slot_deadline(db, t, i)
		if exp != 0 && exp <= expire_now() {
			if !expiry_deletion_paused() {
				db_erase_expired(db, t, i)
				key_expired_event(key, db)
			}
			return nil
		}
	}
	return entry_touched(entry_view(db, t, i))
}

db_key_state :: proc(db: ^Db, key: []u8) -> (exists: bool, expired: bool) #no_bounds_check {
	l := lookup_make(key)
	t, i := db_locate(db, &l)
	if i < 0 {
		return false, false
	}
	exp := slot_deadline(db, t, i)
	return true, exp != 0 && exp <= srv.now_ms
}

keyspace_store_seed :: proc(db: ^Db, key: []u8) -> (value: []u8, access_word: u32, exists, eligible: bool) {
	l := lookup_make(key)
	t, i := db_locate(db, &l)
	if i < 0 {
		return nil, 0, false, true
	}
	if key_timed(t.slots[i].key) {
		return nil, 0, false, false
	}
	e := entry_view(db, t, i)
	if entry_type(e) != .String || mc_meta_get(db, e.kp) != nil {
		return nil, 0, false, false
	}
	return e.val, entry_access_word(e), true, true
}

mc_worker_key_admissible :: proc(db: ^Db, key: []u8) -> bool {
	if db.mc == nil { return true }
	l := lookup_make(key)
	t, i := db_locate(db, &l)
	return i < 0 || mc_meta_get(db, entry_view(db, t, i).kp) == nil
}

keyspace_store_pause_admissible :: proc(db: ^Db, key: []u8) -> bool {
	l := lookup_make(key)
	t, i := db_locate(db, &l)
	if i < 0 { return true }
	e := entry_view(db, t, i)
	return entry_type(e) != .Hash && (e.expire_at == 0 || e.expire_at > expire_now())
}

keyspace_store_seed_full :: proc(db: ^Db, key: []u8) -> (value: []u8, access_word: u32, expires: i64, encoding: u8, exists, eligible: bool) {
	l := lookup_make(key)
	t, i := db_locate(db, &l)
	if i < 0 {
		return nil, 0, 0, 0, false, true
	}
	e := entry_view(db, t, i)
	if entry_type(e) != .String || mc_meta_get(db, e.kp) != nil {
		return nil, 0, 0, 0, false, false
	}
	return e.val, entry_access_word(e), e.expire_at, u8(entry_obj_encoding(e)), true, true
}

keyspace_store_import_full :: proc(db: ^Db, key, value: []u8, access_word: u32, changed, exists: bool, expires: i64, encoding: u8) {
	if changed && !exists {
		db_remove_in(db, key)
		return
	}
	if changed {
		keyspace_store_clear_lapsed(db, key)
	}
	keyspace_store_import(db, key, value, access_word, changed, expires)
	if changed {
		l := lookup_make(key)
		t, i := db_locate(db, &l)
		if i >= 0 {
			entry_set_encoding(entry_view(db, t, i), Obj_Encoding(encoding))
		}
	}
}

@(private = "file")
keyspace_store_clear_lapsed :: proc(db: ^Db, key: []u8) {
	l := lookup_make(key)
	t, i := db_locate(db, &l)
	if i >= 0 {
		due := slot_deadline(db, t, i)
		if due != 0 && due <= expire_now() {
			entry_set_expire(entry_view(db, t, i), 0)
		}
	}
}

keyspace_store_seed_object :: proc(db: ^Db, key: []u8) -> (object: rawptr, kind: Obj_Type, access_word: u32, expires: i64, eligible: bool) {
	l := lookup_make(key)
	t, i := db_locate(db, &l)
	if i < 0 {
		return nil, .String, 0, 0, false
	}
	e := entry_view(db, t, i)
	if entry_type(e) == .String || mc_meta_get(db, e.kp) != nil {
		return nil, entry_type(e), 0, 0, false
	}
	kind = entry_type(e)
	return entry_object(e, kind), kind, entry_access_word(e), e.expire_at, true
}

keyspace_store_string_copy :: proc(db: ^Db, key: []u8) -> bool {
	l := lookup_make(key)
	t, i := db_locate(db, &l)
	if i < 0 { return false }
	e := entry_view(db, t, i)
	return entry_type(e) == .String && entry_obj_encoding(e) == .Int && !entry_shared_integer(e)
}

keyspace_store_import_copy :: proc(db: ^Db, key, value: []u8, access_word: u32, expires: i64, encoding: u8) {
	e := keyspace_store_object_destination(db, key, expires)
	enc := Obj_Encoding(encoding)
	entry_copy_string(e, value, enc)
	entry_set_encoding(e, enc)
	entry_set_expire(e, expires)
	entry_set_access_word(e, access_word)
}

keyspace_store_import_metadata :: proc(db: ^Db, key: []u8, access_word: u32, expires: i64) {
	l := lookup_make(key)
	t, i := db_locate(db, &l)
	if i >= 0 {
		e := entry_view(db, t, i)
		entry_set_expire(e, expires)
		entry_set_access_word(e, access_word)
	}
}

keyspace_store_object_destination :: proc(db: ^Db, key: []u8, expires: i64) -> ^Entry {
	keyspace_store_clear_lapsed(db, key)
	saved := store_no_touch
	store_no_touch = true
	defer store_no_touch = saved
	e, _ := db_upsert_timed_in(db, key, expires)
	return e
}

keyspace_store_import_list :: proc(db: ^Db, key: []u8, object: rawptr, access_word: u32, expires: i64) {
	e := keyspace_store_object_destination(db, key, expires)
	list_copy_attach(e, object)
	entry_set_expire(e, expires)
	entry_set_access_word(e, access_word)
}

lua_store_reply_bound :: proc(db: ^Db, key: []u8) -> u128 {
	l := lookup_make(key)
	t, i := db_locate(db, &l)
	if i < 0 {
		return 0
	}
	e := entry_view(db, t, i)
	if entry_type(e) == .String {
		return u128(len(e.val)) + 64
	}
	return u128(entry_memory(e))*64 + 128
}

keyspace_store_import :: proc(db: ^Db, key, value: []u8, access_word: u32, changed: bool, expires: i64) {
	if changed {
		saved := store_no_touch
		store_no_touch = true
		e, _ := db_upsert_timed_in(db, key, expires)
		entry_assign(e, value)
		entry_set_expire(e, expires)
		entry_set_access_word(e, access_word)
		store_no_touch = saved
		return
	}
	l := lookup_make(key)
	t, i := db_locate(db, &l)
	if i >= 0 {
		entry_set_access_word(entry_view(db, t, i), access_word)
	}
}

db_find_read :: proc(key: []u8) -> ^Entry {
	e := db_find(key)
	if e == nil {
		srv.stat_misses += 1
		notify(.Key_Miss, "keymiss", key)
	} else {
		srv.stat_hits += 1
	}
	return e
}

db_remove :: #force_inline proc(key: []u8) -> (found: bool, expired: bool) {
	return db_remove_in(db_cur, key)
}

db_remove_in :: proc(db: ^Db, key: []u8) -> (found: bool, expired: bool) #no_bounds_check {
	l := lookup_make(key)
	db_rehash_step(db)
	t, i := db_locate(db, &l)
	if i < 0 {
		return false, false
	}
	if db.expires > 0 {
		exp := slot_deadline(db, t, i)
		expired = exp != 0 && exp <= expire_now()
	}
	if expired {
		saved := lazy_set(cfg.lazyfree_lazy_expire)
		db_erase(db, t, i)
		lazy_mode = saved
	} else {
		db_erase(db, t, i)
	}
	db_maybe_shrink(db)
	return true, expired
}

db_upsert :: #force_inline proc(key: []u8) -> (^Entry, bool) {
	return db_upsert_in(db_cur, key)
}

db_upsert_timed :: #force_inline proc(key: []u8, at: i64) -> (^Entry, bool) {
	return db_upsert_timed_in(db_cur, key, at)
}

db_upsert_timed_in :: proc(db: ^Db, key: []u8, at: i64) -> (^Entry, bool) {
	saved := store_new_deadline
	store_new_deadline = clamp(at, 0, MAX_EXPIRE_MS)
	e, created := db_upsert_in(db, key)
	store_new_deadline = saved
	return e, created
}

db_upsert_in :: proc(db: ^Db, key: []u8) -> (^Entry, bool) #no_bounds_check {
	l := lookup_make(key)
	db_rehash_step(db)
	t := &db.t[0]
	want_meta := !store_no_touch
	if db.rehash_idx >= 0 {
		i := table_find_slow(t, &db.slab, &l, want_meta)
		if i >= 0 {
			if db.expires > 0 {
				exp := slot_deadline(db, t, i)
				if exp != 0 && exp <= expire_now() {
					db_erase_expired(db, t, i)
					key_expired_event(key, db)
					return db_upsert_in(db, key)
				}
			}
			return entry_touched(entry_view(db, t, i)), false
		}
		t = &db.t[1]
	}
	i, found := table_find_slot(t, &db.slab, &l, want_meta)
	if found {
		if db.expires > 0 {
			exp := slot_deadline(db, t, i)
			if exp != 0 && exp <= expire_now() {
				db_erase_expired(db, t, i)
				key_expired_event(key, db)
				return db_upsert_in(db, key)
			}
		}
		return entry_touched(entry_view(db, t, i)), false
	}
	if t.growth == 0 && t.ctrl[i] == CTRL_EMPTY {
		t = db_make_room(db)
		i = table_claim(t, l.hash)
	} else {
		table_place(t, i, l.hash)
		if t.growth <= t.warm_at && db.next.region == nil {
			db_prepare_next(db)
		}
	}
	if store_new_deadline != 0 {
		key_store_timed(db, &t.slots[i].key, key, u64(store_new_deadline))
		db.expires += 1
	} else {
		key_store(db, &t.slots[i].key, key)
	}
	fresh := access_fresh_note()
	t.slots[i].meta = Slot_Meta {
		stamp = fresh.stamp,
	}
	t.slots[i].val = transmute(Val_Handle)(u64(fresh.tally) << TALLY_SHIFT)
	e := entry_view(db, t, i)
	if !store_reconciling { notify_in(.New, "new", key, db) }
	return e, true
}

db_set :: proc(key: []u8, val: []u8, expire_at: i64) {
	e, _ := db_upsert_timed(key, expire_at)
	entry_assign(e, val)
	entry_set_expire(e, expire_at)
}

db_rename :: proc(src: []u8, dst: []u8) -> bool #no_bounds_check {
	db := cur_db()
	l := lookup_make(src)
	t, i := db_locate(db, &l)
	if i < 0 {
		return false
	}
	stamp := t.slots[i].meta.stamp
	due := slot_deadline(db, t, i)
	if due != 0 && due <= expire_now() {
		db_erase_expired(db, t, i)
		key_expired_event(src, db)
		return false
	}
	vh := t.slots[i].val
	vform := t.slots[i].key.small.tag.val_form
	t.slots[i].key.small.tag.val_form = FORM_NONE
	db_erase(db, t, i)
	db_find_in(db, dst)
	e, _ := db_upsert_timed_in(db, dst, due)
	mc_meta_on_erase(db, e.kp)
	val_release(db, e.kp, e.vp)
	e.vp^ = vh
	e.kp.small.tag.val_form = vform
	e.mp.stamp = stamp
	entry_set_expire(e, due)
	return true
}

db_move :: proc(src: ^Db, dst: ^Db, key: []u8) -> bool #no_bounds_check {
	l := lookup_make(key)
	t, i := db_locate(src, &l)
	if i < 0 {
		return false
	}
	stamp := t.slots[i].meta.stamp
	due := slot_deadline(src, t, i)
	if due != 0 && due <= expire_now() {
		db_erase_expired(src, t, i)
		key_expired_event(key, src)
		return false
	}
	if db_find_in(dst, key) != nil {
		return false
	}
	e, _ := db_upsert_timed_in(dst, key, due)
	kp := &t.slots[i].key
	vh := t.slots[i].val
	form := kp.small.tag.val_form
	switch form {
	case FORM_SLAB:
		n := int(vh.slab.len)
		off := slab_alloc(&dst.slab, n)
		intrinsics.mem_copy_non_overlapping(slab_ptr(&dst.slab, off), slab_ptr(&src.slab, vh.slab.offset), n)
		vh.slab.offset = off
	case FORM_HEAP:
		bs := (^Big_Str)(vh.ref.addr)
		n := int(bs.cap) + BIG_STR_BYTES
		src.heap_objs -= 1
		src.heap_bytes -= n
		dst.heap_objs += 1
		dst.heap_bytes += n
		kp.small.tag.val_form = FORM_NONE
	case FORM_OBJECT:
		n: int
		#partial switch vh.slab.info.type {
		case .Set:
			n = set_object_move(rawptr(vh.ref.addr), src, dst)
		case .List:
			n = list_object_acct(rawptr(vh.ref.addr))
		case .Zset:
			n = zset_object_move(rawptr(vh.ref.addr), src, dst)
		case .Stream:
			n = stream_object_acct(rawptr(vh.ref.addr))
		case:
			n = object_move(vh.slab.info.type, rawptr(vh.ref.addr), src, dst)
		}
		src.heap_objs -= 1
		src.heap_bytes -= n
		dst.heap_objs += 1
		dst.heap_bytes += n
		kp.small.tag.val_form = FORM_NONE
	}
	e.vp^ = vh
	e.kp.small.tag.val_form = form
	e.mp.stamp = stamp
	entry_set_expire(e, due)
	db_erase(src, t, i)
	db_maybe_shrink(src)
	return true
}

db_swap :: proc(a: int, b: int) {
	if a == b {
		return
	}
	x := &dbs[a]
	y := &dbs[b]
	x^, y^ = y^, x^
	x.id = a
	y.id = b
	x.hreg.owner = x
	y.hreg.owner = y
	x.sctx.owner = x
	y.sctx.owner = y
	x.zctx.owner = x
	y.zctx.owner = y
}

db_flush :: proc() {
	db_flush_in(cur_db())
}

db_flush_all :: proc(lazy: bool = false) {
	for &d in dbs {
		db_flush_in(&d, lazy)
	}
}

db_flush_in :: proc(db: ^Db, lazy: bool = false) {
	mc_meta_on_flush(db)
	hash_registry_flush(db)
	st.maintenance_clear(db.sctx)
	zt.maintenance_clear(db.zctx)
	db.avg_ttl = 0
	if db_size_of(db) == 0 && db.rehash_idx < 0 && db.t[0].region == nil && db.slab.base == nil && db.heap_objs == 0 {
		db.expires = 0
		db.expire_cursor = 0
		return
	}
	scan := db.heap_objs > 0
	if db.rehash_idx >= 0 {
		store_rehashing -= 1
	}
	db_drop_next(db)
	job := Lazy_Job {
		scan  = scan,
		count = db_size_of(db),
	}
	if !lazy && scan {
		storage_dead_payload += db.heap_bytes
	}
	for k in 0 ..< 2 {
		t := &db.t[k]
		if t.region == nil {
			continue
		}
		if lazy {
			job.tables[job.ntables] = t^
			job.ntables += 1
			t^ = {}
		} else if scan && t.live > 0 {
			dead_push(t^)
			t^ = {}
		} else {
			table_detach(t)
		}
	}
	db_used_memory -= db.heap_bytes
	if lazy {
		job.bytes += db.heap_bytes + db.slab.live
		job.slab_live = db.slab.live
		job.slab_base, job.slab_size = slab_take(&db.slab)
		lazyfree_submit(job)
	} else {
		slab_detach(&db.slab)
	}
	db.t[0] = table_empty()
	db.rehash_idx = -1
	db.expires = 0
	db.heap_objs = 0
	db.heap_bytes = 0
	db.expire_cursor = 0
}

graveyard_push :: proc "contextless" (base: [^]u8, size: int, kind: Storage_Kind) {
	if size <= 0 {
		return
	}
	if size <= RELEASE_NOW_BYTES || graveyard_len >= GRAVEYARD_MAX {
		storage_unmap(base, size, kind)
		return
	}
	graveyard[graveyard_len] = {base, size, kind}
	storage_retired[kind] += size
	graveyard_len += 1
}

@(private = "file")
graveyard_step :: proc "contextless" (deadline: i64) {
	for graveyard_len > 0 {
		r := &graveyard[graveyard_len - 1]
		chunk := min(r.size, RELEASE_CHUNK)
		storage_unmap(&r.base[r.size - chunk], chunk, r.kind)
		storage_retired[r.kind] -= chunk
		r.size -= chunk
		if r.size == 0 {
			graveyard_len -= 1
		}
		if now_ns() >= deadline {
			break
		}
	}
}

table_release_values :: proc "contextless" (t: ^Table) {
	dead_free_range(t, 0, t.cap)
}

@(private = "file")
dead_free_range :: proc "contextless" (t: ^Table, from: int, to: int) -> (released: int) #no_bounds_check {
	for i in from ..< to {
		if t.ctrl[i] & 0x80 == 0 {
			continue
		}
		kp := &t.slots[i].key
		if kp.small.tag.key_form == FORM_HEAP {
			extra := DEADLINE_BYTES if kp.heap.timed != 0 else 0
			released += (^int)(kp.heap.addr)^ + 8 + extra
			mem_free(rawptr(kp.heap.addr - uintptr(extra)))
		}
		if kp.small.tag.val_form == FORM_HEAP {
			bs := (^Big_Str)(t.slots[i].val.ref.addr)
			released += int(bs.cap) + BIG_STR_BYTES
			mem_free(bs.data)
			mem_free(bs)
		} else if kp.small.tag.val_form == FORM_OBJECT {
			#partial switch t.slots[i].val.slab.info.type {
			case .Set:
				released += set_object_release(rawptr(t.slots[i].val.ref.addr))
			case .List:
				released += list_object_release(rawptr(t.slots[i].val.ref.addr))
			case .Zset:
				released += zset_object_release(rawptr(t.slots[i].val.ref.addr))
			case .Stream:
				released += stream_object_release(rawptr(t.slots[i].val.ref.addr))
			case:
				released += object_release(t.slots[i].val.slab.info.type, rawptr(t.slots[i].val.ref.addr))
			}
		}
	}
	return
}

@(private = "file")
dead_push :: proc "contextless" (t: Table) {
	if dead_len >= DEAD_MAX {
		tt := t
		storage_dead_payload -= dead_free_range(&tt, 0, tt.cap)
		table_detach(&tt)
		return
	}
	dead[dead_len] = {t, 0}
	dead_len += 1
}

@(private = "file")
dead_step :: proc "contextless" () {
	d := &dead[dead_len - 1]
	end := min(d.pos + DEAD_SCAN_SLOTS, d.t.cap)
	storage_dead_payload -= dead_free_range(&d.t, d.pos, end)
	d.pos = end
	if end >= d.t.cap {
		table_detach(&d.t)
		dead_len -= 1
	}
}

db_tick :: proc "contextless" () {
	hash_resize_tick()
	set_resize_tick()
	zset_resize_tick()
	if srv.now_ms >= hash_tick_due {
		hash_tick()
	}
	if !slab_cold_pages && !slab_reclaim_pending() && store_rehashing == 0 && graveyard_len == 0 && dead_len == 0 && store_warming == 0 {
		return
	}
	idle := srv.stat_commands == store_tick_commands
	store_tick_commands = srv.stat_commands
	start := now_ns()
	slab_reclaim(start + WARM_BUSY_TICK_NS)
	if slab_cold_pages {
		slab_cold_pages = false
		warm_deadline := start + (WARM_TICK_NS if idle else WARM_BUSY_TICK_NS)
		for &d in dbs {
			if slab_warm(&d.slab, warm_deadline) && d.slab.warm < d.slab.top + slab_warm_ahead(&d.slab) {
				slab_cold_pages = true
			}
		}
	}
	if store_warming > 0 {
		deadline := start + (WARM_TICK_NS if idle else WARM_BUSY_TICK_NS)
		for &d in dbs {
			if d.next.region != nil && d.next_warm < d.next.size {
				db_warm(&d, deadline)
			}
		}
	}
	if cfg.activerehashing && store_rehashing > 0 {
		deadline := start + (REHASH_TICK_NS if idle else REHASH_BUSY_TICK_NS)
		n := len(dbs)
		for _ in 0 ..< n {
			if store_rehashing == 0 {
				break
			}
			d := &dbs[rehash_db_next]
			for d.rehash_idx >= 0 {
				db_rehash_groups(d, REHASH_TICK_GROUPS, REHASH_TICK_SLOTS)
				if now_ns() >= deadline {
					break
				}
			}
			if d.rehash_idx >= 0 {
				break
			}
			rehash_db_next = rehash_db_next + 1 if rehash_db_next + 1 < n else 0
		}
	}
	if dead_len > 0 {
		dead_step()
	}
	if graveyard_len > 0 {
		graveyard_step(now_ns() + (RELEASE_TICK_NS if idle else RELEASE_BUSY_TICK_NS))
	}
}

@(private = "file")
db_expire_slot :: proc(db: ^Db, t: ^Table, slot: int) {
	if .Expired not_in notify_active && !key_hooks && !aof.feed {
		db_erase_expired(db, t, slot)
		return
	}
	expired_key_copy(&t.slots[slot].key, &db.slab)
	db_erase_expired(db, t, slot)
	key_expired_event(expired_key_buf[:], db)
}

@(private = "file")
db_expire_scan :: proc(db: ^Db, deadline: i64) #no_bounds_check {
	t := &db.t[1] if db.rehash_idx >= 0 else &db.t[0]
	group := u64(db.expire_cursor) >> GROUP_SHIFT
	if group >= t.groups {
		group = 0
	}
	budget := min(t.cap, expire_slots_limit) >> GROUP_SHIFT
	pause_every := EXPIRE_CHUNK >> GROUP_SHIFT
	now := srv.now_ms
	remaining_total: i64
	live_timed: i64
	for visited := 1; visited <= budget && db.expires > 0; visited += 1 {
		occupied := group_full(group_load(t.ctrl, group))
		for occupied != 0 {
			slot := int(group << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(occupied))
			occupied &= occupied - 1
			kh := t.slots[slot].key
			if !key_timed(kh) {
				continue
			}
			due := i64(key_deadline_ptr(kh, &db.slab)^)
			switch {
			case due == 0:
			case due > now:
				remaining_total += due - now
				live_timed += 1
			case:
				expire_cycle_expired += 1
				db_expire_slot(db, t, slot)
			}
		}
		group += 1
		if group == t.groups {
			group = 0
		}
		if visited % pause_every == 0 && now_ns() >= deadline {
			break
		}
	}
	db.expire_cursor = int(group << GROUP_SHIFT)
	expire_cycle_sampled += live_timed
	if live_timed > 0 {
		fresh := remaining_total / live_timed
		db.avg_ttl = fresh if db.avg_ttl == 0 else (db.avg_ttl / 50) * 49 + fresh / 50
	}
	db_maybe_shrink(db)
}

expiry_sweep_on := true
expire_slots_limit := EXPIRE_SLOTS_PER_TICK
expire_cycle_expired: i64
expire_cycle_sampled: i64

expired_key_buf: [dynamic]u8

expired_key_copy :: proc(kp: ^Key_Handle, s: ^Slab) {
	clear(&expired_key_buf)
	append(&expired_key_buf, ..key_bytes(kp, s))
}

expiry_deletion_paused :: #force_inline proc "contextless" () -> bool {
	return srv.pause_end_ms > srv.now_ms
}

db_active_expire :: proc() {
	if !expiry_sweep_on || expiry_deletion_paused() {
		return
	}
	n := len(dbs)
	effort := cfg.active_expire_effort - 1
	expire_slots_limit = EXPIRE_SLOTS_PER_TICK * int(4 + effort) / 4
	start := now_ns()
	deadline := start + EXPIRE_TICK_NS * 10 / config_hz_current * (25 + 2 * effort) / 25
	expire_cycle_expired = 0
	expire_cycle_sampled = 0
	timelimit_exit := false
	for _ in 0 ..< n {
		d := &dbs[expire_db_next]
		expire_db_next = expire_db_next + 1 if expire_db_next + 1 < n else 0
		if d.expires == 0 {
			d.avg_ttl = 0
			continue
		}
		db_expire_scan(d, deadline)
		if now_ns() >= deadline {
			timelimit_exit = true
			break
		}
	}
	elapsed := now_ns() - start
	stat_expire_cycle_us += elapsed / 1000
	if timelimit_exit {
		stat_expired_time_cap_reached += 1
	}
	total := expire_cycle_expired + expire_cycle_sampled
	current := f64(expire_cycle_expired) / f64(total) if total > 0 else 0
	stat_expired_stale_perc = current * 0.05 + stat_expired_stale_perc * 0.95
	latency_add_if_needed("expire-cycle", elapsed / 1_000_000)
}

RANDOM_KEY_PAUSED_TRIES :: 100

db_random_key :: proc() -> (key: string, ok: bool) #no_bounds_check {
	db := cur_db()
	tries := RANDOM_KEY_PAUSED_TRIES
	for {
		total := db_size_of(db)
		if total == 0 {
			return
		}
		t := &db.t[0]
		if db.rehash_idx >= 0 && int(rng_next() % u64(total)) >= db.t[0].live {
			t = &db.t[1]
		}
		if t.live == 0 {
			continue
		}
		i := random_full_slot(t)
		if i < 0 {
			return
		}
		if db.expires > 0 {
			exp := slot_deadline(db, t, i)
			if exp != 0 && exp <= expire_now() {
				if !expiry_deletion_paused() {
					expired_key_copy(&t.slots[i].key, &db.slab)
					db_erase_expired(db, t, i)
					key_expired_event(expired_key_buf[:], db)
					continue
				}
				if db.expires < total {
					continue
				}
				tries -= 1
				if tries > 0 {
					continue
				}
			}
		}
		return transmute(string)key_bytes(&t.slots[i].key, &db.slab), true
	}
}

db_keys :: proc(pat: []u8, all: bool) #no_bounds_check {
	db := cur_db()
	clear(&key_scratch)
	now := srv.now_ms
	for k in 0 ..< 2 {
		if k == 1 && db.rehash_idx < 0 {
			break
		}
		t := &db.t[k]
		for g in 0 ..< t.groups {
			full := group_full(group_load(t.ctrl, g))
			for full != 0 {
				i := int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(full))
				full &= full - 1
				if db.expires > 0 {
					exp := slot_deadline(db, t, i)
					if exp != 0 && exp <= now {
						continue
					}
				}
				kb := key_bytes(&t.slots[i].key, &db.slab)
				if all || glob_match(pat, kb, false) {
					append(&key_scratch, transmute(string)kb)
				}
			}
		}
	}
}

@(private = "file")
Scan_Pass :: struct {
	db:       ^Db,
	pattern:  []u8,
	filtered: bool,
	now:      i64,
	examined: i64,
}

@(private = "file")
scan_offer :: proc(pass: ^Scan_Pass, t: ^Table, slot: int, name: []u8) #no_bounds_check {
	if pass.filtered && !glob_match(pass.pattern, name, false) {
		return
	}
	due := slot_deadline(pass.db, t, slot) if pass.db.expires > 0 else 0
	if due != 0 && due <= pass.now {
		append(&scan_expired, ..name)
		append(&scan_expired_ends, len(scan_expired))
		return
	}
	append(&key_scratch, transmute(string)name)
}

@(private = "file")
scan_take_home :: proc(pass: ^Scan_Pass, t: ^Table, home: u64) #no_bounds_check {
	group := home
	hop: u64
	for {
		ctrl := group_load(t.ctrl, group)
		occupied := group_full(ctrl)
		for occupied != 0 {
			slot := int(group << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(occupied))
			occupied &= occupied - 1
			name := key_bytes(&t.slots[slot].key, &pass.db.slab)
			if hash_home(hash_bytes(name), t.groups) == home {
				pass.examined += 1
				scan_offer(pass, t, slot, name)
			}
		}
		if group_empty(ctrl) != 0 {
			return
		}
		group = probe_next(t, group, &hop)
	}
}

@(private = "file")
scan_round :: proc(pass: ^Scan_Pass, cursor: u64) -> u64 {
	db := pass.db
	if db.rehash_idx < 0 {
		only := &db.t[0]
		home := hash_home(cursor, only.groups)
		scan_take_home(pass, only, home)
		return group_floor(only.groups, home + 1)
	}
	narrow, wide := &db.t[0], &db.t[1]
	if narrow.groups > wide.groups {
		narrow, wide = wide, narrow
	}
	home := hash_home(cursor, narrow.groups)
	scan_take_home(pass, narrow, home)
	next := group_floor(narrow.groups, home + 1)
	last := hash_home(next - 1, wide.groups)
	for g := hash_home(cursor, wide.groups); g <= last; g += 1 {
		scan_take_home(pass, wide, g)
	}
	return next
}

db_scan :: proc(cursor: u64, count: i64, pat: []u8, has_pat: bool) -> u64 {
	pass := Scan_Pass{db = cur_db(), pattern = pat, filtered = has_pat, now = srv.now_ms}
	scan_reset()
	if db_size_of(pass.db) == 0 {
		return 0
	}
	rounds := I64_MAX if count >= I64_MAX / 10 else count * 10
	at := cursor
	for rounds > 0 {
		at = scan_round(&pass, at)
		rounds -= 1
		if at == 0 || pass.examined >= count {
			break
		}
	}
	return at
}

@(private = "file")
scan_reset :: proc() {
	clear(&scan_expired_ends)
	clear(&scan_expired)
	clear(&key_scratch)
}

@(private = "file")
htstats_table :: proc(b: ^[dynamic]u8, t: ^Table, title: string) {
	sb_str(b, title)
	sb_str(b, "\n table size: ")
	sb_int(b, i64(t.cap))
	sb_str(b, "\n number of elements: ")
	sb_int(b, i64(t.live))
	sb_str(b, "\n tombstones: ")
	sb_int(b, i64(t.tombs))
	sb_str(b, "\n")
}

db_htstats :: proc(b: ^[dynamic]u8, id: int) {
	db := &dbs[id]
	sb_str(b, "[Dictionary HT]\n")
	if db_size_of(db) == 0 && db.rehash_idx < 0 {
		sb_str(b, "No stats available for empty dictionaries\n")
	} else {
		htstats_table(b, &db.t[0], "Hash table 0 stats (main hash table):")
		if db.rehash_idx >= 0 {
			htstats_table(b, &db.t[1], "Hash table 1 stats (rehashing target):")
			sb_str(b, " rehash index: ")
			sb_int(b, db.rehash_idx)
			sb_str(b, "\n")
		}
	}
	sb_str(b, "[Expires HT]\n number of elements: ")
	sb_int(b, i64(db.expires))
	sb_str(b, "\n")
}

SECONDS_STAMP_MASK :: (1 << 24) - 1
MINUTE_STAMP_WRAP :: 65535
TALLY_START :: 5
TALLY_CEILING :: 255
SHARED_INTEGER_LIMIT :: 10000

store_no_touch: bool
store_reconciling: bool
store_new_deadline: i64
access_counts_hits: bool
tally_log_factor := 10
tally_decay_minutes := 1

Access_Note :: bit_field u32 {
	stamp: u16 | 16,
	tally: u8  | 8,
}

#assert(size_of(Access_Note) == 4)

access_minute_now :: #force_inline proc "contextless" () -> u16 {
	return u16((srv.now_ms / 60_000) & 0xFFFF)
}

seconds_note :: #force_inline proc "contextless" (seconds: u32) -> Access_Note {
	return Access_Note{stamp = u16(seconds & 0xFFFF), tally = u8((seconds >> 16) & 0xFF)}
}

note_seconds :: #force_inline proc "contextless" (note: Access_Note) -> u32 {
	return u32(note.tally) << 16 | u32(note.stamp)
}

seconds_before :: proc "contextless" (now: u32, idle: i64) -> u32 {
	borrow := i64(1) if idle > i64(now) else 0
	return u32((i64(now) - idle - borrow) & SECONDS_STAMP_MASK)
}

access_fresh_note :: #force_inline proc "contextless" () -> Access_Note {
	if access_counts_hits {
		return Access_Note{stamp = access_minute_now(), tally = TALLY_START}
	}
	return seconds_note(access_seconds_now)
}

entry_note :: #force_inline proc "contextless" (e: ^Entry) -> Access_Note {
	return Access_Note{stamp = e.mp.stamp, tally = e.vp.small.tally}
}

entry_keep_note :: #force_inline proc "contextless" (e: ^Entry, note: Access_Note) {
	e.mp.stamp = note.stamp
	e.vp.small.tally = note.tally
}

entry_access_word :: #force_inline proc "contextless" (e: ^Entry) -> u32 {
	return transmute(u32)entry_note(e)
}

entry_set_access_word :: #force_inline proc "contextless" (e: ^Entry, word: u32) {
	entry_keep_note(e, transmute(Access_Note)word)
}

entry_debug_lru :: proc "contextless" (e: ^Entry) -> i64 {
	note := entry_note(e)
	if access_counts_hits {
		return i64(note.stamp) << 8 | i64(note.tally)
	}
	return i64(note_seconds(note))
}

entry_touch :: #force_inline proc "contextless" (e: ^Entry) {
	if store_no_touch || pst.child_pid > 0 {
		return
	}
	if access_counts_hits {
		entry_count_hit(e)
		return
	}
	entry_keep_note(e, seconds_note(access_seconds_now))
}

entry_touched :: #force_inline proc "contextless" (e: ^Entry) -> ^Entry {
	entry_touch(e)
	return e
}

entry_access_init :: proc "contextless" (e: ^Entry) {
	entry_keep_note(e, access_fresh_note())
}

entry_idle_ms :: proc "contextless" (e: ^Entry) -> i64 {
	return lru_idle_ms_of(note_seconds(entry_note(e)))
}

entry_idle_seconds :: proc "contextless" (e: ^Entry) -> i64 {
	return entry_idle_ms(e) / 1000
}

entry_restore_idle :: proc "contextless" (e: ^Entry, idle: i64) {
	entry_keep_note(e, seconds_note(seconds_before(access_seconds_now, idle)))
}

entry_restore_tally :: proc "contextless" (e: ^Entry, tally: i64) {
	entry_keep_note(e, Access_Note{stamp = access_minute_now(), tally = u8(clamp(tally, 0, TALLY_CEILING))})
}

entry_tally :: proc "contextless" (e: ^Entry) -> i64 {
	note := entry_note(e)
	return lfu_value_of(note.tally, note.stamp, access_minute_now(), tally_decay_minutes)
}

lru_idle_ms_of :: #force_inline proc "contextless" (seconds: u32) -> i64 {
	now := access_seconds_now
	span := i64(now - seconds) if seconds <= now else i64(now) + SECONDS_STAMP_MASK - i64(seconds)
	return span * 1000
}

minutes_between :: #force_inline proc "contextless" (then, now: u16) -> i64 {
	if then <= now {
		return i64(now - then)
	}
	return MINUTE_STAMP_WRAP - i64(then) + i64(now)
}

lfu_value_of :: proc "contextless" (tally: u8, stamp: u16, minute: u16, decay_minutes: int) -> i64 {
	if decay_minutes <= 0 {
		return i64(tally)
	}
	lost := minutes_between(stamp, minute) / i64(decay_minutes)
	return max(i64(tally) - lost, 0)
}

unit_fraction :: #force_inline proc "contextless" (draw: u64) -> f64 {
	return f64(draw >> 11) * (1.0 / f64(u64(1) << 53))
}

tally_climbs :: proc "contextless" (tally: i64, fraction: f64, log_factor: int) -> bool {
	excess := tally - TALLY_START
	if excess <= 0 {
		return true
	}
	return fraction * (f64(excess) * f64(log_factor) + 1) < 1
}

@(cold)
entry_count_hit :: #force_no_inline proc "contextless" (e: ^Entry) {
	minute := access_minute_now()
	note := entry_note(e)
	level := lfu_value_of(note.tally, note.stamp, minute, tally_decay_minutes)
	if level < TALLY_CEILING && tally_climbs(level, unit_fraction(rng_next()), tally_log_factor) {
		level += 1
	}
	entry_keep_note(e, Access_Note{stamp = minute, tally = u8(level)})
}

db_find_raw_in :: proc(db: ^Db, key: []u8) -> ^Entry {
	lookup := lookup_make(key)
	table, index := db_locate(db, &lookup)
	return entry_view(db, table, index) if index >= 0 else nil
}

db_find_notouch :: proc(key: []u8) -> ^Entry {
	saved := store_no_touch
	store_no_touch = true
	e := db_find(key)
	store_no_touch = saved
	return e
}

db_find_read_notouch :: proc(key: []u8) -> ^Entry {
	saved := store_no_touch
	store_no_touch = true
	e := db_find_read(key)
	store_no_touch = saved
	return e
}

entry_obj_encoding :: proc "contextless" (e: ^Entry) -> Obj_Encoding {
	if e.kp.small.tag.val_form <= FORM_INLINE + INLINE_BYTES {
		return small_encoding(e.val)
	}
	return e.vp.slab.info.enc
}

entry_shared_integer :: proc "contextless" (e: ^Entry) -> bool {
	form := e.kp.small.tag.val_form
	if form < FORM_INLINE || form > FORM_INLINE + INLINE_BYTES {
		return false
	}
	v, ok := parse_i64(e.val)
	return ok && v >= 0 && v < SHARED_INTEGER_LIMIT
}

entry_copy_string :: proc "contextless" (e: ^Entry, v: []u8, enc: Obj_Encoding) {
	inline_ok := enc != .Raw
	if enc == .Int {
		if n, ok := parse_i64(v); ok && n >= 0 && n < SHARED_INTEGER_LIMIT {
			inline_ok = false
		}
	}
	entry_store(e, v, enc, inline_ok)
}

RANDOM_SLOT_PROBES :: 64

scan_expired: [dynamic]u8
scan_expired_ends: [dynamic]int

@(private = "file")
random_full_slot :: proc "contextless" (t: ^Table) -> int #no_bounds_check {
	for _ in 0 ..< RANDOM_SLOT_PROBES {
		i := int((u128(rng_next()) * u128(t.cap)) >> 64)
		if t.ctrl[i] & 0x80 != 0 {
			return i
		}
	}
	r := int(rng_next() % u64(t.live))
	for g in 0 ..< t.groups {
		full := group_full(group_load(t.ctrl, g))
		n := int(intrinsics.count_ones(full))
		if r < n {
			for _ in 0 ..< r {
				full &= full - 1
			}
			return int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(full))
		}
		r -= n
	}
	return -1
}

db_sample_key :: proc(db: ^Db) -> (e: ^Entry, key: []u8, ok: bool) #no_bounds_check {
	total := db_size_of(db)
	if total == 0 {
		return
	}
	t := &db.t[0]
	if db.rehash_idx >= 0 && int(rng_next() % u64(total)) >= db.t[0].live {
		t = &db.t[1]
	}
	if t.live == 0 {
		return
	}
	i := random_full_slot(t)
	if i < 0 {
		return
	}
	return entry_view(db, t, i), key_bytes(&t.slots[i].key, &db.slab), true
}

Evict_Score :: enum u8 {
	Lru,
	Lfu,
	Ttl,
}

Evict_Sample :: struct {
	score: u64,
	key:   []u8,
}

db_evict_sample :: proc(db: ^Db, out: []Evict_Sample, volatile: bool, score: Evict_Score) -> int #no_bounds_check {
	total := db_size_of(db)
	if total == 0 || len(out) == 0 {
		return 0
	}
	k := 0
	if db.rehash_idx >= 0 && int(rng_next() % u64(total)) >= db.t[0].live {
		k = 1
	}
	n := table_evict_sample(db, &db.t[k], out, volatile, score)
	if n == 0 && db.rehash_idx >= 0 {
		n = table_evict_sample(db, &db.t[1 - k], out, volatile, score)
	}
	return n
}

@(private = "file")
slot_evict_rank :: #force_inline proc "contextless" (meta: Slot_Meta, val: Val_Handle, due: i64, score: Evict_Score) -> u64 {
	note := Access_Note{stamp = meta.stamp, tally = val.small.tally}
	switch score {
	case .Lru:
		return u64(lru_idle_ms_of(note_seconds(note)))
	case .Lfu:
		return u64(TALLY_CEILING - lfu_value_of(note.tally, note.stamp, access_minute_now(), tally_decay_minutes))
	case .Ttl:
		return max(u64) - u64(due)
	}
	return 0
}

@(private = "file")
table_evict_sample :: proc(db: ^Db, table: ^Table, picks: []Evict_Sample, timed_only: bool, rank: Evict_Score) -> int #no_bounds_check {
	taken, window, at := 0, 0, 0
	if table.live > 0 {
		window = table.cap if timed_only else min(len(picks) * 10, table.cap)
		at = int((u128(rng_next()) * u128(table.cap)) >> 64)
	}
	for window > 0 && taken < len(picks) {
		group := u64(at >> GROUP_SHIFT)
		lane := at & (GROUP_SLOTS - 1)
		span := min(GROUP_SLOTS - lane, window)
		lanes := ((u32(1) << u32(span)) - 1) << u32(lane)
		occupied := group_full(group_load(table.ctrl, group)) & lanes
		for occupied != 0 && taken < len(picks) {
			slot := int(group << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(occupied))
			occupied &= occupied - 1
			kh := table.slots[slot].key
			if timed_only && !key_timed(kh) {
				continue
			}
			due := key_deadline(kh, &db.slab) if rank == .Ttl else 0
			picks[taken] = {slot_evict_rank(table.slots[slot].meta, table.slots[slot].val, due, rank), key_bytes(&table.slots[slot].key, &db.slab)}
			taken += 1
		}
		window -= span
		at += span
		if at >= table.cap {
			at -= table.cap
		}
	}
	return taken
}

db_evict_has :: proc(db: ^Db, key: []u8, volatile: bool) -> bool {
	l := lookup_make(key)
	t, i := db_locate(db, &l)
	if i < 0 {
		return false
	}
	return !volatile || key_timed(t.slots[i].key)
}

db_scan_purge_expired :: proc(count_misses: bool) {
	db := cur_db()
	start := 0
	saved := lazy_set(cfg.lazyfree_lazy_expire)
	defer lazy_mode = saved
	for end in scan_expired_ends {
		found, expired := db_remove_in(db, scan_expired[start:end])
		if found && expired {
			srv.stat_expired += 1
			key_expired_event(scan_expired[start:end], db)
			if count_misses {
				srv.stat_misses += 1
			}
		}
		start = end
	}
	clear(&scan_expired)
	clear(&scan_expired_ends)
}
