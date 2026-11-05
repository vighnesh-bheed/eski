package hyperloglog_test

import "base:runtime"
import "core:log"
import "core:testing"
import "core:time"
import hll "../../src/hll"

@(test)
raw_heap_allocator_contract :: proc(t: ^testing.T) {
	a := hll.hll_raw_heap_allocator()
	block, err := runtime.mem_alloc(64, 16, a)
	testing.expect_value(t, err, runtime.Allocator_Error.None)
	testing.expect_value(t, len(block), 64)
	for b in block {
		if b != 0 {
			testing.expect(t, false, "alloc is not zeroed")
			break
		}
	}
	for &b in block {
		b = 0xab
	}
	grown, grow_err := runtime.mem_resize(raw_data(block), 64, 256, 16, a)
	testing.expect_value(t, grow_err, runtime.Allocator_Error.None)
	testing.expect_value(t, len(grown), 256)
	testing.expect_value(t, grown[63], 0xab)
	testing.expect_value(t, grown[64], 0)
	testing.expect_value(t, grown[255], 0)
	runtime.mem_free(raw_data(grown), a)
	_, align_err := runtime.mem_alloc(64, 64, a)
	testing.expect_value(t, align_err, runtime.Allocator_Error.Invalid_Argument)
	features: runtime.Allocator_Mode_Set
	_, query_err := a.procedure(a.data, .Query_Features, 0, 0, &features, 0)
	testing.expect_value(t, query_err, runtime.Allocator_Error.None)
	testing.expect(t, .Resize in features)

	buf := hll.hll_new_sparse(a)
	name_buf: [32]u8
	for n in 0 ..< 3000 {
		elems := [1][]u8{elem_name(name_buf[:], "alloc", n)}
		_, add_err := hll.hll_pfadd(&buf, elems[:], false, hll.HLL_SPARSE_MAX_BYTES_DEFAULT, a)
		testing.expect_value(t, add_err, hll.Error.None)
	}
	testing.expect_value(t, len(buf), hll.HLL_DENSE_SIZE)
	copy_buf := hll.hll_clone(buf, a)
	testing.expect(t, string(copy_buf) == string(buf))
	hll.hll_free(copy_buf, a)
	hll.hll_free(buf, a)
}

@(test)
api_ownership_without_leaks :: proc(t: ^testing.T) {
	buf: []u8
	elems := [2][]u8{transmute([]u8)string("p"), transmute([]u8)string("q")}
	updated, err := hll.hll_pfadd(&buf, elems[:], true)
	testing.expect_value(t, err, hll.Error.None)
	testing.expect_value(t, updated, 2)
	created_only: []u8
	updated, err = hll.hll_pfadd(&created_only, nil, true)
	testing.expect_value(t, updated, 1)
	testing.expect(t, !hll.hll_cache_valid(created_only))
	created_hex := hex_encode(created_only)
	testing.expect_value(t, created_hex, "48594c4c0100000000000000000000807fff")
	delete(created_hex)
	changed, add_err := hll.hll_add(&created_only, transmute([]u8)string("p"))
	testing.expect(t, changed)
	testing.expect_value(t, add_err, hll.Error.None)
	testing.expect(t, !hll.hll_cache_valid(created_only))
	invalid := false
	testing.expect_value(t, hll.hll_count(created_only, &invalid), 1)
	decoded, ok := hll.hll_decode_sparse_for_debug(buf)
	testing.expect(t, ok)
	testing.expect(t, len(decoded) > 0)
	delete(decoded)
	header_only := hex_decode("48594c4c010000000000000000000000")
	defer delete(header_only)
	nothing, nothing_ok := hll.hll_decode_sparse_for_debug(header_only)
	testing.expect(t, nothing_ok)
	testing.expect_value(t, nothing, "")
	value, reg_err := hll.hll_get_register(buf, 0)
	testing.expect_value(t, reg_err, hll.Error.None)
	testing.expect_value(t, value, 0)
	converted, conv_err := hll.hll_to_dense(&buf)
	testing.expect(t, converted)
	testing.expect_value(t, conv_err, hll.Error.None)
	_, not_sparse := hll.hll_decode_sparse_for_debug(buf)
	testing.expect(t, !not_sparse)
	again, again_err := hll.hll_to_dense(&buf)
	testing.expect(t, !again)
	testing.expect_value(t, again_err, hll.Error.None)
	regs: [hll.HLL_REGISTERS]u8
	hll.hll_merge_into(&regs, created_only)
	testing.expect_value(t, hll.hll_store_registers(&buf, &regs, false), hll.Error.None)
	merged: []u8
	srcs := [2][]u8{buf, created_only}
	testing.expect_value(t, hll.hll_merge(&merged, false, srcs[:]), hll.Error.None)
	testing.expect_value(t, hll.hll_count(merged, &invalid), 2)
	ok_selftest, msg := hll.hll_selftest(1)
	testing.expect(t, ok_selftest)
	testing.expect_value(t, msg, "")
	hll.hll_free(merged)
	hll.hll_free(buf)
	hll.hll_free(created_only)
}

@(test)
selftest_passes_quickly :: proc(t: ^testing.T) {
	seeds := [?]u64{0, 1, 0xdead_beef, 0x0123_4567_89ab_cdef}
	limits := [?]int{0, 100, hll.HLL_SPARSE_MAX_BYTES_DEFAULT, 20000}
	for seed in seeds {
		for limit in limits {
			start := time.tick_now()
			ok, msg := hll.hll_selftest(seed, limit)
			elapsed := time.tick_since(start)
			testing.expectf(t, ok, "seed %x limit %d: %s", seed, limit, msg)
			log.infof("selftest seed %x limit %d took %v", seed, limit, elapsed)
		}
	}
	start := time.tick_now()
	ok, _ := hll.hll_selftest(42, hll.HLL_SPARSE_MAX_BYTES_DEFAULT, hll.hll_raw_heap_allocator())
	elapsed := time.tick_since(start)
	testing.expect(t, ok)
	when !ODIN_DEBUG {
		testing.expectf(t, time.duration_seconds(elapsed) < 1, "selftest took %v", elapsed)
	}
}
