package main

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"
import ht "hashtype"
import lb "label"
import lp "listpack"
import ow "owner"
import st "settype"
import vt "vsettype"
import zt "zsettype"

ERR_LABEL_NAME_IN_USE :: "INUSE name in use at "
ERR_LABEL_ELEMENT_IN_USE :: "INUSE element in use at "
ERR_LABEL_PARTITIONS :: "ERR label partition limit reached"
LABEL_ROLE_SENTINEL :: u8(1)
LABEL_ROLE_ORDERED :: u8(2)
LABEL_PARTITIONS_DEFAULT :: 1024
LABEL_WRITE_FLAGS :: Key_Flags{.Rw, .Ow, .Rm, .Insert, .Delete, .Update}

Label_Copy :: struct {
	label: lb.Id,
	seq:   u64,
}

Label_Copies :: struct {
	name:   []u8,
	copies: [dynamic]Label_Copy,
}

Label_Db :: struct {
	by_id:    [dynamic]^Db,
	order:    [dynamic]^Db,
	copies:   map[string]^Label_Copies,
	sentinel: ^Db,
}

Label_Stream :: struct {
	main:  u64,
	hash:  u64,
	list:  u64,
	set:   u64,
	zset:  u64,
	vset:  u64,
	ready: bool,
}

Vset_Charge :: struct {
	label: lb.Id,
	owner: ow.Owner,
	bytes: int,
}

Vset_Snap :: struct {
	charges: []Vset_Charge,
	global:  int,
	owner:   ow.Owner,
	shared:  bool,
}

label_dbs: []Label_Db
label_partitions: int
label_partitions_max: i64 = LABEL_PARTITIONS_DEFAULT
label_stream_seed: i64
label_active: bool
label_copy_seq: u64
label_streams: [dynamic]Label_Stream
label_stream_owner := -1
label_server_stream: Label_Stream
label_stream_secret: u64
label_refs: [dynamic]Key_Ref
label_text: [dynamic]u8
label_charges_before: [dynamic]Vset_Charge
label_charges_after: [dynamic]Vset_Charge
label_ids: [dynamic]lb.Id
label_cmd_writes: bool

keyspace_labels_enable :: proc() {
	if label_dbs != nil || len(dbs) == 0 {
		return
	}
	keyspace_fence()
	label_dbs = make([]Label_Db, len(dbs))
	for &ld, i in label_dbs {
		append(&ld.by_id, &dbs[i])
		dbs[i].label = lb.BOTTOM_ID
		ld.sentinel = label_db_new(i, lb.BOTTOM_ID)
		ld.sentinel.role = LABEL_ROLE_SENTINEL
		if db_size_of(&dbs[i]) > 0 {
			label_order_insert(&ld, &dbs[i])
		}
	}
	secret: [8]u8
	linux.getrandom(secret[:], {})
	label_stream_secret = (^u64)(&secret[0])^ ~ u64(srv.now_ms) * 0x9E37_79B9_7F4A_7C15
	if label_stream_seed != 0 {
		label_stream_secret = label_mix(u64(label_stream_seed))
	}
	label_stream_owner = -1
	tracking_bcast_settle()
	hooks_update()
}

label_db_new :: proc(id: int, label: lb.Id) -> ^Db {
	d := new(Db)
	d.hreg = new(ht.Registry)
	d.hreg.owner = d
	d.sctx = new(st.Context)
	d.sctx.owner = d
	d.zctx = new(zt.Context)
	d.zctx.owner = d
	db_part_init(d, id)
	d.label = label
	return d
}

label_part :: #force_inline proc "contextless" (dbi: int, id: lb.Id) -> ^Db {
	ld := &label_dbs[dbi]
	if int(id) < len(ld.by_id) {
		return ld.by_id[id]
	}
	return nil
}

label_part_make :: proc(dbi: int, id: lb.Id) -> (^Db, bool) {
	if p := label_part(dbi, id); p != nil {
		return p, true
	}
	if i64(label_partitions) >= label_partitions_max {
		return nil, false
	}
	ld := &label_dbs[dbi]
	if int(id) >= len(ld.by_id) {
		resize(&ld.by_id, int(id) + 1)
	}
	p := label_db_new(dbi, id)
	ld.by_id[id] = p
	append(&db_parts, p)
	label_partitions += 1
	return p, true
}

