package main

import "base:intrinsics"
import "base:runtime"
import ht "hashtype"
import lb "label"
import ow "owner"
import st "settype"
import vt "vsettype"
import zt "zsettype"

ERR_OWNER_PARTITIONS :: "ERR owner partition limit reached"
OWNER_SAMPLE_BUCKETS :: 48

Owner_Active :: enum u8 {
	Expire,
	Field,
	Hash_Resize,
	Set_Resize,
	Zset_Resize,
	Rehash,
}

Owner_Weight :: enum u8 {
	Keys,
	Expires,
}

Owner_Part :: struct {
	space:  ^Owner_Space,
	active: [Owner_Active]u32,
	sample: [Owner_Weight]u32,
	bucket: [Owner_Weight]u8,
	db:     Db_Core,
}

Owner_Ctx :: struct {
	hreg: ht.Registry,
	sctx: st.Context,
	zctx: zt.Context,
}

OWNER_HEAD_BYTES :: offset_of(Owner_Part, db)

#assert(OWNER_HEAD_BYTES == 48)
#assert(OWNER_HEAD_BYTES + size_of(Db_Core) == size_of(Owner_Part))
#assert(size_of(Owner_Part) == 376)
#assert(offset_of(Db, slab) == size_of(Db_Core))
#assert(offset_of(Owner_Ctx, hreg) == 0)
#assert(size_of(Owner_Ctx) == 152)

owner_compact := true

owner_db :: #force_inline proc "contextless" (p: ^Owner_Part) -> ^Db {
	return (^Db)(&p.db)
}

owner_part_of :: #force_inline proc "contextless" (db: ^Db) -> ^Owner_Part {
	return (^Owner_Part)(uintptr(db) - OWNER_HEAD_BYTES)
}

@(cold)
owner_ctx_need :: #force_no_inline proc "contextless" (db: ^Db, type: Obj_Type) {
	if db.hreg == nil && (type == .Hash || type == .Set || type == .Zset) {
		owner_ctx_make(db)
	}
}

owner_ctx_make :: proc "contextless" (db: ^Db) {
	c := (^Owner_Ctx)(runtime.heap_alloc(size_of(Owner_Ctx), true))
	if c == nil {
		store_fatal("out of memory")
	}
	c.hreg.owner = db
	c.sctx.owner = db
	c.zctx.owner = db
	db.hreg = &c.hreg
	db.sctx = &c.sctx
	db.zctx = &c.zctx
	owner_structs(owner_part_of(db).space.entry, size_of(Owner_Ctx))
}

owner_ctx_drop :: proc "contextless" (db: ^Db) {
	if db.hreg == nil {
		return
	}
	c := (^Owner_Ctx)(db.hreg)
	ht.registry_destroy(&c.hreg)
	st.maintenance_clear(&c.sctx)
	zt.maintenance_clear(&c.zctx)
	db.hreg = nil
	db.sctx = nil
	db.zctx = nil
	owner_structs(owner_part_of(db).space.entry, -size_of(Owner_Ctx))
	runtime.heap_free(c)
}

Owner_Slot :: struct {
	label: lb.Id,
	part:  ^Owner_Part,
}

Owner_Dup :: struct {
	reader:     lb.Id,
	valid:      bool,
	shared_gen: u64,
	own_gen:    u64,
	keys:       int,
	expires:    int,
}

Owner_Space :: struct {
	entry:      ^Owner_Entry,
	first:      Owner_Slot,
	more:       ^[dynamic]Owner_Slot,
	ever_more:  ^[dynamic]lb.Id,
	copies:     ^map[string]^Label_Copies,
	own_gen:    u64,
	dup:        Owner_Dup,
	dbi:        int,
	pos:        int,
	ever_first: lb.Id,
	nparts:     u16,
	ever_n:     u16,
}

Owner_Stream :: struct {
	label: lb.Id,
	words: Label_Stream,
}

Keyspace_Owner :: struct {
	quota:     i64,
	quota_set: bool,
	stream:    Owner_Stream,
	streams:   ^[dynamic]^Owner_Stream,
	space:     ^Owner_Space,
	spaces:    ^[dynamic]^Owner_Space,
	used:      int,
	keys:      int,
	parts:     int,
	structs:   int,
}

Owner_Counts :: struct {
	keys:     i64,
	elements: i64,
	bytes:    i64,
}

Owner_Info :: struct {
	keys:       i64,
	elements:   i64,
	bytes:      i64,
	partitions: i64,
	labels:     i64,
	quota:      i64,
}

Owner_Totals :: struct {
	holding:    i64,
	partitions: i64,
	bytes:      i64,
}

Owner_Db :: struct {
	spaces:     [dynamic]^Owner_Space,
	shared_gen: u64,
	keys:       int,
	tables:     int,
}

Owner_Sampler :: struct {
	bucket: [OWNER_SAMPLE_BUCKETS][dynamic]^Owner_Part,
	mass:   u64,
}

