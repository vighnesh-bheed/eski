package hnsw

import "base:intrinsics"
import "base:runtime"
import "core:math"

NONE :: max(u32)

LEVEL_FREE :: u8(0xFF)

LEVEL_RESERVED :: u8(0xFE)

LEVEL_TWIN :: u8(0xFD)

COINCIDENT_MAX :: 2

LEVEL_CAP :: 30

M_MIN :: 2

M_MAX :: 32767

M_DEFAULT :: 16

EF_CONSTRUCTION_DEFAULT :: 200

SEED_DEFAULT :: u64(0x5EED_0F_E5C1_0001)

PROMOTION_DEFAULT :: 0.25

SLOT_LIMIT :: int(max(u32)) - 1

GROWTH_MIN :: 16

CACHE_LINE :: 64

LINK_PAD :: 8

WIDTH_U16_SLOTS :: 65_535

WIDTH_U24_SLOTS :: 16_777_215

LINK_PREFETCH_BYTES :: 2 << 20

Distance_Proc :: #type proc(ctx: rawptr, a, b: u32) -> f32

Query_Proc :: #type proc(ctx: rawptr, slot: u32) -> f32

Accept_Proc :: #type proc(ctx: rawptr, slot: u32) -> bool

Prefetch_Proc :: #type proc(ctx: rawptr, slot: u32)

Batch_Query_Proc :: #type proc(qctx: rawptr, slots: []u32, out: []f32)

Level_Law :: enum u8 {
	Constant,
	Inverse_Log_M,
}

Error :: enum u8 {
	None,
	Out_Of_Memory,
	Invalid_Parameter,
	Not_Reserved,
	Not_Found,
	Slot_Limit,
}

Params :: struct {
	m:                 int,
	ef_construction:   int,
	seed:              u64,
	extend_candidates: bool,
	keep_pruned:       bool,
	level_law:         Level_Law,
	promotion:         f64,
	twins:             bool,
}

Index :: struct {
	distance:          Distance_Proc,
	ctx:               rawptr,
	prefetch:          Prefetch_Proc,
	prefetch_ctx:      rawptr,
	allocator:         runtime.Allocator,
	links0:            [^]u8,
	degree0:           [^]u16,
	levels:            [^]u8,
	upper_at:          [^]u32,
	upper:             [^]u8,
	upper_len:         int,
	upper_cap:         int,
	width:             int,
	row:               int,
	prefetch_links:    bool,
	upper_free:        [LEVEL_CAP + 1]u32,
	cap:               int,
	slots:             int,
	live:              int,
	free_head:         u32,
	entry:             u32,
	max_level:         int,
	m:                 int,
	m0:                int,
	ef_construction:   int,
	promotion:         f64,
	level_log:         f64,
	rng:               u64,
	node_uid:          u64,
	extend_candidates: bool,
	keep_pruned:       bool,
	twin_link:         [^]u32,
	twin_cap:          int,
	twins:             int,
	coincident:        int,
}

Info :: struct {
	m:               int,
	ef_construction: int,
	size:            int,
	max_level:       int,
	max_node_uid:    u64,
	entry:           u32,
	slots:           int,
	memory:          int,
	link_width:      int,
	twins:           int,
}

List :: struct {
	data:  [^]u8,
	count: int,
	cap:   int,
}

params_default :: proc "contextless" () -> Params {
	return Params {
		m = M_DEFAULT,
		ef_construction = EF_CONSTRUCTION_DEFAULT,
		seed = SEED_DEFAULT,
		extend_candidates = false,
		keep_pruned = true,
		level_law = .Constant,
		promotion = PROMOTION_DEFAULT,
		twins = true,
	}
}

