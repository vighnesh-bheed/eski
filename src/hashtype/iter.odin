package hashtype

import lp "../listpack"

Iterator :: struct {
	h: Hash,
	fptr: [^]u8,
	vptr: [^]u8,
	tptr: [^]u8,
	idx: int,
	expire: u64,
	skip_expired: bool,
	now: u64,
	bank: int,
	blob: ^Blob,
}

iterator :: proc "contextless" (h: Hash) -> Iterator {
	return Iterator{h = h, idx = -1}
}

iterator_live :: proc "contextless" (h: Hash, now: u64) -> Iterator {
	return Iterator{h = h, idx = -1, skip_expired = true, now = now}
}

pack_first :: #force_inline proc "contextless" (p: [^]u8) -> [^]u8 {
	if p == nil || p[lp.LP_HDR_SIZE] == lp.LP_EOF {
		return nil
	}
	return lp.padd(p, lp.LP_HDR_SIZE)
}

pack_next :: #force_inline proc "contextless" (p: [^]u8) -> [^]u8 {
	if p == nil {
		return nil
	}
	n := lp.lp_skip(p)
	if n[0] == lp.LP_EOF {
		return nil
	}
	return n
}

next :: proc "contextless" (it: ^Iterator) -> bool {
	if it.h == nil {
		return false
	}
	for {
		it.expire = NO_FIELD_DEADLINE
		if it.h.encoding == .Hashtable {
			for {
				slots, cap := table_bank(it.h.table, it.bank)
				it.idx += 1
				if it.idx >= cap {
					if it.bank == 1 {
						return false
					}
					it.bank = 1
					it.idx = -1
					continue
				}
				if blob_live(slots[it.idx].blob) {
					it.blob = slots[it.idx].blob
					it.expire = table_field_expire(it.h.table, it.blob)
					break
				}
			}
		} else {
			if it.idx == -1 {
				it.fptr = pack_first(it.h.lp)
			} else {
				last := it.vptr
				if it.h.encoding == .Listpack_Ex {
					last = it.tptr
				}
				it.fptr = pack_next(last)
			}
			if it.fptr == nil {
				return false
			}
			it.idx += 1
			it.vptr = pack_next(it.fptr)
			if it.vptr == nil {
				return false
			}
			if it.h.encoding == .Listpack_Ex {
				it.tptr = pack_next(it.vptr)
				if it.tptr == nil {
					return false
				}
				v := value_from_lp(it.tptr)
				if v.ival != 0 {
					it.expire = u64(v.ival)
				}
			}
		}
		if !it.skip_expired || it.expire == NO_FIELD_DEADLINE || it.expire >= it.now {
			return true
		}
	}
}

current_field :: proc "contextless" (it: ^Iterator) -> Value {
	if it.h.encoding == .Hashtable {
		return Value{str = blob_field(it.blob)}
	}
	return value_from_lp(it.fptr)
}

current_value :: proc "contextless" (it: ^Iterator) -> Value {
	if it.h.encoding == .Hashtable {
		return Value{str = blob_value(it.blob)}
	}
	return value_from_lp(it.vptr)
}

current_expire :: proc "contextless" (it: ^Iterator) -> u64 {
	return it.expire
}

current :: proc "contextless" (it: ^Iterator, what: int) -> Value {
	if what == OBJ_HASH_KEY {
		return current_field(it)
	}
	return current_value(it)
}
