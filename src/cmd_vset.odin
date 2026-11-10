package main

import "base:runtime"
import "hnsw"
import "vfilter"
import va "vsetargs"
import vt "vsettype"

VSET_MODULE_NAME :: va.MODULE_NAME
VSET_MODULE_VERSION :: va.MODULE_VERSION
ERR_VSET_NO_KEY :: "ERR key does not exist"
ERR_VSET_COPY :: "ERR not supported for this module key"
ERR_VSET_COUNT_RANGE :: "ERR COUNT value is out of range"
VSET_REPLY_CHUNK :: 1024
VSET_SCRATCH_KEEP :: 1 << 16

vset_force_single_threaded: bool

vset_scratch: vt.Scratch
vset_hits: [dynamic]vt.Hit
vset_slots: [dynamic]u32
vset_links: [dynamic]u32
vset_floats: [dynamic]f32

@(private = "file")
vset_commands := [?]Command {
	{"VADD", cmd_vadd, -5},
	{"VCARD", cmd_vcard, 2},
	{"VDIM", cmd_vdim, 2},
	{"VEMB", cmd_vemb, -3},
	{"VGETATTR", cmd_vgetattr, 3},
	{"VINFO", cmd_vinfo, 2},
	{"VISMEMBER", cmd_vismember, 3},
	{"VLINKS", cmd_vlinks, -3},
	{"VRANDMEMBER", cmd_vrandmember, -2},
	{"VRANGE", cmd_vrange, -4},
	{"VREM", cmd_vrem, 3},
	{"VSETATTR", cmd_vsetattr, 4},
	{"VSIM", cmd_vsim, -4},
}

vset_heap :: #force_inline proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

vset_scratch_get :: proc() -> ^vt.Scratch {
	if !vset_scratch.ready {
		vt.scratch_init(&vset_scratch, vset_heap())
	}
	return &vset_scratch
}

vset_object_release :: proc "contextless" (obj: rawptr) -> int {
	s := cast(vt.Vset)obj
	if s == nil {
		return 0
	}
	n := vt.memory_usage(s)
	context = runtime.default_context()
	vt.destroy(s)
	return n
}

vset_object_acct :: proc "contextless" (obj: rawptr) -> int {
	return vt.memory_usage(cast(vt.Vset)obj)
}

vset_object_card :: proc "contextless" (obj: rawptr) -> int {
	return vt.card(cast(vt.Vset)obj)
}

vset_attach :: proc "contextless" (e: ^Entry, s: vt.Vset) {
	entry_object_attach(e, s, .Vectorset, .Raw, vt.memory_usage(s))
}

vset_sync :: proc "contextless" (db: ^Db, s: vt.Vset, before: int) {
	object_account(db, vt.memory_usage(s) - before)
}

vset_lookup :: proc(key: []u8, read: bool) -> (e: ^Entry, s: vt.Vset, wrong: bool) {
	e = db_find_read(key) if read else db_find(key)
	if e == nil {
		return
	}
	if entry_type(e) != .Vectorset {
		return e, nil, true
	}
	return e, cast(vt.Vset)entry_object(e, .Vectorset), false
}

vset_quant :: proc "contextless" (q: va.Quant) -> vt.Quant {
	switch q {
	case .Q8:
		return .Q8
	case .Noquant:
		return .NOQUANT
	case .Bin:
		return .BIN
	}
	return .Q8
}

@(private = "file")
vset_text_int :: proc "contextless" (buf: ^[24]u8, v: int) -> string {
	n := format_i64(raw_data(buf[:]), i64(v))
	return string(buf[:n])
}

vset_reply_parse_error :: proc(c: ^Conn, err: va.Error) {
	reply_error_parts(c, err.text, err.near)
}

