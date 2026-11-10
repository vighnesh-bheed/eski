package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import hn "../../src/hnsw"
import vm "../../src/vmath"

nat :: proc(s: string) -> int {
	v, ok := strconv.parse_i64(s, 10)
	assert(ok && v >= 0)
	return int(v)
}

integer :: proc(s: string) -> i64 {
	v, ok := strconv.parse_i64(s, 10)
	assert(ok)
	return v
}

word :: proc(s: string) -> u64 {
	v, ok := strconv.parse_u64(s, 10)
	assert(ok)
	return v
}

dyadic :: proc(s: string) -> f32 {
	parts := strings.split(s, ":")
	defer delete(parts)
	assert(len(parts) == 2)
	num := integer(parts[0])
	assert(abs(num) <= 1 << 24)
	x := math.ldexp(f32(num), -nat(parts[1]))
	assert(f64(x) == math.ldexp(f64(num), -nat(parts[1])))
	return x
}

dyadic_text :: proc(b: ^strings.Builder, mant: u64, exp: int, negative: bool) {
	m := mant
	e := exp
	if m == 0 {
		strings.write_string(b, "0/1")
		return
	}
	for m % 2 == 0 && e < 0 {
		m /= 2
		e += 1
	}
	if negative {
		strings.write_byte(b, '-')
	}
	if e >= 0 {
		assert(e < 40 && m < 1 << 23)
		fmt.sbprintf(b, "%d/1", m << uint(e))
	} else if -e < 63 {
		fmt.sbprintf(b, "%d/%d", m, u64(1) << uint(-e))
	} else {
		fmt.sbprintf(b, "%d/", m)
		pow2_text(b, -e)
	}
}

pow2_text :: proc(b: ^strings.Builder, k: int) {
	digits := make([dynamic]u8, 1)
	defer delete(digits)
	digits[0] = 1
	for _ in 0 ..< k {
		carry := u8(0)
		for &d in digits {
			v := d * 2 + carry
			d = v % 10
			carry = v / 10
		}
		if carry > 0 {
			append(&digits, carry)
		}
	}
	for i := len(digits) - 1; i >= 0; i -= 1 {
		strings.write_byte(b, '0' + digits[i])
	}
}

exact32 :: proc(b: ^strings.Builder, x: f32) {
	bits := transmute(u32)x
	e := int((bits >> 23) & 0xFF)
	m := u64(bits & 0x7FFFFF)
	assert(e != 0xFF)
	if e == 0 {
		e = 1
	} else {
		m |= 0x800000
	}
	dyadic_text(b, m, e - 150, bits >> 31 != 0)
}

exact64 :: proc(b: ^strings.Builder, x: f64) {
	bits := transmute(u64)x
	e := int((bits >> 52) & 0x7FF)
	m := bits & 0xFFFFFFFFFFFFF
	assert(e != 0x7FF)
	if e == 0 {
		e = 1
	} else {
		m |= 1 << 52
	}
	dyadic_text(b, m, e - 1075, bits >> 63 != 0)
}

dyadics :: proc(fields: []string) -> []f32 {
	xs := make([]f32, len(fields))
	for f, i in fields {
		xs[i] = dyadic(f)
	}
	return xs
}

encode_bin :: proc(xs: []f32, dim: int) -> []u8 {
	bytes := make([]u8, vm.elem_vector_bytes(.Bin, dim))
	assert(vm.encode_normalised(.Bin, xs, bytes) == 0)
	words := vm.u64_view(bytes)
	packed := make([]u64, vm.bin_words(dim))
	defer delete(packed)
	vm.pack_bits(xs, packed)
	assert(len(words) == len(packed))
	for w, i in words {
		assert(w == packed[i])
	}
	return bytes
}

bit :: proc(b: bool) -> int {
	return 1 if b else 0
}

hamming_both :: proc(a, b: []u64) -> u64 {
	h := vm.hamming_ref(a, b)
	assert(vm.kernels.hamming(raw_data(a), raw_data(b), min(len(a), len(b))) == h)
	assert(vm.BASE_KERNELS.hamming(raw_data(a), raw_data(b), min(len(a), len(b))) == h)
	return h
}

