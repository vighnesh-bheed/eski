package termstats

import "base:runtime"
import "../label"

Pair :: struct {
	label: label.Id,
	count: u32,
}

Term :: struct {
	first: Pair,
	more:  ^[dynamic]Pair,
}

Stats :: struct {
	documents: label.Counters,
	lengths:   label.Counters,
	terms:     [dynamic]Term,
	allocator: runtime.Allocator,
}

Totals :: struct {
	documents:    u64,
	total_length: u64,
}

EMPTY :: label.ID_NONE

init :: proc(s: ^Stats, allocator := context.allocator) {
	s^ = Stats{allocator = allocator}
	label.counters_init(&s.documents, allocator)
	label.counters_init(&s.lengths, allocator)
	s.terms = make([dynamic]Term, 0, 0, allocator)
}

destroy :: proc(s: ^Stats) {
	for &t in s.terms {
		release(s, &t)
	}
	delete(s.terms)
	label.counters_destroy(&s.documents)
	label.counters_destroy(&s.lengths)
	s^ = Stats{}
}

release :: proc(s: ^Stats, t: ^Term) {
	if t.more != nil {
		delete(t.more^)
		free(t.more, s.allocator)
	}
	t^ = Term{first = Pair{label = EMPTY}}
}

document_add :: proc(s: ^Stats, id: label.Id, length: u32) -> label.Error {
	label.counters_add(&s.documents, id, 1) or_return
	if e := label.counters_add(&s.lengths, id, u64(length)); e != .None {
		label.counters_sub(&s.documents, id, 1)
		return e
	}
	return .None
}

document_remove :: proc(s: ^Stats, id: label.Id, length: u32) -> label.Error {
	if label.counters_get(&s.documents, id) == 0 || label.counters_get(&s.lengths, id) < u64(length) {
		return .Underflow
	}
	label.counters_sub(&s.documents, id, 1) or_return
	return label.counters_sub(&s.lengths, id, u64(length))
}

ensure_term :: proc(s: ^Stats, term: u32) -> label.Error {
	if int(term) < len(s.terms) {
		return .None
	}
	old := len(s.terms)
	if int(term) + 1 > cap(s.terms) && reserve(&s.terms, max(2 * cap(s.terms), int(term) + 1)) != nil {
		return .Out_Of_Memory
	}
	if resize(&s.terms, int(term) + 1) != nil {
		return .Out_Of_Memory
	}
	for i in old ..< len(s.terms) {
		s.terms[i] = Term{first = Pair{label = EMPTY}}
	}
	return .None
}

term_add :: proc(s: ^Stats, term: u32, id: label.Id, delta: u32 = 1) -> label.Error {
	if id == label.ID_NONE {
		return .Invalid_Label
	}
	ensure_term(s, term) or_return
	t := &s.terms[term]
	if t.first.label == EMPTY || t.first.label == id {
		if t.first.label == id && delta > max(u32) - t.first.count {
			return .Overflow
		}
		if t.first.label == EMPTY {
			t.first = Pair{label = id, count = delta}
		} else {
			t.first.count += delta
		}
		return .None
	}
	if t.more == nil {
		more, e := new([dynamic]Pair, s.allocator)
		if e != nil {
			return .Out_Of_Memory
		}
		more^ = make([dynamic]Pair, 0, 2, s.allocator)
		t.more = more
	}
	for &p in t.more^ {
		if p.label == id {
			if delta > max(u32) - p.count {
				return .Overflow
			}
			p.count += delta
			return .None
		}
	}
	if _, e := append(t.more, Pair{label = id, count = delta}); e != nil {
		return .Out_Of_Memory
	}
	return .None
}

term_remove :: proc(s: ^Stats, term: u32, id: label.Id, delta: u32 = 1) -> label.Error {
	if int(term) >= len(s.terms) {
		return .Underflow if delta > 0 else .None
	}
	t := &s.terms[term]
	if t.first.label == id && t.first.label != EMPTY {
		if t.first.count < delta {
			return .Underflow
		}
		t.first.count -= delta
		if t.first.count == 0 {
			if t.more != nil && len(t.more^) > 0 {
				t.first = pop(t.more)
			} else {
				t.first = Pair{label = EMPTY}
			}
		}
		return .None
	}
	if t.more != nil {
		for &p, i in t.more^ {
			if p.label == id {
				if p.count < delta {
					return .Underflow
				}
				p.count -= delta
				if p.count == 0 {
					unordered_remove(t.more, i)
				}
				return .None
			}
		}
	}
	return .Underflow if delta > 0 else .None
}

term_forget :: proc(s: ^Stats, term: u32) {
	if int(term) < len(s.terms) {
		release(s, &s.terms[term])
	}
}

term_total :: proc "contextless" (s: ^Stats, term: u32) -> u64 {
	if int(term) >= len(s.terms) {
		return 0
	}
	t := &s.terms[term]
	n := u64(0)
	if t.first.label != EMPTY {
		n += u64(t.first.count)
	}
	if t.more != nil {
		for p in t.more^ {
			n += u64(p.count)
		}
	}
	return n
}

term_count :: proc "contextless" (s: ^Stats, term: u32, id: label.Id) -> u64 {
	if int(term) >= len(s.terms) {
		return 0
	}
	t := &s.terms[term]
	if t.first.label == id && id != EMPTY {
		return u64(t.first.count)
	}
	if t.more != nil {
		for p in t.more^ {
			if p.label == id {
				return u64(p.count)
			}
		}
	}
	return 0
}

term_visible :: proc "contextless" (s: ^Stats, term: u32, v: ^label.Visibility) -> u64 {
	if int(term) >= len(s.terms) {
		return 0
	}
	t := &s.terms[term]
	n := u64(0)
	if t.first.label != EMPTY && label.visible(v, t.first.label) {
		n += u64(t.first.count)
	}
	if t.more != nil {
		for p in t.more^ {
			if label.visible(v, p.label) {
				n += u64(p.count)
			}
		}
	}
	return n
}

totals :: proc "contextless" (s: ^Stats) -> Totals {
	return Totals{documents = label.counters_total(&s.documents), total_length = label.counters_total(&s.lengths)}
}

totals_for :: proc "contextless" (s: ^Stats, id: label.Id) -> Totals {
	return Totals{documents = label.counters_get(&s.documents, id), total_length = label.counters_get(&s.lengths, id)}
}

totals_visible :: proc "contextless" (s: ^Stats, v: ^label.Visibility) -> Totals {
	return Totals{documents = label.counters_visible(&s.documents, v), total_length = label.counters_visible(&s.lengths, v)}
}
