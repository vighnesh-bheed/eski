package main

import "base:intrinsics"
import "base:runtime"
import "core:crypto/blake2b"
import "core:sys/linux"
import ht "hashtype"
import lt "listtype"
import "rdb"
import lr "lua_runtime"
import st "settype"
import sm "streamtype"
import zt "zsettype"
import vt "vsettype"
import "sysclock"

PERSIST_FAILED_SAVE_BACKOFF :: 5

PERSIST_COW_SAMPLE_KEYS :: 1024

PERSIST_COW_SAMPLE_MS :: 1000

PERSIST_CMD_SET :: 1024

ERR_BGSAVE_IN_PROGRESS :: "ERR Background save already in progress"

ERR_MISCONF :: "MISCONF Eski is configured to save RDB snapshots, but it's currently unable to persist to disk. Commands that may modify the data set are disabled, because this instance is configured to report errors during writes if RDB snapshotting fails (stop-writes-on-bgsave-error option). Please check the Eski logs for details about the RDB error."

ERR_LOADING :: "LOADING Eski is loading the dataset in memory"

Persist_Sanitize :: enum u8 {
	No,
	Yes,
	Clients,
}

Persist_Protected :: enum u8 {
	No,
	Yes,
	Local,
}

Persist_Cmd_Flag :: enum u8 {
	Write,
	Loading_Ok,
}

Persist_Cmd_Flags :: bit_set[Persist_Cmd_Flag;u8]

Save_Param :: struct {
	seconds: i64,
	changes: i64,
}

Persist_Progress :: struct {
	processed:   i64,
	total:       i64,
	cow:         i64,
	cow_peak:    i64,
	cow_sum:     i64,
	cow_samples: i64,
	cow_ms:      i64,
}

Load_Result :: enum u8 {
	Ok,
	Not_Exist,
	Failed,
}

Persist :: struct {
	dirty:               i64,
	dirty_at_fork:       i64,
	lastsave:            i64,
	bgsave_attempt_at:   i64,
	lastbgsave_err:      bool,
	child_pid:           linux.Pid,
	save_time_start:     i64,
	save_time_last:      i64,
	bgsave_scheduled:    bool,
	stat_rdb_saves:      i64,
	stat_rdb_cow:        i64,
	progress:            ^Persist_Progress,
	loading:             bool,
	loading_start:       i64,
	loading_total:       i64,
	loading_loaded:      i64,
	loading_used_mem:    i64,
	last_load_expired:   i64,
	last_load_loaded:    i64,
	last_load_empty:     i64,
	serve_while_loading: bool,
	in_child:            bool,
	gate_active:         bool,
	save_params:         [dynamic]Save_Param,
	compression:         bool,
	checksum:            bool,
	stop_writes:         bool,
	del_sync_files:      bool,
	key_save_delay:      i64,
	sanitize:            Persist_Sanitize,
	protected:           Persist_Protected,
	skip_checksum:       bool,
	cmds_ready:          bool,
	zset_seeded:         bool,
	dirty_explicit:      bool,
	child_aof:           bool,
	latest_fork_usec:    i64,
	total_forks:         i64,
}

pst := Persist {
	save_time_last  = -1,
	save_time_start = -1,
	compression     = true,
	checksum        = true,
	stop_writes     = true,
}

@(private = "file")
persist_cmd_keys: [PERSIST_CMD_SET]^Command

@(private = "file")
persist_ping_cmd: ^Command

@(private = "file")
persist_cmd_bits: [PERSIST_CMD_SET]Persist_Cmd_Flags

@(private = "file")
persist_write_names := [?]string {
	"eval", "evalsha", "fcall", "function",
	"append", "bitfield", "bitop", "blmove", "blmpop", "blpop", "brpop", "brpoplpush", "bzmpop", "bzpopmax", "bzpopmin",
	"copy", "decr", "decrby", "del", "expire", "expireat", "flushall", "flushdb", "geoadd", "georadius",
	"georadiusbymember", "geosearchstore", "getdel", "getex", "getset", "hdel", "hexpire", "hexpireat", "hincrby",
	"hincrbyfloat", "hmset", "hpersist", "hpexpire", "hpexpireat", "hset", "hsetnx", "incr", "incrby", "incrbyfloat",
	"linsert", "lmove", "lmpop", "lpop", "lpush", "lpushx", "lrem", "lset", "ltrim", "migrate", "move", "mset",
	"msetnx", "persist", "pexpire", "pexpireat", "pfadd", "pfdebug", "pfmerge", "psetex", "rename", "renamenx",
	"restore", "restore-asking", "rpop", "rpoplpush", "rpush", "rpushx", "sadd", "sdiffstore", "set", "setbit",
	"setex", "setnx", "setrange", "sinterstore", "smove", "sort", "spop", "srem", "sunionstore", "swapdb", "unlink",
	"xack", "xadd", "xautoclaim", "xclaim", "xdel", "xgroup", "xreadgroup", "xsetid", "xtrim", "zadd", "zdiffstore",
	"zincrby", "zinterstore", "zmpop", "zpopmax", "zpopmin", "zrangestore", "zrem", "zremrangebylex",
	"zremrangebyrank", "zremrangebyscore", "zunionstore", "VADD", "VREM", "VSETATTR",
}

@(private = "file")
persist_loading_names := [?]string {
	"acl", "auth", "client", "command", "config", "debug", "discard", "echo", "exec", "hello", "info", "lastsave",
	"latency", "monitor", "multi", "psubscribe", "publish", "punsubscribe", "quit", "readonly", "readwrite",
	"replconf", "reset", "role", "select", "shutdown", "slowlog", "spublish", "ssubscribe", "subscribe",
	"sunsubscribe", "time", "unsubscribe", "unwatch", "watch",
}

@(private = "file")
persist_cmd_slot :: #force_inline proc "contextless" (cmd: ^Command) -> int {
	h := u64(uintptr(cmd)) >> 3
	h *= 0x9E3779B97F4A7C15
	i := int(h >> 54) & (PERSIST_CMD_SET - 1)
	for persist_cmd_keys[i] != nil && persist_cmd_keys[i] != cmd {
		i = (i + 1) & (PERSIST_CMD_SET - 1)
	}
	return i
}

@(private = "file")
persist_cmd_mark :: proc(name: string, flag: Persist_Cmd_Flag) {
	for &slot in cmd_table {
		cmd := slot.cmd
		if cmd == nil || cmd.name != name {
			continue
		}
		i := persist_cmd_slot(cmd)
		persist_cmd_keys[i] = cmd
		persist_cmd_bits[i] += {flag}
	}
}

@(private = "file")
persist_cmds_lazy :: proc "contextless" () {
	context = runtime.default_context()
	persist_init_commands()
}

persist_cmd_flags :: #force_inline proc "contextless" (cmd: ^Command) -> Persist_Cmd_Flags {
	if cmd == nil {
		return {}
	}
	if !pst.cmds_ready {
		persist_cmds_lazy()
	}
	i := persist_cmd_slot(cmd)
	if persist_cmd_keys[i] != cmd {
		return {}
	}
	return persist_cmd_bits[i]
}

persist_init_commands :: proc() {
	persist_cmd_keys = {}
	persist_cmd_bits = {}
	persist_ping_cmd = nil
	for &slot in cmd_table {
		if slot.cmd != nil && slot.cmd.name == "ping" {
			persist_ping_cmd = slot.cmd
		}
	}
	for name in persist_write_names {
		persist_cmd_mark(name, .Write)
	}
	for name in persist_loading_names {
		persist_cmd_mark(name, .Loading_Ok)
	}
	marked := false
	for k in persist_cmd_keys {
		if k != nil {
			marked = true
			break
		}
	}
	pst.cmds_ready = marked
}

@(private = "file")
persist_aof_denied :: #force_inline proc "contextless" () -> bool {
	return aof.state != .Disabled && aof.write_err
}

persist_update_gate :: proc "contextless" () {
	pst.gate_active = pst.loading || persist_writes_denied() || persist_aof_denied()
}

persist_writes_denied :: #force_inline proc "contextless" () -> bool {
	return pst.stop_writes && pst.lastbgsave_err && len(pst.save_params) > 0
}

persist_gate :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8 = nil) -> bool {
	flags := persist_cmd_flags(cmd)
	if pst.loading && .Loading_Ok not_in flags {
		reply_error(c, ERR_LOADING)
		return true
	}
	write := .Write in flags
	if lua_is_eval(cmd) {
		write = lua_outer_persistence_write(cmd, argv)
	} else if cmd != nil && cmd.handler == cmd_function && !is_write_command(cmd.name, argv) {
		write = false
	}
	if write || (cmd != nil && cmd == persist_ping_cmd) {
		if persist_writes_denied() {
			reply_error(c, ERR_MISCONF)
			return true
		}
		if persist_aof_denied() {
			reply_error_parts(c, "MISCONF Errors writing to the AOF file: ", errno_text(aof.write_errno))
			return true
		}
	}
	return false
}

