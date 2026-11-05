package geo

import zt "../zsettype"

Error :: enum u8 {
	None,
	Syntax,
	Not_Float,
	Invalid_Pair,
	Unit,
	Need_Radius,
	Need_Width,
	Need_Height,
	Radius_Negative,
	Box_Negative,
	Not_Integer,
	Count_Positive,
	Member,
	Store_With,
	Searchstore_With,
	Origin,
	Shape,
	Any_Count,
}

ERROR_TEXT := [Error]string {
	.None             = "",
	.Syntax           = "ERR syntax error",
	.Not_Float        = "ERR value is not a valid float",
	.Invalid_Pair     = "ERR invalid longitude,latitude pair ",
	.Unit             = "ERR unsupported unit provided. please use M, KM, FT, MI",
	.Need_Radius      = "ERR need numeric radius",
	.Need_Width       = "ERR need numeric width",
	.Need_Height      = "ERR need numeric height",
	.Radius_Negative  = "ERR radius cannot be negative",
	.Box_Negative     = "ERR height or width cannot be negative",
	.Not_Integer      = "ERR value is not an integer or out of range",
	.Count_Positive   = "ERR COUNT must be > 0",
	.Member           = "ERR could not decode requested zset member",
	.Store_With       = "ERR STORE option in GEORADIUS is not compatible with WITHDIST, WITHHASH and WITHCOORD options",
	.Searchstore_With = "ERR GEOSEARCHSTORE is not compatible with WITHDIST, WITHHASH and WITHCOORD options",
	.Origin           = "ERR exactly one of FROMMEMBER or FROMLONLAT can be specified for ",
	.Shape            = "ERR exactly one of BYRADIUS and BYBOX can be specified for ",
	.Any_Count        = "ERR the ANY argument requires COUNT argument",
}

ERROR_TEXT_MAX :: 1024

Request_Flag :: enum u8 {
	Coords,
	Member,
	No_Store,
	Search,
	Search_Store,
}

Request_Flags :: bit_set[Request_Flag;u8]

Request :: struct {
	shape:      Shape,
	sort:       Sort,
	count:      int,
	any:        bool,
	with_dist:  bool,
	with_hash:  bool,
	with_coord: bool,
	store:      bool,
	store_key:  []u8,
	store_dist: bool,
	pair:       [2]f64,
}

Add_Options :: struct {
	nx:    bool,
	xx:    bool,
	ch:    bool,
	first: int,
}

@(private = "file")
word_is :: proc "contextless" (a: []u8, word: string) -> bool {
	if len(a) != len(word) {
		return false
	}
	for i in 0 ..< len(a) {
		c := a[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != word[i] {
			return false
		}
	}
	return true
}

@(private = "file")
append_text :: proc "contextless" (buf: []u8, at: int, s: []u8) -> int {
	n := min(len(s), len(buf) - at)
	for i in 0 ..< n {
		buf[at + i] = s[i]
	}
	return at + n
}

error_text :: proc "contextless" (buf: []u8, err: Error, pair: [2]f64, name: []u8) -> []u8 {
	pos := append_text(buf, 0, transmute([]u8)ERROR_TEXT[err])
	#partial switch err {
	case .Invalid_Pair:
		pos += format_f6(buf[pos:], pair[0])
		pos = append_text(buf, pos, []u8{','})
		pos += format_f6(buf[pos:], pair[1])
	case .Origin, .Shape:
		pos = append_text(buf, pos, name)
	}
	return buf[:pos]
}

unit_to_meters :: proc "contextless" (unit: []u8) -> (f64, bool) {
	if word_is(unit, "m") {
		return 1, true
	}
	if word_is(unit, "km") {
		return 1000, true
	}
	if word_is(unit, "ft") {
		return 0.3048, true
	}
	if word_is(unit, "mi") {
		return 1609.34, true
	}
	return 0, false
}

parse_long_lat :: proc "contextless" (lon_arg, lat_arg: []u8) -> (xy: [2]f64, err: Error) {
	ok: bool
	xy[0], ok = zt.parse_score(lon_arg)
	if !ok {
		return xy, .Not_Float
	}
	xy[1], ok = zt.parse_score(lat_arg)
	if !ok {
		return xy, .Not_Float
	}
	if xy[0] < LONG_MIN || xy[0] > LONG_MAX || xy[1] < LAT_MIN || xy[1] > LAT_MAX {
		return xy, .Invalid_Pair
	}
	return xy, .None
}

score_of :: proc "contextless" (xy: [2]f64) -> f64 {
	hash, _ := encode_wgs84(xy[0], xy[1], STEP_MAX)
	return f64(align52(hash))
}

parse_add :: proc "contextless" (argv: [][]u8) -> (o: Add_Options, err: Error) {
	i := 2
	for i < len(argv) {
		if word_is(argv[i], "nx") {
			o.nx = true
		} else if word_is(argv[i], "xx") {
			o.xx = true
		} else if word_is(argv[i], "ch") {
			o.ch = true
		} else {
			break
		}
		i += 1
	}
	o.first = i
	left := len(argv) - i
	if left == 0 || left % 3 != 0 || (o.nx && o.xx) {
		return o, .Syntax
	}
	return o, .None
}

