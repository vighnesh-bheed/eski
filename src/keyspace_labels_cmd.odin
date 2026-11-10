package main

import lb "label"
import ow "owner"
import vt "vsettype"

ERR_LABEL_NO_KEY :: "ERR no such key"
ERR_LABEL_DECLASSIFY_DIRECTION :: "ERR the target label must be below the copy's label"
ERR_LABEL_VSET_ELEMENT :: "ERR name an element to relabel a vector set"
ERR_LABEL_NOT_VSET :: "ERR an element can only be named for a vector set"

label_key_subcommand :: proc(sub: []u8) -> string {
	switch {
	case eq_nocase(sub, "of"):
		return "label|of"
	case eq_nocase(sub, "declassify"):
		return "label|declassify"
	case eq_nocase(sub, "copies"):
		return "label|copies"
	case eq_nocase(sub, "quota"):
		return "label|quota"
	}
	return ""
}

label_key_command :: proc(c: ^Conn, argv: [][]u8) {
	sub := argv[1]
	switch {
	case eq_nocase(sub, "of"):
		label_cmd_of(c, argv)
	case eq_nocase(sub, "declassify"):
		label_cmd_declassify(c, argv)
	case eq_nocase(sub, "copies"):
		label_cmd_copies(c, argv)
	case eq_nocase(sub, "quota"):
		label_cmd_quota(c, argv)
	}
}

label_reply_id :: proc(c: ^Conn, id: lb.Id, o := ow.SHARED) {
	clear(&label_text)
	access_format(&label_text, id)
	scope_format(&label_text, ow.Scope{id, o})
	reply_bulk(c, label_text[:])
}

label_cmd_of :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) != 3 && len(argv) != 4 {
		reply_wrong_args(c, "label|of")
		return
	}
	e := db_find_read_notouch(argv[2])
	if e == nil {
		reply_null(c)
		return
	}
	if len(argv) == 3 {
		label_reply_id(c, e.db.label, e.db.owner)
		return
	}
	obj := entry_object(e, .Vectorset)
	if obj == nil {
		reply_wrongtype(c)
		return
	}
	s := cast(vt.Vset)obj
	a := label_vt_access()
	v, err := vt.view_open(s, &a, vset_scratch_get())
	if err != .None {
		reply_null(c)
		return
	}
	r, found := vt.view_find(&v, argv[3])
	if !found {
		reply_null(c)
		return
	}
	label_reply_id(c, vt.ref_label(s, r), ow.Owner(vt.ref_owner(s, r)))
}

Label_Target :: struct {
	id:      lb.Id,
	element: []u8,
	has:     bool,
}

label_parse_target :: proc(c: ^Conn, argv: [][]u8, from: int) -> (t: Label_Target, ok: bool) {
	if from >= len(argv) {
		reply_error(c, ERR_SYNTAX)
		return
	}
	marking := argv[from]
	trust: []u8
	has_trust := false
	i := from + 1
	for i < len(argv) {
		switch {
		case eq_nocase(argv[i], "trust") && i + 1 < len(argv) && !has_trust:
			trust = argv[i + 1]
			has_trust = true
			i += 2
		case eq_nocase(argv[i], "element") && i + 1 < len(argv) && !t.has:
			t.element = argv[i + 1]
			t.has = true
			i += 2
		case:
			reply_error(c, ERR_SYNTAX)
			return
		}
	}
	l, parsed := label_key_parse_label(marking, trust, has_trust)
	if !parsed || !lb.ceiling_admits(access_ceiling(c.user), l) {
		reply_error(c, ERR_LABEL_INVALID)
		return
	}
	id, interned := access_intern(l)
	if !interned {
		reply_error(c, ERR_LABEL_INVALID)
		return
	}
	t.id = id
	return t, true
}

