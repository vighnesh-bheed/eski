package tagindex

import "core:fmt"
import "core:testing"
import "../roaring"
import "../termdict"

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

@(test)
tag_values_map_to_bitmaps_and_collect_deleted_documents :: proc(t: ^testing.T) {
	r := Rng{0x7A6}
	f: Field
	init(&f)
	defer destroy(&f)
	values := [?]string{"news", "sports", "tech", "light blue", "", "ünïcode"}
	shadow: [len(values)]map[u32]bool
	defer for &m in shadow {
		delete(m)
	}
	for _ in 0 ..< 5000 {
		v := rng_below(&r, len(values))
		doc := u32(1 + rng_below(&r, 2000))
		if rng_below(&r, 5) == 0 {
			removed, err := remove(&f, values[v], doc)
			testing.expect_value(t, err, Error.None)
			testing.expect_value(t, removed, doc in shadow[v])
			delete_key(&shadow[v], doc)
		} else {
			_, err := add(&f, values[v], doc)
			testing.expect_value(t, err, Error.None)
			shadow[v][doc] = true
		}
	}
	records := 0
	for v, i in values {
		testing.expect_value(t, cardinality(&f, v), len(shadow[i]))
		records += len(shadow[i])
		b, _, found := lookup(&f, v)
		testing.expect_value(t, found, len(shadow[i]) > 0)
		if found {
			for doc in shadow[i] {
				testing.expect(t, roaring.contains(b, doc))
			}
		}
	}
	testing.expect_value(t, f.records, records)
	deleted: roaring.Bitmap
	roaring.init(&deleted)
	defer roaring.destroy(&deleted)
	for doc in 1 ..= 2000 {
		if rng_below(&r, 3) == 0 {
			roaring.add(&deleted, u32(doc))
		}
	}
	Count :: struct {
		n: int,
	}
	seen := Count{}
	cb := proc(ctx: rawptr, value: termdict.Id, doc: u32) {
		(^Count)(ctx).n += 1
	}
	dropped, err := collect(&f, &deleted, cb, &seen)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, seen.n, dropped)
	want := 0
	for v, i in values {
		n := 0
		for doc in shadow[i] {
			if roaring.contains(&deleted, doc) {
				want += 1
			} else {
				n += 1
			}
		}
		testing.expect_value(t, cardinality(&f, v), n)
		_, _, found := lookup(&f, v)
		testing.expect_value(t, found, n > 0)
	}
	testing.expect_value(t, dropped, want)
	testing.expect_value(t, f.records, records - want)
	for i in 0 ..< 50 {
		add(&f, fmt.tprintf("v%d", i), 7)
	}
	testing.expect(t, value_count(&f) >= 50)
}
