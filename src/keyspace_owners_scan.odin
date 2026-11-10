package main

import "base:intrinsics"
import lb "label"

OWNER_SCAN_PHASE :: u64(1)
OWNER_SCAN_ALIGN :: u64(1) << 17
OWNER_SCAN_ORD_MASK :: u64(0x7FFF)

owner_visible_parts: [dynamic]^Db
owner_visible_labels: [dynamic]lb.Id

owner_reader_space :: #force_inline proc(dbi: int) -> ^Owner_Space {
	return owner_space_of(access.owner_entry, dbi)
}

owner_visible_ever :: proc(sp: ^Owner_Space) -> []lb.Id {
	clear(&owner_visible_labels)
	for i in 0 ..< owner_ever_len(sp) {
		l := owner_ever_at(sp, i)
		if access_visible(l) {
			append(&owner_visible_labels, l)
		}
	}
	return owner_visible_labels[:]
}

owner_visible_own :: proc(sp: ^Owner_Space) -> []^Db {
	clear(&owner_visible_parts)
	for i in 0 ..< owner_ever_len(sp) {
		l := owner_ever_at(sp, i)
		if !access_visible(l) {
			continue
		}
		if q := owner_space_part(sp, l); q != nil {
			append(&owner_visible_parts, &q.db)
		}
	}
	return owner_visible_parts[:]
}

owner_own_resolve :: proc(sp: ^Owner_Space, name: []u8, l: ^Lookup) -> (p: ^Db, t: ^Table, i: int) {
	if q := owner_space_part(sp, access.id); q != nil && db_size_of(&q.db) > 0 {
		tt, ii := db_locate_slot(&q.db, l)
		if ii >= 0 && label_slot_live(&q.db, tt, ii) {
			return &q.db, tt, ii
		}
	}
	return owner_best_own(sp, name, l, access.id, access.vis)
}

owner_resolved_own :: proc(sp: ^Owner_Space, cp: ^Label_Copies, l: ^Lookup) -> lb.Id {
	p, _, i := owner_own_resolve(sp, cp.name, l)
	if i < 0 {
		return lb.ID_NONE
	}
	return p.label
}

owner_shadowed :: proc(sp: ^Owner_Space, p: ^Db, name: []u8) -> bool {
	if sp.copies == nil || len(sp.copies) == 0 {
		return false
	}
	cp, ok := sp.copies[string(name)]
	if !ok {
		return false
	}
	l := lookup_make(name)
	return owner_resolved_own(sp, cp, &l) != p.label
}

owner_has_live_own :: proc(sp: ^Owner_Space, name: []u8) -> bool {
	if sp == nil {
		return false
	}
	l := lookup_make(name)
	_, _, i := owner_best_own(sp, name, &l, lb.ID_NONE, access.vis)
	return i >= 0
}

owner_shared_hides :: proc(dbi: int, sp: ^Owner_Space, p: ^Db, name: []u8) -> bool {
	return label_shadowed(dbi, p, name) || owner_has_live_own(sp, name)
}

owner_own_counts :: proc(sp: ^Owner_Space) -> (keys, expires: int) {
	for p in owner_visible_own(sp) {
		keys += db_size_of(p)
		expires += p.expires
	}
	if sp.copies == nil {
		return
	}
	for _, cp in sp.copies {
		k := 0
		for c in cp.copies {
			if access_visible(c.label) {
				k += 1
			}
		}
		if k < 2 {
			continue
		}
		keys -= k - 1
		l := lookup_make(cp.name)
		resolved := owner_resolved_own(sp, cp, &l)
		for c in cp.copies {
			if c.label == resolved || !access_visible(c.label) {
				continue
			}
			q := owner_space_part(sp, c.label)
			if q == nil {
				continue
			}
			t, i := db_locate_slot(&q.db, &l)
			if i >= 0 && key_timed(t.slots[i].key) {
				expires -= 1
			}
		}
	}
	return
}

@(private = "file")
Owner_Side :: struct {
	live:  ^Db,
	ltab:  ^Table,
	lslot: int,
	count: int,
}

