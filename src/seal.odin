package main

import "core:sys/linux"
import "rdb"
import "seal"

SEAL_KEY_FILE_MAX :: 80

SEAL_PAGE :: 4096

Seal_File_Writer :: seal.File_Writer

Seal_File_Reader :: seal.File_Reader

Seal_Keys :: struct {
	current:      seal.Key,
	previous:     seal.Key,
	has_previous: bool,
}

encryption_key_file: string

encryption_key_file_previous: string

encryption_adopt_plain: bool

seal_on: bool

seal_keys: ^Seal_Keys

seal_startup_phase: bool

seal_saw_plain: bool

seal_saw_previous: bool

seal_rewrap_snapshot: bool

seal_rewrap_aof: bool

seal_force_gc: bool

seal_reading_name: string

seal_quiet: bool

@(private = "file")
seal_keys_fallback: Seal_Keys

@(private = "file")
seal_refuse_start :: proc(parts: ..string) -> ! {
	l: Log_Line
	ll_begin(&l, LOG_WARNING)
	ll_str(&l, "Refusing to start: ")
	for p in parts {
		ll_str(&l, p)
	}
	ll_end(&l)
	linux.exit_group(1)
}

@(private = "file")
seal_keys_alloc :: proc() -> ^Seal_Keys {
	p, err := linux.mmap(0, SEAL_PAGE, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	if err != .NONE || p == nil {
		return &seal_keys_fallback
	}
	linux.madvise(p, SEAL_PAGE, .DONTDUMP)
	linux.mlock(p, SEAL_PAGE)
	return (^Seal_Keys)(p)
}

@(private = "file")
seal_read_key_file :: proc(path: string, k: ^seal.Key) -> (reason: string, detail: string) {
	buf: [PERSIST_PATH_MAX]u8
	fd, err := linux.open(persist_cstr(path, buf[:]), {.CLOEXEC})
	if err != .NONE {
		return "cannot be opened: ", errno_text(err)
	}
	defer linux.close(fd)
	sb: linux.Stat
	if serr := linux.fstat(fd, &sb); serr != .NONE {
		return "cannot be examined: ", errno_text(serr)
	}
	if sb.mode & linux.S_IFMT != linux.S_IFREG {
		return "is not a regular file", ""
	}
	if sb.mode & {.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH} != {} {
		return "can be read or written by its group or by other users; allow its owner only (mode 0400 or 0600)", ""
	}
	if sb.uid != linux.geteuid() && sb.uid != 0 {
		return "belongs to another user; it must belong to the user the server runs as, or to root", ""
	}
	text: [SEAL_KEY_FILE_MAX]u8
	defer seal.zero(&text, len(text))
	n := 0
	for n < len(text) {
		got, rerr := linux.read(fd, text[n:])
		if rerr == .EINTR {
			continue
		}
		if rerr != .NONE {
			return "cannot be read: ", errno_text(rerr)
		}
		if got <= 0 {
			break
		}
		n += got
	}
	if !seal.key_parse(text[:n], k) {
		return "must hold exactly 64 hexadecimal characters (32 random bytes), optionally followed by one newline", ""
	}
	return "", ""
}

seal_load_keys :: proc() {
	if encryption_key_file == "" {
		if encryption_key_file_previous != "" || encryption_adopt_plain {
			seal_refuse_start("encryption-adopt-plain and encryption-key-file-previous need encryption-key-file")
		}
		return
	}
	seal_keys = seal_keys_alloc()
	if reason, detail := seal_read_key_file(encryption_key_file, &seal_keys.current); reason != "" {
		seal_wipe_keys()
		seal_refuse_start("the encryption key file ", encryption_key_file, " ", reason, detail)
	}
	if encryption_key_file_previous != "" {
		if reason, detail := seal_read_key_file(encryption_key_file_previous, &seal_keys.previous); reason != "" {
			seal_wipe_keys()
			seal_refuse_start("the previous encryption key file ", encryption_key_file_previous, " ", reason, detail)
		}
		if seal.same_key_id(seal_keys.previous.id, seal_keys.current.id) {
			seal_wipe_keys()
			seal_refuse_start("encryption-key-file-previous holds the same key as encryption-key-file")
		}
		seal_keys.has_previous = true
	}
	seal_on = true
	seal_startup_phase = true
}

seal_wipe_keys :: proc "contextless" () {
	if seal_keys != nil {
		seal.zero(seal_keys, size_of(Seal_Keys))
	}
}

seal_salt :: proc "contextless" () -> (s: [seal.SALT_SIZE]u8) {
	seal.salt_draw(&s)
	return
}

Seal_Key_Use :: enum u8 {
	None,
	Current,
	Previous,
}

seal_key_for :: proc "contextless" (id: [seal.KEY_ID_SIZE]u8) -> (^seal.Key, Seal_Key_Use) {
	if !seal_on {
		return nil, .None
	}
	if seal.same_key_id(id, seal_keys.current.id) {
		return &seal_keys.current, .Current
	}
	if seal_startup_phase && seal_keys.has_previous && seal.same_key_id(id, seal_keys.previous.id) {
		return &seal_keys.previous, .Previous
	}
	return nil, .None
}

seal_plain_allowed :: proc "contextless" () -> bool {
	return seal_startup_phase && encryption_adopt_plain
}

seal_reader_failed :: proc "contextless" (r: ^seal.File_Reader) {
	if r.state == .Torn && r.mode == .Live {
		return
	}
	l: Log_Line
	ll_begin(&l, LOG_WARNING)
	ll_str(&l, "The encrypted data file ")
	ll_str(&l, seal_reading_name)
	switch r.state {
	case .Torn:
		ll_str(&l, " is cut short at segment ")
	case .Failed:
		ll_str(&l, " could not be read at segment ")
	case .Damaged, .Open, .End:
		ll_str(&l, " is damaged at segment ")
	}
	ll_int(&l, i64(r.segment))
	ll_str(&l, " (byte offset ")
	ll_int(&l, r.cut)
	ll_str(&l, "): ")
	ll_str(&l, r.reason)
	if r.state == .Failed && r.errno != .NONE {
		ll_str(&l, ": ")
		ll_str(&l, errno_text(r.errno))
	}
	ll_end(&l)
}

Seal_Open :: enum u8 {
	Plain,
	Sealed,
	Refused,
	Torn_Header,
}

seal_header_of :: proc(fd: linux.Fd) -> (raw: [seal.HEADER_SIZE]u8, got: int) {
	for got < seal.HEADER_SIZE {
		n, err := linux.pread(fd, raw[got:], i64(got))
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			break
		}
		got += n
	}
	return
}

