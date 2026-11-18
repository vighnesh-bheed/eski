package main

import fi "ftindex"
import fq "ftquery"

Search_Legacy_Filter :: struct {
	field: string,
	node: fq.Node,
}

search_legacy_filter :: proc(args: [][]u8, geo: bool) -> (Search_Legacy_Filter, string) {
	n := 5 if geo else 3
	if len(args) < n {
		return {}, "SEARCH_PARSE_ARGS GEOFILTER requires 5 arguments" if geo else "SEARCH_PARSE_ARGS FILTER requires 3 arguments"
	}
	out := Search_Legacy_Filter{field = string(args[0]), node = {kind = .Geo if geo else .Numeric}}
	if geo {
		fields := [?]string{"<lon>", "<lat>", "<radius>"}
		values: [3]f64
		for field, i in fields {
			v, ok := fi.number_parse(string(args[i+1]))
			if !ok {
				return {}, ft_argument_error(field, SEARCH_INVALID_ARGUMENT)
			}
			values[i] = v
		}
		unit, ok := fq.unit_from(string(args[4]))
		if !ok {
			return {}, ft_error("SEARCH_PARSE_ARGS Unknown distance unit ", string(args[4]))
		}
		out.node.lon, out.node.lat, out.node.radius, out.node.unit = values[0], values[1], values[2], unit
		if !(values[0] >= -180 && values[0] <= 180 && values[1] >= -fq.GEO_LAT_LIMIT && values[1] <= fq.GEO_LAT_LIMIT) {
			return {}, "SEARCH_SYNTAX Invalid GeoFilter lat/lon"
		}
		if values[2] <= 0 {
			return {}, "SEARCH_SYNTAX Invalid GeoFilter radius"
		}
	} else {
		for arg, i in args[1:3] {
			s := string(arg)
			open := len(s) > 0 && s[0] == '('
			v, ok := fi.number_parse(s[int(open):])
			if !ok {
				return {}, ft_error("SEARCH_PARSE_ARGS Bad ", "lower" if i == 0 else "upper", " range: ", s)
			}
			if i == 0 {
				out.node.min, out.node.min_open = v, open
			} else {
				out.node.max, out.node.max_open = v, open
			}
		}
	}
	return out, ""
}

search_apply_legacy_filters :: proc(query: ^fq.Query, index: ^fi.Index, filters: []Search_Legacy_Filter) {
	if len(filters) == 0 || query.root == fq.NO_NODE {
		return
	}
	knn := query.root if fq.node_get(query, query.root).kind == .Vector && fq.node_get(query, query.root).vector.kind == .Knn else fq.NO_NODE
	root := query.root
	if knn != fq.NO_NODE {
		root = fq.NO_NODE
		if prior := fq.node_get(query, knn).children; len(prior) != 0 {
			root = prior[0]
		}
	}
	for filter in filters {
		id := fq.node_new(query, filter.node.kind)
		node := fq.node_get(query, id)
		field, found := fi.field_index(index, filter.field)
		node.field = field if found else -1
		node.min, node.max, node.min_open, node.max_open = filter.node.min, filter.node.max, filter.node.min_open, filter.node.max_open
		node.lon, node.lat, node.radius, node.unit = filter.node.lon, filter.node.lat, filter.node.radius, filter.node.unit
		root = fq.make_and(query, root, id)
	}
	if knn == fq.NO_NODE {
		query.root = root
	} else if len(fq.node_get(query, knn).children) == 0 {
		fq.node_add_child(query, knn, root)
	} else {
		fq.node_get(query, knn).children[0] = root
	}
}
