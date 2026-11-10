package main

import "base:intrinsics"
import "base:runtime"
import "core:strconv"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import ht "hashtype"
import ks "keyspace"
import lt "listtype"
import "rdb"
import rx "rax"
import st "settype"
import sm "streamtype"
import zt "zsettype"
import vt "vsettype"
import "sysclock"

AOF_ITEMS_PER_EMITTED_COMMAND :: 64

AOF_AUTOSYNC_BYTES :: 4 * 1024 * 1024

AOF_WRITE_DEFER_MAX_MS :: 2000

AOF_LOAD_EVENTS_BYTES :: 2 * 1024 * 1024

AOF_JOBS :: 256

AOF_NAME_MAX :: 512

ERR_AOF_REWRITE_RUNNING :: "ERR Background append only file rewriting already in progress"

ERR_AOF_LOAD :: "ERR Error trying to load the AOF files, check server logs."

ERR_AOF_CHILD_BGSAVE :: "ERR Another child process is active (AOF?): can't BGSAVE right now. Use BGSAVE SCHEDULE in order to schedule a BGSAVE whenever possible."

Aof_Status :: enum u8 {
	Disabled,
	Enabled,
	Awaiting_Base,
}

Aof_Fsync :: enum u8 {
	No,
	Always,
	Everysec,
}

Aof_File_Kind :: enum u8 {
	Base,
	History,
	Incr,
}

Aof_File :: struct {
	name: [dynamic]u8,
	seq:  i64,
	kind: Aof_File_Kind,
}

Aof_Manifest :: struct {
	has_base: bool,
	base:     Aof_File,
	incr:     [dynamic]Aof_File,
	history:  [dynamic]Aof_File,
	base_seq: i64,
	incr_seq: i64,
}

Aof_Load_Outcome :: enum u8 {
	Loaded,
	Blank,
	Absent,
	Unopenable,
	Aborted,
	Truncated_Tail,
}

Aof_Deferred :: struct {
	fd: linux.Fd,
	id: i64,
}

Aof_Job_Kind :: enum u8 {
	Fsync,
	Close,
	Unlink,
}

Aof_Job :: struct {
	kind: Aof_Job_Kind,
	fd:   linux.Fd,
	path: [AOF_NAME_MAX]u8,
}

Aof :: struct {
	state:               Aof_Status,
	wanted:              bool,
	fsync:               Aof_Fsync,
	preamble:            bool,
	load_truncated:      bool,
	incremental_fsync:   bool,
	timestamps:          bool,
	no_fsync_on_rewrite: bool,
	disable_auto_gc:     bool,
	auto_pct:            i64,
	auto_min:            i64,
	dirname:             string,
	filename:            string,
	fd:                  linux.Fd,
	buf:                 [dynamic]u8,
	selected_db:         int,
	last_ts:             i64,
	current_size:        i64,
	base_size:           i64,
	fsynced_size:        i64,
	last_fsync_ms:       i64,
	deferred_write_at:   i64,
	delayed_fsync:       i64,
	write_err:           bool,
	write_errno:         linux.Errno,
	rewrite_scheduled:   bool,
	rewrite_start:       i64,
	rewrite_last:        i64,
	rewrite_preamble:    bool,
	rewrite_state:       Aof_Status,
	stat_rewrites:       i64,
	failures:            i64,
	last_rewrite_err:    bool,
	last_cow:            i64,
	manifest:            Aof_Manifest,
	loading:             bool,
	feed:                bool,
	started:             bool,
	in_cmd:              bool,
	in_tx:               bool,
	stage:               [dynamic]u8,
	stage_count:         int,
	stage_first_db:      int,
	stage_db:            int,
	deferred:            [dynamic]Aof_Deferred,
	fake:                ^Conn,
	xrg_existed:         [dynamic]bool,
	xrg_cmd:             ^Command,
	scan_cmd:            ^Command,
	randomkey_cmd:       ^Command,
	migrate_dels:        [dynamic][]u8,
	scratch:             [dynamic]u8,
	args:                [dynamic][]u8,
}

aof := Aof {
	fsync             = .Everysec,
	preamble          = true,
	load_truncated    = true,
	incremental_fsync = true,
	auto_pct          = 100,
	auto_min          = 64 * 1024 * 1024,
	dirname           = "appendonlydir",
	filename          = "appendonly.aof",
	fd                = -1,
	selected_db       = -1,
	rewrite_start     = -1,
	rewrite_last      = -1,
}

aof_bio_mutex: sync.Mutex

aof_bio_sema: sync.Sema

aof_bio_jobs: [AOF_JOBS]Aof_Job

aof_bio_head: int

aof_bio_tail: int

aof_bio_pending_fsync: i32

@(private = "file")
aof_bio_jobs_pending: i32

aof_bio_thread: ^thread.Thread

@(private = "file")
aof_bio_sizes: [AOF_JOBS]i64

@(private = "file")
aof_bio_synced: i64

@(private = "file")
aof_bio_gens: [AOF_JOBS]i64

@(private = "file")
aof_sync_gen: i64

@(private = "file")
AOF_SYNC_SIZE_BITS :: 40

@(private = "file")
AOF_SYNC_SIZE_MASK :: i64(1) << AOF_SYNC_SIZE_BITS - 1

@(private = "file")
aof_bio_err: i32

@(private = "file")
aof_err_from_fsync: bool

@(private = "file")
aof_explicit: bool

@(private = "file")
aof_rewrite_incr_seq: i64

@(private = "file")
aof_retry_at: i64
aof_retry_reported: bool

@(private = "file")
aof_last_err_log: i64

@(private = "file")
aof_keypos: [dynamic]int

@(private = "file")
aof_ids: [dynamic]sm.ID

@(private = "file")
aof_flags_scratch: [dynamic]i64

@(private = "file")
Aof_Snap :: struct {
	valid:       bool,
	existed:     bool,
	last_id:     sm.ID,
	entries:     i64,
	group_found: bool,
}

@(private = "file")
aof_snap: Aof_Snap

@(private = "file")
aof_snap_pel: [dynamic]bool

@(private = "file")
aof_q_bytes: [dynamic]u8

@(private = "file")
aof_q_lens: [dynamic]int

@(private = "file")
aof_q_argc: [dynamic]int

@(private = "file")
aof_q_argv: [dynamic][]u8

@(private = "file")
aof_load_argv: [dynamic][]u8

expire_now :: #force_inline proc "contextless" () -> i64 {
	if aof.loading {
		return 0
	}
	if lua_active != nil {
		return lua_active.frozen_ms
	}
	return srv.now_ms
}

aof_rewriting :: #force_inline proc "contextless" () -> bool {
	return pst.child_pid > 0 && pst.child_aof
}

aof_bytes :: #force_inline proc(s: string) -> []u8 {
	return transmute([]u8)s
}

@(private = "file")
aof_now_ms :: proc "contextless" () -> i64 {
	ts, _ := sysclock.realtime()
	return i64(ts.time_sec) * 1000 + i64(ts.time_nsec) / 1_000_000
}

@(private = "file")
aof_mode_file :: proc "contextless" () -> linux.Mode {
	return {.IRUSR, .IWUSR, .IRGRP, .IROTH}
}

@(private = "file")
aof_mode_dir :: proc "contextless" () -> linux.Mode {
	return {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}
}

aof_update_feed :: proc "contextless" () {
	on := aof.state == .Enabled || (aof.state == .Awaiting_Base && aof_rewriting())
	aof.feed = on && !aof.loading && aof.fd >= 0
}

@(private = "file")
aof_feed_refresh :: proc() {
	before := aof.feed
	aof_update_feed()
	if before != aof.feed {
		hooks_update()
	}
}

aof_cpath :: proc(name: string, buf: []u8) -> cstring {
	n := 0
	limit := len(buf) - 1
	for i in 0 ..< len(aof.dirname) {
		if n >= limit {
			break
		}
		buf[n] = aof.dirname[i]
		n += 1
	}
	if n < limit {
		buf[n] = '/'
		n += 1
	}
	for i in 0 ..< len(name) {
		if n >= limit {
			break
		}
		buf[n] = name[i]
		n += 1
	}
	buf[n] = 0
	return cstring(raw_data(buf))
}

aof_path :: proc(dst: ^[dynamic]u8, name: string) {
	clear(dst)
	append(dst, aof.dirname)
	append(dst, '/')
	append(dst, name)
}

@(private = "file")
aof_put_decimal :: proc(dst: ^[dynamic]u8, v: i64) {
	tmp: [24]u8
	n := format_i64(&tmp[0], v)
	append(dst, ..tmp[:n])
}

aof_name :: proc(dst: ^[dynamic]u8, seq: i64, kind: string) {
	clear(dst)
	append(dst, aof.filename)
	append(dst, '.')
	aof_put_decimal(dst, seq)
	append(dst, '.')
	append(dst, kind)
}

aof_manifest_name :: proc(dst: ^[dynamic]u8) {
	clear(dst)
	append(dst, aof.filename)
	append(dst, ".manifest")
}

aof_temp_incr_name :: proc(dst: ^[dynamic]u8) {
	clear(dst)
	append(dst, "temp-")
	append(dst, aof.filename)
	append(dst, ".incr")
}

aof_temp_base_name :: proc(dst: []u8, pid: linux.Pid, bg: bool) -> string {
	prefix := "temp-rewriteaof-bg-" if bg else "temp-rewriteaof-"
	n := 0
	for i in 0 ..< len(prefix) {
		dst[n] = prefix[i]
		n += 1
	}
	n += format_i64(&dst[n], i64(pid))
	suffix := ".aof"
	for i in 0 ..< len(suffix) {
		dst[n] = suffix[i]
		n += 1
	}
	return string(dst[:n])
}

aof_file_size :: proc(name: string) -> i64 {
	buf: [PERSIST_PATH_MAX]u8
	sb: linux.Stat
	if linux.stat(aof_cpath(name, buf[:]), &sb) != .NONE {
		return 0
	}
	return i64(sb.size)
}

@(private = "file")
aof_file_exists :: proc(name: string) -> bool {
	buf: [PERSIST_PATH_MAX]u8
	sb: linux.Stat
	return linux.stat(aof_cpath(name, buf[:]), &sb) == .NONE
}

@(private = "file")
aof_is_dir :: proc "contextless" (mode: linux.Mode) -> bool {
	return .IFDIR in mode && .IFREG not_in mode
}

aof_dir_exists :: proc() -> bool {
	buf: [PERSIST_PATH_MAX]u8
	sb: linux.Stat
	if linux.stat(persist_cstr(aof.dirname, buf[:]), &sb) != .NONE {
		return false
	}
	return aof_is_dir(sb.mode)
}

aof_make_dir :: proc() -> bool {
	buf: [PERSIST_PATH_MAX]u8
	path := persist_cstr(aof.dirname, buf[:])
	sb: linux.Stat
	if linux.stat(path, &sb) == .NONE {
		if aof_is_dir(sb.mode) {
			return true
		}
		plog(LOG_WARNING, "Can't open or create append-only dir ", aof.dirname, ": ", errno_text(.ENOTDIR))
		return false
	}
	err := linux.mkdir(path, aof_mode_dir())
	if err != .NONE && err != .EEXIST {
		plog(LOG_WARNING, "Can't open or create append-only dir ", aof.dirname, ": ", errno_text(err))
		return false
	}
	return true
}

aof_fsync_dir :: proc() {
	buf: [PERSIST_PATH_MAX]u8
	fd, err := linux.open(persist_cstr(aof.dirname, buf[:]), {.DIRECTORY, .CLOEXEC})
	if err != .NONE {
		return
	}
	linux.fsync(fd)
	linux.close(fd)
}

@(private = "file")
aof_write_all :: proc "contextless" (fd: linux.Fd, data: []u8) -> (written: int, err: linux.Errno) {
	rest := data
	for len(rest) > 0 {
		n, e := linux.write(fd, rest)
		if e == .EINTR {
			continue
		}
		if e != .NONE {
			return written, e
		}
		if n <= 0 {
			return written, .ENOSPC
		}
		written += n
		rest = rest[n:]
	}
	return written, .NONE
}

aof_file_clone :: proc(f: Aof_File) -> Aof_File {
	out := Aof_File {
		seq  = f.seq,
		kind = f.kind,
	}
	append(&out.name, ..f.name[:])
	return out
}

aof_file_free :: proc(f: ^Aof_File) {
	delete(f.name)
	f.name = nil
}

aof_manifest_free :: proc(m: ^Aof_Manifest) {
	if m.has_base {
		aof_file_free(&m.base)
	}
	for &f in m.incr {
		aof_file_free(&f)
	}
	for &f in m.history {
		aof_file_free(&f)
	}
	delete(m.incr)
	delete(m.history)
	m^ = {}
}

aof_manifest_dup :: proc(m: ^Aof_Manifest) -> Aof_Manifest {
	out := Aof_Manifest {
		has_base = m.has_base,
		base_seq = m.base_seq,
		incr_seq = m.incr_seq,
	}
	if m.has_base {
		out.base = aof_file_clone(m.base)
	}
	for f in m.incr {
		append(&out.incr, aof_file_clone(f))
	}
	for f in m.history {
		append(&out.history, aof_file_clone(f))
	}
	return out
}

@(private = "file")
aof_name_needs_quotes :: proc "contextless" (name: []u8) -> bool {
	if len(name) == 0 {
		return true
	}
	for c in name {
		if c <= ' ' || c >= 0x7f || c == '"' || c == '\\' || c == '\'' {
			return true
		}
	}
	return false
}

@(private = "file")
aof_put_quoted :: proc(b: ^[dynamic]u8, name: []u8) {
	digits := "0123456789abcdef"
	append(b, '"')
	for c in name {
		switch c {
		case '\\':
			append(b, "\\\\")
		case '"':
			append(b, "\\\"")
		case '\n':
			append(b, "\\n")
		case '\r':
			append(b, "\\r")
		case '\t':
			append(b, "\\t")
		case:
			if c < ' ' || c >= 0x7f {
				append(b, "\\x")
				append(b, digits[c >> 4])
				append(b, digits[c & 15])
			} else {
				append(b, c)
			}
		}
	}
	append(b, '"')
}

@(private = "file")
aof_manifest_line :: proc(b: ^[dynamic]u8, f: ^Aof_File) {
	append(b, "file ")
	if aof_name_needs_quotes(f.name[:]) {
		aof_put_quoted(b, f.name[:])
	} else {
		append(b, ..f.name[:])
	}
	append(b, " seq ")
	aof_put_decimal(b, f.seq)
	append(b, " type ")
	switch f.kind {
	case .Base:
		append(b, 'b')
	case .History:
		append(b, 'h')
	case .Incr:
		append(b, 'i')
	}
	append(b, '\n')
}

aof_manifest_text :: proc(m: ^Aof_Manifest, b: ^[dynamic]u8) {
	clear(b)
	if m.has_base {
		aof_manifest_line(b, &m.base)
	}
	for &f in m.history {
		aof_manifest_line(b, &f)
	}
	for &f in m.incr {
		aof_manifest_line(b, &f)
	}
}

@(private = "file")
AOF_MANIFEST_LINE_MAX :: 1024

@(private = "file")
aof_hex_value :: proc "contextless" (c: u8) -> (int, bool) {
	switch c {
	case '0' ..= '9':
		return int(c - '0'), true
	case 'a' ..= 'f':
		return int(c - 'a') + 10, true
	case 'A' ..= 'F':
		return int(c - 'A') + 10, true
	}
	return 0, false
}

@(private = "file")
aof_manifest_token :: proc(line: []u8, at: ^int, out: ^[dynamic]u8) -> (found: bool, ok: bool) {
	i := at^
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i += 1
	}
	if i >= len(line) {
		at^ = i
		return false, true
	}
	clear(out)
	if line[i] != '"' && line[i] != '\'' {
		for i < len(line) && line[i] != ' ' && line[i] != '\t' {
			append(out, line[i])
			i += 1
		}
		at^ = i
		return true, true
	}
	quote := line[i]
	i += 1
	for {
		if i >= len(line) {
			return false, false
		}
		c := line[i]
		if c == quote {
			i += 1
			if i < len(line) && line[i] != ' ' && line[i] != '\t' {
				return false, false
			}
			at^ = i
			return true, true
		}
		if c == '\\' && quote == '"' && i + 1 < len(line) {
			e := line[i + 1]
			switch e {
			case 'n':
				append(out, '\n')
				i += 2
			case 'r':
				append(out, '\r')
				i += 2
			case 't':
				append(out, '\t')
				i += 2
			case 'b':
				append(out, '\b')
				i += 2
			case 'a':
				append(out, '\a')
				i += 2
			case 'x':
				if i + 3 < len(line) {
					hi, okh := aof_hex_value(line[i + 2])
					lo, okl := aof_hex_value(line[i + 3])
					if okh && okl {
						append(out, u8(hi * 16 + lo))
						i += 4
						continue
					}
				}
				append(out, 'x')
				i += 2
			case:
				append(out, e)
				i += 2
			}
			continue
		}
		if c == '\\' && quote == '\'' && i + 1 < len(line) && line[i + 1] == '\'' {
			append(out, '\'')
			i += 2
			continue
		}
		append(out, c)
		i += 1
	}
}

aof_manifest_parse :: proc(text: []u8, m: ^Aof_Manifest) -> (ok: bool, reason: string) {
	m^ = {}
	tok: [dynamic]u8
	defer delete(tok)
	name: [dynamic]u8
	defer delete(name)
	start := 0
	hist_base, hist_incr: i64 = 0, 0
	for start < len(text) {
		end := start
		for end < len(text) && text[end] != '\n' {
			end += 1
		}
		line := text[start:end]
		start = end + 1
		if len(line) > AOF_MANIFEST_LINE_MAX {
			aof_manifest_free(m)
			return false, "The AOF manifest file contains too long line"
		}
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		first := 0
		for first < len(line) && (line[first] == ' ' || line[first] == '\t') {
			first += 1
		}
		if first == len(line) {
			aof_manifest_free(m)
			return false, "Invalid AOF manifest file format"
		}
		if line[first] == '#' { continue }
		have_name, have_seq, have_type := false, false, false
		seq: i64 = 0
		kind := Aof_File_Kind.Base
		at := 0
		for {
			found, good := aof_manifest_token(line, &at, &tok)
			if !good {
				aof_manifest_free(m)
				return false, "Invalid AOF manifest file format"
			}
			if !found {
				break
			}
			key := string(tok[:])
			is_file := key == "file"
			is_seq := key == "seq"
			is_type := key == "type"
			found, good = aof_manifest_token(line, &at, &tok)
			if !found || !good {
				aof_manifest_free(m)
				return false, "Invalid AOF manifest file format"
			}
			switch {
			case is_file:
				clear(&name)
				append(&name, ..tok[:])
				have_name = true
			case is_seq:
				v, vok := parse_i64(tok[:])
				if !vok || v <= 0 {
					aof_manifest_free(m)
					return false, "Invalid AOF file sequence number"
				}
				seq = v
				have_seq = true
			case is_type:
				if len(tok) != 1 {
					aof_manifest_free(m)
					return false, "Unknown AOF file type"
				}
				switch tok[0] {
				case 'b':
					kind = .Base
				case 'h':
					kind = .History
				case 'i':
					kind = .Incr
				case:
					aof_manifest_free(m)
					return false, "Unknown AOF file type"
				}
				have_type = true
			}
		}
		if !have_name || !have_seq || !have_type || len(name) == 0 {
			aof_manifest_free(m)
			return false, "Invalid AOF manifest file format"
		}
		for c in name {
			if c == '/' || c == 0 {
				aof_manifest_free(m)
				return false, "Invalid AOF file name"
			}
		}
		f := Aof_File {
			seq  = seq,
			kind = kind,
		}
		append(&f.name, ..name[:])
		switch kind {
		case .Base:
			if m.has_base {
				aof_file_free(&f)
				aof_manifest_free(m)
				return false, "Found duplicate base file information"
			}
			m.base = f
			m.has_base = true
			m.base_seq = seq
		case .History:
			hname := string(f.name[:])
			if len(hname) > 9 && hname[len(hname) - 9:] == ".incr.aof" {
				hist_incr = max(hist_incr, seq)
			} else {
				hist_base = max(hist_base, seq)
			}
			append(&m.history, f)
		case .Incr:
			if seq <= m.incr_seq {
				aof_file_free(&f)
				aof_manifest_free(m)
				return false, "Found a non-monotonic sequence number"
			}
			append(&m.incr, f)
			m.incr_seq = seq
		}
	}
	if !m.has_base && len(m.incr) == 0 {
		aof_manifest_free(m)
		return false, "Found an empty AOF manifest"
	}
	m.base_seq = max(m.base_seq, hist_base)
	m.incr_seq = max(m.incr_seq, hist_incr)
	return true, ""
}

