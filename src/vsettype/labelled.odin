package vsettype

import "../hnsw"
import lbl "../label"
import "../rax"
import "../vmath"

NAME_MULTI :: u64(1) << 63
PART_NONE :: max(u32)
PART_FIXED_BYTES :: size_of(Part_Block)
VIEW_BASE_BYTES :: size_of(Vset_Object) + size_of(Labelled)
NAME_INDEX_BYTES :: 24
SHARED_PART_LIMIT :: u32(lbl.LABEL_LIMIT)

Access :: struct {
	label:      lbl.Id,
	owner:      Owner,
	visibility: ^lbl.Visibility,
	table:      ^lbl.Table,
	stream:     ^u64,
	top:        bool,
}

Ref :: struct {
	slot: u32,
	part: u32,
}

REF_NONE :: Ref{slot = NIL_SLOT, part = PART_NONE}

Copies :: struct {
	count: u32,
	cap:   u32,
	index: u32,
	spare: u32,
}

Part_Block :: struct {
	using part: Partition,
	charge:     Charge,
}

Name_Set :: struct {
	multis:    [^]^Copies,
	multi_len: u32,
	multi_cap: u32,
}

Labelled :: struct {
	sorted:      [^]^Partition,
	by_id:       [^]^Partition,
	owners:      ^Owner_Index,
	using names: Name_Set,
	sorted_len:  u16,
	sorted_cap:  u16,
	id_cap:      u16,
	id_high:     u16,
	total:       int,
}

Name_Index :: struct {
	tree:   ^rax.Rax,
	set:    ^Name_Set,
	charge: ^Charge,
	gen:    ^u64,
	stale:  ^u64,
}

Change :: struct {
	added:      bool,
	found:      bool,
	dropped:    bool,
	emptied:    bool,
	label_new:  bool,
	label_gone: bool,
}

resolution_compare :: proc "contextless" (a: ^Access, x, y: lbl.Id) -> int {
	if x == y || a.table == nil {
		return 0
	}
	lx, okx := lbl.table_label(a.table, x)
	ly, oky := lbl.table_label(a.table, y)
	if !okx || !oky {
		return 0
	}
	return lbl.resolution_compare(lx, ly)
}

label_order_less :: proc "contextless" (a: ^Access, x, y: lbl.Id) -> bool {
	if r := resolution_compare(a, x, y); r != 0 {
		return r > 0
	}
	if a.table != nil {
		lx, okx := lbl.table_label(a.table, x)
		ly, oky := lbl.table_label(a.table, y)
		if okx && oky {
			for w := lbl.COMPARTMENT_WORDS - 1; w >= 0; w -= 1 {
				if lx.compartments[w] != ly.compartments[w] {
					return lx.compartments[w] > ly.compartments[w]
				}
			}
		}
	}
	return x < y
}

scope_order_less :: proc "contextless" (a: ^Access, x: Scope, y: Scope) -> bool {
	if r := resolution_compare(a, x.label, y.label); r != 0 {
		return r > 0
	}
	if x.owner != y.owner {
		return x.owner != SHARED
	}
	return label_order_less(a, x.label, y.label)
}

sees :: #force_inline proc "contextless" (a: ^Access, l: lbl.Id) -> bool {
	return a.visibility != nil && lbl.visible(a.visibility, l)
}

sees_part :: #force_inline proc "contextless" (a: ^Access, p: ^Part_Head) -> bool {
	return (p.owner == SHARED || p.owner == a.owner) && sees(a, p.label)
}

access_valid :: #force_inline proc "contextless" (a: ^Access) -> bool {
	return a.owner == SHARED || (a.owner != EVERY_OWNER && a.stream != nil)
}

access_stream :: proc(a: ^Access) -> ^u64 {
	if a.stream != nil {
		return a.stream
	}
	if a.owner != SHARED {
		return nil
	}
	return label_stream(a.label)
}

draw_seed :: proc(a: ^Access) -> u64 {
	st := access_stream(a)
	if st == nil {
		return stream_seed(a.label)
	}
	return stream_next(st) | 1
}

copies_entries :: #force_inline proc "contextless" (c: ^Copies) -> [^]Ref {
	return ([^]Ref)(uintptr(c) + size_of(Copies))
}