label_vt_order :: #force_inline proc "contextless" () -> vt.Access {
	return vt.Access{table = &label_table}
}

label_less :: proc "contextless" (x, y: lb.Id) -> bool {
	a := label_vt_order()
	return vt.label_order_less(&a, x, y)
}

label_order_insert :: proc(ld: ^Label_Db, p: ^Db) {
	p.role |= LABEL_ROLE_ORDERED
	at := len(ld.order)
	for q, i in ld.order {
		if label_less(p.label, q.label) {
			at = i
			break
		}
	}
	inject_at(&ld.order, at, p)
}

label_swap :: proc(a, b: int) {
	if label_dbs == nil || a == b {
		return
	}
	owner_swap(a, b)
	label_dbs[a], label_dbs[b] = label_dbs[b], label_dbs[a]
	for i in ([2]int{a, b}) {
		ld := &label_dbs[i]
		ld.by_id[0] = &dbs[i]
		ld.sentinel.id = i
		for p, k in ld.by_id {
			if p != nil && k > 0 {
				p.id = i
			}
		}
		for &p in ld.order {
			if p.label == lb.BOTTOM_ID {
				p = &dbs[i]
			}
		}
		dbs[i].label = lb.BOTTOM_ID
	}
}

label_stream_of :: proc(id: lb.Id) -> ^Label_Stream {
	if int(id) >= len(label_streams) {
		resize(&label_streams, int(id) + 1)
	}
	s := &label_streams[id]
	if !s.ready {
		l, _ := access_label_of(id)
		base := lb.label_hash(l) ~ label_stream_secret
		s.main = label_mix(base + 1) | 1
		s.hash = label_mix(base + 2)
		s.list = label_mix(base + 3) | 1
		s.set = label_mix(base + 4)
		s.zset = label_mix(base + 5) | 1
		s.vset = label_mix(base + 6)
		s.ready = true
	}
	return s
}

label_mix :: proc "contextless" (x: u64) -> u64 {
	z := x * 0x9E37_79B9_7F4A_7C15
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

label_stream_save :: proc() {
	dst := &label_server_stream
	if owner_stream_cur != nil {
		dst = owner_stream_cur
	} else if label_stream_owner >= 0 {
		dst = &label_streams[label_stream_owner]
	}
	dst.main = rng_state
	dst.hash = ht.random_state
	dst.list = lp.random_state
	dst.set = st.set_random_state
	dst.zset = zt.sl_rng
	dst.ready = true
}

label_stream_put :: proc(s: ^Label_Stream) {
	rng_state = s.main
	ht.random_state = s.hash
	lp.random_state = s.list
	st.set_random_state = s.set
	zt.sl_rng = s.zset
}

label_stream_leave_cur :: proc() {
	label_stream_save()
	if owner_stream_cur == &owner_stream_pending {
		owner_stream_commit()
	}
}

label_stream_load :: proc(id: lb.Id) {
	if owner_stream_cur == nil && label_stream_owner == int(id) {
		return
	}
	label_stream_leave_cur()
	s := label_stream_of(id)
	label_stream_put(s)
	label_stream_owner = int(id)
	owner_stream_cur = nil
	owner_stream_cur_entry = nil
}

owner_stream_load :: proc(e: ^Owner_Entry, id: lb.Id) {
	if owner_stream_cur != nil && owner_stream_cur_entry == e && owner_stream_cur_label == id {
		return
	}
	label_stream_leave_cur()
	s := owner_stream_lazy(e, id)
	label_stream_put(s)
	label_stream_owner = -2
	owner_stream_cur = s
	owner_stream_cur_entry = e
	owner_stream_cur_label = id
}

label_stream_server :: proc() {
	if label_stream_owner == -1 && owner_stream_cur == nil {
		return
	}
	label_stream_leave_cur()
	label_stream_put(&label_server_stream)
	label_stream_owner = -1
	owner_stream_cur = nil
	owner_stream_cur_entry = nil
}

label_vt_access :: proc() -> vt.Access {
	if owner_user() && access.owner_entry != nil {
		s := owner_stream_current(access.owner_entry, access.id)
		return vt.Access{label = access.id, owner = vt.Owner(access.owner), visibility = access.vis, table = &label_table, stream = &s.vset, top = access.top}
	}
	s := label_stream_of(access.id)
	return vt.Access{label = access.id, visibility = access.vis, table = &label_table, stream = &s.vset, top = access.top}
}

keyspace_label_enter :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8) -> string {
	if owner_user() && access.owner_entry != nil {
		owner_stream_load(access.owner_entry, access.id)
	} else {
		label_stream_load(access.id)
	}
	label_active = true
	if c.db == nil {
		return ""
	}
	return label_step(c.db, cmd, argv)
}

