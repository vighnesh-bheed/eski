package main
import "base:intrinsics"

Pubsub_Flag :: enum u8 {
	Subscribed,
	Held_Off,
	Close_Asap,
	Tracking,
}

Ps_Kind :: enum u8 {
	Channel,
	Pattern,
	Shard,
}

Ps_Entry :: struct {
	name: []u8,
	subs: [dynamic]^Conn,
	kind: Ps_Kind,
}

Ps_State :: struct {
	metadata_accounted, metadata_shared: int,
	lists:        [Ps_Kind][dynamic]^Ps_Entry,
	deferred:     [dynamic]u8,
	mark:         int,
	soft_since:   i64,
	slot:         int,
	trk:          Track_Flags,
	trk_redirect: i64,
	trk_prefixes: [dynamic][]u8,
}

Obuf_Class :: enum u8 {
	Normal,
	Replica,
	Pubsub,
}

Obuf_Limit :: struct {
	hard:    u64,
	soft:    u64,
	seconds: i64,
}

ERR_OOM :: "OOM command not allowed when used memory > 'maxmemory'."

obuf_limits := [Obuf_Class]Obuf_Limit {
	.Normal  = {0, 0, 0},
	.Replica = {256 * 1024 * 1024, 64 * 1024 * 1024, 60},
	.Pubsub  = {32 * 1024 * 1024, 8 * 1024 * 1024, 60},
}

maxmemory_bytes: u64

stat_obuf_disconnections: i64

ps_conns: [dynamic]^Conn

ps_exec: ^Conn

ps_hooked: bool

cmd_hooks: bool

ps_held_count: int

hooks_update :: proc() {
	cmd_hooks = maxmemory_bytes != 0 || cfg.maxmemory_clients != 0 || len(ps_conns) > 0 || tracking_clients > 0 || ps_held_count > 0 || tx_multi_count > 0 || len(monitors) > 0 || labels_on
}

@(private)
ps_doomed: [dynamic]^Conn

ps_state :: proc(c: ^Conn) -> ^Ps_State {
	if c.pubsub == nil {
		c.pubsub = new(Ps_State)
		c.pubsub.slot = -1
		client_metadata_sync(c)
	}
	return c.pubsub
}

ps_mark :: proc(c: ^Conn) {
	if .Subscribed in c.ps {
		return
	}
	st := ps_state(c)
	c.ps += {.Subscribed}
	st.slot = len(ps_conns)
	append(&ps_conns, c)
	mem_registry_changed()
	hooks_update()
}

ps_unmark :: proc(c: ^Conn) {
	if .Subscribed not_in c.ps {
		return
	}
	c.ps -= {.Subscribed}
	st := c.pubsub
	last := ps_conns[len(ps_conns) - 1]
	ps_conns[st.slot] = last
	last.pubsub.slot = st.slot
	pop(&ps_conns)
	st.slot = -1
	st.soft_since = 0
	hooks_update()
}

ps_begin :: proc(c: ^Conn) {
	if ps_exec == c {
		return
	}
	st := ps_state(c)
	ps_exec = c
	st.mark = c.wlen - c.wpos
}

@(private)
ps_emit :: proc(t: ^Conn, frame: []u8) #no_bounds_check {
	first: u8 = '>' if t.resp >= RESP3 else '*'
	if t == ps_exec {
		b := &t.pubsub.deferred
		start := len(b)
		append(b, ..frame)
		b[start] = first
		return
	}
	n := len(frame)
	p := wb_reserve(t, n)
	intrinsics.mem_copy_non_overlapping(p, raw_data(frame), n)
	p[0] = first
	t.wlen += n
	if !t.want_write {
		epoll_set(t.fd, .MOD, true, t.id)
		t.want_write = true
	}
	if t.wlen - t.wpos > WBUF_INIT && .Close_Asap not_in t.ps && obuf_class_over(t, .Pubsub, &t.pubsub.soft_since) {
		t.ps += {.Close_Asap}
		append(&ps_doomed, t)
	}
}

push_write :: proc(t: ^Conn, data: []u8) {
	if t == ps_exec {
		append(&t.pubsub.deferred, ..data)
		client_metadata_sync(t)
		return
	}
	n := len(data)
	p := wb_reserve(t, n)
	intrinsics.mem_copy_non_overlapping(p, raw_data(data), n)
	t.wlen += n
	if !t.want_write {
		epoll_set(t.fd, .MOD, true, t.id)
		t.want_write = true
	}
	if .Subscribed in t.ps && t.wlen - t.wpos > WBUF_INIT && .Close_Asap not_in t.ps && obuf_class_over(t, .Pubsub, &t.pubsub.soft_since) {
		t.ps += {.Close_Asap}
	}
}