seal_refuse_file :: proc(what: string, name: string, parts: ..string) {
	if seal_quiet {
		return
	}
	l: Log_Line
	ll_begin(&l, LOG_WARNING)
	ll_str(&l, "Refusing to load the ")
	ll_str(&l, what)
	ll_str(&l, " ")
	ll_str(&l, name)
	ll_str(&l, ": ")
	for p in parts {
		ll_str(&l, p)
	}
	ll_end(&l)
}

SEAL_TEXT_NO_KEY :: "the data file is encrypted; set encryption-key-file"

SEAL_TEXT_OTHER_KEY :: "the data file was written with another key"

SEAL_TEXT_PLAIN :: "the data file is not encrypted although encryption-key-file is set; start once with encryption-adopt-plain yes to encrypt it"

SEAL_TEXT_KIND :: "the data file is an encrypted file of another kind"

SEAL_TEXT_HEADER :: "the encryption header of the data file is damaged or incomplete"

seal_classify :: proc(fd: linux.Fd, what: string, name: string, kinds: bit_set[seal.Kind]) -> (outcome: Seal_Open, header: [seal.HEADER_SIZE]u8, h: seal.Header, key: ^seal.Key, use: Seal_Key_Use) {
	got: int
	header, got = seal_header_of(fd)
	if !seal.looks_encrypted(header[:got]) {
		if !seal_on {
			return .Plain, header, h, nil, .None
		}
		if !seal_plain_allowed() {
			seal_refuse_file(what, name, SEAL_TEXT_PLAIN)
			return .Refused, header, h, nil, .None
		}
		seal_saw_plain = true
		return .Plain, header, h, nil, .None
	}
	if !seal_on {
		seal_refuse_file(what, name, SEAL_TEXT_NO_KEY)
		return .Refused, header, h, nil, .None
	}
	res: seal.Header_Result
	h, res = seal.header_parse(header[:got])
	if res == .Short {
		return .Torn_Header, header, h, nil, .None
	}
	if res != .Ok {
		seal_refuse_file(what, name, SEAL_TEXT_HEADER)
		return .Refused, header, h, nil, .None
	}
	if h.kind not_in kinds {
		seal_refuse_file(what, name, SEAL_TEXT_KIND)
		return .Refused, header, h, nil, .None
	}
	key, use = seal_key_for(h.key_id)
	if key == nil {
		seal_refuse_file(what, name, SEAL_TEXT_OTHER_KEY)
		return .Refused, header, h, nil, .None
	}
	if use == .Previous {
		seal_saw_previous = true
	}
	return .Sealed, header, h, key, use
}

