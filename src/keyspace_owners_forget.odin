package main

import "base:intrinsics"
import lb "label"
import ow "owner"
import vt "vsettype"

owner_live_keys :: proc(e: ^Owner_Entry) -> int {
	keys := e.keyspace.keys
	for t in owner_touched {
		if t.p.space.entry == e {
			keys += db_size_of(owner_db(t.p)) - t.keys
		}
	}
	return keys
}

owner_presences :: proc(d: ^Db, out: ^[dynamic]vt.Vset) {
	if d.heap_objs == 0 {
		return
	}
	for k in 0 ..< 2 {
		if k == 1 && d.rehash_idx < 0 {
			break
		}
		t := &d.t[k]
		for g in 0 ..< t.groups {
			full := group_full(group_load(t.ctrl, g))
			for full != 0 {
				i := int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(full))
				full &= full - 1
				if t.slots[i].key.small.tag.val_form == FORM_OBJECT && t.slots[i].val.slab.info.type == .Vectorset {
					s := vt.Vset(rawptr(t.slots[i].val.ref.addr))
					known := false
					for x in out {
						if x == s {
							known = true
							break
						}
					}
					if !known {
						append(out, s)
					}
				}
			}
		}
	}
}

owner_elements :: proc(e: ^Owner_Entry) -> int {
	parts := make([dynamic]^Owner_Part, context.temp_allocator)
	owner_parts_of(e, &parts)
	sets := make([dynamic]vt.Vset, context.temp_allocator)
	for q in parts {
		owner_presences(owner_db(q), &sets)
	}
	n := 0
	for s in sets {
		n += vt.owner_card(s, vt.Owner(e.number))
	}
	return n
}

owner_labels_used :: proc(e: ^Owner_Entry) -> int {
	parts := make([dynamic]^Owner_Part, context.temp_allocator)
	owner_parts_of(e, &parts)
	labels := make([dynamic]lb.Id, context.temp_allocator)
	for q in parts {
		known := false
		for l in labels {
			if l == q.db.label {
				known = true
				break
			}
		}
		if !known {
			append(&labels, q.db.label)
		}
	}
	return len(labels)
}

@(private = "file")
owner_forget_walk :: proc(d: ^Db, o: ow.Owner, events: bool) {
	for k in 0 ..< 2 {
		if k == 1 && d.rehash_idx < 0 {
			break
		}
		t := &d.t[k]
		for g in 0 ..< t.groups {
			full := group_full(group_load(t.ctrl, g))
			for full != 0 {
				i := int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(full))
				full &= full - 1
				kp := &t.slots[i].key
				vp := &t.slots[i].val
				if kp.small.tag.val_form == FORM_OBJECT && vp.slab.info.type == .Vectorset {
					kp.small.tag.val_form = FORM_NONE
					vp.bits &= u64(0xFF) << TALLY_SHIFT
					d.heap_objs -= 1
				}
				if events {
					notify_publish("del", key_bytes(kp, &d.slab), d.id, ow.Scope{d.label, o})
				}
			}
		}
	}
}

keyspace_owner_forget :: proc(e: ^Owner_Entry) -> Owner_Counts {
	counts: Owner_Counts
	if e == nil {
		return counts
	}
	o := e.number
	counts.bytes = i64(owner_used_live(e))
	counts.keys = i64(owner_live_keys(e))
	parts := make([dynamic]^Owner_Part, context.temp_allocator)
	owner_parts_of(e, &parts)
	events := .Generic in notify_active
	sets := make([dynamic]vt.Vset, context.temp_allocator)
	homes := make([dynamic]int, context.temp_allocator)
	for q in parts {
		had := len(sets)
		owner_presences(owner_db(q), &sets)
		for _ in had ..< len(sets) {
			append(&homes, q.db.id)
		}
	}
	for s, k in sets {
		if vt.owner_scope(s, vt.Owner(o)) == nil {
			continue
		}
		counts.elements += i64(vt.owner_card(s, vt.Owner(o)))
		before := label_vset_snapshot(s, o)
		vt.remove_owner(s, vt.Owner(o))
		if vt.card(s) == 0 {
			label_vset_settle(homes[k], before, nil)
			vt.destroy(s)
		} else {
			label_vset_settle(homes[k], before, s)
		}
	}
	for q in parts {
		if events || q.db.heap_objs > 0 {
			owner_forget_walk(owner_db(q), o, events)
		}
	}
	for q in parts {
		label := q.db.label
		owner_part_flush(q, true, true)
		label_tracking_flush(label, o)
	}
	for e.keyspace.space != nil {
		owner_space_drop(e.keyspace.space)
	}
	owner_streams_drop(e)
	if access.owner_entry == e {
		access.owner_entry = nil
	}
	e.keyspace = {}
	return counts
}

keyspace_owner_holds :: proc(e: ^Owner_Entry) -> bool {
	return owner_live_keys(e) > 0
}

keyspace_owner_info :: proc(e: ^Owner_Entry) -> Owner_Info {
	return Owner_Info {
		keys = i64(owner_live_keys(e)),
		elements = i64(owner_elements(e)),
		bytes = i64(owner_used_live(e)),
		partitions = i64(e.keyspace.parts),
		labels = i64(owner_labels_used(e)),
		quota = owner_quota_of(e),
	}
}

keyspace_owner_quota :: proc(e: ^Owner_Entry, set: bool, limit: i64) -> (quota: i64, used: i64) {
	if set {
		e.keyspace.quota = limit
		e.keyspace.quota_set = limit > 0
	}
	return owner_quota_of(e), i64(owner_used_live(e))
}
