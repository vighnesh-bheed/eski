package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strings"
import dt "doctable"
import fi "ftindex"
import ht "hashtype"
import lp "listpack"
import ow "owner"
import "postings"
import vt "vsettype"
import "roaring"

Search_Partition :: struct {
	scope:       ow.Scope,
	on_json:     bool,
	data:        fi.Index,
	error_order: []Search_Error_Order,
	real:        vt.Charge,
	vectors:     []vt.Charge,
	base:        Search_Bytes,
	content:     Search_Bytes,
	members:     map[u32]Search_Bytes,
	field_limits: map[u32]int,
	held:        int,
	id_base:     i64,
	activity:    Search_Activity,
}

Search_Activity :: struct {
	indexing_ns: i64,
	gc_ns:       i64,
	gc_last_ns:  i64,
	gc_last_at:  i64,
	gc_cycles:   i64,
	gc_bytes:    i64,
}

Search_Error_Order :: struct {
	order: u64,
	failures: int,
}

search_error_order: u64

search_active_in :: #force_inline proc "contextless" (db: ^Db) -> bool {
	return db.id == 0 && len(search_registry) > 0
}

search_db_scope :: #force_inline proc "contextless" (db: ^Db) -> ow.Scope {
	return ow.Scope{db.label, db.owner} if labels_on else ow.SHARED_BOTTOM
}

search_scope_db :: proc (scope: ow.Scope) -> ^Db {
	if !labels_on {
		return &dbs[0] if scope == ow.SHARED_BOTTOM else nil
	}
	if scope.owner == ow.SHARED {
		return label_part(0, scope.label)
	}
	if e := owner_entry(scope.owner); e != nil {
		if part := owner_space_part(owner_space_of(e, 0), scope.label); part != nil {
			return owner_db(part)
		}
	}
	return nil
}

search_hash_exact :: proc(scope: ow.Scope, name: string) -> ht.Hash {
	return ht.Hash(search_document_exact(scope, name, false))
}

search_document_exact :: proc(scope: ow.Scope, name: string, on_json: bool) -> rawptr {
	value, _ := search_document_with_deadline(scope, name, on_json)
	return value
}

search_document_with_deadline :: proc(scope: ow.Scope, name: string, on_json: bool) -> (rawptr, u64) {
	db := search_scope_db(scope)
	if db == nil {
		return nil, 0
	}
	return search_document_in(db, name, on_json)
}

@(private = "file")
search_document_in :: proc(db: ^Db, name: string, on_json: bool) -> (rawptr, u64) {
	saved := store_no_touch
	store_no_touch = true
	defer store_no_touch = saved
	if entry := db_find_raw_in(db, transmute([]u8)name); entry != nil && !entry_expired(entry) {
		return entry_object(entry, .Json if on_json else .Hash), u64(entry.expire_at)
	}
	return nil, 0
}

search_document_live :: proc(value: rawptr, on_json: bool, now: u64) -> bool {
	if on_json {
		return value != nil
	}
	return search_hash_live(ht.Hash(value), now)
}

search_partitions :: proc(index: ^Search_Index, reader: ow.Scope) -> [dynamic]^Search_Partition {
	parts := make([dynamic]^Search_Partition, context.temp_allocator)
	for scope, part in index.partitions {
		if !labels_on || scope_sees(reader, scope) {
			append(&parts, part)
		}
	}
	return parts
}

search_prefix_matches :: proc "contextless" (index: ^Search_Index, name: string) -> bool {
	for prefix in index.spec.prefixes {
		if len(prefix) <= len(name) && name[:len(prefix)] == prefix {
			return true
		}
	}
	return false
}

search_worker_blocked :: proc(dbi: int, key: []u8) -> bool {
	if dbi != 0 || len(search_registry) == 0 {
		return false
	}
	scopes, found := search_registry[ow.SHARED]
	if !found {
		return false
	}
	bucket := scopes[ow.SHARED_BOTTOM.label]
	if bucket != nil {
		for _, index in bucket.indexes {
			if search_prefix_matches(index, string(key)) {
				return true
			}
		}
	}
	return false
}

