package main

import geo "../../src/geo"
import zt "../../src/zsettype"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

human :: proc(v: f64) -> string {
	buf: [geo.HUMAN_MAX]u8
	n := geo.format_human(buf[:], v)
	return fmt.tprint(string(buf[:n]))
}

dist :: proc(v: f64) -> string {
	buf: [geo.DISTANCE_MAX]u8
	n := geo.format_distance(buf[:], v)
	return fmt.tprint(string(buf[:n]))
}

Place :: struct {
	lon, lat, name: string,
}

words :: proc(text: string) -> [][]u8 {
	parts := strings.split(text, "|", context.temp_allocator)
	out := make([][]u8, len(parts), context.temp_allocator)
	for p, i in parts {
		out[i] = transmute([]u8)p
	}
	return out
}

place_set :: proc(places: []Place) -> zt.Zset {
	z := zt.create_skiplist(len(places))
	for p in places {
		xy, err := geo.parse_long_lat(transmute([]u8)p.lon, transmute([]u8)p.lat)
		check(err == .None, fmt.tprintf("place %s has valid coordinates", p.name))
		zt.add(z, geo.score_of(xy), transmute([]u8)p.name, {})
	}
	return z
}

stored_xy :: proc(z: zt.Zset, name: string) -> [2]f64 {
	score, found := zt.score(z, transmute([]u8)name)
	check(found, fmt.tprintf("member %s is stored", name))
	xy, _ := geo.decode_score(score)
	return xy
}

query :: proc(z: zt.Zset, flags: geo.Request_Flags, command: string) -> string {
	argv := words(command)
	req, err := geo.parse_request(argv, 1, flags, z)
	if err != .None {
		return fmt.tprintf("error %v", err)
	}
	found := make([dynamic]geo.Point, context.temp_allocator)
	scratch := make([dynamic]geo.Point, context.temp_allocator)
	n := geo.run(z, &req, &found, &scratch)
	b := strings.builder_make(context.temp_allocator)
	for &p, i in found[:n] {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		buf: [21]u8
		strings.write_string(&b, string(zt.item_bytes(&p.member, &buf)))
		if req.with_dist {
			strings.write_string(&b, " ")
			strings.write_string(&b, dist(p.dist / req.shape.conversion))
		}
		if req.with_coord {
			fmt.sbprintf(&b, " (%s %s)", human(p.longitude), human(p.latitude))
		}
	}
	return strings.to_string(b)
}

expect_query :: proc(z: zt.Zset, flags: geo.Request_Flags, command, want: string) {
	got := query(z, flags, command)
	check(got == want, fmt.tprintf("%s\n    want %s\n    got  %s", command, want, got))
}

geodist :: proc(z: zt.Zset, a, b, unit: string) -> string {
	pa := stored_xy(z, a)
	pb := stored_xy(z, b)
	factor, ok := geo.unit_to_meters(transmute([]u8)unit)
	check(ok, fmt.tprintf("unit %s", unit))
	return dist(geo.distance(pa[0], pa[1], pb[0], pb[1]) / factor)
}