vset_reply_failure :: proc(c: ^Conn, f: vt.Failure) {
	a, b: [24]u8
	#partial switch f.err {
	case .Dimension_Mismatch:
		reply_error_parts(c, "ERR Vector dimension mismatch - got ", vset_text_int(&a, f.got), " but set has ", vset_text_int(&b, f.expected))
	case .Projection_Input_Mismatch:
		reply_error_parts(c, "ERR Input dimension mismatch for projection - got ", vset_text_int(&a, f.got), " but projection expects ", vset_text_int(&b, f.expected))
	case .Filter_Syntax:
		reply_error_parts(c, vfilter.SYNTAX_ERROR_PREFIX, vfilter.reply_near(f.near))
	case .None:
	case:
		text, _ := vt.failure_text(f)
		reply_error(c, text)
	}
}

vset_propagate :: proc(c: ^Conn, argv: [][]u8, changed: bool) {
	pst.dirty_explicit = true
	if changed {
		pst.dirty += 1
	}
	aof_emit_explicit(c, argv, changed)
}

vset_reply_attribute :: proc(c: ^Conn, s: vt.Vset, slot: u32) {
	if text, ok := vt.element_attribute(s, slot); ok {
		reply_bulk_str(c, text)
	} else {
		reply_null(c)
	}
}

vset_trim :: proc() {
	if cap(vset_hits) > VSET_SCRATCH_KEEP {
		delete(vset_hits)
		vset_hits = nil
	}
	if cap(vset_slots) > VSET_SCRATCH_KEEP {
		delete(vset_slots)
		vset_slots = nil
	}
	if cap(vset_links) > VSET_SCRATCH_KEEP {
		delete(vset_links)
		vset_links = nil
	}
	if cap(vset_floats) > VSET_SCRATCH_KEEP {
		delete(vset_floats)
		vset_floats = nil
	}
}

vset_output_over :: proc(c: ^Conn) -> bool {
	return c.fd >= 0 && c.kind == .Redis && obuf_normal_limited && obuf_class_over(c, .Normal, &c.obuf_soft)
}

cmd_vadd :: proc(c: ^Conn, argv: [][]u8) {
	req, err := va.parse_vadd(argv[1:], vset_heap())
	defer va.vadd_request_destroy(&req)
	if err.kind != .None {
		vset_reply_parse_error(c, err)
		return
	}
	key := req.key
	defer signal_key(key)
	e, s, wrong := vset_lookup(key, false)
	if wrong {
		pst.dirty_explicit = true
		reply_wrongtype(c)
		return
	}
	add := vt.Add_Request {
		name     = req.element,
		vector   = req.vector,
		quant    = vset_quant(req.quant),
		reduce   = int(req.reduce),
		m        = int(req.m),
		ef       = int(req.ef),
		attr     = req.attributes,
		set_attr = req.set_attributes,
	}
	sc := vset_scratch_get()
	added: bool
	if s == nil {
		created, failed := vt.create_for(&add)
		if failed.err != .None {
			pst.dirty_explicit = true
			vset_reply_failure(c, failed)
			return
		}
		added, failed = vt.add(created, &add, sc)
		if failed.err != .None {
			vt.destroy(created)
			pst.dirty_explicit = true
			vset_reply_failure(c, failed)
			return
		}
		fresh, _ := db_upsert(key)
		vset_attach(fresh, created)
	} else {
		before := vt.memory_usage(s)
		had := vt.contains(s, req.element)
		failed: vt.Failure
		added, failed = vt.add(s, &add, sc)
		vset_sync(e.db, s, before)
		if failed.err != .None {
			lost := had && !vt.contains(s, req.element)
			if vt.card(s) == 0 {
				db_remove(key)
			}
			pst.dirty_explicit = true
			if lost {
				removal := [3][]u8{transmute([]u8)string("VREM"), key, req.element}
				vset_propagate(c, removal[:], true)
			}
			vset_reply_failure(c, failed)
			return
		}
	}
	vset_propagate(c, argv, true)
	reply_bool(c, added)
}

