package main

import "core:fmt"
import "core:os"
import "core:strings"

Rng :: struct {
	s: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.s += 0x9e3779b97f4a7c15
	z := r.s
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

rng_below :: proc(r: ^Rng, n: int) -> int {
	if n <= 0 {
		return 0
	}
	return int(rng_next(r) % u64(n))
}

rng_chance :: proc(r: ^Rng, percent: int) -> bool {
	return rng_below(r, 100) < percent
}

rng_float :: proc(r: ^Rng) -> f64 {
	return f64(rng_next(r) >> 11) / f64(u64(1) << 53)
}

pick :: proc(r: ^Rng, opts: []string) -> string {
	return opts[rng_below(r, len(opts))]
}

Gen :: struct {
	buf: [dynamic]u8,
	n:   int,
	rng: Rng,
}

g_cmd :: proc(g: ^Gen, args: ..string) {
	parts := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		parts[i] = transmute([]u8)a
	}
	cmd_append(&g.buf, parts)
	g.n += 1
}

g_cmds :: proc(g: ^Gen, args: []string) {
	g_cmd(g, ..args)
}

tp :: proc(args: ..any) -> string {
	return fmt.tprint(..args, sep = "")
}

coord :: proc(v: f64) -> string {
	return fmt.tprintf("%.15f", v)
}

random_point :: proc(g: ^Gen) -> (lon: f64, lat: f64) {
	r := &g.rng
	switch rng_below(r, 10) {
	case 0:
		lon = -180 + rng_float(r) * 0.5
		lat = -85.05112878 + rng_float(r) * 170.10225756
	case 1:
		lon = 179.5 + rng_float(r) * 0.5
		lat = -85.05112878 + rng_float(r) * 170.10225756
	case 2:
		lon = -180 + rng_float(r) * 360
		lat = 84.5 + rng_float(r) * 0.55112878
	case 3:
		lon = -180 + rng_float(r) * 360
		lat = -85.05112878 + rng_float(r) * 0.5
	case 4, 5:
		lon = 13 + rng_float(r) * 2
		lat = 37 + rng_float(r) * 2
	case:
		lon = -180 + rng_float(r) * 360
		lat = -85.05112878 + rng_float(r) * 170.10225756
	}
	return
}

fill_points :: proc(g: ^Gen, key: string, n: int, prefix: string) {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "GEOADD", key)
	for i in 0 ..< n {
		lon, lat := random_point(g)
		append(&args, coord(lon), coord(lat))
		if rng_chance(&g.rng, 10) {
			append(&args, tp(i))
		} else {
			append(&args, tp(prefix, i))
		}
	}
	g_cmds(g, args[:])
	g_cmd(g, "ZCARD", key)
	g_cmd(g, "OBJECT", "ENCODING", key)
}

UNITS := [?]string{"m", "km", "ft", "mi", "M", "KM", "Ft", "MI"}

