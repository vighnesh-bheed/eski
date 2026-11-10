package termdict

import "core:slice"
import "core:strings"
import "core:testing"

Rng :: struct {
	state: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E37_79B9_7F4A_7C15
	z := r.state
	z = (z ~ z >> 30) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ z >> 27) * 0x94D0_49BB_1331_11EB
	return z ~ z >> 31
}

rng_below :: proc(r: ^Rng, n: int) -> int {
	return int(rng_next(r) % u64(n))
}

random_term :: proc(r: ^Rng) -> string {
	alphabet := "abcde+\xc3\xa9z"
	n := rng_below(r, 7)
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< n {
		strings.write_byte(&b, alphabet[rng_below(r, len(alphabet))])
	}
	return strings.to_string(b)
}

@(test)
dictionary_follows_a_map_and_iterates_in_byte_order :: proc(t: ^testing.T) {
	r := Rng{0x7E4D}
	d: Dictionary
	init(&d)
	defer destroy(&d)
	shadow := make(map[string]Id)
	defer {
		for k in shadow {
			delete(k)
		}
		delete(shadow)
	}
	for step in 0 ..< 20_000 {
		term := random_term(&r)
		if rng_below(&r, 4) == 0 {
			id, found := lookup(&d, term)
			want, present := shadow[term]
			testing.expect_value(t, found, present)
			if present {
				testing.expect_value(t, id, want)
				testing.expect(t, remove(&d, id))
				testing.expect(t, !remove(&d, id))
				k, _ := shadow[term]
				_ = k
				for key in shadow {
					if key == term {
						delete_key(&shadow, key)
						delete(key)
						break
					}
				}
			}
		} else {
			id, inserted, err := insert(&d, term)
			testing.expect_value(t, err, Error.None)
			want, present := shadow[term]
			testing.expect_value(t, inserted, !present)
			if present {
				testing.expect_value(t, id, want)
			} else {
				shadow[strings.clone(term)] = id
			}
			txt, ok := text(&d, id)
			testing.expect(t, ok && txt == term)
		}
		if step % 5000 == 4999 {
			keys := make([dynamic]string, context.temp_allocator)
			for k in shadow {
				append(&keys, k)
			}
			slice.sort(keys[:])
			it: Iterator
			iterator_seek(&it, &d, "")
			i := 0
			for {
				term_text, id, ok := iterator_next(&it)
				if !ok {
					break
				}
				if !testing.expect(t, i < len(keys) && term_text == keys[i] && id == shadow[keys[i]]) {
					break
				}
				i += 1
			}
			iterator_close(&it)
			testing.expect_value(t, i, len(keys))
			testing.expect_value(t, count(&d), len(keys))
			from, stop := random_term(&r), random_term(&r)
			if from > stop {
				from, stop = stop, from
			}
			want := make([dynamic]string, context.temp_allocator)
			for k in keys {
				if k >= from && k < stop {
					append(&want, k)
				}
			}
			iterator_range(&it, &d, from, stop)
			j := 0
			for {
				term_text, _, ok := iterator_next(&it)
				if !ok {
					break
				}
				testing.expect(t, j < len(want) && term_text == want[j])
				j += 1
			}
			iterator_close(&it)
			testing.expect_value(t, j, len(want))
		}
	}
	empty_id, inserted, _ := insert(&d, "")
	_ = inserted
	got, found := lookup(&d, "")
	testing.expect(t, found && got == empty_id)
}

@(test)
removed_ids_are_reused :: proc(t: ^testing.T) {
	d: Dictionary
	init(&d)
	defer destroy(&d)
	a, _, _ := insert(&d, "alpha")
	b, _, _ := insert(&d, "beta")
	testing.expect(t, a != b)
	testing.expect(t, remove(&d, a))
	c, inserted, _ := insert(&d, "gamma")
	testing.expect(t, inserted && c == a)
	_, found := lookup(&d, "alpha")
	testing.expect(t, !found)
	testing.expect_value(t, count(&d), 2)
	testing.expect_value(t, capacity(&d), 2)
	m := Matcher{}
	out := make([dynamic]Id)
	defer delete(out)
	truncated, err := expand(&m, &d, "a", 10, &out)
	testing.expect(t, !truncated && err == .None && len(out) == 0)
}

@(test)
unlisted_terms_resolve_but_stay_out_of_scans_and_counts :: proc(t: ^testing.T) {
	d: Dictionary
	init(&d)
	defer destroy(&d)
	insert(&d, "abc")
	long_id, inserted, _ := insert(&d, "abd", false)
	testing.expect(t, inserted)
	insert(&d, "abe")
	got, found := lookup(&d, "abd")
	testing.expect(t, found && got == long_id && !is_listed(&d, long_id))
	testing.expect_value(t, count(&d), 2)
	testing.expect_value(t, size(&d), 3)
	it: Iterator
	iterator_seek(&it, &d, "ab")
	seen := make([dynamic]string, context.temp_allocator)
	for {
		term, _, ok := iterator_next(&it)
		if !ok {
			break
		}
		append(&seen, term)
	}
	iterator_close(&it)
	testing.expect(t, len(seen) == 2 && seen[0] == "abc" && seen[1] == "abe")
	testing.expect(t, remove(&d, long_id))
	testing.expect_value(t, count(&d), 2)
	testing.expect_value(t, size(&d), 2)
}
