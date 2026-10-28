package hll

HLL_TEST_CYCLES :: 8
HLL_TEST_ELEMENTS :: 100_000
HLL_TEST_SPARSE_LIMIT :: 8192

@(private = "file")
SELFTEST_CHECKPOINTS := [?]int{1, 10, 100, 1000, 5000, 20000, HLL_TEST_ELEMENTS}

splitmix64 :: proc "contextless" (state: ^u64) -> u64 {
	state^ += 0x9e3779b97f4a7c15
	z := state^
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

@(private = "file")
selftest_elem :: #force_inline proc "contextless" (out: ^[8]u8, base: u64, n: int) {
	v := base + u64(n)
	for i in 0 ..< 8 {
		out[i] = u8(v >> (8 * uint(i)))
	}
}

@(private = "file")
selftest_registers :: proc() -> (ok: bool, msg: string) {
	state := u64(0x5eed)
	area: [HLL_DENSE_REG_BYTES]u8
	expect: [HLL_REGISTERS]u8
	decoded: [HLL_REGISTERS]u8
	for _ in 0 ..< HLL_TEST_CYCLES {
		for i in 0 ..< HLL_REGISTERS {
			v := u8(splitmix64(&state) & HLL_REGISTER_MAX)
			expect[i] = v
			dense_put(area[:], i, v)
		}
		for i in 0 ..< HLL_REGISTERS {
			if dense_get(area[:], i) != expect[i] {
				return false, "TESTFAILED dense register read back differs"
			}
		}
		dense_decode_into(area[:], decoded[:], false)
		if decoded != expect {
			return false, "TESTFAILED dense block decode differs"
		}
	}
	return true, ""
}

hll_selftest :: proc(
	seed: u64,
	sparse_max_bytes := HLL_SPARSE_MAX_BYTES_DEFAULT,
	allocator := context.allocator,
) -> (
	ok: bool,
	msg: string,
) {
	ok, msg = selftest_registers()
	if !ok {
		return
	}
	limit := clamp(sparse_max_bytes, 0, HLL_TEST_SPARSE_LIMIT)
	state := seed
	base := splitmix64(&state)
	sparse := hll_new_sparse(allocator)
	dense := hll_new_sparse(allocator)
	defer hll_free(sparse, allocator)
	defer hll_free(dense, allocator)
	if sparse == nil || dense == nil {
		return false, HLL_ERR_OOM
	}
	if _, err := hll_to_dense(&dense, allocator); err != .None {
		return false, "TESTFAILED dense conversion of the empty value"
	}
	expect: [HLL_REGISTERS]u8
	got: [HLL_REGISTERS]u8
	elem: [8]u8
	added := 0
	for checkpoint in SELFTEST_CHECKPOINTS {
		for added < checkpoint {
			selftest_elem(&elem, base, added)
			index, count := hll_pat_len(elem[:])
			expect[index] = max(expect[index], count)
			if _, err := hll_add(&sparse, elem[:], limit, allocator); err != .None {
				return false, "TESTFAILED add to the sparse value failed"
			}
			if _, err := hll_add(&dense, elem[:], limit, allocator); err != .None {
				return false, "TESTFAILED add to the dense value failed"
			}
			added += 1
		}
		if hll_get_registers(sparse, &got) != .None || got != expect {
			return false, "TESTFAILED sparse registers differ from the model"
		}
		if hll_get_registers(dense, &got) != .None || got != expect {
			return false, "TESTFAILED dense registers differ from the model"
		}
		bad := false
		from_sparse := hll_estimate(sparse, &bad)
		from_dense := hll_estimate(dense, &bad)
		from_raw := hll_estimate_raw(&expect)
		if bad || from_sparse != from_raw || from_dense != from_raw {
			return false, "TESTFAILED estimates differ between encodings"
		}
		diff := abs(f64(from_raw) - f64(checkpoint))
		if diff > max(2, f64(checkpoint) * 0.05) {
			return false, "TESTFAILED estimate outside the error bound"
		}
	}
	half := hll_new_sparse(allocator)
	defer hll_free(half, allocator)
	other: [HLL_REGISTERS]u8
	for n in 0 ..< 2000 {
		selftest_elem(&elem, base ~ 0xa5a5a5a5a5a5a5a5, n)
		index, count := hll_pat_len(elem[:])
		other[index] = max(other[index], count)
		if _, err := hll_add(&half, elem[:], limit, allocator); err != .None {
			return false, "TESTFAILED add to the merge source failed"
		}
	}
	merged := hll_new_sparse(allocator)
	defer hll_free(merged, allocator)
	sources := [2][]u8{sparse, half}
	if hll_merge(&merged, true, sources[:], limit, allocator) != .None {
		return false, "TESTFAILED merge failed"
	}
	if hll_get_registers(merged, &got) != .None {
		return false, "TESTFAILED merged value is corrupted"
	}
	for i in 0 ..< HLL_REGISTERS {
		if got[i] != max(expect[i], other[i]) {
			return false, "TESTFAILED merged registers differ from the union"
		}
	}
	return true, ""
}