search_hash_changed :: proc "contextless" (db: ^Db, key: []u8, h: ht.Hash, empty_write: bool = false) {
	search_document_changed(db, key, h, false, empty_write)
}

search_document_changed :: proc "contextless" (db: ^Db, key: []u8, value: rawptr, on_json: bool, empty_write: bool = false) {
	if !search_active_in(db) {
		return
	}
	context = runtime.default_context()
	scope := search_db_scope(db)
	name := string(key)
	indexes := search_visible(scope, context.allocator)
	defer delete(indexes)
	for index in indexes {
		if index.spec.on_json != on_json || !search_prefix_matches(index, name) {
			continue
		}
		if now := hash_now(); !search_document_live(value, on_json, now) {
			if part := index.partitions[scope]; part != nil {
				if empty_write {
					part.data.errors.failures += 1
				}
				search_part_remove(index, part, name)
			}
		} else {
			search_index_document(index, scope, name, value, now)
		}
	}
}

@(private = "file")
search_part_init :: proc(part: ^Search_Partition, scope: ow.Scope, index: ^Search_Index, allocator := context.allocator) {
	part.scope = scope
	part.on_json = index.spec.on_json
	part.members = make(map[u32]Search_Bytes, allocator)
	part.base = search_part_schema_bytes(&index.spec.definition)
	factory: fi.Vector_Factory
	if part.real.root != nil {
		for f in index.spec.definition.fields {
			if f.kind == .Vector {
				part.vectors = make([]vt.Charge, len(index.spec.definition.fields), allocator)
				factory = search_part_vector_make
				break
			}
		}
	}
	if factory == nil && part.on_json {
		factory = fi.multi_vector_factory
	}
	if fi.init(&part.data, index.spec.definition, factory, part, allocator = allocator, scoped = labels_on) != .None {
		store_fatal("cannot initialize search index partition")
	}
}

@(private = "file")
search_part_vector_make :: proc(ctx: rawptr, field: ^fi.Field, allocator: runtime.Allocator) -> (fi.Vector_Source, fi.Error) {
	part := (^Search_Partition)(ctx)
	for &f, i in part.data.definition.fields {
		if &f == field {
			part.vectors[i].root = part.real.root
			vector_allocator := vt.charge_allocator(&part.vectors[i])
			if part.on_json {
				return fi.multi_vector_factory(nil, field, vector_allocator)
			}
			return fi.default_factory(nil, field, vector_allocator)
		}
	}
	return {}, .Invalid_Definition
}

search_part_destroy :: proc(part: ^Search_Partition) {
	allocator := part.data.allocator
	delete(part.members)
	delete(part.field_limits)
	delete(part.error_order, allocator)
	fi.destroy(&part.data)
	delete(part.vectors, allocator)
}

@(private = "file")
search_part_make :: proc(index: ^Search_Index, scope: ow.Scope) -> ^Search_Partition {
	part := new(Search_Partition, vt.ledger_allocator(&search_memory))
	part.real.root = &search_memory
	search_part_init(part, scope, index, vt.charge_allocator(&part.real))
	return part
}

@(private = "file")
search_part_free :: proc(part: ^Search_Partition) {
	search_scope_charge(part.scope, -part.held)
	search_part_destroy(part)
	free(part, vt.ledger_allocator(&search_memory))
}

search_parts_clear :: proc(index: ^Search_Index) {
	ft_cursor_remove_index(index)
	for _, part in index.partitions {
		search_part_free(part)
	}
	delete(index.partitions)
	index.partitions = nil
}

@(private = "file")
search_part_remove :: proc(index: ^Search_Index, part: ^Search_Partition, name: string) {
	if id, removed := fi.remove(&part.data, name); removed {
		search_document_release(part, id)
		search_part_collect(part)
		search_part_sync(index, part)
	}
}

