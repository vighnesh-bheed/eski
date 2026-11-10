package main

import lb "label"

ERR_LABEL_INVALID :: "ERR invalid label"
ERR_LABELS_OFF :: "ERR labels are not configured on this server"
ERR_LABEL_CONTEXT :: "ERR invalid context"
ERR_LABEL_TOKEN :: "ERR invalid label token"
ERR_LABEL_PER_COMMAND :: "ERR this login must send every command through LABEL AS"
ERR_LABEL_TOKEN_ONLY :: "ERR this login must send every command through LABEL AS TOKEN"
ERR_LABEL_SESSION_NEEDED :: "ERR this command needs a session label set with LABEL SESSION"
ERR_LABEL_SESSION_DENIED :: "ERR LABEL SESSION is not available to this login"
ERR_LABEL_TRANSACTION :: "ERR the command's label differs from the transaction's label"
ERR_LABEL_NESTED :: "ERR LABEL AS cannot wrap LABEL AS or LABEL SESSION"
ERR_LABEL_CONTEXT_MISMATCH :: "ERR the label differs from the context's label"
ERR_LABEL_TOP :: "ERR this command needs a label that dominates the whole label scheme"
ERR_LABEL_PERSISTENCE :: "ERR persistence is off while a label scheme is configured"
ERR_LABEL_SCRIPT :: "ERR this command needs a label that dominates the running script's label"

Access :: struct {
	label: lb.Label,
	id:    lb.Id,
	vis:   ^lb.Visibility,
	top:   bool,
	ctx:   ^Label_Context,
}

Access_Conn :: struct {
	session:  lb.Label,
	explicit: bool,
	bound:    lb.Label,
	implicit: lb.Label,
	monitor:  lb.Label,
	ran:      bool,
	accounted: int,
}

Acl_Label_Rules :: struct {
	clearance:     lb.Label,
	clearance_set: bool,
	clearance_top: bool,
	trust:         u8,
	trust_set:     bool,
	trust_top:     bool,
	per_command:   bool,
	require_token: bool,
	keys:          [dynamic][32]u8,
}

labels_on: bool
label_scheme: lb.Config
label_table: lb.Table
access: Access

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

access_sees_conn :: proc(other: ^Conn) -> bool {
	if !labels_on || access.top {
		return true
	}
	return lb.dominates(access.label, access_conn_session(other))
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
		if stale {
			acl_evict_conn(c, self)
		}
	}
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
access_set :: proc(l: lb.Label, ctx: ^Label_Context) -> bool {
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
	access.top = lb.dominates(l, access_scheme_top())
	access.ctx = ctx
	return true
}

access_reset_to_bottom :: proc() {
	access_set({}, nil)
}

@(cold)
access_enter :: #force_no_inline proc(c: ^Conn, argv: [][]u8, slot: ^Cmd_Slot) -> ([][]u8, ^Cmd_Slot, bool) {
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
	rules := &c.user.labels if c.user != nil else nil
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
		prefixed = true
	} else {
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
	}
	if !lb.ceiling_admits(access_ceiling(c.user), l) || !access_set(l, ctx) {
		access_refuse(c, s, args, ERR_LABEL_INVALID)
		return args, s, false
	}
	if s == nil {
		return args, s, true
	}
	if msg := access_command_refusal(s.cmd, args); msg != "" {
		access_refuse(c, s, args, msg)
		return args, s, false
	}
	if access_needs_session(s.cmd, args) && !a.explicit {
		access_refuse(c, s, args, ERR_LABEL_SESSION_NEEDED)
		return args, s, false
	}
	if s.cmd.handler == cmd_monitor {
		a.monitor = l
	}
	return args, s, true
}

access_monitor_sees :: proc(m: ^Conn) -> bool {
	if !labels_on {
		return true
	}
	if m.label == nil {
		return false
	}
	return lb.dominates(m.label.monitor, access.label)
}

access_publish_label :: proc() -> lb.Id {
	if !labels_on {
		return lb.BOTTOM_ID
	}
	return access.id
}

access_subscriber_sees :: #force_inline proc(t: ^Conn, msg: lb.Label) -> bool {
	return lb.dominates(access_conn_session(t), msg)
}

access_counts_subscriber :: #force_inline proc(t: ^Conn) -> bool {
	return lb.dominates(access.label, access_conn_session(t))
}

access_busy_script: Access

access_busy_dispatch :: proc(c: ^Conn, argv: [][]u8) {
	access_busy_script = access
	defer access = access_busy_script
	if len(argv) == 0 {
		return
	}
	inner, _, ok := access_enter(c, argv, lookup_entry(argv[0]))
	if ok {
		lua_busy_dispatch_inner(c, inner)
	}
}

access_busy_sees_script :: proc() -> bool {
	return !labels_on || access.top || lb.dominates(access.label, access_busy_script.label)
}
