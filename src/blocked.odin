package main

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import lb "label"
import ld "ldfloat"

ERR_TIMEOUT_NOT_FLOAT :: "ERR timeout is not a float or out of range"

ERR_TIMEOUT_RANGE :: "ERR timeout is out of range"

ERR_TIMEOUT_NEGATIVE :: "ERR timeout is negative"

ERR_UNBLOCKED :: "UNBLOCKED client unblocked via CLIENT UNBLOCK"

Block_Type :: enum u8 {
	None,
	List,
	Zset,
	Stream,
	Lazyfree,
}

Block_State :: struct {
	deadline:            i64,
	keys:                [dynamic]string,
	wake_on_key_removal: bool,
	exact:               bool,
	label:               lb.Id,
	stream_ids:          [dynamic][2]u64,
}

Block_Key :: struct {
	waiters: [dynamic]^Conn,
	ready:   bool,
	nokey:   int,
}

Block_Wakeup :: struct {
	db_index: int,
	name:     string,
}

block_keys: []map[string]^Block_Key

block_ready: [dynamic]Block_Wakeup

block_clients: [dynamic]^Conn

block_unblocked: [dynamic]^Conn

block_by_type: [Block_Type]int

block_next_deadline: i64

block_work: int

block_nokey_clients: int

block_removed: bool

@(private = "file")
block_serving: bool

@(private = "file")
block_reexecuting: bool

@(private = "file")
block_draining: bool

@(private = "file")
block_current: ^Conn

@(private = "file")
block_rearmed: bool

@(private = "file")
block_spans: [dynamic]int

@(private = "file")
block_key_total: int

@(private = "file")
block_nokey_total: int

block_init :: proc() {
	for &m in block_keys {
		for k, bk in m {
			delete(bk.waiters)
			free(bk)
			delete(k)
		}
		delete(m)
	}
	delete(block_keys)
	block_keys = make([]map[string]^Block_Key, max(len(dbs), db_count, 1))
	clear(&block_ready)
	clear(&block_clients)
	clear(&block_unblocked)
	clear(&block_spans)
	block_by_type = {}
	block_next_deadline = 0
	block_work = lazy_blocked
	block_nokey_clients = 0
	block_removed = false
	block_serving = false
	block_reexecuting = false
	block_draining = false
	block_current = nil
	block_rearmed = false
	block_key_total = 0
	block_nokey_total = 0
}

block_type_of :: #force_inline proc "contextless" (t: Obj_Type) -> Block_Type {
	#partial switch t {
	case .List:
		return .List
	case .Zset:
		return .Zset
	case .Stream:
		return .Stream
	}
	return .None
}

block_count :: #force_inline proc "contextless" () -> int {
	return len(block_clients)
}

block_total_keys :: proc() -> int {
	return block_key_total
}

block_total_nokey_keys :: proc() -> int {
	return block_nokey_total
}

block_timeout_ms :: proc "contextless" (v: ld.F80) -> (ms: i64, err: string) {
	switch v.class {
	case .NaN:
		return 0, ERR_TIMEOUT_NOT_FLOAT
	case .Zero:
		return 0, ""
	case .Inf:
		if v.neg {
			return 0, ERR_TIMEOUT_NEGATIVE
		}
		return 0, ERR_TIMEOUT_RANGE
	case .Finite:
	}
	if v.mant == 0 {
		return 0, ""
	}
	limit := u128(max(i64))
	product := u128(v.mant) * 1000
	exp := int(v.exp)
	extra := 64 - int(intrinsics.count_leading_zeros(product))
	if extra > 0 {
		dropped := product & ((u128(1) << uint(extra)) - 1)
		half := u128(1) << uint(extra - 1)
		product >>= uint(extra)
		if dropped > half || (dropped == half && product & 1 == 1) {
			product += 1
		}
		exp += extra
	}
	if v.neg {
		if exp >= 0 || (-exp < 128 && product >> uint(-exp) != 0) {
			return 0, ERR_TIMEOUT_NEGATIVE
		}
		return 0, ""
	}
	if exp >= 0 {
		if exp > 62 || product > limit >> uint(exp) {
			return 0, ERR_TIMEOUT_RANGE
		}
		return i64(product << uint(exp)), ""
	}
	shift := -exp
	if shift >= 120 {
		return 1, ""
	}
	whole := product >> uint(shift)
	if whole << uint(shift) != product {
		whole += 1
	}
	if whole > limit {
		return 0, ERR_TIMEOUT_RANGE
	}
	return i64(whole), ""
}

