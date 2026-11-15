package main

import "core:slice"
import "core:sys/linux"
import lb "label"
import ow "owner"
import "rdb"
import vt "vsettype"

ACCESS_MODULE_ID :: u64(0x7ac922fa569b9401)
ACCESS_MODULE_WHEN :: 2
ACCESS_MODULE_STRING :: 5
ACCESS_FORMAT_VERSION :: 1
ACCESS_FLAG_LABELLED :: u64(1)
ACCESS_FLAG_OWNERS :: u64(2)
ACCESS_RECORD_HEADER :: 1
ACCESS_RECORD_PARTITION :: 2
ACCESS_RECORD_ORDER :: 3
ACCESS_FORGET_DELAY_DEFAULT :: 300
ACCESS_KEY_TEXT_MAX :: 256
ACCESS_RELOAD_OPTIONS :: "ERR DEBUG RELOAD MERGE and NOFLUSH are not available with a label scheme or owner mode"
ACCESS_LABELLED_FILE :: "holds data with labels or owners; start the server with the label scheme and owner mode it was written with"

Access_Mode :: struct {
	labelled: bool,
	owners:   bool,
}

Access_Quota :: struct {
	label: u64,
	bytes: u64,
}

Access_Owner_Record :: struct {
	text:  []u8,
	quota: u64,
}

Access_Header :: struct {
	flags:  u64,
	scheme: lb.Config,
	table:  lb.Table,
	quotas: [dynamic]Access_Quota,
	owners: [dynamic]Access_Owner_Record,
	forget: u64,
	seed:   u64,
	ready:  bool,
}

Access_Vset :: struct {
	set:   vt.Vset,
	owner: vt.Owner,
}

Access_Load_Part :: struct {
	db:    int,
	label: u64,
	owner: u64,
}

Access_Order :: struct {
	owner:  u64,
	name:   []u8,
	labels: []u64,
}

Access_Dead :: struct {
	owner:  u64,
	name:   []u8,
	labels: [dynamic]u64,
}

Access_Dead_Names :: map[string]^Access_Dead

Access_Names :: map[string]bool

Access_Load :: struct {
	active:     bool,
	startup:    bool,
	served:     bool,
	mode:       Access_Mode,
	header:     Access_Header,
	labels:     [dynamic]lb.Id,
	owners:     [dynamic]^Owner_Entry,
	created:    [dynamic]bool,
	parts:      map[Access_Load_Part]bool,
	dbs:        map[int]bool,
	db:         int,
	in_part:    bool,
	part_label: u64,
	part_owner: u64,
	part:       ^Db,
	db_keys:    u64,
	ordered:    bool,
	orders:     [dynamic]Access_Order,
	dead:       map[u64]^Access_Dead_Names,
	vctx:       vt.Load_Context,
	vsets:      [dynamic]Access_Vset,
}

Access_Save_Part :: struct {
	db:    ^Db,
	owner: u64,
}

Access_Save_Order :: struct {
	owner: u64,
	name:  []u8,
	cp:    ^Label_Copies,
}

access_ld := Access_Load {
	db = -1,
}

access_load_startup: bool
access_save_forced: bool
access_save_forced_mode: Access_Mode
access_save_refused: string
access_forget_seq: u64
access_forget_in_snapshot: u64
access_forget_at_fork: u64
access_forget_due_ms: i64
access_forget_in_aof: u64
access_forget_aof_confirmed: u64
access_forget_aof_due_ms: i64
access_snapshot_used: bool
owners_forget_snapshot_delay: i64 = ACCESS_FORGET_DELAY_DEFAULT
owners_forget_aof_delay: i64 = ACCESS_FORGET_DELAY_DEFAULT

@(private = "file")
access_save_owners: [dynamic]^Owner_Entry

@(private = "file")
access_vsave: vt.Save_Context

@(private = "file")
access_vsave_parts: map[vt.Vset]int

access_server_mode :: proc "contextless" () -> Access_Mode {
	if !labels_on {
		return {}
	}
	return Access_Mode{label_scheme_labelled, owners_on}
}

access_save_mode :: proc "contextless" () -> (Access_Mode, bool) {
	if access_save_forced {
		return access_save_forced_mode, true
	}
	if !labels_on {
		return {}, false
	}
	return access_server_mode(), true
}

access_mode_flags :: proc "contextless" (m: Access_Mode) -> u64 {
	flags: u64 = 0
	if m.labelled {
		flags |= ACCESS_FLAG_LABELLED
	}
	if m.owners {
		flags |= ACCESS_FLAG_OWNERS
	}
	return flags
}

access_mode_of_flags :: proc "contextless" (flags: u64) -> Access_Mode {
	return Access_Mode{flags & ACCESS_FLAG_LABELLED != 0, flags & ACCESS_FLAG_OWNERS != 0}
}

access_mode_words :: proc "contextless" (m: Access_Mode) -> string {
	switch {
	case m.labelled && m.owners:
		return "a label scheme and owner mode"
	case m.labelled:
		return "a label scheme without owner mode"
	case m.owners:
		return "owner mode without a label scheme"
	}
	return "neither a label scheme nor owner mode"
}

access_prepare_save :: proc() {
	access_save_refused = ""
	if _, labelled := access_save_mode(); !labelled {
		return
	}
	access_forget_at_fork = access_forget_seq
}

access_vset_scope :: #force_inline proc "contextless" (db: ^Db) -> vt.Owner {
	return vt.Owner(db.owner) if db.role & DB_ROLE_OWNER != 0 else vt.SHARED
}

access_vset_savable :: proc(db: ^Db, s: vt.Vset) -> bool {
	if vt.part_at_scope(s, db.label, access_vset_scope(db)) == nil {
		access_save_refused = "a vector set key has no vector partition at its own scope"
		return false
	}
	return true
}

access_write_vset :: proc(w: ^rdb.Writer, db: ^Db, s: vt.Vset) -> bool {
	if !vset_rdb_save_part(w, &access_vsave, s, db.label, access_vset_scope(db)) {
		return false
	}
	access_vsave_parts[s] += 1
	return true
}

@(private = "file")
access_vset_part_total :: proc "contextless" (s: vt.Vset) -> int {
	if s == nil {
		return 0
	}
	if s.lab == nil {
		return 1 if s.count > 0 else 0
	}
	n := int(s.lab.sorted_len)
	if idx := s.lab.owners; idx != nil {
		for i in 0 ..< idx.slot_cap {
			sl := idx.slots[i]
			if sl.owner != vt.SHARED && sl.scope != nil {
				n += int(sl.scope.part_len)
			}
		}
	}
	return n
}

