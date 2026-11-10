package vsettype

import "core:math"
import "core:strconv"
import "core:strings"

Replay_Key :: struct {
	set:   Vset,
	other: bool,
}

Replay :: struct {
	dbs:    [16]map[string]Replay_Key,
	db:     [4]int,
	dump:   []u8,
	sc:     Scratch,
	resp:   Resp,
	floats: [dynamic]f32,
	hits:   [dynamic]Hit,
	slots:  [dynamic]u32,
	links:  [dynamic]u32,
	values: [dynamic]f32,
	scores: map[string]f64,
	truth:  bool,
}

Outcome :: enum u8 {
	Package,
	Server,
	Args,
}

replay_init :: proc(rp: ^Replay) {
	for &d in rp.dbs {
		d = make(map[string]Replay_Key)
	}
	scratch_init(&rp.sc)
	strings.builder_init(&rp.resp.b)
}

replay_drop :: proc(entry: Replay_Key) {
	if entry.set != nil {
		destroy(entry.set)
	}
}

replay_flush :: proc(rp: ^Replay) {
	for &d in rp.dbs {
		for k, v in d {
			replay_drop(v)
			delete(k)
		}
		clear(&d)
	}
}

replay_destroy :: proc(rp: ^Replay) {
	replay_flush(rp)
	for &d in rp.dbs {
		delete(d)
	}
	scratch_destroy(&rp.sc)
	strings.builder_destroy(&rp.resp.b)
	delete(rp.floats)
	delete(rp.hits)
	delete(rp.slots)
	delete(rp.links)
	delete(rp.values)
	delete(rp.dump)
	delete(rp.scores)
}

replay_db :: proc(rp: ^Replay, proto: int) -> ^map[string]Replay_Key {
	return &rp.dbs[rp.db[proto]]
}

replay_lookup :: proc(rp: ^Replay, proto: int, key: string) -> (entry: Replay_Key, found: bool) {
	return replay_db(rp, proto)[key]
}

replay_store :: proc(rp: ^Replay, proto: int, key: string, entry: Replay_Key) {
	db := replay_db(rp, proto)
	if old, found := db[key]; found {
		replay_drop(old)
		db[key] = entry
		return
	}
	db[strings.clone(key)] = entry
}

replay_delete :: proc(rp: ^Replay, db: ^map[string]Replay_Key, key: string, drop := true) -> bool {
	if key not_in db {
		return false
	}
	k, v := delete_key(db, key)
	if drop {
		replay_drop(v)
	}
	delete(k)
	return true
}

fold :: proc(a: string, b: string) -> bool {
	return strings.equal_fold(a, b)
}

parse_int :: proc(s: string) -> (v: i64, ok: bool) {
	return strconv.parse_i64_of_base(s, 10)
}

parse_vector :: proc(rp: ^Replay, argv: []string, at: ^int) -> (vector: []f32, ok: bool) {
	if at^ + 1 >= len(argv) {
		return nil, false
	}
	form := argv[at^]
	clear(&rp.floats)
	if fold(form, "FP32") {
		blob := argv[at^ + 1]
		if len(blob) == 0 || len(blob) % 4 != 0 {
			return nil, false
		}
		for i := 0; i < len(blob); i += 4 {
			bits := u32(blob[i]) | u32(blob[i + 1]) << 8 | u32(blob[i + 2]) << 16 | u32(blob[i + 3]) << 24
			append(&rp.floats, transmute(f32)bits)
		}
		at^ += 2
		return rp.floats[:], true
	}
	if fold(form, "VALUES") {
		n, nok := parse_int(argv[at^ + 1])
		if !nok || n <= 0 || i64(at^) + 2 + n > i64(len(argv)) {
			return nil, false
		}
		for i in 0 ..< int(n) {
			v, vok := strconv.parse_f64(argv[at^ + 2 + i])
			if !vok || math.is_nan(v) {
				return nil, false
			}
			append(&rp.floats, f32(v))
		}
		at^ += 2 + int(n)
		return rp.floats[:], true
	}
	return nil, false
}

reply_failure :: proc(rp: ^Replay, f: Failure) {
	text, _ := failure_text(f, context.temp_allocator)
	resp_error(&rp.resp, text)
}

WRONGTYPE :: "WRONGTYPE Operation against a key holding the wrong kind of value"