random_search :: proc(g: ^Gen, key: string, members: int, prefix: string) {
	r := &g.rng
	args := make([dynamic]string, context.temp_allocator)
	kind := rng_below(r, 6)
	store := ""
	center_member := tp(prefix, rng_below(r, members + 2))
	lon, lat := random_point(g)
	size := 0.0
	switch rng_below(r, 10) {
	case 0:
		size = rng_float(r) * 100
	case 1, 2, 3, 4:
		size = 10 + rng_float(r) * 300
	case 5, 6:
		size = 500 + rng_float(r) * 3000
	case 7:
		size = 5000 + rng_float(r) * 15000
	case 8:
		size = f64(rng_below(r, 50))
	case 9:
		size = 0
	}
	unit := "km"
	if rng_chance(r, 30) {
		unit = pick(r, UNITS[:])
		switch strings.to_lower(unit, context.temp_allocator) {
		case "m":
			size *= 1000
		case "ft":
			size *= 3280.84
		case "mi":
			size *= 0.621371
		}
	}
	size_s := fmt.tprintf("%.6f", size)
	switch kind {
	case 0:
		append(&args, pick(r, []string{"GEORADIUS", "GEORADIUS_RO"}), key, coord(lon), coord(lat), size_s, unit)
	case 1:
		append(&args, pick(r, []string{"GEORADIUSBYMEMBER", "GEORADIUSBYMEMBER_RO"}), key, center_member, size_s, unit)
	case 2, 3, 4:
		append(&args, "GEOSEARCH", key)
	case 5:
		store = pick(r, []string{"gdst", "gdst2"})
		append(&args, "GEOSEARCHSTORE", store, key)
	}
	if kind >= 2 {
		if rng_chance(r, 50) {
			append(&args, "FROMMEMBER", center_member)
		} else {
			append(&args, "FROMLONLAT", coord(lon), coord(lat))
		}
		if rng_chance(r, 50) {
			append(&args, "BYRADIUS", size_s, unit)
		} else {
			h := size * (0.2 + rng_float(r) * 1.8)
			append(&args, "BYBOX", size_s, fmt.tprintf("%.6f", h), unit)
		}
	}
	readonly := args[0] == "GEORADIUS_RO" || args[0] == "GEORADIUSBYMEMBER_RO"
	if kind != 5 && !readonly && (kind <= 1) && rng_chance(r, 20) {
		store = pick(r, []string{"gdst", "gdst2"})
		append(&args, pick(r, []string{"STORE", "STOREDIST"}), store)
	} else if kind == 5 && rng_chance(r, 50) {
		append(&args, "STOREDIST")
	}
	if store == "" {
		if rng_chance(r, 40) {
			append(&args, "WITHDIST")
		}
		if rng_chance(r, 30) {
			append(&args, "WITHHASH")
		}
		if rng_chance(r, 30) {
			append(&args, "WITHCOORD")
		}
	}
	switch rng_below(r, 4) {
	case 0:
		append(&args, "ASC")
	case 1:
		append(&args, "DESC")
	}
	if rng_chance(r, 40) {
		append(&args, "COUNT", tp(1 + rng_below(r, 20)))
		if rng_chance(r, 30) {
			append(&args, "ANY")
		}
	}
	g_cmds(g, args[:])
	if store != "" {
		g_cmd(g, "ZRANGE", store, "0", "-1", "WITHSCORES")
		g_cmd(g, "OBJECT", "ENCODING", store)
	}
}

