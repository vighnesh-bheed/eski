package flatindex

import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:testing"
import "../vmath"

Probe_Spec :: struct {
	seed:  u64,
	kind:  u8,
	bits:  []u64,
	axis:  int,
	value: u64,
	fill:  bool,
}

Probe_Doc :: struct {
	key:  string,
	spec: Probe_Spec,
}

Probe_Set :: struct {
	name:      string,
	elem:      vmath.Elem,
	metric:    vmath.Metric,
	dim:       int,
	seeded:    int,
	seed_base: u64,
	kinds:     int,
	docs:      []Probe_Doc,
}

Probe_Case :: struct {
	id:      int,
	group:   string,
	set:     int,
	query:   Probe_Spec,
	ordered: bool,
	total:   int,
	reply:   string,
}

Range_Set :: struct {
	name:   string,
	elem:   vmath.Elem,
	metric: vmath.Metric,
	dim:    int,
	docs:   []string,
	query:  string,
}

Range_Case :: struct {
	set:    int,
	radius: string,
	bits:   u64,
	want:   []int,
}

Probe_Row :: struct {
	doc:   int,
	text:  string,
	exact: u64,
	has:   bool,
}

probe_elem_bits :: proc(r: ^vmath.Rng, elem: vmath.Elem, kind: u8) -> u64 {
	x := vmath.rng_next(r)
	#partial switch elem {
	case .F32:
		if kind == 0 {
			return u64(transmute(u32)(f32(i64(x >> 40) - (1 << 23)) / f32(1 << 23)))
		}
		return ((x >> 63) << 31) | ((120 + ((x >> 23) & 7)) << 23) | (x & 0x7FFFFF)
	case .F64:
		if kind == 0 {
			return transmute(u64)(f64(i64(x >> 11) - (1 << 52)) / f64(u64(1) << 52))
		}
		return ((x >> 63) << 63) | ((1016 + ((x >> 52) & 7)) << 52) | (x & ((u64(1) << 52) - 1))
	case .F16:
		return ((x >> 63) << 15) | ((8 + ((x >> 10) & 7)) << 10) | (x & 0x3FF)
	case .BF16:
		return ((x >> 63) << 15) | ((120 + ((x >> 7) & 7)) << 7) | (x & 0x7F)
	case .Int8, .U8:
		return x >> 56
	}
	return 0
}

probe_blob :: proc(spec: Probe_Spec, elem: vmath.Elem, dim: int) -> []u8 {
	size := vmath.elem_size(elem)
	out := make([]u8, dim * size, context.temp_allocator)
	r: vmath.Rng
	vmath.rng_seed(&r, spec.seed)
	for i in 0 ..< dim {
		b: u64
		switch {
		case len(spec.bits) > 0:
			b = spec.bits[i]
		case spec.fill:
			b = spec.value
		case spec.axis > 0:
			b = spec.value if i == spec.axis - 1 else 0
		case:
			b = probe_elem_bits(&r, elem, spec.kind)
		}
		for j in 0 ..< size {
			out[i * size + j] = u8(b >> uint(8 * j))
		}
	}
	return out
}

probe_rows :: proc(reply: string) -> []Probe_Row {
	rows := make([dynamic]Probe_Row, context.temp_allocator)
	for part in strings.split(reply, " ", context.temp_allocator) {
		f := strings.split(part, ",", context.temp_allocator)
		row := Probe_Row{doc = strconv.parse_int(f[0]) or_else -1, text = f[1]}
		if len(f) > 2 {
			row.exact, row.has = strconv.parse_u64_of_base(f[2], 16)
		}
		append(&rows, row)
	}
	return rows[:]
}

digits_match :: proc(text: string, v: f64) -> bool {
	bits := transmute(u64)v
	switch text {
	case "nan", "-nan":
		return math.is_nan(v) && (bits >> 63 == 1) == (text[0] == '-')
	case "inf":
		return v == math.inf_f64(1)
	case "-inf":
		return v == math.inf_f64(-1)
	}
	y, ok := strconv.parse_f64(text)
	if !ok || math.is_nan(v) || math.is_inf(v) {
		return false
	}
	buf: [64]u8
	z, zok := strconv.parse_f64(strconv.write_float(buf[:], v, 'e', 11, 64))
	return zok && z == y
}