seal_file_size :: proc(fd: linux.Fd) -> i64 {
	sb: linux.Stat
	if linux.fstat(fd, &sb) != .NONE {
		return 0
	}
	return i64(sb.size)
}

seal_snapshot_attach :: proc(r: ^rdb.Reader, sr: ^seal.File_Reader, fd: linux.Fd, name: string) -> bool {
	outcome, header, h, key, use := seal_classify(fd, "data file", name, {.Snapshot})
	switch outcome {
	case .Plain:
		if seal_on {
			seal_rewrap_snapshot = true
		}
		return true
	case .Refused:
		return false
	case .Torn_Header:
		seal_refuse_file("data file", name, SEAL_TEXT_HEADER)
		return false
	case .Sealed:
	}
	if use == .Previous {
		seal_rewrap_snapshot = true
	}
	seal_reading_name = name
	seal.reader_init(sr, fd, seal_file_size(fd), key, header, h.kind, .Closed)
	sr.on_fail = seal_reader_failed
	r.seal = sr
	return true
}

seal_snapshot_done :: proc(r: ^rdb.Reader, sr: ^seal.File_Reader) -> bool {
	if r.seal == nil {
		return true
	}
	if r.end != r.pos || !seal.finish(sr) {
		if sr.state == .Open || sr.state == .End {
			plog(LOG_WARNING, "The encrypted data file ", seal_reading_name, " holds decrypted bytes after the end of its data")
		}
		return false
	}
	return true
}

seal_reader_release :: proc(r: ^rdb.Reader, sr: ^seal.File_Reader) {
	if r.seal != nil {
		r.seal = nil
		seal.reader_destroy(sr)
	}
}

seal_probe_attach :: proc(r: ^rdb.Reader, sr: ^seal.File_Reader, fd: linux.Fd) -> string {
	header, got := seal_header_of(fd)
	if !seal.looks_encrypted(header[:got]) {
		if seal_on && got > 0 && !seal_plain_allowed() {
			return "is not encrypted although encryption-key-file is set"
		}
		return ""
	}
	if !seal_on {
		return "is encrypted; set encryption-key-file"
	}
	h, res := seal.header_parse(header[:got])
	if res != .Ok {
		return "has a damaged or incomplete encryption header"
	}
	if h.kind != .Snapshot && h.kind != .Base {
		return "is an encrypted file of another kind"
	}
	key, _ := seal_key_for(h.key_id)
	if key == nil {
		return "was written with another key"
	}
	seal_reading_name = "probe"
	seal.reader_init(sr, fd, seal_file_size(fd), key, header, h.kind, .Closed)
	r.seal = sr
	return ""
}

seal_writer_attach :: proc(w: ^rdb.Writer, sw: ^seal.File_Writer, fd: linux.Fd, kind: seal.Kind, salt: [seal.SALT_SIZE]u8) {
	seal.file_writer_init(sw, fd, &seal_keys.current, kind, salt)
	w.seal = sw
}

seal_writer_close :: proc(w: ^rdb.Writer, sw: ^seal.File_Writer) -> bool {
	if w.seal == nil {
		return !w.failed
	}
	good := rdb.writer_seal_finish(w)
	w.seal = nil
	seal.file_writer_destroy(sw)
	return good
}

