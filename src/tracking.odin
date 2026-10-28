package main

import "core:slice"

Track_Flag :: enum u8 {
	On,
	Bcast,
	Optin,
	Optout,
	Caching,
	Noloop,
	Broken_Redir,
}

Track_Flags :: bit_set[Track_Flag;u8]

tracking_on: bool

tracking_clients: int

trk_max_keys: i64 = 1000000

ERR_TRK_REDIRECT_TWICE :: "ERR A client can only redirect to a single other client"

ERR_TRK_REDIRECT_MISSING :: "ERR The client ID you want redirect to does not exist"

ERR_TRK_PREFIX_BCAST :: "ERR PREFIX option requires BCAST mode to be enabled"

ERR_TRK_SWITCH_BCAST :: "ERR You can't switch BCAST mode on/off before disabling tracking for this client, and then re-enabling it with a different mode."

ERR_TRK_OPT_BCAST :: "ERR OPTIN and OPTOUT are not compatible with BCAST"

ERR_TRK_OPT_BOTH :: "ERR You can't specify both OPTIN mode and OPTOUT mode"

ERR_TRK_SWITCH_OPT :: "ERR You can't switch OPTIN/OPTOUT mode before disabling tracking for this client, and then re-enabling it with a different mode."

ERR_TRK_CACHING_YES :: "ERR CLIENT CACHING YES is only valid when tracking is enabled in OPTIN mode."

ERR_TRK_CACHING_NO :: "ERR CLIENT CACHING NO is only valid when tracking is enabled in OPTOUT mode."

@(private = "file")
TRK_PUSH_HEAD :: ">2\r\n$10\r\ninvalidate\r\n"

@(private = "file")
TRK_MESSAGE_HEAD :: "*3\r\n$7\r\nmessage\r\n$20\r\n__redis__:invalidate\r\n"

@(private = "file")
TRK_BROKEN_HEAD :: ">2\r\n$21\r\ntracking-redir-broken\r\n:"

@(private = "file")
TRK_NULL_RESP3 :: "_\r\n"

@(private = "file")
TRK_NULL_RESP2 :: "$-1\r\n"

@(private = "file")
TRK_OPT_MODES :: Track_Flags{.Optin, .Optout}

@(private = "file")
TRK_OPTION_FLAGS :: Track_Flags{.Bcast, .Optin, .Optout, .Noloop}

@(private = "file")
TRK_LIMIT_BUDGET_NS :: 1_000_000

@(private = "file")
TRK_LIMIT_CHECK_EVERY :: 64

@(private = "file")
TRK_SCRATCH_KEEP :: 1 << 20

@(private = "file")
TRK_OVERLAP_HEAD :: "ERR Prefix '"

@(private = "file")
TRK_OVERLAP_EXISTING :: "' overlaps with an existing prefix '"

@(private = "file")
TRK_OVERLAP_PROVIDED :: "' overlaps with another provided prefix '"

@(private = "file")
TRK_OVERLAP_TAIL :: "'. Prefixes for a single client must not overlap."

@(private = "file")
Trk_Entry :: struct {
	key:  []u8,
	ids:  [dynamic]i64,
	slot: int,
}

@(private = "file")
Trk_Batch_Key :: struct {
	key: string,
	by:  i64,
}

@(private = "file")
Trk_Prefix :: struct {
	prefix:  []u8,
	clients: [dynamic]^Conn,
	seen:    map[string]int,
	batch:   [dynamic]Trk_Batch_Key,
}

@(private = "file")
Trk_Deferred :: struct {
	id:   i64,
	off:  int,
	len:  int,
	hold: bool,
}

@(private = "file")
trk_table: map[string]^Trk_Entry

@(private = "file")
trk_dense: [dynamic]^Trk_Entry

@(private = "file")
trk_items: int

@(private = "file")
trk_conns: map[i64]^Conn

@(private = "file")
trk_prefixes: [dynamic]^Trk_Prefix

