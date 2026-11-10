package vsettype

import "../hnsw"
import lbl "../label"
import "../rax"
import "../vmath"

OWNER_PART_BASE :: u32(1) << 16
OWNER_PART_END :: u32(1) << 31
COMPACT_FIXED_BYTES :: size_of(Compact_Block)
OWNER_SLOTS_MIN :: u32(8)
SCOPE_PARTS_MIN :: u32(3)
SCAN_STALE :: max(u64)

Compact_Block :: struct {
	using head: Part_Head,
	charge:     Charge,
	uid:        u64,
	seed:       u64,
}

Owner_Slot :: struct {
	owner: Owner,
	scope: ^Owner_Scope,
}

Owner_Scope :: struct {
	charge:      Charge,
	names:       ^rax.Rax,
	parts:       [^]^Part_Head,
	using own:   Name_Set,
	seen_shared: u64,
	owner:       Owner,
	part_len:    u16,
	part_cap:    u16,
	collide:     bool,
}

Owner_Index :: struct {
	ledger:     Ledger,
	index:      Charge,
	parts:      [^]^Part_Head,
	free:       [^]u32,
	slots:      [^]Owner_Slot,
	part_cap:   u32,
	part_high:  u32,
	free_len:   u32,
	free_cap:   u32,
	slot_cap:   u32,
	slot_len:   u32,
	rax_bytes:  int,
	shared_gen: u64,
}

owner_part_by_id :: #force_inline proc "contextless" (idx: ^Owner_Index, id: u32) -> ^Part_Head {
	if idx == nil {
		return nil
	}
	local := id - OWNER_PART_BASE
	if local >= idx.part_high {
		return nil
	}
	return idx.parts[local]
}

owner_home :: #force_inline proc "contextless" (o: Owner, mask: u32) -> u32 {
	return u32(mix64(u64(o))) & mask
}

owner_scope :: proc "contextless" (s: Vset, o: Owner) -> ^Owner_Scope {
	if s == nil || s.lab == nil || o == SHARED {
		return nil
	}
	idx := s.lab.owners
	if idx == nil || idx.slot_len == 0 {
		return nil
	}
	mask := idx.slot_cap - 1
	i := owner_home(o, mask)
	for {
		sl := &idx.slots[i]
		if sl.owner == o {
			return sl.scope
		}
		if sl.owner == SHARED {
			return nil
		}
		i = (i + 1) & mask
	}
}

slots_put :: proc "contextless" (idx: ^Owner_Index, o: Owner, scope: ^Owner_Scope) {
	mask := idx.slot_cap - 1
	i := owner_home(o, mask)
	for idx.slots[i].owner != SHARED {
		i = (i + 1) & mask
	}
	idx.slots[i] = Owner_Slot{owner = o, scope = scope}
}

slots_resize :: proc "contextless" (idx: ^Owner_Index, cap: u32) -> bool {
	fresh := ([^]Owner_Slot)(charge_alloc(&idx.index, int(cap) * size_of(Owner_Slot), align_of(Owner_Slot), true))
	if fresh == nil {
		return false
	}
	old := idx.slots
	old_cap := idx.slot_cap
	idx.slots = fresh
	idx.slot_cap = cap
	for i in 0 ..< old_cap {
		if sl := old[i]; sl.owner != SHARED {
			slots_put(idx, sl.owner, sl.scope)
		}
	}
	charge_free(&idx.index, old)
	return true
}

slots_delete :: proc "contextless" (idx: ^Owner_Index, o: Owner) {
	mask := idx.slot_cap - 1
	i := owner_home(o, mask)
	for idx.slots[i].owner != o {
		if idx.slots[i].owner == SHARED {
			return
		}
		i = (i + 1) & mask
	}
	j := i
	for {
		j = (j + 1) & mask
		if idx.slots[j].owner == SHARED {
			break
		}
		k := owner_home(idx.slots[j].owner, mask)
		stays := (i < k && k <= j) if i <= j else (i < k || k <= j)
		if stays {
			continue
		}
		idx.slots[i] = idx.slots[j]
		i = j
	}
	idx.slots[i] = {}
}

