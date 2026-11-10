package label

import "core:testing"

@(test)
dominance_is_a_partial_order_on_the_small_lattice :: proc(t: ^testing.T) {
	for i in 0 ..< SMALL_LABELS {
		a := small_label(i)
		testing.expect(t, dominates(a, a))
		testing.expect(t, dominates(a, BOTTOM))
		for j in 0 ..< SMALL_LABELS {
			b := small_label(j)
			if dominates(a, b) && dominates(b, a) {
				testing.expect(t, a == b)
			}
			for k in 0 ..< SMALL_LABELS {
				c := small_label(k)
				if dominates(a, b) && dominates(b, c) {
					testing.expect(t, dominates(a, c))
				}
			}
		}
	}
}

@(test)
join_and_meet_are_least_upper_and_greatest_lower_bounds :: proc(t: ^testing.T) {
	for i in 0 ..< SMALL_LABELS {
		a := small_label(i)
		for j in 0 ..< SMALL_LABELS {
			b := small_label(j)
			up := join(a, b)
			down := meet(a, b)
			testing.expect(t, dominates(up, a) && dominates(up, b))
			testing.expect(t, dominates(a, down) && dominates(b, down))
			testing.expect(t, join(a, b) == join(b, a) && meet(a, b) == meet(b, a))
			testing.expect(t, join(a, meet(a, b)) == a && meet(a, join(a, b)) == a)
			for k in 0 ..< SMALL_LABELS {
				c := small_label(k)
				testing.expect_value(t, dominates(c, a) && dominates(c, b), dominates(c, up))
				testing.expect_value(t, dominates(a, c) && dominates(b, c), dominates(down, c))
				testing.expect(t, meet(a, join(b, c)) == join(meet(a, b), meet(a, c)))
			}
		}
	}
}

@(test)
lattice_laws_hold_on_wide_random_labels :: proc(t: ^testing.T) {
	r := Rng{0x1A77_1CE5}
	for _ in 0 ..< 20_000 {
		a := random_label(&r, LEVEL_LIMIT, COMPARTMENT_LIMIT, 12)
		b := random_label(&r, LEVEL_LIMIT, COMPARTMENT_LIMIT, 12)
		c := random_label(&r, LEVEL_LIMIT, COMPARTMENT_LIMIT, 12)
		up := join(a, b)
		down := meet(a, b)
		testing.expect(t, dominates(up, a) && dominates(up, b))
		testing.expect(t, dominates(a, down) && dominates(b, down))
		testing.expect_value(t, dominates(c, a) && dominates(c, b), dominates(c, up))
		testing.expect_value(t, dominates(a, c) && dominates(b, c), dominates(down, c))
		testing.expect(t, join(join(a, b), c) == join(a, join(b, c)))
		testing.expect(t, meet(meet(a, b), c) == meet(a, meet(b, c)))
		want := a.level >= b.level
		for x in 0 ..< COMPARTMENT_LIMIT {
			if compartment_has(b, x) && !compartment_has(a, x) {
				want = false
			}
		}
		testing.expect_value(t, dominates(a, b), want)
	}
}

@(test)
compartment_helpers_cover_every_word :: proc(t: ^testing.T) {
	l: Label
	testing.expect_value(t, compartment_next(l, 0), COMPARTMENT_LIMIT)
	testing.expect_value(t, compartment_highest(l), -1)
	for c in ([]int{0, 1, 63, 64, 127, 128, 191, 192, 254, 255}) {
		testing.expect(t, compartment_add(&l, c))
	}
	testing.expect(t, !compartment_add(&l, 256))
	testing.expect(t, !compartment_add(&l, -1))
	testing.expect(t, !compartment_has(l, 256))
	testing.expect_value(t, compartment_count(l), 10)
	testing.expect_value(t, compartment_highest(l), 255)
	seen := [dynamic]int{}
	defer delete(seen)
	for c := compartment_next(l, 0); c < COMPARTMENT_LIMIT; c = compartment_next(l, c + 1) {
		append(&seen, c)
	}
	testing.expect_value(t, len(seen), 10)
	testing.expect_value(t, seen[2], 63)
	testing.expect_value(t, seen[3], 64)
	testing.expect_value(t, seen[9], 255)
	testing.expect(t, compartment_remove(&l, 255))
	testing.expect_value(t, compartment_highest(l), 254)
	m, ok := label_make(3, 5, 200)
	testing.expect(t, ok && m.level == 3 && compartment_has(m, 5) && compartment_has(m, 200) && compartment_count(m) == 2)
	_, bad := label_make(256)
	testing.expect(t, !bad)
	_, bad = label_make(0, 300)
	testing.expect(t, !bad)
}

