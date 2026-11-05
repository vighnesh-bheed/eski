package hll

import "base:runtime"

HLL_SPARSE_XZERO_BIT :: 0x40
HLL_SPARSE_VAL_BIT :: 0x80
HLL_SPARSE_VAL_MAX_VALUE :: 32
HLL_SPARSE_VAL_MAX_LEN :: 4
HLL_SPARSE_ZERO_MAX_LEN :: 64
HLL_SPARSE_XZERO_MAX_LEN :: 16384

HLL_SPARSE_SEQ_MAX :: 5

HLL_POS_NONE :: -1
HLL_POS_UNKNOWN :: -2

Sparse_Op :: enum u8 {
	Zero,
	XZero,
	Val,
}

Sparse_Iter :: struct {
	s:   []u8,
	pos: int,
}

Sparse_Cursor :: struct {
	pos:        int,
	first:      int,
	prev_pos:   int,
	prev_first: int,
}

Sparse_Loc :: struct {
	pos:         int,
	first:       int,
	runlen:      int,
	regval:      int,
	oplen:       int,
	op:          Sparse_Op,
	prev_pos:    int,
	prev_first:  int,
	pprev_pos:   int,
	pprev_first: int,
}

Sparse_Outcome :: enum u8 {
	Unchanged,
	Changed,
	Promote,
}

sparse_is_zero :: #force_inline proc "contextless" (b: u8) -> bool {
	return b & 0xc0 == 0
}

sparse_is_xzero :: #force_inline proc "contextless" (b: u8) -> bool {
	return b & 0xc0 == HLL_SPARSE_XZERO_BIT
}

sparse_is_val :: #force_inline proc "contextless" (b: u8) -> bool {
	return b & HLL_SPARSE_VAL_BIT != 0
}

sparse_zero_len :: #force_inline proc "contextless" (b: u8) -> int {
	return int(b & 0x3f) + 1
}

sparse_xzero_len :: #force_inline proc "contextless" (b0, b1: u8) -> int {
	return (int(b0 & 0x3f) << 8 | int(b1)) + 1
}

sparse_val_value :: #force_inline proc "contextless" (b: u8) -> int {
	return int((b >> 2) & 0x1f) + 1
}

sparse_val_len :: #force_inline proc "contextless" (b: u8) -> int {
	return int(b & 3) + 1
}

sparse_val_byte :: #force_inline proc "contextless" (val, length: int) -> u8 {
	return u8(HLL_SPARSE_VAL_BIT | ((val - 1) << 2) | (length - 1))
}

sparse_zero_byte :: #force_inline proc "contextless" (length: int) -> u8 {
	return u8(length - 1)
}

sparse_xzero_bytes :: #force_inline proc "contextless" (length: int) -> (u8, u8) {
	n := length - 1
	return u8(HLL_SPARSE_XZERO_BIT | (n >> 8)), u8(n & 0xff)
}

byte_at :: #force_inline proc "contextless" (s: []u8, i: int) -> u8 {
	if i < len(s) {
		return s[i]
	}
	return 0
}

sparse_op_len :: #force_inline proc "contextless" (b: u8) -> int {
	if b & 0xc0 == HLL_SPARSE_XZERO_BIT {
		return 2
	}
	return 1
}

sparse_iter :: #force_inline proc "contextless" (s: []u8) -> Sparse_Iter {
	return Sparse_Iter{s = s, pos = HLL_HDR_SIZE}
}

sparse_next :: #force_inline proc "contextless" (it: ^Sparse_Iter) -> (op: Sparse_Op, runlen: int, regval: int, ok: bool) {
	if it.pos >= len(it.s) {
		return
	}
	b := it.s[it.pos]
	if b & HLL_SPARSE_VAL_BIT != 0 {
		op = .Val
		runlen = sparse_val_len(b)
		regval = sparse_val_value(b)
		it.pos += 1
	} else if b & HLL_SPARSE_XZERO_BIT != 0 {
		op = .XZero
		runlen = sparse_xzero_len(b, byte_at(it.s, it.pos + 1))
		it.pos += 2
	} else {
		op = .Zero
		runlen = sparse_zero_len(b)
		it.pos += 1
	}
	ok = true
	return
}

