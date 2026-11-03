package main

import "core:sys/linux"

Command_Proc :: #type proc(c: ^Conn, argv: [][]u8)

Command :: struct {
	name:    string,
	handler: Command_Proc,
	arity:   int,
}

ERR_NOT_INT :: "ERR value is not an integer or out of range"
ERR_SYNTAX :: "ERR syntax error"
ERR_OVERFLOW :: "ERR increment or decrement would overflow"
ERR_NO_KEY :: "ERR no such key"

CMD_TABLE_SIZE :: 1024
CMD_TABLE_MASK :: CMD_TABLE_SIZE - 1
CMD_NAME_MAX :: 32

Cmd_Slot :: struct {
	key:      string,
	cmd:      ^Command,
	stats:    ^Cmd_Hot,
	keyspace: Maybe(Keyspace_Op),
}

cmd_table: [CMD_TABLE_SIZE]Cmd_Slot
cmd_count: int
scratch: [dynamic]u8
key_scratch: [dynamic]string

cmd_hash :: proc "contextless" (name: []u8) -> u32 #no_bounds_check {
	h: u32 = 2166136261
	for b in name {
		h = (h ~ u32(lower(b))) * 16777619
	}
	return h
}

@(private = "file")
cmd_home :: proc "contextless" (name: string) -> int {
	return int(cmd_hash(transmute([]u8)name) & CMD_TABLE_MASK)
}

@(private = "file")
register_fail :: proc "contextless" (reason: string, name: string) -> ! {
	linux.write(2, transmute([]u8)string("eski: cannot register command '"))
	linux.write(2, transmute([]u8)name)
	linux.write(2, transmute([]u8)string("': "))
	linux.write(2, transmute([]u8)reason)
	linux.write(2, transmute([]u8)string("\n"))
	linux.exit_group(70)
}

@(private = "file")
table_insert :: proc "contextless" (key: string, cmd: ^Command) #no_bounds_check {
	cur := Cmd_Slot{key = key, cmd = cmd}
	if op, ok := keyspace_operation(cmd); ok {
		cur.keyspace = op
	}
	h := cmd_home(cur.key)
	dist := 0
	for {
		slot := cmd_table[h]
		if slot.cmd == nil {
			cmd_table[h] = cur
			cmd_count += 1
			return
		}
		slot_dist := (h - cmd_home(slot.key)) & CMD_TABLE_MASK
		if slot_dist < dist || (slot_dist == dist && slot.key > cur.key) {
			cmd_table[h] = cur
			cur = slot
			dist = slot_dist
		}
		h = (h + 1) & CMD_TABLE_MASK
		dist += 1
	}
}

register_command :: proc "contextless" (cmd: ^Command) #no_bounds_check {
	if len(cmd.name) == 0 || len(cmd.name) > CMD_NAME_MAX {
		register_fail("name must be 1 to 32 bytes", cmd.name)
	}
	for b in transmute([]u8)cmd.name {
		if b >= 'A' && b <= 'Z' {
			register_fail("name must be lowercase", cmd.name)
		}
	}
	if cmd.handler == nil || cmd.arity == 0 {
		register_fail("handler and a non-zero arity are required", cmd.name)
	}
	if cmd_count >= CMD_TABLE_SIZE / 2 {
		register_fail("command table is full", cmd.name)
	}
	h := cmd_home(cmd.name)
	for cmd_table[h].cmd != nil {
		if cmd_table[h].key == cmd.name {
			register_fail("registered twice", cmd.name)
		}
		h = (h + 1) & CMD_TABLE_MASK
	}
	table_insert(cmd.name, cmd)
}

register_commands :: proc "contextless" (cmds: []Command) {
	for &cmd in cmds {
		register_command(&cmd)
	}
}

commands_init :: proc() {
	reserve(&scratch, 4096)
	reserve(&key_scratch, 256)
	info_init()
	stats_init()
}

@(private = "file")
lookup_slot :: proc(name: []u8) -> int #no_bounds_check {
	if len(name) == 0 || len(name) > CMD_NAME_MAX {
		return -1
	}
	h := cmd_hash(name) & CMD_TABLE_MASK
	for {
		slot := &cmd_table[h]
		if slot.cmd == nil {
			return -1
		}
		if eq_nocase(name, slot.key) {
			return int(h)
		}
		h = (h + 1) & CMD_TABLE_MASK
	}
}

lookup_command :: proc(name: []u8) -> ^Command {
	slot := lookup_entry(name)
	return slot.cmd if slot != nil else nil
}