@(private = "file")
search_part_collect :: proc(part: ^Search_Partition, track := true) {
	start := now_ns() if track else 0
	before := search_part_real(part) if track else 0
	if _, err := fi.collect(&part.data); err != .None {
		store_fatal("cannot collect search document")
	}
	if track {
		part.activity.gc_cycles += 1
		part.activity.gc_last_at = now_ns()
		part.activity.gc_last_ns = max(part.activity.gc_last_at - start, 0)
		part.activity.gc_ns += part.activity.gc_last_ns
		part.activity.gc_bytes += i64(max(before - search_part_real(part), 0))
	}
}

@(private = "file")
search_index_partition :: proc(index: ^Search_Index, scope: ow.Scope) -> ^Search_Partition {
	part := index.partitions[scope]
	if part == nil {
		part = search_part_make(index, scope)
		if index.partitions == nil {
			index.partitions = make(map[ow.Scope]^Search_Partition, vt.ledger_allocator(&search_memory))
		}
		index.partitions[scope] = part
	}
	return part
}

@(private = "file")
search_index_document :: proc(index: ^Search_Index, scope: ow.Scope, name: string, value: rawptr, now: u64) {
	part := search_index_partition(index, scope)
	search_part_add(part, name, value, now)
	search_part_sync(index, part)
}

search_json_deleted :: proc(db: ^Db, key: []u8) {
	if !search_active_in(db) {
		return
	}
	scope := search_db_scope(db)
	name := string(key)
	for index in search_visible(scope) {
		if !index.spec.on_json || !search_prefix_matches(index, name) {
			continue
		}
		part := search_index_partition(index, scope)
		if part.error_order == nil {
			part.error_order = make([]Search_Error_Order, len(part.data.slots) + 1, part.data.allocator)
		}
		fi.set_error(&part.data.errors, fmt.tprintf("SEARCH_QUERY_BAD Key does not exist: %s", name), name, part.data.allocator)
		search_error_order += 1
		part.error_order[0] = {search_error_order, part.data.errors.failures}
		search_part_sync(index, part)
	}
}

search_part_real :: proc(part: ^Search_Partition) -> int {
	bytes := part.real.bytes + vt.usable_size(part)
	for vector in part.vectors {
		bytes += vector.bytes
	}
	return bytes
}

@(private = "file")
search_part_sync :: proc(index: ^Search_Index, initial: ^Search_Partition) {
	part := initial
	bytes := search_charge_sum(search_part_charge_bytes(part))
	if search_part_real(part) > bytes {
		fi.release_work(&part.data)
		if search_part_real(part) > bytes {
			part = search_part_compact(index, part)
			bytes = search_charge_sum(search_part_charge_bytes(part))
		}
	}
	if search_part_real(part) > bytes {
		store_fatal("search partition exceeds its content charge")
	}
	search_scope_charge(part.scope, bytes - part.held)
	part.held = bytes
}

@(private = "file")
search_restore_errors :: proc(dst: ^fi.Field_Errors, src: fi.Field_Errors, allocator: runtime.Allocator) {
	delete(dst.last_key, allocator)
	delete(dst.last_error, allocator)
	dst^ = src
	dst.last_key = strings.clone(src.last_key, allocator)
	dst.last_error = strings.clone(src.last_error, allocator)
}

@(private = "file")
search_part_compact :: proc(index: ^Search_Index, part: ^Search_Partition) -> ^Search_Partition {
	fresh := search_part_make(index, part.scope)
	search_part_copy_live(part, fresh, search_scope_db(part.scope), hash_now())
	fi.release_work(&fresh.data)
	allocator := fresh.data.allocator
	search_restore_errors(&fresh.data.errors, part.data.errors, allocator)
	for &slot, i in fresh.data.slots {
		search_restore_errors(&slot.errors, part.data.slots[i].errors, allocator)
	}
	if part.error_order != nil {
		fresh.error_order = make([]Search_Error_Order, len(part.error_order), allocator)
		copy(fresh.error_order, part.error_order)
	}
	fresh.id_base = search_part_max_id(part) - i64(dt.max_id(&fresh.data.docs))
	fresh.activity = part.activity
	fresh.held, part.held = part.held, 0
	index.partitions[part.scope] = fresh
	search_part_free(part)
	return fresh
}

