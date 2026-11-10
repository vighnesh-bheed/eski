package main

import "base:intrinsics"
import lb "label"
import ow "owner"

Tx_Flag :: enum u8 {
	Multi,
	Dirty_Exec,
	Dirty_Cas,
}

Tx_Cmd :: struct {
	cmd:   ^Command,
	first: int,
	argc:  int,
}

Watched_Key :: struct {
	db:      int,
	key:     string,
	expired: bool,
	present: bool,
	label:   lb.Id,
	owner:   ow.Owner,
}

#assert(size_of(Watched_Key) == 32)

Watcher :: struct {
	c:   ^Conn,
	idx: int,
}

Watch_Key :: struct {
	key:      string,
	watchers: [dynamic]Watcher,
}

Tx_State :: struct {
	metadata_accounted, watch_shared: int,
	cmds:    [dynamic]Tx_Cmd,
	spans:   [dynamic][2]int,
	bytes:   [dynamic]u8,
	argv:    [dynamic][]u8,
	mem:     int,
	watched: [dynamic]Watched_Key,
}

ERR_EXECABORT :: "EXECABORT Transaction discarded because of previous errors."

ERR_EXECABORT_PREFIX :: "EXECABORT Transaction discarded because of: "

ERR_NO_MULTI :: "ERR Command not allowed inside a transaction"

TX_SHRINK_BYTES :: 1 << 20

@(private = "file")
ERR_MULTI_NESTED :: "ERR MULTI calls can not be nested"

@(private = "file")
ERR_EXEC_WITHOUT_MULTI :: "ERR EXEC without MULTI"

@(private = "file")
ERR_DISCARD_WITHOUT_MULTI :: "ERR DISCARD without MULTI"

@(private = "file")
ERR_WATCH_IN_MULTI :: "ERR WATCH inside MULTI is not allowed"

@(private = "file")
TX_ARG_SLOT :: 8

tx_multi_count: int

watch_total: int

watch_clients: int

watch_dbs: []map[string]^Watch_Key

deny_blocking: bool

tx_exec_conn: ^Conn

tx_exec_argv_mem: int

tx_reply_managed: bool

@(private = "file")
watch_victims: [dynamic]^Conn

@(private = "file")
tx_abort_buf: [dynamic]u8

tx_state :: proc(c: ^Conn) -> ^Tx_State {
	if c.tx == nil {
		c.tx = new(Tx_State)
		client_metadata_sync(c)
	}
	return c.tx
}

tx_flag :: #force_inline proc(c: ^Conn) {
	if .Multi in c.txf {
		c.txf += {.Dirty_Exec}
	}
}

tx_immediate :: #force_inline proc(cmd: ^Command) -> bool {
	h := cmd.handler
	return h == cmd_exec || h == cmd_discard || h == cmd_multi || h == cmd_watch || h == cmd_quit || h == cmd_reset
}

@(private = "file")
tx_shrink :: proc(a: ^[dynamic]$T) {
	if cap(a) * size_of(T) > TX_SHRINK_BYTES {
		delete(a^)
		a^ = nil
	} else {
		clear(a)
	}
}

@(private = "file")
tx_clear_queue :: proc(st: ^Tx_State) {
	tx_mem_total -= st.mem
	st.mem = 0
	tx_shrink(&st.cmds)
	tx_shrink(&st.spans)
	tx_shrink(&st.bytes)
	tx_shrink(&st.argv)
}

@(private = "file")
tx_leave :: proc(c: ^Conn) {
	if .Multi in c.txf {
		tx_multi_count -= 1
		hooks_update()
	}
	c.txf -= {.Multi, .Dirty_Exec}
	if c.tx != nil {
		tx_clear_queue(c.tx)
	}
}

tx_discard :: proc(c: ^Conn) {
	tx_leave(c)
	watch_unwatch_all(c)
}

tx_conn_closed :: proc(c: ^Conn) {
	tx_discard(c)
	st := c.tx
	if st == nil {
		return
	}
	delete(st.cmds)
	delete(st.spans)
	delete(st.bytes)
	delete(st.argv)
	delete(st.watched)
	client_metadata_drop_tx(c)
	free(st)
	c.tx = nil
}

