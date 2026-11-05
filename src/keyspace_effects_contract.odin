package main

import ks "keyspace"

Keyspace_Event_Kind :: enum u8 {
	Invalidate,
	Notify,
	Wake,
}

Keyspace_Event :: struct {
	kind: Keyspace_Event_Kind,
	db: int,
	key: []u8,
	class: Notify_Class,
	name: string,
	object_type: Obj_Type,
	attributed: bool,
	exists: bool,
	always: bool,
	repeat: int,
}

Keyspace_Poststate :: struct {
	db: int,
	key: []u8,
	exists: bool,
	kind: Obj_Type,
	expires: i64,
	clock: u32,
	payload: ^ks.Value,
}

keyspace_effect_key :: proc "contextless" (task: ^Keyspace_Task, r: ^ks.Record) -> []u8 {
	for arg in task.argv { if transmute(string)arg == r.key { return arg } }
	store_fatal("keyspace effect key ownership invariant")
}

keyspace_effect :: proc "contextless" (task: ^Keyspace_Task, r: ^ks.Record, kind: Keyspace_Event_Kind, class: Notify_Class = {}, name: string = "", attributed: bool = true, always: bool = false, object_type: Obj_Type = .String, repeat: int = 1) {
	if len(task.event_storage) == 0 { return }
	index := len(task.events)
	if index == len(task.event_storage) { store_fatal("keyspace event capacity invariant") }
	task.events = task.event_storage[:index + 1]
	task.events[index] = Keyspace_Event{kind = kind, db = r.db, key = keyspace_effect_key(task, r), class = class, name = name, object_type = object_type, attributed = attributed, exists = r.exists, always = always, repeat = repeat}
}

keyspace_invalidate :: proc "contextless" (task: ^Keyspace_Task, r: ^ks.Record, attributed: bool = true, always: bool = false, repeat: int = 1) {
	keyspace_effect(task, r, .Invalidate, attributed = attributed, always = always, repeat = repeat)
}

keyspace_notify :: proc "contextless" (task: ^Keyspace_Task, r: ^ks.Record, class: Notify_Class, name: string, always: bool = false) {
	keyspace_effect(task, r, .Notify, class = class, name = name, always = always)
}

keyspace_wake :: proc "contextless" (task: ^Keyspace_Task, r: ^ks.Record, kind: Obj_Type) {
	keyspace_effect(task, r, .Wake, object_type = kind)
}

keyspace_changed :: proc "contextless" (task: ^Keyspace_Task, r: ^ks.Record, class: Notify_Class, name: string, deleted: bool = false) {
	keyspace_invalidate(task, r)
	keyspace_notify(task, r, class, name)
	if deleted { keyspace_notify(task, r, .Generic, "del") }
}
