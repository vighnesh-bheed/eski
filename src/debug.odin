package main

import "base:intrinsics"
import "core:strconv"
import "core:sys/linux"
import ht "hashtype"
import lp "listpack"
import lt "listtype"
import st "settype"
import zt "zsettype"

REPLY_BUFFER_PEAK_RESET_DEFAULT_MS :: 5000
DEBUG_STATS_VECTLEN :: 50
ERR_POSITIVE :: "ERR value is out of range, must be positive"

aof_flush_sleep_us: i64
dict_resizing := true
reply_buffer_resizing := true
reply_buffer_peak_reset_ms: i64 = REPLY_BUFFER_PEAK_RESET_DEFAULT_MS
repl_id: [40]u8
repl_id2: [40]u8

@(private = "file")
repl_ids_ready: bool
@(private = "file")
debug_buf: [dynamic]u8

@(private = "file")
debug_help := [?]string {
	"DEBUG <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"AOF-FLUSH-SLEEP <microsec>",
	"    Server will sleep before flushing the AOF, this is used for testing.",
	"CHANGE-REPL-ID",
	"    Change the replication IDs of the instance.",
	"    Dangerous: should be used only for testing the replication subsystem.",
	"CONFIG-REWRITE-FORCE-ALL",
	"    Like CONFIG REWRITE but writes all configuration options, including",
	"    keywords not listed in original configuration file or default values.",
	"DIGEST",
	"    Output a hex signature representing the current DB content.",
	"DIGEST-VALUE <key> [<key> ...]",
	"    Output a hex signature of the values of all the specified keys.",
	"ERROR <string>",
	"    Return a Redis protocol error with <string> as message. Useful for clients",
	"    unit tests to simulate Redis errors.",
	"LEAK <string>",
	"    Create a memory leak of the input string.",
	"LOG <message>",
	"    Write <message> to the server log.",
	"HTSTATS <dbid> [full]",
	"    Return hash table statistics of the specified Redis database.",
	"HTSTATS-KEY <key> [full]",
	"    Like HTSTATS but for the hash table stored at <key>'s value.",
	"LOADAOF",
	"    Flush the AOF buffers on disk and reload the AOF in memory.",
	"REPLICATE <string>",
	"    Replicates the provided string to replicas, allowing data divergence.",
	"OBJECT <key>",
	"    Show low level info about `key` and associated value.",
	"POPULATE <count> [<prefix>] [<size>]",
	"    Create <count> string keys named key:<num>. If <prefix> is specified then",
	"    it is used instead of the 'key' prefix. These are not propagated to",
	"    replicas. Cluster slots are not respected so keys not belonging to the",
	"    current node can be created in cluster mode.",
	"PROTOCOL <type>",
	"    Reply with a test value of the specified type. <type> can be: string,",
	"    integer, double, bignum, null, array, set, map, attrib, push, verbatim,",
	"    true, false.",
	"RELOAD [option ...]",
	"    Save the RDB on disk and reload it back to memory. Valid <option> values:",
	"    * MERGE: conflicting keys will be loaded from RDB.",
	"    * NOFLUSH: the existing database will not be removed before load, but",
	"      conflicting keys will generate an exception and kill the server.",
	"    * NOSAVE: the database will be loaded from an existing RDB file.",
	"    Examples:",
	"    * DEBUG RELOAD: verify that the server is able to persist, flush and reload",
	"      the database.",
	"    * DEBUG RELOAD NOSAVE: replace the current database with the contents of an",
	"      existing RDB file.",
	"    * DEBUG RELOAD NOSAVE NOFLUSH MERGE: add the contents of an existing RDB",
	"      file to the database.",
	"SET-ACTIVE-EXPIRE <0|1>",
	"    Setting it to 0 disables expiring keys (and hash-fields) in background ",
	"    when they are not accessed (otherwise the Redis behavior). Setting it",
	"    to 1 reenables back the default.",
	"QUICKLIST-PACKED-THRESHOLD <size>",
	"    Sets the threshold for elements to be inserted as plain vs packed nodes",
	"    Default value is 1GB, allows values up to 4GB. Setting to 0 restores to default.",
	"SET-SKIP-CHECKSUM-VALIDATION <0|1>",
	"    Enables or disables checksum checks for RDB files and RESTORE's payload.",
	"SLEEP <seconds>",
	"    Stop the server for <seconds>. Decimals allowed.",
	"STRINGMATCH-TEST",
	"    Run a fuzz tester against the stringmatchlen() function.",
	"LISTPACK <key>",
	"    Show low level info about the listpack encoding of <key>.",
	"QUICKLIST <key> [<0|1>]",
	"    Show low level info about the quicklist encoding of <key>.",
	"    The optional argument (0 by default) sets the level of detail",
	"CLIENT-EVICTION",
	"    Show low level client eviction pools info (maxmemory-clients).",
	"PAUSE-CRON <0|1>",
	"    Stop periodic cron job processing.",
	"REPLYBUFFER PEAK-RESET-TIME <NEVER||RESET|time>",
	"    Sets the time (in milliseconds) to wait between client reply buffer peak resets.",
	"    In case NEVER is provided the last observed peak will never be reset",
	"    In case RESET is provided the peak reset time will be restored to the default value",
	"REPLYBUFFER RESIZING <0|1>",
	"    Enable or disable the reply buffer resize cron job",
	"DICT-RESIZING <0|1>",
	"    Enable or disable the main dict and expire dict resizing.",
	"HELP",
	"    Print this help.",
}

