package hyperloglog_test

import "core:strings"
import hll "../../src/hll"

MODEL_ERR_WRONG_KIND :: "WRONGTYPE Operation against a key holding the wrong kind of value"

Model_Kind :: enum u8 {
	String,
	Other,
}

Model_Value :: struct {
	kind: Model_Kind,
	val:  []u8,
}

Model_Event :: struct {
	event: string,
	key:   string,
}

Model :: struct {
	keys:             map[string]Model_Value,
	sparse_max_bytes: int,
	scratch:          [dynamic]u8,
	regs:             [hll.HLL_REGISTERS]u8,
	dirty:            i64,
	aof_records:      int,
	events:           [dynamic]Model_Event,
	out:              [dynamic]u8,
	dump_found:       bool,
	dump_value:       []u8,
}

Model_Status :: enum u8 {
	Missing,
	Ok,
	Wrong_Kind,
	Not_Hll,
}

model_init :: proc(m: ^Model) {
	m.keys = make(map[string]Model_Value)
	m.sparse_max_bytes = hll.HLL_SPARSE_MAX_BYTES_DEFAULT
	m.scratch = make([dynamic]u8)
	m.events = make([dynamic]Model_Event)
	m.out = make([dynamic]u8)
}

model_destroy :: proc(m: ^Model) {
	for k, v in m.keys {
		delete(k)
		delete(v.val)
	}
	delete(m.keys)
	delete(m.scratch)
	for ev in m.events {
		delete(ev.key)
	}
	delete(m.events)
	delete(m.out)
}

model_set :: proc(m: ^Model, key: []u8, val: []u8, kind := Model_Kind.String) {
	copy_val := make([]u8, len(val))
	copy(copy_val, val)
	if existing, found := &m.keys[string(key)]; found {
		delete(existing.val)
		existing.val = copy_val
		existing.kind = kind
		return
	}
	m.keys[strings.clone(string(key))] = Model_Value{kind = kind, val = copy_val}
}

model_lookup :: proc(m: ^Model, key: []u8) -> (v: ^Model_Value, status: Model_Status) {
	found: bool
	v, found = &m.keys[string(key)]
	if !found {
		return nil, .Missing
	}
	if v.kind != .String {
		return v, .Wrong_Kind
	}
	if !hll.hll_is_valid(v.val) {
		return v, .Not_Hll
	}
	return v, .Ok
}

@(private = "file")
put_line :: proc(m: ^Model, prefix: u8, s: string) {
	append(&m.out, prefix)
	append(&m.out, s)
	append(&m.out, "\r\n")
}

@(private = "file")
put_int :: proc(m: ^Model, v: i64) {
	buf: [24]u8
	n := 0
	x := v
	negative := x < 0
	for {
		d := x % 10
		if d < 0 {
			d = -d
		}
		buf[n] = u8('0' + d)
		n += 1
		x /= 10
		if x == 0 {
			break
		}
	}
	append(&m.out, ':')
	if negative {
		append(&m.out, '-')
	}
	for i := n - 1; i >= 0; i -= 1 {
		append(&m.out, buf[i])
	}
	append(&m.out, "\r\n")
}

@(private = "file")
put_bulk :: proc(m: ^Model, s: []u8) {
	append(&m.out, '$')
	head: [24]u8
	n := 0
	x := len(s)
	for {
		head[n] = u8('0' + x % 10)
		n += 1
		x /= 10
		if x == 0 {
			break
		}
	}
	for i := n - 1; i >= 0; i -= 1 {
		append(&m.out, head[i])
	}
	append(&m.out, "\r\n")
	append(&m.out, ..s)
	append(&m.out, "\r\n")
}

@(private = "file")
put_error :: proc(m: ^Model, msg: string) {
	put_line(m, '-', msg)
}

@(private = "file")
put_status_error :: proc(m: ^Model, status: Model_Status) {
	if status == .Wrong_Kind {
		put_error(m, MODEL_ERR_WRONG_KIND)
	} else {
		put_error(m, hll.HLL_ERR_WRONGTYPE)
	}
}

@(private = "file")
put_arity :: proc(m: ^Model, name: string) {
	append(&m.out, "-ERR wrong number of arguments for '")
	append(&m.out, name)
	append(&m.out, "' command\r\n")
}

