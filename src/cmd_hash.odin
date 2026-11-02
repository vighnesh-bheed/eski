package main

import ht "hashtype"

hset_generic :: proc(c: ^Conn, argv: [][]u8, name: string) {
	pst.dirty_explicit = true
	if len(argv) < 4 || len(argv) % 2 != 0 {
		reply_wrong_args(c, name)
		return
	}
	key := argv[1]
	e, h, wrong := hash_lookup_create(key)
	if wrong {
		reply_wrongtype(c)
		return
	}
	created := ht.hset(h, argv[2:])
	pst.dirty += i64((len(argv) - 2) / 2)
	hash_done(e, h)
	signal_key(key)
	notify(.Hash, "hset", key)
	if name == "hmset" {
		reply_ok(c)
	} else {
		reply_int(c, i64(created))
	}
}

cmd_hset :: proc(c: ^Conn, argv: [][]u8) {
	hset_generic(c, argv, "hset")
}

cmd_hmset :: proc(c: ^Conn, argv: [][]u8) {
	hset_generic(c, argv, "hmset")
}

cmd_hsetnx :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	key := argv[1]
	e, h, wrong := hash_lookup_create(key)
	if wrong {
		reply_wrongtype(c)
		return
	}
	_, res := ht.get(h, argv[2], hash_now())
	if res == .Ok {
		reply_int(c, 0)
		return
	}
	if res == .Expired || res == .Expired_Hash {
		stat_expired_subkeys += 1
		if res == .Expired_Hash {
			hash_reset(e, h)
		}
		hash_notify_lazy(key, res)
		if res == .Expired_Hash {
			notify(.New, "new", key)
		}
	}
	ht.set(h, argv[2], argv[3])
	pst.dirty += 1
	hash_done(e, h)
	signal_key(key)
	notify(.Hash, "hset", key)
	reply_int(c, 1)
}

