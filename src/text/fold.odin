package text

CP_LIMIT :: 0x200000

lower_lookup :: #force_inline proc "contextless" (cp: u32) -> (lower: u32, special: bool) #no_bounds_check {
	if cp >= LOWER_LIMIT {
		return cp, false
	}
	block := u32(LOWER_STAGE1[cp >> LOWER_BLOCK_SHIFT])
	index := LOWER_STAGE2[block << LOWER_BLOCK_SHIFT | cp & 0xFF]
	if index == LOWER_SPECIAL {
		return cp, true
	}
	return u32(i32(cp) + LOWER_DELTAS[index]), false
}

lower_full :: proc "contextless" (cp: u32, out: ^[3]u32) -> int {
	lower, special := lower_lookup(cp)
	if !special {
		out[0] = lower
		return 1
	}
	for e in LOWER_EXPANSIONS {
		if e.cp == cp {
			out^ = e.seq
			return int(e.count)
		}
	}
	out[0] = cp
	return 1
}

lower_simple :: proc "contextless" (cp: u32) -> u32 {
	lower, special := lower_lookup(cp)
	if special {
		return cp
	}
	return lower
}

source_byte :: #force_inline proc "contextless" (text: []u8, tail: []u8, i: int) -> u8 #no_bounds_check {
	if i < len(text) {
		return text[i]
	}
	j := i - len(text)
	if j < len(tail) {
		return tail[j]
	}
	return 0
}

decode_unit :: proc "contextless" (text: []u8, tail: []u8, i: int) -> (cp: u32, next: int) {
	b0 := u32(source_byte(text, tail, i))
	if b0 < 0x80 {
		return b0, i + 1
	}
	if b0 < 0xE0 {
		b1 := u32(source_byte(text, tail, i + 1))
		return (b0 & 0x1F) << 6 | b1 & 0x3F, i + 2
	}
	if b0 < 0xF0 {
		b1 := u32(source_byte(text, tail, i + 1))
		b2 := u32(source_byte(text, tail, i + 2))
		return (b0 & 0x0F) << 12 | (b1 & 0x3F) << 6 | b2 & 0x3F, i + 3
	}
	b1 := u32(source_byte(text, tail, i + 1))
	b2 := u32(source_byte(text, tail, i + 2))
	b3 := u32(source_byte(text, tail, i + 3))
	return (b0 & 0x07) << 18 | (b1 & 0x3F) << 12 | (b2 & 0x3F) << 6 | b3 & 0x3F, i + 4
}

encode_unit :: #force_inline proc "contextless" (cp: u32, buf: ^[4]u8) -> int {
	switch {
	case cp < 0x80:
		buf[0] = u8(cp)
		return 1
	case cp < 0x800:
		buf[0] = u8(0xC0 | cp >> 6)
		buf[1] = u8(0x80 | cp & 0x3F)
		return 2
	case cp < 0x10000:
		buf[0] = u8(0xE0 | cp >> 12)
		buf[1] = u8(0x80 | cp >> 6 & 0x3F)
		buf[2] = u8(0x80 | cp & 0x3F)
		return 3
	}
	buf[0] = u8(0xF0 | cp >> 18 & 0x07)
	buf[1] = u8(0x80 | cp >> 12 & 0x3F)
	buf[2] = u8(0x80 | cp >> 6 & 0x3F)
	buf[3] = u8(0x80 | cp & 0x3F)
	return 4
}

ascii_lower :: #force_inline proc "contextless" (b: u8) -> u8 {
	return b + 32 if b - 'A' < 26 else b
}

fold :: proc(text: []u8, tail: []u8, out: ^[dynamic]u8) #no_bounds_check {
	base := len(out)
	non_zero_resize(out, base + len(text))
	dst := out[base:]
	n := 0
	for n < len(text) {
		b := text[n]
		if b >= 0x80 || b == 0 {
			break
		}
		dst[n] = ascii_lower(b)
		n += 1
	}
	if n == len(text) {
		return
	}
	non_zero_resize(out, base + n)
	if text[n] == 0 {
		return
	}
	fold_units(text, tail, n, out)
}

fold_units :: proc(text: []u8, tail: []u8, from: int, out: ^[dynamic]u8) {
	i := from
	seq: [3]u32
	buf: [4]u8
	for i < len(text) {
		cp, next := decode_unit(text, tail, i)
		i = next
		if cp == 0 {
			return
		}
		if cp < 0x80 {
			append(out, ascii_lower(u8(cp)))
			continue
		}
		count := lower_full(cp, &seq)
		for k in 0 ..< count {
			w := encode_unit(seq[k], &buf)
			append(out, ..buf[:w])
		}
	}
}

trie_form :: proc(term: []u8, out: ^[dynamic]u8) -> (in_trie: bool) {
	units := 0
	stopped := false
	buf: [4]u8
	i := 0
	for i < len(term) {
		cp, next := decode_unit(term, nil, i)
		i = next
		units += 1
		if stopped {
			continue
		}
		u := cp & 0xFFFF
		if u == 0 {
			stopped = true
			continue
		}
		w := encode_unit(u, &buf)
		append(out, ..buf[:w])
	}
	return units <= TRIE_UNIT_LIMIT
}

unit_count :: proc "contextless" (term: []u8) -> int {
	units := 0
	i := 0
	for i < len(term) {
		_, next := decode_unit(term, nil, i)
		i = next
		units += 1
	}
	return units
}