write_heap :: proc(b: ^strings.Builder, items: []hn.Candidate) {
	if len(items) == 0 {
		strings.write_byte(b, '-')
		return
	}
	for c, i in items {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		write_cand(b, c)
	}
}

write_cand :: proc(b: ^strings.Builder, c: hn.Candidate) {
	assert(f32(i64(c.dist)) == c.dist)
	fmt.sbprintf(b, "%d:%d", i64(c.dist), c.id)
}

write_contained :: proc(b: ^strings.Builder, v: ^hn.Visited) {
	any := false
	for i in 0 ..< v.cap {
		if hn.visited_contains(v, u32(i)) {
			if any {
				strings.write_byte(b, ',')
			}
			fmt.sbprintf(b, "%d", i)
			any = true
		}
	}
	if !any {
		strings.write_byte(b, '-')
	}
}

candidate :: proc(d, id: string) -> hn.Candidate {
	dist := integer(d)
	assert(abs(dist) < 1 << 24)
	return hn.Candidate{f32(dist), u32(nat(id))}
}

special :: proc(s: string) -> f32 {
	switch s {
	case "inf":
		return math.inf_f32(1)
	case "-inf":
		return math.inf_f32(-1)
	case "nan":
		return math.nan_f32()
	}
	return dyadic(s)
}

encode_token :: proc(s: string) -> f32 {
	switch s {
	case "-0":
		return transmute(f32)u32(0x80000000)
	case "tiny":
		return math.ldexp(f32(1), -80)
	case "huge":
		return math.ldexp(f32(1), 64)
	case "big":
		return math.ldexp(f32(1), 63)
	}
	v := integer(s)
	assert(abs(v) < 1 << 12)
	return f32(v)
}

write_arena :: proc(b: ^strings.Builder, a: ^vm.Arena) {
	fmt.sbprintf(b, "%d:%d:%d:", a.high, a.cap, a.live)
	if a.free == vm.NIL_SLOT {
		strings.write_byte(b, '-')
	} else {
		fmt.sbprintf(b, "%d", a.free)
	}
	strings.write_byte(b, '|')
	at := a.free
	steps := 0
	for at != vm.NIL_SLOT {
		assert(at < a.high && steps <= int(a.high))
		if steps > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, "%d", at)
		at = vm.free_next(a.norms[at])
		steps += 1
	}
	if steps == 0 {
		strings.write_byte(b, '-')
	}
	strings.write_byte(b, '|')
	for i in 0 ..< int(a.high) {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, "%x", transmute(u32)a.norms[i])
	}
	if a.high == 0 {
		strings.write_byte(b, '-')
	}
}

Points :: struct {
	xs: [dynamic][2]i64,
}

Point_Query :: struct {
	pts: ^Points,
	x:   i64,
	y:   i64,
}

points_distance :: proc(ctx: rawptr, a, b: u32) -> f32 {
	p := (^Points)(ctx)
	pa := p.xs[a]
	pb := p.xs[b]
	dx := pa[0] - pb[0]
	dy := pa[1] - pb[1]
	return f32(dx * dx + dy * dy)
}

point_query :: proc(ctx: rawptr, slot: u32) -> f32 {
	q := (^Point_Query)(ctx)
	pa := q.pts.xs[slot]
	dx := pa[0] - q.x
	dy := pa[1] - q.y
	return f32(dx * dx + dy * dy)
}

write_ids :: proc(b: ^strings.Builder, ids: []u32) {
	if len(ids) == 0 {
		strings.write_byte(b, '-')
		return
	}
	for v, i in ids {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, "%d", v)
	}
}