@(private = "file")
owner_side_timed :: proc(side: Owner_Side) -> int {
	if side.live == nil {
		return 0
	}
	return 1 if key_timed(side.ltab.slots[side.lslot].key) else 0
}

@(private = "file")
owner_cross :: proc(dbi: int, sp: ^Owner_Space, want_expires: bool) -> (cross, fix: int) {
	own := owner_visible_own(sp)
	ownc := make([]^Db, len(own), context.temp_allocator)
	copy(ownc, own)
	shared := label_visible_order(dbi)
	if len(shared) == 0 {
		return
	}
	sharedc := make([]^Db, len(shared), context.temp_allocator)
	copy(sharedc, shared)
	ld := &label_dbs[dbi]
	now := expire_now()
	for p, pi in ownc {
		if db_size_of(p) == 0 {
			continue
		}
		for k in 0 ..< 2 {
			if k == 1 && p.rehash_idx < 0 {
				break
			}
			t := &p.t[k]
			for g in 0 ..< t.groups {
				full := group_full(group_load(t.ctrl, g))
				for full != 0 {
					i := int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(full))
					full &= full - 1
					name := key_bytes(&t.slots[i].key, &p.slab)
					l := lookup_make(name)
					earlier := false
					for q in ownc[:pi] {
						if db_size_of(q) > 0 {
							if _, j := db_locate_slot(q, &l); j >= 0 {
								earlier = true
								break
							}
						}
					}
					if earlier {
						continue
					}
					sphys: ^Db
					stab: ^Table
					sslot := -1
					for q in sharedc {
						if db_size_of(q) == 0 {
							continue
						}
						if tt, j := db_locate_slot(q, &l); j >= 0 {
							sphys, stab, sslot = q, tt, j
							break
						}
					}
					if sphys == nil {
						continue
					}
					cross += 1
					if !want_expires {
						continue
					}
					x, y: Owner_Side
					x.live, x.ltab, x.lslot = owner_own_resolve(sp, name, &l)
					if x.lslot < 0 {
						x.live = nil
					}
					multi_own := sp.copies != nil && string(name) in sp.copies^
					c_o := owner_side_timed(x)
					if !multi_own {
						c_o = 1 if key_timed(t.slots[i].key) else 0
					}
					multi_shared := len(ld.copies) > 0 && string(name) in ld.copies
					if multi_shared {
						cp := ld.copies[string(name)]
						resolved := label_registry_resolved(dbi, cp, &l)
						if resolved != lb.ID_NONE {
							if q := label_part(dbi, resolved); q != nil {
								tt, j := db_locate_slot(q, &l)
								if j >= 0 {
									y.live, y.ltab, y.lslot = q, tt, j
								}
							}
						}
					} else {
						due := slot_deadline(sphys, stab, sslot) if sphys.expires > 0 else 0
						if due == 0 || due > now {
							y.live, y.ltab, y.lslot = sphys, stab, sslot
						}
					}
					c_s := owner_side_timed(y)
					if !multi_shared {
						c_s = 1 if key_timed(stab.slots[sslot].key) else 0
					}
					correct := 0
					switch {
					case x.live != nil && x.live.label == access.id:
						correct = owner_side_timed(x)
					case y.live != nil && y.live.label == access.id:
						correct = owner_side_timed(y)
					case x.live != nil && (y.live == nil || access_compare(x.live.label, y.live.label) >= 0):
						correct = owner_side_timed(x)
					case y.live != nil:
						correct = owner_side_timed(y)
					}
					fix += c_o + c_s - correct
				}
			}
		}
	}
	return
}

owner_dup_keys :: proc(dbi: int, sp: ^Owner_Space) -> int {
	gen := owner_dbs[dbi].shared_gen if dbi < len(owner_dbs) else 0
	d := &sp.dup
	if d.valid && d.reader == access.id && d.shared_gen == gen && d.own_gen == sp.own_gen {
		return d.keys
	}
	keys, _ := owner_own_counts(sp)
	cross, _ := owner_cross(dbi, sp, false)
	d^ = Owner_Dup {
		reader     = access.id,
		valid      = true,
		shared_gen = gen,
		own_gen    = sp.own_gen,
		keys       = keys - cross,
	}
	return d.keys
}

