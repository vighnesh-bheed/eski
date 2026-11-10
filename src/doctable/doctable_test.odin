package doctable

import "core:slice"
import "core:testing"
import "../roaring"

Op_Kind :: enum u8 {
	Index,
	Remove,
	Rename,
	Check,
}

Op :: struct {
	kind:  Op_Kind,
	key:   string,
	to:    string,
	docs:  int,
	max:   u32,
	live:  []string,
}

MAINTENANCE := [?]Op {
	{kind = .Index, key = "m:pre1"},
	{kind = .Index, key = "m:pre2"},
	{kind = .Check, docs = 2, max = 2, live = {"m:pre1", "m:pre2"}},
	{kind = .Index, key = "m:pre1"},
	{kind = .Index, key = "m:1"},
	{kind = .Check, docs = 3, max = 4, live = {"m:pre1", "m:pre2", "m:1"}},
	{kind = .Index, key = "m:1"},
	{kind = .Check, docs = 3, max = 5, live = {"m:pre1", "m:pre2", "m:1"}},
	{kind = .Index, key = "m:1"},
	{kind = .Check, docs = 3, max = 6, live = {"m:pre1", "m:pre2", "m:1"}},
	{kind = .Index, key = "m:1"},
	{kind = .Check, docs = 3, max = 7, live = {"m:pre1", "m:pre2", "m:1"}},
	{kind = .Remove, key = "m:1"},
	{kind = .Check, docs = 2, max = 7, live = {"m:pre1", "m:pre2"}},
	{kind = .Index, key = "m:2"},
	{kind = .Check, docs = 3, max = 8, live = {"m:pre1", "m:pre2", "m:2"}},
	{kind = .Remove, key = "m:2"},
	{kind = .Check, docs = 2, max = 8, live = {"m:pre1", "m:pre2"}},
	{kind = .Index, key = "m:3"},
	{kind = .Check, docs = 3, max = 9, live = {"m:pre1", "m:pre2", "m:3"}},
	{kind = .Rename, key = "m:3", to = "m:4"},
	{kind = .Check, docs = 3, max = 9, live = {"m:pre1", "m:pre2", "m:4"}},
	{kind = .Remove, key = "m:4"},
	{kind = .Check, docs = 2, max = 9, live = {"m:pre1", "m:pre2"}},
	{kind = .Index, key = "m:5"},
	{kind = .Check, docs = 3, max = 10, live = {"m:pre1", "m:pre2", "m:5"}},
	{kind = .Index, key = "m:6"},
	{kind = .Check, docs = 4, max = 11, live = {"m:pre1", "m:pre2", "m:5", "m:6"}},
	{kind = .Check, docs = 4, max = 11, live = {"m:pre1", "m:pre2", "m:5", "m:6"}},
	{kind = .Index, key = "m:7"},
	{kind = .Check, docs = 5, max = 12, live = {"m:pre1", "m:pre2", "m:5", "m:6", "m:7"}},
	{kind = .Index, key = "m:9"},
	{kind = .Check, docs = 6, max = 13, live = {"m:pre1", "m:pre2", "m:5", "m:6", "m:7", "m:9"}},
	{kind = .Remove, key = "m:9"},
	{kind = .Check, docs = 5, max = 13, live = {"m:pre1", "m:pre2", "m:5", "m:6", "m:7"}},
	{kind = .Index, key = "m:10"},
	{kind = .Check, docs = 6, max = 14, live = {"m:pre1", "m:pre2", "m:5", "m:6", "m:7", "m:10"}},
	{kind = .Index, key = "m:10"},
	{kind = .Check, docs = 6, max = 15, live = {"m:pre1", "m:pre2", "m:5", "m:6", "m:7", "m:10"}},
	{kind = .Index, key = "m:11"},
	{kind = .Remove, key = "m:5"},
	{kind = .Check, docs = 6, max = 16, live = {"m:pre1", "m:pre2", "m:6", "m:7", "m:10", "m:11"}},
	{kind = .Index, key = "m:db1"},
	{kind = .Remove, key = "m:db1"},
	{kind = .Check, docs = 6, max = 17, live = {"m:pre1", "m:pre2", "m:6", "m:7", "m:10", "m:11"}},
}

