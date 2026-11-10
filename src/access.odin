package main

import lb "label"
import ow "owner"

ERR_LABEL_INVALID :: "ERR invalid label"
ERR_LABELS_OFF :: "ERR labels are not configured on this server"
ERR_LABEL_CONTEXT :: "ERR invalid context"
ERR_LABEL_TOKEN :: "ERR invalid label token"
ERR_LABEL_PER_COMMAND :: "ERR this login must send every command through LABEL AS"
ERR_LABEL_TOKEN_ONLY :: "ERR this login must send every command through LABEL AS TOKEN"
ERR_LABEL_SESSION_NEEDED :: "ERR this command needs a session label set with LABEL SESSION"
ERR_LABEL_SESSION_DENIED :: "ERR LABEL SESSION is not available to this login"
ERR_LABEL_TRANSACTION :: "ERR the command's label differs from the transaction's label"
ERR_LABEL_WATCH_EXEC :: "EXECABORT Transaction discarded because of: the command's label differs from the transaction's label"
ERR_LABEL_NESTED :: "ERR LABEL AS cannot wrap LABEL AS or LABEL SESSION"
ERR_LABEL_CONTEXT_MISMATCH :: "ERR the label differs from the context's label"
ERR_LABEL_TOP :: "ERR this command needs a label that dominates the whole label scheme"
ERR_LABEL_PERSISTENCE :: "ERR persistence is off while a label scheme is configured"
ERR_LABEL_SCRIPT :: "ERR this command needs a label that dominates the running script's label"
ERR_OWNER_INVALID :: "ERR invalid owner"
ERR_OWNERS_OFF :: "ERR owners are not enabled on this server"
ERR_OWNER_REQUIRED :: "ERR this login must name an owner with every command"
ERR_OWNER_CONTEXT :: "ERR the owner differs from the context's owner"
ERR_OWNER_BOUND :: "ERR this connection is bound to another owner"
ERR_OWNER_TRANSACTION :: ERR_LABEL_TRANSACTION

Access :: struct {
	label:       lb.Label,
	id:          lb.Id,
	vis:         ^lb.Visibility,
	top:         bool,
	label_top:   bool,
	operator:    bool,
	ctx:         ^Label_Context,
	owner:       ow.Owner,
	owner_entry: ^Owner_Entry,
}

Access_Conn :: struct {
	session:        lb.Label,
	explicit:       bool,
	owner_pinned:   bool,
	pin_owner:      ow.Owner,
	bound:          lb.Label,
	bound_prefixed: bool,
	owner:          ow.Owner,
	implicit:       lb.Label,
	monitor:        lb.Label,
	watched:        lb.Label,
	watching:       bool,
	watch_mixed:    bool,
	ran:            bool,
	watched_owner:  ow.Owner,
	accounted:      int,
}

#assert(size_of(Access_Conn) == 232)

Owner_Kind :: enum u8 {
	None,
	Any,
	Fixed,
}

Acl_Label_Rules :: struct {
	clearance:      lb.Label,
	clearance_set:  bool,
	clearance_top:  bool,
	trust:          u8,
	trust_set:      bool,
	trust_top:      bool,
	per_command:    bool,
	require_token:  bool,
	keys:           [dynamic][32]u8,
	owners:         Owner_Kind,
	owner_shared:   bool,
	owner_operator: bool,
	owner_len:      u8,
	owner_id:       [ow.TEXT_MAX]u8,
}

Owner_Pick :: enum u8 {
	None,
	Text,
	Shared,
}

Access_Arrival :: struct {
	pick:       Owner_Pick,
	text:       []u8,
	owner_only: bool,
	token:      bool,
	pin:        bool,
	token_pick: Owner_Pick,
	token_len:  u8,
	token_buf:  [ow.TEXT_MAX]u8,
}

labels_on: bool
owners_on: bool
label_scheme: lb.Config
label_table: lb.Table
access: Access
access_arrival: Access_Arrival

@(private = "file")
ACCESS_VIS_SLOTS :: 64

@(private = "file")
Access_Vis_Slot :: struct {
	vis:    lb.Visibility,
	reader: lb.Id,
	stamp:  u64,
	live:   bool,
}

@(private = "file")
access_vis_slots: [ACCESS_VIS_SLOTS]Access_Vis_Slot

@(private = "file")
access_vis_where: [dynamic]u8

@(private = "file")
access_vis_clock: u64

