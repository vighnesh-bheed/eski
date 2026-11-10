package vsettype

import "base:intrinsics"
import "../hnsw"
import lbl "../label"
import "../rax"
import "../vmath"

NAME_MULTI :: u64(1) << 63
PART_NONE :: max(u32)
PART_FIXED_BYTES :: size_of(Part_Block)
VIEW_BASE_BYTES :: size_of(Vset_Object) + size_of(Labelled)
NAME_INDEX_BYTES :: 24

Access :: struct {
	label:      lbl.Id,
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

Labelled :: struct {
	sorted:     [^]^Partition,
	by_id:      [^]^Partition,
	multis:     [^]^Copies,
	sorted_len: u32,
	sorted_cap: u32,
	id_cap:     u32,
	id_high:    u32,
	multi_len:  u32,
	multi_cap:  u32,
	total:      int,
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
	when intrinsics.type_has_field(lbl.Label, "trust") {
		return lbl.resolution_compare(lx, ly)
	} else {
		if lx.level != ly.level {
			return 1 if lx.level > ly.level else -1
		}
		cx := lbl.compartment_count(lx)
		cy := lbl.compartment_count(ly)
		if cx != cy {
			return 1 if cx > cy else -1
		}
		return 0
	}
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

sees :: #force_inline proc "contextless" (a: ^Access, l: lbl.Id) -> bool {
	return a.visibility != nil && lbl.visible(a.visibility, l)
}

access_stream :: proc(a: ^Access) -> ^u64 {
	if a.stream != nil {
		return a.stream
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

names_lookup :: proc "contextless" (s: Vset, name: []u8, one: ^Ref) -> []Ref {
	v, found := rax.find(s.names, name)
	if !found {
		return nil
	}
	return name_decode(v, one)
}

labelled :: #force_inline proc "contextless" (s: Vset) -> bool {
	return s != nil && s.lab != nil
}

part_by_id :: #force_inline proc "contextless" (s: Vset, id: u32) -> ^Partition {
	if s.lab == nil {
		return &s.core if id == 0 else nil
	}
	if id >= s.lab.id_high {
		return nil
	}
	return s.lab.by_id[id]
}

ref_part :: #force_inline proc "contextless" (s: Vset, r: Ref) -> ^Partition {
	return part_by_id(s, r.part)
}

ref_label :: #force_inline proc "contextless" (s: Vset, r: Ref) -> lbl.Id {
	return part_by_id(s, r.part).label
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

lab_grow :: proc "contextless" (s: Vset, p: rawptr, cap: u32, elem: int, need: u32) -> (q: rawptr, fresh: u32, ok: bool) {
	if need <= cap {
		return p, cap, true
	}
	n := max(need, cap * 2, 4)
	q = block_resize(&s.ledger, p, int(cap) * elem, int(n) * elem, 8, false)
	if q == nil {
		return p, cap, false
	}
	return q, n, true
}

sorted_reserve :: proc "contextless" (s: Vset, need: u32) -> bool {
	lab := s.lab
	q, cap, ok := lab_grow(s, lab.sorted, lab.sorted_cap, size_of(^Partition), need)
	lab.sorted = ([^]^Partition)(q)
	lab.sorted_cap = cap
	return ok
}

ids_reserve :: proc "contextless" (s: Vset, need: u32) -> bool {
	lab := s.lab
	q, cap, ok := lab_grow(s, lab.by_id, lab.id_cap, size_of(^Partition), need)
	lab.by_id = ([^]^Partition)(q)
	lab.id_cap = cap
	return ok
}

