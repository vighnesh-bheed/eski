package vsettype

import "core:slice"
import "../hnsw"
import "../vmath"

FLAT_LIMIT_DEFAULT :: 512
SHRINK_LIMIT_DEFAULT :: 128

flat_limit := FLAT_LIMIT_DEFAULT
shrink_limit := SHRINK_LIMIT_DEFAULT

Seq_Slot :: struct {
	seq:  u64,
	slot: u32,
}

part_graph_reset :: proc(s: Vset, p: ^Partition, rng: u64, uid: u64) {
	m := p.graph.m
	hnsw.destroy(&p.graph)
	hnsw.init(&p.graph, graph_params(m, rng), graph_distance, p, part_allocator(s, p))
	p.graph.node_uid = uid
}

part_maybe_graduate :: proc(s: Vset, p: ^Part_Head, sc: ^Scratch) {
	if p.mode == .Flat && p.count > flat_limit {
		if p.kind == .Compact {
			owner_graduate(s, p, sc)
		} else {
			part_graduate(s, (^Partition)(p), sc)
		}
	}
}

part_maybe_flatten :: proc(s: Vset, p: ^Part_Head) {
	if p.mode == .Graph && p.count <= shrink_limit {
		if p.owner != SHARED {
			owner_flatten(s, p)
		} else {
			part_flatten(s, (^Partition)(p))
		}
	}
}

part_flatten :: proc(s: Vset, p: ^Partition) {
	part_graph_reset(s, p, p.graph.rng, p.graph.node_uid)
	p.mode = .Flat
}

part_graduate :: proc(s: Vset, p: ^Partition, sc: ^Scratch) -> Error {
	g := &p.graph
	rng := g.rng
	uid := g.node_uid
	fail :: proc(s: Vset, p: ^Partition, rng: u64, uid: u64) -> Error {
		part_graph_reset(s, p, rng, uid)
		p.mode = .Flat
		return .Out_Of_Memory
	}
	if hnsw.reserve_capacity(g, int(p.arena.cap)) != .None {
		return fail(s, p, rng, uid)
	}
	for i in 0 ..< int(p.arena.high) {
		slot, err := hnsw.reserve(g)
		if err != .None || slot != u32(i) {
			return fail(s, p, rng, uid)
		}
	}
	clear(&sc.slots)
	for at := p.arena.free; at != NIL_SLOT; at = vmath.free_next(p.arena.norms[at]) {
		if _, err := append(&sc.slots, at); err != nil {
			return fail(s, p, rng, uid)
		}
	}
	for i := len(sc.slots) - 1; i >= 0; i -= 1 {
		hnsw.release(g, sc.slots[i])
	}
	clear(&sc.pairs)
	if reserve(&sc.pairs, p.count) != nil {
		return fail(s, p, rng, uid)
	}
	for i in 0 ..< p.count {
		slot := p.order[i]
		append(&sc.pairs, Seq_Slot{seq = p.elements[slot].seq, slot = slot})
	}
	slice.sort_by(sc.pairs[:], proc(a, b: Seq_Slot) -> bool {
		return a.seq < b.seq
	})
	p.mode = .Graph
	for pair in sc.pairs {
		if part_insert_node(p, pair.slot, EF_DEFAULT, sc) != .None {
			return fail(s, p, rng, uid)
		}
	}
	g.node_uid = uid
	part_refresh_prefetch(p)
	return .None
}