@(private = "file")
access_ready: bool

access_init :: proc() {
	if access_ready {
		return
	}
	access_ready = true
	lb.config_default(&label_scheme)
	lb.table_init(&label_table)
	access_scheme_changed()
}

access_on :: #force_inline proc "contextless" () -> bool {
	return labels_on
}

@(private = "file")
access_top_label: lb.Label

access_scheme_changed :: proc "contextless" () {
	access_top_label, _ = lb.config_top(&label_scheme)
}

access_scheme_top :: #force_inline proc "contextless" () -> lb.Label {
	return access_top_label
}

access_label_of :: proc "contextless" (id: lb.Id) -> (lb.Label, bool) {
	return lb.table_label(&label_table, id)
}

access_visible :: #force_inline proc "contextless" (id: lb.Id) -> bool {
	return lb.visible(access.vis, id)
}

access_dominates :: proc "contextless" (reader, data: lb.Id) -> bool {
	r, rok := lb.table_label(&label_table, reader)
	d, dok := lb.table_label(&label_table, data)
	return rok && dok && lb.dominates(r, d)
}

access_compare :: proc "contextless" (a, b: lb.Id) -> int {
	first, _ := lb.table_label(&label_table, a)
	second, _ := lb.table_label(&label_table, b)
	return lb.resolution_compare(first, second)
}

scope_sees :: proc "contextless" (reader, data: ow.Scope) -> bool {
	return access_dominates(reader.label, data.label) && ow.sees(reader.owner, data.owner)
}

scope_compare :: proc "contextless" (reader_owner: ow.Owner, a, b: ow.Scope) -> int {
	if r := access_compare(a.label, b.label); r != 0 {
		return r
	}
	return ow.rank(reader_owner, a.owner, b.owner)
}

scope_format :: proc(b: ^[dynamic]u8, scope: ow.Scope) {
	if !owners_on {
		return
	}
	if scope.owner == ow.SHARED {
		sb_str(b, " SHARED")
		return
	}
	text, _ := owner_text(scope.owner)
	sb_str(b, " OWNER ")
	sb_str(b, text)
}

access_scope :: #force_inline proc "contextless" () -> ow.Scope {
	return ow.Scope{access.id, access.owner}
}

access_view_owner :: #force_inline proc "contextless" () -> ow.Owner {
	return ow.EVERY if access.operator else access.owner
}

access_intern :: proc(l: lb.Label) -> (lb.Id, bool) {
	if !lb.config_valid(&label_scheme, l) {
		return lb.ID_NONE, false
	}
	id, e := lb.table_intern(&label_table, l)
	if e != .None {
		return lb.ID_NONE, false
	}
	if access.vis != nil {
		lb.visibility_refresh(access.vis, &label_table)
	}
	return id, true
}

access_format_label :: proc(b: ^[dynamic]u8, l: lb.Label) -> bool {
	text, ok := lb.format(&label_scheme, l, context.temp_allocator)
	if !ok {
		return false
	}
	sb_str(b, text)
	return true
}

access_format :: proc(b: ^[dynamic]u8, id: lb.Id) -> bool {
	l, ok := lb.table_label(&label_table, id)
	if !ok {
		return false
	}
	return access_format_label(b, l)
}

access_format_marking :: proc(b: ^[dynamic]u8, l: lb.Label) -> bool {
	secrecy := l
	secrecy.trust = 0
	return access_format_label(b, secrecy)
}

access_trust_name :: proc(l: lb.Label) -> string {
	return lb.config_trust_name(&label_scheme, int(l.trust))
}

access_visibility :: proc(reader: lb.Id) -> ^lb.Visibility {
	i := int(reader)
	if i >= len(access_vis_where) {
		resize(&access_vis_where, max(i + 1, lb.table_count(&label_table)))
	}
	access_vis_clock += 1
	if k := access_vis_where[i]; k != 0 {
		s := &access_vis_slots[k - 1]
		s.stamp = access_vis_clock
		lb.visibility_refresh(&s.vis, &label_table)
		return &s.vis
	}
	victim := -1
	for &s, k in access_vis_slots {
		if !s.live {
			victim = k
			break
		}
		if &s.vis == access.vis {
			continue
		}
		if victim < 0 || s.stamp < access_vis_slots[victim].stamp {
			victim = k
		}
	}
	s := &access_vis_slots[victim]
	if s.live {
		access_vis_where[s.reader] = 0
		lb.visibility_destroy(&s.vis)
	}
	reader_label, _ := lb.table_label(&label_table, reader)
	lb.visibility_build(&s.vis, &label_table, reader_label)
	s.reader = reader
	s.stamp = access_vis_clock
	s.live = true
	access_vis_where[i] = u8(victim + 1)
	return &s.vis
}

