package main

import "base:runtime"
import "jsondoc"

JSON_MODULE_NAME :: "ReJSON"
JSON_MODULE_VERSION :: 81000

@(private = "file")
json_workspace: jsondoc.Workspace

@(private = "file")
json_commands := [?]Command {
	{"json.arrappend", cmd_json, -3},
	{"json.arrindex", cmd_json, -4},
	{"json.arrinsert", cmd_json, -5},
	{"json.arrlen", cmd_json, -2},
	{"json.arrpop", cmd_json, -2},
	{"json.arrtrim", cmd_json, 5},
	{"json.clear", cmd_json, -2},
	{"json.debug", cmd_json, -2},
	{"json.del", cmd_json, -2},
	{"json.forget", cmd_json, -2},
	{"json.get", cmd_json, -2},
	{"json.merge", cmd_json, -4},
	{"json.mget", cmd_json, -3},
	{"json.mset", cmd_json, -4},
	{"json.numincrby", cmd_json, 4},
	{"json.nummultby", cmd_json, 4},
	{"json.numpowby", cmd_json, 4},
	{"json.objkeys", cmd_json, -2},
	{"json.objlen", cmd_json, -2},
	{"json.resp", cmd_json, -2},
	{"json.set", cmd_json, -4},
	{"json.strappend", cmd_json, -3},
	{"json.strlen", cmd_json, -2},
	{"json.toggle", cmd_json, 3},
	{"json.type", cmd_json, -2},
}

@(init)
register_json_commands :: proc "contextless" () {
	register_commands(json_commands[:])
}

json_write :: proc "contextless" (op: jsondoc.Operation) -> bool {
	switch op {
	case .Set, .Merge, .Mset, .Arr_Append, .Arr_Insert, .Arr_Pop, .Arr_Trim, .Clear, .Del,
	     .Forget, .Num_Incr, .Num_Mult, .Num_Pow, .Str_Append, .Toggle:
		return true
	case .Unknown, .Arr_Index, .Arr_Len, .Debug_Help, .Debug_Memory, .Get, .Mget, .Obj_Keys,
	     .Obj_Len, .Resp, .Str_Len, .Type:
		return false
	}
	return false
}

@(private = "file")
json_args :: proc(args: [][]u8, allocator: runtime.Allocator) -> ([]string, bool) {
	out, err := make([]string, len(args), allocator)
	if err != nil {
		return nil, false
	}
	for arg, i in args {
		out[i] = string(arg)
	}
	return out, true
}

@(private = "file")
json_reply :: proc(c: ^Conn, reply: jsondoc.Reply) {
	switch reply.kind {
	case .Nil:
		reply_null(c)
	case .Status:
		reply_simple(c, reply.text)
	case .Error:
		reply_error(c, reply.text)
	case .String:
		reply_bulk_str(c, reply.text)
	case .Integer:
		reply_int(c, reply.integer)
	case .Double:
		buf: [64]u8
		number := jsondoc.resp_double(buf[:], reply.double)
		reply_double_text(c, transmute([]u8)number)
	case .Boolean:
		reply_bool(c, reply.boolean)
	case .Array, .Map:
		if reply.kind == .Map {
			reply_map(c, len(reply.items) / 2)
		} else {
			reply_array(c, len(reply.items))
		}
		for item in reply.items {
			json_reply(c, item)
		}
	}
}

