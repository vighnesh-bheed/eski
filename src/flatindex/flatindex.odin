package flatindex

import "base:runtime"
import "../roaring"
import "../vmath"

DEFAULT_BLOCK_SIZE :: 1024

DEFAULT_INITIAL_CAP :: 0

GROWTH_MIN :: 4

FIRST_CAP :: 1

NEW_BLOCK_MAX :: 1024

CHUNK :: 256

ID_NONE :: max(u32)

ALGORITHM :: "FLAT"

ID_BYTES :: size_of(u32)

AUX_BYTES :: size_of(f32)

Error :: enum u8 {
	None,
	Out_Of_Memory,
	Invalid_Spec,
	Blob_Size,
	Not_Found,
	Invalid_Id,
	Query_Mismatch,
	Negative_Radius,
	Invalid_Radius,
	Unsorted_Ids,
}

Spec :: struct {
	elem:        vmath.Elem,
	metric:      vmath.Metric,
	dim:         int,
	block_size:  int,
	initial_cap: int,
}

Hit :: struct {
	id:   u32,
	dist: f64,
}

Order :: enum u8 {
	Distance,
	Id,
}

Accept_Proc :: #type proc(ctx: rawptr, id: u32) -> bool

Filter :: struct {
	accept: Accept_Proc,
	ctx:    rawptr,
	ids:    []u32,
	set:    ^roaring.Bitmap,
	kind:   Set_Kind,
}

Set_Kind :: enum u8 {
	None,
	Ids,
	Bitmap,
}

Block :: struct {
	arena: vmath.Arena,
	ids:   []u32,
	dead:  []u64,
	used:  int,
	live:  int,
}

Index :: struct {
	spec:      Spec,
	proto:     vmath.Arena,
	blocks:    [dynamic]Block,
	firsts:    [dynamic]u32,
	allocator: runtime.Allocator,
	count:     int,
	dead:      int,
	block:     int,
	first_cap: int,
	stride:    int,
}

Info :: struct {
	elem:           vmath.Elem,
	metric:         vmath.Metric,
	dim:            int,
	block_size:     int,
	initial_cap:    int,
	count:          int,
	dead:           int,
	blocks:         int,
	capacity:       int,
	memory:         int,
	vector_bytes:   int,
	slot_bytes:     int,
	marked_deleted: int,
}

spec_default :: proc "contextless" (elem: vmath.Elem, metric: vmath.Metric, dim: int) -> Spec {
	return Spec{elem = elem, metric = metric, dim = dim, block_size = DEFAULT_BLOCK_SIZE, initial_cap = DEFAULT_INITIAL_CAP}
}

spec_check :: proc "contextless" (s: Spec) -> Error {
	if !vmath.family_supports(.Search, s.elem, s.metric) || !vmath.dim_valid(s.dim) || s.block_size < 1 || s.initial_cap < 0 {
		return .Invalid_Spec
	}
	return .None
}

vector_bytes :: proc "contextless" (s: Spec) -> int {
	return vmath.elem_vector_bytes(s.elem, s.dim)
}

slot_bytes :: proc "contextless" (s: Spec) -> int {
	return vector_bytes(s) + AUX_BYTES + ID_BYTES
}

block_size_valid :: proc "contextless" (v: i64) -> bool {
	return v >= 1
}

initial_cap_valid :: proc "contextless" (v: i64) -> bool {
	return v >= 0
}

type_name :: proc "contextless" (s: Spec) -> string {
	return vmath.search_type_name(s.elem)
}

metric_name :: proc "contextless" (s: Spec) -> string {
	return vmath.metric_name(s.metric)
}

init :: proc(ix: ^Index, spec: Spec, allocator := context.allocator) -> Error {
	spec_check(spec) or_return
	ix^ = {}
	if vmath.arena_init(&ix.proto, spec.elem, spec.metric, spec.dim, allocator, 0, .Search) != nil {
		return .Invalid_Spec
	}
	ix.spec = spec
	ix.allocator = allocator
	ix.block = min(spec.block_size, vmath.SLOT_LIMIT)
	ix.first_cap = clamp(spec.initial_cap if spec.initial_cap > 0 else FIRST_CAP, 1, ix.block)
	ix.stride = vector_bytes(spec)
	ix.blocks.allocator = allocator
	ix.firsts.allocator = allocator
	return .None
}

destroy :: proc(ix: ^Index) {
	for &blk in ix.blocks {
		block_free(ix, &blk)
	}
	delete(ix.blocks)
	delete(ix.firsts)
	ix^ = {}
}

reset :: proc(ix: ^Index) {
	for &blk in ix.blocks {
		block_free(ix, &blk)
	}
	runtime.clear(&ix.blocks)
	runtime.clear(&ix.firsts)
	ix.count = 0
	ix.dead = 0
}

count :: proc "contextless" (ix: ^Index) -> int {
	return ix.count
}

memory :: proc "contextless" (ix: ^Index) -> int {
	total := cap(ix.blocks) * size_of(Block) + cap(ix.firsts) * size_of(u32)
	for &blk in ix.blocks {
		total += vmath.arena_footprint(&blk.arena) + len(blk.ids) * size_of(u32) + len(blk.dead) * size_of(u64)
	}
	return total
}

capacity :: proc "contextless" (ix: ^Index) -> int {
	total := 0
	for &blk in ix.blocks {
		total += len(blk.ids)
	}
	return total
}

info :: proc "contextless" (ix: ^Index) -> Info {
	return Info {
		elem = ix.spec.elem,
		metric = ix.spec.metric,
		dim = ix.spec.dim,
		block_size = ix.spec.block_size,
		initial_cap = ix.spec.initial_cap,
		count = ix.count,
		dead = ix.dead,
		blocks = len(ix.blocks),
		capacity = capacity(ix),
		memory = memory(ix),
		vector_bytes = ix.stride,
		slot_bytes = slot_bytes(ix.spec),
		marked_deleted = 0,
	}
}

filter_accept :: proc "contextless" (accept: Accept_Proc, ctx: rawptr) -> Filter {
	return Filter{accept = accept, ctx = ctx}
}

filter_ids :: proc "contextless" (ids: []u32, accept: Accept_Proc = nil, ctx: rawptr = nil) -> Filter {
	return Filter{accept = accept, ctx = ctx, ids = ids, kind = .Ids}
}

filter_bitmap :: proc "contextless" (set: ^roaring.Bitmap, accept: Accept_Proc = nil, ctx: rawptr = nil) -> Filter {
	return Filter{accept = accept, ctx = ctx, set = set, kind = .Bitmap}
}