@(private = "file")
block_deadline_from :: proc(arg: []u8, now: i64) -> (deadline: i64, problem: string) {
	value, parsed := ld.parse(arg)
	if !parsed {
		return 0, ERR_TIMEOUT_NOT_FLOAT
	}
	span, why := block_timeout_ms(value)
	switch {
	case why != "":
		return 0, why
	case span == 0:
		return 0, ""
	case span > max(i64) - now:
		return 0, ERR_TIMEOUT_RANGE
	}
	return now + span, ""
}

block_parse_timeout :: proc(c: ^Conn, arg: []u8) -> (deadline: i64, ok: bool) {
	at, problem := block_deadline_from(arg, srv.now_ms)
	if problem != "" {
		reply_error(c, problem)
		return 0, false
	}
	return at, true
}

block_in_reexecution :: #force_inline proc "contextless" () -> bool {
	return block_reexecuting
}

block_note_removed :: #force_inline proc "contextless" () {
	if block_nokey_clients > 0 {
		block_removed = true
	}
}

@(private = "file")
block_db_index :: proc "contextless" (db: ^Db) -> int {
	if db == nil || len(dbs) == 0 {
		return -1
	}
	base := uintptr(raw_data(dbs))
	p := uintptr(db)
	if p >= base {
		i := int((p - base) / size_of(Db))
		if i < len(dbs) && &dbs[i] == db {
			return i
		}
	}
	if labels_on && db.id >= 0 && db.id < len(dbs) {
		return db.id
	}
	return -1
}

@(private = "file")
block_reserve_dbs :: proc(n: int) {
	if n <= len(block_keys) {
		return
	}
	grown := make([]map[string]^Block_Key, n)
	copy(grown, block_keys)
	delete(block_keys)
	block_keys = grown
}

@(private = "file")
block_index :: proc(c: ^Conn) -> int {
	for i := len(block_clients) - 1; i >= 0; i -= 1 {
		if block_clients[i] == c {
			return i
		}
	}
	return -1
}

@(private = "file")
block_free_key :: proc(m: ^map[string]^Block_Key, key: string) {
	k, bk := delete_key(m, key)
	if bk != nil {
		delete(bk.waiters)
		free(bk)
	}
	delete(k)
}

block_for_keys :: proc(c: ^Conn, type: Block_Type, keys: [][]u8, deadline: i64, wake_on_key_removal := false) {
	if block_reexecuting && c == block_current {
		block_rearmed = true
		pst.dirty_explicit = true
		c.blocked = type
		return
	}
	if c.blocked != .None || type == .None || type == .Lazyfree {
		return
	}
	dbi := block_db_index(c.db)
	if dbi < 0 {
		reply_null_array(c)
		return
	}
	block_reserve_dbs(dbi + 1)
	bs := c.bstate
	if bs == nil {
		bs = new(Block_State)
		c.bstate = bs
	}
	clear(&bs.keys)
	bs.deadline = deadline
	bs.wake_on_key_removal = wake_on_key_removal
	bs.label = access.id if labels_on else lb.BOTTOM_ID
	bs.exact = labels_on && label_cmd_writes
	m := &block_keys[dbi]
	outer: for k in keys {
		kp, vp, inserted, _ := map_entry(m, string(k))
		if inserted {
			kp^ = strings.clone(string(k))
			vp^ = new(Block_Key)
		} else {
			for seen in bs.keys {
				if seen == kp^ {
					continue outer
				}
			}
		}
		bk := vp^
		if len(bk.waiters) == 0 {
			block_key_total += 1
		}
		append(&bk.waiters, c)
		if wake_on_key_removal {
			if bk.nokey == 0 {
				block_nokey_total += 1
			}
			bk.nokey += 1
		}
		append(&bs.keys, kp^)
	}
	if wake_on_key_removal {
		block_nokey_clients += 1
	}
	pst.dirty_explicit = true
	c.blocked = type
	block_by_type[type] += 1
	append(&block_clients, c)
	append(&block_spans, 0)
	block_work += 1
	if deadline != 0 && (block_next_deadline == 0 || deadline < block_next_deadline) {
		block_next_deadline = deadline
	}
}