section_basic :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	g_cmd(g, "GEOADD", "sic", "13.361389", "38.115556", "Palermo", "15.087269", "37.502669", "Catania")
	g_cmd(g, "GEOADD", "sic", "CH", "13.361389", "38.115556", "Palermo", "15.1", "37.5", "Catania")
	g_cmd(g, "GEOADD", "sic", "NX", "1", "1", "Palermo", "2", "2", "New")
	g_cmd(g, "GEOADD", "sic", "XX", "CH", "13.361389", "38.115556", "Palermo", "3", "3", "Other")
	g_cmd(g, "GEOADD", "sic", "XX", "NX", "1", "1", "a")
	g_cmd(g, "GEOADD", "sic", "CH", "XX", "NX", "1", "1", "a")
	g_cmd(g, "GEOADD", "sic", "GT", "1", "1", "a")
	g_cmd(g, "GEOADD", "sic", "1", "1")
	g_cmd(g, "GEOADD", "sic", "1", "1", "a", "2")
	g_cmd(g, "GEOADD", "sic", "CH", "CH", "CH")
	g_cmd(g, "GEOADD", "sic", "NX", "CH", "XX")
	for c in ([?][2]string{{"181", "0"}, {"-181", "0"}, {"0", "85.06"}, {"0", "-85.06"}, {"200", "100"}, {"1e300", "-1e-7"}, {"inf", "0"}, {"0", "-inf"}, {"abc", "1"}, {"1", "abc"}, {"nan", "1"}, {"", "1"}, {" 1", "1"}, {"180", "85.05112878"}, {"-180", "-85.05112878"}, {"0x10", "0x1p3"}, {"180.0000001", "0"}}) {
		g_cmd(g, "GEOADD", "edge", c[0], c[1], "m")
	}
	g_cmd(g, "GEOADD", "edge", "1", "1", "ok", "200", "200", "bad", "2", "2", "never")
	g_cmd(g, "ZRANGE", "edge", "0", "-1", "WITHSCORES")
	g_cmd(g, "ZRANGE", "sic", "0", "-1", "WITHSCORES")
	g_cmd(g, "GEOPOS", "sic", "Palermo", "nope", "Catania", "New", "edge")
	g_cmd(g, "GEOPOS", "edge", "m", "ok")
	g_cmd(g, "GEOPOS", "nokey", "a", "b")
	g_cmd(g, "GEOPOS", "sic")
	g_cmd(g, "GEOHASH", "sic", "Palermo", "nope", "Catania")
	g_cmd(g, "GEOHASH", "edge", "m", "ok")
	g_cmd(g, "GEOHASH", "nokey", "a")
	g_cmd(g, "GEOHASH", "sic")
	for u in UNITS {
		g_cmd(g, "GEODIST", "sic", "Palermo", "Catania", u)
	}
	g_cmd(g, "GEODIST", "sic", "Palermo", "Catania")
	g_cmd(g, "GEODIST", "sic", "Palermo", "Palermo")
	g_cmd(g, "GEODIST", "sic", "Palermo", "nope")
	g_cmd(g, "GEODIST", "nokey", "a", "b")
	g_cmd(g, "GEODIST", "sic", "Palermo", "Catania", "parsec")
	g_cmd(g, "GEODIST", "nokey", "a", "b", "parsec")
	g_cmd(g, "GEODIST", "sic", "Palermo", "Catania", "km", "x")
	g_cmd(g, "GEODIST", "edge", "m", "ok", "mi")
	g_cmd(g, "ZADD", "weird", "-5", "neg", "1e20", "huge", "4503599627370495", "max52", "4503599627370496", "over", "0.5", "half", "-1e20", "hugeneg")
	g_cmd(g, "GEOPOS", "weird", "neg", "huge", "max52", "over", "half", "hugeneg")
	g_cmd(g, "GEOHASH", "weird", "neg", "huge", "max52", "over", "half", "hugeneg")
	g_cmd(g, "GEODIST", "weird", "neg", "max52")
	g_cmd(g, "GEORADIUS", "weird", "0", "0", "20000", "km", "WITHCOORD", "WITHHASH", "WITHDIST")
	g_cmd(g, "SET", "str", "v")
	g_cmd(g, "HSET", "hsh", "f", "v")
	wrong := [?][]string {
		{"GEOADD", "str", "1", "1", "a"},
		{"GEOPOS", "str", "a"},
		{"GEOHASH", "hsh", "a"},
		{"GEODIST", "str", "a", "b"},
		{"GEODIST", "str", "a", "b", "parsec"},
		{"GEORADIUS", "str", "1", "1", "1", "km"},
		{"GEORADIUS", "str", "1000", "1", "1", "km"},
		{"GEORADIUSBYMEMBER", "hsh", "a", "1", "km"},
		{"GEOSEARCH", "str", "FROMLONLAT", "1", "1", "BYRADIUS", "1", "km"},
		{"GEOSEARCHSTORE", "d", "str", "FROMLONLAT", "1", "1", "BYRADIUS", "1", "km"},
		{"GEOSEARCHSTORE", "str", "sic", "FROMLONLAT", "13", "38", "BYRADIUS", "500", "km"},
	}
	for w in wrong {
		g_cmds(g, w)
	}
	g_cmd(g, "TYPE", "str")
	errs := [?][]string {
		{"GEORADIUS", "sic", "15", "37", "200", "km", "WITHDIST", "STORE", "x"},
		{"GEORADIUS", "sic", "15", "37", "200", "km", "STORE"},
		{"GEORADIUS", "sic", "15", "37", "200", "km", "STOREDIST"},
		{"GEORADIUS_RO", "sic", "15", "37", "200", "km", "STORE", "x"},
		{"GEORADIUSBYMEMBER_RO", "sic", "Palermo", "200", "km", "STOREDIST", "x"},
		{"GEORADIUS", "sic", "15", "37", "-1", "km"},
		{"GEORADIUS", "sic", "15", "37", "abc", "km"},
		{"GEORADIUS", "sic", "15", "37", "1", "lightyear"},
		{"GEORADIUS", "sic", "15", "37", "1", "km", "COUNT"},
		{"GEORADIUS", "sic", "15", "37", "1", "km", "COUNT", "0"},
		{"GEORADIUS", "sic", "15", "37", "1", "km", "COUNT", "-3"},
		{"GEORADIUS", "sic", "15", "37", "1", "km", "COUNT", "abc"},
		{"GEORADIUS", "sic", "15", "37", "1", "km", "ANY"},
		{"GEORADIUS", "sic", "15", "37", "1", "km", "FOO"},
		{"GEORADIUS", "sic", "190", "37", "1", "km"},
		{"GEORADIUS", "sic", "15", "37", "1", "km", "FROMMEMBER", "Palermo"},
		{"GEORADIUSBYMEMBER", "sic", "nope", "1", "km"},
		{"GEORADIUSBYMEMBER", "sic", "nope", "abc", "km"},
		{"GEORADIUSBYMEMBER", "nokey", "nope", "abc", "km"},
		{"GEORADIUSBYMEMBER", "nokey", "nope", "1", "km", "STORE", "d"},
		{"GEORADIUSBYMEMBER", "nokey", "nope", "1", "km", "WITHDIST", "STORE", "d"},
		{"GEORADIUSBYMEMBER", "nokey", "nope", "1", "km", "BAD"},
		{"GEOSEARCH", "sic", "BYBOX", "3", "3", "km", "ASC", "DESC", "WITHHASH", "WITHDIST", "WITHCOORD"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "37", "ASC", "WITHCOORD"},
		{"geosearch", "sic", "FROMLONLAT", "15", "37", "ASC"},
		{"GeoSearch", "sic", "BYRADIUS", "1", "km"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "37", "FROMMEMBER", "Palermo", "BYBOX", "3", "3", "km"},
		{"GEOSEARCH", "sic", "FROMMEMBER", "Palermo", "FROMLONLAT", "15", "37", "BYBOX", "3", "3", "km"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "37", "BYRADIUS", "3", "km", "BYBOX", "3", "3", "km"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "37", "BYBOX", "3", "3", "km", "BYRADIUS", "3", "km"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "37", "BYBOX", "-3", "3", "km"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "37", "BYBOX", "3", "-3", "km"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "37", "BYBOX", "abc", "3", "km"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "37", "BYBOX", "3", "abc", "km"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "37", "BYBOX", "3", "3", "parsec"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "37", "BYBOX", "3", "3"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "37", "BYRADIUS", "3", "km", "STOREDIST"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "37", "BYRADIUS", "3", "km", "STORE", "x"},
		{"GEOSEARCH", "sic", "FROMMEMBER", "nope", "BYRADIUS", "3", "km"},
		{"GEOSEARCH", "nokey", "FROMMEMBER", "nope", "BYRADIUS", "3", "km"},
		{"GEOSEARCH", "nokey", "FROMMEMBER", "nope", "BYRADIUS", "-3", "km"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "95", "BYRADIUS", "3", "km"},
		{"GEOSEARCH", "sic", "FROMLONLAT", "15", "37", "BYRADIUS", "3", "km", "ANY", "COUNT", "2"},
		{"GEOSEARCHSTORE", "d", "sic", "FROMLONLAT", "15", "37", "BYRADIUS", "300", "km", "WITHDIST"},
		{"GEOSEARCHSTORE", "d", "sic", "FROMLONLAT", "15", "37", "BYRADIUS", "300", "km", "STORE", "d"},
		{"GEOSEARCHSTORE", "d", "nokey", "FROMLONLAT", "15", "37", "BYRADIUS", "300", "km"},
		{"GEOSEARCHSTORE", "d", "nokey", "FROMMEMBER", "x", "BYRADIUS", "300", "km", "STOREDIST"},
		{"GEOADD", "k"},
		{"GEOPOS"},
		{"GEODIST", "k", "a"},
		{"GEORADIUS", "k", "1", "1", "1"},
		{"GEORADIUSBYMEMBER", "k", "a", "1"},
		{"GEOSEARCH", "k", "FROMLONLAT", "1", "1", "BYRADIUS"},
		{"GEOSEARCHSTORE", "d", "k", "FROMLONLAT", "1", "1", "BYRADIUS", "1"},
	}
	for e in errs {
		g_cmds(g, e)
	}
	g_cmd(g, "EXISTS", "d")
	g_cmd(g, "GEOSEARCHSTORE", "d", "sic", "FROMLONLAT", "15", "37", "BYRADIUS", "300", "km", "STOREDIST")
	g_cmd(g, "ZRANGE", "d", "0", "-1", "WITHSCORES")
	g_cmd(g, "GEOSEARCHSTORE", "d", "sic", "FROMLONLAT", "100", "37", "BYRADIUS", "1", "km")
	g_cmd(g, "EXISTS", "d")
	g_cmd(g, "GEORADIUS", "sic", "15", "37", "200", "km", "STORE", "sic")
	g_cmd(g, "ZRANGE", "sic", "0", "-1", "WITHSCORES")
	g_cmd(g, "GEOADD", "dup", "10", "10", "a", "10", "10", "b", "10", "10", "c", "10.0001", "10", "d", "9.9999", "10", "e")
	g_cmd(g, "GEORADIUS", "dup", "10", "10", "100", "km", "ASC", "WITHDIST")
	g_cmd(g, "GEORADIUS", "dup", "10", "10", "100", "km", "DESC", "WITHDIST")
	g_cmd(g, "GEORADIUS", "dup", "10", "10", "100", "km", "COUNT", "2", "WITHDIST")
	g_cmd(g, "GEORADIUS", "dup", "10", "10", "100", "km", "COUNT", "2", "DESC")
	g_cmd(g, "GEORADIUS", "dup", "10", "10", "100", "km", "COUNT", "3", "ANY")
	g_cmd(g, "GEOSEARCH", "dup", "FROMMEMBER", "a", "BYBOX", "50", "50", "km", "COUNT", "4", "ASC", "WITHCOORD", "WITHHASH", "WITHDIST")
	g_cmd(g, "GEOADD", "pole", "45", "65", "n1", "-135", "85.05", "n2", "0", "85.05112878", "n3", "179.9999", "-85", "n4", "-179.9999", "-85", "n5", "180", "0", "n6", "-180", "0", "n7")
	g_cmd(g, "GEORADIUSBYMEMBER", "pole", "n1", "5009431", "m")
	g_cmd(g, "GEORADIUSBYMEMBER", "pole", "n4", "50", "km", "WITHDIST", "ASC")
	g_cmd(g, "GEOSEARCH", "pole", "FROMMEMBER", "n6", "BYBOX", "100", "100", "km", "WITHCOORD")
	g_cmd(g, "GEOSEARCH", "pole", "FROMLONLAT", "0", "85", "BYRADIUS", "1000", "km", "WITHDIST", "DESC")
	g_cmd(g, "GEOSEARCH", "pole", "FROMLONLAT", "179", "-85", "BYBOX", "400", "400", "km", "ASC")
	g_cmd(g, "GEORADIUS", "pole", "0", "0", "50000", "km", "WITHCOORD")
	g_cmd(g, "GEORADIUS", "pole", "0", "0", "0", "km")
	g_cmd(g, "GEORADIUS", "pole", "45", "65", "0", "m", "WITHDIST")
	g_cmd(g, "GEORADIUS", "pole", "45", "65", "inf", "km", "COUNT", "3")
}

