package main

import "base:runtime"
import ht "hashtype"

hash_registry_flush :: proc "contextless" (db: ^Db) {
	if db.hreg != nil {
		ht.registry_destroy(db.hreg)
	}
}

hash_rename :: proc(key: []u8) {
	e, h, wrong := hash_lookup(key, false)
	if wrong || h == nil || ht.key_ref(h) == nil {
		return
	}
	hash_key_ref_free(h)
	ht.set_key_ref(h, hash_key_ref_new(key, e.db.hreg))
	hash_done(e, h)
}

hash_move_registry :: proc "contextless" (h: ht.Hash, from: ^Db, to: ^Db) {
	hash_key_ref_move(ht.key_ref(h), to.hreg)
	ht.maintenance_bind(h, to.hreg)
	minimum := ht.registered_expire(h)
	if minimum == ht.DEADLINE_UNSET || from.hreg == to.hreg {
		return
	}
	ht.registry_remove(h)
	ht.registry_add(to.hreg, h, minimum)
}

hash_notify_lazy :: proc(key: []u8, read: ht.Field_Read) {
	if .Reaped not_in read {
		return
	}
	notify(.Hash, "hexpired", key)
	if .Emptied in read {
		notify(.Generic, "del", key)
	}
	signal_key_expired(key, cur_db())
}

hash_lazy :: proc(key: []u8, e: ^Entry, h: ht.Hash, read: ht.Field_Read) -> (deleted: bool) {
	if .Emptied in read {
		stat_expired_subkeys += 1
		owned := make([]u8, len(key))
		defer delete(owned)
		copy(owned, key)
		db_remove_in(e.db, owned)
		hash_notify_lazy(owned, read)
		return true
	}
	if .Reaped in read {
		stat_expired_subkeys += 1
		hash_sync(e.db, h)
		hash_notify_lazy(key, read)
	}
	return false
}

hash_expire_if_needed :: proc(key: []u8, e: ^Entry, h: ht.Hash) -> (deleted: bool) {
	if expiry_deletion_paused() {
		return false
	}
	before := ht.length(h)
	emptied := ht.expire_if_needed(h, hash_now())
	if emptied {
		stat_expired_subkeys += i64(before)
		owned := make([]u8, len(key))
		defer delete(owned)
		copy(owned, key)
		db_remove_in(e.db, owned)
		hash_notify_lazy(owned, {.Reaped, .Emptied})
		return true
	}
	removed := before - ht.length(h)
	if removed > 0 {
		stat_expired_subkeys += i64(removed)
		hash_done(e, h)
		hash_notify_lazy(key, {.Reaped})
	}
	return false
}

reply_ints :: proc(c: ^Conn, vals: []i64) {
	reply_array(c, len(vals))
	for value in vals {
		reply_int(c, value)
	}
}

reply_ints_repeat :: proc(c: ^Conn, v: i64, n: int) {
	reply_array(c, n)
	for _ in 0 ..< n {
		reply_int(c, v)
	}
}