sparse_reg_histo :: proc "contextless" (s: []u8, reghisto: ^[64]int) -> (valid: bool) {
	it := sparse_iter(s)
	index := 0
	for {
		op, runlen, regval, ok := sparse_next(&it)
		if !ok {
			break
		}
		index += runlen
		if index > HLL_REGISTERS {
			return false
		}
		if op == .Val {
			reghisto[regval] += runlen
		} else {
			reghisto[0] += runlen
		}
	}
	return index == HLL_REGISTERS
}

sparse_decode_into :: proc "contextless" (s: []u8, regs: []u8, max_mode: bool) -> bool {
	it := sparse_iter(s)
	index := 0
	for {
		op, runlen, regval, ok := sparse_next(&it)
		if !ok {
			break
		}
		if index + runlen > HLL_REGISTERS {
			return false
		}
		if op == .Val {
			value := u8(regval)
			for k in index ..< index + runlen {
				if !max_mode || regs[k] < value {
					regs[k] = value
				}
			}
		} else if !max_mode {
			for k in index ..< index + runlen {
				regs[k] = 0
			}
		}
		index += runlen
	}
	return index == HLL_REGISTERS
}

sparse_cursor_start :: #force_inline proc "contextless" () -> Sparse_Cursor {
	return Sparse_Cursor{pos = HLL_HDR_SIZE, first = 0, prev_pos = HLL_POS_NONE, prev_first = 0}
}

sparse_cursor_after :: #force_inline proc "contextless" (loc: Sparse_Loc) -> Sparse_Cursor {
	if loc.prev_pos < 0 {
		return sparse_cursor_start()
	}
	return Sparse_Cursor {
		pos = loc.prev_pos,
		first = loc.prev_first,
		prev_pos = loc.pprev_pos,
		prev_first = loc.pprev_first,
	}
}

sparse_locate :: proc "contextless" (s: []u8, index: int, cur: Sparse_Cursor) -> (loc: Sparse_Loc, found: bool) {
	pos := cur.pos
	first := cur.first
	p1_pos, p1_first := cur.prev_pos, cur.prev_first
	p2_pos, p2_first := HLL_POS_UNKNOWN, 0
	if p1_pos == HLL_POS_NONE {
		p2_pos = HLL_POS_NONE
	}
	for pos < len(s) {
		b := s[pos]
		runlen, regval, oplen: int
		op: Sparse_Op
		if b & HLL_SPARSE_VAL_BIT != 0 {
			op = .Val
			runlen = sparse_val_len(b)
			regval = sparse_val_value(b)
			oplen = 1
		} else if b & HLL_SPARSE_XZERO_BIT != 0 {
			op = .XZero
			runlen = sparse_xzero_len(b, byte_at(s, pos + 1))
			oplen = 2
		} else {
			op = .Zero
			runlen = sparse_zero_len(b)
			oplen = 1
		}
		if index < first + runlen {
			loc = Sparse_Loc {
				pos         = pos,
				first       = first,
				runlen      = runlen,
				regval      = regval,
				oplen       = oplen,
				op          = op,
				prev_pos    = p1_pos,
				prev_first  = p1_first,
				pprev_pos   = p2_pos,
				pprev_first = p2_first,
			}
			return loc, true
		}
		p2_pos, p2_first = p1_pos, p1_first
		p1_pos, p1_first = pos, first
		pos += oplen
		first += runlen
	}
	return loc, false
}

sparse_register_at :: proc "contextless" (s: []u8, index: int) -> (value: int, found: bool) {
	loc, ok := sparse_locate(s, index, sparse_cursor_start())
	if !ok {
		return 0, false
	}
	return loc.regval, true
}

