package geo

foreign import libm "system:m"

@(default_calling_convention = "c")
foreign libm {
	@(link_name = "sin")
	c_sin :: proc(x: f64) -> f64 ---
	@(link_name = "cos")
	c_cos :: proc(x: f64) -> f64 ---
	@(link_name = "asin")
	c_asin :: proc(x: f64) -> f64 ---
	@(link_name = "sqrt")
	c_sqrt :: proc(x: f64) -> f64 ---
}

D_R :: f64(0h3F91DF46A2529D39)

EARTH_RADIUS_IN_METERS :: f64(6372797.560856)

MERCATOR_MAX :: f64(20037726.37)

@(private = "file")
POLAR_LATITUDE :: 66.0

@(private = "file")
HIGH_POLAR_LATITUDE :: 80.0

Shape_Type :: enum u8 {
	Circular,
	Rectangle,
}

Shape :: struct {
	type:       Shape_Type,
	xy:         [2]f64,
	conversion: f64,
	bounds:     [4]f64,
	radius:     f64,
	height:     f64,
	width:      f64,
}

Radius :: struct {
	hash:      Hash_Bits,
	area:      Area,
	neighbors: Neighbors,
}

deg_rad :: #force_inline proc "contextless" (ang: f64) -> f64 {
	return ang * D_R
}

rad_deg :: #force_inline proc "contextless" (ang: f64) -> f64 {
	return ang / D_R
}

estimate_steps_by_radius :: proc "contextless" (range_meters_in: f64, lat: f64) -> u8 {
	if range_meters_in == 0 {
		return STEP_MAX
	}
	span := range_meters_in
	step := 1
	for span < MERCATOR_MAX && step <= STEP_MAX + 4 {
		span *= 2
		step += 1
	}
	step -= 2
	if lat > POLAR_LATITUDE || lat < -POLAR_LATITUDE {
		step -= 1
		if lat > HIGH_POLAR_LATITUDE || lat < -HIGH_POLAR_LATITUDE {
			step -= 1
		}
	}
	return u8(clamp(step, 1, STEP_MAX))
}

@(private = "file")
reach_meters :: proc "contextless" (shape: ^Shape) -> (along_lat, along_long: f64) {
	if shape.type == .Circular {
		return shape.radius * shape.conversion, shape.radius * shape.conversion
	}
	return shape.height / 2 * shape.conversion, shape.width / 2 * shape.conversion
}

bounding_box :: proc "contextless" (shape: ^Shape) {
	along_lat, along_long := reach_meters(shape)
	long_r := deg_rad(shape.xy[0])
	lat_r := deg_rad(shape.xy[1])
	lat_delta := along_lat / EARTH_RADIUS_IN_METERS
	widest := lat_r - lat_delta if shape.xy[1] < 0 else lat_r + lat_delta
	long_delta := along_long / EARTH_RADIUS_IN_METERS / c_cos(widest)
	shape.bounds[0] = rad_deg(long_r - long_delta)
	shape.bounds[1] = rad_deg(lat_r - lat_delta)
	shape.bounds[2] = rad_deg(long_r + long_delta)
	shape.bounds[3] = rad_deg(lat_r + lat_delta)
}

@(private = "file")
search_radius_meters :: proc "contextless" (shape: ^Shape) -> f64 {
	if shape.type == .Circular {
		return shape.radius * shape.conversion
	}
	half_w := shape.width / 2
	half_h := shape.height / 2
	return c_sqrt(half_w * half_w + half_h * half_h) * shape.conversion
}

@(private = "file")
cell_area :: proc "contextless" (hash: Hash_Bits) -> Area {
	area, _ := decode_wgs84(hash)
	return area
}

@(private = "file")
center_cell :: proc "contextless" (shape: ^Shape, step: u8) -> (r: Radius) {
	r.hash, _ = encode_wgs84(shape.xy[0], shape.xy[1], step)
	r.neighbors = neighbors_of(r.hash)
	r.area = cell_area(r.hash)
	return
}

@(private = "file")
neighbors_short_of_bounds :: proc "contextless" (r: ^Radius, b: [4]f64) -> bool {
	north := cell_area(r.neighbors.north)
	south := cell_area(r.neighbors.south)
	east := cell_area(r.neighbors.east)
	west := cell_area(r.neighbors.west)
	return north.latitude.max < b[3] || south.latitude.min > b[1] || east.longitude.max < b[2] || west.longitude.min > b[0]
}

calculate_areas :: proc "contextless" (shape: ^Shape) -> (r: Radius) {
	bounding_box(shape)
	step := estimate_steps_by_radius(search_radius_meters(shape), shape.xy[1])
	r = center_cell(shape, step)
	if step > 1 && neighbors_short_of_bounds(&r, shape.bounds) {
		step -= 1
		r = center_cell(shape, step)
	}
	if step < 2 {
		return
	}
	b := shape.bounds
	n := &r.neighbors
	if r.area.latitude.min < b[1] {
		n.south = {}
		n.south_west = {}
		n.south_east = {}
	}
	if r.area.latitude.max > b[3] {
		n.north = {}
		n.north_east = {}
		n.north_west = {}
	}
	if r.area.longitude.min < b[0] {
		n.west = {}
		n.south_west = {}
		n.north_west = {}
	}
	if r.area.longitude.max > b[2] {
		n.east = {}
		n.south_east = {}
		n.north_east = {}
	}
	return
}

lat_distance :: proc "contextless" (lat1d, lat2d: f64) -> f64 {
	return EARTH_RADIUS_IN_METERS * abs(deg_rad(lat2d) - deg_rad(lat1d))
}

distance :: proc "contextless" (lon1d, lat1d, lon2d, lat2d: f64) -> f64 {
	lon1r := deg_rad(lon1d)
	lon2r := deg_rad(lon2d)
	v := c_sin((lon2r - lon1r) / 2)
	if v == 0 {
		return lat_distance(lat1d, lat2d)
	}
	lat1r := deg_rad(lat1d)
	lat2r := deg_rad(lat2d)
	u := c_sin((lat2r - lat1r) / 2)
	a := u * u + c_cos(lat1r) * c_cos(lat2r) * v * v
	return 2.0 * EARTH_RADIUS_IN_METERS * c_asin(c_sqrt(a))
}

distance_if_in_radius :: proc "contextless" (x1, y1, x2, y2, radius: f64) -> (dist: f64, ok: bool) {
	dist = distance(x1, y1, x2, y2)
	if dist > radius {
		return dist, false
	}
	return dist, true
}

distance_if_in_rectangle :: proc "contextless" (width_m, height_m, x1, y1, x2, y2: f64) -> (dist: f64, ok: bool) {
	if lat_distance(y2, y1) > height_m / 2 {
		return 0, false
	}
	if distance(x2, y2, x1, y2) > width_m / 2 {
		return 0, false
	}
	return distance(x1, y1, x2, y2), true
}

within_shape :: proc "contextless" (shape: ^Shape, score: f64) -> (xy: [2]f64, dist: f64, ok: bool) {
	xy, ok = decode_score(score)
	if !ok {
		return
	}
	if shape.type == .Circular {
		dist, ok = distance_if_in_radius(shape.xy[0], shape.xy[1], xy[0], xy[1], shape.radius * shape.conversion)
	} else {
		dist, ok = distance_if_in_rectangle(shape.width * shape.conversion, shape.height * shape.conversion, shape.xy[0], shape.xy[1], xy[0], xy[1])
	}
	return
}