@(private = "file")
trk_bcast_index: map[string]^Trk_Prefix

@(private = "file")
trk_bcast_lens: [dynamic]int

@(private = "file")
trk_bcast_dirty: bool

@(private = "file")
trk_deferred: [dynamic]Trk_Deferred

@(private = "file")
trk_deferred_bytes: [dynamic]u8

@(private = "file")
trk_keys: [dynamic]int

@(private = "file")
trk_payload: [dynamic]u8

@(private = "file")
trk_payload_own: [dynamic]u8

@(private = "file")
trk_frame: [dynamic]u8

@(private = "file")
trk_parsed: [dynamic][]u8

@(private = "file")
trk_targets: [dynamic]^Conn

@(private = "file")
trk_redirects: map[i64]^Conn

@(private = "file")
trk_error: [dynamic]u8

@(private = "file")
trk_shrink :: proc(b: ^[dynamic]u8) {
	if cap(b) > TRK_SCRATCH_KEEP {
		delete(b^)
		b^ = nil
	} else {
		clear(b)
	}
}

@(private = "file")
trk_put_int :: proc(b: ^[dynamic]u8, v: i64) {
	digits: [24]u8
	n := format_i64(raw_data(digits[:]), v)
	append(b, ..digits[:n])
}

@(private = "file")
trk_put_bulk :: proc(b: ^[dynamic]u8, s: []u8) {
	append(b, '$')
	trk_put_int(b, i64(len(s)))
	append(b, "\r\n")
	append(b, ..s)
	append(b, "\r\n")
}

@(private = "file")
trk_clone :: proc(s: []u8) -> []u8 {
	out := make([]u8, len(s))
	copy(out, s)
	return out
}

@(private = "file")
trk_starts_with :: proc(s: []u8, p: []u8) -> bool {
	return len(s) >= len(p) && string(s[:len(p)]) == string(p)
}

@(private = "file")
trk_prefix_overlap :: proc(a: []u8, b: []u8) -> bool {
	if len(a) <= len(b) {
		return trk_starts_with(b, a)
	}
	return trk_starts_with(a, b)
}

@(private = "file")
trk_flags :: #force_inline proc(c: ^Conn) -> Track_Flags {
	if c.pubsub == nil {
		return {}
	}
	return c.pubsub.trk
}

@(private = "file")
trk_update :: proc() {
	tracking_on = tracking_clients > 0
	if !tracking_on {
		trk_table_reset()
	}
	key_hooks_update()
	hooks_update()
}

@(private = "file")
trk_free_entry :: proc(e: ^Trk_Entry) {
	delete(e.key)
	delete(e.ids)
	free(e)
}

@(private = "file")
trk_table_reset :: proc() {
	for e in trk_dense {
		trk_free_entry(e)
	}
	clear(&trk_dense)
	clear(&trk_table)
	trk_items = 0
}

@(private = "file")
trk_unlink :: proc(e: ^Trk_Entry) {
	delete_key(&trk_table, string(e.key))
	last := trk_dense[len(trk_dense) - 1]
	trk_dense[e.slot] = last
	last.slot = e.slot
	pop(&trk_dense)
	trk_items -= len(e.ids)
}

