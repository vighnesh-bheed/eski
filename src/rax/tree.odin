package rax

import "base:intrinsics"
import "base:runtime"

Rax :: struct {
	stored:   u64,
	nodes:    u64,
	root:     ^Node,
	shared:   ^int,
	mem:      int,
	finger:   uintptr,
	version:  u32,
	stamp:    u32,
}

Free_Callback :: #type proc "contextless" (data: rawptr)

@(private)
SHRINK_FLOOR :: 256
@(private)
EDGE_LEFT :: uintptr(1)
@(private)
EDGE_RIGHT :: uintptr(2)
@(private)
EDGE_BITS :: uintptr(3)
@(private)
MISS_SHIFT :: 2
@(private)
MISS_BITS :: uintptr(12)
@(private)
MISS_LIMIT :: uintptr(3)
@(private)
FINGER_TAG :: uintptr(15)

@(private)
edges_of :: #force_inline proc "contextless" (leftmost: bool, rightmost: bool) -> uintptr {
	e: uintptr = 0
	if leftmost {
		e |= EDGE_LEFT
	}
	if rightmost {
		e |= EDGE_RIGHT
	}
	return e
}

@(private)
finger_leaf :: #force_inline proc "contextless" (r: ^Rax) -> (^Node, uintptr, uintptr) {
	if r.finger == 0 || r.stamp != r.version {
		return nil, 0, 0
	}
	return cast(^Node)(r.finger &~ FINGER_TAG), r.finger & EDGE_BITS, (r.finger & MISS_BITS) >> MISS_SHIFT
}

@(private)
finger_note :: #force_inline proc "contextless" (r: ^Rax, n: ^Node, edges: uintptr, misses: uintptr) {
	f := uintptr(n) | edges | (misses << MISS_SHIFT)
	if r.finger != f || r.stamp != r.version {
		r.finger = f
		r.stamp = r.version
	}
}

@(private)
finger_hit :: #force_inline proc "contextless" (r: ^Rax) {
	if r.finger & MISS_BITS != 0 {
		r.finger &~= MISS_BITS
	}
}

@(private)
finger_settle :: #force_inline proc "contextless" (r: ^Rax, prev: ^Node, misses: uintptr) {
	if r.finger == 0 {
		return
	}
	m := misses
	if cast(^Node)(r.finger &~ FINGER_TAG) == prev {
		m = 0
	}
	r.finger = (r.finger &~ MISS_BITS) | (m << MISS_SHIFT)
	r.stamp = r.version
}

@(private)
finger_search :: proc "contextless" (f: ^Node, edges: uintptr, s: [^]u8, sl: int, sroom: int) -> (int, bool, bool) {
	idx, exact := node_lookup(f, s, sl, sroom, false, false)
	if exact {
		return idx, true, true
	}
	count := int(f.count)
	if idx > 0 && idx < count {
		return idx, false, true
	}
	if idx == 0 && edges & EDGE_LEFT != 0 {
		return idx, false, true
	}
	if idx == count && edges & EDGE_RIGHT != 0 {
		return idx, false, true
	}
	return idx, false, false
}

@(private)
finger_probe :: proc "contextless" (f: ^Node, edges: uintptr, s: [^]u8, sl: int, sroom: int) -> (int, bool, bool) {
	count := int(f.count)
	if !f.varlen {
		pp: Pattern_Probe = ---
		pattern_probe(f, s, sl, sroom, &pp)
		last := pattern_compare_slot(f, &pp, count - 1)
		if last >= 0 {
			if last == 0 {
				return count - 1, true, true
			}
			return count, false, edges & EDGE_RIGHT != 0
		}
		head := pattern_compare_slot(f, &pp, 0)
		if head <= 0 {
			if head == 0 {
				return 0, true, true
			}
			return 0, false, edges & EDGE_LEFT != 0
		}
		idx, exact := search_pattern_with(f, &pp, false)
		return idx, exact, true
	}
	last := var_compare_entry(f, count - 1, s, sl, sroom)
	if last >= 0 {
		if last == 0 {
			return count - 1, true, true
		}
		return count, false, edges & EDGE_RIGHT != 0
	}
	head := var_compare_entry(f, 0, s, sl, sroom)
	if head <= 0 {
		if head == 0 {
			return 0, true, true
		}
		return 0, false, edges & EDGE_LEFT != 0
	}
	idx, exact := node_lookup(f, s, sl, sroom, false, false)
	return idx, exact, true
}

@(private)
used_after_remove :: #force_inline proc "contextless" (n: ^Node, idx: int) -> int {
	count := int(n.count) - 1
	if !n.varlen {
		return pattern_used(node_body(n), int(n.plen), int(n.width), count)
	}
	_, kl := entry_key(n, idx)
	return node_used(n) - HEAD_BYTES - kl
}

