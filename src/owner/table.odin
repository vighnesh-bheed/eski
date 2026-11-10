package owner

import "base:runtime"

Error :: enum u8 {
	None,
	Invalid_Text,
	Table_Full,
	Out_Of_Memory,
}

COMPACT_MIN :: 64

Table :: struct($E: typeid) {
	by_text:   map[string]^E,
	numbers:   [dynamic]Owner,
	entries:   [dynamic]^E,
	holes:     int,
	next:      u32,
	limit:     u32,
	allocator: runtime.Allocator,
}

table_init :: proc(t: ^Table($E), limit := LAST_USER, allocator := context.allocator) {
	t^ = Table(E) {
		next      = u32(FIRST_USER),
		limit     = u32(min(limit, LAST_USER)),
		allocator = allocator,
	}
	t.by_text = make(map[string]^E, allocator)
	t.numbers = make([dynamic]Owner, allocator)
	t.entries = make([dynamic]^E, allocator)
}

table_destroy :: proc(t: ^Table($E)) {
	for e in t.entries {
		if e != nil {
			delete(e.text, t.allocator)
			free(e, t.allocator)
		}
	}
	delete(t.by_text)
	delete(t.numbers)
	delete(t.entries)
	t^ = {}
}

table_count :: #force_inline proc "contextless" (t: ^Table($E)) -> int {
	return len(t.by_text)
}

table_issued :: #force_inline proc "contextless" (t: ^Table($E)) -> u32 {
	return t.next - u32(FIRST_USER)
}

table_lookup :: proc(t: ^Table($E), text: []u8) -> ^E {
	if len(text) == 0 || len(text) > TEXT_MAX {
		return nil
	}
	return t.by_text[string(text)]
}

table_intern :: proc(t: ^Table($E), text: []u8) -> (^E, Error) {
	if !text_valid(text) {
		return nil, .Invalid_Text
	}
	if e, found := t.by_text[string(text)]; found {
		return e, .None
	}
	if t.next < u32(FIRST_USER) || t.next > t.limit {
		return nil, .Table_Full
	}
	e, err := new(E, t.allocator)
	if err != nil {
		return nil, .Out_Of_Memory
	}
	owned, owned_err := make([]u8, len(text), t.allocator)
	if owned_err != nil {
		free(e, t.allocator)
		return nil, .Out_Of_Memory
	}
	copy(owned, text)
	e.number = Owner(t.next)
	e.text = string(owned)
	if _, a := append(&t.numbers, e.number); a != nil {
		delete(owned, t.allocator)
		free(e, t.allocator)
		return nil, .Out_Of_Memory
	}
	if _, a := append(&t.entries, e); a != nil {
		pop(&t.numbers)
		delete(owned, t.allocator)
		free(e, t.allocator)
		return nil, .Out_Of_Memory
	}
	if m := map_insert(&t.by_text, e.text, e); m == nil {
		pop(&t.numbers)
		pop(&t.entries)
		delete(owned, t.allocator)
		free(e, t.allocator)
		return nil, .Out_Of_Memory
	}
	t.next += 1
	return e, .None
}

@(private = "file")
table_position :: proc "contextless" (t: ^Table($E), number: Owner) -> int {
	lo, hi := 0, len(t.numbers)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if t.numbers[mid] < number {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

table_find :: proc "contextless" (t: ^Table($E), number: Owner) -> ^E {
	if !is_user(number) {
		return nil
	}
	i := table_position(t, number)
	if i < len(t.numbers) && t.numbers[i] == number {
		return t.entries[i]
	}
	return nil
}

table_text :: proc "contextless" (t: ^Table($E), number: Owner) -> (string, bool) {
	e := table_find(t, number)
	if e == nil {
		return "", false
	}
	return e.text, true
}

table_from :: proc "contextless" (t: ^Table($E), from: Owner) -> ^E {
	for i := table_position(t, from); i < len(t.entries); i += 1 {
		if e := t.entries[i]; e != nil {
			return e
		}
	}
	return nil
}

@(private = "file")
table_compact :: proc(t: ^Table($E)) {
	kept := 0
	for e, i in t.entries {
		if e == nil {
			continue
		}
		t.entries[kept] = e
		t.numbers[kept] = t.numbers[i]
		kept += 1
	}
	resize(&t.entries, kept)
	resize(&t.numbers, kept)
	t.holes = 0
}

table_drop :: proc(t: ^Table($E), number: Owner) -> bool {
	if !is_user(number) {
		return false
	}
	i := table_position(t, number)
	if i >= len(t.numbers) || t.numbers[i] != number || t.entries[i] == nil {
		return false
	}
	e := t.entries[i]
	delete_key(&t.by_text, e.text)
	delete(e.text, t.allocator)
	free(e, t.allocator)
	t.entries[i] = nil
	t.holes += 1
	if t.holes >= COMPACT_MIN && t.holes * 2 > len(t.entries) {
		table_compact(t)
	}
	return true
}
