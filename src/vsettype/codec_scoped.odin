package vsettype

import "core:slice"
import "../hnsw"
import lbl "../label"
import "../vfilter"
import "../vmath"

Save_Context :: struct {
	objects: map[Vset]u64,
}

save_context_destroy :: proc(ctx: ^Save_Context) {
	delete(ctx.objects)
	ctx^ = {}
}

save_object :: proc(ctx: ^Save_Context, s: Vset) -> u64 {
	if n, ok := ctx.objects[s]; ok {
		return n
	}
	n := u64(len(ctx.objects))
	ctx.objects[s] = n
	return n
}

scoped_plan :: proc(s: Vset, scope: Scope, object: u64) -> (plan: Plan, ok: bool) {
	p := part_at_scope(s, scope.label, scope.owner)
	if p == nil {
		return {}, false
	}
	return part_plan(s, p, true, object), true
}

scoped_write :: proc(s: Vset, scope: Scope, plan: ^Plan, sink: Sink) -> int {
	p := part_at_scope(s, scope.label, scope.owner)
	if p == nil {
		return 0
	}
	return part_write(s, p, plan, sink)
}

Load_Object :: struct {
	set:    Vset,
	db:     int,
	key:    []u8,
	params: Params,
}

Scope_Key :: struct {
	object: u64,
	label:  lbl.Id,
	owner:  Owner,
}

Rank_Entry :: struct {
	name:   []u8,
	object: u32,
	owner:  Owner,
	copies: u32,
	rank:   u32,
	part:   u32,
	slot:   u32,
	kept:   bool,
}

Load_Context :: struct {
	objects: [dynamic]Load_Object,
	scopes:  map[Scope_Key]struct{},
	ranks:   [dynamic]Rank_Entry,
	found:   [dynamic]Elem_Rank,
}

load_context_destroy :: proc(ctx: ^Load_Context) {
	for &o in ctx.objects {
		delete(o.key)
	}
	for &r in ctx.ranks {
		delete(r.name)
	}
	delete(ctx.objects)
	delete(ctx.scopes)
	delete(ctx.ranks)
	delete(ctx.found)
	ctx^ = {}
}

scope_shape_check :: proc "contextless" (sh: ^Shape, scope: Scope) -> Decode_Error {
	if scope.owner == EVERY_OWNER || scope.label == lbl.ID_NONE {
		return .Bad_Scope
	}
	if sh.mode == .Pinned && (scope.label != lbl.BOTTOM_ID || scope.owner != SHARED) {
		return .Bad_Scope
	}
	return .None
}

owner_part_block :: proc(s: Vset, p: ^Part_Head, seed: u64) -> (out: ^Part_Head, err: Error) {
	idx := s.lab.owners
	compact := (^Compact_Block)(p)
	blk := (^Part_Block)(block_alloc(&idx.ledger, size_of(Part_Block), align_of(Part_Block), true))
	if blk == nil {
		return nil, .Out_Of_Memory
	}
	blk.head = compact.head
	blk.kind = .Block
	blk.mode = .Graph
	blk.charge = Charge{bytes = compact.charge.bytes, root = &idx.ledger}
	alloc := charge_allocator(&blk.charge)
	blk.arena.allocator = alloc
	if hnsw.init(&blk.graph, graph_params(s.graph.m, seed), graph_distance, &blk.part, alloc) != .None {
		block_free(&idx.ledger, blk)
		return nil, .Out_Of_Memory
	}
	scope_replace(s, p, &blk.head)
	block_free(&idx.ledger, compact)
	return &blk.head, .None
}

