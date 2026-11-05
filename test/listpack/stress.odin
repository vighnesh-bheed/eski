package main

import lp "../../src/listpack"
import "core:fmt"

random_text :: proc(target: []u8, lo, hi: int) -> int {
	n := lo + int(lp.random_below(u64(hi - lo + 1)))
	switch lp.random_below(4) {
	case 0:
		for i in 0 ..< n {
			target[i] = u8(lp.lp_rand())
		}
	case 1:
		for i in 0 ..< n {
			target[i] = '0' + u8(lp.random_below(10))
		}
	case 2:
		for i in 0 ..< n {
			target[i] = 'a' + u8(lp.random_below(26))
		}
	case:
		for i in 0 ..< n {
			target[i] = ' ' + u8(lp.random_below(95))
		}
	}
	return n
}

ref_is_canonical_int :: proc(s: []u8) -> (v: i64, ok: bool) {
	if len(s) == 0 || len(s) > 20 {
		return 0, false
	}
	if len(s) == 1 && s[0] == '0' {
		return 0, true
	}
	i := 0
	neg := false
	if s[0] == '-' {
		neg = true
		i = 1
	}
	if i >= len(s) || s[i] < '1' || s[i] > '9' {
		return 0, false
	}
	acc: i128 = 0
	for ; i < len(s); i += 1 {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		acc = acc * 10 + i128(s[i] - '0')
	}
	if neg {
		acc = -acc
	}
	if acc < i128(min(i64)) || acc > i128(max(i64)) {
		return 0, false
	}
	return i64(acc), true
}

ref_entry :: proc(out: ^[dynamic]u8, s: []u8) {
	start := len(out)
	if v, ok := ref_is_canonical_int(s); ok {
		u := u64(v)
		switch {
		case v >= 0 && v <= 127:
			append(out, u8(v))
		case v >= -4096 && v <= 4095:
			x := u & 0x1fff
			append(out, u8(0xC0 | (x >> 8)), u8(x & 0xff))
		case v >= -32768 && v <= 32767:
			append(out, 0xF1, u8(u), u8(u >> 8))
		case v >= -8388608 && v <= 8388607:
			append(out, 0xF2, u8(u), u8(u >> 8), u8(u >> 16))
		case v >= -2147483648 && v <= 2147483647:
			append(out, 0xF3, u8(u), u8(u >> 8), u8(u >> 16), u8(u >> 24))
		case:
			append(out, 0xF4)
			for k in 0 ..< 8 {
				append(out, u8(u >> uint(8 * k)))
			}
		}
	} else {
		n := len(s)
		switch {
		case n < 64:
			append(out, u8(0x80 | n))
		case n < 4096:
			append(out, u8(0xE0 | (n >> 8)), u8(n & 0xff))
		case:
			append(out, 0xF0, u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24))
		}
		append(out, ..s)
	}
	l := len(out) - start
	switch {
	case l <= 127:
		append(out, u8(l))
	case l < 16383:
		append(out, u8(l >> 7), u8((l & 127) | 128))
	case l < 2097151:
		append(out, u8(l >> 14), u8(((l >> 7) & 127) | 128), u8((l & 127) | 128))
	case l < 268435455:
		append(out, u8(l >> 21), u8(((l >> 14) & 127) | 128), u8(((l >> 7) & 127) | 128), u8((l & 127) | 128))
	case:
		append(out, u8(l >> 28), u8(((l >> 21) & 127) | 128), u8(((l >> 14) & 127) | 128), u8(((l >> 7) & 127) | 128), u8((l & 127) | 128))
	}
}

ref_encode :: proc(model: [][]u8, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, 64, allocator)
	append(&out, 0, 0, 0, 0, 0, 0)
	for s in model {
		ref_entry(&out, s)
	}
	append(&out, 0xFF)
	total := len(out)
	out[0] = u8(total)
	out[1] = u8(total >> 8)
	out[2] = u8(total >> 16)
	out[3] = u8(total >> 24)
	n := len(model) if len(model) < 65535 else 65535
	out[4] = u8(n)
	out[5] = u8(n >> 8)
	return out[:]
}

