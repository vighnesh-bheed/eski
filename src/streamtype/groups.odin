package streamtype

import rx "../rax"
import "base:runtime"

ENTRIES_READ_UNKNOWN :: -1
AUTOCLAIM_MAX_COUNT :: max(i64) / 16
AUTOCLAIM_ATTEMPTS_FACTOR :: 10

CG :: struct {
	last_id:      ID,
	entries_read: i64,
	pel:          ^rx.Rax,
	consumers:    ^rx.Rax,
}

Consumer :: struct {
	seen_time:   i64,
	active_time: i64,
	name:        []u8,
	pel:         ^rx.Rax,
}

NACK :: struct {
	delivery_time:  i64,
	delivery_count: u64,
	consumer:       ^Consumer,
}

Claim_Args :: struct {
	minidle:      i64,
	force:        bool,
	justid:       bool,
	retrycount:   i64,
	deliverytime: i64,
	last_id:      ID,
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
cg_alloc :: proc "contextless" (s: Stream, size: int) -> rawptr {
	p := runtime.heap_alloc(size, true)
	if p == nil {
		out_of_memory()
	}
	s.cg_mem += usable(p)
	return p
}

@(private)
cg_release :: proc "contextless" (s: Stream, p: rawptr) {
	if p == nil {
		return
	}
	s.cg_mem -= usable(p)
	runtime.heap_free(p)
}

@(private)
id_key :: #force_inline proc "contextless" (id: ID) -> (key: [16]u8) {
	encode_id(&key, id)
	return
}

lookup_cg :: proc "contextless" (s: Stream, name: []u8) -> ^CG {
	if s == nil || s.cgroups == nil {
		return nil
	}
	v, found := rx.find(s.cgroups, name)
	if !found {
		return nil
	}
	return (^CG)(v)
}

create_cg :: proc "contextless" (s: Stream, name: []u8, id: ID, entries_read: i64) -> ^CG {
	if s.cgroups == nil {
		s.cgroups = rx.create(&s.cg_mem)
	}
	if _, found := rx.find(s.cgroups, name); found {
		return nil
	}
	cg := (^CG)(cg_alloc(s, size_of(CG)))
	cg.last_id = id
	cg.entries_read = entries_read
	cg.pel = rx.create(&s.cg_mem)
	cg.consumers = rx.create(&s.cg_mem)
	rx.insert(s.cgroups, name, cg)
	return cg
}

@(private)
free_consumer :: proc "contextless" (s: Stream, c: ^Consumer) {
	rx.destroy(c.pel)
	cg_release(s, c)
}

@(private)
free_cg :: proc "contextless" (s: Stream, cg: ^CG) {
	it: rx.Iterator
	rx.start(&it, cg.pel)
	rx.seek(&it, "^")
	for rx.next(&it) {
		cg_release(s, it.data)
	}
	rx.stop(&it)
	rx.destroy(cg.pel)
	rx.start(&it, cg.consumers)
	rx.seek(&it, "^")
	for rx.next(&it) {
		free_consumer(s, (^Consumer)(it.data))
	}
	rx.stop(&it)
	rx.destroy(cg.consumers)
	cg_release(s, cg)
}

destroy_cg :: proc "contextless" (s: Stream, name: []u8) -> bool {
	if s.cgroups == nil {
		return false
	}
	old: rawptr
	if !rx.remove(s.cgroups, name, &old) {
		return false
	}
	free_cg(s, (^CG)(old))
	return true
}

free_groups :: proc "contextless" (s: Stream) {
	if s == nil || s.cgroups == nil {
		return
	}
	it: rx.Iterator
	rx.start(&it, s.cgroups)
	rx.seek(&it, "^")
	for rx.next(&it) {
		free_cg(s, (^CG)(it.data))
	}
	rx.stop(&it)
	rx.destroy(s.cgroups)
	s.cgroups = nil
}

lookup_consumer :: proc "contextless" (cg: ^CG, name: []u8) -> ^Consumer {
	if cg == nil {
		return nil
	}
	v, found := rx.find(cg.consumers, name)
	if !found {
		return nil
	}
	return (^Consumer)(v)
}