keyspace_label_leave :: proc() {
	label_active = false
	if owners_on {
		owner_settle()
	}
	label_stream_server()
}

label_command_writes :: #force_inline proc(cmd: ^Command, spec: ^Cmd_Spec) -> bool {
	return (spec != nil && .Write in spec.flags) || cmd.handler == cmd_debug
}

label_step :: proc(home: ^Db, cmd: ^Command, argv: [][]u8) -> string {
	dbi := home.id
	ld := &label_dbs[dbi]
	user := owner_user()
	own: ^Db
	if user {
		if op := owner_space_part(owner_space_of(access.owner_entry, dbi), access.id); op != nil {
			own = owner_db(op)
			owner_touch(own)
		}
	} else {
		own = label_part(dbi, access.id)
	}
	if own == nil {
		ld.sentinel.label = access.id
		ld.sentinel.owner = access.owner if user else ow.SHARED
		own = ld.sentinel
	}
	db_cur = own
	spec := cmd_spec_lookup(cmd, argv)
	writes := label_command_writes(cmd, spec)
	label_cmd_writes = writes
	if !writes {
		return ""
	}
	if owners_on && access.owner == ow.EVERY {
		return ERR_OWNER_INVALID
	}
	if spec != nil {
		if msg := label_write_check(cmd, spec, argv); msg != "" {
			return msg
		}
	}
	if own.role & LABEL_ROLE_SENTINEL != 0 {
		if user {
			if access.owner_entry == nil {
				return ERR_OWNER_INVALID
			}
			p, ok := owner_part_make(access.owner_entry, dbi, access.id)
			if !ok {
				return ERR_OWNER_PARTITIONS
			}
			db_cur = owner_db(p)
			owner_touch(db_cur)
		} else {
			p, ok := label_part_make(dbi, access.id)
			if !ok {
				return ERR_LABEL_PARTITIONS
			}
			db_cur = p
		}
	}
	if user {
		if msg := owner_quota_check(cmd, spec, access.owner_entry); msg != "" {
			return msg
		}
	} else if label_quota_active() {
		if msg := label_quota_check(cmd, spec); msg != "" {
			return msg
		}
	}
	return ""
}

label_write_check :: proc(cmd: ^Command, spec: ^Cmd_Spec, argv: [][]u8) -> string {
	if .Module in spec.flags {
		return ""
	}
	clear(&label_refs)
	find_keys(spec, argv, &label_refs)
	all_write := cmd.name == "xreadgroup"
	copying := cmd.handler == cmd_copy
	for ref in label_refs {
		if ref.pos <= 0 || ref.pos >= len(argv) {
			continue
		}
		if copying && ref.pos == 2 {
			continue
		}
		if !all_write && ref.flags != {} && ref.flags & LABEL_WRITE_FLAGS == {} {
			continue
		}
		if l, o, found := label_write_conflict(db_cur, argv[ref.pos]); found {
			if label_creates_only(cmd, argv, ref.pos) {
				continue
			}
			return label_in_use_text(ERR_LABEL_NAME_IN_USE, l, o)
		}
	}
	return ""
}

label_creates_only :: proc(cmd: ^Command, argv: [][]u8, pos: int) -> bool {
	h := cmd.handler
	switch {
	case h == cmd_setnx, h == cmd_msetnx:
		return true
	case h == cmd_renamenx:
		return pos == 2
	case h == cmd_set:
		return set_creates_only(argv)
	}
	return false
}

label_write_conflict :: proc(own: ^Db, key: []u8) -> (lb.Id, ow.Owner, bool) {
	l := lookup_make(key)
	if label_live_in(own, &l) {
		return lb.ID_NONE, ow.SHARED, false
	}
	p: ^Db
	i: int
	if owner_user() {
		p, _, i = owner_locate_other(own.id, key, &l, access.id, access.owner_entry, access.vis)
	} else {
		p, _, i = label_locate_other(own.id, key, &l, access.id, access.vis)
	}
	if i < 0 {
		return lb.ID_NONE, ow.SHARED, false
	}
	return p.label, p.owner, true
}

