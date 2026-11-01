package main

import geo "geo"
import zt "zsettype"

@(private = "file")
GEO_SCRATCH_KEEP :: 65536

@(private = "file")
GEO_SCORE_TEXT :: 24

@(private = "file")
geo_points: [dynamic]geo.Point

@(private = "file")
geo_sorted: [dynamic]geo.Point

@(private = "file")
geo_argv: [dynamic][]u8

@(private = "file")
geo_scores: [dynamic]u8

@(private = "file")
geo_error :: proc(c: ^Conn, err: geo.Error, pair: [2]f64, name: []u8) {
	buf: [geo.ERROR_TEXT_MAX]u8
	reply_error_bytes(c, geo.error_text(buf[:], err, pair, name))
}

@(private = "file")
geo_lookup :: proc(c: ^Conn, key: []u8) -> (z: zt.Zset, ok: bool) {
	_, found, wrong := zset_lookup(key, true)
	if wrong {
		reply_wrongtype(c)
		return nil, false
	}
	return found, true
}

@(private = "file")
geo_reply_human :: proc(c: ^Conn, v: f64) {
	buf: [geo.HUMAN_MAX]u8
	n := geo.format_human(buf[:], v)
	reply_double_text(c, buf[:n])
}

@(private = "file")
geo_reply_distance :: proc(c: ^Conn, meters: f64, conversion: f64) {
	buf: [geo.DISTANCE_MAX]u8
	n := geo.format_distance(buf[:], meters / conversion)
	reply_bulk(c, buf[:n])
}

@(private = "file")
geo_trim :: proc() {
	clear(&geo_points)
	clear(&geo_sorted)
	clear(&geo_argv)
	clear(&geo_scores)
	if cap(geo_points) > GEO_SCRATCH_KEEP {
		delete(geo_points)
		geo_points = nil
	}
	if cap(geo_sorted) > GEO_SCRATCH_KEEP {
		delete(geo_sorted)
		geo_sorted = nil
	}
	if cap(geo_argv) > GEO_SCRATCH_KEEP {
		delete(geo_argv)
		geo_argv = nil
	}
	if cap(geo_scores) > GEO_SCRATCH_KEEP * GEO_SCORE_TEXT {
		delete(geo_scores)
		geo_scores = nil
	}
}

@(private = "file")
geo_append_score :: proc(score: f64) -> []u8 {
	digits: [GEO_SCORE_TEXT]u8
	n := format_i64(raw_data(digits[:]), i64(score))
	start := len(geo_scores)
	append(&geo_scores, ..digits[:n])
	return geo_scores[start:start + n]
}

cmd_geoadd :: proc(c: ^Conn, argv: [][]u8) {
	o, err := geo.parse_add(argv)
	if err != .None {
		geo_error(c, err, {}, argv[0])
		return
	}
	defer geo_trim()
	triples := (len(argv) - o.first) / 3
	clear(&geo_scores)
	reserve(&geo_scores, triples * GEO_SCORE_TEXT)
	clear(&geo_argv)
	reserve(&geo_argv, o.first + triples * 2)
	append(&geo_argv, transmute([]u8)string("zadd"))
	append(&geo_argv, ..argv[1:o.first])
	for i := o.first; i < len(argv); i += 3 {
		xy, perr := geo.parse_long_lat(argv[i], argv[i + 1])
		if perr != .None {
			geo_error(c, perr, xy, argv[0])
			return
		}
		append(&geo_argv, geo_append_score(geo.score_of(xy)))
		append(&geo_argv, argv[i + 2])
	}
	cmd_zadd(c, geo_argv[:])
}

@(private = "file")
geo_store :: proc(key: []u8, points: []geo.Point, req: ^geo.Request, event: string) {
	dst := zset_new_skiplist(len(points))
	maxlen, totlen := 0, 0
	for &p in points {
		buf: [21]u8
		member := zt.item_bytes(&p.member, &buf)
		maxlen = max(maxlen, len(member))
		totlen += len(member)
		score := p.dist / req.shape.conversion if req.store_dist else p.score
		_, _, _ = zt.add(dst, score, member, {})
	}
	zt.convert_to_listpack_if_needed(dst, maxlen, totlen)
	zset_store_result(cur_db(), key, dst, event)
	if len(points) > 0 { pst.dirty += i64(len(points) - 1) }
}

@(private = "file")
geo_reply_points :: proc(c: ^Conn, points: []geo.Point, req: ^geo.Request) {
	reply_array(c, len(points))
	extra := int(req.with_dist) + int(req.with_hash) + int(req.with_coord)
	for &p in points {
		buf: [21]u8
		member := zt.item_bytes(&p.member, &buf)
		if extra == 0 {
			reply_bulk(c, member)
			continue
		}
		reply_array(c, 1 + extra)
		reply_bulk(c, member)
		if req.with_dist {
			geo_reply_distance(c, p.dist, req.shape.conversion)
		}
		if req.with_hash {
			reply_int(c, i64(geo.score_to_bits(p.score)))
		}
		if req.with_coord {
			reply_array(c, 2)
			geo_reply_human(c, p.longitude)
			geo_reply_human(c, p.latitude)
		}
	}
}

