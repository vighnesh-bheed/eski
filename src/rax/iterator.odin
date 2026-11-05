package rax

import "base:intrinsics"
import "base:runtime"

@(private)
ITER_INLINE_KEY_BYTES :: 128
@(private)
ITER_PATH_INLINE :: 8

@(private)
Iter_State :: enum u8 {
	Idle,
	Exhausted,
	Seeked,
	Walking,
}

@(private)
Iter_Step :: struct {
	node: ^Node,
	idx:  int,
}

@(private)
Seek_Op :: enum u8 {
	First,
	Last,
	Equal,
	Greater,
	Greater_Equal,
	Less,
	Less_Equal,
}

Iterator :: struct {
	data:        rawptr,
	tree:        ^Rax,
	key_heap:    [^]u8,
	key_cap:     int,
	key_len:     int,
	path_heap:   [^]Iter_Step,
	path_cap:    int,
	depth:       int,
	version:     u32,
	state:       Iter_State,
	partial:     bool,
	key_inline:  [ITER_INLINE_KEY_BYTES]u8,
	path_inline: [ITER_PATH_INLINE]Iter_Step,
}

start :: proc "contextless" (it: ^Iterator, rt: ^Rax) {
	it.data = nil
	it.tree = rt
	it.key_heap = nil
	it.key_cap = 0
	it.key_len = 0
	it.path_heap = nil
	it.path_cap = 0
	it.depth = 0
	it.version = 0
	it.state = .Idle
	it.partial = false
}

stop :: proc "contextless" (it: ^Iterator) {
	if it.key_heap != nil {
		runtime.heap_free(it.key_heap)
		it.key_heap = nil
	}
	if it.path_heap != nil {
		runtime.heap_free(it.path_heap)
		it.path_heap = nil
	}
	it.key_cap = 0
	it.path_cap = 0
	it.key_len = 0
	it.depth = 0
	it.state = .Idle
	it.partial = false
}

eof :: proc "contextless" (it: ^Iterator) -> bool {
	return it.state != .Seeked && it.state != .Walking
}

key :: proc "contextless" (it: ^Iterator) -> []u8 {
	return iter_key_buffer(it)[:it.key_len]
}

@(private)
iter_key_buffer :: #force_inline proc "contextless" (it: ^Iterator) -> [^]u8 {
	if it.key_heap != nil {
		return it.key_heap
	}
	return &it.key_inline[0]
}

@(private)
iter_path :: #force_inline proc "contextless" (it: ^Iterator) -> [^]Iter_Step {
	if it.path_heap != nil {
		return it.path_heap
	}
	return &it.path_inline[0]
}

@(private)
iter_reserve_key :: proc "contextless" (it: ^Iterator, length: int) -> [^]u8 {
	if it.key_heap == nil {
		if length <= ITER_INLINE_KEY_BYTES {
			return &it.key_inline[0]
		}
		capacity := max(length, 2 * ITER_INLINE_KEY_BYTES)
		p := cast([^]u8)runtime.heap_alloc(capacity, false)
		if p == nil {
			return nil
		}
		it.key_heap = p
		it.key_cap = capacity
		return p
	}
	if length > it.key_cap {
		capacity := max(length, it.key_cap + it.key_cap / 2)
		p := cast([^]u8)runtime.heap_alloc(capacity, false)
		if p == nil {
			return nil
		}
		runtime.heap_free(it.key_heap)
		it.key_heap = p
		it.key_cap = capacity
	}
	return it.key_heap
}

@(private)
iter_reserve_path :: proc "contextless" (it: ^Iterator, depth: int) -> [^]Iter_Step {
	if it.path_heap == nil && depth <= ITER_PATH_INLINE {
		return &it.path_inline[0]
	}
	if it.path_heap != nil && depth <= it.path_cap {
		return it.path_heap
	}
	capacity := max(depth, 2 * ITER_PATH_INLINE)
	p := cast([^]Iter_Step)runtime.heap_alloc(capacity * size_of(Iter_Step), false)
	if p == nil {
		return nil
	}
	if it.path_heap != nil {
		runtime.heap_free(it.path_heap)
	}
	it.path_heap = p
	it.path_cap = capacity
	return p
}

