package doctable

import "base:runtime"
import "core:strings"
import "../label"
import "../roaring"

PAGE_SHIFT :: 10

PAGE_SIZE :: 1 << PAGE_SHIFT

ID_LIMIT :: max(u32) - 1

DEFAULT_SCORE :: f32(1)

Error :: enum u8 {
	None,
	Out_Of_Memory,
	Ids_Exhausted,
	Not_Found,
}

State :: enum u8 {
	Absent,
	Live,
	Deleted,
}

Doc :: struct {
	key:           string,
	length:        u32,
	max_frequency: u32,
	score:         f32,
	label:         label.Id,
	state:         State,
}

Fields :: struct {
	length:        u32,
	max_frequency: u32,
	score:         f32,
	label:         label.Id,
}

Page :: struct {
	docs:    [PAGE_SIZE]Doc,
	present: u32,
}

Table :: struct {
	pages:     [dynamic]^Page,
	keys:      map[string]u32,
	live:      roaring.Bitmap,
	deleted:   roaring.Bitmap,
	last_id:   u32,
	allocator: runtime.Allocator,
}

Removed_Proc :: #type proc(ctx: rawptr, id: u32, doc: ^Doc)

init :: proc(t: ^Table, allocator := context.allocator) {
	t^ = Table{allocator = allocator}
	t.pages = make([dynamic]^Page, 0, 0, allocator)
	t.keys = make(map[string]u32, 16, allocator)
	roaring.init(&t.live, allocator)
	roaring.init(&t.deleted, allocator)
}

destroy :: proc(t: ^Table) {
	for p in t.pages {
		if p == nil {
			continue
		}
		for &d in p.docs {
			if d.state != .Absent {
				delete(d.key, t.allocator)
			}
		}
		free(p, t.allocator)
	}
	delete(t.pages)
	delete(t.keys)
	roaring.destroy(&t.live)
	roaring.destroy(&t.deleted)
	t^ = Table{}
}

max_id :: #force_inline proc "contextless" (t: ^Table) -> u32 {
	return t.last_id
}

count :: proc "contextless" (t: ^Table) -> int {
	return roaring.cardinality(&t.live)
}

pending :: proc "contextless" (t: ^Table) -> int {
	return roaring.cardinality(&t.deleted)
}

slot :: proc "contextless" (t: ^Table, id: u32) -> ^Doc {
	page := int(id >> PAGE_SHIFT)
	if id == 0 || page >= len(t.pages) || t.pages[page] == nil {
		return nil
	}
	d := &t.pages[page].docs[id & (PAGE_SIZE - 1)]
	if d.state == .Absent {
		return nil
	}
	return d
}

get :: proc "contextless" (t: ^Table, id: u32) -> ^Doc {
	d := slot(t, id)
	if d == nil || d.state != .Live {
		return nil
	}
	return d
}

lookup :: proc(t: ^Table, key: string) -> (u32, bool) {
	id, found := t.keys[key]
	return id, found
}

mark_deleted :: proc(t: ^Table, id: u32) -> Error {
	d := slot(t, id)
	if d == nil || d.state != .Live {
		return .Not_Found
	}
	if _, e := roaring.add(&t.deleted, id); e != .None {
		return .Out_Of_Memory
	}
	if _, e := roaring.remove(&t.live, id); e != .None {
		roaring.remove(&t.deleted, id)
		return .Out_Of_Memory
	}
	d.state = .Deleted
	return .None
}

add :: proc(t: ^Table, key: string, fields: Fields) -> (id: u32, replaced: u32, err: Error) {
	if t.last_id >= ID_LIMIT {
		return 0, 0, .Ids_Exhausted
	}
	id = t.last_id + 1
	page := int(id >> PAGE_SHIFT)
	if page >= len(t.pages) {
		if page + 1 > cap(t.pages) && reserve(&t.pages, max(2 * cap(t.pages), page + 1)) != nil {
			return 0, 0, .Out_Of_Memory
		}
		if resize(&t.pages, page + 1) != nil {
			return 0, 0, .Out_Of_Memory
		}
	}
	if t.pages[page] == nil {
		p, pe := new(Page, t.allocator)
		if pe != nil {
			return 0, 0, .Out_Of_Memory
		}
		t.pages[page] = p
	}
	owned, ce := strings.clone(key, t.allocator)
	if ce != nil {
		return 0, 0, .Out_Of_Memory
	}
	if _, e := roaring.add(&t.live, id); e != .None {
		delete(owned, t.allocator)
		return 0, 0, .Out_Of_Memory
	}
	previous, had := t.keys[key]
	if had {
		if e := mark_deleted(t, previous); e != .None {
			roaring.remove(&t.live, id)
			delete(owned, t.allocator)
			return 0, 0, e
		}
		delete_key(&t.keys, key)
		replaced = previous
	}
	t.keys[owned] = id
	d := &t.pages[page].docs[id & (PAGE_SIZE - 1)]
	d^ = Doc{key = owned, length = fields.length, max_frequency = fields.max_frequency, score = fields.score, label = fields.label, state = .Live}
	t.pages[page].present += 1
	t.last_id = id
	return id, replaced, .None
}

remove :: proc(t: ^Table, key: string) -> (id: u32, err: Error) {
	found: bool
	id, found = t.keys[key]
	if !found {
		return 0, .Not_Found
	}
	mark_deleted(t, id) or_return
	delete_key(&t.keys, key)
	return id, .None
}

rename :: proc(t: ^Table, from, to: string) -> (id: u32, replaced: u32, err: Error) {
	found: bool
	id, found = t.keys[from]
	if !found {
		return 0, 0, .Not_Found
	}
	if from == to {
		return id, 0, .None
	}
	owned, ce := strings.clone(to, t.allocator)
	if ce != nil {
		return 0, 0, .Out_Of_Memory
	}
	if other, had := t.keys[to]; had {
		if e := mark_deleted(t, other); e != .None {
			delete(owned, t.allocator)
			return 0, 0, e
		}
		delete_key(&t.keys, to)
		replaced = other
	}
	d := slot(t, id)
	delete_key(&t.keys, from)
	delete(d.key, t.allocator)
	d.key = owned
	t.keys[owned] = id
	return id, replaced, .None
}

collect :: proc(t: ^Table, removed: Removed_Proc = nil, removed_ctx: rawptr = nil) -> int {
	it: roaring.Iterator
	roaring.iterator_init(&it, &t.deleted)
	n := 0
	for id, ok := roaring.next(&it); ok; id, ok = roaring.next(&it) {
		d := slot(t, id)
		if d == nil {
			continue
		}
		if removed != nil {
			removed(removed_ctx, id, d)
		}
		delete(d.key, t.allocator)
		d^ = Doc{}
		page := int(id >> PAGE_SHIFT)
		p := t.pages[page]
		p.present -= 1
		if p.present == 0 && page != int(t.last_id >> PAGE_SHIFT) {
			free(p, t.allocator)
			t.pages[page] = nil
		}
		n += 1
	}
	roaring.clear(&t.deleted)
	return n
}

frequency_weight :: proc "contextless" (weight: f64) -> u32 {
	if !(weight >= 1) {
		return 1
	}
	if weight >= f64(max(u32)) {
		return max(u32)
	}
	return u32(weight)
}