copies_bytes :: #force_inline proc "contextless" (cap: u32) -> int {
	return size_of(Copies) + int(cap) * size_of(Ref)
}

name_inline :: #force_inline proc "contextless" (r: Ref) -> rawptr {
	return rawptr(uintptr((u64(r.part) << 32 | u64(r.slot)) + 1))
}

name_multi :: #force_inline proc "contextless" (c: ^Copies) -> rawptr {
	return rawptr(uintptr(u64(uintptr(c)) | NAME_MULTI))
}

name_decode :: proc "contextless" (v: rawptr, one: ^Ref) -> []Ref {
	x := u64(uintptr(v))
	if x & NAME_MULTI != 0 {
		c := (^Copies)(uintptr(x &~ NAME_MULTI))
		return copies_entries(c)[:c.count]
	}
	x -= 1
	one^ = Ref{slot = u32(x), part = u32(x >> 32)}
	return ([^]Ref)(one)[:1]
}

tree_lookup :: proc "contextless" (tree: ^rax.Rax, name: []u8, one: ^Ref) -> []Ref {
	if tree == nil {
		return nil
	}
	v, found := rax.find(tree, name)
	if !found {
		return nil
	}
	return name_decode(v, one)
}

names_lookup :: proc "contextless" (s: Vset, name: []u8, one: ^Ref) -> []Ref {
	return tree_lookup(s.names, name, one)
}

labelled :: #force_inline proc "contextless" (s: Vset) -> bool {
	return s != nil && s.lab != nil
}

part_by_id :: #force_inline proc "contextless" (s: Vset, id: u32) -> ^Part_Head {
	if s.lab == nil {
		return &s.core if id == 0 else nil
	}
	if id >= OWNER_PART_BASE {
		return owner_part_by_id(s.lab.owners, id)
	}
	if id >= u32(s.lab.id_high) {
		return nil
	}
	return s.lab.by_id[id]
}

ref_part :: #force_inline proc "contextless" (s: Vset, r: Ref) -> ^Part_Head {
	return part_by_id(s, r.part)
}

ref_label :: #force_inline proc "contextless" (s: Vset, r: Ref) -> lbl.Id {
	return part_by_id(s, r.part).label
}

ref_owner :: #force_inline proc "contextless" (s: Vset, r: Ref) -> Owner {
	return part_by_id(s, r.part).owner
}

ref_scope :: #force_inline proc "contextless" (s: Vset, r: Ref) -> Scope {
	p := part_by_id(s, r.part)
	return Scope{label = p.label, owner = p.owner}
}