label_in_use_text :: proc(head: string, l: lb.Id, o := ow.SHARED) -> string {
	clear(&label_text)
	sb_str(&label_text, head)
	access_format(&label_text, l)
	scope_format(&label_text, ow.Scope{l, o})
	return string(label_text[:])
}

label_live_in :: proc(p: ^Db, l: ^Lookup) -> bool {
	if db_size_of(p) == 0 {
		return false
	}
	t, i := db_locate_slot(p, l)
	if i < 0 {
		return false
	}
	if p.expires > 0 {
		exp := slot_deadline(p, t, i)
		if exp != 0 && exp <= expire_now() {
			return false
		}
	}
	return true
}

label_slot_live :: #force_inline proc "contextless" (p: ^Db, t: ^Table, i: int) -> bool {
	if p.expires > 0 {
		exp := slot_deadline(p, t, i)
		return exp == 0 || exp > expire_now()
	}
	return true
}

label_copy_better :: proc "contextless" (a, b: Label_Copy) -> bool {
	r := access_compare(a.label, b.label)
	if r != 0 {
		return r > 0
	}
	return a.seq < b.seq
}

label_locate_other :: proc(dbi: int, key: []u8, l: ^Lookup, reader: lb.Id, vis: ^lb.Visibility) -> (p: ^Db, t: ^Table, i: int) {
	ld := &label_dbs[dbi]
	if len(ld.copies) > 0 {
		if cp, ok := ld.copies[string(key)]; ok {
			floor: Label_Copy
			bounded := false
			for {
				best := -1
				for c, k in cp.copies {
					if c.label == reader || !lb.visible(vis, c.label) {
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
				q := label_part(dbi, cp.copies[best].label)
				if q != nil {
					tt, ii := db_locate_slot(q, l)
					if ii >= 0 && label_slot_live(q, tt, ii) {
						return q, tt, ii
					}
				}
				floor = cp.copies[best]
				bounded = true
			}
			return nil, nil, -1
		}
	}
	for q in ld.order {
		if q.label == reader || db_size_of(q) == 0 || !lb.visible(vis, q.label) {
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

label_find_miss :: proc(db: ^Db, key: []u8, l: ^Lookup) -> ^Entry {
	if !label_active || db != db_cur {
		return nil
	}
	saved := store_no_touch
	store_no_touch = true
	defer store_no_touch = saved
	p: ^Db
	t: ^Table
	i: int
	if owner_user() {
		p, t, i = owner_locate_other(db.id, key, l, access.id, access.owner_entry, access.vis)
	} else {
		p, t, i = label_locate_other(db.id, key, l, access.id, access.vis)
	}
	if i < 0 {
		return nil
	}
	return db_view_slot(p, t, i)
}

label_scope_part :: proc(dbi: int, reader: lb.Id, o: ow.Owner) -> (own: ^Db, e: ^Owner_Entry) {
	if owners_on && ow.is_user(o) {
		e = owner_entry(o)
		if op := owner_space_part(owner_space_of(e, dbi), reader); op != nil {
			own = owner_db(op)
		}
		return
	}
	return label_part(dbi, reader), nil
}

label_scope_other :: proc(dbi: int, key: []u8, l: ^Lookup) -> (p: ^Db, t: ^Table, i: int) {
	if owner_user() {
		return owner_locate_other(dbi, key, l, access.id, access.owner_entry, access.vis)
	}
	return label_locate_other(dbi, key, l, access.id, access.vis)
}

label_scope_find :: proc(dbi: int) -> ^Db {
	own, _ := label_scope_part(dbi, access.id, vset_scope_owner())
	return own
}

label_resolve :: proc(dbi: int, key: []u8, reader: lb.Id, vis: ^lb.Visibility, o := ow.SHARED) -> (p: ^Db, t: ^Table, i: int) {
	l := lookup_make(key)
	own, e := label_scope_part(dbi, reader, o)
	if own != nil && db_size_of(own) > 0 {
		tt, ii := db_locate_slot(own, &l)
		if ii >= 0 && label_slot_live(own, tt, ii) {
			return own, tt, ii
		}
	}
	if owners_on && ow.is_user(o) {
		return owner_locate_other(dbi, key, &l, reader, e, vis)
	}
	return label_locate_other(dbi, key, &l, reader, vis)
}

label_key_state :: proc(dbi: int, key: []u8, reader: lb.Id, o := ow.SHARED) -> (exists: bool, expired: bool) {
	vis := access_visibility(reader)
	l := lookup_make(key)
	own_stale := false
	own, e := label_scope_part(dbi, reader, o)
	if own != nil && db_size_of(own) > 0 {
		t, i := db_locate_slot(own, &l)
		if i >= 0 {
			if label_slot_live(own, t, i) {
				return true, false
			}
			own_stale = true
		}
	}
	j: int
	if owners_on && ow.is_user(o) {
		_, _, j = owner_locate_other(dbi, key, &l, reader, e, vis)
	} else {
		_, _, j = label_locate_other(dbi, key, &l, reader, vis)
	}
	if j >= 0 {
		return true, false
	}
	return own_stale, own_stale
}

label_entry_foreign :: #force_inline proc "contextless" (e: ^Entry) -> bool {
	return labels_on && e.db != db_cur
}

label_next_seq :: #force_inline proc "contextless" () -> u64 {
	label_copy_seq += 1
	return label_copy_seq
}

label_note_created :: proc "contextless" (db: ^Db, key: []u8) {
	context = runtime.default_context()
	if db.role & LABEL_ROLE_SENTINEL != 0 {
		store_fatal("a labelled write reached the empty partition")
	}
	if label_dbs == nil {
		return
	}
	if db.role & DB_ROLE_OWNER != 0 {
		owner_note_created(db, key)
		return
	}
	if owners_on {
		owner_shared_changed(db.id)
	}
	ld := &label_dbs[db.id]
	if db.role & LABEL_ROLE_ORDERED == 0 {
		label_order_insert(ld, db)
	}
	if len(ld.copies) > 0 {
		if cp, ok := ld.copies[string(key)]; ok {
			append(&cp.copies, Label_Copy{db.label, label_next_seq()})
			return
		}
	}
	if len(ld.order) < 2 {
		return
	}
	l := lookup_make(key)
	for q in ld.order {
		if q == db || db_size_of(q) == 0 {
			continue
		}
		_, i := db_locate_slot(q, &l)
		if i >= 0 {
			cp := new(Label_Copies)
			cp.name = make([]u8, len(key))
			copy(cp.name, key)
			append(&cp.copies, Label_Copy{q.label, label_next_seq()})
			append(&cp.copies, Label_Copy{db.label, label_next_seq()})
			ld.copies[string(cp.name)] = cp
			return
		}
	}
}

label_note_erased :: proc "contextless" (db: ^Db, key: []u8) {
	if label_dbs == nil || db.role & LABEL_ROLE_SENTINEL != 0 {
		return
	}
	if db.role & DB_ROLE_OWNER != 0 {
		context = runtime.default_context()
		owner_note_erased(db, key)
		return
	}
	if owners_on {
		owner_shared_changed(db.id)
	}
	ld := &label_dbs[db.id]
	if len(ld.copies) == 0 {
		return
	}
	context = runtime.default_context()
	cp, ok := ld.copies[string(key)]
	if !ok {
		return
	}
	for c, k in cp.copies {
		if c.label == db.label {
			ordered_remove(&cp.copies, k)
			break
		}
	}
	if len(cp.copies) <= 1 {
		delete_key(&ld.copies, string(cp.name))
		label_copies_free(cp)
	}
}

label_copies_free :: proc(cp: ^Label_Copies) {
	delete(cp.copies)
	delete(cp.name)
	free(cp)
}

label_registry_purge :: proc(db: ^Db) {
	if db.role & DB_ROLE_OWNER != 0 {
		owner_registry_purge(db)
		return
	}
	if owners_on {
		owner_shared_changed(db.id)
	}
	ld := &label_dbs[db.id]
	if len(ld.copies) == 0 {
		return
	}
	gone := make([dynamic]string, context.temp_allocator)
	for name, cp in ld.copies {
		for c, k in cp.copies {
			if c.label == db.label {
				ordered_remove(&cp.copies, k)
				break
			}
		}
		if len(cp.copies) <= 1 {
			append(&gone, name)
		}
	}
	for name in gone {
		cp := ld.copies[name]
		delete_key(&ld.copies, name)
		label_copies_free(cp)
	}
}

label_flush_prepare :: proc(db: ^Db) {
	if label_dbs == nil || db.role & LABEL_ROLE_SENTINEL != 0 {
		return
	}
	label_registry_purge(db)
	if db.heap_objs == 0 {
		return
	}
	owned := db.role & DB_ROLE_OWNER != 0
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
				kp := &t.slots[i].key
				vp := &t.slots[i].val
				if kp.small.tag.val_form == FORM_OBJECT && vp.slab.info.type == .Vectorset {
					label_vset_detach(db, vp)
				} else if owned && kp.small.tag.val_form == FORM_OBJECT {
					owner_object_unbind(vp)
				}
			}
		}
	}
}