cmd_hget :: proc(c: ^Conn, argv: [][]u8) {
	key := argv[1]
	e, h, wrong := hash_lookup(key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if h == nil {
		reply_null(c)
		return
	}
	v, res := ht.get(h, argv[2], hash_now(), !expiry_deletion_paused())
	if res == .Ok {
		reply_hash_value(c, v)
	} else {
		reply_null(c)
		hash_lazy(key, e, h, res)
	}
}

cmd_hmget :: proc(c: ^Conn, argv: [][]u8) {
	key := argv[1]
	_, h, wrong := hash_lookup(key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	reply_array(c, len(argv) - 2)
	if h == nil {
		for _ in argv[2:] {
			reply_null(c)
		}
		return
	}
	changed := false
	empty := false
	notify_expired := false
	now := hash_now()
	for field in argv[2:] {
		if empty {
			reply_null(c)
			continue
		}
		v, res := ht.get(h, field, now, !expiry_deletion_paused())
		if res == .Ok {
			reply_hash_value(c, v)
		} else {
			reply_null(c)
			if res == .Expired || res == .Expired_Hash {
				stat_expired_subkeys += 1
				signal_key_expired(key, cur_db())
				changed = true
				empty = res == .Expired_Hash
				notify_expired = notify_expired || res == .Expired
			}
		}
	}
	if changed {
		if empty {
			db_remove(key)
		} else {
			hash_sync(cur_db(), h)
		}
		if notify_expired {
			notify(.Hash, "hexpired", key)
			if empty {
				notify(.Generic, "del", key)
			}
		}
	}
}

hgetall_generic :: proc(c: ^Conn, argv: [][]u8, keys, vals: bool) {
	_, h, wrong := hash_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	n := 0
	now := hash_now()
	if h != nil {
		n = ht.length_live(h, now)
	}
	if keys && vals {
		reply_map(c, n)
	} else {
		reply_array(c, n)
	}
	if h == nil {
		return
	}
	it := ht.iterator_live(h, now)
	for ht.next(&it) {
		if keys {
			reply_hash_value(c, ht.current_field(&it))
		}
		if vals {
			reply_hash_value(c, ht.current_value(&it))
		}
	}
}

cmd_hgetall :: proc(c: ^Conn, argv: [][]u8) {
	hgetall_generic(c, argv, true, true)
}

cmd_hkeys :: proc(c: ^Conn, argv: [][]u8) {
	hgetall_generic(c, argv, true, false)
}

cmd_hvals :: proc(c: ^Conn, argv: [][]u8) {
	hgetall_generic(c, argv, false, true)
}

cmd_hlen :: proc(c: ^Conn, argv: [][]u8) {
	_, h, wrong := hash_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	reply_int(c, i64(ht.length(h)))
}

cmd_hexists :: proc(c: ^Conn, argv: [][]u8) {
	key := argv[1]
	e, h, wrong := hash_lookup(key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if h == nil {
		reply_int(c, 0)
		return
	}
	found, res := ht.exists(h, argv[2], hash_now(), !expiry_deletion_paused())
	reply_int(c, i64(found))
	hash_lazy(key, e, h, res)
}

cmd_hstrlen :: proc(c: ^Conn, argv: [][]u8) {
	key := argv[1]
	e, h, wrong := hash_lookup(key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if h == nil {
		reply_int(c, 0)
		return
	}
	n, res := ht.field_strlen(h, argv[2], hash_now(), !expiry_deletion_paused())
	reply_int(c, i64(n))
	hash_lazy(key, e, h, res)
}

cmd_hdel :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	key := argv[1]
	e, h, wrong := hash_lookup(key, false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if h == nil {
		reply_int(c, 0)
		return
	}
	n, empty := ht.hdel(h, argv[2:])
	pst.dirty += i64(n)
	if n > 0 {
		hash_done(e, h)
		if empty {
			db_remove(key)
		}
		signal_key(key)
		notify(.Hash, "hdel", key)
		if empty {
			notify(.Generic, "del", key)
		}
	}
	reply_int(c, i64(n))
}

hash_incr_prepare :: proc(c: ^Conn, key: []u8, field: []u8) -> (e: ^Entry, h: ht.Hash, ok: bool) {
	wrong: bool
	e, h, wrong = hash_lookup_create(key)
	if wrong {
		reply_wrongtype(c)
		return nil, nil, false
	}
	_, res := ht.get(h, field, hash_now())
	if res == .Expired || res == .Expired_Hash {
		stat_expired_subkeys += 1
		if res == .Expired_Hash {
			hash_reset(e, h)
		}
		hash_notify_lazy(key, res)
		if res == .Expired_Hash {
			notify(.New, "new", key)
		}
	}
	return e, h, true
}

cmd_hincrby :: proc(c: ^Conn, argv: [][]u8) {
	incr, err := ht.parse_incrby_increment(argv[3])
	if err != .None {
		reply_hash_error(c, err)
		return
	}
	key := argv[1]
	e, h, ok := hash_incr_prepare(c, key, argv[2])
	if !ok {
		return
	}
	result, incr_err := ht.incrby(h, argv[2], incr, hash_now())
	if incr_err != .None {
		reply_hash_error(c, incr_err)
		return
	}
	hash_done(e, h)
	signal_key(key)
	notify(.Hash, "hincrby", key)
	reply_int(c, result)
}

cmd_hincrbyfloat :: proc(c: ^Conn, argv: [][]u8) {
	incr, err := ht.parse_incrbyfloat_increment(argv[3])
	if err != .None {
		reply_hash_error(c, err)
		return
	}
	key := argv[1]
	e, h, ok := hash_incr_prepare(c, key, argv[2])
	if !ok {
		return
	}
	result, incr_err := ht.incrbyfloat(h, argv[2], incr, hash_ldbuf[:], hash_now())
	if incr_err != .None {
		reply_hash_error(c, incr_err)
		return
	}
	hash_done(e, h)
	signal_key(key)
	notify(.Hash, "hincrbyfloat", key)
	reply_bulk(c, result)
}

reply_random_pairs :: proc(c: ^Conn, with_values: bool) {
	for field, i in hash_fields {
		if with_values && c.resp == 3 {
			reply_array(c, 2)
		}
		reply_hash_value(c, field)
		if with_values {
			reply_hash_value(c, hash_values[i])
		}
	}
}

@(private = "file")
hrandfield_keep_streaming :: proc(c: ^Conn) -> bool {
	if !lua_capture_allow(c, 0) {
		return false
	}
	over := c.fd >= 0 && obuf_normal_limited && .Subscribed not_in c.ps && obuf_class_over(c, .Normal, &c.obuf_soft)
	if over {
		c.close_after = true
	}
	return !over
}

@(private = "file")
hrandfield_page :: proc(c: ^Conn, h: ht.Hash, size: int, with_values: bool) {
	clear(&hash_fields)
	clear(&hash_values)
	ht.random_with_repeats(h, size, with_values, &hash_fields, &hash_values)
	reply_random_pairs(c, with_values)
}

@(private = "file")
hrandfield_counted :: proc(c: ^Conn, key: []u8, count: i64, with_values: bool) {
	e, h, wrong := hash_lookup(key, true)
	switch {
	case wrong:
		reply_wrongtype(c)
		return
	case h == nil || hash_expire_if_needed(key, e, h):
		reply_array(c, 0)
		return
	}
	defer {
		clear(&hash_fields)
		clear(&hash_values)
	}
	per_pick := 2 if with_values && c.resp != 3 else 1
	if count >= 0 {
		wanted := min(count, i64(ht.length(h)))
		reply_array(c, int(wanted) * per_pick)
		if wanted > 0 {
			clear(&hash_fields)
			clear(&hash_values)
			ht.random_unique(h, int(wanted), with_values, &hash_fields, &hash_values)
			reply_random_pairs(c, with_values)
		}
		return
	}
	picks := -count
	reply_array(c, int(picks) * per_pick)
	pages := (picks - 1) / ht.RANDOM_PICK_BATCH + 1
	tail := int(picks - (pages - 1) * ht.RANDOM_PICK_BATCH)
	for page in 1 ..= pages {
		hrandfield_page(c, h, ht.RANDOM_PICK_BATCH if page < pages else tail, with_values)
		if !hrandfield_keep_streaming(c) {
			break
		}
	}
}

cmd_hrandfield :: proc(c: ^Conn, argv: [][]u8) {
	args, err := ht.parse_hrandfield_args(argv[2:])
	if err != .None {
		reply_hash_error(c, err)
		return
	}
	key := argv[1]
	if args.has_count {
		hrandfield_counted(c, key, args.count, args.with_values)
		return
	}
	e, h, wrong := hash_lookup(key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if h == nil || hash_expire_if_needed(key, e, h) {
		reply_null(c)
		return
	}
	field, _ := ht.random_element(h)
	reply_hash_value(c, field)
}

cmd_hscan :: proc(c: ^Conn, argv: [][]u8) {
	cursor, valid := ht.parse_scan_cursor(argv[2])
	if !valid {
		reply_hash_error(c, .Invalid_Cursor)
		return
	}
	_, h, wrong := hash_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	clear(&hash_fields)
	if h == nil {
		reply_array(c, 2)
		reply_bulk(c, transmute([]u8)string("0"))
		reply_array(c, 0)
		return
	}
	opts, err := ht.parse_scan_options(argv[3:], true)
	if err != .None {
		reply_hash_error(c, err)
		return
	}
	next_cursor := ht.scan(h, cursor, opts, &hash_fields, hash_now())
	buf: [21]u8
	n := format_u64(raw_data(buf[:]), next_cursor)
	reply_array(c, 2)
	reply_bulk(c, buf[:n])
	reply_array(c, len(hash_fields))
	for v in hash_fields {
		reply_hash_value(c, v)
	}
	clear(&hash_fields)
}