init :: proc(ix: ^Index, params: Params, distance: Distance_Proc, ctx: rawptr, allocator: runtime.Allocator) -> Error {
	if params.m < M_MIN || params.m > M_MAX || params.ef_construction < 1 || distance == nil {
		return .Invalid_Parameter
	}
	promotion := 1 / f64(params.m)
	switch params.level_law {
	case .Constant:
		if !(params.promotion > 0 && params.promotion < 1) {
			return .Invalid_Parameter
		}
		promotion = params.promotion
	case .Inverse_Log_M:
	}
	ix^ = Index{}
	ix.distance = distance
	ix.ctx = ctx
	ix.allocator = allocator
	ix.m = params.m
	ix.m0 = 2 * params.m
	ix.ef_construction = params.ef_construction
	ix.promotion = promotion
	ix.level_log = math.ln(promotion)
	ix.rng = params.seed
	ix.extend_candidates = params.extend_candidates
	ix.keep_pruned = params.keep_pruned
	ix.coincident = params.twins ? clamp(params.m / 2, 1, COINCIDENT_MAX) : 0
	ix.free_head = NONE
	ix.entry = NONE
	ix.width = link_width(0)
	ix.row = ix.m0 * ix.width
	for i in 0 ..= LEVEL_CAP {
		ix.upper_free[i] = NONE
	}
	return .None
}

set_prefetch :: proc "contextless" (ix: ^Index, prefetch: Prefetch_Proc, ctx: rawptr) {
	ix.prefetch = prefetch
	ix.prefetch_ctx = ctx
}

destroy :: proc(ix: ^Index) {
	array_free(ix.links0, links_bytes(ix.cap, ix.row), ix.allocator)
	array_free(ix.degree0, ix.cap, ix.allocator)
	array_free(ix.levels, ix.cap, ix.allocator)
	array_free(ix.upper_at, ix.cap, ix.allocator)
	array_free(ix.twin_link, ix.twin_cap, ix.allocator)
	array_free(ix.upper, pool_bytes(ix.upper_cap, ix.width), ix.allocator)
	ix^ = Index{}
	ix.free_head = NONE
	ix.entry = NONE
}

link_width :: proc "contextless" (capacity: int) -> int {
	if capacity <= WIDTH_U16_SLOTS {
		return 2
	}
	if capacity <= WIDTH_U24_SLOTS {
		return 3
	}
	return 4
}

width_none :: #force_inline proc "contextless" (width: int) -> u32 {
	return u32(u64(1) << uint(8 * width) - 1)
}

links_bytes :: #force_inline proc "contextless" (capacity: int, row: int) -> int {
	return capacity * row + LINK_PAD
}

pool_bytes :: #force_inline proc "contextless" (words: int, width: int) -> int {
	return words * width + LINK_PAD
}

id_load :: #force_inline proc "contextless" (p: [^]u8, i: int, $W: int) -> u32 #no_bounds_check {
	when W == 2 {
		return u32(intrinsics.unaligned_load((^u16le)(&p[2 * i])))
	} else when W == 3 {
		return u32(intrinsics.unaligned_load((^u32le)(&p[3 * i]))) & 0xFF_FFFF
	} else {
		return u32(intrinsics.unaligned_load((^u32le)(&p[4 * i])))
	}
}

id_store :: #force_inline proc "contextless" (p: [^]u8, i: int, $W: int, v: u32) #no_bounds_check {
	when W == 2 {
		intrinsics.unaligned_store((^u16le)(&p[2 * i]), u16le(v))
	} else when W == 3 {
		p[3 * i] = u8(v)
		p[3 * i + 1] = u8(v >> 8)
		p[3 * i + 2] = u8(v >> 16)
	} else {
		intrinsics.unaligned_store((^u32le)(&p[4 * i]), u32le(v))
	}
}

word_get :: #force_inline proc "contextless" (p: [^]u8, i: int, width: int) -> u32 {
	switch width {
	case 2:
		return id_load(p, i, 2)
	case 3:
		return id_load(p, i, 3)
	}
	return id_load(p, i, 4)
}

word_set :: #force_inline proc "contextless" (p: [^]u8, i: int, width: int, v: u32) {
	switch width {
	case 2:
		id_store(p, i, 2, v)
	case 3:
		id_store(p, i, 3, v)
	case:
		id_store(p, i, 4, v)
	}
}

raw_get :: #force_inline proc "contextless" (p: [^]u8) -> u32 {
	return u32(intrinsics.unaligned_load((^u32le)(p)))
}

