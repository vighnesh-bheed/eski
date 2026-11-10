package main

import "base:runtime"
import "core:testing"
import ht "hashtype"
import st "settype"
import zt "zsettype"

Owner_Test_Part :: struct {
	db:   Db,
	hreg: ht.Registry,
	sctx: st.Context,
	zctx: zt.Context,
}

owner_test_bytes :: proc(s: string) -> []u8 {
	return raw_data(s)[:len(s)]
}

owner_test_heap_db :: proc() -> ^Db {
	if len(dbs) == 0 {
		db_init()
	}
	p := new(Owner_Test_Part, runtime.heap_allocator())
	db := &p.db
	db_part_init(db, 0)
	db.role = DB_ROLE_HEAP
	db.hreg = &p.hreg
	p.hreg.owner = db
	db.sctx = &p.sctx
	p.sctx.owner = db
	db.zctx = &p.zctx
	p.zctx.owner = db
	return db
}

owner_test_heap_db_free :: proc(db: ^Db) {
	db_flush_in(db, false)
	free((^Owner_Test_Part)(db), runtime.heap_allocator())
}

owner_test_found :: proc(db: ^Db, name: string) -> bool {
	l := lookup_make(owner_test_bytes(name))
	_, i := db_locate_slot(db, &l)
	return i >= 0
}

@(test)
keyspace_owners_short_timed_heap_keys_are_found :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	db := owner_test_heap_db()
	defer owner_test_heap_db_free(db)
	at := i64(4_000_000_000_000)
	names := []string{"a", "abcdefg", "abcdefgh"}
	for name in names {
		e, created := db_upsert_timed_in(db, owner_test_bytes(name), at)
		testing.expect(t, created)
		entry_assign(e, owner_test_bytes("value-one"))
		testing.expect(t, owner_test_found(db, name))
		again, created_again := db_upsert_timed_in(db, owner_test_bytes(name), at)
		testing.expect(t, !created_again)
		entry_assign(again, owner_test_bytes("value-two"))
		testing.expect_value(t, string(again.val), "value-two")
		testing.expect_value(t, again.expire_at, at)
	}
	testing.expect_value(t, db_size_of(db), 3)
	testing.expect_value(t, db.expires, 3)
	for name in ([]string{"b", "bcdefgh", "bcdefghi"}) {
		e, _ := db_upsert_in(db, owner_test_bytes(name))
		entry_assign(e, owner_test_bytes("plain"))
		entry_set_expire(e, at)
		testing.expect(t, owner_test_found(db, name))
		found, _ := db_remove_in(db, owner_test_bytes(name))
		testing.expect(t, found)
		testing.expect(t, !owner_test_found(db, name))
	}
	for name in names {
		found, _ := db_remove_in(db, owner_test_bytes(name))
		testing.expect(t, found)
	}
	testing.expect_value(t, db_size_of(db), 0)
	testing.expect_value(t, db.expires, 0)
}

@(test)
keyspace_owners_empty_heap_values_charge_their_allocation :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	db := owner_test_heap_db()
	defer owner_test_heap_db_free(db)
	anchor, _ := db_upsert_in(db, owner_test_bytes("anchor"))
	entry_assign(anchor, owner_test_bytes("x"))
	base := db_used_memory
	stored, _ := db_upsert_in(db, owner_test_bytes("s"))
	entry_copy_string(stored, nil, .Raw)
	one := db_used_memory - base
	appended, _ := db_upsert_in(db, owner_test_bytes("t"))
	entry_append(appended, nil)
	entry_heap_close(appended)
	two := db_used_memory - base - one
	testing.expect_value(t, one, 1 + BIG_STR_BYTES)
	testing.expect_value(t, two, one)
	entry_copy_string(stored, nil, .Raw)
	testing.expect_value(t, db_used_memory - base, one + two)
	found, _ := db_remove_in(db, owner_test_bytes("s"))
	testing.expect(t, found)
	found, _ = db_remove_in(db, owner_test_bytes("t"))
	testing.expect(t, found)
	testing.expect_value(t, db_used_memory, base)
}

@(test)
keyspace_owners_empty_heap_close_then_empty_store :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	db := owner_test_heap_db()
	defer owner_test_heap_db_free(db)
	base := db_used_memory
	e, _ := db_upsert_in(db, owner_test_bytes("empty"))
	e.val = nil
	e.cap = 0
	entry_heap_close(e)
	testing.expect_value(t, e.kp.small.tag.val_form, u8(FORM_HEAP))
	entry_copy_string(e, nil, .Raw)
	testing.expect_value(t, len(e.val), 0)
	entry_copy_string(e, owner_test_bytes("abc"), .Raw)
	testing.expect_value(t, string(e.val), "abc")
	found, _ := db_remove_in(db, owner_test_bytes("empty"))
	testing.expect(t, found)
	testing.expect_value(t, db_used_memory, base)
}