unit_documented_sicily :: proc() {
	sicily := [?]Place{{"13.361389", "38.115556", "Palermo"}, {"15.087269", "37.502669", "Catania"}}
	z := place_set(sicily[:])
	defer zt.destroy(z)
	cases := [?][2]string{{"m", "166274.1516"}, {"km", "166.2742"}, {"mi", "103.3182"}, {"ft", "545518.8700"}}
	for c in cases {
		got := geodist(z, "Palermo", "Catania", c[0])
		check(got == c[1], fmt.tprintf("GEODIST Palermo Catania %s is %s, got %s", c[0], c[1], got))
	}
	check(geodist(z, "Palermo", "Palermo", "m") == "0.0000", "GEODIST of a member to itself")
	positions := [?][3]string{{"Palermo", "13.36138933897018433", "38.11555639549629859"}, {"Catania", "15.08726745843887329", "37.50266842333162032"}}
	for p in positions {
		xy := stored_xy(z, p[0])
		check(human(xy[0]) == p[1] && human(xy[1]) == p[2], fmt.tprintf("GEOPOS %s is %s %s, got %s %s", p[0], p[1], p[2], human(xy[0]), human(xy[1])))
	}
	hashes := [?][2]string{{"Palermo", "sqc8b49rny0"}, {"Catania", "sqdtr74hyu0"}}
	for h in hashes {
		score, _ := zt.score(z, transmute([]u8)h[0])
		text: [11]u8
		check(geo.geohash_string(score, &text) && string(text[:]) == h[1], fmt.tprintf("GEOHASH %s is %s, got %s", h[0], h[1], string(text[:])))
	}
	scores := [?]struct {
		name:  string,
		score: u64,
	}{{"Palermo", 3479099956230698}, {"Catania", 3479447370796909}}
	for s in scores {
		score, _ := zt.score(z, transmute([]u8)s.name)
		check(u64(score) == s.score, fmt.tprintf("ZSCORE %s is %d, got %.0f", s.name, s.score, score))
	}
	expect_query(z, {.Coords}, "GEORADIUS|Sicily|15|37|200|km|WITHDIST|ASC", "Catania 56.4413, Palermo 190.4424")
	expect_query(z, {.Coords}, "GEORADIUS|Sicily|15|37|200|km|WITHCOORD|ASC", "Catania (15.08726745843887329 37.50266842333162032), Palermo (13.36138933897018433 38.11555639549629859)")
	expect_query(z, {.Coords}, "GEORADIUS|Sicily|15|37|100|km", "Catania")
	edges := [?]Place{{"12.758489", "38.788135", "edge1"}, {"17.241510", "38.788135", "edge2"}}
	for e in edges {
		xy, _ := geo.parse_long_lat(transmute([]u8)e.lon, transmute([]u8)e.lat)
		zt.add(z, geo.score_of(xy), transmute([]u8)e.name, {})
	}
	expect_query(z, {.Search}, "GEOSEARCH|Sicily|FROMLONLAT|15|37|BYBOX|400|400|km|ASC|WITHCOORD|WITHDIST", "Catania 56.4413 (15.08726745843887329 37.50266842333162032), Palermo 190.4424 (13.36138933897018433 38.11555639549629859), edge2 279.7403 (17.24151045083999634 38.78813451624225195), edge1 279.7405 (12.7584877610206604 38.78813451624225195)")
	expect_query(z, {.Search}, "GEOSEARCH|Sicily|FROMLONLAT|15|37|BYRADIUS|200|km|ASC", "Catania, Palermo")
}

unit_suite_new_york :: proc() {
	nyc := [?]Place {
		{"-73.9454966", "40.747533", "lic market"},
		{"-73.9733487", "40.7648057", "central park n/q/r"},
		{"-73.9903085", "40.7362513", "union square"},
		{"-74.0131604", "40.7126674", "wtc one"},
		{"-73.7858139", "40.6428986", "jfk"},
		{"-73.9375699", "40.7498929", "q4"},
		{"-73.9564142", "40.7480973", "4545"},
	}
	z := place_set(nyc[:])
	defer zt.destroy(z)
	published := [?]struct {
		name:  string,
		score: u64,
	} {
		{"wtc one", 1791873972053020},
		{"union square", 1791875485187452},
		{"central park n/q/r", 1791875761332224},
		{"4545", 1791875796750882},
		{"lic market", 1791875804419201},
		{"q4", 1791875830079666},
		{"jfk", 1791895905559723},
	}
	for p in published {
		score, _ := zt.score(z, transmute([]u8)p.name)
		check(u64(score) == p.score, fmt.tprintf("geoset score of %s is %d, got %.0f", p.name, p.score, score))
	}
	expect_query(z, {.Coords}, "GEORADIUS|nyc|-73.9798091|40.7598464|3|km|asc", "central park n/q/r, 4545, union square")
	expect_query(z, {.Coords}, "GEORADIUS|nyc|-73.9798091|40.7598464|3|km|withdist|asc", "central park n/q/r 0.7750, 4545 2.3651, union square 2.7697")
	expect_query(z, {.Coords}, "GEORADIUS|nyc|-73.9798091|40.7598464|10|km|COUNT|2|DESC", "wtc one, q4")
	expect_query(z, {.Member}, "GEORADIUSBYMEMBER|nyc|wtc one|7|km", "wtc one, union square, central park n/q/r, 4545, lic market")
	expect_query(z, {.Member}, "GEORADIUSBYMEMBER|nyc|wtc one|7|km|withdist", "wtc one 0.0000, union square 3.2544, central park n/q/r 6.7000, 4545 6.1975, lic market 6.8969")
	expect_query(z, {.Search}, "GEOSEARCH|nyc|frommember|wtc one|bybox|14|14|km", "wtc one, union square, central park n/q/r, 4545, lic market, q4")
}