multis_reserve :: proc "contextless" (s: Vset, need: u32) -> bool {
	lab := s.lab
	q, cap, ok := lab_grow(s, lab.multis, lab.multi_cap, size_of(^Copies), need)
	lab.multis = ([^]^Copies)(q)
	lab.multi_cap = cap
	return ok
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

free_id :: proc "contextless" (lab: ^Labelled) -> u32 {
	for i in 0 ..< lab.id_high {
		if lab.by_id[i] == nil {
			return i
		}
	}
	return lab.id_high
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

part_rebind :: proc(p: ^Partition, c: ^Charge) {
	alloc := charge_allocator(c)
	p.arena.allocator = alloc
	p.graph.allocator = alloc
	p.graph.ctx = p
	if p.prefetch {
		hnsw.set_prefetch(&p.graph, vmath.arena_prefetch_hook, &p.arena)
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
	q := s.core.quant
	blk.part = s.core
	blk.charge = Charge{bytes = part_block_bytes(&s.core), root = &s.ledger}
	part_rebind(&blk.part, &blk.charge)
	blk.id = 0
	blk.label = lbl.BOTTOM_ID
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

part_create :: proc(s: Vset, l: lbl.Id, seed: u64) -> (p: ^Partition, err: Error) {
	lab := s.lab
	id := free_id(lab)
	if !ids_reserve(s, id + 1) || !sorted_reserve(s, lab.sorted_len + 1) {
		return nil, .Out_Of_Memory
	}
	blk := (^Part_Block)(block_alloc(&s.ledger, size_of(Part_Block), align_of(Part_Block), true))
	if blk == nil {
		return nil, .Out_Of_Memory
	}
	blk.charge.root = &s.ledger
	if err = part_init(&blk.part, s.quant, s.dim, s.graph.m, seed, charge_allocator(&blk.charge)); err != .None {
		block_free(&s.ledger, blk)
		return nil, err
	}
	blk.id = id
	blk.label = l
	blk.mode = .Flat
	lab.by_id[id] = &blk.part
	if id == lab.id_high {
		lab.id_high += 1
	}
	sorted_insert(s, &blk.part)
	return &blk.part, .None
}

part_retire :: proc(s: Vset, p: ^Partition) {
	if s.lab == nil || p == &s.core {
		return
	}
	sorted_remove(s, p)
	s.lab.by_id[p.id] = nil
	part_release_all(s, p)
	block_free(&s.ledger, p)
}

part_for_write :: proc(s: Vset, a: ^Access) -> (p: ^Partition, created: bool, err: Error) {
	if s.lab == nil {
		if a.label == lbl.BOTTOM_ID && s.count > 0 {
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
	if p = part_at_label(s, a.label); p != nil {
		return p, false, .None
	}
	p, err = part_create(s, a.label, draw_seed(a))
	return p, err == .None, err
}

part_footprint :: proc "contextless" (s: Vset, p: ^Partition) -> int {
	if p == &s.core {
		return PART_FIXED_BYTES + s.ledger.bytes - usable_size(s)
	}
	return PART_FIXED_BYTES + (^Part_Block)(p).charge.bytes
}

labelled_destroy :: proc(s: Vset) {
	lab := s.lab
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
	return n
}

copies_alloc :: proc "contextless" (s: Vset, cap: u32) -> ^Copies {
	c := (^Copies)(block_alloc(&s.ledger, copies_bytes(cap), 8, false))
	if c != nil {
		c^ = Copies{cap = cap}
	}
	return c
}

names_add :: proc(s: Vset, name: []u8, r: Ref) -> bool {
	v, found := rax.find(s.names, name)
	if !found {
		rax.insert(s.names, name, name_inline(r))
		return true
	}
	x := u64(uintptr(v))
	if x & NAME_MULTI == 0 {
		if s.lab == nil {
			return false
		}
		one: Ref
		old := name_decode(v, &one)[0]
		if !multis_reserve(s, s.lab.multi_len + 1) {
			return false
		}
		c := copies_alloc(s, 2)
		if c == nil {
			return false
		}
		e := copies_entries(c)
		e[0] = old
		e[1] = r
		c.count = 2
		c.index = s.lab.multi_len
		s.lab.multis[c.index] = c
		s.lab.multi_len += 1
		rax.insert(s.names, name, name_multi(c))
		return true
	}
	c := (^Copies)(uintptr(x &~ NAME_MULTI))
	if c.count == c.cap {
		grown := (^Copies)(block_resize(&s.ledger, c, copies_bytes(c.cap), copies_bytes(c.cap * 2), 8, false))
		if grown == nil {
			return false
		}
		grown.cap *= 2
		if grown != c {
			s.lab.multis[grown.index] = grown
			rax.insert(s.names, name, name_multi(grown))
			c = grown
		}
	}
	copies_entries(c)[c.count] = r
	c.count += 1
	return true
}

names_remove :: proc(s: Vset, name: []u8, r: Ref) {
	v, found := rax.find(s.names, name)
	if !found {
		return
	}
	x := u64(uintptr(v))
	if x & NAME_MULTI == 0 {
		rax.remove(s.names, name)
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
	lab := s.lab
	if c.count == 1 {
		rax.insert(s.names, name, name_inline(e[0]))
	} else {
		rax.remove(s.names, name)
	}
	last := lab.multis[lab.multi_len - 1]
	lab.multis[c.index] = last
	last.index = c.index
	lab.multi_len -= 1
	block_free(&s.ledger, c)
}

resolve :: proc "contextless" (a: ^Access, s: Vset, copies: []Ref) -> int {
	best := -1
	best_label: lbl.Id
	for r, i in copies {
		l := ref_label(s, r)
		if l == a.label {
			return i
		}
		if !sees(a, l) {
			continue
		}
		if best < 0 || resolution_compare(a, l, best_label) > 0 {
			best = i
			best_label = l
		}
	}
	return best
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
	return false
}

top_visible_label :: proc "contextless" (s: Vset, a: ^Access) -> (l: lbl.Id, ok: bool) {
	if s == nil {
		return lbl.ID_NONE, false
	}
	if s.lab == nil {
		if s.count > 0 && (a.label == lbl.BOTTOM_ID || sees(a, lbl.BOTTOM_ID)) {
			return lbl.BOTTOM_ID, true
		}
		return lbl.ID_NONE, false
	}
	if part_at_label(s, a.label) != nil {
		return a.label, true
	}
	for i in 0 ..< s.lab.sorted_len {
		x := s.lab.sorted[i].label
		if sees(a, x) && (!ok || label_order_less(a, x, l)) {
			l = x
			ok = true
		}
	}
	if !ok {
		l = lbl.ID_NONE
	}
	return
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
		q := s.core.quant
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
	for i in 0 ..< p.count {
		slot := p.order[i]
		names_remove(s, part_element_name(p, slot), Ref{slot = slot, part = p.id})
	}
	removed = p.count
	s.lab.total -= removed
	part_retire(s, p)
	s.version += 1
	ch.found = true
	ch.label_gone = true
	ch.emptied = s.lab.total == 0
	return
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
	if s == nil {
		return 0
	}
	n := memory_usage(s)
	if s.lab == nil {
		if s.count > 0 {
			n -= part_footprint(s, &s.core)
		}
		return n
	}
	for i in 0 ..< s.lab.sorted_len {
		n -= part_footprint(s, s.lab.sorted[i])
	}
	return n
}

params_match :: proc "contextless" (a: Vset, b: Vset) -> bool {
	return a.quant == b.quant && a.dim == b.dim && a.input_dim == b.input_dim && a.graph.m == b.graph.m
}

joinable :: proc "contextless" (s: Vset, req: ^Add_Request) -> bool {
	return check_add(s, req).err == .None
}

part_move :: proc(src: Vset, dst: Vset, p: ^Partition, id: u32) {
	for i in 0 ..< p.count {
		slot := p.order[i]
		name := part_element_name(p, slot)
		names_remove(src, name, Ref{slot = slot, part = p.id})
		names_add(dst, name, Ref{slot = slot, part = id})
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
	if id == dst.lab.id_high {
		dst.lab.id_high += 1
	}
	sorted_insert(dst, p)
	dst.lab.total += p.count
	src.version += 1
	dst.version += 1
}

split_label :: proc(s: Vset, l: lbl.Id) -> (out: Vset, ch: Change, err: Error) {
	if s == nil || s.lab == nil {
		return nil, ch, .Invalid_Parameter
	}
	p := part_at_label(s, l)
	if p == nil {
		return nil, ch, .Element_Not_Found
	}
	params := params_of(s)
	params.seed = 1
	if out, err = create(params); err != .None {
		return nil, ch, err
	}
	if labelled_attach(out) != .None || !ids_reserve(out, 1) || !sorted_reserve(out, 1) {
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
	need := dst.lab.sorted_len + src.lab.sorted_len
	if !sorted_reserve(dst, need) || !ids_reserve(dst, dst.lab.id_high + src.lab.sorted_len) {
		return .Out_Of_Memory
	}
	for src.lab.sorted_len > 0 {
		p := src.lab.sorted[src.lab.sorted_len - 1]
		part_move(src, dst, p, free_id(dst.lab))
	}
	return .None
}
