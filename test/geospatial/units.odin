package geospatial

import "core:math"
import "core:testing"
import geo "../../src/geo"
import zt "../../src/zsettype"

BIG_1E300 :: "1000000000000000052504760255204420248704468581108159154915854115511802457988908195786371375080447864043704443832883878176942523235360430575644792184786706982848387200926575803737830233794788090059368953234970799945081119038967640880074652742780142494579258788820056842838115669472196386865459400540160"

human_text :: proc(buf: []u8, v: f64) -> string {
	return string(buf[:geo.format_human(buf, v)])
}

f6_text :: proc(buf: []u8, v: f64) -> string {
	return string(buf[:geo.format_f6(buf, v)])
}

distance_text :: proc(buf: []u8, v: f64) -> string {
	return string(buf[:geo.format_distance(buf, v)])
}

parse_coord :: proc(s: string) -> f64 {
	v, ok := zt.parse_score(transmute([]u8)s)
	assert(ok)
	return v
}

@(test)
scores_match_dataset_rows :: proc(t: ^testing.T) {
	testing.expect(t, len(SCORE_ROWS) > 100)
	for row in SCORE_ROWS {
		xy, err := geo.parse_long_lat(transmute([]u8)row.lon, transmute([]u8)row.lat)
		testing.expect_value(t, err, geo.Error.None)
		testing.expect_value(t, u64(geo.score_of(xy)), row.score)
		hash, ok := geo.encode_wgs84(xy[0], xy[1], geo.STEP_MAX)
		testing.expect(t, ok)
		testing.expect_value(t, geo.align52(hash), row.score)
	}
}

@(test)
positions_match_dataset_rows :: proc(t: ^testing.T) {
	testing.expect(t, len(DECODE_ROWS) > 100)
	for row in DECODE_ROWS {
		xy, ok := geo.decode_score(row.score)
		testing.expect(t, ok)
		a, b: [geo.HUMAN_MAX]u8
		testing.expect_value(t, human_text(a[:], xy[0]), row.lon)
		testing.expect_value(t, human_text(b[:], xy[1]), row.lat)
	}
}

@(test)
geohash_strings_match_dataset_rows :: proc(t: ^testing.T) {
	testing.expect(t, len(HASH_ROWS) > 100)
	for row in HASH_ROWS {
		text: [11]u8
		testing.expect(t, geo.geohash_string(row.score, &text))
		testing.expect_value(t, string(text[:]), row.text)
	}
	text: [11]u8
	xy := [2]f64{-5.6, 42.6}
	testing.expect(t, geo.geohash_string(geo.score_of(xy), &text))
	testing.expect_value(t, string(text[:]), "ezs42e44yx0")
}

@(test)
distances_match_dataset_rows :: proc(t: ^testing.T) {
	testing.expect(t, len(DIST_ROWS) > 100)
	for row in DIST_ROWS {
		a, aok := geo.decode_score(row.first)
		b, bok := geo.decode_score(row.second)
		testing.expect(t, aok && bok)
		conversion, known := geo.unit_to_meters(transmute([]u8)row.unit)
		testing.expect(t, known)
		buf: [geo.DISTANCE_MAX]u8
		testing.expect_value(t, distance_text(buf[:], geo.distance(a[0], a[1], b[0], b[1]) / conversion), row.text)
	}
}

@(test)
stored_distances_match_dataset_bits :: proc(t: ^testing.T) {
	testing.expect(t, len(STOREDIST_ROWS) > 100)
	for row in STOREDIST_ROWS {
		xy, ok := geo.decode_score(row.score)
		testing.expect(t, ok)
		d := geo.distance(row.lon, row.lat, xy[0], xy[1]) / row.conversion
		testing.expect_value(t, transmute(u64)d, transmute(u64)row.stored)
	}
}