@(private = "file")
block_release :: proc(c: ^Conn) {
	t := c.blocked
	bs := c.bstate
	if t == .None || t == .Lazyfree || bs == nil {
		return
	}
	dbi := block_db_index(c.db)
	if dbi >= 0 && dbi < len(block_keys) {
		m := &block_keys[dbi]
		for ks in bs.keys {
			bk, found := m[ks]
			if !found {
				continue
			}
			for w, i in bk.waiters {
				if w == c {
					ordered_remove(&bk.waiters, i)
					break
				}
			}
			if bs.wake_on_key_removal {
				bk.nokey -= 1
				if bk.nokey == 0 {
					block_nokey_total -= 1
				}
			}
			if len(bk.waiters) == 0 {
				block_key_total -= 1
				if !bk.ready {
					block_free_key(m, ks)
				}
			}
		}
	}
	clear(&bs.keys)
	if bs.wake_on_key_removal {
		block_nokey_clients -= 1
	}
	bs.wake_on_key_removal = false
	bs.deadline = 0
	block_by_type[t] -= 1
	i := block_index(c)
	if i >= 0 {
		unordered_remove(&block_clients, i)
		unordered_remove(&block_spans, i)
	}
	block_work -= 1
	c.blocked = .None
}

@(private = "file")
block_queue_unblocked :: proc(c: ^Conn) {
	if c.wake_queued {
		return
	}
	c.wake_queued = true
	append(&block_unblocked, c)
	block_work += 1
}

block_wake :: proc(c: ^Conn) {
	block_queue_unblocked(c)
}

@(private = "file")
block_skip_command :: proc(c: ^Conn, failed: bool) {
	i := block_index(c)
	span := 0
	if i >= 0 {
		span = block_spans[i]
	}
	block_release(c)
	c.rpos = min(c.rpos + span, c.rlen)
	srv.stat_commands += 1
	stats_unblocked(c, nil, failed)
	block_queue_unblocked(c)
}

block_after_command :: proc(c: ^Conn, start: int) -> (stop: bool) {
	if c.blocked != .None {
		stop = true
		if c.blocked != .Lazyfree {
			i := block_index(c)
			if i >= 0 && block_spans[i] == 0 {
				block_spans[i] = c.rpos - start
				c.rpos = start
			}
		}
	}
	if !block_serving && (len(block_ready) > 0 || block_removed) {
		block_serve_ready()
	}
	return
}

block_conn_closed :: proc(c: ^Conn) {
	if c.wake_queued {
		for &w in block_unblocked {
			if w == c {
				w = nil
			}
		}
		c.wake_queued = false
		block_work -= 1
	}
	if c.blocked == .Lazyfree {
		lazyfree_unblock(c)
		stats_conn_closed(c)
	} else if c.blocked != .None {
		block_release(c)
		stats_conn_closed(c)
	}
	if c.bstate != nil {
		delete(c.bstate.keys)
		delete(c.bstate.stream_ids)
		free(c.bstate)
		c.bstate = nil
	}
}

block_unblock_timeout :: proc(c: ^Conn) {
	if c.blocked == .None || c.blocked == .Lazyfree {
		return
	}
	mark := c.wlen
	reply_null_array(c)
	if .Off in c.reply {
		c.wlen = mark
	}
	block_skip_command(c, false)
}

block_unblock_error :: proc(c: ^Conn, msg: string) {
	if c.blocked == .None || c.blocked == .Lazyfree {
		return
	}
	mark := c.wlen
	reply_error(c, msg)
	if .Off in c.reply {
		c.wlen = mark
	}
	block_skip_command(c, true)
}