owner_dbsize :: proc(dbi: int) -> int {
	n := label_dbsize_shared(dbi)
	sp := owner_reader_space(dbi)
	if sp == nil {
		return n
	}
	return n + owner_dup_keys(dbi, sp)
}

owner_keyspace_line :: proc(dbi: int) -> (keys, expires: int, avg_ttl: i64, subexpiry: int) {
	keys, expires, avg_ttl, subexpiry = label_keyspace_line_shared(dbi)
	sp := owner_reader_space(dbi)
	if sp == nil {
		return
	}
	weighted := i128(avg_ttl) * i128(max(expires, 0))
	timed := 0
	for p in owner_visible_own(sp) {
		subexpiry += hash_subexpiry(p)
		weighted += i128(p.avg_ttl) * i128(p.expires)
		timed += p.expires
	}
	for p in label_visible_order(dbi) {
		timed += p.expires
	}
	_, oe := owner_own_counts(sp)
	keys += owner_dup_keys(dbi, sp)
	fix := 0
	if timed > 0 {
		_, fix = owner_cross(dbi, sp, true)
	}
	expires += oe - fix
	avg_ttl = 0
	if expires > 0 {
		avg_ttl = i64(weighted / i128(max(expires, 1)))
	}
	return
}

owner_keys :: proc(dbi: int, pat: []u8, all: bool) #no_bounds_check {
	clear(&key_scratch)
	now := srv.now_ms
	sp := owner_reader_space(dbi)
	if sp != nil {
		own := owner_visible_own(sp)
		ownc := make([]^Db, len(own), context.temp_allocator)
		copy(ownc, own)
		for p in ownc {
			owner_keys_part(p, pat, all, now, dbi, sp, true)
		}
	}
	for p in label_visible_order(dbi) {
		owner_keys_part(p, pat, all, now, dbi, sp, false)
	}
}

@(private = "file")
owner_keys_part :: proc(p: ^Db, pat: []u8, all: bool, now: i64, dbi: int, sp: ^Owner_Space, own: bool) #no_bounds_check {
	if db_size_of(p) == 0 {
		return
	}
	for k in 0 ..< 2 {
		if k == 1 && p.rehash_idx < 0 {
			break
		}
		t := &p.t[k]
		for g in 0 ..< t.groups {
			full := group_full(group_load(t.ctrl, g))
			for full != 0 {
				i := int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(full))
				full &= full - 1
				if p.expires > 0 {
					exp := slot_deadline(p, t, i)
					if exp != 0 && exp <= now {
						continue
					}
				}
				kb := key_bytes(&t.slots[i].key, &p.slab)
				if !all && !glob_match(pat, kb, false) {
					continue
				}
				if own {
					if owner_shadowed(sp, p, kb) {
						continue
					}
				} else if owner_shared_hides(dbi, sp, p, kb) {
					continue
				}
				append(&key_scratch, transmute(string)kb)
			}
		}
	}
}

@(private = "file")
Owner_Scan :: struct {
	using base: Label_Scan,
	sp:         ^Owner_Space,
	phase:      int,
}

@(private = "file")
owner_scan_offer :: proc(pass: ^Owner_Scan, t: ^Table, slot: int, name: []u8) {
	if pass.filtered && !glob_match(pass.pattern, name, false) {
		return
	}
	due := slot_deadline(pass.db, t, slot) if pass.db.expires > 0 else 0
	if due != 0 && due <= pass.now {
		if pass.own {
			append(&scan_expired, ..name)
			append(&scan_expired_ends, len(scan_expired))
		}
		return
	}
	if pass.phase == 0 {
		if owner_shadowed(pass.sp, pass.db, name) {
			return
		}
	} else if owner_shared_hides(pass.dbi, pass.sp, pass.db, name) {
		return
	}
	append(&key_scratch, transmute(string)name)
}

