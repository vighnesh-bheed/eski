package hll

import "base:runtime"

HLL_P :: 14
HLL_Q :: 64 - HLL_P
HLL_REGISTERS :: 1 << HLL_P
HLL_P_MASK :: HLL_REGISTERS - 1
HLL_BITS :: 6
HLL_REGISTER_MAX :: (1 << HLL_BITS) - 1
HLL_HDR_SIZE :: 16
HLL_DENSE_SIZE :: HLL_HDR_SIZE + (HLL_REGISTERS * HLL_BITS + 7) / 8
HLL_DENSE :: 0
HLL_SPARSE :: 1
HLL_MAX_ENCODING :: 1
HLL_SPARSE_MAX_BYTES_DEFAULT :: 3000
HLL_MAGIC :: "HYLL"
HLL_CACHE_INVALID_BIT :: 0x80
HLL_EMPTY_SPARSE_SIZE :: HLL_HDR_SIZE + 2

HLL_ERR_WRONGTYPE :: "WRONGTYPE Key is not a valid HyperLogLog string value."
HLL_ERR_INVALIDOBJ :: "INVALIDOBJ Corrupted HLL object detected"
HLL_ERR_NO_KEY :: "ERR The specified key does not exist"
HLL_ERR_NOT_SPARSE :: "ERR HLL encoding is not sparse"
HLL_ERR_UNKNOWN_SUBCOMMAND_FMT :: "ERR Unknown PFDEBUG subcommand '%s'"
HLL_ERR_OOM :: "ERR out of memory"

@(rodata)
HLL_EMPTY_SPARSE := [HLL_EMPTY_SPARSE_SIZE]u8{'H', 'Y', 'L', 'L', HLL_SPARSE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, HLL_CACHE_INVALID_BIT, 0x7f, 0xff}

Error :: enum u8 {
	None,
	Wrong_Type,
	Corrupted,
	Out_Of_Memory,
}

hll_error_message :: proc "contextless" (err: Error) -> string {
	switch err {
	case .None:
		return ""
	case .Wrong_Type:
		return HLL_ERR_WRONGTYPE
	case .Corrupted:
		return HLL_ERR_INVALIDOBJ
	case .Out_Of_Memory:
		return HLL_ERR_OOM
	}
	return ""
}

hll_new_sparse :: proc(allocator := context.allocator) -> []u8 {
	buf := make([]u8, HLL_EMPTY_SPARSE_SIZE, allocator)
	if buf != nil {
		copy(buf, HLL_EMPTY_SPARSE[:])
	}
	return buf
}

hll_validate :: proc "contextless" (buf: []u8) -> (ok: bool, msg: string) {
	if len(buf) < HLL_HDR_SIZE {
		return false, HLL_ERR_WRONGTYPE
	}
	if buf[0] != HLL_MAGIC[0] || buf[1] != HLL_MAGIC[1] || buf[2] != HLL_MAGIC[2] || buf[3] != HLL_MAGIC[3] {
		return false, HLL_ERR_WRONGTYPE
	}
	if buf[4] > HLL_MAX_ENCODING {
		return false, HLL_ERR_WRONGTYPE
	}
	if buf[4] == HLL_DENSE && len(buf) != HLL_DENSE_SIZE {
		return false, HLL_ERR_WRONGTYPE
	}
	return true, ""
}

hll_is_valid :: #force_inline proc "contextless" (buf: []u8) -> bool {
	ok, _ := hll_validate(buf)
	return ok
}

hll_encoding_name :: proc "contextless" (buf: []u8) -> string {
	if !hll_is_valid(buf) {
		return ""
	}
	if buf[4] == HLL_DENSE {
		return "dense"
	}
	return "sparse"
}

hll_cache_valid :: #force_inline proc "contextless" (buf: []u8) -> bool {
	return buf[15] & HLL_CACHE_INVALID_BIT == 0
}

hll_invalidate_cache :: #force_inline proc "contextless" (buf: []u8) {
	buf[15] |= HLL_CACHE_INVALID_BIT
}

hll_cached_card :: proc "contextless" (buf: []u8) -> u64 {
	card: u64
	for i in 0 ..< 8 {
		card |= u64(buf[8 + i]) << (8 * uint(i))
	}
	return card
}

hll_store_card :: proc "contextless" (buf: []u8, card: u64) {
	for i in 0 ..< 8 {
		buf[8 + i] = u8(card >> (8 * uint(i)))
	}
}

@(private)
dynamic_view :: proc "contextless" (buf: []u8, allocator: runtime.Allocator) -> [dynamic]u8 {
	raw := runtime.Raw_Dynamic_Array {
		data      = raw_data(buf),
		len       = len(buf),
		cap       = len(buf),
		allocator = allocator,
	}
	return transmute([dynamic]u8)raw
}

@(private)
dynamic_finish :: proc(d: ^[dynamic]u8) -> []u8 {
	if cap(d^) != len(d^) {
		shrink(d)
	}
	return d[:]
}