unit_suite_edges :: proc() {
	Edge_Case :: struct {
		places:  []Place,
		flags:   geo.Request_Flags,
		command: string,
		want:    string,
		sorted:  bool,
	}
	cases := [?]Edge_Case {
		{{{"-122.407107", "37.794300", "1"}, {"-122.227336", "37.794300", "2"}}, {.Coords}, "GEORADIUS|points|-122.407107|37.794300|30|mi|ASC|WITHDIST", "1 0.0001, 2 9.8182", false},
		{{{"179.5", "36", "point1"}, {"-179.5", "36", "point2"}}, {.Search}, "GEOSEARCH|points|fromlonlat|179|37|bybox|400|400|km|asc", "point1, point2", false},
		{{{"179.5", "36", "point1"}, {"-179.5", "36", "point2"}}, {.Search}, "GEOSEARCH|points|fromlonlat|-179|37|bybox|400|400|km|asc", "point2, point1", false},
		{{{"-47.271613776683807", "-54.534504198047678", "user_000000"}}, {.Coords}, "GEORADIUS|users|0|0|50000|km|WITHCOORD", "user_000000 (-47.27161377668380737 -54.5345041980476779)", false},
		{{{"-0.15307903289794921875", "85", "n1"}, {"0.3515625", "85.00019260486917005437", "n2"}}, {.Member}, "GEORADIUSBYMEMBER|k1|n1|4891.94|m", "n1, n2", false},
		{{{"-4.95211958885192871094", "85", "n3"}, {"11.25", "85.0511", "n4"}}, {.Member}, "GEORADIUSBYMEMBER|k1|n3|156544|m", "n3, n4", false},
		{{{"-45", "65.50900022111811438208", "n5"}, {"90", "85.0511", "n6"}}, {.Member}, "GEORADIUSBYMEMBER|k1|n5|5009431|m", "n5, n6", false},
		{{{"45", "65", "n1"}, {"-135", "85.05", "n2"}}, {.Member}, "GEORADIUSBYMEMBER|k1|n1|5009431|m", "n1, n2", false},
		{{{"12.75", "36.995", "test1"}, {"12.75", "36.50", "test2"}, {"13.00", "36.50", "test3"}}, {.Search}, "GEOSEARCH|Sicily|fromlonlat|15|37|bybox|400|2|km", "test1", false},
		{{{"12.75", "36.995", "test1"}, {"12.75", "36.50", "test2"}, {"-1", "37.00", "test3"}}, {.Search}, "GEOSEARCH|Sicily|fromlonlat|15|37|bybox|3000|2|km|asc", "test1, test3", false},
		{{{"12.758489", "38.788135", "edge1"}, {"17.241510", "38.788135", "edge2"}, {"17.250000", "35.202000", "edge3"}, {"12.750000", "35.202000", "edge4"}, {"12.748489955781654", "37", "edge5"}, {"15", "38.798135872540925", "edge6"}, {"17.251510044218346", "37", "edge7"}, {"15", "35.201864127459075", "edge8"}, {"12.692799634687903", "38.798135872540925", "corner1"}, {"12.692799634687903", "38.798135872540925", "corner2"}, {"17.200560937451133", "35.201864127459075", "corner3"}, {"12.799439062548865", "35.201864127459075", "corner4"}}, {.Search}, "GEOSEARCH|Sicily|fromlonlat|15|37|bybox|400|400|km|asc", "edge1, edge2, edge5, edge7", true},
	}
	for c in cases {
		z := place_set(c.places)
		got := query(z, c.flags, c.command)
		if c.sorted {
			names := strings.split(got, ", ", context.temp_allocator)
			slice.sort(names)
			got = strings.join(names, ", ", context.temp_allocator)
		}
		check(got == c.want, fmt.tprintf("%s\n    want %s\n    got  %s", c.command, c.want, got))
		zt.destroy(z)
	}
	pairs := [?]struct {
		lon, lat, text: string,
	} {
		{"200", "100", "ERR invalid longitude,latitude pair 200.000000,100.000000"},
		{"-180.0000001", "0", "ERR invalid longitude,latitude pair -180.000000,0.000000"},
		{"0", "85.05112879", "ERR invalid longitude,latitude pair 0.000000,85.051129"},
		{"1e20", "0", "ERR invalid longitude,latitude pair 100000000000000000000.000000,0.000000"},
		{"0.5000005", "-90", "ERR invalid longitude,latitude pair 0.500000,-90.000000"},
		{"1.0000015", "95", "ERR invalid longitude,latitude pair 1.000001,95.000000"},
		{"2.5", "-85.0511288", "ERR invalid longitude,latitude pair 2.500000,-85.051129"},
		{"-1e-7", "86", "ERR invalid longitude,latitude pair -0.000000,86.000000"},
	}
	for p in pairs {
		xy, err := geo.parse_long_lat(transmute([]u8)p.lon, transmute([]u8)p.lat)
		buf: [geo.ERROR_TEXT_MAX]u8
		text := string(geo.error_text(buf[:], err, xy, nil))
		check(err == .Invalid_Pair && text == p.text, fmt.tprintf("GEOADD %s %s reports %s, got %s", p.lon, p.lat, p.text, text))
	}
	wiki, _ := geo.parse_long_lat(transmute([]u8)string("-5.6"), transmute([]u8)string("42.6"))
	text: [11]u8
	check(geo.geohash_string(geo.score_of(wiki), &text) && string(text[:]) == "ezs42e44yx0", "geohash of the Wikipedia example")
}