access_conn :: proc(c: ^Conn) -> ^Access_Conn {
	if c.label == nil {
		c.label = new(Access_Conn)
		client_metadata_sync(c)
	}
	return c.label
}

access_conn_closed :: proc(c: ^Conn) {
	if c.label != nil {
		client_metadata_total -= c.label.accounted
		free(c.label)
		c.label = nil
	}
}

access_user_changed :: proc(c: ^Conn) {
	if c.label != nil {
		c.label.explicit = false
		c.label.session = {}
		c.label.ran = false
		c.label.owner_pinned = false
		c.label.pin_owner = ow.SHARED
	}
}

access_holds_push :: proc(c: ^Conn) -> bool {
	return .Tracking in c.ps || ps_total(c) + ps_count(c, .Shard) > 0
}

access_rules :: #force_inline proc(c: ^Conn) -> ^Acl_Label_Rules {
	return &c.user.labels if c.user != nil else nil
}

access_fixed_id :: #force_inline proc(r: ^Acl_Label_Rules) -> []u8 {
	return r.owner_id[:r.owner_len]
}

access_is_operator :: proc(r: ^Acl_Label_Rules) -> bool {
	return r == nil || r.owner_operator
}

access_may_act_text :: proc(r: ^Acl_Label_Rules, text: []u8) -> bool {
	if r == nil {
		return false
	}
	switch r.owners {
	case .Any:
		return true
	case .Fixed:
		return bytes_eq(access_fixed_id(r), text)
	case .None:
	}
	return false
}

access_may_act :: proc(r: ^Acl_Label_Rules, o: ow.Owner) -> bool {
	switch {
	case o == ow.EVERY:
		return false
	case o == ow.SHARED:
		return r == nil || r.owners == .None || r.owner_shared
	}
	text, known := owner_text(o)
	return known && access_may_act_text(r, transmute([]u8)text)
}

access_may_pin :: proc(r: ^Acl_Label_Rules, o: ow.Owner) -> bool {
	if o == ow.EVERY {
		return r != nil && r.owner_operator && r.owners == .Any
	}
	return access_may_act(r, o)
}

access_implicit_pin :: proc(r: ^Acl_Label_Rules) -> (ow.Owner, bool) {
	if r == nil || r.owners == .None {
		return ow.SHARED, true
	}
	if r.owners == .Fixed {
		e, err := owner_intern(access_fixed_id(r))
		if err != .None {
			return ow.SHARED, false
		}
		return e.number, true
	}
	if r.owner_operator {
		return ow.EVERY, true
	}
	return ow.SHARED, false
}

access_user_settled :: proc(c: ^Conn) {
	if !labels_on || !access_holds_push(c) {
		return
	}
	rules := access_rules(c)
	if rules != nil && (rules.per_command || rules.require_token) {
		c.close_after = true
		return
	}
	l := lb.ceiling_session(access_ceiling(c.user))
	if _, interned := access_intern(l); !interned {
		c.close_after = true
		return
	}
	pin := ow.SHARED
	if owners_on {
		o, ok := access_implicit_pin(rules)
		if !ok {
			c.close_after = true
			return
		}
		pin = o
	}
	a := access_conn(c)
	a.session = l
	a.explicit = true
	if owners_on {
		a.owner_pinned = true
		a.pin_owner = pin
	}
}

access_pin_bound :: proc(c: ^Conn) {
	a := access_conn(c)
	if !a.explicit {
		a.session = a.bound
		a.explicit = true
	}
	if owners_on && !a.owner_pinned {
		a.owner_pinned = true
		a.pin_owner = a.owner
	}
}

access_watch_note_label :: proc(c: ^Conn, l: lb.Label, o: ow.Owner = ow.SHARED) {
	a := access_conn(c)
	if !a.watching {
		a.watched = l
		a.watched_owner = o
		a.watching = true
	} else if a.watched != l || a.watched_owner != o {
		a.watch_mixed = true
	}
}

access_watch_note :: proc(c: ^Conn) {
	access_watch_note_label(c, access.label, access.owner)
}

