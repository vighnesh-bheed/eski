package main

import ow "owner"

OWNERS_LIST_COUNT :: 10

Owner_Entry :: struct {
	number:   ow.Owner,
	text:     string,
	keyspace: Keyspace_Owner,
}

owner_table: ow.Table(Owner_Entry)
owner_quota_default: i64
owner_partitions_max: i64

@(private = "file")
owner_table_ready: bool

@(private = "file")
owners_help_lines := [?]string {
	"OWNERS <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"FORGET <id>",
	"    Remove every key, element, context, cached token and slow log entry of an owner, close its",
	"    connections and drop its id.",
	"INFO <id>",
	"    Show the keys, elements, bytes, partitions, labels and quota of an owner.",
	"LIST <cursor> [COUNT <count>]",
	"    Iterate over the ids of the owners holding data.",
	"QUOTA <id> [LIMIT <bytes>]",
	"    Show or set the memory quota of an owner.",
	"HELP",
	"    Print this help.",
}

owner_intern :: proc(text: []u8) -> (^Owner_Entry, ow.Error) {
	if !owner_table_ready {
		ow.table_init(&owner_table)
		owner_table_ready = true
	}
	return ow.table_intern(&owner_table, text)
}

owner_lookup :: proc(text: []u8) -> ^Owner_Entry {
	if !owner_table_ready {
		return nil
	}
	return ow.table_lookup(&owner_table, text)
}

owner_entry :: proc(o: ow.Owner) -> ^Owner_Entry {
	if !owner_table_ready {
		return nil
	}
	return ow.table_find(&owner_table, o)
}

owner_text :: proc(o: ow.Owner) -> (string, bool) {
	if e := owner_entry(o); e != nil {
		return e.text, true
	}
	return "", false
}

owner_drop :: proc(o: ow.Owner) -> bool {
	if !owner_table_ready {
		return false
	}
	return ow.table_drop(&owner_table, o)
}

owner_count :: proc() -> int {
	if !owner_table_ready {
		return 0
	}
	return ow.table_count(&owner_table)
}

owner_reply_text :: proc(c: ^Conn, o: ow.Owner) {
	if text, known := owner_text(o); known {
		reply_bulk_str(c, text)
	} else {
		reply_null(c)
	}
}

owner_reply_pin :: proc(c: ^Conn, o: ow.Owner) {
	switch {
	case o == ow.SHARED:
		reply_bulk_str(c, "SHARED")
	case o == ow.EVERY:
		reply_bulk_str(c, "EVERY")
	case:
		b := make([dynamic]u8, context.temp_allocator)
		sb_str(&b, "OWNER ")
		text, _ := owner_text(o)
		sb_str(&b, text)
		reply_bulk(c, b[:])
	}
}

owners_enabled :: proc() {
	for c in srv.conns {
		if c == nil || !access_holds_push(c) {
			continue
		}
		a := access_conn(c)
		if !a.owner_pinned {
			a.owner_pinned = true
			a.pin_owner = ow.SHARED
		}
	}
}

@(private = "file")
owner_holds :: proc(c: ^Conn, o: ow.Owner) -> bool {
	a := c.label
	if a == nil {
		return false
	}
	if a.owner_pinned && a.pin_owner == o {
		return true
	}
	if (.Multi in c.txf || c.blocked != .None) && a.owner == o {
		return true
	}
	if a.watching && a.watched_owner == o {
		return true
	}
	if c.tx != nil {
		for w in c.tx.watched {
			if w.owner == o {
				return true
			}
		}
	}
	return false
}

@(private = "file")
owners_close :: proc(self: ^Conn, o: ow.Owner) -> int {
	n := 0
	for c in srv.conns {
		if c == nil || !owner_holds(c, o) {
			continue
		}
		n += 1
		c.close_after = true
		if c != self && !acl_is_doomed(c) {
			append(&acl_doomed, c)
		}
	}
	return n
}

@(private = "file")
owners_valid_id :: proc(c: ^Conn, id: []u8) -> bool {
	if !ow.text_valid(id) {
		reply_error(c, ERR_OWNER_INVALID)
		return false
	}
	return true
}

@(private = "file")
owners_forget :: proc(c: ^Conn, id: []u8) {
	if !owners_valid_id(c, id) {
		return
	}
	counts: Owner_Counts
	connections, contexts, entries := 0, 0, 0
	if e := owner_lookup(id); e != nil {
		o := e.number
		counts = keyspace_owner_forget(e)
		connections = owners_close(c, o)
		contexts = label_contexts_drop_owner(o)
		entries = slowlog_drop_owner(o)
		lua_scopes_forget_owner(o)
		owner_drop(o)
	}
	tokens := label_token_cache_drop_owner(string(id))
	if label_audit_active() {
		b := make([dynamic]u8, context.temp_allocator)
		mark := [8]int{}
		values := [7]i64{counts.keys, counts.elements, counts.bytes, i64(connections), i64(contexts), i64(tokens), i64(entries)}
		for v, k in values {
			mark[k] = len(b)
			sb_int(&b, v)
		}
		mark[7] = len(b)
		text := string(b[:])
		label_audit(c, "owner-forget", "owner", string(id), "keys", text[mark[0]:mark[1]], "elements", text[mark[1]:mark[2]], "bytes", text[mark[2]:mark[3]], "connections", text[mark[3]:mark[4]], "contexts", text[mark[4]:mark[5]], "tokens", text[mark[5]:mark[6]], "slowlog", text[mark[6]:mark[7]])
	}
	reply_map(c, 3)
	reply_bulk_str(c, "keys")
	reply_int(c, counts.keys)
	reply_bulk_str(c, "elements")
	reply_int(c, counts.elements)
	reply_bulk_str(c, "bytes")
	reply_int(c, counts.bytes)
}