section_random :: proc(g: ^Gen, rounds: int) {
	g_cmd(g, "FLUSHALL")
	keys := [?]string{"pts0", "pts1", "pts2", "pts3"}
	sizes := [?]int{40, 120, 400, 2000}
	for k, i in keys {
		fill_points(g, k, sizes[i], tp("p", i, ":"))
	}
	for round in 0 ..< rounds {
		r := &g.rng
		ki := rng_below(r, len(keys))
		key := keys[ki]
		prefix := tp("p", ki, ":")
		switch rng_below(r, 20) {
		case 0:
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "GEOADD", key)
			if rng_chance(r, 30) {
				append(&args, pick(r, []string{"NX", "XX", "CH"}))
			}
			for _ in 0 ..< 1 + rng_below(r, 5) {
				lon, lat := random_point(g)
				append(&args, coord(lon), coord(lat), tp(prefix, rng_below(r, sizes[ki] + 20)))
			}
			g_cmds(g, args[:])
		case 1:
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "GEOPOS", key)
			for _ in 0 ..< 1 + rng_below(r, 5) {
				append(&args, tp(prefix, rng_below(r, sizes[ki] + 5)))
			}
			g_cmds(g, args[:])
		case 2:
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "GEOHASH", key)
			for _ in 0 ..< 1 + rng_below(r, 5) {
				append(&args, tp(prefix, rng_below(r, sizes[ki] + 5)))
			}
			g_cmds(g, args[:])
		case 3:
			g_cmd(g, "GEODIST", key, tp(prefix, rng_below(r, sizes[ki])), tp(prefix, rng_below(r, sizes[ki])), pick(r, UNITS[:]))
		case:
			random_search(g, key, sizes[ki], prefix)
		}
		if round % 1000 == 999 {
			g_cmd(g, "GEOSEARCHSTORE", key, key, "FROMMEMBER", tp(prefix, 1), "BYRADIUS", "2000", "km", "STOREDIST")
			g_cmd(g, "ZRANGE", key, "0", "-1", "WITHSCORES")
			g_cmd(g, "DEL", key)
			fill_points(g, key, sizes[ki], prefix)
			free_all(context.temp_allocator)
		}
	}
}