lookup_entry :: proc(name: []u8) -> ^Cmd_Slot #no_bounds_check {
	if len(name) == 0 || len(name) > CMD_NAME_MAX {
		return nil
	}
	h := cmd_hash(name) & CMD_TABLE_MASK
	for {
		slot := &cmd_table[h]
		if slot.cmd == nil {
			return nil
		}
		if eq_nocase(name, slot.key) {
			return slot
		}
		h = (h + 1) & CMD_TABLE_MASK
	}
}

rename_command :: proc(from: []u8, to: []u8) -> string {
	h := lookup_slot(from)
	if h < 0 {
		return "No such command in rename-command"
	}
	cmd := cmd_table[h].cmd
	cmd_table[h] = {}
	cmd_count -= 1
	for {
		next := (h + 1) & CMD_TABLE_MASK
		slot := cmd_table[next]
		if slot.cmd == nil || ((next - cmd_home(slot.key)) & CMD_TABLE_MASK) == 0 {
			break
		}
		cmd_table[h] = slot
		cmd_table[next] = {}
		h = next
	}
	if len(to) == 0 {
		return ""
	}
	if len(to) > CMD_NAME_MAX {
		return "Target command name is too long"
	}
	if lookup_slot(to) >= 0 {
		return "Target command name already exists"
	}
	key := make([]u8, len(to))
	for b, i in to {
		key[i] = lower(b)
	}
	table_insert(string(key), cmd)
	return ""
}

execute :: proc(c: ^Conn, argv: [][]u8) {
	slot := lookup_entry(argv[0])
	resolved := slot.cmd if slot != nil else nil
	diagnostics_command_begin(resolved.name if resolved != nil else "unknown", argv)
	defer diagnostics_command_end()
	if !keyspace_candidate(slot, argv) {
		keyspace_fence()
	}
	if slot == nil {
		c.last_cmd = "NULL"
		stat_cur = nil
		reply_unknown_command(c, argv)
		tx_flag(c)
		return
	}
	cmd := slot.cmd
	st := slot.stats
	c.last_cmd = cmd.name
	n := len(argv)
	if (cmd.arity > 0 && n != cmd.arity) || (cmd.arity < 0 && n < -cmd.arity) {
		keyspace_settle(c)
		stat_cur = nil
		execute_bad_arity(c, cmd)
		stat_reject(st, argv)
		return
	}
	if c.acl_gate && acl_reject(c, cmd, st, argv) {
		keyspace_fence()
		return
	}
	if cmd_hooks {
		execute_hooked(c, slot, argv)
		return
	}
	if pst.gate_active {
		keyspace_fence()
		if execute_gate(c, cmd, st, argv) {
			return
		}
	}
	if keyspace_candidate(slot, argv) && keyspace_try(c, slot, argv) {
		return
	}
	db_cur = c.db
	store_no_touch = .No_Touch in c.flags && cmd.handler != cmd_touch
	pending := c.wlen - c.wpos
	dirty := pst.dirty
	if aof.feed {
		aof_cmd_begin(c, cmd, argv)
	}
	stat_cur = &st.stats
	t0 := mono_now()
	cmd.handler(c, argv)
	ticks := mono_now() - t0
	deferred := compute_note_deferred(c, cmd, st, t0)
	if deferred {
		stat_cur = nil
	} else if ticks < st.limit_ticks {
		#no_bounds_check st.small[(ticks * mono_mul) >> 32] += 1
		srv.stat_commands += 1
	} else {
		stat_call_slow(c, cmd, st, argv, ticks)
	}
	persist_note(c, cmd, argv, pending, dirty)
}

@(cold)
execute_gate :: #force_no_inline proc(c: ^Conn, cmd: ^Command, st: ^Cmd_Hot, argv: [][]u8) -> bool {
	stat_cur = nil
	if persist_gate(c, cmd, argv) {
		stat_reject(st, argv)
		return true
	}
	return false
}

