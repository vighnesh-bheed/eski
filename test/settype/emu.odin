package settype_harness

import "base:runtime"
import "core:time"
import eski "../../src"
import lp "../../src/listpack"
import st "../../src/settype"

Key_Kind :: enum u8 {
	String,
	Set,
}

Key :: struct {
	kind:      Key_Kind,
	str:       []u8,
	set:       st.Set,
	tainted:   bool,
	ambiguous: bool,
	ttl:       bool,
}

Set_View :: struct {
	name: string,
	set:  st.Set,
	enc:  st.Encoding,
}

Store_Plan :: struct {
	valid:     bool,
	tainted:   bool,
	ambiguous: bool,
}

Model :: struct {
	db:       map[string]Key,
	resp:     int,
	out:      [dynamic]u8,
	vals:     [dynamic]st.Value,
	srcs:     [dynamic]st.Set,
	unstable: bool,
	random:   bool,
}

@(private = "file")
inproc_booted: bool

@(private = "file")
inproc_temp: runtime.Default_Temp_Allocator

@(private = "file")
inproc_conn: ^eski.Conn

@(private = "file")
inproc_views: [dynamic]Set_View

inproc_boot :: proc() {
	if inproc_booted {
		return
	}
	eski.mono_init()
	eski.config_table_init()
	eski.config_init()
	eski.commands_init()
	eski.stats_init()
	eski.acl_init()
	eski.db_init()
	eski.block_init()
	eski.mem_init()
	eski.info_init()
	eski.hash_store_init()
	eski.persist_init_commands()
	eski.argv_init()
	eski.config_load_string("enable-debug-command yes\nsave \"\"\nappendonly no\n")
	runtime.default_temp_allocator_init(&inproc_temp, 1 << 20, runtime.heap_allocator())
	inproc_booted = true
}

inproc_open :: proc() {
	inproc_boot()
	c := new(eski.Conn, runtime.heap_allocator())
	c.fd = -1
	c.resp = eski.RESP2
	c.db = &eski.dbs[0]
	eski.acl_conn_init(c)
	inproc_conn = c
}

inproc_settle :: proc(c: ^eski.Conn) {
	for spins := 0; c.blocked == .Lazyfree && spins < 100000; spins += 1 {
		eski.lazyfree_drain()
		if c.blocked == .Lazyfree {
			time.sleep(100 * time.Microsecond)
		}
	}
	if c.blocked != .None && c.blocked != .Lazyfree {
		eski.block_unblock_timeout(c)
	}
}

inproc_call :: proc(argv: [][]u8) -> []u8 {
	context.temp_allocator = runtime.default_temp_allocator(&inproc_temp)
	defer free_all(context.temp_allocator)
	c := inproc_conn
	eski.update_clock()
	c.wlen = 0
	eski.db_cur = c.db
	eski.execute(c, argv)
	inproc_settle(c)
	return c.wbuf[:c.wlen]
}

inproc_command :: proc(args: ..string) -> []u8 {
	argv := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		argv[i] = transmute([]u8)a
	}
	return inproc_call(argv)
}

inproc_clone :: proc(s: []u8) -> []u8 {
	out := make([]u8, len(s))
	copy(out, s)
	return out
}

model_make :: proc() -> Model {
	inproc_open()
	model_views_forget()
	inproc_command("FLUSHALL")
	inproc_command("CONFIG", "SET", "rdbcompression", "no")
	return Model{resp = int(inproc_conn.resp)}
}

model_views_forget :: proc() {
	for v in inproc_views {
		delete(v.name)
	}
	clear(&inproc_views)
}

model_release_view :: proc(k: ^Key) {
	if k.set != nil {
		st.destroy(k.set)
		k.set = nil
	}
	delete(k.str)
	k.str = nil
}

model_forget :: proc(m: ^Model, name: string) {
	if name not_in m.db {
		return
	}
	model_release_view(&m.db[name])
	stored, _ := delete_key(&m.db, name)
	delete(stored)
}

model_destroy :: proc(m: ^Model) {
	for name, &k in m.db {
		model_release_view(&k)
		delete(name)
	}
	delete(m.db)
	model_views_forget()
	delete(m.out)
	delete(m.vals)
	delete(m.srcs)
	if inproc_conn != nil {
		inproc_command("FLUSHALL")
	}
	m^ = {}
}