@(private = "file")
notify_event :: proc(m: ^Model, event: string, key: []u8) {
	append(&m.events, Model_Event{event = event, key = strings.clone(string(key))})
}

@(private = "file")
model_pfadd :: proc(m: ^Model, argv: [][]u8) {
	key := argv[1]
	v, status := model_lookup(m, key)
	if status == .Wrong_Kind || status == .Not_Hll {
		put_status_error(m, status)
		return
	}
	created := status == .Missing
	empty := hll.HLL_EMPTY_SPARSE
	cur := empty[:] if created else v.val
	clear(&m.scratch)
	changed, in_scratch, err := hll.pfadd_apply(cur, argv[2:], &m.scratch, m.sparse_max_bytes)
	if created {
		model_set(m, key, m.scratch[:] if in_scratch && changed else cur)
	} else if in_scratch && changed {
		model_set(m, key, m.scratch[:])
	}
	if err != .None {
		put_error(m, hll.hll_error_message(err))
		return
	}
	if !created && !changed {
		put_int(m, 0)
		return
	}
	if created {
		m.dirty += 1
	}
	if changed {
		m.dirty += 1
	}
	notify_event(m, "pfadd", key)
	put_int(m, 1)
}

@(private = "file")
model_pfcount :: proc(m: ^Model, argv: [][]u8) {
	if len(argv) == 2 {
		v, status := model_lookup(m, argv[1])
		switch status {
		case .Missing:
			put_int(m, 0)
			return
		case .Wrong_Kind, .Not_Hll:
			put_status_error(m, status)
			return
		case .Ok:
		}
		if hll.hll_cache_valid(v.val) {
			put_int(m, i64(hll.hll_cached_card(v.val)))
			return
		}
		invalid := false
		card := hll.hll_count(v.val, &invalid)
		if invalid {
			put_error(m, hll.HLL_ERR_INVALIDOBJ)
			return
		}
		m.dirty += 1
		m.aof_records += 1
		put_int(m, i64(card))
		return
	}
	m.regs = {}
	for key in argv[1:] {
		v, status := model_lookup(m, key)
		switch status {
		case .Missing:
			continue
		case .Wrong_Kind, .Not_Hll:
			put_status_error(m, status)
			return
		case .Ok:
		}
		if hll.hll_merge_into(&m.regs, v.val) != .None {
			put_error(m, hll.HLL_ERR_INVALIDOBJ)
			return
		}
	}
	put_int(m, i64(hll.hll_estimate_raw(&m.regs)))
}

@(private = "file")
model_pfmerge :: proc(m: ^Model, argv: [][]u8) {
	m.regs = {}
	use_dense := false
	for key in argv[1:] {
		v, status := model_lookup(m, key)
		switch status {
		case .Missing:
			continue
		case .Wrong_Kind, .Not_Hll:
			put_status_error(m, status)
			return
		case .Ok:
		}
		if v.val[4] == hll.HLL_DENSE {
			use_dense = true
		}
		if hll.hll_merge_into(&m.regs, v.val) != .None {
			put_error(m, hll.HLL_ERR_INVALIDOBJ)
			return
		}
	}
	dest := argv[1]
	v, status := model_lookup(m, dest)
	exists := status == .Ok
	clear(&m.scratch)
	in_scratch, err := hll.pfmerge_apply(v.val if exists else nil, exists, &m.regs, use_dense, &m.scratch, m.sparse_max_bytes)
	if err != .None {
		put_error(m, hll.hll_error_message(err))
		return
	}
	if in_scratch {
		model_set(m, dest, m.scratch[:])
	}
	m.dirty += 1
	notify_event(m, "pfadd", dest)
	put_line(m, '+', "OK")
}

