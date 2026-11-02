package streamtype

import rx "../rax"
import "base:runtime"

ENTRIES_READ_UNKNOWN :: -1
AUTOCLAIM_MAX_COUNT :: max(i64) / 16
AUTOCLAIM_SCAN_MULTIPLIER :: 10
CLAIM_UNSET :: -1

Group :: struct {
	pending:   ^rx.Rax,
	members:   ^rx.Rax,
	delivered: ID,
	reads:     i64,
}

Member :: struct {
	name:      []u8,
	owned:     ^rx.Rax,
	seen_ms:   i64,
	active_ms: i64,
}

Delivery :: struct {
	owner:   ^Member,
	sent_ms: i64,
	times:   u64,
}

Claim_Flag :: enum u8 {
	Force,
	Ids_Only,
}

Claim_Flags :: bit_set[Claim_Flag;u8]

Claim_Options :: struct {
	raise_to:   ID,
	idle_floor: i64,
	stamp:      i64,
	tries:      i64,
	flags:      Claim_Flags,
}

XGROUP_HELP := [?]string {
	"XGROUP <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"CREATE <key> <groupname> <id|$> [option]",
	"    Create a new consumer group. Options are:",
	"    * MKSTREAM",
	"      Create the empty stream if it does not exist.",
	"    * ENTRIESREAD entries_read",
	"      Set the group's entries_read counter (internal use).",
	"CREATECONSUMER <key> <groupname> <consumer>",
	"    Create a new consumer in the specified group.",
	"DELCONSUMER <key> <groupname> <consumer>",
	"    Remove the specified consumer.",
	"DESTROY <key> <groupname>",
	"    Remove the specified group.",
	"SETID <key> <groupname> <id|$> [ENTRIESREAD entries_read]",
	"    Set the current group ID and entries_read counter.",
	"HELP",
	"    Print this help.",
}

XGROUP_CREATE_MAX_ARGS :: 8

Nogroup_Form :: enum u8 {
	For_Key_Name,
	Key_Or_Group,
	Xreadgroup,
}

append_nogroup_error :: proc(buf: ^[dynamic]u8, form: Nogroup_Form, key: []u8, group: []u8) {
	switch form {
	case .For_Key_Name:
		append(buf, "NOGROUP No such consumer group '")
		append(buf, ..group)
		append(buf, "' for key name '")
		append(buf, ..key)
		append(buf, "'")
	case .Key_Or_Group, .Xreadgroup:
		append(buf, "NOGROUP No such key '")
		append(buf, ..key)
		append(buf, "' or consumer group '")
		append(buf, ..group)
		append(buf, "'")
		if form == .Xreadgroup {
			append(buf, " in XREADGROUP with GROUP option")
		}
	}
}

append_claim_option_error :: proc(buf: ^[dynamic]u8, opt: []u8) {
	append(buf, "ERR Unrecognized XCLAIM option '")
	append(buf, ..opt)
	append(buf, "'")
}

Claim_Result :: enum u8 {
	Skipped,
	Claimed,
	Deleted,
}

@(private)
group_alloc :: proc "contextless" (s: Stream, size: int) -> rawptr {
	p := runtime.heap_alloc(size, true)
	if p == nil {
		out_of_memory()
	}
	s.group_bytes += usable(p)
	return p
}

@(private)
group_release :: proc "contextless" (s: Stream, p: rawptr) {
	if p == nil {
		return
	}
	s.group_bytes -= usable(p)
	runtime.heap_free(p)
}

@(private)
id_key :: #force_inline proc "contextless" (id: ID) -> (key: [16]u8) {
	encode_id(&key, id)
	return
}

find_group :: proc "contextless" (s: Stream, name: []u8) -> ^Group {
	if s == nil || s.groups == nil {
		return nil
	}
	v, found := rx.find(s.groups, name)
	if !found {
		return nil
	}
	return (^Group)(v)
}

add_group :: proc "contextless" (s: Stream, name: []u8, id: ID, entries_read: i64) -> ^Group {
	if s.groups == nil {
		s.groups = rx.create(&s.group_bytes)
	}
	if _, found := rx.find(s.groups, name); found {
		return nil
	}
	g := (^Group)(group_alloc(s, size_of(Group)))
	g.delivered = id
	g.reads = entries_read
	g.pending = rx.create(&s.group_bytes)
	g.members = rx.create(&s.group_bytes)
	rx.insert(s.groups, name, g)
	return g
}

@(private)
release_member :: proc "contextless" (s: Stream, m: ^Member) {
	rx.destroy(m.owned)
	group_release(s, m)
}