debug_more :: proc(c: ^Conn, argv: [][]u8) -> bool {
	sub := argv[1]
	n := len(argv)
	switch {
	case n == 2 && eq_nocase(sub, "help"):
		reply_array(c, len(debug_help))
		for line in debug_help {
			reply_simple(c, line)
		}
	case n == 3 && eq_nocase(sub, "log"):
		plog(LOG_WARNING, "DEBUG LOG: ", string(argv[2]))
		reply_ok(c)
	case n == 3 && eq_nocase(sub, "leak"):
		_ = clone_key(argv[2])
		reply_ok(c)
	case n >= 3 && n <= 5 && eq_nocase(sub, "populate"):
		debug_populate(c, argv)
	case n == 3 && eq_nocase(sub, "listpack"):
		debug_listpack(c, argv[2])
	case (n == 3 || n == 4) && eq_nocase(sub, "quicklist"):
		debug_quicklist(c, argv[2], n == 4 && c_atoi(argv[3]) != 0)
	case n == 3 && eq_nocase(sub, "aof-flush-sleep"):
		aof_flush_sleep_us = i64(i32(c_atoi(argv[2])))
		reply_ok(c)
	case n >= 3 && eq_nocase(sub, "replicate"):
		reply_ok(c)
	case n == 3 && eq_nocase(sub, "error"):
		debug_error(c, argv[2])
	case n >= 3 && eq_nocase(sub, "htstats-key"):
		debug_htstats_key(c, argv[2], n >= 4 && eq_nocase(argv[3], "full"))
	case n == 2 && eq_nocase(sub, "change-repl-id"):
		plog(LOG_NOTICE, "Changing replication IDs after receiving DEBUG change-repl-id")
		repl_id_change()
		repl_id2_clear()
		reply_ok(c)
	case n == 2 && eq_nocase(sub, "stringmatch-test"):
		debug_stringmatch_test()
		reply_simple(c, "Apparently the server did not crash: test passed")
	case n == 2 && eq_nocase(sub, "client-eviction"):
		debug_client_eviction(c)
	case n == 4 && eq_nocase(sub, "replybuffer"):
		debug_replybuffer(c, argv)
	case n == 3 && eq_nocase(sub, "dict-resizing"):
		dict_resizing = c_atoi(argv[2]) != 0
		if dict_resizing {
			db_resize_all()
		}
		reply_ok(c)
	case:
		return false
	}
	return true
}

repl_id_change :: proc() {
	hexd := "0123456789abcdef"
	for i in 0 ..< len(repl_id) {
		repl_id[i] = hexd[rng_next() & 15]
	}
	repl_ids_ready = true
}

@(private = "file")
repl_id2_clear :: proc() {
	for &b in repl_id2 {
		b = '0'
	}
}

replication_ids :: proc() -> (id: []u8, id2: []u8) {
	if !repl_ids_ready {
		repl_id_change()
		repl_id2_clear()
	}
	return repl_id[:], repl_id2[:]
}

@(private = "file")
debug_error :: proc(c: ^Conn, msg: []u8) {
	n := len(msg) + 3
	p := wb_reserve(c, n)
	p[0] = '-'
	for b, i in msg {
		p[i + 1] = ' ' if b == '\r' || b == '\n' else b
	}
	p[n - 2] = '\r'
	p[n - 1] = '\n'
	c.wlen += n
}

@(private = "file")
parse_positive :: proc(c: ^Conn, arg: []u8) -> (i64, bool) {
	v, ok := parse_i64(arg)
	if !ok || v < 0 {
		reply_error(c, ERR_POSITIVE)
		return 0, false
	}
	return v, true
}

