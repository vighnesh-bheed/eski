package numindex

import "base:runtime"
import "core:math"
import "../roaring"

LEAF_MAX :: 256

Error :: enum u8 {
	None,
	Out_Of_Memory,
	Not_A_Number,
}

Entry :: struct {
	value: f64,
	doc:   u32,
}

Leaf :: struct {
	entries: [dynamic]Entry,
}

Index :: struct {
	leaves:    [dynamic]Leaf,
	firsts:    [dynamic]Entry,
	count:     int,
	allocator: runtime.Allocator,
}

Bound :: struct {
	value:     f64,
	exclusive: bool,
}

below :: proc "contextless" () -> Bound {
	return Bound{value = math.inf_f64(-1)}
}

above :: proc "contextless" () -> Bound {
	return Bound{value = math.inf_f64(1)}
}

inclusive :: proc "contextless" (v: f64) -> Bound {
	return Bound{value = v}
}

exclusive :: proc "contextless" (v: f64) -> Bound {
	return Bound{value = v, exclusive = true}
}

entry_less :: #force_inline proc "contextless" (a, b: Entry) -> bool {
	return a.value < b.value || (a.value == b.value && a.doc < b.doc)
}

init :: proc(ix: ^Index, allocator := context.allocator) {
	ix^ = Index{allocator = allocator}
	ix.leaves = make([dynamic]Leaf, 0, 0, allocator)
	ix.firsts = make([dynamic]Entry, 0, 0, allocator)
}

destroy :: proc(ix: ^Index) {
	for &l in ix.leaves {
		delete(l.entries)
	}
	delete(ix.leaves)
	delete(ix.firsts)
	ix^ = Index{}
}

count :: #force_inline proc "contextless" (ix: ^Index) -> int {
	return ix.count
}

canonical :: #force_inline proc "contextless" (v: f64) -> f64 {
	return 0 if v == 0 else v
}

leaf_for :: proc "contextless" (ix: ^Index, e: Entry) -> int #no_bounds_check {
	lo, hi := 0, len(ix.firsts)
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		if entry_less(e, ix.firsts[mid]) {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return max(lo - 1, 0)
}

entry_search :: proc "contextless" (entries: []Entry, e: Entry) -> (int, bool) #no_bounds_check {
	lo, hi := 0, len(entries)
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		if entry_less(entries[mid], e) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(entries) && entries[lo] == e
}

add :: proc(ix: ^Index, doc: u32, value: f64) -> (added: bool, err: Error) {
	if math.is_nan(value) {
		return false, .Not_A_Number
	}
	e := Entry{value = canonical(value), doc = doc}
	if len(ix.leaves) == 0 {
		entries, me := make([dynamic]Entry, 0, 8, ix.allocator)
		if me != nil {
			return false, .Out_Of_Memory
		}
		append(&entries, e)
		if _, ae := append(&ix.leaves, Leaf{entries = entries}); ae != nil {
			delete(entries)
			return false, .Out_Of_Memory
		}
		if _, ae := append(&ix.firsts, e); ae != nil {
			l := pop(&ix.leaves)
			delete(l.entries)
			return false, .Out_Of_Memory
		}
		ix.count = 1
		return true, .None
	}
	li := leaf_for(ix, e)
	leaf := &ix.leaves[li]
	at, found := entry_search(leaf.entries[:], e)
	if found {
		return false, .None
	}
	if _, ie := inject_at(&leaf.entries, at, e); ie != nil {
		return false, .Out_Of_Memory
	}
	if at == 0 {
		ix.firsts[li] = e
	}
	ix.count += 1
	if len(leaf.entries) > LEAF_MAX {
		split(ix, li) or_return
	}
	return true, .None
}

split :: proc(ix: ^Index, li: int) -> Error {
	leaf := &ix.leaves[li]
	half := len(leaf.entries) / 2
	upper, me := make([dynamic]Entry, len(leaf.entries) - half, LEAF_MAX + 1, ix.allocator)
	if me != nil {
		return .Out_Of_Memory
	}
	copy(upper[:], leaf.entries[half:])
	first := upper[0]
	if _, e := inject_at(&ix.leaves, li + 1, Leaf{entries = upper}); e != nil {
		delete(upper)
		return .Out_Of_Memory
	}
	if _, e := inject_at(&ix.firsts, li + 1, first); e != nil {
		l := ix.leaves[li + 1]
		ordered_remove(&ix.leaves, li + 1)
		delete(l.entries)
		return .Out_Of_Memory
	}
	resize(&ix.leaves[li].entries, half)
	return .None
}

