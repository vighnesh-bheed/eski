package geospatial

import "core:strings"
import geo "../../src/geo"
import zt "../../src/zsettype"

Key_Kind :: enum u8 {
	String,
	Hash,
	Zset,
}

Key :: struct {
	kind: Key_Kind,
	z:    zt.Zset,
}

Model :: struct {
	keys:   map[string]Key,
	resp:   int,
	out:    [dynamic]u8,
	points: [dynamic]geo.Point,
	tmp:    [dynamic]geo.Point,
	scores: [dynamic]f64,
}

WRONGTYPE :: "WRONGTYPE Operation against a key holding the wrong kind of value"

model_init :: proc(m: ^Model) {
	m.resp = 2
}

model_drop_key :: proc(m: ^Model, key: []u8) -> bool {
	if string(key) not_in m.keys {
		return false
	}
	stored, k := delete_key(&m.keys, string(key))
	if k.kind == .Zset {
		zt.destroy(k.z)
	}
	delete(stored)
	return true
}

model_flush :: proc(m: ^Model) {
	for name, k in m.keys {
		if k.kind == .Zset {
			zt.destroy(k.z)
		}
		delete(name)
	}
	clear(&m.keys)
}

model_destroy :: proc(m: ^Model) {
	model_flush(m)
	delete(m.keys)
	delete(m.out)
	delete(m.points)
	delete(m.tmp)
	delete(m.scores)
}

model_put :: proc(m: ^Model, key: []u8, k: Key) {
	if _, found := m.keys[string(key)]; found {
		model_drop_key(m, key)
	}
	m.keys[strings.clone(string(key))] = k
}

w_raw :: proc(m: ^Model, s: string) {
	append(&m.out, s)
}

w_line :: proc(m: ^Model, prefix: u8, body: []u8) {
	append(&m.out, prefix)
	append(&m.out, ..body)
	append(&m.out, "\r\n")
}

w_int :: proc(m: ^Model, v: i64) {
	buf: [32]u8
	w_line(m, ':', transmute([]u8)strings_of_i64(buf[:], v))
}

strings_of_i64 :: proc(buf: []u8, v: i64) -> string {
	neg := v < 0
	mag := u64(0) - u64(v) if neg else u64(v)
	pos := len(buf)
	for {
		pos -= 1
		buf[pos] = u8('0' + mag % 10)
		mag /= 10
		if mag == 0 {
			break
		}
	}
	if neg {
		pos -= 1
		buf[pos] = '-'
	}
	return string(buf[pos:])
}

w_len :: proc(m: ^Model, prefix: u8, n: int) {
	buf: [32]u8
	w_line(m, prefix, transmute([]u8)strings_of_i64(buf[:], i64(n)))
}

w_array :: proc(m: ^Model, n: int) {
	w_len(m, '*', n)
}

w_bulk :: proc(m: ^Model, s: []u8) {
	w_len(m, '$', len(s))
	append(&m.out, ..s)
	append(&m.out, "\r\n")
}

w_null :: proc(m: ^Model) {
	w_raw(m, "_\r\n" if m.resp == 3 else "$-1\r\n")
}

w_null_array :: proc(m: ^Model) {
	w_raw(m, "_\r\n" if m.resp == 3 else "*-1\r\n")
}

w_error :: proc(m: ^Model, s: []u8) {
	w_line(m, '-', s)
}

w_double_text :: proc(m: ^Model, s: []u8) {
	if m.resp == 3 {
		w_line(m, ',', s)
	} else {
		w_bulk(m, s)
	}
}

w_double :: proc(m: ^Model, v: f64) {
	buf: [zt.D2STRING_MAX]u8
	n := zt.d2string(buf[:], v)
	w_double_text(m, buf[:n])
}

w_geo_error :: proc(m: ^Model, err: geo.Error, pair: [2]f64, name: []u8) {
	buf: [geo.ERROR_TEXT_MAX]u8
	w_error(m, geo.error_text(buf[:], err, pair, name))
}