model_note :: proc(m: ^Model, key: []u8) -> ^Key {
	if string(key) not_in m.db {
		m.db[string(inproc_clone(key))] = Key {
			kind = .Set,
		}
	}
	return &m.db[string(key)]
}

server_set :: proc(m: ^Model, key: []u8) -> (e: ^eski.Entry, s: st.Set, found: bool, wrong: bool) {
	e = eski.db_find_in(inproc_conn.db, key)
	if e == nil {
		return nil, nil, false, false
	}
	if eski.entry_type(e) != .Set {
		return e, nil, true, true
	}
	return e, st.Set(eski.entry_object(e, .Set)), true, false
}

server_replace :: proc(e: ^eski.Entry, s: st.Set, fresh: st.Set) {
	st.release_storage(s)
	s.data = fresh.data
	s.table = fresh.table
	s.encoding = fresh.encoding
	lp.lp_mem_free(fresh)
	eski.set_done(e, s)
}

model_install :: proc(m: ^Model, name: string, src: st.Set) {
	e, s, found, wrong := server_set(m, transmute([]u8)name)
	if !found || wrong {
		return
	}
	server_replace(e, s, st.dup(src))
}

model_sync :: proc(m: ^Model) {
	for v in inproc_views {
		if v.name in m.db {
			k := &m.db[v.name]
			if k.kind == .Set && k.set != nil && (k.set != v.set || k.set.encoding != v.enc) {
				model_install(m, v.name, k.set)
			}
		}
	}
	model_views_forget()
}

model_prune :: proc(m: ^Model) {
	gone := make([dynamic]string, context.temp_allocator)
	for name, &k in m.db {
		_, s, found, wrong := server_set(m, transmute([]u8)name)
		if !found || wrong {
			append(&gone, name)
			continue
		}
		if s.encoding != .Listpack || st.size(s) <= 1 {
			k.tainted = false
		}
	}
	for name in gone {
		model_forget(m, name)
	}
}

model_uncertain :: proc(m: ^Model, s: st.Set, key: []u8) -> bool {
	if s == nil || s.encoding == .Intset {
		return false
	}
	if s.encoding == .Hashtable {
		return true
	}
	if k, ok := m.db[string(key)]; ok {
		return k.tainted || k.ambiguous
	}
	return false
}

lookup :: proc(m: ^Model, key: []u8) -> ^Key {
	model_sync(m)
	e := eski.db_find_in(inproc_conn.db, key)
	if e == nil {
		model_forget(m, string(key))
		return nil
	}
	kind := eski.entry_type(e)
	ttl := e.expire_at > 0
	val := e.val
	obj := eski.entry_object(e, kind) if kind != .String else nil
	k := model_note(m, key)
	model_release_view(k)
	k.ttl = ttl
	#partial switch kind {
	case .Set:
		k.kind = .Set
		k.set = st.dup(st.Set(obj))
		append(&inproc_views, Set_View{name = string(inproc_clone(key)), set = k.set, enc = k.set.encoding})
	case .String:
		k.kind = .String
		k.str = inproc_clone(val)
	case:
		k.kind = .String
	}
	return k
}

lookup_set :: proc(m: ^Model, key: []u8) -> (k: ^Key, found: bool, wrong: bool) {
	k = lookup(m, key)
	if k == nil {
		return nil, false, false
	}
	return k, true, k.kind != .Set
}

lower_name :: proc(s: []u8, allocator := context.temp_allocator) -> string {
	out := make([]u8, len(s), allocator)
	for b, i in s {
		out[i] = b + 32 if b >= 'A' && b <= 'Z' else b
	}
	return string(out)
}

arity_of :: proc(name: string) -> (int, bool) {
	inproc_boot()
	cmd := eski.lookup_command(transmute([]u8)name)
	if cmd == nil {
		return 0, false
	}
	return cmd.arity, true
}

parse_i64 :: proc(s: []u8) -> (i64, bool) {
	v: i64
	if !lp.lp_string_to_int64(s, &v) {
		return 0, false
	}
	return v, true
}

spop_count_arg :: proc(arg: []u8) -> (i64, bool) {
	v, ok := parse_i64(arg)
	return v, ok && v >= 0
}

set_members :: proc(s: st.Set, allocator := context.temp_allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	it := st.iterator(s)
	for {
		v, ok := st.next(&it)
		if !ok {
			break
		}
		buf: [lp.LP_INTBUF_SIZE]u8
		b := st.value_bytes(v, &buf)
		c := make([]u8, len(b), allocator)
		copy(c, b)
		append(&out, string(c))
	}
	return out
}