@(test)
step_estimates_match_dataset_searches :: proc(t: ^testing.T) {
	for row in STEP_ROWS {
		testing.expect_value(t, geo.estimate_steps_by_radius(row.meters, row.lat), row.step)
	}
	Case :: struct {
		meters: f64,
		lat:    f64,
		step:   u8,
	}
	cases := [?]Case {
		{0, 0, 26},
		{1e-9, 0, 26},
		{1, 0, 24},
		{100, 0, 17},
		{1000, 0, 14},
		{100000, 0, 7},
		{5000000, 0, 2},
		{20000000, 0, 1},
		{math.inf_f64(1), 0, 1},
		{1000, 66, 14},
		{1000, 66.1, 13},
		{1000, -70, 13},
		{1000, 80, 13},
		{1000, 80.5, 12},
		{1000, -85, 12},
		{-1, 0, 26},
		{5e-324, 0, 26},
		{math.nan_f64(), 0, 1},
	}
	for c in cases {
		testing.expect_value(t, geo.estimate_steps_by_radius(c.meters, c.lat), c.step)
	}
	testing.expect_value(t, geo.STEP_MAX, 26)
	testing.expect_value(t, geo.EARTH_RADIUS_IN_METERS, 6372797.560856)
	testing.expect_value(t, geo.MERCATOR_MAX, 20037726.37)
}

@(test)
interleave_places_latitude_on_even_bits :: proc(t: ^testing.T) {
	testing.expect_value(t, geo.interleave64(1, 0), 1)
	testing.expect_value(t, geo.interleave64(0, 1), 2)
	testing.expect_value(t, geo.interleave64(max(u32), 0), 0x5555555555555555)
	testing.expect_value(t, geo.interleave64(0, max(u32)), 0xAAAAAAAAAAAAAAAA)
	state: u64 = 0x9E3779B97F4A7C15
	for _ in 0 ..< 2000 {
		state ~= state << 13
		state ~= state >> 7
		state ~= state << 17
		x, y := u32(state), u32(state >> 32)
		z := geo.interleave64(x, y)
		testing.expect_value(t, geo.deinterleave64(z), u64(x) | u64(y) << 32)
		testing.expect_value(t, geo.interleave64(u32(geo.deinterleave64(z)), u32(geo.deinterleave64(z) >> 32)), z)
	}
}

@(test)
encode_decode_range_edges :: proc(t: ^testing.T) {
	low, ok := geo.encode_wgs84(-180, -85.05112878, 26)
	testing.expect(t, ok)
	testing.expect_value(t, low.bits, 0)
	high: geo.Hash_Bits
	high, ok = geo.encode_wgs84(180, 85.05112878, 26)
	testing.expect(t, ok)
	testing.expect_value(t, high.bits, u64(3) << 52)
	east: geo.Hash_Bits
	east, ok = geo.encode_wgs84(180, 0, 26)
	testing.expect(t, ok)
	testing.expect_value(t, east.bits, 10133099161583616)
	origin: geo.Hash_Bits
	origin, ok = geo.encode_wgs84(0, 0, 26)
	testing.expect(t, ok)
	testing.expect_value(t, origin.bits, 3377699720527872)
	_, ok = geo.encode_wgs84(180.0000001, 0, 26)
	testing.expect(t, !ok)
	_, ok = geo.encode_wgs84(0, -85.06, 26)
	testing.expect(t, !ok)
	_, ok = geo.encode_wgs84(math.nan_f64(), 0, 26)
	testing.expect(t, !ok)
	_, ok = geo.encode_wgs84(0, 0, 0)
	testing.expect(t, !ok)
	_, ok = geo.encode_wgs84(0, 0, 33)
	testing.expect(t, !ok)
	xy: [2]f64
	xy, ok = geo.decode_to_long_lat_wgs84(high)
	testing.expect(t, ok)
	testing.expect_value(t, xy, [2]f64{180, 85.05112878})
	_, ok = geo.decode_wgs84(geo.Hash_Bits{})
	testing.expect(t, !ok)
	edges := [?]f64{-180, -179.9999999, -90, -1e-12, 0, 1e-12, 45, 90, 179.9999999}
	lats := [?]f64{-85.05112878, -85.05, -45, -1e-12, 0, 1e-12, 45, 85.05, 85.0511287}
	for step in ([?]u8{1, 2, 13, 25, 26}) {
		for lon in edges {
			for lat in lats {
				hash, good := geo.encode_wgs84(lon, lat, step)
				testing.expect(t, good)
				area, decoded := geo.decode_wgs84(hash)
				testing.expect(t, decoded)
				testing.expect(t, area.longitude.min <= lon && lon <= area.longitude.max)
				testing.expect(t, area.latitude.min <= lat && lat <= area.latitude.max)
				again, _ := geo.encode_wgs84((area.longitude.min + area.longitude.max) / 2, (area.latitude.min + area.latitude.max) / 2, step)
				testing.expect_value(t, again.bits, hash.bits)
			}
		}
	}
	long_range, lat_range := geo.coord_ranges()
	plain, plain_ok := geo.encode(long_range, lat_range, 13.361389, 38.115556, 26)
	testing.expect(t, plain_ok)
	testing.expect_value(t, plain.bits, 3479099956230698)
	coarse, coarse_ok := geo.encode(long_range, lat_range, 13.361389, 38.115556, 10)
	testing.expect(t, coarse_ok)
	testing.expect_value(t, geo.align52(coarse), 3479099956230698 & ~u64((1 << 32) - 1))
	_, outside := geo.encode(geo.Range{-10, 10}, lat_range, 13.361389, 38.115556, 26)
	testing.expect(t, !outside)
}