@(cold)
execute_hooked :: #force_no_inline proc(c: ^Conn, slot: ^Cmd_Slot, argv: [][]u8) {
	cmd := slot.cmd
	st := slot.stats
	stat_cur = nil
	if cmd.handler == cmd_debug && !debug_allowed(c) {
		reply_error(c, ERR_DEBUG_NOT_ALLOWED)
		tx_flag(c)
		stat_reject(st, argv)
		return
	}
	if cfg.maxmemory_clients != 0 && evict_clients(c) {
		return
	}
	memory_ok := true
	if maxmemory_bytes != 0 {
		memory_ok = perform_evictions() != .Fail
	}
	if c.ps != {} && !pubsub_before(c, cmd, argv) {
		stat_reject(st, argv)
		return
	}
	if !memory_ok && oom_denied(c, cmd, argv) {
		keyspace_settle(c)
		reject_oom(c, cmd)
		stat_reject(st, argv)
		if ps_exec != nil {
			pubsub_after(c, nil, nil)
		}
		return
	}
	if pst.gate_active {
		keyspace_settle(c)
	}
	if pst.gate_active && hooked_persist_gate(c, cmd, argv) {
		stat_reject(st, argv)
		if ps_exec != nil {
			pubsub_after(c, nil, nil)
		}
		return
	}
	if .Monitor in c.flags && monitor_rejects(c, cmd, argv) {
		if ps_exec != nil {
			pubsub_after(c, nil, nil)
		}
		return
	}
	if .Multi in c.txf && !tx_immediate(cmd) {
		queued_errors := stat_total_error_replies
		tx_queue(c, cmd, argv)
		if stat_total_error_replies != queued_errors {
			stat_reject(st, argv)
		}
		if ps_exec != nil {
			pubsub_after(c, nil, nil)
		}
		return
	}
	if keyspace_candidate(slot, argv) && keyspace_try(c, slot, argv) {
		ps_exec = nil
		return
	}
	db_cur = c.db
	store_no_touch = .No_Touch in c.flags && cmd.handler != cmd_touch
	pending := c.wlen - c.wpos
	dirty := pst.dirty
	tx_reply_managed = false
	if aof.feed {
		aof_cmd_begin(c, cmd, argv)
	}
	ps_hooked = true
	stat_cur = &st.stats
	t0 := mono_now()
	if len(monitors) > 0 && lua_is_eval(cmd) {
		monitor_feed_raw(c, argv)
	}
	cmd.handler(c, argv)
	ticks := mono_now() - t0
	ps_hooked = false
	deferred := compute_note_deferred(c, cmd, st, t0)
	if deferred {
		stat_cur = nil
	} else if ticks < st.limit_ticks {
		#no_bounds_check st.small[(ticks * mono_mul) >> 32] += 1
		srv.stat_commands += 1
	} else {
		stat_call_slow(c, cmd, st, argv, ticks)
	}
	persist_note(c, cmd, argv, pending, dirty)
	if ps_exec != nil {
		pubsub_after(c, cmd, argv)
	}
	if len(monitors) > 0 && !lua_is_eval(cmd) {
		monitor_feed(c, cmd, argv)
	}
	if client_buckets_on {
		client_bucket_track(c)
	}
}

@(cold)
reply_wrong_args :: #force_no_inline proc(c: ^Conn, name: string) {
	reply_error_parts(c, "ERR wrong number of arguments for '", name, "' command")
}

sanitize_scratch :: proc() {
	for &b in scratch {
		if b == '\r' || b == '\n' {
			b = ' '
		}
	}
}

@(cold)
reply_unknown_command :: #force_no_inline proc(c: ^Conn, argv: [][]u8) {
	clear(&scratch)
	sb_str(&scratch, "ERR unknown command '")
	name := generic_cstr(argv[0])
	sb_bytes(&scratch, name[:min(len(name), 128)])
	sb_str(&scratch, "', with args beginning with: ")
	args_len := 0
	for i in 1 ..< len(argv) {
		if args_len >= 128 {
			break
		}
		a := generic_cstr(argv[i])
		part := a[:min(len(a), 128 - args_len)]
		sb_byte(&scratch, '\'')
		sb_bytes(&scratch, part)
		sb_str(&scratch, "' ")
		args_len += len(part) + 3
	}
	sanitize_scratch()
	reply_error_bytes(c, scratch[:])
}

@(cold)
reply_unknown_subcommand :: #force_no_inline proc(c: ^Conn, sub: []u8, cmdname: string) {
	clear(&scratch)
	sb_str(&scratch, "ERR unknown subcommand '")
	sb_bytes(&scratch, generic_cstr(sub[:min(len(sub), 128)]))
	sb_str(&scratch, "'. Try ")
	sb_str(&scratch, cmdname)
	sb_str(&scratch, " HELP.")
	sanitize_scratch()
	reply_error_bytes(c, scratch[:])
}

@(cold)
reply_subcommand_syntax_error :: #force_no_inline proc(c: ^Conn, sub: []u8, cmdname: string) {
	clear(&scratch)
	sb_str(&scratch, "ERR unknown subcommand or wrong number of arguments for '")
	sb_bytes(&scratch, generic_cstr(sub[:min(len(sub), 128)]))
	sb_str(&scratch, "'. Try ")
	sb_str(&scratch, cmdname)
	sb_str(&scratch, " HELP.")
	sanitize_scratch()
	reply_error_bytes(c, scratch[:])
}
