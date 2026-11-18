package main

import "base:runtime"
import "core:strings"
import dt "doctable"
import ht "hashtype"
import ow "owner"
import vt "vsettype"

FT_CURSOR_CAPACITY :: 128
ft_cursor_full :: proc() -> string {
	return ft_error("SEARCH_LIMIT_OVER INDEX_CURSOR_LIMIT of ", ft_int_text(ft_config_numbers[.Cursor_Limit]), " has been reached for an index")
}

FT_Cursor_Owner :: struct {
	scope: ow.Scope,
	user: ^Acl_User,
}

FT_Cursor_Source :: struct {
	scope: ow.Scope,
	key: string,
	fields: int,
	due, key_due: u64,
}

FT_Cursor_Bucket :: struct {
	items: map[i64]^FT_Cursor,
}

FT_Cursor :: struct {
	index: ^Search_Index,
	owner: FT_Cursor_Owner,
	id: i64,
	prev, next: ^FT_Cursor,
	rows: []FT_Row,
	at: int,
	total: int,
	count: int,
	idle_ms: i64,
	deadline: u64,
	warn, buffered, first, expand: bool,
	sources: []FT_Cursor_Source,
	depends: [dynamic]ow.Scope,
}

ft_cursors: ^FT_Cursor
ft_cursor_reap_next: ^FT_Cursor
ft_cursor_count: int

ft_cursor_owner :: proc(c: ^Conn, reader: ow.Scope) -> FT_Cursor_Owner {
	return {reader, c.user}
}

ft_cursor_store :: proc(c: ^Conn, index: ^Search_Index, state: ^Search_Query_State, options: FT_Cursor_Options, result: FT_Pipeline_Result, skip: int, source: []Search_Row, first: bool) -> ^FT_Cursor {
	allocator := vt.ledger_allocator(&search_memory)
	owner := ft_cursor_owner(c, state.reader)
	bucket := index.cursors[owner]
	if ft_config_numbers[.Cursor_Limit] == 0 {
		return nil
	}
	if bucket != nil && len(bucket.items) >= int(ft_config_numbers[.Cursor_Limit]) {
		ft_cursor_collect(index, owner)
		bucket = index.cursors[owner]
		if bucket != nil && len(bucket.items) >= int(ft_config_numbers[.Cursor_Limit]) {
			return nil
		}
	}
	if bucket == nil {
		if index.cursors == nil {
			index.cursors = make(map[FT_Cursor_Owner]^FT_Cursor_Bucket, allocator)
		}
		bucket = new(FT_Cursor_Bucket, allocator)
		bucket.items = make(map[i64]^FT_Cursor, allocator)
		index.cursors[owner] = bucket
	}
	cursor := new(FT_Cursor, allocator)
	cursor.index, cursor.owner = index, owner
	for cursor.id == 0 || bucket.items[cursor.id] != nil {
		random: [8]u8
		runtime.rand_bytes(random[:])
		cursor.id = i64(transmute(u64)random & u64(max(i32)))
	}
	bucket.items[cursor.id] = cursor
	cursor.next = ft_cursors
	if ft_cursors != nil {
		ft_cursors.prev = cursor
	}
	ft_cursors = cursor
	ft_cursor_count += 1
	cursor.total, cursor.buffered, cursor.warn, cursor.first = result.total, result.buffered, result.warn, first
	cursor.expand = result.expand
	cursor.count, cursor.idle_ms = options.count, options.idle_ms
	ft_cursor_refresh(cursor)
	cursor.rows = make([]FT_Row, len(result.rows) - skip, allocator)
	for &row, i in cursor.rows {
		cells := result.rows[skip+i].cells
		if len(cells) != 0 {
			row.cells = make([dynamic]FT_Cell, len(cells), allocator)
			for cell, j in cells {
				row.cells[j] = {strings.clone(cell.name, allocator), ft_cursor_clone_value(cell.value)}
			}
		}
	}
	if labels_on {
		cursor.depends = make([dynamic]ow.Scope, 0, len(state.scopes), allocator)
		for data, scope in state.scopes {
			if dt.count(&data.docs) > 0 {
				append(&cursor.depends, scope)
			}
		}
		cursor.sources = make([]FT_Cursor_Source, len(source), allocator)
		now := hash_now()
		for doc, i in source {
			value, deadline := search_document_with_deadline(doc.scope, doc.key, index.spec.on_json)
			item := FT_Cursor_Source{scope = doc.scope, key = strings.clone(doc.key, allocator), due = deadline, key_due = deadline}
			if h := ht.Hash(value); !index.spec.on_json && h != nil {
				item.fields = ht.length_live(h, now)
				if ht.registered_expire(h) != max(u64) {
					it := ht.iterator_live(h, now)
					for ht.next(&it) {
						if expiry := ht.current_expire(&it); expiry != 0 && (item.due == 0 || expiry < item.due) {
							item.due = expiry
						}
					}
				}
			}
			cursor.sources[i] = item
		}
	}
	return cursor
}