@(private)
scratch_load :: proc(scratch: ^[dynamic]u8, src: []u8) -> Error {
	if resize(scratch, len(src)) != nil {
		return .Out_Of_Memory
	}
	copy(scratch[:], src)
	return .None
}

pfadd_apply :: proc(cur: []u8, elems: [][]u8, scratch: ^[dynamic]u8, sparse_max_bytes: int) -> (changed: bool, in_scratch: bool, err: Error) {
	if cur[4] == HLL_DENSE {
		regs := cur[HLL_HDR_SIZE:]
		for elem in elems {
			index, count := hll_pat_len(elem)
			if dense_set(regs, index, count) {
				changed = true
			}
		}
		if changed {
			hll_invalidate_cache(cur)
		}
		return
	}
	for elem in elems {
		index, count := hll_pat_len(elem)
		if !in_scratch {
			if int(count) <= HLL_SPARSE_VAL_MAX_VALUE {
				value, found := sparse_register_at(cur, index)
				if !found {
					err = .Corrupted
					return
				}
				if value >= int(count) {
					continue
				}
			}
			if load_err := scratch_load(scratch, cur); load_err != .None {
				err = load_err
				return
			}
			in_scratch = true
		}
		set_changed, set_err := hll_dyn_set(scratch, index, count, sparse_max_bytes)
		if set_err != .None {
			err = set_err
			return
		}
		if set_changed {
			changed = true
		}
	}
	if changed && in_scratch {
		hll_invalidate_cache(scratch[:])
	}
	return
}

pfmerge_apply :: proc(dst: []u8, dst_exists: bool, max_regs: ^[HLL_REGISTERS]u8, use_dense: bool, scratch: ^[dynamic]u8, sparse_max_bytes: int) -> (in_scratch: bool, err: Error) {
	if dst_exists && dst[4] == HLL_DENSE {
		dense_merge_registers(dst[HLL_HDR_SIZE:], max_regs)
		hll_invalidate_cache(dst)
		return false, .None
	}
	source := dst if dst_exists else HLL_EMPTY_SPARSE[:]
	if use_dense {
		if convert_err := sparse_to_dense_into(source, scratch); convert_err != .None {
			return false, convert_err
		}
	} else if load_err := scratch_load(scratch, source); load_err != .None {
		return false, load_err
	}
	if store_err := sparse_store_registers(scratch, max_regs, sparse_max_bytes); store_err != .None {
		return false, store_err
	}
	hll_invalidate_cache(scratch[:])
	return true, .None
}

to_dense_apply :: proc(cur: []u8, scratch: ^[dynamic]u8) -> (converted: bool, err: Error) {
	if cur[4] == HLL_DENSE {
		return false, .None
	}
	if convert_err := sparse_to_dense_into(cur, scratch); convert_err != .None {
		return false, convert_err
	}
	return true, .None
}

hll_add :: proc(
	buf: ^[]u8,
	elem: []u8,
	sparse_max_bytes := HLL_SPARSE_MAX_BYTES_DEFAULT,
	allocator := context.allocator,
) -> (
	changed: bool,
	err: Error,
) {
	elems := [1][]u8{elem}
	updated: int
	updated, err = hll_pfadd(buf, elems[:], false, sparse_max_bytes, allocator)
	return updated > 0, err
}

hll_pfadd :: proc(
	buf: ^[]u8,
	elems: [][]u8,
	created: bool,
	sparse_max_bytes := HLL_SPARSE_MAX_BYTES_DEFAULT,
	allocator := context.allocator,
) -> (
	updated: int,
	err: Error,
) {
	if created && len(buf^) == 0 {
		buf^ = hll_new_sparse(allocator)
		if buf^ == nil {
			return 0, .Out_Of_Memory
		}
	}
	if !hll_is_valid(buf^) {
		return 0, .Wrong_Type
	}
	d := dynamic_view(buf^, allocator)
	changed := false
	for elem in elems {
		index, count := hll_pat_len(elem)
		set_changed, set_err := hll_dyn_set(&d, index, count, sparse_max_bytes)
		if set_err != .None {
			err = set_err
			break
		}
		if set_changed {
			changed = true
		}
	}
	if changed && err == .None {
		hll_invalidate_cache(d[:])
	}
	buf^ = dynamic_finish(&d)
	if err != .None {
		return 0, err
	}
	if created {
		updated += 1
	}
	if changed {
		updated += 1
	}
	return updated, .None
}

hll_count :: proc "contextless" (buf: []u8, invalid: ^bool) -> u64 {
	if !hll_is_valid(buf) {
		invalid^ = true
		return 0
	}
	if hll_cache_valid(buf) {
		return hll_cached_card(buf)
	}
	bad := false
	card := hll_estimate(buf, &bad)
	if bad {
		invalid^ = true
		return 0
	}
	hll_store_card(buf, card)
	return card
}

hll_merge_into :: proc "contextless" (max_regs: ^[HLL_REGISTERS]u8, buf: []u8) -> Error {
	if !hll_is_valid(buf) {
		return .Wrong_Type
	}
	if buf[4] == HLL_DENSE {
		dense_decode_into(buf[HLL_HDR_SIZE:], max_regs[:], true)
		return .None
	}
	if !sparse_decode_into(buf, max_regs[:], true) {
		return .Corrupted
	}
	return .None
}

