package main

import "core:c"
import "core:fmt"
import lr "lua_runtime"
import "rdb"

LUA_FLAG_NO_WRITES :: u32(1)
LUA_FLAG_ALLOW_OOM :: u32(2)
LUA_FLAG_ALLOW_STALE :: u32(4)
LUA_FLAG_NO_CLUSTER :: u32(8)
LUA_FLAG_CROSS_SLOT :: u32(16)

Lua_Library :: struct {
	next: ^Lua_Library,
	previous: ^Lua_Library,
	indexed_next: ^Lua_Library,
	name: []u8,
	code: []u8,
	handle: rawptr,
	count: int,
	retirement: ^Lua_Retirement,
	functions: []Lua_Function_Index,
	host_bytes: int,
	accounted: bool,
}

Lua_Function_Index :: struct {
	next: ^Lua_Function_Index,
	library: ^Lua_Library,
	index: int,
	name: []u8,
	hash: u64,
}

Lua_Retirement :: struct {
	remaining: int,
	engine: bool,
}

lua_libraries: ^Lua_Library
lua_retired_libraries: ^Lua_Library
lua_library_count: int
lua_function_count: int
lua_retirement_count: int
lua_library_host_bytes: int
lua_library_index: []^Lua_Library
lua_function_index: []^Lua_Function_Index

lua_lower_name :: proc(name: []u8, temporary: bool = false) -> []u8 {
	allocator := context.temp_allocator if temporary else context.allocator
	result := make([]u8, len(name), allocator)
	for byte, i in name {
		result[i] = lower(byte)
	}
	return result
}

lua_library_index_reserve :: proc(count: int) {
	if count <= len(lua_library_index) {
		return
	}
	size := max(256, len(lua_library_index))
	for size < count {
		size *= 2
	}
	buckets := make([]^Lua_Library, size)
	for library := lua_libraries; library != nil; library = library.next {
		bucket := int(hash_bytes(library.name)&u64(size-1))
		library.indexed_next = buckets[bucket]
		buckets[bucket] = library
	}
	delete(lua_library_index)
	lua_library_index = buckets
}

lua_function_index_reserve :: proc(count: int) {
	if count <= len(lua_function_index) {
		return
	}
	size := max(256, len(lua_function_index))
	for size < count {
		size *= 2
	}
	buckets := make([]^Lua_Function_Index, size)
	for library := lua_libraries; library != nil; library = library.next {
		for &entry in library.functions {
			bucket := int(entry.hash&u64(size-1))
			entry.next = buckets[bucket]
			buckets[bucket] = &entry
		}
	}
	delete(lua_function_index)
	lua_function_index = buckets
}

lua_name_equal :: proc "contextless" (left, right: []u8) -> bool {
	if len(left) != len(right) {
		return false
	}
	for original, i in left {
		byte := original
		other := right[i]
		if byte >= 'A' && byte <= 'Z' {
			byte += 'a'-'A'
		}
		if other >= 'A' && other <= 'Z' {
			other += 'a'-'A'
		}
		if byte != other {
			return false
		}
	}
	return true
}

lua_function_error :: proc(client: ^Conn, message: string) {
	text := make([]u8, len(message), context.temp_allocator)
	for byte, i in transmute([]u8)message {
		if byte == 0 {
			text = text[:i]
			break
		}
		text[i] = ' ' if byte == '\r' || byte == '\n' else byte
	}
	reply_error_bytes(client, text)
}

lua_library_find :: proc(name: []u8) -> ^Lua_Library {
	if len(lua_library_index) == 0 {
		return nil
	}
	bucket := int(hash_bytes(name)&u64(len(lua_library_index)-1))
	for library := lua_library_index[bucket]; library != nil; library = library.indexed_next {
		if bytes_eq(library.name, name) {
			return library
		}
	}
	return nil
}

lua_function_find :: proc(name: []u8, omit: ^Lua_Library = nil) -> (library: ^Lua_Library, index: int, info: lr.Function_Info) {
	if len(lua_function_index) == 0 {
		return nil, 0, {}
	}
	normalized := lua_lower_name(name, true)
	bucket := int(hash_bytes(normalized)&u64(len(lua_function_index)-1))
	for entry := lua_function_index[bucket]; entry != nil; entry = entry.next {
		if entry.library != omit && bytes_eq(entry.name, normalized) {
			return entry.library, entry.index, lr.library_info(entry.library.handle, c.size_t(entry.index))
		}
	}
	return nil, 0, {}
}