vset_scope_owner :: #force_inline proc "contextless" () -> ow.Owner {
	return access.owner if owner_user() else ow.SHARED
}

label_vset_charges :: proc(s: vt.Vset, out: ^[dynamic]Vset_Charge, o: ow.Owner, shared: bool) {
	clear(out)
	if s == nil {
		return
	}
	if shared {
		clear(&label_ids)
		vt.labels_present(s, &label_ids)
		if len(label_ids) > 0 {
			anchor := label_ids[0]
			for id in label_ids[1:] {
				if label_less(id, anchor) {
					anchor = id
				}
			}
			bytes_shared := vt.shared_memory(s)
			for id in label_ids {
				bytes := vt.label_memory(s, id)
				if id == anchor {
					bytes += bytes_shared
				}
				append(out, Vset_Charge{id, ow.SHARED, bytes})
			}
		}
	}
	if ow.is_user(o) {
		clear(&label_ids)
		vt.owner_labels(s, vt.Owner(o), &label_ids)
		for id in label_ids {
			append(out, Vset_Charge{id, o, vt.scope_memory(s, id, vt.Owner(o))})
		}
	}
}

label_vset_global :: proc(s: vt.Vset) -> int {
	if !owners_on || s == nil {
		return 0
	}
	n := vt.index_bytes(s)
	clear(&label_ids)
	vt.labels_present(s, &label_ids)
	if len(label_ids) == 0 {
		n += vt.shared_memory(s)
	}
	return n
}