sparse_merge_region :: proc "contextless" (s: []u8, start, seq_end: int) -> int {
	n := len(s)
	end := seq_end
	if end < n {
		end += sparse_op_len(s[end])
	}
	q := start
	for q < end && q < n {
		b := s[q]
		if b & HLL_SPARSE_VAL_BIT != 0 && q + 1 < end && q + 1 < n {
			next := s[q + 1]
			if next & HLL_SPARSE_VAL_BIT != 0 && (b ~ next) & 0x7c == 0 {
				total := int(b & 3) + int(next & 3) + 2
				if total <= HLL_SPARSE_VAL_MAX_LEN {
					s[q] = (b & 0xfc) | u8(total - 1)
					copy(s[q + 1:n - 1], s[q + 2:n])
					n -= 1
					end -= 1
					continue
				}
			}
		}
		q += sparse_op_len(b)
	}
	return n
}

@(private = "file")
seq_push_zero :: #force_inline proc "contextless" (seq: ^[HLL_SPARSE_SEQ_MAX]u8, n: ^int, length: int) {
	if length <= HLL_SPARSE_ZERO_MAX_LEN {
		seq[n^] = sparse_zero_byte(length)
		n^ += 1
	} else {
		seq[n^], seq[n^ + 1] = sparse_xzero_bytes(length)
		n^ += 2
	}
}

sparse_apply_set :: proc(buf: ^[dynamic]u8, index: int, loc: Sparse_Loc, count: u8, sparse_max_bytes: int) -> (outcome: Sparse_Outcome, err: Error) {
	value := int(count)
	merge_start := loc.prev_pos if loc.prev_pos >= 0 else loc.pos
	if loc.op == .Val {
		if loc.regval >= value {
			return .Unchanged, .None
		}
		if loc.runlen == 1 {
			buf[loc.pos] = sparse_val_byte(value, 1)
			n := sparse_merge_region(buf[:], merge_start, loc.pos + 1)
			if n != len(buf) {
				resize(buf, n)
			}
			return .Changed, .None
		}
	}
	seq: [HLL_SPARSE_SEQ_MAX]u8
	sn := 0
	before := index - loc.first
	after := loc.first + loc.runlen - 1 - index
	if loc.op == .Val {
		if before > 0 {
			seq[sn] = sparse_val_byte(loc.regval, before)
			sn += 1
		}
		seq[sn] = sparse_val_byte(value, 1)
		sn += 1
		if after > 0 {
			seq[sn] = sparse_val_byte(loc.regval, after)
			sn += 1
		}
	} else {
		if before > 0 {
			seq_push_zero(&seq, &sn, before)
		}
		seq[sn] = sparse_val_byte(value, 1)
		sn += 1
		if after > 0 {
			seq_push_zero(&seq, &sn, after)
		}
	}
	oldlen := len(buf)
	newlen := oldlen - loc.oplen + sn
	if newlen > sparse_max_bytes {
		return .Promote, .None
	}
	tail_from := loc.pos + loc.oplen
	tail_len := oldlen - tail_from
	if newlen > oldlen {
		if resize(buf, newlen) != nil {
			return .Unchanged, .Out_Of_Memory
		}
	}
	s := buf[:]
	if tail_len > 0 {
		copy(s[loc.pos + sn:loc.pos + sn + tail_len], s[tail_from:oldlen])
	}
	written := min(sn, newlen - loc.pos)
	if written > 0 {
		copy(s[loc.pos:loc.pos + written], seq[:written])
	}
	if newlen < oldlen {
		resize(buf, newlen)
	}
	n := sparse_merge_region(buf[:], merge_start, min(loc.pos + sn, newlen))
	if n != len(buf) {
		resize(buf, n)
	}
	return .Changed, .None
}

sparse_to_dense_into :: proc(src: []u8, dst: ^[dynamic]u8) -> Error {
	regs: [HLL_REGISTERS]u8
	if !sparse_decode_into(src, regs[:], false) {
		return .Corrupted
	}
	if resize(dst, HLL_DENSE_SIZE) != nil {
		return .Out_Of_Memory
	}
	if raw_data(dst^) != raw_data(src) {
		copy(dst[:HLL_HDR_SIZE], src[:HLL_HDR_SIZE])
	}
	dst[4] = HLL_DENSE
	dense_encode_from(dst[HLL_HDR_SIZE:], regs[:])
	return .None
}

