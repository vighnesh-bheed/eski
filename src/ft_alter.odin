package main

import "core:fmt"
import fi "ftindex"
import vt "vsettype"

cmd_ft_alter :: proc(c: ^Conn, argv: [][]u8) {
	scope := search_scope()
	index := search_query_index(c, string(argv[1]), scope)
	if index == nil {
		return
	}
	if index.scope != scope {
		reply_error(c, label_in_use_text("INUSE index in use at ", index.scope.label, index.scope.owner))
		return
	}
	at := 2
	skip := eq_nocase(argv[at], "skipinitialscan")
	if skip {
		at += 1
	}
	if !eq_nocase(argv[at], "schema") {
		reply_error(c, "ALTER must be followed by SCHEMA")
		return
	}
	if !eq_nocase(argv[at+1], "add") {
		reply_error(c, "Unknown action passed to ALTER SCHEMA")
		return
	}
	at += 2
	if len(argv) - at < 2 {
		reply_error(c, "ERR wrong number of arguments for 'FT.ALTER' command")
		return
	}
	old := &index.spec
	new := old^
	a := context.temp_allocator
	fields := make([dynamic]fi.Field, a)
	flags := make([dynamic]Search_Attribute, a)
	seen := make(map[string]bool, a)
	append(&fields, ..old.definition.fields)
	append(&flags, ..old.attributes)
	for field in fields {
		seen[field.name] = true
	}
	for at < len(argv) {
		f, options, err := search_field_parse(argv, &at, old.on_json)
		if err != "" {
			reply_error(c, err)
			return
		}
		if old.on_json {
			if why := search_validate_json_path(index.name, f.source, f.name); why != "" {
				reply_error(c, why)
				return
			}
		}
		if seen[f.name] {
			reply_error(c, fmt.tprintf("SEARCH_QUERY_BAD Duplicate field in schema - %s", f.name))
			return
		}
		seen[f.name] = true
		append(&fields, f)
		append(&flags, options)
	}
	new.definition.fields, new.attributes = fields[:], flags[:]
	if !fi.valid_definition(&new.definition) {
		reply_error(c, "SEARCH_QUERY_BAD Invalid index schema")
		return
	}
	bytes := search_definition_bytes(index.name, &new)
	delta := bytes - index.held
	if why := search_definition_admit(scope, delta); why != "" {
		reply_error(c, why)
		return
	}
	allocator := vt.charge_allocator(&index.real)
	owned, err := fi.clone_definition(&new.definition, allocator)
	if err != .None {
		store_fatal("out of memory")
	}
	attributes := make([]Search_Attribute, len(flags), allocator)
	copy(attributes, flags[:])
	old_count := len(old.definition.fields)
	fi.free_definition(&old.definition, allocator)
	delete(old.attributes, allocator)
	old.definition, old.attributes = owned, attributes
	index.held = bytes
	search_scope_charge(scope, delta)
	search_rebuild_schema(index, old_count, skip)
	search_metadata_changed()
	reply_ok(c)
}
