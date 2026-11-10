package text

import "base:runtime"
import "core:slice"

DEFAULT_STOP_WORDS := [33]string {
	"a",
	"is",
	"the",
	"an",
	"and",
	"are",
	"as",
	"at",
	"be",
	"but",
	"by",
	"for",
	"if",
	"in",
	"into",
	"it",
	"no",
	"not",
	"of",
	"on",
	"or",
	"such",
	"that",
	"their",
	"then",
	"there",
	"these",
	"they",
	"this",
	"to",
	"was",
	"will",
	"with",
}

Stop_Mode :: enum u8 {
	Default,
	None,
	Custom,
}

Stop_Words :: struct {
	mode:      Stop_Mode,
	words:     []string,
	bytes:     []u8,
	slots:     []u32,
	mask:      u32,
	lengths:   u64,
	firsts:    [4]u64,
	allocator: runtime.Allocator,
}

Query_Term_Kind :: enum u8 {
	Plain,
	Exact,
	Prefix,
	Suffix,
	Infix,
	Wildcard,
	Fuzzy,
	Tag,
}

stop_hash :: #force_inline proc "contextless" (word: []u8) -> u32 {
	h := u32(2166136261)
	for b in word {
		h = (h ~ u32(b)) * 16777619
	}
	return h
}

stop_words_build :: proc(sw: ^Stop_Words, mode: Stop_Mode, folded: [][]u8, allocator := context.allocator) -> Error {
	sorted := make([]string, len(folded), context.temp_allocator)
	total := 0
	for w, i in folded {
		sorted[i] = string(w)
		total += len(w)
	}
	slice.sort(sorted)
	unique := 0
	for w in sorted {
		if unique == 0 || w != sorted[unique - 1] {
			sorted[unique] = w
			unique += 1
		}
	}
	size := 8
	for size < 2 * unique {
		size *= 2
	}
	bytes, berr := make([]u8, total, allocator)
	words, werr := make([]string, unique, allocator)
	slots, serr := make([]u32, size, allocator)
	if berr != nil || werr != nil || serr != nil {
		delete(bytes, allocator)
		delete(words, allocator)
		delete(slots, allocator)
		return .Out_Of_Memory
	}
	at := 0
	for i in 0 ..< unique {
		w := sorted[i]
		copy(bytes[at:], w)
		words[i] = string(bytes[at:][:len(w)])
		at += len(w)
	}
	mask := u32(size - 1)
	lengths: u64
	firsts: [4]u64
	for w, i in words {
		h := stop_hash(transmute([]u8)w) & mask
		for slots[h] != 0 {
			h = (h + 1) & mask
		}
		slots[h] = u32(i + 1)
		lengths |= u64(1) << uint(min(len(w), 63))
		if len(w) > 0 {
			firsts[w[0] >> 6] |= u64(1) << (w[0] & 63)
		}
	}
	sw^ = Stop_Words {
		mode      = mode,
		words     = words,
		bytes     = bytes,
		slots     = slots,
		mask      = mask,
		lengths   = lengths,
		firsts    = firsts,
		allocator = allocator,
	}
	return .None
}

stop_words_default :: proc(sw: ^Stop_Words, allocator := context.allocator) -> Error {
	folded: [len(DEFAULT_STOP_WORDS)][]u8
	for w, i in DEFAULT_STOP_WORDS {
		folded[i] = transmute([]u8)w
	}
	return stop_words_build(sw, .Default, folded[:], allocator)
}

stop_words_none :: proc(sw: ^Stop_Words, allocator := context.allocator) -> Error {
	return stop_words_build(sw, .None, nil, allocator)
}

stop_words_custom :: proc(sw: ^Stop_Words, words: [][]u8, allocator := context.allocator) -> Error {
	if len(words) == 0 {
		return stop_words_none(sw, allocator)
	}
	store := make([dynamic]u8, 0, 64, context.temp_allocator)
	ends := make([]int, len(words), context.temp_allocator)
	for w, i in words {
		fold(w, nil, &store)
		ends[i] = len(store)
	}
	folded := make([][]u8, len(words), context.temp_allocator)
	start := 0
	for end, i in ends {
		folded[i] = store[start:end]
		start = end
	}
	return stop_words_build(sw, .Custom, folded, allocator)
}

stop_words_destroy :: proc(sw: ^Stop_Words) {
	if sw.allocator.procedure != nil {
		delete(sw.bytes, sw.allocator)
		delete(sw.words, sw.allocator)
		delete(sw.slots, sw.allocator)
	}
	sw^ = {}
}

is_stop_word :: proc "contextless" (sw: ^Stop_Words, term: []u8) -> bool #no_bounds_check {
	if sw == nil || len(sw.words) == 0 {
		return false
	}
	if sw.lengths & (u64(1) << uint(min(len(term), 63))) == 0 {
		return false
	}
	if len(term) > 0 && sw.firsts[term[0] >> 6] & (u64(1) << (term[0] & 63)) == 0 {
		return false
	}
	h := stop_hash(term) & sw.mask
	for {
		slot := sw.slots[h]
		if slot == 0 {
			return false
		}
		if sw.words[slot - 1] == string(term) {
			return true
		}
		h = (h + 1) & sw.mask
	}
}

stop_words_list :: proc "contextless" (sw: ^Stop_Words) -> []string {
	return sw.words
}

stop_words_reported :: proc "contextless" (sw: ^Stop_Words) -> bool {
	return sw.mode != .Default
}

query_drops_term :: proc "contextless" (sw: ^Stop_Words, term: []u8, kind: Query_Term_Kind, no_stop_words: bool) -> bool {
	if no_stop_words || kind != .Plain {
		return false
	}
	return is_stop_word(sw, term)
}