@(private = "file")
access_vsets_complete :: proc() -> bool {
	for s, written in access_vsave_parts {
		if written != access_vset_part_total(s) {
			access_save_refused = "a vector set has a vector partition without a key at its scope"
			return false
		}
	}
	return true
}

@(private = "file")
access_vsave_release :: proc() {
	vset_save_context_destroy(&access_vsave)
	delete(access_vsave_parts)
	access_vsave_parts = nil
}

access_snapshots_on :: proc() -> bool {
	return len(pst.save_params) > 0 || access_snapshot_used
}

access_forget_uncovered :: proc() -> bool {
	return owners_on && access_forget_seq > access_forget_in_snapshot && access_snapshots_on()
}

@(private = "file")
access_snapshot_file_present :: proc() -> bool {
	buf: [PERSIST_PATH_MAX]u8
	sb: linux.Stat
	return linux.stat(persist_cstr(persist_filename(), buf[:]), &sb) == .NONE
}

access_forget_noted :: proc() -> u64 {
	access_forget_seq += 1
	if owners_forget_snapshot_delay > 0 && access_forget_due_ms == 0 {
		access_forget_due_ms = srv.now_ms + owners_forget_snapshot_delay * 1000
	}
	if owners_forget_aof_delay > 0 && access_forget_aof_due_ms == 0 {
		access_forget_aof_due_ms = srv.now_ms + owners_forget_aof_delay * 1000
	}
	access_forget_snapshot_warned = false
	if !aof.loading && !pst.loading {
		access_forget_warn_aof()
		access_forget_warn_snapshot()
	}
	return access_forget_seq
}

@(private = "file")
access_forget_snapshot_warned: bool

@(private = "file")
access_forget_warn_aof :: proc() {
	if aof.state == .Disabled && aof_log_files_present() {
		plog(LOG_WARNING, "OWNERS FORGET ran while the append-only file is off, and ", aof.dirname, " still holds files of an earlier append-only file that can hold the data it removed; delete those files, or turn the append-only file on, which rewrites them")
	}
}

@(private = "file")
access_forget_warn_snapshot :: proc() {
	if access_snapshots_on() || !access_snapshot_file_present() {
		return
	}
	plog(LOG_WARNING, "OWNERS FORGET ran while snapshots are not in use, and the data file ", persist_filename(), " was neither read nor written by this server, so it can hold the data it removed; delete it, or save a snapshot, which replaces it")
}

access_forget_in_aof_value :: proc() -> u64 {
	if aof.state == .Disabled && !aof_log_files_present() {
		return access_forget_seq
	}
	return access_forget_aof_confirmed
}

access_forget_aof_uncovered :: proc() -> bool {
	return owners_on && aof.state != .Disabled && access_forget_seq > access_forget_in_aof
}

access_forget_aof_unconfirmed :: proc() -> bool {
	return owners_on && aof.state != .Disabled && access_forget_seq > access_forget_aof_confirmed
}

access_aof_rewritten :: proc(covered: u64) {
	if covered > access_forget_in_aof {
		access_forget_in_aof = covered
	}
	if access_forget_in_aof >= access_forget_seq {
		access_forget_aof_due_ms = 0
	}
}

access_aof_failed :: proc() {
	if owners_on && owners_forget_aof_delay > 0 && access_forget_seq > access_forget_in_aof && access_forget_aof_due_ms == 0 {
		access_forget_aof_due_ms = srv.now_ms + owners_forget_aof_delay * 1000
	}
}

access_forget_aof_cron :: proc() {
	if !owners_on || access_forget_aof_due_ms == 0 {
		return
	}
	if aof.state == .Disabled && owners_forget_aof_delay > 0 && srv.now_ms < access_forget_aof_due_ms {
		return
	}
	if aof.state == .Disabled && owners_forget_aof_delay > 0 {
		access_forget_warn_aof()
	}
	if aof.state == .Disabled || owners_forget_aof_delay <= 0 || access_forget_seq <= access_forget_in_aof {
		access_forget_aof_due_ms = 0
		return
	}
	if srv.now_ms < access_forget_aof_due_ms || pst.child_pid > 0 || pst.loading || aof.loading || aof.state != .Enabled {
		return
	}
	access_forget_aof_due_ms = 0
	plog(LOG_NOTICE, "Rewriting the append-only file after OWNERS FORGET")
	if !aof_rewrite_background() {
		access_aof_failed()
	}
}

access_forget_in_snapshot_value :: proc() -> u64 {
	if !access_snapshots_on() && !access_snapshot_file_present() {
		return access_forget_seq
	}
	return access_forget_in_snapshot
}

access_snapshot_saved :: proc(covered: u64) {
	access_snapshot_used = true
	if covered > access_forget_in_snapshot {
		access_forget_in_snapshot = covered
	}
	if access_forget_in_snapshot >= access_forget_seq {
		access_forget_due_ms = 0
	}
}

access_snapshot_failed :: proc() {
	if owners_on && owners_forget_snapshot_delay > 0 && access_forget_seq > access_forget_in_snapshot && access_forget_due_ms == 0 {
		access_forget_due_ms = srv.now_ms + owners_forget_snapshot_delay * 1000
	}
}

access_forget_cron :: proc() {
	if !owners_on || access_forget_due_ms == 0 {
		return
	}
	if owners_forget_snapshot_delay <= 0 || access_forget_seq <= access_forget_in_snapshot {
		access_forget_due_ms = 0
		return
	}
	if srv.now_ms >= access_forget_due_ms && !pst.loading && !access_forget_snapshot_warned {
		access_forget_snapshot_warned = true
		access_forget_warn_snapshot()
	}
	if srv.now_ms < access_forget_due_ms || pst.child_pid > 0 || pst.loading || !access_snapshots_on() {
		return
	}
	access_forget_due_ms = 0
	plog(LOG_NOTICE, "Saving a snapshot after OWNERS FORGET")
	if !persist_bgsave() {
		access_snapshot_failed()
	}
}

access_info_forget :: proc(b: ^[dynamic]u8) {
	info_line_int(b, "owners_forget_sequence", i64(access_forget_seq))
	info_line_int(b, "owners_forget_in_snapshot", i64(access_forget_in_snapshot_value()))
	info_line_int(b, "owners_forget_in_aof", i64(access_forget_in_aof_value()))
}

@(private = "file")
access_put_uint :: proc(w: ^rdb.Writer, v: u64) {
	rdb.put_len(w, rdb.MODULE_OPCODE_UINT)
	rdb.put_len(w, v)
}