cmd_vrem :: proc(c: ^Conn, argv: [][]u8) {
	req, err := va.parse_vrem(argv[1:])
	if err.kind != .None {
		vset_reply_parse_error(c, err)
		return
	}
	defer signal_key(req.key)
	e, s, wrong := vset_lookup(req.key, false)
	if wrong {
		pst.dirty_explicit = true
		reply_wrongtype(c)
		return
	}
	if s == nil {
		vset_propagate(c, argv, false)
		reply_bool(c, false)
		return
	}
	before := vt.memory_usage(s)
	removed, emptied, failed := vt.remove(s, req.element, vset_scratch_get())
	vset_sync(e.db, s, before)
	if failed.err != .None {
		pst.dirty_explicit = true
		vset_reply_failure(c, failed)
		return
	}
	if emptied {
		db_remove(req.key)
	}
	vset_propagate(c, argv, removed)
	reply_bool(c, removed)
}

cmd_vsetattr :: proc(c: ^Conn, argv: [][]u8) {
	req, err := va.parse_vsetattr(argv[1:])
	if err.kind != .None {
		vset_reply_parse_error(c, err)
		return
	}
	defer signal_key(req.key)
	e, s, wrong := vset_lookup(req.key, false)
	if wrong {
		pst.dirty_explicit = true
		reply_wrongtype(c)
		return
	}
	if s == nil {
		vset_propagate(c, argv, false)
		reply_bool(c, false)
		return
	}
	before := vt.memory_usage(s)
	found, failed := vt.set_attribute(s, req.element, req.attributes)
	vset_sync(e.db, s, before)
	if failed != .None {
		pst.dirty_explicit = true
		vset_reply_failure(c, vt.failure(failed))
		return
	}
	vset_propagate(c, argv, found)
	reply_bool(c, found)
}