probe_build :: proc(t: ^testing.T, s: Probe_Set, ix: ^Index) {
	spec := spec_default(s.elem, s.metric, s.dim)
	spec.block_size = 4
	testing.expect_value(t, init(ix, spec, context.allocator), Error.None)
	id: u32 = 1
	for i in 0 ..< s.seeded {
		_, err := add(ix, id, probe_blob(Probe_Spec{seed = s.seed_base + u64(i), kind = u8(i % s.kinds)}, s.elem, s.dim))
		testing.expect_value(t, err, Error.None)
		id += 1
	}
	for d in s.docs {
		_, err := add(ix, id, probe_blob(d.spec, s.elem, s.dim))
		testing.expect_value(t, err, Error.None)
		id += 1
	}
}

probe_check :: proc(t: ^testing.T, c: Probe_Case, ix: ^Index) -> (rows: int, good: bool) {
	s := PROBE_SETS[c.set]
	qy: Query
	if !testing.expect_value(t, query_for(&qy, ix, probe_blob(c.query, s.elem, s.dim), context.temp_allocator), Error.None) {
		return 0, false
	}
	want := probe_rows(c.reply)
	out := make([dynamic]Hit, context.temp_allocator)
	knn(ix, &qy, c.total, &out)
	if len(out) != len(want) || c.total != len(want) {
		log.infof("case %d: %d hits for %d rows", c.id, len(out), len(want))
		return 0, false
	}
	good = true
	for row, i in want {
		h: Hit
		found := false
		if c.ordered {
			h = out[i]
			found = int(h.id) == row.doc + 1
		} else {
			for x in out {
				if int(x.id) == row.doc + 1 {
					h = x
					found = true
				}
			}
		}
		if !found {
			log.infof("case %d row %d: doc %d not at its place (got %v)", c.id, i, row.doc, out[i])
			good = false
			continue
		}
		if !digits_match(row.text, h.dist) {
			log.infof("case %d row %d: reply %s, computed %v", c.id, i, row.text, h.dist)
			good = false
		}
		if row.has && finite(h.dist) && transmute(u64)h.dist != row.exact {
			log.infof("case %d row %d: exact %x, computed %x", c.id, i, row.exact, transmute(u64)h.dist)
			good = false
		}
		rows += 1
	}
	return
}

probe_run :: proc(t: ^testing.T) -> (cases: int, rows: int, exact: int, ordered: int) {
	built := make([]Index, len(PROBE_SETS))
	ready := make([]bool, len(PROBE_SETS))
	defer delete(built)
	defer delete(ready)
	for c in PROBE_CASES {
		if !ready[c.set] {
			probe_build(t, PROBE_SETS[c.set], &built[c.set])
			ready[c.set] = true
		}
		n, ok := probe_check(t, c, &built[c.set])
		s := PROBE_SETS[c.set]
		testing.expectf(t, ok, "probe case %d (%s %v %s dim %d) differs from the reference", c.id, c.group, s.elem, metric_name(spec_default(s.elem, s.metric, 1)), s.dim)
		cases += 1
		rows += n
		if c.ordered {
			ordered += 1
		}
		for r in probe_rows(c.reply) {
			if r.has {
				exact += 1
			}
		}
		free_all(context.temp_allocator)
	}
	for &ix, i in built {
		if ready[i] {
			destroy(&ix)
		}
	}
	return
}

@(test)
probe_table_header :: proc(t: ^testing.T) {
	testing.expect_value(t, PROBE_DIGEST, "sha256:f245f4c83b84a9e9a0588da1c9456e579455310f0945d5db52cd2ba27f2000cc")
	testing.expect_value(t, PROBE_CAPTURED_ON, "2026-11-06")
	testing.expect_value(t, RANGE_PROBE_CAPTURED_ON, "2026-11-07")
}

@(test)
probe_knn_matches_reference :: proc(t: ^testing.T) {
	saved := vmath.search_kernels.level
	defer vmath.use_level(saved)
	for level in supported_levels() {
		vmath.use_level(level)
		cases, rows, exact, ordered := probe_run(t)
		testing.expect_value(t, cases, len(PROBE_CASES))
		log.infof("level %v: %d recorded cases, %d rows, %d exact doubles, %d cases in recorded order", level, cases, rows, exact, ordered)
	}
}