@(private = "file")
access_put_text :: proc(w: ^rdb.Writer, s: []u8) {
	rdb.put_len(w, ACCESS_MODULE_STRING)
	rdb.put_string(w, s)
}

@(private = "file")
access_record_open :: proc(w: ^rdb.Writer, kind: u64) {
	rdb.put_u8(w, rdb.OPCODE_MODULE_AUX)
	rdb.put_len(w, ACCESS_MODULE_ID)
	rdb.put_len(w, rdb.MODULE_OPCODE_UINT)
	rdb.put_len(w, ACCESS_MODULE_WHEN)
	access_put_uint(w, kind)
}

@(private = "file")
access_record_close :: proc(w: ^rdb.Writer) {
	rdb.put_len(w, rdb.MODULE_OPCODE_EOF)
}

@(private = "file")
access_owner_saved :: proc(e: ^Owner_Entry) -> bool {
	return e.keyspace.parts > 0 || e.keyspace.quota_set
}

access_write_header :: proc(w: ^rdb.Writer, mode: Access_Mode) -> bool {
	blob := make([dynamic]u8, context.temp_allocator)
	if lb.encode(&label_scheme, &label_table, &blob) != .None {
		access_save_refused = "the label scheme could not be encoded"
		return false
	}
	access_save_owners = make([dynamic]^Owner_Entry, context.temp_allocator)
	if mode.owners {
		for e in owner_table.entries {
			if e != nil && access_owner_saved(e) {
				append(&access_save_owners, e)
			}
		}
	}
	quotas := make([dynamic]Access_Quota, context.temp_allocator)
	for id, bytes in label_quotas {
		if bytes > 0 {
			append(&quotas, Access_Quota{u64(id), u64(bytes)})
		}
	}
	slice.sort_by(quotas[:], proc(a, b: Access_Quota) -> bool {
		return a.label < b.label
	})
	access_record_open(w, ACCESS_RECORD_HEADER)
	access_put_uint(w, ACCESS_FORMAT_VERSION)
	access_put_uint(w, access_mode_flags(mode))
	access_put_text(w, blob[:])
	access_put_uint(w, u64(len(quotas)))
	for q in quotas {
		access_put_uint(w, q.label)
		access_put_uint(w, q.bytes)
	}
	access_put_uint(w, u64(len(access_save_owners)))
	for e in access_save_owners {
		access_put_text(w, transmute([]u8)e.text)
		access_put_uint(w, u64(e.keyspace.quota) if e.keyspace.quota_set else 0)
	}
	seed, held := vset_seed_get()
	access_put_uint(w, access_forget_at_fork)
	access_put_uint(w, seed if held else 0)
	access_record_close(w)
	return !w.failed
}

@(private = "file")
access_collect_parts :: proc(dbi: int, out: ^[dynamic]Access_Save_Part) -> (keys: int, expires: int) {
	clear(out)
	if dbi < len(label_dbs) {
		for p in label_dbs[dbi].by_id {
			if p != nil && db_size_of(p) > 0 {
				append(out, Access_Save_Part{p, 0})
			}
		}
		slice.sort_by(out[:], proc(a, b: Access_Save_Part) -> bool {
			return label_less(a.db.label, b.db.label)
		})
	}
	for e, k in access_save_owners {
		s := owner_space_of(e, dbi)
		if s == nil {
			continue
		}
		start := len(out)
		for j in 0 ..< int(s.nparts) {
			d := owner_db(owner_space_at(s, j))
			if db_size_of(d) > 0 {
				append(out, Access_Save_Part{d, u64(k + 1)})
			}
		}
		slice.sort_by(out[start:], proc(a, b: Access_Save_Part) -> bool {
			return label_less(a.db.label, b.db.label)
		})
	}
	for p in out {
		keys += db_size_of(p.db)
		expires += max(p.db.expires, 0)
	}
	return
}

@(private = "file")
access_write_order :: proc(w: ^rdb.Writer, dbi: int) {
	entries := make([dynamic]Access_Save_Order, context.temp_allocator)
	if dbi < len(label_dbs) {
		for _, cp in label_dbs[dbi].copies {
			if len(cp.copies) >= 2 {
				append(&entries, Access_Save_Order{0, cp.name, cp})
			}
		}
	}
	for e, k in access_save_owners {
		s := owner_space_of(e, dbi)
		if s == nil || s.copies == nil {
			continue
		}
		for _, cp in s.copies {
			if len(cp.copies) >= 2 {
				append(&entries, Access_Save_Order{u64(k + 1), cp.name, cp})
			}
		}
	}
	if len(entries) == 0 {
		return
	}
	slice.sort_by(entries[:], proc(a, b: Access_Save_Order) -> bool {
		if a.owner != b.owner {
			return a.owner < b.owner
		}
		return string(a.name) < string(b.name)
	})
	ages := make([dynamic]Label_Copy, context.temp_allocator)
	access_record_open(w, ACCESS_RECORD_ORDER)
	access_put_uint(w, u64(len(entries)))
	for x in entries {
		access_put_uint(w, x.owner)
		access_put_text(w, x.name)
		clear(&ages)
		append(&ages, ..x.cp.copies[:])
		slice.sort_by(ages[:], proc(a, b: Label_Copy) -> bool {
			return a.seq < b.seq
		})
		access_put_uint(w, u64(len(ages)))
		for c in ages {
			access_put_uint(w, u64(c.label))
		}
	}
	access_record_close(w)
}

access_write_dbs :: proc(w: ^rdb.Writer, lru: bool, lfu: bool) -> bool {
	access_vsave_release()
	defer access_vsave_release()
	parts := make([dynamic]Access_Save_Part, context.temp_allocator)
	processed: i64 = 0
	for dbi in 0 ..< len(dbs) {
		keys, expires := access_collect_parts(dbi, &parts)
		if keys == 0 {
			continue
		}
		rdb.put_u8(w, rdb.OPCODE_SELECTDB)
		rdb.put_len(w, u64(dbi))
		rdb.put_u8(w, rdb.OPCODE_RESIZEDB)
		rdb.put_len(w, u64(keys))
		rdb.put_len(w, u64(expires))
		for p in parts {
			access_record_open(w, ACCESS_RECORD_PARTITION)
			access_put_uint(w, u64(p.db.label))
			access_put_uint(w, p.owner)
			access_record_close(w)
			if !persist_write_table(w, p.db, lru, lfu, &processed, true) {
				return false
			}
		}
		access_write_order(w, dbi)
	}
	if !access_vsets_complete() {
		return false
	}
	return !w.failed
}