search_part_max_id :: proc "contextless" (part: ^Search_Partition) -> i64 {
	return part.id_base + i64(dt.max_id(&part.data.docs))
}

@(private = "file")
search_part_add :: proc(part: ^Search_Partition, name: string, value: rawptr, now: u64, track_errors: bool = true, field_limit := max(int)) {
	start := now_ns() if track_errors else 0
	fields := part.data.definition.fields
	previous := part.data.errors.failures
	part.data.analyzer.min_stem = int(ft_config_numbers[.Min_Stem])
	added: fi.Added
	err: fi.Error
	if part.on_json {
		added, err = search_add_json(part, name, cast(^Json_Object)value, field_limit)
	} else {
		added, err = search_add_hash(part, name, ht.Hash(value), now, field_limit)
	}
	if err != .None {
		store_fatal("cannot index search document")
	}
	if added.replaced != 0 {
		search_document_release(part, added.replaced)
		search_part_collect(part, track_errors)
	}
	if added.outcome == .Indexed {
		bytes := search_document_bytes(name, added.size)
		if field_limit < len(fields) {
			if part.field_limits == nil {
				part.field_limits = make(map[u32]int, part.data.allocator)
			}
			part.field_limits[added.id] = field_limit
			bytes[.Documents] += 128
		}
		search_document_charge(part, added.id, bytes)
	}
	if track_errors {
		part.activity.indexing_ns += max(now_ns() - start, 0)
	}
	if track_errors && part.data.errors.failures != previous {
		if part.error_order == nil {
			part.error_order = make([]Search_Error_Order, len(fields) + 1, part.data.allocator)
		}
		search_error_order += 1
		part.error_order[0] = {search_error_order, part.data.errors.failures}
		for slot, i in part.data.slots {
			if slot.errors.failures > part.error_order[i + 1].failures {
				part.error_order[i + 1] = {search_error_order, slot.errors.failures}
				break
			}
		}
	}
}

@(private = "file")
search_add_hash :: proc(part: ^Search_Partition, name: string, h: ht.Hash, now: u64, field_limit: int) -> (fi.Added, fi.Error) {
	def := &part.data.definition
	values := make([dynamic]fi.Value, 0, len(def.fields) + 2)
	defer delete(values)
	integers := make([][lp.DECIMAL_BUFFER_BYTES]u8, len(def.fields) + 2)
	defer delete(integers)
	for field in def.fields[:min(field_limit, len(def.fields))] {
		search_hash_value(h, field.source, now, &values, integers)
	}
	if def.score_field != "" {
		search_hash_value(h, def.score_field, now, &values, integers)
	}
	if def.language_field != "" {
		search_hash_value(h, def.language_field, now, &values, integers)
	}
	return fi.add(&part.data, name, values[:], measure = true, field_limit = field_limit)
}

@(private = "file")
search_hash_value :: proc(h: ht.Hash, field: string, now: u64, values: ^[dynamic]fi.Value, integers: [][lp.DECIMAL_BUFFER_BYTES]u8) {
	value, state := ht.get(h, transmute([]u8)field, now, false)
	if .Live in state {
		bytes := ht.value_bytes(value, &integers[len(values^)])
		append(values, fi.Value{field, string(bytes)})
	}
}

search_scan :: proc(index: ^Search_Index) {
	if !labels_on {
		search_scan_db(index, &dbs[0])
		return
	}
	for db in label_dbs[0].by_id {
		if db != nil && scope_sees(search_db_scope(db), index.scope) {
			search_scan_db(index, db)
		}
	}
	if owners_on && len(owner_dbs) > 0 {
		for space in owner_dbs[0].spaces {
			for i in 0 ..< owner_space_count(space) {
				db := owner_db(owner_space_at(space, i))
				if scope_sees(search_db_scope(db), index.scope) {
					search_scan_db(index, db)
				}
			}
		}
	}
}