persist_note :: #force_inline proc(c: ^Conn, cmd: ^Command, argv: [][]u8, pending: int, dirty_before: i64) {
	flags := persist_cmd_flags(cmd)
	if pst.dirty_explicit {
		pst.dirty_explicit = false
	} else if pst.dirty == dirty_before && .Write in flags && !persist_failed_reply(c, pending) {
		pst.dirty += 1
	}
	aof_after_command(c, cmd, flags, argv, pending)
}

@(private = "file")
persist_failed_reply :: #force_inline proc "contextless" (c: ^Conn, pending: int) -> bool {
	return c != nil && pending >= 0 && c.wlen > pending && c.wbuf[pending] == '-'
}

log_fd: linux.Fd = 1

@(private)
MONTHS := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

persist_filename :: proc "contextless" () -> string {
	if len(cfg.dbfilename) == 0 {
		return "dump.rdb"
	}
	return cfg.dbfilename
}

Slot_Value :: struct {
	str:  []u8,
	obj:  rawptr,
	type: Obj_Type,
}

@(private = "file")
persist_type_byte :: proc "contextless" (v: Slot_Value) -> u8 {
	if v.obj == nil {
		return rdb.TYPE_STRING
	}
	switch v.type {
	case .String:
		return rdb.TYPE_STRING
	case .List:
		return lt.rdb_type(cast(lt.List)v.obj)
	case .Set:
		return st.rdb_type(cast(st.Set)v.obj)
	case .Zset:
		return zt.rdb_type(cast(zt.Zset)v.obj)
	case .Hash:
		return ht.rdb_type(cast(ht.Hash)v.obj)
	case .Stream:
		return sm.rdb_type(cast(sm.Stream)v.obj)
	case .Vectorset:
		return rdb.TYPE_MODULE_2
	}
	return rdb.TYPE_STRING
}

persist_write_value :: proc(w: ^rdb.Writer, key: []u8, v: Slot_Value, with_key: bool = true) -> bool {
	rdb.put_type(w, persist_type_byte(v))
	if with_key {
		rdb.put_string(w, key)
	}
	if v.obj == nil || v.type == .String {
		rdb.put_string(w, v.str)
		return !w.failed
	}
	switch v.type {
	case .String:
	case .List:
		lt.rdb_save(w, cast(lt.List)v.obj)
	case .Set:
		st.rdb_save(w, cast(st.Set)v.obj)
	case .Zset:
		zt.rdb_save(w, cast(zt.Zset)v.obj)
	case .Hash:
		ht.rdb_save(w, cast(ht.Hash)v.obj)
	case .Stream:
		sm.rdb_save(w, cast(sm.Stream)v.obj)
	case .Vectorset:
		vset_rdb_save(w, cast(vt.Vset)v.obj)
	}
	return !w.failed
}

@(private = "file")
persist_slot_entry :: #force_inline proc "contextless" (db: ^Db, t: ^Table, i: int) -> Entry {
	return Entry {
		db = db,
		mp = &t.slots[i].meta,
		kp = &t.slots[i].key,
		vp = &t.slots[i].val,
		expire_at = slot_deadline(db, t, i),
	}
}

@(private = "file")
persist_table_count :: #force_inline proc "contextless" (db: ^Db) -> int {
	return 2 if db.rehash_idx >= 0 else 1
}

@(private = "file")
persist_table_ok :: #force_inline proc "contextless" (t: ^Table) -> bool {
	return t.ctrl != nil && t.cap > 0 && t.live > 0
}

persist_write_rdb :: proc(w: ^rdb.Writer, aof_base: bool = false) -> bool {
	rdb.put_header(w, persist_unix_now(), i64(mem_used()), aof_base)
	lua_libraries_save(w)
	processed: i64 = 0
	lru := persist_policy_lru()
	lfu := persist_policy_lfu()
	for &db, id in dbs {
		size := db_size_of(&db)
		if size == 0 {
			continue
		}
		rdb.put_u8(w, rdb.OPCODE_SELECTDB)
		rdb.put_len(w, u64(id))
		rdb.put_u8(w, rdb.OPCODE_RESIZEDB)
		rdb.put_len(w, u64(size))
		rdb.put_len(w, u64(max(db.expires, 0)))
		for bank in 0 ..< persist_table_count(&db) {
			t := &db.t[bank]
			if !persist_table_ok(t) {
				continue
			}
			for g: u64 = 0; g < t.groups; g += 1 {
				bits := group_full(group_load(t.ctrl, g))
				for bits != 0 {
					i := int(g) * GROUP_SLOTS + int(intrinsics.count_trailing_zeros(bits))
					bits &= bits - 1
					kp := &t.slots[i].key
					expire := slot_deadline(&db, t, i)
					if expire != 0 {
						rdb.put_u8(w, rdb.OPCODE_EXPIRETIME_MS)
						rdb.put_ms(w, expire)
					}
					if lru || lfu {
						e := persist_slot_entry(&db, t, i)
						if lru {
							rdb.put_u8(w, rdb.OPCODE_IDLE)
							rdb.put_len(w, u64(max(entry_idle_seconds(&e), 0)))
						} else {
							rdb.put_u8(w, rdb.OPCODE_FREQ)
							rdb.put_u8(w, u8(clamp(entry_tally(&e), 0, 255)))
						}
					}
					v := persist_slot_value(&db, kp, &t.slots[i].val)
					if !persist_write_value(w, key_bytes(kp, &db.slab), v, true) {
						return false
					}
					processed += 1
					persist_child_progress(processed)
				}
			}
		}
	}
	rdb.put_trailer(w)
	return rdb.writer_flush(w)
}

@(private = "file")
persist_publish_progress :: proc(processed: i64) {
	p := pst.progress
	if p == nil {
		return
	}
	intrinsics.volatile_store(&p.processed, processed)
	persist_pace_cow(p, processed)
}

@(private = "file")
persist_child_progress :: proc(processed: i64) {
	persist_publish_progress(processed)
	if delay := pst.key_save_delay; delay != 0 {
		persist_debug_delay(delay)
	}
}