Owner_Touch :: struct {
	p:     ^Owner_Part,
	keys:  int,
	bytes: int,
	exp:   int,
	tabs:  int,
}

owner_dbs: []Owner_Db
owner_active: [Owner_Active][dynamic]^Owner_Part
owner_active_next: [Owner_Active]int
owner_sampler: [Owner_Weight]Owner_Sampler
owner_touched: [dynamic]Owner_Touch
owner_parts_total: int
owner_keys_total: int
owner_expires_total: int
owner_bytes_total: int
owner_struct_bytes: int
owner_global_bytes: int
owner_holding: int
owner_draw: u64 = 0x9E37_79B9_7F4A_7C15
owner_stream_cur: ^Label_Stream
owner_stream_spare: Label_Stream
owner_stream_cur_entry: ^Owner_Entry
owner_stream_cur_label: lb.Id
owner_stream_pending: Label_Stream
owner_stream_pending_seed: Label_Stream
owner_stream_pending_entry: ^Owner_Entry
owner_stream_pending_label: lb.Id
owner_stream_probe: Label_Stream

owner_user :: #force_inline proc "contextless" () -> bool {
	return owners_on && ow.is_user(access.owner)
}

owner_db_ready :: proc(dbi: int) -> ^Owner_Db {
	if owner_dbs == nil {
		owner_dbs = make([]Owner_Db, max(len(dbs), 1))
		owner_structs(nil, len(owner_dbs) * size_of(Owner_Db))
	}
	if dbi >= len(owner_dbs) {
		grown := make([]Owner_Db, dbi + 1)
		copy(grown, owner_dbs)
		owner_structs(nil, (len(grown) - len(owner_dbs)) * size_of(Owner_Db))
		delete(owner_dbs)
		owner_dbs = grown
	}
	return &owner_dbs[dbi]
}

owner_shared_changed :: #force_inline proc "contextless" (dbi: int) {
	if dbi >= 0 && dbi < len(owner_dbs) {
		owner_dbs[dbi].shared_gen += 1
	}
}

owner_structs :: #force_inline proc "contextless" (e: ^Owner_Entry, n: int) {
	owner_struct_bytes += n
	if e != nil {
		e.keyspace.structs += n
		e.keyspace.used += n
	} else {
		owner_global_bytes += n
	}
}

owner_slot_share :: #force_inline proc "contextless" (e: ^Owner_Entry, n: int) {
	owner_global_bytes -= n
	e.keyspace.structs += n
	e.keyspace.used += n
}

owner_space_of :: proc "contextless" (e: ^Owner_Entry, dbi: int) -> ^Owner_Space {
	if e == nil {
		return nil
	}
	ks := &e.keyspace
	if ks.space != nil && ks.space.dbi == dbi {
		return ks.space
	}
	if ks.spaces != nil {
		for s in ks.spaces {
			if s.dbi == dbi {
				return s
			}
		}
	}
	return nil
}

owner_space_make :: proc(e: ^Owner_Entry, dbi: int) -> ^Owner_Space {
	if s := owner_space_of(e, dbi); s != nil {
		return s
	}
	od := owner_db_ready(dbi)
	s := new(Owner_Space)
	s.entry = e
	s.dbi = dbi
	s.first.label = lb.ID_NONE
	s.ever_first = lb.ID_NONE
	s.pos = len(od.spaces)
	before_slots := cap(od.spaces)
	append(&od.spaces, s)
	owner_structs(nil, (cap(od.spaces) - before_slots) * size_of(^Owner_Space))
	owner_slot_share(e, size_of(^Owner_Space))
	ks := &e.keyspace
	if ks.space == nil {
		ks.space = s
	} else {
		if ks.spaces == nil {
			ks.spaces = new([dynamic]^Owner_Space)
			owner_structs(e, size_of([dynamic]^Owner_Space))
		}
		before := cap(ks.spaces)
		append(ks.spaces, s)
		owner_structs(e, (cap(ks.spaces) - before) * size_of(^Owner_Space))
	}
	owner_structs(e, size_of(Owner_Space))
	return s
}

owner_space_drop :: proc(s: ^Owner_Space) {
	e := s.entry
	ks := &e.keyspace
	od := &owner_dbs[s.dbi]
	last := od.spaces[len(od.spaces) - 1]
	od.spaces[s.pos] = last
	last.pos = s.pos
	pop(&od.spaces)
	owner_slot_share(e, -size_of(^Owner_Space))
	if ks.space == s {
		ks.space = nil
		if ks.spaces != nil && len(ks.spaces) > 0 {
			ks.space = pop(ks.spaces)
		}
	} else if ks.spaces != nil {
		for x, i in ks.spaces {
			if x == s {
				unordered_remove(ks.spaces, i)
				break
			}
		}
	}
	if ks.spaces != nil && len(ks.spaces) == 0 {
		owner_structs(e, -(cap(ks.spaces) * size_of(^Owner_Space) + size_of([dynamic]^Owner_Space)))
		delete(ks.spaces^)
		free(ks.spaces)
		ks.spaces = nil
	}
	if s.copies != nil {
		for name, cp in s.copies {
			owner_structs(e, -owner_copies_bytes(cp))
			label_copies_free(cp)
			_ = name
		}
		owner_structs(e, -owner_registry_bytes(s.copies))
		delete(s.copies^)
		free(s.copies)
	}
	if s.more != nil {
		owner_structs(e, -(cap(s.more) * size_of(Owner_Slot) + size_of([dynamic]Owner_Slot)))
		delete(s.more^)
		free(s.more)
	}
	if s.ever_more != nil {
		owner_structs(e, -(cap(s.ever_more) * size_of(lb.Id) + size_of([dynamic]lb.Id)))
		delete(s.ever_more^)
		free(s.ever_more)
	}
	owner_structs(e, -size_of(Owner_Space))
	free(s)
}