scoped_part_make :: proc(s: Vset, scope: Scope, sh: ^Shape) -> (p: ^Part_Head, err: Error) {
	if scope.owner == SHARED {
		full: ^Partition
		if full, err = part_create(s, scope.label, sh.rng); err != .None {
			return nil, err
		}
		full.mode = sh.mode
		return full, .None
	}
	idx: ^Owner_Index
	if idx, err = owners_attach(s); err != .None {
		return nil, err
	}
	owner := owner_scope(s, scope.owner)
	fresh := false
	if owner == nil {
		if owner, err = owner_scope_make(s, idx, scope.owner); err != .None {
			if idx.slot_len == 0 {
				owners_detach(s)
			}
			return nil, err
		}
		fresh = true
	}
	if p, err = owner_part_create(s, owner, scope.label, sh.rng); err != .None {
		if fresh {
			owner_scope_drop(s, owner)
		}
		return nil, err
	}
	if sh.mode == .Graph {
		block: ^Part_Head
		if block, err = owner_part_block(s, p, sh.rng); err != .None {
			owner_part_retire(s, p)
			return nil, err
		}
		p = block
	}
	return p, .None
}

part_abandon :: proc(s: Vset, p: ^Part_Head) {
	ni := part_index(s, p)
	for i in 0 ..< p.count {
		slot := p.order[i]
		index_remove(s, &ni, part_element_name(p, slot), Ref{slot = slot, part = p.id})
	}
	part_retire(s, p)
}

part_load :: proc(s: Vset, d: ^Decoder, sh: ^Shape, scope: Scope, found: ^[dynamic]Elem_Rank) -> (p: ^Part_Head, err: Decode_Error) {
	if part_at_scope(s, scope.label, scope.owner) != nil {
		return nil, .Bad_Scope
	}
	cerr: Error
	if p, cerr = scoped_part_make(s, scope, sh); cerr != .None {
		return nil, .Out_Of_Memory
	}
	t := Fill_Target{ni = part_index(s, p), ranks = found}
	if err = part_fill(s, p, d, sh, &t); err != .None {
		part_abandon(s, p)
		return nil, err
	}
	tally_refresh(p)
	s.lab.total += p.count
	s.version = 0
	return p, .None
}

load_set_new :: proc(params: Params) -> (s: Vset, err: Decode_Error) {
	p := params
	p.seed = 1
	cerr: Error
	if s, cerr = create(p); cerr != .None {
		return nil, .Out_Of_Memory if cerr == .Out_Of_Memory else .Bad_Header
	}
	if labelled_attach(s) != .None {
		destroy(s)
		return nil, .Out_Of_Memory
	}
	return s, .None
}

clone_bytes :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}

load_part :: proc(ctx: ^Load_Context, data: []u8, db: int, key: []u8, scope: Scope, keep: bool) -> (s: Vset, fresh: bool, err: Decode_Error) {
	d := Decoder{data = data}
	sh: Shape
	if err = shape_read(&d, &sh); err != .None {
		return
	}
	if sh.flags & CODEC_SCOPED == 0 {
		return nil, false, .Bad_Scope
	}
	if err = scope_shape_check(&sh, scope); err != .None {
		return
	}
	if err = shape_check(&sh, len(data), decoder_left(&d)); err != .None {
		return
	}
	params := Params{quant = sh.quant, dim = sh.dim, input_dim = sh.input_dim, m = sh.m}
	if sh.object >= u64(max(u32)) {
		return nil, false, .Bad_Object
	}
	obj: ^Load_Object
	switch {
	case sh.object == u64(len(ctx.objects)):
		append(&ctx.objects, Load_Object{db = db, key = clone_bytes(key), params = params})
		obj = &ctx.objects[len(ctx.objects) - 1]
	case sh.object < u64(len(ctx.objects)):
		obj = &ctx.objects[sh.object]
		if obj.db != db || string(obj.key) != string(key) || obj.params != params {
			return nil, false, .Bad_Object
		}
	case:
		return nil, false, .Bad_Object
	}
	sk := Scope_Key{object = sh.object, label = scope.label, owner = scope.owner}
	if sk in ctx.scopes {
		return nil, false, .Bad_Scope
	}
	ctx.scopes[sk] = {}
	target := obj.set
	made := false
	if !keep || target == nil {
		if target, err = load_set_new(params); err != .None {
			return
		}
		made = true
	} else {
		write_fence(target)
	}
	clear(&ctx.found)
	p: ^Part_Head
	if p, err = part_load(target, &d, &sh, scope, &ctx.found); err != .None {
		if made {
			destroy(target)
		}
		return nil, false, err
	}
	object := u32(sh.object)
	if keep {
		for f in ctx.found {
			append(&ctx.ranks, Rank_Entry{name = clone_bytes(part_element_name(p, f.slot)), object = object, owner = scope.owner, copies = f.copies, rank = f.rank, part = p.id, slot = f.slot, kept = true})
		}
		if made {
			obj.set = target
			fresh = true
		}
		return target, fresh, .None
	}
	at := 0
	for i in 0 ..< p.count {
		slot := p.order[i]
		entry := Rank_Entry{name = clone_bytes(part_element_name(p, slot)), object = object, owner = scope.owner, copies = 1, part = p.id, slot = slot}
		if at < len(ctx.found) && ctx.found[at].slot == slot {
			entry.copies = ctx.found[at].copies
			entry.rank = ctx.found[at].rank
			at += 1
		}
		append(&ctx.ranks, entry)
	}
	destroy(target)
	return nil, false, .None
}

