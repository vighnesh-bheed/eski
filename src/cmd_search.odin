package main

import "core:fmt"

SEARCH_MODULE_NAME :: "search"
SEARCH_MODULE_VERSION :: 81001
ERR_SEARCH_EXISTS :: "SEARCH_INDEX_EXISTS Index already exists"
ERR_SEARCH_DB :: "Cannot create index on db != 0"
ERR_SEARCH_UNKNOWN :: "SEARCH_ARG_UNRECOGNIZED Unknown argument"
ERR_SEARCH_PERMISSIONS :: "NOPERM User does not have the required permissions to query the index"

@(private = "file")
search_commands := [?]Command{
	{"FT.AGGREGATE", cmd_ft_aggregate, -3},
	{"FT.CURSOR", cmd_ft_cursor, -2},
	{"FT.EXPLAIN", cmd_ft_explain, -3},
	{"FT.EXPLAINCLI", cmd_ft_explaincli, -3},
	{"FT.HYBRID", cmd_ft_hybrid, -7},
	{"FT.ALIASADD", cmd_ft_aliasadd, 3},
	{"FT.ALIASDEL", cmd_ft_aliasdel, 2},
	{"FT.ALIASUPDATE", cmd_ft_aliasupdate, 3},
	{"FT.ALTER", cmd_ft_alter, -6},
	{"FT.CONFIG", cmd_ft_config, -2},
	{"FT.CREATE", cmd_ft_create, -5},
	{"FT.DROPINDEX", cmd_ft_dropindex, -2},
	{"FT.INFO", cmd_ft_info, 2},
	{"FT.PROFILE", cmd_ft_profile, -5},
	{"FT.SEARCH", cmd_ft_search, -3},
	{"FT.TAGVALS", cmd_ft_tagvals, 3},
	{"FT._LIST", cmd_ft_list, -1},
}

@(init)
register_search_commands :: proc "contextless" () {
	register_module_commands(search_commands[:])
}

search_metadata_command :: #force_inline proc "contextless" (cmd: ^Command) -> bool {
	return cmd.handler == cmd_ft_create || cmd.handler == cmd_ft_dropindex ||
		cmd.handler == cmd_ft_alter || cmd.handler == cmd_ft_aliasadd ||
		cmd.handler == cmd_ft_aliasupdate || cmd.handler == cmd_ft_aliasdel
}

search_reply_missing :: proc(c: ^Conn, name: string) {
	reply_error(c, fmt.tprintf("SEARCH_INDEX_NOT_FOUND Index not found: %s", name))
}

search_reply_string :: proc(c: ^Conn, value: string) {
	for ch in transmute([]u8)value {
		if ch == '\r' || ch == '\n' || ch == 0 {
			reply_bulk_str(c, value)
			return
		}
	}
	reply_simple(c, value)
}

search_acl_allows :: proc(c: ^Conn, index: ^Search_Index) -> bool {
	if c.user == nil {
		return true
	}
	for prefix in index.spec.prefixes {
		if !acl_read_covers_prefix(c.user, transmute([]u8)prefix) {
			return false
		}
	}
	return true
}

cmd_ft_create :: proc(c: ^Conn, argv: [][]u8) {
	if c.db.id != 0 {
		reply_error(c, ERR_SEARCH_DB)
		return
	}
	name := string(argv[1])
	scope := search_scope()
	if search_find(name, scope) != nil {
		reply_error(c, ERR_SEARCH_EXISTS)
		return
	}
	spec, err := search_create_parse(argv)
	if err != "" {
		reply_error(c, err)
		return
	}
	if refusal := search_definition_admit(scope, search_definition_bytes(name, &spec)); refusal != "" {
		reply_error(c, refusal)
		return
	}
	search_index_create(name, scope, spec)
	if lua_active != nil {
		lua_active.wrote = true
	}
	reply_ok(c)
}

cmd_ft_dropindex :: proc(c: ^Conn, argv: [][]u8) {
	del_docs := len(argv) == 3 && eq_nocase(argv[2], "dd")
	if len(argv) > 2 && !del_docs {
		reply_error(c, ERR_SEARCH_UNKNOWN)
		return
	}
	name := string(argv[1])
	scope := search_scope()
	index := search_find(name, scope)
	if index == nil {
		search_reply_missing(c, name)
		return
	}
	if !search_acl_allows(c, index) {
		reply_error(c, ERR_SEARCH_PERMISSIONS)
		return
	}
	if index.scope != scope {
		reply_error(c, label_in_use_text("INUSE index in use at ", index.scope.label, index.scope.owner))
		return
	}
	search_index_drop(index, del_docs)
	pst.dirty += 1
	if lua_active != nil {
		lua_active.wrote = true
	}
	reply_ok(c)
}

cmd_ft_info :: proc(c: ^Conn, argv: [][]u8) {
	name := string(argv[1])
	index := search_find(name, search_scope())
	if index == nil {
		search_reply_missing(c, name)
		return
	}
	if !search_acl_allows(c, index) {
		reply_error(c, ERR_SEARCH_PERMISSIONS)
		return
	}
	if index.uses < max(i64) {
		index.uses += 1
	}
	search_reply_info(c, index)
}

cmd_ft_list :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) != 1 {
		if len(argv) == 2 && eq_nocase(argv[1], "withclusterstate") {
			reply_error(c, "ERR FT._LIST does not support WITHCLUSTERSTATE")
			return
		}
		reply_error(c, ERR_SEARCH_UNKNOWN)
		return
	}
	names := search_names(search_scope())
	reply_set(c, len(names))
	for name in names {
		search_reply_string(c, name)
	}
}