owner_copies_bytes :: #force_inline proc "contextless" (cp: ^Label_Copies) -> int {
	return size_of(Label_Copies) + len(cp.name) + cap(cp.copies) * size_of(Label_Copy)
}

owner_registry_bytes :: #force_inline proc "contextless" (m: ^map[string]^Label_Copies) -> int {
	return size_of(map[string]^Label_Copies) + cap(m^) * (size_of(string) + size_of(^Label_Copies) + 8)
}

owner_space_part :: proc "contextless" (s: ^Owner_Space, label: lb.Id) -> ^Owner_Part {
	if s == nil {
		return nil
	}
	if s.first.part != nil && s.first.label == label {
		return s.first.part
	}
	if s.more != nil {
		for slot in s.more {
			if slot.label == label {
				return slot.part
			}
		}
	}
	return nil
}

owner_space_count :: #force_inline proc "contextless" (s: ^Owner_Space) -> int {
	return int(s.nparts)
}

owner_space_at :: proc "contextless" (s: ^Owner_Space, i: int) -> ^Owner_Part {
	if i == 0 {
		return s.first.part
	}
	return s.more[i - 1].part
}

owner_ever_len :: #force_inline proc "contextless" (s: ^Owner_Space) -> int {
	if s == nil {
		return 0
	}
	return int(s.ever_n)
}

owner_ever_at :: proc "contextless" (s: ^Owner_Space, i: int) -> lb.Id {
	if i == 0 {
		return s.ever_first
	}
	return s.ever_more[i - 1]
}

owner_ever_add :: proc(s: ^Owner_Space, label: lb.Id) {
	n := int(s.ever_n)
	for i in 0 ..< n {
		if owner_ever_at(s, i) == label {
			return
		}
	}
	e := s.entry
	if n == 0 {
		s.ever_first = label
		s.ever_n = 1
		return
	}
	if s.ever_more == nil {
		s.ever_more = new([dynamic]lb.Id)
		owner_structs(e, size_of([dynamic]lb.Id))
	}
	before := cap(s.ever_more)
	append(s.ever_more, label)
	owner_structs(e, (cap(s.ever_more) - before) * size_of(lb.Id))
	s.ever_n += 1
	for i := n; i > 0; i -= 1 {
		a := owner_ever_at(s, i - 1)
		b := owner_ever_at(s, i)
		if !label_less(b, a) {
			break
		}
		owner_ever_put(s, i - 1, b)
		owner_ever_put(s, i, a)
	}
}

owner_ever_put :: #force_inline proc "contextless" (s: ^Owner_Space, i: int, label: lb.Id) {
	if i == 0 {
		s.ever_first = label
	} else {
		s.ever_more[i - 1] = label
	}
}

owner_part_bytes :: #force_inline proc "contextless" (p: ^Db) -> int {
	return p.t[0].size + p.t[1].size + p.heap_bytes
}

owner_part_tables :: #force_inline proc "contextless" (p: ^Db) -> int {
	return p.t[0].size + p.t[1].size
}

owner_part_make :: proc(e: ^Owner_Entry, dbi: int, label: lb.Id) -> (^Owner_Part, bool) {
	s := owner_space_of(e, dbi)
	if p := owner_space_part(s, label); p != nil {
		return p, true
	}
	if owner_partitions_max > 0 && i64(owner_parts_total) >= owner_partitions_max {
		return nil, false
	}
	if s == nil {
		s = owner_space_make(e, dbi)
	}
	p := (^Owner_Part)(runtime.heap_alloc(size_of(Owner_Part), true))
	if p == nil {
		store_fatal("out of memory")
	}
	d := owner_db(p)
	db_part_init(d, dbi)
	d.label = label
	d.owner = e.number
	d.role = DB_ROLE_HEAP | DB_ROLE_OWNER
	p.space = s
	if !owner_compact {
		owner_ctx_make(d)
	}
	if s.first.part == nil {
		s.first = Owner_Slot{label, p}
	} else {
		if s.more == nil {
			s.more = new([dynamic]Owner_Slot)
			owner_structs(e, size_of([dynamic]Owner_Slot))
		}
		before := cap(s.more)
		append(s.more, Owner_Slot{label, p})
		owner_structs(e, (cap(s.more) - before) * size_of(Owner_Slot))
	}
	s.nparts += 1
	owner_ever_add(s, label)
	if e.keyspace.parts == 0 {
		owner_holding += 1
	}
	e.keyspace.parts += 1
	owner_parts_total += 1
	owner_structs(e, size_of(Owner_Part))
	s.dup.valid = false
	return p, true
}