@(private = "file")
access_len :: proc(r: ^rdb.Reader) -> (u64, bool) {
	v, encoded, got := rdb.get_len_enc(r)
	if !got || encoded {
		return 0, false
	}
	return v, true
}

@(private = "file")
access_get_uint :: proc(r: ^rdb.Reader) -> (u64, bool) {
	op, got := access_len(r)
	if !got || op != rdb.MODULE_OPCODE_UINT {
		return 0, false
	}
	return access_len(r)
}

@(private = "file")
access_get_text :: proc(r: ^rdb.Reader, slot: int) -> ([]u8, bool) {
	op, got := access_len(r)
	if !got || op != ACCESS_MODULE_STRING {
		return nil, false
	}
	return rdb.get_string(r, slot)
}

@(private = "file")
access_get_end :: proc(r: ^rdb.Reader) -> bool {
	op, got := access_len(r)
	return got && op == rdb.MODULE_OPCODE_EOF
}

@(private = "file")
access_text :: proc(parts: ..string) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	for p in parts {
		sb_str(&b, p)
	}
	return string(b[:])
}

@(private = "file")
access_num :: proc(v: u64) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	sb_u64(&b, v)
	return string(b[:])
}

access_key_text :: proc(key: []u8) -> string {
	hexd := "0123456789abcdef"
	b := make([dynamic]u8, context.temp_allocator)
	sb_byte(&b, '\'')
	for ch, i in key {
		if i == ACCESS_KEY_TEXT_MAX {
			sb_str(&b, "...")
			break
		}
		switch {
		case ch == '\\' || ch == '\'':
			sb_byte(&b, '\\')
			sb_byte(&b, ch)
		case ch >= 0x20 && ch < 0x7f:
			sb_byte(&b, ch)
		case:
			sb_str(&b, "\\x")
			sb_byte(&b, hexd[ch >> 4])
			sb_byte(&b, hexd[ch & 15])
		}
	}
	sb_byte(&b, '\'')
	return string(b[:])
}

access_header_destroy :: proc(h: ^Access_Header) {
	if h.ready {
		lb.config_destroy(&h.scheme)
		lb.table_destroy(&h.table)
	}
	for o in h.owners {
		delete(o.text)
	}
	delete(h.owners)
	delete(h.quotas)
	h^ = {}
}

@(private = "file")
ACCESS_HEADER_MALFORMED :: "the file has a malformed labelled header"

access_read_header :: proc(r: ^rdb.Reader, h: ^Access_Header) -> string {
	version, got := access_get_uint(r)
	if !got {
		return ACCESS_HEADER_MALFORMED
	}
	if version != ACCESS_FORMAT_VERSION {
		return access_text("the file has a labelled header of format version ", access_num(version), ", which this release cannot read")
	}
	flags, got_flags := access_get_uint(r)
	if !got_flags {
		return ACCESS_HEADER_MALFORMED
	}
	if flags == 0 || flags & ~(ACCESS_FLAG_LABELLED | ACCESS_FLAG_OWNERS) != 0 {
		return "the file has a labelled header with unknown mode flags"
	}
	h.flags = flags
	blob, got_blob := access_get_text(r, 0)
	if !got_blob {
		return ACCESS_HEADER_MALFORMED
	}
	if lb.decode(blob, &h.scheme, &h.table) != .None {
		return "the file has a labelled header whose label scheme does not decode"
	}
	h.ready = true
	if (flags & ACCESS_FLAG_LABELLED != 0) != lb.config_labelled(&h.scheme) {
		return "the file has a labelled header whose mode flags do not match its label scheme"
	}
	count := u64(lb.table_count(&h.table))
	nq, got_nq := access_get_uint(r)
	if !got_nq {
		return ACCESS_HEADER_MALFORMED
	}
	if nq > count {
		return "the file has a labelled header with more label quotas than labels"
	}
	quoted := make([]u8, (count + 7) / 8, context.temp_allocator)
	for _ in 0 ..< nq {
		label, got_label := access_get_uint(r)
		bytes, got_bytes := access_get_uint(r)
		if !got_label || !got_bytes {
			return ACCESS_HEADER_MALFORMED
		}
		if label >= count {
			return access_text("the file has a labelled header with a quota for label ", access_num(label), " beyond its label table")
		}
		if bytes == 0 || bytes > u64(max(i64)) {
			return "the file has a labelled header with an invalid label quota"
		}
		if access_bit_has(quoted, int(label)) {
			return "the file has a labelled header with two quotas for one label"
		}
		access_bit_put(quoted, int(label), true)
		append(&h.quotas, Access_Quota{label, bytes})
	}
	no, got_no := access_get_uint(r)
	if !got_no {
		return ACCESS_HEADER_MALFORMED
	}
	if no > 0 && flags & ACCESS_FLAG_OWNERS == 0 {
		return "the file has a labelled header that lists owners without owner mode"
	}
	if no > u64(ow.LAST_USER) {
		return "the file has a labelled header with more owners than owner ids exist"
	}
	seen := make(map[string]bool, context.temp_allocator)
	for k in 0 ..< no {
		text, got_text := access_get_text(r, 1)
		if !got_text {
			return ACCESS_HEADER_MALFORMED
		}
		if !ow.text_valid(text) {
			return access_text("the file has a labelled header whose owner ", access_num(k + 1), " has an invalid id")
		}
		if string(text) in seen {
			return access_text("the file has a labelled header whose owner ", access_num(k + 1), " repeats an earlier owner")
		}
		owned := make([]u8, len(text))
		copy(owned, text)
		seen[string(owned)] = true
		quota, got_quota := access_get_uint(r)
		if !got_quota {
			delete(owned)
			return ACCESS_HEADER_MALFORMED
		}
		if quota > u64(max(i64)) {
			delete(owned)
			return "the file has a labelled header with an invalid owner quota"
		}
		append(&h.owners, Access_Owner_Record{owned, quota})
	}
	forget, got_forget := access_get_uint(r)
	seed, got_seed := access_get_uint(r)
	if !got_forget || !got_seed || !access_get_end(r) {
		return ACCESS_HEADER_MALFORMED
	}
	h.forget = forget
	h.seed = seed
	return ""
}

