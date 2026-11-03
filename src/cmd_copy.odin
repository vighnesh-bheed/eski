package main

@(private = "file")
COPY_ERR_SAME :: "ERR source and destination objects are the same"

@(private = "file")
COPY_KEEP_BYTES :: 1 << 20

@(private = "file")
copy_text: [dynamic]u8

cmd_copy :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	target, replace, ok := copy_options(c, argv)
	if !ok {
		return
	}
	source := argv[1]
	destination := argv[2]
	if target == c.db && bytes_eq(source, destination) {
		reply_error(c, COPY_ERR_SAME)
		return
	}
	if db_find(source) == nil {
		reply_int(c, 0)
		return
	}
	if db_find_in(target, destination) != nil {
		if !replace {
			reply_int(c, 0)
			return
		}
		db_remove_in(target, destination)
		block_note_removed()
	}
	src := db_find_notouch(source)
	if src == nil {
		reply_int(c, 0)
		return
	}
	kind := entry_type(src)
	expire := src.expire_at
	encoding: Obj_Encoding
	obj: rawptr
	extra: u64
	if kind == .String {
		encoding = entry_obj_encoding(src)
		clear(&copy_text)
		append(&copy_text, ..src.val)
	} else {
		duplicated: bool
		obj, extra, duplicated = copy_object_dup(src)
		if !duplicated {
			reply_int(c, 0)
			return
		}
	}
	e, _ := db_upsert_timed_in(target, destination, expire)
	if kind == .String {
		entry_copy_string(e, copy_text[:], encoding)
	} else {
		copy_object_attach(e, destination, kind, obj, extra)
	}
	entry_set_expire(e, expire)
	copy_restart_clock(target, destination)
	signal_key_in(destination, target)
	notify_in(.Generic, "copy_to", destination, target)
	block_signal_existing(target, destination)
	pst.dirty += 1
	reply_int(c, 1)
	if cap(copy_text) > COPY_KEEP_BYTES {
		delete(copy_text)
		copy_text = nil
	}
}

@(private = "file")
copy_options :: proc(c: ^Conn, argv: [][]u8) -> (target: ^Db, replace: bool, ok: bool) {
	target = c.db
	i := 3
	for i < len(argv) {
		opt := argv[i]
		if eq_nocase(opt, "replace") {
			replace = true
		} else if eq_nocase(opt, "db") && i + 1 < len(argv) {
			id, parsed := parse_db_index(c, argv[i + 1], "")
			if !parsed {
				return
			}
			if !db_index_valid(id) {
				reply_error(c, ERR_DB_RANGE)
				return
			}
			target = &dbs[id]
			i += 1
		} else {
			reply_error(c, ERR_SYNTAX)
			return
		}
		i += 1
	}
	ok = true
	return
}

@(private = "file")
copy_restart_clock :: proc(db: ^Db, key: []u8) {
	saved := store_no_touch
	store_no_touch = true
	if e := db_find_in(db, key); e != nil {
		entry_access_init(e)
	}
	store_no_touch = saved
}