owner_part_release :: proc(p: ^Owner_Part) {
	for k in Owner_Active {
		owner_active_drop(p, k)
	}
	for k in Owner_Weight {
		owner_sampler_remove(p, k)
	}
	d := owner_db(p)
	evict_pool_forget(d)
	for i := len(owner_touched) - 1; i >= 0; i -= 1 {
		if owner_touched[i].p == p {
			ordered_remove(&owner_touched, i)
		}
	}
	if d.rehash_idx >= 0 {
		store_rehashing -= 1
	}
	gone := owner_part_bytes(d)
	owner_dbs[d.id].tables -= owner_part_tables(d)
	for k in 0 ..< 2 {
		table_detach(&d.t[k])
	}
	if d.heap_bytes != 0 {
		db_used_memory -= d.heap_bytes
	}
	owner_ctx_drop(d)
	s := p.space
	e := s.entry
	e.keyspace.used -= gone
	owner_bytes_total -= gone
	if s.first.part == p {
		s.first = Owner_Slot{lb.ID_NONE, nil}
		if s.more != nil && len(s.more) > 0 {
			s.first = pop(s.more)
		}
	} else if s.more != nil {
		for slot, i in s.more {
			if slot.part == p {
				unordered_remove(s.more, i)
				break
			}
		}
	}
	s.nparts -= 1
	s.dup.valid = false
	e.keyspace.parts -= 1
	if e.keyspace.parts == 0 {
		owner_holding -= 1
	}
	owner_parts_total -= 1
	owner_structs(e, -size_of(Owner_Part))
	if db_cur == d {
		db_cur = label_dbs[d.id].sentinel if d.id >= 0 && d.id < len(label_dbs) else &dbs[0]
	}
	runtime.heap_free(p)
}

owner_touch :: proc(p: ^Db) {
	op := owner_part_of(p)
	for t in owner_touched {
		if t.p == op {
			return
		}
	}
	append(&owner_touched, Owner_Touch{op, db_size_of(p), owner_part_bytes(p), p.expires, owner_part_tables(p)})
}

owner_touch_db :: #force_inline proc(p: ^Db) {
	if p.role & DB_ROLE_OWNER != 0 {
		owner_touch(p)
	}
}

owner_settle :: proc() {
	for len(owner_touched) > 0 {
		t := pop(&owner_touched)
		owner_settle_part(t)
	}
}

owner_settle_part :: proc(t: Owner_Touch) {
	p := t.p
	d := owner_db(p)
	e := p.space.entry
	if d.t[0].cap == TABLE_MIN_CAP && table_lanes(&d.t[0]) == TABLE_MIN_CAP && d.rehash_idx < 0 {
		db_table_compact(d)
	}
	dk := db_size_of(d) - t.keys
	dbytes := owner_part_bytes(d) - t.bytes
	dtabs := owner_part_tables(d) - t.tabs
	e.keyspace.keys += dk
	e.keyspace.used += dbytes
	owner_keys_total += dk
	owner_expires_total += d.expires - t.exp
	owner_bytes_total += dbytes
	od := &owner_dbs[d.id]
	od.keys += dk
	od.tables += dtabs
	if dk != 0 {
		p.space.dup.valid = false
	}
	if db_size_of(d) == 0 {
		owner_part_release(p)
		return
	}
	owner_enroll(p)
}

owner_enroll :: proc(p: ^Owner_Part) {
	d := owner_db(p)
	if d.expires > 0 {
		owner_active_add(p, .Expire)
	}
	if d.hreg != nil {
		if d.hreg.len > 0 {
			owner_active_add(p, .Field)
		}
		if d.hreg.resize_head != nil {
			owner_active_add(p, .Hash_Resize)
		}
		if d.sctx.resize_head != nil {
			owner_active_add(p, .Set_Resize)
		}
		if d.zctx.resize_head != nil {
			owner_active_add(p, .Zset_Resize)
		}
	}
	if d.rehash_idx >= 0 {
		owner_active_add(p, .Rehash)
	}
	owner_sampler_note(p, .Keys)
	owner_sampler_note(p, .Expires)
}

owner_active_add :: proc(p: ^Owner_Part, k: Owner_Active) {
	if p.active[k] != 0 {
		return
	}
	before := cap(owner_active[k])
	append(&owner_active[k], p)
	owner_structs(nil, (cap(owner_active[k]) - before) * size_of(^Owner_Part))
	owner_slot_share(p.space.entry, size_of(^Owner_Part))
	p.active[k] = u32(len(owner_active[k]))
}

