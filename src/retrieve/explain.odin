package retrieve

import "core:math"
import "core:mem"
import "core:slice"

Score_Trace :: struct {
	label: string,
	leaf: Leaf,
	frequency: u32,
	value: f64,
	children: []Score_Trace,
	positions: []u32,
}

Score_Trace_Context :: struct {
	nodes: [dynamic]Score_Trace,
	allocator: mem.Allocator,
	track_positions, explain: bool,
}

trace_leaf :: proc(s: ^Scoring, cursor: ^Cursor, l: Leaf, frequency: u32, label: string, value: f64) {
	if s == nil || s.trace == nil {
		return
	}
	entry := Score_Trace{label = label, leaf = l, frequency = frequency if l.kind != .Filter else 0, value = value}
	if s.trace.track_positions && l.kind == .Term {
		pos := make([dynamic]u32, s.trace.allocator)
		if positions(cursor, &pos) {
			entry.positions = pos[:]
		}
	}
	append(&s.trace.nodes, entry)
}

trace_zero :: proc(s: ^Scoring, weight: f64, frequency: u32) {
	append(&s.trace.nodes, Score_Trace{leaf = leaf(.Filter, weight), frequency = frequency})
}

trace_group :: proc(s: ^Scoring, first: int, weight, value: f64) {
	if s == nil || s.trace == nil {
		return
	}
	nodes := &s.trace.nodes
	children := make([]Score_Trace, len(nodes^) - first, s.trace.allocator)
	copy(children, nodes^[first:])
	resize(nodes, first)
	append(nodes, Score_Trace{leaf = {weight = weight}, children = children, value = value})
}

trace_start :: #force_inline proc(s: ^Scoring) -> int {
	return len(s.trace.nodes) if s != nil && s.trace != nil else 0
}

trace_merge_positions :: proc(nodes: []Score_Trace, out: ^[dynamic]u32) {
	for node in nodes {
		append(out, ..node.positions)
		trace_merge_positions(node.children, out)
	}
}

trace_offsets :: proc(nodes: []Score_Trace, out: ^[dynamic][]u32, allocator: mem.Allocator) {
	for node in nodes {
		if len(node.positions) > 0 {
			append(out, node.positions)
		}
		if len(node.children) > 0 {
			merged := make([dynamic]u32, allocator)
			trace_merge_positions(node.children, &merged)
			if len(merged) > 0 {
				slice.sort(merged[:])
				append(out, merged[:])
			}
		}
	}
}

trace_slop :: proc(nodes: []Score_Trace, allocator: mem.Allocator) -> int {
	offsets := make([dynamic][]u32, allocator)
	for root in nodes {
		if len(root.positions) > 0 {
			append(&offsets, root.positions)
		}
		trace_offsets(root.children, &offsets, allocator)
	}
	if len(offsets) < 2 {
		return 1
	}
	sum := 0.0
	for k in 1 ..< len(offsets) {
		a, b := offsets[k-1], offsets[k]
		i, j := 0, 0
		best := u32(max(u32))
		for i < len(a) && j < len(b) {
			if a[i] <= b[j] {
				best = min(best, b[j] - a[i])
				i += 1
			} else {
				best = min(best, a[i] - b[j])
				j += 1
			}
		}
		sum += f64(best) * f64(best)
	}
	return max(1, int(math.sqrt(sum)))
}

Explanation :: struct {
	text: string,
	children: []Explanation,
}