@(test)
special_scores_decode_like_dataset :: proc(t: ^testing.T) {
	Case :: struct {
		score: f64,
		lon:   string,
		lat:   string,
		hash:  string,
	}
	cases := [?]Case {
		{-5, "180", "85.0511287799999991", "bp05b5048p0"},
		{1e20, "-179.99999731779098511", "-85.05112751263942528", "00bh0hbj200"},
		{4503599627370495, "179.99999731779098511", "85.05112751263942528", "zzpgzgpfxz0"},
		{4503599627370496, "-179.99999731779098511", "85.0511287799999991", "bp05b5048p0"},
		{0.5, "-179.99999731779098511", "-85.05112751263942528", "00bh0hbj200"},
		{-1e20, "180", "-85.05112751263942528", "00bh0hbj200"},
	}
	for c in cases {
		xy, ok := geo.decode_score(c.score)
		testing.expect(t, ok)
		a, b: [geo.HUMAN_MAX]u8
		testing.expect_value(t, human_text(a[:], xy[0]), c.lon)
		testing.expect_value(t, human_text(b[:], xy[1]), c.lat)
		text: [11]u8
		testing.expect(t, geo.geohash_string(c.score, &text))
		testing.expect_value(t, string(text[:]), c.hash)
	}
	testing.expect_value(t, geo.score_to_bits(-5), 0xFFFFFFFFFFFFFFFB)
	testing.expect_value(t, geo.score_to_bits(1e20), 0)
	testing.expect_value(t, geo.score_to_bits(-1e20), u64(1) << 63)
	testing.expect_value(t, geo.score_to_bits(0.5), 0)
	testing.expect_value(t, geo.score_to_bits(1.8446744073709552e19 / 2), u64(1) << 63)
}

