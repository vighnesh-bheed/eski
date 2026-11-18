package ftindex

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import ftq "../ftquery"
import "../geo"
import "../retrieve"

Geo_Point :: struct {
	lon, lat: f64,
}

geo_parse_point :: proc(value: string) -> (Geo_Point, string) {
	split := -1
	for ch, i in transmute([]u8)value {
		if ch == ',' || ch == ' ' {
			split = i
			break
		}
	}
	if split < 0 {
		return {}, "SEARCH_PARSE_ARGS Invalid geo string: missing separator"
	}
	parts := [2]string{value[:split], value[split+1:]}
	coordinates: [2]f64
	for component, i in parts {
		raw := strings.trim_space(component)
		n, ok := number_parse(raw)
		if math.is_inf(n) || strings.equal_fold(raw, "nan") {
			return {}, "SEARCH_PARSE_ARGS Geo coordinates must be finite"
		}
		if !ok {
			message := "cannot parse float from empty string" if raw == "" else "invalid float literal"
			return {}, fmt.tprintf("SEARCH_PARSE_ARGS Invalid geo string %q: %s", component, message)
		}
		coordinates[i] = n
	}
	lon, lat := coordinates[0], coordinates[1]
	if lon < -180 || lon > 180 || lat < -ftq.GEO_LAT_LIMIT || lat > ftq.GEO_LAT_LIMIT {
		return {}, fmt.tprintf("SEARCH_GEO_COORDINATES_INVALID Invalid geo coordinates: %.6f, %.6f", lon, lat)
	}
	return {lon, lat}, ""
}

GEO_UNIT_METRES := [ftq.Unit]f64{.M=1, .Km=1000, .Mi=1609.34, .Ft=0.3048}

geo_node :: proc(b: ^Builder, n: ^ftq.Node) -> Built {
	if n.field < 0 || n.field >= len(b.ix.slots) {
		return NONE_BUILT
	}
	location := b.ix.slots[n.field].locations
	if len(location) == 0 {
		return NONE_BUILT
	}
	docs := make([dynamic]u32, b.a)
	radius := n.radius * GEO_UNIT_METRES[n.unit]
	for id, point in location {
		if !check_deadline(b) {
			return NONE_BUILT
		}
		if geo.distance(n.lon, n.lat, point.lon, point.lat) <= radius {
			append(&docs, id)
			continue
		}
		for extra in b.ix.slots[n.field].extra_locations[id] {
			if !check_deadline(b) {
				return NONE_BUILT
			}
			if geo.distance(n.lon, n.lat, extra.lon, extra.lat) <= radius {
				append(&docs, id)
				break
			}
		}
	}
	if len(docs) == 0 {
		return NONE_BUILT
	}
	slice.sort(docs[:])
	cursor := new(retrieve.Array_Cursor, b.a)
	retrieve.array_cursor_init(cursor, docs[:], b.deleted, value_filter_leaf(b))
	return Built{cursor = cursor}
}
