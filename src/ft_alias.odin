package main

import "core:slice"
import "core:strings"
import ow "owner"
import vt "vsettype"

Search_Alias :: struct {
	name: string,
	scope: ow.Scope,
	target: ^Search_Index,
	age: u64,
	held: int,
}

Search_Alias_Bucket :: struct {
	names: map[string]^Search_Alias,
}

search_aliases: map[ow.Scope]^Search_Alias_Bucket

search_scope_precedes :: proc(reader, left, right: ow.Scope, left_age, right_age: u64) -> bool {
	if (left.label == reader.label) != (right.label == reader.label) {
		return left.label == reader.label
	}
	if rank := scope_compare(reader.owner, left, right); rank != 0 {
		return rank > 0
	}
	return left_age < right_age
}

search_alias_find :: proc(name: string, reader: ow.Scope) -> ^Search_Alias {
	best: ^Search_Alias
	for scope, bucket in search_aliases {
		if labels_on && !scope_sees(reader, scope) {
			continue
		}
		if alias := bucket.names[name]; alias != nil && (best == nil || search_scope_precedes(reader, alias.scope, best.scope, alias.age, best.age)) {
			best = alias
		}
	}
	return best
}

search_resolve :: proc(name: string, reader: ow.Scope) -> (^Search_Index, ^Search_Alias) {
	index := search_find_definition(name, reader)
	alias := search_alias_find(name, reader)
	if alias != nil && (index == nil || search_scope_precedes(reader, alias.scope, index.scope, alias.age, index.age)) {
		return alias.target, alias
	}
	return index, nil
}

search_find :: proc(name: string, reader: ow.Scope) -> ^Search_Index {
	index, _ := search_resolve(name, reader)
	return index
}

search_alias_bytes :: proc(name: string) -> int {
	return 1024 + 2 * len(name)
}

search_alias_create :: proc(name: string, scope: ow.Scope, target: ^Search_Index) -> ^Search_Alias {
	a := vt.ledger_allocator(&search_memory)
	if search_aliases == nil {
		search_aliases = make(map[ow.Scope]^Search_Alias_Bucket, a)
	}
	bucket := search_aliases[scope]
	if bucket == nil {
		bucket = new(Search_Alias_Bucket, a)
		bucket.names = make(map[string]^Search_Alias, a)
		search_aliases[scope] = bucket
	}
	alias := new(Search_Alias, a)
	search_age += 1
	alias^ = {name = strings.clone(name, a), scope = scope, target = target, age = search_age, held = search_alias_bytes(name)}
	bucket.names[alias.name] = alias
	search_scope_charge(scope, alias.held)
	return alias
}

search_alias_drop :: proc(alias: ^Search_Alias) {
	a := vt.ledger_allocator(&search_memory)
	bucket := search_aliases[alias.scope]
	delete_key(&bucket.names, alias.name)
	search_scope_charge(alias.scope, -alias.held)
	delete(alias.name, a)
	if len(bucket.names) == 0 {
		delete(bucket.names)
		free(bucket, a)
		delete_key(&search_aliases, alias.scope)
		if len(search_aliases) == 0 {
			delete(search_aliases)
			search_aliases = nil
		} else if len(search_aliases) * 4 < cap(search_aliases) {
			shrink(&search_aliases)
		}
	} else if len(bucket.names) * 4 < cap(bucket.names) {
		shrink(&bucket.names)
	}
	free(alias, a)
}

search_aliases_ordered :: proc() -> []^Search_Alias {
	out := make([dynamic]^Search_Alias, context.temp_allocator)
	for _, bucket in search_aliases {
		for _, alias in bucket.names {
			append(&out, alias)
		}
	}
	slice.sort_by(out[:], proc(left, right: ^Search_Alias) -> bool { return left.age < right.age })
	return out[:]
}

search_alias_drop_target :: proc(index: ^Search_Index) {
	for alias in search_aliases_ordered() {
		if alias.target == index {
			search_alias_drop(alias)
		}
	}
}

search_alias_forget :: proc(owner: ow.Owner) {
	for alias in search_aliases_ordered() {
		if alias.scope.owner == owner {
			search_alias_drop(alias)
		}
	}
}

search_alias_owner_present :: proc(owner: ow.Owner) -> bool {
	for scope in search_aliases {
		if scope.owner == owner {
			return true
		}
	}
	return false
}

search_alias_flush :: proc(scope: ow.Scope, all_scopes: bool) -> i64 {
	n: i64
	for alias in search_aliases_ordered() {
		if all_scopes || (alias.scope.owner == scope.owner &&
		   (alias.scope.label == scope.label || (owners_on && access.label_top))) {
			search_alias_drop(alias)
			n += 1
		}
	}
	return n
}

cmd_ft_aliasadd :: proc(c: ^Conn, argv: [][]u8) {
	search_alias_change(c, argv, false)
}

cmd_ft_aliasupdate :: proc(c: ^Conn, argv: [][]u8) {
	search_alias_change(c, argv, true)
}

search_alias_change :: proc(c: ^Conn, argv: [][]u8, update: bool) {
	scope := search_scope()
	target, indirect := search_resolve(string(argv[2]), scope)
	if target == nil {
		search_reply_missing(c, string(argv[2]))
		return
	}
	if indirect != nil {
		reply_error(c, "SEARCH_INDEX_NOT_FOUND Unknown index name (or name is an alias itself)")
		return
	}
	if !search_acl_allows(c, target) {
		reply_error(c, ERR_SEARCH_PERMISSIONS)
		return
	}
	name := string(argv[1])
	current, alias := search_resolve(name, scope)
	if current != nil && alias == nil {
		reply_error(c, "SEARCH_INDEX_NOT_FOUND Alias does not belong to provided spec" if update else "SEARCH_ALIAS_CONFLICT Alias conflicts with an existing index name")
		return
	}
	if alias != nil {
		if !update {
			reply_error(c, "SEARCH_INDEX_EXISTS Alias already exists")
			return
		}
		if alias.scope != scope {
			reply_error(c, label_in_use_text("INUSE index in use at ", alias.scope.label, alias.scope.owner))
			return
		}
		if !search_acl_allows(c, alias.target) {
			reply_error(c, ERR_SEARCH_PERMISSIONS)
			return
		}
		alias.target = target
	} else {
		if why := search_definition_admit(scope, search_alias_bytes(name)); why != "" {
			reply_error(c, why)
			return
		}
		search_alias_create(name, scope, target)
	}
	search_metadata_changed()
	reply_ok(c)
}

cmd_ft_aliasdel :: proc(c: ^Conn, argv: [][]u8) {
	scope := search_scope()
	index, alias := search_resolve(string(argv[1]), scope)
	if alias == nil {
		reply_error(c, "Alias does not exist" if index == nil else "SEARCH_INDEX_NOT_FOUND Alias does not belong to provided spec")
		return
	}
	if !search_acl_allows(c, index) {
		reply_error(c, ERR_SEARCH_PERMISSIONS)
		return
	}
	if alias.scope != scope {
		reply_error(c, label_in_use_text("INUSE index in use at ", alias.scope.label, alias.scope.owner))
		return
	}
	search_alias_drop(alias)
	search_metadata_changed()
	reply_ok(c)
}

search_metadata_changed :: proc() {
	pst.dirty += 1
	if lua_active != nil {
		lua_active.wrote = true
	}
}