ft_cursor_clone_value :: proc(src: FT_Value) -> FT_Value {
	a := vt.ledger_allocator(&search_memory)
	switch value in src {
	case f64:
		return value
	case i64:
		return value
	case FT_Json_Double:
		return value
	case string:
		return strings.clone(value, a)
	case []FT_Value:
		copy := make([]FT_Value, len(value), a)
		for item, i in value {
			copy[i] = ft_cursor_clone_value(item)
		}
		return copy
	case FT_Object:
		copy := make([]FT_Cell, len(value), a)
		for item, i in value {
			copy[i] = {strings.clone(item.name, a), ft_cursor_clone_value(item.value)}
		}
		return FT_Object(copy)
	}
	return nil
}

ft_cursor_free_value :: proc(value: FT_Value) {
	a := vt.ledger_allocator(&search_memory)
	switch item in value {
	case f64, i64, FT_Json_Double:
	case string:
		delete(item, a)
	case []FT_Value:
		for val in item {
			ft_cursor_free_value(val)
		}
		delete(item, a)
	case FT_Object:
		ft_cursor_free_cells(cast([]FT_Cell)item)
		delete(cast([]FT_Cell)item, a)
	}
}

ft_cursor_free_cells :: proc(cells: []FT_Cell) {
	a := vt.ledger_allocator(&search_memory)
	for cell in cells {
		delete(cell.name, a)
		ft_cursor_free_value(cell.value)
	}
}

ft_cursor_refresh :: proc(cursor: ^FT_Cursor) {
	cursor.deadline = mono_posix_ns() + u64(cursor.idle_ms) * 1_000_000
}

ft_cursor_expired :: proc(cursor: ^FT_Cursor, now: u64) -> bool {
	return now >= cursor.deadline
}

ft_cursor_delete :: proc(cursor: ^FT_Cursor) {
	a := vt.ledger_allocator(&search_memory)
	if ft_cursor_reap_next == cursor {
		ft_cursor_reap_next = cursor.next
	}
	if cursor.prev != nil {
		cursor.prev.next = cursor.next
	} else {
		ft_cursors = cursor.next
	}
	if cursor.next != nil {
		cursor.next.prev = cursor.prev
	}
	index := cursor.index
	bucket := index.cursors[cursor.owner]
	delete_key(&bucket.items, cursor.id)
	if len(bucket.items) == 0 {
		delete(bucket.items)
		free(bucket, a)
		delete_key(&index.cursors, cursor.owner)
		if len(index.cursors) == 0 {
			delete(index.cursors)
			index.cursors = nil
		}
	}
	for &row in cursor.rows[cursor.at:] {
		ft_cursor_free_cells(row.cells[:])
		delete(row.cells)
	}
	delete(cursor.rows, a)
	for source in cursor.sources {
		delete(source.key, a)
	}
	delete(cursor.sources, a)
	delete(cursor.depends)
	free(cursor, a)
	ft_cursor_count -= 1
}