block_signal_key :: proc(db: ^Db, key: []u8, type: Obj_Type) {
	if block_by_type[block_type_of(type)] == 0 && block_nokey_clients == 0 {
		return
	}
	dbi := block_db_index(db)
	if dbi < 0 || dbi >= len(block_keys) {
		return
	}
	k, bk, found := runtime.map_get(block_keys[dbi], string(key))
	if !found || bk.ready {
		return
	}
	if labels_on && !block_label_wakes(bk, db.label) {
		return
	}
	block_queue_ready(dbi, k, bk)
}

@(private = "file")
block_queue_ready :: proc(dbi: int, key: string, bk: ^Block_Key) {
	if bk.ready {
		return
	}
	bk.ready = true
	append(&block_ready, Block_Wakeup{db_index = dbi, name = key})
	block_work += 1
}

block_check_removed :: proc() {
	block_removed = false
	if block_nokey_clients == 0 {
		return
	}
	for dbi in 0 ..< len(block_keys) {
		for key, bk in block_keys[dbi] {
			if bk.nokey == 0 || bk.ready {
				continue
			}
			if labels_on {
				for w in bk.waiters {
					wt, wf := block_waiter_type(dbi, key, w)
					if !wf || wt != .Stream {
						block_queue_ready(dbi, key, bk)
						break
					}
				}
				continue
			}
			t, found := block_key_type(dbi, key)
			if !found || t != .Stream {
				block_queue_ready(dbi, key, bk)
			}
		}
	}
}

block_signal_existing :: proc(db: ^Db, key: []u8) {
	if len(block_clients) == 0 {
		return
	}
	dbi := block_db_index(db)
	if dbi < 0 {
		return
	}
	if labels_on {
		l := lookup_make(key)
		tt, i := db_locate_slot(db, &l)
		if i >= 0 && label_slot_live(db, tt, i) {
			block_signal_key(db, key, entry_type(db_view_slot(db, tt, i)))
		}
		return
	}
	t, found := block_key_type(dbi, string(key))
	if found {
		block_signal_key(db, key, t)
	}
}

block_scan_ready :: proc(db: ^Db) {
	if len(block_clients) == 0 {
		return
	}
	dbi := block_db_index(db)
	if dbi < 0 || dbi >= len(block_keys) {
		return
	}
	for key, bk in block_keys[dbi] {
		if bk.ready || len(bk.waiters) == 0 {
			continue
		}
		found: bool
		if labels_on {
			_, found = block_any_waiter_type(dbi, key, bk)
		} else {
			_, found = block_key_type(dbi, key)
		}
		if found || bk.nokey > 0 {
			block_queue_ready(dbi, key, bk)
		}
	}
}

@(private = "file")
block_key_type :: proc(dbi: int, key: string) -> (t: Obj_Type, found: bool) {
	if dbi < 0 || dbi >= len(dbs) {
		return
	}
	db := &dbs[dbi]
	k := transmute([]u8)key
	exists, expired := db_key_state(db, k)
	if !exists || expired {
		return
	}
	e := db_find_in(db, k)
	if e == nil {
		return
	}
	return entry_type(e), true
}

@(private = "file")
block_reexecute :: proc(c: ^Conn) {
	t := c.blocked
	start := c.rpos
	r := parse_command(c)
	if r != .Command || argc == 0 {
		c.rpos = start
		return
	}
	c.need = 0
	block_current = c
	block_rearmed = false
	block_reexecuting = true
	c.blocked = .None
	executed := true
	if srv.pause_end_ms != 0 || c.reply != {} {
		executed = execute_guarded(c, argv_buf[:argc])
	} else {
		execute(c, argv_buf[:argc])
	}
	block_reexecuting = false
	block_current = nil
	rearmed := block_rearmed
	block_rearmed = false
	c.blocked = t
	if executed && rearmed {
		c.rpos = start
		return
	}
	block_release(c)
	if !executed {
		c.rpos = start
		return
	}
	block_queue_unblocked(c)
}

