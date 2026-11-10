package label

import "core:testing"

@(test)
visible_totals_sum_only_dominated_labels :: proc(t: ^testing.T) {
	tb: Table
	testing.expect_value(t, table_init(&tb), Error.None)
	defer table_destroy(&tb)
	r := Rng{0xC0_47}
	for _ in 0 ..< 400 {
		table_intern(&tb, random_label(&r, 5, 20, 3))
	}
	c: Counters
	counters_init(&c)
	defer counters_destroy(&c)
	shadow := make([]u64, table_count(&tb))
	defer delete(shadow)
	for _ in 0 ..< 20_000 {
		id := Id(rng_below(&r, table_count(&tb)))
		delta := u64(rng_below(&r, 50))
		if rng_below(&r, 3) == 0 {
			e := counters_sub(&c, id, delta)
			if shadow[id] >= delta {
				testing.expect_value(t, e, Error.None)
				shadow[id] -= delta
			} else {
				testing.expect_value(t, e, Error.Underflow)
			}
		} else {
			testing.expect_value(t, counters_add(&c, id, delta), Error.None)
			shadow[id] += delta
		}
	}
	total := u64(0)
	for i in 0 ..< len(shadow) {
		testing.expect_value(t, counters_get(&c, Id(i)), shadow[i])
		total += shadow[i]
	}
	testing.expect_value(t, counters_total(&c), total)
	for _ in 0 ..< 50 {
		reader := random_label(&r, 5, 20, 12)
		v: Visibility
		testing.expect_value(t, visibility_build(&v, &tb, reader), Error.None)
		want := u64(0)
		for i in 0 ..< len(shadow) {
			if dominates(reader, tb.labels[i]) {
				want += shadow[i]
			}
		}
		testing.expect_value(t, counters_visible(&c, &v), want)
		visibility_destroy(&v)
	}
	top: Label
	top.level = 4
	top.compartments = {max(u64), max(u64), max(u64), max(u64)}
	v: Visibility
	visibility_build(&v, &tb, top)
	testing.expect_value(t, counters_visible(&c, &v), total)
	visibility_destroy(&v)
}

@(test)
counters_refuse_overflow_and_stale_ids :: proc(t: ^testing.T) {
	c: Counters
	counters_init(&c)
	defer counters_destroy(&c)
	testing.expect_value(t, counters_add(&c, Id(3), max(u64) - 5), Error.None)
	testing.expect_value(t, counters_add(&c, Id(9), 6), Error.Overflow)
	testing.expect_value(t, counters_add(&c, Id(9), 5), Error.None)
	testing.expect_value(t, counters_add(&c, Id(0), 1), Error.Overflow)
	testing.expect_value(t, counters_add(&c, ID_NONE, 0), Error.Invalid_Label)
	testing.expect_value(t, counters_sub(&c, Id(9), 6), Error.Underflow)
	testing.expect_value(t, counters_sub(&c, Id(200), 1), Error.Underflow)
	testing.expect_value(t, counters_sub(&c, Id(200), 0), Error.None)
	testing.expect_value(t, counters_sub(&c, Id(3), max(u64) - 5), Error.None)
	testing.expect_value(t, counters_total(&c), 5)
	tb: Table
	table_init(&tb)
	defer table_destroy(&tb)
	for i in 1 ..< 12 {
		table_intern(&tb, distinct_label(i))
	}
	v: Visibility
	visibility_init(&v, BOTTOM)
	defer visibility_destroy(&v)
	testing.expect_value(t, counters_visible(&c, &v), 0)
	visibility_refresh(&v, &tb)
	testing.expect_value(t, counters_visible(&c, &v), 0)
	testing.expect_value(t, counters_add(&c, Id(0), 7), Error.None)
	testing.expect_value(t, counters_visible(&c, &v), 7)
}