@(test)
probe_range_matches_reference :: proc(t: ^testing.T) {
	built := make([]Index, len(RANGE_SETS))
	defer delete(built)
	for s, i in RANGE_SETS {
		testing.expect_value(t, init(&built[i], spec_default(s.elem, s.metric, s.dim), context.allocator), Error.None)
		for d, j in s.docs {
			_, err := add(&built[i], u32(j + 1), transmute([]u8)d)
			testing.expect_value(t, err, Error.None)
		}
	}
	checked := 0
	for c in RANGE_CASES {
		s := RANGE_SETS[c.set]
		ix := &built[c.set]
		qy: Query
		testing.expect_value(t, query_for(&qy, ix, transmute([]u8)s.query, context.temp_allocator), Error.None)
		radius := transmute(f64)c.bits
		if parsed, ok := strconv.parse_f64(c.radius); ok {
			testing.expectf(t, transmute(u64)parsed == c.bits, "radius text %s parses to %x, recorded %x", c.radius, transmute(u64)parsed, c.bits)
		}
		out := make([dynamic]Hit, context.temp_allocator)
		testing.expect_value(t, range_search(ix, &qy, radius, &out, {}, -1, .Id), Error.None)
		got := make([dynamic]int, context.temp_allocator)
		for h in out {
			append(&got, int(h.id) - 1)
		}
		same := len(got) == len(c.want)
		for i in 0 ..< min(len(got), len(c.want)) {
			if got[i] != c.want[i] {
				same = false
			}
		}
		testing.expectf(t, same, "range %s %v %v radius %s: got %v, recorded %v", s.name, s.elem, s.metric, c.radius, got[:], c.want)
		checked += 1
		free_all(context.temp_allocator)
	}
	for &ix in built {
		destroy(&ix)
	}
	log.infof("%d recorded range cases over %d indexes", checked, len(RANGE_SETS))
	testing.expect(t, checked == len(RANGE_CASES) && checked > 700)
}

Contract_Set :: struct {
	name:    string,
	elem:    vmath.Elem,
	metric:  vmath.Metric,
	dim:     int,
	docs:    []string,
	query:   string,
	ordered: bool,
	total:   int,
	reply:   string,
}

remainder_of :: proc(d: f64) -> f64 {
	return (d - math.floor(d * 1000000) / 1000000) * 1000000
}

@(test)
probe_contract_distances :: proc(t: ^testing.T) {
	saved := vmath.search_kernels.level
	defer vmath.use_level(saved)
	for level in supported_levels() {
		vmath.use_level(level)
		rows := 0
		remainders := 0
		ordered := 0
		for s in CONTRACT_SETS {
			spec := spec_default(s.elem, s.metric, s.dim)
			spec.block_size = 4
			ix: Index
			testing.expect_value(t, init(&ix, spec, context.allocator), Error.None)
			for d, j in s.docs {
				_, err := add(&ix, u32(j + 1), transmute([]u8)d)
				testing.expect_value(t, err, Error.None)
			}
			qy: Query
			testing.expect_value(t, query_for(&qy, &ix, transmute([]u8)s.query, context.temp_allocator), Error.None)
			out := make([dynamic]Hit, context.temp_allocator)
			knn(&ix, &qy, 10, &out)
			testing.expectf(t, len(out) == s.total, "%s: %d hits, recorded %d", s.name, len(out), s.total)
			for part, i in strings.split(s.reply, " ", context.temp_allocator) {
				f := strings.split(part, ",", context.temp_allocator)
				doc := strconv.parse_int(f[0]) or_else -1
				h: Hit
				found := false
				if s.ordered && i < len(out) {
					h = out[i]
					found = int(h.id) == doc + 1
				} else {
					for x in out {
						if int(x.id) == doc + 1 {
							h = x
							found = true
						}
					}
				}
				testing.expectf(t, found, "%s %v row %d: doc %d out of place", s.name, level, i, doc)
				testing.expectf(t, digits_match(f[1], h.dist), "%s %v %v %v dim %d doc %d: recorded %s, computed %v", s.name, level, s.elem, s.metric, s.dim, doc, f[1], h.dist)
				if finite(h.dist) && len(f) > 2 && f[2] != "" {
					testing.expectf(t, digits_match(f[2], remainder_of(h.dist)), "%s %v %v %v dim %d doc %d: recorded remainder %s, computed %v", s.name, level, s.elem, s.metric, s.dim, doc, f[2], remainder_of(h.dist))
					remainders += 1
				}
				rows += 1
			}
			if s.ordered {
				ordered += 1
			}
			destroy(&ix)
			free_all(context.temp_allocator)
		}
		log.infof("contract probe at %v: %d indexes, %d rows, %d remainders, %d in recorded order", level, len(CONTRACT_SETS), rows, remainders, ordered)
		testing.expect_value(t, rows, 372)
	}
}