rank_less :: proc(a, b: Rank_Entry) -> bool {
	if a.object != b.object {
		return a.object < b.object
	}
	if a.owner != b.owner {
		return a.owner < b.owner
	}
	if c := lex_compare(a.name, b.name); c != 0 {
		return c < 0
	}
	return a.rank < b.rank
}

rank_group_compare :: proc(e: Rank_Entry, object: u32, owner: Owner, name: []u8) -> int {
	if e.object != object {
		return -1 if e.object < object else 1
	}
	if e.owner != owner {
		return -1 if e.owner < owner else 1
	}
	return lex_compare(e.name, name)
}

rank_group :: proc(ranks: []Rank_Entry, object: u32, owner: Owner, name: []u8) -> []Rank_Entry {
	lo, hi := 0, len(ranks)
	for lo < hi {
		mid := (lo + hi) / 2
		if rank_group_compare(ranks[mid], object, owner, name) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	end := lo
	for end < len(ranks) && rank_group_compare(ranks[end], object, owner, name) == 0 {
		end += 1
	}
	return ranks[lo:end]
}

owner_index :: proc "contextless" (s: Vset, o: Owner) -> Name_Index {
	if o == SHARED {
		return shared_index(s)
	}
	return scope_index(owner_scope(s, o))
}

copies_reorder :: proc(s: Vset, o: Owner, name: []u8, group: []Rank_Entry, kept: int) -> bool {
	ni := owner_index(s, o)
	one: Ref
	refs := tree_lookup(ni.tree, name, &one)
	if len(refs) != kept {
		return false
	}
	if kept < 2 {
		return true
	}
	for e in group {
		if !e.kept {
			continue
		}
		r := Ref{slot = e.slot, part = e.part}
		found := false
		for x in refs {
			if x == r {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	at := 0
	for e in group {
		if e.kept {
			refs[at] = Ref{slot = e.slot, part = e.part}
			at += 1
		}
	}
	return true
}

multis_recorded :: proc(s: Vset, object: u32, o: Owner, set: ^Name_Set, ranks: []Rank_Entry) -> bool {
	for m in 0 ..< set.multi_len {
		c := set.multis[m]
		entries := copies_entries(c)[:c.count]
		name := ref_name(s, entries[0])
		group := rank_group(ranks, object, o, name)
		for r in entries {
			found := false
			for e in group {
				if e.kept && e.part == r.part && e.slot == r.slot {
					found = true
					break
				}
			}
			if !found {
				return false
			}
		}
	}
	return true
}

load_drop :: proc(ctx: ^Load_Context, s: Vset) {
	for &o in ctx.objects {
		if o.set == s {
			o.set = nil
		}
	}
	destroy(s)
}

load_finish :: proc(ctx: ^Load_Context) -> Decode_Error {
	for &o in ctx.objects {
		if o.set != nil {
			write_fence(o.set)
		}
	}
	ranks := ctx.ranks[:]
	slice.sort_by(ranks, rank_less)
	for i := 0; i < len(ranks); {
		j := i + 1
		for j < len(ranks) && ranks[j].object == ranks[i].object && ranks[j].owner == ranks[i].owner && lex_compare(ranks[j].name, ranks[i].name) == 0 {
			j += 1
		}
		group := ranks[i:j]
		k := group[0].copies
		if int(k) != len(group) {
			return .Bad_Rank
		}
		kept := 0
		for e, x in group {
			if e.copies != k || int(e.rank) != x {
				return .Bad_Rank
			}
			if e.kept {
				kept += 1
			}
		}
		s := ctx.objects[group[0].object].set
		if s != nil {
			if !copies_reorder(s, group[0].owner, group[0].name, group, kept) {
				return .Bad_Rank
			}
		} else if kept > 0 {
			return .Bad_Rank
		}
		i = j
	}
	for &obj, n in ctx.objects {
		s := obj.set
		if s == nil || s.lab == nil {
			continue
		}
		if !multis_recorded(s, u32(n), SHARED, &s.lab.names, ranks) {
			return .Bad_Rank
		}
		idx := s.lab.owners
		if idx == nil {
			continue
		}
		for i in 0 ..< idx.slot_cap {
			sl := idx.slots[i]
			if sl.owner == SHARED {
				continue
			}
			if !multis_recorded(s, u32(n), sl.owner, &sl.scope.own, ranks) {
				return .Bad_Rank
			}
		}
	}
	return .None
}

deserialize_at :: proc(data: []u8, a: ^Access, scratch: ^Scratch = nil) -> (out: Vset, err: Decode_Error) {
	if !access_valid(a) {
		return nil, .Bad_Scope
	}
	version: u8
	if version, err = payload_version(data); err != .None {
		return nil, err
	}
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	src: Vset
	if version == CODEC_VERSION {
		src, err = deserialize_graph(data, sc, 1, false)
	} else {
		src, err = deserialize_v1(data, sc)
	}
	if err != .None {
		return nil, err
	}
	defer destroy(src)
	if out, err = load_set_new(params_of(src)); err != .None {
		return nil, err
	}
	p, _, perr := part_for_write(out, a)
	if perr != .None {
		destroy(out)
		return nil, .Out_Of_Memory
	}
	clear(&sc.pairs)
	if reserve(&sc.pairs, src.count) != nil {
		destroy(out)
		return nil, .Out_Of_Memory
	}
	for i in 0 ..< src.count {
		slot := src.order[i]
		append(&sc.pairs, Seq_Slot{seq = src.elements[slot].seq, slot = slot})
	}
	slice.sort_by(sc.pairs[:], proc(x, y: Seq_Slot) -> bool {
		return x.seq < y.seq
	})
	order := make([]u32, len(sc.pairs))
	defer delete(order)
	for pair, i in sc.pairs {
		order[i] = pair.slot
	}
	for slot in order {
		name := element_name(src, slot)
		text, has := element_attribute(src, slot)
		attr: vfilter.Attribute
		if has {
			made: bool
			if attr, made = part_make_attribute(out, p, transmute([]u8)text, true); !made {
				destroy(out)
				return nil, .Out_Of_Memory
			}
		}
		at, f := part_insert_raw(out, p, name, vmath.arena_bytes(&src.arena, slot), vmath.arena_norm(&src.arena, slot), vmath.arena_range(&src.arena, slot), attr, sc)
		if f.err != .None {
			part_discard_attribute(out, p, &attr)
			destroy(out)
			return nil, .Out_Of_Memory
		}
		ni := part_index(out, p)
		if !index_add(out, &ni, name, Ref{slot = at, part = p.id}) {
			destroy(out)
			return nil, .Out_Of_Memory
		}
		out.lab.total += 1
	}
	tally_refresh(p)
	part_maybe_graduate(out, p, sc)
	out.version = 0
	return out, .None
}