access_header_refusal :: proc(h: ^Access_Header, adopt: bool) -> string {
	file := access_mode_of_flags(h.flags)
	if !labels_on {
		return ACCESS_LABELLED_FILE
	}
	server := access_server_mode()
	if file != server {
		return access_text("was written with ", access_mode_words(file), " and this server runs with ", access_mode_words(server), "; start the server with the label scheme and owner mode the file was written with")
	}
	if msg, _ := label_scheme_merge(&h.scheme, adopt); msg != "" {
		return msg
	}
	if owners_on && label_scheme_reserved(&h.scheme) {
		return "names a level OWNER or SHARED in its label scheme, which owner mode reserves"
	}
	return ""
}

access_load_begin :: proc() {
	access_load_free()
	access_ld.startup = access_load_startup
}

access_load_free :: proc() {
	ld := &access_ld
	access_header_destroy(&ld.header)
	delete(ld.labels)
	delete(ld.owners)
	delete(ld.created)
	delete(ld.parts)
	delete(ld.dbs)
	access_load_clear_db()
	delete(ld.orders)
	delete(ld.dead)
	vset_load_context_destroy(&ld.vctx)
	delete(ld.vsets)
	ld^ = Access_Load {
		db = -1,
	}
}

@(private = "file")
access_load_clear_db :: proc() {
	ld := &access_ld
	for o in ld.orders {
		delete(o.name)
		delete(o.labels)
	}
	clear(&ld.orders)
	for _, names in ld.dead {
		for _, d in names {
			delete(d.labels)
			delete(d.name)
			free(d)
		}
		delete(names^)
		free(names)
	}
	clear(&ld.dead)
}

@(private = "file")
access_bit_put :: #force_inline proc "contextless" (bits: []u8, i: int, on: bool) {
	if on {
		bits[i >> 3] |= u8(1) << uint(i & 7)
	} else {
		bits[i >> 3] &~= u8(1) << uint(i & 7)
	}
}

@(private = "file")
access_bit_has :: #force_inline proc "contextless" (bits: []u8, i: int) -> bool {
	return bits[i >> 3] & (u8(1) << uint(i & 7)) != 0
}

@(private = "file")
access_name_add :: proc(sets: ^map[u64]^Access_Names, owner: u64, name: []u8) {
	set, found := sets[owner]
	if !found {
		set = new(Access_Names, context.temp_allocator)
		set^ = make(Access_Names, context.temp_allocator)
		sets[owner] = set
	}
	set^[string(name)] = true
}

@(private = "file")
access_name_has :: proc(sets: ^map[u64]^Access_Names, owner: u64, name: []u8) -> bool {
	set, found := sets[owner]
	return found && string(name) in set^
}

@(private = "file")
access_dead_find :: proc(owner: u64, name: []u8) -> ^Access_Dead {
	names, found := access_ld.dead[owner]
	if !found {
		return nil
	}
	d, has := names^[string(name)]
	if !has {
		return nil
	}
	return d
}

access_load_module :: proc(r: ^rdb.Reader) -> (msg: string, refusal: bool) {
	if !labels_on {
		return ACCESS_LABELLED_FILE, true
	}
	when_op, got_op := access_len(r)
	when_value, got_value := access_len(r)
	if !got_op || !got_value {
		return "the file has a malformed labelled record", false
	}
	if when_op != rdb.MODULE_OPCODE_UINT || when_value != ACCESS_MODULE_WHEN {
		return "the file has a labelled record with an unknown placement", false
	}
	kind, got_kind := access_get_uint(r)
	if !got_kind {
		return "the file has a malformed labelled record", false
	}
	ld := &access_ld
	if kind == ACCESS_RECORD_HEADER {
		if ld.active {
			return "the file has a second labelled header", false
		}
		return access_load_header(r)
	}
	if !ld.active {
		return "the file has a labelled record before its labelled header", false
	}
	switch kind {
	case ACCESS_RECORD_PARTITION:
		return access_load_partition(r), false
	case ACCESS_RECORD_ORDER:
		return access_load_order(r), false
	}
	return access_text("the file has a labelled record of unknown kind ", access_num(kind)), false
}

@(private = "file")
access_load_header :: proc(r: ^rdb.Reader) -> (string, bool) {
	ld := &access_ld
	h := &ld.header
	if msg := access_read_header(r, h); msg != "" {
		return msg, false
	}
	if msg := access_header_refusal(h, true); msg != "" {
		return msg, true
	}
	ld.mode = access_mode_of_flags(h.flags)
	for i in 0 ..< lb.table_count(&h.table) {
		l, _ := lb.table_label(&h.table, lb.Id(i))
		id, interned := access_intern(l)
		if !interned {
			return "the file has a label table that does not fit the server's label table", false
		}
		append(&ld.labels, id)
	}
	append(&ld.owners, nil)
	append(&ld.created, false)
	for rec in h.owners {
		existed := owner_lookup(rec.text) != nil
		e, err := owner_intern(rec.text)
		if err != .None {
			return "the file has more owners than the server's owner table holds", false
		}
		append(&ld.owners, e)
		append(&ld.created, !existed)
	}
	ld.active = true
	return "", false
}

@(private = "file")
access_load_owner_check :: proc(owner: u64) -> string {
	ld := &access_ld
	if owner != 0 && !ld.mode.owners {
		return "the file has a labelled record that names an owner without owner mode"
	}
	if owner >= u64(len(ld.owners)) {
		return access_text("the file has a labelled record that names owner ", access_num(owner), " beyond its owner table")
	}
	return ""
}

@(private = "file")
access_load_partition :: proc(r: ^rdb.Reader) -> string {
	ld := &access_ld
	label, got_label := access_get_uint(r)
	owner, got_owner := access_get_uint(r)
	if !got_label || !got_owner || !access_get_end(r) {
		return "the file has a malformed partition record"
	}
	if ld.db < 0 {
		return "the file has a partition record outside any database"
	}
	if ld.ordered {
		return "the file has a partition record after the copy order of its database"
	}
	if label >= u64(len(ld.labels)) {
		return access_text("the file has a partition record for label ", access_num(label), " beyond its label table")
	}
	if msg := access_load_owner_check(owner); msg != "" {
		return msg
	}
	key := Access_Load_Part{ld.db, label, owner}
	if key in ld.parts {
		return access_text("the file has two partition records for label ", access_num(label), " and owner ", access_num(owner), " of the file in one database")
	}
	ld.parts[key] = true
	if owners_on {
		owner_settle()
	}
	ld.in_part = true
	ld.part_label = label
	ld.part_owner = owner
	ld.part = nil
	return ""
}