write_index :: proc(b: ^strings.Builder, ix: ^hn.Index, buf: []u32) {
	if ix.entry == hn.NONE {
		strings.write_byte(b, '-')
	} else {
		fmt.sbprintf(b, "%d", ix.entry)
	}
	fmt.sbprintf(b, ":%d:%d:%d:%d|", ix.max_level, ix.live, ix.twins, ix.width)
	at := ix.free_head
	count := 0
	for at != hn.NONE {
		assert(int(at) < ix.slots && count <= ix.slots)
		if count > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, "%d", at)
		next := hn.word_get(ix.links0[int(at) * ix.row:], 0, ix.width)
		at = next == hn.width_none(ix.width) ? hn.NONE : next
		count += 1
	}
	if count == 0 {
		strings.write_byte(b, '-')
	}
	strings.write_byte(b, '|')
	for i in 0 ..< ix.slots {
		slot := u32(i)
		if i > 0 {
			strings.write_byte(b, ';')
		}
		level := ix.levels[slot]
		next := ix.twin_link != nil ? ix.twin_link[slot] : hn.NONE
		fmt.sbprintf(b, "%d:", level)
		if next == hn.NONE {
			strings.write_byte(b, '-')
		} else {
			fmt.sbprintf(b, "%d", next)
		}
		strings.write_byte(b, ':')
		if level == hn.LEVEL_TWIN {
			fmt.sbprintf(b, "%d", hn.twin_prev(ix, slot))
		} else {
			strings.write_byte(b, '-')
		}
		strings.write_byte(b, ':')
		if int(level) <= hn.LEVEL_CAP {
			for l in 0 ..= int(level) {
				if l > 0 {
					strings.write_byte(b, '/')
				}
				write_ids(b, hn.layer_links(ix, slot, l, buf))
			}
		} else {
			strings.write_byte(b, '-')
		}
	}
}

force_level :: proc(ix: ^hn.Index, level: int) {
	ix.rng = 0
	state := u64(0)
	u := hn.rng_uniform(&state)
	lu := math.ln(u)
	assert(lu < 0)
	ix.level_log = lu / (f64(level) + 0.5)
}