run_vadd :: proc(rp: ^Replay, argv: []string, proto: int) -> Outcome {
	if len(argv) < 5 {
		return .Args
	}
	req: Add_Request
	cas := false
	at := 2
	if fold(argv[at], "REDUCE") {
		r, ok := parse_int(argv[at + 1])
		if !ok || r <= 0 {
			return .Args
		}
		req.reduce = int(r)
		at += 2
	}
	vector, ok := parse_vector(rp, argv, &at)
	if !ok || at >= len(argv) {
		return .Args
	}
	req.vector = vector
	req.name = transmute([]u8)argv[at]
	at += 1
	for at < len(argv) {
		tok := argv[at]
		switch {
		case fold(tok, "CAS"):
			cas = true
			at += 1
		case fold(tok, "NOQUANT"):
			req.quant = .NOQUANT
			at += 1
		case fold(tok, "Q8"):
			req.quant = .Q8
			at += 1
		case fold(tok, "BIN"):
			req.quant = .BIN
			at += 1
		case fold(tok, "EF") || fold(tok, "M") || fold(tok, "SETATTR"):
			if at + 1 >= len(argv) {
				return .Args
			}
			value := argv[at + 1]
			at += 2
			if fold(tok, "SETATTR") {
				req.attr = transmute([]u8)value
				req.set_attr = true
				continue
			}
			n, nok := parse_int(value)
			if fold(tok, "EF") {
				if !nok || n < 1 || n > EF_MAX {
					return .Args
				}
				req.ef = int(n)
			} else {
				if !nok || n < M_MIN || n > M_MAX {
					return .Args
				}
				req.m = int(n)
			}
		case:
			return .Args
		}
	}
	if req.reduce > len(req.vector) {
		return .Args
	}
	entry, found := replay_lookup(rp, proto, argv[1])
	if found && entry.other {
		resp_error(&rp.resp, WRONGTYPE)
		return .Server
	}
	if !found {
		s, f := create_for(&req)
		if f.err != .None {
			reply_failure(rp, f)
			return .Package
		}
		added: bool
		added, f = add(s, &req, &rp.sc)
		if f.err != .None {
			destroy(s)
			reply_failure(rp, f)
			return .Package
		}
		replay_store(rp, proto, argv[1], Replay_Key{set = s})
		resp_bool(&rp.resp, added)
		return .Package
	}
	added: bool
	f: Failure
	if cas {
		plan: Cas_Plan
		f = cas_prepare(entry.set, &req, &plan, &rp.sc)
		if f.err == .None {
			added, f = cas_commit(entry.set, &plan, &rp.sc)
		}
		cas_discard(&plan)
	} else {
		added, f = add(entry.set, &req, &rp.sc)
	}
	if f.err != .None {
		reply_failure(rp, f)
	} else {
		resp_bool(&rp.resp, added)
	}
	return .Package
}

Vsim_Flags :: struct {
	scores:  bool,
	attribs: bool,
}

run_vsim :: proc(rp: ^Replay, argv: []string, proto: int) -> Outcome {
	if len(argv) < 4 {
		return .Args
	}
	req: Search_Request
	flags: Vsim_Flags
	at := 2
	if fold(argv[at], "ELE") {
		req.kind = .Element
		req.element = transmute([]u8)argv[at + 1]
		at += 2
	} else {
		vector, ok := parse_vector(rp, argv, &at)
		if !ok {
			return .Args
		}
		req.vector = vector
	}
	for at < len(argv) {
		tok := argv[at]
		switch {
		case fold(tok, "WITHSCORES"):
			flags.scores = true
			at += 1
		case fold(tok, "WITHATTRIBS"):
			flags.attribs = true
			at += 1
		case fold(tok, "TRUTH"):
			req.truth = true
			at += 1
		case fold(tok, "NOTHREAD"):
			at += 1
		case fold(tok, "COUNT") || fold(tok, "EF") || fold(tok, "EPSILON") || fold(tok, "FILTER") || fold(tok, "FILTER-EF"):
			if at + 1 >= len(argv) {
				return .Args
			}
			value := argv[at + 1]
			at += 2
			switch {
			case fold(tok, "FILTER"):
				req.filter = value
				req.use_filter = true
			case fold(tok, "EPSILON"):
				e, eok := strconv.parse_f64(value)
				if !eok || math.is_nan(e) || e <= 0 {
					return .Args
				}
				req.epsilon = e
				req.use_epsilon = true
			case:
				n, nok := parse_int(value)
				if !nok || n <= 0 {
					return .Args
				}
				if fold(tok, "COUNT") {
					req.count = int(n)
				} else if fold(tok, "EF") {
					if n > EF_MAX {
						return .Args
					}
					req.ef = int(n)
				} else {
					req.filter_ef = int(n)
				}
			}
		case:
			return .Args
		}
	}
	entry, found := replay_lookup(rp, proto, argv[1])
	if !found {
		resp_array(&rp.resp, 0)
		return .Server
	}
	if entry.other {
		resp_error(&rp.resp, WRONGTYPE)
		return .Server
	}
	s := entry.set
	clear(&rp.hits)
	if f := search(s, &req, &rp.sc, &rp.hits); f.err != .None {
		reply_failure(rp, f)
		return .Package
	}
	write_hits(rp, s, rp.hits[:], flags)
	rp.truth = req.truth
	clear(&rp.scores)
	all := Search_Request{kind = req.kind, vector = req.vector, element = req.element, count = card(s), truth = true}
	every: [dynamic]Hit
	defer delete(every)
	search(s, &all, &rp.sc, &every)
	for h in every {
		rp.scores[string(element_name(s, h.slot))] = h.score
	}
	return .Package
}