seal_manifest_open :: proc(data: ^[dynamic]u8, name: string) -> bool {
	if !seal.looks_encrypted(data[:]) {
		if !seal_on {
			return true
		}
		if len(data) == 0 {
			return true
		}
		if seal_quiet || !seal_plain_allowed() {
			seal_refuse_file("append-only manifest", name, SEAL_TEXT_PLAIN)
			return false
		}
		seal_saw_plain = true
		seal_rewrap_aof = true
		return true
	}
	if !seal_on {
		seal_refuse_file("append-only manifest", name, SEAL_TEXT_NO_KEY)
		return false
	}
	h, res := seal.header_parse(data[:])
	if res != .Ok || h.kind != .Manifest {
		seal_refuse_file("append-only manifest", name, SEAL_TEXT_HEADER)
		return false
	}
	key, use := seal_key_for(h.key_id)
	if key == nil {
		seal_refuse_file("append-only manifest", name, SEAL_TEXT_OTHER_KEY)
		return false
	}
	if len(data) > seal.HEADER_SIZE + seal.MANIFEST_MAX + seal.SEGMENT_OVERHEAD {
		seal_refuse_file("append-only manifest", name, "the encrypted manifest is larger than a manifest can be")
		return false
	}
	plain: [dynamic]u8
	ok, reason := seal.open_whole(key, data[:], .Manifest, &plain)
	if !ok {
		delete(plain)
		seal_refuse_file("append-only manifest", name, "the encrypted manifest cannot be opened: ", reason)
		return false
	}
	if use == .Previous && !seal_quiet {
		seal_saw_previous = true
		seal_rewrap_aof = true
	}
	delete(data^)
	data^ = plain
	return true
}

seal_manifest_seal :: proc(text: []u8, out: ^[dynamic]u8) -> bool {
	return seal.seal_whole(&seal_keys.current, .Manifest, seal_salt(), text, out)
}

seal_hex :: proc(dst: ^[dynamic]u8, b: []u8) {
	digits := "0123456789abcdef"
	for c in b {
		append(dst, digits[c >> 4], digits[c & 15])
	}
}

seal_unhex :: proc(text: []u8, out: []u8) -> bool {
	if len(text) != 2 * len(out) {
		return false
	}
	for i in 0 ..< len(out) {
		hi, ok_hi := seal.hex_digit(text[2 * i])
		lo, ok_lo := seal.hex_digit(text[2 * i + 1])
		if !ok_hi || !ok_lo {
			return false
		}
		out[i] = hi << 4 | lo
	}
	return true
}

@(private = "file")
seal_snapshot_state :: proc() -> (plain: bool, previous: bool) {
	name := persist_filename()
	buf: [PERSIST_PATH_MAX]u8
	fd, err := linux.open(persist_cstr(name, buf[:]), {.CLOEXEC})
	if err != .NONE {
		return false, false
	}
	defer linux.close(fd)
	header, got := seal_header_of(fd)
	if got == 0 {
		return false, false
	}
	if !seal.looks_encrypted(header[:got]) {
		return true, false
	}
	h, res := seal.header_parse(header[:got])
	if res != .Ok {
		return false, false
	}
	_, use := seal_key_for(h.key_id)
	return false, use == .Previous
}

seal_startup_done :: proc() {
	if !seal_on {
		return
	}
	plain, previous := seal_snapshot_state()
	if plain {
		if encryption_adopt_plain {
			seal_saw_plain = true
			seal_rewrap_snapshot = true
		} else {
			plog(LOG_WARNING, "The data file ", persist_filename(), " is not encrypted and this start does not read it; it can hold data from before encryption-key-file was set, so delete it or start once with encryption-adopt-plain yes")
		}
	}
	if previous {
		seal_saw_previous = true
		seal_rewrap_snapshot = true
	}
	if encryption_adopt_plain && !seal_saw_plain {
		seal_refuse_start("encryption-adopt-plain is set but no data file without encryption was found; remove the setting")
	}
	if seal_keys.has_previous && !seal_saw_previous {
		seal_refuse_start("encryption-key-file-previous is set but no data file written with the previous key was found; remove the setting")
	}
	if seal_rewrap_aof && aof.state != .Disabled {
		seal_force_gc = true
		ok := aof_rewrite_sync()
		if ok {
			aof_drain_jobs()
		}
		seal_force_gc = false
		if !ok {
			seal_refuse_start("the append-only file could not be rewritten under the current encryption key; check the lines above")
		}
		plog(LOG_NOTICE, "The append-only file was rewritten under the current encryption key and its older files were removed")
	}
	if seal_rewrap_snapshot {
		if !persist_rdb_save() {
			seal_refuse_start("the data file ", persist_filename(), " could not be saved under the current encryption key; check the lines above")
		}
		plog(LOG_NOTICE, "The data file ", persist_filename(), " was saved again under the current encryption key")
	}
	if seal_saw_plain || seal_saw_previous {
		plog(LOG_WARNING, "Copies and backups of the data files made before this start still hold the data as it was then; delete them, and remove encryption-adopt-plain and encryption-key-file-previous before the next start")
	}
	seal_startup_phase = false
}
