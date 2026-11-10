package vmath

import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:testing"

Search_Spec :: struct {
	seed:  u64,
	kind:  u8,
	bits:  []u64,
	axis:  int,
	value: u64,
	fill:  bool,
}

Search_Doc :: struct {
	key:  string,
	spec: Search_Spec,
}

Search_Set :: struct {
	index:     string,
	group:     string,
	elem:      Elem,
	metric:    Metric,
	dim:       int,
	seeded:    int,
	seed_base: u64,
	kinds:     int,
	docs:      []Search_Doc,
}

Search_Op :: enum u8 {
	Knn,
	Agg,
}

Search_Case :: struct {
	id:      int,
	section: string,
	set:     int,
	op:      Search_Op,
	query:   Search_Spec,
	hash:    u64,
	reply:   string,
}

Search_Built :: struct {
	arena: Arena,
	keys:  []string,
	ready: bool,
}

search_elem_bits :: proc(r: ^Rng, elem: Elem, kind: u8) -> u64 {
	x := rng_next(r)
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

search_blob :: proc(spec: Search_Spec, elem: Elem, dim: int, allocator := context.temp_allocator) -> []u8 {
	size := elem_size(elem)
	out := make([]u8, dim * size, allocator)
	r: Rng
	rng_seed(&r, spec.seed)
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
			b = search_elem_bits(&r, elem, spec.kind)
		}
		for j in 0 ..< size {
			out[i * size + j] = u8(b >> uint(8 * j))
		}
	}
	return out
}

search_build :: proc(t: ^testing.T, s: Search_Set, b: ^Search_Built) {
	if b.ready {
		return
	}
	testing.expect_value(t, arena_init(&b.arena, s.elem, s.metric, s.dim, context.allocator, s.seeded + len(s.docs), .Search), nil)
	keys := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< s.seeded {
		spec := Search_Spec{seed = s.seed_base + u64(i), kind = u8(i % s.kinds)}
		_, err := arena_insert_blob(&b.arena, search_blob(spec, s.elem, s.dim))
		testing.expect_value(t, err, nil)
		append(&keys, strings.concatenate({"d", strconv.write_int(make([]u8, 24, context.temp_allocator), i64(i), 10)}, context.temp_allocator))
	}
	for d in s.docs {
		_, err := arena_insert_blob(&b.arena, search_blob(d.spec, s.elem, s.dim))
		testing.expect_value(t, err, nil)
		append(&keys, d.key)
	}
	b.keys = keys[:]
	b.ready = true
}

search_slot :: proc(b: ^Search_Built, key: string) -> u32 {
	for k, i in b.keys {
		if k == key {
			return u32(i)
		}
	}
	return NIL_SLOT
}

resp_bulk :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '$')
	strings.write_int(sb, len(s))
	strings.write_string(sb, "\r\n")
	strings.write_string(sb, s)
	strings.write_string(sb, "\r\n")
}

resp_head :: proc(sb: ^strings.Builder, kind: byte, n: int) {
	strings.write_byte(sb, kind)
	strings.write_int(sb, n)
	strings.write_string(sb, "\r\n")
}

search_rebuild :: proc(c: Search_Case, lv: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	switch c.op {
	case .Knn:
		k := (len(lv) - 1) / 3
		resp_head(&sb, '*', 1 + 2 * k)
		resp_head(&sb, ':', strconv.parse_int(lv[0]) or_else -1)
		for i := 1; i + 2 < len(lv); i += 3 {
			resp_bulk(&sb, lv[i])
			resp_head(&sb, '*', 2)
			resp_bulk(&sb, lv[i + 1])
			resp_bulk(&sb, lv[i + 2])
		}
	case .Agg:
		rows := make([dynamic][2]int, context.temp_allocator)
		for i := 1; i + 1 < len(lv); i += 2 {
			if lv[i] == "d" || len(rows) == 0 {
				append(&rows, [2]int{i, i})
			}
			rows[len(rows) - 1][1] = i + 2
		}
		resp_head(&sb, '*', 1 + len(rows))
		resp_head(&sb, ':', strconv.parse_int(lv[0]) or_else -1)
		for r in rows {
			resp_head(&sb, '*', r[1] - r[0])
			for i in r[0] ..< r[1] {
				resp_bulk(&sb, lv[i])
			}
		}
	}
	return strings.to_string(sb)
}