ft_cursor_reap :: proc() {
	if ft_cursors == nil {
		return
	}
	if ft_cursor_reap_next == nil {
		ft_cursor_reap_next = ft_cursors
	}
	now := mono_posix_ns()
	for n := 0; n < 64 && ft_cursor_reap_next != nil; n += 1 {
		cursor := ft_cursor_reap_next
		ft_cursor_reap_next = cursor.next
		if ft_cursor_expired(cursor, now) {
			ft_cursor_delete(cursor)
		}
	}
}

ft_cursor_shutdown :: proc() {
	for ft_cursors != nil {
		ft_cursor_delete(ft_cursors)
	}
}

ft_cursor_remove_index :: proc(index: ^Search_Index) {
	if len(index.cursors) == 0 {
		return
	}
	for cursor := ft_cursors; cursor != nil; {
		next := cursor.next
		if cursor.index == index {
			ft_cursor_delete(cursor)
		}
		cursor = next
	}
}

ft_cursor_remove_scope :: proc(index: ^Search_Index, scope: ow.Scope) {
	if len(index.cursors) == 0 {
		return
	}
	for cursor := ft_cursors; cursor != nil; {
		next := cursor.next
		if cursor.index == index {
			touched := cursor.owner.scope == scope
			for dependency in cursor.depends {
				touched = touched || dependency == scope
			}
			if touched {
				ft_cursor_delete(cursor)
			}
		}
		cursor = next
	}
}

ft_cursor_forget_owner :: proc(owner: ow.Owner) {
	for cursor := ft_cursors; cursor != nil; {
		next := cursor.next
		touched := cursor.owner.scope.owner == owner
		for dependency in cursor.depends {
			touched = touched || dependency.owner == owner
		}
		if touched {
			ft_cursor_delete(cursor)
		}
		cursor = next
	}
}

ft_cursor_remove_user :: proc(user: ^Acl_User) {
	for cursor := ft_cursors; cursor != nil; {
		next := cursor.next
		if cursor.owner.user == user {
			ft_cursor_delete(cursor)
		}
		cursor = next
	}
}

ft_cursor_sources_live :: proc(cursor: ^FT_Cursor) -> bool {
	now := hash_now()
	saved := store_no_touch
	store_no_touch = true
	defer store_no_touch = saved
	for source in cursor.sources {
		value, key_due := search_document_with_deadline(source.scope, source.key, cursor.index.spec.on_json)
		if value == nil || (source.key_due != 0 && source.key_due != key_due) ||
		   (source.due != 0 && now >= source.due) ||
		   (!cursor.index.spec.on_json && ht.length_live(ht.Hash(value), now) < source.fields) {
			return false
		}
		reader := cursor.owner.scope
		db, _, slot := label_resolve(0, transmute([]u8)source.key, reader.label, access.vis, reader.owner, false)
		if slot < 0 || search_db_scope(db) != source.scope {
			return false
		}
	}
	return true
}

ft_cursor_count_for_index :: proc(index: ^Search_Index) -> int {
	total := 0
	for _, bucket in index.cursors {
		total += len(bucket.items)
	}
	return total
}

ft_cursor_collect :: proc(index: ^Search_Index, owner: FT_Cursor_Owner) -> int {
	bucket := index.cursors[owner]
	if bucket == nil {
		return 0
	}
	expired := make([dynamic]^FT_Cursor, context.temp_allocator)
	now := mono_posix_ns()
	for _, cursor in bucket.items {
		if ft_cursor_expired(cursor, now) {
			append(&expired, cursor)
		}
	}
	for cursor in expired {
		ft_cursor_delete(cursor)
	}
	return len(expired)
}