@(private = "file")
tx_strip_err :: proc(msg: string) -> string {
	m := msg
	if len(m) > 0 && m[0] == '-' {
		m = m[1:]
	}
	if len(m) >= 4 && m[:4] == "ERR " {
		m = m[4:]
	}
	return m
}

@(cold)
tx_exec_abort :: #force_no_inline proc(c: ^Conn, parts: ..string) {
	b := &tx_abort_buf
	clear(b)
	sb_str(b, ERR_EXECABORT_PREFIX)
	for p, i in parts {
		sb_str(b, tx_strip_err(p) if i == 0 else p)
	}
	reply_error_bytes(c, b[:])
	tx_discard(c)
	if len(monitors) > 0 {
		tx_monitor_exec(c)
	}
}

@(private = "file")
tx_monitor_exec :: proc(c: ^Conn) {
	if argc < 1 || argc > len(argv_buf) {
		return
	}
	argv := argv_buf[:argc]
	cmd := lookup_command(argv[0])
	if cmd != nil && cmd.handler == cmd_exec {
		monitor_feed_raw(c, argv)
	}
}

@(cold)
execute_bad_arity :: #force_no_inline proc(c: ^Conn, cmd: ^Command) {
	if cmd.handler == cmd_exec {
		tx_exec_abort(c, "wrong number of arguments for '", cmd.name, "' command")
		return
	}
	reply_wrong_args(c, cmd.name)
	tx_flag(c)
}

@(private = "file")
tx_fill_argv :: proc(st: ^Tx_State) {
	resize(&st.argv, len(st.spans))
	for s, i in st.spans {
		st.argv[i] = st.bytes[s[0]:s[1]]
	}
}

@(private = "file")
tx_args :: #force_inline proc(st: ^Tx_State, q: Tx_Cmd) -> [][]u8 {
	return st.argv[q.first:q.first + q.argc]
}

tx_may_replicate :: proc(c: ^Conn) -> bool {
	st := c.tx
	if st == nil || .Multi not_in c.txf {
		return false
	}
	tx_fill_argv(st)
	for q in st.cmds {
		args := tx_args(st, q)
		if lua_outer_readonly(q.cmd, args) || (q.cmd.handler == cmd_script && len(args) > 1 && eq_nocase(args[1], "load")) { continue }
		flags := command_flags(q.cmd, args)
		if flags & {.Write, .May_Replicate} != {} {
			return true
		}
	}
	return false
}

command_flags :: proc(cmd: ^Command, argv: [][]u8) -> Cmd_Flags {
	spec := cmd_spec_lookup(cmd, argv)
	if spec == nil {
		return {}
	}
	return spec.flags
}

oom_denied :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8) -> bool {
	if cmd.handler != cmd_exec {
		return .Denyoom in command_flags(cmd, argv)
	}
	st := c.tx
	if st == nil || .Multi not_in c.txf {
		return false
	}
	tx_fill_argv(st)
	for q in st.cmds {
		if .Denyoom in command_flags(q.cmd, tx_args(st, q)) {
			return true
		}
	}
	return false
}

@(cold)
reject_oom :: #force_no_inline proc(c: ^Conn, cmd: ^Command) {
	if cmd.handler == cmd_exec {
		tx_exec_abort(c, ERR_OOM)
		return
	}
	reply_error(c, ERR_OOM)
	tx_flag(c)
}

@(private = "file")
tx_persist_refusal :: proc(cmd: ^Command, argv: [][]u8) -> (msg: string, refused: bool) {
	flags := persist_cmd_flags(cmd)
	write := .Write in flags && (cmd.handler != cmd_function || is_write_command(cmd.name, argv))
	if lua_is_eval(cmd) {
		write = lua_outer_persistence_write(cmd, argv)
	}
	if (write || cmd.handler == cmd_ping) && persist_writes_denied() {
		return ERR_MISCONF, true
	}
	if pst.loading && .Loading_Ok not_in flags {
		return ERR_LOADING, true
	}
	return "", false
}

