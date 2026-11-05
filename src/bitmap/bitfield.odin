package bitmap

Overflow :: enum u8 {
	Wrap,
	Sat,
	Fail,
}

Bitfield_Opcode :: enum u8 {
	Get,
	Set,
	Incrby,
}

Field_Command :: struct {
	offset:   u64,
	value:    i64,
	opcode:   Bitfield_Opcode,
	overflow: Overflow,
	bits:     u8,
	signed:   bool,
}

Bitfield_Reply :: struct {
	value: i64,
	null:  bool,
}

Bitfield_Program :: struct {
	ops:              [dynamic]Field_Command,
	replies:          [dynamic]Bitfield_Reply,
	readonly:         bool,
	last_written_bit: u64,
}

bitfield_program_destroy :: proc(prog: ^Bitfield_Program) {
	delete(prog.ops)
	delete(prog.replies)
	prog^ = {}
}

field_window :: #force_inline proc "contextless" (p: []u8, byte_index: u64) -> (window: [16]u8) #no_bounds_check {
	n := u64(len(p))
	for k in u64(0) ..< 9 {
		at := byte_index + k
		if at < n {
			window[k] = p[at]
		}
	}
	return
}

field_mask :: #force_inline proc "contextless" (bits: u64) -> u64 {
	if bits >= 64 {
		return max(u64)
	}
	return (u64(1) << bits) - 1
}

extract_field :: #force_inline proc "contextless" (q: [^]u8, shift, bits: u64) -> u64 #no_bounds_check {
	w := load_be_word(q) << shift
	if shift + bits > 64 {
		w |= u64(q[8]) >> (8 - shift)
	}
	return w >> (64 - bits)
}

deposit_field :: #force_inline proc "contextless" (q: [^]u8, shift, bits, value: u64) #no_bounds_check {
	w := load_be_word(q)
	if shift + bits <= 64 {
		place := 64 - shift - bits
		mask := field_mask(bits) << place
		w = (w &~ mask) | ((value << place) & mask)
		store_be_word(q, w)
		return
	}
	spill := shift + bits - 64
	high_mask := max(u64) >> shift
	w = (w &~ high_mask) | ((value >> spill) & high_mask)
	store_be_word(q, w)
	keep := u8(0xff) >> spill
	q[8] = (q[8] & keep) | u8((value << (8 - spill)) & 0xff)
}

get_unsigned_bitfield :: proc "contextless" (p: []u8, offset_in: u64, bits: u64) -> u64 {
	if bits == 0 || bits > 64 {
		return 0
	}
	byte_index := offset_in >> 3
	shift := offset_in & 7
	if byte_index + 9 <= u64(len(p)) {
		return extract_field(raw_data(p)[byte_index:], shift, bits)
	}
	if byte_index >= u64(len(p)) {
		return 0
	}
	window := field_window(p, byte_index)
	return extract_field(&window[0], shift, bits)
}

get_signed_bitfield :: proc "contextless" (p: []u8, offset: u64, bits: u64) -> i64 {
	if bits == 0 || bits > 64 {
		return 0
	}
	raw := get_unsigned_bitfield(p, offset, bits)
	pad := 64 - bits
	return i64(raw << pad) >> pad
}

set_unsigned_bitfield :: proc "contextless" (p: []u8, offset_in: u64, bits: u64, value: u64) {
	if bits == 0 || bits > 64 {
		return
	}
	byte_index := offset_in >> 3
	shift := offset_in & 7
	n := u64(len(p))
	if byte_index + 9 <= n {
		deposit_field(raw_data(p)[byte_index:], shift, bits, value)
		return
	}
	if byte_index >= n {
		return
	}
	window := field_window(p, byte_index)
	deposit_field(&window[0], shift, bits, value)
	for k in u64(0) ..< 9 {
		at := byte_index + k
		if at < n {
			p[at] = window[k]
		}
	}
}

set_signed_bitfield :: proc "contextless" (p: []u8, offset: u64, bits: u64, value: i64) {
	set_unsigned_bitfield(p, offset, bits, u64(value))
}

unsigned_wrap :: proc "contextless" (value: u64, incr: i64, bits: u64) -> u64 {
	return (value + u64(incr)) & field_mask(bits)
}

signed_wrap :: proc "contextless" (value: i64, incr: i64, bits: u64) -> i64 {
	sum := u64(value) + u64(incr)
	if bits == 0 || bits >= 64 {
		return i64(sum)
	}
	pad := 64 - bits
	return i64(sum << pad) >> pad
}

Field_Bound :: enum i8 {
	Below = -1,
	Within = 0,
	Above = 1,
}

unsigned_bound :: proc "contextless" (value: u64, incr: i64, bits: u64) -> Field_Bound {
	top := field_mask(bits)
	if value > top {
		return .Above
	}
	total := i128(value) + i128(incr)
	if total > i128(top) {
		return .Above
	}
	return .Below if total < 0 else .Within
}

wrapped_gap :: proc "contextless" (limit, value: i64) -> i64 {
	return i64(u64(limit) - u64(value))
}

signed_bound :: proc "contextless" (value: i64, incr: i64, bits: u64) -> Field_Bound {
	if bits == 0 || bits >= 64 {
		total := i128(value) + i128(incr)
		if total > i128(max(i64)) {
			return .Above
		}
		return .Below if total < i128(min(i64)) else .Within
	}
	top := i64(field_mask(bits - 1))
	bottom := ~top
	if value > top || incr > wrapped_gap(top, value) {
		return .Above
	}
	if value < bottom || incr < wrapped_gap(bottom, value) {
		return .Below
	}
	return .Within
}

