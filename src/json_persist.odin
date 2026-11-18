package main

import "core:crypto/blake2b"
import "jsondoc"
import "rdb"

JSON_RDB_MODULE :: u64(0x12c92225238dfc01)
JSON_MODULE_STRING :: 5

json_rdb_save :: proc(w: ^rdb.Writer, object: ^Json_Object) {
	nodes: int
	size := jsondoc.native_measure(object.doc.root, &nodes)
	rdb.put_len(w, JSON_RDB_MODULE)
	rdb.put_len(w, JSON_MODULE_STRING)
	rdb.put_len(w, u64(size))
	jsondoc.native_write({w, json_write_rdb_bytes}, object.doc.root)
	rdb.put_len(w, rdb.MODULE_OPCODE_EOF)
}

@(private = "file")
json_write_rdb_bytes :: proc (ptr: rawptr, bytes: []u8) {
	w := cast(^rdb.Writer)ptr
	if !w.failed {
		rdb.put_raw(w, bytes)
	}
}

json_rdb_load :: proc(r: ^rdb.Reader) -> ^Json_Object {
	op, encoded, ok := rdb.get_len_enc(r)
	if !ok || encoded || op != JSON_MODULE_STRING {
		rdb.corrupt(r, "has an invalid Eski JSON module payload")
		return nil
	}
	size, size_encoded, got_size := rdb.get_len_enc(r)
	if !got_size || size_encoded {
		rdb.corrupt(r, "has an invalid Eski JSON payload length")
		return nil
	}
	object := json_object_new()
	if object == nil {
		rdb.corrupt(r, "could not allocate an Eski JSON document")
		return nil
	}
	object.doc.root = jsondoc.native_read(r, size, object.doc.allocator)
	if object.doc.root != nil {
		tail, tail_encoded, got_tail := rdb.get_len_enc(r)
		if got_tail && !tail_encoded && tail == rdb.MODULE_OPCODE_EOF {
			return object
		}
	}
	json_object_release(object)
	rdb.corrupt(r, "has an invalid Eski JSON document")
	return nil
}

json_aof_rewrite :: proc(w: ^rdb.Writer, key: []u8, object: ^Json_Object) {
	root := object.doc.root
	nodes: int
	jsondoc.native_measure(root, &nodes)
	if nodes <= jsondoc.MAX_ITEMS && jsondoc.text_preserves_value(root) {
		text, err := jsondoc.serialize(root, allocator = context.allocator)
		if err == "" {
			defer delete(text)
			aof_w_header(w, 4)
			aof_w_str(w, "JSON.SET")
			aof_w_arg(w, key)
			aof_w_str(w, "$")
			aof_w_str(w, text)
			return
		}
	}
	payload: rdb.Writer
	rdb.writer_init_mem(&payload, false, false)
	defer rdb.writer_destroy(&payload)
	dump_payload(&payload, key, {obj = object, type = .Json})
	if payload.failed {
		w.failed = true
		return
	}
	aof_w_header(w, 4)
	aof_w_str(w, "RESTORE")
	aof_w_arg(w, key)
	aof_w_str(w, "0")
	aof_w_arg(w, rdb.writer_bytes(&payload))
}

json_digest :: proc (h: ^blake2b.Context, object: ^Json_Object) {
	jsondoc.native_write({h, json_digest_bytes}, object.doc.root)
}

@(private = "file")
json_digest_bytes :: proc (ptr: rawptr, bytes: []u8) {
	blake2b.update(cast(^blake2b.Context)ptr, bytes)
}