label_cmd_declassify :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	if len(argv) < 4 {
		reply_wrong_args(c, "label|declassify")
		return
	}
	target, ok := label_parse_target(c, argv, 3)
	if !ok {
		return
	}
	key := argv[2]
	own := cur_db()
	from := access.id
	if target.id == from || !access_dominates(from, target.id) {
		reply_error(c, ERR_LABEL_DECLASSIFY_DIRECTION)
		return
	}
	if target.has {
		label_declassify_element(c, key, target)
		return
	}
	l := lookup_make(key)
	user := owner_user()
	if !label_live_in(own, &l) {
		other: ^Db
		i: int
		if user {
			other, _, i = owner_locate_other(own.id, key, &l, access.id, access.owner_entry, access.vis)
		} else {
			other, _, i = label_locate_other(own.id, key, &l, access.id, access.vis)
		}
		if i >= 0 {
			reply_error(c, label_in_use_text(ERR_LABEL_NAME_IN_USE, other.label, other.owner))
			return
		}
		reply_error(c, ERR_LABEL_NO_KEY)
		return
	}
	e := db_find_notouch(key)
	if e == nil {
		reply_error(c, ERR_LABEL_NO_KEY)
		return
	}
	if entry_type(e) == .Vectorset {
		reply_error(c, ERR_LABEL_VSET_ELEMENT)
		return
	}
	if seen, _, i := label_resolve(own.id, key, target.id, access_visibility(target.id), vset_scope_owner()); i >= 0 {
		reply_error(c, label_in_use_text(ERR_LABEL_NAME_IN_USE, seen.label, seen.owner))
		return
	}
	made, made_msg := label_scope_make(own.id, target.id)
	if made_msg != "" {
		reply_error(c, made_msg)
		return
	}
	if !db_move(own, made, key) {
		reply_error(c, ERR_LABEL_NO_KEY)
		return
	}
	pst.dirty += 1
	block_signal_existing(made, key)
	block_note_removed()
	signal_key_in(key, own)
	signal_key_in(key, made)
	notify_in(.Generic, "relabel_from", key, own)
	notify_in(.Generic, "relabel_to", key, made)
	label_audit_declassify(c, key, nil, from, target.id)
	reply_ok(c)
}

label_target_access :: proc(target: lb.Id, vis: ^lb.Visibility) -> vt.Access {
	if owner_user() && access.owner_entry != nil {
		return vt.Access{label = target, owner = vt.Owner(access.owner), visibility = vis, table = &label_table, stream = &owner_stream_of(access.owner_entry, target).vset}
	}
	return vt.Access{label = target, visibility = vis, table = &label_table, stream = &label_stream_of(target).vset}
}

label_scope_make :: proc(dbi: int, id: lb.Id) -> (^Db, string) {
	if owner_user() {
		if access.owner_entry == nil {
			return nil, ERR_OWNER_INVALID
		}
		p, ok := owner_part_make(access.owner_entry, dbi, id)
		if !ok {
			return nil, ERR_OWNER_PARTITIONS
		}
		owner_touch(&p.db)
		return &p.db, ""
	}
	p, ok := label_part_make(dbi, id)
	if !ok {
		return nil, ERR_LABEL_PARTITIONS
	}
	return p, ""
}

label_declassify_seen :: proc(s: vt.Vset, obj: rawptr, dbi: int, key: []u8, target: Label_Target) -> (msg: string, f: vt.Failure) {
	a := label_vt_access()
	v, err := vt.view_open(s, &a, vset_scratch_get())
	if err != .None {
		return "", vt.failure(err)
	}
	if r, found := vt.view_find(&v, target.element); !found || vt.ref_label(s, r) != access.id || ow.Owner(vt.ref_owner(s, r)) != vset_scope_owner() {
		return "", {}
	}
	vis := access_visibility(target.id)
	p, t, i := label_resolve(dbi, key, target.id, vis, vset_scope_owner())
	if i < 0 {
		return "", {}
	}
	if entry_object(db_view_slot(p, t, i), .Vectorset) != obj {
		return label_in_use_text(ERR_LABEL_NAME_IN_USE, p.label, p.owner), {}
	}
	at := label_target_access(target.id, vis)
	tv, terr := vt.view_open(s, &at, vset_scratch_get())
	if terr != .None {
		return "", vt.failure(terr)
	}
	if r, found := vt.view_find(&tv, target.element); found {
		return label_in_use_text(ERR_LABEL_ELEMENT_IN_USE, vt.ref_label(s, r), ow.Owner(vt.ref_owner(s, r))), {}
	}
	return "", {}
}