lua_library_memory :: proc "contextless" () -> (host, vm: int) {
	host = lua_library_host_bytes + lua_retirement_count*size_of(Lua_Retirement)
	host += (len(lua_library_index)+len(lua_function_index))*size_of(rawptr)
	vm = int(lr.functions_stats().current_bytes)
	return
}

lua_library_free :: proc(library: ^Lua_Library) {
	if library == nil {
		return
	}
	lr.library_free(library.handle)
	retirement := library.retirement
	count := library.count
	if library.accounted {
		lua_library_host_bytes -= library.host_bytes
	}
	for entry in library.functions {
		delete(entry.name)
	}
	delete(library.functions)
	delete(library.name)
	delete(library.code)
	free(library)
	if retirement != nil {
		lazyfree_note_reaped(count)
		retirement.remaining -= 1
		if retirement.remaining == 0 {
			if retirement.engine {
				lazyfree_note_reaped(1)
			}
			free(retirement)
			lua_retirement_count -= 1
		}
	}
}

lua_library_reap :: proc(limit: int) {
	for _ in 0..<limit {
		library := lua_retired_libraries
		if library == nil {
			return
		}
		lua_retired_libraries = library.next
		lua_library_free(library)
	}
}

lua_library_unlink :: proc(library: ^Lua_Library, asynchronous: bool) {
	bucket := int(hash_bytes(library.name)&u64(len(lua_library_index)-1))
	link := &lua_library_index[bucket]
	for link^ != nil && link^ != library {
		link = &link^.indexed_next
	}
	if link^ == nil {
		return
	}
	link^ = library.indexed_next
	for &entry in library.functions {
		function_bucket := int(entry.hash&u64(len(lua_function_index)-1))
		function_link := &lua_function_index[function_bucket]
		for function_link^ != nil && function_link^ != &entry {
			function_link = &function_link^.next
		}
		if function_link^ != &entry {
			store_fatal("Function index ownership invariant")
		}
		function_link^ = entry.next
	}
	if library.previous != nil {
		library.previous.next = library.next
	} else {
		lua_libraries = library.next
	}
	if library.next != nil {
		library.next.previous = library.previous
	}
	library.previous, library.indexed_next = nil, nil
	lua_library_count -= 1
	lua_function_count -= library.count
	if lua_library_count == 0 {
		delete(lua_library_index)
		delete(lua_function_index)
		lua_library_index = nil
		lua_function_index = nil
	}
	if asynchronous {
		library.next = lua_retired_libraries
		lua_retired_libraries = library
	} else {
		lua_library_free(library)
	}
}

lua_library_flush :: proc(asynchronous: bool, reset_engine: bool = true) {
	retirement: ^Lua_Retirement
	deferred := asynchronous && lua_function_count > LAZYFREE_THRESHOLD
	if deferred {
		retirement = new(Lua_Retirement)
		lua_retirement_count += 1
		retirement.remaining = lua_library_count
		retirement.engine = reset_engine
		lazyfree_note_deferred(lua_function_count + (1 if reset_engine else 0))
	}
	for lua_libraries != nil {
		lua_libraries.retirement = retirement
		lua_library_unlink(lua_libraries, deferred)
	}
	if reset_engine {
		lr.functions_reset()
	}
	if !deferred {
		lua_library_reap(max(int))
	}
}