raw_set :: #force_inline proc "contextless" (p: [^]u8, v: u32) {
	intrinsics.unaligned_store((^u32le)(p), u32le(v))
}

widen :: proc "contextless" (dst: [^]u8, src: [^]u8, words: int, from, to: int) #no_bounds_check {
	none_from := width_none(from)
	none_to := width_none(to)
	for i in 0 ..< words {
		v := word_get(src, i, from)
		word_set(dst, i, to, v == none_from ? none_to : v)
	}
}

array_resize :: proc(p: ^[^]$T, old_n, new_n: int, allocator: runtime.Allocator, alignment := align_of(T)) -> bool {
	data, err := runtime.non_zero_mem_resize(p^, old_n * size_of(T), new_n * size_of(T), alignment, allocator)
	if err != nil {
		return false
	}
	p^ = cast([^]T)raw_data(data)
	return true
}

array_free :: proc(p: [^]$T, n: int, allocator: runtime.Allocator) {
	if p != nil {
		runtime.mem_free_with_size(p, n * size_of(T), allocator)
	}
}

reserve_capacity :: proc(ix: ^Index, n: int) -> Error {
	if n <= ix.cap {
		return .None
	}
	if n > SLOT_LIMIT {
		return .Slot_Limit
	}
	if !twin_grow(ix, n) {
		return .Out_Of_Memory
	}
	old := ix.cap
	width := max(ix.width, link_width(n))
	if width != ix.width {
		return reencode(ix, n, width)
	}
	if !array_resize(&ix.links0, links_bytes(old, ix.row), links_bytes(n, ix.row), ix.allocator, CACHE_LINE) {
		return .Out_Of_Memory
	}
	if !array_resize(&ix.degree0, old, n, ix.allocator) {
		array_resize(&ix.links0, links_bytes(n, ix.row), links_bytes(old, ix.row), ix.allocator, CACHE_LINE)
		return .Out_Of_Memory
	}
	if !array_resize(&ix.levels, old, n, ix.allocator) {
		array_resize(&ix.links0, links_bytes(n, ix.row), links_bytes(old, ix.row), ix.allocator, CACHE_LINE)
		array_resize(&ix.degree0, n, old, ix.allocator)
		return .Out_Of_Memory
	}
	if !array_resize(&ix.upper_at, old, n, ix.allocator) {
		array_resize(&ix.links0, links_bytes(n, ix.row), links_bytes(old, ix.row), ix.allocator, CACHE_LINE)
		array_resize(&ix.degree0, n, old, ix.allocator)
		array_resize(&ix.levels, n, old, ix.allocator)
		return .Out_Of_Memory
	}
	ix.cap = n
	ix.prefetch_links = links_bytes(n, ix.row) >= LINK_PREFETCH_BYTES
	return .None
}

reencode :: proc(ix: ^Index, n: int, width: int) -> Error {
	if !twin_grow(ix, n) {
		return .Out_Of_Memory
	}
	old := ix.cap
	row := ix.m0 * width
	links: [^]u8
	if !array_resize(&links, 0, links_bytes(n, row), ix.allocator, CACHE_LINE) {
		return .Out_Of_Memory
	}
	pool: [^]u8
	if ix.upper_cap > 0 && !array_resize(&pool, 0, pool_bytes(ix.upper_cap, width), ix.allocator) {
		array_free(links, links_bytes(n, row), ix.allocator)
		return .Out_Of_Memory
	}
	if !array_resize(&ix.degree0, old, n, ix.allocator) {
		array_free(links, links_bytes(n, row), ix.allocator)
		array_free(pool, pool_bytes(ix.upper_cap, width), ix.allocator)
		return .Out_Of_Memory
	}
	if !array_resize(&ix.levels, old, n, ix.allocator) {
		array_free(links, links_bytes(n, row), ix.allocator)
		array_free(pool, pool_bytes(ix.upper_cap, width), ix.allocator)
		array_resize(&ix.degree0, n, old, ix.allocator)
		return .Out_Of_Memory
	}
	if !array_resize(&ix.upper_at, old, n, ix.allocator) {
		array_free(links, links_bytes(n, row), ix.allocator)
		array_free(pool, pool_bytes(ix.upper_cap, width), ix.allocator)
		array_resize(&ix.degree0, n, old, ix.allocator)
		array_resize(&ix.levels, n, old, ix.allocator)
		return .Out_Of_Memory
	}
	if ix.slots > 0 {
		widen(links, ix.links0, ix.slots * ix.m0, ix.width, width)
	}
	if ix.upper_len > 0 {
		widen(pool, ix.upper, ix.upper_len, ix.width, width)
	}
	for level in 1 ..= LEVEL_CAP {
		for at := ix.upper_free[level]; at != NONE; {
			next := raw_get(ix.upper[int(at) * ix.width:])
			raw_set(pool[int(at) * width:], next)
			at = next
		}
	}
	array_free(ix.links0, links_bytes(old, ix.row), ix.allocator)
	array_free(ix.upper, pool_bytes(ix.upper_cap, ix.width), ix.allocator)
	ix.links0 = links
	ix.upper = pool
	ix.width = width
	ix.row = row
	ix.cap = n
	ix.prefetch_links = links_bytes(n, row) >= LINK_PREFETCH_BYTES
	return .None
}

