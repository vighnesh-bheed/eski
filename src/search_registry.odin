package main

import "core:slice"
import "core:strings"
import fi "ftindex"
import lb "label"
import ow "owner"
import vt "vsettype"

Search_Index :: struct {
	name:  string,
	scope: ow.Scope,
	age:   u64,
	uses:  i64,
	dialects: bit_set[1 ..= 4],
	spec:  Search_Create,
	held:  int,
	real:  vt.Charge,
	partitions: map[ow.Scope]^Search_Partition,
	cursors: map[FT_Cursor_Owner]^FT_Cursor_Bucket,
}

Search_Scope :: struct {
	indexes: map[string]^Search_Index,
}

search_registry: map[ow.Owner]map[lb.Id]^Search_Scope
search_age: u64

search_scope :: #force_inline proc "contextless" () -> ow.Scope {
	return access_scope() if labels_on else ow.SHARED_BOTTOM
}

search_visible :: proc(reader: ow.Scope, allocator := context.temp_allocator) -> [dynamic]^Search_Index {
	result := make([dynamic]^Search_Index, allocator)
	if reader.owner == ow.EVERY {
		for _, scopes in search_registry {
			search_scope_collect(scopes, reader.label, &result)
		}
	} else {
		if scopes, found := search_registry[reader.owner]; found {
			search_scope_collect(scopes, reader.label, &result)
		}
		if reader.owner != ow.SHARED {
			if scopes, found := search_registry[ow.SHARED]; found {
				search_scope_collect(scopes, reader.label, &result)
			}
		}
	}
	return result
}

@(private = "file")
search_scope_collect :: proc(scopes: map[lb.Id]^Search_Scope, reader: lb.Id, result: ^[dynamic]^Search_Index) {
	for marking, entry in scopes {
		if labels_on && !access_dominates(reader, marking) {
			continue
		}
		for _, index in entry.indexes {
			append(result, index)
		}
	}
}

search_find_exact :: proc(name: string, scope: ow.Scope) -> ^Search_Index {
	scopes, known := search_registry[scope.owner]
	if known {
		if entry := scopes[scope.label]; entry != nil {
			return entry.indexes[name]
		}
	}
	return nil
}

search_find_definition :: proc(name: string, reader: ow.Scope) -> ^Search_Index {
	if index := search_find_exact(name, reader); index != nil {
		return index
	}
	if reader.owner != ow.SHARED {
		if index := search_find_exact(name, ow.Scope{reader.label, ow.SHARED}); index != nil {
			return index
		}
	}
	best: ^Search_Index
	if reader.owner == ow.EVERY {
		for _, scopes in search_registry {
			search_find_at(scopes, name, reader, &best)
		}
	} else {
		if scopes, found := search_registry[reader.owner]; found {
			search_find_at(scopes, name, reader, &best)
		}
		if reader.owner != ow.SHARED {
			if scopes, found := search_registry[ow.SHARED]; found {
				search_find_at(scopes, name, reader, &best)
			}
		}
	}
	return best
}

@(private = "file")
search_find_at :: proc(scopes: map[lb.Id]^Search_Scope, name: string, reader: ow.Scope, best: ^^Search_Index) {
	for marking, entry in scopes {
		if !access_dominates(reader.label, marking) {
			continue
		}
		index := entry.indexes[name]
		if index == nil {
			continue
		}
		if best^ == nil {
			best^ = index
			continue
		}
		rank := scope_compare(reader.owner, index.scope, best^.scope)
		if rank > 0 || (rank == 0 && index.age < best^.age) {
			best^ = index
		}
	}
}