reply_digits_match :: proc(text: string, v: f64) -> bool {
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

chunk_value :: proc(lv: []string, row: int) -> (v: f64, ok: bool) {
	for k in 0 ..= 5 {
		name := lv[row + 4 + 2 * k]
		if len(name) != 2 || name[0] != 'c' || int(name[1] - '0') != k {
			return
		}
		n := strconv.parse_i64(lv[row + 5 + 2 * k]) or_return
		v += f64(n) * math.pow(f64(2), f64(-20 * k))
	}
	return v, true
}

search_check :: proc(t: ^testing.T, c: Search_Case, s: Search_Set, b: ^Search_Built) -> (rows: int, good: bool) {
	lv := strings.split(c.reply, "|", context.temp_allocator)
	if fnv1a64(transmute([]u8)search_rebuild(c, lv)) != c.hash {
		return 0, false
	}
	a := &b.arena
	buf, _ := query_alloc(a, context.temp_allocator)
	q, ok := query_encode_blob(a, search_blob(c.query, s.elem, s.dim), buf)
	if !ok {
		return 0, false
	}
	prefix := strings.concatenate({s.index, ":"}, context.temp_allocator)
	good = true
	switch c.op {
	case .Knn:
		for i := 1; i + 2 < len(lv); i += 3 {
			slot := search_slot(b, strings.trim_prefix(lv[i], prefix))
			rows += 1
			if slot == NIL_SLOT {
				good = false
				continue
			}
			d := arena_query_score(a, q, slot)
			if !reply_digits_match(lv[i + 2], d) {
				log.infof("case %d row %s: reply %s, computed %v (bits %x)", c.id, lv[i], lv[i + 2], d, transmute(u64)d)
				good = false
			}
		}
	case .Agg:
		for i := 1; i + 3 < len(lv); i += 16 {
			slot := search_slot(b, strings.trim_prefix(lv[i + 3], prefix))
			rows += 1
			if slot == NIL_SLOT {
				good = false
				continue
			}
			d := arena_query_score(a, q, slot)
			if !reply_digits_match(lv[i + 1], d) {
				good = false
			}
			if exact, eok := chunk_value(lv, i); eok && !math.is_nan(d) && !math.is_inf(d) && transmute(u64)exact != transmute(u64)d {
				good = false
			}
		}
	}
	return
}

search_probe_run :: proc(t: ^testing.T, table: []Search_Case) -> (cases: int, rows: int) {
	built := make([]Search_Built, len(SEARCH_SETS), context.temp_allocator)
	for c in table {
		s := SEARCH_SETS[c.set]
		search_build(t, s, &built[c.set])
		n, ok := search_check(t, c, s, &built[c.set])
		testing.expectf(t, ok, "search probe case %d (%s %v %s %v dim %d) differs from the reference", c.id, c.section, s.elem, metric_name(s.metric), c.op, s.dim)
		cases += 1
		rows += n
	}
	for &b in built {
		if b.ready {
			arena_destroy(&b.arena)
		}
	}
	return
}

search_probe_levels :: proc() -> []Level {
	out := make([dynamic]Level, context.temp_allocator)
	cpu := cpu_detect()
	for level in Level {
		if level_supported(level, cpu) {
			append(&out, level)
		}
	}
	return out[:]
}

search_probe_all_levels :: proc(t: ^testing.T, table: []Search_Case) -> (cases: int, rows: int) {
	saved := kernels.level
	defer use_level(saved)
	for level in search_probe_levels() {
		use_level(level)
		cases, rows = search_probe_run(t, table)
		free_all(context.temp_allocator)
	}
	return
}

@(test)
search_probe_table_is_complete :: proc(t: ^testing.T) {
	total := len(SEARCH_CASES_F32) + len(SEARCH_CASES_HALF) + len(SEARCH_CASES_F64) + len(SEARCH_CASES_INT) + len(SEARCH_CASES_SPECIAL) + len(SEARCH_CASES_TIES) + len(SEARCH_CASES_READER)
	testing.expect_value(t, total, SEARCH_PROBE_CASE_COUNT)
	testing.expect_value(t, SEARCH_PROBE_DIGEST, PROBE_DIGEST)
	testing.expect_value(t, SEARCH_PROBE_IMAGE, PROBE_IMAGE)
	testing.expect_value(t, SEARCH_PROBE_CAPTURED_ON, "2026-11-06")
}

@(test)
search_probe_float32 :: proc(t: ^testing.T) {
	cases, rows := search_probe_all_levels(t, SEARCH_CASES_F32[:])
	testing.expect_value(t, cases, 390)
	testing.expect_value(t, rows, 4810)
}

@(test)
search_probe_half :: proc(t: ^testing.T) {
	cases, rows := search_probe_all_levels(t, SEARCH_CASES_HALF[:])
	testing.expect_value(t, cases, 780)
	testing.expect_value(t, rows, 9620)
}

@(test)
search_probe_float64 :: proc(t: ^testing.T) {
	cases, rows := search_probe_all_levels(t, SEARCH_CASES_F64[:])
	testing.expect_value(t, cases, 390)
	testing.expect_value(t, rows, 4810)
}

@(test)
search_probe_integer :: proc(t: ^testing.T) {
	cases, rows := search_probe_all_levels(t, SEARCH_CASES_INT[:])
	testing.expect_value(t, cases, 432)
	testing.expect_value(t, rows, 6912)
}

@(test)
search_probe_special :: proc(t: ^testing.T) {
	cases, rows := search_probe_all_levels(t, SEARCH_CASES_SPECIAL[:])
	testing.expect_value(t, cases, 60)
	testing.expect_value(t, rows, 552)
}

@(test)
search_probe_ties :: proc(t: ^testing.T) {
	cases, rows := search_probe_all_levels(t, SEARCH_CASES_TIES[:])
	testing.expect_value(t, cases, 48)
	testing.expect_value(t, rows, 320)
}

@(test)
search_probe_reader :: proc(t: ^testing.T) {
	cases, rows := search_probe_all_levels(t, SEARCH_CASES_READER[:])
	testing.expect_value(t, cases, 83)
	testing.expect(t, rows > 0)
}
