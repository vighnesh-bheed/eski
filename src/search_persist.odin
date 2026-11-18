package main

import "base:runtime"
import "core:slice"
import "core:strconv"
import "core:strings"
import fi "ftindex"
import lb "label"
import ow "owner"
import "rdb"
import "text"

SEARCH_RDB_MODULE :: u64(0x12c9224ab721d401)
SEARCH_RDB_VERSION :: 1
SEARCH_RDB_ALIAS_VERSION :: 2
SEARCH_RDB_MAX_ARG_BYTES :: u64(1) << 40

@(private = "file")
Search_Load_Name :: struct {
	label: lb.Id,
	owner: string,
	name:  string,
}

@(private = "file")
Search_Load_Definition :: struct {
	name:  Search_Load_Name,
	age:   u64,
	scope: ow.Scope,
	spec:  Search_Create,
}

Search_Load_Alias :: struct {
	name: Search_Load_Name,
	age: u64,
	target_age: u64,
	scope: ow.Scope,
}

Search_Load :: struct {
	arena:   runtime.Arena,
	entries: [dynamic]Search_Load_Definition,
	seen:    map[Search_Load_Name]bool,
	ages:    map[u64]Search_Load_Name,
	aliases: [dynamic]Search_Load_Alias,
	last_alias: bool,
}

search_definitions_ordered :: proc() -> []^Search_Index {
	indexes := make([dynamic]^Search_Index, context.temp_allocator)
	for _, scopes in search_registry {
		for _, bucket in scopes {
			for _, index in bucket.indexes {
				append(&indexes, index)
			}
		}
	}
	slice.sort_by(indexes[:], proc(a, b: ^Search_Index) -> bool { return a.age < b.age })
	return indexes[:]
}

search_definitions_clear :: proc() {
	for index in search_definitions_ordered() {
		search_index_drop(index, false)
	}
	search_age = 0
}

@(private = "file")
search_persist_int :: proc(n: int) -> string {
	buf: [24]u8
	length := format_i64(&buf[0], i64(n))
	return strings.clone(string(buf[:length]), context.temp_allocator)
}

@(private = "file")
search_persist_float :: proc(v: f64) -> string {
	buf: [64]u8
	spelling := strconv.write_float(buf[:], v, 'e', -1, 64)
	return strings.clone(spelling, context.temp_allocator)
}

@(private = "file")
search_vector_args_saved :: proc(args: ^[dynamic]string, f: ^fi.Field, attr: Search_Attribute) {
	v := &f.vector
	append(args, "VECTOR", SEARCH_VECTOR_ALGORITHMS[v.method])
	count := len(args^)
	append(args, "", "TYPE", SEARCH_VECTOR_TYPES[v.elem], "DIM", search_persist_int(v.dim), "DISTANCE_METRIC", SEARCH_VECTOR_METRICS[v.metric])
	if attr.initial_cap != 0 {
		append(args, "INITIAL_CAP", search_persist_int(attr.initial_cap))
	}
	if v.method == .Flat && attr.block_size != 0 {
		append(args, "BLOCK_SIZE", search_persist_int(attr.block_size))
	}
	if v.method == .Hnsw {
		append(args, "M", search_persist_int(v.m), "EF_CONSTRUCTION", search_persist_int(v.ef_construction),
			"EF_RUNTIME", search_persist_int(v.ef_runtime), "EPSILON", search_persist_float(v.epsilon))
	}
	args^[count] = search_persist_int(len(args^) - count - 1)
}