reserve :: proc(ix: ^Index) -> (slot: u32, err: Error) {
	if ix.free_head != NONE {
		slot = ix.free_head
		next := word_get(ix.links0[int(slot) * ix.row:], 0, ix.width)
		ix.free_head = next == width_none(ix.width) ? NONE : next
		ix.levels[slot] = LEVEL_RESERVED
		return slot, .None
	}
	if ix.slots == ix.cap {
		if ix.cap >= SLOT_LIMIT {
			return NONE, .Slot_Limit
		}
		grown := min(max(GROWTH_MIN, ix.cap + ix.cap / 2), SLOT_LIMIT)
		if e := reserve_capacity(ix, grown); e != .None {
			return NONE, e
		}
	}
	slot = u32(ix.slots)
	ix.slots += 1
	ix.levels[slot] = LEVEL_RESERVED
	ix.degree0[slot] = 0
	ix.upper_at[slot] = NONE
	return slot, .None
}

release :: proc "contextless" (ix: ^Index, slot: u32) -> Error {
	if int(slot) >= ix.slots || ix.levels[slot] != LEVEL_RESERVED {
		return .Not_Reserved
	}
	slot_push_free(ix, slot)
	return .None
}

slot_push_free :: proc "contextless" (ix: ^Index, slot: u32) {
	ix.levels[slot] = LEVEL_FREE
	ix.degree0[slot] = 0
	ix.upper_at[slot] = NONE
	if ix.twin_link != nil {
		ix.twin_link[slot] = NONE
	}
	word_set(ix.links0[int(slot) * ix.row:], 0, ix.width, ix.free_head == NONE ? width_none(ix.width) : ix.free_head)
	ix.free_head = slot
}

upper_words :: #force_inline proc "contextless" (ix: ^Index, level: int) -> int {
	return level * (ix.m + 1)
}

upper_alloc :: proc(ix: ^Index, level: int) -> (offset: u32, err: Error) {
	words := upper_words(ix, level)
	if ix.upper_free[level] != NONE {
		offset = ix.upper_free[level]
		ix.upper_free[level] = raw_get(ix.upper[int(offset) * ix.width:])
	} else {
		if ix.upper_len + words >= int(max(u32)) {
			return NONE, .Slot_Limit
		}
		if ix.upper_len + words > ix.upper_cap {
			grown := min(max(ix.upper_len + words, ix.upper_cap + ix.upper_cap / 2, 256), int(max(u32)) - 1)
			if !array_resize(&ix.upper, ix.upper_cap > 0 ? pool_bytes(ix.upper_cap, ix.width) : 0, pool_bytes(grown, ix.width), ix.allocator) {
				return NONE, .Out_Of_Memory
			}
			ix.upper_cap = grown
		}
		offset = u32(ix.upper_len)
		ix.upper_len += words
	}
	for l in 0 ..< level {
		word_set(ix.upper[(int(offset) + l * (ix.m + 1)) * ix.width:], 0, ix.width, 0)
	}
	return offset, .None
}