@(private = "file")
debug_populate :: proc(c: ^Conn, argv: [][]u8) {
	keys, ok := parse_positive(c, argv[2])
	if !ok {
		return
	}
	if pst.loading {
		reply_error(c, ERR_LOADING)
		return
	}
	valsize: i64 = 0
	if len(argv) == 5 {
		valsize, ok = parse_positive(c, argv[4])
		if !ok {
			return
		}
	}
	prefix := argv[3] if len(argv) >= 4 else transmute([]u8)string("key")
	for nul, i in prefix {
		if nul == 0 {
			prefix = prefix[:i]
			break
		}
	}
	key: [127]u8
	vbuf: [127]u8
	val: [dynamic]u8
	defer delete(val)
	for j in 0 ..< keys {
		kn := copy(key[:], prefix)
		kn += copy(key[kn:], ":")
		digits: [24]u8
		dn := format_i64(&digits[0], j)
		kn += copy(key[kn:], digits[:dn])
		if db_find(key[:kn]) != nil {
			continue
		}
		vn := copy(vbuf[:], "value:")
		vn += copy(vbuf[vn:], digits[:dn])
		v := vbuf[:vn]
		if valsize > 0 {
			resize(&val, int(valsize))
			intrinsics.mem_zero(raw_data(val), int(valsize))
			copy(val[:], vbuf[:vn])
			v = val[:]
		}
		e, _ := db_upsert(key[:kn])
		entry_assign(e, v)
		signal_key(key[:kn])
	}
	reply_ok(c)
}

@(private = "file")
debug_listpack :: proc(c: ^Conn, key: []u8) {
	e := db_find_read_notouch(key)
	if e == nil {
		reply_error(c, ERR_NO_KEY)
		return
	}
	enc := entry_obj_encoding(e)
	if enc != .Listpack && enc != .Listpack_Ex {
		reply_error(c, "ERR Not a listpack encoded object.")
		return
	}
	p: [^]u8
	if l := lt.List(entry_object(e, .List)); l != nil {
		p = l.lp
	} else if h := ht.Hash(entry_object(e, .Hash)); h != nil {
		p = h.lp
	} else if s := st.Set(entry_object(e, .Set)); s != nil {
		p = s.data
	} else if z := zt.Zset(entry_object(e, .Zset)); z != nil {
		p = z.lp
	}
	if p != nil {
		repr := lp.lp_repr(p)
		write_fd(1, repr)
		delete(repr)
	}
	reply_simple(c, "Listpack structure printed on stdout")
}

@(private = "file")
debug_quicklist :: proc(c: ^Conn, key: []u8, full: bool) {
	e := db_find_read_notouch(key)
	if e == nil {
		reply_error(c, ERR_NO_KEY)
		return
	}
	l := lt.List(entry_object(e, .List))
	if l == nil || l.encoding != .Quicklist {
		reply_error(c, "ERR Not a quicklist encoded object.")
		return
	}
	ql := l.ql
	b := &debug_buf
	clear(b)
	sb_str(b, "{count : ")
	sb_int(b, i64(ql.count))
	sb_str(b, "}\n{len : ")
	sb_int(b, i64(ql.len))
	sb_str(b, "}\n{fill : ")
	sb_int(b, i64(ql.fill))
	sb_str(b, "}\n{compress : ")
	sb_int(b, i64(ql.compress))
	sb_str(b, "}\n{bookmark_count : 0}\n")
	i := 0
	for node := ql.head; node != nil; node = node.next {
		sb_str(b, "{quicklist node(")
		sb_int(b, i64(i))
		sb_str(b, ")\n{container : ")
		sb_str(b, "PLAIN" if node.plain else "PACKED")
		sb_str(b, ", encoding: RAW, size: ")
		sb_int(b, i64(node.sz))
		sb_str(b, ", count: ")
		sb_int(b, i64(node.count))
		sb_str(b, ", recompress: 0, attempted_compress: 0}\n")
		i += 1
		if !full {
			continue
		}
		if node.plain {
			sb_str(b, "{ entry : ")
			for k in 0 ..< node.sz {
				if node.entry[k] == 0 {
					break
				}
				sb_byte(b, node.entry[k])
			}
			sb_str(b, " }\n")
		} else {
			sb_str(b, "{ listpack:\n")
			repr := lp.lp_repr(node.entry)
			sb_str(b, repr)
			delete(repr)
			sb_str(b, "}\n")
		}
		sb_str(b, "}\n")
	}
	write_fd(1, string(b[:]))
	reply_simple(c, "Quicklist structure printed on stdout")
}

@(private = "file")
Ht_Stats :: struct {
	size:        int,
	used:        int,
	buckets:     int,
	max_chain:   int,
	total_chain: int,
	clvector:    [DEBUG_STATS_VECTLEN]int,
}