aof_read_whole :: proc(path: cstring) -> (data: [dynamic]u8, exists: bool, err: linux.Errno) {
	fd, oerr := linux.open(path, {.CLOEXEC})
	if oerr == .ENOENT {
		return nil, false, .NONE
	}
	if oerr != .NONE {
		return nil, true, oerr
	}
	defer linux.close(fd)
	exists = true
	chunk: [8192]u8
	for {
		n, rerr := linux.read(fd, chunk[:])
		if rerr == .EINTR {
			continue
		}
		if rerr != .NONE {
			delete(data)
			return nil, true, rerr
		}
		if n <= 0 {
			break
		}
		append(&data, ..chunk[:n])
	}
	return
}

aof_manifest_load_from_disk :: proc(m: ^Aof_Manifest) -> (exists: bool, ok: bool) {
	m^ = {}
	if !aof_dir_exists() {
		return false, true
	}
	mname: [dynamic]u8
	defer delete(mname)
	aof_manifest_name(&mname)
	buf: [PERSIST_PATH_MAX]u8
	data, found, err := aof_read_whole(aof_cpath(string(mname[:]), buf[:]))
	defer delete(data)
	if !found {
		return false, true
	}
	if err != .NONE {
		plog(LOG_WARNING, "Fail to open AOF manifest ", string(mname[:]), ": ", errno_text(err))
		return true, false
	}
	good, reason := aof_manifest_parse(data[:], m)
	if !good {
		plog(LOG_WARNING, reason)
		return true, false
	}
	return true, true
}

aof_write_file_atomic :: proc(name: string, data: []u8) -> bool {
	tname: [dynamic]u8
	defer delete(tname)
	append(&tname, "temp-")
	append(&tname, name)
	tbuf: [PERSIST_PATH_MAX]u8
	fbuf: [PERSIST_PATH_MAX]u8
	tpath := aof_cpath(string(tname[:]), tbuf[:])
	fpath := aof_cpath(name, fbuf[:])
	fd, err := linux.open(tpath, {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, aof_mode_file())
	if err != .NONE {
		plog(LOG_WARNING, "Can't open the AOF manifest file ", string(tname[:]), ": ", errno_text(err))
		return false
	}
	_, werr := aof_write_all(fd, data)
	if werr == .NONE {
		werr = linux.fsync(fd)
	}
	linux.close(fd)
	if werr != .NONE {
		plog(LOG_WARNING, "Can't persist the AOF manifest file ", string(tname[:]), ": ", errno_text(werr))
		linux.unlink(tpath)
		return false
	}
	if rerr := linux.rename(tpath, fpath); rerr != .NONE {
		plog(LOG_WARNING, "Error trying to rename the temporary AOF manifest file ", string(tname[:]), " into ", name, ": ", errno_text(rerr))
		linux.unlink(tpath)
		return false
	}
	aof_fsync_dir()
	return true
}

aof_persist_manifest :: proc(m: ^Aof_Manifest) -> bool {
	text: [dynamic]u8
	defer delete(text)
	aof_manifest_text(m, &text)
	mname: [dynamic]u8
	defer delete(mname)
	aof_manifest_name(&mname)
	return aof_write_file_atomic(string(mname[:]), text[:])
}

aof_manifest_set :: proc(m: Aof_Manifest) {
	aof_manifest_free(&aof.manifest)
	aof.manifest = m
}

aof_bio_pending :: #force_inline proc "contextless" () -> i32 {
	return intrinsics.atomic_load(&aof_bio_pending_fsync)
}

@(private = "file")
aof_datasync_retry :: proc "contextless" (fd: linux.Fd) -> linux.Errno {
	for {
		if err := linux.fdatasync(fd); err != .EINTR {
			return err
		}
	}
}

@(private = "file")
aof_job_sync :: proc "contextless" (fd: linux.Fd) {
	#partial switch err := aof_datasync_retry(fd); err {
	case .NONE, .EBADF, .EINVAL:
	case:
		intrinsics.atomic_store(&aof_bio_err, i32(err))
	}
}

aof_bio_run :: proc "contextless" (job: ^Aof_Job) {
	switch job.kind {
	case .Unlink:
		linux.unlink(cstring(&job.path[0]))
	case .Close:
		linux.close(job.fd)
	case .Fsync:
		aof_job_sync(job.fd)
	}
}

aof_bio_main :: proc() {
	context.assertion_failure_proc = diagnostics_assertion_failure if intrinsics.atomic_load_explicit(&diagnostic_initialized, .Acquire) != 0 else context.assertion_failure_proc
	diagnostics_thread_enter()
	defer diagnostics_thread_leave()
	runtime_tuning_enter(.Bio)
	for {
		sync.sema_wait(&aof_bio_sema)
		sync.mutex_lock(&aof_bio_mutex)
		if aof_bio_head == aof_bio_tail {
			sync.mutex_unlock(&aof_bio_mutex)
			continue
		}
		slot := aof_bio_head % AOF_JOBS
		job := aof_bio_jobs[slot]
		size := aof_bio_sizes[slot]
		gen := aof_bio_gens[slot]
		aof_bio_head += 1
		sync.mutex_unlock(&aof_bio_mutex)
		aof_bio_run(&job)
		if job.kind == .Fsync {
			aof_bio_note_synced(gen, size)
			intrinsics.atomic_sub(&aof_bio_pending_fsync, 1)
		}
		intrinsics.atomic_sub_explicit(&aof_bio_jobs_pending, 1, .Release)
	}
}

aof_bio_before_fork :: proc() {
	for intrinsics.atomic_load_explicit(&aof_bio_jobs_pending, .Acquire) != 0 {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
}

aof_bio_after_fork :: proc() {
	aof_bio_thread = nil
	aof_bio_head = 0
	aof_bio_tail = 0
	aof_bio_mutex = {}
	aof_bio_sema = {}
	aof_bio_pending_fsync = 0
	aof_bio_jobs_pending = 0
}

@(private = "file")
aof_bio_note_synced :: proc "contextless" (gen: i64, size: i64) {
	if intrinsics.atomic_load(&aof_bio_err) != 0 {
		return
	}
	cur := intrinsics.atomic_load(&aof_bio_synced)
	if cur >> AOF_SYNC_SIZE_BITS == gen && cur & AOF_SYNC_SIZE_MASK >= size {
		return
	}
	intrinsics.atomic_store(&aof_bio_synced, gen << AOF_SYNC_SIZE_BITS | (size & AOF_SYNC_SIZE_MASK))
}

@(private = "file")
aof_bio_push :: proc(job: Aof_Job, size: i64) {
	if pst.in_child {
		local := job
		aof_bio_run(&local)
		if job.kind == .Fsync {
			gen := aof_sync_gen & (i64(1) << (63 - AOF_SYNC_SIZE_BITS) - 1)
			aof_bio_note_synced(gen, size)
		}
		return
	}
	if aof_bio_thread == nil {
		aof_bio_thread = thread.create_and_start(aof_bio_main)
	}
	if job.kind == .Fsync {
		intrinsics.atomic_add(&aof_bio_pending_fsync, 1)
	}
	intrinsics.atomic_add_explicit(&aof_bio_jobs_pending, 1, .Relaxed)
	sync.mutex_lock(&aof_bio_mutex)
	gen := aof_sync_gen & (i64(1) << (63 - AOF_SYNC_SIZE_BITS) - 1)
	if aof_bio_tail - aof_bio_head >= AOF_JOBS {
		sync.mutex_unlock(&aof_bio_mutex)
		local := job
		aof_bio_run(&local)
		if job.kind == .Fsync {
			aof_bio_note_synced(gen, size)
			intrinsics.atomic_sub(&aof_bio_pending_fsync, 1)
		}
		intrinsics.atomic_sub_explicit(&aof_bio_jobs_pending, 1, .Release)
		return
	}
	slot := aof_bio_tail % AOF_JOBS
	aof_bio_jobs[slot] = job
	aof_bio_sizes[slot] = size
	aof_bio_gens[slot] = gen
	aof_bio_tail += 1
	sync.mutex_unlock(&aof_bio_mutex)
	sync.sema_post(&aof_bio_sema)
}

aof_bio_submit :: proc(job: Aof_Job) {
	aof_bio_push(job, aof.current_size)
}

aof_bio_fsync :: proc(fd: linux.Fd) {
	aof_bio_push(Aof_Job{kind = .Fsync, fd = fd}, aof.current_size)
}

aof_bio_close :: proc(fd: linux.Fd) {
	aof_bio_push(Aof_Job{kind = .Close, fd = fd}, 0)
}

aof_bio_unlink :: proc(name: string) {
	job := Aof_Job {
		kind = .Unlink,
		fd   = -1,
	}
	aof_cpath(name, job.path[:])
	aof_bio_push(job, 0)
}

@(private = "file")
aof_bio_collect :: proc() {
	if e := intrinsics.atomic_exchange(&aof_bio_err, 0); e != 0 {
		aof.write_err = true
		aof.write_errno = linux.Errno(e)
		aof_err_from_fsync = true
		plog(LOG_WARNING, "Error syncing the AOF file in the background: ", errno_text(linux.Errno(e)))
		persist_update_gate()
		return
	}
	gen := aof_sync_gen & (i64(1) << (63 - AOF_SYNC_SIZE_BITS) - 1)
	packed := intrinsics.atomic_load(&aof_bio_synced)
	if packed >> AOF_SYNC_SIZE_BITS != gen {
		return
	}
	done := min(packed & AOF_SYNC_SIZE_MASK, aof.current_size)
	if done > aof.fsynced_size {
		aof.fsynced_size = done
		if aof.write_err && aof_err_from_fsync {
			aof.write_err = false
			aof_err_from_fsync = false
			plog(LOG_NOTICE, "AOF fsync error looks solved, Eski can write again.")
			persist_update_gate()
		}
	}
}

aof_put_header :: proc(b: ^[dynamic]u8, n: int) {
	tmp: [24]u8
	tmp[0] = '*'
	k := 1 + format_i64(&tmp[1], i64(n))
	tmp[k] = '\r'
	tmp[k + 1] = '\n'
	append(b, ..tmp[:k + 2])
}

aof_put_arg :: proc(b: ^[dynamic]u8, a: []u8) {
	tmp: [24]u8
	tmp[0] = '$'
	k := 1 + format_i64(&tmp[1], i64(len(a)))
	tmp[k] = '\r'
	tmp[k + 1] = '\n'
	append(b, ..tmp[:k + 2])
	append(b, ..a)
	append(b, "\r\n")
}

aof_put_str :: proc(b: ^[dynamic]u8, a: string) {
	aof_put_arg(b, transmute([]u8)a)
}

aof_put_int :: proc(b: ^[dynamic]u8, v: i64) {
	tmp: [24]u8
	n := format_i64(&tmp[0], v)
	aof_put_arg(b, tmp[:n])
}

aof_put_id :: proc(b: ^[dynamic]u8, id: sm.ID) {
	tmp: [sm.ID_TEXT_MAX]u8
	aof_put_arg(b, sm.format_id(&tmp, id))
}

aof_put_argv :: proc(b: ^[dynamic]u8, argv: [][]u8) {
	for a in argv {
		aof_put_arg(b, a)
	}
}

aof_select_into :: proc(b: ^[dynamic]u8, dbid: int) {
	append(b, "*2\r\n$6\r\nSELECT\r\n")
	aof_put_int(b, i64(dbid))
}

aof_emit_timestamp :: proc() {
	if !aof.timestamps {
		return
	}
	now := aof_now_ms() / 1000
	if now == aof.last_ts {
		return
	}
	aof.last_ts = now
	append(&aof.buf, "#TS:")
	aof_put_decimal(&aof.buf, now)
	append(&aof.buf, "\r\n")
}

aof_stage_switch_db :: proc(dbid: int) {
	if aof.stage_count == 0 {
		aof.stage_first_db = dbid
		aof.stage_db = dbid
		return
	}
	if dbid != aof.stage_db {
		aof_select_into(&aof.stage, dbid)
		aof.stage_db = dbid
	}
}

aof_stage_begin :: proc(dbid: int, nargs: int) {
	aof_stage_switch_db(dbid)
	aof.stage_count += 1
	aof_put_header(&aof.stage, nargs)
}

aof_stage_argv :: proc(dbid: int, argv: [][]u8) {
	aof_stage_begin(dbid, len(argv))
	aof_put_argv(&aof.stage, argv)
}

@(private = "file")
aof_sink :: proc(dbid: int, nargs: int) -> ^[dynamic]u8 {
	if aof.in_cmd || aof.in_tx {
		aof_stage_begin(dbid, nargs)
		return &aof.stage
	}
	aof_emit_timestamp()
	if aof.selected_db != dbid {
		aof_select_into(&aof.buf, dbid)
		aof.selected_db = dbid
	}
	aof_put_header(&aof.buf, nargs)
	return &aof.buf
}

aof_write_argv :: proc(dbid: int, argv: [][]u8) {
	b := aof_sink(dbid, len(argv))
	aof_put_argv(b, argv)
}

aof_feed_argv_direct :: proc(dbid: int, argv: [][]u8) {
	if !aof.feed {
		return
	}
	aof_write_argv(dbid, argv)
}

aof_stage_commit :: proc(wrap: bool) {
	defer {
		clear(&aof.stage)
		aof.stage_count = 0
		if cap(aof.stage) > 1 << 20 {
			delete(aof.stage)
			aof.stage = nil
		}
	}
	if aof.stage_count == 0 || aof.fd < 0 {
		return
	}
	aof_emit_timestamp()
	if wrap {
		append(&aof.buf, "*1\r\n$5\r\nMULTI\r\n")
	}
	if aof.selected_db != aof.stage_first_db {
		aof_select_into(&aof.buf, aof.stage_first_db)
	}
	append(&aof.buf, ..aof.stage[:])
	if wrap {
		append(&aof.buf, "*1\r\n$4\r\nEXEC\r\n")
	}
	aof.selected_db = aof.stage_db
}

@(private = "file")
aof_db_of :: proc(c: ^Conn) -> ^Db {
	if c != nil && c.db != nil {
		return c.db
	}
	return cur_db()
}

aof_emit :: proc(c: ^Conn, args: ..[]u8) {
	if !aof.feed {
		return
	}
	db := aof_db_of(c)
	if db == nil {
		return
	}
	aof_write_argv(db.id, args)
	aof_explicit = true
}

aof_emit_direct :: proc(c: ^Conn, argv: [][]u8) {
	if !aof.feed {
		return
	}
	db := aof_db_of(c)
	if db == nil {
		return
	}
	aof_write_argv(db.id, argv)
}

aof_emit_explicit :: proc(c: ^Conn, argv: [][]u8, write: bool) {
	if write {
		aof_emit_direct(c, argv)
	}
	aof_explicit = true
}

aof_mc_set :: proc(key: []u8, val: []u8, at: i64, keepttl: bool) {
	if !aof.feed {
		return
	}
	db := cur_db()
	if db == nil {
		return
	}
	n := 3
	if at > 0 || keepttl {
		n = 5 if at > 0 else 4
	}
	b := aof_sink(db.id, n)
	aof_put_str(b, "SET")
	aof_put_arg(b, key)
	aof_put_arg(b, val)
	if at > 0 {
		aof_put_str(b, "PXAT")
		aof_put_int(b, at)
	} else if keepttl {
		aof_put_str(b, "KEEPTTL")
	}
}

aof_mc_pexpireat :: proc(key: []u8, at: i64) {
	if !aof.feed {
		return
	}
	db := cur_db()
	if db == nil {
		return
	}
	b := aof_sink(db.id, 3)
	aof_put_str(b, "PEXPIREAT")
	aof_put_arg(b, key)
	aof_put_int(b, at)
}

aof_mc_command :: proc(args: ..[]u8) {
	if !aof.feed || len(args) == 0 {
		return
	}
	db := cur_db()
	if db == nil {
		return
	}
	aof_write_argv(db.id, args)
}

aof_hash_field_expired :: proc(h: ht.Hash, field: []u8) {
	ref := ht.key_ref(h)
	if ref == nil { return }
	registry := hash_key_ref_registry(ref)
	if registry == nil || registry.owner == nil || !aof.feed { return }
	db := cast(^Db)registry.owner
	b := aof_sink(db.id, 3)
	aof_put_str(b, "HDEL")
	aof_put_arg(b, hash_key_ref_bytes(ref))
	aof_put_arg(b, field)
}

aof_propagate_del :: proc(db: ^Db, key: []u8, lazy: bool) {
	if !aof.feed || db == nil {
		return
	}
	b := aof_sink(db.id, 2)
	aof_put_str(b, "UNLINK" if lazy else "DEL")
	aof_put_arg(b, key)
}

aof_migrate_deleted :: proc(c: ^Conn, keys: [][]u8) {
	if !aof.feed {
		return
	}
	aof_explicit = true
	if len(keys) == 0 {
		return
	}
	db := aof_db_of(c)
	if db == nil {
		return
	}
	b := aof_sink(db.id, 1 + len(keys))
	aof_put_str(b, "DEL")
	aof_put_argv(b, keys)
}

@(private = "file")
aof_shrink_buf :: proc() {
	if cap(aof.buf) > 4 << 20 && len(aof.buf) == 0 {
		delete(aof.buf)
		aof.buf = nil
	}
}

@(private = "file")
aof_account_written :: proc(n: int) {
	aof.current_size += i64(n)
	aof_incr_bytes += i64(n)
}

@(private = "file")
aof_clear_write_error :: proc() {
	if !aof.write_err || aof_err_from_fsync {
		return
	}
	plog(LOG_WARNING, "AOF write error looks solved, Eski can write again.")
	aof.write_err = false
	persist_update_gate()
}

@(private = "file")
aof_note_write_failure :: proc(written: int, err: linux.Errno) {
	if written > 0 && linux.ftruncate(aof.fd, aof_incr_bytes) != .NONE {
		aof_account_written(written)
		remove_range(&aof.buf, 0, written)
	}
	aof_err_from_fsync = false
	aof.write_errno = err
	aof_log_write_error(err)
	switch {
	case aof.fsync == .Always:
		plog(LOG_WARNING, "Can't recover from AOF write error when the AOF fsync policy is 'always'. Exiting...")
		linux.exit_group(1)
	case !aof.write_err:
		aof.write_err = true
		persist_update_gate()
	}
}

@(private = "file")
aof_log_write_error :: proc(err: linux.Errno) {
	stamp := persist_unix_now()
	if stamp - aof_last_err_log < 30 {
		return
	}
	aof_last_err_log = stamp
	plog(LOG_WARNING, "Error writing to the AOF file: ", errno_text(err))
}

aof_write_buffer :: proc() -> bool {
	if len(aof.buf) == 0 || aof.fd < 0 {
		return true
	}
	started := latency_start()
	written, err := aof_write_all(aof.fd, aof.buf[:])
	latency_end("aof-write", started)
	if err != .NONE {
		aof_note_write_failure(written, err)
		return false
	}
	aof_account_written(written)
	clear(&aof.buf)
	aof_shrink_buf()
	aof_clear_write_error()
	return true
}

@(private = "file")
aof_incr_bytes: i64

@(private = "file")
aof_fsync_suppressed :: proc() -> bool {
	return aof.no_fsync_on_rewrite && pst.child_pid > 0
}

@(private = "file")
aof_maybe_background_sync :: proc(now: i64) {
	if aof_bio_pending() != 0 || now - aof.last_fsync_ms < 1000 {
		return
	}
	aof_bio_fsync(aof.fd)
	aof.last_fsync_ms = now
}

@(private = "file")
aof_keep_deferring :: proc(now: i64) -> bool {
	if aof.deferred_write_at == 0 {
		aof.deferred_write_at = now
		return true
	}
	if now - aof.deferred_write_at < AOF_WRITE_DEFER_MAX_MS {
		return true
	}
	aof.delayed_fsync += 1
	plog(LOG_NOTICE, "Asynchronous AOF fsync is taking too long (disk is busy?). Writing the AOF buffer without waiting for fsync to complete, this may slow down Eski.")
	return false
}

@(private = "file")
aof_write_pending :: proc() -> bool {
	aof.deferred_write_at = 0
	if aof_flush_sleep_us > 0 {
		aof_flush_sleep()
	}
	return aof_write_buffer()
}

@(private = "file")
aof_sync_now :: proc(now: i64) {
	started := latency_start()
	err := aof_datasync_retry(aof.fd)
	latency_end("aof-fsync-always", started)
	if err == .NONE {
		aof.last_fsync_ms = now
		aof.fsynced_size = aof.current_size
		return
	}
	plog(LOG_WARNING, "Can't persist AOF for fsync error when the AOF fsync policy is 'always': ", errno_text(err), ". Exiting...")
	linux.exit_group(1)
}

aof_flush :: proc(force: bool) {
	now := aof_now_ms()
	if aof.fd < 0 {
		return
	}
	per_second := aof.fsync == .Everysec
	if len(aof.buf) == 0 {
		if per_second && aof.fsynced_size != aof.current_size && !aof_fsync_suppressed() {
			aof_maybe_background_sync(now)
		}
		return
	}
	if per_second && !force && aof_bio_pending() > 0 && aof_keep_deferring(now) {
		return
	}
	if !aof_write_pending() || aof_fsync_suppressed() {
		return
	}
	#partial switch aof.fsync {
	case .Always:
		aof_sync_now(now)
	case .Everysec:
		aof_maybe_background_sync(now)
	}
}