label_vset_part :: proc(dbi: int, id: lb.Id, o: ow.Owner) -> ^Db {
	if ow.is_user(o) {
		if p := owner_space_part(owner_space_of(owner_entry(o), dbi), id); p != nil {
			owner_touch(owner_db(p))
			return owner_db(p)
		}
		return nil
	}
	return label_part(dbi, id)
}

label_vset_settle :: proc(dbi: int, before: Vset_Snap, s: vt.Vset) {
	label_vset_charges(s, &label_charges_after, before.owner, before.shared)
	for b in before.charges {
		after := 0
		for a in label_charges_after {
			if a.label == b.label && a.owner == b.owner {
				after = a.bytes
				break
			}
		}
		if after != b.bytes {
			if p := label_vset_part(dbi, b.label, b.owner); p != nil {
				object_account(p, after - b.bytes)
			}
		}
	}
	for a in label_charges_after {
		seen := false
		for b in before.charges {
			if b.label == a.label && b.owner == a.owner {
				seen = true
				break
			}
		}
		if !seen {
			if p := label_vset_part(dbi, a.label, a.owner); p != nil {
				object_account(p, a.bytes)
			}
		}
	}
	if owners_on {
		db_used_memory += label_vset_global(s) - before.global
	}
}

label_vset_take :: proc(s: vt.Vset) -> Vset_Snap {
	return label_vset_snapshot(s, vset_scope_owner())
}

label_vset_snapshot :: proc(s: vt.Vset, o: ow.Owner) -> Vset_Snap {
	shared := !ow.is_user(o) || !vt.labelled(s)
	label_vset_charges(s, &label_charges_before, o, shared)
	out := make([]Vset_Charge, len(label_charges_before), context.temp_allocator)
	copy(out, label_charges_before[:])
	return Vset_Snap{charges = out, global = label_vset_global(s), owner = o, shared = shared}
}

label_vset_none :: proc() -> Vset_Snap {
	o := vset_scope_owner()
	return Vset_Snap{owner = o, shared = !ow.is_user(o)}
}