@(test)
fixed_formatting :: proc(t: ^testing.T) {
	buf: [400]u8
	testing.expect_value(t, f6_text(buf[:], 1e300), BIG_1E300 + ".000000")
	testing.expect_value(t, f6_text(buf[:], -1e-7), "-0.000000")
	testing.expect_value(t, f6_text(buf[:], -0.0), "-0.000000")
	testing.expect_value(t, f6_text(buf[:], math.inf_f64(1)), "inf")
	testing.expect_value(t, f6_text(buf[:], math.inf_f64(-1)), "-inf")
	testing.expect_value(t, f6_text(buf[:], math.nan_f64()), "nan")
	testing.expect_value(t, f6_text(buf[:], 180.0000001), "180.000000")
	testing.expect_value(t, f6_text(buf[:], 85.06), "85.060000")
	testing.expect_value(t, f6_text(buf[:], 0.0078125), "0.007812")
	testing.expect_value(t, f6_text(buf[:], 0.0234375), "0.023438")
	testing.expect_value(t, f6_text(buf[:], 2.5e-6), "0.000003")
	testing.expect_value(t, f6_text(buf[:], 1e22), "10000000000000000000000.000000")
	testing.expect_value(t, distance_text(buf[:], 0.03125), "0.0312")
	testing.expect_value(t, distance_text(buf[:], 0.09375), "0.0938")
	testing.expect_value(t, distance_text(buf[:], 0.00005), "0.0001")
	testing.expect_value(t, distance_text(buf[:], 1e-5), "0.0000")
	testing.expect_value(t, distance_text(buf[:], 12345.67895), "12345.6789")
	testing.expect_value(t, distance_text(buf[:], 167419.14020232), "167419.1402")
	testing.expect_value(t, human_text(buf[:], geo.LAT_MAX), "85.0511287799999991")
	testing.expect_value(t, human_text(buf[:], 180), "180")
	testing.expect_value(t, human_text(buf[:], -0.0), "0")
	testing.expect_value(t, human_text(buf[:], -1e-20), "0")
	testing.expect_value(t, human_text(buf[:], 0.5), "0.5")
	testing.expect_value(t, human_text(buf[:], 0.1), "0.10000000000000001")
	testing.expect_value(t, human_text(buf[:], 123.456), "123.45600000000000307")
	testing.expect_value(t, human_text(buf[:], -123.456), "-123.45600000000000307")
	testing.expect_value(t, human_text(buf[:], 0.000003814697265625), "0.00000381469726562")
	testing.expect_value(t, human_text(buf[:], 1.5e-17), "0.00000000000000002")
	testing.expect_value(t, human_text(buf[:], 5e-324), "0")
	testing.expect_value(t, human_text(buf[:], 1180591620717411303424), "1180591620717411303424")
	testing.expect_value(t, human_text(buf[:], 1e300), BIG_1E300)
	testing.expect_value(t, len(human_text(buf[:], max(f64))), 309)
	small: [4]u8
	testing.expect_value(t, geo.format_human(small[:], 123.456), 4)
	testing.expect_value(t, string(small[:]), "123.")
	testing.expect_value(t, geo.HUMAN_MAX, 64)
	testing.expect_value(t, geo.DISTANCE_MAX, 32)
}

@(test)
error_strings :: proc(t: ^testing.T) {
	Case :: struct {
		err:  geo.Error,
		text: string,
	}
	cases := [?]Case {
		{.Syntax, "ERR syntax error"},
		{.Not_Float, "ERR value is not a valid float"},
		{.Invalid_Pair, "ERR invalid longitude,latitude pair 181.000000,-0.000000"},
		{.Unit, "ERR unsupported unit provided. please use M, KM, FT, MI"},
		{.Need_Radius, "ERR need numeric radius"},
		{.Need_Width, "ERR need numeric width"},
		{.Need_Height, "ERR need numeric height"},
		{.Radius_Negative, "ERR radius cannot be negative"},
		{.Box_Negative, "ERR height or width cannot be negative"},
		{.Not_Integer, "ERR value is not an integer or out of range"},
		{.Count_Positive, "ERR COUNT must be > 0"},
		{.Member, "ERR could not decode requested zset member"},
		{.Store_With, "ERR STORE option in GEORADIUS is not compatible with WITHDIST, WITHHASH and WITHCOORD options"},
		{.Searchstore_With, "ERR GEOSEARCHSTORE is not compatible with WITHDIST, WITHHASH and WITHCOORD options"},
		{.Origin, "ERR exactly one of FROMMEMBER or FROMLONLAT can be specified for GEOSEARCH"},
		{.Shape, "ERR exactly one of BYRADIUS and BYBOX can be specified for GEOSEARCH"},
		{.Any_Count, "ERR the ANY argument requires COUNT argument"},
	}
	seen: bit_set[geo.Error]
	for c in cases {
		buf: [geo.ERROR_TEXT_MAX]u8
		testing.expect_value(t, string(geo.error_text(buf[:], c.err, {181, -0.0}, transmute([]u8)string("GEOSEARCH"))), c.text)
		seen += {c.err}
	}
	for e in geo.Error {
		testing.expect(t, e == .None || e in seen)
	}
	wide: [geo.ERROR_TEXT_MAX]u8
	text := string(geo.error_text(wide[:], .Invalid_Pair, {1e300, 1e300}, nil))
	testing.expect_value(t, text, "ERR invalid longitude,latitude pair " + BIG_1E300 + ".000000," + BIG_1E300 + ".000000")
}