label_declassify_element :: proc(c: ^Conn, key: []u8, target: Label_Target) {
	e := db_find_notouch(key)
	if e == nil {
		reply_error(c, ERR_LABEL_NO_KEY)
		return
	}
	obj := entry_object(e, .Vectorset)
	if obj == nil {
		if label_entry_foreign(e) {
			reply_error(c, label_in_use_text(ERR_LABEL_NAME_IN_USE, e.db.label, e.db.owner))
		} else {
			reply_error(c, ERR_LABEL_NOT_VSET)
		}
		return
	}
	s := cast(vt.Vset)obj
	own := cur_db()
	dbi := own.id
	if msg, seen_failed := label_declassify_seen(s, obj, dbi, key, target); msg != "" || seen_failed.err != .None {
		if msg != "" {
			reply_error(c, msg)
		} else {
			vset_reply_failure(c, seen_failed)
		}
		return
	}
	made, made_msg := label_scope_make(dbi, target.id)
	if made_msg != "" {
		reply_error(c, made_msg)
		return
	}
	a := label_vt_access()
	to := a
	to.label = target.id
	to.stream = label_target_access(target.id, a.visibility).stream
	before := label_vset_take(s)
	from_gone, to_new, failed := vt.relabel_at(s, &a, &to, target.element, vset_scratch_get())
	if failed.err != .None {
		label_vset_settle(dbi, before, s)
		vset_reply_failure(c, failed)
		return
	}
	if to_new {
		fresh, _ := db_upsert_in(made, key)
		entry_object_attach(fresh, s, .Vectorset, .Raw, 0)
	}
	if from_gone {
		vset_presence_drop(own, key)
	}
	label_vset_settle(dbi, before, s)
	pst.dirty += 1
	signal_key_in(key, own)
	signal_key_in(key, made)
	notify_in(.Generic, "relabel_from", key, own)
	notify_in(.Generic, "relabel_to", key, made)
	label_audit_declassify(c, key, target.element, access.id, target.id)
	reply_ok(c)
}

label_cmd_copies :: proc(c: ^Conn, argv: [][]u8) {
	if !owners_on && len(argv) != 2 && len(argv) != 3 {
		reply_wrong_args(c, "label|copies")
		return
	}
	args := argv[2:]
	id: []u8
	scoped := false
	if owners_on && len(args) > 0 {
		switch {
		case eq_nocase(args[0], "shared"):
			args = args[1:]
		case eq_nocase(args[0], "owner") && len(args) >= 2:
			scoped = true
			id = args[1]
			args = args[2:]
		}
		if len(args) > 1 {
			reply_wrong_args(c, "label|copies")
			return
		}
	}
	if !access.top {
		reply_error(c, access_top_refusal())
		return
	}
	if scoped {
		if !ow.text_valid(id) {
			reply_error(c, ERR_OWNER_INVALID)
			return
		}
		label_copies_owner(c, owner_lookup(id), args)
		return
	}
	ld := &label_dbs[c.db.id]
	if len(args) == 0 {
		names := make([dynamic]string, context.temp_allocator)
		for name in ld.copies {
			append(&names, name)
		}
		label_reply_names(c, names[:])
		return
	}
	key := args[0]
	l := lookup_make(key)
	found := make([dynamic]^Db, context.temp_allocator)
	types := make([dynamic]Obj_Type, context.temp_allocator)
	for p in ld.order {
		if db_size_of(p) == 0 {
			continue
		}
		t, i := db_locate_slot(p, &l)
		if i < 0 || !label_slot_live(p, t, i) {
			continue
		}
		append(&found, p)
		append(&types, entry_type(db_view_slot(p, t, i)))
	}
	reply_array(c, len(found))
	for p, k in found {
		reply_array(c, 2)
		label_reply_id(c, p.label)
		reply_simple(c, type_name(types[k]))
	}
}