create_consumer :: proc "contextless" (s: Stream, cg: ^CG, name: []u8, now: i64) -> ^Consumer {
	if _, found := rx.find(cg.consumers, name); found {
		return nil
	}
	p := cg_alloc(s, size_of(Consumer) + len(name))
	c := (^Consumer)(p)
	text := ([^]u8)(uintptr(p) + size_of(Consumer))
	for i in 0 ..< len(name) {
		text[i] = name[i]
	}
	c.name = text[:len(name)]
	c.seen_time = now
	c.active_time = -1
	c.pel = rx.create(&s.cg_mem)
	rx.insert(cg.consumers, c.name, c)
	return c
}

lookup_or_create_consumer :: proc "contextless" (s: Stream, cg: ^CG, name: []u8, now: i64) -> (c: ^Consumer, created: bool) {
	c = lookup_consumer(cg, name)
	if c != nil {
		return c, false
	}
	return create_consumer(s, cg, name, now), true
}

del_consumer :: proc "contextless" (s: Stream, cg: ^CG, c: ^Consumer) -> u64 {
	dropped := c.pel.numele
	it: rx.Iterator
	rx.start(&it, c.pel)
	rx.seek(&it, "^")
	for rx.next(&it) {
		old: rawptr
		if rx.remove(cg.pel, rx.key(&it), &old) {
			cg_release(s, old)
		}
	}
	rx.stop(&it)
	rx.remove(cg.consumers, c.name)
	free_consumer(s, c)
	return dropped
}

create_nack :: proc "contextless" (s: Stream, consumer: ^Consumer, now: i64) -> ^NACK {
	n := (^NACK)(cg_alloc(s, size_of(NACK)))
	n.delivery_time = now
	n.delivery_count = 1
	n.consumer = consumer
	return n
}

lookup_nack :: proc "contextless" (cg: ^CG, id: ID) -> ^NACK {
	key := id_key(id)
	v, found := rx.find(cg.pel, key[:])
	if !found {
		return nil
	}
	return (^NACK)(v)
}

@(private)
nack_assign :: proc "contextless" (nack: ^NACK, key: []u8, to: ^Consumer) {
	if nack.consumer == to {
		return
	}
	if nack.consumer != nil {
		rx.remove(nack.consumer.pel, key)
	}
	rx.insert(to.pel, key, nack)
	nack.consumer = to
}

@(private)
nack_drop :: proc "contextless" (s: Stream, cg: ^CG, nack: ^NACK, key: []u8) {
	if nack.consumer != nil {
		rx.remove(nack.consumer.pel, key)
	}
	rx.remove(cg.pel, key)
	cg_release(s, nack)
}

ack :: proc "contextless" (s: Stream, cg: ^CG, id: ID) -> bool {
	key := id_key(id)
	v, found := rx.find(cg.pel, key[:])
	if !found {
		return false
	}
	nack_drop(s, cg, (^NACK)(v), key[:])
	return true
}

@(private)
tombstones_from :: #force_inline proc "contextless" (s: Stream, id: ID) -> bool {
	lo := id
	return range_has_tombstones(s, &lo, nil)
}

cg_lag :: proc "contextless" (s: Stream, cg: ^CG) -> (lag: i64, valid: bool) {
	if s.entries_added == 0 || s.length == 0 {
		return 0, true
	}
	if compare_id(cg.last_id, s.first_id) < 0 && !tombstones_from(s, s.first_id) {
		return i64(s.length), true
	}
	if cg.entries_read != ENTRIES_READ_UNKNOWN && !tombstones_from(s, cg.last_id) {
		return i64(s.entries_added) - cg.entries_read, true
	}
	estimate := estimate_distance(s, cg.last_id)
	if estimate == ENTRIES_READ_UNKNOWN {
		return 0, false
	}
	return i64(s.entries_added) - estimate, true
}