aof_fsync_sync :: proc() {
	if aof.fd < 0 {
		return
	}
	if len(aof.buf) > 0 {
		aof_flush(true)
	}
	if aof.fsynced_size >= aof.current_size {
		return
	}
	err := linux.fdatasync(aof.fd)
	for err == .EINTR {
		err = linux.fdatasync(aof.fd)
	}
	if err == .NONE {
		aof.fsynced_size = aof.current_size
		aof.last_fsync_ms = aof_now_ms()
	}
}

aof_defer_conn :: proc(c: ^Conn) {
	if c == nil {
		return
	}
	n := len(aof.deferred)
	if n > 0 && aof.deferred[n - 1].fd == c.fd && aof.deferred[n - 1].id == c.id {
		return
	}
	append(&aof.deferred, Aof_Deferred{fd = c.fd, id = c.id})
}

@(private = "file")
aof_release_deferred :: proc() {
	for d in aof.deferred {
		idx := int(d.fd)
		if idx < 0 || idx >= len(srv.conns) {
			continue
		}
		c := srv.conns[idx]
		if c == nil || c.id != d.id || c.fd != d.fd {
			continue
		}
		if c.wlen > c.wpos {
			c.want_write = true
			epoll_set(c.fd, .MOD, true, c.id)
		}
	}
	clear(&aof.deferred)
}

aof_before_sleep :: proc() {
	if aof.fd >= 0 {
		aof_bio_collect()
		if len(aof.buf) > 0 || (aof.fsync == .Everysec && aof.fsynced_size != aof.current_size) {
			aof_flush(false)
		}
	}
	if len(aof.deferred) > 0 {
		aof_release_deferred()
	}
}

aof_flush_for_reply :: proc() {
	if aof.fd < 0 || len(aof.buf) == 0 {
		return
	}
	aof_flush(aof.fsync == .Always)
}

Aof_Rp :: struct {
	b: []u8,
	i: int,
}

aof_rp_line :: proc(p: ^Aof_Rp) -> (kind: u8, line: []u8, ok: bool) {
	if p.i >= len(p.b) {
		return
	}
	kind = p.b[p.i]
	j := p.i + 1
	for j + 1 < len(p.b) && !(p.b[j] == '\r' && p.b[j + 1] == '\n') {
		j += 1
	}
	if j + 1 >= len(p.b) {
		return
	}
	line = p.b[p.i + 1:j]
	p.i = j + 2
	ok = true
	return
}

aof_rp_int :: proc(p: ^Aof_Rp) -> (v: i64, ok: bool) {
	save := p.i
	kind, line, good := aof_rp_line(p)
	if !good || kind != ':' {
		p.i = save
		return
	}
	return parse_i64(line)
}

aof_rp_bulk :: proc(p: ^Aof_Rp) -> (data: []u8, null: bool, ok: bool) {
	save := p.i
	kind, line, good := aof_rp_line(p)
	if !good {
		p.i = save
		return
	}
	switch kind {
	case '$', '=':
		n, nok := parse_i64(line)
		if !nok {
			p.i = save
			return
		}
		if n < 0 {
			return nil, true, true
		}
		if p.i + int(n) + 2 > len(p.b) {
			p.i = save
			return
		}
		data = p.b[p.i:p.i + int(n)]
		p.i += int(n) + 2
		if kind == '=' && len(data) >= 4 {
			data = data[4:]
		}
		return data, false, true
	case '+', ',', '(', ':':
		return line, false, true
	case '_':
		return nil, true, true
	}
	p.i = save
	return
}

aof_rp_agg :: proc(p: ^Aof_Rp) -> (n: int, null: bool, ok: bool) {
	save := p.i
	kind, line, good := aof_rp_line(p)
	if !good {
		p.i = save
		return
	}
	switch kind {
	case '*', '~', '>', '%':
		v, vok := parse_i64(line)
		if !vok {
			p.i = save
			return
		}
		if v < 0 {
			return 0, true, true
		}
		if kind == '%' {
			return int(v) * 2, false, true
		}
		return int(v), false, true
	case '_':
		return 0, true, true
	}
	p.i = save
	return
}

aof_rp_skip :: proc(p: ^Aof_Rp) -> bool {
	if p.i >= len(p.b) {
		return false
	}
	switch p.b[p.i] {
	case '$', '=', '!':
		_, line, good := aof_rp_line(p)
		if !good {
			return false
		}
		n, nok := parse_i64(line)
		if !nok {
			return false
		}
		if n < 0 {
			return true
		}
		if p.i + int(n) + 2 > len(p.b) {
			return false
		}
		p.i += int(n) + 2
		return true
	case '*', '~', '>', '%', '|':
		kind, line, good := aof_rp_line(p)
		if !good {
			return false
		}
		n, nok := parse_i64(line)
		if !nok {
			return false
		}
		if n < 0 {
			return true
		}
		count := int(n)
		if kind == '%' || kind == '|' {
			count *= 2
		}
		for _ in 0 ..< count {
			if !aof_rp_skip(p) {
				return false
			}
		}
		if kind == '|' {
			return aof_rp_skip(p)
		}
		return true
	case:
		_, _, good := aof_rp_line(p)
		return good
	}
}

aof_reply_is_null :: proc(reply: []u8) -> bool {
	if len(reply) == 0 {
		return false
	}
	switch reply[0] {
	case '_':
		return true
	case '$', '*':
		return len(reply) >= 3 && reply[1] == '-' && reply[2] == '1'
	}
	return false
}

aof_reply_int :: proc(reply: []u8) -> (i64, bool) {
	p := Aof_Rp {
		b = reply,
	}
	return aof_rp_int(&p)
}

aof_reply_bulk :: proc(reply: []u8) -> ([]u8, bool) {
	p := Aof_Rp {
		b = reply,
	}
	data, null, ok := aof_rp_bulk(&p)
	if !ok || null {
		return nil, false
	}
	return data, true
}

aof_zero_skip :: proc(reply: []u8) -> bool {
	v, ok := aof_reply_int(reply)
	return ok && v == 0
}

@(private = "file")
aof_reply_empty_agg :: proc(reply: []u8) -> bool {
	p := Aof_Rp {
		b = reply,
	}
	n, null, ok := aof_rp_agg(&p)
	return ok && (null || n == 0)
}

@(private = "file")
aof_reply_failed :: proc "contextless" (reply: []u8) -> bool {
	return len(reply) > 0 && (reply[0] == '-' || reply[0] == '!')
}

@(private = "file")
aof_reply_view :: proc(c: ^Conn, pending: int) -> []u8 {
	if c == nil || c.wbuf == nil || pending < 0 || pending > c.wlen {
		return nil
	}
	reply := c.wbuf[pending:c.wlen]
	for len(reply) > 0 && (reply[0] == '>' || reply[0] == '|') {
		p := Aof_Rp {
			b = reply,
		}
		if !aof_rp_skip(&p) {
			return nil
		}
		reply = reply[p.i:]
	}
	return reply
}

aof_key_state :: proc(db: ^Db, key: []u8) -> (exists: bool, expire: i64, v: Slot_Value) {
	if db == nil {
		return
	}
	t, i := persist_raw_locate(db, key)
	if i < 0 {
		return
	}
	at := slot_deadline(db, t, i)
	if at != 0 && at <= expire_now() {
		return
	}
	return true, at, persist_slot_value(db, &t.slots[i].key, &t.slots[i].val)
}

aof_stream_of :: proc(db: ^Db, key: []u8) -> sm.Stream {
	exists, _, v := aof_key_state(db, key)
	if !exists || v.obj == nil || v.type != .Stream {
		return nil
	}
	return cast(sm.Stream)v.obj
}

aof_parse_id :: proc(s: []u8) -> (id: sm.ID, ok: bool) {
	return sm.parse_exact_id(s)
}

aof_has_token :: proc(argv: [][]u8, from: int, tok: string) -> bool {
	for i in max(from, 0) ..< len(argv) {
		if eq_nocase(argv[i], tok) {
			return true
		}
	}
	return false
}

@(private = "file")
Aof_Kind :: enum u8 {
	Unknown,
	Plain,
	Zero_Skip,
	Pop,
	Set,
	Setex,
	Getex,
	Getdel,
	Expire,
	Incrbyfloat,
	Hincrbyfloat,
	Spop,
	Lmpop,
	Zmpop,
	Blpop,
	Brpop,
	Blmpop,
	Bzpopmin,
	Bzpopmax,
	Bzmpop,
	Blmove,
	Brpoplpush,
	Xadd,
	Xtrim,
	Xreadgroup,
	Xclaim,
	Xautoclaim,
	Xgroup,
	Restore,
	Hexpire,
	Hpexpire,
	Hexpireat,
	Hpexpireat,
	Hpersist,
	Sort,
	Store_Opt,
	Bitfield,
	Migrate,
	Linsert,
	Scan,
	Randomkey,
	Hincrby,
	Hsetnx,
	Exec,
}

@(private = "file")
AOF_KIND_SLOTS :: 1024

@(private = "file")
aof_kind_keys: [AOF_KIND_SLOTS]^Command

@(private = "file")
aof_kind_vals: [AOF_KIND_SLOTS]Aof_Kind

@(private = "file")
aof_kind_by_name :: proc(name: string) -> Aof_Kind {
	switch name {
	case "set":
		return .Set
	case "setex", "psetex":
		return .Setex
	case "getex":
		return .Getex
	case "getdel":
		return .Getdel
	case "expire", "pexpire", "expireat", "pexpireat":
		return .Expire
	case "incrbyfloat":
		return .Incrbyfloat
	case "hincrbyfloat":
		return .Hincrbyfloat
	case "spop":
		return .Spop
	case "lmpop":
		return .Lmpop
	case "zmpop":
		return .Zmpop
	case "blpop":
		return .Blpop
	case "brpop":
		return .Brpop
	case "blmpop":
		return .Blmpop
	case "bzpopmin":
		return .Bzpopmin
	case "bzpopmax":
		return .Bzpopmax
	case "bzmpop":
		return .Bzmpop
	case "blmove":
		return .Blmove
	case "brpoplpush":
		return .Brpoplpush
	case "xadd":
		return .Xadd
	case "xtrim":
		return .Xtrim
	case "xreadgroup":
		return .Xreadgroup
	case "xclaim":
		return .Xclaim
	case "xautoclaim":
		return .Xautoclaim
	case "xgroup":
		return .Xgroup
	case "restore", "restore-asking":
		return .Restore
	case "hexpire":
		return .Hexpire
	case "hpexpire":
		return .Hpexpire
	case "hexpireat":
		return .Hexpireat
	case "hpexpireat":
		return .Hpexpireat
	case "hpersist":
		return .Hpersist
	case "sort":
		return .Sort
	case "georadius", "georadiusbymember":
		return .Store_Opt
	case "bitfield":
		return .Bitfield
	case "migrate":
		return .Migrate
	case "linsert":
		return .Linsert
	case "scan":
		return .Scan
	case "randomkey":
		return .Randomkey
	case "hincrby":
		return .Hincrby
	case "hsetnx":
		return .Hsetnx
	case "exec":
		return .Exec
	case "del", "unlink", "sadd", "srem", "hdel", "zrem", "zremrangebyrank", "zremrangebyscore", "zremrangebylex", "lrem", "setnx", "msetnx", "smove", "renamenx", "move", "copy", "xdel", "xack", "pfadd", "lpushx", "rpushx", "setrange", "persist":
		return .Zero_Skip
	case "lpop", "rpop", "zpopmin", "zpopmax", "lmove", "rpoplpush":
		return .Pop
	}
	return .Plain
}

@(private = "file")
aof_kind_of :: proc(cmd: ^Command) -> Aof_Kind {
	if cmd == nil {
		return .Plain
	}
	h := u64(uintptr(cmd)) >> 3
	h *= 0x9E3779B97F4A7C15
	i := int(h >> 54) & (AOF_KIND_SLOTS - 1)
	for _ in 0 ..< AOF_KIND_SLOTS {
		k := aof_kind_keys[i]
		if k == cmd {
			return aof_kind_vals[i]
		}
		if k == nil {
			kind := aof_kind_by_name(cmd.name)
			aof_kind_keys[i] = cmd
			aof_kind_vals[i] = kind
			switch kind {
			case .Xreadgroup:
				aof.xrg_cmd = cmd
			case .Scan:
				aof.scan_cmd = cmd
			case .Randomkey:
				aof.randomkey_cmd = cmd
			case .Unknown, .Plain, .Zero_Skip, .Pop, .Set, .Setex, .Getex, .Getdel, .Expire, .Incrbyfloat, .Hincrbyfloat, .Spop, .Lmpop, .Zmpop, .Blpop, .Brpop, .Blmpop, .Bzpopmin, .Bzpopmax, .Bzmpop, .Blmove, .Brpoplpush, .Xadd, .Xtrim, .Xclaim, .Xautoclaim, .Xgroup, .Restore, .Hexpire, .Hpexpire, .Hexpireat, .Hpexpireat, .Hpersist, .Sort, .Store_Opt, .Bitfield, .Migrate, .Linsert, .Hincrby, .Hsetnx, .Exec:
			}
			return kind
		}
		i = (i + 1) & (AOF_KIND_SLOTS - 1)
	}
	return aof_kind_by_name(cmd.name)
}

@(private = "file")
aof_emit_del :: proc(db: ^Db, key: []u8) {
	b := aof_sink(db.id, 2)
	aof_put_str(b, "DEL")
	aof_put_arg(b, key)
}

@(private = "file")
aof_snap_cmd: ^Command

@(private = "file")
aof_tx_conn: ^Conn

@(private = "file")
aof_expired_before: i64

@(private = "file")
aof_precheck_keys :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8) {
	db := aof_db_of(c)
	if db == nil || db.expires <= 0 {
		return
	}
	spec := cmd_spec_lookup(cmd, argv)
	if spec == nil {
		return
	}
	clear(&aof_keypos)
	command_keys(spec, argv, &aof_keypos)
	for pos, n in aof_keypos {
		if pos <= 0 || pos >= len(argv) {
			continue
		}
		key := argv[pos]
		seen := false
		for prev in aof_keypos[:n] {
			if prev > 0 && prev < len(argv) && bytes_eq(argv[prev], key) {
				seen = true
				break
			}
		}
		if seen {
			continue
		}
		exists, expired := db_key_state(db, key)
		if exists && expired {
			aof_emit_del(db, key)
		}
	}
}

@(private = "file")
aof_precheck_field :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) < 3 {
		return
	}
	db := aof_db_of(c)
	if db == nil {
		return
	}
	exists, _, v := aof_key_state(db, argv[1])
	if !exists || v.obj == nil || v.type != .Hash {
		return
	}
	_, _ = ht.get(cast(ht.Hash)v.obj, argv[2], hash_now())
}

Aof_Xrg :: struct {
	group:    []u8,
	consumer: []u8,
	noack:    bool,
	keys_at:  int,
	nkeys:    int,
}

aof_xrg_parse :: proc(argv: [][]u8) -> (x: Aof_Xrg, ok: bool) {
	if len(argv) < 7 || !eq_nocase(argv[1], "group") {
		return
	}
	x.group = argv[2]
	x.consumer = argv[3]
	i := 4
	for i < len(argv) {
		a := argv[i]
		switch {
		case eq_nocase(a, "count"), eq_nocase(a, "block"):
			i += 2
		case eq_nocase(a, "noack"):
			x.noack = true
			i += 1
		case eq_nocase(a, "streams"):
			rest := len(argv) - i - 1
			if rest <= 0 || rest % 2 != 0 {
				return
			}
			x.keys_at = i + 1
			x.nkeys = rest / 2
			ok = true
			return
		case:
			return
		}
	}
	return
}

@(private = "file")
aof_group_of :: proc(db: ^Db, key: []u8, group: []u8) -> (sm.Stream, ^sm.Group) {
	s := aof_stream_of(db, key)
	if s == nil {
		return nil, nil
	}
	return s, sm.find_group(s, group)
}

aof_consumer_exists :: proc(db: ^Db, key: []u8, group: []u8, consumer: []u8) -> bool {
	_, cg := aof_group_of(db, key, group)
	return cg != nil && sm.find_member(cg, consumer) != nil
}

aof_nack_of :: proc(cg: ^sm.Group, id: sm.ID) -> ^sm.Delivery {
	if cg == nil || cg.pending == nil {
		return nil
	}
	key: [16]u8
	sm.encode_id(&key, id)
	it: rx.Iterator
	rx.start(&it, cg.pending)
	rx.seek(&it, ">=", key[:])
	found: ^sm.Delivery
	if rx.next(&it) && bytes_eq(rx.key(&it), key[:]) {
		found = (^sm.Delivery)(it.data)
	}
	rx.stop(&it)
	return found
}

aof_xrg_snapshot :: proc(c: ^Conn, argv: [][]u8) {
	clear(&aof.xrg_existed)
	x, ok := aof_xrg_parse(argv)
	if !ok {
		return
	}
	db := aof_db_of(c)
	for k in 0 ..< x.nkeys {
		append(&aof.xrg_existed, aof_consumer_exists(db, argv[x.keys_at + k], x.group, x.consumer))
	}
	aof_snap.valid = true
}

@(private = "file")
aof_claim_snapshot :: proc(c: ^Conn, argv: [][]u8, with_ids: bool) {
	if len(argv) < 5 {
		return
	}
	db := aof_db_of(c)
	_, cg := aof_group_of(db, argv[1], argv[2])
	aof_snap.valid = true
	aof_snap.group_found = cg != nil
	aof_snap.existed = cg != nil && sm.find_member(cg, argv[3]) != nil
	if cg != nil {
		aof_snap.last_id = cg.delivered
		aof_snap.entries = cg.reads
	}
	clear(&aof_snap_pel)
	if !with_ids {
		return
	}
	for i := 5; i < len(argv); i += 1 {
		id, idok := sm.parse_exact_id(argv[i])
		if !idok {
			break
		}
		append(&aof_snap_pel, cg != nil && aof_nack_of(cg, id) != nil)
	}
}

@(private = "file")
aof_tx_precheck_queue :: proc(c: ^Conn) {
	if c == nil || c.tx == nil {
		return
	}
	db := aof_db_of(c)
	if db == nil || db.expires <= 0 {
		return
	}
	txs := c.tx
	for q in txs.cmds {
		if q.cmd == nil || q.first < 0 || q.argc <= 0 || q.first + q.argc > len(txs.spans) {
			continue
		}
		mode := -1
		sp := txs.spans[q.first]
		if sp[0] >= 0 && sp[1] >= 0 && sp[0] + sp[1] <= len(txs.bytes) && eq_fold(txs.bytes[sp[0]:sp[0] + sp[1]], transmute([]u8)q.cmd.name) {
			mode = 0
		} else if sp[0] >= 0 && sp[1] >= sp[0] && sp[1] <= len(txs.bytes) && eq_fold(txs.bytes[sp[0]:sp[1]], transmute([]u8)q.cmd.name) {
			mode = 1
		}
		if mode < 0 {
			continue
		}
		clear(&aof_load_argv)
		valid := true
		for j in q.first ..< q.first + q.argc {
			s := txs.spans[j]
			lo, hi := s[0], s[0] + s[1]
			if mode == 1 {
				hi = s[1]
			}
			if lo < 0 || hi < lo || hi > len(txs.bytes) {
				valid = false
				break
			}
			append(&aof_load_argv, txs.bytes[lo:hi])
		}
		if valid {
			aof_precheck_keys(c, q.cmd, aof_load_argv[:])
		}
	}
	clear(&aof_load_argv)
}

