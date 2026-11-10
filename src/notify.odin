package main

import lb "label"

Notify_Class :: enum u16 {
	Keyspace,
	Keyevent,
	Generic,
	String,
	List,
	Set,
	Hash,
	Zset,
	Expired,
	Evicted,
	Stream,
	Key_Miss,
	Loaded,
	Module,
	New,
}

Notify_Set :: bit_set[Notify_Class;u16]

NOTIFY_ALL :: Notify_Set{.Generic, .String, .List, .Set, .Hash, .Zset, .Expired, .Evicted, .Stream, .Module}

ERR_NOTIFY_CLASS :: "Invalid event class character. Use 'Ag$lshzxeKEtmdn'."

notify_config: Notify_Set

notify_active: Notify_Set

key_hooks: bool

@(private = "file")
NOTIFY_CHANNELS :: Notify_Set{.Keyspace, .Keyevent}

@(private = "file")
NOTIFY_CHAN_KEEP :: 64 * 1024

@(private = "file")
Notify_Letter :: struct {
	class:  Notify_Class,
	letter: u8,
}

@(private = "file")
notify_body_letters := [?]Notify_Letter {
	{.Generic, 'g'},
	{.String, '$'},
	{.List, 'l'},
	{.Set, 's'},
	{.Hash, 'h'},
	{.Zset, 'z'},
	{.Expired, 'x'},
	{.Evicted, 'e'},
	{.Stream, 't'},
	{.Module, 'd'},
	{.New, 'n'},
}

@(private = "file")
notify_tail_letters := [?]Notify_Letter{{.Keyspace, 'K'}, {.Keyevent, 'E'}, {.Key_Miss, 'm'}}

@(private = "file")
notify_chan: [dynamic]u8

notify :: #force_inline proc(class: Notify_Class, event: string, key: []u8) {
	if class in notify_active {
		notify_publish(event, key, cur_db().id)
	}
}

notify_in :: #force_inline proc(class: Notify_Class, event: string, key: []u8, db: ^Db) {
	if class in notify_active {
		notify_publish(event, key, db.id)
	}
}

key_hooks_update :: #force_inline proc() {
	key_hooks = tracking_on || watch_total > 0 || notify_active != {}
}

signal_key :: #force_inline proc(key: []u8) {
	if key_hooks {
		signal_key_hooked(key, cur_db(), true)
	}
}

signal_key_in :: #force_inline proc(key: []u8, db: ^Db) {
	if key_hooks {
		signal_key_hooked(key, db, true)
	}
}

signal_key_expired :: #force_inline proc(key: []u8, db: ^Db) {
	if key_hooks {
		signal_key_hooked(key, db, false)
	}
}

@(cold)
signal_key_hooked :: #force_no_inline proc(key: []u8, db: ^Db, attributed: bool) {
	if watch_total > 0 {
		watch_touch(key, db)
	}
	if tracking_on {
		tracking_invalidate_key(key, attributed)
	}
}

key_expired_event :: proc(key: []u8, db: ^Db) {
	signal_key_expired(key, db)
	notify_in(.Expired, "expired", key, db)
}

@(private = "file")
notify_put_db :: proc(b: ^[dynamic]u8, dbid: int) {
	digits: [24]u8
	n := format_i64(raw_data(digits[:]), i64(dbid))
	append(b, ..digits[:n])
}

@(cold)
notify_publish :: #force_no_inline proc(event: string, key: []u8, dbid: int, key_label := lb.BOTTOM_ID) {
	if len(ps_maps[.Channel]) == 0 && len(ps_patterns) == 0 {
		return
	}
	b := &notify_chan
	if .Keyspace in notify_config {
		clear(b)
		append(b, "__keyspace@")
		notify_put_db(b, dbid)
		append(b, "__:")
		append(b, ..key)
		ps_publish(b[:], transmute([]u8)event, .Channel, key_label)
	}
	if .Keyevent in notify_config {
		clear(b)
		append(b, "__keyevent@")
		notify_put_db(b, dbid)
		append(b, "__:")
		append(b, event)
		ps_publish(b[:], key, .Channel, key_label)
	}
	if cap(b) > NOTIFY_CHAN_KEEP {
		delete(b^)
		b^ = nil
	}
}

notify_parse :: proc(s: []u8) -> (Notify_Set, bool) {
	flags: Notify_Set
	for ch in s {
		switch ch {
		case 'A':
			flags += NOTIFY_ALL
		case 'g':
			flags += {.Generic}
		case '$':
			flags += {.String}
		case 'l':
			flags += {.List}
		case 's':
			flags += {.Set}
		case 'h':
			flags += {.Hash}
		case 'z':
			flags += {.Zset}
		case 'x':
			flags += {.Expired}
		case 'e':
			flags += {.Evicted}
		case 'K':
			flags += {.Keyspace}
		case 'E':
			flags += {.Keyevent}
		case 't':
			flags += {.Stream}
		case 'm':
			flags += {.Key_Miss}
		case 'd':
			flags += {.Module}
		case 'n':
			flags += {.New}
		case:
			return {}, false
		}
	}
	return flags, true
}

notify_format :: proc(flags: Notify_Set, dst: []u8) -> int {
	n := 0
	if NOTIFY_ALL <= flags {
		if n < len(dst) {
			dst[n] = 'A'
			n += 1
		}
	} else {
		for l in notify_body_letters {
			if l.class in flags && n < len(dst) {
				dst[n] = l.letter
				n += 1
			}
		}
	}
	for l in notify_tail_letters {
		if l.class in flags && n < len(dst) {
			dst[n] = l.letter
			n += 1
		}
	}
	return n
}

notify_apply :: proc(flags: Notify_Set) {
	notify_config = flags
	if flags & NOTIFY_CHANNELS != {} {
		notify_active = flags
	} else {
		notify_active = {}
	}
	key_hooks_update()
}