ROUNDING_PAIRS := [?][5]string {
	{"173.743134", "75.464801", "-119.180200", "17.017254", "m"},
	{"-87.223949", "-16.308497", "-158.192364", "-8.633348", "m"},
	{"105.976613", "33.829054", "-121.514528", "-69.462768", "m"},
	{"122.388401", "75.595786", "1.756219", "-50.112840", "ft"},
	{"-133.437520", "-42.905478", "19.798117", "26.751090", "ft"},
	{"-50.842380", "65.312781", "-59.572909", "-0.958814", "ft"},
	{"-95.999010", "-2.556336", "137.294960", "17.171747", "ft"},
	{"134.824746", "50.638431", "14.772715", "36.940337", "ft"},
	{"-57.580685", "-76.062147", "168.645592", "48.871489", "ft"},
	{"-57.580685", "-76.062147", "49.935356", "84.593918", "ft"},
	{"-86.697229", "32.728730", "154.738295", "-69.191448", "ft"},
	{"-149.479745", "27.299561", "-24.105409", "0.811692", "ft"},
	{"-35.500746", "75.955491", "25.905228", "-13.955277", "ft"},
	{"137.819820", "79.482613", "-99.624992", "19.128002", "ft"},
	{"103.810700", "80.188313", "-131.916647", "-27.416059", "ft"},
	{"114.832433", "-41.036467", "-118.961808", "-10.404335", "ft"},
	{"-83.570491", "-63.031784", "103.817348", "73.199191", "ft"},
	{"0.031896", "-54.757020", "117.879765", "66.984176", "ft"},
	{"156.471422", "-66.932171", "-171.736295", "-21.428999", "ft"},
	{"156.471422", "-66.932171", "-40.637047", "18.555204", "ft"},
	{"57.347816", "-73.771439", "-34.385561", "58.879734", "ft"},
	{"24.394211", "-82.880234", "-51.414582", "-14.204285", "ft"},
	{"24.394211", "-82.880234", "-83.371851", "-5.709062", "ft"},
	{"141.718653", "-51.127495", "145.870481", "75.638707", "ft"},
	{"172.125265", "74.163238", "-40.854676", "-42.322040", "m"},
	{"-104.144833", "13.850303", "78.966373", "-43.814035", "ft"},
	{"122.079886", "-64.592971", "-103.271867", "-34.011901", "ft"},
	{"3.946676", "-52.725662", "-162.543320", "66.189912", "ft"},
	{"90.960483", "24.563421", "143.340266", "65.209218", "ft"},
	{"-36.087431", "-9.204073", "165.821123", "34.791123", "ft"},
	{"-95.483485", "-43.000075", "88.267480", "-5.904856", "ft"},
	{"-98.357014", "-79.203438", "-19.523740", "2.656322", "ft"},
	{"-58.301435", "-13.505336", "-149.770156", "36.914023", "ft"},
	{"-1.524697", "-53.156754", "-155.611057", "-2.632312", "m"},
	{"-51.613480", "54.667515", "-69.265525", "77.042102", "m"},
	{"-101.647648", "-22.319546", "-176.606769", "69.973206", "ft"},
	{"-171.584899", "20.211620", "-0.162069", "-9.514746", "ft"},
	{"-133.755883", "-11.798169", "-11.415809", "-69.299261", "ft"},
	{"-110.265371", "81.893775", "92.371773", "-69.714919", "ft"},
	{"149.774841", "-56.931042", "111.719454", "12.804626", "ft"},
	{"46.719438", "-17.976410", "-107.643920", "-54.274982", "m"},
	{"176.579369", "13.151287", "-21.770144", "61.791079", "m"},
}