lua_library_header :: proc(code: []u8) -> (name, body: []u8, err: string) {
	if len(code) < 2 || code[0] != '#' || code[1] != '!' {
		return nil, nil, "ERR Missing library metadata"
	}
	end := -1
	for byte, i in code {
		if byte == '\n' {
			end = i
			break
		}
	}
	if end < 0 {
		return nil, nil, "ERR Invalid library metadata"
	}
	words: [dynamic][]u8
	defer delete(words)
	if !split_args(code[:end], &words, context.temp_allocator) || len(words) == 0 {
		return nil, nil, "ERR Invalid library metadata"
	}
	named := false
	for word in words[1:] {
		if len(word) < 5 || !eq_nocase(word[:5], "name=") {
			return nil, nil, fmt.tprintf("ERR Invalid metadata value given: %s", string(word))
		}
		if named {
			return nil, nil, "ERR Invalid metadata value, name argument was given multiple times"
		}
		named = true
		name = word[5:]
	}
	if !named {
		return nil, nil, "ERR Library name was not given"
	}
	valid := len(name) > 0
	for byte in name {
		valid = valid && ((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_')
	}
	if !valid {
		return nil, nil, "ERR Library names can only contain letters, numbers, or underscores(_) and must be at least one character long"
	}
	if len(words[0]) < 2 || !eq_nocase(words[0][2:], "lua") {
		return nil, nil, fmt.tprintf("ERR Engine '%s' not found", string(words[0][2:]) if len(words[0]) >= 2 else "")
	}
	return name, code[end:], ""
}

lua_library_prepare :: proc(code: []u8, client: ^Conn) -> ^Lua_Library {
	name, body, err := lua_library_header(code)
	if err != "" {
		lua_function_error(client, err)
		return nil
	}
	options := lua_options()
	loaded := lr.library_load(lua_arg(body), &options)
	defer lr.free_result(&loaded.result)
	if loaded.library == nil || loaded.result.status != lr.OK {
		if loaded.library != nil {
			lr.library_free(loaded.library)
		}
		lua_result_reply(client, &loaded.result)
		return nil
	}
	library := new(Lua_Library)
	library.name = make([]u8, len(name))
	copy(library.name, name)
	library.code = make([]u8, len(code))
	copy(library.code, code)
	library.handle = loaded.library
	library.count = int(lr.library_count(loaded.library))
	if library.count == 0 {
		lua_library_free(library)
		reply_error(client, "ERR No functions registered")
		return nil
	}
	library.functions = make([]Lua_Function_Index, library.count)
	library.host_bytes = size_of(Lua_Library) + len(library.name) + len(library.code) + library.count*size_of(Lua_Function_Index)
	for &entry, i in library.functions {
		metadata := lr.library_info(library.handle, c.size_t(i))
		entry.library = library
		entry.index = i
		entry.name = lua_lower_name(metadata.name.data[:int(metadata.name.len)])
		entry.hash = hash_bytes(entry.name)
		library.host_bytes += len(entry.name)
	}
	return library
}

lua_library_collision :: proc(library: ^Lua_Library, replaced: ^Lua_Library, staged: []^Lua_Library = nil) -> []u8 {
	for i in 0..<library.count {
		info := lr.library_info(library.handle, c.size_t(i))
		name := info.name.data[:int(info.name.len)]
		if found, _, _ := lua_function_find(name, replaced); found != nil {
			return name
		}
		for other in staged {
			for j in 0..<other.count {
				second := lr.library_info(other.handle, c.size_t(j))
				if lua_name_equal(name, second.name.data[:int(second.name.len)]) {
					return name
				}
			}
		}
	}
	return nil
}

lua_library_publish :: proc(library: ^Lua_Library) {
	lua_library_index_reserve(lua_library_count+1)
	lua_function_index_reserve(lua_function_count+library.count)
	bucket := int(hash_bytes(library.name)&u64(len(lua_library_index)-1))
	library.indexed_next = lua_library_index[bucket]
	lua_library_index[bucket] = library
	for &entry in library.functions {
		function_bucket := int(entry.hash&u64(len(lua_function_index)-1))
		entry.next = lua_function_index[function_bucket]
		lua_function_index[function_bucket] = &entry
	}
	if lua_libraries != nil {
		lua_libraries.previous = library
	}
	library.previous = nil
	library.next = lua_libraries
	lua_libraries = library
	library.accounted = true
	lua_library_host_bytes += library.host_bytes
	lua_library_count += 1
	lua_function_count += library.count
}

lua_function_stats :: proc(client: ^Conn) {
	reply_map(client, 2)
	reply_bulk_str(client, "running_script")
	if lua_active == nil || !lua_active.function {
		reply_null(client)
	} else {
		reply_map(client, 3)
		reply_bulk_str(client, "name")
		reply_bulk(client, lua_active.identifier)
		reply_bulk_str(client, "command")
		reply_array(client, len(lua_active.argv))
		for arg in lua_active.argv {
			reply_bulk(client, arg)
		}
		reply_bulk_str(client, "duration_ms")
		reply_int(client, i64(mono_ticks_us(mono_now()-lua_active.start)/1000))
	}
	reply_bulk_str(client, "engines")
	reply_map(client, 1)
	reply_bulk_str(client, "LUA")
	reply_map(client, 2)
	reply_bulk_str(client, "libraries_count")
	reply_int(client, i64(lua_library_count))
	reply_bulk_str(client, "functions_count")
	reply_int(client, i64(lua_function_count))
}

lua_function_list :: proc(client: ^Conn, pattern: []u8, with_code: bool) {
	count := 0
	for library := lua_libraries; library != nil; library = library.next {
		if pattern == nil || glob_match(pattern, library.name, true) {
			count += 1
		}
	}
	reply_array(client, count)
	for library := lua_libraries; library != nil; library = library.next {
		if pattern != nil && !glob_match(pattern, library.name, true) {
			continue
		}
		reply_map(client, 4 if with_code else 3)
		reply_bulk_str(client, "library_name")
		reply_bulk(client, library.name)
		reply_bulk_str(client, "engine")
		reply_bulk_str(client, "LUA")
		reply_bulk_str(client, "functions")
		reply_array(client, library.count)
		for i in 0..<library.count {
			info := lr.library_info(library.handle, c.size_t(i))
			reply_map(client, 3)
			reply_bulk_str(client, "name")
			reply_bulk(client, info.name.data[:int(info.name.len)])
			reply_bulk_str(client, "description")
			if info.description.data == nil {
				reply_null(client)
			} else {
				reply_bulk(client, info.description.data[:int(info.description.len)])
			}
			reply_bulk_str(client, "flags")
			flags := [?]string{"no-writes", "allow-oom", "allow-stale", "no-cluster", "allow-cross-slot-keys"}
			flag_count := 0
			for _, j in flags {
				if info.flags & (u32(1)<<uint(j)) != 0 {
					flag_count += 1
				}
			}
			reply_set(client, flag_count)
			for flag, j in flags {
				if info.flags & (u32(1)<<uint(j)) != 0 {
					reply_simple(client, flag)
				}
			}
		}
		if with_code {
			reply_bulk_str(client, "library_code")
			reply_bulk(client, library.code)
		}
	}
}

lua_libraries_save :: proc(writer: ^rdb.Writer) {
	for library := lua_libraries; library != nil; library = library.next {
		rdb.put_u8(writer, rdb.OPCODE_FUNCTION2)
		rdb.put_string(writer, library.code)
	}
}

lua_function_dump :: proc(client: ^Conn) {
	writer: rdb.Writer
	rdb.writer_init_mem(&writer, pst.compression, false)
	defer rdb.writer_destroy(&writer)
	lua_libraries_save(&writer)
	rdb.put_u8(&writer, u8(rdb.RDB_VERSION&255))
	rdb.put_u8(&writer, u8(rdb.RDB_VERSION>>8))
	rdb.put_ms(&writer, i64(rdb.crc64(0, rdb.writer_bytes(&writer))))
	reply_bulk(client, rdb.writer_bytes(&writer))
}

lua_function_restore :: proc(client: ^Conn, payload: []u8, policy: string) {
	if !dump_verify(payload) {
		reply_error(client, "ERR DUMP payload version or checksum are wrong")
		return
	}
	reader: rdb.Reader
	rdb.reader_init_mem(&reader, payload[:len(payload)-DUMP_TRAILER_LEN], false)
	defer rdb.reader_destroy(&reader)
	staged: [dynamic]^Lua_Library
	staged_names := make(map[string]^Lua_Library, context.temp_allocator)
	staged_functions := make(map[string]bool, context.temp_allocator)
	defer delete(staged_names)
	defer delete(staged_functions)
	defer {
		for library in staged {
			lua_library_free(library)
		}
		delete(staged)
	}
	for reader.pos < reader.end {
		kind, good := rdb.get_u8(&reader)
		if !good {
			reply_error(client, "ERR Bad data format")
			return
		}
		if kind != rdb.OPCODE_FUNCTION2 {
			reply_error(client, "ERR Pre-GA function format not supported" if kind == rdb.OPCODE_FUNCTION_PRE_GA else "ERR given type is not a function")
			return
		}
		code, valid := rdb.get_string(&reader, 0)
		if !valid {
			reply_error(client, "ERR Bad data format")
			return
		}
		name, _, header_err := lua_library_header(code)
		if header_err != "" {
			lua_function_error(client, header_err)
			return
		}
		if _, exists := staged_names[string(name)]; exists {
			lua_function_error(client, fmt.tprintf("ERR Library '%s' already exists", string(name)))
			return
		}
		library := lua_library_prepare(code, client)
		if library == nil {
			return
		}
		staged_names[string(library.name)] = library
		append(&staged, library)
		for entry in library.functions {
			if staged_functions[string(entry.name)] {
				info := lr.library_info(library.handle, c.size_t(entry.index))
				reply_error_parts(client, "ERR Function ", string(info.name.data[:int(info.name.len)]), " already exists")
				return
			}
			staged_functions[string(entry.name)] = true
		}
	}
	for item in staged {
		old := lua_library_find(item.name)
		if old != nil && policy == "append" {
			lua_function_error(client, fmt.tprintf("ERR Library %s already exists", string(item.name)))
			return
		}
		for entry in item.functions {
			info := lr.library_info(item.handle, c.size_t(entry.index))
			name := info.name.data[:int(info.name.len)]
			if policy != "flush" {
				if existing, _, _ := lua_function_find(entry.name); existing != nil {
					_, replaced := staged_names[string(existing.name)]
					if policy != "replace" || !replaced {
						reply_error_parts(client, "ERR Function ", string(name), " already exists")
						return
					}
				}
			}
		}
	}
	if policy == "flush" {
		lua_library_flush(false, false)
	}
	for item in staged {
		if old := lua_library_find(item.name); old != nil {
			lua_library_unlink(old, false)
		}
		lua_library_publish(item)
	}
	clear(&staged)
	pst.dirty += 1
	reply_ok(client)
}

lua_function_dispatch :: proc(client: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	sub := argv[1]
	switch {
	case eq_nocase(sub, "load"):
		if len(argv) < 3 {
			reply_wrong_args(client, "function|load")
			return
		}
		replace := false
		for option in argv[2:len(argv)-1] {
			if !eq_nocase(option, "replace") {
				lua_function_error(client, fmt.tprintf("ERR Unknown option given: %s", string(option)))
				return
			}
			replace = true
		}
		code := argv[len(argv)-1]
		name, _, err := lua_library_header(code)
		if err != "" {
			lua_function_error(client, err)
			return
		}
		old := lua_library_find(name)
		if old != nil && !replace {
			reply_error_parts(client, "ERR Library '", string(name), "' already exists")
			return
		}
		library := lua_library_prepare(code, client)
		if library == nil {
			return
		}
		if collision := lua_library_collision(library, old); collision != nil {
			reply_error_parts(client, "ERR Function ", string(collision), " already exists")
			lua_library_free(library)
			return
		}
		if old != nil {
			lua_library_unlink(old, false)
		}
		lua_library_publish(library)
		pst.dirty += 1
		reply_bulk(client, library.name)
	case eq_nocase(sub, "delete"):
		if len(argv) != 3 {
			reply_wrong_args(client, "function|delete")
			return
		}
		library := lua_library_find(argv[2])
		if library == nil {
			reply_error(client, "ERR Library not found")
			return
		}
		lua_library_unlink(library, false)
		pst.dirty += 1
		reply_ok(client)
	case eq_nocase(sub, "flush"):
		asynchronous := cfg.lazyfree_lazy_user_flush
		if len(argv) > 3 {
			reply_subcommand_syntax_error(client, sub, "FUNCTION")
			return
		}
		if len(argv) == 3 {
			if !eq_nocase(argv[2], "sync") && !eq_nocase(argv[2], "async") {
				reply_error(client, "ERR FUNCTION FLUSH only supports SYNC|ASYNC option")
				return
			}
			asynchronous = eq_nocase(argv[2], "async")
		}
		lua_library_flush(asynchronous)
		pst.dirty += 1
		reply_ok(client)
	case eq_nocase(sub, "list"):
		pattern: []u8
		with_code := false
		for i := 2; i < len(argv); i += 1 {
			if !with_code && eq_nocase(argv[i], "withcode") {
				with_code = true
			} else if pattern == nil && eq_nocase(argv[i], "libraryname") {
				if i+1 == len(argv) {
					reply_error(client, "ERR library name argument was not given")
					return
				}
				i += 1
				pattern = argv[i]
			} else {
				lua_function_error(client, fmt.tprintf("ERR Unknown argument %s", string(argv[i])))
				return
			}
		}
		lua_function_list(client, pattern, with_code)
	case eq_nocase(sub, "stats"):
		if len(argv) != 2 {
			reply_wrong_args(client, "function|stats")
			return
		}
		lua_function_stats(client)
	case eq_nocase(sub, "kill"):
		if len(argv) != 2 {
			reply_wrong_args(client, "function|kill")
			return
		}
		lua_kill(client, true)
	case eq_nocase(sub, "dump"):
		if len(argv) != 2 {
			reply_wrong_args(client, "function|dump")
			return
		}
		lua_function_dump(client)
	case eq_nocase(sub, "restore"):
		if len(argv) < 3 || len(argv) > 4 {
			reply_subcommand_syntax_error(client, sub, "FUNCTION")
			return
		}
		policy := "append"
		if len(argv) == 4 {
			switch {
			case eq_nocase(argv[3], "flush"): policy = "flush"
			case eq_nocase(argv[3], "replace"): policy = "replace"
			case eq_nocase(argv[3], "append"):
			case:
				reply_error(client, "ERR Wrong restore policy given, value should be either FLUSH, APPEND or REPLACE.")
				return
			}
		}
		lua_function_restore(client, argv[2], policy)
	case:
		reply_unknown_subcommand(client, sub, "FUNCTION")
	}
}