suite_distance :: proc(lon1, lat1, lon2, lat2: f64) -> f64 {
	rad :: math.PI / 180
	v := math.sin((lon2 - lon1) * rad / 2)
	u := math.sin((lat2 - lat1) * rad / 2)
	return 2.0 * 6372797.560856 * math.asin(math.sqrt(u * u + math.cos(lat1 * rad) * math.cos(lat2 * rad) * v * v))
}

unit_suite_fuzz :: proc() {
	regression := [?][3]f64 {
		{7083, 81.634948934258375, 30.561509253718668},
		{5416, -70.863281847379767, -46.347003465679947},
		{6064, -89.818768962202014, -40.463868561416803},
		{156, 149.29737817929004, 15.95807862745508},
		{143, 59.235461856813856, 66.269555127373678},
		{187, -101.88575239939883, 49.061997951502917},
		{154, -90.187939661642517, 66.615930412251487},
		{145, 163.03472387745728, 64.012747720821181},
		{143, 137.86663517256579, 63.986745399416776},
		{151, 59.149620271823181, 65.204186651485145},
		{149, 84.062063109158544, -65.685403922426232},
		{16751, -1.8175081637769495, 20.665668878082954},
	}
	rng := Rng{20261101}
	mismatched, returned, expected := 0, 0, 0
	for v, round in regression {
		z := zt.create_skiplist(20000)
		lons := make([]f64, 20000, context.temp_allocator)
		lats := make([]f64, 20000, context.temp_allocator)
		for j in 0 ..< 20000 {
			lons[j] = -180 + rng_float(&rng) * 360
			lats[j] = -70 + rng_float(&rng) * 140
			zt.add(z, geo.score_of({lons[j], lats[j]}), transmute([]u8)fmt.tprintf("place:%d", j), {})
		}
		for shape in ([]string{"byradius", "bybox"}) {
			command := fmt.tprintf("GEOSEARCH|mypoints|fromlonlat|%.17g|%.17g|byradius|%.0f|km", v[1], v[2], v[0]) if shape == "byradius" else fmt.tprintf("GEOSEARCH|mypoints|fromlonlat|%.17g|%.17g|bybox|%.0f|%.0f|km", v[1], v[2], v[0], v[0])
			got := make(map[string]bool, 64, context.temp_allocator)
			listed := query(z, {.Search}, command)
			if len(listed) > 0 {
				for name in strings.split(listed, ", ", context.temp_allocator) {
					got[name] = true
				}
			}
			returned += len(got)
			half := v[0] * 1000 / 2
			for j in 0 ..< 20000 {
				name := fmt.tprintf("place:%d", j)
				inside: bool
				if shape == "byradius" {
					inside = suite_distance(lons[j], lats[j], v[1], v[2]) < v[0] * 1000
				} else {
					inside = suite_distance(lons[j], lats[j], v[1], lats[j]) <= half && suite_distance(lons[j], lats[j], lons[j], v[2]) <= half
				}
				if inside {
					expected += 1
				}
				if inside == (name in got) {
					continue
				}
				xy := stored_xy(z, name)
				rounding := false
				if shape == "byradius" {
					d := suite_distance(xy[0], xy[1], v[1], v[2])
					rounding = d / (v[0] * 1000) > 0.999 || d < v[0] * 1000
				} else {
					wide := half * 1.001
					rounding = suite_distance(xy[0], xy[1], v[1], xy[1]) <= wide && suite_distance(xy[0], xy[1], xy[0], v[2]) <= wide
				}
				if !rounding {
					mismatched += 1
					check(false, fmt.tprintf("regression vector %d %s misses or adds %s", round, shape, name))
				}
			}
		}
		zt.destroy(z)
		free_all(context.temp_allocator)
	}
	check(mismatched == 0 && returned > 10000, fmt.tprintf("suite regression vectors agree with brute force, %d real mismatches", mismatched))
	fmt.printfln("    regression searches returned %d places, brute force expected %d", returned, expected)
}

