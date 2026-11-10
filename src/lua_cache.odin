package main

import "core:crypto/legacy/sha1"
import lb "label"
import lr "lua_runtime"
import ow "owner"

LUA_CACHE_BUCKETS :: 1024
LUA_EVAL_CACHE_LIMIT :: 500

Lua_Source :: struct {
	digest: [40]u8,
	body: []u8,
	pinned: bool,
	bucket_next: ^Lua_Source,
	previous: ^Lua_Source,
	next: ^Lua_Source,
	lru_previous: ^Lua_Source,
	lru_next: ^Lua_Source,
}

Lua_Holder :: struct {
	entry: ^Lua_Source,
	home: ^Lua_Scope,
	entry_next: ^Lua_Holder,
	lru_previous: ^Lua_Holder,
	lru_next: ^Lua_Holder,
	pinned: bool,
}

Lua_Scope :: struct {
	scope: ow.Scope,
	random: u64,
	lru_head: ^Lua_Holder,
	lru_tail: ^Lua_Holder,
	eval_count: int,
	bytes: int,
}

lua_scopes: map[u64]^Lua_Scope
lua_holders: map[^Lua_Source]^Lua_Holder
lua_scope_bytes: int

lua_sources: [LUA_CACHE_BUCKETS]^Lua_Source
lua_sources_head, lua_sources_tail: ^Lua_Source
lua_lru_head, lua_lru_tail: ^Lua_Source
lua_retired_head, lua_retired_tail: ^Lua_Source
lua_cache_bytes, lua_retired_bytes: int
lua_cache_count, lua_eval_count: int
lua_cache_evictions: i64
lua_enable_deprecated_api: bool
lua_max_memory: i64 = max(i64)
lua_max_output: i64 = 512 * 1024 * 1024
lua_max_bridge_memory: i64 = max(i64)
lua_max_cache_memory: i64 = max(i64)

lua_digest :: proc(body: []u8) -> [40]u8 {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, body)
	hash: [20]u8
	sha1.final(&ctx, hash[:])
	hex := "0123456789abcdef"
	out: [40]u8
	for byte, i in hash {
		out[2*i] = hex[byte >> 4]
		out[2*i+1] = hex[byte & 15]
	}
	return out
}

lua_digest_parse :: proc(bytes: []u8) -> (digest: [40]u8, ok: bool) {
	if len(bytes) != len(digest) {
		return digest, false
	}
	for original, i in bytes {
		byte := lower(original)
		if !(byte >= '0' && byte <= '9') && !(byte >= 'a' && byte <= 'f') {
			return digest, false
		}
		digest[i] = byte
	}
	return digest, true
}

lua_digest_key :: proc "contextless" (hex: []u8) -> (key: [20]u8) {
	for i in 0 ..< min(len(hex)/2, len(key)) {
		high, low := hex[2*i], hex[2*i+1]
		high = high-'0' if high <= '9' else high-'a'+10
		low = low-'0' if low <= '9' else low-'a'+10
		key[i] = high<<4 | low
	}
	return
}

lua_lru_remove :: proc(entry: ^Lua_Source) {
	if entry.pinned {
		return
	}
	if entry.lru_previous != nil {
		entry.lru_previous.lru_next = entry.lru_next
	} else {
		lua_lru_head = entry.lru_next
	}
	if entry.lru_next != nil {
		entry.lru_next.lru_previous = entry.lru_previous
	} else {
		lua_lru_tail = entry.lru_previous
	}
	entry.lru_previous, entry.lru_next = nil, nil
}

lua_lru_touch :: proc(entry: ^Lua_Source) {
	if entry.pinned || lua_lru_head == entry {
		return
	}
	lua_lru_remove(entry)
	entry.lru_next = lua_lru_head
	if lua_lru_head != nil {
		lua_lru_head.lru_previous = entry
	} else {
		lua_lru_tail = entry
	}
	lua_lru_head = entry
}

