package hashtype

import lp "../listpack"

Iterator :: struct {
	h: Hash,
	at_field: [^]u8,
	at_value: [^]u8,
	at_deadline: [^]u8,
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
	if p == nil || p[lp.PACK_HEADER_BYTES] == lp.PACK_END {
		return nil
	}
	return lp.padd(p, lp.PACK_HEADER_BYTES)
}

pack_next :: #force_inline proc "contextless" (p: [^]u8) -> [^]u8 {
	if p == nil {
		return nil
	}
	n := lp.lp_skip(p)
	if n[0] == lp.PACK_END {
		return nil
	}
	return n
}

next :: proc "contextless" (it: ^Iterator) -> bool {
	if it.h == nil {
		return false
	}
	for {
		it.expire = DEADLINE_UNSET
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
				it.at_field = pack_first(it.h.lp)
			} else {
				last := it.at_value
				if it.h.encoding == .Listpack_Ex {
					last = it.at_deadline
				}
				it.at_field = pack_next(last)
			}
			if it.at_field == nil {
				return false
			}
			it.idx += 1
			it.at_value = pack_next(it.at_field)
			if it.at_value == nil {
				return false
			}
			if it.h.encoding == .Listpack_Ex {
				it.at_deadline = pack_next(it.at_value)
				if it.at_deadline == nil {
					return false
				}
				v := value_from_lp(it.at_deadline)
				if v.ival != 0 {
					it.expire = u64(v.ival)
				}
			}
		}
		if !it.skip_expired || it.expire == DEADLINE_UNSET || it.expire >= it.now {
			return true
		}
	}
}

current_field :: proc "contextless" (it: ^Iterator) -> Value {
	if it.h.encoding == .Hashtable {
		return Value{str = blob_field(it.blob)}
	}
	return value_from_lp(it.at_field)
}

current_value :: proc "contextless" (it: ^Iterator) -> Value {
	if it.h.encoding == .Hashtable {
		return Value{str = blob_value(it.blob)}
	}
	return value_from_lp(it.at_value)
}

current_expire :: proc "contextless" (it: ^Iterator) -> u64 {
	return it.expire
}
