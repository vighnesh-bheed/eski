package label

import "core:testing"

distinct_label :: proc(i: int) -> (l: Label) {
	for c in 0 ..< 16 {
		if i >> uint(c) & 1 != 0 {
			compartment_add(&l, c * 16 + c % 7)
		}
	}
	l.level = u8(i >> 16)
	return l
}

@(test)
interning_assigns_stable_ids_from_bottom :: proc(t: ^testing.T) {
	tb: Table
	testing.expect_value(t, table_init(&tb), Error.None)
	defer table_destroy(&tb)
	testing.expect_value(t, table_count(&tb), 1)
	first, found := table_find(&tb, BOTTOM)
	testing.expect(t, found && first == BOTTOM_ID)
	r := Rng{0x1D5}
	seen := make(map[Label]Id)
	defer delete(seen)
	seen[BOTTOM] = BOTTOM_ID
	for _ in 0 ..< 30_000 {
		l := random_label(&r, 8, 40, 3)
		id, e := table_intern(&tb, l)
		testing.expect_value(t, e, Error.None)
		if old, ok := seen[l]; ok {
			testing.expect_value(t, id, old)
		} else {
			testing.expect_value(t, int(id), len(seen))
			seen[l] = id
		}
		back, present := table_label(&tb, id)
		testing.expect(t, present && back == l)
	}
	testing.expect_value(t, table_count(&tb), len(seen))
	for l, id in seen {
		got, ok := table_find(&tb, l)
		testing.expect(t, ok && got == id)
	}
	_, ok := table_label(&tb, Id(table_count(&tb)))
	testing.expect(t, !ok)
	_, ok = table_label(&tb, ID_NONE)
	testing.expect(t, !ok)
	missing, _ := label_make(9)
	_, ok = table_find(&tb, missing)
	testing.expect(t, !ok)
	empty: Table
	_, ok = table_find(&empty, BOTTOM)
	testing.expect(t, !ok)
	_, e := table_intern(&empty, BOTTOM)
	testing.expect_value(t, e, Error.Invalid_Label)
}

@(test)
interning_stops_at_the_label_limit :: proc(t: ^testing.T) {
	tb: Table
	testing.expect_value(t, table_init(&tb), Error.None)
	defer table_destroy(&tb)
	for i in 1 ..< LABEL_LIMIT {
		id, e := table_intern(&tb, distinct_label(i))
		if e != .None || int(id) != i {
			testing.expectf(t, false, "label %d: id %d error %v", i, id, e)
			return
		}
	}
	testing.expect_value(t, table_count(&tb), LABEL_LIMIT)
	extra := distinct_label(1 << 16)
	id, e := table_intern(&tb, extra)
	testing.expect(t, e == .Table_Full && id == ID_NONE)
	testing.expect_value(t, table_count(&tb), LABEL_LIMIT)
	_, found := table_find(&tb, extra)
	testing.expect(t, !found)
	id, e = table_intern(&tb, distinct_label(LABEL_LIMIT - 1))
	testing.expect(t, e == .None && int(id) == LABEL_LIMIT - 1)
	id, e = table_intern(&tb, BOTTOM)
	testing.expect(t, e == .None && id == BOTTOM_ID)
	for i in 0 ..< LABEL_LIMIT {
		l, ok := table_label(&tb, Id(i))
		if !ok || l != distinct_label(i) {
			testing.expectf(t, false, "id %d no longer names its label", i)
			return
		}
	}
	testing.expect_value(t, len(tb.index), 131_072)
}