access_watch_differs :: proc(c: ^Conn) -> bool {
	a := c.label
	return a != nil && a.watching && (a.watch_mixed || a.watched != a.bound || a.watched_owner != a.owner)
}

access_watch_clear :: proc(c: ^Conn) {
	if a := c.label; a != nil {
		a.watching = false
		a.watch_mixed = false
	}
}

access_watch_adopt :: proc() {
	for c in srv.conns {
		if c != nil && c.tx != nil && (len(c.tx.watched) > 0 || .Dirty_Cas in c.txf) {
			access_watch_note_label(c, lb.BOTTOM)
		}
	}
}

access_ceiling :: proc(u: ^Acl_User) -> lb.Label {
	if u == nil {
		top := access_scheme_top()
		top.trust = u8(lb.config_trust_count(&label_scheme) - 1)
		return top
	}
	r := &u.labels
	l: lb.Label
	if r.clearance_top {
		l = access_scheme_top()
	} else if r.clearance_set {
		l = r.clearance
	}
	l.trust = 0
	if r.trust_top {
		l.trust = u8(lb.config_trust_count(&label_scheme) - 1)
	} else if r.trust_set {
		l.trust = r.trust
	}
	return l
}

access_conn_session :: proc(c: ^Conn) -> lb.Label {
	if c.label != nil && c.label.explicit {
		return c.label.session
	}
	return lb.ceiling_session(access_ceiling(c.user))
}

access_conn_owner :: proc(c: ^Conn) -> ow.Owner {
	if !owners_on {
		return ow.SHARED
	}
	if c.label != nil && c.label.owner_pinned {
		return c.label.pin_owner
	}
	r := access_rules(c)
	if r == nil || r.owners == .None {
		return ow.SHARED
	}
	if r.owners == .Fixed {
		if e := owner_lookup(access_fixed_id(r)); e != nil {
			return e.number
		}
	}
	return ow.EVERY
}

access_conn_scope :: proc(c: ^Conn) -> (lb.Label, ow.Owner) {
	return access_conn_session(c), access_conn_owner(c)
}

access_sees_conn :: proc(other: ^Conn) -> bool {
	if !labels_on || access.top {
		return true
	}
	if !lb.dominates(access.label, access_conn_session(other)) {
		return false
	}
	return !owners_on || ow.sees(access_view_owner(), access_conn_owner(other))
}

access_acl_changed :: proc(self: ^Conn) {
	if !labels_on {
		return
	}
	label_token_cache_clear()
	label_contexts_prune()
	for c in srv.conns {
		if c == nil || c.label == nil {
			continue
		}
		ceiling := access_ceiling(c.user)
		a := c.label
		stale := false
		if a.explicit {
			stale = !lb.ceiling_admits(ceiling, a.session)
		} else if a.ran {
			stale = !lb.ceiling_admits(ceiling, a.implicit)
		}
		if .Multi in c.txf && !lb.ceiling_admits(ceiling, a.bound) {
			stale = true
		}
		if .Monitor in c.flags && !lb.ceiling_admits(ceiling, a.monitor) {
			stale = true
		}
		if owners_on && !stale {
			stale = access_owner_stale(c)
		}
		if stale {
			acl_evict_conn(c, self)
		}
	}
}

@(private = "file")
access_owner_stale :: proc(c: ^Conn) -> bool {
	a := c.label
	r := access_rules(c)
	if a.owner_pinned && !access_may_pin(r, a.pin_owner) {
		return true
	}
	if .Multi in c.txf && !access_may_act(r, a.owner) {
		return true
	}
	if a.watching && !access_may_act(r, a.watched_owner) {
		return true
	}
	if c.tx != nil {
		for w in c.tx.watched {
			if !access_may_act(r, w.owner) {
				return true
			}
		}
	}
	return .Monitor in c.flags && !access_is_operator(r)
}

@(private = "file")
access_word :: proc(argv: [][]u8, i: int, word: string) -> bool {
	return i < len(argv) && eq_nocase(argv[i], word)
}