@(private)
release_group :: proc "contextless" (s: Stream, g: ^Group) {
	it: rx.Iterator
	rx.start(&it, g.pending)
	rx.seek(&it, "^")
	for rx.next(&it) {
		group_release(s, it.data)
	}
	rx.stop(&it)
	rx.destroy(g.pending)
	rx.start(&it, g.members)
	rx.seek(&it, "^")
	for rx.next(&it) {
		release_member(s, (^Member)(it.data))
	}
	rx.stop(&it)
	rx.destroy(g.members)
	group_release(s, g)
}

drop_group :: proc "contextless" (s: Stream, name: []u8) -> bool {
	if s.groups == nil {
		return false
	}
	old: rawptr
	if !rx.remove(s.groups, name, &old) {
		return false
	}
	release_group(s, (^Group)(old))
	return true
}

free_groups :: proc "contextless" (s: Stream) {
	if s == nil || s.groups == nil {
		return
	}
	it: rx.Iterator
	rx.start(&it, s.groups)
	rx.seek(&it, "^")
	for rx.next(&it) {
		release_group(s, (^Group)(it.data))
	}
	rx.stop(&it)
	rx.destroy(s.groups)
	s.groups = nil
}

find_member :: proc "contextless" (g: ^Group, name: []u8) -> ^Member {
	if g == nil {
		return nil
	}
	v, found := rx.find(g.members, name)
	if !found {
		return nil
	}
	return (^Member)(v)
}

add_member :: proc "contextless" (s: Stream, g: ^Group, name: []u8, now: i64) -> ^Member {
	if _, found := rx.find(g.members, name); found {
		return nil
	}
	p := group_alloc(s, size_of(Member) + len(name))
	m := (^Member)(p)
	text := ([^]u8)(uintptr(p) + size_of(Member))
	for i in 0 ..< len(name) {
		text[i] = name[i]
	}
	m.name = text[:len(name)]
	m.seen_ms = now
	m.active_ms = -1
	m.owned = rx.create(&s.group_bytes)
	rx.insert(g.members, m.name, m)
	return m
}

member_for :: proc "contextless" (s: Stream, g: ^Group, name: []u8, now: i64) -> (m: ^Member, created: bool) {
	m = find_member(g, name)
	if m != nil {
		return m, false
	}
	return add_member(s, g, name, now), true
}

drop_member :: proc "contextless" (s: Stream, g: ^Group, m: ^Member) -> u64 {
	dropped := m.owned.numele
	it: rx.Iterator
	rx.start(&it, m.owned)
	rx.seek(&it, "^")
	for rx.next(&it) {
		old: rawptr
		if rx.remove(g.pending, rx.key(&it), &old) {
			group_release(s, old)
		}
	}
	rx.stop(&it)
	rx.remove(g.members, m.name)
	release_member(s, m)
	return dropped
}

new_delivery :: proc "contextless" (s: Stream, owner: ^Member, now: i64) -> ^Delivery {
	d := (^Delivery)(group_alloc(s, size_of(Delivery)))
	d.sent_ms = now
	d.times = 1
	d.owner = owner
	return d
}

find_delivery :: proc "contextless" (g: ^Group, id: ID) -> ^Delivery {
	key := id_key(id)
	v, found := rx.find(g.pending, key[:])
	if !found {
		return nil
	}
	return (^Delivery)(v)
}

@(private)
hand_over :: proc "contextless" (d: ^Delivery, key: []u8, to: ^Member) {
	if d.owner == to {
		return
	}
	if d.owner != nil {
		rx.remove(d.owner.owned, key)
	}
	rx.insert(to.owned, key, d)
	d.owner = to
}

@(private)
forget_delivery :: proc "contextless" (s: Stream, g: ^Group, d: ^Delivery, key: []u8) {
	if d.owner != nil {
		rx.remove(d.owner.owned, key)
	}
	rx.remove(g.pending, key)
	group_release(s, d)
}

ack :: proc "contextless" (s: Stream, g: ^Group, id: ID) -> bool {
	key := id_key(id)
	v, found := rx.find(g.pending, key[:])
	if !found {
		return false
	}
	forget_delivery(s, g, (^Delivery)(v), key[:])
	return true
}

@(private)
holes_after :: #force_inline proc "contextless" (s: Stream, id: ID) -> bool {
	lo := id
	return may_hold_tombstones(s, &lo, nil)
}

@(private)
Id_Place :: enum u8 {
	Before_Head,
	At_Head,
	Inside,
	At_Top,
	Past_Top,
}

@(private)
place_of :: proc "contextless" (s: Stream, id: ID) -> Id_Place {
	switch compare_id(id, s.top) {
	case 0:
		return .At_Top
	case 1:
		return .Past_Top
	}
	switch compare_id(id, s.head) {
	case -1:
		return .Before_Head
	case 0:
		return .At_Head
	}
	return .Inside
}