label_vset_release :: proc "contextless" (db: ^Db, obj: rawptr) {
	context = runtime.default_context()
	s := vt.Vset(obj)
	o := db.owner if db.role & DB_ROLE_OWNER != 0 else ow.SHARED
	before := label_vset_snapshot(s, o)
	if ow.is_user(o) {
		vt.remove_scope(s, db.label, vt.Owner(o))
	} else {
		vt.remove_label(s, db.label)
	}
	if vt.card(s) == 0 {
		label_vset_settle(db.id, before, nil)
		vt.destroy(s)
		return
	}
	label_vset_settle(db.id, before, s)
}

label_vset_detach :: proc(db: ^Db, vp: ^Val_Handle) {
	s := vt.Vset(rawptr(vp.ref.addr))
	o := db.owner if db.role & DB_ROLE_OWNER != 0 else ow.SHARED
	others := false
	if ow.is_user(o) {
		others = vt.card(s) != vt.scope_card(s, db.label, vt.Owner(o))
	} else {
		clear(&label_ids)
		vt.labels_present(s, &label_ids)
		for id in label_ids {
			if id != db.label {
				others = true
			}
		}
		if owners_on && vt.owner_count(s) > 0 {
			others = true
		}
	}
	if !others {
		return
	}
	before := label_vset_snapshot(s, o)
	fresh: vt.Vset
	err: vt.Error
	if ow.is_user(o) {
		fresh, _, err = vt.split_scope(s, db.label, vt.Owner(o))
	} else {
		fresh, _, err = vt.split_label(s, db.label)
	}
	if err != .None || fresh == nil {
		return
	}
	label_vset_settle(db.id, before, s)
	if ow.is_user(o) {
		object_account(db, vt.scope_memory(fresh, db.label, vt.Owner(o)))
		db_used_memory += label_vset_global(fresh)
	} else {
		object_account(db, vt.memory_usage(fresh))
	}
	vp.ref.addr = uintptr(rawptr(fresh))
}

label_vset_detach_key :: proc(db: ^Db, key: []u8) {
	l := lookup_make(key)
	t, i := db_locate_slot(db, &l)
	if i < 0 {
		return
	}
	kp := &t.slots[i].key
	vp := &t.slots[i].val
	if kp.small.tag.val_form == FORM_OBJECT && vp.slab.info.type == .Vectorset {
		label_vset_detach(db, vp)
	}
}

label_copy_target :: proc(dbi: int, key: []u8, replace: bool) -> (target: ^Db, refusal: string, occupied: bool) {
	l := lookup_make(key)
	if owner_user() {
		e := access.owner_entry
		if e == nil {
			return nil, ERR_OWNER_INVALID, false
		}
		op := owner_space_part(owner_space_of(e, dbi), access.id)
		if op == nil || !label_live_in(owner_db(op), &l) {
			if other, _, i := owner_locate_other(dbi, key, &l, access.id, e, access.vis); i >= 0 {
				if !replace {
					return nil, "", true
				}
				return nil, label_in_use_text(ERR_LABEL_NAME_IN_USE, other.label, other.owner), false
			}
		}
		made, ok := owner_part_make(e, dbi, access.id)
		if !ok {
			return nil, ERR_OWNER_PARTITIONS, false
		}
		owner_touch(owner_db(made))
		return owner_db(made), "", false
	}
	own := label_part(dbi, access.id)
	if own == nil || !label_live_in(own, &l) {
		if other, _, i := label_locate_other(dbi, key, &l, access.id, access.vis); i >= 0 {
			if !replace {
				return nil, "", true
			}
			return nil, label_in_use_text(ERR_LABEL_NAME_IN_USE, other.label), false
		}
	}
	p, ok := label_part_make(dbi, access.id)
	if !ok {
		return nil, ERR_LABEL_PARTITIONS, false
	}
	return p, "", false
}

label_flush :: proc(home: ^Db, all: bool, lazy: bool) -> i64 {
	if owners_on {
		return owner_flush(home, all, lazy)
	}
	removed: i64 = 0
	n := len(db_parts)
	for k in 0 ..< n {
		p := db_parts[k]
		if !all && p.id != home.id {
			continue
		}
		if !access.top && p.label != access.id {
			continue
		}
		removed += i64(db_size_of(p))
		watch_flush(p)
		db_flush_in(p, lazy)
		if !access.top {
			label_tracking_flush(p.label)
		}
	}
	if access.top {
		tracking_flush()
	}
	return removed
}

label_block_scan_db :: proc(dbi: int) {
	for p in label_dbs[dbi].by_id {
		if p != nil {
			block_scan_ready(p)
		}
	}
}