owners_attach :: proc(s: Vset) -> (idx: ^Owner_Index, err: Error) {
	lab := s.lab
	if lab.owners != nil {
		return lab.owners, .None
	}
	idx = (^Owner_Index)(block_alloc(&s.ledger, size_of(Owner_Index), align_of(Owner_Index), true))
	if idx == nil {
		return nil, .Out_Of_Memory
	}
	idx.index = Charge{bytes = usable_size(idx), root = &s.ledger}
	lab.owners = idx
	return idx, .None
}

owners_detach :: proc(s: Vset) {
	idx := s.lab.owners
	if idx == nil {
		return
	}
	charge_free(&idx.index, idx.parts)
	charge_free(&idx.index, idx.free)
	charge_free(&idx.index, idx.slots)
	block_free(&s.ledger, idx)
	s.lab.owners = nil
}

owner_scope_make :: proc(s: Vset, idx: ^Owner_Index, o: Owner) -> (scope: ^Owner_Scope, err: Error) {
	if o == SHARED || o == EVERY_OWNER {
		return nil, .Invalid_Parameter
	}
	if (idx.slot_len + 1) * 4 > idx.slot_cap * 3 && !slots_resize(idx, max(OWNER_SLOTS_MIN, idx.slot_cap * 2)) {
		return nil, .Out_Of_Memory
	}
	scope = (^Owner_Scope)(block_alloc(&idx.ledger, size_of(Owner_Scope), align_of(Owner_Scope), true))
	if scope == nil {
		return nil, .Out_Of_Memory
	}
	scope.charge.root = &idx.ledger
	scope.owner = o
	scope.names = rax.create(&idx.rax_bytes)
	scope.seen_shared = SCAN_STALE
	slots_put(idx, o, scope)
	idx.slot_len += 1
	return scope, .None
}

owner_scope_drop :: proc(s: Vset, scope: ^Owner_Scope) {
	idx := s.lab.owners
	slots_delete(idx, scope.owner)
	idx.slot_len -= 1
	for i in 0 ..< scope.multi_len {
		charge_free(&scope.charge, scope.multis[i])
	}
	charge_free(&scope.charge, scope.multis)
	charge_free(&scope.charge, scope.parts)
	rax.destroy(scope.names)
	block_free(&idx.ledger, scope)
	if idx.slot_len == 0 {
		owners_detach(s)
		return
	}
	if idx.slot_cap > OWNER_SLOTS_MIN && idx.slot_len * 8 < idx.slot_cap {
		slots_resize(idx, idx.slot_cap / 2)
	}
}

scope_index :: proc "contextless" (scope: ^Owner_Scope) -> Name_Index {
	if scope == nil {
		return {}
	}
	return Name_Index{tree = scope.names, set = &scope.own, charge = &scope.charge, stale = &scope.seen_shared}
}