@(private = "file")
aof_is_queueing :: proc(c: ^Conn, kind: Aof_Kind) -> bool {
	return c != nil && .Multi in c.txf && !aof.in_tx && tx_exec_conn != c && kind != .Exec
}

aof_cmd_prepare :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8) {
	aof_snap = {}
	aof_snap_cmd = nil
	if cmd == nil || len(argv) == 0 {
		return
	}
	kind := aof_kind_of(cmd)
	if aof_is_queueing(c, kind) {
		return
	}
	aof_snap_cmd = cmd
	aof_precheck_keys(c, cmd, argv)
	#partial switch kind {
	case .Hincrby, .Hsetnx:
		aof_precheck_field(c, argv)
	case .Xreadgroup:
		aof_xrg_snapshot(c, argv)
	case .Xclaim:
		aof_claim_snapshot(c, argv, true)
	case .Xautoclaim:
		aof_claim_snapshot(c, argv, false)
	case .Scan, .Randomkey:
		aof_expired_before = srv.stat_expired
		aof_snap.valid = true
	}
}

aof_cmd_begin :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8) {
	if !aof.feed {
		return
	}
	if aof.in_tx {
		if lua_effect_owner(c) || (c == aof_tx_conn && (tx_exec_conn != nil || (c != nil && .Multi in c.txf))) {
			aof_cmd_prepare(c, cmd, argv)
			return
		}
		aof_tx_end()
	}
	if aof.in_cmd || aof.stage_count > 0 {
		aof_stage_commit(aof.stage_count > 1)
	}
	aof.in_cmd = true
	aof_explicit = false
	aof_cmd_prepare(c, cmd, argv)
}

aof_tx_begin :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8) {
	if !aof.feed {
		return
	}
	if !aof.in_tx {
		aof.in_tx = true
		aof_tx_conn = c
		aof_explicit = false
		if cmd == nil || aof_kind_of(cmd) == .Exec {
			aof_tx_precheck_queue(c)
			return
		}
	}
	if cmd != nil && aof_kind_of(cmd) != .Exec {
		aof_cmd_prepare(c, cmd, argv)
	}
}

aof_tx_end :: proc() {
	if !aof.in_tx {
		return
	}
	aof.in_tx = false
	aof_tx_conn = nil
	aof_stage_commit(aof.stage_count > 1)
}

aof_emit_pexpireat :: proc(c: ^Conn, key: []u8, at: i64) {
	db := aof_db_of(c)
	b := aof_sink(db.id, 3)
	aof_put_str(b, "PEXPIREAT")
	aof_put_arg(b, key)
	aof_put_int(b, at)
}

aof_emit_set_pxat :: proc(c: ^Conn, key: []u8, val: []u8, at: i64) {
	db := aof_db_of(c)
	b := aof_sink(db.id, 5)
	aof_put_str(b, "SET")
	aof_put_arg(b, key)
	aof_put_arg(b, val)
	aof_put_str(b, "PXAT")
	aof_put_int(b, at)
}

aof_propagate_as_is :: proc(c: ^Conn, argv: [][]u8) {
	db := aof_db_of(c)
	aof_write_argv(db.id, argv)
}

aof_tr_set :: proc(c: ^Conn, argv: [][]u8, reply: []u8) {
	if len(argv) < 3 {
		return
	}
	db := aof_db_of(c)
	nx, xx, get, expiry, relative, has_ifeq := false, false, false, false, false, false
	ifeq: []u8
	i := 3
	for i < len(argv) {
		a := argv[i]
		switch {
		case eq_nocase(a, "nx"):
			nx = true
		case eq_nocase(a, "xx"):
			xx = true
		case eq_nocase(a, "get"):
			get = true
		case eq_nocase(a, "ex"), eq_nocase(a, "px"), eq_nocase(a, "exat"):
			expiry = true
			relative = true
			i += 1
		case eq_nocase(a, "pxat"):
			expiry = true
			i += 1
		case eq_nocase(a, "ifeq"):
			has_ifeq = true
			if i + 1 < len(argv) {
				ifeq = argv[i + 1]
			}
			i += 1
		}
		i += 1
	}
	happened := true
	switch {
	case len(reply) == 0:
		exists, _, v := aof_key_state(db, argv[1])
		happened = exists && v.obj == nil && bytes_eq(v.str, argv[2])
	case !get:
		happened = !aof_reply_is_null(reply)
	case nx:
		happened = aof_reply_is_null(reply)
	case xx:
		happened = !aof_reply_is_null(reply)
	case has_ifeq:
		old, ok := aof_reply_bulk(reply)
		happened = ok && bytes_eq(old, ifeq)
	}
	if !happened {
		return
	}
	if expiry {
		exists, at, _ := aof_key_state(db, argv[1])
		if !exists {
			aof_emit_del(db, argv[1])
			return
		}
		if relative && at > 0 {
			aof_emit_set_pxat(c, argv[1], argv[2], at)
			return
		}
	}
	aof_write_argv(db.id, argv)
}

@(private = "file")
aof_tr_setex :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) < 4 {
		return
	}
	db := aof_db_of(c)
	exists, at, _ := aof_key_state(db, argv[1])
	if !exists {
		aof_emit_del(db, argv[1])
		return
	}
	if at <= 0 {
		b := aof_sink(db.id, 3)
		aof_put_str(b, "SET")
		aof_put_arg(b, argv[1])
		aof_put_arg(b, argv[3])
		return
	}
	aof_emit_set_pxat(c, argv[1], argv[3], at)
}

aof_tr_getex :: proc(c: ^Conn, argv: [][]u8, reply: []u8) {
	if len(argv) < 2 || aof_reply_is_null(reply) {
		return
	}
	persist, expiry := false, false
	for a in argv[2:] {
		switch {
		case eq_nocase(a, "persist"):
			persist = true
		case eq_nocase(a, "ex"), eq_nocase(a, "px"), eq_nocase(a, "exat"), eq_nocase(a, "pxat"):
			expiry = true
		}
	}
	if !persist && !expiry {
		return
	}
	db := aof_db_of(c)
	exists, at, _ := aof_key_state(db, argv[1])
	if !exists {
		aof_emit_del(db, argv[1])
		return
	}
	if persist || at <= 0 {
		b := aof_sink(db.id, 2)
		aof_put_str(b, "PERSIST")
		aof_put_arg(b, argv[1])
		return
	}
	aof_emit_pexpireat(c, argv[1], at)
}

@(private = "file")
aof_tr_expire :: proc(c: ^Conn, argv: [][]u8, reply: []u8) {
	if len(argv) < 3 || aof_zero_skip(reply) {
		return
	}
	db := aof_db_of(c)
	exists, at, _ := aof_key_state(db, argv[1])
	if !exists {
		aof_emit_del(db, argv[1])
		return
	}
	if at > 0 {
		aof_emit_pexpireat(c, argv[1], at)
	}
}

@(private = "file")
aof_tr_incrbyfloat :: proc(c: ^Conn, argv: [][]u8) {
	db := aof_db_of(c)
	exists, _, v := aof_key_state(db, argv[1])
	if !exists || v.obj != nil {
		return
	}
	b := aof_sink(db.id, 4)
	aof_put_str(b, "SET")
	aof_put_arg(b, argv[1])
	aof_put_arg(b, v.str)
	aof_put_str(b, "KEEPTTL")
}

@(private = "file")
aof_tr_hincrbyfloat :: proc(c: ^Conn, argv: [][]u8, reply: []u8, field_deadline: i64 = -1) {
	if len(argv) < 4 { return }
	db := aof_db_of(c)
	if db == nil { return }
	val, ok := aof_reply_bulk(reply)
	h: ht.Hash
	if !ok || field_deadline < 0 {
		t, i := persist_raw_locate(db, argv[1])
		if i >= 0 {
			v := persist_slot_value(db, &t.slots[i].key, &t.slots[i].val)
			if v.obj != nil && v.type == .Hash { h = cast(ht.Hash)v.obj }
		}
	}
	vbuf: [24]u8
	if !ok {
		if h == nil { return }
		hv, _, found := ht.get_raw(h, argv[2])
		if !found { return }
		val = ht.value_bytes(hv, cast(^[21]u8)&vbuf)
	}
	deadline := field_deadline
	if deadline < 0 {
		deadline = 0
		if h != nil {
			_, expires, found := ht.get_raw(h, argv[2])
			if found && expires != ht.DEADLINE_UNSET { deadline = i64(expires) }
		}
	}
	b := aof_sink(db.id, 4)
	aof_put_str(b, "HSET")
	aof_put_arg(b, argv[1])
	aof_put_arg(b, argv[2])
	aof_put_arg(b, val)
	if deadline > 0 {
		b = aof_sink(db.id, 6)
		aof_put_str(b, "HPEXPIREAT")
		aof_put_arg(b, argv[1])
		aof_put_int(b, deadline)
		aof_put_str(b, "FIELDS")
		aof_put_int(b, 1)
		aof_put_arg(b, argv[2])
	}
}

AOF_SPOP_BATCH :: 1024

aof_tr_spop :: proc(c: ^Conn, argv: [][]u8, reply: []u8) {
	db := aof_db_of(c)
	if len(reply) == 0 {
		aof_write_argv(db.id, argv)
		return
	}
	if len(argv) == 2 {
		member, ok := aof_reply_bulk(reply)
		if !ok {
			return
		}
		b := aof_sink(db.id, 3)
		aof_put_str(b, "SREM")
		aof_put_arg(b, argv[1])
		aof_put_arg(b, member)
		return
	}
	p := Aof_Rp {
		b = reply,
	}
	n, null, ok := aof_rp_agg(&p)
	if !ok || null || n == 0 {
		return
	}
	exists, _, _ := aof_key_state(db, argv[1])
	if !exists {
		aof_emit_del(db, argv[1])
		return
	}
	clear(&aof.args)
	for _ in 0 ..< n {
		m, mnull, mok := aof_rp_bulk(&p)
		if !mok || mnull {
			clear(&aof.args)
			aof_write_argv(db.id, argv)
			return
		}
		append(&aof.args, m)
	}
	for start := 0; start < len(aof.args); start += AOF_SPOP_BATCH {
		batch := aof.args[start:min(start + AOF_SPOP_BATCH, len(aof.args))]
		b := aof_sink(db.id, 2 + len(batch))
		aof_put_str(b, "SREM")
		aof_put_arg(b, argv[1])
		aof_put_argv(b, batch)
	}
	clear(&aof.args)
}

@(private = "file")
aof_emit_pop :: proc(db: ^Db, name: string, key: []u8, count: int) {
	b := aof_sink(db.id, 3 if count >= 0 else 2)
	aof_put_str(b, name)
	aof_put_arg(b, key)
	if count >= 0 {
		aof_put_int(b, i64(count))
	}
}

aof_tr_mpop :: proc(c: ^Conn, argv: [][]u8, reply: []u8, blocking: bool, zset: bool) {
	db := aof_db_of(c)
	at := 2 if blocking else 1
	if at >= len(argv) {
		return
	}
	nk, nok := parse_i64(argv[at])
	dir := at + 1 + int(nk)
	if !nok || nk <= 0 || dir >= len(argv) {
		return
	}
	if len(reply) == 0 {
		if !blocking {
			aof_write_argv(db.id, argv)
		}
		return
	}
	p := Aof_Rp {
		b = reply,
	}
	n, null, ok := aof_rp_agg(&p)
	if !ok || null || n < 2 {
		return
	}
	key, knull, kok := aof_rp_bulk(&p)
	if !kok || knull {
		return
	}
	m, mnull, mok := aof_rp_agg(&p)
	if !mok || mnull || m == 0 {
		return
	}
	name: string
	if zset {
		name = "ZPOPMIN" if eq_nocase(argv[dir], "min") else "ZPOPMAX"
	} else {
		name = "LPOP" if eq_nocase(argv[dir], "left") else "RPOP"
	}
	aof_emit_pop(db, name, key, m)
}

@(private = "file")
aof_tr_bpop :: proc(c: ^Conn, reply: []u8, name: string) {
	if len(reply) == 0 {
		return
	}
	p := Aof_Rp {
		b = reply,
	}
	n, null, ok := aof_rp_agg(&p)
	if !ok || null || n < 2 {
		return
	}
	key, knull, kok := aof_rp_bulk(&p)
	if !kok || knull {
		return
	}
	aof_emit_pop(aof_db_of(c), name, key, -1)
}

@(private = "file")
aof_tr_blmove :: proc(c: ^Conn, argv: [][]u8, reply: []u8, plain: bool) {
	if len(reply) == 0 || aof_reply_is_null(reply) {
		return
	}
	db := aof_db_of(c)
	if plain {
		if len(argv) < 3 {
			return
		}
		b := aof_sink(db.id, 3)
		aof_put_str(b, "RPOPLPUSH")
		aof_put_arg(b, argv[1])
		aof_put_arg(b, argv[2])
		return
	}
	if len(argv) < 5 {
		return
	}
	b := aof_sink(db.id, 5)
	aof_put_str(b, "LMOVE")
	aof_put_argv(b, argv[1:5])
}

aof_trim_threshold :: proc(s: sm.Stream, minid: bool, dst: ^[sm.ID_TEXT_MAX]u8) -> []u8 {
	if !minid {
		n := format_i64(&dst[0], i64(s.live))
		return dst[:n]
	}
	if s.live > 0 {
		si: sm.Cursor
		sm.cursor_open(&si, s, nil, nil, false)
		id, _, found := sm.cursor_next(&si)
		sm.cursor_close(&si)
		if found {
			return sm.format_id(dst, id)
		}
	}
	return sm.format_id(dst, sm.ID_MAX)
}

@(private = "file")
Aof_Trim :: struct {
	strat:  int,
	approx: bool,
	thr:    int,
	next:   int,
	nomk:   int,
}

@(private = "file")
aof_parse_trim :: proc(argv: [][]u8, from: int, adding: bool) -> (t: Aof_Trim) {
	t.strat = -1
	t.thr = -1
	t.nomk = -1
	i := from
	for i < len(argv) {
		a := argv[i]
		if adding && eq_nocase(a, "nomkstream") {
			t.nomk = i
			i += 1
			continue
		}
		if eq_nocase(a, "maxlen") || eq_nocase(a, "minid") {
			t.strat = i
			i += 1
			if i < len(argv) && len(argv[i]) == 1 && argv[i][0] == '~' {
				t.approx = true
				i += 1
			} else if i < len(argv) && len(argv[i]) == 1 && argv[i][0] == '=' {
				i += 1
			}
			t.thr = i
			i += 1
			continue
		}
		if eq_nocase(a, "limit") {
			i += 2
			continue
		}
		break
	}
	t.next = i
	return
}

@(private = "file")
aof_emit_trimmed :: proc(db: ^Db, argv: [][]u8, t: Aof_Trim, s: sm.Stream, idpos: int, id: sm.ID) {
	tbuf: [sm.ID_TEXT_MAX]u8
	thr: []u8
	if t.approx {
		thr = aof_trim_threshold(s, eq_nocase(argv[t.strat], "minid"), &tbuf)
	}
	b := aof_sink(db.id, len(argv))
	for k in 0 ..< len(argv) {
		switch {
		case k == idpos:
			aof_put_id(b, id)
		case t.approx && k == t.strat + 1:
			aof_put_str(b, "=")
		case t.approx && k == t.thr:
			aof_put_arg(b, thr)
		case:
			aof_put_arg(b, argv[k])
		}
	}
}

aof_tr_xadd :: proc(c: ^Conn, argv: [][]u8, reply: []u8) {
	if len(argv) < 5 || aof_reply_is_null(reply) {
		return
	}
	db := aof_db_of(c)
	s := aof_stream_of(db, argv[1])
	if s == nil {
		return
	}
	t := aof_parse_trim(argv, 2, true)
	if t.next >= len(argv) || (t.strat >= 0 && t.thr >= len(argv)) {
		aof_write_argv(db.id, argv)
		return
	}
	aof_emit_trimmed(db, argv, t, s, t.next, s.top)
}

aof_tr_xtrim :: proc(c: ^Conn, argv: [][]u8, reply: []u8) {
	if len(argv) < 4 || aof_zero_skip(reply) {
		return
	}
	db := aof_db_of(c)
	t := aof_parse_trim(argv, 2, false)
	if !t.approx || t.strat < 0 || t.thr >= len(argv) {
		aof_write_argv(db.id, argv)
		return
	}
	s := aof_stream_of(db, argv[1])
	if s == nil {
		aof_write_argv(db.id, argv)
		return
	}
	aof_emit_trimmed(db, argv, t, s, -1, {})
}

aof_emit_xclaim :: proc(c: ^Conn, key: []u8, group: []u8, consumer: []u8, id: sm.ID, time: i64, count: u64, lastid: sm.ID) {
	db := aof_db_of(c)
	b := aof_sink(db.id, 14)
	aof_put_str(b, "XCLAIM")
	aof_put_arg(b, key)
	aof_put_arg(b, group)
	aof_put_arg(b, consumer)
	aof_put_str(b, "0")
	aof_put_id(b, id)
	aof_put_str(b, "TIME")
	aof_put_int(b, time)
	aof_put_str(b, "RETRYCOUNT")
	aof_put_int(b, i64(count))
	aof_put_str(b, "FORCE")
	aof_put_str(b, "JUSTID")
	aof_put_str(b, "LASTID")
	aof_put_id(b, lastid)
}

aof_emit_setid :: proc(c: ^Conn, key: []u8, group: []u8, cg: ^sm.Group) {
	db := aof_db_of(c)
	b := aof_sink(db.id, 7)
	aof_put_str(b, "XGROUP")
	aof_put_str(b, "SETID")
	aof_put_arg(b, key)
	aof_put_arg(b, group)
	aof_put_id(b, cg.delivered)
	aof_put_str(b, "ENTRIESREAD")
	aof_put_int(b, cg.reads)
}

aof_emit_createconsumer :: proc(c: ^Conn, key: []u8, group: []u8, consumer: []u8) {
	db := aof_db_of(c)
	b := aof_sink(db.id, 5)
	aof_put_str(b, "XGROUP")
	aof_put_str(b, "CREATECONSUMER")
	aof_put_arg(b, key)
	aof_put_arg(b, group)
	aof_put_arg(b, consumer)
}

@(private = "file")
aof_emit_xack :: proc(c: ^Conn, key: []u8, group: []u8, ids: []sm.ID) {
	if len(ids) == 0 {
		return
	}
	db := aof_db_of(c)
	b := aof_sink(db.id, 3 + len(ids))
	aof_put_str(b, "XACK")
	aof_put_arg(b, key)
	aof_put_arg(b, group)
	for id in ids {
		aof_put_id(b, id)
	}
}

aof_reply_stream_ids :: proc(p: ^Aof_Rp, out: ^[dynamic]sm.ID) -> bool {
	n, null, ok := aof_rp_agg(p)
	if !ok {
		return false
	}
	if null {
		return true
	}
	for _ in 0 ..< n {
		if p.i < len(p.b) && (p.b[p.i] == '*' || p.b[p.i] == '~') {
			m, mnull, mok := aof_rp_agg(p)
			if !mok {
				return false
			}
			if mnull || m == 0 {
				continue
			}
			idb, inull, iok := aof_rp_bulk(p)
			if !iok || inull {
				return false
			}
			id, idok := sm.parse_exact_id(idb)
			if !idok {
				return false
			}
			append(out, id)
			for _ in 1 ..< m {
				if !aof_rp_skip(p) {
					return false
				}
			}
			continue
		}
		idb, inull, iok := aof_rp_bulk(p)
		if !iok {
			return false
		}
		if inull {
			continue
		}
		id, idok := sm.parse_exact_id(idb)
		if !idok {
			return false
		}
		append(out, id)
	}
	return true
}

