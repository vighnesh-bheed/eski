package prefix

import "core:strings"
import "core:unicode/utf8"
import "../label"
import "../termdict"
import "../termstats"

MIN_LENGTH :: 2

LIMIT :: 200

Params :: struct {
	min_length: int,
	stats:      ^termstats.Stats,
	visibility: ^label.Visibility,
}

params_default :: proc "contextless" () -> Params {
	return Params{min_length = MIN_LENGTH}
}

params_visible :: proc "contextless" (stats: ^termstats.Stats, visibility: ^label.Visibility) -> Params {
	return Params{min_length = MIN_LENGTH, stats = stats, visibility = visibility}
}

hidden :: #force_inline proc "contextless" (p: ^Params, id: termdict.Id) -> bool {
	if p.visibility == nil {
		return false
	}
	return p.stats == nil || termstats.term_visible(p.stats, u32(id), p.visibility) == 0
}

expand :: proc(ctx: rawptr, d: ^termdict.Dictionary, pattern: string, limit: int, out: ^[dynamic]termdict.Id) -> (truncated: bool, err: termdict.Error) {
	p := (^Params)(ctx)
	if utf8.rune_count_in_string(pattern) < p.min_length {
		return false, .None
	}
	it: termdict.Iterator
	termdict.iterator_seek(&it, d, pattern)
	defer termdict.iterator_close(&it)
	n := 0
	for {
		term, id, ok := termdict.iterator_next(&it)
		if !ok || !strings.has_prefix(term, pattern) {
			break
		}
		if hidden(p, id) {
			continue
		}
		if limit >= 0 && n >= limit {
			truncated = true
			break
		}
		if _, e := append(out, id); e != nil {
			return truncated, .Out_Of_Memory
		}
		n += 1
	}
	return truncated, .None
}

matcher :: proc(p: ^Params) -> termdict.Matcher {
	return termdict.Matcher{ctx = p, expand = expand}
}