@(private = "file")
search_scan_db :: proc(index: ^Search_Index, db: ^Db) {
	scope := search_db_scope(db)
	now := hash_now()
	for k in 0 ..< 2 {
		if k == 1 && db.rehash_idx < 0 {
			break
		}
		t := &db.t[k]
		for g in 0 ..< t.groups {
			full := group_full(group_load(t.ctrl, g))
			for full != 0 {
				i := int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(full))
				full &= full - 1
				slot := &t.slots[i]
				if slot.key.small.tag.val_form != FORM_OBJECT || slot.val.slab.info.type != (.Json if index.spec.on_json else Obj_Type.Hash) {
					continue
				}
				key := string(key_bytes(&slot.key, &db.slab))
				if due := slot_deadline(db, t, i); (due != 0 && due <= i64(now)) || !search_prefix_matches(index, key) {
					continue
				}
				value := rawptr(slot.val.ref.addr)
				if search_document_live(value, index.spec.on_json, now) {
					search_index_document(index, scope, key, value, now)
				}
			}
		}
	}
}

search_hash_live :: proc(h: ht.Hash, now: u64) -> bool {
	if h == nil || ht.length(h) == 0 {
		return false
	}
	if ht.registered_expire(h) >= now {
		return true
	}
	it := ht.iterator_live(h, now)
	return ht.next(&it)
}

search_part_flush :: proc(db: ^Db) {
	if !search_active_in(db) {
		return
	}
	search_scope_parts_clear(search_db_scope(db))
}

search_owner_parts_clear :: proc(e: ^Owner_Entry, all_labels: bool) {
	if e == nil || len(search_registry) == 0 {
		return
	}
	if !all_labels {
		search_scope_parts_clear(ow.Scope{access.id, e.number})
		return
	}
	space := owner_space_of(e, 0)
	for i in 0 ..< owner_ever_len(space) {
		search_scope_parts_clear(ow.Scope{owner_ever_at(space, i), e.number})
	}
}

@(private = "file")
search_scope_parts_clear :: proc(scope: ow.Scope) {
	for index in search_visible(scope) {
		ft_cursor_remove_scope(index, scope)
		if part := index.partitions[scope]; part != nil {
			delete_key(&index.partitions, scope)
			if len(index.partitions) == 0 {
				delete(index.partitions)
				index.partitions = nil
			} else if cap(index.partitions) / 4 > len(index.partitions) {
				shrink(&index.partitions)
			}
			search_part_free(part)
		}
	}
}

search_rebuild_schema :: proc(index: ^Search_Index, old_count: int, skip: bool) {
	if !skip {
		search_parts_clear(index)
		search_scan(index)
		return
	}
	ft_cursor_remove_index(index)
	now := hash_now()
	for scope, old in index.partitions {
		part := search_part_make(index, scope)
		search_part_copy_live(old, part, search_scope_db(scope), now, old_count)
		part.id_base = search_part_max_id(old) - i64(dt.max_id(&part.data.docs))
		part.activity = old.activity
		allocator := part.data.allocator
		search_restore_errors(&part.data.errors, old.data.errors, allocator)
		for &slot, i in old.data.slots {
			search_restore_errors(&part.data.slots[i].errors, slot.errors, allocator)
		}
		if old.error_order != nil {
			part.error_order = make([]Search_Error_Order, len(part.data.slots) + 1, allocator)
			copy(part.error_order, old.error_order)
		}
		index.partitions[scope] = part
		search_part_free(old)
		search_part_sync(index, part)
	}
}

search_rebuild_db0 :: proc() {
	if len(search_registry) == 0 {
		return
	}
	for _, scopes in search_registry {
		for _, bucket in scopes {
			for _, index in bucket.indexes {
				search_parts_clear(index)
				search_scan(index)
			}
		}
	}
}