section_parity :: proc(g: ^Gen) {
	g_cmd(g, "FLUSHALL")
	for pair, i in ROUNDING_PAIRS {
		key := tp("round", i)
		g_cmd(g, "GEOADD", key, pair[0], pair[1], "a", pair[2], pair[3], "b")
		g_cmd(g, "GEODIST", key, "a", "b", pair[4])
		g_cmd(g, "GEOSEARCH", key, "FROMMEMBER", "a", "BYRADIUS", "25000", "km", "ASC", "WITHDIST")
		g_cmd(g, "GEORADIUSBYMEMBER", key, "a", "100000000", pair[4], "WITHDIST", "ASC")
		g_cmd(g, "GEOSEARCHSTORE", tp(key, "d"), key, "FROMMEMBER", "a", "BYRADIUS", "25000", "km", "STOREDIST")
		g_cmd(g, "ZRANGE", tp(key, "d"), "0", "-1", "WITHSCORES")
	}
	g_cmd(g, "GEOADD", "rep", "13.361389", "38.115556", "a", "15.087269", "37.502669", "b")
	repeated := [?][]string{
		{"FROMMEMBER", "a", "FROMMEMBER", "b", "BYRADIUS", "500", "km"},
		{"FROMLONLAT", "15", "37", "FROMLONLAT", "13", "38", "BYRADIUS", "10", "km"},
		{"FROMMEMBER", "a", "BYRADIUS", "1", "km", "BYRADIUS", "500", "km"},
		{"FROMMEMBER", "a", "BYBOX", "1", "1", "km", "BYBOX", "500", "500", "km"},
		{"FROMMEMBER", "nosuch", "FROMMEMBER", "a", "BYRADIUS", "500", "km"},
		{"FROMMEMBER", "a", "FROMMEMBER", "nosuch", "BYRADIUS", "500", "km"},
		{"FROMLONLAT", "200", "37", "FROMLONLAT", "13", "38", "BYRADIUS", "10", "km"},
		{"FROMMEMBER", "a", "BYRADIUS", "-1", "km", "BYRADIUS", "500", "km"},
		{"FROMMEMBER", "a", "BYRADIUS", "1", "xx", "BYRADIUS", "500", "km"},
		{"FROMMEMBER", "a", "BYBOX", "1", "1", "km", "BYRADIUS", "500", "km"},
		{"FROMMEMBER", "a", "FROMLONLAT", "13", "38", "BYRADIUS", "500", "km"},
		{"FROMLONLAT", "13", "38", "FROMMEMBER", "a", "BYRADIUS", "500", "km"},
		{"FROMMEMBER", "a", "BYRADIUS", "500", "km", "BYBOX", "1", "1", "km"},
		{"FROMMEMBER", "a", "BYRADIUS", "1", "km", "FROMMEMBER", "b", "BYRADIUS", "500", "km", "WITHDIST"},
		{"FROMMEMBER", "a", "FROMMEMBER", "b", "BYRADIUS", "500", "km", "COUNT", "1", "COUNT", "2", "ASC", "DESC"},
	}
	for options in repeated {
		for key in ([2]string{"rep", "nokey"}) {
			a := make([dynamic]string, context.temp_allocator)
			append(&a, "GEOSEARCH", key)
			append(&a, ..options)
			g_cmds(g, a[:])
			b := make([dynamic]string, context.temp_allocator)
			append(&b, "GEOSEARCHSTORE", "repd", key)
			append(&b, ..options)
			g_cmds(g, b[:])
			g_cmd(g, "ZRANGE", "repd", "0", "-1", "WITHSCORES")
		}
	}
	g_cmd(g, "GEOSEARCHSTORE", "repd", "rep", "FROMMEMBER", "a", "BYBOX", "1", "1", "km", "BYBOX", "500", "500", "km", "STOREDIST")
	g_cmd(g, "ZRANGE", "repd", "0", "-1", "WITHSCORES")
	g_cmd(g, "FLUSHALL")
}

run_gen :: proc(dir: string) -> bool {
	g := Gen {
		buf = make([dynamic]u8),
		rng = Rng{s = 0x6E0_5EED},
	}
	for proto in ([?]string{"2", "3"}) {
		g_cmd(&g, "HELLO", proto)
		section_basic(&g)
		section_parity(&g)
		section_random(&g, 9000 if proto == "2" else 3000)
		free_all(context.temp_allocator)
	}
	g_cmd(&g, "HELLO", "2")
	path := fmt.tprintf("%s/script.resp", dir)
	if err := os.write_entire_file(path, g.buf[:]); err != nil {
		fmt.eprintln("cannot write", path)
		return false
	}
	fmt.printfln("generated %d commands, %d bytes", g.n, len(g.buf))
	delete(g.buf)
	return true
}