@(private = "file")
trk_remember :: proc(id: i64, key: []u8) {
	e, found := trk_table[string(key)]
	if !found {
		e = new(Trk_Entry)
		e.key = trk_clone(key)
		e.slot = len(trk_dense)
		append(&trk_dense, e)
		trk_table[string(e.key)] = e
	}
	lo, hi := 0, len(e.ids)
	for lo < hi {
		mid := (lo + hi) / 2
		if e.ids[mid] < id {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(e.ids) && e.ids[lo] == id {
		return
	}
	inject_at(&e.ids, lo, id)
	trk_items += 1
}

@(private = "file")
trk_conn_lookup :: proc(id: i64) -> ^Conn {
	if t, ok := trk_redirects[id]; ok {
		return t
	}
	t := conn_by_id(id)
	if t == nil || t.kind != .Redis {
		return nil
	}
	ps_state(t)
	trk_redirects[id] = t
	return t
}

@(private = "file")
trk_drain_deferred :: proc(final: bool, keep: ^Conn = nil) {
	kept := 0
	used := 0
	for d in trk_deferred {
		t := trk_conn_lookup(d.id)
		if t == nil {
			continue
		}
		if t == keep || (d.hold && (!final || t.blocked == .Lazyfree)) {
			copy(trk_deferred_bytes[used:], trk_deferred_bytes[d.off:][:d.len])
			trk_deferred[kept] = Trk_Deferred{d.id, used, d.len, d.hold}
			kept += 1
			used += d.len
			continue
		}
		push_write(t, trk_deferred_bytes[d.off:][:d.len])
	}
	resize(&trk_deferred, kept)
	if kept == 0 {
		trk_shrink(&trk_deferred_bytes)
	} else {
		resize(&trk_deferred_bytes, used)
	}
}

@(private = "file")
trk_write :: proc(t: ^Conn, frame: []u8, hold := false) {
	if t == ps_exec || (ps_exec == nil && t.ps & {.Subscribed, .Tracking} == {}) {
		off := len(trk_deferred_bytes)
		append(&trk_deferred_bytes, ..frame)
		append(&trk_deferred, Trk_Deferred{t.id, off, len(frame), hold})
		return
	}
	if ps_exec != nil && len(trk_deferred) > 0 {
		trk_drain_deferred(false, ps_exec)
	}
	push_write(t, frame)
}

@(private = "file")
trk_deliver :: proc(c: ^Conn, st: ^Ps_State, payload: []u8, null: bool) {
	t := c
	if st.trk_redirect != 0 {
		t = trk_conn_lookup(st.trk_redirect)
		if t == nil {
			st.trk += {.Broken_Redir}
			if c.resp >= RESP3 {
				b := &trk_frame
				clear(b)
				append(b, TRK_BROKEN_HEAD)
				trk_put_int(b, st.trk_redirect)
				append(b, "\r\n")
				trk_write(c, b[:])
			}
			return
		}
	}
	b := &trk_frame
	clear(b)
	if t.resp >= RESP3 {
		append(b, TRK_PUSH_HEAD)
	} else if .Subscribed in t.ps {
		append(b, TRK_MESSAGE_HEAD)
	} else {
		return
	}
	if !null {
		append(b, ..payload)
	} else if c.resp >= RESP3 {
		append(b, TRK_NULL_RESP3)
	} else {
		append(b, TRK_NULL_RESP2)
	}
	trk_write(t, b[:], null)
}

@(private = "file")
trk_key_payload :: proc(b: ^[dynamic]u8, key: []u8) -> []u8 {
	clear(b)
	append(b, "*1\r\n")
	trk_put_bulk(b, key)
	return b[:]
}

@(private = "file")
trk_find_bcast :: proc(p: []u8) -> (idx: int, found: bool) {
	lo, hi := 0, len(trk_prefixes)
	for lo < hi {
		mid := (lo + hi) / 2
		if string(trk_prefixes[mid].prefix) < string(p) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(trk_prefixes) && string(trk_prefixes[lo].prefix) == string(p)
}

@(private = "file")
trk_rebuild_lens :: proc() {
	clear(&trk_bcast_lens)
	for bs in trk_prefixes {
		n := len(bs.prefix)
		i := 0
		for i < len(trk_bcast_lens) && trk_bcast_lens[i] < n {
			i += 1
		}
		if i < len(trk_bcast_lens) && trk_bcast_lens[i] == n {
			continue
		}
		inject_at(&trk_bcast_lens, i, n)
	}
}

@(private = "file")
trk_batch_reset :: proc(bs: ^Trk_Prefix) {
	for k in bs.batch {
		delete(k.key)
	}
	clear(&bs.batch)
	clear(&bs.seen)
}

@(private = "file")
trk_free_bcast :: proc(idx: int) {
	bs := trk_prefixes[idx]
	ordered_remove(&trk_prefixes, idx)
	delete_key(&trk_bcast_index, string(bs.prefix))
	trk_batch_reset(bs)
	delete(bs.batch)
	delete(bs.seen)
	delete(bs.clients)
	delete(bs.prefix)
	free(bs)
	trk_rebuild_lens()
}

@(private = "file")
trk_enable_prefix :: proc(c: ^Conn, st: ^Ps_State, p: []u8) {
	idx, found := trk_find_bcast(p)
	bs: ^Trk_Prefix
	if found {
		bs = trk_prefixes[idx]
	} else {
		bs = new(Trk_Prefix)
		bs.prefix = trk_clone(p)
		inject_at(&trk_prefixes, idx, bs)
		trk_bcast_index[string(bs.prefix)] = bs
		trk_rebuild_lens()
	}
	for x in bs.clients {
		if x == c {
			return
		}
	}
	append(&bs.clients, c)
	at := 0
	for at < len(st.trk_prefixes) && string(st.trk_prefixes[at]) < string(bs.prefix) {
		at += 1
	}
	inject_at(&st.trk_prefixes, at, bs.prefix)
}

@(private = "file")
trk_remember_broadcast :: proc(key: []u8, by: ^Conn) {
	by_id: i64 = 0
	if by != nil {
		by_id = by.id
	}
	for n in trk_bcast_lens {
		if n > len(key) {
			break
		}
		bs, ok := trk_bcast_index[string(key[:n])]
		if !ok {
			continue
		}
		if at, seen := bs.seen[string(key)]; seen {
			if bs.batch[at].by != by_id {
				bs.batch[at].by = 0
			}
			continue
		}
		k := string(trk_clone(key))
		bs.seen[k] = len(bs.batch)
		append(&bs.batch, Trk_Batch_Key{k, by_id})
		trk_bcast_dirty = true
	}
}

@(private = "file")
trk_batch_payload :: proc(b: ^[dynamic]u8, bs: ^Trk_Prefix, skip: i64) -> int {
	count := 0
	for k in bs.batch {
		if skip == 0 || k.by != skip {
			count += 1
		}
	}
	clear(b)
	append(b, '*')
	trk_put_int(b, i64(count))
	append(b, "\r\n")
	for k in bs.batch {
		if skip == 0 || k.by != skip {
			trk_put_bulk(b, transmute([]u8)k.key)
		}
	}
	return count
}

@(private = "file")
trk_flush_bcast :: proc() {
	trk_bcast_dirty = false
	for bs in trk_prefixes {
		if len(bs.batch) == 0 {
			continue
		}
		slice.sort_by(bs.batch[:], proc(x, y: Trk_Batch_Key) -> bool {
			return x.key < y.key
		})
		all := trk_batch_payload(&trk_payload, bs, 0)
		for c in bs.clients {
			st := c.pubsub
			if .Noloop in st.trk {
				if trk_batch_payload(&trk_payload_own, bs, c.id) > 0 {
					trk_deliver(c, st, trk_payload_own[:], false)
				}
			} else if all > 0 {
				trk_deliver(c, st, trk_payload[:], false)
			}
		}
		trk_batch_reset(bs)
	}
	trk_shrink(&trk_payload)
	trk_shrink(&trk_payload_own)
	trk_shrink(&trk_frame)
}

@(private = "file")
trk_enable :: proc(c: ^Conn, redirect: i64, options: Track_Flags, prefixes: [][]u8) {
	st := ps_state(c)
	if .On not_in st.trk {
		tracking_clients += 1
		trk_conns[c.id] = c
		c.ps += {.Tracking}
	}
	st.trk = {.On} + (options & TRK_OPTION_FLAGS)
	st.trk_redirect = redirect
	if .Bcast in options {
		if len(prefixes) == 0 {
			trk_enable_prefix(c, st, nil)
		} else {
			for p in prefixes {
				trk_enable_prefix(c, st, p)
			}
		}
	}
	trk_update()
}

tracking_disable :: proc(c: ^Conn) {
	delete_key(&trk_redirects, c.id)
	st := c.pubsub
	if st == nil {
		return
	}
	if .On not_in st.trk {
		st.trk = {}
		c.ps -= {.Tracking}
		return
	}
	for p in st.trk_prefixes {
		idx, found := trk_find_bcast(p)
		if !found {
			continue
		}
		bs := trk_prefixes[idx]
		for x, i in bs.clients {
			if x == c {
				ordered_remove(&bs.clients, i)
				break
			}
		}
		if len(bs.clients) == 0 {
			trk_free_bcast(idx)
		}
	}
	clear(&st.trk_prefixes)
	st.trk = {}
	st.trk_redirect = 0
	c.ps -= {.Tracking}
	delete_key(&trk_conns, c.id)
	tracking_clients -= 1
	trk_update()
}

@(private = "file")
trk_put_clean :: proc(b: ^[dynamic]u8, s: []u8) {
	for ch in s {
		append(b, ' ' if ch == '\r' || ch == '\n' else ch)
	}
}

@(private = "file")
trk_reply_overlap :: proc(c: ^Conn, a: []u8, b: []u8, existing: bool) {
	msg := &trk_error
	clear(msg)
	append(msg, TRK_OVERLAP_HEAD)
	trk_put_clean(msg, a)
	append(msg, TRK_OVERLAP_EXISTING if existing else TRK_OVERLAP_PROVIDED)
	trk_put_clean(msg, b)
	append(msg, TRK_OVERLAP_TAIL)
	reply_error_bytes(c, msg[:])
	trk_shrink(msg)
}

@(private = "file")
trk_check_overlaps :: proc(c: ^Conn, prefixes: [][]u8) -> bool {
	st := c.pubsub
	for p, i in prefixes {
		if st != nil {
			for q in st.trk_prefixes {
				if trk_prefix_overlap(p, q) {
					trk_reply_overlap(c, p, q, true)
					return false
				}
			}
		}
		for k in i + 1 ..< len(prefixes) {
			if trk_prefix_overlap(p, prefixes[k]) {
				trk_reply_overlap(c, p, prefixes[k], false)
				return false
			}
		}
	}
	return true
}

client_tracking :: proc(c: ^Conn, argv: [][]u8) {
	on: bool
	if eq_nocase(argv[2], "on") {
		on = true
	} else if !eq_nocase(argv[2], "off") {
		reply_error(c, ERR_SYNTAX)
		return
	}
	options: Track_Flags
	redirect: i64
	has_redirect := false
	prefixes := &trk_parsed
	clear(prefixes)
	for j := 3; j < len(argv); j += 1 {
		a := argv[j]
		more := j + 1 < len(argv)
		if more && eq_nocase(a, "redirect") {
			j += 1
			if has_redirect {
				reply_error(c, ERR_TRK_REDIRECT_TWICE)
				return
			}
			v, ok := parse_i64(argv[j])
			if !ok {
				reply_error(c, ERR_NOT_INT)
				return
			}
			if trk_conn_lookup(v) == nil {
				reply_error(c, ERR_TRK_REDIRECT_MISSING)
				return
			}
			redirect = v
			has_redirect = true
		} else if eq_nocase(a, "bcast") {
			options += {.Bcast}
		} else if eq_nocase(a, "optin") {
			options += {.Optin}
		} else if eq_nocase(a, "optout") {
			options += {.Optout}
		} else if eq_nocase(a, "noloop") {
			options += {.Noloop}
		} else if more && eq_nocase(a, "prefix") {
			j += 1
			append(prefixes, argv[j])
		} else {
			reply_error(c, ERR_SYNTAX)
			return
		}
	}
	if !on {
		tracking_disable(c)
		reply_ok(c)
		return
	}
	cur := trk_flags(c)
	was_on := .On in cur
	if len(prefixes) > 0 && .Bcast not_in options {
		reply_error(c, ERR_TRK_PREFIX_BCAST)
		return
	}
	if was_on && (.Bcast in cur) != (.Bcast in options) {
		reply_error(c, ERR_TRK_SWITCH_BCAST)
		return
	}
	if options & TRK_OPT_MODES == TRK_OPT_MODES {
		reply_error(c, ERR_TRK_OPT_BOTH)
		return
	}
	if .Bcast in options && options & TRK_OPT_MODES != {} {
		reply_error(c, ERR_TRK_OPT_BCAST)
		return
	}
	if was_on && ((.Optin in options && .Optout in cur) || (.Optout in options && .Optin in cur)) {
		reply_error(c, ERR_TRK_SWITCH_OPT)
		return
	}
	if options & TRK_OPT_MODES == {} {
		options += cur & TRK_OPT_MODES
	}
	if .Bcast in options && !trk_check_overlaps(c, prefixes[:]) {
		return
	}
	trk_enable(c, redirect, options, prefixes[:])
	clear(prefixes)
	reply_ok(c)
}

client_caching :: proc(c: ^Conn, argv: [][]u8) {
	flags := trk_flags(c)
	if .On not_in flags || flags & TRK_OPT_MODES == {} {
		reply_error(c, ERR_CACHING)
		return
	}
	a := argv[2]
	if eq_nocase(a, "yes") {
		if .Optin not_in flags {
			reply_error(c, ERR_TRK_CACHING_YES)
			return
		}
	} else if eq_nocase(a, "no") {
		if .Optout not_in flags {
			reply_error(c, ERR_TRK_CACHING_NO)
			return
		}
	} else {
		reply_error(c, ERR_SYNTAX)
		return
	}
	c.pubsub.trk += {.Caching}
	reply_ok(c)
}

tracking_redirect_of :: proc(c: ^Conn) -> i64 {
	st := c.pubsub
	if st == nil || .On not_in st.trk {
		return -1
	}
	return st.trk_redirect
}

client_getredir :: proc(c: ^Conn, argv: [][]u8) {
	reply_int(c, tracking_redirect_of(c))
}

tracking_client_flags :: proc(b: ^[dynamic]u8, c: ^Conn) {
	flags := trk_flags(c)
	if .On not_in flags {
		return
	}
	append(b, 't')
	if .Broken_Redir in flags {
		append(b, 'R')
	}
	if .Bcast in flags {
		append(b, 'B')
	}
}

client_trackinginfo :: proc(c: ^Conn, argv: [][]u8) {
	flags := trk_flags(c)
	reply_map(c, 3)
	reply_bulk_str(c, "flags")
	if .On not_in flags {
		reply_set(c, 1)
		reply_bulk_str(c, "off")
	} else {
		n := 1
		names: [8]string
		names[0] = "on"
		if .Bcast in flags {
			names[n] = "bcast"
			n += 1
		}
		if .Optin in flags {
			names[n] = "optin"
			n += 1
			if .Caching in flags {
				names[n] = "caching-yes"
				n += 1
			}
		}
		if .Optout in flags {
			names[n] = "optout"
			n += 1
			if .Caching in flags {
				names[n] = "caching-no"
				n += 1
			}
		}
		if .Noloop in flags {
			names[n] = "noloop"
			n += 1
		}
		if .Broken_Redir in flags {
			names[n] = "broken_redirect"
			n += 1
		}
		reply_set(c, n)
		for name in names[:n] {
			reply_bulk_str(c, name)
		}
	}
	reply_bulk_str(c, "redirect")
	reply_int(c, tracking_redirect_of(c))
	reply_bulk_str(c, "prefixes")
	if .On not_in flags {
		reply_array(c, 0)
		return
	}
	st := c.pubsub
	reply_array(c, len(st.trk_prefixes))
	for p in st.trk_prefixes {
		reply_bulk(c, p)
	}
}

tracking_invalidate_key :: proc(key: []u8, attributed: bool, bcast := true) {
	by: ^Conn = nil
	if attributed {
		by = ps_exec
	}
	if bcast && len(trk_prefixes) > 0 {
		trk_remember_broadcast(key, by)
	}
	if len(trk_table) == 0 {
		return
	}
	e, found := trk_table[string(key)]
	if !found {
		return
	}
	trk_unlink(e)
	payload := trk_key_payload(&trk_payload, e.key)
	for id in e.ids {
		c, ok := trk_conns[id]
		if !ok {
			continue
		}
		st := c.pubsub
		if .Bcast in st.trk {
			continue
		}
		if c == by && .Noloop in st.trk {
			continue
		}
		trk_deliver(c, st, payload, false)
	}
	trk_free_entry(e)
	if cap(trk_payload) > TRK_SCRATCH_KEEP || cap(trk_frame) > TRK_SCRATCH_KEEP {
		trk_shrink(&trk_payload)
		trk_shrink(&trk_frame)
	}
}

tracking_flush :: proc() {
	if tracking_clients > 0 {
		targets := &trk_targets
		clear(targets)
		for _, c in trk_conns {
			append(targets, c)
		}
		slice.sort_by(targets[:], proc(a, b: ^Conn) -> bool {
			return a.id < b.id
		})
		for c in targets {
			trk_deliver(c, c.pubsub, nil, true)
		}
		clear(targets)
	}
	trk_table_reset()
}

tracking_pending :: #force_inline proc() -> bool {
	return len(trk_deferred) > 0
}

tracking_flush_pending :: proc(c: ^Conn) {
	if len(trk_deferred) > 0 {
		trk_drain_deferred(false)
	}
}

tracking_after_command :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8) {
	st := c.pubsub
	if st == nil || .On not_in st.trk {
		return
	}
	if .Multi in c.txf || cmd.handler == cmd_client || cmd.handler == cmd_multi {
		return
	}
	tracking_remember_keys(c, cmd, argv)
	st.trk -= {.Caching}
}

tracking_remember_keys :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8) {
	st := c.pubsub
	if st == nil || cmd == nil {
		return
	}
	flags := st.trk
	if .On not_in flags || .Bcast in flags {
		return
	}
	if .Optin in flags && .Caching not_in flags {
		return
	}
	if .Optout in flags && .Caching in flags {
		return
	}
	spec := cmd_spec_lookup(cmd, argv)
	if spec == nil || .Readonly not_in spec.flags {
		return
	}
	clear(&trk_keys)
	command_keys(spec, argv, &trk_keys)
	for i in trk_keys {
		if i >= 0 && i < len(argv) {
			trk_remember(c.id, argv[i])
		}
	}
}

tracking_limit :: proc() {
	if trk_max_keys <= 0 || i64(len(trk_dense)) <= trk_max_keys {
		return
	}
	deadline := now_ns() + TRK_LIMIT_BUDGET_NS
	evicted := 0
	for i64(len(trk_dense)) > trk_max_keys {
		e := trk_dense[int(rng_next() % u64(len(trk_dense)))]
		tracking_invalidate_key(e.key, false, false)
		evicted += 1
		if evicted % TRK_LIMIT_CHECK_EVERY == 0 && now_ns() > deadline {
			break
		}
	}
}

tracking_before_sleep :: proc() {
	if trk_bcast_dirty {
		trk_flush_bcast()
	}
	tracking_limit()
	if len(trk_deferred) > 0 {
		trk_drain_deferred(true)
	}
}

tracking_info_stats :: proc(b: ^[dynamic]u8) {
	info_line_int(b, "tracking_total_keys", i64(len(trk_table)))
	info_line_int(b, "tracking_total_items", i64(trk_items))
	info_line_int(b, "tracking_total_prefixes", i64(len(trk_prefixes)))
}
