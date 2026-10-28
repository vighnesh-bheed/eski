package persistence

import "core:os"
import "core:strings"
import "../../src/rdb"

Walk_Str :: struct {
	start:  int,
	end:    int,
	kind:   rdb.String_Kind,
	length: int,
}

Walk_Key :: struct {
	db:          int,
	type:        int,
	key:         string,
	expire:      i64,
	idle:        i64,
	freq:        i64,
	record:      int,
	type_off:    int,
	value_start: int,
	value_end:   int,
	str_from:    int,
	str_to:      int,
}

Walk_Aux :: struct {
	key: string,
	val: string,
}

Walk_Db :: struct {
	id:      int,
	size:    u64,
	expires: u64,
}

Walk :: struct {
	data:      []u8,
	version:   int,
	aux:       [dynamic]Walk_Aux,
	dbs:       [dynamic]Walk_Db,
	keys:      [dynamic]Walk_Key,
	strs:      [dynamic]Walk_Str,
	eof_off:   int,
	end_off:   int,
	stored:    u64,
	computed:  u64,
	ok:        bool,
	reason:    string,
}

read_file :: proc(path: string) -> ([]u8, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return nil, false
	}
	return data, true
}

walk_destroy :: proc(w: ^Walk) {
	for a in w.aux {
		delete(a.key)
		delete(a.val)
	}
	for k in w.keys {
		delete(k.key)
	}
	delete(w.aux)
	delete(w.dbs)
	delete(w.keys)
	delete(w.strs)
}

@(private = "file")
walk_fail :: proc(w: ^Walk, r: ^rdb.Reader, why: string) -> bool {
	w.ok = false
	w.reason = why if rdb.ok(r) else strings.clone(rdb.reader_reason(r), context.temp_allocator)
	return false
}

@(private = "file")
walk_string :: proc(w: ^Walk, r: ^rdb.Reader) -> ([]u8, bool) {
	start := int(rdb.reader_offset(r))
	out, _, kind, good := rdb.get_string_kind(r, 0)
	if !good {
		return nil, false
	}
	append(&w.strs, Walk_Str{start = start, end = int(rdb.reader_offset(r)), kind = kind, length = len(out)})
	return out, true
}

@(private = "file")
walk_len :: proc(r: ^rdb.Reader) -> (u64, bool) {
	v := rdb.get_len(r)
	return v, rdb.ok(r)
}

@(private = "file")
walk_strings :: proc(w: ^Walk, r: ^rdb.Reader, n: u64) -> bool {
	for _ in 0 ..< n {
		if _, good := walk_string(w, r); !good {
			return false
		}
	}
	return true
}

@(private = "file")
walk_value :: proc(w: ^Walk, r: ^rdb.Reader, t: int) -> bool {
	switch t {
	case rdb.TYPE_STRING, rdb.TYPE_HASH_ZIPMAP, rdb.TYPE_LIST_ZIPLIST, rdb.TYPE_SET_INTSET, rdb.TYPE_ZSET_ZIPLIST, rdb.TYPE_HASH_ZIPLIST, rdb.TYPE_HASH_LISTPACK, rdb.TYPE_ZSET_LISTPACK, rdb.TYPE_SET_LISTPACK:
		_, good := walk_string(w, r)
		return good
	case rdb.TYPE_LIST, rdb.TYPE_SET, rdb.TYPE_LIST_QUICKLIST:
		n, good := walk_len(r)
		return good && walk_strings(w, r, n)
	case rdb.TYPE_HASH:
		n, good := walk_len(r)
		return good && walk_strings(w, r, n * 2)
	case rdb.TYPE_ZSET:
		n, good := walk_len(r)
		if !good {
			return false
		}
		for _ in 0 ..< n {
			if _, sgood := walk_string(w, r); !sgood {
				return false
			}
			if _, dgood := rdb.get_double_str(r); !dgood {
				return false
			}
		}
		return true
	case rdb.TYPE_ZSET_2:
		n, good := walk_len(r)
		if !good {
			return false
		}
		for _ in 0 ..< n {
			if _, sgood := walk_string(w, r); !sgood {
				return false
			}
			if _, dgood := rdb.get_double_bin(r); !dgood {
				return false
			}
		}
		return true
	case rdb.TYPE_LIST_QUICKLIST_2:
		n, good := walk_len(r)
		if !good {
			return false
		}
		for _ in 0 ..< n {
			if _, cgood := walk_len(r); !cgood {
				return false
			}
			if _, sgood := walk_string(w, r); !sgood {
				return false
			}
		}
		return true
	case rdb.TYPE_HASH_METADATA:
		if _, mgood := rdb.get_ms(r); !mgood {
			return false
		}
		n, good := walk_len(r)
		if !good {
			return false
		}
		for _ in 0 ..< n {
			if _, tgood := walk_len(r); !tgood {
				return false
			}
			if !walk_strings(w, r, 2) {
				return false
			}
		}
		return true
	case rdb.TYPE_HASH_LISTPACK_EX:
		if _, mgood := rdb.get_ms(r); !mgood {
			return false
		}
		_, good := walk_string(w, r)
		return good
	case rdb.TYPE_STREAM_LISTPACKS, rdb.TYPE_STREAM_LISTPACKS_2, rdb.TYPE_STREAM_LISTPACKS_3:
		return walk_stream(w, r, t)
	}
	return false
}