@(cold)
hooked_persist_gate :: #force_no_inline proc(c: ^Conn, cmd: ^Command, argv: [][]u8) -> bool {
	if cmd.handler == cmd_exec && .Multi in c.txf && c.tx != nil {
		tx_fill_argv(c.tx)
		for q in c.tx.cmds {
			if msg, refused := tx_persist_refusal(q.cmd, tx_args(c.tx, q)); refused {
				tx_exec_abort(c, msg)
				return true
			}
		}
		return false
	}
	if persist_gate(c, cmd, argv) {
		tx_flag(c)
		return true
	}
	return false
}

@(private = "file")
is_container_command :: proc(name: string) -> bool {
	switch name {
	case "acl", "client", "cluster", "command", "config", "function", "latency", "memory", "module", "object", "pubsub", "script", "slowlog", "xgroup", "xinfo":
		return true
	}
	return false
}

tx_queue :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8) {
	if len(argv) > 1 && is_container_command(cmd.name) {
		if _, ok := resolve_subcommand(c, cmd, argv); !ok {
			tx_flag(c)
			return
		}
	}
	if .No_Multi in command_flags(cmd, argv) {
		reply_error(c, ERR_NO_MULTI)
		tx_flag(c)
		return
	}
	if .Dirty_Exec in c.txf || (.Dirty_Cas in c.txf && !labels_on) {
		reply_simple(c, "QUEUED")
		return
	}
	st := tx_state(c)
	first := len(st.spans)
	cost := 0
	for a in argv {
		start := len(st.bytes)
		append(&st.bytes, ..a)
		append(&st.spans, [2]int{start, len(st.bytes)})
		cost += len(a) + TX_ARG_SLOT
	}
	append(&st.cmds, Tx_Cmd{cmd, first, len(argv)})
	st.mem += cost
	tx_mem_total += cost
	reply_simple(c, "QUEUED")
}

@(private = "file")
ps_notice_command :: #force_inline proc(cmd: ^Command) -> bool {
	h := cmd.handler
	return h == cmd_subscribe || h == cmd_unsubscribe || h == cmd_psubscribe || h == cmd_punsubscribe || h == cmd_ssubscribe || h == cmd_sunsubscribe
}

@(private = "file")
tx_inline_notices :: proc(c: ^Conn, from: int) {
	ps := c.pubsub
	if ps == nil || len(ps.deferred) <= from {
		return
	}
	n := len(ps.deferred) - from
	p := wb_reserve(c, n)
	intrinsics.mem_copy_non_overlapping(p, raw_data(ps.deferred[from:]), n)
	c.wlen += n
	resize(&ps.deferred, from)
}

@(private = "file")
tx_reply_step :: #force_inline proc(c: ^Conn, pending: int, closing: bool) {
	if closing || c.reply & {.Off, .Skip} != {} {
		c.wlen = c.wpos + pending
	}
}

