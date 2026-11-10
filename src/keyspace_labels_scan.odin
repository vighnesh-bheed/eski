package main

import "base:intrinsics"
import lb "label"

LABEL_SCAN_ALIGN :: u64(1) << 16
LABEL_SCAN_POS_BITS :: 48
LABEL_SCAN_POS_MASK :: (u64(1) << LABEL_SCAN_POS_BITS) - 1
LABEL_RANDOM_TRIES :: 100

label_visible_parts: [dynamic]^Db

label_visible_order :: proc(dbi: int) -> []^Db {
	clear(&label_visible_parts)
	for p in label_dbs[dbi].order {
		if access_visible(p.label) {
			append(&label_visible_parts, p)
		}
	}
	return label_visible_parts[:]
}

label_registry_resolved :: proc(dbi: int, cp: ^Label_Copies, l: ^Lookup) -> lb.Id {
	for c in cp.copies {
		if c.label == access.id {
			if p := label_part(dbi, c.label); p != nil {
				t, i := db_locate_slot(p, l)
				if i >= 0 && label_slot_live(p, t, i) {
					return c.label
				}
			}
		}
	}
	p, _, i := label_locate_other(dbi, cp.name, l, access.id, access.vis)
	if i < 0 {
		return lb.ID_NONE
	}
	return p.label
}

label_shadowed :: #force_inline proc(dbi: int, p: ^Db, name: []u8) -> bool {
	ld := &label_dbs[dbi]
	if len(ld.copies) == 0 {
		return false
	}
	cp, ok := ld.copies[string(name)]
	if !ok {
		return false
	}
	l := lookup_make(name)
	return label_registry_resolved(dbi, cp, &l) != p.label
}

label_dbsize :: proc(dbi: int) -> int {
	ld := &label_dbs[dbi]
	n := 0
	for p in ld.order {
		if access_visible(p.label) {
			n += db_size_of(p)
		}
	}
	for _, cp in ld.copies {
		k := 0
		for c in cp.copies {
			if access_visible(c.label) {
				k += 1
			}
		}
		if k > 1 {
			n -= k - 1
		}
	}
	return n
}

label_keyspace_line :: proc(dbi: int) -> (keys, expires: int, avg_ttl: i64, subexpiry: int) {
	ld := &label_dbs[dbi]
	weighted: i128 = 0
	for p in ld.order {
		if !access_visible(p.label) {
			continue
		}
		keys += db_size_of(p)
		expires += p.expires
		subexpiry += hash_subexpiry(p)
		weighted += i128(p.avg_ttl) * i128(p.expires)
	}
	for _, cp in ld.copies {
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
		resolved := label_registry_resolved(dbi, cp, &l)
		for c in cp.copies {
			if c.label == resolved || !access_visible(c.label) {
				continue
			}
			p := label_part(dbi, c.label)
			if p == nil {
				continue
			}
			t, i := db_locate_slot(p, &l)
			if i >= 0 && key_timed(t.slots[i].key) {
				expires -= 1
			}
		}
	}
	if expires > 0 {
		avg_ttl = i64(weighted / i128(max(expires, 1)))
	}
	return
}

label_keys :: proc(dbi: int, pat: []u8, all: bool) #no_bounds_check {
	clear(&key_scratch)
	now := srv.now_ms
	for p in label_visible_order(dbi) {
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
					if label_shadowed(dbi, p, kb) {
						continue
					}
					append(&key_scratch, transmute(string)kb)
				}
			}
		}
	}
}

Label_Scan :: struct {
	db:       ^Db,
	dbi:      int,
	pattern:  []u8,
	filtered: bool,
	now:      i64,
	examined: i64,
	own:      bool,
}

label_scan_offer :: proc(pass: ^Label_Scan, t: ^Table, slot: int, name: []u8) {
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
	if label_shadowed(pass.dbi, pass.db, name) {
		return
	}
	append(&key_scratch, transmute(string)name)
}

label_scan_home :: proc(pass: ^Label_Scan, t: ^Table, home: u64, lo: u64, hi: u64, open_end: bool) #no_bounds_check {
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
			label_scan_offer(pass, t, slot, name)
		}
		if group_empty(ctrl) != 0 {
			return
		}
		group = probe_next(t, group, &hop)
	}
}

label_scan_range :: proc(pass: ^Label_Scan, t: ^Table, lo: u64, hi: u64, open_end: bool) {
	if t.groups == 0 || t.live == 0 {
		return
	}
	first := hash_home(lo, t.groups)
	last := t.groups - 1 if open_end else hash_home(hi - 1, t.groups)
	for g := first; g <= last; g += 1 {
		label_scan_home(pass, t, g, lo, hi, open_end)
	}
}

label_scan_round :: proc(pass: ^Label_Scan, pos: u64) -> (next: u64, done: bool) {
	db := pass.db
	narrow := &db.t[0]
	if db.rehash_idx >= 0 && db.t[1].groups < narrow.groups {
		narrow = &db.t[1]
	}
	floor := group_floor(narrow.groups, hash_home(pos, narrow.groups) + 1)
	open_end := floor == 0
	if !open_end {
		next = (floor + LABEL_SCAN_ALIGN - 1) &~ (LABEL_SCAN_ALIGN - 1)
		if next == 0 {
			open_end = true
		}
	}
	label_scan_range(pass, &db.t[0], pos, next, open_end)
	if db.rehash_idx >= 0 {
		label_scan_range(pass, &db.t[1], pos, next, open_end)
	}
	return next, open_end
}

label_scan :: proc(dbi: int, cursor: u64, count: i64, pat: []u8, has_pat: bool) -> u64 {
	clear(&scan_expired_ends)
	clear(&scan_expired)
	clear(&key_scratch)
	parts := label_visible_order(dbi)
	ord := int(cursor >> LABEL_SCAN_POS_BITS)
	pos := (cursor & LABEL_SCAN_POS_MASK) << 16
	if ord >= len(parts) {
		return 0
	}
	rounds := I64_MAX if count >= I64_MAX / 10 else count * 10
	examined: i64 = 0
	for ord < len(parts) {
		p := parts[ord]
		pass := Label_Scan{db = p, dbi = dbi, pattern = pat, filtered = has_pat, now = srv.now_ms, own = p == db_cur}
		finished := db_size_of(p) == 0
		for !finished && rounds > 0 {
			next, done := label_scan_round(&pass, pos)
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
			if ord >= len(parts) {
				return 0
			}
		}
		if examined >= count || rounds <= 0 {
			break
		}
	}
	return u64(ord) << LABEL_SCAN_POS_BITS | (pos >> 16)
}

label_random_pick :: proc(dbi: int, parts: []^Db, weights: []int, total: int, tries: ^int) -> (key: string, ok: bool, erased: bool) {
	for tries^ > 0 {
		tries^ -= 1
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
				return "", false, true
			}
			continue
		}
		if label_shadowed(dbi, p, name) {
			continue
		}
		return transmute(string)name, true, false
	}
	return "", false, false
}

label_random_key :: proc(dbi: int) -> (key: string, ok: bool) #no_bounds_check {
	parts := label_visible_order(dbi)
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
		erased: bool
		key, ok, erased = label_random_pick(dbi, parts, weights, total, &tries)
		if ok {
			return
		}
		if !erased {
			break
		}
	}
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
						if !label_slot_live(p, t, i) {
							continue
						}
						name := key_bytes(&t.slots[i].key, &p.slab)
						if label_shadowed(dbi, p, name) {
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