scope_lower :: proc "contextless" (scope: ^Owner_Scope, l: lbl.Id) -> int {
	lo, hi := 0, int(scope.part_len)
	for lo < hi {
		mid := (lo + hi) / 2
		if scope.parts[mid].label < l {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

scope_part_at :: proc "contextless" (scope: ^Owner_Scope, l: lbl.Id) -> ^Part_Head {
	if scope == nil {
		return nil
	}
	i := scope_lower(scope, l)
	if i < int(scope.part_len) && scope.parts[i].label == l {
		return scope.parts[i]
	}
	return nil
}

scope_reserve :: proc "contextless" (scope: ^Owner_Scope, need: u32) -> bool {
	cap := u32(scope.part_cap)
	if need <= cap {
		return true
	}
	if need > SHARED_PART_LIMIT {
		return false
	}
	n := min(max(need, cap * 2, SCOPE_PARTS_MIN), SHARED_PART_LIMIT)
	q := charge_resize(&scope.charge, scope.parts, int(cap) * size_of(^Part_Head), int(n) * size_of(^Part_Head), 8, false)
	if q == nil {
		return false
	}
	scope.parts = ([^]^Part_Head)(q)
	scope.part_cap = u16(n)
	return true
}

scope_insert :: proc "contextless" (scope: ^Owner_Scope, p: ^Part_Head) {
	i := scope_lower(scope, p.label)
	for j := int(scope.part_len); j > i; j -= 1 {
		scope.parts[j] = scope.parts[j - 1]
	}
	scope.parts[i] = p
	scope.part_len += 1
}

scope_remove :: proc "contextless" (scope: ^Owner_Scope, p: ^Part_Head) {
	i := scope_lower(scope, p.label)
	if i >= int(scope.part_len) || scope.parts[i] != p {
		return
	}
	for j in i ..< int(scope.part_len) - 1 {
		scope.parts[j] = scope.parts[j + 1]
	}
	scope.part_len -= 1
}

scope_replace :: proc "contextless" (s: Vset, old: ^Part_Head, fresh: ^Part_Head) {
	idx := s.lab.owners
	idx.parts[fresh.id - OWNER_PART_BASE] = fresh
	scope := owner_scope(s, fresh.owner)
	if i := scope_lower(scope, fresh.label); i < int(scope.part_len) && scope.parts[i] == old {
		scope.parts[i] = fresh
	}
}

owner_id_take :: proc "contextless" (idx: ^Owner_Index) -> (id: u32, ok: bool) {
	if idx.free_len > 0 {
		idx.free_len -= 1
		return OWNER_PART_BASE + idx.free[idx.free_len], true
	}
	local := idx.part_high
	if local >= OWNER_PART_END - OWNER_PART_BASE {
		return 0, false
	}
	q, cap, grown := charge_grow(&idx.index, idx.parts, idx.part_cap, size_of(^Part_Head), local + 1)
	idx.parts = ([^]^Part_Head)(q)
	idx.part_cap = cap
	if !grown {
		return 0, false
	}
	f, fcap, fgrown := charge_grow(&idx.index, idx.free, idx.free_cap, size_of(u32), local + 1)
	idx.free = ([^]u32)(f)
	idx.free_cap = fcap
	if !fgrown {
		return 0, false
	}
	idx.parts[local] = nil
	idx.part_high += 1
	return OWNER_PART_BASE + local, true
}

owner_id_give :: proc "contextless" (idx: ^Owner_Index, id: u32) {
	local := id - OWNER_PART_BASE
	idx.parts[local] = nil
	idx.free[idx.free_len] = local
	idx.free_len += 1
}

owner_part_create :: proc(s: Vset, scope: ^Owner_Scope, l: lbl.Id, seed: u64) -> (p: ^Part_Head, err: Error) {
	idx := s.lab.owners
	if !scope_reserve(scope, u32(scope.part_len) + 1) {
		return nil, .Out_Of_Memory
	}
	id, ok := owner_id_take(idx)
	if !ok {
		return nil, .Out_Of_Memory
	}
	blk := (^Compact_Block)(block_alloc(&idx.ledger, size_of(Compact_Block), align_of(Compact_Block), true))
	if blk == nil {
		owner_id_give(idx, id)
		return nil, .Out_Of_Memory
	}
	blk.charge.root = &idx.ledger
	if vmath.arena_init(&blk.arena, s.arena.elem, .Cosine, s.dim, charge_allocator(&blk.charge)) != nil {
		block_free(&idx.ledger, blk)
		owner_id_give(idx, id)
		return nil, .Out_Of_Memory
	}
	blk.id = id
	blk.label = l
	blk.owner = scope.owner
	blk.kind = .Compact
	blk.mode = .Flat
	blk.seed = seed
	idx.parts[id - OWNER_PART_BASE] = &blk.head
	scope_insert(scope, &blk.head)
	return &blk.head, .None
}

owner_part_retire :: proc(s: Vset, p: ^Part_Head) {
	idx := s.lab.owners
	scope := owner_scope(s, p.owner)
	scope_remove(scope, p)
	owner_id_give(idx, p.id)
	part_release_all(s, p)
	block_free(&idx.ledger, p)
	if scope.part_len == 0 {
		owner_scope_drop(s, scope)
	}
}

owner_part_for_write :: proc(s: Vset, a: ^Access) -> (p: ^Part_Head, created: bool, err: Error) {
	idx: ^Owner_Index
	if idx, err = owners_attach(s); err != .None {
		return nil, false, err
	}
	scope := owner_scope(s, a.owner)
	fresh := false
	if scope == nil {
		if scope, err = owner_scope_make(s, idx, a.owner); err != .None {
			if idx.slot_len == 0 {
				owners_detach(s)
			}
			return nil, false, err
		}
		fresh = true
	} else if p = scope_part_at(scope, a.label); p != nil {
		return p, false, .None
	}
	if p, err = owner_part_create(s, scope, a.label, draw_seed(a)); err != .None {
		if fresh {
			owner_scope_drop(s, scope)
		}
		return nil, false, err
	}
	return p, true, .None
}

part_uid :: #force_inline proc "contextless" (p: ^Part_Head) -> u64 {
	if p.kind == .Compact {
		return (^Compact_Block)(p).uid
	}
	return part_graph(p).node_uid
}

part_uid_bump :: #force_inline proc "contextless" (p: ^Part_Head) -> u64 {
	if p.kind == .Compact {
		blk := (^Compact_Block)(p)
		blk.uid += 1
		return blk.uid
	}
	g := part_graph(p)
	g.node_uid += 1
	return g.node_uid
}

proxy_fill :: proc "contextless" (s: Vset, out: ^Partition, blk: ^Compact_Block) {
	out^ = {}
	out.head = blk.head
	out.graph.m = s.graph.m
	out.graph.m0 = s.graph.m0
	out.graph.rng = blk.seed
	out.graph.node_uid = blk.uid
	out.graph.free_head = hnsw.NONE
	out.graph.entry = hnsw.NONE
}

owner_graduate :: proc(s: Vset, p: ^Part_Head, sc: ^Scratch) -> Error {
	idx := s.lab.owners
	compact := (^Compact_Block)(p)
	blk := (^Part_Block)(block_alloc(&idx.ledger, size_of(Part_Block), align_of(Part_Block), true))
	if blk == nil {
		return .Out_Of_Memory
	}
	blk.head = compact.head
	blk.kind = .Block
	blk.charge = Charge{bytes = compact.charge.bytes, root = &idx.ledger}
	alloc := charge_allocator(&blk.charge)
	blk.arena.allocator = alloc
	if hnsw.init(&blk.graph, graph_params(s.graph.m, compact.seed), graph_distance, &blk.part, alloc) != .None {
		block_free(&idx.ledger, blk)
		return .Out_Of_Memory
	}
	blk.graph.node_uid = compact.uid
	if part_graduate(s, &blk.part, sc) != .None {
		hnsw.destroy(&blk.graph)
		block_free(&idx.ledger, blk)
		return .Out_Of_Memory
	}
	scope_replace(s, p, &blk.head)
	block_free(&idx.ledger, compact)
	return .None
}

owner_flatten :: proc(s: Vset, p: ^Part_Head) {
	idx := s.lab.owners
	full := (^Part_Block)(p)
	compact := (^Compact_Block)(block_alloc(&idx.ledger, size_of(Compact_Block), align_of(Compact_Block), true))
	if compact == nil {
		return
	}
	uid := full.graph.node_uid
	seed := full.graph.rng
	hnsw.destroy(&full.graph)
	compact.head = full.head
	compact.kind = .Compact
	compact.mode = .Flat
	compact.charge = Charge{bytes = full.charge.bytes, root = &idx.ledger}
	compact.arena.allocator = charge_allocator(&compact.charge)
	compact.uid = uid
	compact.seed = seed
	scope_replace(s, p, &compact.head)
	block_free(&idx.ledger, full)
}

scope_overhead :: proc "contextless" (scope: ^Owner_Scope) -> int {
	return usable_size(scope) + scope.charge.bytes + rax.memory(scope.names)
}

owner_bytes :: proc "contextless" (s: Vset) -> int {
	if s == nil || s.lab == nil || s.lab.owners == nil {
		return 0
	}
	return s.lab.owners.ledger.bytes + s.lab.owners.rax_bytes
}

index_bytes :: proc "contextless" (s: Vset) -> int {
	if s == nil || s.lab == nil || s.lab.owners == nil {
		return 0
	}
	return s.lab.owners.index.bytes
}

has_scope :: proc "contextless" (s: Vset, l: lbl.Id, o: Owner) -> bool {
	return part_at_scope(s, l, o) != nil
}

scope_card :: proc "contextless" (s: Vset, l: lbl.Id, o: Owner) -> int {
	p := part_at_scope(s, l, o)
	return 0 if p == nil else p.count
}

scope_memory :: proc "contextless" (s: Vset, l: lbl.Id, o: Owner) -> int {
	if o == SHARED {
		return label_memory(s, l)
	}
	scope := owner_scope(s, o)
	p := scope_part_at(scope, l)
	if p == nil {
		return 0
	}
	n := part_footprint(s, p)
	if scope.parts[0] == p {
		n += scope_overhead(scope)
	}
	return n
}

owner_memory :: proc "contextless" (s: Vset, o: Owner) -> int {
	scope := owner_scope(s, o)
	if scope == nil {
		return 0
	}
	n := scope_overhead(scope)
	for i in 0 ..< scope.part_len {
		n += part_footprint(s, scope.parts[i])
	}
	return n
}

owner_card :: proc "contextless" (s: Vset, o: Owner) -> int {
	scope := owner_scope(s, o)
	if scope == nil {
		return 0
	}
	n := 0
	for i in 0 ..< scope.part_len {
		n += scope.parts[i].count
	}
	return n
}

owner_labels :: proc(s: Vset, o: Owner, out: ^[dynamic]lbl.Id) {
	scope := owner_scope(s, o)
	if scope == nil {
		return
	}
	for i in 0 ..< scope.part_len {
		append(out, scope.parts[i].label)
	}
}

owner_count :: proc "contextless" (s: Vset) -> int {
	if s == nil || s.lab == nil || s.lab.owners == nil {
		return 0
	}
	return int(s.lab.owners.slot_len)
}

remove_scope :: proc(s: Vset, l: lbl.Id, o: Owner) -> (removed: int, ch: Change) {
	if o == SHARED {
		return remove_label(s, l)
	}
	if s == nil {
		ch.emptied = true
		return
	}
	p := part_at_scope(s, l, o)
	if p == nil {
		ch.emptied = card(s) == 0
		return
	}
	removed = part_remove_all(s, p)
	ch.found = true
	ch.label_gone = true
	ch.emptied = s.lab.total == 0
	return
}

remove_owner :: proc(s: Vset, o: Owner, labels: ^[dynamic]lbl.Id = nil) -> (removed: int, ch: Change) {
	if s == nil {
		ch.emptied = true
		return
	}
	scope := owner_scope(s, o)
	if scope == nil {
		ch.emptied = card(s) == 0
		return
	}
	idx := s.lab.owners
	for i in 0 ..< scope.part_len {
		p := scope.parts[i]
		if labels != nil {
			append(labels, p.label)
		}
		removed += p.count
		owner_id_give(idx, p.id)
		part_release_all(s, p)
		block_free(&idx.ledger, p)
	}
	scope.part_len = 0
	s.lab.total -= removed
	owner_scope_drop(s, scope)
	s.version += 1
	ch.found = removed > 0
	ch.label_gone = removed > 0
	ch.emptied = s.lab.total == 0
	return
}

owner_part_move :: proc(src: Vset, dst: Vset, p: ^Part_Head, dscope: ^Owner_Scope) -> Error {
	sidx := src.lab.owners
	didx := dst.lab.owners
	if !scope_reserve(dscope, u32(dscope.part_len) + 1) {
		return .Out_Of_Memory
	}
	id, ok := owner_id_take(didx)
	if !ok {
		return .Out_Of_Memory
	}
	sscope := owner_scope(src, p.owner)
	sni := scope_index(sscope)
	dni := scope_index(dscope)
	for i in 0 ..< p.count {
		slot := p.order[i]
		name := part_element_name(p, slot)
		index_remove(src, &sni, name, Ref{slot = slot, part = p.id})
		index_add(dst, &dni, name, Ref{slot = slot, part = id})
	}
	scope_remove(sscope, p)
	owner_id_give(sidx, p.id)
	c := part_charge(src, p)
	moved := usable_size(p) + c.bytes
	sidx.ledger.bytes -= moved
	didx.ledger.bytes += moved
	c.root = &didx.ledger
	p.id = id
	didx.parts[id - OWNER_PART_BASE] = p
	scope_insert(dscope, p)
	src.lab.total -= p.count
	dst.lab.total += p.count
	src.version += 1
	dst.version += 1
	if sscope.part_len == 0 {
		owner_scope_drop(src, sscope)
	}
	return .None
}

split_scope :: proc(s: Vset, l: lbl.Id, o: Owner) -> (out: Vset, ch: Change, err: Error) {
	if o == SHARED {
		return split_label(s, l)
	}
	if s == nil || s.lab == nil {
		return nil, ch, .Invalid_Parameter
	}
	p := part_at_scope(s, l, o)
	if p == nil {
		return nil, ch, .Element_Not_Found
	}
	if out, err = split_target(s); err != .None {
		return nil, ch, err
	}
	didx: ^Owner_Index
	if didx, err = owners_attach(out); err != .None {
		destroy(out)
		return nil, ch, err
	}
	dscope: ^Owner_Scope
	if dscope, err = owner_scope_make(out, didx, o); err != .None {
		destroy(out)
		return nil, ch, err
	}
	if err = owner_part_move(s, out, p, dscope); err != .None {
		destroy(out)
		return nil, ch, err
	}
	out.version = 0
	ch.found = true
	ch.label_gone = true
	ch.emptied = s.lab.total == 0
	return out, ch, .None
}

owners_clash :: proc "contextless" (dst: Vset, src: Vset) -> bool {
	idx := src.lab.owners
	for i in 0 ..< idx.slot_cap {
		sl := idx.slots[i]
		if sl.owner == SHARED {
			continue
		}
		for j in 0 ..< sl.scope.part_len {
			if part_at_scope(dst, sl.scope.parts[j].label, sl.owner) != nil {
				return true
			}
		}
	}
	return false
}

owners_absorb :: proc(dst: Vset, src: Vset) -> Error {
	didx, err := owners_attach(dst)
	if err != .None {
		return err
	}
	for src.lab.owners != nil {
		idx := src.lab.owners
		scope: ^Owner_Scope
		for i in 0 ..< idx.slot_cap {
			if idx.slots[i].owner != SHARED {
				scope = idx.slots[i].scope
				break
			}
		}
		dscope := owner_scope(dst, scope.owner)
		if dscope == nil {
			if dscope, err = owner_scope_make(dst, didx, scope.owner); err != .None {
				return err
			}
		}
		if err = owner_part_move(src, dst, scope.parts[scope.part_len - 1], dscope); err != .None {
			return err
		}
	}
	return .None
}

owners_destroy :: proc(s: Vset) {
	idx := s.lab.owners
	for i in 0 ..< idx.slot_cap {
		sl := idx.slots[i]
		if sl.owner == SHARED {
			continue
		}
		scope := sl.scope
		for j in 0 ..< scope.part_len {
			p := scope.parts[j]
			part_release_all(s, p)
			block_free(&idx.ledger, p)
		}
		for j in 0 ..< scope.multi_len {
			charge_free(&scope.charge, scope.multis[j])
		}
		charge_free(&scope.charge, scope.multis)
		charge_free(&scope.charge, scope.parts)
		rax.destroy(scope.names)
		block_free(&idx.ledger, scope)
	}
	owners_detach(s)
}