owner_active_drop :: proc(p: ^Owner_Part, k: Owner_Active) {
	at := int(p.active[k])
	if at == 0 {
		return
	}
	list := &owner_active[k]
	last := list[len(list) - 1]
	list[at - 1] = last
	last.active[k] = u32(at)
	pop(list)
	p.active[k] = 0
	owner_slot_share(p.space.entry, -size_of(^Owner_Part))
}

owner_bucket_of :: #force_inline proc "contextless" (w: int) -> u8 {
	return u8(63 - intrinsics.count_leading_zeros(u64(w)))
}

owner_weight :: #force_inline proc "contextless" (p: ^Owner_Part, k: Owner_Weight) -> int {
	if k == .Keys {
		return db_size_of(owner_db(p))
	}
	return p.db.expires
}

owner_sampler_remove :: proc(p: ^Owner_Part, k: Owner_Weight) {
	at := int(p.sample[k])
	if at == 0 {
		return
	}
	s := &owner_sampler[k]
	b := p.bucket[k]
	list := &s.bucket[b]
	last := list[len(list) - 1]
	list[at - 1] = last
	last.sample[k] = u32(at)
	pop(list)
	p.sample[k] = 0
	owner_slot_share(p.space.entry, -size_of(^Owner_Part))
	s.mass -= u64(1) << (b + 1)
}

owner_sampler_note :: proc(p: ^Owner_Part, k: Owner_Weight) {
	w := owner_weight(p, k)
	if w == 0 {
		owner_sampler_remove(p, k)
		return
	}
	b := owner_bucket_of(w)
	if p.sample[k] != 0 && p.bucket[k] == b {
		return
	}
	owner_sampler_remove(p, k)
	s := &owner_sampler[k]
	before := cap(s.bucket[b])
	append(&s.bucket[b], p)
	owner_structs(nil, (cap(s.bucket[b]) - before) * size_of(^Owner_Part))
	owner_slot_share(p.space.entry, size_of(^Owner_Part))
	p.sample[k] = u32(len(s.bucket[b]))
	p.bucket[k] = b
	s.mass += u64(1) << (b + 1)
}

owner_rand :: #force_inline proc "contextless" () -> u64 {
	owner_draw += 0x9E37_79B9_7F4A_7C15
	z := owner_draw
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

owner_sampler_pick :: proc(k: Owner_Weight) -> ^Owner_Part #no_bounds_check {
	s := &owner_sampler[k]
	if s.mass == 0 {
		return nil
	}
	for {
		r := owner_rand() % s.mass
		b := 0
		for b < OWNER_SAMPLE_BUCKETS {
			m := u64(len(s.bucket[b])) << u64(b + 1)
			if r < m {
				break
			}
			r -= m
			b += 1
		}
		if b >= OWNER_SAMPLE_BUCKETS {
			continue
		}
		p := s.bucket[b][int(r >> u64(b + 1))]
		if owner_rand() % (u64(1) << u64(b + 1)) < u64(owner_weight(p, k)) {
			return p
		}
	}
}

owner_stream_find :: proc(e: ^Owner_Entry, id: lb.Id) -> ^Label_Stream {
	ks := &e.keyspace
	if ks.stream.words.ready && ks.stream.label == id {
		return &ks.stream.words
	}
	if ks.streams != nil {
		for s in ks.streams {
			if s.label == id {
				return &s.words
			}
		}
	}
	return nil
}

owner_stream_seed :: proc(e: ^Owner_Entry, id: lb.Id, w: ^Label_Stream) {
	l, _ := access_label_of(id)
	base := lb.label_hash(l) ~ label_stream_secret ~ label_mix(owner_text_hash(e.text) + 0x51_7C_C1_B7_27_22_0A_95)
	w.main = label_mix(base + 1) | 1
	w.hash = label_mix(base + 2)
	w.list = label_mix(base + 3) | 1
	w.set = label_mix(base + 4)
	w.zset = label_mix(base + 5) | 1
	w.vset = label_mix(base + 6)
	w.ready = true
}

owner_stream_of :: proc(e: ^Owner_Entry, id: lb.Id) -> ^Label_Stream {
	if s := owner_stream_find(e, id); s != nil {
		return s
	}
	ks := &e.keyspace
	found: ^Owner_Stream
	if !ks.stream.words.ready {
		found = &ks.stream
	} else {
		if ks.streams == nil {
			ks.streams = new([dynamic]^Owner_Stream)
			owner_structs(e, size_of([dynamic]^Owner_Stream))
		}
		found = new(Owner_Stream)
		before := cap(ks.streams)
		append(ks.streams, found)
		owner_structs(e, (cap(ks.streams) - before) * size_of(^Owner_Stream) + size_of(Owner_Stream))
	}
	found.label = id
	owner_stream_seed(e, id, &found.words)
	return &found.words
}

owner_stream_lazy :: proc(e: ^Owner_Entry, id: lb.Id) -> ^Label_Stream {
	if s := owner_stream_find(e, id); s != nil {
		return s
	}
	owner_stream_seed(e, id, &owner_stream_pending)
	owner_stream_pending_seed = owner_stream_pending
	owner_stream_pending_entry = e
	owner_stream_pending_label = id
	return &owner_stream_pending
}