@(private = "file")
search_field_args_saved :: proc(args: ^[dynamic]string, f: ^fi.Field, attr: Search_Attribute, on_json: bool) {
	append(args, f.source)
	if f.name != f.source {
		append(args, "AS", f.name)
	}
	switch f.kind {
	case .Text:
		append(args, "TEXT", "WEIGHT", search_persist_float(f.weight))
		if f.no_stem {
			append(args, "NOSTEM")
		}
	case .Tag:
		append(args, "TAG")
		if !on_json || f.separator != 0 {
			separator := make([]u8, 1, context.temp_allocator)
			separator[0] = f.separator
			append(args, "SEPARATOR", string(separator))
		}
		if f.case_sensitive {
			append(args, "CASESENSITIVE")
		}
	case .Numeric:
		append(args, "NUMERIC")
	case .Vector:
		search_vector_args_saved(args, f, attr)
	case .Geo:
		append(args, "GEO")
	case .Geoshape:
		store_fatal("a search definition has a field kind that cannot be saved")
	}
	if f.sortable {
		append(args, "SORTABLE")
		if attr.unf && f.kind != .Numeric {
			append(args, "UNF")
		}
	}
	if f.no_index {
		append(args, "NOINDEX")
	}
	if f.suffix_trie {
		append(args, "WITHSUFFIXTRIE")
	}
	if f.index_empty {
		append(args, "INDEXEMPTY")
	}
	if f.index_missing {
		append(args, "INDEXMISSING")
	}
}

search_create_args_saved :: proc(index: ^Search_Index) -> []string {
	spec := &index.spec
	def := &spec.definition
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "FT.CREATE", index.name, "ON", "JSON" if spec.on_json else "HASH", "PREFIX", search_persist_int(len(spec.prefixes)))
	append(&args, ..spec.prefixes)
	if spec.explicit_language {
		append(&args, "LANGUAGE", text.language_name(def.language))
	}
	if def.language_field != "" {
		append(&args, "LANGUAGE_FIELD", def.language_field)
	}
	append(&args, "SCORE", search_persist_float(spec.default_score))
	if def.score_field != "" {
		append(&args, "SCORE_FIELD", def.score_field)
	}
	if def.payload_field != "" {
		append(&args, "PAYLOAD_FIELD", def.payload_field)
	}
	if def.stop_mode != .Default {
		append(&args, "STOPWORDS", search_persist_int(len(def.stop_words)))
		append(&args, ..def.stop_words)
	}
	if spec.max_text_fields {
		append(&args, "MAXTEXTFIELDS")
	}
	if spec.indexes_all {
		append(&args, "INDEXALL", "ENABLE")
	}
	if spec.skip_initial_scan {
		append(&args, "SKIPINITIALSCAN")
	}
	append(&args, "SCHEMA")
	for &f, i in def.fields {
		search_field_args_saved(&args, &f, spec.attributes[i], spec.on_json)
	}
	return args[:]
}

search_persist_scope :: proc(scope: ow.Scope, labelled: bool) -> (marking, owner: string, ok: bool) {
	if !labelled {
		return "", "", scope == ow.SHARED_BOTTOM
	}
	l: lb.Label
	if scope.label != lb.BOTTOM_ID {
		l, ok = access_label_of(scope.label)
		if !ok {
			return
		}
	}
	marking, ok = lb.format(&label_scheme, l, context.temp_allocator)
	if ok && scope.owner != ow.SHARED {
		owner, ok = owner_text(scope.owner)
	}
	return
}

@(private = "file")
search_rdb_put_text :: proc(w: ^rdb.Writer, s: string) {
	rdb.put_len(w, ACCESS_MODULE_STRING)
	rdb.put_len(w, u64(len(s)))
	rdb.put_raw(w, transmute([]u8)s)
}

search_write_record :: proc(w: ^rdb.Writer, mode: Access_Mode, labelled: bool, scope: ow.Scope, version, age: u64, args: []string) -> bool {
	marking, owner, known := search_persist_scope(scope, labelled)
	if !known || (owner != "" && !mode.owners) {
		access_save_refused = "a search definition has a scope that cannot be saved in the current mode"
		return false
	}
	rdb.put_u8(w, rdb.OPCODE_MODULE_AUX)
	rdb.put_len(w, SEARCH_RDB_MODULE)
	access_put_uint(w, ACCESS_MODULE_WHEN)
	access_put_uint(w, version)
	access_put_uint(w, access_mode_flags(mode))
	access_put_uint(w, age)
	search_rdb_put_text(w, marking)
	search_rdb_put_text(w, owner)
	access_put_uint(w, u64(len(args)))
	for arg in args {
		search_rdb_put_text(w, arg)
	}
	rdb.put_len(w, rdb.MODULE_OPCODE_EOF)
	return !w.failed
}