access_housekeeping :: proc(slot: ^Cmd_Slot, argv: [][]u8) -> bool {
	if slot == nil {
		return true
	}
	h := slot.cmd.handler
	switch {
	case h == cmd_auth, h == cmd_hello, h == cmd_ping, h == cmd_quit, h == cmd_reset, h == cmd_echo, h == cmd_select:
		return true
	case h == cmd_label:
		return access_word(argv, 1, "whoami") || access_word(argv, 1, "help") || access_word(argv, 1, "session")
	case h == cmd_context:
		return access_word(argv, 1, "help")
	case h == cmd_client:
		return access_word(argv, 1, "setname") || access_word(argv, 1, "setinfo") || access_word(argv, 1, "id")
	case h == cmd_owners:
		return access_word(argv, 1, "help")
	}
	return false
}

access_needs_session :: proc(cmd: ^Command, argv: [][]u8) -> bool {
	h := cmd.handler
	if h == cmd_subscribe || h == cmd_psubscribe || h == cmd_ssubscribe {
		return true
	}
	return h == cmd_client && access_word(argv, 1, "tracking") && access_word(argv, 2, "on")
}

access_top_only :: proc(cmd: ^Command, argv: [][]u8) -> bool {
	h := cmd.handler
	switch {
	case h == cmd_monitor, h == cmd_swapdb, h == cmd_debug, h == cmd_latency:
		return true
	case h == cmd_client:
		return access_word(argv, 1, "pause") || access_word(argv, 1, "unpause")
	case h == cmd_memory:
		return access_word(argv, 1, "stats") || access_word(argv, 1, "doctor") || access_word(argv, 1, "malloc-stats") || access_word(argv, 1, "purge")
	case h == cmd_slowlog:
		return access_word(argv, 1, "reset")
	case h == cmd_config:
		return access_word(argv, 1, "resetstat")
	case h == cmd_owners:
		return owners_on && !access_word(argv, 1, "help")
	}
	return false
}

access_persistence_refuses :: proc(cmd: ^Command, argv: [][]u8) -> bool {
	if !labels_on {
		return false
	}
	h := cmd.handler
	switch {
	case h == cmd_save, h == cmd_bgsave, h == cmd_bgrewriteaof, h == cmd_dump, h == cmd_restore, h == cmd_migrate:
		return true
	case h == cmd_debug:
		return access_word(argv, 1, "reload") || access_word(argv, 1, "loadaof")
	case h == cmd_shutdown:
		for a in argv[1:] {
			if eq_nocase(a, "save") {
				return true
			}
		}
	}
	return false
}

access_persistence_off :: #force_inline proc "contextless" () -> bool {
	return labels_on
}

access_command_refusal :: proc(cmd: ^Command, argv: [][]u8) -> string {
	if access_persistence_refuses(cmd, argv) {
		return ERR_LABEL_PERSISTENCE
	}
	if !access.top && access_top_only(cmd, argv) {
		return ERR_LABEL_TOP
	}
	return ""
}

@(private = "file")
access_refuse :: proc(c: ^Conn, slot: ^Cmd_Slot, argv: [][]u8, msg: string) {
	keyspace_settle(c)
	stat_cur = nil
	if slot != nil {
		c.last_cmd = slot.cmd.name
	}
	if slot != nil && slot.cmd.handler == cmd_exec && .Multi in c.txf {
		tx_exec_abort(c, msg)
	} else {
		reply_error(c, msg)
		tx_flag(c)
	}
	if slot != nil && slot.stats != nil {
		stat_reject(slot.stats, argv)
	}
}

@(private = "file")
access_set :: proc(l: lb.Label, ctx: ^Label_Context, operator: bool) -> bool {
	if !lb.config_valid(&label_scheme, l) {
		return false
	}
	id, e := lb.table_intern(&label_table, l)
	if e != .None {
		return false
	}
	access.label = l
	access.id = id
	access.vis = access_visibility(id)
	access.label_top = lb.dominates(l, access_scheme_top())
	access.operator = operator
	access.top = access.label_top && (operator || !owners_on)
	access.ctx = ctx
	access.owner = ow.SHARED
	access.owner_entry = nil
	return true
}

access_reset_to_bottom :: proc() {
	access_set({}, nil, false)
}