aof_tr_xreadgroup :: proc(c: ^Conn, argv: [][]u8, reply: []u8) {
	x, ok := aof_xrg_parse(argv)
	if !ok {
		return
	}
	db := aof_db_of(c)
	snap := aof_snap.valid && aof_snap_cmd != nil && len(aof.xrg_existed) == x.nkeys
	handled: [64]bool
	if len(reply) > 0 && !aof_reply_is_null(reply) {
		p := Aof_Rp {
			b = reply,
		}
		is_map := reply[0] == '%'
		n, null, aok := aof_rp_agg(&p)
		if aok && !null {
			streams := n / 2 if is_map else n
			for _ in 0 ..< streams {
				if !is_map {
					m, mnull, mok := aof_rp_agg(&p)
					if !mok || mnull || m != 2 {
						break
					}
				}
				key, knull, kok := aof_rp_bulk(&p)
				if !kok || knull {
					break
				}
				clear(&aof_ids)
				if !aof_reply_stream_ids(&p, &aof_ids) {
					break
				}
				k := -1
				for j in 0 ..< x.nkeys {
					if bytes_eq(argv[x.keys_at + j], key) {
						k = j
						break
					}
				}
				if k < 0 {
					continue
				}
				if k < len(handled) {
					handled[k] = true
				}
				idarg := argv[x.keys_at + x.nkeys + k]
				history := !(len(idarg) == 1 && idarg[0] == '>')
				_, cg := aof_group_of(db, key, x.group)
				if cg == nil {
					continue
				}
				claims := 0
				if history || !x.noack {
					for id in aof_ids {
						nack := aof_nack_of(cg, id)
						if nack == nil {
							continue
						}
						last := cg.delivered if history else id
						aof_emit_xclaim(c, key, x.group, x.consumer, id, nack.sent_ms, u64(nack.times), last)
						claims += 1
					}
				}
				if !history && len(aof_ids) > 0 {
					aof_emit_setid(c, key, x.group, cg)
				}
				if claims == 0 && snap && !aof.xrg_existed[k] && aof_consumer_exists(db, key, x.group, x.consumer) {
					aof_emit_createconsumer(c, key, x.group, x.consumer)
				}
			}
		}
		clear(&aof_ids)
	}
	if !snap {
		return
	}
	for k in 0 ..< x.nkeys {
		if k < len(handled) && handled[k] {
			continue
		}
		key := argv[x.keys_at + k]
		if !aof.xrg_existed[k] && aof_consumer_exists(db, key, x.group, x.consumer) {
			aof_emit_createconsumer(c, key, x.group, x.consumer)
		}
	}
}

@(private = "file")
aof_claim_common :: proc(c: ^Conn, argv: [][]u8, claimed: []sm.ID, deleted: []sm.ID) {
	db := aof_db_of(c)
	key, group, consumer := argv[1], argv[2], argv[3]
	_, cg := aof_group_of(db, key, group)
	if cg == nil {
		return
	}
	claims := 0
	for id in claimed {
		nack := aof_nack_of(cg, id)
		if nack == nil {
			continue
		}
		aof_emit_xclaim(c, key, group, consumer, id, nack.sent_ms, u64(nack.times), cg.delivered)
		claims += 1
	}
	snap := aof_snap.valid && aof_snap_cmd != nil
	if claims == 0 && snap {
		if !aof_snap.existed && sm.find_member(cg, consumer) != nil {
			aof_emit_createconsumer(c, key, group, consumer)
		}
		if aof_snap.group_found && sm.compare_id(cg.delivered, aof_snap.last_id) != 0 {
			aof_emit_setid(c, key, group, cg)
		}
	}
	aof_emit_xack(c, key, group, deleted)
}

aof_tr_xclaim :: proc(c: ^Conn, argv: [][]u8, reply: []u8) {
	if len(argv) < 6 {
		return
	}
	clear(&aof_ids)
	if len(reply) > 0 {
		p := Aof_Rp {
			b = reply,
		}
		if !aof_reply_stream_ids(&p, &aof_ids) {
			clear(&aof_ids)
		}
	}
	claimed := len(aof_ids)
	db := aof_db_of(c)
	if aof_snap.valid && aof_snap_cmd != nil {
		_, cg := aof_group_of(db, argv[1], argv[2])
		k := 0
		for i := 5; i < len(argv) && k < len(aof_snap_pel); i += 1 {
			id, idok := sm.parse_exact_id(argv[i])
			if !idok {
				break
			}
			if aof_snap_pel[k] && (cg == nil || aof_nack_of(cg, id) == nil) {
				append(&aof_ids, id)
			}
			k += 1
		}
	}
	aof_claim_common(c, argv, aof_ids[:claimed], aof_ids[claimed:])
	clear(&aof_ids)
}

aof_tr_xautoclaim :: proc(c: ^Conn, argv: [][]u8, reply: []u8) {
	if len(argv) < 6 || len(reply) == 0 {
		return
	}
	p := Aof_Rp {
		b = reply,
	}
	n, null, ok := aof_rp_agg(&p)
	if !ok || null || n < 2 || !aof_rp_skip(&p) {
		return
	}
	clear(&aof_ids)
	if !aof_reply_stream_ids(&p, &aof_ids) {
		clear(&aof_ids)
		return
	}
	claimed := len(aof_ids)
	if n >= 3 && !aof_reply_stream_ids(&p, &aof_ids) {
		resize(&aof_ids, claimed)
	}
	aof_claim_common(c, argv, aof_ids[:claimed], aof_ids[claimed:])
	clear(&aof_ids)
}

aof_tr_restore :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) < 4 {
		return
	}
	db := aof_db_of(c)
	exists, at, _ := aof_key_state(db, argv[1])
	if !exists {
		aof_emit_del(db, argv[1])
		return
	}
	ttl, ok := parse_i64(argv[2])
	if !ok || ttl == 0 || at <= 0 || aof_has_token(argv, 4, "absttl") {
		aof_write_argv(db.id, argv)
		return
	}
	b := aof_sink(db.id, len(argv) + 1)
	for a, k in argv {
		if k == 2 {
			aof_put_int(b, at)
		} else {
			aof_put_arg(b, a)
		}
	}
	aof_put_str(b, "ABSTTL")
}

aof_tr_geoadd :: proc(c: ^Conn, argv: [][]u8, reply: []u8) {
	if aof_reply_failed(reply) {
		return
	}
	aof_propagate_as_is(c, argv)
}

aof_tr_hexpire :: proc(c: ^Conn, name: string, argv: [][]u8, reply: []u8, deadline: i64 = -1) {
	if len(argv) < 6 {
		return
	}
	db := aof_db_of(c)
	fi := -1
	for i in 3 ..< len(argv) {
		if eq_nocase(argv[i], "fields") {
			fi = i
			break
		}
	}
	if fi < 0 || fi + 1 >= len(argv) {
		return
	}
	nf, nok := parse_i64(argv[fi + 1])
	if !nok || nf <= 0 || fi + 2 + int(nf) > len(argv) {
		return
	}
	fields := argv[fi + 2:fi + 2 + int(nf)]
	v, vok := parse_i64(argv[2])
	if !vok {
		return
	}
	at := v
	if deadline >= 0 {
		at = deadline
	} else {
	switch name {
	case "hexpire":
		at = i64(hash_now()) + v * 1000
	case "hpexpire":
		at = i64(hash_now()) + v
	case "hexpireat":
		at = v * 1000
	}
	}
	clear(&aof_flags_scratch)
	ok := true
	if len(reply) > 0 {
		p := Aof_Rp {
			b = reply,
		}
		n, null, aok := aof_rp_agg(&p)
		if !aok || null || n != len(fields) {
			ok = false
		} else {
			for _ in 0 ..< n {
				code, cok := aof_rp_int(&p)
				if !cok {
					ok = false
					break
				}
				append(&aof_flags_scratch, code)
			}
		}
	} else {
		ok = false
	}
	if !ok {
		b := aof_sink(db.id, len(argv))
		for a, k in argv {
			switch k {
			case 0:
				aof_put_str(b, "HPEXPIREAT")
			case 2:
				aof_put_int(b, at)
			case:
				aof_put_arg(b, a)
			}
		}
		clear(&aof_flags_scratch)
		return
	}
	set, gone := 0, 0
	for code in aof_flags_scratch {
		switch code {
		case 1:
			set += 1
		case 2:
			gone += 1
		}
	}
	if set == len(fields) {
		b := aof_sink(db.id, len(argv))
		for a, k in argv {
			switch k {
			case 0:
				aof_put_str(b, "HPEXPIREAT")
			case 2:
				aof_put_int(b, at)
			case:
				aof_put_arg(b, a)
			}
		}
	} else if set > 0 {
		b := aof_sink(db.id, 5 + set)
		aof_put_str(b, "HPEXPIREAT")
		aof_put_arg(b, argv[1])
		aof_put_int(b, at)
		aof_put_str(b, "FIELDS")
		aof_put_int(b, i64(set))
		for f, k in fields {
			if aof_flags_scratch[k] == 1 {
				aof_put_arg(b, f)
			}
		}
	}
	if gone > 0 {
		for f, k in fields {
			if aof_flags_scratch[k] == 2 {
				b := aof_sink(db.id, 3)
				aof_put_str(b, "HDEL")
				aof_put_arg(b, argv[1])
				aof_put_arg(b, f)
			}
		}
	}
	clear(&aof_flags_scratch)
}

@(private = "file")
aof_any_code_one :: proc(reply: []u8) -> bool {
	if len(reply) == 0 {
		return true
	}
	p := Aof_Rp {
		b = reply,
	}
	n, null, ok := aof_rp_agg(&p)
	if !ok || null {
		return false
	}
	for _ in 0 ..< n {
		v, vok := aof_rp_int(&p)
		if !vok {
			return true
		}
		if v == 1 {
			return true
		}
	}
	return false
}

@(private = "file")
aof_scan_expired :: proc(c: ^Conn) {
	if !aof_snap.valid || aof_snap_cmd == nil || srv.stat_expired <= aof_expired_before {
		return
	}
	db := aof_db_of(c)
	if db == nil {
		return
	}
	start := 0
	for end in scan_expired_ends {
		if end < start || end > len(scan_expired) {
			break
		}
		key := scan_expired[start:end]
		start = end
		if len(key) == 0 {
			continue
		}
		exists, expired := db_key_state(db, key)
		if !exists || expired {
			aof_emit_del(db, key)
		}
	}
}

aof_translate :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8, reply: []u8) {
	db := aof_db_of(c)
	if db == nil {
		return
	}
	kind := aof_kind_of(cmd)
	#partial switch kind {
	case .Set:
		aof_tr_set(c, argv, reply)
	case .Setex:
		aof_tr_setex(c, argv)
	case .Getex:
		aof_tr_getex(c, argv, reply)
	case .Getdel:
		if len(argv) >= 2 && len(reply) > 0 && !aof_reply_is_null(reply) {
			aof_emit_del(db, argv[1])
		}
	case .Expire:
		aof_tr_expire(c, argv, reply)
	case .Incrbyfloat:
		aof_tr_incrbyfloat(c, argv)
	case .Hincrbyfloat:
		aof_tr_hincrbyfloat(c, argv, reply)
	case .Spop:
		aof_tr_spop(c, argv, reply)
	case .Lmpop:
		aof_tr_mpop(c, argv, reply, false, false)
	case .Zmpop:
		aof_tr_mpop(c, argv, reply, false, true)
	case .Blmpop:
		aof_tr_mpop(c, argv, reply, true, false)
	case .Bzmpop:
		aof_tr_mpop(c, argv, reply, true, true)
	case .Blpop:
		aof_tr_bpop(c, reply, "LPOP")
	case .Brpop:
		aof_tr_bpop(c, reply, "RPOP")
	case .Bzpopmin:
		aof_tr_bpop(c, reply, "ZPOPMIN")
	case .Bzpopmax:
		aof_tr_bpop(c, reply, "ZPOPMAX")
	case .Blmove:
		aof_tr_blmove(c, argv, reply, false)
	case .Brpoplpush:
		aof_tr_blmove(c, argv, reply, true)
	case .Xadd:
		aof_tr_xadd(c, argv, reply)
	case .Xtrim:
		aof_tr_xtrim(c, argv, reply)
	case .Xreadgroup:
		aof_tr_xreadgroup(c, argv, reply)
	case .Xclaim:
		aof_tr_xclaim(c, argv, reply)
	case .Xautoclaim:
		aof_tr_xautoclaim(c, argv, reply)
	case .Xgroup:
		if len(argv) >= 2 && eq_nocase(argv[1], "help") {
			return
		}
		if len(argv) >= 2 && (eq_nocase(argv[1], "destroy") || eq_nocase(argv[1], "createconsumer")) && aof_zero_skip(reply) {
			return
		}
		aof_write_argv(db.id, argv)
	case .Restore:
		aof_tr_restore(c, argv)
	case .Hexpire:
		aof_tr_hexpire(c, "hexpire", argv, reply)
	case .Hpexpire:
		aof_tr_hexpire(c, "hpexpire", argv, reply)
	case .Hexpireat:
		aof_tr_hexpire(c, "hexpireat", argv, reply)
	case .Hpexpireat:
		aof_tr_hexpire(c, "hpexpireat", argv, reply)
	case .Hpersist:
		if aof_any_code_one(reply) {
			aof_write_argv(db.id, argv)
		}
	case .Sort:
		if aof_has_token(argv, 2, "store") {
			aof_write_argv(db.id, argv)
		}
	case .Store_Opt:
		if aof_has_token(argv, 2, "store") || aof_has_token(argv, 2, "storedist") {
			aof_write_argv(db.id, argv)
		}
	case .Bitfield:
		if aof_has_token(argv, 2, "set") || aof_has_token(argv, 2, "incrby") {
			aof_write_argv(db.id, argv)
		}
	case .Migrate:
	case .Linsert:
		if v, ok := aof_reply_int(reply); ok && v <= 0 {
			return
		}
		aof_write_argv(db.id, argv)
	case .Zero_Skip, .Hsetnx:
		if aof_zero_skip(reply) {
			return
		}
		aof_write_argv(db.id, argv)
	case .Pop:
		if aof_reply_is_null(reply) || aof_reply_empty_agg(reply) {
			return
		}
		aof_write_argv(db.id, argv)
	case:
		aof_write_argv(db.id, argv)
	}
}

aof_after_command :: proc(c: ^Conn, cmd: ^Command, flags: Persist_Cmd_Flags, argv: [][]u8, pending: int) {
	if !aof.feed {
		if !aof.in_tx {
			if aof.in_cmd || aof.stage_count > 0 {
				aof_stage_commit(aof.stage_count > 1)
			}
			aof.in_cmd = false
		}
		aof_explicit = false
		aof_snap = {}
		aof_snap_cmd = nil
		return
	}
	kind := aof_kind_of(cmd)
	if kind == .Exec && aof.in_tx {
		aof_tx_end()
	}
	aof_after_inner(c, cmd, kind, flags, argv, pending)
	if !aof.in_tx {
		if aof.in_cmd || aof.stage_count > 0 {
			aof_stage_commit(aof.stage_count > 1)
		}
		aof.in_cmd = false
	}
	aof_explicit = false
	aof_snap = {}
	aof_snap_cmd = nil
}

@(private = "file")
aof_after_inner :: proc(c: ^Conn, cmd: ^Command, kind: Aof_Kind, flags: Persist_Cmd_Flags, argv: [][]u8, pending: int) {
	if cmd == nil || len(argv) == 0 || lua_is_eval(cmd) || (cmd.handler == cmd_function && !is_write_command(cmd.name, argv)) || aof_is_queueing(c, kind) {
		return
	}
	if aof_snap_cmd != nil && aof_snap_cmd != cmd {
		aof_snap = {}
		aof_snap_cmd = nil
	}
	reply := aof_reply_view(c, pending)
	if kind == .Scan || kind == .Randomkey {
		aof_scan_expired(c)
		return
	}
	if .Write not_in flags || aof_explicit || aof_reply_failed(reply) {
		return
	}
	if kind == .Xreadgroup {
		aof_tr_xreadgroup(c, argv, reply)
		return
	}
	if len(reply) == 0 && c != nil && (c.blocked == .List || c.blocked == .Zset || c.blocked == .Stream) {
		return
	}
	aof_translate(c, cmd, argv, reply)
}

aof_w_header :: proc(w: ^rdb.Writer, n: int) {
	tmp: [24]u8
	tmp[0] = '*'
	k := 1 + format_i64(&tmp[1], i64(n))
	tmp[k] = '\r'
	tmp[k + 1] = '\n'
	rdb.put_raw(w, tmp[:k + 2])
}

aof_w_arg :: proc(w: ^rdb.Writer, a: []u8) {
	tmp: [24]u8
	tmp[0] = '$'
	k := 1 + format_i64(&tmp[1], i64(len(a)))
	tmp[k] = '\r'
	tmp[k + 1] = '\n'
	rdb.put_raw(w, tmp[:k + 2])
	rdb.put_raw(w, a)
	rdb.put_raw(w, transmute([]u8)string("\r\n"))
}

aof_w_str :: proc(w: ^rdb.Writer, s: string) {
	aof_w_arg(w, transmute([]u8)s)
}

aof_w_int :: proc(w: ^rdb.Writer, v: i64) {
	tmp: [24]u8
	n := format_i64(&tmp[0], v)
	aof_w_arg(w, tmp[:n])
}

aof_w_id :: proc(w: ^rdb.Writer, id: sm.ID) {
	tmp: [sm.ID_TEXT_MAX]u8
	aof_w_arg(w, sm.format_id(&tmp, id))
}

aof_format_score :: proc(dst: ^[64]u8, v: f64) -> []u8 {
	n := 0
	put :: proc(dst: ^[64]u8, n: ^int, c: u8) {
		if n^ < len(dst) {
			dst[n^] = c
			n^ += 1
		}
	}
	if v != v {
		copy(dst[:], "nan")
		return dst[:3]
	}
	if v > max(f64) {
		copy(dst[:], "inf")
		return dst[:3]
	}
	if v < -max(f64) {
		copy(dst[:], "-inf")
		return dst[:4]
	}
	if v == 0 {
		if transmute(u64)v >> 63 != 0 {
			copy(dst[:], "-0")
			return dst[:2]
		}
		dst[0] = '0'
		return dst[:1]
	}
	tmp: [64]u8
	s := strconv.write_float(tmp[:], v, 'e', -1, 64)
	neg := false
	digits: [32]u8
	k := 0
	exp := 0
	exp_neg := false
	i := 0
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		neg = s[i] == '-'
		i += 1
	}
	for i < len(s) && s[i] != 'e' && s[i] != 'E' {
		if s[i] >= '0' && s[i] <= '9' && k < len(digits) {
			digits[k] = s[i]
			k += 1
		}
		i += 1
	}
	if i < len(s) {
		i += 1
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			exp_neg = s[i] == '-'
			i += 1
		}
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			exp = exp * 10 + int(s[i] - '0')
			i += 1
		}
	}
	if exp_neg {
		exp = -exp
	}
	for k > 1 && digits[k - 1] == '0' {
		k -= 1
	}
	point := exp + 1
	if neg {
		put(dst, &n, '-')
	}
	switch {
	case k <= point && point <= 21:
		for j in 0 ..< k {
			put(dst, &n, digits[j])
		}
		for _ in k ..< point {
			put(dst, &n, '0')
		}
	case 0 < point && point <= 21:
		for j in 0 ..< point {
			put(dst, &n, digits[j])
		}
		put(dst, &n, '.')
		for j in point ..< k {
			put(dst, &n, digits[j])
		}
	case -6 < point && point <= 0:
		put(dst, &n, '0')
		put(dst, &n, '.')
		for _ in 0 ..< -point {
			put(dst, &n, '0')
		}
		for j in 0 ..< k {
			put(dst, &n, digits[j])
		}
	case:
		put(dst, &n, digits[0])
		if k > 1 {
			put(dst, &n, '.')
			for j in 1 ..< k {
				put(dst, &n, digits[j])
			}
		}
		put(dst, &n, 'e')
		e := point - 1
		put(dst, &n, '-' if e < 0 else '+')
		ebuf: [8]u8
		el := format_i64(&ebuf[0], i64(abs(e)))
		for j in 0 ..< el {
			put(dst, &n, ebuf[j])
		}
	}
	return dst[:n]
}

