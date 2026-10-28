package hll

import "base:intrinsics"
import core_hash "core:hash"

HLL_HASH_SEED :: 0xadc83b19

murmurhash64a :: proc "contextless" (key: []u8, seed: u64) -> u64 #no_bounds_check {
	return core_hash.murmur64a(key, seed)
}

hll_pat_len_from_hash :: #force_inline proc "contextless" (hash: u64) -> (index: int, count: u8) {
	index = int(hash & HLL_P_MASK)
	rest := (hash >> HLL_P) | (u64(1) << HLL_Q)
	count = u8(intrinsics.count_trailing_zeros(rest)) + 1
	return
}

hll_pat_len :: proc "contextless" (elem: []u8) -> (index: int, count: u8) {
	return hll_pat_len_from_hash(murmurhash64a(elem, HLL_HASH_SEED))
}