owner_stream_commit :: proc() {
	e := owner_stream_pending_entry
	if e == nil {
		return
	}
	owner_stream_pending_entry = nil
	if owner_stream_pending == owner_stream_pending_seed {
		return
	}
	s := owner_stream_of(e, owner_stream_pending_label)
	s^ = owner_stream_pending
}

owner_stream_current :: proc(e: ^Owner_Entry, id: lb.Id) -> ^Label_Stream {
	if owner_stream_cur != nil && owner_stream_cur_entry == e && owner_stream_cur_label == id {
		return owner_stream_cur
	}
	return owner_stream_of(e, id)
}

owner_stream_peek :: proc(e: ^Owner_Entry, id: lb.Id) -> ^Label_Stream {
	if s := owner_stream_find(e, id); s != nil {
		return s
	}
	owner_stream_seed(e, id, &owner_stream_probe)
	return &owner_stream_probe
}

owner_text_hash :: proc "contextless" (text: string) -> u64 {
	h: u64 = 0xCBF2_9CE4_8422_2325
	for i in 0 ..< len(text) {
		h = (h ~ u64(text[i])) * 0x0000_0100_0000_01B3
	}
	return h
}

owner_streams_drop :: proc(e: ^Owner_Entry) {
	ks := &e.keyspace
	if owner_stream_cur_entry == e {
		owner_stream_cur_entry = nil
	}
	if owner_stream_pending_entry == e {
		owner_stream_pending_entry = nil
		if owner_stream_cur == &owner_stream_pending {
			owner_stream_cur = &owner_stream_spare
		}
	}
	if owner_stream_cur == &ks.stream.words {
		owner_stream_cur = &owner_stream_spare
	}
	if ks.streams != nil {
		for s in ks.streams {
			if owner_stream_cur == &s.words {
				owner_stream_cur = &owner_stream_spare
			}
			owner_structs(e, -size_of(Owner_Stream))
			free(s)
		}
		owner_structs(e, -(cap(ks.streams) * size_of(^Owner_Stream) + size_of([dynamic]^Owner_Stream)))
		delete(ks.streams^)
		free(ks.streams)
		ks.streams = nil
	}
	ks.stream = {}
}

keyspace_owners_totals :: proc() -> Owner_Totals {
	return Owner_Totals{holding = i64(owner_holding), partitions = i64(owner_parts_total), bytes = i64(owner_bytes_total + owner_struct_bytes - owner_global_bytes + ow.table_entries_bytes(&owner_table))}
}

owner_best_own :: proc(s: ^Owner_Space, key: []u8, l: ^Lookup, skip: lb.Id, vis: ^lb.Visibility) -> (p: ^Db, t: ^Table, i: int) {
	if s == nil {
		return nil, nil, -1
	}
	if s.copies != nil && len(s.copies) > 0 {
		if cp, ok := s.copies[string(key)]; ok {
			floor: Label_Copy
			bounded := false
			for {
				best := -1
				for c, k in cp.copies {
					if c.label == skip || !lb.visible(vis, c.label) {
						continue
					}
					if bounded && !label_copy_better(floor, c) {
						continue
					}
					if best < 0 || label_copy_better(c, cp.copies[best]) {
						best = k
					}
				}
				if best < 0 {
					break
				}
				if q := owner_space_part(s, cp.copies[best].label); q != nil {
					tt, ii := db_locate_slot(owner_db(q), l)
					if ii >= 0 && label_slot_live(owner_db(q), tt, ii) {
						return owner_db(q), tt, ii
					}
				}
				floor = cp.copies[best]
				bounded = true
			}
			return nil, nil, -1
		}
	}
	for k in 0 ..< int(s.nparts) {
		q := owner_db(owner_space_at(s, k))
		if q.label == skip || db_size_of(q) == 0 || !lb.visible(vis, q.label) {
			continue
		}
		tt, ii := db_locate_slot(q, l)
		if ii >= 0 {
			if label_slot_live(q, tt, ii) {
				return q, tt, ii
			}
			return nil, nil, -1
		}
	}
	return nil, nil, -1
}

owner_locate_other :: proc(dbi: int, key: []u8, l: ^Lookup, reader: lb.Id, e: ^Owner_Entry, vis: ^lb.Visibility) -> (p: ^Db, t: ^Table, i: int) {
	if exact := label_part(dbi, reader); exact != nil && db_size_of(exact) > 0 {
		tt, ii := db_locate_slot(exact, l)
		if ii >= 0 && label_slot_live(exact, tt, ii) {
			return exact, tt, ii
		}
	}
	op, ot, oi := owner_best_own(owner_space_of(e, dbi), key, l, reader, vis)
	sp, sst, si := label_locate_other(dbi, key, l, reader, vis)
	if oi < 0 {
		return sp, sst, si
	}
	if si < 0 || access_compare(op.label, sp.label) >= 0 {
		return op, ot, oi
	}
	return sp, sst, si
}

