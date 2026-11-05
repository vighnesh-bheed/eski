package main

import ks "keyspace"
import zt "zsettype"
import geo "geo"

keyspace_geo_human :: proc "contextless" (task: ^Keyspace_Task, b: ^Keyspace_Builder, value: f64) {
	buf: [geo.HUMAN_MAX]u8
	n := geo.format_human(buf[:], value)
	if task.client.resp == RESP3 { keyspace_builder_text(b, ","); keyspace_builder_bytes(b, buf[:n]); keyspace_builder_text(b, "\r\n") } else { keyspace_builder_bulk(b, buf[:n]) }
}

keyspace_geo_distance :: proc "contextless" (b: ^Keyspace_Builder, value: f64) {
	buf: [geo.DISTANCE_MAX]u8
	n := geo.format_distance(buf[:], value)
	keyspace_builder_bulk(b, buf[:n])
}

keyspace_geo_execute :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	defer job.abort = task.failed
	argv := task.argv
	name := task.command_name
	if name == "geoadd" { keyspace_geo_add(task); return }
	conversion := 1.0
	if name == "geodist" {
		if len(argv) > 5 { task.failed = true; return }
		if len(argv) == 5 { known: bool; conversion, known = geo.unit_to_meters(argv[4]); if !known { task.failed = true; return } }
	}
	index := 2 if name == "geosearchstore" else 1
	r := keyspace_task_record(task, argv[index])
	if r == nil { task.failed = true; return }
	keyspace_expire(task, r)
	if r.exists && r.kind != u8(Obj_Type.Zset) { task.failed = true; return }
	keyspace_read(task, r)
	z := cast(zt.Zset)r.object
	b := keyspace_object_builder(task, .Zset, z, len(argv) * 128)
	defer ks.free(&keyspace_pool, b.bytes)
	if b.failed { return }
	if name == "geohash" || name == "geopos" {
		keyspace_builder_integer(&b, i64(len(argv) - 2), '*')
		for member in argv[2:] {
			if name == "geohash" {
				score: f64; found := false
				if z != nil { score, found = zt.score(z, member) }
				text: [11]u8
				if !found || !geo.geohash_string(score, &text) { keyspace_hash_null(task, &b) } else { keyspace_builder_bulk(&b, text[:]) }
			} else {
				xy: [2]f64; found := false
				if z != nil { xy, found = geo.member_xy(z, member) }
				if !found { keyspace_builder_text(&b, "_\r\n" if task.client.resp == RESP3 else "*-1\r\n") } else {
					keyspace_builder_integer(&b, 2, '*'); keyspace_geo_human(task, &b, xy[0]); keyspace_geo_human(task, &b, xy[1])
				}
			}
		}
		keyspace_builder_finish(task, &b); return
	}
	if name == "geodist" {
		if z == nil { task.null = true; return }
		a, x := geo.member_xy(z, argv[2]); c, y := geo.member_xy(z, argv[3])
		if !x || !y { task.null = true; return }
		keyspace_geo_distance(&b, geo.distance(a[0], a[1], c[0], c[1]) / conversion)
		keyspace_builder_finish(task, &b); return
	}
	flags: geo.Request_Flags
	switch name {
	case "georadius": flags = {.Coords}
	case "georadius_ro": flags = {.Coords, .No_Store}
	case "georadiusbymember": flags = {.Member}
	case "georadiusbymember_ro": flags = {.Member, .No_Store}
	case "geosearch": flags = {.Search}
	case "geosearchstore": flags = {.Search, .Search_Store}
	case: task.failed = true; return
	}
	request, err := geo.parse_request(argv, index, flags, z)
	if err != .None { task.failed = true; return }
	charge := keyspace_zset_length(z) * 4 * size_of(geo.Point) + 1024
	if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return }; defer ks.release_external(&keyspace_pool, charge)
	points := make([dynamic]geo.Point, 0, keyspace_zset_length(z)); defer delete(points)
	sorted := make([dynamic]geo.Point, 0, keyspace_zset_length(z)); defer delete(sorted)
	count := 0
	if z != nil { count = geo.run(z, &request, &points, &sorted) }
	if request.store {
		items := make([]zt.Item, count); defer delete(items)
		for point, i in points[:count] {
			items[i] = point.member
			items[i].score = point.dist / request.shape.conversion if request.store_dist else point.score
		}
		keyspace_zset_store_items(task, request.store_key, items, "geosearchstore" if task.command_name == "geosearchstore" else "georadiusstore")
		if !task.failed { task.dirty = max(task.dirty, i64(count)) }; return
	}
	keyspace_builder_integer(&b, i64(count), '*')
	extra := int(request.with_dist) + int(request.with_hash) + int(request.with_coord)
	for &point in points[:count] {
		if extra != 0 { keyspace_builder_integer(&b, i64(1 + extra), '*') }
		buf: [21]u8
		keyspace_builder_bulk(&b, zt.item_bytes(&point.member, &buf))
		if request.with_dist { keyspace_geo_distance(&b, point.dist / request.shape.conversion) }
		if request.with_hash { keyspace_builder_integer(&b, i64(geo.score_to_bits(point.score))) }
		if request.with_coord {
			keyspace_builder_integer(&b, 2, '*'); keyspace_geo_human(task, &b, point.longitude); keyspace_geo_human(task, &b, point.latitude)
		}
	}
	keyspace_builder_finish(task, &b)
}

keyspace_geo_add :: proc(task: ^Keyspace_Task) {
	argv := task.argv
	options, err := geo.parse_add(argv)
	if err != .None { task.failed = true; return }
	count := (len(argv) - options.first) / 3
	charge := count * size_of(f64)
	if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return }; defer ks.release_external(&keyspace_pool, charge)
	scores := make([]f64, count); defer delete(scores)
	for _, i in scores {
		xy, problem := geo.parse_long_lat(argv[options.first + i * 3], argv[options.first + i * 3 + 1])
		if problem != .None { task.failed = true; return }; scores[i] = geo.score_of(xy)
	}
	r := task.records[0]
	keyspace_expire(task, r)
	if r.exists && r.kind != u8(Obj_Type.Zset) { task.failed = true; return }
	keyspace_touch(task, r)
	if !r.exists && options.xx { return }
	work, ok := keyspace_object_work(task, r, .Zset)
	if !ok { return }; defer keyspace_object_discard(&work)
	if !r.exists { zt.destroy(cast(zt.Zset)work.object); work.object = zt.type_create(count, len(argv[options.first + 2])) }
	flags: zt.Zadd_Flags
	if options.nx { flags += {.Nx} }; if options.xx { flags += {.Xx} }
	added, updated := 0, 0
	for score, i in scores {
		out, _, valid := zt.add(cast(zt.Zset)work.object, score, argv[options.first + i * 3 + 2], flags)
		if !valid { task.failed = true; return }
		added += int(.Added in out); updated += int(.Updated in out)
	}
	task.integer = i64(added + updated if options.ch else added)
	if added + updated == 0 { return }
	if !keyspace_object_commit(task, r, &work) { return }; task.dirty = i64(added + updated)
	keyspace_changed(task, r, .Zset, "zadd")
	keyspace_wake(task, r, .Zset)
}
