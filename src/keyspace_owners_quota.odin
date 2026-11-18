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
	used := e.keyspace.used + ow.table_entry_bytes(&owner_table, e) + lua_owner_script_bytes(e.number) + search_owner_charges[e.number]
	for t in owner_touched {
		if t.p.space.entry == e {
			used += owner_part_bytes(owner_db(t.p)) - t.bytes
		}
	}
	return used
}

owner_quota_check :: proc(cmd: ^Command, spec: ^Cmd_Spec, argv: [][]u8, e: ^Owner_Entry) -> string {
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
	keys := db_size_of(db_cur)
	retained := owner_quota_expire(e, db_cur)
	if db_size_of(db_cur) != keys {
		if msg := label_write_check(cmd, spec, argv); msg != "" {
			return msg
		}
	}
	if i64(owner_used_live(e)) - retained <= quota {
		return ""
	}
	evict_in_owner(e, quota, retained)
	if i64(owner_used_live(e)) - retained > quota {
		return ERR_OWNER_QUOTA_OOM
	}
	return ""
}

owner_quota_expire :: proc(e: ^Owner_Entry, destination: ^Db) -> i64 {
	if aof.loading || pst.loading || expiry_deletion_paused() {
		return 0
	}
	now := expire_now()
	parts := make([dynamic]^Owner_Part, context.temp_allocator)
	owner_parts_of(e, &parts)
	retained: i64
	for p in parts {
		d := owner_db(p)
		expired := db_quota_expire(d, now)
		outer := lua_active != nil && d == lua_active.outer_db
		if (!expired && !(outer && lua_active.outer_db_expired)) || db_size_of(d) != 0 {
			continue
		}
		if outer {
			lua_active.outer_db_expired = true
		}
		if d != destination && !outer {
			owner_settle_part(owner_touch_take(p))
			continue
		}
		if owner_compact {
			owner_ctx_drop(d)
		}
		if d != destination {
			retained = size_of(Owner_Part) + (size_of(Owner_Ctx) if d.hreg != nil else 0)
		}
	}
	return retained
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