@(test)
units_are_case_insensitive :: proc(t: ^testing.T) {
	Case :: struct {
		unit:   string,
		meters: f64,
	}
	cases := [?]Case{{"m", 1}, {"M", 1}, {"km", 1000}, {"Km", 1000}, {"ft", 0.3048}, {"FT", 0.3048}, {"mi", 1609.34}, {"mI", 1609.34}}
	for c in cases {
		v, ok := geo.unit_to_meters(transmute([]u8)c.unit)
		testing.expect(t, ok)
		testing.expect_value(t, v, c.meters)
	}
	for bad in ([?]string{"", "parsec", "kms", "m ", "meter"}) {
		_, ok := geo.unit_to_meters(transmute([]u8)bad)
		testing.expect(t, !ok)
	}
}

@(test)
search_cells_never_repeat_and_contain_origin :: proc(t: ^testing.T) {
	origins := [?][2]f64{{0, 0}, {179.99, 0.5}, {-179.99, -0.5}, {13.36, 38.11}, {0, 85.05}, {0, -85.05}, {180, 85.05112878}, {-180, -85.05112878}}
	radii := [?]f64{0, 1, 50, 1000, 50000, 500000, 5000000, 20000000}
	for origin in origins {
		for radius in radii {
			shape := geo.Shape {
				type       = .Circular,
				xy         = origin,
				conversion = 1,
				radius     = radius,
			}
			r := geo.calculate_areas(&shape)
			testing.expect(t, !geo.hash_is_zero(r.hash))
			testing.expect(t, r.area.longitude.min <= origin[0] || origin[0] == 180)
			testing.expect(t, r.area.latitude.min <= origin[1])
			n := r.neighbors
			cells := [?]geo.Hash_Bits{n.north, n.south, n.east, n.west, n.north_east, n.north_west, n.south_east, n.south_west}
			for c in cells {
				if geo.hash_is_zero(c) {
					continue
				}
				testing.expect_value(t, c.step, r.hash.step)
			}
		}
	}
}

Brute_Point :: struct {
	member: string,
	xy:     [2]f64,
}

@(test)
search_agrees_with_brute_force :: proc(t: ^testing.T) {
	z := zt.create_skiplist(600)
	defer zt.destroy(z)
	state: u64 = 0x2545F4914F6CDD1D
	next :: proc(s: ^u64) -> f64 {
		s^ ~= s^ << 13
		s^ ~= s^ >> 7
		s^ ~= s^ << 17
		return f64(s^ >> 11) / f64(u64(1) << 53)
	}
	names: [600][8]u8
	for i in 0 ..< 600 {
		lon := -20 + next(&state) * 40
		lat := 30 + next(&state) * 20
		name := names[i][:]
		name[0] = 'm'
		v := i
		for k := 7; k >= 1; k -= 1 {
			name[k] = u8('0' + v % 10)
			v /= 10
		}
		_, _, _ = zt.add(z, geo.score_of({lon, lat}), name, {})
	}
	points := make([dynamic]geo.Point)
	defer delete(points)
	tmp := make([dynamic]geo.Point)
	defer delete(tmp)
	for _ in 0 ..< 300 {
		shape := geo.Shape {
			xy         = {-15 + next(&state) * 30, 33 + next(&state) * 14},
			conversion = 1000,
		}
		if next(&state) < 0.5 {
			shape.type = .Circular
			shape.radius = 1 + next(&state) * 600
		} else {
			shape.type = .Rectangle
			shape.width = 1 + next(&state) * 1200
			shape.height = 1 + next(&state) * 1200
		}
		clear(&points)
		probe := shape
		geo.search(z, &probe, &points, 0)
		expected := 0
		it := zt.iter_make(z, false)
		item: zt.Item
		for zt.iter_next(&it, &item) {
			if _, _, inside := geo.within_shape(&shape, item.score); inside {
				expected += 1
			}
		}
		testing.expect_value(t, len(points), expected)
		for &p in points {
			_, _, inside := geo.within_shape(&shape, p.score)
			testing.expect(t, inside)
		}
	}
}