@(private = "file")
persist_save_internal :: proc(filename: string) -> bool {
	if access_persistence_off() {
		plog(LOG_WARNING, "RDB save refused: ", LABEL_PERSISTENCE_ON)
		return false
	}
	tbuf: [64]u8
	temp := persist_temp_name(linux.getpid(), tbuf[:])
	tcbuf: [80]u8
	ctemp := persist_cstr(temp, tcbuf[:])
	if !pst.in_child {
		intrinsics.atomic_store_explicit(&persist_signal_saving, 1, .Release)
	}
	defer {
		if !pst.in_child { intrinsics.atomic_store_explicit(&persist_signal_saving, 0, .Release) }
	}
	fd, err := linux.open(ctemp, {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if err != .NONE {
		cwd: [PERSIST_PATH_MAX]u8
		plog(LOG_WARNING, "Failed opening the temp RDB file ", temp, " (in server root dir ", persist_cwd(cwd[:]), ") for saving: ", errno_text(err))
		return false
	}
	w: rdb.Writer
	rdb.writer_init_file(&w, fd, pst.compression, pst.checksum)
	if cfg.rdb_save_incremental_fsync {
		w.sync_every = 4 << 20
	}
	good := persist_write_rdb(&w, false)
	good = rdb.writer_flush(&w) && good
	write_errno := w.errno
	rdb.writer_destroy(&w)
	if good {
		if serr := linux.fsync(fd); serr != .NONE {
			good = false
			write_errno = serr
		}
	}
	linux.close(fd)
	if !good {
		plog(LOG_WARNING, "Write error saving DB on disk: ", errno_text(write_errno))
		linux.unlink(ctemp)
		return false
	}
	fbuf: [PERSIST_PATH_MAX]u8
	cfinal := persist_cstr(filename, fbuf[:])
	if rerr := linux.rename(ctemp, cfinal); rerr != .NONE {
		cwd: [PERSIST_PATH_MAX]u8
		plog(LOG_WARNING, "Error moving temp DB file ", temp, " on the final destination ", filename, " (in server root dir ", persist_cwd(cwd[:]), "): ", errno_text(rerr))
		linux.unlink(ctemp)
		return false
	}
	if dfd, derr := linux.open(".", {.DIRECTORY, .CLOEXEC}); derr == .NONE {
		linux.fsync(dfd)
		linux.close(dfd)
	}
	plog(LOG_NOTICE, "DB saved on disk")
	return true
}

persist_rdb_save :: proc() -> bool {
	keyspace_fence()
	if pst.child_pid > 0 && !pst.child_aof {
		plog(LOG_WARNING, "Background save already in progress")
		return false
	}
	good := persist_save_internal(persist_filename())
	pst.stat_rdb_saves += 1
	if good {
		pst.dirty = 0
		pst.lastsave = persist_unix_now()
		pst.lastbgsave_err = false
	}
	persist_update_gate()
	return good
}

persist_bgsave :: proc() -> bool {
	keyspace_fence()
	if access_persistence_off() {
		plog(LOG_WARNING, "Background save refused: ", LABEL_PERSISTENCE_ON)
		return false
	}
	if pst.child_pid > 0 {
		return false
	}
	pst.dirty_at_fork = pst.dirty
	pst.bgsave_attempt_at = persist_unix_now()
	persist_progress_prepare()
	keyspace_before_fork()
	compute_before_fork()
	pid, err := runtime_fork()
	if err != .NONE {
		pst.lastbgsave_err = true
		plog(LOG_WARNING, "Can't save in background: fork: ", errno_text(err))
		persist_update_gate()
		return false
	}
	if pid == 0 {
		persist_child_setup()
		runtime_tuning_enter(.Rdb)
		good := persist_save_internal(persist_filename())
		if good {
			persist_sample_cow()
			persist_log_cow("Fork CoW for RDB: current ")
		}
		linux.exit_group(0 if good else 1)
	}
	pst.latest_fork_usec = runtime_fork_last_usec
	pst.total_forks += 1
	pst.stat_rdb_saves += 1
	pst.child_pid = pid
	pst.child_aof = false
	pst.save_time_start = persist_unix_now()
	pst.bgsave_scheduled = false
	tmp: [24]u8
	n := format_i64(&tmp[0], i64(pid))
	plog(LOG_NOTICE, "Background saving started by pid ", string(tmp[:n]))
	return true
}

persist_remove_temp :: proc(pid: linux.Pid) {
	tbuf: [64]u8
	name := persist_temp_name(pid, tbuf[:])
	cbuf: [80]u8
	linux.unlink(persist_cstr(name, cbuf[:]))
}

Persist_Child_Result :: enum u8 {
	Saved,
	Failed,
	Killed,
}

persist_kill_child :: proc() {
	pid := pst.child_pid
	if pid <= 0 || pst.child_aof {
		return
	}
	linux.kill(pid, .SIGUSR1)
	persist_reap(pid)
	persist_remove_temp(pid)
	persist_rdb_child_finished(.Killed, int(linux.Signal.SIGUSR1))
}

@(private = "file")
persist_reap :: proc(pid: linux.Pid) {
	keyspace_signal_owed()
	status: u32
	for {
		_, err := linux.wait4(pid, &status, {}, nil)
		if err != .EINTR {
			return
		}
	}
}

@(private = "file")
persist_rdb_child_finished :: proc(result: Persist_Child_Result, signal: int = 0) {
	now := persist_unix_now()
	switch result {
	case .Saved:
		plog(LOG_NOTICE, "Background saving terminated with success")
		pst.dirty = max(pst.dirty - pst.dirty_at_fork, 0)
		pst.lastsave = now
		pst.lastbgsave_err = false
	case .Failed:
		plog(LOG_WARNING, "Background saving error")
		pst.lastbgsave_err = true
	case .Killed:
		digits: [24]u8
		width := format_i64(&digits[0], i64(signal))
		plog(LOG_WARNING, "Background saving terminated by signal ", string(digits[:width]))
		if pst.child_pid > 0 {
			persist_remove_temp(pst.child_pid)
		}
		if signal != int(linux.Signal.SIGUSR1) {
			pst.lastbgsave_err = true
		}
	}
	if p := pst.progress; p != nil {
		pst.stat_rdb_cow = intrinsics.volatile_load(&p.cow)
	}
	started := pst.save_time_start
	pst.save_time_start = -1
	if started >= 0 {
		pst.save_time_last = now - started
	}
	pst.child_pid, pst.child_aof = 0, false
	persist_update_gate()
}

persist_check_child :: proc() {
	pid := pst.child_pid
	if pid <= 0 {
		return
	}
	status: u32
	got, err := linux.wait4(pid, &status, {.WNOHANG}, nil)
	if err == .EINTR || (err == .NONE && got == 0) {
		return
	}
	exitcode, bysignal := 1, 0
	if err == .NONE && got == pid {
		if status & 0x7f == 0 {
			exitcode = int((status >> 8) & 0xff)
		} else {
			bysignal = int(status & 0x7f)
			exitcode = 0
		}
	} else if pst.child_aof {
		pst.child_pid = 0
		pst.child_aof = false
		return
	}
	if pst.child_aof {
		aof_rewrite_done(exitcode, bysignal)
		if pst.child_pid == pid {
			pst.child_pid = 0
			pst.child_aof = false
		}
		return
	}
	switch {
	case bysignal != 0:
		persist_rdb_child_finished(.Killed, bysignal)
	case exitcode == 0:
		persist_rdb_child_finished(.Saved)
	case:
		persist_rdb_child_finished(.Failed)
	}
}

Loaded_Value :: struct {
	type: Obj_Type,
	str:  []u8,
	obj:  rawptr,
}

@(private = "file")
persist_seed_zsets :: proc() {
	if !pst.zset_seeded {
		zset_seed()
		pst.zset_seeded = true
	}
}

persist_deep_sanitize :: proc "contextless" (restore: bool) -> bool {
	switch pst.sanitize {
	case .Yes:
		return true
	case .Clients:
		return restore && !aof.loading
	case .No:
	}
	return false
}

@(private = "file")
STRING_SLOT :: 2

@(private = "file")
KEY_SLOT :: 3

persist_load_object :: proc(r: ^rdb.Reader, rdbtype: int, deep: bool) -> (v: Loaded_Value) {
	switch rdbtype {
	case rdb.TYPE_STRING:
		s, good := rdb.get_string(r, STRING_SLOT)
		if good {
			v.type = .String
			v.str = s
		}
	case rdb.TYPE_LIST, rdb.TYPE_LIST_ZIPLIST, rdb.TYPE_LIST_QUICKLIST, rdb.TYPE_LIST_QUICKLIST_2:
		l := lt.rdb_load(r, rdbtype, deep)
		if l != nil {
			v.type = .List
			v.obj = l
		}
	case rdb.TYPE_SET, rdb.TYPE_SET_INTSET, rdb.TYPE_SET_LISTPACK:
		s := st.rdb_load(r, rdbtype, deep)
		if s != nil {
			v.type = .Set
			v.obj = s
		}
	case rdb.TYPE_ZSET, rdb.TYPE_ZSET_2, rdb.TYPE_ZSET_ZIPLIST, rdb.TYPE_ZSET_LISTPACK:
		persist_seed_zsets()
		z := zt.rdb_load(r, rdbtype, deep)
		if z != nil {
			v.type = .Zset
			v.obj = z
		}
	case rdb.TYPE_HASH, rdb.TYPE_HASH_ZIPMAP, rdb.TYPE_HASH_ZIPLIST, rdb.TYPE_HASH_LISTPACK, rdb.TYPE_HASH_TABLE_EX_RC, rdb.TYPE_HASH_LISTPACK_EX_RC, rdb.TYPE_HASH_TABLE_EX, rdb.TYPE_HASH_LISTPACK_EX:
		h := ht.rdb_load(r, rdbtype, deep)
		if h != nil {
			v.type = .Hash
			v.obj = h
		}
	case rdb.TYPE_STREAM_LISTPACKS, rdb.TYPE_STREAM_LISTPACKS_2, rdb.TYPE_STREAM_LISTPACKS_3:
		s := sm.rdb_load(r, rdbtype, deep)
		if s != nil {
			v.type = .Stream
			v.obj = s
		}
	case rdb.TYPE_MODULE_PRE_GA:
		rdb.corrupt(r, "holds module data in a pre-release format")
	case rdb.TYPE_MODULE_2:
		id := rdb.get_len(r)
		if !rdb.ok(r) {
			rdb.corrupt(r, "holds module data with an unreadable module id")
			return
		}
		if id == VSET_RDB_MODULE_ID {
			if vs := vset_rdb_load(r); vs != nil {
				v.type = .Vectorset
				v.obj = vs
			}
			return
		}
		name: [9]u8
		rdb.corrupt(r, "holds data of unknown module type '", 0, false, rdb.module_name_by_id(id, &name))
		rdb.corrupt_append(r, "'")
	case:
		rdb.corrupt(r, "has unknown encoding type ", u64(max(rdbtype, 0)), true)
	}
	if !rdb.ok(r) && v.obj != nil {
		persist_free_loaded(v)
		v = {}
	}
	return
}

persist_free_loaded :: proc(v: Loaded_Value) {
	if v.obj != nil && v.type != .String {
		object_release_any(v.type, v.obj)
	}
}

persist_attach :: proc(e: ^Entry, key: []u8, v: Loaded_Value) {
	switch v.type {
	case .String:
		entry_assign(e, v.str)
	case .List:
		list_copy_attach(e, v.obj)
	case .Set:
		set_copy_attach(e, v.obj)
	case .Zset:
		zset_copy_attach(e, key, v.obj, 0)
	case .Hash:
		h := cast(ht.Hash)v.obj
		h.acct = ht.memory_usage(h)
		hash_copy_attach(e, key, v.obj, ht.earliest_deadline(h))
		hash_sync(e.db, h)
	case .Stream:
		s := cast(sm.Stream)v.obj
		s.acct = sm.memory_usage(s)
		stream_copy_attach(e, v.obj)
	case .Vectorset:
		vset_attach(e, cast(vt.Vset)v.obj)
	}
}

@(private = "file")
PERSIST_LOG_KEY_MAX :: 256

@(private = "file")
Corrupt_Phrase :: struct {
	prefix: string,
	phrase: string,
}

@(private = "file")
persist_corrupt_phrases := [?]Corrupt_Phrase {
	{"Unknown length encoding", "has a length field with an unknown encoding"},
	{"Invalid length", "has an invalid length field"},
	{"Invalid string length", "holds a string with an invalid length"},
	{"Invalid LZF compressed string", "holds compressed data that does not decompress"},
	{"Unknown RDB string encoding type", "holds a string with an unknown encoding"},
	{"Invalid double value", "holds an invalid floating point value"},
	{"Listpack re-added with existing key", "has a duplicate node"},
	{"Empty listpack inside stream", "has an empty node"},
	{"Stream node key entry", "has a node whose key is not an entry ID"},
	{"Stream listpack", "has a node that fails its integrity check"},
	{"Stream length inconsistent", "has a length that does not match its nodes"},
	{"Duplicated consumer group name", "has a duplicate consumer group"},
	{"Duplicate stream consumer", "has a duplicate consumer"},
	{"Duplicated global PEL entry", "has a duplicate pending entry"},
	{"Duplicated consumer PEL entry", "has a pending entry claimed by two consumers"},
	{"Consumer entry not found", "has a consumer pending entry that its group lacks"},
	{"Stream CG PEL entry without consumer", "has a pending entry without a consumer"},
	{"Error reading the consumer", "has an unreadable consumer or group name"},
	{"Stream", "has malformed metadata"},
	{"Duplicate set members", "has duplicate members"},
	{"Duplicate zset fields", "has duplicate members"},
	{"Zset with NAN score", "has a score that is not a number"},
	{"Duplicate hash fields", "has duplicate fields"},
	{"Hash with dup elements", "has duplicate fields"},
	{"has an invalid field expiry", "has an invalid field expiry"},
	{"Invalid set length", "has an invalid length"},
	{"Invalid sorted set length", "has an invalid length"},
	{"Invalid set type", "has an unknown encoding"},
	{"Unknown sorted set encoding", "has an unknown encoding"},
	{"Unsupported hash type", "has an unknown encoding"},
}

@(private = "file")
persist_has_prefix :: proc "contextless" (s: string, prefix: string) -> bool {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}

@(private = "file")
persist_corrupt_phrase :: proc "contextless" (reason: string) -> string {
	for p in persist_corrupt_phrases {
		if persist_has_prefix(reason, p.prefix) {
			return p.phrase
		}
	}
	marker := "integrity check failed"
	for i := 0; i + len(marker) <= len(reason); i += 1 {
		if reason[i:i + len(marker)] == marker {
			return "fails its integrity check"
		}
	}
	return "is malformed"
}

@(private = "file")
persist_type_word :: proc "contextless" (rdbtype: int) -> string {
	switch rdbtype {
	case rdb.TYPE_STRING:
		return "string"
	case rdb.TYPE_LIST, rdb.TYPE_LIST_ZIPLIST, rdb.TYPE_LIST_QUICKLIST, rdb.TYPE_LIST_QUICKLIST_2:
		return "list"
	case rdb.TYPE_SET, rdb.TYPE_SET_INTSET, rdb.TYPE_SET_LISTPACK:
		return "set"
	case rdb.TYPE_ZSET, rdb.TYPE_ZSET_2, rdb.TYPE_ZSET_ZIPLIST, rdb.TYPE_ZSET_LISTPACK:
		return "sorted set"
	case rdb.TYPE_HASH, rdb.TYPE_HASH_ZIPMAP, rdb.TYPE_HASH_ZIPLIST, rdb.TYPE_HASH_LISTPACK, rdb.TYPE_HASH_TABLE_EX_RC, rdb.TYPE_HASH_LISTPACK_EX_RC, rdb.TYPE_HASH_TABLE_EX, rdb.TYPE_HASH_LISTPACK_EX:
		return "hash"
	case rdb.TYPE_STREAM_LISTPACKS, rdb.TYPE_STREAM_LISTPACKS_2, rdb.TYPE_STREAM_LISTPACKS_3:
		return "stream"
	}
	return ""
}

@(private = "file")
persist_ll_key :: proc "contextless" (l: ^Log_Line, key: []u8) {
	hexd := "0123456789abcdef"
	ll_str(l, "'")
	for ch, i in key {
		if i == PERSIST_LOG_KEY_MAX {
			ll_str(l, "...")
			break
		}
		if ch == '\\' || ch == '\'' {
			esc := [2]u8{'\\', ch}
			ll_bytes(l, esc[:])
		} else if ch >= 0x20 && ch < 0x7f {
			one := [1]u8{ch}
			ll_bytes(l, one[:])
		} else {
			hex := [4]u8{'\\', 'x', hexd[ch >> 4], hexd[ch & 15]}
			ll_bytes(l, hex[:])
		}
	}
	ll_str(l, "'")
}

@(private = "file")
persist_fail_begin :: proc "contextless" (l: ^Log_Line, r: ^rdb.Reader) {
	ll_begin(l, LOG_WARNING)
	ll_str(l, "Loading the RDB file failed at byte offset ")
	ll_int(l, rdb.reader_offset(r))
	ll_str(l, ": ")
}

@(private = "file")
persist_fail_end :: proc "contextless" (l: ^Log_Line) -> ! {
	ll_end(l)
	linux.exit_group(1)
}

@(private = "file")
persist_fail_with :: proc "contextless" (r: ^rdb.Reader, parts: ..string) -> ! {
	l: Log_Line
	persist_fail_begin(&l, r)
	for p in parts {
		ll_str(&l, p)
	}
	persist_fail_end(&l)
}

@(private = "file")
persist_load_failed :: proc "contextless" (r: ^rdb.Reader) -> ! {
	if r.status == .Corrupt {
		persist_fail_with(r, "the file ", persist_corrupt_phrase(rdb.reader_reason(r)))
	}
	persist_fail_with(r, "unexpected end of file")
}

@(private = "file")
persist_value_failed :: proc "contextless" (r: ^rdb.Reader, key: []u8, rdbtype: int) -> ! {
	word := persist_type_word(rdbtype)
	l: Log_Line
	persist_fail_begin(&l, r)
	if r.status != .Corrupt {
		ll_str(&l, "unexpected end of file, the ")
		ll_str(&l, word if word != "" else "value")
		ll_str(&l, " at key ")
		persist_ll_key(&l, key)
		ll_str(&l, " is truncated")
	} else if word == "" {
		ll_str(&l, "key ")
		persist_ll_key(&l, key)
		ll_str(&l, " ")
		ll_str(&l, rdb.reader_reason(r))
	} else {
		ll_str(&l, "the ")
		ll_str(&l, word)
		ll_str(&l, " at key ")
		persist_ll_key(&l, key)
		ll_str(&l, " ")
		ll_str(&l, persist_corrupt_phrase(rdb.reader_reason(r)))
	}
	persist_fail_end(&l)
}

@(private = "file")
persist_log_empty_key :: proc "contextless" (key: []u8) {
	l: Log_Line
	ll_begin(&l, LOG_VERBOSE)
	ll_str(&l, "Skipping empty key ")
	persist_ll_key(&l, key)
	ll_str(&l, " while loading the RDB file")
	ll_end(&l)
}

persist_log_load_done :: proc "contextless" () {
	l: Log_Line
	ll_begin(&l, LOG_NOTICE)
	ll_str(&l, "Done loading RDB, keys loaded: ")
	ll_int(&l, pst.last_load_loaded)
	ll_str(&l, ", keys expired: ")
	ll_int(&l, pst.last_load_expired)
	if pst.last_load_empty > 0 {
		ll_str(&l, ", empty keys skipped: ")
		ll_int(&l, pst.last_load_empty)
	}
	ll_str(&l, ".")
	ll_end(&l)
}

@(private = "file")
persist_aux_int :: proc(val: []u8) -> (i64, bool) {
	return rdb.string2ll(val)
}

@(private = "file")
persist_handle_aux :: proc(key: []u8, val: []u8) {
	name := string(key)
	switch name {
	case "redis-ver":
		plog(LOG_NOTICE, "Loading RDB produced by version ", string(val))
	case "ctime":
		if t, good := persist_aux_int(val); good {
			age := persist_unix_now() - t
			l: Log_Line
			ll_begin(&l, LOG_NOTICE)
			ll_str(&l, "RDB age ")
			ll_int(&l, max(age, 0))
			ll_str(&l, " seconds")
			ll_end(&l)
		}
	case "used-mem":
		if m, good := persist_aux_int(val); good {
			pst.loading_used_mem = m
			l: Log_Line
			ll_begin(&l, LOG_NOTICE)
			ll_str(&l, "RDB memory usage when created ")
			ll_fixed(&l, f64(m) / (1024 * 1024), 2)
			ll_str(&l, " Mb")
			ll_end(&l)
		}
	case "aof-base":
		if v, good := persist_aux_int(val); good && v != 0 {
			plog(LOG_NOTICE, "RDB is base AOF")
		}
	case "redis-bits", "aof-preamble", "repl-stream-db", "repl-id", "repl-offset", "lua":
	case:
		plog(LOG_DEBUG, "Unrecognized RDB AUX field: '", name, "'")
	}
}

Access_Hint_Kind :: enum u8 {
	None,
	Idle_Seconds,
	Frequency,
}

Access_Hint :: struct {
	kind:  Access_Hint_Kind,
	value: i64,
}

persist_apply_access_hint :: proc(e: ^Entry, hint: Access_Hint) {
	counting := persist_policy_lfu()
	switch hint.kind {
	case .None:
	case .Frequency:
		if counting {
			entry_restore_tally(e, hint.value)
		}
	case .Idle_Seconds:
		if !counting {
			entry_restore_idle(e, hint.value)
		}
	}
}

@(private = "file")
persist_skip_expired: bool

@(private = "file")
persist_load_version :: proc(magic: []u8) -> int {
	if len(magic) != 9 || string(magic[:5]) != "REDIS" {
		return -1
	}
	v := 0
	for c in magic[5:] {
		if c < '0' || c > '9' {
			return -1
		}
		v = v * 10 + int(c - '0')
	}
	return v
}

persist_load_stream :: proc(r: ^rdb.Reader, merge: bool, preserve_libraries: bool = false) -> Load_Result {
	magic, got := rdb.take(r, 9)
	if !got {
		persist_load_failed(r)
	}
	version := persist_load_version(magic)
	if version < 0 {
		plog(LOG_WARNING, "Wrong signature trying to load DB from file")
		return .Failed
	}
	if version < 1 || version > rdb.RDB_VERSION {
		tmp: [24]u8
		n := format_i64(&tmp[0], i64(version))
		plog(LOG_WARNING, "Can't handle RDB format version ", string(tmp[:n]))
		return .Failed
	}
	if !preserve_libraries {
		lua_library_flush(false)
	}
	deep := persist_deep_sanitize(false)
	pst.last_load_loaded = 0
	pst.last_load_expired = 0
	pst.last_load_empty = 0
	db := &dbs[0]
	expire: i64 = -1
	hint: Access_Hint
	now_ms := persist_unix_ms()
	keys_seen: i64 = 0
	for {
		t := rdb.get_type(r)
		if t < 0 {
			persist_load_failed(r)
		}
		switch t {
		case rdb.OPCODE_EXPIRETIME:
			secs, good := rdb.get_u32_le(r)
			if !good {
				persist_load_failed(r)
			}
			expire = i64(i32(secs)) * 1000
			continue
		case rdb.OPCODE_EXPIRETIME_MS:
			ms, good := rdb.get_ms(r)
			if !good {
				persist_load_failed(r)
			}
			expire = ms
			continue
		case rdb.OPCODE_FREQ:
			f, good := rdb.get_u8(r)
			if !good {
				persist_load_failed(r)
			}
			hint = Access_Hint{.Frequency, i64(f)}
			continue
		case rdb.OPCODE_IDLE:
			idle := rdb.get_len(r)
			if !rdb.ok(r) {
				persist_load_failed(r)
			}
			if hint.kind != .Frequency {
				hint = Access_Hint{.Idle_Seconds, i64(min(idle, u64(max(i64))))}
			}
			continue
		case rdb.OPCODE_EOF:
		case rdb.OPCODE_SELECTDB:
			id := rdb.get_len(r)
			if !rdb.ok(r) {
				persist_load_failed(r)
			}
			if id >= u64(len(dbs)) {
				tmp: [24]u8
				n := format_i64(&tmp[0], i64(len(dbs)))
				plog(LOG_WARNING, "FATAL: Data file was created with a server configured to handle more than ", string(tmp[:n]), " databases. Exiting")
				linux.exit_group(1)
			}
			db = &dbs[id]
			continue
		case rdb.OPCODE_RESIZEDB:
			rdb.get_len(r)
			rdb.get_len(r)
			if !rdb.ok(r) {
				persist_load_failed(r)
			}
			continue
		case rdb.OPCODE_SLOT_INFO:
			rdb.get_len(r)
			rdb.get_len(r)
			rdb.get_len(r)
			if !rdb.ok(r) {
				persist_load_failed(r)
			}
			continue
		case rdb.OPCODE_AUX:
			k, kgood := rdb.get_string(r, 0)
			if !kgood {
				persist_load_failed(r)
			}
			v, vgood := rdb.get_string(r, 1)
			if !vgood {
				persist_load_failed(r)
			}
			persist_handle_aux(k, v)
			continue
		case rdb.OPCODE_MODULE_AUX:
			id := rdb.get_len(r)
			if !rdb.ok(r) {
				persist_load_failed(r)
			}
			name: [9]u8
			persist_fail_with(r, "the file carries auxiliary data of unknown module type '", rdb.module_name_by_id(id, &name), "'")
		case rdb.OPCODE_FUNCTION2:
			code, good := rdb.get_string(r, 0)
			if !good {
				persist_load_failed(r)
			}
			capture := Conn{fd = -1, resp = 2, db = db}
			library := lua_library_prepare(code, &capture)
			mem_free(capture.wbuf)
			if library == nil {
				persist_fail_with(r, "function library compilation failed")
			}
			old := lua_library_find(library.name)
			if old != nil && !merge {
				lua_library_free(library)
				return .Failed
			}
			if lua_library_collision(library, old) != nil {
				lua_library_free(library)
				return .Failed
			}
			if old != nil {
				lua_library_unlink(old, false)
			}
			lua_library_publish(library)
			continue
		case rdb.OPCODE_FUNCTION_PRE_GA:
			persist_fail_with(r, "pre-release function library format is unsupported")
		case:
			key, kgood := rdb.get_string(r, KEY_SLOT)
			if !kgood {
				persist_load_failed(r)
			}
			v := persist_load_object(r, t, deep)
			if r.status == .Empty_Key {
				r.status = .Ok
				persist_log_empty_key(key)
				pst.last_load_empty += 1
				expire, hint = -1, {}
				continue
			}
			if !rdb.ok(r) {
				persist_value_failed(r, key, t)
			}
			keys_seen += 1
			if persist_skip_expired && expire != -1 && expire < now_ms {
				persist_free_loaded(v)
				pst.last_load_expired += 1
				expire, hint = -1, {}
				continue
			}
			due := expire if expire != -1 else 0
			e, created := db_upsert_timed_in(db, key, due)
			if !created {
				if !merge {
					l: Log_Line
					persist_fail_begin(&l, r)
					ll_str(&l, "duplicated key ")
					persist_ll_key(&l, key)
					ll_str(&l, " in database ")
					ll_int(&l, i64(db.id))
					persist_fail_end(&l)
				}
				db_remove_in(db, key)
				e, _ = db_upsert_timed_in(db, key, due)
			}
			persist_attach(e, key, v)
			if expire != -1 {
				entry_set_expire(e, expire)
			}
			persist_apply_access_hint(e, hint)
			pst.last_load_loaded += 1
			expire, hint = -1, {}
			if cfg.key_load_delay != 0 {
				persist_debug_delay(cfg.key_load_delay)
			}
			rdb.reader_poll_progress(r)
			if keys_seen & 1023 == 0 && persist_signal_pending() && pst.loading {
				persist_signal_loading_exit()
			}
			continue
		}
		break
	}
	if version >= 5 {
		expected := rdb.reader_checksum(r)
		trailer, tgood := rdb.take(r, 8)
		if !tgood {
			persist_load_failed(r)
		}
		stored: u64 = 0
		for i in 0 ..< 8 {
			stored |= u64(trailer[i]) << (8 * uint(i))
		}
		if r.checksum && !pst.skip_checksum {
			if stored == 0 {
				plog(LOG_WARNING, "RDB file was saved with checksum disabled: no check performed.")
			} else if stored != expected {
				l: Log_Line
				persist_fail_begin(&l, r)
				ll_str(&l, "CRC error: CRC mismatch, the file stores checksum ")
				persist_ll_hex16(&l, stored)
				ll_str(&l, " but its contents hash to ")
				persist_ll_hex16(&l, expected)
				persist_fail_end(&l)
			}
		}
	}
	return .Ok
}

@(private = "file")
persist_unix_ms :: proc "contextless" () -> i64 {
	ts, _ := sysclock.realtime()
	return i64(ts.time_sec) * 1000 + i64(ts.time_nsec) / 1_000_000
}

@(private = "file")
persist_ll_hex16 :: proc "contextless" (l: ^Log_Line, v: u64) {
	digits := "0123456789abcdef"
	tmp: [16]u8
	for i in 0 ..< 16 {
		tmp[i] = digits[(v >> (4 * uint(15 - i))) & 15]
	}
	ll_str(l, string(tmp[:]))
}

persist_refuse_unlabelled_file :: proc() {
	name := persist_filename()
	pbuf: [PERSIST_PATH_MAX]u8
	st: linux.Stat
	if linux.stat(persist_cstr(name, pbuf[:]), &st) == .ENOENT {
		return
	}
	cwd: [PERSIST_PATH_MAX]u8
	plog(LOG_WARNING, "Refusing to start: the data file ", name, " in ", persist_cwd(cwd[:]), " ", LABEL_STARTUP_FILE)
	linux.exit_group(1)
}

persist_rdb_load :: proc(merge: bool, at_startup: bool, preserve_libraries: bool = false) -> Load_Result {
	keyspace_fence()
	name := persist_filename()
	pbuf: [PERSIST_PATH_MAX]u8
	fd, err := linux.open(persist_cstr(name, pbuf[:]), {.CLOEXEC})
	if err == .ENOENT {
		return .Not_Exist
	}
	if labels_on {
		if err == .NONE {
			linux.close(fd)
		}
		plog(LOG_WARNING, "Refusing to load ", name, ": a server with a label scheme or owner mode never loads data that carries no labels or owners")
		return .Failed
	}
	if err != .NONE {
		plog(LOG_WARNING, "Fatal error loading the DB, check server logs. Exiting.")
		plog(LOG_WARNING, "Error opening ", name, ": ", errno_text(err))
		return .Failed
	}
	defer linux.close(fd)
	stat: linux.Stat
	pst.loading_total = 0
	if linux.fstat(fd, &stat) == .NONE {
		pst.loading_total = i64(stat.size)
	}
	pst.loading = true
	pst.loading_start = persist_unix_now()
	pst.loading_loaded = 0
	pst.loading_used_mem = 0
	pst.serve_while_loading = at_startup
	persist_update_gate()
	r: rdb.Reader
	rdb.reader_init_file(&r, fd, pst.checksum)
	r.progress = persist_loading_progress
	r.tick_every = cfg.loading_events_interval_bytes if cfg.loading_events_interval_bytes > 0 else PERSIST_LOADING_EVENTS_BYTES
	r.next_tick = r.tick_every
	start := now_ns()
	persist_skip_expired = true
	result := persist_load_stream(&r, merge, preserve_libraries)
	persist_skip_expired = false
	pst.loading_loaded = rdb.reader_offset(&r)
	rdb.reader_destroy(&r)
	pst.loading = false
	pst.serve_while_loading = false
	persist_update_gate()
	if result != .Ok {
		return result
	}
	persist_log_load_done()
	if at_startup {
		m: Log_Line
		ll_begin(&m, LOG_NOTICE)
		ll_str(&m, "DB loaded from disk: ")
		ll_fixed(&m, f64(now_ns() - start) / 1e9, 3)
		ll_str(&m, " seconds")
		ll_end(&m)
	}
	return .Ok
}

Shutdown_Flag :: enum u8 {
	Nosave,
	Save,
	Now,
	Force,
}

Shutdown_Flags :: bit_set[Shutdown_Flag;u8]

persist_finish_shutdown :: proc(flags: Shutdown_Flags) -> bool {
	runtime_supervised_stopping()
	keyspace_shutdown()
	compute_shutdown()
	transport_close_listeners()
	lua_debug_shutdown()
	if lua_active == nil {
		lua_library_flush(false)
		lr.reset()
		mem_registry_changed()
	}
	remove_pid_file()
	plog(LOG_WARNING, "Eski is now ready to exit, bye bye...")
	runtime_operations_shutdown()
	diagnostics_shutdown()
	linux.exit_group(0)
}

persist_prepare_shutdown :: proc(flags_in: Shutdown_Flags) -> bool {
	keyspace_fence()
	flags := flags_in
	if pst.loading {
		flags += {.Nosave}
		flags -= {.Save}
	}
	plog(LOG_NOTICE, "User requested shutdown...")
	if aof.state == .Awaiting_Base && .Force not_in flags {
		plog(LOG_WARNING, "Writing initial AOF, can't exit.")
		return false
	}
	if pst.child_pid > 0 && !pst.child_aof {
		plog(LOG_WARNING, "There is a child saving an .rdb. Killing it!")
		persist_kill_child()
	}
	aof_shutdown()
	if .Nosave not_in flags && (.Save in flags || len(pst.save_params) > 0) {
		plog(LOG_NOTICE, "Saving the final RDB snapshot before exiting.")
		if !persist_rdb_save() {
			if .Force in flags {
				plog(LOG_WARNING, "Error trying to save the DB. Exit anyway.")
			} else {
				plog(LOG_WARNING, "Error trying to save the DB, can't exit.")
				return false
			}
		}
	}
	return true
}

@(private = "file")
persist_signal_flags :: proc(sig: i32) -> Shutdown_Flags {
	bits := cfg.shutdown_on_sigint if sig == i32(linux.Signal.SIGINT) else cfg.shutdown_on_sigterm
	flags: Shutdown_Flags
	if bits & SHUTDOWN_SAVE != 0 {
		flags += {.Save}
	}
	if bits & SHUTDOWN_NOSAVE != 0 {
		flags += {.Nosave}
	}
	if bits & SHUTDOWN_NOW != 0 {
		flags += {.Now}
	}
	if bits & SHUTDOWN_FORCE != 0 {
		flags += {.Force}
	}
	return flags
}

@(private = "file")
persist_cron_signals :: proc() {
	pending := intrinsics.atomic_load_explicit(&persist_sig_pending, .Acquire)
	if pending == 0 {
		return
	}
	sig := intrinsics.atomic_load_explicit(&persist_sig_last, .Acquire)
	persist_signal_log(sig)
	if flags := persist_signal_flags(sig); persist_prepare_shutdown(flags) {
		persist_finish_shutdown(flags)
	}
	name := "SIGINT" if sig == i32(linux.Signal.SIGINT) else "SIGTERM"
	plog(LOG_WARNING, name, " received but errors trying to shut down the server, check the logs for more information")
	intrinsics.atomic_sub_explicit(&persist_sig_pending, pending, .Acq_Rel)
}

@(private = "file")
persist_due_save_rule :: proc(now: i64) -> (rule: Save_Param, due: bool) {
	if pst.lastbgsave_err && now - pst.bgsave_attempt_at <= PERSIST_FAILED_SAVE_BACKOFF {
		return
	}
	for candidate in pst.save_params {
		if pst.dirty >= candidate.changes && now - pst.lastsave > candidate.seconds {
			return candidate, true
		}
	}
	return
}

@(private = "file")
persist_auto_save :: proc(now: i64) {
	rule, due := persist_due_save_rule(now)
	if !due {
		return
	}
	l: Log_Line
	ll_begin(&l, LOG_NOTICE)
	ll_int(&l, rule.changes)
	ll_str(&l, " changes in ")
	ll_int(&l, rule.seconds)
	ll_str(&l, " seconds. Saving...")
	ll_end(&l)
	persist_bgsave()
}

persist_cron :: proc() {
	keyspace_collect()
	persist_cron_signals()
	migrate_cron()
	set_scratch_trim()
	zset_reset_scratch()
	persist_check_child()
	aof_cron()
	switch {
	case pst.child_pid > 0 || pst.loading:
	case pst.bgsave_scheduled:
		persist_bgsave()
	case:
		persist_auto_save(persist_unix_now())
	}
}

persist_startup :: proc() {
	persist_init_commands()
	persist_install_signals()
	pst.lastsave = persist_unix_now()
	persist_update_gate()
	if labels_on {
		persist_refuse_unlabelled_file()
	}
	if !aof.started && !aof_startup() {
		plog(LOG_WARNING, "Fatal error loading the DB, check server logs. Exiting.")
		linux.exit_group(1)
	}
	if aof.wanted || aof.state != .Disabled {
		return
	}
	switch persist_rdb_load(false, true) {
	case .Ok, .Not_Exist:
	case .Failed:
		plog(LOG_WARNING, "Fatal error loading the DB, check server logs. Exiting.")
		linux.exit_group(1)
	}
}

persist_flushed :: proc(all: bool, removed: i64) {
	pst.dirty += removed
	pst.dirty_explicit = true
	if !all {
		return
	}
	if pst.child_pid > 0 && !pst.child_aof {
		persist_kill_child()
	}
	if len(pst.save_params) > 0 {
		persist_rdb_save()
	}
}

cmd_save :: proc(c: ^Conn, argv: [][]u8) {
	if pst.child_pid > 0 && !pst.child_aof {
		reply_error(c, ERR_BGSAVE_IN_PROGRESS)
		return
	}
	if persist_rdb_save() {
		reply_ok(c)
	} else {
		reply_error(c, "ERR")
	}
}

cmd_bgsave :: proc(c: ^Conn, argv: [][]u8) {
	schedule := false
	if len(argv) > 1 {
		if len(argv) == 2 && eq_nocase(argv[1], "schedule") {
			schedule = true
		} else {
			reply_error(c, ERR_SYNTAX)
			return
		}
	}
	if pst.child_pid > 0 && !pst.child_aof {
		reply_error(c, ERR_BGSAVE_IN_PROGRESS)
		return
	}
	if pst.child_pid > 0 {
		if schedule {
			pst.bgsave_scheduled = true
			reply_simple(c, "Background saving scheduled")
		} else {
			reply_error(c, ERR_AOF_CHILD_BGSAVE)
		}
		return
	}
	if persist_bgsave() {
		reply_simple(c, "Background saving started")
	} else {
		reply_error(c, "ERR")
	}
}

cmd_lastsave :: proc(c: ^Conn, argv: [][]u8) {
	reply_int(c, pst.lastsave)
}

cmd_shutdown :: proc(c: ^Conn, argv: [][]u8) {
	flags: Shutdown_Flags
	abort := false
	for arg in argv[1:] {
		switch {
		case eq_nocase(arg, "nosave"):
			flags += {.Nosave}
		case eq_nocase(arg, "save"):
			flags += {.Save}
		case eq_nocase(arg, "now"):
			flags += {.Now}
		case eq_nocase(arg, "force"):
			flags += {.Force}
		case eq_nocase(arg, "abort"):
			abort = true
		case:
			reply_error(c, ERR_SYNTAX)
			return
		}
	}
	if (abort && flags != {}) || (.Nosave in flags && .Save in flags) {
		reply_error(c, ERR_SYNTAX)
		return
	}
	if abort {
		if intrinsics.atomic_exchange_explicit(&persist_sig_pending, 0, .Acq_Rel) != 0 {
			plog(LOG_WARNING, "Shutdown manually aborted.")
			reply_ok(c)
		} else {
			reply_error(c, "ERR No shutdown in progress.")
		}
		return
	}
	if persist_prepare_shutdown(flags) {
		persist_finish_shutdown(flags)
	}
	reply_error(c, "ERR Errors trying to SHUTDOWN. Check logs.")
}

persist_info :: proc(b: ^[dynamic]u8) {
	child := pst.child_pid > 0 && !pst.child_aof
	any_child := pst.child_pid > 0
	p := pst.progress
	cow_peak, cow, cow_age, processed, total: i64
	if any_child && p != nil {
		cow_peak = intrinsics.volatile_load(&p.cow_peak)
		cow = intrinsics.volatile_load(&p.cow)
		stamp := intrinsics.volatile_load(&p.cow_ms)
		if cow > 0 && stamp > 0 {
			cow_age = max(now_ns() / 1_000_000 - stamp, 0) / 1000
		}
		processed = intrinsics.volatile_load(&p.processed)
		total = intrinsics.volatile_load(&p.total)
	}
	perc: f64 = 0
	if total > 0 {
		perc = f64(processed) * 100 / f64(total)
	}
	info_section_header(b, "Persistence")
	info_line_int(b, "loading", 1 if pst.loading else 0)
	info_line_int(b, "async_loading", 0)
	info_line_int(b, "current_cow_peak", cow_peak)
	info_line_int(b, "current_cow_size", cow)
	info_line_int(b, "current_cow_size_age", cow_age)
	info_line_fixed(b, "current_fork_perc", perc)
	info_line_int(b, "current_save_keys_processed", processed)
	info_line_int(b, "current_save_keys_total", total)
	info_line_int(b, "rdb_changes_since_last_save", pst.dirty)
	info_line_int(b, "rdb_bgsave_in_progress", 1 if child else 0)
	info_line_int(b, "rdb_last_save_time", pst.lastsave)
	info_line_str(b, "rdb_last_bgsave_status", "err" if pst.lastbgsave_err else "ok")
	info_line_int(b, "rdb_last_bgsave_time_sec", pst.save_time_last)
	current: i64 = -1
	if child && pst.save_time_start >= 0 {
		current = persist_unix_now() - pst.save_time_start
	}
	info_line_int(b, "rdb_current_bgsave_time_sec", current)
	info_line_int(b, "rdb_saves", pst.stat_rdb_saves)
	info_line_int(b, "rdb_last_cow_size", pst.stat_rdb_cow)
	info_line_int(b, "rdb_last_load_keys_expired", pst.last_load_expired)
	info_line_int(b, "rdb_last_load_keys_loaded", pst.last_load_loaded)
	aof_info(b)
	if pst.loading {
		persist_info_loading(b)
	}
}

@(private = "file")
persist_info_loading :: proc(b: ^[dynamic]u8) {
	now := persist_unix_now()
	elapsed := max(now - pst.loading_start, 0)
	loaded := pst.loading_loaded
	total := pst.loading_total
	perc: f64 = 0
	if total > 0 {
		perc = f64(loaded) * 100 / f64(total)
	}
	eta: i64 = 1
	if elapsed > 0 && loaded > 0 {
		eta = i64(f64(total - loaded) / (f64(loaded) / f64(elapsed)))
	}
	info_line_int(b, "loading_start_time", pst.loading_start)
	info_line_int(b, "loading_total_bytes", total)
	info_line_int(b, "loading_rdb_used_mem", pst.loading_used_mem)
	info_line_int(b, "loading_loaded_bytes", loaded)
	info_line_fixed(b, "loading_loaded_perc", perc)
	info_line_int(b, "loading_eta_seconds", max(eta, 0))
}

DIGEST_BYTES :: 20

Digest :: [DIGEST_BYTES]u8

@(private = "file")
Digest_Tag :: enum u8 {
	String = 1,
	List,
	Set,
	Zset,
	Hash,
	Stream,
	Key,
	Vectorset,
}

@(private = "file")
digest_begin :: proc(h: ^blake2b.Context, tag: Digest_Tag) {
	blake2b.init(h, DIGEST_BYTES)
	label := [1]u8{u8(tag)}
	blake2b.update(h, label[:])
}

@(private = "file")
digest_word :: proc(h: ^blake2b.Context, v: u64) {
	le: [8]u8
	for n in 0 ..< 8 {
		le[n] = u8(v >> (8 * uint(n)))
	}
	blake2b.update(h, le[:])
}

@(private = "file")
digest_text :: proc(h: ^blake2b.Context, text: []u8) {
	digest_word(h, u64(len(text)))
	blake2b.update(h, text)
}

@(private = "file")
digest_close :: proc(h: ^blake2b.Context) -> (sum: Digest) {
	blake2b.final(h, sum[:])
	return
}

@(private = "file")
digest_accumulate :: proc(total: ^Digest, part: Digest) {
	carry: u16 = 0
	for n in 0 ..< DIGEST_BYTES {
		lane := u16(total[n]) + u16(part[n]) + carry
		total[n] = u8(lane)
		carry = lane >> 8
	}
}

@(private = "file")
digest_score_bits :: proc(score: f64) -> u64 {
	return 0 if score == 0 else transmute(u64)score
}

@(private = "file")
digest_list :: proc(h: ^blake2b.Context, l: lt.List) {
	walk := lt.iterator(l, 0, .Tail)
	entry: lt.List_Entry
	for lt.iter_next(&walk, &entry) {
		scratch: [24]u8
		digest_text(h, lt.value_bytes(lt.entry_value(&walk, &entry), cast(^[21]u8)&scratch))
	}
}

@(private = "file")
digest_set :: proc(s: st.Set) -> (total: Digest) {
	walk := st.iterator(s)
	for {
		member, more := st.next(&walk)
		if !more {
			break
		}
		scratch: [24]u8
		h: blake2b.Context
		digest_begin(&h, .Set)
		digest_text(&h, st.value_bytes(member, cast(^[21]u8)&scratch))
		digest_accumulate(&total, digest_close(&h))
	}
	return
}

@(private = "file")
digest_zset :: proc(z: zt.Zset) -> (total: Digest) {
	walk := zt.iter_make(z, false)
	item: zt.Item
	for zt.iter_next(&walk, &item) {
		scratch: [24]u8
		h: blake2b.Context
		digest_begin(&h, .Zset)
		digest_text(&h, zt.item_bytes(&item, cast(^[21]u8)&scratch))
		digest_word(&h, digest_score_bits(item.score))
		digest_accumulate(&total, digest_close(&h))
	}
	return
}

@(private = "file")
digest_hash :: proc(hv: ht.Hash) -> (total: Digest) {
	walk := ht.iterator(hv)
	for ht.next(&walk) {
		field_scratch, value_scratch: [24]u8
		h: blake2b.Context
		digest_begin(&h, .Hash)
		digest_text(&h, ht.value_bytes(ht.current_field(&walk), cast(^[21]u8)&field_scratch))
		digest_text(&h, ht.value_bytes(ht.current_value(&walk), cast(^[21]u8)&value_scratch))
		deadline := ht.current_expire(&walk)
		if deadline != ht.DEADLINE_UNSET && deadline != 0 {
			digest_word(&h, u64(deadline))
		}
		digest_accumulate(&total, digest_close(&h))
	}
	return
}

@(private = "file")
digest_stream :: proc(h: ^blake2b.Context, s: sm.Stream) {
	walk: sm.Cursor
	sm.cursor_open(&walk, s, nil, nil, false)
	defer sm.cursor_close(&walk)
	for id, pairs in sm.cursor_next(&walk) {
		digest_word(h, id.ms)
		digest_word(h, id.seq)
		digest_word(h, u64(pairs))
		for _ in 0 ..< pairs {
			field, value := sm.cursor_field(&walk)
			digest_text(h, field)
			digest_text(h, value)
		}
	}
}

@(private = "file")
digest_vset :: proc(h: ^blake2b.Context, s: vt.Vset) {
	p := vt.params_of(s)
	digest_word(h, u64(p.quant))
	digest_word(h, u64(p.dim))
	digest_word(h, u64(p.input_dim))
	digest_word(h, u64(p.m))
	total: Digest
	if labels_on {
		a := label_vt_access()
		if digest_owner_db != nil {
			a = owner_scope_access(digest_owner_db)
		}
		v, err := vt.view_open(s, &a, vset_scratch_get())
		if err == .None {
			for j in 0 ..< vt.view_size(&v) {
				r := vt.view_ref_at(&v, j)
				text, has := vt.ref_attribute(s, r)
				digest_accumulate(&total, digest_vset_element(vt.ref_name(s, r), vt.ref_raw_embedding(s, r), text, has))
			}
		}
	} else {
		it := vt.element_iterator(s)
		for {
			slot, more := vt.next_element(&it)
			if !more {
				break
			}
			text, has := vt.element_attribute(s, slot)
			digest_accumulate(&total, digest_vset_element(vt.element_name(s, slot), vt.raw_embedding(s, slot), text, has))
		}
	}
	blake2b.update(h, total[:])
}

@(private = "file")
digest_vset_element :: proc(name: []u8, raw: vt.Raw_Embedding, text: string, has: bool) -> Digest {
	eh: blake2b.Context
	digest_begin(&eh, .Vectorset)
	digest_text(&eh, name)
	digest_text(&eh, raw.data)
	digest_word(&eh, u64(transmute(u32)raw.norm))
	digest_word(&eh, u64(transmute(u32)raw.range) if raw.has_range else 0)
	if has {
		digest_word(&eh, 1)
		digest_text(&eh, transmute([]u8)text)
	} else {
		digest_word(&eh, 0)
	}
	return digest_close(&eh)
}

@(private = "file")
digest_of_value :: proc(v: Slot_Value) -> Digest {
	h: blake2b.Context
	if v.type == .String || v.obj == nil {
		digest_begin(&h, .String)
		digest_text(&h, v.str)
		return digest_close(&h)
	}
	#partial switch v.type {
	case .List:
		digest_begin(&h, .List)
		digest_list(&h, cast(lt.List)v.obj)
	case .Set:
		digest_begin(&h, .Set)
		members := digest_set(cast(st.Set)v.obj)
		blake2b.update(&h, members[:])
	case .Zset:
		digest_begin(&h, .Zset)
		members := digest_zset(cast(zt.Zset)v.obj)
		blake2b.update(&h, members[:])
	case .Hash:
		digest_begin(&h, .Hash)
		members := digest_hash(cast(ht.Hash)v.obj)
		blake2b.update(&h, members[:])
	case .Stream:
		digest_begin(&h, .Stream)
		digest_stream(&h, cast(sm.Stream)v.obj)
	case .Vectorset:
		digest_begin(&h, .Vectorset)
		digest_vset(&h, cast(vt.Vset)v.obj)
	case:
		blake2b.init(&h, DIGEST_BYTES)
	}
	return digest_close(&h)
}

@(private = "file")
digest_of_key :: proc(db: ^Db, t: ^Table, slot: int) -> Digest {
	h: blake2b.Context
	digest_begin(&h, .Key)
	digest_word(&h, u64(db.id))
	digest_text(&h, key_bytes(&t.slots[slot].key, &db.slab))
	contents := digest_of_value(persist_slot_value(db, &t.slots[slot].key, &t.slots[slot].val))
	blake2b.update(&h, contents[:])
	expiring := [1]u8{1 if key_timed(t.slots[slot].key) else 0}
	blake2b.update(&h, expiring[:])
	return digest_close(&h)
}

@(private = "file")
reply_digest :: proc(c: ^Conn, d: ^[20]u8) {
	digits := "0123456789abcdef"
	hex: [40]u8
	for i in 0 ..< 20 {
		hex[2 * i] = digits[d[i] >> 4]
		hex[2 * i + 1] = digits[d[i] & 15]
	}
	reply_simple(c, string(hex[:]))
}

@(private = "file")
digest_table :: proc(total: ^Digest, db: ^Db, t: ^Table) {
	for g in 0 ..< t.groups {
		occupied := group_full(group_load(t.ctrl, g))
		base := int(g) * GROUP_SLOTS
		for occupied != 0 {
			slot := base + int(intrinsics.count_trailing_zeros(occupied))
			occupied &= occupied - 1
			digest_accumulate(total, digest_of_key(db, t, slot))
		}
	}
}

@(private = "file")
digest_db :: proc(total: ^Digest, db: ^Db) {
	if db_size_of(db) == 0 {
		return
	}
	for &t in db.t[:persist_table_count(db)] {
		if persist_table_ok(&t) {
			digest_table(total, db, &t)
		}
	}
}

digest_owner_db: ^Db

persist_dataset_digest :: proc(final: ^[20]u8) {
	total: Digest
	if labels_on {
		for p in db_parts {
			digest_db(&total, p)
		}
		for od in owner_dbs {
			for sp in od.spaces {
				for k in 0 ..< int(sp.nparts) {
					digest_owner_db = owner_db(owner_space_at(sp, k))
					digest_db(&total, digest_owner_db)
				}
			}
		}
		digest_owner_db = nil
	} else {
		for &db in dbs {
			digest_db(&total, &db)
		}
	}
	final^ = total
}

@(private = "file")
persist_debug_reload :: proc(c: ^Conn, argv: [][]u8) {
	merge, noflush, nosave := false, false, false
	for arg in argv[2:] {
		switch {
		case eq_nocase(arg, "merge"):
			merge = true
		case eq_nocase(arg, "noflush"):
			noflush = true
		case eq_nocase(arg, "nosave"):
			nosave = true
		case:
			reply_error(c, "ERR DEBUG RELOAD only supports the MERGE, NOFLUSH and NOSAVE options.")
			return
		}
	}
	if !nosave {
		if pst.child_pid > 0 && !pst.child_aof {
			persist_kill_child()
		}
		if !persist_rdb_save() {
			reply_error(c, "ERR")
			return
		}
	}
	if !noflush {
		db_flush_all()
	}
	if persist_rdb_load(merge, false, noflush) != .Ok {
		reply_error(c, "ERR Error trying to load the RDB dump, check server logs.")
		return
	}
	plog(LOG_NOTICE, "DB reloaded by DEBUG RELOAD")
	reply_ok(c)
}

persist_raw_digest_value :: proc(c: ^Conn, keys: [][]u8) {
	reply_array(c, len(keys))
	for key in keys {
		d: [20]u8
		db := c.db if c.db != nil else cur_db()
		if labels_on {
			db = cur_db()
		}
		t, i := persist_raw_locate(db, key)
		if i < 0 && labels_on {
			l := lookup_make(key)
			db, t, i = label_scope_other(db.id, key, &l)
		}
		if i >= 0 {
			d = digest_of_value(persist_slot_value(db, &t.slots[i].key, &t.slots[i].val))
		}
		reply_digest(c, &d)
	}
}

persist_debug :: proc(c: ^Conn, argv: [][]u8) -> bool {
	if len(argv) < 2 {
		return false
	}
	sub := argv[1]
	switch {
	case labels_on && (eq_nocase(sub, "reload") || eq_nocase(sub, "loadaof")):
		reply_error(c, access_persistence_text())
	case eq_nocase(sub, "reload"):
		persist_debug_reload(c, argv)
	case eq_nocase(sub, "digest") && len(argv) == 2:
		d: [20]u8
		persist_dataset_digest(&d)
		reply_digest(c, &d)
	case eq_nocase(sub, "digest-value") && len(argv) >= 2:
		persist_raw_digest_value(c, argv[2:])
	case eq_nocase(sub, "loadaof") && len(argv) == 2:
		aof_debug_loadaof(c)
	case eq_nocase(sub, "set-skip-checksum-validation") && len(argv) == 3:
		v, good := parse_i64(argv[2])
		if !good {
			reply_error(c, ERR_NOT_INT)
			return true
		}
		pst.skip_checksum = v != 0
		reply_ok(c)
	case:
		return false
	}
	return true
}

@(private = "file")
persist_commands := [?]Command {
	{"save", cmd_save, 1},
	{"bgsave", cmd_bgsave, -1},
	{"lastsave", cmd_lastsave, 1},
	{"shutdown", cmd_shutdown, -1},
}

@(init)
register_persist_commands :: proc "contextless" () {
	register_commands(persist_commands[:])
}