@(cold)
owner_note_created :: #force_no_inline proc(db: ^Db, key: []u8) {
	p := owner_part_of(db)
	s := p.space
	e := s.entry
	s.own_gen += 1
	if s.copies != nil && len(s.copies) > 0 {
		if cp, ok := s.copies[string(key)]; ok {
			before := owner_copies_bytes(cp)
			append(&cp.copies, Label_Copy{db.label, label_next_seq()})
			owner_structs(e, owner_copies_bytes(cp) - before)
			return
		}
	}
	if s.nparts < 2 {
		return
	}
	l := lookup_make(key)
	for k in 0 ..< int(s.nparts) {
		q := owner_db(owner_space_at(s, k))
		if q == db || db_size_of(q) == 0 {
			continue
		}
		_, i := db_locate_slot(q, &l)
		if i < 0 {
			continue
		}
		if s.copies == nil {
			s.copies = new(map[string]^Label_Copies)
			owner_structs(e, owner_registry_bytes(s.copies))
		}
		cp := new(Label_Copies)
		cp.name = make([]u8, len(key))
		copy(cp.name, key)
		append(&cp.copies, Label_Copy{q.label, label_next_seq()})
		append(&cp.copies, Label_Copy{db.label, label_next_seq()})
		map_before := owner_registry_bytes(s.copies)
		s.copies[string(cp.name)] = cp
		owner_structs(e, owner_copies_bytes(cp) + owner_registry_bytes(s.copies) - map_before)
		return
	}
}

@(cold)
owner_note_erased :: #force_no_inline proc(db: ^Db, key: []u8) {
	p := owner_part_of(db)
	s := p.space
	s.own_gen += 1
	if s.copies == nil || len(s.copies) == 0 {
		return
	}
	cp, ok := s.copies[string(key)]
	if !ok {
		return
	}
	owner_copies_drop_label(s, cp, db.label)
}

owner_copies_drop_label :: proc(s: ^Owner_Space, cp: ^Label_Copies, label: lb.Id) -> bool {
	e := s.entry
	for c, k in cp.copies {
		if c.label == label {
			ordered_remove(&cp.copies, k)
			break
		}
	}
	if len(cp.copies) > 1 {
		return false
	}
	map_before := owner_registry_bytes(s.copies)
	owner_structs(e, -owner_copies_bytes(cp))
	delete_key(s.copies, string(cp.name))
	owner_structs(e, owner_registry_bytes(s.copies) - map_before)
	label_copies_free(cp)
	return true
}

owner_registry_purge :: proc(db: ^Db) {
	p := owner_part_of(db)
	s := p.space
	s.own_gen += 1
	if s.copies == nil || len(s.copies) == 0 {
		return
	}
	gone := make([dynamic]^Label_Copies, context.temp_allocator)
	for _, cp in s.copies {
		append(&gone, cp)
	}
	for cp in gone {
		owner_copies_drop_label(s, cp, db.label)
	}
}

owner_object_unbind :: proc(vp: ^Val_Handle) {
	obj := rawptr(vp.ref.addr)
	#partial switch vp.slab.info.type {
	case .Set:
		st.maintenance_cancel(st.Set(obj))
	case .Zset:
		zt.maintenance_cancel(zt.Zset(obj))
	case .Hash:
		ht.maintenance_cancel(ht.Hash(obj))
	}
}

owner_touch_take :: proc(p: ^Owner_Part) -> Owner_Touch {
	for t, i in owner_touched {
		if t.p == p {
			ordered_remove(&owner_touched, i)
			return t
		}
	}
	d := owner_db(p)
	return Owner_Touch{p, db_size_of(d), owner_part_bytes(d), d.expires, owner_part_tables(d)}
}

owner_part_flush :: proc(p: ^Owner_Part, lazy: bool, watch: bool) -> int {
	t := owner_touch_take(p)
	d := owner_db(p)
	n := db_size_of(d)
	if watch {
		watch_flush(d)
	}
	db_flush_in(d, lazy)
	owner_settle_part(t)
	return n
}

owner_flush :: proc(home: ^Db, all: bool, lazy: bool) -> i64 {
	removed: i64 = 0
	user := owner_user()
	everything := access.top && !user && !access.owner_named
	if everything {
		watch_flush_views(-1 if all else home.id)
	}
	if !user || everything {
		n := len(db_parts)
		for k in 0 ..< n {
			p := db_parts[k]
			if !all && p.id != home.id {
				continue
			}
			if !everything && !access.label_top && p.label != access.id {
				continue
			}
			removed += i64(db_size_of(p))
			if !everything {
				watch_flush(p)
			}
			db_flush_in(p, lazy)
			if !everything {
				label_tracking_flush(p.label)
			}
		}
	}
	doomed := make([dynamic]^Owner_Part, context.temp_allocator)
	if everything {
		for dbi in 0 ..< len(owner_dbs) {
			if !all && dbi != home.id {
				continue
			}
			for sp in owner_dbs[dbi].spaces {
				for k in 0 ..< int(sp.nparts) {
					append(&doomed, owner_space_at(sp, k))
				}
			}
		}
		for q in doomed {
			removed += i64(owner_part_flush(q, lazy, false))
		}
		tracking_flush()
		return removed
	}
	if !user || access.owner_entry == nil {
		return removed
	}
	e := access.owner_entry
	for dbi in 0 ..< len(owner_dbs) {
		if !all && dbi != home.id {
			continue
		}
		sp := owner_space_of(e, dbi)
		if sp == nil {
			continue
		}
		for k in 0 ..< int(sp.nparts) {
			q := owner_space_at(sp, k)
			if access.label_top || q.db.label == access.id {
				append(&doomed, q)
			}
		}
	}
	for q in doomed {
		label := q.db.label
		removed += i64(owner_part_flush(q, lazy, true))
		label_tracking_flush(label, e.number)
	}
	return removed
}