lua_cache_find :: proc(digest: [40]u8, touch := false) -> ^Lua_Source {
	lookup := digest
	entry := lua_sources[int(hash_bytes(lookup[:]) & (LUA_CACHE_BUCKETS-1))]
	for entry != nil {
		if entry.digest == digest {
			if touch {
				lua_lru_touch(entry)
			}
			return entry
		}
		entry = entry.bucket_next
	}
	return nil
}

lua_cache_remove :: proc(entry: ^Lua_Source) {
	bucket := int(hash_bytes(entry.digest[:]) & (LUA_CACHE_BUCKETS-1))
	link := &lua_sources[bucket]
	for link^ != nil && link^ != entry {
		link = &link^.bucket_next
	}
	if link^ != entry {
		store_fatal("Lua cache ownership invariant")
	}
	link^ = entry.bucket_next
	if entry.previous != nil {
		entry.previous.next = entry.next
	} else {
		lua_sources_head = entry.next
	}
	if entry.next != nil {
		entry.next.previous = entry.previous
	} else {
		lua_sources_tail = entry.previous
	}
	if !entry.pinned {
		lua_lru_remove(entry)
		lua_eval_count -= 1
	}
	lua_cache_count -= 1
	lua_cache_bytes -= size_of(Lua_Source) + len(entry.body)
	key := lua_digest_key(entry.digest[:])
	lr.eval_forget(lua_arg(key[:]))
	delete(entry.body)
	free(entry)
}

lua_cache_reap :: proc(limit: int) {
	lua_debug_reap()
	lua_library_reap(max(limit, 64))
	for _ in 0 ..< limit {
		entry := lua_retired_head
		if entry == nil {
			break
		}
		lua_retired_head = entry.next
		lua_retired_bytes -= size_of(Lua_Source) + len(entry.body)
		delete(entry.body)
		free(entry)
	}
	if lua_retired_head == nil {
		lua_retired_tail = nil
	}
}

lua_cache_store :: proc(body: []u8, digest: [40]u8, pinned: bool) -> ^Lua_Source {
	if labels_on {
		return lua_cache_hold(body, digest, pinned)
	}
	if entry := lua_cache_find(digest, !pinned); entry != nil {
		return entry
	}
	if len(body) > max(int)-size_of(Lua_Source) {
		return nil
	}
	charge := size_of(Lua_Source) + len(body)
	if charge > int(lua_max_cache_memory) {
		return nil
	}
	lua_cache_reap(16)
	for lua_lru_tail != nil && (lua_cache_bytes+lua_retired_bytes > int(lua_max_cache_memory)-charge || (!pinned && lua_eval_count >= LUA_EVAL_CACHE_LIMIT)) {
		lua_cache_remove(lua_lru_tail)
		lua_cache_evictions += 1
	}
	if lua_cache_bytes+lua_retired_bytes > int(lua_max_cache_memory)-charge {
		return nil
	}
	return lua_cache_insert(body, digest, pinned)
}

lua_cache_insert :: proc(body: []u8, digest: [40]u8, pinned: bool) -> ^Lua_Source {
	charge := size_of(Lua_Source) + len(body)
	entry := new(Lua_Source)
	entry.digest, entry.body, entry.pinned = digest, clone_bytes(body), pinned
	bucket := int(hash_bytes(entry.digest[:]) & (LUA_CACHE_BUCKETS-1))
	entry.bucket_next = lua_sources[bucket]
	lua_sources[bucket] = entry
	entry.previous = lua_sources_tail
	if lua_sources_tail != nil {
		lua_sources_tail.next = entry
	} else {
		lua_sources_head = entry
	}
	lua_sources_tail = entry
	lua_cache_bytes += charge
	lua_cache_count += 1
	if !pinned {
		entry.lru_next = lua_lru_head
		if lua_lru_head != nil {
			lua_lru_head.lru_previous = entry
		} else {
			lua_lru_tail = entry
		}
		lua_lru_head = entry
		lua_eval_count += 1
	}
	return entry
}

