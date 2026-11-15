package main

import lb "label"
import ow "owner"

Access_Resume :: struct {
	label:       lb.Label,
	owner:       ow.Owner,
	owner_named: bool,
	operator:    bool,
}

access_resume_capture :: proc "contextless" () -> Access_Resume {
	return Access_Resume{label = access.label, owner = access.owner, owner_named = access.owner_named, operator = access.operator}
}

access_resume_operator :: proc() -> Access_Resume {
	return Access_Resume{label = access_scheme_top(), owner = ow.SHARED, operator = true}
}

access_resume_enter :: proc(s: Access_Resume) -> bool {
	if !labels_on || !lb.config_valid(&label_scheme, s.label) {
		return false
	}
	entry: ^Owner_Entry
	switch {
	case s.owner == ow.SHARED:
	case s.owner == ow.EVERY:
		if !owners_on || !s.operator {
			return false
		}
	case:
		if !owners_on {
			return false
		}
		entry = owner_entry(s.owner)
		if entry == nil {
			return false
		}
	}
	id, e := lb.table_intern(&label_table, s.label)
	if e != .None {
		return false
	}
	access.label = s.label
	access.id = id
	access.vis = access_visibility(id)
	access.label_top = lb.dominates(s.label, access_scheme_top())
	access.operator = s.operator
	access.top = access.label_top && (s.operator || !owners_on)
	access.ctx = nil
	access.owner = s.owner
	access.owner_named = s.owner_named
	access.owner_entry = entry
	if entry != nil {
		owner_stream_load(entry, id)
	} else {
		label_stream_load(id)
	}
	label_active = true
	return true
}

access_resume_partition :: proc(home: ^Db, writes: bool) -> (own: ^Db, refusal: string) {
	dbi := home.id
	user := owner_user()
	if user {
		if op := owner_space_part(owner_space_of(access.owner_entry, dbi), access.id); op != nil {
			own = owner_db(op)
			owner_touch(own)
		}
	} else {
		own = label_part(dbi, access.id)
	}
	label_cmd_writes = writes
	if own == nil && writes {
		if user {
			p, ok := owner_part_make(access.owner_entry, dbi, access.id)
			if !ok {
				return nil, ERR_OWNER_PARTITIONS
			}
			own = owner_db(p)
			owner_touch(own)
		} else {
			p, ok := label_part_make(dbi, access.id)
			if !ok {
				return nil, ERR_LABEL_PARTITIONS
			}
			own = p
		}
	}
	if own == nil {
		ld := &label_dbs[dbi]
		ld.sentinel.label = access.id
		ld.sentinel.owner = access.owner if user else ow.SHARED
		own = ld.sentinel
	}
	db_cur = own
	return own, ""
}

access_resume_leave :: proc() {
	keyspace_label_leave()
	access_reset_to_bottom()
}