owner_swap :: proc(a, b: int) {
	if owner_dbs == nil {
		return
	}
	need := max(a, b)
	owner_db_ready(need)
	owner_dbs[a], owner_dbs[b] = owner_dbs[b], owner_dbs[a]
	for i in ([2]int{a, b}) {
		od := &owner_dbs[i]
		od.shared_gen += 1
		for sp in od.spaces {
			sp.dbi = i
			sp.dup.valid = false
			for k in 0 ..< int(sp.nparts) {
				owner_space_at(sp, k).db.id = i
			}
		}
	}
}

owner_active_expire :: proc(deadline: i64) -> bool {
	list := &owner_active[.Expire]
	budget := len(list)
	next := &owner_active_next[.Expire]
	for budget > 0 && len(list) > 0 {
		budget -= 1
		if next^ >= len(list) {
			next^ = 0
		}
		p := list[next^]
		if p.db.expires == 0 {
			p.db.avg_ttl = 0
			owner_active_drop(p, .Expire)
			continue
		}
		next^ += 1
		owner_touch(owner_db(p))
		db_expire_scan(owner_db(p), deadline)
		owner_settle()
		if now_ns() >= deadline {
			return true
		}
	}
	return false
}

owner_field_tick :: proc(deadline: i64, now: u64) {
	list := &owner_active[.Field]
	budget := len(list)
	next := &owner_active_next[.Field]
	for budget > 0 && len(list) > 0 && now_ns() < deadline {
		budget -= 1
		if next^ >= len(list) {
			next^ = 0
		}
		p := list[next^]
		d := owner_db(p)
		if ht.registry_len(d.hreg) == 0 {
			owner_active_drop(p, .Field)
			continue
		}
		next^ += 1
		if ht.registry_next_expire(d.hreg) > now {
			continue
		}
		owner_touch(d)
		hash_expire_partition(d, now)
		owner_settle()
	}
}

owner_resize_tick :: proc(k: Owner_Active, deadline: i64) {
	list := &owner_active[k]
	budget := len(list)
	next := &owner_active_next[k]
	for budget > 0 && len(list) > 0 && now_ns() < deadline {
		budget -= 1
		if next^ >= len(list) {
			next^ = 0
		}
		p := list[next^]
		d := owner_db(p)
		pending := false
		if d.hreg != nil {
			switch k {
			case .Hash_Resize:
				pending = d.hreg.resize_head != nil
			case .Set_Resize:
				pending = d.sctx.resize_head != nil
			case .Zset_Resize:
				pending = d.zctx.resize_head != nil
			case .Expire, .Field, .Rehash:
			}
		}
		if !pending {
			owner_active_drop(p, k)
			continue
		}
		next^ += 1
		owner_touch(d)
		for _ in 0 ..< 16 {
			done := false
			switch k {
			case .Hash_Resize:
				h, _ := ht.maintenance_step(d.hreg, ht.RESIZE_WRITE_SCANS, ht.RESIZE_WRITE_MOVES)
				if h == nil {
					done = true
				} else {
					hash_sync(d, h)
				}
			case .Set_Resize:
				h, _ := st.maintenance_step(d.sctx, st.RESIZE_WRITE_SCANS, st.RESIZE_WRITE_MOVES)
				if h == nil {
					done = true
				} else {
					set_sync(d, h)
				}
			case .Zset_Resize:
				h, _ := zt.maintenance_step(d.zctx, zt.RESIZE_WRITE_SCANS, zt.RESIZE_WRITE_MOVES)
				if h == nil {
					done = true
				} else {
					zset_sync(d, h)
				}
			case .Expire, .Field, .Rehash:
				done = true
			}
			if done || now_ns() >= deadline {
				break
			}
		}
		owner_settle()
	}
}

owner_scope_access :: proc(d: ^Db) -> vt.Access {
	e := owner_entry(d.owner)
	a := vt.Access{label = d.label, owner = vt.Owner(d.owner), visibility = access_visibility(d.label), table = &label_table}
	if e != nil {
		a.stream = &owner_stream_peek(e, d.label).vset
	}
	return a
}