cmd_json :: proc(c: ^Conn, input: [][]u8) {
	argv := input
	op := jsondoc.name_operation(string(argv[0]))
	args := argv[2:]
	if json_write(op) {
		pst.dirty_explicit = true
		if aof.feed { aof_emit_explicit(c, nil, false) }
	}
	if op == .Debug_Memory {
		switch {
		case len(argv) >= 3 && eq_nocase(argv[1], "memory"):
			argv = argv[1:]
			args = argv[2:]
		case eq_nocase(argv[1], "help"):
			op = .Debug_Help
		case eq_nocase(argv[1], "memory"):
			reply_wrong_args(c, "json.debug")
			return
		case:
			reply_error(c, "ERR unknown subcommand - try `JSON.DEBUG HELP`")
			return
		}
	}
	if json_workspace.allocator.procedure == nil && !jsondoc.workspace_init(&json_workspace) {
		reply_error(c, jsondoc.OUT_OF_MEMORY)
		return
	}
	defer jsondoc.workspace_reset(&json_workspace)
	allocator := json_workspace.allocator
	#partial switch op {
	case .Mget:
		json_mget(c, argv[1:], allocator)
	case .Mset:
		json_mset(c, argv, allocator)
	case .Debug_Help:
		out := jsondoc.execute(nil, op, nil, int(c.resp), allocator)
		json_reply(c, out.reply)
	case:
		text, ok := json_args(args, allocator)
		if !ok {
			reply_error(c, jsondoc.OUT_OF_MEMORY)
			return
		}
		json_single(c, argv, op, text, allocator)
	}
}

@(private = "file")
json_single :: proc(c: ^Conn, argv: [][]u8, op: jsondoc.Operation, args: []string, allocator: runtime.Allocator) {
	key := argv[1]
	write := json_write(op)
	entry := db_find(key) if write else db_find_read(key)
	object := json_object_at(entry)
	wrong := entry != nil && object == nil
	elsewhere := entry != nil && label_entry_foreign(entry)
	if write && elsewhere && !json_set_creates_only(argv) {
		reply_error(c, label_in_use_text(ERR_LABEL_NAME_IN_USE, entry.db.label, entry.db.owner))
		return
	}
	if write && entry != nil && !elsewhere {
		signal_key_in(key, entry.db)
	}
	if write && !elsewhere && object == nil && !wrong && (op == .Set || op == .Merge) {
		object = json_object_new()
		if object == nil {
			reply_error(c, jsondoc.OUT_OF_MEMORY)
			return
		}
	}
	db := entry.db if entry != nil else cur_db()
	doc := jsondoc.Document{}
	previous_bytes, previous_charge: int
	if object != nil {
		doc = object.doc
		previous_bytes = object.bytes
		previous_charge = json_object_content_memory(object)
	}
	working := &object.doc if object != nil && !elsewhere else &doc
	out := jsondoc.execute(working, op, args, int(c.resp), allocator, wrong)
	json_reply(c, out.reply)
	if !write || elsewhere {
		return
	}
	if object != nil {
		if entry == nil {
			if object.doc.root != nil {
				target, _ := db_upsert_in(db, key)
				json_object_attach(target, object)
				signal_key_in(key, db)
			} else {
				json_object_release(object)
			}
		} else {
			json_object_sync(db, object, previous_bytes, previous_charge)
			if object.doc.root == nil {
				db_remove_in(db, key)
				search_json_deleted(db, key)
			} else if out.changed {
				search_document_changed(db, key, object, true)
			}
		}
	}
	if out.changed {
		if out.reply.kind != .Error {
			notify_in(.Module, jsondoc.operation_name(.Del if op == .Forget else op), key, db)
		}
		pst.dirty += 1
	}
	json_aof_effect(c, argv, out)
}

@(private = "file")
json_mget :: proc(c: ^Conn, args: [][]u8, allocator: runtime.Allocator) {
	path := string(args[len(args) - 1])
	reply_array(c, len(args) - 1)
	for key in args[:len(args) - 1] {
		object := json_object_at(db_find_read(key))
		root := object.doc.root if object != nil else nil
		json_reply(c, jsondoc.read_mget(root, path, allocator))
	}
}

@(private = "file")
Json_Mset_Key :: struct {
	key:    []u8,
	object: ^Json_Object,
	stored: bool,
}

