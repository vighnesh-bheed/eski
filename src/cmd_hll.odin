package main

import "base:runtime"
import "hll"

HLL_SCRATCH_KEEP :: 1 << 16

hll_sparse_max_bytes := hll.HLL_SPARSE_MAX_BYTES_DEFAULT

@(private = "file")
hll_regs: [hll.HLL_REGISTERS]u8

@(private = "file")
hll_scratch: [dynamic]u8

@(private = "file")
Hll_Status :: enum u8 {
	Missing,
	Ok,
	Wrong_Kind,
	Not_Hll,
}

@(private = "file")
hll_alloc :: #force_inline proc() -> runtime.Allocator {
	return hll.hll_raw_heap_allocator()
}

@(private = "file")
hll_scratch_ready :: proc() -> ^[dynamic]u8 {
	if hll_scratch.allocator.procedure == nil {
		hll_scratch = make([dynamic]u8, 0, hll.HLL_DENSE_SIZE, hll_alloc())
	}
	clear(&hll_scratch)
	return &hll_scratch
}

@(private = "file")
hll_scratch_trim :: proc() {
	if cap(hll_scratch) > HLL_SCRATCH_KEEP {
		delete(hll_scratch)
		hll_scratch = nil
		return
	}
	clear(&hll_scratch)
}

@(private = "file")
hll_lookup :: proc(key: []u8, write: bool) -> (e: ^Entry, status: Hll_Status) {
	e = db_find(key) if write else db_find_read(key)
	if e == nil {
		return nil, .Missing
	}
	if entry_type(e) != .String {
		return e, .Wrong_Kind
	}
	if !hll.hll_is_valid(e.val) {
		return e, .Not_Hll
	}
	return e, .Ok
}

@(private = "file")
hll_reply_status :: proc(c: ^Conn, status: Hll_Status) {
	if status == .Wrong_Kind {
		reply_wrongtype(c)
	} else {
		reply_error(c, hll.HLL_ERR_WRONGTYPE)
	}
}

@(private = "file")
hll_entry_store :: proc(e: ^Entry, v: []u8) {
	entry_copy_string(e, v, .Raw)
}

@(private = "file")
hll_entry_to_dense :: proc(e: ^Entry) -> (converted: bool, err: hll.Error) {
	scratch := hll_scratch_ready()
	converted, err = hll.to_dense_apply(e.val, scratch)
	if converted && err == .None {
		hll_entry_store(e, scratch[:])
	}
	return
}

cmd_pfadd :: proc(c: ^Conn, argv: [][]u8) {
	key := argv[1]
	e, status := hll_lookup(key, true)
	if status == .Wrong_Kind || status == .Not_Hll {
		hll_reply_status(c, status)
		return
	}
	created := status == .Missing
	empty := hll.HLL_EMPTY_SPARSE
	cur := empty[:] if created else e.val
	scratch := hll_scratch_ready()
	changed, in_scratch, err := hll.pfadd_apply(cur, argv[2:], scratch, hll_sparse_max_bytes)
	if created {
		e, _ = db_upsert(key)
		hll_entry_store(e, scratch[:] if in_scratch && changed else cur)
	} else if in_scratch && changed {
		hll_entry_store(e, scratch[:])
	}
	hll_scratch_trim()
	if err != .None {
		reply_error(c, hll.hll_error_message(err))
		return
	}
	if !created && !changed {
		pst.dirty_explicit = true
		reply_int(c, 0)
		return
	}
	if created {
		pst.dirty += 1
	}
	if changed {
		pst.dirty += 1
	}
	signal_key(key)
	notify(.String, "pfadd", key)
	reply_int(c, 1)
}

cmd_pfcount :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) == 2 {
		e, status := hll_lookup(argv[1], false)
		switch status {
		case .Missing:
			reply_int(c, 0)
			return
		case .Wrong_Kind, .Not_Hll:
			hll_reply_status(c, status)
			return
		case .Ok:
		}
		if hll.hll_cache_valid(e.val) {
			reply_int(c, i64(hll.hll_cached_card(e.val)))
			return
		}
		invalid := false
		card := hll.hll_count(e.val, &invalid)
		if invalid {
			reply_error(c, hll.HLL_ERR_INVALIDOBJ)
			return
		}
		pst.dirty += 1
		aof_emit(c, ..argv)
		reply_int(c, i64(card))
		return
	}
	hll_regs = {}
	for key in argv[1:] {
		e, status := hll_lookup(key, false)
		switch status {
		case .Missing:
			continue
		case .Wrong_Kind, .Not_Hll:
			hll_reply_status(c, status)
			return
		case .Ok:
		}
		if hll.hll_merge_into(&hll_regs, e.val) != .None {
			reply_error(c, hll.HLL_ERR_INVALIDOBJ)
			return
		}
	}
	reply_int(c, i64(hll.hll_estimate_raw(&hll_regs)))
}