@(private = "file")
model_pfdebug :: proc(m: ^Model, argv: [][]u8) {
	sub := argv[1]
	key := argv[2]
	v, status := model_lookup(m, key)
	switch status {
	case .Missing:
		put_error(m, hll.HLL_ERR_NO_KEY)
		return
	case .Wrong_Kind, .Not_Hll:
		put_status_error(m, status)
		return
	case .Ok:
	}
	lower := strings.to_lower(string(sub))
	defer delete(lower)
	switch lower {
	case "getreg":
		if v.val[4] == hll.HLL_SPARSE {
			clear(&m.scratch)
			converted, err := hll.to_dense_apply(v.val, &m.scratch)
			if err != .None {
				put_error(m, hll.hll_error_message(err))
				return
			}
			if converted {
				model_set(m, key, m.scratch[:])
				m.dirty += 1
			}
		}
		v, _ = model_lookup(m, key)
		hll.hll_get_registers(v.val, &m.regs)
		append(&m.out, "*16384\r\n")
		for value in m.regs {
			put_int(m, i64(value))
		}
	case "decode":
		if v.val[4] != hll.HLL_SPARSE {
			put_error(m, hll.HLL_ERR_NOT_SPARSE)
			return
		}
		clear(&m.scratch)
		hll.sparse_debug_append(v.val, &m.scratch)
		put_bulk(m, m.scratch[:])
	case "encoding":
		put_line(m, '+', hll.hll_encoding_name(v.val))
	case "todense":
		clear(&m.scratch)
		converted, err := hll.to_dense_apply(v.val, &m.scratch)
		if err != .None {
			put_error(m, hll.hll_error_message(err))
			return
		}
		if converted {
			model_set(m, key, m.scratch[:])
			m.dirty += 1
			put_int(m, 1)
		} else {
			put_int(m, 0)
		}
	case:
		append(&m.out, "-ERR Unknown PFDEBUG subcommand '")
		append(&m.out, ..sub)
		append(&m.out, "'\r\n")
	}
}

@(private = "file")
parse_int :: proc(s: []u8) -> (v: int, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	for c in s {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v * 10 + int(c - '0')
	}
	return v, true
}

model_exec :: proc(m: ^Model, argv: [][]u8) {
	clear(&m.out)
	m.dump_found = false
	m.dump_value = nil
	name := strings.to_lower(string(argv[0]))
	defer delete(name)
	switch name {
	case "pfadd":
		if len(argv) < 2 {
			put_arity(m, name)
			return
		}
		model_pfadd(m, argv)
	case "pfcount":
		if len(argv) < 2 {
			put_arity(m, name)
			return
		}
		model_pfcount(m, argv)
	case "pfmerge":
		if len(argv) < 2 {
			put_arity(m, name)
			return
		}
		model_pfmerge(m, argv)
	case "pfdebug":
		if len(argv) != 3 {
			put_arity(m, name)
			return
		}
		model_pfdebug(m, argv)
	case "pfselftest":
		if len(argv) != 1 {
			put_arity(m, name)
			return
		}
		ok, msg := hll.hll_selftest(0x1234_5678_9abc_def0)
		if ok {
			put_line(m, '+', "OK")
		} else {
			put_error(m, msg)
		}
	case "set":
		model_set(m, argv[1], argv[2])
		m.dirty += 1
		put_line(m, '+', "OK")
	case "lpush":
		model_set(m, argv[1], argv[2], .Other)
		m.dirty += 1
		put_int(m, 1)
	case "get":
		v, found := m.keys[string(argv[1])]
		if !found {
			append(&m.out, "$-1\r\n")
		} else {
			put_bulk(m, v.val)
		}
	case "strlen":
		v, found := m.keys[string(argv[1])]
		put_int(m, i64(len(v.val)) if found else 0)
	case "exists":
		_, found := m.keys[string(argv[1])]
		put_int(m, 1 if found else 0)
	case "append":
		joined := make([dynamic]u8)
		defer delete(joined)
		if v, found := m.keys[string(argv[1])]; found {
			append(&joined, ..v.val)
		}
		append(&joined, ..argv[2])
		model_set(m, argv[1], joined[:])
		m.dirty += 1
		put_int(m, i64(len(joined)))
	case "config":
		limit, ok := parse_int(argv[3])
		if ok {
			m.sparse_max_bytes = limit
		}
		put_line(m, '+', "OK")
	case "dump":
		v, found := m.keys[string(argv[1])]
		m.dump_found = found
		if found {
			m.dump_value = v.val
		}
	case:
		put_error(m, "ERR unknown command in model")
	}
}