model_gather :: proc(m: ^Model, keys: [][]u8) -> (any_uncertain: bool, first_uncertain: bool, ok: bool) {
	clear(&m.srcs)
	for key, i in keys {
		_, s, found, wrong := server_set(m, key)
		if wrong {
			clear(&m.srcs)
			return false, false, false
		}
		append(&m.srcs, s if found else nil)
		u := found && model_uncertain(m, s, key)
		any_uncertain ||= u
		if i == 0 {
			first_uncertain = u
		}
	}
	return any_uncertain, first_uncertain, true
}

model_sources :: proc(m: ^Model) -> []st.Set {
	out := make([]st.Set, len(m.srcs), context.temp_allocator)
	copy(out, m.srcs[:])
	return out
}

value_is_integer :: proc(v: st.Value) -> bool {
	return v.is_int || lp.lp_string_to_int64(v.str, nil)
}

order_sensitive :: proc(m: ^Model, r: st.Set) -> bool {
	clear(&m.vals)
	it := st.iterator(r)
	integers := 0
	first_text := -1
	for {
		v, ok := st.next(&it)
		if !ok {
			break
		}
		if value_is_integer(v) {
			integers += 1
		} else if first_text < 0 {
			first_text = len(m.vals)
		}
		append(&m.vals, v)
	}
	if integers == 0 || first_text < 0 {
		return false
	}
	ints_first := st.create_intset()
	for v in m.vals {
		if value_is_integer(v) {
			st.add_aux(ints_first, v)
		}
	}
	for v in m.vals {
		if !value_is_integer(v) {
			st.add_aux(ints_first, v)
		}
	}
	text_first := st.create_intset()
	st.add_aux(text_first, m.vals[first_text])
	for v, i in m.vals {
		if i != first_text {
			st.add_aux(text_first, v)
		}
	}
	differs := ints_first.encoding != text_first.encoding
	st.destroy(ints_first)
	st.destroy(text_first)
	clear(&m.vals)
	return differs
}

store_plan :: proc(m: ^Model, name: string, args: [][]u8) -> (plan: Store_Plan) {
	if len(args) < 3 {
		return
	}
	any_uncertain, first_uncertain, ok := model_gather(m, args[2:])
	if !ok {
		return
	}
	r: st.Set
	iterated := any_uncertain
	switch name {
	case "sinterstore":
		r = st.inter_store(model_sources(m))
	case "sunionstore":
		r = st.union_diff(model_sources(m), .Union)
	case:
		r = st.union_diff(model_sources(m), .Diff)
		iterated = first_uncertain
	}
	plan.valid = true
	plan.tainted = iterated && r.encoding == .Listpack && st.size(r) > 1
	plan.ambiguous = name != "sinterstore" && iterated && order_sensitive(m, r)
	st.destroy(r)
	return
}

algebra_unstable :: proc(m: ^Model, name: string, keys: [][]u8) -> bool {
	any_uncertain, first_uncertain, ok := model_gather(m, keys)
	if !ok {
		return false
	}
	if name == "sinter" {
		return any_uncertain
	}
	r: st.Set
	iterated := any_uncertain
	if name == "sunion" {
		r = st.union_diff(model_sources(m), .Union)
	} else {
		r = st.union_diff(model_sources(m), .Diff)
		iterated = first_uncertain
	}
	unstable := st.size(r) > 1 && (iterated || r.encoding == .Hashtable)
	st.destroy(r)
	return unstable
}

spop_is_random :: proc(m: ^Model, args: [][]u8) -> bool {
	if len(args) != 2 && len(args) != 3 {
		return false
	}
	_, s, found, wrong := server_set(m, args[1])
	if !found || wrong {
		return false
	}
	size := i64(st.size(s))
	if len(args) == 2 {
		return size > 1
	}
	count, ok := spop_count_arg(args[2])
	return ok && count > 0 && count < size
}

whole_set_unstable :: proc(m: ^Model, key: []u8) -> bool {
	_, s, found, wrong := server_set(m, key)
	if !found || wrong {
		return false
	}
	single := [1]st.Set{s}
	r := st.union_diff(single[:], .Union)
	unstable := st.size(r) > 1 && (model_uncertain(m, s, key) || r.encoding == .Hashtable)
	st.destroy(r)
	return unstable
}