search_write_rdb :: proc(w: ^rdb.Writer, mode: Access_Mode, labelled: bool) -> bool {
	for index in search_definitions_ordered() {
		if !search_write_record(w, mode, labelled, index.scope, SEARCH_RDB_VERSION, index.age, search_create_args_saved(index)) {
			return false
		}
	}
	for alias in search_aliases_ordered() {
		args := [3]string{"FT.ALIASADD", alias.name, ft_int_text(i64(alias.target.age))}
		if !search_write_record(w, mode, labelled, alias.scope, SEARCH_RDB_ALIAS_VERSION, alias.age, args[:]) {
			return false
		}
	}
	return true
}

@(private = "file")
search_rdb_get_text :: proc(r: ^rdb.Reader, limit: u64, allocator: runtime.Allocator) -> (string, bool) {
	op, got := access_len(r)
	if !got || op != ACCESS_MODULE_STRING {
		return "", false
	}
	n, sized := access_len(r)
	if !sized || n > limit || (n > rdb.READER_BUF && i64(n) > rdb.reader_remaining(r)) {
		return "", false
	}
	bytes, taken := rdb.take(r, int(n))
	if !taken {
		return "", false
	}
	return strings.clone(string(bytes), allocator), true
}

search_read_rdb :: proc(r: ^rdb.Reader, load: ^Search_Load) -> string {
	placement, placement_ok := access_get_uint(r)
	version, version_ok := access_get_uint(r)
	if !placement_ok || placement != ACCESS_MODULE_WHEN || !version_ok || (version != SEARCH_RDB_VERSION && version != SEARCH_RDB_ALIAS_VERSION) {
		return "the file has a search definition with an unknown placement or version"
	}
	mode, got_mode := access_get_uint(r)
	if !got_mode || mode != access_mode_flags(access_ld.mode) {
		return "the file has a search definition that names another access mode"
	}
	alias := version == SEARCH_RDB_ALIAS_VERSION
	load.last_alias = alias
	age, got_age := access_get_uint(r)
	last: u64
	if alias && len(load.aliases) != 0 {
		last = load.aliases[len(load.aliases) - 1].age
	} else if !alias && len(load.entries) != 0 {
		last = load.entries[len(load.entries) - 1].age
	}
	if !got_age || age == 0 || age > u64(max(i64)) || age <= last || age in load.ages || (!alias && len(load.aliases) != 0) {
		return "the file has a search definition with an invalid creation order"
	}
	allocator := runtime.arena_allocator(&load.arena)
	marking, got_marking := search_rdb_get_text(r, lb.MARKING_MAX, allocator)
	owner, got_owner := search_rdb_get_text(r, ow.TEXT_MAX, allocator)
	if !got_marking || !got_owner || (owner != "" && (!access_ld.mode.owners || !ow.text_valid(transmute([]u8)owner))) {
		return "the file has a search definition with an invalid scope"
	}
	label := lb.BOTTOM_ID
	if access_ld.active {
		logical, failure := lb.parse(&access_ld.header.scheme, marking)
		file_id, known := lb.table_find(&access_ld.header.table, logical)
		if failure.error != .None || !known {
			return "the file has a search definition with a marking missing from its labelled header"
		}
		label = access_ld.labels[file_id]
	} else if marking != "" {
		return "the file has a search definition with a marking outside labelled mode"
	}
	argc, got_count := access_get_uint(r)
	if !got_count || (argc != 3 if alias else argc < 5) || argc > MBULK_MAX || i64(argc) > rdb.reader_remaining(r) / 2 {
		return "the file has a search definition with an invalid argument count"
	}
	args := make([dynamic][]u8, allocator)
	for _ in 0 ..< argc {
		arg, got := search_rdb_get_text(r, SEARCH_RDB_MAX_ARG_BYTES, allocator)
		if !got {
			return "the file has a search definition with an invalid argument length or type"
		}
		append(&args, transmute([]u8)arg)
	}
	if !access_get_end(r) || string(args[0]) != ("FT.ALIASADD" if alias else "FT.CREATE") {
		return "the file has a malformed search definition"
	}
	name := Search_Load_Name{label, owner, string(args[1])}
	if load.seen == nil {
		load.seen = make(map[Search_Load_Name]bool, allocator)
		load.ages = make(map[u64]Search_Load_Name, allocator)
		load.entries = make([dynamic]Search_Load_Definition, allocator)
		load.aliases = make([dynamic]Search_Load_Alias, allocator)
	}
	if name in load.seen {
		return "the file has a duplicate search index definition in one scope"
	}
	if alias {
		target_age, ok := parse_i64(args[2])
		if !ok || target_age <= 0 {
			return "the file has a search alias with an invalid target"
		}
		target, exists := load.ages[u64(target_age)]
		if !exists || (access_ld.active && !access_dominates(name.label, target.label)) || (target.owner != "" && name.owner != target.owner) {
			return "the file has a search alias with an invalid target"
		}
		append(&load.aliases, Search_Load_Alias{name = name, age = age, target_age = u64(target_age)})
	} else {
		context.temp_allocator = allocator
		spec, err := search_create_parse(args[:])
		if err != "" {
			return "the file has an invalid search index schema"
		}
		append(&load.entries, Search_Load_Definition{name = name, age = age, spec = spec})
		load.ages[age] = name
	}
	load.seen[name] = true
	return ""
}