@(private = "file")
access_load_order :: proc(r: ^rdb.Reader) -> string {
	ld := &access_ld
	if ld.db < 0 {
		return "the file has a copy order outside any database"
	}
	if ld.ordered {
		return "the file has two copy orders for one database"
	}
	n, got_n := access_get_uint(r)
	if !got_n {
		return "the file has a malformed copy order"
	}
	if n > ld.db_keys / 2 {
		return "the file has a copy order with more entries than its database has copies"
	}
	seen := make(map[u64]^Access_Names, context.temp_allocator)
	marks := make([]u8, (len(ld.labels) + 7) / 8, context.temp_allocator)
	for _ in 0 ..< n {
		owner, got_owner := access_get_uint(r)
		if !got_owner {
			return "the file has a malformed copy order"
		}
		if msg := access_load_owner_check(owner); msg != "" {
			return msg
		}
		name, got_name := access_get_text(r, 1)
		if !got_name {
			return "the file has a malformed copy order"
		}
		k, got_k := access_get_uint(r)
		if !got_k {
			return "the file has a malformed copy order"
		}
		if k < 2 || k > u64(len(ld.labels)) {
			return access_text("the file has a copy order for key ", access_key_text(name), " that does not list two or more copies")
		}
		if access_name_has(&seen, owner, name) {
			return access_text("the file has a copy order that lists key ", access_key_text(name), " twice")
		}
		owned := make([]u8, len(name))
		copy(owned, name)
		access_name_add(&seen, owner, owned)
		labels := make([]u64, int(k))
		append(&ld.orders, Access_Order{owner, owned, labels})
		for j in 0 ..< int(k) {
			label, got_label := access_get_uint(r)
			if !got_label {
				return "the file has a malformed copy order"
			}
			held := Access_Load_Part{ld.db, label, owner}
			if label >= u64(len(ld.labels)) || held not_in ld.parts {
				return access_text("the file has a copy order for key ", access_key_text(owned), " that names a partition the file does not hold")
			}
			if access_bit_has(marks, int(label)) {
				return access_text("the file has a copy order for key ", access_key_text(owned), " that lists one copy twice")
			}
			access_bit_put(marks, int(label), true)
			labels[j] = label
		}
		for x in labels {
			access_bit_put(marks, int(x), false)
		}
	}
	if !access_get_end(r) {
		return "the file has a malformed copy order"
	}
	if owners_on {
		owner_settle()
	}
	ld.ordered = true
	ld.in_part = false
	ld.part = nil
	return ""
}

access_load_select :: proc(dbi: int) -> string {
	ld := &access_ld
	if msg := access_load_db_end(); msg != "" {
		return msg
	}
	if dbi in ld.dbs {
		return access_text("the file selects database ", access_num(u64(dbi)), " twice")
	}
	ld.dbs[dbi] = true
	ld.db = dbi
	return ""
}

access_load_in_part :: #force_inline proc "contextless" () -> bool {
	return access_ld.in_part
}

@(private = "file")
access_dead_has :: proc(owner: u64, key: []u8, label: u64) -> bool {
	if len(access_ld.dead) == 0 {
		return false
	}
	d := access_dead_find(owner, key)
	if d == nil {
		return false
	}
	for x in d.labels {
		if x == label {
			return true
		}
	}
	return false
}

access_load_target :: proc(key: []u8) -> (target: ^Db, msg: string, duplicate: bool) {
	ld := &access_ld
	if access_dead_has(ld.part_owner, key, ld.part_label) {
		return nil, "", true
	}
	ld.db_keys += 1
	if ld.part != nil {
		if ld.part_owner != 0 {
			owner_touch(ld.part)
		}
		return ld.part, "", false
	}
	label := ld.labels[ld.part_label]
	if ld.part_owner == 0 {
		p, made := label_part_make(ld.db, label)
		if !made {
			return nil, "the file holds more label partitions than label-partitions-max allows", false
		}
		ld.part = p
		return p, "", false
	}
	e := ld.owners[ld.part_owner]
	p, made := owner_part_make(e, ld.db, label)
	if !made {
		return nil, "the file holds more owner partitions than owner-partitions-max allows", false
	}
	ld.part = owner_db(p)
	owner_touch(ld.part)
	return ld.part, "", false
}

access_load_vset :: proc(r: ^rdb.Reader, key: []u8, keep: bool) -> (s: vt.Vset, good: bool) {
	ld := &access_ld
	id := rdb.get_len(r)
	if !rdb.ok(r) {
		return nil, false
	}
	if !vset_rdb_module(id) {
		name: [9]u8
		rdb.corrupt(r, "holds data of unknown module type '", 0, false, rdb.module_name_by_id(id, &name))
		rdb.corrupt_append(r, "'")
		return nil, false
	}
	owner := vt.SHARED
	if ld.part_owner != 0 {
		owner = vt.Owner(ld.owners[ld.part_owner].number)
	}
	label := ld.labels[ld.part_label]
	if !keep {
		return nil, vset_rdb_discard_part(r, &ld.vctx, id, ld.db, key, label, owner)
	}
	s, _ = vset_rdb_load_part(r, &ld.vctx, id, ld.db, key, label, owner)
	if s == nil {
		return nil, false
	}
	append(&ld.vsets, Access_Vset{s, owner})
	return s, true
}

access_load_presence :: proc(part: ^Db, key: []u8, due: i64, s: vt.Vset) -> (e: ^Entry, created: bool) {
	if e, created = db_upsert_timed_in(part, key, due); !created {
		return
	}
	entry_object_attach(e, s, .Vectorset, .Raw, 0)
	return
}

access_load_vsets_finish :: proc(r: ^rdb.Reader) -> bool {
	return vset_rdb_load_finish(r, &access_ld.vctx)
}

access_load_seed :: proc() -> (seed: u64, found: bool) {
	h := &access_ld.header
	return h.seed, h.seed != 0
}

@(private = "file")
access_load_vset_charges :: proc(dbi: int) {
	ld := &access_ld
	if len(ld.vsets) == 0 {
		return
	}
	done := make(map[[2]u64]bool, context.temp_allocator)
	sets := make(map[vt.Vset]bool, context.temp_allocator)
	for x in ld.vsets {
		pair := [2]u64{u64(uintptr(rawptr(x.set))), u64(x.owner)}
		if pair in done {
			continue
		}
		done[pair] = true
		if x.set not_in sets {
			sets[x.set] = true
			label_vset_settle(dbi, Vset_Snap{owner = ow.SHARED, shared = true}, x.set)
		}
		if x.owner != vt.SHARED {
			label_vset_settle(dbi, Vset_Snap{owner = ow.Owner(x.owner), shared = false, mem = vt.memory_usage(x.set)}, x.set)
		}
	}
	clear(&ld.vsets)
}