@(test)
sorting_is_stable_and_count_truncates :: proc(t: ^testing.T) {
	script := [?]string {
		"GEOADD|dup|10|10|a|10|10|b|10|10|c|10.0001|10|d|9.9999|10|e",
		"GEORADIUS|dup|10|10|100|km|ASC|WITHDIST",
		"GEORADIUS|dup|10|10|100|km|DESC|WITHDIST",
		"GEORADIUS|dup|10|10|100|km|COUNT|2|WITHDIST",
		"GEORADIUS|dup|10|10|100|km|COUNT|2|DESC",
		"GEORADIUS|dup|10|10|100|km|COUNT|3|ANY",
	}
	replies := [?]string {
		":5\r\n",
		"*5\r\n*2\r\n$1\r\na\r\n$6\r\n0.0003\r\n*2\r\n$1\r\nb\r\n$6\r\n0.0003\r\n*2\r\n$1\r\nc\r\n$6\r\n0.0003\r\n*2\r\n$1\r\nd\r\n$6\r\n0.0108\r\n*2\r\n$1\r\ne\r\n$6\r\n0.0109\r\n",
		"*5\r\n*2\r\n$1\r\ne\r\n$6\r\n0.0109\r\n*2\r\n$1\r\nd\r\n$6\r\n0.0108\r\n*2\r\n$1\r\na\r\n$6\r\n0.0003\r\n*2\r\n$1\r\nb\r\n$6\r\n0.0003\r\n*2\r\n$1\r\nc\r\n$6\r\n0.0003\r\n",
		"*2\r\n*2\r\n$1\r\na\r\n$6\r\n0.0003\r\n*2\r\n$1\r\nb\r\n$6\r\n0.0003\r\n",
		"*2\r\n$1\r\ne\r\n$1\r\nd\r\n",
		"*3\r\n$1\r\ne\r\n$1\r\na\r\n$1\r\nb\r\n",
	}
	testing.expect_value(t, replay_fixture(t, script[:], replies[:]), 0)
	v := make([dynamic]geo.Point)
	defer delete(v)
	tmp := make([dynamic]geo.Point)
	defer delete(tmp)
	for i in 0 ..< 100 {
		append(&v, geo.Point{dist = f64(i % 7), score = f64(i)})
	}
	geo.sort_points(v[:], .Asc, &tmp)
	for i in 1 ..< len(v) {
		testing.expect(t, v[i - 1].dist < v[i].dist || v[i - 1].dist == v[i].dist && v[i - 1].score < v[i].score)
	}
	geo.sort_points(v[:], .Desc, &tmp)
	for i in 1 ..< len(v) {
		testing.expect(t, v[i - 1].dist > v[i].dist || v[i - 1].dist == v[i].dist && v[i - 1].score < v[i].score)
	}
}