@(private = "file")
aof_rewrite_hash :: proc(w: ^rdb.Writer, key: []u8, h: ht.Hash, now: u64) {
	live := ht.length_live(h, now)
	if live <= 0 {
		return
	}
	has_ttl := false
	probe := ht.iterator_live(h, now)
	for ht.next(&probe) {
		e := ht.current_expire(&probe)
		if e != 0 && e != ht.DEADLINE_UNSET {
			has_ttl = true
			break
		}
	}
	fbuf, vbuf: [24]u8
	it := ht.iterator_live(h, now)
	if !has_ttl {
		remaining := live
		for remaining > 0 {
			batch := min(remaining, AOF_ITEMS_PER_EMITTED_COMMAND)
			aof_w_header(w, 2 + 2 * batch)
			aof_w_str(w, "HMSET")
			aof_w_arg(w, key)
			for _ in 0 ..< batch {
				if !ht.next(&it) {
					aof_w_str(w, "")
					aof_w_str(w, "")
					continue
				}
				aof_w_arg(w, ht.value_bytes(ht.current_field(&it), cast(^[21]u8)&fbuf))
				aof_w_arg(w, ht.value_bytes(ht.current_value(&it), cast(^[21]u8)&vbuf))
			}
			remaining -= batch
		}
		return
	}
	for ht.next(&it) {
		field := ht.value_bytes(ht.current_field(&it), cast(^[21]u8)&fbuf)
		aof_w_header(w, 4)
		aof_w_str(w, "HMSET")
		aof_w_arg(w, key)
		aof_w_arg(w, field)
		aof_w_arg(w, ht.value_bytes(ht.current_value(&it), cast(^[21]u8)&vbuf))
		e := ht.current_expire(&it)
		if e != 0 && e != ht.DEADLINE_UNSET {
			aof_w_header(w, 6)
			aof_w_str(w, "HPEXPIREAT")
			aof_w_arg(w, key)
			aof_w_int(w, i64(e))
			aof_w_str(w, "FIELDS")
			aof_w_str(w, "1")
			aof_w_arg(w, field)
		}
	}
}

aof_rewrite_stream :: proc(w: ^rdb.Writer, key: []u8, s: sm.Stream) {
	if s.live > 0 {
		si: sm.Cursor
		sm.cursor_open(&si, s, nil, nil, false)
		for id, numfields in sm.cursor_next(&si) {
			aof_w_header(w, 3 + 2 * int(numfields))
			aof_w_str(w, "XADD")
			aof_w_arg(w, key)
			aof_w_id(w, id)
			for _ in 0 ..< numfields {
				field, value := sm.cursor_field(&si)
				aof_w_arg(w, field)
				aof_w_arg(w, value)
			}
		}
		sm.cursor_close(&si)
	} else {
		first := s.top
		if first.ms == 0 && first.seq == 0 {
			first.seq = 1
		}
		aof_w_header(w, 7)
		aof_w_str(w, "XADD")
		aof_w_arg(w, key)
		aof_w_str(w, "MAXLEN")
		aof_w_str(w, "0")
		aof_w_id(w, first)
		aof_w_str(w, "x")
		aof_w_str(w, "y")
	}
	aof_w_header(w, 7)
	aof_w_str(w, "XSETID")
	aof_w_arg(w, key)
	aof_w_id(w, s.top)
	aof_w_str(w, "ENTRIESADDED")
	aof_w_int(w, i64(s.added))
	aof_w_str(w, "MAXDELETEDID")
	aof_w_id(w, s.tomb)
	if s.groups == nil {
		return
	}
	gi: rx.Iterator
	rx.start(&gi, s.groups)
	rx.seek(&gi, "^")
	for rx.next(&gi) {
		group := rx.key(&gi)
		cg := (^sm.Group)(gi.data)
		aof_w_header(w, 7)
		aof_w_str(w, "XGROUP")
		aof_w_str(w, "CREATE")
		aof_w_arg(w, key)
		aof_w_arg(w, group)
		aof_w_id(w, cg.delivered)
		aof_w_str(w, "ENTRIESREAD")
		aof_w_int(w, cg.reads)
		if cg.pending != nil {
			pi: rx.Iterator
			rx.start(&pi, cg.pending)
			rx.seek(&pi, "^")
			for rx.next(&pi) {
				nack := (^sm.Delivery)(pi.data)
				if nack == nil || nack.owner == nil {
					continue
				}
				aof_w_header(w, 12)
				aof_w_str(w, "XCLAIM")
				aof_w_arg(w, key)
				aof_w_arg(w, group)
				aof_w_arg(w, nack.owner.name)
				aof_w_str(w, "0")
				aof_w_id(w, sm.decode_id(rx.key(&pi)))
				aof_w_str(w, "TIME")
				aof_w_int(w, nack.sent_ms)
				aof_w_str(w, "RETRYCOUNT")
				aof_w_int(w, i64(nack.times))
				aof_w_str(w, "JUSTID")
				aof_w_str(w, "FORCE")
			}
			rx.stop(&pi)
		}
		if cg.members != nil {
			ci: rx.Iterator
			rx.start(&ci, cg.members)
			rx.seek(&ci, "^")
			for rx.next(&ci) {
				consumer := (^sm.Member)(ci.data)
				if consumer == nil || (consumer.owned != nil && consumer.owned.stored > 0) {
					continue
				}
				aof_w_header(w, 5)
				aof_w_str(w, "XGROUP")
				aof_w_str(w, "CREATECONSUMER")
				aof_w_arg(w, key)
				aof_w_arg(w, group)
				aof_w_arg(w, consumer.name)
			}
			rx.stop(&ci)
		}
	}
	rx.stop(&gi)
}

aof_rewrite_value :: proc(w: ^rdb.Writer, key: []u8, v: Slot_Value) {
	if v.obj == nil || v.type == .String {
		aof_w_header(w, 3)
		aof_w_str(w, "SET")
		aof_w_arg(w, key)
		aof_w_arg(w, v.str)
		return
	}
	buf: [24]u8
	switch v.type {
	case .String:
	case .List:
		l := cast(lt.List)v.obj
		remaining := lt.length(l)
		it := lt.iterator(l, 0, .Tail)
		entry: lt.List_Entry
		for remaining > 0 {
			batch := min(remaining, AOF_ITEMS_PER_EMITTED_COMMAND)
			aof_w_header(w, 2 + batch)
			aof_w_str(w, "RPUSH")
			aof_w_arg(w, key)
			for _ in 0 ..< batch {
				if !lt.iter_next(&it, &entry) {
					aof_w_str(w, "")
					continue
				}
				aof_w_arg(w, lt.value_bytes(lt.entry_value(&it, &entry), cast(^[21]u8)&buf))
			}
			remaining -= batch
		}
	case .Set:
		s := cast(st.Set)v.obj
		remaining := st.size(s)
		it := st.iterator(s)
		for remaining > 0 {
			batch := min(remaining, AOF_ITEMS_PER_EMITTED_COMMAND)
			aof_w_header(w, 2 + batch)
			aof_w_str(w, "SADD")
			aof_w_arg(w, key)
			for _ in 0 ..< batch {
				member, more := st.next(&it)
				if !more {
					aof_w_str(w, "")
					continue
				}
				aof_w_arg(w, st.value_bytes(member, cast(^[21]u8)&buf))
			}
			remaining -= batch
		}
	case .Zset:
		z := cast(zt.Zset)v.obj
		remaining := zt.length(z)
		it := zt.iter_make(z, false)
		item: zt.Item
		sbuf: [64]u8
		for remaining > 0 {
			batch := min(remaining, AOF_ITEMS_PER_EMITTED_COMMAND)
			aof_w_header(w, 2 + 2 * batch)
			aof_w_str(w, "ZADD")
			aof_w_arg(w, key)
			for _ in 0 ..< batch {
				if !zt.iter_next(&it, &item) {
					aof_w_str(w, "0")
					aof_w_str(w, "")
					continue
				}
				aof_w_arg(w, aof_format_score(&sbuf, item.score))
				aof_w_arg(w, zt.item_bytes(&item, cast(^[21]u8)&buf))
			}
			remaining -= batch
		}
	case .Hash:
		aof_rewrite_hash(w, key, cast(ht.Hash)v.obj, u64(max(aof_now_ms(), 0)))
	case .Stream:
		aof_rewrite_stream(w, key, cast(sm.Stream)v.obj)
	case .Vectorset:
		vset_aof_rewrite(w, key, cast(vt.Vset)v.obj)
	}
}

@(private = "file")
aof_child_tick :: proc(processed: i64) {
	if !pst.in_child {
		return
	}
	p := pst.progress
	if p != nil {
		intrinsics.volatile_store(&p.processed, processed)
		persist_pace_cow(p, processed)
	}
	if pst.key_save_delay != 0 {
		persist_debug_delay(pst.key_save_delay)
	}
}

aof_rewrite_commands :: proc(w: ^rdb.Writer) -> bool {
	for library := lua_libraries; library != nil; library = library.next {
		aof_w_header(w, 3)
		aof_w_str(w, "FUNCTION")
		aof_w_str(w, "LOAD")
		aof_w_arg(w, library.code)
	}
	now := aof_now_ms()
	if aof.timestamps {
		tmp: [40]u8
		head := "#TS:"
		copy(tmp[:], head)
		k := len(head) + format_i64(&tmp[len(head)], now / 1000)
		tmp[k] = '\r'
		tmp[k + 1] = '\n'
		rdb.put_raw(w, tmp[:k + 2])
	}
	processed: i64 = 0
	for &db, id in dbs {
		if db_size_of(&db) == 0 {
			continue
		}
		selected := false
		banks := 2 if db.rehash_idx >= 0 else 1
		for bank in 0 ..< banks {
			t := &db.t[bank]
			if t.ctrl == nil || t.cap <= 0 || t.live <= 0 {
				continue
			}
			for g: u64 = 0; g < t.groups; g += 1 {
				bits := group_full(group_load(t.ctrl, g))
				for bits != 0 {
					i := int(g) * GROUP_SLOTS + int(intrinsics.count_trailing_zeros(bits))
					bits &= bits - 1
					expire := slot_deadline(&db, t, i)
					if !selected {
						aof_w_header(w, 2)
						aof_w_str(w, "SELECT")
						aof_w_int(w, i64(id))
						selected = true
					}
					kp := &t.slots[i].key
					key := key_bytes(kp, &db.slab)
					aof_rewrite_value(w, key, persist_slot_value(&db, kp, &t.slots[i].val))
					if expire != 0 {
						aof_w_header(w, 3)
						aof_w_str(w, "PEXPIREAT")
						aof_w_arg(w, key)
						aof_w_int(w, expire)
					}
					processed += 1
					aof_child_tick(processed)
					if w.failed {
						return false
					}
				}
			}
		}
	}
	return rdb.writer_flush(w)
}

