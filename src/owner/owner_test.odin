package owner

import "core:fmt"
import "core:testing"
import lb "../label"

Test_Entry :: struct {
	number: Owner,
	text:   string,
	extra:  int,
}

@(private = "file")
Rng :: struct {
	s: u64,
}

@(private = "file")
next_u64 :: proc(r: ^Rng) -> u64 {
	r.s += 0x9E37_79B9_7F4A_7C15
	z := r.s
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

@(private = "file")
below :: proc(r: ^Rng, n: int) -> int {
	return int(next_u64(r) % u64(n))
}

@(private = "file")
sample_owners := [?]Owner{SHARED, FIRST_USER, Owner(2), Owner(7), LAST_USER, EVERY}

@(test)
the_flat_order_puts_shared_below_users_and_every_above :: proc(t: ^testing.T) {
	for r in sample_owners {
		testing.expect(t, sees(r, r))
		testing.expect(t, sees(r, SHARED))
		testing.expect(t, sees(EVERY, r))
		testing.expect_value(t, sees(SHARED, r), r == SHARED)
		testing.expect_value(t, sees(r, EVERY), r == EVERY)
		for d in sample_owners {
			if is_user(r) && is_user(d) {
				testing.expect_value(t, sees(r, d), r == d)
			}
			if sees(r, d) && sees(d, r) {
				testing.expect_value(t, r, d)
			}
			for x in sample_owners {
				if sees(r, d) && sees(d, x) {
					testing.expect(t, sees(r, x))
				}
			}
		}
	}
	testing.expect(t, !is_user(SHARED) && !is_user(EVERY) && is_user(FIRST_USER) && is_user(LAST_USER))
}

@(test)
scopes_dominate_in_the_product_order :: proc(t: ^testing.T) {
	r := Rng{0x0A11}
	labels: [24]lb.Label
	for &l in labels {
		l.level = u8(below(&r, 4))
		l.trust = u8(below(&r, 3))
		for c in 0 ..< 5 {
			if below(&r, 2) == 0 {
				lb.compartment_add(&l, c * 37)
			}
		}
	}
	product :: proc(rl: lb.Label, ro: Owner, dl: lb.Label, do_: Owner) -> bool {
		return lb.dominates(rl, dl) && sees(ro, do_)
	}
	for _ in 0 ..< 20_000 {
		a, b, c := labels[below(&r, len(labels))], labels[below(&r, len(labels))], labels[below(&r, len(labels))]
		oa, ob, oc := sample_owners[below(&r, len(sample_owners))], sample_owners[below(&r, len(sample_owners))], sample_owners[below(&r, len(sample_owners))]
		testing.expect(t, product(a, oa, a, oa))
		if product(a, oa, b, ob) && product(b, ob, c, oc) {
			testing.expect(t, product(a, oa, c, oc))
		}
		if is_user(oa) && is_user(ob) && oa != ob {
			testing.expect(t, !product(a, oa, b, ob))
		}
	}
}

@(test)
the_owner_tie_puts_the_readers_copy_before_the_shared_one :: proc(t: ^testing.T) {
	u, v := FIRST_USER, Owner(9)
	testing.expect_value(t, rank(u, u, SHARED), 1)
	testing.expect_value(t, rank(u, SHARED, u), -1)
	testing.expect_value(t, rank(u, u, u), 0)
	testing.expect_value(t, rank(u, SHARED, SHARED), 0)
	testing.expect_value(t, rank(u, v, SHARED), 0)
	testing.expect_value(t, rank(SHARED, u, SHARED), 0)
	testing.expect_value(t, rank(EVERY, u, SHARED), 0)
	for r in sample_owners {
		for a in sample_owners {
			for b in sample_owners {
				testing.expect_value(t, rank(r, a, b), -rank(r, b, a))
				if rank(r, a, b) != 0 {
					testing.expect(t, sees(r, a) && sees(r, b))
				}
			}
		}
	}
}

@(test)
owner_texts_are_printable_ascii_without_spaces :: proc(t: ^testing.T) {
	testing.expect(t, !text_valid(nil))
	testing.expect(t, text_valid(transmute([]u8)string("u")))
	testing.expect(t, text_valid(transmute([]u8)string("auth0|5f3c-9a~!")))
	long: [TEXT_MAX + 1]u8
	for &b in long {
		b = 'x'
	}
	testing.expect(t, text_valid(long[:TEXT_MAX]))
	testing.expect(t, !text_valid(long[:]))
	for b in 0 ..< 256 {
		one := [1]u8{u8(b)}
		testing.expect_value(t, text_valid(one[:]), b > 32 && b < 127 && b != '*')
	}
	testing.expect(t, !text_valid(transmute([]u8)string("a b")))
	testing.expect(t, text_valid(transmute([]u8)string("**")))
	testing.expect(t, !text_valid(transmute([]u8)string("a\tb")))
}

@(test)
interning_numbers_owners_in_order_of_first_use :: proc(t: ^testing.T) {
	tb: Table(Test_Entry)
	table_init(&tb)
	defer table_destroy(&tb)
	a, ea := table_intern(&tb, transmute([]u8)string("alice"))
	testing.expect(t, ea == .None && a != nil && a.number == FIRST_USER && a.text == "alice")
	b, eb := table_intern(&tb, transmute([]u8)string("bob"))
	testing.expect(t, eb == .None && b.number == Owner(2))
	again, e2 := table_intern(&tb, transmute([]u8)string("alice"))
	testing.expect(t, e2 == .None && again == a)
	testing.expect(t, table_lookup(&tb, transmute([]u8)string("bob")) == b)
	testing.expect(t, table_lookup(&tb, transmute([]u8)string("carol")) == nil)
	testing.expect(t, table_find(&tb, Owner(2)) == b)
	testing.expect(t, table_find(&tb, SHARED) == nil && table_find(&tb, EVERY) == nil && table_find(&tb, Owner(3)) == nil)
	text, found := table_text(&tb, FIRST_USER)
	testing.expect(t, found && text == "alice")
	_, bad := table_intern(&tb, transmute([]u8)string("has space"))
	testing.expect_value(t, bad, Error.Invalid_Text)
	testing.expect_value(t, table_count(&tb), 2)
	testing.expect(t, table_drop(&tb, FIRST_USER))
	testing.expect(t, !table_drop(&tb, FIRST_USER))
	testing.expect(t, table_lookup(&tb, transmute([]u8)string("alice")) == nil && table_find(&tb, FIRST_USER) == nil)
	fresh, e3 := table_intern(&tb, transmute([]u8)string("alice"))
	testing.expect(t, e3 == .None && fresh.number == Owner(3))
	testing.expect_value(t, table_issued(&tb), 3)
	testing.expect(t, table_from(&tb, SHARED) == b && table_from(&tb, Owner(3)) == fresh && table_from(&tb, Owner(4)) == nil)
}

@(test)
a_full_table_refuses_new_owners_and_never_reuses_numbers :: proc(t: ^testing.T) {
	tb: Table(Test_Entry)
	table_init(&tb, Owner(3))
	defer table_destroy(&tb)
	names := [?]string{"a", "b", "c"}
	for n, i in names {
		e, err := table_intern(&tb, transmute([]u8)n)
		testing.expect(t, err == .None && e.number == Owner(i + 1))
	}
	_, full := table_intern(&tb, transmute([]u8)string("d"))
	testing.expect_value(t, full, Error.Table_Full)
	testing.expect(t, table_drop(&tb, Owner(2)))
	_, still := table_intern(&tb, transmute([]u8)string("b"))
	testing.expect_value(t, still, Error.Table_Full)
	known, err := table_intern(&tb, transmute([]u8)string("c"))
	testing.expect(t, err == .None && known.number == Owner(3))
}

@(test)
random_interning_agrees_with_a_model :: proc(t: ^testing.T) {
	tb: Table(Test_Entry)
	table_init(&tb)
	defer table_destroy(&tb)
	model := make(map[string]Owner)
	defer {
		for k in model {
			delete(k)
		}
		delete(model)
	}
	issued := u32(0)
	r := Rng{0x0E77}
	for step in 0 ..< 60_000 {
		name := fmt.tprintf("user-%d", below(&r, 900))
		switch below(&r, 10) {
		case 0 ..= 4:
			e, err := table_intern(&tb, transmute([]u8)name)
			testing.expect_value(t, err, Error.None)
			if want, ok := model[name]; ok {
				testing.expect_value(t, e.number, want)
			} else {
				issued += 1
				testing.expect_value(t, e.number, Owner(issued))
				model[fmt.aprintf("%s", name)] = e.number
			}
			testing.expect(t, e.text == name)
		case 5 ..= 7:
			want, ok := model[name]
			e := table_lookup(&tb, transmute([]u8)name)
			testing.expect_value(t, e != nil, ok)
			if ok {
				testing.expect(t, table_find(&tb, want) == e)
			}
		case:
			want, ok := model[name]
			if !ok {
				continue
			}
			testing.expect(t, table_drop(&tb, want))
			testing.expect(t, table_find(&tb, want) == nil)
			for k in model {
				if k == name {
					delete_key(&model, k)
					delete(k)
					break
				}
			}
		}
		if step % 997 == 0 {
			testing.expect_value(t, table_count(&tb), len(model))
			last := SHARED
			count := 0
			for e := table_from(&tb, SHARED); e != nil; e = table_from(&tb, e.number + 1) {
				testing.expect(t, e.number > last)
				last = e.number
				count += 1
				want, ok := model[e.text]
				testing.expect(t, ok && want == e.number)
			}
			testing.expect_value(t, count, len(model))
		}
	}
	testing.expect_value(t, table_issued(&tb), issued)
}
