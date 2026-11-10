package rrf

import "core:slice"
import "../retrieve"

CONSTANT :: 60

WINDOW :: 20

Params :: struct {
	constant: f64,
	window:   int,
}

params_default :: proc "contextless" () -> Params {
	return Params{constant = CONSTANT, window = WINDOW}
}

Contribution :: struct {
	doc:    u32,
	branch: int,
	value:  f64,
}

contribution_before :: proc(a, b: Contribution) -> bool {
	return a.doc < b.doc || (a.doc == b.doc && a.branch < b.branch)
}

fuse :: proc(ctx: rawptr, branches: [][]retrieve.Ranked, out: ^[dynamic]retrieve.Ranked) -> retrieve.Error {
	p := (^Params)(ctx)
	room := 0
	for b in branches {
		room += len(b) if p.window <= 0 else min(len(b), p.window)
	}
	parts, err := make([dynamic]Contribution, 0, room)
	if err != nil {
		return .Out_Of_Memory
	}
	defer delete(parts)
	for b, bi in branches {
		n := len(b) if p.window <= 0 else min(len(b), p.window)
		for r in 0 ..< n {
			append(&parts, Contribution{doc = b[r].doc, branch = bi, value = 1.0 / (p.constant + f64(r + 1))})
		}
	}
	slice.stable_sort_by(parts[:], contribution_before)
	start := len(out)
	if e := reserve(out, start + len(parts)); e != nil {
		return .Out_Of_Memory
	}
	i := 0
	for i < len(parts) {
		doc := parts[i].doc
		total := parts[i].value
		j := i + 1
		for j < len(parts) && parts[j].doc == doc {
			total += parts[j].value
			j += 1
		}
		append(out, retrieve.Ranked{doc = doc, score = total})
		i = j
	}
	retrieve.sort_ranked(out[start:])
	return .None
}

fusion :: proc(p: ^Params) -> retrieve.Fusion {
	return retrieve.Fusion{ctx = p, fuse = fuse}
}