@(cold)
access_enter :: #force_no_inline proc(c: ^Conn, argv: [][]u8, slot: ^Cmd_Slot) -> ([][]u8, ^Cmd_Slot, bool) {
	access_arrival = {}
	if acl_auth_required(c) {
		access_reset_to_bottom()
		return argv, slot, true
	}
	a := access_conn(c)
	args := argv
	s := slot
	l: lb.Label
	ctx: ^Label_Context
	prefixed := false
	rules := access_rules(c)
	if s != nil && s.cmd.handler == cmd_label && len(args) >= 2 && eq_nocase(args[1], "as") {
		used, msg := label_as_parse(c, args, &l, &ctx)
		if msg != "" {
			access_refuse(c, s, args, msg)
			return args, s, false
		}
		inner := args[used:]
		next := lookup_entry(inner[0])
		if next != nil && next.cmd.handler == cmd_label && len(inner) >= 2 && (eq_nocase(inner[1], "as") || eq_nocase(inner[1], "session")) {
			access_refuse(c, s, args, ERR_LABEL_NESTED)
			return args, s, false
		}
		args = inner
		s = next
		prefixed = !access_arrival.owner_only
	}
	if !prefixed {
		if rules != nil && (rules.per_command || rules.require_token) && .Multi not_in c.txf && !access_housekeeping(s, args) {
			access_refuse(c, s, args, ERR_LABEL_TOKEN_ONLY if rules.require_token else ERR_LABEL_PER_COMMAND)
			return args, s, false
		}
		l = access_conn_session(c)
		if !a.explicit {
			a.implicit = l
			a.ran = true
		}
	}
	if .Multi in c.txf {
		if prefixed && l != a.bound {
			access_refuse(c, s, args, ERR_LABEL_TRANSACTION)
			return args, s, false
		}
		l = a.bound
	} else if s != nil && s.cmd.handler == cmd_multi {
		a.bound = l
		a.bound_prefixed = prefixed
	}
	if !lb.ceiling_admits(access_ceiling(c.user), l) || !access_set(l, ctx, access_is_operator(rules)) {
		access_refuse(c, s, args, ERR_LABEL_INVALID)
		return args, s, false
	}
	if s == nil {
		return args, s, true
	}
	if access_needs_session(s.cmd, args) && !a.explicit {
		if prefixed || (.Multi in c.txf && a.bound_prefixed) || (rules != nil && (rules.per_command || rules.require_token)) {
			access_refuse(c, s, args, ERR_LABEL_SESSION_NEEDED)
			return args, s, false
		}
		access_arrival.pin = .Multi not_in c.txf
	}
	return args, s, true
}

access_admit :: proc(c: ^Conn, s: ^Cmd_Slot, args: [][]u8) -> bool {
	if s == nil || acl_auth_required(c) {
		return true
	}
	if msg := access_command_refusal(s.cmd, args); msg != "" {
		access_refuse(c, s, args, msg)
		return false
	}
	if owners_on {
		if msg := access_owner_arrive(c, s, args); msg != "" {
			access_refuse(c, s, args, msg)
			return false
		}
	}
	if access_arrival.pin {
		a := access_conn(c)
		a.session = access.label
		a.explicit = true
	}
	if s.cmd.handler == cmd_monitor {
		access_conn(c).monitor = access.label
	}
	return true
}

@(private = "file")
access_token_owner :: proc(r: ^Acl_Label_Rules) -> (o: ow.Owner, named: bool, msg: string) {
	arr := &access_arrival
	switch arr.token_pick {
	case .None:
		if r != nil && r.owners == .Any {
			return ow.SHARED, false, ERR_LABEL_TOKEN
		}
		return ow.SHARED, false, ""
	case .Shared:
		if !access_may_act(r, ow.SHARED) {
			return ow.SHARED, false, ERR_LABEL_TOKEN
		}
		return ow.SHARED, true, ""
	case .Text:
		text := arr.token_buf[:arr.token_len]
		if !ow.text_valid(text) || !access_may_act_text(r, text) {
			return ow.SHARED, false, ERR_LABEL_TOKEN
		}
		e, err := owner_intern(text)
		if err != .None {
			return ow.SHARED, false, ERR_OWNER_INVALID
		}
		return e.number, true, ""
	}
	return ow.SHARED, false, ERR_LABEL_TOKEN
}

@(private = "file")
access_explicit_owner :: proc(r: ^Acl_Label_Rules) -> (ow.Owner, string) {
	arr := &access_arrival
	if arr.pick == .Shared {
		if !access_may_act(r, ow.SHARED) {
			return ow.SHARED, ERR_OWNER_INVALID
		}
		return ow.SHARED, ""
	}
	if !ow.text_valid(arr.text) || !access_may_act_text(r, arr.text) {
		return ow.SHARED, ERR_OWNER_INVALID
	}
	e, err := owner_intern(arr.text)
	if err != .None {
		return ow.SHARED, ERR_OWNER_INVALID
	}
	return e.number, ""
}