@(private = "file")
parse_distance :: proc "contextless" (number, unit: []u8, shape: ^Shape) -> Error {
	value, ok := zt.parse_score(number)
	if !ok {
		return .Need_Radius
	}
	if value < 0 {
		return .Radius_Negative
	}
	shape.radius = value
	conversion, known := unit_to_meters(unit)
	if !known {
		return .Unit
	}
	shape.conversion = conversion
	shape.type = .Circular
	return .None
}

@(private = "file")
parse_box :: proc "contextless" (width, height, unit: []u8, shape: ^Shape) -> Error {
	w, wok := zt.parse_score(width)
	if !wok {
		return .Need_Width
	}
	h, hok := zt.parse_score(height)
	if !hok {
		return .Need_Height
	}
	if w < 0 || h < 0 {
		return .Box_Negative
	}
	shape.width = w
	shape.height = h
	conversion, known := unit_to_meters(unit)
	if !known {
		return .Unit
	}
	shape.conversion = conversion
	shape.type = .Rectangle
	return .None
}

member_xy :: proc(z: zt.Zset, member: []u8) -> (xy: [2]f64, ok: bool) {
	score: f64
	score, ok = zt.score(z, member)
	if !ok {
		return
	}
	return decode_score(score)
}

parse_request :: proc(argv: [][]u8, src_index: int, flags: Request_Flags, z: zt.Zset) -> (req: Request, err: Error) {
	base := src_index + 1
	if .Coords in flags {
		base = 6
		req.shape.xy, err = parse_long_lat(argv[2], argv[3])
		if err != .None {
			req.pair = req.shape.xy
			return
		}
		if err = parse_distance(argv[4], argv[5], &req.shape); err != .None {
			return
		}
	} else if .Member in flags {
		base = 5
		if z != nil {
			ok: bool
			req.shape.xy, ok = member_xy(z, argv[2])
			if !ok {
				return req, .Member
			}
			if err = parse_distance(argv[3], argv[4], &req.shape); err != .None {
				return
			}
		}
	}
	searching := .Search in flags
	can_store := !searching && .No_Store not_in flags
	from_member, from_lonlat, by_radius, by_box := false, false, false, false
	for i := base; i < len(argv); i += 1 {
		arg := argv[i]
		left := len(argv) - i
		if word_is(arg, "withdist") {
			req.with_dist = true
		} else if word_is(arg, "withhash") {
			req.with_hash = true
		} else if word_is(arg, "withcoord") {
			req.with_coord = true
		} else if word_is(arg, "any") {
			req.any = true
		} else if word_is(arg, "asc") {
			req.sort = .Asc
		} else if word_is(arg, "desc") {
			req.sort = .Desc
		} else if word_is(arg, "count") && left > 1 {
			n, ok := zt.parse_long(argv[i + 1])
			if !ok {
				return req, .Not_Integer
			}
			if n <= 0 {
				return req, .Count_Positive
			}
			req.count = int(n)
			i += 1
		} else if can_store && (word_is(arg, "store") || word_is(arg, "storedist")) && left > 1 {
			req.store = true
			req.store_key = argv[i + 1]
			req.store_dist = word_is(arg, "storedist")
			i += 1
		} else if .Search_Store in flags && word_is(arg, "storedist") {
			req.store_dist = true
		} else if searching && word_is(arg, "frommember") && left > 1 && !from_lonlat {
			if z != nil {
				ok: bool
				req.shape.xy, ok = member_xy(z, argv[i + 1])
				if !ok {
					return req, .Member
				}
			}
			from_member = true
			i += 1
		} else if searching && word_is(arg, "fromlonlat") && left > 2 && !from_member {
			req.shape.xy, err = parse_long_lat(argv[i + 1], argv[i + 2])
			if err != .None {
				req.pair = req.shape.xy
				return
			}
			from_lonlat = true
			i += 2
		} else if searching && word_is(arg, "byradius") && left > 2 && !by_box {
			if err = parse_distance(argv[i + 1], argv[i + 2], &req.shape); err != .None {
				return
			}
			by_radius = true
			i += 2
		} else if searching && word_is(arg, "bybox") && left > 3 && !by_radius {
			if err = parse_box(argv[i + 1], argv[i + 2], argv[i + 3], &req.shape); err != .None {
				return
			}
			by_box = true
			i += 3
		} else {
			return req, .Syntax
		}
	}
	if .Search_Store in flags {
		req.store = true
		req.store_key = argv[1]
	}
	if req.store && (req.with_dist || req.with_hash || req.with_coord) {
		return req, .Searchstore_With if .Search_Store in flags else .Store_With
	}
	if searching && from_member == from_lonlat {
		return req, .Origin
	}
	if searching && by_radius == by_box {
		return req, .Shape
	}
	if req.any && req.count == 0 {
		return req, .Any_Count
	}
	return req, .None
}

run :: proc(z: zt.Zset, req: ^Request, out: ^[dynamic]Point, tmp: ^[dynamic]Point) -> int {
	search(z, &req.shape, out, req.count if req.any else 0)
	order := req.sort
	if order == .None && req.count > 0 && !req.any {
		order = .Asc
	}
	sort_points(out[:], order, tmp)
	if req.count > 0 && req.count < len(out) {
		return req.count
	}
	return len(out)
}
