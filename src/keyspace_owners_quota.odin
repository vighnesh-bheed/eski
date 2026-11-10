package main

import ow "owner"

ERR_OWNER_QUOTA_OOM :: "OOM command not allowed when used memory > 'owner-quota'."

owner_quota_of :: #force_inline proc "contextless" (e: ^Owner_Entry) -> i64 {
	if e.keyspace.quota_set {
		return e.keyspace.quota
	}
	return owner_quota_default
}

owner_used_live :: proc(e: ^Owner_Entry) -> int {
	used := e.keyspace.used + ow.table_entry_bytes(&owner_table, e)
	for t in owner_touched {
		if t.p.space.entry == e {
			used += owner_part_bytes(&t.p.db) - t.bytes
		}
	}
	return used
}

owner_quota_check :: proc(cmd: ^Command, spec: ^Cmd_Spec, e: ^Owner_Entry) -> string {
	if e == nil || spec == nil || .Denyoom not_in spec.flags {
		return ""
	}
	quota := owner_quota_of(e)
	if quota <= 0 {
		return ""
	}
	used := owner_used_live(e)
	if i64(used) <= quota {
		return ""
	}
	evict_in_owner(e, quota)
	if i64(owner_used_live(e)) > quota {
		return ERR_OWNER_QUOTA_OOM
	}
	return ""
}

owner_parts_of :: proc(e: ^Owner_Entry, out: ^[dynamic]^Owner_Part) {
	clear(out)
	ks := &e.keyspace
	if ks.space != nil {
		for k in 0 ..< int(ks.space.nparts) {
			append(out, owner_space_at(ks.space, k))
		}
	}
	if ks.spaces != nil {
		for sp in ks.spaces {
			for k in 0 ..< int(sp.nparts) {
				append(out, owner_space_at(sp, k))
			}
		}
	}
}