create :: proc "contextless" (shared: ^int = nil) -> ^Rax {
	tree := cast(^Rax)runtime.heap_alloc(size_of(Rax), true)
	if tree == nil {
		intrinsics.trap()
	}
	tree^ = Rax{nodes = 1, shared = shared}
	account(tree, usable_size(tree))
	return tree
}

@(private)
free_subtree :: proc "contextless" (r: ^Rax, n: ^Node, cb: Free_Callback) {
	count := int(n.count)
	if n.level == 0 {
		if cb != nil {
			for i in 0 ..< count {
				v := entry_ptr(n, i)
				if v != nil {
					cb(v)
				}
			}
		}
	} else {
		for ci in 0 ..= count {
			free_subtree(r, child_at(n, ci), cb)
		}
	}
	node_release(r, n)
}

destroy :: proc "contextless" (r: ^Rax, cb: Free_Callback = nil) {
	if r == nil {
		return
	}
	if r.root != nil {
		free_subtree(r, r.root, cb)
		r.root = nil
	}
	account(r, -usable_size(r))
	runtime.heap_free(r)
}

@(private)
insert_descend :: proc "contextless" (
	r: ^Rax,
	n: ^Node,
	s: [^]u8,
	sl: int,
	sroom: int,
	data: rawptr,
	old: ^rawptr,
	overwrite: bool,
	rightmost: bool,
	leftmost: bool,
	out: ^Insert_Result,
) {
	out.node = n
	if n.level == 0 {
		idx, exact := node_search(n, s, sl, sroom, false)
		if exact {
			out.existed = true
			if old != nil {
				old^ = entry_ptr(n, idx)
			}
			if overwrite {
				entry_set_ptr(n, idx, data)
			}
			finger_note(r, n, edges_of(leftmost, rightmost), (r.finger & MISS_BITS) >> MISS_SHIFT)
			return
		}
		node_insert(r, n, idx, s, sl, sroom, data, rightmost, leftmost, out)
		if out.right == nil {
			r.finger = uintptr(out.node) | edges_of(leftmost, rightmost)
		} else {
			r.finger = 0
		}
		return
	}
	ci, _ := node_search(n, s, sl, sroom, true)
	child := child_at(n, ci)
	sub: Insert_Result = ---
	sub.node = nil
	sub.right = nil
	sub.existed = false
	separator_reset(&sub.sep)
	insert_descend(r, child, s, sl, sroom, data, old, overwrite, rightmost && ci == int(n.count), leftmost && ci == 0, &sub)
	if sub.existed {
		out.existed = true
		return
	}
	if sub.node != child {
		set_child(n, ci, sub.node)
	}
	if sub.right != nil {
		node_insert(r, n, ci, separator_data(&sub.sep), sub.sep.length, sub.sep.length, sub.right, rightmost, leftmost, out)
		separator_release(&sub.sep)
	}
}

@(private)
insert_common :: proc "contextless" (r: ^Rax, s: []u8, data: rawptr, old: ^rawptr, overwrite: bool) -> bool {
	buf: Probe_Buffer = ---
	sp, sl, sroom := probe_prepare(&buf, s)
	if r.root == nil {
		r.root = single_node(r, sp, sl, data)
		r.stored += 1
		r.version += 1
		finger_note(r, r.root, EDGE_LEFT | EDGE_RIGHT, 0)
		return true
	}
	f, edges, misses := finger_leaf(r)
	if f != nil && misses < MISS_LIMIT {
		idx, exact, usable := finger_probe(f, edges, sp, sl, sroom)
		if usable {
			finger_hit(r)
			misses = 0
			if exact {
				if old != nil {
					old^ = entry_ptr(f, idx)
				}
				if overwrite {
					entry_set_ptr(f, idx, data)
				}
				return false
			}
			if node_insert_fast(f, idx, sp, sl, sroom, data) {
				r.stored += 1
				r.version += 1
				r.stamp = r.version
				return true
			}
		} else {
			misses += 1
		}
	}
	out: Insert_Result = ---
	out.node = nil
	out.right = nil
	out.existed = false
	separator_reset(&out.sep)
	insert_descend(r, r.root, sp, sl, sroom, data, old, overwrite, true, true, &out)
	if out.existed {
		return false
	}
	root := out.node
	if out.right != nil {
		root = grow_root(r, root, &out.sep, out.right)
		separator_release(&out.sep)
	}
	r.root = root
	r.stored += 1
	r.version += 1
	finger_settle(r, f, misses)
	return true
}

insert :: proc "contextless" (r: ^Rax, s: []u8, data: rawptr, old: ^rawptr = nil) -> bool {
	return insert_common(r, s, data, old, true)
}