gen_value :: proc(buf: []u8) -> []u8 {
	switch lp.lp_rand() % 12 {
	case 0:
		return buf[:0]
	case 1:
		v := i64(lp.lp_rand() % 300) - 150
		return buf[:lp.ll2string(raw_data(buf), v)]
	case 2:
		v := (i64(lp.lp_rand()) << 33 | i64(lp.lp_rand())) >> (lp.lp_rand() % 63)
		if lp.lp_rand() % 2 == 0 {
			v = -v
		}
		return buf[:lp.ll2string(raw_data(buf), v)]
	case 3:
		edges := [?]i64{127, 128, -4096, -4097, 4095, 4096, 32767, 32768, -32768, -32769, 8388607, 8388608, -8388608, -8388609, 2147483647, 2147483648, -2147483648, -2147483649, max(i64), min(i64)}
		return buf[:lp.ll2string(raw_data(buf), edges[lp.lp_rand() % len(edges)])]
	case 4:
		odd := [?]string{"007", "-0", "+5", "1.5", "9223372036854775808", "-9223372036854775809", "00", "-", " 1", "1 "}
		s := odd[lp.lp_rand() % len(odd)]
		copy(buf, s)
		return buf[:len(s)]
	case 5:
		lens := [?]int{63, 64, 125, 126, 127, 4093, 4094, 4095, 4096}
		n := lens[lp.lp_rand() % len(lens)]
		for i in 0 ..< n {
			buf[i] = u8('a' + i % 26)
		}
		return buf[:n]
	case 6:
		if lp.lp_rand() % 16 == 0 && len(buf) >= 16380 {
			n := 16376 + int(lp.lp_rand() % 4)
			for i in 0 ..< n {
				buf[i] = u8(lp.lp_rand())
			}
			return buf[:n]
		}
		return buf[:random_text(buf, 1, 200)]
	case:
		return buf[:random_text(buf, 0, 40)]
	}
}

model_insert :: proc(model: ^[dynamic][]u8, idx: int, s: []u8) {
	c := make([]u8, len(s))
	copy(c, s)
	inject_at(model, idx, c)
}

model_remove :: proc(model: ^[dynamic][]u8, idx: int, n: int) {
	for k in 0 ..< n {
		delete(model[idx + k])
	}
	remove_range(model, idx, idx + n)
}