spop_whole_unstable :: proc(m: ^Model, args: [][]u8) -> bool {
	if len(args) != 3 {
		return false
	}
	_, s, found, wrong := server_set(m, args[1])
	if !found || wrong {
		return false
	}
	count, ok := spop_count_arg(args[2])
	return ok && count >= i64(st.size(s)) && whole_set_unstable(m, args[1])
}

srandmember_classify :: proc(m: ^Model, args: [][]u8, reply: []u8) {
	if len(reply) > 0 && reply[0] == '-' {
		return
	}
	if len(args) != 2 && len(args) != 3 {
		return
	}
	_, s, found, wrong := server_set(m, args[1])
	if !found || wrong {
		return
	}
	size := i64(st.size(s))
	if len(args) == 2 {
		m.random = size > 1
		return
	}
	l, ok := parse_i64(args[2])
	switch {
	case !ok || l == 0:
	case l > 0 && l >= size:
		m.unstable = whole_set_unstable(m, args[1])
	case l > 0:
		m.random = true
	case:
		m.random = size > 1
	}
}

spop_apply :: proc(m: ^Model, key: []u8, popped: [][]u8, count: int) {
	model_sync(m)
	e, s, found, wrong := server_set(m, key)
	if !found || wrong {
		return
	}
	size := st.size(s)
	remaining := size - count
	k := model_note(m, key)
	if count > 0 && count < size && remaining <= count / st.SPOP_MOVE_STRATEGY_MUL {
		uncertain := s.encoding == .Hashtable || k.tainted || k.ambiguous
		gone := make(map[string]bool, len(popped), context.temp_allocator)
		for p in popped {
			gone[string(p)] = true
		}
		fresh := st.create_intset() if s.encoding == .Intset else st.create_listpack()
		it := st.iterator(s)
		for {
			v, ok := st.next(&it)
			if !ok {
				break
			}
			buf: [lp.LP_INTBUF_SIZE]u8
			if string(st.value_bytes(v, &buf)) in gone {
				continue
			}
			st.add_aux(fresh, v)
		}
		server_replace(e, s, fresh)
		k.tainted = uncertain
		k.ambiguous = false
	} else {
		argv := make([][]u8, len(popped) + 2, context.temp_allocator)
		argv[0] = transmute([]u8)string("SREM")
		argv[1] = key
		copy(argv[2:], popped)
		inproc_call(argv)
	}
	model_prune(m)
}

copy_targets_other_db :: proc(args: [][]u8) -> bool {
	for a in args[3:] {
		if lower_name(a) == "db" {
			return true
		}
	}
	return false
}

exec :: proc(m: ^Model, args: [][]u8) -> []u8 {
	model_sync(m)
	clear(&m.out)
	m.unstable = false
	m.random = false
	if len(args) == 0 {
		return m.out[:]
	}
	name := lower_name(args[0])
	plan: Store_Plan
	copied: Key
	copy_known := false
	switch name {
	case "spop":
		if spop_is_random(m, args) {
			m.random = true
			return m.out[:]
		}
		m.unstable = spop_whole_unstable(m, args)
	case "smembers":
		if len(args) == 2 {
			_, s, found, wrong := server_set(m, args[1])
			m.unstable = found && !wrong && model_uncertain(m, s, args[1])
		}
	case "sinter", "sunion", "sdiff":
		m.unstable = algebra_unstable(m, name, args[1:])
	case "sinterstore", "sunionstore", "sdiffstore":
		plan = store_plan(m, name, args)
	case "copy":
		if len(args) >= 3 && !copy_targets_other_db(args) {
			_, _, found, wrong := server_set(m, args[1])
			if found && !wrong {
				copy_known = true
				if k, ok := m.db[string(args[1])]; ok {
					copied = k
				}
			}
		}
	}
	append(&m.out, ..inproc_call(args))
	m.resp = int(inproc_conn.resp)
	switch name {
	case "srandmember":
		srandmember_classify(m, args, m.out[:])
	case "sinterstore", "sunionstore", "sdiffstore":
		if plan.valid {
			if _, _, found, wrong := server_set(m, args[1]); found && !wrong {
				k := model_note(m, args[1])
				k.tainted = plan.tainted
				k.ambiguous = plan.ambiguous
			}
		}
	case "copy":
		if copy_known && string(m.out[:]) == ":1\r\n" {
			k := model_note(m, args[2])
			k.tainted = copied.tainted
			k.ambiguous = copied.ambiguous
		}
	}
	model_prune(m)
	return m.out[:]
}
