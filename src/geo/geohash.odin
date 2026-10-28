package geo

STEP_MAX :: 26

LAT_MIN :: -85.05112878

LAT_MAX :: 85.05112878

LONG_MIN :: -180.0

LONG_MAX :: 180.0

GEO_ALPHABET :: "0123456789bcdefghjkmnpqrstuvwxyz"

Hash_Bits :: struct {
	bits: u64,
	step: u8,
}

Range :: struct {
	min: f64,
	max: f64,
}

Area :: struct {
	hash:      Hash_Bits,
	longitude: Range,
	latitude:  Range,
}

Neighbors :: struct {
	north:      Hash_Bits,
	east:       Hash_Bits,
	west:       Hash_Bits,
	south:      Hash_Bits,
	north_east: Hash_Bits,
	south_east: Hash_Bits,
	north_west: Hash_Bits,
	south_west: Hash_Bits,
}

@(private = "file")
EVEN_BITS :: u64(0x5555555555555555)

@(private = "file")
ODD_BITS :: u64(0xAAAAAAAAAAAAAAAA)

@(private = "file")
TWO_POW_63 :: f64(9223372036854775808.0)

hash_is_zero :: #force_inline proc "contextless" (h: Hash_Bits) -> bool {
	return h.bits == 0 && h.step == 0
}

@(private)
range_is_zero :: #force_inline proc "contextless" (r: Range) -> bool {
	return r.min == 0 && r.max == 0
}

@(private = "file")
spread_bits :: #force_inline proc "contextless" (v: u32) -> u64 {
	x := u64(v)
	x = (x | (x << 16)) & 0x0000FFFF0000FFFF
	x = (x | (x << 8)) & 0x00FF00FF00FF00FF
	x = (x | (x << 4)) & 0x0F0F0F0F0F0F0F0F
	x = (x | (x << 2)) & 0x3333333333333333
	x = (x | (x << 1)) & 0x5555555555555555
	return x
}

@(private = "file")
gather_bits :: #force_inline proc "contextless" (v: u64) -> u32 {
	x := v & EVEN_BITS
	x = (x | (x >> 1)) & 0x3333333333333333
	x = (x | (x >> 2)) & 0x0F0F0F0F0F0F0F0F
	x = (x | (x >> 4)) & 0x00FF00FF00FF00FF
	x = (x | (x >> 8)) & 0x0000FFFF0000FFFF
	x = (x | (x >> 16)) & 0x00000000FFFFFFFF
	return u32(x)
}

interleave64 :: proc "contextless" (xlo: u32, ylo: u32) -> u64 {
	return spread_bits(xlo) | (spread_bits(ylo) << 1)
}

deinterleave64 :: proc "contextless" (interleaved: u64) -> u64 {
	return u64(gather_bits(interleaved)) | (u64(gather_bits(interleaved >> 1)) << 32)
}

coord_ranges :: proc "contextless" () -> (long_range: Range, lat_range: Range) {
	return Range{LONG_MIN, LONG_MAX}, Range{LAT_MIN, LAT_MAX}
}

@(private = "file")
range_usable :: #force_inline proc "contextless" (r: Range) -> bool {
	return !range_is_zero(r) && r.max > r.min
}

@(private = "file")
cell_index :: #force_inline proc "contextless" (v: f64, r: Range, step: u8) -> u32 {
	fraction := (v - r.min) / (r.max - r.min)
	fraction *= f64(u64(1) << step)
	return u32(u64(fraction))
}

encode :: proc "contextless" (long_range, lat_range: Range, longitude, latitude: f64, step: u8) -> (hash: Hash_Bits, ok: bool) {
	if step == 0 || step > 32 || !range_usable(long_range) || !range_usable(lat_range) {
		return
	}
	if !(longitude >= LONG_MIN && longitude <= LONG_MAX && latitude >= LAT_MIN && latitude <= LAT_MAX) {
		return
	}
	if !(longitude >= long_range.min && longitude <= long_range.max && latitude >= lat_range.min && latitude <= lat_range.max) {
		return
	}
	hash.bits = interleave64(cell_index(latitude, lat_range, step), cell_index(longitude, long_range, step))
	hash.step = step
	return hash, true
}

encode_wgs84 :: proc "contextless" (longitude, latitude: f64, step: u8) -> (Hash_Bits, bool) {
	long_range, lat_range := coord_ranges()
	return encode(long_range, lat_range, longitude, latitude, step)
}