@(private = "file")
owners_info :: proc(c: ^Conn, id: []u8) {
	if !owners_valid_id(c, id) {
		return
	}
	info := Owner_Info{quota = owner_quota_default}
	if e := owner_lookup(id); e != nil {
		info = keyspace_owner_info(e)
	}
	reply_map(c, 6)
	reply_bulk_str(c, "keys")
	reply_int(c, info.keys)
	reply_bulk_str(c, "elements")
	reply_int(c, info.elements)
	reply_bulk_str(c, "bytes")
	reply_int(c, info.bytes)
	reply_bulk_str(c, "partitions")
	reply_int(c, info.partitions)
	reply_bulk_str(c, "labels")
	reply_int(c, info.labels)
	reply_bulk_str(c, "quota")
	reply_int(c, info.quota)
}

@(private = "file")
owners_list :: proc(c: ^Conn, argv: [][]u8) {
	cursor, valid := scan_parse_cursor(argv[2])
	if !valid || cursor > u64(ow.LAST_USER) {
		reply_error(c, "ERR invalid cursor")
		return
	}
	count := OWNERS_LIST_COUNT
	switch len(argv) {
	case 3:
	case 5:
		if !eq_nocase(argv[3], "count") {
			reply_error(c, ERR_SYNTAX)
			return
		}
		n, ok := parse_i64(argv[4])
		if !ok {
			reply_error(c, ERR_NOT_INT)
			return
		}
		if n < 1 {
			reply_error(c, ERR_SYNTAX)
			return
		}
		count = int(min(n, 1 << 20))
	case:
		reply_error(c, ERR_SYNTAX)
		return
	}
	found := make([dynamic]^Owner_Entry, context.temp_allocator)
	next := u64(0)
	if owner_table_ready {
		from := ow.Owner(max(cursor, u64(ow.FIRST_USER)))
		examined := 0
		e := ow.table_from(&owner_table, from)
		for e != nil && examined < count {
			if keyspace_owner_holds(e) {
				append(&found, e)
			}
			examined += 1
			last := e.number
			e = ow.table_from(&owner_table, last + 1) if last < ow.LAST_USER else nil
			if e != nil {
				next = u64(e.number)
			} else {
				next = 0
			}
		}
	}
	b := make([dynamic]u8, context.temp_allocator)
	sb_u64(&b, next)
	reply_array(c, 2)
	reply_bulk(c, b[:])
	reply_array(c, len(found))
	for e in found {
		reply_bulk_str(c, e.text)
	}
}

@(private = "file")
owners_quota :: proc(c: ^Conn, argv: [][]u8) {
	id := argv[2]
	if !owners_valid_id(c, id) {
		return
	}
	limit: i64 = -1
	switch len(argv) {
	case 3:
	case 5:
		if !eq_nocase(argv[3], "limit") {
			reply_error(c, ERR_SYNTAX)
			return
		}
		n, ok := parse_i64(argv[4])
		if !ok || n < 0 {
			reply_error(c, ERR_NOT_INT)
			return
		}
		limit = n
	case:
		reply_error(c, ERR_SYNTAX)
		return
	}
	if limit >= 0 {
		e, err := owner_intern(id)
		if err != .None {
			reply_error(c, ERR_OWNER_INVALID)
			return
		}
		keyspace_owner_quota(e, true, limit)
		label_audit(c, "owner-quota", "owner", string(id), "limit", string(argv[4]))
		reply_ok(c)
		return
	}
	quota, used := owner_quota_default, i64(0)
	if e := owner_lookup(id); e != nil {
		quota, used = keyspace_owner_quota(e, false, 0)
	}
	reply_array(c, 2)
	reply_int(c, quota)
	reply_int(c, used)
}

cmd_owners :: proc(c: ^Conn, argv: [][]u8) {
	if container_precheck(c, argv, "owners", "OWNERS") {
		return
	}
	sub := argv[1]
	switch {
	case eq_nocase(sub, "help"):
		c.last_cmd = "owners|help"
		reply_array(c, len(owners_help_lines))
		for line in owners_help_lines {
			reply_simple(c, line)
		}
		return
	case eq_nocase(sub, "forget"):
		c.last_cmd = "owners|forget"
	case eq_nocase(sub, "info"):
		c.last_cmd = "owners|info"
	case eq_nocase(sub, "list"):
		c.last_cmd = "owners|list"
	case eq_nocase(sub, "quota"):
		c.last_cmd = "owners|quota"
	}
	if !owners_on {
		reply_error(c, ERR_OWNERS_OFF)
		return
	}
	if !access.top {
		reply_error(c, access_top_refusal())
		return
	}
	switch {
	case eq_nocase(sub, "forget"):
		owners_forget(c, argv[2])
	case eq_nocase(sub, "info"):
		owners_info(c, argv[2])
	case eq_nocase(sub, "list"):
		owners_list(c, argv)
	case eq_nocase(sub, "quota"):
		owners_quota(c, argv)
	}
}

@(private = "file")
owner_commands := [?]Command{{"owners", cmd_owners, -2}}

@(init)
register_owner_commands :: proc "contextless" () {
	register_commands(owner_commands[:])
}
