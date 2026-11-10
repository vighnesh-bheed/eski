package termstats

import "core:testing"
import "../label"

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

random_label :: proc(r: ^Rng) -> label.Label {
	l: label.Label
	l.level = u8(rng_below(r, 4))
	for _ in 0 ..< rng_below(r, 3) {
		label.compartment_add(&l, rng_below(r, 6))
	}
	return l
}

@(test)
visible_statistics_sum_the_partitions_a_reader_dominates :: proc(t: ^testing.T) {
	r := Rng{0x57A7}
	tb: label.Table
	label.table_init(&tb)
	defer label.table_destroy(&tb)
	for _ in 0 ..< 40 {
		label.table_intern(&tb, random_label(&r))
	}
	s: Stats
	init(&s)
	defer destroy(&s)
	n := label.table_count(&tb)
	docs := make([]u64, n)
	defer delete(docs)
	lengths := make([]u64, n)
	defer delete(lengths)
	terms :: 50
	counts := make([][]u64, terms)
	defer {
		for c in counts {
			delete(c)
		}
		delete(counts)
	}
	for i in 0 ..< terms {
		counts[i] = make([]u64, n)
	}
	for _ in 0 ..< 20_000 {
		id := label.Id(rng_below(&r, n))
		switch rng_below(&r, 4) {
		case 0:
			length := u32(rng_below(&r, 30))
			testing.expect_value(t, document_add(&s, id, length), label.Error.None)
			docs[id] += 1
			lengths[id] += u64(length)
		case 1:
			if docs[id] > 0 {
				length := u32(min(lengths[id], u64(rng_below(&r, 30))))
				if docs[id] == 1 {
					length = u32(lengths[id])
				}
				testing.expect_value(t, document_remove(&s, id, length), label.Error.None)
				docs[id] -= 1
				lengths[id] -= u64(length)
			}
		case 2:
			term := rng_below(&r, terms)
			testing.expect_value(t, term_add(&s, u32(term), id), label.Error.None)
			counts[term][id] += 1
		case 3:
			term := rng_below(&r, terms)
			e := term_remove(&s, u32(term), id)
			if counts[term][id] > 0 {
				testing.expect_value(t, e, label.Error.None)
				counts[term][id] -= 1
			} else {
				testing.expect_value(t, e, label.Error.Underflow)
			}
		}
	}
	for term in 0 ..< terms {
		total := u64(0)
		for id in 0 ..< n {
			testing.expect_value(t, term_count(&s, u32(term), label.Id(id)), counts[term][id])
			total += counts[term][id]
		}
		testing.expect_value(t, term_total(&s, u32(term)), total)
	}
	for _ in 0 ..< 30 {
		reader := random_label(&r)
		v: label.Visibility
		label.visibility_build(&v, &tb, reader)
		want := Totals{}
		for id in 0 ..< n {
			if label.dominates(reader, tb.labels[id]) {
				want.documents += docs[id]
				want.total_length += lengths[id]
			}
		}
		testing.expect_value(t, totals_visible(&s, &v), want)
		for term in 0 ..< terms {
			w := u64(0)
			for id in 0 ..< n {
				if label.dominates(reader, tb.labels[id]) {
					w += counts[term][id]
				}
			}
			testing.expect_value(t, term_visible(&s, u32(term), &v), w)
		}
		label.visibility_destroy(&v)
	}
	all := Totals{}
	for id in 0 ..< n {
		all.documents += docs[id]
		all.total_length += lengths[id]
	}
	testing.expect_value(t, totals(&s), all)
	testing.expect_value(t, totals_for(&s, label.BOTTOM_ID), Totals{documents = docs[0], total_length = lengths[0]})
	term_forget(&s, 3)
	testing.expect_value(t, term_total(&s, 3), 0)
	testing.expect_value(t, term_add(&s, 1, label.ID_NONE), label.Error.Invalid_Label)
	testing.expect_value(t, term_remove(&s, 999, 0), label.Error.Underflow)
}