@(private = "file")
owner_scan_home :: proc(pass: ^Owner_Scan, t: ^Table, home: u64, lo: u64, hi: u64, open_end: bool) #no_bounds_check {
	group := home
	hop: u64
	for {
		ctrl := group_load(t.ctrl, group)
		occupied := group_full(ctrl)
		for occupied != 0 {
			slot := int(group << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(occupied))
			occupied &= occupied - 1
			name := key_bytes(&t.slots[slot].key, &pass.db.slab)
			h := hash_bytes(name)
			if hash_home(h, t.groups) != home || h < lo || (!open_end && h >= hi) {
				continue
			}
			pass.examined += 1
			owner_scan_offer(pass, t, slot, name)
		}
		if group_empty(ctrl) != 0 {
			return
		}
		group = probe_next(t, group, &hop)
	}
}

@(private = "file")
owner_scan_range :: proc(pass: ^Owner_Scan, t: ^Table, lo: u64, hi: u64, open_end: bool) {
	if t.groups == 0 || t.live == 0 {
		return
	}
	first := hash_home(lo, t.groups)
	last := t.groups - 1 if open_end else hash_home(hi - 1, t.groups)
	for g := first; g <= last; g += 1 {
		owner_scan_home(pass, t, g, lo, hi, open_end)
	}
}

@(private = "file")
owner_scan_round :: proc(pass: ^Owner_Scan, pos: u64) -> (next: u64, done: bool) {
	db := pass.db
	narrow := &db.t[0]
	if db.rehash_idx >= 0 && db.t[1].groups < narrow.groups {
		narrow = &db.t[1]
	}
	floor := group_floor(narrow.groups, hash_home(pos, narrow.groups) + 1)
	open_end := floor == 0
	if !open_end {
		next = (floor + OWNER_SCAN_ALIGN - 1) &~ (OWNER_SCAN_ALIGN - 1)
		if next == 0 {
			open_end = true
		}
	}
	owner_scan_range(pass, &db.t[0], pos, next, open_end)
	if db.rehash_idx >= 0 {
		owner_scan_range(pass, &db.t[1], pos, next, open_end)
	}
	return next, open_end
}

owner_scan :: proc(dbi: int, cursor: u64, count: i64, pat: []u8, has_pat: bool) -> u64 {
	clear(&scan_expired_ends)
	clear(&scan_expired)
	clear(&key_scratch)
	sp := owner_reader_space(dbi)
	ever := owner_visible_ever(sp) if sp != nil else nil
	everc := make([]lb.Id, len(ever), context.temp_allocator)
	copy(everc, ever)
	shared := label_visible_order(dbi)
	sharedc := make([]^Db, len(shared), context.temp_allocator)
	copy(sharedc, shared)
	phase := int(cursor & OWNER_SCAN_PHASE)
	ord := int((cursor >> LABEL_SCAN_POS_BITS) & OWNER_SCAN_ORD_MASK)
	pos := (cursor & LABEL_SCAN_POS_MASK &~ OWNER_SCAN_PHASE) << 16
	if phase == 0 && ord >= len(everc) {
		phase, ord, pos = 1, 0, 0
	}
	if phase == 1 && ord >= len(sharedc) {
		return 0
	}
	rounds := I64_MAX if count >= I64_MAX / 10 else count * 10
	examined: i64 = 0
	for {
		lim := len(everc) if phase == 0 else len(sharedc)
		if ord >= lim {
			if phase == 0 {
				phase, ord, pos = 1, 0, 0
				continue
			}
			return 0
		}
		p: ^Db
		if phase == 0 {
			if q := owner_space_part(sp, everc[ord]); q != nil {
				p = &q.db
			}
		} else {
			p = sharedc[ord]
		}
		finished := p == nil || db_size_of(p) == 0
		pass: Owner_Scan
		if p != nil {
			pass = Owner_Scan {
				base = Label_Scan{db = p, dbi = dbi, pattern = pat, filtered = has_pat, now = srv.now_ms, own = p == db_cur},
				sp = sp,
				phase = phase,
			}
		}
		for !finished && rounds > 0 {
			next, done := owner_scan_round(&pass, pos)
			rounds -= 1
			if done {
				finished = true
				break
			}
			pos = next
			if examined + pass.examined >= count {
				break
			}
		}
		examined += pass.examined
		if finished {
			ord += 1
			pos = 0
			lim = len(everc) if phase == 0 else len(sharedc)
			if ord >= lim {
				if phase == 0 {
					phase, ord = 1, 0
					if len(sharedc) == 0 {
						return 0
					}
				} else {
					return 0
				}
			}
		}
		if examined >= count || rounds <= 0 {
			break
		}
	}
	return (OWNER_SCAN_PHASE if phase == 1 else 0) | (u64(min(ord, int(OWNER_SCAN_ORD_MASK))) << LABEL_SCAN_POS_BITS) | (pos >> 16)
}

