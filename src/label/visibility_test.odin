package label

import "core:testing"

expect_exact :: proc(t: ^testing.T, v: ^Visibility, tb: ^Table) -> bool {
	for i in 0 ..< table_count(tb) {
		if visible(v, Id(i)) != dominates(v.reader, tb.labels[i]) {
			testing.expectf(t, false, "bit %d disagrees with dominance", i)
			return false
		}
	}
	for i in table_count(tb) ..< len(v.words) * 64 {
		if v.words[i >> 6] >> uint(i & 63) & 1 != 0 {
			testing.expectf(t, false, "bit %d beyond the table is set", i)
			return false
		}
	}
	return true
}

@(test)
visibility_bits_equal_dominance_after_every_growth :: proc(t: ^testing.T) {
	tb: Table
	testing.expect_value(t, table_init(&tb), Error.None)
	defer table_destroy(&tb)
	r := Rng{0xB175}
	readers := [?]Label{BOTTOM, random_label(&r, 6, 30, 10), random_label(&r, 6, 30, 25), {level = 5, compartments = {max(u64), 0, 0, 0}}}
	vs: [len(readers)]Visibility
	for &v, i in vs {
		visibility_init(&v, readers[i])
	}
	defer for &v in vs {
		visibility_destroy(&v)
	}
	steps := 0
	for table_count(&tb) < 3_000 {
		grow := 1 + rng_below(&r, 150)
		for _ in 0 ..< grow {
			table_intern(&tb, random_label(&r, 6, 30, 3))
		}
		for &v in vs {
			stale := v.built
			for i in stale ..< table_count(&tb) {
				testing.expect(t, !visible(&v, Id(i)))
			}
			testing.expect_value(t, visibility_refresh(&v, &tb), Error.None)
			testing.expect_value(t, v.built, table_count(&tb))
			if !expect_exact(t, &v, &tb) {
				return
			}
			fresh: Visibility
			testing.expect_value(t, visibility_build(&fresh, &tb, v.reader), Error.None)
			testing.expect(t, len(fresh.words) == len(v.words))
			for w in 0 ..< len(fresh.words) {
				testing.expect_value(t, fresh.words[w], v.words[w])
			}
			visibility_destroy(&fresh)
		}
		steps += 1
	}
	testing.expect(t, steps > 10)
	testing.expect(t, visible(&vs[0], BOTTOM_ID) && visible(&vs[1], BOTTOM_ID))
	testing.expect(t, !visible(&vs[0], ID_NONE))
	testing.expect_value(t, visibility_refresh(&vs[0], &tb), Error.None)
	n := 0
	for i in 0 ..< table_count(&tb) {
		if dominates(readers[2], tb.labels[i]) {
			n += 1
		}
	}
	testing.expect_value(t, visible_count(&vs[2]), n)
}

@(test)
visibility_covers_the_full_table :: proc(t: ^testing.T) {
	tb: Table
	testing.expect_value(t, table_init(&tb), Error.None)
	defer table_destroy(&tb)
	for i in 1 ..< LABEL_LIMIT {
		table_intern(&tb, distinct_label(i))
	}
	reader: Label
	for c in 0 ..< 8 {
		compartment_add(&reader, c * 16 + c % 7)
	}
	v: Visibility
	testing.expect_value(t, visibility_build(&v, &tb, reader), Error.None)
	defer visibility_destroy(&v)
	testing.expect_value(t, len(v.words), 1024)
	testing.expect_value(t, visible_count(&v), 256)
	expect_exact(t, &v, &tb)
	testing.expect(t, visible(&v, Id(255)) && !visible(&v, Id(256)) && !visible(&v, Id(LABEL_LIMIT - 1)))
}