cmd_pfmerge :: proc(c: ^Conn, argv: [][]u8) {
	hll_regs = {}
	dense_wanted := false
	for key in argv[1:] {
		e, status := hll_lookup(key, false)
		switch status {
		case .Missing:
			continue
		case .Wrong_Kind, .Not_Hll:
			hll_reply_status(c, status)
			return
		case .Ok:
		}
		if e.val[4] == hll.HLL_DENSE {
			dense_wanted = true
		}
		if hll.hll_merge_into(&hll_regs, e.val) != .None {
			reply_error(c, hll.HLL_ERR_INVALIDOBJ)
			return
		}
	}
	dest := argv[1]
	e, status := hll_lookup(dest, true)
	exists := status == .Ok
	scratch := hll_scratch_ready()
	in_scratch, err := hll.pfmerge_apply(e.val if exists else nil, exists, &hll_regs, dense_wanted, scratch, hll_sparse_max_bytes)
	if err != .None {
		hll_scratch_trim()
		reply_error(c, hll.hll_error_message(err))
		return
	}
	if !exists {
		e, _ = db_upsert(dest)
	}
	if in_scratch {
		hll_entry_store(e, scratch[:])
	}
	hll_scratch_trim()
	pst.dirty += 1
	signal_key(dest)
	notify(.String, "pfadd", dest)
	reply_ok(c)
}

cmd_pfdebug :: proc(c: ^Conn, argv: [][]u8) {
	sub := argv[1]
	key := argv[2]
	e, status := hll_lookup(key, true)
	switch status {
	case .Missing:
		reply_error(c, hll.HLL_ERR_NO_KEY)
		return
	case .Wrong_Kind, .Not_Hll:
		hll_reply_status(c, status)
		return
	case .Ok:
	}
	switch {
	case eq_nocase(sub, "getreg"):
		if e.val[4] == hll.HLL_SPARSE {
			converted, err := hll_entry_to_dense(e)
			if err != .None {
				hll_scratch_trim()
				reply_error(c, hll.hll_error_message(err))
				return
			}
			if converted {
				hll.hll_get_registers(hll_scratch[:], &hll_regs)
				pst.dirty += 1
				signal_key(key)
			}
			hll_scratch_trim()
		} else {
			hll.hll_get_registers(e.val, &hll_regs)
			pst.dirty_explicit = true
		}
		reply_array(c, hll.HLL_REGISTERS)
		for value in hll_regs {
			reply_int(c, i64(value))
		}
	case eq_nocase(sub, "decode"):
		if e.val[4] != hll.HLL_SPARSE {
			reply_error(c, hll.HLL_ERR_NOT_SPARSE)
			return
		}
		scratch := hll_scratch_ready()
		hll.sparse_debug_append(e.val, scratch)
		reply_bulk(c, scratch[:])
		hll_scratch_trim()
		pst.dirty_explicit = true
	case eq_nocase(sub, "encoding"):
		reply_simple(c, hll.hll_encoding_name(e.val))
		pst.dirty_explicit = true
	case eq_nocase(sub, "todense"):
		converted, err := hll_entry_to_dense(e)
		hll_scratch_trim()
		if err != .None {
			reply_error(c, hll.hll_error_message(err))
			return
		}
		if converted {
			pst.dirty += 1
			signal_key(key)
			reply_int(c, 1)
		} else {
			pst.dirty_explicit = true
			reply_int(c, 0)
		}
	case:
		reply_error_parts(c, "ERR Unknown PFDEBUG subcommand '", string(sub), "'")
	}
}

cmd_pfselftest :: proc(c: ^Conn, argv: [][]u8) {
	ok, msg := hll.hll_selftest(rng_next(), hll.HLL_SPARSE_MAX_BYTES_DEFAULT, hll_alloc())
	if !ok {
		reply_error(c, msg)
		return
	}
	reply_ok(c)
}

@(private = "file")
hll_commands := [?]Command {
	{"pfadd", cmd_pfadd, -2},
	{"pfcount", cmd_pfcount, -2},
	{"pfmerge", cmd_pfmerge, -2},
	{"pfdebug", cmd_pfdebug, 3},
	{"pfselftest", cmd_pfselftest, 1},
}

@(init)
register_hll_commands :: proc "contextless" () {
	register_commands(hll_commands[:])
}