search_rdb_conflicts :: proc(load: ^Search_Load) -> bool {
	latest := load.aliases[len(load.aliases) - 1].name if load.last_alias else load.entries[len(load.entries) - 1].name
	scope := ow.Scope{latest.label, ow.SHARED}
	bucket := search_aliases[scope]
	return search_find_exact(latest.name, scope) != nil || (bucket != nil && bucket.names[latest.name] != nil)
}

search_load_scope :: proc(name: Search_Load_Name) -> (ow.Scope, bool) {
	scope := ow.Scope{label = name.label, owner = ow.SHARED}
	if name.owner != "" {
		e, failure := owner_intern(transmute([]u8)name.owner)
		if failure != .None {
			return {}, false
		}
		scope.owner = e.number
	}
	return scope, true
}

search_load_drop_name :: proc(name: string, scope: ow.Scope) {
	if index := search_find_exact(name, scope); index != nil {
		search_index_drop(index, false)
	}
	if bucket := search_aliases[scope]; bucket != nil {
		if alias := bucket.names[name]; alias != nil {
			search_alias_drop(alias)
		}
	}
}

search_restore_rdb :: proc(load: ^Search_Load, replace: bool) -> string {
	if !replace && u64(len(load.entries) + len(load.aliases)) >= max(u64) - search_age {
		return "the search index creation order is full"
	}
	for &entry in load.entries {
		scope, ok := search_load_scope(entry.name)
		if !ok {
			return "the file has more search owners than the server's owner table holds"
		}
		entry.scope = scope
	}
	for &entry in load.aliases {
		scope, ok := search_load_scope(entry.name)
		if !ok {
			return "the file has more search owners than the server's owner table holds"
		}
		entry.scope = scope
	}
	if replace {
		search_definitions_clear()
	}
	targets := make(map[u64]^Search_Index, context.temp_allocator)
	for &entry in load.entries {
		if !replace {
			search_load_drop_name(entry.name.name, entry.scope)
		}
		index := search_index_create(entry.name.name, entry.scope, entry.spec, scan = false)
		targets[entry.age] = index
		if replace {
			index.age = entry.age
			search_age = index.age
		}
	}
	for &entry in load.aliases {
		if !replace {
			search_load_drop_name(entry.name.name, entry.scope)
		}
		age := search_age
		alias := search_alias_create(entry.name.name, entry.scope, targets[entry.target_age])
		if replace {
			alias.age = entry.age
			search_age = max(age, alias.age)
		}
	}
	search_rebuild_db0()
	return ""
}