run_model_stress :: proc(accurate: bool) {
	rounds := 4000 if accurate else 1000
	ops_per_round := 400
	buf := make([]u8, 20000)
	defer delete(buf)
	byte_checks, byte_fail := 0, 0
	for _ in 0 ..< rounds {
		l := lp.lp_new(0)
		model := make([dynamic][]u8)
		for op in 0 ..< ops_per_round {
			n := len(model)
			kind := int(lp.lp_rand() % 13)
			if n == 0 && kind >= 2 && kind != 10 {
				kind = 0
			}
			switch kind {
			case 0:
				v := gen_value(buf)
				l = lp.lp_append(l, v)
				model_insert(&model, n, v)
			case 1:
				v := gen_value(buf)
				l = lp.lp_prepend(l, v)
				model_insert(&model, 0, v)
			case 2, 3:
				idx := int(lp.lp_rand()) % n
				p := lp.lp_seek(l, i64(idx))
				v := gen_value(buf)
				newp: [^]u8
				if kind == 2 {
					l = lp.lp_insert_string(l, v, p, lp.Placement.Before, &newp)
					model_insert(&model, idx, v)
				} else {
					l = lp.lp_insert_string(l, v, p, lp.Placement.After, &newp)
					model_insert(&model, idx + 1, v)
				}
				check(newp != nil && lp.lp_compare(newp, v), "insert newp")
			case 4:
				idx := int(lp.lp_rand()) % n
				p := lp.lp_seek(l, i64(-n + idx))
				iv := i64(lp.lp_rand()) - (1 << 30)
				if lp.lp_rand() % 3 == 0 {
					iv = iv * iv * (1 if lp.lp_rand() % 2 == 0 else -1)
				}
				tmp: [lp.DECIMAL_BUFFER_BYTES]u8
				sl := lp.ll2string(raw_data(tmp[:]), iv)
				l = lp.lp_insert_integer(l, iv, p, lp.Placement.After, nil)
				model_insert(&model, idx + 1, tmp[:sl])
			case 5:
				idx := int(lp.lp_rand()) % n
				p := lp.lp_seek(l, i64(idx))
				if lp.lp_rand() % 4 == 0 {
					iv := i64(lp.lp_rand()) * i64(lp.lp_rand() % 5000) - 70000
					l = lp.lp_replace_integer(l, &p, iv)
					tmp: [lp.DECIMAL_BUFFER_BYTES]u8
					sl := lp.ll2string(raw_data(tmp[:]), iv)
					model_remove(&model, idx, 1)
					model_insert(&model, idx, tmp[:sl])
				} else {
					v := gen_value(buf)
					l = lp.lp_replace(l, &p, v)
					model_remove(&model, idx, 1)
					model_insert(&model, idx, v)
					check(p != nil && lp.lp_compare(p, v), "replace cursor")
				}
			case 6:
				idx := int(lp.lp_rand()) % n
				p := lp.lp_seek(l, i64(idx))
				l = lp.lp_delete(l, p, &p)
				model_remove(&model, idx, 1)
				if idx < len(model) {
					check(p != nil && lp.lp_compare(p, model[idx]), "delete newp")
				} else {
					check(p == nil, "delete last newp")
				}
			case 7:
				idx := int(lp.lp_rand()) % n
				num := int(lp.lp_rand() % 6)
				index := i64(idx) if lp.lp_rand() % 2 == 0 else i64(idx - n)
				l = lp.lp_delete_range(l, index, u64(num))
				model_remove(&model, idx, min(num, n - idx))
			case 8:
				idx := int(lp.lp_rand()) % n
				num := 1 + int(lp.lp_rand() % 5)
				p := lp.lp_seek(l, i64(idx))
				l = lp.lp_delete_range_with_entry(l, &p, u64(num))
				model_remove(&model, idx, min(num, n - idx))
			case 9:
				idx := int(lp.lp_rand()) % n
				p := lp.lp_seek(l, i64(idx))
				k := 1 + int(lp.lp_rand() % 5)
				ents := make([]lp.Element, k)
				store := make([dynamic][]u8)
				for e in 0 ..< k {
					if lp.lp_rand() % 3 == 0 {
						iv := i64(lp.lp_rand()) - 1000000
						ents[e] = lp.entry_from_int(iv)
						tmp: [lp.DECIMAL_BUFFER_BYTES]u8
						sl := lp.ll2string(raw_data(tmp[:]), iv)
						c := make([]u8, sl)
						copy(c, tmp[:sl])
						append(&store, c)
					} else {
						v := gen_value(buf[:4200])
						c := make([]u8, len(v))
						copy(c, v)
						append(&store, c)
						ents[e] = lp.entry_from_bytes(c)
					}
				}
				after := lp.lp_rand() % 2 == 0
				newp: [^]u8
				l = lp.lp_splice_entries(l, ents, p, lp.Placement.After if after else lp.Placement.Before, &newp)
				base := idx + 1 if after else idx
				for e in 0 ..< k {
					model_insert(&model, base + e, store[e])
				}
				check(newp != nil && lp.lp_compare(newp, store[k - 1]), "batch insert newp")
				for c in store {
					delete(c)
				}
				delete(store)
				delete(ents)
			case 10:
				k := 1 + int(lp.lp_rand() % 4)
				ents := make([]lp.Element, k)
				store := make([dynamic][]u8)
				for e in 0 ..< k {
					v := gen_value(buf[:4200])
					c := make([]u8, len(v))
					copy(c, v)
					append(&store, c)
					ents[e] = lp.entry_from_bytes(c)
				}
				l = lp.lp_append_entries(l, ents)
				for e in 0 ..< k {
					model_insert(&model, len(model), store[e])
				}
				for c in store {
					delete(c)
				}
				delete(store)
				delete(ents)
			case 11:
				ps := make([dynamic][^]u8)
				idxs := make([dynamic]int)
				p := lp.lp_first(l)
				i := 0
				for p != nil {
					if lp.lp_rand() % 4 == 0 {
						append(&ps, p)
						append(&idxs, i)
					}
					p = lp.lp_next(l, p)
					i += 1
				}
				l = lp.lp_batch_delete(l, ps[:])
				for k := len(idxs) - 1; k >= 0; k -= 1 {
					model_remove(&model, idxs[k], 1)
				}
				delete(ps)
				delete(idxs)
			case 12:
				idx := int(lp.lp_rand()) % n
				p := lp.lp_seek(l, i64(idx))
				q := lp.lp_seek(l, i64(idx - n))
				check(p == q && lp.lp_compare(p, model[idx]), "seek both directions")
				f := lp.lp_find(l, lp.lp_first(l), model[idx], 0)
				check(f != nil && lp.lp_compare(f, model[idx]) && uintptr(f) <= uintptr(p), "find first occurrence")
			}
			check(lp.lp_length(l) == u64(len(model)), "model length")
			if len(model) < 64 || op % 16 == 0 {
				want := ref_encode(model[:], context.temp_allocator)
				got := lp.lp_view(l)
				byte_checks += 1
				if string(want) != string(got) {
					byte_fail += 1
					if byte_fail <= 3 {
						fmt.eprintfln("byte mismatch after op kind %d: want %d bytes got %d", kind, len(want), len(got))
					}
				}
				check(lp.lp_validate_integrity(l, u64(lp.lp_bytes(l)), true, nil, nil), "model integrity")
				free_all(context.temp_allocator)
			}
		}
		intbuf: [lp.DECIMAL_BUFFER_BYTES]u8
		p := lp.lp_last(l)
		i := len(model) - 1
		back_ok := true
		for p != nil {
			back_ok = back_ok && string(lp.lp_get_bytes(p, &intbuf)) == string(model[i])
			p = lp.lp_prev(l, p)
			i -= 1
		}
		check(back_ok && i == -1, "backward walk matches model")
		for s in model {
			delete(s)
		}
		delete(model)
		lp.lp_free(l)
	}
	check(byte_fail == 0, "listpack bytes equal reference encoder")
	fmt.printfln("    reference encoder byte comparisons: %d, mismatches: %d", byte_checks, byte_fail)
}