@(private)
iter_load :: proc "contextless" (it: ^Iterator, n: ^Node, i: int) -> bool #no_bounds_check {
	plen := int(n.plen)
	if !n.varlen {
		buf := iter_reserve_key(it, plen)
		if buf == nil {
			return false
		}
		pattern_key_copy(n, i, buf)
		it.key_len = plen
		it.data = entry_ptr(n, i)
		return true
	}
	k, kl := entry_key(n, i)
	length := plen + kl
	buf := iter_reserve_key(it, length)
	if buf == nil {
		return false
	}
	if plen > 0 {
		intrinsics.mem_copy_non_overlapping(buf, node_prefix(n), plen)
	}
	if kl > 0 {
		intrinsics.mem_copy_non_overlapping(&buf[plen], k, kl)
	}
	it.key_len = length
	it.data = entry_ptr(n, i)
	return true
}

@(private)
path_advance :: proc "contextless" (path: [^]Iter_Step, depth: int) -> bool #no_bounds_check {
	l := 1
	for l < depth && path[l].idx >= int(path[l].node.count) {
		l += 1
	}
	if l >= depth {
		return false
	}
	path[l].idx += 1
	nd := child_at(path[l].node, path[l].idx)
	for l > 1 {
		l -= 1
		path[l] = Iter_Step{nd, 0}
		nd = node_first(nd)
	}
	path[0] = Iter_Step{nd, 0}
	return true
}

@(private)
path_retreat :: proc "contextless" (path: [^]Iter_Step, depth: int) -> bool #no_bounds_check {
	l := 1
	for l < depth && path[l].idx == 0 {
		l += 1
	}
	if l >= depth {
		return false
	}
	path[l].idx -= 1
	nd := child_at(path[l].node, path[l].idx)
	for l > 1 {
		l -= 1
		c := int(nd.count)
		path[l] = Iter_Step{nd, c}
		nd = child_at(nd, c)
	}
	path[0] = Iter_Step{nd, int(nd.count) - 1}
	return true
}

@(private)
iter_complete_path :: proc "contextless" (it: ^Iterator) #no_bounds_check {
	path := iter_path(it)
	buf: Probe_Buffer = ---
	s, sl, sroom := probe_prepare(&buf, iter_key_buffer(it)[:it.key_len])
	nd := it.tree.root
	for l := it.depth - 1; l > 0; l -= 1 {
		ci, _ := node_search(nd, s, sl, sroom, true)
		path[l] = Iter_Step{nd, ci}
		nd = child_at(nd, ci)
	}
	it.partial = false
}

@(private)
seek_adjust :: #force_inline proc "contextless" (op: Seek_Op, idx: int, exact: bool) -> (int, bool) {
	#partial switch op {
	case .Equal:
		return idx, exact
	case .Greater:
		return idx + 1 if exact else idx, true
	case .Less_Equal:
		return idx if exact else idx - 1, true
	case .Less:
		return idx - 1, true
	}
	return idx, true
}

@(private)
iter_exhaust :: #force_inline proc "contextless" (it: ^Iterator) {
	it.state = .Exhausted
	it.key_len = 0
	it.data = nil
}