search_delete_documents :: proc(index: ^Search_Index) {
	part := index.partitions[index.scope]
	if part == nil {
		return
	}
	db := search_scope_db(index.scope)
	if db == nil {
		return
	}
	if db.role & DB_ROLE_OWNER != 0 {
		owner_touch(db)
	}
	for name in part.data.docs.keys {
		value, _ := search_document_in(db, name, index.spec.on_json)
		if !search_document_live(value, index.spec.on_json, hash_now()) {
			continue
		}
		key := transmute([]u8)name
		if found, expired := db_remove_in(db, key); found && !expired {
			pst.dirty += 1
			signal_key_in(key, db)
			notify_in(.Generic, "del", key, db)
		}
	}
	block_note_removed()
}

search_part_snapshot :: proc(index: ^Search_Index, part, snapshot: ^Search_Partition) -> bool {
	db := search_scope_db(part.scope)
	if dt.count(&part.data.docs) == 0 || db == nil || (db.expires == 0 && ht.registry_len(db.hreg) == 0) {
		return false
	}
	now := hash_now()
	for name in part.data.docs.keys {
		value, _ := search_document_in(db, name, index.spec.on_json)
		if value == nil || (!index.spec.on_json && ht.registered_expire(ht.Hash(value)) < now) {
			search_part_init(snapshot, part.scope, index)
			search_part_copy_live(part, snapshot, db, now)
			return true
		}
	}
	return false
}

@(private = "file")
search_part_copy_live :: proc(part, copy: ^Search_Partition, db: ^Db, now: u64, field_limit := max(int)) {
	if db == nil {
		return
	}
	it: roaring.Iterator
	roaring.iterator_init(&it, &part.data.docs.live)
	for id, ok := roaring.next(&it); ok; id, ok = roaring.next(&it) {
		doc := dt.get(&part.data.docs, id)
		value, _ := search_document_in(db, doc.key, part.on_json)
		if search_document_live(value, part.on_json, now) {
			limit, has_limit := part.field_limits[id]
			search_part_add(copy, doc.key, value, now, false, min(field_limit, limit) if has_limit else field_limit)
		}
	}
}

search_part_counts :: proc(index: ^Search_Index, part: ^Search_Partition, sizes: ^Search_Bytes = nil, vector_fields: []int = nil, blocks: ^int = nil) -> fi.Info {
	counts := fi.info(&part.data)
	measure := part
	snapshot: Search_Partition
	if search_part_snapshot(index, part, &snapshot) {
		visible := fi.info(&snapshot.data)
		counts.num_docs = visible.num_docs
		counts.num_terms = visible.num_terms
		counts.num_records = visible.num_records
		measure = &snapshot
	}
	if sizes != nil {
		sizes^ = search_part_charge_bytes(measure, vector_fields)
	}
	if blocks != nil {
		for list in measure.data.lists {
			if list != nil {
				blocks^ += (postings.length(list) + postings.BLOCK - 1) / postings.BLOCK
			}
		}
	}
	if measure == &snapshot {
		search_part_destroy(&snapshot)
	}
	return counts
}

search_document_renamed :: proc(db: ^Db, from_key, to_key: []u8, value: rawptr, on_json: bool) {
	if !search_active_in(db) {
		return
	}
	scope := search_db_scope(db)
	from, to := string(from_key), string(to_key)
	now := hash_now()
	for index in search_visible(scope) {
		if index.spec.on_json != on_json {
			continue
		}
		from_matches := search_prefix_matches(index, from)
		to_matches := search_prefix_matches(index, to)
		if !from_matches && !to_matches {
			continue
		}
		if part := index.partitions[scope]; part != nil && from_matches {
			if to_matches {
				target, target_found := dt.lookup(&part.data.docs, to)
				if id, found := fi.rename(&part.data, from, to); found {
					if target_found && id != target {
						search_document_release(part, target)
						search_part_collect(part)
					}
					if size, known := part.members[id]; known {
						delta := search_document_key_bytes(to) - size[.Keys]
						size[.Keys] += delta
						part.members[id] = size
						part.content[.Keys] += delta
					}
					search_part_sync(index, part)
					continue
				}
			} else {
				search_part_remove(index, part, from)
			}
		}
		if to_matches && search_document_live(value, on_json, now) {
			search_index_document(index, scope, to, value, now)
		}
	}
}