@(private = "file")
ht_stats_add :: proc(s: ^Ht_Stats, counts: []int) {
	for chain in counts {
		if chain == 0 {
			s.clvector[0] += 1
			continue
		}
		s.buckets += 1
		s.clvector[min(chain, DEBUG_STATS_VECTLEN - 1)] += 1
		s.max_chain = max(s.max_chain, chain)
		s.total_chain += chain
	}
}

@(private = "file")
sb_fixed2 :: proc(b: ^[dynamic]u8, v: f32) {
	tmp: [64]u8
	s := strconv.write_float(tmp[:], f64(v), 'f', 2, 64)
	if len(s) > 0 && s[0] == '+' {
		s = s[1:]
	}
	sb_str(b, s)
}

@(private = "file")
ht_stats_msg :: proc(b: ^[dynamic]u8, s: ^Ht_Stats, full: bool, bank: int = 0, title: string = "main hash table") {
	sb_str(b, "Hash table ")
	sb_int(b, i64(bank))
	sb_str(b, " stats (")
	sb_str(b, title)
	sb_str(b, "):\n")
	if s.used == 0 {
		sb_str(b, "No stats available for empty dictionaries\n")
		return
	}
	sb_str(b, " table size: ")
	sb_int(b, i64(s.size))
	sb_str(b, "\n number of elements: ")
	sb_int(b, i64(s.used))
	sb_str(b, "\n")
	if !full {
		return
	}
	sb_str(b, " different slots: ")
	sb_int(b, i64(s.buckets))
	sb_str(b, "\n max chain length: ")
	sb_int(b, i64(s.max_chain))
	sb_str(b, "\n avg chain length (counted): ")
	sb_fixed2(b, f32(s.total_chain) / f32(s.buckets))
	sb_str(b, "\n avg chain length (computed): ")
	sb_fixed2(b, f32(s.used) / f32(s.buckets))
	sb_str(b, "\n Chain length distribution:\n")
	for i in 0 ..< DEBUG_STATS_VECTLEN - 1 {
		if s.clvector[i] == 0 {
			continue
		}
		sb_str(b, "   ")
		sb_int(b, i64(i))
		sb_str(b, ": ")
		sb_int(b, i64(s.clvector[i]))
		sb_str(b, " (")
		sb_fixed2(b, f32(s.clvector[i]) / f32(s.size) * 100)
		sb_str(b, "%)\n")
	}
}

@(private = "file")
home_counts :: proc(cap: int) -> []int {
	return make([]int, cap, context.temp_allocator)
}

@(private = "file")
debug_htstats_key :: proc(c: ^Conn, key: []u8, full: bool) {
	e := db_find_read_notouch(key)
	if e == nil {
		reply_error(c, ERR_NO_KEY)
		return
	}
	stats: [2]Ht_Stats
	count := 1
	found := false
	if h := ht.Hash(entry_object(e, .Hash)); h != nil && h.encoding == .Hashtable {
		t := h.table
		count = 2 if t.resize != nil else 1
		for i in 0 ..< count {
			bank := 1 - i if count == 2 else 0
			slots, cap := ht.table_bank(t, bank)
			s := &stats[i]
			s.size = cap
			s.used = t.count
			if t.resize != nil {
				s.used = t.resize.old_count if bank == 1 else t.count - t.resize.old_count
			}
			if full {
				counts := home_counts(cap)
				for j in 0 ..< cap {
					if ht.blob_live(slots[j].blob) {
						counts[slots[j].hash & u64(cap - 1)] += 1
					}
				}
				ht_stats_add(s, counts)
			}
		}
		found = true
	} else if set := st.Set(entry_object(e, .Set)); set != nil && set.encoding == .Hashtable {
		t := set.table
		count = 2 if t.resize != nil else 1
		for i in 0 ..< count {
			bank := 1 - i if count == 2 else 0
			slots, cap := st.table_bank(t, bank)
			s := &stats[i]
			s.size = cap
			s.used = t.count
			if t.resize != nil {
				s.used = t.resize.old_count if bank == 1 else t.count - t.resize.old_count
			}
			if full {
				counts := home_counts(cap)
				for j in 0 ..< cap {
					if st.blob_live(slots[j].blob) {
						counts[slots[j].hash & u64(cap - 1)] += 1
					}
				}
				ht_stats_add(s, counts)
			}
		}
		found = true
	} else if z := zt.Zset(entry_object(e, .Zset)); z != nil && z.encoding == .Skiplist {
		sl := z.sl
		count = 2 if sl.resize != nil else 1
		for i in 0 ..< count {
			bank := 1 - i if count == 2 else 0
			slots, cap := zt.dict_bank(sl, bank)
			s := &stats[i]
			s.size = cap
			s.used = sl.count
			if sl.resize != nil {
				s.used = sl.resize.old_count if bank == 1 else sl.count - sl.resize.old_count
			}
			if full {
				counts := home_counts(cap)
				for j in 0 ..< cap {
					if zt.node_live(slots[j]) {
						counts[slots[j].hash & u64(cap - 1)] += 1
					}
				}
				ht_stats_add(s, counts)
			}
		}
		found = true
	}
	if !found {
		reply_error(c, "ERR The value stored at the specified key is not represented using an hash table")
		return
	}
	b := &debug_buf
	clear(b)
	ht_stats_msg(b, &stats[0], full)
	if count == 2 {
		ht_stats_msg(b, &stats[1], full, 1, "rehashing target")
	}
	reply_verbatim(c, b[:])
}

