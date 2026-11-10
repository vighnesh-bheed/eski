package prefix

import "core:strings"
import "core:unicode/utf8"
import "../termdict"

MIN_LENGTH :: 2

LIMIT :: 200

Params :: struct {
	min_length: int,
}

params_default :: proc "contextless" () -> Params {
	return Params{min_length = MIN_LENGTH}
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