@(test)
trust_is_reversed_in_admission_and_in_the_lattice :: proc(t: ^testing.T) {
	for i in 0 ..< SMALL_TRUSTED_LABELS {
		a := small_label(i)
		testing.expect(t, dominates(a, a))
		for j in 0 ..< SMALL_TRUSTED_LABELS {
			b := small_label(j)
			want := a.level >= b.level && a.trust <= b.trust
			for x in 0 ..< 4 {
				if compartment_has(b, x) && !compartment_has(a, x) {
					want = false
				}
			}
			testing.expect_value(t, dominates(a, b), want)
			if dominates(a, b) && dominates(b, a) {
				testing.expect(t, a == b)
			}
			up := join(a, b)
			down := meet(a, b)
			testing.expect(t, dominates(up, a) && dominates(up, b))
			testing.expect(t, dominates(a, down) && dominates(b, down))
			testing.expect(t, up.trust == min(a.trust, b.trust) && down.trust == max(a.trust, b.trust))
			testing.expect(t, join(a, meet(a, b)) == a && meet(a, join(a, b)) == a)
			admitted := b.level <= a.level && b.trust <= a.trust
			for x in 0 ..< 4 {
				if compartment_has(b, x) && !compartment_has(a, x) {
					admitted = false
				}
			}
			testing.expect_value(t, ceiling_admits(a, b), admitted)
			order := resolution_compare(a, b)
			testing.expect_value(t, order, -resolution_compare(b, a))
			if a.level != b.level {
				testing.expect_value(t, order > 0, a.level > b.level)
			} else if compartment_count(a) != compartment_count(b) {
				testing.expect_value(t, order > 0, compartment_count(a) > compartment_count(b))
			} else {
				testing.expect_value(t, order, 1 if a.trust > b.trust else (-1 if a.trust < b.trust else 0))
			}
		}
		testing.expect(t, ceiling_admits(a, ceiling_session(a)))
		testing.expect(t, ceiling_session(a).trust == 0 && ceiling_session(a).level == a.level && ceiling_session(a).compartments == a.compartments)
	}
	r := Rng{0x7A05_7}
	for _ in 0 ..< 20_000 {
		a := random_label(&r, LEVEL_LIMIT, COMPARTMENT_LIMIT, 12, TRUST_LIMIT)
		b := random_label(&r, LEVEL_LIMIT, COMPARTMENT_LIMIT, 12, TRUST_LIMIT)
		c := random_label(&r, LEVEL_LIMIT, COMPARTMENT_LIMIT, 12, TRUST_LIMIT)
		up := join(a, b)
		down := meet(a, b)
		testing.expect_value(t, dominates(c, a) && dominates(c, b), dominates(c, up))
		testing.expect_value(t, dominates(a, c) && dominates(b, c), dominates(down, c))
		testing.expect(t, meet(a, join(b, c)) == join(meet(a, b), meet(a, c)))
		testing.expect(t, join(join(a, b), c) == join(a, join(b, c)))
		if dominates(a, b) && dominates(b, c) {
			testing.expect(t, dominates(a, c))
		}
	}
}