upper_release :: proc "contextless" (ix: ^Index, offset: u32, level: int) {
	raw_set(ix.upper[int(offset) * ix.width:], ix.upper_free[level])
	ix.upper_free[level] = offset
}

is_live :: #force_inline proc "contextless" (ix: ^Index, slot: u32) -> bool {
	return int(slot) < ix.slots && ix.levels[slot] < LEVEL_RESERVED
}

is_node :: #force_inline proc "contextless" (ix: ^Index, slot: u32) -> bool {
	return int(slot) < ix.slots && ix.levels[slot] <= LEVEL_CAP
}

is_twin :: #force_inline proc "contextless" (ix: ^Index, slot: u32) -> bool {
	return int(slot) < ix.slots && ix.levels[slot] == LEVEL_TWIN
}

node_level :: proc "contextless" (ix: ^Index, slot: u32) -> int {
	if !is_live(ix, slot) {
		return -1
	}
	if ix.levels[slot] == LEVEL_TWIN {
		return 0
	}
	return int(ix.levels[slot])
}

layer_cap :: #force_inline proc "contextless" (ix: ^Index, layer: int) -> int {
	return layer == 0 ? ix.m0 : ix.m
}

list_get :: #force_inline proc "contextless" (ix: ^Index, slot: u32, layer: int) -> List #no_bounds_check {
	if layer == 0 {
		return List{data = ix.links0[int(slot) * ix.row:], count = int(ix.degree0[slot]), cap = ix.m0}
	}
	at := (int(ix.upper_at[slot]) + (layer - 1) * (ix.m + 1)) * ix.width
	return List{data = ix.upper[at + ix.width:], count = int(word_get(ix.upper[at:], 0, ix.width)), cap = ix.m}
}

prefetch_span :: #force_inline proc "contextless" (p: [^]u8, bytes: int) #no_bounds_check {
	for off := 0; off < bytes; off += CACHE_LINE {
		intrinsics.prefetch_read_data(&p[off], 3)
	}
	intrinsics.prefetch_read_data(&p[bytes - 1], 3)
}

links_prefetch :: #force_inline proc "contextless" (ix: ^Index, slot: u32, layer: int) #no_bounds_check {
	if !ix.prefetch_links {
		return
	}
	if layer == 0 {
		prefetch_span(ix.links0[int(slot) * ix.row:], ix.row)
		intrinsics.prefetch_read_data(&ix.degree0[slot], 3)
	} else {
		prefetch_span(ix.upper[(int(ix.upper_at[slot]) + (layer - 1) * (ix.m + 1)) * ix.width:], (ix.m + 1) * ix.width)
	}
}

list_set_count :: #force_inline proc "contextless" (ix: ^Index, slot: u32, layer: int, count: int) #no_bounds_check {
	if layer == 0 {
		ix.degree0[slot] = u16(count)
	} else {
		word_set(ix.upper[(int(ix.upper_at[slot]) + (layer - 1) * (ix.m + 1)) * ix.width:], 0, ix.width, u32(count))
	}
}

list_id :: #force_inline proc "contextless" (ix: ^Index, l: List, i: int) -> u32 {
	return word_get(l.data, i, ix.width)
}

list_put :: #force_inline proc "contextless" (ix: ^Index, l: List, i: int, id: u32) {
	word_set(l.data, i, ix.width, id)
}

list_count :: #force_inline proc "contextless" (ix: ^Index, slot: u32, layer: int) -> int {
	return list_get(ix, slot, layer).count
}

decode_width :: #force_inline proc "contextless" (l: List, out: [^]u32, $W: int) #no_bounds_check {
	for i in 0 ..< l.count {
		out[i] = id_load(l.data, i, W)
	}
}

list_decode :: proc "contextless" (ix: ^Index, l: List, out: [^]u32) -> []u32 {
	switch ix.width {
	case 2:
		decode_width(l, out, 2)
	case 3:
		decode_width(l, out, 3)
	case:
		decode_width(l, out, 4)
	}
	return out[:l.count]
}