ps_obuf_usage :: proc(t: ^Conn) -> u64 {
	if t.wlen <= t.wpos || t.wcap <= WBUF_INIT { return 0 }
	return u64(t.wcap)
}

@(private)
ps_close_doomed :: proc() {
	for d in ps_doomed {
		if d == ps_exec {
			d.close_after = true
			continue
		}
		stat_obuf_disconnections += 1
		conn_close(d)
	}
	clear(&ps_doomed)
}

resolve_subcommand :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8) -> (full: string, ok: bool) {
	full = cmd.name
	if len(argv) < 2 {
		return full, true
	}
	container := false
	for &s in ps_subcommands {
		bar := len(cmd.name)
		if len(s.full) <= bar || s.full[bar] != '|' || s.full[:bar] != cmd.name {
			continue
		}
		container = true
		if !eq_nocase(argv[1], s.full[bar + 1:]) {
			continue
		}
		c.last_cmd = s.full
		if !arity_ok(s.arity, len(argv)) {
			reply_wrong_args(c, s.full)
			return s.full, false
		}
		return s.full, true
	}
	if container {
		upper: [CMD_NAME_MAX]u8
		for i in 0 ..< len(cmd.name) {
			ch := cmd.name[i]
			upper[i] = ch - 32 if ch >= 'a' && ch <= 'z' else ch
		}
		c.last_cmd = "NULL"
		reply_unknown_subcommand(c, argv[1], string(upper[:len(cmd.name)]))
		return "", false
	}
	return full, true
}

pubsub_before :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8) -> bool {
	if .Held_Off in c.ps {
		c.ps -= {.Held_Off}
		c.reply = c.reply - {.Held} + {.Off}
		ps_held_count -= 1
		hooks_update()
	}
	if c.ps & {.Subscribed, .Tracking} == {} {
		return true
	}
	if .Subscribed in c.ps && c.resp < RESP3 && !ps_allowed(cmd) {
		ps_reject(c, cmd, argv)
		return false
	}
	ps_exec = c
	c.pubsub.mark = c.wlen - c.wpos
	return true
}

pubsub_after :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8) {
	st := c.pubsub
	if st != nil && .Tracking in c.ps && cmd != nil {
		tracking_after_command(c, cmd, argv)
	}
	if tracking_pending() {
		tracking_flush_pending(c)
	}
	ps_exec = nil
	if st == nil || len(st.deferred) == 0 {
		return
	}
	if c.reply & {.Off, .Skip} != {} {
		if !tx_reply_managed {
			c.wlen = c.wpos + st.mark
		}
		if .Off in c.reply {
			c.reply = c.reply - {.Off} + {.Held}
			c.ps += {.Held_Off}
			ps_held_count += 1
			hooks_update()
		}
		c.reply -= {.Skip}
	}
	n := len(st.deferred)
	p := wb_reserve(c, n)
	intrinsics.mem_copy_non_overlapping(p, raw_data(st.deferred), n)
	c.wlen += n
	clear(&st.deferred)
}

pubsub_reset :: proc(c: ^Conn) {
	if c.pubsub == nil {
		return
	}
	tracking_disable(c)
	for kind in Ps_Kind {
		ps_unsubscribe_all(c, kind, false)
	}
	ps_unmark(c)
}

pubsub_conn_closed :: proc(c: ^Conn) {
	if ps_exec == c {
		ps_exec = nil
	}
	if .Held_Off in c.ps {
		c.ps -= {.Held_Off}
		ps_held_count -= 1
		hooks_update()
	}
	st := c.pubsub
	tracking_disable(c)
	for kind in Ps_Kind {
		ps_unsubscribe_all(c, kind, false)
		delete(st.lists[kind])
	}
	ps_unmark(c)
	delete(st.trk_prefixes)
	delete(st.deferred)
	client_metadata_drop_ps(c)
	free(st)
	c.pubsub = nil
}

pubsub_cron :: proc() {
	for i := len(ps_conns) - 1; i >= 0; i -= 1 {
		if i >= len(ps_conns) {
			continue
		}
		t := ps_conns[i]
		if t == ps_exec {
			continue
		}
		if .Close_Asap in t.ps || obuf_class_over(t, .Pubsub, &t.pubsub.soft_since) {
			stat_obuf_disconnections += 1
			conn_close(t)
		}
	}
}

ps_oom :: proc(c: ^Conn) -> bool {
	if over, _ := memory_state_over(); !over {
		return false
	}
	reply_error(c, ERR_OOM)
	return true
}