@(private = "file")
json_mset :: proc(c: ^Conn, argv: [][]u8, allocator: runtime.Allocator) {
	count := (len(argv) - 1) / 3
	keys, keys_err := make([]Json_Mset_Key, count, allocator)
	requests, requests_err := make([]jsondoc.Set_Request, count, allocator)
	refs, refs_err := make([]^Json_Mset_Key, count, allocator)
	positions, positions_err := make(map[string]^Json_Mset_Key, count, allocator)
	if keys_err != nil || requests_err != nil || refs_err != nil || positions_err != nil {
		reply_error(c, jsondoc.OUT_OF_MEMORY)
		return
	}
	defer delete(positions)
	defer {
		for &key in keys {
			if !key.stored && key.object != nil {
				json_object_release(key.object)
			}
		}
	}
	db := cur_db()
	for i := 1; i < len(argv); i += 3 {
		key := argv[i]
		entry := db_find(key)
		object := json_object_at(entry)
		wrong := entry != nil && object == nil
		if entry != nil {
			if label_entry_foreign(entry) {
				reply_error(c, label_in_use_text(ERR_LABEL_NAME_IN_USE, entry.db.label, entry.db.owner))
				return
			}
			signal_key_in(key, entry.db)
		}
		doc := &object.doc if object != nil else &jsondoc.Document{}
		remaining := len(argv) - i
		if remaining < 3 {
			path := string(argv[i + 1]) if remaining == 2 else "$"
			out := jsondoc.mset_short_triple(doc, wrong, path, allocator)
			json_reply(c, out.reply)
			return
		}
		index := i / 3
		triple := jsondoc.Set_Triple{doc, string(argv[i + 1]), string(argv[i + 2]), wrong}
		request, out := jsondoc.prepare_mset_triple(triple, allocator)
		if out.reply.kind == .Error {
			json_reply(c, out.reply)
			return
		}
		requests[index] = request
		target, found := positions[string(key)]
		if !found {
			target = &keys[index]
			target^ = {key, object, object != nil}
			if runtime.map_insert(&positions, string(key), target) == nil {
				reply_error(c, jsondoc.OUT_OF_MEMORY)
				return
			}
		}
		refs[index] = target
	}
	for key in refs {
		if key.object == nil {
			key.object = json_object_new()
			if key.object == nil {
				reply_error(c, jsondoc.OUT_OF_MEMORY)
				return
			}
		}
	}
	status := jsondoc.Outcome{reply = jsondoc.reply_status("OK")}
	for request, i in requests {
		key := refs[i]
		object := key.object
		previous_bytes := object.bytes
		previous_charge := json_object_content_memory(object)
		out := jsondoc.apply_set(&object.doc, request, false, allocator)
		if key.stored {
			json_object_sync(db, object, previous_bytes, previous_charge)
			if out.changed {
				search_document_changed(db, key.key, object, true)
			}
		} else if object.doc.root != nil {
			entry, _ := db_upsert_in(db, key.key)
			json_object_attach(entry, object)
			key.stored = true
			signal_key_in(key.key, db)
		}
		if out.changed {
			status.changed = true
			pst.dirty += 1
			if out.reply.kind != .Error {
				notify_in(.Module, "json.mset", key.key, db)
			}
		}
		if out.reply.kind == .Nil || out.reply.kind == .Error {
			status.reply = out.reply
		}
		if out.reply.kind == .Error {
			break
		}
	}
	json_reply(c, status.reply)
	json_aof_effect(c, argv, status)
}

json_set_creates_only :: proc(argv: [][]u8) -> bool {
	if len(argv) < 5 || !eq_nocase(argv[0], "json.set") || (string(argv[2]) != "$" && string(argv[2]) != ".") {
		return false
	}
	args, ok := json_args(argv[4:], context.temp_allocator)
	if !ok {
		return false
	}
	condition, _, error := jsondoc.set_options(.Set, args, context.temp_allocator)
	return error.reply.kind != .Error && condition == .NX
}

aof_json_replayed_partial: bool

@(private = "file")
json_aof_effect :: proc(c: ^Conn, argv: [][]u8, out: jsondoc.Outcome) {
	if out.changed && out.reply.kind == .Error {
		if out.reply.text == jsondoc.OUT_OF_MEMORY {
			if aof.feed { store_fatal("out of memory applying an append-only JSON write") }
			return
		}
		if aof.loading {
			aof_json_replayed_partial = true
		}
	}
	aof_emit_explicit(c, argv, out.changed)
}