list_contains :: proc "contextless" (ix: ^Index, slot: u32, layer: int, id: u32) -> bool {
	l := list_get(ix, slot, layer)
	for i in 0 ..< l.count {
		if list_id(ix, l, i) == id {
			return true
		}
	}
	return false
}

list_append :: proc "contextless" (ix: ^Index, slot: u32, layer: int, id: u32) -> bool {
	l := list_get(ix, slot, layer)
	if l.count >= l.cap {
		return false
	}
	list_put(ix, l, l.count, id)
	list_set_count(ix, slot, layer, l.count + 1)
	return true
}

list_remove :: proc "contextless" (ix: ^Index, slot: u32, layer: int, id: u32) -> bool {
	l := list_get(ix, slot, layer)
	for i in 0 ..< l.count {
		if list_id(ix, l, i) == id {
			list_put(ix, l, i, list_id(ix, l, l.count - 1))
			list_set_count(ix, slot, layer, l.count - 1)
			return true
		}
	}
	return false
}

list_replace :: proc "contextless" (ix: ^Index, slot: u32, layer: int, old_id, new_id: u32) -> bool {
	l := list_get(ix, slot, layer)
	for i in 0 ..< l.count {
		if list_id(ix, l, i) == old_id {
			list_put(ix, l, i, new_id)
			return true
		}
	}
	return false
}

layer_links :: proc "contextless" (ix: ^Index, slot: u32, layer: int, buf: []u32) -> []u32 {
	if is_twin(ix, slot) && layer == 0 {
		return buf[:0]
	}
	if !is_node(ix, slot) || layer < 0 || layer > int(ix.levels[slot]) {
		return nil
	}
	l := list_get(ix, slot, layer)
	if len(buf) < l.count {
		return nil
	}
	return list_decode(ix, l, raw_data(buf))
}

node_layers :: proc "contextless" (ix: ^Index, slot: u32) -> int {
	return node_level(ix, slot) + 1
}

links_top_first :: proc "contextless" (ix: ^Index, slot: u32, i: int, buf: []u32) -> []u32 {
	level := node_level(ix, slot)
	if level < 0 || i < 0 || i > level {
		return nil
	}
	return layer_links(ix, slot, level - i, buf)
}

node_fixed_bytes :: proc "contextless" (m: int, width: int) -> int {
	return 2 * m * width + size_of(u16) + size_of(u8) + size_of(u32)
}

node_expected_upper_bytes :: proc "contextless" (m: int, promotion: f64, width: int) -> f64 {
	return f64((m + 1) * width) * promotion / (1 - promotion)
}

node_expected_bytes :: proc "contextless" (m: int, promotion: f64, width: int) -> f64 {
	return f64(node_fixed_bytes(m, width)) + node_expected_upper_bytes(m, promotion, width)
}

memory :: proc "contextless" (ix: ^Index) -> int {
	n := size_of(Index) + ix.cap * node_fixed_bytes(ix.m, ix.width)
	if ix.cap > 0 {
		n += LINK_PAD
	}
	if ix.upper_cap > 0 {
		n += pool_bytes(ix.upper_cap, ix.width)
	}
	return n + ix.twin_cap * size_of(u32)
}

used_bytes :: proc "contextless" (ix: ^Index) -> int {
	n := ix.slots * node_fixed_bytes(ix.m, ix.width) + ix.upper_len * ix.width
	if ix.twin_link != nil {
		n += ix.slots * size_of(u32)
	}
	return n
}

size :: proc "contextless" (ix: ^Index) -> int {
	return ix.live
}

slot_count :: proc "contextless" (ix: ^Index) -> int {
	return ix.slots
}

info :: proc "contextless" (ix: ^Index) -> Info {
	return Info {
		m = ix.m,
		ef_construction = ix.ef_construction,
		size = ix.live,
		max_level = ix.max_level,
		max_node_uid = ix.node_uid,
		entry = ix.entry,
		slots = ix.slots,
		memory = memory(ix),
		link_width = ix.width,
		twins = ix.twins,
	}
}