@(private)
is_missing :: #force_inline proc "contextless" (buf: []u8) -> bool {
	return len(buf) == 0 && raw_data(buf) == nil
}

hll_count_union :: proc "contextless" (srcs: [][]u8) -> (card: u64, err: Error) {
	regs: [HLL_REGISTERS]u8
	for src in srcs {
		if is_missing(src) {
			continue
		}
		if merge_err := hll_merge_into(&regs, src); merge_err != .None {
			return 0, merge_err
		}
	}
	return hll_estimate_raw(&regs), .None
}

hll_store_registers :: proc(
	dst: ^[]u8,
	max_regs: ^[HLL_REGISTERS]u8,
	use_dense: bool,
	sparse_max_bytes := HLL_SPARSE_MAX_BYTES_DEFAULT,
	allocator := context.allocator,
) -> Error {
	if !hll_is_valid(dst^) {
		return .Wrong_Type
	}
	scratch := make([dynamic]u8, 0, 0, allocator)
	in_scratch, err := pfmerge_apply(dst^, true, max_regs, use_dense, &scratch, sparse_max_bytes)
	if in_scratch {
		old := dst^
		dst^ = dynamic_finish(&scratch)
		delete(old, allocator)
	} else {
		delete(scratch)
	}
	return err
}

hll_merge :: proc(
	dst: ^[]u8,
	dst_exists: bool,
	srcs: [][]u8,
	sparse_max_bytes := HLL_SPARSE_MAX_BYTES_DEFAULT,
	allocator := context.allocator,
) -> Error {
	regs: [HLL_REGISTERS]u8
	use_dense := false
	if dst_exists {
		if !hll_is_valid(dst^) {
			return .Wrong_Type
		}
		if dst[4] == HLL_DENSE {
			use_dense = true
		}
		if merge_err := hll_merge_into(&regs, dst^); merge_err != .None {
			return merge_err
		}
	}
	for src in srcs {
		if is_missing(src) {
			continue
		}
		if !hll_is_valid(src) {
			return .Wrong_Type
		}
		if src[4] == HLL_DENSE {
			use_dense = true
		}
		if merge_err := hll_merge_into(&regs, src); merge_err != .None {
			return merge_err
		}
	}
	scratch := make([dynamic]u8, 0, 0, allocator)
	in_scratch, err := pfmerge_apply(dst^ if dst_exists else nil, dst_exists, &regs, use_dense, &scratch, sparse_max_bytes)
	if in_scratch {
		old := dst^
		dst^ = dynamic_finish(&scratch)
		if dst_exists {
			delete(old, allocator)
		}
	} else {
		delete(scratch)
	}
	return err
}

hll_to_dense :: proc(buf: ^[]u8, allocator := context.allocator) -> (converted: bool, err: Error) {
	if !hll_is_valid(buf^) {
		return false, .Wrong_Type
	}
	if buf[4] == HLL_DENSE {
		return false, .None
	}
	d := dynamic_view(buf^, allocator)
	err = sparse_promote(&d)
	buf^ = dynamic_finish(&d)
	return err == .None, err
}

hll_get_registers :: proc "contextless" (buf: []u8, out: ^[HLL_REGISTERS]u8) -> Error {
	if !hll_is_valid(buf) {
		return .Wrong_Type
	}
	if buf[4] == HLL_DENSE {
		dense_decode_into(buf[HLL_HDR_SIZE:], out[:], false)
		return .None
	}
	if !sparse_decode_into(buf, out[:], false) {
		return .Corrupted
	}
	return .None
}

hll_get_register :: proc "contextless" (buf: []u8, index: int) -> (value: u8, err: Error) {
	if !hll_is_valid(buf) {
		return 0, .Wrong_Type
	}
	if index < 0 || index >= HLL_REGISTERS {
		return 0, .None
	}
	if buf[4] == HLL_DENSE {
		return dense_get(buf[HLL_HDR_SIZE:], index), .None
	}
	reghisto: [64]int
	if !sparse_reg_histo(buf, &reghisto) {
		return 0, .Corrupted
	}
	found_value, found := sparse_register_at(buf, index)
	if !found {
		return 0, .Corrupted
	}
	return u8(found_value), .None
}

hll_decode_sparse_for_debug :: proc(buf: []u8, allocator := context.allocator) -> (decoded: string, ok: bool) {
	if !hll_is_valid(buf) || buf[4] != HLL_SPARSE {
		return "", false
	}
	out := make([dynamic]u8, 0, 0, allocator)
	sparse_debug_append(buf, &out)
	if len(out) == 0 {
		delete(out)
		return "", true
	}
	return string(dynamic_finish(&out)), true
}

hll_free :: proc(buf: []u8, allocator := context.allocator) {
	delete(buf, allocator)
}

hll_clone :: proc(buf: []u8, allocator := context.allocator) -> []u8 {
	out := make([]u8, len(buf), allocator)
	if out != nil {
		copy(out, buf)
	}
	return out
}