aof_write_base_to :: proc(path: cstring, preamble: bool) -> bool {
	fd, err := linux.open(path, {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, aof_mode_file())
	if err != .NONE {
		plog(LOG_WARNING, "Opening the temp file for the AOF rewrite failed: ", errno_text(err))
		return false
	}
	w: rdb.Writer
	if preamble {
		rdb.writer_init_file(&w, fd, pst.compression, pst.checksum)
	} else {
		rdb.writer_init_file(&w, fd, false, false)
	}
	if aof.incremental_fsync {
		w.sync_every = AOF_AUTOSYNC_BYTES
	}
	good := persist_write_rdb(&w, true) if preamble else aof_rewrite_commands(&w)
	good = rdb.writer_flush(&w) && good
	werr := w.errno
	rdb.writer_destroy(&w)
	if good {
		if serr := linux.fsync(fd); serr != .NONE {
			good = false
			werr = serr
		}
	}
	linux.close(fd)
	if !good {
		plog(LOG_WARNING, "Write error writing append only file on disk: ", errno_text(werr))
		linux.unlink(path)
	}
	return good
}

aof_open_incr :: proc(name: string, truncate: bool) -> (linux.Fd, linux.Errno) {
	buf: [PERSIST_PATH_MAX]u8
	flags := linux.Open_Flags{.WRONLY, .CREAT, .APPEND, .CLOEXEC}
	if truncate {
		flags += {.TRUNC}
	}
	return linux.open(aof_cpath(name, buf[:]), flags, aof_mode_file())
}

aof_switch_fd :: proc(fd: linux.Fd) {
	old := aof.fd
	aof.fd = fd
	aof.selected_db = -1
	aof.last_ts = 0
	aof_incr_bytes = 0
	if fd >= 0 {
		sb: linux.Stat
		if linux.fstat(fd, &sb) == .NONE {
			aof_incr_bytes = i64(sb.size)
		}
	}
	if old >= 0 && old != fd {
		if aof.fsync != .No {
			aof_bio_fsync(old)
		}
		aof_bio_close(old)
	}
}

@(private = "file")
aof_close_fd :: proc() {
	if aof.fd < 0 {
		return
	}
	aof_bio_close(aof.fd)
	aof.fd = -1
	aof_incr_bytes = 0
}

aof_open_new_incr_for_rewrite :: proc() -> bool {
	name: [dynamic]u8
	defer delete(name)
	if aof.state == .Awaiting_Base {
		aof_temp_incr_name(&name)
		fd, err := aof_open_incr(string(name[:]), true)
		if err != .NONE {
			plog(LOG_WARNING, "Can't open the append-only file ", string(name[:]), ": ", errno_text(err))
			return false
		}
		clear(&aof.buf)
		aof_switch_fd(fd)
		return true
	}
	if aof.state != .Enabled {
		return true
	}
	aof_flush(true)
	if len(aof.buf) > 0 {
		plog(LOG_WARNING, "Can't start the AOF rewrite while the AOF buffer can't be written: ", errno_text(aof.write_errno))
		return false
	}
	seq := aof.manifest.incr_seq + 1
	aof_name(&name, seq, "incr.aof")
	fd, err := aof_open_incr(string(name[:]), true)
	if err != .NONE {
		plog(LOG_WARNING, "Can't open the append-only file ", string(name[:]), ": ", errno_text(err))
		return false
	}
	f := Aof_File {
		seq  = seq,
		kind = .Incr,
	}
	append(&f.name, ..name[:])
	append(&aof.manifest.incr, f)
	prev_seq := aof.manifest.incr_seq
	aof.manifest.incr_seq = seq
	if !aof_persist_manifest(&aof.manifest) {
		last := pop(&aof.manifest.incr)
		aof_file_free(&last)
		aof.manifest.incr_seq = prev_seq
		linux.close(fd)
		buf: [PERSIST_PATH_MAX]u8
		linux.unlink(aof_cpath(string(name[:]), buf[:]))
		return false
	}
	aof_switch_fd(fd)
	aof_rewrite_incr_seq = seq
	return true
}

aof_remove_temp_base :: proc(pid: linux.Pid) {
	tbuf: [64]u8
	name := aof_temp_base_name(tbuf[:], pid, true)
	cbuf: [80]u8
	linux.unlink(persist_cstr(name, cbuf[:]))
}

aof_remove_temp_incr :: proc() {
	name: [dynamic]u8
	defer delete(name)
	aof_temp_incr_name(&name)
	buf: [PERSIST_PATH_MAX]u8
	if linux.unlink(aof_cpath(string(name[:]), buf[:])) == .NONE {
		plog(LOG_NOTICE, "Removing the temp incr aof file ", string(name[:]))
	}
}

@(private = "file")
aof_in_exec :: proc() -> bool {
	return aof.in_tx || tx_exec_conn != nil
}

aof_rewrite_background :: proc() -> bool {
	keyspace_fence()
	if access_writes_refused() {
		plog(LOG_WARNING, "AOF rewrite refused: ", LABEL_PERSISTENCE_ON)
		return false
	}
	if pst.child_pid > 0 || pst.loading || aof.loading {
		return false
	}
	if !aof_make_dir() {
		aof.last_rewrite_err = true
		return false
	}
	if !aof_open_new_incr_for_rewrite() {
		aof.last_rewrite_err = true
		return false
	}
	aof.rewrite_preamble = aof.preamble
	aof.rewrite_state = aof.state
	persist_progress_prepare()
	keyspace_before_fork()
	compute_before_fork()
	pid, ferr := runtime_fork()
	if ferr != .NONE {
		plog(LOG_WARNING, "Can't rewrite append only file in background: fork: ", errno_text(ferr))
		aof.last_rewrite_err = true
		aof_feed_refresh()
		return false
	}
	if pid == 0 {
		persist_child_setup()
		runtime_tuning_enter(.Aof_Rewrite)
		tbuf: [64]u8
		tmp := aof_temp_base_name(tbuf[:], linux.getpid(), true)
		cbuf: [80]u8
		good := aof_write_base_to(persist_cstr(tmp, cbuf[:]), aof.rewrite_preamble)
		if good {
			plog(LOG_NOTICE, "Successfully created the temporary AOF base file ", tmp)
			persist_sample_cow()
			persist_log_cow("Fork CoW for AOF rewrite: current ")
		}
		linux.exit_group(0 if good else 1)
	}
	pst.latest_fork_usec = runtime_fork_last_usec
	pst.total_forks += 1
	pst.child_pid = pid
	pst.child_aof = true
	aof.rewrite_scheduled = false
	aof.rewrite_start = persist_unix_now()
	aof.stat_rewrites += 1
	tmp: [24]u8
	n := format_i64(&tmp[0], i64(pid))
	plog(LOG_NOTICE, "Background append only file rewriting started by pid ", string(tmp[:n]))
	aof_feed_refresh()
	return true
}

aof_delete_history :: proc() {
	if aof.disable_auto_gc || len(aof.manifest.history) == 0 {
		return
	}
	names: [dynamic]Aof_File
	defer {
		for &f in names {
			aof_file_free(&f)
		}
		delete(names)
	}
	for f in aof.manifest.history {
		append(&names, f)
	}
	clear(&aof.manifest.history)
	if !aof_persist_manifest(&aof.manifest) {
		for f in names {
			append(&aof.manifest.history, f)
		}
		clear(&names)
		return
	}
	for f in names {
		plog(LOG_NOTICE, "Removing the history file ", string(f.name[:]), " in the background")
		aof_bio_unlink(string(f.name[:]))
	}
}

aof_apply_gc :: proc() -> string {
	aof_delete_history()
	return ""
}

@(private = "file")
aof_recompute_sizes :: proc() {
	total: i64 = 0
	if aof.manifest.has_base {
		total += aof_file_size(string(aof.manifest.base.name[:]))
	}
	for f in aof.manifest.incr {
		total += aof_file_size(string(f.name[:]))
	}
	aof.current_size = total
	aof.base_size = total
	aof.fsynced_size = 0
	aof.last_fsync_ms = 0
	aof_sync_gen += 1
	if aof.fd >= 0 {
		sb: linux.Stat
		if linux.fstat(aof.fd, &sb) == .NONE {
			aof_incr_bytes = i64(sb.size)
		}
	}
}

@(private = "file")
aof_retire :: proc(m: ^Aof_Manifest, f: Aof_File) {
	gone := f
	gone.kind = .History
	inject_at(&m.history, 0, gone)
}

@(private = "file")
aof_retire_incr_below :: proc(m: ^Aof_Manifest, limit: i64) {
	kept := 0
	for f in m.incr {
		if f.seq < limit {
			aof_retire(m, f)
			continue
		}
		m.incr[kept] = f
		kept += 1
	}
	resize(&m.incr, kept)
}

@(private = "file")
aof_rename_temp :: proc(what: string, from_name: string, from: cstring, to_name: string, to: cstring) -> bool {
	if err := linux.rename(from, to); err != .NONE {
		plog(LOG_WARNING, "Error trying to rename the temporary AOF ", what, " file ", from_name, " into ", to_name, ": ", errno_text(err))
		return false
	}
	plog(LOG_NOTICE, "Successfully renamed the temporary AOF ", what, " file ", from_name, " into ", to_name)
	return true
}

@(private = "file")
aof_adopt_seed_incr :: proc(m: ^Aof_Manifest, incr_name: ^[dynamic]u8) -> bool {
	seq := m.incr_seq + 1
	aof_name(incr_name, seq, "incr.aof")
	temp: [dynamic]u8
	defer delete(temp)
	aof_temp_incr_name(&temp)
	from: [PERSIST_PATH_MAX]u8
	to: [PERSIST_PATH_MAX]u8
	if !aof_rename_temp("incr", string(temp[:]), aof_cpath(string(temp[:]), from[:]), string(incr_name[:]), aof_cpath(string(incr_name[:]), to[:])) {
		return false
	}
	aof_retire_incr_below(m, max(i64))
	fresh := Aof_File {
		seq  = seq,
		kind = .Incr,
	}
	append(&fresh.name, ..incr_name[:])
	append(&m.incr, fresh)
	m.incr_seq = seq
	return true
}

@(private = "file")
aof_return_seed_incr :: proc(incr_name: string) {
	temp: [dynamic]u8
	defer delete(temp)
	aof_temp_incr_name(&temp)
	from: [PERSIST_PATH_MAX]u8
	to: [PERSIST_PATH_MAX]u8
	linux.rename(aof_cpath(incr_name, from[:]), aof_cpath(string(temp[:]), to[:]))
}

@(private = "file")
aof_adopt_manifest :: proc(m: Aof_Manifest) {
	aof_manifest_set(m)
	aof_recompute_sizes()
	if aof.state == .Awaiting_Base {
		aof.state = .Enabled
	}
	aof_delete_history()
}

@(private = "file")
aof_install_rewrite :: proc(pid: linux.Pid) -> bool {
	next := aof_manifest_dup(&aof.manifest)
	seq := next.base_seq + 1
	base_name: [dynamic]u8
	defer delete(base_name)
	aof_name(&base_name, seq, "base.rdb" if aof.rewrite_preamble else "base.aof")
	nbuf: [64]u8
	temp := aof_temp_base_name(nbuf[:], pid, true)
	tbuf: [80]u8
	bbuf: [PERSIST_PATH_MAX]u8
	temp_path := persist_cstr(temp, tbuf[:])
	base_path := aof_cpath(string(base_name[:]), bbuf[:])
	if !aof_rename_temp("base", temp, temp_path, string(base_name[:]), base_path) {
		aof_manifest_free(&next)
		linux.unlink(temp_path)
		return false
	}
	if next.has_base {
		aof_retire(&next, next.base)
	}
	next.base = Aof_File {
		seq  = seq,
		kind = .Base,
	}
	append(&next.base.name, ..base_name[:])
	next.has_base = true
	next.base_seq = seq
	incr_name: [dynamic]u8
	defer delete(incr_name)
	settled := true
	moved := false
	switch aof.state {
	case .Disabled:
		aof_retire_incr_below(&next, max(i64))
	case .Enabled:
		aof_retire_incr_below(&next, aof_rewrite_incr_seq)
	case .Awaiting_Base:
		settled = aof_adopt_seed_incr(&next, &incr_name)
		moved = settled
	}
	if settled && aof_persist_manifest(&next) {
		aof_adopt_manifest(next)
		return true
	}
	linux.unlink(base_path)
	if moved {
		aof_return_seed_incr(string(incr_name[:]))
	}
	aof_manifest_free(&next)
	return false
}

@(private = "file")
aof_abandon_seed :: proc() {
	clear(&aof.buf)
	aof_close_fd()
	aof_remove_temp_incr()
}

@(private = "file")
aof_arm_retry_limit :: proc() {
	if aof.failures < 3 {
		return
	}
	delay: i64 = 60
	for left := aof.failures - 3; left > 0 && delay < 3600; left -= 1 {
		delay *= 2
	}
	aof_retry_reported = false
	aof_retry_at = persist_unix_now() + min(delay, 3600)
}

aof_rewrite_failed :: proc() {
	aof.failures += 1
	aof.last_rewrite_err = true
	if aof.state == .Awaiting_Base {
		aof.rewrite_scheduled = true
		aof_abandon_seed()
	}
	aof_arm_retry_limit()
}

@(private = "file")
aof_forget_child :: proc() {
	pst.child_aof = false
	pst.child_pid = 0
}

@(private = "file")
aof_rewrite_succeeded :: proc(pid: linux.Pid) {
	plog(LOG_NOTICE, "Background AOF rewrite terminated with success")
	if !aof_install_rewrite(pid) {
		aof_rewrite_failed()
		return
	}
	aof.failures = 0
	aof.last_rewrite_err = false
	aof_retry_at = 0
	aof_retry_reported = false
	plog(LOG_NOTICE, "Background AOF rewrite finished successfully")
}

@(private = "file")
aof_rewrite_abandoned :: proc(pid: linux.Pid, killed_by_us: bool) {
	if pid > 0 {
		aof_remove_temp_base(pid)
	}
	if !killed_by_us {
		aof_rewrite_failed()
	} else if aof.state == .Awaiting_Base {
		aof.rewrite_scheduled = true
	}
}

@(private = "file")
aof_close_rewrite_window :: proc() {
	if started := aof.rewrite_start; started >= 0 {
		aof.rewrite_last = persist_unix_now() - started
	}
	aof.rewrite_start = -1
}

aof_rewrite_done :: proc(exitcode: int, bysignal: int) {
	pid := pst.child_pid
	aof_forget_child()
	if pst.progress != nil {
		aof.last_cow = intrinsics.volatile_load(&pst.progress.cow)
	}
	aof_close_rewrite_window()
	switch {
	case bysignal == 0 && exitcode == 0:
		aof_rewrite_succeeded(pid)
	case bysignal == 0:
		plog(LOG_WARNING, "Background AOF rewrite terminated with error")
		aof_rewrite_abandoned(pid, false)
	case:
		digits: [24]u8
		plog(LOG_WARNING, "Background AOF rewrite terminated by signal ", string(digits[:format_i64(&digits[0], i64(bysignal))]))
		aof_rewrite_abandoned(pid, bysignal == int(linux.Signal.SIGUSR1))
	}
	persist_update_gate()
	aof_feed_refresh()
}

@(private = "file")
aof_reap :: proc(pid: linux.Pid) {
	keyspace_signal_owed()
	status: u32
	for {
		if _, err := linux.wait4(pid, &status, {}, nil); err != .EINTR {
			return
		}
	}
}

aof_kill_child :: proc() {
	if aof_rewriting() {
		aof_terminate_child(pst.child_pid)
	}
}

@(private = "file")
aof_terminate_child :: proc(pid: linux.Pid) {
	digits: [24]u8
	plog(LOG_NOTICE, "Killing running AOF rewrite child: ", string(digits[:format_i64(&digits[0], i64(pid))]))
	linux.kill(pid, .SIGUSR1)
	aof_reap(pid)
	aof_remove_temp_base(pid)
	aof_forget_child()
	aof.rewrite_start = -1
	aof_feed_refresh()
}

aof_start :: proc() -> bool {
	keyspace_fence()
	if access_writes_refused() {
		plog(LOG_WARNING, "AOF start refused: ", LABEL_PERSISTENCE_ON)
		return false
	}
	if !aof.started {
		aof.wanted = true
		return true
	}
	if aof.state != .Disabled {
		return true
	}
	if !aof_make_dir() {
		return false
	}
	aof.state = .Awaiting_Base
	aof.last_fsync_ms = aof_now_ms()
	if (pst.child_pid > 0 && !pst.child_aof) || aof_in_exec() || pst.loading {
		aof.rewrite_scheduled = true
		plog(LOG_NOTICE, "AOF was enabled but there is already another background operation. An AOF background was scheduled to start when possible.")
	} else {
		if aof_rewriting() {
			plog(LOG_NOTICE, "AOF was enabled but there is already an AOF rewriting in background. Stopping background AOF and starting a rewrite now.")
			aof_kill_child()
		}
		if !aof_rewrite_background() {
			aof_close_fd()
			aof_remove_temp_incr()
			aof.state = .Disabled
			plog(LOG_WARNING, "Eski needs to enable the AOF but can't trigger a background AOF rewrite operation. Check the above logs for more info about the error.")
			aof_feed_refresh()
			persist_update_gate()
			return false
		}
	}
	aof_feed_refresh()
	persist_update_gate()
	return true
}

aof_stop :: proc() {
	if !aof.started {
		aof.wanted = false
		return
	}
	if aof.state == .Disabled {
		return
	}
	was := aof.state
	if aof.fd >= 0 {
		if was == .Enabled {
			aof_flush(true)
			linux.fdatasync(aof.fd)
		}
		aof_close_fd()
	}
	if aof_rewriting() {
		aof_kill_child()
	}
	if was == .Awaiting_Base {
		aof_remove_temp_incr()
	}
	clear(&aof.buf)
	clear(&aof.stage)
	aof.stage_count = 0
	aof.state = .Disabled
	aof.rewrite_scheduled = false
	aof.write_err = false
	aof_err_from_fsync = false
	aof_feed_refresh()
	persist_update_gate()
}

aof_create_on_start :: proc() -> bool {
	if !aof_make_dir() {
		return false
	}
	seq := aof.manifest.base_seq + 1
	name: [dynamic]u8
	defer delete(name)
	aof_name(&name, seq, "base.rdb" if aof.preamble else "base.aof")
	tbuf: [64]u8
	tmp := aof_temp_base_name(tbuf[:], linux.getpid(), false)
	cbuf: [80]u8
	src := persist_cstr(tmp, cbuf[:])
	if !aof_write_base_to(src, aof.preamble) {
		return false
	}
	fbuf: [PERSIST_PATH_MAX]u8
	if err := linux.rename(src, aof_cpath(string(name[:]), fbuf[:])); err != .NONE {
		plog(LOG_WARNING, "Error trying to rename the temporary AOF base file ", tmp, " into ", string(name[:]), ": ", errno_text(err))
		linux.unlink(src)
		return false
	}
	if aof.manifest.has_base {
		old := aof.manifest.base
		old.kind = .History
		append(&aof.manifest.history, old)
	}
	aof.manifest.base = Aof_File {
		seq  = seq,
		kind = .Base,
	}
	append(&aof.manifest.base.name, ..name[:])
	aof.manifest.has_base = true
	aof.manifest.base_seq = seq
	plog(LOG_NOTICE, "Creating AOF base file ", string(name[:]), " on server start")
	return true
}

aof_open_incr_on_start :: proc() -> bool {
	if !aof_make_dir() {
		return false
	}
	if !aof.manifest.has_base && len(aof.manifest.incr) == 0 {
		if !aof_create_on_start() {
			return false
		}
	}
	fd: linux.Fd
	err: linux.Errno
	if n := len(aof.manifest.incr); n > 0 {
		last := string(aof.manifest.incr[n - 1].name[:])
		fd, err = aof_open_incr(last, false)
		if err != .NONE {
			plog(LOG_WARNING, "Can't open the append-only file ", last, ": ", errno_text(err))
			return false
		}
		plog(LOG_NOTICE, "Opening AOF incr file ", last, " on server start")
	} else {
		name: [dynamic]u8
		defer delete(name)
		seq := aof.manifest.incr_seq + 1
		aof_name(&name, seq, "incr.aof")
		fd, err = aof_open_incr(string(name[:]), true)
		if err != .NONE {
			plog(LOG_WARNING, "Can't open the append-only file ", string(name[:]), ": ", errno_text(err))
			return false
		}
		f := Aof_File {
			seq  = seq,
			kind = .Incr,
		}
		append(&f.name, ..name[:])
		append(&aof.manifest.incr, f)
		aof.manifest.incr_seq = seq
		plog(LOG_NOTICE, "Creating AOF incr file ", string(name[:]), " on server start")
	}
	if !aof_persist_manifest(&aof.manifest) {
		linux.close(fd)
		return false
	}
	aof_switch_fd(fd)
	aof_recompute_sizes()
	aof.fsynced_size = aof.current_size
	aof.last_fsync_ms = aof_now_ms()
	return true
}

@(private = "file")
aof_upgrade_old_style :: proc() -> (did: bool, ok: bool) {
	nbuf: [PERSIST_PATH_MAX]u8
	old := persist_cstr(aof.filename, nbuf[:])
	sb: linux.Stat
	if linux.stat(old, &sb) != .NONE || aof_is_dir(sb.mode) {
		return false, true
	}
	if !aof_make_dir() {
		return true, false
	}
	m: Aof_Manifest
	m.base = Aof_File {
		seq  = 1,
		kind = .Base,
	}
	append(&m.base.name, aof.filename)
	m.has_base = true
	m.base_seq = 1
	if !aof_persist_manifest(&m) {
		aof_manifest_free(&m)
		return true, false
	}
	fbuf: [PERSIST_PATH_MAX]u8
	if err := linux.rename(old, aof_cpath(aof.filename, fbuf[:])); err != .NONE {
		plog(LOG_WARNING, "Error trying to move the old AOF file ", aof.filename, " into dir ", aof.dirname, ": ", errno_text(err))
		mname: [dynamic]u8
		defer delete(mname)
		aof_manifest_name(&mname)
		mb: [PERSIST_PATH_MAX]u8
		linux.unlink(aof_cpath(string(mname[:]), mb[:]))
		aof_manifest_free(&m)
		return true, false
	}
	aof_fsync_dir()
	aof_manifest_set(m)
	plog(LOG_NOTICE, "Successfully migrated an old-style AOF into the AOF directory")
	return true, true
}

aof_startup :: proc() -> bool {
	aof.started = true
	m: Aof_Manifest
	exists, ok := aof_manifest_load_from_disk(&m)
	if !aof.wanted {
		if exists && ok {
			aof_manifest_set(m)
		} else {
			aof_manifest_free(&m)
			aof_manifest_set({})
		}
		aof.state = .Disabled
		aof_feed_refresh()
		return true
	}
	if !ok {
		aof_manifest_free(&m)
		return false
	}
	if exists {
		aof_manifest_set(m)
		if aof.manifest.has_base && len(aof.manifest.incr) == 0 && len(aof.manifest.history) == 0 && string(aof.manifest.base.name[:]) == aof.filename && !aof_file_exists(aof.filename) {
			old_buf, destination_buf: [PERSIST_PATH_MAX]u8
			old := persist_cstr(aof.filename, old_buf[:])
			old_stat: linux.Stat
			if linux.stat(old, &old_stat) == .NONE && old_stat.mode & linux.S_IFMT == linux.S_IFREG {
				if err := linux.rename(old, aof_cpath(aof.filename, destination_buf[:])); err != .NONE {
					plog(LOG_WARNING, "Error trying to move the old AOF file ", aof.filename, " into dir ", aof.dirname, ": ", errno_text(err))
					return false
				}
				aof_fsync_dir()
				plog(LOG_NOTICE, "Completed interrupted old-style AOF migration into the AOF directory")
			}
		}
	} else {
		aof_manifest_free(&m)
		aof_manifest_set({})
		if _, upgraded := aof_upgrade_old_style(); !upgraded {
			return false
		}
	}
	aof.state = .Enabled
	if aof.manifest.has_base || len(aof.manifest.incr) > 0 {
		t0 := now_ns()
		#partial switch aof_load_all(true) {
		case .Aborted, .Unopenable, .Absent:
			return false
		case .Loaded, .Truncated_Tail:
			l: Log_Line
			ll_begin(&l, LOG_NOTICE)
			ll_str(&l, "DB loaded from append only file: ")
			ll_fixed(&l, f64(now_ns() - t0) / 1e9, 3)
			ll_str(&l, " seconds")
			ll_end(&l)
		}
	}
	if !aof_open_incr_on_start() {
		return false
	}
	aof_delete_history()
	aof_feed_refresh()
	persist_update_gate()
	return true
}

@(private = "file")
aof_retry_allowed :: proc() -> bool {
	if aof.failures < 3 || persist_unix_now() >= aof_retry_at {
		return true
	}
	if !aof_retry_reported {
		aof_retry_reported = true
		tmp: [24]u8
		n := format_i64(&tmp[0], (aof_retry_at - persist_unix_now() + 59) / 60)
		plog(LOG_WARNING, "Background AOF rewrite has repeatedly failed and triggered the limit, will retry in ", string(tmp[:n]), " minutes")
	}
	return false
}

aof_cron :: proc() {
	if pst.in_child || aof.loading {
		return
	}
	aof_bio_collect()
	aof_delete_history()
	if aof.state == .Awaiting_Base && !aof_rewriting() && !aof.rewrite_scheduled {
		aof.rewrite_scheduled = true
	}
	if !aof_rewriting() && aof.rewrite_start >= 0 {
		aof.rewrite_start = -1
	}
	if pst.child_pid <= 0 && !pst.loading && !aof_in_exec() {
		if aof.rewrite_scheduled {
			if aof_retry_allowed() {
				aof_rewrite_background()
			}
		} else if aof.state == .Enabled && aof.auto_pct > 0 && aof.current_size > aof.auto_min {
			base := aof.base_size if aof.base_size > 0 else 1
			growth := aof.current_size * 100 / base - 100
			if growth >= aof.auto_pct && aof_retry_allowed() {
				tmp: [24]u8
				n := format_i64(&tmp[0], growth)
				plog(LOG_NOTICE, "Starting automatic rewriting of AOF on ", string(tmp[:n]), "% growth")
				aof_rewrite_background()
			}
		}
	}
	if aof.fd >= 0 && (aof.write_err || (len(aof.buf) > 0 && aof.fsync == .Everysec)) {
		aof_flush(false)
	}
}

aof_shutdown :: proc() {
	if aof_rewriting() {
		plog(LOG_WARNING, "There is a child rewriting the AOF. Killing it!")
		aof_kill_child()
	}
	if aof.state == .Awaiting_Base {
		plog(LOG_WARNING, "Writing initial AOF. Exit anyway.")
	}
	if aof.state != .Disabled && aof.fd >= 0 {
		plog(LOG_NOTICE, "Calling fsync() on the AOF file.")
		aof_flush(true)
		linux.fdatasync(aof.fd)
		aof.fsynced_size = aof.current_size
	}
}

Aof_Reader :: struct {
	fd:    linux.Fd,
	buf:   [dynamic]u8,
	pos:   int,
	base:  i64,
	eof:   bool,
	offs:  [dynamic][2]int,
	split: [dynamic][]u8,
	keep:  int,
	err:   linux.Errno,
}

Aof_Parse :: enum u8 {
	Ok,
	Eof,
	Truncated,
	Bad,
}

@(private = "file")
AOF_READ_CHUNK :: 256 * 1024

@(private = "file")
AOF_LINE_MAX :: 1024

aof_reader_free :: proc(r: ^Aof_Reader) {
	delete(r.buf)
	delete(r.offs)
	delete(r.split)
	r.buf = nil
	r.offs = nil
	r.split = nil
}

aof_r_fill :: proc(r: ^Aof_Reader, need: int) -> bool {
	for len(r.buf) - r.pos < need {
		if r.eof {
			return false
		}
		if r.keep > 0 {
			rest := len(r.buf) - r.keep
			if rest > 0 {
				copy(r.buf[:rest], r.buf[r.keep:])
			}
			resize(&r.buf, rest)
			r.pos -= r.keep
			r.base += i64(r.keep)
			r.keep = 0
		}
		old := len(r.buf)
		want := max(AOF_READ_CHUNK, need - (old - r.pos))
		non_zero_resize(&r.buf, old + want)
		got := 0
		for {
			n, err := linux.read(r.fd, r.buf[old:old + want])
			if err == .EINTR {
				continue
			}
			if err != .NONE {
				r.err = err
				r.eof = true
			} else if n <= 0 {
				r.eof = true
			} else {
				got = n
			}
			break
		}
		resize(&r.buf, old + got)
	}
	return true
}

aof_r_offset :: #force_inline proc(r: ^Aof_Reader) -> i64 {
	return r.base + i64(r.pos)
}

aof_r_line :: proc(r: ^Aof_Reader) -> (line: []u8, res: Aof_Parse) {
	scanned := 0
	for {
		for i := r.pos + scanned; i < len(r.buf); i += 1 {
			if r.buf[i] != '\n' {
				continue
			}
			l := r.buf[r.pos:i]
			if len(l) == 0 || l[len(l) - 1] != '\r' {
				return nil, .Bad
			}
			r.pos = i + 1
			return l[:len(l) - 1], .Ok
		}
		scanned = len(r.buf) - r.pos
		if scanned > AOF_LINE_MAX {
			return nil, .Bad
		}
		if !aof_r_fill(r, scanned + 1) {
			return nil, .Truncated
		}
	}
}