lookup :: proc(m: ^Model, key: []u8) -> (z: zt.Zset, ok: bool) {
	k, found := m.keys[string(key)]
	if !found {
		return nil, true
	}
	if k.kind != .Zset {
		w_error(m, transmute([]u8)string(WRONGTYPE))
		return nil, false
	}
	return k.z, true
}

eq_fold :: proc(a: []u8, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		c := a[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != b[i] {
			return false
		}
	}
	return true
}

member_bytes :: proc(it: ^zt.Item, buf: ^[21]u8) -> []u8 {
	return zt.item_bytes(it, buf)
}

zadd_like :: proc(m: ^Model, key: []u8, flags: zt.Zadd_Flags, ch: bool, scores: []f64, members: [][]u8) {
	z, ok := lookup(m, key)
	if !ok {
		return
	}
	if z == nil {
		if .Xx in flags {
			w_int(m, 0)
			return
		}
		z = zt.type_create(len(scores), len(members[0]))
		model_put(m, key, Key{kind = .Zset, z = z})
	}
	added, updated := 0, 0
	for v, i in scores {
		out, _, _ := zt.add(z, v, members[i], flags)
		if .Added in out {
			added += 1
		}
		if .Updated in out {
			updated += 1
		}
	}
	w_int(m, i64(added + updated if ch else added))
}

cmd_geoadd :: proc(m: ^Model, argv: [][]u8) {
	o, err := geo.parse_add(argv)
	if err != .None {
		w_geo_error(m, err, {}, argv[0])
		return
	}
	clear(&m.scores)
	members := make([dynamic][]u8, 0, (len(argv) - o.first) / 3)
	defer delete(members)
	for i := o.first; i < len(argv); i += 3 {
		xy, perr := geo.parse_long_lat(argv[i], argv[i + 1])
		if perr != .None {
			w_geo_error(m, perr, xy, argv[0])
			return
		}
		append(&m.scores, geo.score_of(xy))
		append(&members, argv[i + 2])
	}
	flags: zt.Zadd_Flags
	if o.nx {
		flags += {.Nx}
	}
	if o.xx {
		flags += {.Xx}
	}
	zadd_like(m, argv[1], flags, o.ch, m.scores[:], members[:])
}

cmd_geopos :: proc(m: ^Model, argv: [][]u8) {
	z, ok := lookup(m, argv[1])
	if !ok {
		return
	}
	w_array(m, len(argv) - 2)
	for member in argv[2:] {
		xy, found := [2]f64{}, false
		if z != nil {
			xy, found = geo.member_xy(z, member)
		}
		if !found {
			w_null_array(m)
			continue
		}
		w_array(m, 2)
		for v in xy {
			buf: [geo.HUMAN_MAX]u8
			n := geo.format_human(buf[:], v)
			w_double_text(m, buf[:n])
		}
	}
}

cmd_geohash :: proc(m: ^Model, argv: [][]u8) {
	z, ok := lookup(m, argv[1])
	if !ok {
		return
	}
	w_array(m, len(argv) - 2)
	for member in argv[2:] {
		score, found := 0.0, false
		if z != nil {
			score, found = zt.score(z, member)
		}
		text: [11]u8
		if !found || !geo.geohash_string(score, &text) {
			w_null(m)
			continue
		}
		w_bulk(m, text[:])
	}
}

cmd_geodist :: proc(m: ^Model, argv: [][]u8) {
	if len(argv) > 5 {
		w_geo_error(m, .Syntax, {}, argv[0])
		return
	}
	conversion := 1.0
	if len(argv) == 5 {
		known: bool
		conversion, known = geo.unit_to_meters(argv[4])
		if !known {
			w_geo_error(m, .Unit, {}, argv[0])
			return
		}
	}
	z, ok := lookup(m, argv[1])
	if !ok {
		return
	}
	if z == nil {
		w_null(m)
		return
	}
	a, afound := geo.member_xy(z, argv[2])
	b, bfound := geo.member_xy(z, argv[3])
	if !afound || !bfound {
		w_null(m)
		return
	}
	buf: [geo.DISTANCE_MAX]u8
	n := geo.format_distance(buf[:], geo.distance(a[0], a[1], b[0], b[1]) / conversion)
	w_bulk(m, buf[:n])
}