label_reply_names :: proc(c: ^Conn, names: []string) {
	for i in 1 ..< len(names) {
		x := names[i]
		j := i
		for j > 0 && x < names[j - 1] {
			names[j] = names[j - 1]
			j -= 1
		}
		names[j] = x
	}
	reply_array(c, len(names))
	for name in names {
		reply_bulk_str(c, name)
	}
}

label_copies_owner :: proc(c: ^Conn, e: ^Owner_Entry, args: [][]u8) {
	sp := owner_space_of(e, c.db.id)
	if len(args) == 0 {
		names := make([dynamic]string, context.temp_allocator)
		if sp != nil && sp.copies != nil {
			for name in sp.copies {
				append(&names, name)
			}
		}
		label_reply_names(c, names[:])
		return
	}
	l := lookup_make(args[0])
	found := make([dynamic]^Db, context.temp_allocator)
	types := make([dynamic]Obj_Type, context.temp_allocator)
	for i in 0 ..< owner_ever_len(sp) {
		q := owner_space_part(sp, owner_ever_at(sp, i))
		if q == nil || db_size_of(&q.db) == 0 {
			continue
		}
		t, j := db_locate_slot(&q.db, &l)
		if j < 0 || !label_slot_live(&q.db, t, j) {
			continue
		}
		append(&found, &q.db)
		append(&types, entry_type(db_view_slot(&q.db, t, j)))
	}
	reply_array(c, len(found))
	for p, k in found {
		reply_array(c, 2)
		label_reply_id(c, p.label, p.owner)
		reply_simple(c, type_name(types[k]))
	}
}

label_cmd_quota :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) < 3 {
		reply_wrong_args(c, "label|quota")
		return
	}
	if !access.top {
		reply_error(c, access_top_refusal())
		return
	}
	marking := argv[2]
	trust: []u8
	has_trust := false
	limit: i64 = -1
	i := 3
	for i < len(argv) {
		switch {
		case eq_nocase(argv[i], "trust") && i + 1 < len(argv) && !has_trust:
			trust = argv[i + 1]
			has_trust = true
			i += 2
		case eq_nocase(argv[i], "limit") && i + 1 < len(argv) && limit < 0:
			n, parsed := parse_i64(argv[i + 1])
			if !parsed || n < 0 {
				reply_error(c, ERR_NOT_INT)
				return
			}
			limit = n
			i += 2
		case:
			reply_error(c, ERR_SYNTAX)
			return
		}
	}
	l, parsed := label_key_parse_label(marking, trust, has_trust)
	if !parsed {
		reply_error(c, ERR_LABEL_INVALID)
		return
	}
	id, interned := access_intern(l)
	if !interned {
		reply_error(c, ERR_LABEL_INVALID)
		return
	}
	if limit >= 0 {
		if limit == 0 {
			delete_key(&label_quotas, id)
		} else {
			label_quotas[id] = int(limit)
		}
		label_audit(c, "label-quota", "label", string(marking), "limit", string(argv[len(argv) - 1]))
		reply_ok(c)
		return
	}
	reply_array(c, 2)
	reply_int(c, i64(label_quotas[id]) if id in label_quotas else 0)
	reply_int(c, i64(label_used(id)))
}

label_key_parse_label :: proc(marking: []u8, trust: []u8, has_trust: bool) -> (l: lb.Label, ok: bool) {
	parsed, f := lb.parse(&label_scheme, string(marking))
	if f.error != .None {
		return {}, false
	}
	if has_trust {
		for b in marking {
			if b == ';' {
				return {}, false
			}
		}
		t, found := lb.config_find_trust(&label_scheme, string(trust))
		if !found {
			return {}, false
		}
		parsed.trust = u8(t)
	}
	return parsed, true
}