cmd_vcard :: proc(c: ^Conn, argv: [][]u8) {
	req, err := va.parse_vcard(argv[1:])
	if err.kind != .None {
		vset_reply_parse_error(c, err)
		return
	}
	_, s, wrong := vset_lookup(req.key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	reply_int(c, i64(vt.card(s)))
}

cmd_vdim :: proc(c: ^Conn, argv: [][]u8) {
	req, err := va.parse_vdim(argv[1:])
	if err.kind != .None {
		vset_reply_parse_error(c, err)
		return
	}
	_, s, wrong := vset_lookup(req.key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		reply_error(c, ERR_VSET_NO_KEY)
		return
	}
	reply_int(c, i64(vt.dim(s)))
}

cmd_vismember :: proc(c: ^Conn, argv: [][]u8) {
	req, err := va.parse_vismember(argv[1:])
	if err.kind != .None {
		vset_reply_parse_error(c, err)
		return
	}
	_, s, wrong := vset_lookup(req.key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	reply_bool(c, s != nil && vt.contains(s, req.element))
}

cmd_vgetattr :: proc(c: ^Conn, argv: [][]u8) {
	req, err := va.parse_vgetattr(argv[1:])
	if err.kind != .None {
		vset_reply_parse_error(c, err)
		return
	}
	_, s, wrong := vset_lookup(req.key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		reply_null(c)
		return
	}
	text, has := vt.get_attribute(s, req.element)
	if !has {
		reply_null(c)
		return
	}
	reply_bulk_str(c, text)
}

cmd_vinfo :: proc(c: ^Conn, argv: [][]u8) {
	req, err := va.parse_vinfo(argv[1:])
	if err.kind != .None {
		vset_reply_parse_error(c, err)
		return
	}
	_, s, wrong := vset_lookup(req.key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		reply_null_array(c)
		return
	}
	info := vt.info(s)
	names := vt.INFO_FIELDS
	reply_map(c, len(names))
	reply_simple(c, names[0])
	reply_simple(c, vt.quant_name(info.quant))
	reply_simple(c, names[1])
	reply_int(c, i64(info.m))
	reply_simple(c, names[2])
	reply_int(c, i64(info.dim))
	reply_simple(c, names[3])
	reply_int(c, i64(info.projection_input_dim))
	reply_simple(c, names[4])
	reply_int(c, i64(info.size))
	reply_simple(c, names[5])
	reply_int(c, i64(info.max_level))
	reply_simple(c, names[6])
	reply_int(c, i64(info.attributes_count))
	reply_simple(c, names[7])
	reply_int(c, i64(info.vset_uid))
	reply_simple(c, names[8])
	reply_int(c, i64(info.max_node_uid))
}

cmd_vemb :: proc(c: ^Conn, argv: [][]u8) {
	req, err := va.parse_vemb(argv[1:])
	if err.kind != .None {
		vset_reply_parse_error(c, err)
		return
	}
	_, s, wrong := vset_lookup(req.key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		reply_null(c)
		return
	}
	slot, found := vt.find(s, req.element)
	if !found {
		reply_null(c)
		return
	}
	if req.raw {
		raw := vt.raw_embedding(s, slot)
		reply_array(c, 4 if raw.has_range else 3)
		reply_simple(c, vt.quant_name(raw.quant))
		reply_bulk(c, raw.data)
		reply_double(c, f64(raw.norm))
		if raw.has_range {
			reply_double(c, f64(raw.range))
		}
		return
	}
	resize(&vset_floats, vt.dim(s))
	values := vt.embedding(s, slot, vset_floats[:])
	reply_array(c, len(values))
	for v in values {
		reply_double(c, f64(v))
	}
}

@(private = "file")
vset_layer_list :: proc(s: vt.Vset, slot: u32, layer: int, layers: int, out: ^[dynamic]u32) {
	clear(out)
	g := &s.graph
	if layer != layers - 1 {
		append(out, ..vt.layer_links(s, slot, layer, &vset_links))
		return
	}
	limit := max(g.m0, 1)
	base := slot
	if hnsw.is_twin(g, slot) {
		base = hnsw.twin_head(g, slot)
		append(out, base)
	}
	links := vt.layer_links(s, base, vt.link_layers(s, base) - 1, &vset_links)
	for other in links {
		if len(out) >= limit {
			return
		}
		if other != slot {
			append(out, other)
		}
		for t := hnsw.next_twin(g, other); t != hnsw.NONE && len(out) < limit; t = hnsw.next_twin(g, t) {
			if t != slot {
				append(out, t)
			}
		}
	}
	for t := hnsw.next_twin(g, base); t != hnsw.NONE && len(out) < limit; t = hnsw.next_twin(g, t) {
		if t != slot {
			append(out, t)
		}
	}
}

cmd_vlinks :: proc(c: ^Conn, argv: [][]u8) {
	req, err := va.parse_vlinks(argv[1:])
	if err.kind != .None {
		vset_reply_parse_error(c, err)
		return
	}
	_, s, wrong := vset_lookup(req.key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		reply_null(c)
		return
	}
	slot, found := vt.find(s, req.element)
	if !found {
		reply_null(c)
		return
	}
	layers := vt.link_layers(s, slot)
	reply_array(c, layers)
	for layer in 0 ..< layers {
		vset_layer_list(s, slot, layer, layers, &vset_slots)
		if req.with_scores {
			reply_map(c, len(vset_slots))
		} else {
			reply_array(c, len(vset_slots))
		}
		for other in vset_slots {
			reply_bulk(c, vt.element_name(s, other))
			if req.with_scores {
				reply_double(c, f64(vt.link_score(s, slot, other)))
			}
		}
	}
	clear(&vset_slots)
}

cmd_vrange :: proc(c: ^Conn, argv: [][]u8) {
	req, err := va.parse_vrange(argv[1:])
	if err.kind != .None {
		vset_reply_parse_error(c, err)
		return
	}
	_, s, wrong := vset_lookup(req.key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		reply_array(c, 0)
		return
	}
	limit, limited := va.vrange_limit(&req)
	count := -1
	if limited {
		count = int(min(limit, i64(max(int))))
	}
	clear(&vset_slots)
	vt.lex_range(s, vset_bound(req.start), vset_bound(req.end), count, &vset_slots)
	reply_array(c, len(vset_slots))
	for slot in vset_slots {
		reply_bulk(c, vt.element_name(s, slot))
	}
	clear(&vset_slots)
	vset_trim()
}

@(private = "file")
vset_bound :: proc "contextless" (b: va.Lex_Bound) -> vt.Lex_Bound {
	switch b.kind {
	case .Min:
		return {kind = .Min}
	case .Max:
		return {kind = .Max}
	case .Inclusive:
		return {kind = .Inclusive, value = b.value}
	case .Exclusive:
		return {kind = .Exclusive, value = b.value}
	}
	return {kind = .Min}
}

cmd_vrandmember :: proc(c: ^Conn, argv: [][]u8) {
	req, err := va.parse_vrandmember(argv[1:])
	if err.kind != .None {
		vset_reply_parse_error(c, err)
		return
	}
	if req.has_count && req.count == min(i64) {
		reply_error(c, ERR_VSET_COUNT_RANGE)
		return
	}
	_, s, wrong := vset_lookup(req.key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if !req.has_count {
		if s == nil {
			reply_null(c)
			return
		}
		slot, _ := vt.random_member(s)
		reply_bulk(c, vt.element_name(s, slot))
		return
	}
	if s == nil || req.count == 0 {
		reply_array(c, 0)
		return
	}
	clear(&vset_slots)
	defer vset_trim()
	defer clear(&vset_slots)
	if req.count > 0 {
		vt.random_distinct(s, int(min(req.count, i64(vt.card(s)))), &vset_slots, vset_heap())
		reply_array(c, len(vset_slots))
		for slot in vset_slots {
			reply_bulk(c, vt.element_name(s, slot))
		}
		return
	}
	total := vt.repeat_total(req.count)
	reply_array(c, int(total))
	for remaining := total; remaining > 0; {
		batch := min(remaining, VSET_REPLY_CHUNK)
		clear(&vset_slots)
		vt.random_repeats(s, int(batch), &vset_slots)
		for slot in vset_slots {
			reply_bulk(c, vt.element_name(s, slot))
		}
		remaining -= batch
		if vset_output_over(c) {
			return
		}
	}
}

@(private = "file")
vset_query_check :: proc "contextless" (s: vt.Vset, req: ^va.Vsim_Request) -> vt.Failure {
	switch req.query {
	case .Element:
		if !vt.contains(s, req.element) {
			return vt.failure(.Element_Not_Found)
		}
	case .Vector:
		n := len(req.vector)
		if n == s.dim {
			return {}
		}
		if s.input_dim > 0 {
			if n != s.input_dim {
				return vt.failure(.Projection_Input_Mismatch, n, s.input_dim)
			}
			return {}
		}
		return vt.failure(.Dimension_Mismatch, n, s.dim)
	}
	return {}
}

cmd_vsim :: proc(c: ^Conn, argv: [][]u8) {
	req, err := va.parse_vsim(argv[1:], vset_heap())
	defer va.vsim_request_destroy(&req)
	if err.kind != .None && err.stage == .Before_Key {
		vset_reply_parse_error(c, err)
		return
	}
	_, s, wrong := vset_lookup(req.key, true)
	if s == nil && !wrong {
		reply_array(c, 0)
		return
	}
	if wrong {
		reply_wrongtype(c)
		return
	}
	if err.kind != .None && err.stage == .After_Key {
		vset_reply_parse_error(c, err)
		return
	}
	if checked := vset_query_check(s, &req); checked.err != .None {
		vset_reply_failure(c, checked)
		return
	}
	if err.kind != .None {
		vset_reply_parse_error(c, err)
		return
	}
	search := vt.Search_Request {
		kind        = .Element if req.query == .Element else .Vector,
		vector      = req.vector,
		element     = req.element,
		count       = int(req.count),
		ef          = int(req.ef),
		epsilon     = req.epsilon,
		use_epsilon = req.epsilon > 0,
		filter      = string(req.filter_text),
		use_filter  = req.has_filter,
		filter_ef   = int(req.filter_ef),
		truth       = req.truth,
	}
	clear(&vset_hits)
	if failed := vt.search(s, &search, vset_scratch_get(), &vset_hits); failed.err != .None {
		clear(&vset_hits)
		vset_reply_failure(c, failed)
		return
	}
	vset_reply_hits(c, s, vset_hits[:], req.with_scores, req.with_attribs)
	clear(&vset_hits)
	vset_trim()
}

vset_reply_hits :: proc(c: ^Conn, s: vt.Vset, hits: []vt.Hit, scores: bool, attribs: bool) {
	n := len(hits)
	switch {
	case scores && attribs:
		if c.resp >= RESP3 {
			reply_map(c, n)
		} else {
			reply_array(c, 3 * n)
		}
		for h in hits {
			reply_bulk(c, vt.element_name(s, h.slot))
			if c.resp >= RESP3 {
				reply_array(c, 2)
			}
			reply_double(c, h.score)
			vset_reply_attribute(c, s, h.slot)
		}
	case scores:
		reply_map(c, n)
		for h in hits {
			reply_bulk(c, vt.element_name(s, h.slot))
			reply_double(c, h.score)
		}
	case attribs:
		reply_map(c, n)
		for h in hits {
			reply_bulk(c, vt.element_name(s, h.slot))
			vset_reply_attribute(c, s, h.slot)
		}
	case:
		reply_array(c, n)
		for h in hits {
			reply_bulk(c, vt.element_name(s, h.slot))
		}
	}
}

ERR_MODULE_NOT_ALLOWED :: "ERR MODULE command not allowed. If the enable-module-command option is set to \"local\", you can run it from a local connection, otherwise you need to set this option in the configuration file, and then restart the server."
ERR_MODULE_LOAD :: "ERR Error loading the extension. Please check the server logs."
ERR_MODULE_UNLOAD_BUILTIN :: "ERR Error unloading module: the module can't be unloaded"
ERR_MODULE_UNLOAD_UNKNOWN :: "ERR Error unloading module: no such module with that name"

@(private = "file")
module_help_lines := [?]string {
	"MODULE <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"LIST",
	"    Return a list of loaded modules.",
	"LOAD <path> [<arg> ...]",
	"    Load a module library from <path>, passing to it any optional arguments.",
	"LOADEX <path> [[CONFIG NAME VALUE] [CONFIG NAME VALUE]] [ARGS ...]",
	"    Load a module library from <path>, while passing it module configurations and optional arguments.",
	"UNLOAD <name>",
	"    Unload a module.",
	"HELP",
	"    Print this help.",
}

@(private = "file")
module_commands := [?]Command {
	{"module", cmd_module, -2},
}

cmd_module :: proc(c: ^Conn, argv: [][]u8) {
	if container_precheck(c, argv, "module", "MODULE") {
		return
	}
	sub := argv[1]
	switch {
	case eq_nocase(sub, "help"):
		reply_array(c, len(module_help_lines))
		for line in module_help_lines {
			reply_simple(c, line)
		}
	case eq_nocase(sub, "list"):
		reply_array(c, 1)
		reply_map(c, 4)
		reply_bulk_str(c, "name")
		reply_bulk_str(c, VSET_MODULE_NAME)
		reply_bulk_str(c, "ver")
		reply_int(c, VSET_MODULE_VERSION)
		reply_bulk_str(c, "path")
		reply_bulk_str(c, "")
		reply_bulk_str(c, "args")
		reply_array(c, 0)
	case !protected_allowed(cfg.enable_module_command, c):
		reply_error(c, ERR_MODULE_NOT_ALLOWED)
	case eq_nocase(sub, "unload"):
		reply_error(c, ERR_MODULE_UNLOAD_BUILTIN if eq_nocase(argv[2], VSET_MODULE_NAME) else ERR_MODULE_UNLOAD_UNKNOWN)
	case:
		reply_error(c, ERR_MODULE_LOAD)
	}
}

@(init)
register_vset_commands :: proc "contextless" () {
	register_module_commands(vset_commands[:])
	register_commands(module_commands[:])
}