store_points :: proc(m: ^Model, key: []u8, points: []geo.Point, req: ^geo.Request) {
	if len(points) == 0 {
		model_drop_key(m, key)
		w_int(m, 0)
		return
	}
	dst := zt.create_skiplist(len(points))
	maxlen, totlen := 0, 0
	for &p in points {
		buf: [21]u8
		member := member_bytes(&p.member, &buf)
		maxlen = max(maxlen, len(member))
		totlen += len(member)
		score := p.dist / req.shape.conversion if req.store_dist else p.score
		_, _, _ = zt.add(dst, score, member, {})
	}
	zt.convert_to_listpack_if_needed(dst, maxlen, totlen)
	model_put(m, key, Key{kind = .Zset, z = dst})
	w_int(m, i64(len(points)))
}

georadius_generic :: proc(m: ^Model, argv: [][]u8, src_index: int, flags: geo.Request_Flags) {
	z, ok := lookup(m, argv[src_index])
	if !ok {
		return
	}
	req, err := geo.parse_request(argv, src_index, flags, z)
	if err != .None {
		w_geo_error(m, err, req.pair, argv[0])
		return
	}
	if z == nil {
		if req.store {
			model_drop_key(m, req.store_key)
			w_int(m, 0)
		} else {
			w_array(m, 0)
		}
		return
	}
	clear(&m.points)
	n := geo.run(z, &req, &m.points, &m.tmp)
	points := m.points[:n]
	if req.store {
		store_points(m, req.store_key, points, &req)
		return
	}
	w_array(m, n)
	extra := int(req.with_dist) + int(req.with_hash) + int(req.with_coord)
	for &p in points {
		buf: [21]u8
		member := member_bytes(&p.member, &buf)
		if extra == 0 {
			w_bulk(m, member)
			continue
		}
		w_array(m, 1 + extra)
		w_bulk(m, member)
		if req.with_dist {
			dbuf: [geo.DISTANCE_MAX]u8
			dn := geo.format_distance(dbuf[:], p.dist / req.shape.conversion)
			w_bulk(m, dbuf[:dn])
		}
		if req.with_hash {
			w_int(m, i64(geo.score_to_bits(p.score)))
		}
		if req.with_coord {
			w_array(m, 2)
			for v in ([2]f64{p.longitude, p.latitude}) {
				hbuf: [geo.HUMAN_MAX]u8
				hn := geo.format_human(hbuf[:], v)
				w_double_text(m, hbuf[:hn])
			}
		}
	}
}

cmd_zrange_all :: proc(m: ^Model, argv: [][]u8) {
	z, ok := lookup(m, argv[1])
	if !ok {
		return
	}
	if z == nil {
		w_array(m, 0)
		return
	}
	items := make([dynamic]zt.Item)
	defer delete(items)
	zt.rank_range(z, 0, -1, false, &items)
	w_array(m, len(items) * (1 if m.resp == 3 else 2))
	for &item in items {
		if m.resp == 3 {
			w_array(m, 2)
		}
		buf: [21]u8
		w_bulk(m, member_bytes(&item, &buf))
		w_double(m, item.score)
	}
}