live_keys :: proc(t: ^Table) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	it: roaring.Iterator
	roaring.iterator_init(&it, &t.live)
	for id, ok := roaring.next(&it); ok; id, ok = roaring.next(&it) {
		append(&out, get(t, id).key)
	}
	slice.sort(out[:])
	return out[:]
}

@(test)
document_ids_follow_the_recorded_maintenance_sequence :: proc(t: ^testing.T) {
	tb: Table
	init(&tb)
	defer destroy(&tb)
	ids := make(map[string]u32)
	defer delete(ids)
	for op, step in MAINTENANCE {
		switch op.kind {
		case .Index:
			id, replaced, err := add(&tb, op.key, Fields{length = 3, score = DEFAULT_SCORE})
			testing.expect_value(t, err, Error.None)
			if previous, had := ids[op.key]; had {
				testing.expect_value(t, replaced, previous)
				testing.expect(t, id > previous)
			} else {
				testing.expect_value(t, replaced, 0)
			}
			ids[op.key] = id
		case .Remove:
			id, err := remove(&tb, op.key)
			testing.expect_value(t, err, Error.None)
			testing.expect_value(t, id, ids[op.key])
			delete_key(&ids, op.key)
			testing.expect(t, get(&tb, id) == nil)
		case .Rename:
			id, replaced, err := rename(&tb, op.key, op.to)
			testing.expect_value(t, err, Error.None)
			testing.expect_value(t, replaced, 0)
			testing.expect_value(t, id, ids[op.key])
			delete_key(&ids, op.key)
			ids[op.to] = id
			got, found := lookup(&tb, op.to)
			testing.expect(t, found && got == id)
			_, still := lookup(&tb, op.key)
			testing.expect(t, !still)
		case .Check:
			testing.expectf(t, count(&tb) == op.docs, "step %d: %d live documents, want %d", step, count(&tb), op.docs)
			testing.expectf(t, max_id(&tb) == op.max, "step %d: max id %d, want %d", step, max_id(&tb), op.max)
			want := make([dynamic]string, context.temp_allocator)
			append(&want, ..op.live)
			slice.sort(want[:])
			testing.expect(t, slice.equal(live_keys(&tb), want[:]))
		}
	}
	testing.expect_value(t, pending(&tb), 11)
	Seen :: struct {
		n: int,
	}
	seen := Seen{}
	freed := collect(&tb, proc(ctx: rawptr, id: u32, d: ^Doc) {
		(^Seen)(ctx).n += 1
	}, &seen)
	testing.expect_value(t, freed, 11)
	testing.expect_value(t, seen.n, 11)
	testing.expect_value(t, pending(&tb), 0)
	testing.expect_value(t, count(&tb), 6)
	testing.expect(t, slot(&tb, 1) == nil && get(&tb, 2) != nil)
	_, err := remove(&tb, "m:none")
	testing.expect_value(t, err, Error.Not_Found)
	_, _, rerr := rename(&tb, "m:none", "m:x")
	testing.expect_value(t, rerr, Error.Not_Found)
	id6, _ := lookup(&tb, "m:6")
	id7, _ := lookup(&tb, "m:7")
	moved, replaced, merr := rename(&tb, "m:6", "m:7")
	testing.expect(t, merr == .None && moved == id6 && replaced == id7)
	testing.expect_value(t, count(&tb), 5)
}

@(test)
pages_are_freed_once_every_document_is_collected :: proc(t: ^testing.T) {
	tb: Table
	init(&tb)
	defer destroy(&tb)
	for i in 0 ..< 3 * PAGE_SIZE {
		key := "k"
		if i % 2 == 0 {
			key = "j"
		}
		add(&tb, key, Fields{length = u32(i)})
	}
	testing.expect_value(t, count(&tb), 2)
	testing.expect_value(t, int(max_id(&tb)), 3 * PAGE_SIZE)
	collect(&tb)
	testing.expect(t, tb.pages[0] == nil && tb.pages[1] == nil)
	testing.expect(t, get(&tb, max_id(&tb)) != nil)
	testing.expect_value(t, frequency_weight(2.5), 2)
	testing.expect_value(t, frequency_weight(0.5), 1)
	testing.expect_value(t, frequency_weight(1.7), 1)
	testing.expect_value(t, frequency_weight(3), 3)
	testing.expect_value(t, frequency_weight(0), 1)
}