@(private = "file")
tx_run :: proc(c: ^Conn, exec_argv: [][]u8) {
	st := c.tx
	watch_unwatch_all(c)
	tx_fill_argv(st)
	argv_mem := 0
	for a in exec_argv {
		argv_mem += len(a)
	}
	outer_conn := tx_exec_conn
	outer_mem := tx_exec_argv_mem
	outer_deny := deny_blocking
	tx_exec_conn = c
	tx_exec_argv_mem = argv_mem
	deny_blocking = true
	saved_stat := stat_cur
	saved_last := c.last_cmd
	head := c.wlen - c.wpos
	reply_array(c, len(st.cmds))
	if c.reply & {.Off, .Skip} != {} {
		c.wlen = c.wpos + head
	}
	for q in st.cmds {
		cmd := q.cmd
		args := tx_args(st, q)
		pending := c.wlen - c.wpos
		closing := c.close_after
		if c.acl_gate {
			stat_cur = nil
			if acl_exec_rejects(c, cmd, args) {
				tx_reply_step(c, pending, closing)
				continue
			}
		}
		if ps_exec != c && (c.pubsub != nil || ps_notice_command(cmd)) {
			ps_begin(c)
		}
		notices := len(c.pubsub.deferred) if c.pubsub != nil else 0
		hot := stat_of(cmd)
		db_cur = c.db
		if labels_on {
			if refusal := label_step(c.db, cmd, args); refusal != "" {
				stat_cur = nil
				reply_error(c, refusal)
				tx_reply_step(c, pending, closing)
				continue
			}
		}
		if labels_on && access_needs_session(cmd, args) {
			access_pin_bound(c)
		}
		store_no_touch = .No_Touch in c.flags && cmd.handler != cmd_touch
		dirty := pst.dirty
		if aof.feed {
			aof_tx_begin(c, cmd, args)
		}
		stat_cur = &hot.stats
		t0 := mono_now()
		cmd.handler(c, args)
		ticks := mono_now() - t0
		if ticks < hot.limit_ticks {
			#no_bounds_check hot.small[(ticks * mono_mul) >> 32] += 1
			srv.stat_commands += 1
		} else {
			stat_call_slow(c, cmd, hot, args, ticks)
		}
		persist_note(c, cmd, args, pending, dirty)
		if c.reply & {.Off, .Skip} != {} {
			c.wlen = c.wpos + pending
		}
		if ps_notice_command(cmd) {
			tx_inline_notices(c, notices)
		}
		if .Tracking in c.ps {
			caching := .Caching in c.pubsub.trk
			queuing := .Multi in c.txf
			c.txf -= {.Multi}
			tracking_after_command(c, cmd, args)
			if queuing {
				c.txf += {.Multi}
			}
			if caching && c.pubsub != nil {
				c.pubsub.trk += {.Caching}
			}
		}
		if len(monitors) > 0 {
			monitor_feed(c, cmd, args)
		}
		if closing {
			c.wlen = c.wpos + pending
		}
	}
	if aof.in_tx {
		aof_tx_end()
	}
	stat_cur = saved_stat
	c.last_cmd = saved_last
	db_cur = c.db
	deny_blocking = outer_deny
	tx_exec_conn = outer_conn
	tx_exec_argv_mem = outer_mem
	tx_reply_managed = true
	tx_leave(c)
}

cmd_multi :: proc(c: ^Conn, argv: [][]u8) {
	if .Multi in c.txf {
		reply_error(c, ERR_MULTI_NESTED)
		return
	}
	tx_state(c)
	c.txf += {.Multi}
	tx_multi_count += 1
	hooks_update()
	reply_ok(c)
}

cmd_discard :: proc(c: ^Conn, argv: [][]u8) {
	if .Multi not_in c.txf {
		reply_error(c, ERR_DISCARD_WITHOUT_MULTI)
		return
	}
	tx_discard(c)
	reply_ok(c)
}

tx_exec_gate :: proc(c: ^Conn) -> bool {
	if .Multi not_in c.txf {
		reply_error(c, ERR_EXEC_WITHOUT_MULTI)
		return true
	}
	if .Dirty_Exec in c.txf {
		reply_error(c, ERR_EXECABORT)
		tx_discard(c)
		return true
	}
	if labels_on && access_watch_differs(c) {
		reply_error(c, ERR_LABEL_WATCH_EXEC)
		tx_discard(c)
		return true
	}
	if .Dirty_Cas in c.txf || watch_expired_since(c) {
		reply_null_array(c)
		tx_discard(c)
		return true
	}
	return false
}

cmd_exec :: proc(c: ^Conn, argv: [][]u8) {
	if !tx_exec_gate(c) {
		tx_run(c, argv)
	}
}

cmd_watch :: proc(c: ^Conn, argv: [][]u8) {
	if .Multi in c.txf {
		reply_error(c, ERR_WATCH_IN_MULTI)
		return
	}
	if labels_on {
		access_watch_note(c)
	}
	if .Dirty_Cas in c.txf && !labels_on {
		reply_ok(c)
		return
	}
	for key in argv[1:] {
		watch_key(c, c.db, key)
	}
	reply_ok(c)
}

cmd_unwatch :: proc(c: ^Conn, argv: [][]u8) {
	watch_unwatch_all(c)
	reply_ok(c)
}

@(private = "file")
watch_registry :: proc(id: int) -> ^map[string]^Watch_Key {
	if id >= len(watch_dbs) {
		grown := make([]map[string]^Watch_Key, max(len(dbs), id + 1))
		copy(grown, watch_dbs)
		delete(watch_dbs)
		watch_dbs = grown
	}
	return &watch_dbs[id]
}