run_corruption_fuzz :: proc(accurate: bool) {
	rounds := 200000 if accurate else 30000
	buf := make([]u8, 9000)
	defer delete(buf)
	accepted, rejected := 0, 0
	ok := true
	for _ in 0 ..< rounds {
		l := lp.lp_new(0)
		n := int(lp.lp_rand() % 12)
		for _ in 0 ..< n {
			l = lp.lp_append(l, gen_value(buf[:4200]))
		}
		size := lp.lp_bytes(l)
		c := lp.lp_malloc(size)
		copy(c[:size], l[:size])
		lp.lp_free(l)
		flips := 1 + int(lp.lp_rand() % 3)
		for _ in 0 ..< flips {
			pos := lp.PACK_HEADER_BYTES + int(lp.lp_rand()) % max(1, size - lp.PACK_HEADER_BYTES)
			if lp.lp_rand() % 8 == 0 {
				pos = int(lp.lp_rand()) % size
			}
			c[pos] = u8(lp.lp_rand())
		}
		vsize := u64(size)
		if lp.lp_rand() % 10 == 0 {
			vsize = u64(int(lp.lp_rand()) % (size + 1))
		}
		if lp.lp_validate_integrity(c, vsize, true, nil, nil) {
			accepted += 1
			count := 0
			p := lp.lp_first(c)
			intbuf: [lp.DECIMAL_BUFFER_BYTES]u8
			for p != nil {
				_ = lp.lp_get_bytes(p, &intbuf)
				count += 1
				p = lp.lp_next(c, p)
			}
			hdr := lp.lp_get_num_elements(c)
			ok = ok && (hdr == lp.COUNT_UNTRACKED || int(hdr) == count)
		} else {
			rejected += 1
		}
		lp.lp_free(c)
	}
	check(ok, "corrupted listpacks accepted by validation iterate consistently")
	check(rejected > 0, "corruption fuzz rejects some inputs")
	fmt.printfln("    corrupted inputs: %d accepted as structurally valid, %d rejected", accepted, rejected)
}