ft_cursor_reply_start :: proc(c: ^Conn, index: ^Search_Index, state: ^Search_Query_State, options: FT_Cursor_Options, result: FT_Pipeline_Result, source: []Search_Row) {
	count := min(options.count, len(result.rows))
	id: i64
	if count == options.count {
		cursor := ft_cursor_store(c, index, state, options, result, count, source, false)
		if cursor == nil {
			reply_error(c, ft_cursor_full())
			return
		}
		id = cursor.id
	}
	total := result.total
	if !result.buffered {
		total = min(total, count)
	}
	reply_array(c, 2)
	ft_reply_aggregate(c, result.rows[:count], total, result.warn, result.expand)
	reply_int(c, id)
}

ft_cursor_take :: proc(c: ^Conn, cursor: ^FT_Cursor, count: int) {
	take := min(count, len(cursor.rows) - cursor.at)
	total := take
	if cursor.first {
		total = cursor.total
	} else if cursor.buffered {
		total = 0
	}
	reply_array(c, 2)
	ft_reply_aggregate(c, cursor.rows[cursor.at:cursor.at+take], total, cursor.warn, cursor.expand)
	if take < count {
		reply_int(c, 0)
		ft_cursor_delete(cursor)
		return
	}
	reply_int(c, cursor.id)
	for &row in cursor.rows[cursor.at:cursor.at+take] {
		ft_cursor_free_cells(row.cells[:])
		delete(row.cells)
		row.cells = nil
	}
	cursor.at += take
	cursor.first = false
	ft_cursor_refresh(cursor)
}

cmd_ft_cursor :: proc(c: ^Conn, argv: [][]u8) {
	read := eq_nocase(argv[1], "read")
	remove := eq_nocase(argv[1], "del")
	collect := eq_nocase(argv[1], "gc")
	if !read && !remove && !collect {
		reply_error(c, ft_error("ERR unknown subcommand '", ft_token(argv[1]), "'. Try FT.CURSOR HELP."))
		return
	}
	if len(argv) < 4 {
		name := "READ" if read else ("DEL" if remove else "GC")
		reply_error(c, ft_error("ERR wrong number of arguments for 'FT.CURSOR|", name, "' command"))
		return
	}
	reader := search_scope()
	index := search_query_index(c, string(argv[2]), reader)
	if index == nil {
		return
	}
	owner := ft_cursor_owner(c, reader)
	if collect {
		reply_int(c, i64(ft_cursor_collect(index, owner)))
		return
	}
	id, valid := search_number(argv[3])
	if len(argv[3]) == 0 || !valid {
		reply_error(c, "Bad cursor ID")
		return
	}
	count := 0
	if read && len(argv) >= 6 && eq_nocase(argv[4], "count") {
		value, ok := search_number(argv[5])
		if !ok {
			reply_error(c, ft_error("Bad value for COUNT: `", ft_token(argv[5]), "`"))
			return
		}
		if value > 0 {
			count = int(value)
		}
	}
	cursor: ^FT_Cursor
	if bucket := index.cursors[owner]; bucket != nil {
		cursor = bucket.items[id]
	}
	if cursor != nil && (ft_cursor_expired(cursor, mono_posix_ns()) || !ft_cursor_sources_live(cursor)) {
		ft_cursor_delete(cursor)
		cursor = nil
	}
	if cursor == nil {
		if read {
			reply_error(c, ft_error("Cursor not found, id: ", ft_int_text(id)))
		} else {
			reply_error(c, "Cursor does not exist")
		}
		return
	}
	if remove {
		ft_cursor_delete(cursor)
		reply_ok(c)
		return
	}
	if len(argv) > 4 && !eq_nocase(argv[4], "count") {
		reply_error(c, ft_error("Unknown argument `", ft_token(argv[4]), "`"))
		return
	}
	if count == 0 {
		count = cursor.count
	}
	ft_cursor_take(c, cursor, count)
}