write_attribute :: proc(rp: ^Replay, s: Vset, slot: u32) {
	if text, has := element_attribute(s, slot); has {
		resp_bulk_text(&rp.resp, text)
	} else {
		resp_null(&rp.resp)
	}
}

write_hits :: proc(rp: ^Replay, s: Vset, hits: []Hit, flags: Vsim_Flags) {
	r := &rp.resp
	if !flags.scores && !flags.attribs {
		resp_array(r, len(hits))
		for h in hits {
			resp_bulk(r, element_name(s, h.slot))
		}
		return
	}
	if r.proto >= 3 {
		resp_count(r, '%', len(hits))
	} else {
		resp_array(r, len(hits) * (3 if flags.scores && flags.attribs else 2))
	}
	for h in hits {
		resp_bulk(r, element_name(s, h.slot))
		if flags.scores && flags.attribs && r.proto >= 3 {
			resp_array(r, 2)
		}
		if flags.scores {
			resp_double(r, h.score)
		}
		if flags.attribs {
			write_attribute(rp, s, h.slot)
		}
	}
}

existing :: proc(rp: ^Replay, argv: []string, proto: int, missing: proc(r: ^Resp)) -> (s: Vset, outcome: Outcome, ok: bool) {
	entry, found := replay_lookup(rp, proto, argv[1])
	if !found {
		missing(&rp.resp)
		return nil, .Server, false
	}
	if entry.other {
		resp_error(&rp.resp, WRONGTYPE)
		return nil, .Server, false
	}
	return entry.set, .Package, true
}

missing_false :: proc(r: ^Resp) {
	resp_bool(r, false)
}

missing_zero :: proc(r: ^Resp) {
	resp_int(r, 0)
}

missing_null :: proc(r: ^Resp) {
	resp_null(r)
}

missing_null_array :: proc(r: ^Resp) {
	resp_null_array(r)
}

missing_empty :: proc(r: ^Resp) {
	resp_array(r, 0)
}

missing_dim :: proc(r: ^Resp) {
	resp_error(r, "ERR key does not exist")
}

run_vrem :: proc(rp: ^Replay, argv: []string, proto: int) -> Outcome {
	if len(argv) != 3 {
		return .Args
	}
	s, outcome, ok := existing(rp, argv, proto, missing_false)
	if !ok {
		return outcome
	}
	removed, emptied, f := remove(s, transmute([]u8)argv[2], &rp.sc)
	if f.err != .None {
		reply_failure(rp, f)
		return .Package
	}
	if emptied {
		replay_delete(rp, replay_db(rp, proto), argv[1])
	}
	resp_bool(&rp.resp, removed)
	return .Package
}

run_vemb :: proc(rp: ^Replay, argv: []string, proto: int) -> Outcome {
	raw := false
	if len(argv) == 4 && fold(argv[3], "RAW") {
		raw = true
	} else if len(argv) != 3 {
		return .Args
	}
	s, outcome, ok := existing(rp, argv, proto, missing_null)
	if !ok {
		return outcome
	}
	slot, found := find(s, transmute([]u8)argv[2])
	r := &rp.resp
	if !found {
		resp_null(r)
		return .Package
	}
	if raw {
		e := raw_embedding(s, slot)
		resp_array(r, 4 if e.has_range else 3)
		resp_status(r, quant_name(e.quant))
		resp_bulk(r, e.data)
		resp_double(r, f64(e.norm))
		if e.has_range {
			resp_double(r, f64(e.range))
		}
		return .Package
	}
	resize(&rp.values, dim(s))
	values := embedding(s, slot, rp.values[:])
	resp_array(r, len(values))
	for v in values {
		resp_double(r, f64(v))
	}
	return .Package
}