decode :: proc "contextless" (long_range, lat_range: Range, hash: Hash_Bits) -> (area: Area, ok: bool) {
	if hash_is_zero(hash) || hash.step > 32 || range_is_zero(long_range) || range_is_zero(lat_range) {
		return
	}
	split := deinterleave64(hash.bits)
	lat_cell := f64(u32(split))
	long_cell := f64(u32(split >> 32))
	cells := f64(u64(1) << hash.step)
	lat_span := lat_range.max - lat_range.min
	long_span := long_range.max - long_range.min
	area.hash = hash
	area.latitude.min = lat_range.min + (lat_cell / cells) * lat_span
	area.latitude.max = lat_range.min + ((lat_cell + 1) / cells) * lat_span
	area.longitude.min = long_range.min + (long_cell / cells) * long_span
	area.longitude.max = long_range.min + ((long_cell + 1) / cells) * long_span
	return area, true
}

decode_wgs84 :: proc "contextless" (hash: Hash_Bits) -> (Area, bool) {
	long_range, lat_range := coord_ranges()
	return decode(long_range, lat_range, hash)
}

area_to_long_lat :: proc "contextless" (area: ^Area) -> (xy: [2]f64) {
	xy[0] = (area.longitude.min + area.longitude.max) / 2
	xy[1] = (area.latitude.min + area.latitude.max) / 2
	xy[0] = clamp(xy[0], LONG_MIN, LONG_MAX)
	xy[1] = clamp(xy[1], LAT_MIN, LAT_MAX)
	return
}

decode_to_long_lat_wgs84 :: proc "contextless" (hash: Hash_Bits) -> (xy: [2]f64, ok: bool) {
	area: Area
	area, ok = decode_wgs84(hash)
	if !ok {
		return
	}
	return area_to_long_lat(&area), true
}

@(private = "file")
shift_axis :: proc "contextless" (hash: ^Hash_Bits, d: int, odd: bool) {
	if d == 0 {
		return
	}
	moving := hash.bits >> 1 if odd else hash.bits
	kept := hash.bits & (EVEN_BITS if odd else ODD_BITS)
	mask := (u32(1) << hash.step) - 1 if hash.step < 32 else max(u32)
	cell := gather_bits(moving)
	cell = (cell + u32(d)) & mask if d > 0 else (cell - u32(-d)) & mask
	spread := spread_bits(cell)
	hash.bits = kept | (spread << 1 if odd else spread)
}

@(private)
move_x :: proc "contextless" (hash: ^Hash_Bits, d: int) {
	shift_axis(hash, d, true)
}

@(private)
move_y :: proc "contextless" (hash: ^Hash_Bits, d: int) {
	shift_axis(hash, d, false)
}

neighbors_of :: proc "contextless" (hash: Hash_Bits) -> (n: Neighbors) {
	n.east = hash
	move_x(&n.east, 1)
	n.west = hash
	move_x(&n.west, -1)
	n.south = hash
	move_y(&n.south, -1)
	n.north = hash
	move_y(&n.north, 1)
	n.north_west = hash
	move_x(&n.north_west, -1)
	move_y(&n.north_west, 1)
	n.north_east = hash
	move_x(&n.north_east, 1)
	move_y(&n.north_east, 1)
	n.south_east = hash
	move_x(&n.south_east, 1)
	move_y(&n.south_east, -1)
	n.south_west = hash
	move_x(&n.south_west, -1)
	move_y(&n.south_west, -1)
	return
}

align52 :: #force_inline proc "contextless" (hash: Hash_Bits) -> u64 {
	return hash.bits << (52 - u64(hash.step) * 2)
}

@(private = "file")
truncate_to_bits :: #force_inline proc "contextless" (x: f64) -> u64 {
	if x >= -TWO_POW_63 && x < TWO_POW_63 {
		return u64(i64(x))
	}
	return u64(1) << 63
}

score_to_bits :: proc "contextless" (score: f64) -> u64 {
	if !(score >= TWO_POW_63) {
		return truncate_to_bits(score)
	}
	return truncate_to_bits(score - TWO_POW_63) ~ (u64(1) << 63)
}

decode_score :: proc "contextless" (score: f64) -> (xy: [2]f64, ok: bool) {
	return decode_to_long_lat_wgs84(Hash_Bits{bits = score_to_bits(score), step = STEP_MAX})
}

geohash_string :: proc "contextless" (score: f64, out: ^[11]u8) -> bool {
	xy, ok := decode_score(score)
	if !ok {
		return false
	}
	hash: Hash_Bits
	hash, ok = encode(Range{-180, 180}, Range{-90, 90}, xy[0], xy[1], STEP_MAX)
	if !ok {
		return false
	}
	alphabet := GEO_ALPHABET
	for i in 0 ..< 11 {
		index: u64 = 0
		if i < 10 {
			index = (hash.bits >> u64(52 - (i + 1) * 5)) & 0x1f
		}
		out[i] = alphabet[index]
	}
	return true
}