@(private = "file")
debug_stringmatch_test :: proc() {
	str: [32]u8
	pat: [32]u8
	for _ in 0 ..< 10_000_000 {
		slen := int(rng_next() % len(str))
		plen := int(rng_next() % len(pat))
		for j in 0 ..< slen {
			str[j] = u8(rng_next() % 128)
		}
		for j in 0 ..< plen {
			pat[j] = u8(rng_next() % 128)
		}
		_ = glob_match(pat[:plen], str[:slen], false)
	}
}

@(private = "file")
debug_client_eviction :: proc(c: ^Conn) {
	if !client_buckets_on {
		reply_error(c, "ERR maxmemory-clients is disabled.")
		return
	}
	count: [CLIENT_BUCKET_MAX_LOG - CLIENT_BUCKET_MIN_LOG + 1]int
	mem: [CLIENT_BUCKET_MAX_LOG - CLIENT_BUCKET_MIN_LOG + 1]int
	for t in srv.conns {
		if t == nil || t.ev_bucket == 0 {
			continue
		}
		k := int(t.ev_bucket) - 1
		count[k] += 1
		mem[k] += conn_memory(t)
	}
	b := &debug_buf
	clear(b)
	for j in 0 ..< len(count) {
		if j == 0 {
			sb_str(b, "bucket          0")
		} else {
			sb_str(b, "bucket ")
			sb_pad_int(b, i64(1) << uint(j - 1 + CLIENT_BUCKET_MIN_LOG), 10)
		}
		if j == len(count) - 1 {
			sb_str(b, "+            : ")
		} else {
			sb_str(b, " - ")
			sb_pad_int(b, (i64(1) << uint(j + CLIENT_BUCKET_MIN_LOG)) - 1, 10)
			sb_str(b, ": ")
		}
		sb_str(b, "tot-mem: ")
		sb_pad_int(b, i64(mem[j]), 10)
		sb_str(b, ", clients: ")
		sb_int(b, i64(count[j]))
		sb_byte(b, '\n')
	}
	reply_verbatim(c, b[:])
}

@(private = "file")
sb_pad_int :: proc(b: ^[dynamic]u8, v: i64, width: int) {
	digits: [24]u8
	n := format_i64(&digits[0], v)
	for _ in n ..< width {
		sb_byte(b, ' ')
	}
	sb_bytes(b, digits[:n])
}

@(private = "file")
debug_replybuffer :: proc(c: ^Conn, argv: [][]u8) {
	switch {
	case eq_nocase(argv[2], "peak-reset-time"):
		if eq_nocase(argv[3], "never") {
			reply_buffer_peak_reset_ms = -1
		} else if eq_nocase(argv[3], "reset") {
			reply_buffer_peak_reset_ms = REPLY_BUFFER_PEAK_RESET_DEFAULT_MS
		} else {
			v, ok := parse_i64(argv[3])
			if !ok {
				reply_error(c, ERR_NOT_INT)
				return
			}
			reply_buffer_peak_reset_ms = v
		}
	case eq_nocase(argv[2], "resizing"):
		reply_buffer_resizing = c_atoi(argv[3]) != 0
	case:
		reply_subcommand_syntax_error(c, argv[1], "DEBUG")
		return
	}
	reply_ok(c)
}

@(cold)
aof_flush_sleep :: #force_no_inline proc() {
	keyspace_signal_owed()
	ts := linux.Time_Spec {
		time_sec  = uint(aof_flush_sleep_us / 1_000_000),
		time_nsec = uint(aof_flush_sleep_us % 1_000_000) * 1000,
	}
	for linux.nanosleep(&ts, &ts) == .EINTR {
	}
}