run_vlinks :: proc(rp: ^Replay, argv: []string, proto: int) -> Outcome {
	scores := false
	if len(argv) == 4 && fold(argv[3], "WITHSCORES") {
		scores = true
	} else if len(argv) != 3 {
		return .Args
	}
	s, outcome, ok := existing(rp, argv, proto, missing_null)
	if !ok {
		return outcome
	}
	slot, found := find(s, transmute([]u8)argv[2])
	r := &rp.resp
	if !found {
		resp_null(r)
		return .Package
	}
	layers := link_layers(s, slot)
	resp_array(r, layers)
	for i in 0 ..< layers {
		links := layer_links(s, slot, i, &rp.links)
		if scores {
			resp_map(r, len(links))
		} else {
			resp_array(r, len(links))
		}
		for other in links {
			resp_bulk(r, element_name(s, other))
			if scores {
				resp_double(r, f64(link_score(s, slot, other)))
			}
		}
	}
	return .Package
}

run_vinfo :: proc(rp: ^Replay, argv: []string, proto: int) -> Outcome {
	if len(argv) != 2 {
		return .Args
	}
	s, outcome, ok := existing(rp, argv, proto, missing_null_array)
	if !ok {
		return outcome
	}
	r := &rp.resp
	in_ := info(s)
	names := INFO_FIELDS
	resp_map(r, len(names))
	values := [9]i64{0, i64(in_.m), i64(in_.dim), i64(in_.projection_input_dim), i64(in_.size), i64(in_.max_level), i64(in_.attributes_count), i64(in_.vset_uid), i64(in_.max_node_uid)}
	for name, i in names {
		resp_status(r, name)
		if i == 0 {
			resp_status(r, quant_name(in_.quant))
		} else {
			resp_int(r, values[i])
		}
	}
	return .Package
}

run_vrandmember :: proc(rp: ^Replay, argv: []string, proto: int) -> Outcome {
	if len(argv) != 2 && len(argv) != 3 {
		return .Args
	}
	count: i64
	with_count := len(argv) == 3
	if with_count {
		ok: bool
		count, ok = parse_int(argv[2])
		if !ok || argv[2] == "-0" {
			return .Args
		}
	}
	s, outcome, ok := existing(rp, argv, proto, missing_empty if with_count else missing_null)
	if !ok {
		return outcome
	}
	r := &rp.resp
	if !with_count {
		slot, _ := random_member(s)
		resp_bulk(r, element_name(s, slot))
		return .Package
	}
	clear(&rp.slots)
	if count > 0 {
		random_distinct(s, int(min(count, i64(max(int)))), &rp.slots)
	} else if count < 0 {
		total := repeat_total(count)
		for total > 0 {
			chunk := int(min(total, 1000))
			random_repeats(s, chunk, &rp.slots)
			total -= u64(chunk)
		}
	}
	resp_array(r, len(rp.slots))
	for slot in rp.slots {
		resp_bulk(r, element_name(s, slot))
	}
	return .Package
}

parse_lex :: proc(text: string, first: bool) -> (b: Lex_Bound, ok: bool) {
	if text == "-" {
		return Lex_Bound{kind = .Min}, first
	}
	if text == "+" {
		return Lex_Bound{kind = .Max}, !first
	}
	if len(text) >= 2 && (text[0] == '[' || text[0] == '(') {
		return Lex_Bound{kind = .Inclusive if text[0] == '[' else .Exclusive, value = transmute([]u8)text[1:]}, true
	}
	return {}, false
}

run_vrange :: proc(rp: ^Replay, argv: []string, proto: int) -> Outcome {
	if len(argv) != 4 && len(argv) != 5 {
		return .Args
	}
	start, sok := parse_lex(argv[2], true)
	end, eok := parse_lex(argv[3], false)
	if !sok || !eok {
		return .Args
	}
	count := -1
	if len(argv) == 5 {
		n, ok := parse_int(argv[4])
		if !ok {
			return .Args
		}
		count = int(n)
	}
	s, outcome, ok := existing(rp, argv, proto, missing_empty)
	if !ok {
		return outcome
	}
	clear(&rp.slots)
	lex_range(s, start, end, count, &rp.slots)
	resp_array(&rp.resp, len(rp.slots))
	for slot in rp.slots {
		resp_bulk(&rp.resp, element_name(s, slot))
	}
	return .Package
}