estimate_distance :: proc "contextless" (s: Stream, id: ID) -> i64 {
	if s.entries_added == 0 {
		return 0
	}
	switch compare_id(id, s.last_id) {
	case 0:
		if s.length > 0 && !id_is_zero(s.max_deleted_entry_id) && compare_id(s.max_deleted_entry_id, s.last_id) > 0 {
			return ENTRIES_READ_UNKNOWN
		}
		return i64(s.entries_added)
	case 1:
		return ENTRIES_READ_UNKNOWN
	}
	if tombstones_from(s, s.first_id) {
		return ENTRIES_READ_UNKNOWN
	}
	switch compare_id(id, s.first_id) {
	case -1:
		return i64(s.entries_added - s.length)
	case 0:
		return i64(s.entries_added - s.length) + 1
	}
	return ENTRIES_READ_UNKNOWN
}

@(private)
advance_entries_read :: proc "contextless" (s: Stream, cg: ^CG, id: ID) {
	if compare_id(cg.last_id, s.first_id) >= 0 && cg.entries_read != ENTRIES_READ_UNKNOWN && !tombstones_from(s, cg.last_id) {
		cg.entries_read += 1
		return
	}
	cg.entries_read = estimate_distance(s, id)
}

group_deliver :: proc "contextless" (s: Stream, cg: ^CG, consumer: ^Consumer, id: ID, noack: bool, now: i64) {
	if compare_id(id, cg.last_id) > 0 {
		advance_entries_read(s, cg, id)
		cg.last_id = id
	}
	if noack || consumer == nil {
		return
	}
	key := id_key(id)
	v, found := rx.find(cg.pel, key[:])
	nack: ^NACK
	if found {
		nack = (^NACK)(v)
		nack.delivery_time = now
		nack.delivery_count = 1
	} else {
		nack = create_nack(s, nil, now)
		rx.insert(cg.pel, key[:], nack)
	}
	nack_assign(nack, key[:], consumer)
	consumer.active_time = now
}

pel_history :: proc(c: ^Consumer, start: ID, count: int, out: ^[dynamic]ID) {
	key := id_key(start)
	it: rx.Iterator
	rx.start(&it, c.pel)
	rx.seek(&it, ">=", key[:])
	for (count <= 0 || len(out) < count) && rx.next(&it) {
		append(out, decode_id(rx.key(&it)))
	}
	rx.stop(&it)
}

pel_touch :: proc "contextless" (c: ^Consumer, id: ID, now: i64) {
	key := id_key(id)
	v, found := rx.find(c.pel, key[:])
	if !found {
		return
	}
	nack := (^NACK)(v)
	nack.delivery_time = now
	nack.delivery_count += 1
}

group_set_id :: proc "contextless" (cg: ^CG, id: ID, entries_read: i64) {
	cg.last_id = id
	cg.entries_read = entries_read
}

group_raise_last_id :: proc "contextless" (cg: ^CG, id: ID) -> bool {
	if compare_id(id, cg.last_id) > 0 {
		cg.last_id = id
		return true
	}
	return false
}

claim_entry :: proc(s: Stream, cg: ^CG, consumer: ^Consumer, id: ID, a: ^Claim_Args, now: i64) -> Claim_Result {
	key := id_key(id)
	v, found := rx.find(cg.pel, key[:])
	nack := (^NACK)(v)
	forced := false
	if !found {
		if !a.force || !entry_exists(s, id) {
			return .Skipped
		}
		nack = create_nack(s, nil, now)
		rx.insert(cg.pel, key[:], nack)
		forced = true
	} else if !entry_exists(s, id) {
		nack_drop(s, cg, nack, key[:])
		return .Deleted
	}
	if !forced && a.minidle > 0 {
		idle := now - nack.delivery_time
		if idle < a.minidle {
			return .Skipped
		}
	}
	when_ms := now
	if a.deliverytime != -1 {
		when_ms = min(a.deliverytime, now)
	}
	nack.delivery_time = when_ms
	if a.retrycount >= 0 {
		nack.delivery_count = u64(a.retrycount)
	} else if !a.justid {
		nack.delivery_count += 1
	}
	nack_assign(nack, key[:], consumer)
	consumer.active_time = now
	return .Claimed
}