@(private = "file")
block_serve_key :: proc(dbi: int, key: string) {
	if dbi < 0 || dbi >= len(block_keys) {
		return
	}
	m := &block_keys[dbi]
	bk, found := m[key]
	if !found {
		return
	}
	i := 0
	for i < len(bk.waiters) {
		c := bk.waiters[i]
		t: Obj_Type
		present: bool
		if labels_on {
			t, present = block_waiter_type(dbi, key, c)
		} else {
			t, present = block_key_type(dbi, key)
		}
		if !present && bk.nokey == 0 {
			break
		}
		eligible := c.bstate.wake_on_key_removal
		if present && block_type_of(t) == c.blocked {
			eligible = true
		}
		if eligible {
			block_reexecute(c)
		}
		if i < len(bk.waiters) && bk.waiters[i] == c {
			i += 1
		}
	}
	bk.ready = false
	if len(bk.waiters) == 0 {
		block_free_key(m, key)
	}
}

block_serve_ready :: proc() {
	if block_serving {
		return
	}
	block_serving = true
	i := 0
	for {
		if block_removed {
			block_check_removed()
		}
		if i >= len(block_ready) {
			break
		}
		wake := block_ready[i]
		i += 1
		block_work -= 1
		block_serve_key(wake.db_index, wake.name)
	}
	clear(&block_ready)
	block_serving = false
}

@(private = "file")
block_drain :: proc() {
	if block_draining {
		return
	}
	block_draining = true
	i := 0
	for i < len(block_unblocked) {
		c := block_unblocked[i]
		block_unblocked[i] = nil
		i += 1
		if c == nil {
			continue
		}
		c.wake_queued = false
		block_work -= 1
		if c.blocked == .None && !c.held && !c.close_after && c.rpos < c.rlen {
			process_input(c)
		}
		conn_flush(c)
	}
	clear(&block_unblocked)
	block_draining = false
}

block_handle_timeouts :: proc() {
	if block_next_deadline == 0 || srv.now_ms < block_next_deadline {
		return
	}
	next: i64 = 0
	i := 0
	for i < len(block_clients) {
		c := block_clients[i]
		d := c.bstate.deadline
		if d != 0 && d <= srv.now_ms {
			block_unblock_timeout(c)
			continue
		}
		if d != 0 && (next == 0 || d < next) {
			next = d
		}
		i += 1
	}
	block_next_deadline = next
}

block_wait_ms :: proc(timeout: i32) -> i32 {
	if len(block_unblocked) > 0 || len(block_ready) > 0 || block_removed {
		return 0
	}
	if block_next_deadline == 0 {
		return timeout
	}
	rem := block_next_deadline - srv.now_ms
	if rem <= 0 {
		return 0
	}
	if timeout < 0 || rem < i64(timeout) {
		return i32(min(rem, i64(max(i32))))
	}
	return timeout
}

block_before_sleep :: proc() {
	block_handle_timeouts()
	block_serve_ready()
	block_drain()
}

@(private = "file")
block_label_wakes :: proc(bk: ^Block_Key, written: lb.Id) -> bool {
	for w in bk.waiters {
		bs := w.bstate
		if bs == nil {
			continue
		}
		if bs.exact {
			if bs.label == written {
				return true
			}
		} else if access_dominates(bs.label, written) {
			return true
		}
	}
	return false
}

@(private = "file")
block_waiter_type :: proc(dbi: int, key: string, c: ^Conn) -> (t: Obj_Type, found: bool) {
	bs := c.bstate
	if bs == nil {
		return
	}
	k := transmute([]u8)key
	if bs.exact {
		p := label_part(dbi, bs.label)
		if p == nil {
			return
		}
		l := lookup_make(k)
		tt, i := db_locate_slot(p, &l)
		if i < 0 || !label_slot_live(p, tt, i) {
			return
		}
		return entry_type(db_view_slot(p, tt, i)), true
	}
	p, tt, i := label_resolve(dbi, k, bs.label, access_visibility(bs.label))
	if i < 0 {
		return
	}
	return entry_type(db_view_slot(p, tt, i)), true
}

block_any_waiter_type :: proc(dbi: int, key: string, bk: ^Block_Key) -> (t: Obj_Type, found: bool) {
	for w in bk.waiters {
		if t, found = block_waiter_type(dbi, key, w); found {
			return
		}
	}
	return
}