execute :: proc(m: ^Model, argv: [][]u8) -> (compare: bool) {
	name := argv[0]
	switch {
	case eq_fold(name, "hello"):
		m.resp = 3 if string(argv[1]) == "3" else 2
		return false
	case eq_fold(name, "flushall"):
		model_flush(m)
		w_raw(m, "+OK\r\n")
	case eq_fold(name, "set"):
		model_put(m, argv[1], Key{kind = .String})
		w_raw(m, "+OK\r\n")
	case eq_fold(name, "hset"):
		model_put(m, argv[1], Key{kind = .Hash})
		w_int(m, 1)
	case eq_fold(name, "del"):
		w_int(m, 1 if model_drop_key(m, argv[1]) else 0)
	case eq_fold(name, "exists"):
		_, found := m.keys[string(argv[1])]
		w_int(m, 1 if found else 0)
	case eq_fold(name, "type"):
		k, found := m.keys[string(argv[1])]
		if !found {
			w_raw(m, "+none\r\n")
		} else {
			switch k.kind {
			case .String:
				w_raw(m, "+string\r\n")
			case .Hash:
				w_raw(m, "+hash\r\n")
			case .Zset:
				w_raw(m, "+zset\r\n")
			}
		}
	case eq_fold(name, "zcard"):
		z, ok := lookup(m, argv[1])
		if ok {
			w_int(m, 0 if z == nil else i64(zt.length(z)))
		}
	case eq_fold(name, "zadd"):
		scores := make([dynamic]f64)
		members := make([dynamic][]u8)
		defer delete(scores)
		defer delete(members)
		for i := 2; i + 1 < len(argv); i += 2 {
			v, _ := zt.parse_score(argv[i])
			append(&scores, v)
			append(&members, argv[i + 1])
		}
		zadd_like(m, argv[1], {}, false, scores[:], members[:])
	case eq_fold(name, "object"):
		z, ok := lookup(m, argv[2])
		if ok {
			if z == nil {
				w_null(m)
			} else {
				w_bulk(m, transmute([]u8)zt.encoding_name(z))
			}
		}
	case eq_fold(name, "zrange"):
		cmd_zrange_all(m, argv)
	case eq_fold(name, "geoadd"):
		cmd_geoadd(m, argv)
	case eq_fold(name, "geopos"):
		cmd_geopos(m, argv)
	case eq_fold(name, "geohash"):
		cmd_geohash(m, argv)
	case eq_fold(name, "geodist"):
		cmd_geodist(m, argv)
	case eq_fold(name, "georadius"):
		georadius_generic(m, argv, 1, {.Coords})
	case eq_fold(name, "georadius_ro"):
		georadius_generic(m, argv, 1, {.Coords, .No_Store})
	case eq_fold(name, "georadiusbymember"):
		georadius_generic(m, argv, 1, {.Member})
	case eq_fold(name, "georadiusbymember_ro"):
		georadius_generic(m, argv, 1, {.Member, .No_Store})
	case eq_fold(name, "geosearch"):
		georadius_generic(m, argv, 1, {.Search})
	case eq_fold(name, "geosearchstore"):
		georadius_generic(m, argv, 2, {.Search, .Search_Store})
	case:
		w_raw(m, "-ERR unknown\r\n")
	}
	return true
}

ARITY := [?]struct {
	name:  string,
	arity: int,
} {
	{"geoadd", -5},
	{"geodist", -4},
	{"geohash", -2},
	{"geopos", -2},
	{"georadius", -6},
	{"georadius_ro", -6},
	{"georadiusbymember", -5},
	{"georadiusbymember_ro", -5},
	{"geosearch", -7},
	{"geosearchstore", -8},
}

arity_ok :: proc(m: ^Model, argv: [][]u8) -> bool {
	for a in ARITY {
		if eq_fold(argv[0], a.name) {
			n := len(argv)
			if a.arity > 0 && n != a.arity || a.arity < 0 && n < -a.arity {
				w_raw(m, "-ERR wrong number of arguments for '")
				w_raw(m, a.name)
				w_raw(m, "' command\r\n")
				return false
			}
		}
	}
	return true
}

run_command :: proc(m: ^Model, argv: [][]u8) -> (compare: bool) {
	clear(&m.out)
	if !arity_ok(m, argv) {
		return true
	}
	return execute(m, argv)
}