owner_random_designated :: proc(dbi: int, sp: ^Owner_Space, p: ^Db, name: []u8) -> bool {
	if p.role & DB_ROLE_OWNER != 0 {
		return !owner_shadowed(sp, p, name)
	}
	return !owner_shared_hides(dbi, sp, p, name)
}

owner_random_key :: proc(dbi: int) -> (key: string, ok: bool) #no_bounds_check {
	sp := owner_reader_space(dbi)
	parts := make([dynamic]^Db, context.temp_allocator)
	if sp != nil {
		for p in owner_visible_own(sp) {
			append(&parts, p)
		}
	}
	for p in label_visible_order(dbi) {
		append(&parts, p)
	}
	weights := make([]int, len(parts), context.temp_allocator)
	tries := LABEL_RANDOM_TRIES
	for tries > 0 {
		total := 0
		for p, k in parts {
			weights[k] = db_size_of(p)
			total += weights[k]
		}
		if total == 0 {
			return "", false
		}
		erased := false
		for tries > 0 {
			tries -= 1
			r := int(rng_next() % u64(total))
			k := 0
			for r >= weights[k] {
				r -= weights[k]
				k += 1
			}
			p := parts[k]
			t := &p.t[0]
			if p.rehash_idx >= 0 && int(rng_next() % u64(max(db_size_of(p), 1))) >= p.t[0].live {
				t = &p.t[1]
			}
			if t.live == 0 {
				continue
			}
			i := db_random_slot(t)
			if i < 0 {
				continue
			}
			name := key_bytes(&t.slots[i].key, &p.slab)
			if !label_slot_live(p, t, i) {
				if p == db_cur && !expiry_deletion_paused() {
					expired_key_copy(&t.slots[i].key, &p.slab)
					db_erase_expired(p, t, i)
					key_expired_event(expired_key_buf[:], p)
					erased = true
					break
				}
				continue
			}
			if !owner_random_designated(dbi, sp, p, name) {
				continue
			}
			return transmute(string)name, true
		}
		if !erased {
			break
		}
	}
	if key, ok = owner_random_scan(dbi, sp, parts[:], true); ok {
		return
	}
	if expiry_deletion_paused() {
		return owner_random_scan(dbi, sp, parts[:], false)
	}
	return "", false
}

owner_random_scan :: proc(dbi: int, sp: ^Owner_Space, parts: []^Db, live: bool) -> (key: string, ok: bool) #no_bounds_check {
	eligible := 0
	for pass in 0 ..< 2 {
		target := 0
		if pass == 1 {
			if eligible == 0 {
				return "", false
			}
			target = int(rng_next() % u64(eligible))
		}
		seen := 0
		for p in parts {
			for k in 0 ..< 2 {
				if k == 1 && p.rehash_idx < 0 {
					break
				}
				t := &p.t[k]
				for g in 0 ..< t.groups {
					full := group_full(group_load(t.ctrl, g))
					for full != 0 {
						i := int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(full))
						full &= full - 1
						if label_slot_live(p, t, i) != live {
							continue
						}
						name := key_bytes(&t.slots[i].key, &p.slab)
						if live && !owner_random_designated(dbi, sp, p, name) {
							continue
						}
						if pass == 1 && seen == target {
							return transmute(string)name, true
						}
						seen += 1
					}
				}
			}
		}
		eligible = seen
	}
	return "", false
}