@(private = "file")
watch_holds :: proc(st: ^Tx_State, c: ^Conn, wk: ^Watch_Key, id: int) -> bool {
	if len(wk.watchers) <= len(st.watched) {
		for w in wk.watchers {
			if w.c == c {
				return true
			}
		}
		return false
	}
	for w in st.watched {
		if w.db == id && w.key == wk.key {
			return true
		}
	}
	return false
}

watch_key :: proc(c: ^Conn, db: ^Db, key: []u8) {
	st := tx_state(c)
	m := watch_registry(db.id)
	wk := m[string(key)]
	if wk == nil {
		wk = new(Watch_Key)
		owned := make([]u8, len(key))
		copy(owned, key)
		wk.key = string(owned)
		m[wk.key] = wk
		mem_registry_changed()
		watch_total += 1
		if watch_total == 1 {
			key_hooks_update()
		}
	} else if watch_holds(st, c, wk, db.id) {
		return
	}
	exists, expired: bool
	if labels_on {
		exists, expired = label_key_state(db.id, key, access.id)
	} else {
		exists, expired = db_key_state(db, key)
	}
	watch_metadata_adjust(wk, -1)
	append(&wk.watchers, Watcher{c, len(st.watched)})
	append(&st.watched, Watched_Key{db.id, wk.key, exists && expired, exists && !expired, access.id if labels_on else lb.BOTTOM_ID, access.owner if owners_on else ow.SHARED})
	watch_metadata_adjust(wk, 1)
	client_metadata_sync(c)
	if len(st.watched) == 1 {
		watch_clients += 1
	}
}

@(private = "file")
watch_release :: proc(c: ^Conn) {
	st := c.tx
	if st == nil || len(st.watched) == 0 {
		return
	}
	for w in st.watched {
		m := &watch_dbs[w.db]
		wk := m[w.key]
		watch_metadata_adjust(wk, -1)
		for x, i in wk.watchers {
			if x.c == c {
				unordered_remove(&wk.watchers, i)
				break
			}
		}
		watch_metadata_adjust(wk, 1)
		if len(wk.watchers) == 0 {
			delete_key(m, w.key)
			delete(wk.watchers)
			delete(wk.key)
			free(wk)
			watch_total -= 1
		}
	}
	clear(&st.watched)
	client_metadata_sync(c)
	watch_clients -= 1
	if watch_total == 0 {
		key_hooks_update()
	}
}

watch_unwatch_all :: proc(c: ^Conn) {
	c.txf -= {.Dirty_Cas}
	access_watch_clear(c)
	watch_release(c)
}

@(private = "file")
watch_mark :: #force_inline proc(c: ^Conn) {
	if .Dirty_Cas not_in c.txf {
		c.txf += {.Dirty_Cas}
		if !labels_on {
			append(&watch_victims, c)
		}
	}
}

@(private = "file")
watch_dirty_victims :: proc() {
	for c in watch_victims {
		watch_release(c)
	}
	clear(&watch_victims)
}

watch_touch :: proc(key: []u8, db: ^Db, known: bool = false, known_exists: bool = false) {
	if watch_total == 0 || db.id < 0 || db.id >= len(watch_dbs) {
		return
	}
	wk := watch_dbs[db.id][string(key)]
	if wk == nil {
		return
	}
	probed := false
	gone := false
	for w in wk.watchers {
		c := w.c
		entry := &c.tx.watched[w.idx]
		if labels_on && (.Dirty_Cas in c.txf || !access_dominates(entry.label, db.label)) {
			continue
		}
		if entry.expired {
			if !probed || labels_on {
				if known {
					gone = !known_exists
				} else if labels_on {
					exists, _ := label_key_state(db.id, key, entry.label)
					gone = !exists
				} else {
					exists, _ := db_key_state(db, key)
					gone = !exists
				}
				probed = true
			}
			if gone {
				entry.expired = false
				continue
			}
		}
		watch_mark(c)
	}
	watch_dirty_victims()
}