unit_radius_steps :: proc() {
	check(geo.estimate_steps_by_radius(0, 0) == geo.STEP_MAX, "a zero radius uses the finest cells")
	check(geo.estimate_steps_by_radius(5e7, 0) == 1, "a radius beyond the planet uses the coarsest cells")
	latitudes := [?]f64{0, 30, -45, 66, 66.5, -70, 80, 80.5, -85}
	previous := [len(latitudes)]u8{}
	for i in 0 ..< len(previous) {
		previous[i] = geo.STEP_MAX
	}
	monotonic, bounded, polar_coarser := true, true, true
	for radius := 0.5; radius < 4e7; radius *= 1.37 {
		equator := geo.estimate_steps_by_radius(radius, 0)
		for lat, i in latitudes {
			step := geo.estimate_steps_by_radius(radius, lat)
			bounded = bounded && step >= 1 && step <= geo.STEP_MAX
			monotonic = monotonic && step <= previous[i]
			previous[i] = step
			if abs(lat) > 66 {
				polar_coarser = polar_coarser && step <= equator
			}
			if abs(lat) > 80 {
				polar_coarser = polar_coarser && step <= geo.estimate_steps_by_radius(radius, 70)
			}
		}
	}
	check(bounded, "estimated steps stay within the geohash range")
	check(monotonic, "a larger radius never selects finer cells")
	check(polar_coarser, "polar latitudes never select finer cells than lower latitudes")
}

unit_interleave :: proc() {
	rng := Rng{77}
	ok := true
	for _ in 0 ..< 50000 {
		r := rng_next(&rng)
		x, y := u32(r), u32(r >> 32)
		v := geo.interleave64(x, y)
		back := geo.deinterleave64(v)
		ok = ok && u32(back) == x && u32(back >> 32) == y
	}
	check(ok, "interleaving coordinates bit by bit round trips")
	check(geo.interleave64(1, 0) == 1 && geo.interleave64(0, 1) == 2 && geo.interleave64(max(u32), 0) == 0x5555555555555555, "interleave puts longitude bits in even positions")
}

run_unit :: proc() -> bool {
	steps := [?]struct {
		name: string,
		fn:   proc(),
	} {
		{"interleave", unit_interleave},
		{"documented sicily examples", unit_documented_sicily},
		{"suite new york vectors", unit_suite_new_york},
		{"suite edge vectors", unit_suite_edges},
		{"radius step estimation", unit_radius_steps},
		{"suite regression vectors", unit_suite_fuzz},
	}
	for s in steps {
		before := checks
		s.fn()
		fmt.printfln("  %-28s %d checks", s.name, checks - before)
		free_all(context.temp_allocator)
	}
	fmt.printfln("geo unit: %d checks, %d failures", checks, failures)
	return failures == 0
}