added_through :: proc "contextless" (s: Stream, id: ID) -> (reached: i64, known: bool) {
	if s.added == 0 {
		return 0, true
	}
	place := place_of(s, id)
	switch place {
	case .At_Top:
		if s.live > 0 && !id_is_zero(s.tomb) && compare_id(s.tomb, s.top) > 0 {
			return 0, false
		}
		reached = i64(s.added)
	case .Before_Head, .At_Head:
		if holes_after(s, s.head) {
			return 0, false
		}
		reached = i64(s.added - s.live)
		if place == .At_Head {
			reached += 1
		}
	case .Inside, .Past_Top:
		return 0, false
	}
	return reached, reached != ENTRIES_READ_UNKNOWN
}

@(private)
exact_reads :: #force_inline proc "contextless" (s: Stream, g: ^Group) -> (i64, bool) {
	if g.reads == ENTRIES_READ_UNKNOWN || holes_after(s, g.delivered) {
		return 0, false
	}
	return g.reads, true
}

group_lag :: proc "contextless" (s: Stream, g: ^Group) -> (lag: i64, known: bool) {
	if s.added == 0 || s.live == 0 {
		return 0, true
	}
	if compare_id(g.delivered, s.head) < 0 && !holes_after(s, s.head) {
		return i64(s.live), true
	}
	if reads, exact := exact_reads(s, g); exact {
		return i64(s.added) - reads, true
	}
	reached, found := added_through(s, g.delivered)
	if !found {
		return 0, false
	}
	return i64(s.added) - reached, true
}

@(private)
note_delivery :: proc "contextless" (s: Stream, g: ^Group, id: ID) {
	if compare_id(g.delivered, s.head) >= 0 {
		if _, exact := exact_reads(s, g); exact {
			g.reads += 1
			return
		}
	}
	reached, known := added_through(s, id)
	g.reads = reached if known else ENTRIES_READ_UNKNOWN
}

group_deliver :: proc "contextless" (s: Stream, g: ^Group, member: ^Member, id: ID, noack: bool, now: i64) {
	if compare_id(id, g.delivered) > 0 {
		note_delivery(s, g, id)
		g.delivered = id
	}
	if noack || member == nil {
		return
	}
	key := id_key(id)
	v, found := rx.find(g.pending, key[:])
	d: ^Delivery
	if found {
		d = (^Delivery)(v)
		d.sent_ms = now
		d.times = 1
	} else {
		d = new_delivery(s, nil, now)
		rx.insert(g.pending, key[:], d)
	}
	hand_over(d, key[:], member)
	member.active_ms = now
}

pel_history :: proc(m: ^Member, start: ID, count: int, out: ^[dynamic]ID) {
	key := id_key(start)
	it: rx.Iterator
	rx.start(&it, m.owned)
	rx.seek(&it, ">=", key[:])
	for (count <= 0 || len(out) < count) && rx.next(&it) {
		append(out, decode_id(rx.key(&it)))
	}
	rx.stop(&it)
}

pel_touch :: proc "contextless" (m: ^Member, id: ID, now: i64) {
	key := id_key(id)
	v, found := rx.find(m.owned, key[:])
	if !found {
		return
	}
	d := (^Delivery)(v)
	d.sent_ms = now
	d.times += 1
}

group_set_id :: proc "contextless" (g: ^Group, id: ID, entries_read: i64) {
	g.delivered = id
	g.reads = entries_read
}

group_raise_last_id :: proc "contextless" (g: ^Group, id: ID) -> bool {
	if compare_id(id, g.delivered) > 0 {
		g.delivered = id
		return true
	}
	return false
}

claim_entry :: proc(s: Stream, g: ^Group, member: ^Member, id: ID, a: ^Claim_Options, now: i64) -> Claim_Result {
	key := id_key(id)
	v, found := rx.find(g.pending, key[:])
	d := (^Delivery)(v)
	forced := false
	if !found {
		if .Force not_in a.flags || !entry_exists(s, id) {
			return .Skipped
		}
		d = new_delivery(s, nil, now)
		rx.insert(g.pending, key[:], d)
		forced = true
	} else if !entry_exists(s, id) {
		forget_delivery(s, g, d, key[:])
		return .Deleted
	}
	if !forced && a.idle_floor > 0 {
		idle := now - d.sent_ms
		if idle < a.idle_floor {
			return .Skipped
		}
	}
	when_ms := now
	if a.stamp != CLAIM_UNSET {
		when_ms = min(a.stamp, now)
	}
	d.sent_ms = when_ms
	if a.tries >= 0 {
		d.times = u64(a.tries)
	} else if .Ids_Only not_in a.flags {
		d.times += 1
	}
	hand_over(d, key[:], member)
	member.active_ms = now
	return .Claimed
}