@(private)
seek_position :: proc "contextless" (it: ^Iterator, op: Seek_Op, ele: []u8) -> bool #no_bounds_check {
	t := it.tree
	if t == nil || t.root == nil {
		iter_exhaust(it)
		return true
	}
	root := t.root
	depth := int(root.level) + 1
	path := iter_reserve_path(it, depth)
	if path == nil {
		iter_exhaust(it)
		return false
	}
	it.depth = depth
	it.version = t.version
	it.partial = false
	found := true
	nd := root
	buf: Probe_Buffer = ---
	s, sl, sroom := probe_prepare(&buf, ele)
	if op != .First && op != .Last && depth > 1 {
		if f, edges, _ := finger_leaf(t); f != nil {
			idx, exact, usable := finger_probe(f, edges, s, sl, sroom)
			if usable {
				pos, hit := seek_adjust(op, idx, exact)
				count := int(f.count)
				if !hit || (pos >= count && edges & EDGE_RIGHT != 0) || (pos < 0 && edges & EDGE_LEFT != 0) {
					iter_exhaust(it)
					return true
				}
				if pos >= 0 && pos < count {
					path[0] = Iter_Step{f, pos}
					it.partial = true
					if !iter_load(it, f, pos) {
						iter_exhaust(it)
						return false
					}
					it.state = .Seeked
					return true
				}
			}
		}
	}
	#partial switch op {
	case .First:
		for l := depth - 1; l > 0; l -= 1 {
			path[l] = Iter_Step{nd, 0}
			nd = node_first(nd)
		}
		path[0] = Iter_Step{nd, 0}
	case .Last:
		for l := depth - 1; l > 0; l -= 1 {
			c := int(nd.count)
			path[l] = Iter_Step{nd, c}
			nd = child_at(nd, c)
		}
		path[0] = Iter_Step{nd, int(nd.count) - 1}
	case:
		for l := depth - 1; l > 0; l -= 1 {
			ci, _ := node_search(nd, s, sl, sroom, true)
			path[l] = Iter_Step{nd, ci}
			nd = child_at(nd, ci)
		}
		idx, exact := node_search(nd, s, sl, sroom, false)
		count := int(nd.count)
		idx, found = seek_adjust(op, idx, exact)
		path[0] = Iter_Step{nd, idx}
		if found {
			if idx >= count {
				found = path_advance(path, depth)
			} else if idx < 0 {
				found = path_retreat(path, depth)
			}
		}
	}
	if !found {
		iter_exhaust(it)
		return true
	}
	if !iter_load(it, path[0].node, path[0].idx) {
		iter_exhaust(it)
		return false
	}
	it.state = .Seeked
	return true
}

@(private)
parse_op :: proc "contextless" (op: string) -> (Seek_Op, bool) {
	switch op {
	case "^":
		return .First, true
	case "$":
		return .Last, true
	case "=":
		return .Equal, true
	case ">":
		return .Greater, true
	case ">=":
		return .Greater_Equal, true
	case "<":
		return .Less, true
	case "<=":
		return .Less_Equal, true
	}
	return .First, false
}

seek :: proc "contextless" (it: ^Iterator, op: string, ele: []u8 = nil) -> bool {
	kind, ok := parse_op(op)
	if !ok {
		iter_exhaust(it)
		return false
	}
	return seek_position(it, kind, ele)
}

@(private)
iter_relocate :: proc "contextless" (it: ^Iterator, op: Seek_Op) -> bool {
	if !seek_position(it, op, iter_key_buffer(it)[:it.key_len]) {
		return false
	}
	if it.state != .Seeked {
		return false
	}
	it.state = .Walking
	return true
}

next :: proc "contextless" (it: ^Iterator) -> bool #no_bounds_check {
	#partial switch it.state {
	case .Seeked:
		if it.tree.version != it.version {
			return iter_relocate(it, .Greater_Equal)
		}
		it.state = .Walking
		return true
	case .Walking:
		if it.tree.version != it.version {
			return iter_relocate(it, .Greater)
		}
		path := iter_path(it)
		leaf := path[0].node
		i := path[0].idx + 1
		if i >= int(leaf.count) {
			if it.partial {
				iter_complete_path(it)
			}
			if !path_advance(path, it.depth) {
				it.state = .Exhausted
				return false
			}
			leaf = path[0].node
			i = 0
		}
		path[0].idx = i
		if !iter_load(it, leaf, i) {
			it.state = .Exhausted
			return false
		}
		return true
	}
	return false
}

prev :: proc "contextless" (it: ^Iterator) -> bool #no_bounds_check {
	#partial switch it.state {
	case .Seeked:
		if it.tree.version != it.version {
			return iter_relocate(it, .Less_Equal)
		}
		it.state = .Walking
		return true
	case .Walking:
		if it.tree.version != it.version {
			return iter_relocate(it, .Less)
		}
		path := iter_path(it)
		leaf := path[0].node
		i := path[0].idx - 1
		if i < 0 {
			if it.partial {
				iter_complete_path(it)
			}
			if !path_retreat(path, it.depth) {
				it.state = .Exhausted
				return false
			}
			leaf = path[0].node
			i = path[0].idx
		}
		path[0].idx = i
		if !iter_load(it, leaf, i) {
			it.state = .Exhausted
			return false
		}
		return true
	}
	return false
}