@(private = "file")
georadius_generic :: proc(c: ^Conn, argv: [][]u8, src_index: int, flags: geo.Request_Flags) {
	pst.dirty_explicit = true
	z, ok := geo_lookup(c, argv[src_index])
	if !ok {
		return
	}
	req, err := geo.parse_request(argv, src_index, flags, z)
	if err != .None {
		geo_error(c, err, req.pair, argv[0])
		return
	}
	if z == nil {
		if req.store {
			zset_store_delete(req.store_key)
			reply_int(c, 0)
		} else {
			reply_array(c, 0)
		}
		return
	}
	defer geo_trim()
	clear(&geo_points)
	n := geo.run(z, &req, &geo_points, &geo_sorted)
	points := geo_points[:n]
	if req.store {
		geo_store(req.store_key, points, &req, "geosearchstore" if .Search_Store in flags else "georadiusstore")
		reply_int(c, i64(n))
		return
	}
	geo_reply_points(c, points, &req)
}

cmd_georadius :: proc(c: ^Conn, argv: [][]u8) {
	georadius_generic(c, argv, 1, {.Coords})
}

cmd_georadiusbymember :: proc(c: ^Conn, argv: [][]u8) {
	georadius_generic(c, argv, 1, {.Member})
}

cmd_georadius_ro :: proc(c: ^Conn, argv: [][]u8) {
	georadius_generic(c, argv, 1, {.Coords, .No_Store})
}

cmd_georadiusbymember_ro :: proc(c: ^Conn, argv: [][]u8) {
	georadius_generic(c, argv, 1, {.Member, .No_Store})
}

cmd_geosearch :: proc(c: ^Conn, argv: [][]u8) {
	georadius_generic(c, argv, 1, {.Search})
}

cmd_geosearchstore :: proc(c: ^Conn, argv: [][]u8) {
	georadius_generic(c, argv, 2, {.Search, .Search_Store})
}

cmd_geohash :: proc(c: ^Conn, argv: [][]u8) {
	z, ok := geo_lookup(c, argv[1])
	if !ok {
		return
	}
	reply_array(c, len(argv) - 2)
	for member in argv[2:] {
		score, found := 0.0, false
		if z != nil {
			score, found = zt.score(z, member)
		}
		text: [11]u8
		if !found || !geo.geohash_string(score, &text) {
			reply_null(c)
			continue
		}
		reply_bulk(c, text[:])
	}
}

cmd_geopos :: proc(c: ^Conn, argv: [][]u8) {
	z, ok := geo_lookup(c, argv[1])
	if !ok {
		return
	}
	reply_array(c, len(argv) - 2)
	for member in argv[2:] {
		xy, found := [2]f64{}, false
		if z != nil {
			xy, found = geo.member_xy(z, member)
		}
		if !found {
			reply_null_array(c)
			continue
		}
		reply_array(c, 2)
		geo_reply_human(c, xy[0])
		geo_reply_human(c, xy[1])
	}
}

cmd_geodist :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) > 5 {
		geo_error(c, .Syntax, {}, argv[0])
		return
	}
	conversion := 1.0
	if len(argv) == 5 {
		known: bool
		conversion, known = geo.unit_to_meters(argv[4])
		if !known {
			geo_error(c, .Unit, {}, argv[0])
			return
		}
	}
	z, ok := geo_lookup(c, argv[1])
	if !ok {
		return
	}
	if z == nil {
		reply_null(c)
		return
	}
	a, afound := geo.member_xy(z, argv[2])
	b, bfound := geo.member_xy(z, argv[3])
	if !afound || !bfound {
		reply_null(c)
		return
	}
	geo_reply_distance(c, geo.distance(a[0], a[1], b[0], b[1]), conversion)
}

@(private = "file")
geo_commands := [?]Command {
	{"geoadd", cmd_geoadd, -5},
	{"geodist", cmd_geodist, -4},
	{"geohash", cmd_geohash, -2},
	{"geopos", cmd_geopos, -2},
	{"georadius", cmd_georadius, -6},
	{"georadius_ro", cmd_georadius_ro, -6},
	{"georadiusbymember", cmd_georadiusbymember, -5},
	{"georadiusbymember_ro", cmd_georadiusbymember_ro, -5},
	{"geosearch", cmd_geosearch, -7},
	{"geosearchstore", cmd_geosearchstore, -8},
}

@(init)
register_geo_commands :: proc "contextless" () {
	register_commands(geo_commands[:])
}