sorted_lower :: proc "contextless" (lab: ^Labelled, l: lbl.Id) -> int {
	lo, hi := 0, int(lab.sorted_len)
	for lo < hi {
		mid := (lo + hi) / 2
		if lab.sorted[mid].label < l {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

part_at_label :: proc "contextless" (s: Vset, l: lbl.Id) -> ^Partition {
	if s.lab == nil {
		return &s.core if l == lbl.BOTTOM_ID && s.count > 0 else nil
	}
	lab := s.lab
	i := sorted_lower(lab, l)
	if i < int(lab.sorted_len) && lab.sorted[i].label == l {
		return lab.sorted[i]
	}
	return nil
}

part_at_scope :: proc "contextless" (s: Vset, l: lbl.Id, o: Owner) -> ^Part_Head {
	if s == nil {
		return nil
	}
	if o == SHARED {
		return part_at_label(s, l)
	}
	if s.lab == nil {
		return nil
	}
	scope := owner_scope(s, o)
	if scope == nil {
		return nil
	}
	return scope_part_at(scope, l)
}

grow_room :: proc "contextless" (cap: u32, need: u32, limit: u32) -> (n: u32, ok: bool) {
	if need > limit {
		return cap, false
	}
	if need <= cap {
		return cap, true
	}
	return min(max(need, cap * 2, 4), limit), true
}

lab_grow :: proc "contextless" (l: ^Ledger, p: rawptr, cap: u32, elem: int, need: u32, limit := max(u32)) -> (q: rawptr, fresh: u32, ok: bool) {
	n, room := grow_room(cap, need, limit)
	if !room {
		return p, cap, false
	}
	if n == cap {
		return p, cap, true
	}
	q = block_resize(l, p, int(cap) * elem, int(n) * elem, 8, false)
	if q == nil {
		return p, cap, false
	}
	return q, n, true
}

charge_grow :: proc "contextless" (c: ^Charge, p: rawptr, cap: u32, elem: int, need: u32, limit := max(u32)) -> (q: rawptr, fresh: u32, ok: bool) {
	n, room := grow_room(cap, need, limit)
	if !room {
		return p, cap, false
	}
	if n == cap {
		return p, cap, true
	}
	q = charge_resize(c, p, int(cap) * elem, int(n) * elem, 8, false)
	if q == nil {
		return p, cap, false
	}
	return q, n, true
}

sorted_reserve :: proc "contextless" (s: Vset, need: u32) -> bool {
	lab := s.lab
	q, cap, ok := lab_grow(&s.ledger, lab.sorted, u32(lab.sorted_cap), size_of(^Partition), need, SHARED_PART_LIMIT)
	lab.sorted = ([^]^Partition)(q)
	lab.sorted_cap = u16(cap)
	return ok
}

ids_reserve :: proc "contextless" (s: Vset, need: u32) -> bool {
	lab := s.lab
	q, cap, ok := lab_grow(&s.ledger, lab.by_id, u32(lab.id_cap), size_of(^Partition), need, SHARED_PART_LIMIT)
	lab.by_id = ([^]^Partition)(q)
	lab.id_cap = u16(cap)
	return ok
}

index_alloc :: proc "contextless" (s: Vset, ni: ^Name_Index, size: int) -> rawptr {
	if ni.charge != nil {
		return charge_alloc(ni.charge, size, 8, false)
	}
	return block_alloc(&s.ledger, size, 8, false)
}

index_free :: proc "contextless" (s: Vset, ni: ^Name_Index, p: rawptr) {
	if ni.charge != nil {
		charge_free(ni.charge, p)
		return
	}
	block_free(&s.ledger, p)
}

index_resize :: proc "contextless" (s: Vset, ni: ^Name_Index, p: rawptr, old_size: int, size: int) -> rawptr {
	if ni.charge != nil {
		return charge_resize(ni.charge, p, old_size, size, 8, false)
	}
	return block_resize(&s.ledger, p, old_size, size, 8, false)
}

multis_reserve :: proc "contextless" (s: Vset, ni: ^Name_Index, need: u32) -> bool {
	set := ni.set
	q: rawptr
	cap: u32
	ok: bool
	if ni.charge != nil {
		q, cap, ok = charge_grow(ni.charge, set.multis, set.multi_cap, size_of(^Copies), need)
	} else {
		q, cap, ok = lab_grow(&s.ledger, set.multis, set.multi_cap, size_of(^Copies), need)
	}
	set.multis = ([^]^Copies)(q)
	set.multi_cap = cap
	return ok
}

shared_index :: proc "contextless" (s: Vset) -> Name_Index {
	ni := Name_Index{tree = s.names}
	if s.lab != nil {
		ni.set = &s.lab.names
		if s.lab.owners != nil {
			ni.gen = &s.lab.owners.shared_gen
		}
	}
	return ni
}

part_index :: proc "contextless" (s: Vset, p: ^Part_Head) -> Name_Index {
	if p.owner == SHARED {
		return shared_index(s)
	}
	return scope_index(owner_scope(s, p.owner))
}

free_id :: proc "contextless" (lab: ^Labelled) -> u32 {
	for i in 0 ..< lab.id_high {
		if lab.by_id[i] == nil {
			return u32(i)
		}
	}
	return u32(lab.id_high)
}

labelled_attach :: proc(s: Vset) -> Error {
	if s.lab != nil {
		return .None
	}
	lab := (^Labelled)(block_alloc(&s.ledger, size_of(Labelled), align_of(Labelled), true))
	if lab == nil {
		return .Out_Of_Memory
	}
	s.lab = lab
	return .None
}

part_rebind :: proc(p: ^Part_Head, c: ^Charge) {
	alloc := charge_allocator(c)
	p.arena.allocator = alloc
	if full := part_full(p); full != nil {
		full.graph.allocator = alloc
		full.graph.ctx = full
		if full.graph.prefetch != nil {
			hnsw.set_prefetch(&full.graph, vmath.arena_prefetch_hook, &full.arena)
		}
	}
}

convert :: proc(s: Vset) -> Error {
	if s.lab != nil {
		return .None
	}
	blk := (^Part_Block)(block_alloc(&s.ledger, size_of(Part_Block), align_of(Part_Block), true))
	if blk == nil {
		return .Out_Of_Memory
	}
	if labelled_attach(s) != .None {
		block_free(&s.ledger, blk)
		return .Out_Of_Memory
	}
	if !ids_reserve(s, 1) || !sorted_reserve(s, 1) {
		labelled_detach(s)
		block_free(&s.ledger, blk)
		return .Out_Of_Memory
	}
	m := s.core.graph.m
	q := s.core.arena.elem
	blk.part = s.core
	blk.charge = Charge{bytes = part_block_bytes(&s.core), root = &s.ledger}
	blk.kind = .Block
	part_rebind(&blk.part, &blk.charge)
	blk.id = 0
	blk.label = lbl.BOTTOM_ID
	blk.owner = SHARED
	blk.mode = .Pinned
	s.core = {}
	part_init(&s.core, q, s.dim, m, 1, allocator_of(s))
	lab := s.lab
	lab.by_id[0] = &blk.part
	lab.id_high = 1
	lab.total = blk.count
	if blk.count > 0 {
		sorted_insert(s, &blk.part)
	}
	return .None
}

labelled_detach :: proc(s: Vset) {
	lab := s.lab
	if lab == nil {
		return
	}
	block_free(&s.ledger, lab.sorted)
	block_free(&s.ledger, lab.by_id)
	block_free(&s.ledger, lab.multis)
	block_free(&s.ledger, lab)
	s.lab = nil
}

create_at :: proc(req: ^Add_Request, a: ^Access) -> (s: Vset, f: Failure) {
	if !access_valid(a) {
		return nil, failure(.Invalid_Parameter)
	}
	p, ok := request_params(req)
	if !ok {
		return nil, failure(.Invalid_Parameter)
	}
	p.seed = 1
	err: Error
	if s, err = create(p); err != .None {
		return nil, failure(err)
	}
	if labelled_attach(s) != .None {
		destroy(s)
		return nil, failure(.Out_Of_Memory)
	}
	return s, {}
}

sorted_insert :: proc "contextless" (s: Vset, p: ^Partition) {
	lab := s.lab
	i := sorted_lower(lab, p.label)
	for j := int(lab.sorted_len); j > i; j -= 1 {
		lab.sorted[j] = lab.sorted[j - 1]
	}
	lab.sorted[i] = p
	lab.sorted_len += 1
}

sorted_remove :: proc "contextless" (s: Vset, p: ^Partition) {
	lab := s.lab
	i := sorted_lower(lab, p.label)
	if i >= int(lab.sorted_len) || lab.sorted[i] != p {
		return
	}
	for j in i ..< int(lab.sorted_len) - 1 {
		lab.sorted[j] = lab.sorted[j + 1]
	}
	lab.sorted_len -= 1
}

part_create :: proc(s: Vset, l: lbl.Id, seed: u64) -> (p: ^Partition, err: Error) {
	lab := s.lab
	id := free_id(lab)
	if !ids_reserve(s, id + 1) || !sorted_reserve(s, u32(lab.sorted_len) + 1) {
		return nil, .Out_Of_Memory
	}
	blk := (^Part_Block)(block_alloc(&s.ledger, size_of(Part_Block), align_of(Part_Block), true))
	if blk == nil {
		return nil, .Out_Of_Memory
	}
	blk.charge.root = &s.ledger
	if err = part_init(&blk.part, s.arena.elem, s.dim, s.graph.m, seed, charge_allocator(&blk.charge)); err != .None {
		block_free(&s.ledger, blk)
		return nil, err
	}
	blk.id = id
	blk.label = l
	blk.owner = SHARED
	blk.kind = .Block
	blk.mode = .Flat
	lab.by_id[id] = &blk.part
	if id == u32(lab.id_high) {
		lab.id_high += 1
	}
	sorted_insert(s, &blk.part)
	return &blk.part, .None
}

part_retire :: proc(s: Vset, p: ^Part_Head) {
	if s.lab == nil || p.kind == .Core {
		return
	}
	if p.owner != SHARED {
		owner_part_retire(s, p)
		return
	}
	full := (^Partition)(p)
	sorted_remove(s, full)
	s.lab.by_id[p.id] = nil
	part_release_all(s, p)
	block_free(&s.ledger, p)
}

part_for_write :: proc(s: Vset, a: ^Access) -> (p: ^Part_Head, created: bool, err: Error) {
	if s.lab == nil {
		if a.owner == SHARED && a.label == lbl.BOTTOM_ID && s.count > 0 {
			return &s.core, false, .None
		}
		if s.count > 0 {
			if err = convert(s); err != .None {
				return nil, false, err
			}
		} else if err = labelled_attach(s); err != .None {
			return nil, false, err
		}
	}
	if a.owner != SHARED {
		return owner_part_for_write(s, a)
	}
	if shared := part_at_label(s, a.label); shared != nil {
		return shared, false, .None
	}
	made: ^Partition
	made, err = part_create(s, a.label, draw_seed(a))
	return made, err == .None, err
}

part_footprint :: proc "contextless" (s: Vset, p: ^Part_Head) -> int {
	switch p.kind {
	case .Core:
		return PART_FIXED_BYTES + s.ledger.bytes - usable_size(s)
	case .Block:
		blk := (^Part_Block)(p)
		if p.owner != SHARED {
			return usable_size(blk) + blk.charge.bytes
		}
		return PART_FIXED_BYTES + blk.charge.bytes
	case .Compact:
		blk := (^Compact_Block)(p)
		return usable_size(blk) + blk.charge.bytes
	}
	return 0
}

labelled_destroy :: proc(s: Vset) {
	lab := s.lab
	if lab.owners != nil {
		owners_destroy(s)
	}
	for i in 0 ..< lab.id_high {
		if p := lab.by_id[i]; p != nil {
			part_release_all(s, p)
			block_free(&s.ledger, p)
			lab.by_id[i] = nil
		}
	}
	for i in 0 ..< lab.multi_len {
		block_free(&s.ledger, lab.multis[i])
	}
	lab.multi_len = 0
	labelled_detach(s)
}

labelled_block_bytes :: proc "contextless" (s: Vset) -> int {
	lab := s.lab
	n := usable_size(lab) + usable_size(lab.sorted) + usable_size(lab.by_id) + usable_size(lab.multis)
	for i in 0 ..< lab.id_high {
		if p := lab.by_id[i]; p != nil {
			n += usable_size(p) + part_block_bytes(p)
		}
	}
	for i in 0 ..< lab.multi_len {
		n += usable_size(lab.multis[i])
	}
	if lab.owners != nil {
		n += lab.owners.index.bytes
	}
	return n
}

copies_alloc :: proc "contextless" (s: Vset, ni: ^Name_Index, cap: u32) -> ^Copies {
	c := (^Copies)(index_alloc(s, ni, copies_bytes(cap)))
	if c != nil {
		c^ = Copies{cap = cap}
	}
	return c
}

index_changed :: #force_inline proc "contextless" (ni: ^Name_Index) {
	if ni.gen != nil {
		ni.gen^ += 1
	}
	if ni.stale != nil {
		ni.stale^ = SCAN_STALE
	}
}

index_add :: proc(s: Vset, ni: ^Name_Index, name: []u8, r: Ref) -> bool {
	v, found := rax.find(ni.tree, name)
	if !found {
		rax.insert(ni.tree, name, name_inline(r))
		index_changed(ni)
		return true
	}
	x := u64(uintptr(v))
	set := ni.set
	if x & NAME_MULTI == 0 {
		if set == nil {
			return false
		}
		one: Ref
		old := name_decode(v, &one)[0]
		if !multis_reserve(s, ni, set.multi_len + 1) {
			return false
		}
		c := copies_alloc(s, ni, 2)
		if c == nil {
			return false
		}
		e := copies_entries(c)
		e[0] = old
		e[1] = r
		c.count = 2
		c.index = set.multi_len
		set.multis[c.index] = c
		set.multi_len += 1
		rax.insert(ni.tree, name, name_multi(c))
		return true
	}
	c := (^Copies)(uintptr(x &~ NAME_MULTI))
	if c.count == c.cap {
		grown := (^Copies)(index_resize(s, ni, c, copies_bytes(c.cap), copies_bytes(c.cap * 2)))
		if grown == nil {
			return false
		}
		grown.cap *= 2
		if grown != c {
			set.multis[grown.index] = grown
			rax.insert(ni.tree, name, name_multi(grown))
			c = grown
		}
	}
	copies_entries(c)[c.count] = r
	c.count += 1
	return true
}

index_remove :: proc(s: Vset, ni: ^Name_Index, name: []u8, r: Ref) {
	v, found := rax.find(ni.tree, name)
	if !found {
		return
	}
	x := u64(uintptr(v))
	if x & NAME_MULTI == 0 {
		rax.remove(ni.tree, name)
		index_changed(ni)
		return
	}
	c := (^Copies)(uintptr(x &~ NAME_MULTI))
	e := copies_entries(c)
	at := -1
	for i in 0 ..< int(c.count) {
		if e[i] == r {
			at = i
			break
		}
	}
	if at < 0 {
		return
	}
	for i in at ..< int(c.count) - 1 {
		e[i] = e[i + 1]
	}
	c.count -= 1
	if c.count > 1 {
		return
	}
	set := ni.set
	if c.count == 1 {
		rax.insert(ni.tree, name, name_inline(e[0]))
	} else {
		rax.remove(ni.tree, name)
		index_changed(ni)
	}
	last := set.multis[set.multi_len - 1]
	set.multis[c.index] = last
	last.index = c.index
	set.multi_len -= 1
	index_free(s, ni, c)
}

names_add :: proc(s: Vset, name: []u8, r: Ref) -> bool {
	ni := part_index(s, part_by_id(s, r.part))
	return index_add(s, &ni, name, r)
}

names_remove :: proc(s: Vset, name: []u8, r: Ref) {
	ni := part_index(s, part_by_id(s, r.part))
	index_remove(s, &ni, name, r)
}

resolve_scoped :: proc "contextless" (a: ^Access, s: Vset, own: []Ref, shared: []Ref) -> (in_own: bool, at: int) {
	if a.owner != SHARED {
		for r, i in own {
			if ref_label(s, r) == a.label {
				return true, i
			}
		}
	}
	for r, i in shared {
		if ref_label(s, r) == a.label {
			return false, i
		}
	}
	at = -1
	best_label: lbl.Id
	if a.owner != SHARED {
		for r, i in own {
			l := ref_label(s, r)
			if !sees(a, l) {
				continue
			}
			if at < 0 || resolution_compare(a, l, best_label) > 0 {
				at = i
				in_own = true
				best_label = l
			}
		}
	}
	for r, i in shared {
		l := ref_label(s, r)
		if !sees(a, l) {
			continue
		}
		if at < 0 || resolution_compare(a, l, best_label) > 0 {
			at = i
			in_own = false
			best_label = l
		}
	}
	return
}

resolve :: proc "contextless" (a: ^Access, s: Vset, copies: []Ref) -> int {
	_, at := resolve_scoped(a, s, nil, copies)
	return at
}

exact_copy :: proc "contextless" (a: ^Access, s: Vset, copies: []Ref) -> int {
	for r, i in copies {
		if ref_label(s, r) == a.label {
			return i
		}
	}
	return -1
}

labels_present :: proc(s: Vset, out: ^[dynamic]lbl.Id) {
	if s == nil {
		return
	}
	if s.lab == nil {
		if s.count > 0 {
			append(out, lbl.BOTTOM_ID)
		}
		return
	}
	for i in 0 ..< s.lab.sorted_len {
		append(out, s.lab.sorted[i].label)
	}
}

has_label :: proc "contextless" (s: Vset, l: lbl.Id) -> bool {
	return s != nil && part_at_label(s, l) != nil
}

label_card :: proc "contextless" (s: Vset, l: lbl.Id) -> int {
	if s == nil {
		return 0
	}
	p := part_at_label(s, l)
	return 0 if p == nil else p.count
}

label_memory :: proc "contextless" (s: Vset, l: lbl.Id) -> int {
	if s == nil {
		return 0
	}
	p := part_at_label(s, l)
	return 0 if p == nil else part_footprint(s, p)
}

has_visible :: proc "contextless" (s: Vset, a: ^Access) -> bool {
	if s == nil {
		return false
	}
	if s.lab == nil {
		return s.count > 0 && sees(a, lbl.BOTTOM_ID)
	}
	for i in 0 ..< s.lab.sorted_len {
		if sees(a, s.lab.sorted[i].label) {
			return true
		}
	}
	if a.owner != SHARED {
		if scope := owner_scope(s, a.owner); scope != nil {
			for i in 0 ..< scope.part_len {
				if sees(a, scope.parts[i].label) {
					return true
				}
			}
		}
	}
	return false
}

top_visible_scope :: proc "contextless" (s: Vset, a: ^Access) -> (top: Scope, ok: bool) {
	top = Scope{label = lbl.ID_NONE}
	if s == nil {
		return
	}
	if s.lab == nil {
		if s.count > 0 && ((a.owner == SHARED && a.label == lbl.BOTTOM_ID) || sees(a, lbl.BOTTOM_ID)) {
			return Scope{label = lbl.BOTTOM_ID}, true
		}
		return
	}
	if part_at_scope(s, a.label, a.owner) != nil {
		return Scope{label = a.label, owner = a.owner}, true
	}
	if a.owner != SHARED && part_at_label(s, a.label) != nil {
		return Scope{label = a.label}, true
	}
	for i in 0 ..< s.lab.sorted_len {
		x := Scope{label = s.lab.sorted[i].label}
		if sees(a, x.label) && (!ok || scope_order_less(a, x, top)) {
			top = x
			ok = true
		}
	}
	if a.owner != SHARED {
		if scope := owner_scope(s, a.owner); scope != nil {
			for i in 0 ..< scope.part_len {
				x := Scope{label = scope.parts[i].label, owner = a.owner}
				if sees(a, x.label) && (!ok || scope_order_less(a, x, top)) {
					top = x
					ok = true
				}
			}
		}
	}
	if !ok {
		top = Scope{label = lbl.ID_NONE}
	}
	return
}

top_visible_label :: proc "contextless" (s: Vset, a: ^Access) -> (l: lbl.Id, ok: bool) {
	top: Scope
	top, ok = top_visible_scope(s, a)
	return top.label, ok
}

remove_label :: proc(s: Vset, l: lbl.Id) -> (removed: int, ch: Change) {
	if s == nil {
		ch.emptied = true
		return
	}
	if s.lab == nil {
		if l != lbl.BOTTOM_ID || s.count == 0 {
			ch.emptied = s.count == 0
			return
		}
		removed = s.count
		m := s.core.graph.m
		q := s.core.arena.elem
		rax.destroy(s.names)
		s.names = rax.create()
		part_release_all(s, &s.core)
		s.core = {}
		part_init(&s.core, q, s.dim, m, 1, allocator_of(s))
		s.version += 1
		ch.found = true
		ch.label_gone = true
		ch.emptied = true
		return
	}
	p := part_at_label(s, l)
	if p == nil {
		ch.emptied = s.lab.total == 0
		return
	}
	removed = part_remove_all(s, p)
	ch.found = true
	ch.label_gone = true
	ch.emptied = s.lab.total == 0
	return
}

part_remove_all :: proc(s: Vset, p: ^Part_Head) -> int {
	ni := part_index(s, p)
	for i in 0 ..< p.count {
		slot := p.order[i]
		index_remove(s, &ni, part_element_name(p, slot), Ref{slot = slot, part = p.id})
	}
	removed := p.count
	s.lab.total -= removed
	part_retire(s, p)
	s.version += 1
	return removed
}

make_labelled :: proc(s: Vset) -> Error {
	if s == nil {
		return .Invalid_Parameter
	}
	if s.lab != nil {
		return .None
	}
	if s.count == 0 {
		return labelled_attach(s)
	}
	return convert(s)
}

shared_memory :: proc "contextless" (s: Vset) -> int {
	return shared_bytes(s)
}

shared_bytes :: proc "contextless" (s: Vset) -> int {
	if s == nil {
		return 0
	}
	n := s.ledger.bytes + rax.memory(s.names)
	if s.lab == nil {
		if s.count > 0 {
			n -= part_footprint(s, &s.core)
		}
		return n
	}
	for i in 0 ..< s.lab.sorted_len {
		n -= part_footprint(s, s.lab.sorted[i])
	}
	if s.lab.owners != nil {
		n -= index_bytes(s)
	}
	return n
}

params_match :: proc "contextless" (a: Vset, b: Vset) -> bool {
	return a.arena.elem == b.arena.elem && a.dim == b.dim && a.input_dim == b.input_dim && a.graph.m == b.graph.m
}

joinable :: proc "contextless" (s: Vset, req: ^Add_Request) -> bool {
	return check_add(s, req).err == .None
}

part_move :: proc(src: Vset, dst: Vset, p: ^Partition, id: u32) {
	sni := shared_index(src)
	dni := shared_index(dst)
	for i in 0 ..< p.count {
		slot := p.order[i]
		name := part_element_name(p, slot)
		index_remove(src, &sni, name, Ref{slot = slot, part = p.id})
		index_add(dst, &dni, name, Ref{slot = slot, part = id})
	}
	sorted_remove(src, p)
	src.lab.by_id[p.id] = nil
	src.lab.total -= p.count
	blk := (^Part_Block)(p)
	moved := usable_size(blk) + blk.charge.bytes
	src.ledger.bytes -= moved
	dst.ledger.bytes += moved
	blk.charge.root = &dst.ledger
	p.id = id
	dst.lab.by_id[id] = p
	if id == u32(dst.lab.id_high) {
		dst.lab.id_high += 1
	}
	sorted_insert(dst, p)
	dst.lab.total += p.count
	src.version += 1
	dst.version += 1
}

split_target :: proc(s: Vset) -> (out: Vset, err: Error) {
	params := params_of(s)
	params.seed = 1
	if out, err = create(params); err != .None {
		return nil, err
	}
	if labelled_attach(out) != .None {
		destroy(out)
		return nil, .Out_Of_Memory
	}
	return out, .None
}

split_label :: proc(s: Vset, l: lbl.Id) -> (out: Vset, ch: Change, err: Error) {
	if s == nil || s.lab == nil {
		return nil, ch, .Invalid_Parameter
	}
	p := part_at_label(s, l)
	if p == nil {
		return nil, ch, .Element_Not_Found
	}
	if out, err = split_target(s); err != .None {
		return nil, ch, err
	}
	if !ids_reserve(out, 1) || !sorted_reserve(out, 1) {
		destroy(out)
		return nil, ch, .Out_Of_Memory
	}
	part_move(s, out, p, 0)
	out.version = 0
	ch.found = true
	ch.label_gone = true
	ch.emptied = s.lab.total == 0
	return out, ch, .None
}

absorb :: proc(dst: Vset, src: Vset) -> Error {
	if dst == nil || src == nil || dst == src || !params_match(dst, src) {
		return .Invalid_Parameter
	}
	if src.lab == nil && src.count == 0 {
		return .None
	}
	if src.lab != nil {
		for i in 0 ..< src.lab.sorted_len {
			if part_at_label(dst, src.lab.sorted[i].label) != nil {
				return .Name_In_Use
			}
		}
		if src.lab.owners != nil && owners_clash(dst, src) {
			return .Name_In_Use
		}
	} else if part_at_label(dst, lbl.BOTTOM_ID) != nil {
		return .Name_In_Use
	}
	if convert(src) != .None {
		return .Out_Of_Memory
	}
	if dst.lab == nil {
		if dst.count > 0 {
			if convert(dst) != .None {
				return .Out_Of_Memory
			}
		} else if labelled_attach(dst) != .None {
			return .Out_Of_Memory
		}
	}
	need := u32(dst.lab.sorted_len) + u32(src.lab.sorted_len)
	if !sorted_reserve(dst, need) || !ids_reserve(dst, min(u32(dst.lab.id_high) + u32(src.lab.sorted_len), SHARED_PART_LIMIT)) {
		return .Out_Of_Memory
	}
	if src.lab.owners != nil {
		if err := owners_absorb(dst, src); err != .None {
			return err
		}
	}
	for src.lab.sorted_len > 0 {
		p := src.lab.sorted[src.lab.sorted_len - 1]
		part_move(src, dst, p, free_id(dst.lab))
	}
	return .None
}