search_names :: proc(reader: ow.Scope) -> []string {
	indexes := search_visible(reader)
	names := make([dynamic]string, 0, len(indexes), context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for index in indexes {
		if index.name not_in seen {
			seen[index.name] = true
			append(&names, index.name)
		}
	}
	slice.sort(names[:])
	return names[:]
}

search_index_create :: proc(name: string, scope: ow.Scope, spec: Search_Create, scan := true) -> ^Search_Index {
	index := new(Search_Index, vt.ledger_allocator(&search_memory))
	index.real.root = &search_memory
	allocator := vt.charge_allocator(&index.real)
	owned := spec
	def, err := fi.clone_definition(&owned.definition, allocator)
	if err != .None {
		store_fatal("out of memory")
	}
	owned.definition = def
	owned.prefixes = make([]string, len(spec.prefixes), allocator)
	for prefix, i in spec.prefixes {
		owned.prefixes[i] = strings.clone(prefix, allocator)
	}
	owned.attributes = make([]Search_Attribute, len(spec.attributes), allocator)
	copy(owned.attributes, spec.attributes)
	search_age += 1
	index.name = strings.clone(name, allocator)
	index.scope = scope
	index.age = search_age
	index.spec = owned
	index.held = search_definition_bytes(name, &owned)
	search_scope_charge(scope, index.held)
	if search_registry == nil {
		search_registry = make(map[ow.Owner]map[lb.Id]^Search_Scope, vt.ledger_allocator(&search_memory))
	}
	scopes, known := search_registry[scope.owner]
	if !known {
		scopes = make(map[lb.Id]^Search_Scope, vt.ledger_allocator(&search_memory))
	}
	bucket := scopes[scope.label]
	if bucket == nil {
		bucket = new(Search_Scope, vt.ledger_allocator(&search_memory))
		bucket.indexes = make(map[string]^Search_Index, vt.ledger_allocator(&search_memory))
		scopes[scope.label] = bucket
		search_registry[scope.owner] = scopes
	}
	bucket.indexes[index.name] = index
	if scan && !spec.skip_initial_scan {
		search_scan(index)
	}
	return index
}

@(private = "file")
search_index_release :: proc(index: ^Search_Index) {
	search_alias_drop_target(index)
	search_parts_clear(index)
	search_scope_charge(index.scope, -index.held)
	allocator := vt.charge_allocator(&index.real)
	fi.free_definition(&index.spec.definition, allocator)
	for prefix in index.spec.prefixes {
		delete(prefix, allocator)
	}
	delete(index.spec.prefixes, allocator)
	delete(index.spec.attributes, allocator)
	delete(index.name, allocator)
	free(index, vt.ledger_allocator(&search_memory))
}

search_index_drop :: proc(index: ^Search_Index, delete_documents: bool) {
	scopes := search_registry[index.scope.owner]
	bucket := scopes[index.scope.label]
	delete_key(&bucket.indexes, index.name)
	marking, owner := index.scope.label, index.scope.owner
	if delete_documents {
		search_delete_documents(index)
	}
	search_index_release(index)
	if len(bucket.indexes) == 0 {
		delete(bucket.indexes)
		free(bucket, vt.ledger_allocator(&search_memory))
		delete_key(&scopes, marking)
		if len(scopes) == 0 {
			delete(scopes)
			delete_key(&search_registry, owner)
			search_release_empty_registry()
		} else {
			if cap(scopes) / 4 > len(scopes) {
				shrink(&scopes)
			}
			search_registry[owner] = scopes
		}
	} else if cap(bucket.indexes) / 4 > len(bucket.indexes) {
		shrink(&bucket.indexes)
	}
}

search_owner_has_definitions :: proc(owner: ow.Owner) -> bool {
	_, found := search_registry[owner]
	return found || search_alias_owner_present(owner)
}

search_forget_owner :: proc(owner: ow.Owner) {
	ft_cursor_forget_owner(owner)
	search_alias_forget(owner)
	scopes, found := search_registry[owner]
	if !found {
		return
	}
	for _, bucket in scopes {
		for _, index in bucket.indexes {
			search_index_release(index)
		}
		delete(bucket.indexes)
		free(bucket, vt.ledger_allocator(&search_memory))
	}
	delete(scopes)
	delete_key(&search_registry, owner)
	search_release_empty_registry()
}

@(private = "file")
search_release_empty_registry :: proc() {
	if len(search_registry) == 0 {
		delete(search_registry)
		search_registry = nil
	} else if cap(search_registry) / 4 > len(search_registry) {
		shrink(&search_registry)
	}
}

search_flush :: proc(dbi: int, all: bool) -> i64 {
	if (len(search_registry) == 0 && len(search_aliases) == 0) || (labels_on && !all && dbi != 0) {
		return 0
	}
	scope := search_scope()
	if owners_on && owner_user() {
		search_owner_parts_clear(access.owner_entry, access.label_top)
	}
	all_scopes := !labels_on || (access.top && (!owners_on || (!owner_user() && !access.owner_named)))
	alias_count := search_alias_flush(scope, all_scopes)
	selected := make([dynamic]^Search_Index, context.temp_allocator)
	if all_scopes {
		for _, scopes in search_registry {
			for _, bucket in scopes {
				for _, index in bucket.indexes {
					append(&selected, index)
				}
			}
		}
	} else {
		scopes, found := search_registry[scope.owner]
		if !found {
			return alias_count
		}
		for marking, bucket in scopes {
			if marking != scope.label && !(owners_on && access.label_top) {
				continue
			}
			for _, index in bucket.indexes {
				append(&selected, index)
			}
		}
	}
	for index in selected {
		search_index_drop(index, false)
	}
	return alias_count + i64(len(selected))
}