remove :: proc(ix: ^Index, doc: u32, value: f64) -> bool {
	if len(ix.leaves) == 0 || math.is_nan(value) {
		return false
	}
	e := Entry{value = canonical(value), doc = doc}
	li := leaf_for(ix, e)
	leaf := &ix.leaves[li]
	at, found := entry_search(leaf.entries[:], e)
	if !found {
		return false
	}
	ordered_remove(&leaf.entries, at)
	ix.count -= 1
	drop_or_refresh(ix, li)
	return true
}

drop_or_refresh :: proc(ix: ^Index, li: int) {
	leaf := &ix.leaves[li]
	if len(leaf.entries) == 0 {
		delete(leaf.entries)
		ordered_remove(&ix.leaves, li)
		ordered_remove(&ix.firsts, li)
		return
	}
	ix.firsts[li] = leaf.entries[0]
}

above_low :: #force_inline proc "contextless" (v: f64, lo: Bound) -> bool {
	return v > lo.value || (!lo.exclusive && v == lo.value)
}

below_high :: #force_inline proc "contextless" (v: f64, hi: Bound) -> bool {
	return v < hi.value || (!hi.exclusive && v == hi.value)
}

Visit_Proc :: #type proc(ctx: rawptr, e: Entry) -> Error

visit :: proc(ix: ^Index, lo, hi: Bound, fn: Visit_Proc, ctx: rawptr) -> Error {
	if len(ix.leaves) == 0 || math.is_nan(lo.value) || math.is_nan(hi.value) {
		return .None
	}
	start := leaf_for(ix, Entry{value = lo.value, doc = 0})
	for li in start ..< len(ix.leaves) {
		entries := ix.leaves[li].entries[:]
		from := 0
		if li == start {
			from, _ = entry_search(entries, Entry{value = lo.value, doc = 0})
		}
		for i in from ..< len(entries) {
			v := entries[i].value
			if !below_high(v, hi) {
				return .None
			}
			if above_low(v, lo) {
				fn(ctx, entries[i]) or_return
			}
		}
	}
	return .None
}

range_bitmap :: proc(ix: ^Index, lo, hi: Bound, out: ^roaring.Bitmap) -> Error {
	add_doc :: proc(ctx: rawptr, e: Entry) -> Error {
		if _, err := roaring.add((^roaring.Bitmap)(ctx), e.doc); err != .None {
			return .Out_Of_Memory
		}
		return .None
	}
	return visit(ix, lo, hi, add_doc, out)
}

range_docs :: proc(ix: ^Index, lo, hi: Bound, out: ^[dynamic]u32) -> Error {
	start := len(out)
	push :: proc(ctx: rawptr, e: Entry) -> Error {
		if _, err := append((^[dynamic]u32)(ctx), e.doc); err != nil {
			return .Out_Of_Memory
		}
		return .None
	}
	visit(ix, lo, hi, push, out) or_return
	tail := out[start:]
	sort_docs(tail)
	n := 0
	for i in 0 ..< len(tail) {
		if i == 0 || tail[i] != tail[n - 1] {
			tail[n] = tail[i]
			n += 1
		}
	}
	resize(out, start + n)
	return .None
}

sort_docs :: proc "contextless" (a: []u32) {
	if len(a) < 2 {
		return
	}
	n := len(a)
	for start := n / 2 - 1; start >= 0; start -= 1 {
		sift(a, start, n)
	}
	for end := n - 1; end > 0; end -= 1 {
		a[0], a[end] = a[end], a[0]
		sift(a, 0, end)
	}
}

sift :: proc "contextless" (a: []u32, at, n: int) #no_bounds_check {
	k := at
	x := a[k]
	for {
		child := 2 * k + 1
		if child >= n {
			break
		}
		if child + 1 < n && a[child + 1] > a[child] {
			child += 1
		}
		if a[child] <= x {
			break
		}
		a[k] = a[child]
		k = child
	}
	a[k] = x
}

collect :: proc(ix: ^Index, deleted: ^roaring.Bitmap) -> int {
	if roaring.is_empty(deleted) {
		return 0
	}
	dropped := 0
	li := 0
	for li < len(ix.leaves) {
		leaf := &ix.leaves[li]
		n := 0
		for e in leaf.entries {
			if roaring.contains(deleted, e.doc) {
				continue
			}
			leaf.entries[n] = e
			n += 1
		}
		dropped += len(leaf.entries) - n
		resize(&leaf.entries, n)
		if n == 0 {
			delete(leaf.entries)
			ordered_remove(&ix.leaves, li)
			ordered_remove(&ix.firsts, li)
			continue
		}
		ix.firsts[li] = leaf.entries[0]
		li += 1
	}
	ix.count -= dropped
	return dropped
}