@(private = "file")
access_owner_arrive :: proc(c: ^Conn, s: ^Cmd_Slot, args: [][]u8) -> string {
	a := access_conn(c)
	r := access_rules(c)
	arr := &access_arrival
	in_multi := .Multi in c.txf
	ctx := access.ctx
	o := ow.SHARED
	named := false
	switch {
	case arr.token:
		token_owner, token_named, msg := access_token_owner(r)
		if msg != "" {
			return msg
		}
		if ctx != nil {
			effective := token_owner
			if !token_named {
				implicit, ok := access_implicit_pin(r)
				if !ok || implicit == ow.EVERY {
					return ERR_LABEL_TOKEN
				}
				effective = implicit
			}
			if ctx.owner != effective {
				return ERR_LABEL_TOKEN
			}
		}
		o, named = token_owner, token_named
	case ctx != nil:
		if !access_may_act(r, ctx.owner) {
			return ERR_LABEL_CONTEXT
		}
		if arr.pick == .Shared && ctx.owner != ow.SHARED {
			return ERR_OWNER_CONTEXT
		}
		if arr.pick == .Text {
			e := owner_lookup(arr.text)
			if e == nil || e.number != ctx.owner {
				return ERR_OWNER_CONTEXT
			}
		}
		o, named = ctx.owner, true
	case arr.pick != .None:
		explicit, msg := access_explicit_owner(r)
		if msg != "" {
			return msg
		}
		o, named = explicit, true
	}
	if !named {
		switch {
		case in_multi:
			o = a.owner
		case r == nil || r.owners == .None:
			o = ow.SHARED
		case r.owners == .Fixed:
			e, err := owner_intern(access_fixed_id(r))
			if err != .None {
				return ERR_OWNER_INVALID
			}
			o = e.number
		case access_housekeeping(s, args):
			o = ow.SHARED
		case r.owner_operator && access_needs_session(s.cmd, args):
			o = ow.EVERY
		case:
			return ERR_OWNER_REQUIRED
		}
	}
	if named && a.owner_pinned && o != a.pin_owner {
		return ERR_OWNER_BOUND
	}
	if named && in_multi && o != a.owner {
		return ERR_OWNER_TRANSACTION
	}
	access.owner = o
	access.owner_entry = owner_entry(o)
	if !in_multi {
		a.owner = o
		if access_needs_session(s.cmd, args) && !a.owner_pinned {
			a.owner_pinned = true
			a.pin_owner = o
		}
	}
	return ""
}

access_monitor_sees :: proc(m: ^Conn) -> bool {
	if !labels_on {
		return true
	}
	if m.label == nil {
		return false
	}
	if owners_on && !access_is_operator(access_rules(m)) {
		return false
	}
	return lb.dominates(m.label.monitor, access.label)
}

access_publish_scope :: proc() -> ow.Scope {
	if !labels_on {
		return ow.SHARED_BOTTOM
	}
	return access_scope()
}

access_subscriber_sees :: #force_inline proc(t: ^Conn, msg: lb.Label, owner: ow.Owner) -> bool {
	return lb.dominates(access_conn_session(t), msg) && (!owners_on || ow.sees(access_conn_owner(t), owner))
}

access_counts_subscriber :: #force_inline proc(t: ^Conn) -> bool {
	return lb.dominates(access.label, access_conn_session(t)) && (!owners_on || ow.sees(access_view_owner(), access_conn_owner(t)))
}

access_receiver_exact :: #force_inline proc(t: ^Conn) -> bool {
	return access_conn_session(t) == access.label && (!owners_on || access_conn_owner(t) == access.owner)
}

access_busy_script: Access

access_busy_dispatch :: proc(c: ^Conn, argv: [][]u8) {
	access_busy_script = access
	saved_arrival := access_arrival
	defer {
		access = access_busy_script
		access_arrival = saved_arrival
	}
	if len(argv) == 0 {
		return
	}
	inner, _, ok := access_enter(c, argv, lookup_entry(argv[0]))
	if ok {
		lua_busy_dispatch_inner(c, inner)
	}
}

access_busy_sees_script :: proc() -> bool {
	if !labels_on || access.top {
		return true
	}
	if !lb.dominates(access.label, access_busy_script.label) {
		return false
	}
	return !owners_on || access.operator || access.owner == access_busy_script.owner
}
