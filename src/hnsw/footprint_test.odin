package hnsw

import "core:log"
import "core:testing"

@(test)
per_node_footprint_for_m_16 :: proc(t: ^testing.T) {
	testing.expect_value(t, node_fixed_bytes(16, 4), 135)
	testing.expect_value(t, node_fixed_bytes(16, 3), 103)
	testing.expect_value(t, node_fixed_bytes(16, 2), 71)
	testing.expect_value(t, node_fixed_bytes(4, 4), 39)
	testing.expect_value(t, node_fixed_bytes(64, 4), 519)
	testing.expect_value(t, link_width(0), 2)
	testing.expect_value(t, link_width(WIDTH_U16_SLOTS), 2)
	testing.expect_value(t, link_width(WIDTH_U16_SLOTS + 1), 3)
	testing.expect_value(t, link_width(WIDTH_U24_SLOTS), 3)
	testing.expect_value(t, link_width(WIDTH_U24_SLOTS + 1), 4)
	testing.expect_value(t, link_width(SLOT_LIMIT), 4)
	wide_upper := node_expected_upper_bytes(16, PROMOTION_DEFAULT, 4)
	testing.expectf(t, wide_upper > 22.66 && wide_upper < 22.67, "expected upper layer bytes per node at M 16 with 32-bit ids: %.3f", wide_upper)
	testing.expectf(t, node_expected_bytes(16, PROMOTION_DEFAULT, 4) > 157.66 && node_expected_bytes(16, PROMOTION_DEFAULT, 4) < 157.67, "32-bit ids at M 16")
	testing.expectf(t, node_expected_bytes(16, PROMOTION_DEFAULT, 3) > 119.99 && node_expected_bytes(16, PROMOTION_DEFAULT, 3) < 120.01, "24-bit ids at M 16")
	expected_upper := node_expected_upper_bytes(16, PROMOTION_DEFAULT, 2)
	testing.expectf(t, expected_upper > 11.33 && expected_upper < 11.34, "expected upper layer bytes per node at M 16 with 16-bit ids: %.3f", expected_upper)
	expected := node_expected_bytes(16, PROMOTION_DEFAULT, 2)
	testing.expectf(t, expected > 82.33 && expected < 82.34, "expected bytes per node at M 16 with 16-bit ids: %.3f", expected)
	paper_upper := node_expected_upper_bytes(16, 1.0 / 16, 4)
	testing.expectf(t, paper_upper > 4.53 && paper_upper < 4.54, "1/ln(M) law upper bytes per node at M 16: %.3f", paper_upper)
	dim :: 4
	count :: 10_000
	p: Points
	points_init(&p, dim, true, count)
	defer points_destroy(&p)
	ix: Index
	testing.expect_value(t, init(&ix, test_params(16, 40, 0xF00D), points_distance, &p, context.allocator), Error.None)
	defer destroy(&ix)
	testing.expect_value(t, reserve_capacity(&ix, count), Error.None)
	s: Scratch
	scratch_init(&s, context.allocator)
	defer scratch_destroy(&s)
	state := u64(0xBEEF)
	build_unit(t, &ix, &s, &p, &state, count)
	testing.expect_value(t, info(&ix).link_width, 2)
	per_node := f64(used_bytes(&ix)) / f64(size(&ix))
	upper := f64(ix.upper_len * ix.width) / f64(size(&ix))
	allocated := f64(memory(&ix)) / f64(size(&ix))
	log.infof("M 16, %d nodes, %d-byte ids: %.2f bytes per node in use (%.2f in upper layers, %.3f expected), %.2f allocated including pool slack, max level %d", count, ix.width, per_node, upper, expected_upper, allocated, ix.max_level)
	testing.expectf(t, per_node > 81 && per_node < 84.5, "bytes per node in use %.2f", per_node)
	testing.expectf(t, upper > 10.25 && upper < 12.5, "upper layer bytes per node %.2f", upper)
	testing.expect_value(t, ix.cap, count)
	testing.expect_value(t, reencode(&ix, ix.cap, 4), Error.None)
	wide := f64(used_bytes(&ix)) / f64(size(&ix))
	log.infof("the same graph with 32-bit ids: %.2f bytes per node in use", wide)
	testing.expectf(t, wide > 155 && wide < 160.5, "bytes per node in use with 32-bit ids %.2f", wide)
}