Autoclaim_Step :: struct {
	id:     ID,
	result: Claim_Result,
}

autoclaim_scan :: proc(s: Stream, cg: ^CG, consumer: ^Consumer, a: ^Autoclaim_Args, now: i64, out: ^[dynamic]Autoclaim_Step) -> (next: ID) {
	attempts := a.count * AUTOCLAIM_ATTEMPTS_FACTOR
	budget := a.count
	start := id_key(a.start)
	it: rx.Iterator
	rx.start(&it, cg.pel)
	rx.seek(&it, ">=", start[:])
	more := rx.next(&it)
	for more && attempts > 0 && budget > 0 {
		attempts -= 1
		id := decode_id(rx.key(&it))
		nack := (^NACK)(it.data)
		if !entry_exists(s, id) {
			key := id_key(id)
			nack_drop(s, cg, nack, key[:])
			append(out, Autoclaim_Step{id, .Deleted})
			budget -= 1
			more = rx.next(&it)
			continue
		}
		if a.minidle > 0 && now - nack.delivery_time < a.minidle {
			more = rx.next(&it)
			continue
		}
		key := id_key(id)
		nack.delivery_time = now
		if !a.justid {
			nack.delivery_count += 1
		}
		nack_assign(nack, key[:], consumer)
		consumer.active_time = now
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

claim :: proc(s: Stream, cg: ^CG, name: []u8, a: ^Claim_Args, ids: []ID, now: i64, claimed: ^[dynamic]ID) {
	consumer, _ := lookup_or_create_consumer(s, cg, name, now)
	consumer.seen_time = now
	group_raise_last_id(cg, a.last_id)
	for id in ids {
		if claim_entry(s, cg, consumer, id, a, now) == .Claimed {
			append(claimed, id)
		}
	}
}

autoclaim :: proc(s: Stream, cg: ^CG, name: []u8, minidle: i64, start: ID, count: i64, justid: bool, now: i64, claimed: ^[dynamic]ID, deleted: ^[dynamic]ID) -> ID {
	consumer, _ := lookup_or_create_consumer(s, cg, name, now)
	consumer.seen_time = now
	a := Autoclaim_Args{minidle = minidle, start = start, count = count, justid = justid}
	steps: [dynamic]Autoclaim_Step
	defer delete(steps)
	next := autoclaim_scan(s, cg, consumer, &a, now, &steps)
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

dup_groups :: proc "contextless" (s: Stream, d: Stream) {
	if s.cgroups == nil {
		return
	}
	gi: rx.Iterator
	rx.start(&gi, s.cgroups)
	rx.seek(&gi, "^")
	for rx.next(&gi) {
		src := (^CG)(gi.data)
		dst := create_cg(d, rx.key(&gi), src.last_id, src.entries_read)
		pi: rx.Iterator
		rx.start(&pi, src.pel)
		rx.seek(&pi, "^")
		for rx.next(&pi) {
			sn := (^NACK)(pi.data)
			dn := create_nack(d, nil, sn.delivery_time)
			dn.delivery_count = sn.delivery_count
			rx.insert(dst.pel, rx.key(&pi), dn)
		}
		rx.stop(&pi)
		ci: rx.Iterator
		rx.start(&ci, src.consumers)
		rx.seek(&ci, "^")
		for rx.next(&ci) {
			sc := (^Consumer)(ci.data)
			dc := create_consumer(d, dst, sc.name, sc.seen_time)
			dc.active_time = sc.active_time
			ki: rx.Iterator
			rx.start(&ki, sc.pel)
			rx.seek(&ki, "^")
			for rx.next(&ki) {
				v, found := rx.find(dst.pel, rx.key(&ki))
				if !found {
					continue
				}
				dn := (^NACK)(v)
				dn.consumer = dc
				rx.insert(dc.pel, rx.key(&ki), dn)
			}
			rx.stop(&ki)
		}
		rx.stop(&ci)
	}
	rx.stop(&gi)
}
