package main

import "core:crypto/legacy/sha1"
import lr "lua_runtime"

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