@(test)
command_errors_and_precedence :: proc(t: ^testing.T) {
	script := [?]string {
		"SET|str|v",
		"GEOADD|sic|13.361389|38.115556|Palermo|15.087269|37.502669|Catania",
		"GEOADD|sic|XX|NX|1|1|a",
		"GEOADD|sic|CH|CH|CH",
		"GEOADD|sic|1|1|a|2",
		"GEOADD|edge|1|abc|m",
		"GEOADD|edge|1|1|ok|200|200|bad|x|2|never",
		"GEOADD|str|200|1|a",
		"GEOADD|str|1|1|a",
		"GEODIST|str|a|b|parsec",
		"GEODIST|sic|Palermo|Catania|km|x",
		"GEORADIUS|str|1000|1|1|km",
		"GEORADIUS|sic|15|37|abc|parsec",
		"GEORADIUS|sic|15|37|-1|parsec",
		"GEORADIUS|sic|15|37|1|km|COUNT|0|ANY",
		"GEORADIUS|sic|15|37|1|km|WITHDIST|ANY|STORE|x",
		"GEORADIUSBYMEMBER|nokey|nope|abc|km|STORE|d",
		"GEORADIUSBYMEMBER|sic|nope|abc|parsec",
		"GEOSEARCH|sic|BYBOX|-1|abc|km|ASC",
		"GEOSEARCH|sic|BYBOX|abc|-1|km|ASC",
		"GEOSEARCH|sic|BYBOX|1|-1|parsec|ASC",
		"GEOSEARCH|sic|BYBOX|1|1|parsec|ASC",
		"GEOSEARCH|sic|FROMMEMBER|nope|BYRADIUS|-1|km",
		"GEOSEARCH|sic|BYRADIUS|-1|km|FROMMEMBER|nope",
		"geosearch|sic|BYRADIUS|1|km|ANY|ASC",
		"GEOSEARCH|sic|FROMLONLAT|15|37|ANY|WITHDIST",
		"GEOSEARCHSTORE|d|sic|FROMLONLAT|15|37|WITHHASH|ASC",
		"GEOSEARCHSTORE|d|sic|FROMLONLAT|15|37|BYRADIUS|1|km|ANY",
	}
	replies := [?]string {
		"+OK\r\n",
		":2\r\n",
		"-ERR syntax error\r\n",
		"-ERR syntax error\r\n",
		"-ERR syntax error\r\n",
		"-ERR value is not a valid float\r\n",
		"-ERR invalid longitude,latitude pair 200.000000,200.000000\r\n",
		"-ERR invalid longitude,latitude pair 200.000000,1.000000\r\n",
		"-WRONGTYPE Operation against a key holding the wrong kind of value\r\n",
		"-ERR unsupported unit provided. please use M, KM, FT, MI\r\n",
		"-ERR syntax error\r\n",
		"-WRONGTYPE Operation against a key holding the wrong kind of value\r\n",
		"-ERR need numeric radius\r\n",
		"-ERR radius cannot be negative\r\n",
		"-ERR COUNT must be > 0\r\n",
		"-ERR STORE option in GEORADIUS is not compatible with WITHDIST, WITHHASH and WITHCOORD options\r\n",
		":0\r\n",
		"-ERR could not decode requested zset member\r\n",
		"-ERR need numeric height\r\n",
		"-ERR need numeric width\r\n",
		"-ERR height or width cannot be negative\r\n",
		"-ERR unsupported unit provided. please use M, KM, FT, MI\r\n",
		"-ERR could not decode requested zset member\r\n",
		"-ERR radius cannot be negative\r\n",
		"-ERR exactly one of FROMMEMBER or FROMLONLAT can be specified for geosearch\r\n",
		"-ERR exactly one of BYRADIUS and BYBOX can be specified for GEOSEARCH\r\n",
		"-ERR GEOSEARCHSTORE is not compatible with WITHDIST, WITHHASH and WITHCOORD options\r\n",
		"-ERR the ANY argument requires COUNT argument\r\n",
	}
	testing.expect_value(t, len(script), len(replies))
	testing.expect_value(t, replay_fixture(t, script[:], replies[:]), 0)
}