lua_cache_flush :: proc(asynchronous: bool) {
	lua_holders_release()
	if lua_sources_head != nil {
		if lua_retired_tail != nil {
			lua_retired_tail.next = lua_sources_head
		} else {
			lua_retired_head = lua_sources_head
		}
		lua_retired_tail = lua_sources_tail
		lua_retired_bytes += lua_cache_bytes
	}
	lua_sources = {}
	lua_sources_head, lua_sources_tail, lua_lru_head, lua_lru_tail = nil, nil, nil, nil
	lua_cache_bytes, lua_cache_count, lua_eval_count = 0, 0, 0
	if !asynchronous {
		lua_cache_reap(max(int))
	}
}

lua_cache_limit_check :: proc(v: i64, s: []u8) -> string {
	if v < i64(lua_cache_bytes+lua_retired_bytes) {
		return "Lua cache limit is below currently owned cache memory"
	}
	return ""
}

lua_cache_lookup :: proc(digest: [40]u8, touch := false) -> ^Lua_Source {
	if !labels_on {
		return lua_cache_find(digest, touch)
	}
	entry := lua_cache_find(digest)
	if entry == nil || !lua_entry_visible(entry) {
		return nil
	}
	if touch {
		if h := lua_holder_of(entry, lua_scope_of(access_scope(), false)); h != nil {
			lua_holder_touch(h)
		}
	}
	return entry
}

lua_entry_visible :: proc(entry: ^Lua_Source) -> bool {
	if access.top {
		return true
	}
	viewer := access_view_owner()
	for h := lua_holders[entry]; h != nil; h = h.entry_next {
		if access_visible(h.home.scope.label) && ow.sees(viewer, h.home.scope.owner) {
			return true
		}
	}
	return false
}

@(private = "file")
lua_scope_key :: #force_inline proc "contextless" (s: ow.Scope) -> u64 {
	return u64(s.label) << 32 | u64(s.owner)
}

lua_scope_of :: proc(s: ow.Scope, create: bool) -> ^Lua_Scope {
	if found, ok := lua_scopes[lua_scope_key(s)]; ok {
		return found
	}
	if !create {
		return nil
	}
	record := new(Lua_Scope)
	record.scope = s
	lua_scopes[lua_scope_key(s)] = record
	lua_scope_bytes += size_of(Lua_Scope)
	return record
}

@(private = "file")
lua_holder_of :: proc(entry: ^Lua_Source, home: ^Lua_Scope) -> ^Lua_Holder {
	if home == nil {
		return nil
	}
	for h := lua_holders[entry]; h != nil; h = h.entry_next {
		if h.home == home {
			return h
		}
	}
	return nil
}

@(private = "file")
lua_holder_unlink_lru :: proc(h: ^Lua_Holder) {
	home := h.home
	if h.lru_previous != nil {
		h.lru_previous.lru_next = h.lru_next
	} else {
		home.lru_head = h.lru_next
	}
	if h.lru_next != nil {
		h.lru_next.lru_previous = h.lru_previous
	} else {
		home.lru_tail = h.lru_previous
	}
	h.lru_previous, h.lru_next = nil, nil
}

@(private = "file")
lua_holder_push_lru :: proc(h: ^Lua_Holder) {
	home := h.home
	h.lru_previous = nil
	h.lru_next = home.lru_head
	if home.lru_head != nil {
		home.lru_head.lru_previous = h
	} else {
		home.lru_tail = h
	}
	home.lru_head = h
}

@(private = "file")
lua_holder_touch :: proc(h: ^Lua_Holder) {
	if h.pinned || h.home.lru_head == h {
		return
	}
	lua_holder_unlink_lru(h)
	lua_holder_push_lru(h)
}

@(private = "file")
lua_holder_charge :: #force_inline proc "contextless" (entry: ^Lua_Source) -> int {
	return size_of(Lua_Source) + len(entry.body)
}