aof_r_command :: proc(r: ^Aof_Reader, argv: ^[dynamic][]u8) -> Aof_Parse {
	for {
		r.keep = r.pos
		if r.pos >= len(r.buf) && !aof_r_fill(r, 1) {
			return .Eof
		}
		if r.buf[r.pos] == '#' {
			_, res := aof_r_line(r)
			if res != .Ok {
				return res
			}
			continue
		}
		if r.buf[r.pos] != '*' {
			return .Bad
		}
		head, hres := aof_r_line(r)
		if hres != .Ok {
			return hres
		}
		n, ok := parse_i64(head[1:])
		if !ok || n < 1 || n > 1 << 30 {
			return .Bad
		}
		clear(&r.offs)
		for _ in 0 ..< n {
			if !aof_r_fill(r, 1) {
				return .Truncated
			}
			if r.buf[r.pos] != '$' {
				return .Bad
			}
			l, lres := aof_r_line(r)
			if lres != .Ok {
				return lres
			}
			size, sok := parse_i64(l[1:])
			if !sok || size < 0 || size > 1 << 40 {
				return .Bad
			}
			if !aof_r_fill(r, int(size) + 2) {
				return .Truncated
			}
			end := r.pos + int(size)
			if r.buf[end] != '\r' || r.buf[end + 1] != '\n' {
				return .Bad
			}
			append(&r.offs, [2]int{r.pos - r.keep, int(size)})
			r.pos = end + 2
		}
		clear(argv)
		for o in r.offs {
			append(argv, r.buf[r.keep + o[0]:r.keep + o[0] + o[1]])
		}
		return .Ok
	}
}

aof_fake_conn :: proc() -> ^Conn {
	if aof.fake == nil {
		c := new(Conn, runtime.heap_allocator())
		c.fd = -1
		c.id = -1
		c.resp = RESP2
		c.kind = .Redis
		c.authed = true
		c.ever_authed = true
		aof.fake = c
	}
	c := aof.fake
	if len(dbs) > 0 && c.db == nil {
		c.db = &dbs[0]
	}
	return c
}

@(private = "file")
aof_exec_one :: proc(c: ^Conn, argv: [][]u8, name: string) -> bool {
	if eq_nocase(argv[0], "select") {
		if len(argv) != 2 {
			plog(LOG_WARNING, "Wrong number of arguments for 'select' command reading the append only file ", name)
			return false
		}
		id, ok := parse_i64(argv[1])
		if !ok || id < 0 || id >= i64(len(dbs)) {
			plog(LOG_WARNING, "Invalid DB index '", string(argv[1]), "' reading the append only file ", name)
			return false
		}
		c.db = &dbs[id]
		return true
	}
	cmd := lookup_command(argv[0])
	if cmd == nil || cmd.handler == nil {
		plog(LOG_WARNING, "Unknown command '", string(argv[0]), "' reading the append only file ", name)
		return false
	}
	if (cmd.arity > 0 && len(argv) != cmd.arity) || (cmd.arity < 0 && len(argv) < -cmd.arity) {
		plog(LOG_WARNING, "Wrong number of arguments for '", string(argv[0]), "' command reading the append only file ", name)
		return false
	}
	db_cur = c.db
	c.wlen = 0
	c.wpos = 0
	cmd.handler(c, argv)
	if c.wlen > 0 && c.wbuf[0] == '-' {
		last := c.wlen
		if last >= 2 && c.wbuf[last - 2] == '\r' && c.wbuf[last - 1] == '\n' { last -= 2 }
		plog(LOG_WARNING, "Error executing '", cmd.name, "' while reading AOF ", name, ": ", string(c.wbuf[1:last]))
		if cfg.propagation_error_behavior == 1 {
			plog(LOG_WARNING, "Fatal AOF command execution error: propagation-error-behavior is panic")
			panic("AOF command execution failed with propagation-error-behavior panic")
		}
	}
	c.wlen = 0
	c.wpos = 0
	pst.dirty_explicit = false
	if cfg.key_load_delay != 0 {
		persist_debug_delay(cfg.key_load_delay)
	}
	return true
}

aof_exec :: proc(c: ^Conn, cmd: ^Command, argv: [][]u8) {
	if cmd == nil || cmd.handler == nil || len(argv) == 0 {
		return
	}
	db_cur = c.db
	cmd.handler(c, argv)
	c.wlen = 0
	c.wpos = 0
	pst.dirty_explicit = false
}

@(private = "file")
aof_q_reset :: proc() {
	clear(&aof_q_bytes)
	clear(&aof_q_lens)
	clear(&aof_q_argc)
}

@(private = "file")
aof_q_push :: proc(argv: [][]u8) {
	append(&aof_q_argc, len(argv))
	for a in argv {
		append(&aof_q_lens, len(a))
		append(&aof_q_bytes, ..a)
	}
}

@(private = "file")
aof_q_run :: proc(c: ^Conn, name: string) -> bool {
	off, li := 0, 0
	for n in aof_q_argc {
		clear(&aof_q_argv)
		for _ in 0 ..< n {
			l := aof_q_lens[li]
			li += 1
			append(&aof_q_argv, aof_q_bytes[off:off + l])
			off += l
		}
		if !aof_exec_one(c, aof_q_argv[:], name) {
			return false
		}
	}
	clear(&aof_q_argv)
	return true
}

@(private = "file")
aof_load_truncated :: proc(name: string, valid: i64, is_last: bool) -> Aof_Load_Outcome {
	tmp: [24]u8
	n := format_i64(&tmp[0], valid)
	if !is_last {
		plog(LOG_WARNING, "Unexpected end of file reading the append only file ", name)
		plog(LOG_WARNING, "Fatal error: the truncated file is not the last file")
		return .Aborted
	}
	if !aof.load_truncated {
		plog(LOG_WARNING, "Unexpected end of file reading the append only file ", name, ". Eski has no AOF repair tool. You can: 1) Make a backup of your AOF file, then remove the incomplete command at its end by hand. 2) Alternatively you can set the 'aof-load-truncated' configuration option to yes and restart the server.")
		return .Aborted
	}
	plog(LOG_WARNING, "!!! Warning: short read while loading the AOF file ", name, "!!!")
	plog(LOG_WARNING, "!!! Truncating the AOF ", name, " at offset ", string(tmp[:n]), " !!!")
	buf: [PERSIST_PATH_MAX]u8
	if err := linux.truncate(aof_cpath(name, buf[:]), valid); err != .NONE {
		plog(LOG_WARNING, "Error truncating the AOF file ", name, ": ", errno_text(err))
		return .Aborted
	}
	plog(LOG_WARNING, "AOF ", name, " loaded anyway because aof-load-truncated is enabled")
	return .Truncated_Tail
}

@(private = "file")
aof_load_commands :: proc(r: ^Aof_Reader, name: string, is_last: bool, done_before: i64) -> Aof_Load_Outcome {
	sm.trim_limit_relaxed = true
	defer sm.trim_limit_relaxed = false
	c := aof_fake_conn()
	if len(dbs) > 0 {
		c.db = &dbs[0]
	}
	valid := aof_r_offset(r)
	before_multi := valid
	inside_transaction := false
	aof_q_reset()
	defer aof_q_reset()
	interval := cfg.loading_events_interval_bytes if cfg.loading_events_interval_bytes > 0 else AOF_LOAD_EVENTS_BYTES
	next_events := valid + interval
	count: i64 = 0
	for {
		res := aof_r_command(r, &aof_load_argv)
		switch res {
		case .Eof:
			if inside_transaction {
				plog(LOG_WARNING, "Revert incomplete MULTI/EXEC transaction in AOF file ", name)
				return aof_load_truncated(name, before_multi, is_last)
			}
			if r.err != .NONE {
				plog(LOG_WARNING, "Unrecoverable error reading the append only file ", name, ": ", errno_text(r.err))
				return .Aborted
			}
			return .Loaded
		case .Truncated:
			if r.err != .NONE {
				plog(LOG_WARNING, "Unrecoverable error reading the append only file ", name, ": ", errno_text(r.err))
				return .Aborted
			}
			return aof_load_truncated(name, before_multi if inside_transaction else valid, is_last)
		case .Bad:
			plog(LOG_WARNING, "Bad file format reading the append only file ", name, ": make a backup of your AOF file, then repair it by hand. Eski has no AOF repair tool.")
			return .Aborted
		case .Ok:
		}
		argv := aof_load_argv[:]
		switch {
		case eq_nocase(argv[0], "multi"):
			if !inside_transaction {
				before_multi = valid
			}
			inside_transaction = true
			aof_q_reset()
		case eq_nocase(argv[0], "exec"):
			if inside_transaction && !aof_q_run(c, name) {
				return .Aborted
			}
			inside_transaction = false
			aof_q_reset()
		case eq_nocase(argv[0], "discard"):
			inside_transaction = false
			aof_q_reset()
		case inside_transaction:
			aof_q_push(argv)
		case:
			if !aof_exec_one(c, argv, name) {
				return .Aborted
			}
		}
		valid = aof_r_offset(r)
		count += 1
		pst.loading_loaded = done_before + valid
		if valid >= next_events {
			next_events = valid + interval
			if pst.serve_while_loading {
				persist_serve_events()
			}
		}
		if count & 1023 == 0 && persist_signal_pending() && pst.loading {
			persist_signal_loading_exit()
		}
	}
}

@(private = "file")
aof_load_one :: proc(f: ^Aof_File, is_last: bool, done_before: i64) -> Aof_Load_Outcome {
	name := string(f.name[:])
	buf: [PERSIST_PATH_MAX]u8
	fd, err := linux.open(aof_cpath(name, buf[:]), {.CLOEXEC})
	if err == .ENOENT {
		plog(LOG_WARNING, "The AOF file ", name, " doesn't exist: ", errno_text(err))
		return .Absent
	}
	if err != .NONE {
		plog(LOG_WARNING, "Fatal error: can't open the append log file ", name, " for reading: ", errno_text(err))
		return .Unopenable
	}
	defer linux.close(fd)
	sb: linux.Stat
	if serr := linux.fstat(fd, &sb); serr != .NONE {
		plog(LOG_WARNING, "Unable to obtain the AOF file ", name, " length. stat: ", errno_text(serr))
		return .Unopenable
	}
	size := i64(sb.size)
	if size == 0 {
		return .Blank
	}
	r := Aof_Reader {
		fd = fd,
	}
	defer aof_reader_free(&r)
	magic: [5]u8
	got, _ := linux.pread(fd, magic[:], 0)
	if got == 5 && string(magic[:]) == "REDIS" {
		if f.kind != .Base {
			plog(LOG_WARNING, "Bad file format reading the append only file ", name, ": make a backup of your AOF file, then repair it by hand. Eski has no AOF repair tool.")
			return .Aborted
		}
		plog(LOG_NOTICE, "Reading RDB base file on AOF loading...")
		rr: rdb.Reader
		rdb.reader_init_file(&rr, fd, pst.checksum)
		rr.progress = persist_loading_progress
		rr.tick_every = cfg.loading_events_interval_bytes if cfg.loading_events_interval_bytes > 0 else AOF_LOAD_EVENTS_BYTES
		rr.next_tick = rr.tick_every
		res := persist_load_stream(&rr, false)
		rest := rdb.reader_offset(&rr)
		rdb.reader_destroy(&rr)
		if res != .Ok {
			plog(LOG_WARNING, "Error reading the RDB base file ", name, ", AOF loading aborted")
			return .Aborted
		}
		persist_log_load_done()
		if rest >= size {
			return .Loaded
		}
		plog(LOG_NOTICE, "Reading the remaining AOF tail...")
		if _, lerr := linux.lseek(fd, rest, .SET); lerr != .NONE {
			plog(LOG_WARNING, "Unrecoverable error reading the append only file ", name, ": ", errno_text(lerr))
			return .Aborted
		}
		r.base = rest
	}
	return aof_load_commands(&r, name, is_last, done_before)
}

aof_load_file :: proc(name: string, is_last: bool, at_startup: bool) -> Aof_Load_Outcome {
	m: Aof_Manifest
	defer aof_manifest_free(&m)
	m.base = Aof_File {
		seq  = 1,
		kind = .Base,
	}
	append(&m.base.name, name)
	m.has_base = true
	return aof_load_manifest(&m, at_startup)
}

aof_log_loaded :: proc(kind: string, name: string, t0: i64) {
	l: Log_Line
	ll_begin(&l, LOG_NOTICE)
	ll_str(&l, "DB loaded from ")
	ll_str(&l, kind)
	ll_str(&l, " file ")
	ll_str(&l, name)
	ll_str(&l, ": ")
	ll_fixed(&l, f64(now_ns() - t0) / 1e9, 3)
	ll_str(&l, " seconds")
	ll_end(&l)
}

aof_load_all :: proc(at_startup: bool) -> Aof_Load_Outcome {
	return aof_load_manifest(&aof.manifest, at_startup)
}

@(private = "file")
aof_load_manifest :: proc(m: ^Aof_Manifest, at_startup: bool) -> Aof_Load_Outcome {
	keyspace_fence()
	if !m.has_base && len(m.incr) == 0 {
		return .Absent
	}
	total: i64 = 0
	missing := 0
	if m.has_base {
		if aof_file_exists(string(m.base.name[:])) {
			total += aof_file_size(string(m.base.name[:]))
		} else {
			missing += 1
		}
	}
	for f in m.incr {
		if aof_file_exists(string(f.name[:])) {
			total += aof_file_size(string(f.name[:]))
		} else {
			missing += 1
		}
	}
	if total == 0 && missing == 0 {
		return .Blank
	}
	saved_dirty := pst.dirty
	saved_db := db_cur
	saved_deny := deny_blocking
	pst.loading = true
	pst.loading_start = persist_unix_now()
	pst.loading_total = total
	pst.loading_loaded = 0
	pst.loading_used_mem = 0
	pst.serve_while_loading = at_startup
	aof.loading = true
	sm.trim_limit_relaxed = true
	deny_blocking = true
	aof_feed_refresh()
	persist_update_gate()
	result := Aof_Load_Outcome.Loaded
	done: i64 = 0
	step :: proc(res: ^Aof_Load_Outcome, r: Aof_Load_Outcome, kind: string, name: string, t0: i64) -> bool {
		switch r {
		case .Loaded:
			aof_log_loaded(kind, name, t0)
		case .Truncated_Tail:
			aof_log_loaded(kind, name, t0)
			res^ = .Truncated_Tail
		case .Blank:
		case .Absent, .Aborted:
			res^ = .Aborted
			return false
		case .Unopenable:
			res^ = .Unopenable
			return false
		}
		return true
	}
	going := true
	if m.has_base {
		t0 := now_ns()
		name := string(m.base.name[:])
		going = step(&result, aof_load_one(&m.base, len(m.incr) == 0, done), "base", name, t0)
		done += aof_file_size(name)
	}
	for i in 0 ..< len(m.incr) {
		if !going {
			break
		}
		t0 := now_ns()
		f := &m.incr[i]
		name := string(f.name[:])
		going = step(&result, aof_load_one(f, i == len(m.incr) - 1, done), "incr", name, t0)
		done += aof_file_size(name)
	}
	pst.loading = false
	pst.serve_while_loading = false
	pst.loading_loaded = done
	aof.loading = false
	sm.trim_limit_relaxed = false
	deny_blocking = saved_deny
	db_cur = saved_db
	pst.dirty = saved_dirty
	pst.dirty_explicit = false
	aof_feed_refresh()
	persist_update_gate()
	return result
}

aof_debug_loadaof :: proc(c: ^Conn) {
	if aof.state == .Enabled {
		aof_flush(true)
	}
	if aof.state == .Disabled {
		m: Aof_Manifest
		exists, ok := aof_manifest_load_from_disk(&m)
		if !ok {
			aof_manifest_free(&m)
			reply_error(c, ERR_AOF_LOAD)
			return
		}
		if exists {
			aof_manifest_set(m)
		} else {
			aof_manifest_free(&m)
		}
	}
	db_flush_all()
	res := aof_load_all(false)
	if aof.fd >= 0 {
		aof_recompute_sizes()
		aof.fsynced_size = aof.current_size
	}
	#partial switch res {
	case .Loaded, .Blank, .Truncated_Tail:
		pst.dirty = 0
		pst.dirty_explicit = false
		plog(LOG_NOTICE, "Append Only File loaded by DEBUG LOADAOF")
		reply_ok(c)
	case:
		reply_error(c, ERR_AOF_LOAD)
	}
}

cmd_bgrewriteaof :: proc(c: ^Conn, argv: [][]u8) {
	if aof_rewriting() {
		reply_error(c, ERR_AOF_REWRITE_RUNNING)
		return
	}
	if pst.child_pid > 0 || aof_in_exec() {
		aof.rewrite_scheduled = true
		reply_simple(c, "Background append only file rewriting scheduled")
		return
	}
	if aof_rewrite_background() {
		reply_simple(c, "Background append only file rewriting started")
		return
	}
	reply_error(c, "ERR Can't execute an AOF background rewriting. Please check the server logs for more information.")
}

aof_info :: proc(b: ^[dynamic]u8) {
	running := aof_rewriting()
	current: i64 = -1
	if running && aof.rewrite_start >= 0 {
		current = max(persist_unix_now() - aof.rewrite_start, 0)
	}
	info_line_int(b, "aof_enabled", 1 if aof.state != .Disabled else 0)
	info_line_int(b, "aof_rewrite_in_progress", 1 if running else 0)
	info_line_int(b, "aof_rewrite_scheduled", 1 if aof.rewrite_scheduled else 0)
	info_line_int(b, "aof_last_rewrite_time_sec", aof.rewrite_last)
	info_line_int(b, "aof_current_rewrite_time_sec", current)
	info_line_str(b, "aof_last_bgrewrite_status", "err" if aof.last_rewrite_err else "ok")
	info_line_int(b, "aof_rewrites", aof.stat_rewrites)
	info_line_int(b, "aof_rewrites_consecutive_failures", aof.failures)
	info_line_str(b, "aof_last_write_status", "err" if aof.write_err else "ok")
	info_line_int(b, "aof_last_cow_size", aof.last_cow)
	info_line_int(b, "module_fork_in_progress", 0)
	info_line_int(b, "module_fork_last_cow_size", 0)
	if aof.state == .Disabled {
		return
	}
	info_line_int(b, "aof_current_size", aof.current_size)
	info_line_int(b, "aof_base_size", aof.base_size)
	info_line_int(b, "aof_pending_rewrite", 1 if aof.rewrite_scheduled else 0)
	info_line_int(b, "aof_buffer_length", i64(len(aof.buf)))
	info_line_int(b, "aof_pending_bio_fsync", i64(aof_bio_pending()))
	info_line_int(b, "aof_delayed_fsync", aof.delayed_fsync)
}

aof_commands := [?]Command {
	{"bgrewriteaof", cmd_bgrewriteaof, 1},
}

@(init)
register_aof_commands :: proc "contextless" () {
	register_commands(aof_commands[:])
}

aof_keyspace_hash :: proc(task: ^Keyspace_Task) {
	p := Aof_Rp{b = ks.value_data(task.hash_expired)}
	for _ in 0 ..< task.hash_expired_count {
		field, null, ok := aof_rp_bulk(&p)
		if !ok || null { store_fatal("hash AOF expiry trace invariant") }
		args := [3][]u8{transmute([]u8)string("HDEL"), task.argv[1], field}
		aof_feed_argv_direct(task.client.db.id, args[:])
	}
	if p.i != len(p.b) { store_fatal("hash AOF expiry trace length invariant") }
	if task.dirty == 0 { return }
	#partial switch task.op {
	case .Hset, .Hmset, .Hsetnx, .Hdel, .Hincrby, .Hincrbyfloat, .Hexpire, .Hpexpire, .Hexpireat, .Hpexpireat, .Hpersist:
	case: return
	}
	text: [64]u8
	b := Keyspace_Builder{bytes = text[:]}
	reply: []u8
	if task.raw {
		reply = ks.value_data(task.results[0])
	} else if task.ok {
		reply = transmute([]u8)string("+OK\r\n")
	} else {
		keyspace_builder_integer(&b, task.integer)
		reply = b.bytes[:b.used]
	}
	if task.op == .Hincrbyfloat {
		_, ok := aof_reply_bulk(reply)
		if !ok { store_fatal("hash AOF floating result invariant") }
	}
	if task.op == .Hincrbyfloat {
		aof_tr_hincrbyfloat(&task.client, task.argv, reply, task.hash_expire_at)
	} else if task.op >= .Hexpire && task.op <= .Hpexpireat {
		aof_tr_hexpire(&task.client, task.command_name, task.argv, reply, task.hash_expire_at)
	} else {
		aof_translate(&task.client, task.command, task.argv, reply)
	}
}
