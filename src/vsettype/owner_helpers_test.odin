package vsettype

import "core:fmt"
import "core:testing"
import lbl "../label"
import "../rax"
import "../vmath"

check_owners :: proc(t: ^testing.T, s: Vset) -> int {
	idx := s.lab.owners
	ok := true
	fail :: proc(t: ^testing.T, ok: ^bool, text: string) {
		testing.expect(t, false, text)
		ok^ = false
	}
	if idx.index.bytes != usable_size(idx) + usable_size(idx.parts) + usable_size(idx.free) + usable_size(idx.slots) {
		fail(t, &ok, fmt.tprintf("owner index charge %d does not match its tables", idx.index.bytes))
	}
	if idx.slot_len == 0 {
		fail(t, &ok, "an owner index is kept without owners")
	}
	if idx.slot_len * 4 > idx.slot_cap * 3 || idx.slot_cap & (idx.slot_cap - 1) != 0 {
		fail(t, &ok, fmt.tprintf("owner table holds %d in %d slots", idx.slot_len, idx.slot_cap))
	}
	scopes := 0
	owned := 0
	ledger := 0
	raxes := 0
	parts_seen := 0
	for i in 0 ..< idx.slot_cap {
		sl := idx.slots[i]
		if sl.owner == SHARED {
			continue
		}
		scopes += 1
		scope := sl.scope
		if scope.owner != sl.owner || owner_scope(s, sl.owner) != scope {
			fail(t, &ok, fmt.tprintf("owner %d is not found through its slot", sl.owner))
			continue
		}
		if scope.part_len == 0 {
			fail(t, &ok, fmt.tprintf("owner %d is kept without partitions", sl.owner))
		}
		ledger += usable_size(scope) + scope.charge.bytes
		raxes += rax.memory(scope.names)
		charged := usable_size(scope.parts) + usable_size(scope.multis)
		for m in 0 ..< scope.multi_len {
			charged += usable_size(scope.multis[m])
		}
		if charged != scope.charge.bytes {
			fail(t, &ok, fmt.tprintf("owner %d charge %d against %d", sl.owner, scope.charge.bytes, charged))
		}
		held := 0
		for j in 0 ..< scope.part_len {
			p := scope.parts[j]
			parts_seen += 1
			if j > 0 && scope.parts[j - 1].label >= p.label {
				fail(t, &ok, fmt.tprintf("owner %d partitions out of order", sl.owner))
			}
			if p.owner != sl.owner || p.id < OWNER_PART_BASE || owner_part_by_id(idx, p.id) != p || p.count == 0 {
				fail(t, &ok, fmt.tprintf("owner %d partition %d is not registered", sl.owner, p.id))
				continue
			}
			if p.kind == .Core {
				fail(t, &ok, fmt.tprintf("owner %d partition %d has the core kind", sl.owner, p.id))
			}
			if c := part_charge(s, p); c == nil || c.root != &idx.ledger || c.bytes != part_block_bytes(p) {
				fail(t, &ok, fmt.tprintf("owner %d partition %d charge is off", sl.owner, p.id))
			} else {
				ledger += usable_size(p) + c.bytes
			}
			if !check_partition(t, s, p) {
				ok = false
			}
			held += p.count
		}
		owned += held
		copies := 0
		multis := 0
		it: rax.Iterator
		rax.start(&it, scope.names)
		rax.seek(&it, "^")
		for rax.next(&it) {
			key := rax.key(&it)
			one: Ref
			list := name_decode(it.data, &one)
			if u64(uintptr(it.data)) & NAME_MULTI != 0 {
				multis += 1
				c := (^Copies)(uintptr(u64(uintptr(it.data)) &~ NAME_MULTI))
				if c.count < 2 || c.index >= scope.multi_len || scope.multis[c.index] != c {
					fail(t, &ok, "owner copies block not registered")
				}
			}
			for r, k in list {
				copies += 1
				p := part_by_id(s, r.part)
				if p == nil || p.owner != sl.owner || int(r.slot) >= int(p.arena.high) || !vmath.arena_is_live(&p.arena, r.slot) {
					fail(t, &ok, fmt.tprintf("owner %d name %q refers to a dead or foreign copy", sl.owner, string(key)))
					continue
				}
				if string(part_element_name(p, r.slot)) != string(key) {
					fail(t, &ok, fmt.tprintf("owner %d name %q refers to element %q", sl.owner, string(key), string(part_element_name(p, r.slot))))
				}
				for q in list[:k] {
					if ref_label(s, q) == p.label {
						fail(t, &ok, fmt.tprintf("owner %d name %q has two copies at label %d", sl.owner, string(key), p.label))
					}
				}
			}
		}
		rax.stop(&it)
		if multis != int(scope.multi_len) || copies != held {
			fail(t, &ok, fmt.tprintf("owner %d names %d copies %d multis against %d held %d registered", sl.owner, copies, multis, held, scope.multi_len))
		}
	}
	if scopes != int(idx.slot_len) {
		fail(t, &ok, fmt.tprintf("%d owner slots used, %d recorded", scopes, idx.slot_len))
	}
	live := 0
	for local in 0 ..< idx.part_high {
		if idx.parts[local] != nil {
			live += 1
		}
	}
	if live != parts_seen || int(idx.free_len) != int(idx.part_high) - live || idx.free_cap < idx.part_high {
		fail(t, &ok, fmt.tprintf("owner partition table holds %d live of %d with %d free, scopes list %d", live, idx.part_high, idx.free_len, parts_seen))
	}
	for f in 0 ..< idx.free_len {
		if idx.parts[idx.free[f]] != nil {
			fail(t, &ok, "a free owner partition id is in use")
		}
	}
	if ledger != idx.ledger.bytes {
		fail(t, &ok, fmt.tprintf("owner ledger %d against %d", idx.ledger.bytes, ledger))
	}
	if raxes != idx.rax_bytes {
		fail(t, &ok, fmt.tprintf("owner name indexes %d against %d", idx.rax_bytes, raxes))
	}
	parts := shared_bytes(s) + index_bytes(s)
	for i in 0 ..< s.lab.sorted_len {
		parts += part_footprint(s, s.lab.sorted[i])
	}
	for i in 0 ..< idx.slot_cap {
		if sl := idx.slots[i]; sl.owner != SHARED {
			parts += owner_memory(s, sl.owner)
		}
	}
	if parts != memory_usage(s) {
		fail(t, &ok, fmt.tprintf("memory %d does not split into shared, owners and index %d", memory_usage(s), parts))
	}
	return owned if ok else -1
}

check_set :: proc(t: ^testing.T, s: Vset) -> bool {
	if s == nil {
		return true
	}
	if s.lab == nil {
		return check_invariants(t, s)
	}
	return check_labelled(t, s)
}

Owner_Lattice :: struct {
	using lattice: Lattice,
	streams:       [8][8]u64,
}

owner_access :: proc(l: ^Owner_Lattice, i: int, o: Owner, top := false) -> Access {
	a := lattice_access(&l.lattice, i)
	a.owner = o
	a.top = top
	if o != SHARED {
		a.stream = &l.streams[i][int(o) % 8]
	}
	return a
}

owner_lattice_init :: proc(l: ^Owner_Lattice, labels: []lbl.Label) {
	lattice_init(&l.lattice, labels)
	for i in 0 ..< 8 {
		for j in 0 ..< 8 {
			l.streams[i][j] = stream_seed(lbl.Id(i)) ~ (u64(j + 1) * 0x9E3779B97F4A7C15)
		}
	}
}