@(private = "file")
walk_stream :: proc(w: ^Walk, r: ^rdb.Reader, t: int) -> bool {
	nodes, good := walk_len(r)
	if !good || !walk_strings(w, r, nodes * 2) {
		return false
	}
	meta := 3 if t == rdb.TYPE_STREAM_LISTPACKS else 8
	for _ in 0 ..< meta {
		if _, mgood := walk_len(r); !mgood {
			return false
		}
	}
	groups, ggood := walk_len(r)
	if !ggood {
		return false
	}
	for _ in 0 ..< groups {
		if _, ngood := walk_string(w, r); !ngood {
			return false
		}
		ids := 2 if t == rdb.TYPE_STREAM_LISTPACKS else 3
		for _ in 0 ..< ids {
			if _, igood := walk_len(r); !igood {
				return false
			}
		}
		pel, pgood := walk_len(r)
		if !pgood {
			return false
		}
		for _ in 0 ..< pel {
			if _, rgood := rdb.take(r, 16); !rgood {
				return false
			}
			if _, tgood := rdb.get_ms(r); !tgood {
				return false
			}
			if _, cgood := walk_len(r); !cgood {
				return false
			}
		}
		consumers, cgood := walk_len(r)
		if !cgood {
			return false
		}
		for _ in 0 ..< consumers {
			if _, ngood := walk_string(w, r); !ngood {
				return false
			}
			times := 2 if t == rdb.TYPE_STREAM_LISTPACKS_3 else 1
			for _ in 0 ..< times {
				if _, tgood := rdb.get_ms(r); !tgood {
					return false
				}
			}
			own, ogood := walk_len(r)
			if !ogood {
				return false
			}
			for _ in 0 ..< own {
				if _, rgood := rdb.take(r, 16); !rgood {
					return false
				}
			}
		}
	}
	return true
}

walk_rdb :: proc(data: []u8) -> (w: Walk) {
	w.data = data
	r: rdb.Reader
	rdb.reader_init_mem(&r, data, true)
	defer rdb.reader_destroy(&r)
	magic, got := rdb.take(&r, 9)
	if !got || string(magic[:5]) != "REDIS" {
		walk_fail(&w, &r, "bad magic")
		return
	}
	for c in magic[5:] {
		w.version = w.version * 10 + int(c - '0')
	}
	db := 0
	expire, idle, freq: i64 = -1, -1, -1
	record := -1
	for {
		at := int(rdb.reader_offset(&r))
		t := rdb.get_type(&r)
		if t < 0 {
			walk_fail(&w, &r, "short read")
			return
		}
		switch t {
		case rdb.OPCODE_EOF:
			w.eof_off = at
			w.computed = rdb.reader_checksum(&r)
			if w.version >= 5 {
				tail, tgood := rdb.take(&r, 8)
				if !tgood {
					walk_fail(&w, &r, "short trailer")
					return
				}
				for i in 0 ..< 8 {
					w.stored |= u64(tail[i]) << (8 * uint(i))
				}
			}
			w.end_off = int(rdb.reader_offset(&r))
			w.ok = true
			return
		case rdb.OPCODE_AUX:
			k, kgood := rdb.get_string(&r, 0)
			if !kgood {
				walk_fail(&w, &r, "aux key")
				return
			}
			key := strings.clone(string(k))
			v, vgood := rdb.get_string(&r, 1)
			if !vgood {
				delete(key)
				walk_fail(&w, &r, "aux value")
				return
			}
			append(&w.aux, Walk_Aux{key = key, val = strings.clone(string(v))})
		case rdb.OPCODE_SELECTDB:
			id, good := walk_len(&r)
			if !good {
				walk_fail(&w, &r, "selectdb")
				return
			}
			db = int(id)
		case rdb.OPCODE_RESIZEDB:
			size, sgood := walk_len(&r)
			expires, egood := walk_len(&r)
			if !sgood || !egood {
				walk_fail(&w, &r, "resizedb")
				return
			}
			append(&w.dbs, Walk_Db{id = db, size = size, expires = expires})
		case rdb.OPCODE_EXPIRETIME_MS:
			if record < 0 {
				record = at
			}
			ms, good := rdb.get_ms(&r)
			if !good {
				walk_fail(&w, &r, "expire")
				return
			}
			expire = ms
		case rdb.OPCODE_EXPIRETIME:
			if record < 0 {
				record = at
			}
			secs, good := rdb.get_u32_le(&r)
			if !good {
				walk_fail(&w, &r, "expire secs")
				return
			}
			expire = i64(secs) * 1000
		case rdb.OPCODE_IDLE:
			if record < 0 {
				record = at
			}
			v, good := walk_len(&r)
			if !good {
				walk_fail(&w, &r, "idle")
				return
			}
			idle = i64(v)
		case rdb.OPCODE_FREQ:
			if record < 0 {
				record = at
			}
			f, good := rdb.get_u8(&r)
			if !good {
				walk_fail(&w, &r, "freq")
				return
			}
			freq = i64(f)
		case:
			if !rdb.is_object_type(t) {
				walk_fail(&w, &r, "unknown type")
				return
			}
			k, kgood := rdb.get_string(&r, 1)
			if !kgood {
				walk_fail(&w, &r, "key")
				return
			}
			entry := Walk_Key {
				db       = db,
				type     = t,
				key      = strings.clone(string(k)),
				expire   = expire,
				idle     = idle,
				freq     = freq,
				record   = record if record >= 0 else at,
				type_off = at,
			}
			entry.value_start = int(rdb.reader_offset(&r))
			entry.str_from = len(w.strs)
			if !walk_value(&w, &r, t) {
				delete(entry.key)
				walk_fail(&w, &r, "value")
				return
			}
			entry.value_end = int(rdb.reader_offset(&r))
			entry.str_to = len(w.strs)
			append(&w.keys, entry)
			expire, idle, freq = -1, -1, -1
			record = -1
		}
	}
}

walk_aux :: proc(w: ^Walk, key: string) -> (string, bool) {
	for a in w.aux {
		if a.key == key {
			return a.val, true
		}
	}
	return "", false
}