sparse_promote :: proc(buf: ^[dynamic]u8) -> Error {
	regs: [HLL_REGISTERS]u8
	if !sparse_decode_into(buf[:], regs[:], false) {
		return .Corrupted
	}
	if resize(buf, HLL_DENSE_SIZE) != nil {
		return .Out_Of_Memory
	}
	buf[4] = HLL_DENSE
	dense_encode_from(buf[HLL_HDR_SIZE:], regs[:])
	return .None
}

hll_dyn_set :: proc(buf: ^[dynamic]u8, index: int, count: u8, sparse_max_bytes: int) -> (changed: bool, err: Error) {
	if buf[4] == HLL_DENSE {
		return dense_set(buf[HLL_HDR_SIZE:], index, count), .None
	}
	if int(count) <= HLL_SPARSE_VAL_MAX_VALUE {
		loc, found := sparse_locate(buf[:], index, sparse_cursor_start())
		if !found {
			return false, .Corrupted
		}
		outcome, apply_err := sparse_apply_set(buf, index, loc, count, sparse_max_bytes)
		if apply_err != .None {
			return false, apply_err
		}
		switch outcome {
		case .Unchanged:
			return false, .None
		case .Changed:
			return true, .None
		case .Promote:
		}
	}
	if promote_err := sparse_promote(buf); promote_err != .None {
		return false, promote_err
	}
	return dense_set(buf[HLL_HDR_SIZE:], index, count), .None
}

sparse_set :: proc(buf: ^[]u8, index: int, count: u8, sparse_max_bytes: int, allocator: runtime.Allocator) -> (bool, Error) {
	if !hll_is_valid(buf^) {
		return false, .Wrong_Type
	}
	if index < 0 || index >= HLL_REGISTERS {
		return false, .None
	}
	d := dynamic_view(buf^, allocator)
	changed, err := hll_dyn_set(&d, index, count, sparse_max_bytes)
	if changed && err == .None {
		hll_invalidate_cache(d[:])
	}
	buf^ = dynamic_finish(&d)
	return changed, err
}

sparse_store_registers :: proc(buf: ^[dynamic]u8, max_regs: ^[HLL_REGISTERS]u8, sparse_max_bytes: int) -> Error {
	if buf[4] == HLL_DENSE {
		dense_merge_registers(buf[HLL_HDR_SIZE:], max_regs)
		return .None
	}
	cur := sparse_cursor_start()
	for index in 0 ..< HLL_REGISTERS {
		count := max_regs[index]
		if count == 0 {
			continue
		}
		if int(count) <= HLL_SPARSE_VAL_MAX_VALUE {
			loc, found := sparse_locate(buf[:], index, cur)
			if found && loc.prev_pos == HLL_POS_UNKNOWN {
				loc, found = sparse_locate(buf[:], index, sparse_cursor_start())
			}
			if !found {
				return .Corrupted
			}
			outcome, apply_err := sparse_apply_set(buf, index, loc, count, sparse_max_bytes)
			if apply_err != .None {
				return apply_err
			}
			if outcome != .Promote {
				cur = sparse_cursor_after(loc)
				continue
			}
		}
		if promote_err := sparse_promote(buf); promote_err != .None {
			return promote_err
		}
		dense_merge_registers(buf[HLL_HDR_SIZE:], max_regs)
		return .None
	}
	return .None
}

@(private = "file")
append_decimal :: proc(out: ^[dynamic]u8, v: int) {
	digits: [20]u8
	n := 0
	x := v
	for {
		digits[n] = u8('0' + x % 10)
		n += 1
		x /= 10
		if x == 0 {
			break
		}
	}
	for i := n - 1; i >= 0; i -= 1 {
		append(out, digits[i])
	}
}

sparse_debug_append :: proc(s: []u8, out: ^[dynamic]u8) {
	it := sparse_iter(s)
	first := true
	for {
		op, runlen, regval, ok := sparse_next(&it)
		if !ok {
			break
		}
		if !first {
			append(out, ' ')
		}
		first = false
		switch op {
		case .Zero:
			append(out, 'z', ':')
			append_decimal(out, runlen)
		case .XZero:
			append(out, 'Z', ':')
			append_decimal(out, runlen)
		case .Val:
			append(out, 'v', ':')
			append_decimal(out, regval)
			append(out, ',')
			append_decimal(out, runlen)
		}
	}
}