@(private = "file")
watch_db_replaced :: proc(emptied: ^Db, replaced: ^Db) {
	if emptied.id >= len(watch_dbs) {
		return
	}
	for _, wk in watch_dbs[emptied.id] {
		key := transmute([]u8)wk.key
		old_exists, old_expired := db_key_state(emptied, key)
		new_exists, new_expired := false, false
		if replaced != nil {
			new_exists, new_expired = db_key_state(replaced, key)
		}
		if labels_on && !old_exists && !new_exists {
			continue
		}
		live := (old_exists && !old_expired) || (new_exists && !new_expired)
		old_stale := old_exists && old_expired
		for w in wk.watchers {
			c := w.c
			entry := &c.tx.watched[w.idx]
			if labels_on && (.Dirty_Cas in c.txf || !access_dominates(entry.label, emptied.label)) {
				continue
			}
			if live || (old_stale && !entry.expired) {
				watch_mark(c)
			} else {
				entry.expired = new_exists && new_expired
				entry.present = false
			}
		}
	}
}

watch_flush :: proc(db: ^Db) {
	if watch_total == 0 {
		return
	}
	if db != nil {
		watch_db_replaced(db, nil)
	} else {
		for &d in dbs {
			watch_db_replaced(&d, nil)
		}
	}
	watch_dirty_victims()
}

watch_swap :: proc(a: int, b: int) {
	if watch_total == 0 || a == b || a < 0 || b < 0 || a >= len(dbs) || b >= len(dbs) {
		return
	}
	if labels_on {
		watch_views_replaced(a, b)
		watch_views_replaced(b, a)
		watch_dirty_victims()
		return
	}
	watch_db_replaced(&dbs[a], &dbs[b])
	watch_db_replaced(&dbs[b], &dbs[a])
	watch_dirty_victims()
}

@(private = "file")
watch_views_replaced :: proc(id: int, other: int) {
	if id >= len(watch_dbs) {
		return
	}
	for _, wk in watch_dbs[id] {
		key := transmute([]u8)wk.key
		for w in wk.watchers {
			if .Dirty_Cas in w.c.txf {
				continue
			}
			entry := &w.c.tx.watched[w.idx]
			old_exists, old_expired := label_key_state(id, key, entry.label)
			new_exists, new_expired := label_key_state(other, key, entry.label)
			live := (old_exists && !old_expired) || (new_exists && !new_expired)
			if live || (old_exists && old_expired && !entry.expired) {
				watch_mark(w.c)
			} else {
				entry.expired = new_exists && new_expired
				entry.present = false
			}
		}
	}
}

watch_expired_since :: proc(c: ^Conn) -> bool {
	st := c.tx
	if st == nil {
		return false
	}
	for w in st.watched {
		if w.expired {
			continue
		}
		exists, expired: bool
		if labels_on {
			exists, expired = label_key_state(w.db, transmute([]u8)w.key, w.label)
		} else {
			exists, expired = db_key_state(&dbs[w.db], transmute([]u8)w.key)
		}
		if w.present && (!exists || expired) {
			return true
		}
		if !w.present && exists && expired {
			return true
		}
	}
	return false
}

tx_dirty_visible :: proc(c: ^Conn) -> bool {
	if !labels_on || access.top || c.tx == nil {
		return true
	}
	for w in c.tx.watched {
		if !access_dominates(access.id, w.label) || (owners_on && !ow.sees(access_view_owner(), w.owner)) {
			return false
		}
	}
	return true
}

tx_client_fields :: proc(b: ^[dynamic]u8, c: ^Conn) {
	st := c.tx
	sb_str(b, " multi=")
	if .Multi in c.txf && st != nil {
		sb_int(b, i64(len(st.cmds)))
	} else {
		sb_str(b, "-1")
	}
	sb_str(b, " watch=")
	sb_int(b, i64(len(st.watched)) if st != nil else 0)
}

tx_multi_mem :: proc(c: ^Conn) -> int {
	if c.tx == nil {
		return 0
	}
	return c.tx.mem
}

@(private = "file")
multi_commands := [?]Command {
	{"multi", cmd_multi, 1},
	{"exec", cmd_exec, 1},
	{"discard", cmd_discard, 1},
	{"watch", cmd_watch, -2},
	{"unwatch", cmd_unwatch, 1},
}

@(init)
register_multi_commands :: proc "contextless" () {
	register_commands(multi_commands[:])
}