main :: proc() {
	assert(len(os.args) == 2)
	input, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	defer delete(input)
	lines := strings.split(string(input), "\n")
	defer delete(lines)
	minh: hn.Min_Heap
	maxh: hn.Max_Heap
	hn.min_heap_init(&minh, context.allocator)
	hn.max_heap_init(&maxh, context.allocator)
	defer hn.min_heap_destroy(&minh)
	defer hn.max_heap_destroy(&maxh)
	heap_max := false
	vis: hn.Visited
	hn.visited_init(&vis, context.allocator)
	defer hn.visited_destroy(&vis)
	arena: vm.Arena
	arena_ready := false
	defer if arena_ready {
		vm.arena_destroy(&arena)
	}
	pts: Points
	defer delete(pts.xs)
	ix: hn.Index
	sc: hn.Scratch
	ix_ready := false
	defer if ix_ready {
		hn.destroy(&ix)
		hn.scratch_destroy(&sc)
	}
	idbuf := make([]u32, 1 << 16)
	defer delete(idbuf)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for line in lines {
		if len(line) == 0 {
			continue
		}
		fields := strings.split(line, " ")
		defer delete(fields)
		strings.builder_reset(&b)
		emit := true
		switch fields[0] {
		case "P":
			n := nat(fields[1])
			out := nat(fields[2])
			p: vm.Projection
			if vm.projection_init(&p, n, out) != nil {
				assert(!vm.projection_valid(n, out))
				strings.write_string(&b, "P|0")
				break
			}
			assert(vm.projection_valid(n, out) && p.kind == .Hadamard && len(p.data) == n * out)
			scale := vm.hadamard_scale(n)
			signs := make([]i64, n * out)
			defer delete(signs)
			strings.write_string(&b, "P|1|")
			for j in 0 ..< out {
				if j > 0 {
					strings.write_byte(&b, ',')
				}
				row := vm.projection_row(&p, j)
				for w, i in row {
					assert(abs(w) == scale)
					signs[j * n + i] = 1 if w > 0 else -1
					strings.write_byte(&b, '+' if w > 0 else '-')
				}
			}
			strings.write_byte(&b, '|')
			first := true
			for j in 0 ..< out {
				for k in j ..< out {
					s: i64
					for i in 0 ..< n {
						s += signs[j * n + i] * signs[k * n + i]
					}
					if !first {
						strings.write_byte(&b, ',')
					}
					fmt.sbprintf(&b, "%d", s)
					first = false
				}
			}
			vm.projection_destroy(&p)
		case "Q":
			xs := dyadics(fields[1:])
			defer delete(xs)
			q := make([]i8, len(xs))
			defer delete(q)
			range_a := vm.quantise_i8(xs, q)
			bytes := make([]u8, vm.elem_vector_bytes(.Int8, len(xs)))
			defer delete(bytes)
			range_b := vm.encode_normalised(.Int8, xs, bytes)
			assert(range_a == range_b)
			view := vm.i8_view(bytes)
			for v, i in q {
				assert(view[i] == v)
			}
			decoded := make([]f32, len(xs))
			defer delete(decoded)
			vm.decode(.Int8, bytes, 1, range_b, decoded)
			strings.write_string(&b, "Q|")
			exact32(&b, range_b)
			strings.write_byte(&b, '|')
			for v, i in q {
				if i > 0 {
					strings.write_byte(&b, ',')
				}
				fmt.sbprintf(&b, "%d", v)
			}
			strings.write_byte(&b, '|')
			for v, i in decoded {
				if i > 0 {
					strings.write_byte(&b, ',')
				}
				exact32(&b, v)
			}
		case "R":
			fmt.sbprintf(&b, "R|%d", vm.q8_round(special(fields[1])))
		case "QE":
			xs := dyadics(fields[1:])
			defer delete(xs)
			bytes := make([]u8, vm.elem_vector_bytes(.Int8, len(xs)))
			defer delete(bytes)
			norm, range_e := vm.encode(.Int8, xs, bytes)
			decoded := make([]f32, len(xs))
			defer delete(decoded)
			vm.decode(.Int8, bytes, norm, range_e, decoded)
			strings.write_string(&b, "QE|")
			exact32(&b, norm)
			strings.write_byte(&b, '|')
			exact32(&b, range_e)
			strings.write_byte(&b, '|')
			view := vm.i8_view(bytes)
			for v, i in view {
				if i > 0 {
					strings.write_byte(&b, ',')
				}
				fmt.sbprintf(&b, "%d", v)
			}
			strings.write_byte(&b, '|')
			for v, i in decoded {
				if i > 0 {
					strings.write_byte(&b, ',')
				}
				exact32(&b, v)
			}
		case "B":
			dim := nat(fields[1])
			xs := dyadics(fields[2:])
			defer delete(xs)
			assert(len(xs) == dim)
			bytes := encode_bin(xs, dim)
			defer delete(bytes)
			words := vm.u64_view(bytes)
			strings.write_string(&b, "B|")
			for w, i in words {
				if i > 0 {
					strings.write_byte(&b, ',')
				}
				fmt.sbprintf(&b, "%d", w)
			}
			fmt.sbprintf(&b, "|%d", bit(vm.bin_padding_clear(words, dim)))
		case "H":
			dim := nat(fields[1])
			assert(len(fields) == 2 + 2 * dim)
			xs := dyadics(fields[2:2 + dim])
			ys := dyadics(fields[2 + dim:])
			defer delete(xs)
			defer delete(ys)
			ab := encode_bin(xs, dim)
			cb := encode_bin(ys, dim)
			defer delete(ab)
			defer delete(cb)
			h := hamming_both(vm.u64_view(ab), vm.u64_view(cb))
			score := vm.score_bin(h, dim)
			assert(vm.kernels.score[.Bin][.Cosine](raw_data(ab), 0, raw_data(cb), 0, dim) == score)
			assert(vm.BASE_KERNELS.score[.Bin][.Cosine](raw_data(ab), 0, raw_data(cb), 0, dim) == score)
			fmt.sbprintf(&b, "H|%d|", h)
			if dim & (dim - 1) == 0 {
				exact64(&b, score)
			} else {
				strings.write_byte(&b, '-')
			}
		case "W":
			dim := nat(fields[1])
			k := nat(fields[2])
			assert(len(fields) == 3 + 2 * k)
			a := make([]u64, k)
			c := make([]u64, k)
			defer delete(a)
			defer delete(c)
			for i in 0 ..< k {
				a[i] = word(fields[3 + i])
				c[i] = word(fields[3 + k + i])
			}
			fmt.sbprintf(&b, "W|%d|%d|%d", hamming_both(a, c), bit(vm.bin_padding_clear(a, dim)), bit(vm.bin_padding_clear(c, dim)))
		case "HN":
			heap_max = fields[1] == "max"
			hn.min_heap_clear(&minh)
			hn.max_heap_clear(&maxh)
			emit = false
		case "HP":
			c := candidate(fields[1], fields[2])
			strings.write_string(&b, "HP|")
			if heap_max {
				assert(hn.max_heap_push(&maxh, c))
				write_heap(&b, maxh.items[:])
			} else {
				assert(hn.min_heap_push(&minh, c))
				write_heap(&b, minh.items[:])
			}
		case "HO":
			strings.write_string(&b, "HO|")
			if heap_max {
				assert(hn.max_heap_len(&maxh) > 0)
				write_cand(&b, hn.max_heap_pop(&maxh))
				strings.write_byte(&b, '|')
				write_heap(&b, maxh.items[:])
			} else {
				assert(hn.min_heap_len(&minh) > 0)
				write_cand(&b, hn.min_heap_pop(&minh))
				strings.write_byte(&b, '|')
				write_heap(&b, minh.items[:])
			}
		case "HT":
			strings.write_string(&b, "HT|")
			if heap_max {
				assert(hn.max_heap_len(&maxh) > 0)
				write_cand(&b, hn.max_heap_top(&maxh))
			} else {
				assert(hn.min_heap_len(&minh) > 0)
				write_cand(&b, hn.min_heap_top(&minh))
			}
		case "HR":
			assert(heap_max && hn.max_heap_len(&maxh) > 0)
			strings.write_string(&b, "HR|")
			write_cand(&b, hn.max_heap_replace_top(&maxh, candidate(fields[1], fields[2])))
			strings.write_byte(&b, '|')
			write_heap(&b, maxh.items[:])
		case "VN":
			hn.visited_destroy(&vis)
			hn.visited_init(&vis, context.allocator)
			emit = false
		case "VB":
			assert(hn.visited_begin(&vis, nat(fields[1])))
			fmt.sbprintf(&b, "VB|%d|%d|", vis.epoch, vis.cap)
			write_contained(&b, &vis)
		case "VM":
			id := nat(fields[1])
			assert(id < vis.cap)
			fmt.sbprintf(&b, "VM|%d|", bit(hn.visited_mark(&vis, u32(id))))
			write_contained(&b, &vis)
		case "VC":
			id := nat(fields[1])
			assert(id < vis.cap)
			fmt.sbprintf(&b, "VC|%d", bit(hn.visited_contains(&vis, u32(id))))
		case "VE":
			e := nat(fields[1])
			assert(e <= int(max(hn.Stamp)))
			vis.epoch = hn.Stamp(e)
			fmt.sbprintf(&b, "VE|%d", e)
		case "CS":
			cs := make([]hn.Candidate, len(fields) - 1)
			defer delete(cs)
			for f, i in fields[1:] {
				parts := strings.split(f, ":")
				defer delete(parts)
				assert(len(parts) == 2)
				cs[i] = candidate(parts[0], parts[1])
			}
			hn.candidates_sort(cs)
			strings.write_string(&b, "CS|")
			write_heap(&b, cs)
		case "LW":
			w := hn.link_width(nat(fields[1]))
			fmt.sbprintf(&b, "LW|%d|%d", w, hn.width_none(w))
		case "LN":
			stored, ok := vm.live_norm(transmute(f32)u32(word(fields[1])))
			fmt.sbprintf(&b, "LN|%x|%d", transmute(u32)stored, bit(ok))
		case "AN":
			if arena_ready {
				vm.arena_destroy(&arena)
			}
			assert(vm.arena_init(&arena, .F32, .Cosine, 1, context.allocator, nat(fields[1])) == nil)
			arena_ready = true
			strings.write_string(&b, "AN|")
			write_arena(&b, &arena)
		case "AA":
			slot, err := vm.arena_alloc(&arena)
			strings.write_string(&b, "AA|")
			if err == nil {
				fmt.sbprintf(&b, "%d|", slot)
			} else {
				strings.write_string(&b, "-|")
			}
			write_arena(&b, &arena)
		case "AF":
			r := vm.arena_free(&arena, u32(nat(fields[1])))
			fmt.sbprintf(&b, "AF|%d|", int(r))
			write_arena(&b, &arena)
		case "AS":
			data := [4]u8{}
			ok := vm.arena_set_raw(&arena, u32(nat(fields[1])), data[:], transmute(f32)u32(word(fields[2])), 0)
			fmt.sbprintf(&b, "AS|%d|", bit(ok))
			write_arena(&b, &arena)
		case "AZ":
			xn := [1]f32{1}
			ok := vm.arena_set_normalised(&arena, u32(nat(fields[1])), xn[:], transmute(f32)u32(word(fields[2])))
			fmt.sbprintf(&b, "AZ|%d|", bit(ok))
			write_arena(&b, &arena)
		case "AI":
			xn := [1]f32{1}
			slot, err := vm.arena_insert_normalised(&arena, xn[:], transmute(f32)u32(word(fields[1])))
			strings.write_string(&b, "AI|")
			if err == nil {
				fmt.sbprintf(&b, "%d|", slot)
			} else {
				strings.write_string(&b, "-|")
			}
			write_arena(&b, &arena)
		case "AE":
			x := [1]f32{encode_token(fields[2])}
			vm.arena_set(&arena, u32(nat(fields[1])), x[:])
			strings.write_string(&b, "AE|")
			write_arena(&b, &arena)
		case "AL":
			fmt.sbprintf(&b, "AL|%d", bit(vm.arena_is_live(&arena, u32(nat(fields[1])))))
		case "XN":
			if ix_ready {
				hn.destroy(&ix)
				hn.scratch_destroy(&sc)
			}
			clear(&pts.xs)
			params := hn.params_default()
			params.m = nat(fields[1])
			params.ef_construction = nat(fields[2])
			params.level_law = .Constant
			params.promotion = 0.5
			assert(hn.init(&ix, params, points_distance, &pts, context.allocator) == .None)
			hn.scratch_init(&sc, context.allocator)
			ix_ready = true
			fmt.sbprintf(&b, "XN|%d|%d", ix.coincident, ix.width)
		case "XI":
			slot, err := hn.reserve(&ix)
			assert(err == .None)
			for len(pts.xs) <= int(slot) {
				append(&pts.xs, [2]i64{})
			}
			pts.xs[slot] = {integer(fields[1]), integer(fields[2])}
			level := nat(fields[3])
			force_level(&ix, level)
			ierr := hn.insert(&ix, &sc, slot)
			if hn.is_node(&ix, slot) {
				assert(hn.node_level(&ix, slot) == level)
			}
			fmt.sbprintf(&b, "XI|%d|%d|", slot, int(ierr))
			write_index(&b, &ix, idbuf)
		case "XR":
			slot, err := hn.reserve(&ix)
			assert(err == .None)
			for len(pts.xs) <= int(slot) {
				append(&pts.xs, [2]i64{})
			}
			fmt.sbprintf(&b, "XR|%d|", slot)
			write_index(&b, &ix, idbuf)
		case "XF":
			err := hn.release(&ix, u32(nat(fields[1])))
			fmt.sbprintf(&b, "XF|%d|", int(err))
			write_index(&b, &ix, idbuf)
		case "XD":
			err := hn.remove(&ix, &sc, u32(nat(fields[1])))
			fmt.sbprintf(&b, "XD|%d|", int(err))
			write_index(&b, &ix, idbuf)
		case "XW":
			err := hn.reencode(&ix, ix.cap, nat(fields[1]))
			fmt.sbprintf(&b, "XW|%d|", int(err))
			write_index(&b, &ix, idbuf)
		case "XS":
			q := Point_Query{&pts, integer(fields[1]), integer(fields[2])}
			k := nat(fields[3])
			out := make([]hn.Candidate, k)
			defer delete(out)
			n, err := hn.search(&ix, &sc, point_query, &q, k, nat(fields[4]), out)
			assert(err == .None)
			strings.write_string(&b, "XS|")
			write_heap(&b, out[:n])
		case:
			panic("invalid case line")
		}
		if emit {
			fmt.println(strings.to_string(b))
		}
	}
}