hexpire_generic :: proc(c: ^Conn, argv: [][]u8, name: string, unit_seconds: bool, relative: bool) {
	pst.dirty_explicit = true
	key := argv[1]
	e, h, wrong := hash_lookup(key, false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	now := hash_now()
	base := u64(0)
	if relative {
		base = now
	}
	args, err := ht.parse_expire_args(argv, unit_seconds, base)
	if err != .None {
		if err == .Invalid_Expire_Time {
			message := make([dynamic]u8)
			defer delete(message)
			sb_str(&message, "ERR ")
			sb_str(&message, ht.ERR_INVALID_EXPIRE_TIME_PREFIX)
			sb_str(&message, name)
			sb_str(&message, ht.ERR_INVALID_EXPIRE_TIME_SUFFIX)
			reply_error(c, transmute(string)message[:])
		} else {
			reply_hash_error(c, err)
		}
		return
	}
	if h == nil {
		reply_ints_repeat(c, ht.EXPIRE_NO_FIELD, len(args.fields))
		return
	}
	ref := ht.key_ref(h)
	if ref == nil {
		ref = hash_key_ref_new(key, e.db.hreg)
	}
	clear(&hash_ints)
	empty := ht.expire_fields(e.db.hreg, ref, h, args.fields, args.expire_at, args.cond, now, &hash_ints)
	deleted, updated: int
	for result in hash_ints {
		if result == ht.EXPIRE_DELETED {
			deleted += 1
		} else if result == ht.EXPIRE_SET {
			updated += 1
		}
	}
	pst.dirty += i64(deleted + updated)
	stat_expired_subkeys += i64(deleted)
	hash_done(e, h)
	owned: []u8
	defer delete(owned)
	if empty {
		owned = make([]u8, len(key))
		copy(owned, key)
		key = owned
		db_remove_in(e.db, key)
	}
	if deleted > 0 || updated > 0 {
		signal_key(key)
		if deleted > 0 {
			notify(.Hash, "hdel", key)
		}
		if updated > 0 {
			notify(.Hash, "hexpire", key)
		}
		if empty {
			notify(.Generic, "del", key)
		}
	}
	reply_ints(c, hash_ints[:])
}

cmd_hexpire :: proc(c: ^Conn, argv: [][]u8) {
	hexpire_generic(c, argv, "hexpire", true, true)
}

cmd_hpexpire :: proc(c: ^Conn, argv: [][]u8) {
	hexpire_generic(c, argv, "hpexpire", false, true)
}

cmd_hexpireat :: proc(c: ^Conn, argv: [][]u8) {
	hexpire_generic(c, argv, "hexpireat", true, false)
}

cmd_hpexpireat :: proc(c: ^Conn, argv: [][]u8) {
	hexpire_generic(c, argv, "hpexpireat", false, false)
}

httl_generic :: proc(c: ^Conn, argv: [][]u8, kind: ht.Ttl_Kind) {
	_, h, wrong := hash_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	fields, err := ht.parse_fields_args(argv)
	if err != .None {
		reply_hash_error(c, err)
		return
	}
	if h == nil {
		reply_ints_repeat(c, ht.TTL_NO_FIELD, len(fields))
		return
	}
	clear(&hash_ints)
	ht.ttl_fields(h, fields, kind, hash_now(), &hash_ints)
	reply_ints(c, hash_ints[:])
}

cmd_httl :: proc(c: ^Conn, argv: [][]u8) {
	httl_generic(c, argv, .Ttl)
}

cmd_hpttl :: proc(c: ^Conn, argv: [][]u8) {
	httl_generic(c, argv, .Pttl)
}

cmd_hexpiretime :: proc(c: ^Conn, argv: [][]u8) {
	httl_generic(c, argv, .Expire_Time)
}

cmd_hpexpiretime :: proc(c: ^Conn, argv: [][]u8) {
	httl_generic(c, argv, .Pexpire_Time)
}

cmd_hpersist :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	e, h, wrong := hash_lookup(argv[1], false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	fields, err := ht.parse_fields_args(argv)
	if err != .None {
		reply_hash_error(c, err)
		return
	}
	if h == nil {
		reply_ints_repeat(c, ht.PERSIST_NO_FIELD, len(fields))
		return
	}
	clear(&hash_ints)
	if ht.persist_fields(h, fields, hash_now(), &hash_ints) {
		pst.dirty += 1
		hash_done(e, h)
		signal_key(argv[1])
		notify(.Hash, "hpersist", argv[1])
	}
	reply_ints(c, hash_ints[:])
}

hash_drop_emptied :: proc(db: ^Db, h: ht.Hash, key_ref: rawptr) {
	key := hash_key_ref_bytes(key_ref)
	e := db_find_in(db, key)
	if e == nil || entry_type(e) != .Hash || entry_object(e, .Hash) != rawptr(h) {
		return
	}
	owned := make([]u8, len(key))
	defer delete(owned)
	copy(owned, key)
	db_remove_in(db, owned)
	notify_in(.Hash, "hexpired", owned, db)
	notify_in(.Generic, "del", owned, db)
	signal_key_expired(owned, db)
}

hash_tick :: proc "contextless" () {
	context = runtime.default_context()
	if srv.now_ms < hash_tick_due {
		return
	}
	hash_tick_due = srv.now_ms + CRON_INTERVAL_MS
	if !expiry_sweep_on || expiry_deletion_paused() || len(dbs) == 0 {
		return
	}
	effort := cfg.active_expire_effort - 1
	deadline := now_ns() + EXPIRE_TICK_NS * (25 + 2 * effort) / 25
	now := hash_now()
	quiet := 0
	for quiet < len(dbs) && now_ns() < deadline {
		hash_db_next %= len(dbs)
		db := &dbs[hash_db_next]
		hash_db_next = (hash_db_next + 1) % len(dbs)
		if ht.registry_len(db.hreg) == 0 || ht.registry_next_expire(db.hreg) > now {
			quiet += 1
			continue
		}
		clear(&hash_expired)
		expired := ht.active_expire(db.hreg, now, FIELD_SWEEP_BATCH, &hash_expired)
		stat_expired_subkeys += i64(expired)
		for item in hash_expired {
			if item.emptied {
				hash_drop_emptied(db, item.h, item.key)
			} else {
				hash_sync(db, item.h)
				key := hash_key_ref_bytes(item.key)
				notify_in(.Hash, "hexpired", key, db)
				signal_key_expired(key, db)
			}
		}
		quiet = 0 if expired == FIELD_SWEEP_BATCH else quiet + 1
	}
}
