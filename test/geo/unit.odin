package main

import geo "../../src/geo"
import "core:fmt"
import "core:strconv"

f6 :: proc(v: f64) -> string {
	buf: [400]u8
	n := geo.format_f6(buf[:], v)
	return fmt.tprint(string(buf[:n]))
}

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

run_unit :: proc() -> bool {
	for i in 0 ..< 100000 {
		x := u32(i * 2654435761)
		y := u32(i * 40503 + 7)
		v := geo.interleave64(x, y)
		d := geo.deinterleave64(v)
		check(u32(d) == x && u32(d >> 32) == y, "interleave round trip")
	}
	h, ok := geo.encode_wgs84(-5.6, 42.6, geo.STEP_MAX)
	check(ok, "encode ok")
	out: [11]u8
	geo.geohash_string(f64(geo.align52(h)), &out)
	check(string(out[:]) == "ezs42e44yx0", fmt.tprintf("wikipedia geohash %s", string(out[:])))
	h2, _ := geo.encode_wgs84(-73.9454966, 40.747533, geo.STEP_MAX)
	check(geo.align52(h2) == 1791875804419201, fmt.tprintf("lic market score %d", geo.align52(h2)))
	f6_cases := [?]struct {
		v: f64,
		s: string,
	}{{200, "200.000000"}, {-1e-7, "-0.000000"}, {0.5, "0.500000"}, {1.0000005, "1.000001"}, {1.0000015, "1.000001"}, {0.5000005, "0.500000"}, {2.5, "2.500000"}, {1e20, "100000000000000000000.000000"}, {-180.0000001, "-180.000000"}, {85.05112879, "85.051129"}}
	for c in f6_cases {
		check(f6(c.v) == c.s, fmt.tprintf("format_f6 %v -> %s want %s", c.v, f6(c.v), c.s))
	}
	big := f6(1e300)
	check(len(big) == 301 + 7 && big[:4] == "1000", "format_f6 of 1e300")
	check(human(-73.97334) == "-73.97333999999999321", fmt.tprintf("human %s", human(-73.97334)))
	check(human(0) == "0" && human(10) == "10" && human(0.5) == "0.5", "human small values")
	check(dist(0) == "0.0000" && dist(0.775) == "0.7750" && dist(166274.1516) == "166274.1516" && dist(0.00005) == "0.0001", "distance format")
	check(dist(0.00015) == "0.0002" || dist(0.00015) == "0.0001", "distance rounding")
	r, rok := strconv.parse_f64("6372797.560856")
	check(rok && r == geo.EARTH_RADIUS_IN_METERS, "earth radius constant")
	m, mok := strconv.parse_f64("20037726.37")
	check(mok && m == geo.MERCATOR_MAX, "mercator constant")
	check(geo.estimate_steps_by_radius(0, 0) == 26 && geo.estimate_steps_by_radius(1e9, 0) == 1, "estimate steps edges")
	fmt.printfln("geo unit: %d checks, %d failures", checks, failures)
	return failures == 0
}