access_load_dead :: proc(key: []u8) -> (duplicate: bool) {
	ld := &access_ld
	if ld.part != nil {
		l := lookup_make(key)
		if _, i := db_locate_slot(ld.part, &l); i >= 0 {
			return true
		}
	}
	if access_dead_has(ld.part_owner, key, ld.part_label) {
		return true
	}
	d := access_dead_find(ld.part_owner, key)
	if d == nil {
		names, found := ld.dead[ld.part_owner]
		if !found {
			names = new(Access_Dead_Names)
			ld.dead[ld.part_owner] = names
		}
		d = new(Access_Dead)
		d.owner = ld.part_owner
		d.name = make([]u8, len(key))
		copy(d.name, key)
		names^[string(d.name)] = d
	}
	append(&d.labels, ld.part_label)
	ld.db_keys += 1
	return false
}

@(private = "file")
access_load_live :: proc(dbi: int, e: ^Owner_Entry, name: []u8, out: ^[dynamic]lb.Id) {
	clear(out)
	l := lookup_make(name)
	if e == nil {
		ld := &label_dbs[dbi]
		if len(ld.copies) > 0 {
			if cp, found := ld.copies[string(name)]; found {
				for c in cp.copies {
					append(out, c.label)
				}
				return
			}
		}
		for p in ld.by_id {
			if p != nil && db_size_of(p) > 0 {
				if _, i := db_locate_slot(p, &l); i >= 0 {
					append(out, p.label)
				}
			}
		}
		return
	}
	s := owner_space_of(e, dbi)
	if s == nil {
		return
	}
	if s.copies != nil && len(s.copies) > 0 {
		if cp, found := s.copies[string(name)]; found {
			for c in cp.copies {
				append(out, c.label)
			}
			return
		}
	}
	for k in 0 ..< int(s.nparts) {
		q := owner_db(owner_space_at(s, k))
		if _, i := db_locate_slot(q, &l); i >= 0 {
			append(out, q.label)
		}
	}
}

@(private = "file")
access_load_registry :: proc(dbi: int, e: ^Owner_Entry, name: []u8) -> ^Label_Copies {
	if e == nil {
		ld := &label_dbs[dbi]
		if cp, found := ld.copies[string(name)]; found {
			return cp
		}
		return nil
	}
	s := owner_space_of(e, dbi)
	if s == nil || s.copies == nil {
		return nil
	}
	if cp, found := s.copies[string(name)]; found {
		return cp
	}
	return nil
}

@(private = "file")
access_load_unordered :: proc(name: []u8) -> string {
	return access_text("the file holds key ", access_key_text(name), " in two or more partitions of database ", access_num(u64(access_ld.db)), " without their copy order")
}

access_load_db_end :: proc() -> string {
	ld := &access_ld
	if !ld.active || ld.db < 0 {
		return ""
	}
	access_load_vset_charges(ld.db)
	if owners_on {
		owner_settle()
	}
	dbi := ld.db
	covered := make(map[u64]^Access_Names, context.temp_allocator)
	live := make([dynamic]lb.Id, context.temp_allocator)
	pruned := make([dynamic]lb.Id, context.temp_allocator)
	server_n := lb.table_count(&label_table)
	listed := make([]u8, (server_n + 7) / 8, context.temp_allocator)
	alive := make([]u8, (server_n + 7) / 8, context.temp_allocator)
	rank := make([]u32, server_n, context.temp_allocator)
	for o in ld.orders {
		e := ld.owners[o.owner] if o.owner > 0 else nil
		access_load_live(dbi, e, o.name, &live)
		d := access_dead_find(o.owner, o.name)
		dead_n := len(d.labels) if d != nil else 0
		if len(live) + dead_n != len(o.labels) {
			return access_text("the file has a copy order for key ", access_key_text(o.name), " that does not match the partitions holding it")
		}
		for y in o.labels {
			access_bit_put(listed, int(ld.labels[y]), true)
		}
		whole := true
		for id in live {
			whole = whole && access_bit_has(listed, int(id)) && !access_bit_has(alive, int(id))
			access_bit_put(alive, int(id), true)
		}
		if d != nil {
			for x in d.labels {
				id := int(ld.labels[x])
				whole = whole && access_bit_has(listed, id) && !access_bit_has(alive, id)
			}
		}
		clear(&pruned)
		for y in o.labels {
			if id := ld.labels[y]; access_bit_has(alive, int(id)) {
				append(&pruned, id)
			}
			access_bit_put(listed, int(ld.labels[y]), false)
		}
		for id in live {
			access_bit_put(alive, int(id), false)
		}
		if !whole {
			return access_text("the file has a copy order for key ", access_key_text(o.name), " that leaves out one of its copies")
		}
		access_name_add(&covered, o.owner, o.name)
		if len(pruned) < 2 {
			continue
		}
		cp := access_load_registry(dbi, e, o.name)
		if cp == nil || len(cp.copies) != len(pruned) {
			return access_text("the file has a copy order for key ", access_key_text(o.name), " that does not match the partitions holding it")
		}
		for id, i in pruned {
			rank[id] = u32(i + 1)
		}
		base := label_copy_seq
		matched := true
		for &c in cp.copies {
			if r := rank[c.label]; r != 0 {
				c.seq = base + u64(r)
			} else {
				matched = false
			}
		}
		for id in pruned {
			rank[id] = 0
		}
		label_copy_seq += u64(len(pruned))
		if !matched {
			return access_text("the file has a copy order for key ", access_key_text(o.name), " that does not match the partitions holding it")
		}
	}
	if dbi < len(label_dbs) {
		for name in label_dbs[dbi].copies {
			if !access_name_has(&covered, 0, transmute([]u8)name) {
				return access_load_unordered(transmute([]u8)name)
			}
		}
	}
	for k in 1 ..< len(ld.owners) {
		s := owner_space_of(ld.owners[k], dbi)
		if s == nil || s.copies == nil {
			continue
		}
		for name in s.copies {
			if !access_name_has(&covered, u64(k), transmute([]u8)name) {
				return access_load_unordered(transmute([]u8)name)
			}
		}
	}
	for _, names in ld.dead {
		for _, d in names^ {
			if access_name_has(&covered, d.owner, d.name) {
				continue
			}
			e := ld.owners[d.owner] if d.owner > 0 else nil
			access_load_live(dbi, e, d.name, &live)
			if len(live) + len(d.labels) >= 2 {
				return access_load_unordered(d.name)
			}
		}
	}
	access_load_clear_db()
	ld.db = -1
	ld.db_keys = 0
	ld.in_part = false
	ld.part = nil
	ld.ordered = false
	return ""
}