try_insert :: proc "contextless" (r: ^Rax, s: []u8, data: rawptr, old: ^rawptr = nil) -> bool {
	return insert_common(r, s, data, old, false)
}

find :: proc "contextless" (r: ^Rax, s: []u8) -> (value: rawptr, found: bool) {
	n := r.root
	if n == nil {
		return nil, false
	}
	buf: Probe_Buffer = ---
	sp, sl, sroom := probe_prepare(&buf, s)
	f, edges, misses := finger_leaf(r)
	if f != nil && misses < MISS_LIMIT {
		idx, exact, usable := finger_search(f, edges, sp, sl, sroom)
		if usable {
			finger_hit(r)
			if !exact {
				return nil, false
			}
			return entry_ptr(f, idx), true
		}
		misses += 1
	}
	leftmost := true
	rightmost := true
	for n.level > 0 {
		ci, _ := node_search(n, sp, sl, sroom, true)
		leftmost = leftmost && ci == 0
		rightmost = rightmost && ci == int(n.count)
		n = child_at(n, ci)
	}
	if n == f {
		misses = 0
	}
	finger_note(r, n, edges_of(leftmost, rightmost), misses)
	idx, exact := node_search(n, sp, sl, sroom, false)
	if !exact {
		return nil, false
	}
	return entry_ptr(n, idx), true
}

@(private)
remove_descend :: proc "contextless" (
	r: ^Rax,
	n: ^Node,
	s: [^]u8,
	sl: int,
	sroom: int,
	old: ^rawptr,
	rightmost: bool,
	leftmost: bool,
	removed: ^bool,
) -> ^Node {
	if n.level == 0 {
		idx, exact := node_search(n, s, sl, sroom, false)
		if !exact {
			return n
		}
		removed^ = true
		if old != nil {
			old^ = entry_ptr(n, idx)
		}
		if n.count == 1 {
			r.finger = 0
			node_release(r, n)
			return nil
		}
		entry_remove(n, idx)
		r.finger = uintptr(n) | edges_of(leftmost, rightmost)
		return n
	}
	ci, _ := node_search(n, s, sl, sroom, true)
	child := child_at(n, ci)
	nc := remove_descend(r, child, s, sl, sroom, old, rightmost && ci == int(n.count), leftmost && ci == 0, removed)
	if !removed^ {
		return n
	}
	if nc == nil {
		if n.count == 0 {
			node_release(r, n)
			return nil
		}
		if ci == 0 {
			node_set_first(n, cast(^Node)entry_ptr(n, 0))
			entry_remove(n, 0)
		} else {
			entry_remove(n, ci - 1)
		}
		return n
	}
	if node_used(nc) * 4 < level_limit(nc.level) {
		if ci < int(n.count) && merge_children(r, n, ci) {
			r.finger = 0
			return n
		}
		if ci > 0 && merge_children(r, n, ci - 1) {
			r.finger = 0
		}
	}
	return n
}

remove :: proc "contextless" (r: ^Rax, s: []u8, old: ^rawptr = nil) -> bool {
	if r.root == nil {
		return false
	}
	buf: Probe_Buffer = ---
	sp, sl, sroom := probe_prepare(&buf, s)
	f, edges, misses := finger_leaf(r)
	if f != nil && misses < MISS_LIMIT {
		idx, exact, usable := finger_probe(f, edges, sp, sl, sroom)
		if !usable {
			misses += 1
		} else {
			finger_hit(r)
			misses = 0
			if !exact {
				return false
			}
			if f.count > 1 {
				after := used_after_remove(f, idx)
				keep := false
				if f == r.root {
					keep = int(f.size) <= SHRINK_FLOOR || after * 4 >= int(f.size)
				} else {
					keep = edges != 0 || after * 4 >= LEAF_LIMIT
				}
				if keep {
					if old != nil {
						old^ = entry_ptr(f, idx)
					}
					entry_remove(f, idx)
					r.stored -= 1
					r.version += 1
					r.stamp = r.version
					return true
				}
			}
		}
	}
	removed := false
	root := remove_descend(r, r.root, sp, sl, sroom, old, true, true, &removed)
	if !removed {
		return false
	}
	for root != nil && root.level > 0 && root.count == 0 {
		only := node_first(root)
		node_release(r, root)
		root = only
	}
	if root != nil && int(root.size) > SHRINK_FLOOR && node_used(root) * 4 < int(root.size) {
		if root.level == 0 {
			r.finger = 0
		}
		root = shrink_node(r, root)
	}
	r.root = root
	r.stored -= 1
	r.version += 1
	finger_settle(r, f, misses)
	return true
}

memory :: proc "contextless" (r: ^Rax) -> int {
	return r.mem
}