Autoclaim_Step :: struct {
	id:     ID,
	result: Claim_Result,
}

autoclaim_scan :: proc(s: Stream, g: ^Group, member: ^Member, a: ^Autoclaim_Args, now: i64, out: ^[dynamic]Autoclaim_Step) -> (next: ID) {
	attempts := a.count * AUTOCLAIM_SCAN_MULTIPLIER
	budget := a.count
	start := id_key(a.start)
	it: rx.Iterator
	rx.start(&it, g.pending)
	rx.seek(&it, ">=", start[:])
	more := rx.next(&it)
	for more && attempts > 0 && budget > 0 {
		attempts -= 1
		id := decode_id(rx.key(&it))
		d := (^Delivery)(it.data)
		if !entry_exists(s, id) {
			key := id_key(id)
			forget_delivery(s, g, d, key[:])
			append(out, Autoclaim_Step{id, .Deleted})
			budget -= 1
			more = rx.next(&it)
			continue
		}
		if a.minidle > 0 && now - d.sent_ms < a.minidle {
			more = rx.next(&it)
			continue
		}
		key := id_key(id)
		d.sent_ms = now
		if !a.justid {
			d.times += 1
		}
		hand_over(d, key[:], member)
		member.active_ms = now
		append(out, Autoclaim_Step{id, .Claimed})
		budget -= 1
		more = rx.next(&it)
	}
	if more {
		next = decode_id(rx.key(&it))
	}
	rx.stop(&it)
	return
}

claim :: proc(s: Stream, g: ^Group, name: []u8, a: ^Claim_Options, ids: []ID, now: i64, claimed: ^[dynamic]ID) {
	member, _ := member_for(s, g, name, now)
	member.seen_ms = now
	group_raise_last_id(g, a.raise_to)
	for id in ids {
		if claim_entry(s, g, member, id, a, now) == .Claimed {
			append(claimed, id)
		}
	}
}

autoclaim :: proc(s: Stream, g: ^Group, name: []u8, minidle: i64, start: ID, count: i64, justid: bool, now: i64, claimed: ^[dynamic]ID, deleted: ^[dynamic]ID) -> ID {
	member, _ := member_for(s, g, name, now)
	member.seen_ms = now
	a := Autoclaim_Args{minidle = minidle, start = start, count = count, justid = justid}
	steps: [dynamic]Autoclaim_Step
	defer delete(steps)
	next := autoclaim_scan(s, g, member, &a, now, &steps)
	for step in steps {
		if step.result == .Claimed {
			append(claimed, step.id)
		} else {
			append(deleted, step.id)
		}
	}
	return next
}

pel_first_last :: proc "contextless" (r: ^rx.Rax) -> (first: ID, last: ID, ok: bool) {
	if r == nil || r.numele == 0 {
		return
	}
	it: rx.Iterator
	rx.start(&it, r)
	rx.seek(&it, "^")
	if rx.next(&it) {
		first = decode_id(rx.key(&it))
	}
	rx.seek(&it, "$")
	if rx.next(&it) {
		last = decode_id(rx.key(&it))
	}
	rx.stop(&it)
	return first, last, true
}

@(private)
copy_group :: proc "contextless" (into: Stream, name: []u8, src: ^Group) {
	dst := add_group(into, name, src.delivered, src.reads)
	mw: rx.Iterator
	rx.start(&mw, src.members)
	rx.seek(&mw, "^")
	for rx.next(&mw) {
		m := (^Member)(mw.data)
		twin := add_member(into, dst, m.name, m.seen_ms)
		twin.active_ms = m.active_ms
	}
	rx.stop(&mw)
	pw: rx.Iterator
	rx.start(&pw, src.pending)
	rx.seek(&pw, "^")
	for rx.next(&pw) {
		d := (^Delivery)(pw.data)
		owner: ^Member
		if d.owner != nil {
			owner = find_member(dst, d.owner.name)
		}
		twin := new_delivery(into, owner, d.sent_ms)
		twin.times = d.times
		rx.insert(dst.pending, rx.key(&pw), twin)
		if owner != nil {
			rx.insert(owner.owned, rx.key(&pw), twin)
		}
	}
	rx.stop(&pw)
}

copy_groups :: proc "contextless" (from: Stream, into: Stream) {
	if from.groups == nil {
		return
	}
	gw: rx.Iterator
	rx.start(&gw, from.groups)
	rx.seek(&gw, "^")
	for rx.next(&gw) {
		copy_group(into, rx.key(&gw), (^Group)(gw.data))
	}
	rx.stop(&gw)
}