Ps_Subcommand :: struct {
	full:  string,
	arity: int,
}

@(private)
ps_subcommands := [?]Ps_Subcommand {
	{"acl|cat", -2},
	{"acl|deluser", -3},
	{"acl|dryrun", -4},
	{"acl|genpass", -2},
	{"acl|getuser", 3},
	{"acl|help", 2},
	{"acl|list", 2},
	{"acl|load", 2},
	{"acl|log", -2},
	{"acl|save", 2},
	{"acl|setuser", -3},
	{"acl|users", 2},
	{"acl|whoami", 2},
	{"client|caching", 3},
	{"client|getname", 2},
	{"client|getredir", 2},
	{"client|help", 2},
	{"client|id", 2},
	{"client|info", 2},
	{"client|kill", -3},
	{"client|list", -2},
	{"client|no-evict", 3},
	{"client|no-touch", 3},
	{"client|pause", -3},
	{"client|reply", 3},
	{"client|setinfo", 4},
	{"client|setname", 3},
	{"client|tracking", -3},
	{"client|trackinginfo", 2},
	{"client|unblock", -3},
	{"client|unpause", 2},
	{"cluster|addslots", -3},
	{"cluster|addslotsrange", -4},
	{"cluster|bumpepoch", 2},
	{"cluster|count-failure-reports", 3},
	{"cluster|countkeysinslot", 3},
	{"cluster|delslots", -3},
	{"cluster|delslotsrange", -4},
	{"cluster|failover", -2},
	{"cluster|flushslots", 2},
	{"cluster|forget", 3},
	{"cluster|getkeysinslot", 4},
	{"cluster|help", 2},
	{"cluster|info", 2},
	{"cluster|keyslot", 3},
	{"cluster|links", 2},
	{"cluster|meet", -4},
	{"cluster|myid", 2},
	{"cluster|myshardid", 2},
	{"cluster|nodes", 2},
	{"cluster|replicas", 3},
	{"cluster|replicate", 3},
	{"cluster|reset", -2},
	{"cluster|saveconfig", 2},
	{"cluster|set-config-epoch", 3},
	{"cluster|setslot", -4},
	{"cluster|shards", 2},
	{"cluster|slaves", 3},
	{"cluster|slots", 2},
	{"command|count", 2},
	{"command|docs", -2},
	{"command|getkeys", -3},
	{"command|getkeysandflags", -3},
	{"command|help", 2},
	{"command|info", -2},
	{"command|list", -2},
	{"config|get", -3},
	{"config|help", 2},
	{"config|resetstat", 2},
	{"config|rewrite", 2},
	{"config|set", -4},
	{"function|delete", 3},
	{"function|dump", 2},
	{"function|flush", -2},
	{"function|help", 2},
	{"function|kill", 2},
	{"function|list", -2},
	{"function|load", -3},
	{"function|restore", -3},
	{"function|stats", 2},
	{"latency|doctor", 2},
	{"latency|graph", 3},
	{"latency|help", 2},
	{"latency|histogram", -2},
	{"latency|history", 3},
	{"latency|latest", 2},
	{"latency|reset", -2},
	{"memory|doctor", 2},
	{"memory|help", 2},
	{"memory|malloc-stats", 2},
	{"memory|purge", 2},
	{"memory|stats", 2},
	{"memory|usage", -3},
	{"module|help", 2},
	{"module|list", 2},
	{"module|load", -3},
	{"module|loadex", -3},
	{"module|unload", 3},
	{"object|encoding", 3},
	{"object|freq", 3},
	{"object|help", 2},
	{"object|idletime", 3},
	{"object|refcount", 3},
	{"pubsub|channels", -2},
	{"pubsub|help", 2},
	{"pubsub|numpat", 2},
	{"pubsub|numsub", -2},
	{"pubsub|shardchannels", -2},
	{"pubsub|shardnumsub", -2},
	{"script|debug", 3},
	{"script|exists", -3},
	{"script|flush", -2},
	{"script|help", 2},
	{"script|kill", 2},
	{"script|load", 3},
	{"slowlog|get", -2},
	{"slowlog|help", 2},
	{"slowlog|len", 2},
	{"slowlog|reset", 2},
	{"xgroup|create", -5},
	{"xgroup|createconsumer", 5},
	{"xgroup|delconsumer", 5},
	{"xgroup|destroy", 4},
	{"xgroup|help", 2},
	{"xgroup|setid", -5},
	{"xinfo|consumers", 4},
	{"xinfo|groups", 3},
	{"xinfo|help", 2},
	{"xinfo|stream", -3},
}