@(private = "file")
lua_holder_drop :: proc(h: ^Lua_Holder, free_entry := true) {
	entry, home := h.entry, h.home
	if !h.pinned {
		lua_holder_unlink_lru(h)
		home.eval_count -= 1
	}
	home.bytes -= lua_holder_charge(entry)
	head := lua_holders[entry]
	if head == h {
		if h.entry_next != nil {
			lua_holders[entry] = h.entry_next
		} else {
			delete_key(&lua_holders, entry)
		}
	} else {
		link := head
		for link != nil && link.entry_next != h {
			link = link.entry_next
		}
		if link == nil {
			store_fatal("Lua script holder ownership invariant")
		}
		link.entry_next = h.entry_next
	}
	free(h)
	lua_cache_bytes -= size_of(Lua_Holder)
	if free_entry && entry not_in lua_holders {
		lua_cache_remove(entry)
	}
}

lua_cache_hold :: proc(body: []u8, digest: [40]u8, pinned: bool) -> ^Lua_Source {
	home := lua_scope_of(access_scope(), true)
	entry := lua_cache_find(digest)
	if entry != nil {
		if h := lua_holder_of(entry, home); h != nil {
			if !pinned {
				lua_holder_touch(h)
			}
			return entry
		}
	}
	if len(body) > max(int)-size_of(Lua_Source) {
		return nil
	}
	charge := size_of(Lua_Source) + len(body)
	if charge > int(lua_max_cache_memory) {
		return nil
	}
	lua_cache_reap(16)
	for home.lru_tail != nil && (home.bytes > int(lua_max_cache_memory)-charge || (!pinned && home.eval_count >= LUA_EVAL_CACHE_LIMIT)) {
		lua_holder_drop(home.lru_tail)
		lua_cache_evictions += 1
	}
	if home.bytes > int(lua_max_cache_memory)-charge {
		return nil
	}
	if entry == nil {
		entry = lua_cache_insert(body, digest, true)
	}
	h := new(Lua_Holder)
	h.entry, h.home, h.pinned = entry, home, pinned
	h.entry_next = lua_holders[entry]
	lua_holders[entry] = h
	lua_cache_bytes += size_of(Lua_Holder)
	home.bytes += charge
	if !pinned {
		lua_holder_push_lru(h)
		home.eval_count += 1
	}
	return entry
}

lua_holders_release :: proc() {
	if len(lua_holders) == 0 {
		return
	}
	held := make([dynamic]^Lua_Holder, 0, len(lua_holders), context.temp_allocator)
	for _, head in lua_holders {
		for h := head; h != nil; h = h.entry_next {
			append(&held, h)
		}
	}
	for h in held {
		lua_holder_drop(h, false)
	}
	clear(&lua_holders)
	for _, home in lua_scopes {
		home.lru_head, home.lru_tail = nil, nil
		home.eval_count, home.bytes = 0, 0
	}
}

lua_scopes_forget_owner :: proc(o: ow.Owner) {
	homes := make([dynamic]^Lua_Scope, context.temp_allocator)
	for _, home in lua_scopes {
		if home.scope.owner == o {
			append(&homes, home)
		}
	}
	if len(homes) == 0 {
		return
	}
	held := make([dynamic]^Lua_Holder, context.temp_allocator)
	for _, head in lua_holders {
		for h := head; h != nil; h = h.entry_next {
			if h.home.scope.owner == o {
				append(&held, h)
			}
		}
	}
	for h in held {
		lua_holder_drop(h)
	}
	for home in homes {
		delete_key(&lua_scopes, lua_scope_key(home.scope))
		free(home)
		lua_scope_bytes -= size_of(Lua_Scope)
	}
}

lua_scope_random :: proc(home: ^Lua_Scope) -> u64 {
	if home.random == 0 {
		l, _ := access_label_of(home.scope.label)
		base := lb.label_hash(l) ~ label_stream_secret
		if home.scope.owner != ow.SHARED {
			text, _ := owner_text(home.scope.owner)
			base ~= label_mix(owner_text_hash(text) + 0x51_7C_C1_B7_27_22_0A_95)
		}
		home.random = (label_mix(base + 7) & 0xFFFF_FFFF_FFFF) | (u64(1) << 63)
	}
	return home.random
}