access_load_finish :: proc() -> string {
	ld := &access_ld
	if !ld.active {
		return ""
	}
	if msg := access_load_db_end(); msg != "" {
		return msg
	}
	h := &ld.header
	for q in h.quotas {
		label_quotas[ld.labels[q.label]] = int(q.bytes)
	}
	for rec, k in h.owners {
		e := ld.owners[k + 1]
		e.keyspace.quota = i64(rec.quota)
		e.keyspace.quota_set = rec.quota > 0
	}
	for k in 1 ..< len(ld.owners) {
		e := ld.owners[k]
		ks := &e.keyspace
		if ld.created[k] && !ld.served && ks.parts == 0 && !ks.quota_set && ks.space == nil && ks.spaces == nil {
			owner_drop(e.number)
		}
	}
	if h.forget > access_forget_seq {
		access_forget_seq = h.forget
	}
	if aof.loading {
		access_forget_in_aof = h.forget
	} else {
		if ld.startup {
			access_forget_in_snapshot = h.forget
		}
		access_snapshot_used = true
	}
	access_load_free()
	return ""
}

access_file_probe :: proc(name: string) -> string {
	pbuf: [PERSIST_PATH_MAX]u8
	fd, err := linux.open(persist_cstr(name, pbuf[:]), {.CLOEXEC})
	if err != .NONE {
		return ""
	}
	defer linux.close(fd)
	r: rdb.Reader
	rdb.reader_init_file(&r, fd, false)
	defer rdb.reader_destroy(&r)
	sr: Seal_File_Reader
	if refusal := seal_probe_attach(&r, &sr, fd); refusal != "" {
		return refusal
	}
	defer seal_reader_release(&r, &sr)
	magic, got := rdb.take(&r, 9)
	if !got || string(magic[:5]) != "REDIS" {
		return ""
	}
	for {
		t := rdb.get_type(&r)
		switch t {
		case rdb.OPCODE_AUX:
			rdb.get_string(&r, 0)
			rdb.get_string(&r, 1)
			if !rdb.ok(&r) {
				return ""
			}
			continue
		case rdb.OPCODE_MODULE_AUX:
			id, got_id := access_len(&r)
			if !got_id || id != ACCESS_MODULE_ID {
				return ""
			}
			op, got_op := access_len(&r)
			when_value, got_when := access_len(&r)
			kind, got_kind := access_get_uint(&r)
			if !got_op || !got_when || !got_kind || op != rdb.MODULE_OPCODE_UINT || when_value != ACCESS_MODULE_WHEN || kind != ACCESS_RECORD_HEADER {
				return ""
			}
			h: Access_Header
			defer access_header_destroy(&h)
			if access_read_header(&r, &h) != "" {
				return ""
			}
			return access_header_refusal(&h, false)
		case -1:
			return ""
		}
		if labels_on {
			return LABEL_STARTUP_FILE
		}
		return ""
	}
}

access_flush_everything :: proc() {
	if owners_on {
		doomed := make([dynamic]^Owner_Part, context.temp_allocator)
		for dbi in 0 ..< len(owner_dbs) {
			for sp in owner_dbs[dbi].spaces {
				for k in 0 ..< int(sp.nparts) {
					append(&doomed, owner_space_at(sp, k))
				}
			}
		}
		for q in doomed {
			owner_part_flush(q, false, false)
		}
	}
	db_flush_all()
}

access_flush_everything_ran :: proc() -> bool {
	if !labels_on {
		return true
	}
	if !access.top {
		return false
	}
	return !owners_on || (!owner_user() && !access.owner_named)
}

access_save_scheme :: proc() -> bool {
	if pst.child_pid > 0 && !pst.child_aof {
		persist_kill_child()
	}
	return persist_rdb_save()
}

access_save_empty :: proc(mode: Access_Mode) -> bool {
	if pst.child_pid > 0 && !pst.child_aof {
		persist_kill_child()
	}
	access_save_forced = true
	access_save_forced_mode = mode
	defer access_save_forced = false
	return persist_rdb_save()
}

@(private = "file")
access_configured_file :: proc(name: string) -> bool {
	return name == persist_filename() || name == aof.filename || name == aof.dirname
}

@(private = "file")
access_stale_temp :: proc(name: string) -> bool {
	if access_configured_file(name) {
		return false
	}
	pid := ""
	switch {
	case len(name) > len("temp-.rdb") && name[:5] == "temp-" && name[len(name) - 4:] == ".rdb":
		pid = name[5:len(name) - 4]
	case len(name) > len("temp-rewriteaof-bg-.aof") && name[:19] == "temp-rewriteaof-bg-" && name[len(name) - 4:] == ".aof":
		pid = name[19:len(name) - 4]
	case len(name) > len("temp-rewriteaof-.aof") && name[:16] == "temp-rewriteaof-" && name[len(name) - 4:] == ".aof":
		pid = name[16:len(name) - 4]
	case:
		return false
	}
	if len(pid) == 0 || len(pid) > 10 {
		return false
	}
	for ch in transmute([]u8)pid {
		if ch < '0' || ch > '9' {
			return false
		}
	}
	if pid == access_num(u64(linux.getpid())) {
		return true
	}
	pbuf: [64]u8
	st: linux.Stat
	return linux.stat(persist_cstr(access_text("/proc/", pid), pbuf[:]), &st) == .ENOENT
}

access_startup_cleanup :: proc() {
	if !labels_on {
		return
	}
	dfd, err := linux.open(".", {.DIRECTORY, .CLOEXEC})
	if err != .NONE {
		return
	}
	defer linux.close(dfd)
	stale := make([dynamic]string, context.temp_allocator)
	buf: [4096]u8
	for {
		n, derr := linux.getdents(dfd, buf[:])
		if derr != .NONE || n <= 0 {
			break
		}
		offset := 0
		for d in linux.dirent_iterate_buf(buf[:n], &offset) {
			name := linux.dirent_name(d)
			if access_stale_temp(name) {
				append(&stale, access_text(name))
			}
		}
	}
	for name in stale {
		cbuf: [PERSIST_PATH_MAX]u8
		if linux.unlink(persist_cstr(name, cbuf[:])) == .NONE {
			plog(LOG_NOTICE, "Removed the stale temporary file ", name)
		}
	}
}