run_simple :: proc(rp: ^Replay, argv: []string, proto: int, name: string) -> Outcome {
	r := &rp.resp
	switch name {
	case "VCARD":
		if len(argv) != 2 {
			return .Args
		}
		s, outcome, ok := existing(rp, argv, proto, missing_zero)
		if !ok {
			return outcome
		}
		resp_int(r, i64(card(s)))
	case "VDIM":
		if len(argv) != 2 {
			return .Args
		}
		s, outcome, ok := existing(rp, argv, proto, missing_dim)
		if !ok {
			return outcome
		}
		resp_int(r, i64(dim(s)))
	case "VSETATTR":
		if len(argv) != 4 {
			return .Args
		}
		s, outcome, ok := existing(rp, argv, proto, missing_false)
		if !ok {
			return outcome
		}
		found, _ := set_attribute(s, transmute([]u8)argv[2], transmute([]u8)argv[3])
		resp_bool(r, found)
	case "VGETATTR":
		if len(argv) != 3 {
			return .Args
		}
		s, outcome, ok := existing(rp, argv, proto, missing_null)
		if !ok {
			return outcome
		}
		text, has := get_attribute(s, transmute([]u8)argv[2])
		if has {
			resp_bulk_text(r, text)
		} else {
			resp_null(r)
		}
	case "VISMEMBER":
		if len(argv) != 3 {
			return .Args
		}
		s, outcome, ok := existing(rp, argv, proto, missing_false)
		if !ok {
			return outcome
		}
		resp_bool(r, contains(s, transmute([]u8)argv[2]))
	case:
		return .Args
	}
	return .Package
}

run_generic :: proc(rp: ^Replay, argv: []string, proto: int, name: string) -> Outcome {
	r := &rp.resp
	db := replay_db(rp, proto)
	switch name {
	case "FLUSHALL":
		replay_flush(rp)
		resp_status(r, "OK")
	case "SET", "HSET":
		replay_store(rp, proto, argv[1], Replay_Key{other = true})
		resp_status(r, "OK")
	case "DEL", "UNLINK":
		n := 0
		for key in argv[1:] {
			if replay_delete(rp, db, key) {
				n += 1
			}
		}
		resp_int(r, i64(n))
	case "EXISTS":
		n := 0
		for key in argv[1:] {
			if key in db {
				n += 1
			}
		}
		resp_int(r, i64(n))
	case "RENAME":
		entry, found := db[argv[1]]
		if !found {
			resp_error(r, "ERR no such key")
		} else {
			replay_delete(rp, db, argv[1], false)
			replay_store(rp, proto, argv[2], entry)
			resp_status(r, "OK")
		}
	case "SELECT":
		n, _ := parse_int(argv[1])
		rp.db[proto] = int(n)
		resp_status(r, "OK")
	case "MOVE":
		n, _ := parse_int(argv[2])
		entry, found := db[argv[1]]
		if found {
			replay_delete(rp, db, argv[1], false)
			target := &rp.dbs[n]
			target[strings.clone(argv[1])] = entry
		}
		resp_int(r, 1 if found else 0)
	case "PEXPIRE":
		replay_delete(rp, db, argv[1])
		resp_int(r, 1)
	case "EXPIRE":
		resp_int(r, 1)
	case "DUMP":
		entry, found := db[argv[1]]
		delete(rp.dump)
		rp.dump = nil
		if found && entry.set != nil {
			rp.dump, _ = serialize_bytes(entry.set)
		}
		resp_status(r, "OK")
	case "RESTORE":
		s, err := deserialize(rp.dump, &rp.sc)
		if err != .None {
			resp_error(r, "ERR Bad data format")
		} else {
			replay_store(rp, proto, argv[1], Replay_Key{set = s})
			resp_status(r, "OK")
		}
	case:
		return .Args
	}
	return .Server
}

replay_run :: proc(rp: ^Replay, argv: []string, proto: int) -> Outcome {
	resp_reset(&rp.resp, proto)
	name := strings.to_upper(argv[0], context.temp_allocator)
	switch name {
	case "VADD":
		return run_vadd(rp, argv, proto)
	case "VSIM":
		return run_vsim(rp, argv, proto)
	case "VREM":
		return run_vrem(rp, argv, proto)
	case "VEMB":
		return run_vemb(rp, argv, proto)
	case "VLINKS":
		return run_vlinks(rp, argv, proto)
	case "VINFO":
		return run_vinfo(rp, argv, proto)
	case "VRANDMEMBER":
		return run_vrandmember(rp, argv, proto)
	case "VRANGE":
		return run_vrange(rp, argv, proto)
	case "VCARD", "VDIM", "VSETATTR", "VGETATTR", "VISMEMBER":
		return run_simple(rp, argv, proto, name)
	}
	return run_generic(rp, argv, proto, name)
}