unsigned_settle :: proc "contextless" (value: u64, incr: i64, bits: u64, mode: Overflow) -> (stored: u64, ok: bool) {
	if mode == .Wrap {
		return unsigned_wrap(value, incr, bits), true
	}
	switch unsigned_bound(value, incr, bits) {
	case .Within:
		return value + u64(incr), true
	case .Above:
		return field_mask(bits), mode == .Sat
	case .Below:
	}
	return 0, mode == .Sat
}

signed_settle :: proc "contextless" (value: i64, incr: i64, bits: u64, mode: Overflow) -> (stored: i64, ok: bool) {
	if mode == .Wrap {
		return signed_wrap(value, incr, bits), true
	}
	top := max(i64) if bits == 0 || bits >= 64 else i64(field_mask(bits - 1))
	switch signed_bound(value, incr, bits) {
	case .Within:
		return value + incr, true
	case .Above:
		return top, mode == .Sat
	case .Below:
	}
	return ~top, mode == .Sat
}

parse_overflow :: proc "contextless" (s: []u8) -> (overflow: Overflow, err: Error) {
	word := c_string(s)
	switch {
	case equal_fold(word, "wrap"):
		return .Wrap, .None
	case equal_fold(word, "sat"):
		return .Sat, .None
	case equal_fold(word, "fail"):
		return .Fail, .None
	}
	return .Wrap, .Overflow_Type
}

bitfield_parse :: proc(
	prog: ^Bitfield_Program,
	args: [][]u8,
	read_only_command := false,
	max_bulk_len := PROTO_MAX_BULK_LEN,
) -> Error {
	clear(&prog.ops)
	clear(&prog.replies)
	prog.readonly = true
	prog.last_written_bit = 0
	mode := Overflow.Wrap
	writes := false
	i := 0
	for i < len(args) {
		word := c_string(args[i])
		remain := len(args) - i - 1
		opcode: Bitfield_Opcode
		switch {
		case equal_fold(word, "get") && remain >= 2:
			opcode = .Get
		case equal_fold(word, "set") && remain >= 3:
			opcode = .Set
		case equal_fold(word, "incrby") && remain >= 3:
			opcode = .Incrby
		case equal_fold(word, "overflow") && remain >= 1:
			mode = parse_overflow(args[i + 1]) or_return
			i += 2
			continue
		case:
			return .Syntax
		}
		signed, bits := parse_bitfield_type(args[i + 1]) or_return
		offset := parse_bit_offset(args[i + 2], true, bits, max_bulk_len) or_return
		op := Field_Command {
			offset   = offset,
			opcode   = opcode,
			overflow = mode,
			bits     = u8(bits),
			signed   = signed,
		}
		if opcode == .Get {
			i += 3
		} else {
			op.value = parse_integer(args[i + 3]) or_return
			writes = true
			prog.last_written_bit = max(prog.last_written_bit, offset + u64(bits) - 1)
			i += 4
		}
		append(&prog.ops, op)
	}
	if writes {
		if read_only_command {
			return .Bitfield_Read_Only
		}
		prog.readonly = false
	}
	return .None
}

bitfield_get :: proc "contextless" (data: []u8, op: Field_Command) -> i64 #no_bounds_check {
	if op.signed {
		return get_signed_bitfield(data, op.offset, u64(op.bits))
	}
	return i64(get_unsigned_bitfield(data, op.offset, u64(op.bits)))
}

bitfield_apply :: proc "contextless" (data: []u8, op: Field_Command, grown: bool) -> (reply: Bitfield_Reply, counted: bool) {
	bits := u64(op.bits)
	if op.signed {
		old := get_signed_bitfield(data, op.offset, bits)
		value, incr := op.value, i64(0)
		if op.opcode == .Incrby {
			value, incr = old, op.value
		}
		next, stored := signed_settle(value, incr, bits, op.overflow)
		if !stored {
			return {null = true}, false
		}
		set_signed_bitfield(data, op.offset, bits, next)
		if op.opcode == .Set {
			return {value = old}, grown || (u64(old) ~ u64(next)) & field_mask(bits) != 0
		}
		return {value = next}, grown || (u64(old) ~ u64(next)) & field_mask(bits) != 0
	}
	old := get_unsigned_bitfield(data, op.offset, bits)
	value, incr := u64(op.value), i64(0)
	if op.opcode == .Incrby {
		value, incr = old, op.value
	}
	next, stored := unsigned_settle(value, incr, bits, op.overflow)
	if !stored {
		return {null = true}, false
	}
	set_unsigned_bitfield(data, op.offset, bits, next)
	if op.opcode == .Set {
		return {value = i64(old)}, grown || (old ~ next) & field_mask(bits) != 0
	}
	return {value = i64(next)}, grown || (old ~ next) & field_mask(bits) != 0
}

bitfield_execute :: proc(
	buf: ^[]u8,
	prog: ^Bitfield_Program,
	allocator := RAW_HEAP_ALLOCATOR,
	capacity: ^int = nil,
) -> (
	changes: int,
	err: Error,
) {
	clear(&prog.replies)
	reserve(&prog.replies, len(prog.ops))
	need := u64(0)
	writes := false
	for op in prog.ops {
		if op.opcode != .Get {
			writes = true
			need = max(need, op.offset + u64(op.bits) - 1)
		}
	}
	before := len(buf^)
	if writes {
		if grow_zero(buf, int(need >> 3) + 1, allocator, capacity) != .None {
			return 0, .Out_Of_Memory
		}
	}
	grown := len(buf^) > before
	data := buf^
	for op in prog.ops {
		if op.opcode == .Get {
			append(&prog.replies, Bitfield_Reply{value = bitfield_get(data, op)})
			continue
		}
		reply, counted := bitfield_apply(data, op, grown)
		append(&prog.replies, reply)
		if counted {
			changes += 1
		}
	}
	return changes, .None
}
