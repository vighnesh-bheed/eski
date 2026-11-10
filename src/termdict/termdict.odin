package termdict

import "base:runtime"
import "core:strings"
import "../rax"

Id :: distinct u32

NONE :: Id(max(u32))

ID_LIMIT :: int(max(u32)) - 1

Error :: enum u8 {
	None,
	Out_Of_Memory,
	Too_Many_Terms,
}

Entry :: struct {
	text:   string,
	live:   bool,
	listed: bool,
}

Dictionary :: struct {
	tree:      ^rax.Rax,
	entries:   [dynamic]Entry,
	free:      [dynamic]Id,
	live:      int,
	listed:    int,
	allocator: runtime.Allocator,
}

key_bytes :: #force_inline proc "contextless" (s: string) -> []u8 {
	return transmute([]u8)s
}

init :: proc(d: ^Dictionary, allocator := context.allocator) {
	d^ = Dictionary{allocator = allocator}
	d.tree = rax.create()
	d.entries = make([dynamic]Entry, 0, 0, allocator)
	d.free = make([dynamic]Id, 0, 0, allocator)
}

destroy :: proc(d: ^Dictionary) {
	if d.tree != nil {
		rax.destroy(d.tree)
	}
	for e in d.entries {
		if e.live {
			delete(e.text, d.allocator)
		}
	}
	delete(d.entries)
	delete(d.free)
	d^ = Dictionary{}
}

count :: #force_inline proc "contextless" (d: ^Dictionary) -> int {
	return d.listed
}

size :: #force_inline proc "contextless" (d: ^Dictionary) -> int {
	return d.live
}

is_listed :: proc "contextless" (d: ^Dictionary, id: Id) -> bool {
	return int(id) < len(d.entries) && d.entries[id].live && d.entries[id].listed
}

capacity :: #force_inline proc "contextless" (d: ^Dictionary) -> int {
	return len(d.entries)
}

lookup :: proc "contextless" (d: ^Dictionary, term: string) -> (Id, bool) {
	v, found := rax.find(d.tree, key_bytes(term))
	if !found {
		return NONE, false
	}
	return Id(uintptr(v) - 1), true
}

insert :: proc(d: ^Dictionary, term: string, listed := true) -> (id: Id, inserted: bool, err: Error) {
	if existing, found := lookup(d, term); found {
		return existing, false, .None
	}
	text, e := strings.clone(term, d.allocator)
	if e != nil {
		return NONE, false, .Out_Of_Memory
	}
	if len(d.free) > 0 {
		id = pop(&d.free)
		d.entries[id] = Entry{text = text, live = true, listed = listed}
	} else {
		if len(d.entries) >= ID_LIMIT {
			delete(text, d.allocator)
			return NONE, false, .Too_Many_Terms
		}
		id = Id(len(d.entries))
		if _, ae := append(&d.entries, Entry{text = text, live = true, listed = listed}); ae != nil {
			delete(text, d.allocator)
			return NONE, false, .Out_Of_Memory
		}
	}
	rax.insert(d.tree, key_bytes(text), rawptr(uintptr(id) + 1))
	d.live += 1
	if listed {
		d.listed += 1
	}
	return id, true, .None
}

remove :: proc(d: ^Dictionary, id: Id) -> bool {
	if int(id) >= len(d.entries) || !d.entries[id].live {
		return false
	}
	e := &d.entries[id]
	rax.remove(d.tree, key_bytes(e.text))
	delete(e.text, d.allocator)
	if e.listed {
		d.listed -= 1
	}
	e^ = Entry{}
	append(&d.free, id)
	d.live -= 1
	return true
}

text :: proc "contextless" (d: ^Dictionary, id: Id) -> (string, bool) {
	if int(id) >= len(d.entries) || !d.entries[id].live {
		return "", false
	}
	return d.entries[id].text, true
}

Iterator :: struct {
	tree:    rax.Iterator,
	dict:    ^Dictionary,
	stop:    string,
	bounded: bool,
	open:    bool,
}

iterator_seek :: proc "contextless" (it: ^Iterator, d: ^Dictionary, from: string) {
	rax.start(&it.tree, d.tree)
	rax.seek(&it.tree, ">=", key_bytes(from))
	it.dict = d
	it.bounded = false
	it.open = true
}

iterator_range :: proc "contextless" (it: ^Iterator, d: ^Dictionary, from: string, stop: string) {
	iterator_seek(it, d, from)
	it.stop = stop
	it.bounded = true
}

iterator_next :: proc "contextless" (it: ^Iterator) -> (term: string, id: Id, ok: bool) {
	if !it.open {
		return "", NONE, false
	}
	for rax.next(&it.tree) {
		k := string(rax.key(&it.tree))
		if it.bounded && k >= it.stop {
			return "", NONE, false
		}
		found := Id(uintptr(it.tree.data) - 1)
		if it.dict.entries[found].listed {
			return it.dict.entries[found].text, found, true
		}
	}
	return "", NONE, false
}

iterator_close :: proc "contextless" (it: ^Iterator) {
	if it.open {
		rax.stop(&it.tree)
		it.open = false
	}
}

Match_Proc :: #type proc(ctx: rawptr, d: ^Dictionary, pattern: string, limit: int, out: ^[dynamic]Id) -> (truncated: bool, err: Error)

Matcher :: struct {
	ctx:    rawptr,
	expand: Match_Proc,
}

expand :: proc(m: ^Matcher, d: ^Dictionary, pattern: string, limit: int, out: ^[dynamic]Id) -> (truncated: bool, err: Error) {
	if m == nil || m.expand == nil {
		return false, .None
	}
	return m.expand(m.ctx, d, pattern, limit, out)
}
