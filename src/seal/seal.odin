package seal

import "base:runtime"
import "core:crypto"
import "core:crypto/aes"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:sys/linux"

MAGIC :: "ESKIENC1"

HEADER_SIZE :: 58

KEY_SIZE :: 32

KEY_ID_SIZE :: 16

SALT_SIZE :: 32

NONCE_SIZE :: 12

TAG_SIZE :: 16

LENGTH_SIZE :: 4

SEGMENT_OVERHEAD :: LENGTH_SIZE + TAG_SIZE

SEGMENT_MAX :: 64 * 1024

MANIFEST_MAX :: 1 << 20

LENGTH_MASK :: u32(0x7fff_ffff)

CONTINUES :: u32(0x8000_0000)

ALGORITHM_AES_256_GCM :: u8(1)

FLAG_LAST :: u8(1)

INFO_KEY_ID :: "eski key id v1"

INFO_SNAPSHOT :: "eski snapshot v1"

INFO_APPEND :: "eski append v1"

INFO_MANIFEST :: "eski manifest v1"

Kind :: enum u8 {
	None        = 0,
	Snapshot    = 1,
	Base        = 2,
	Incremental = 3,
	Manifest    = 4,
}

Key :: struct {
	bytes: [KEY_SIZE]u8,
	id:    [KEY_ID_SIZE]u8,
}

Header :: struct {
	kind:      Kind,
	algorithm: u8,
	key_id:    [KEY_ID_SIZE]u8,
	salt:      [SALT_SIZE]u8,
}

Header_Result :: enum u8 {
	Ok,
	Not_Encrypted,
	Short,
	Bad_Kind,
	Bad_Algorithm,
}

kind_info :: proc "contextless" (kind: Kind) -> string {
	#partial switch kind {
	case .Snapshot:
		return INFO_SNAPSHOT
	case .Base, .Incremental:
		return INFO_APPEND
	case .Manifest:
		return INFO_MANIFEST
	}
	return ""
}

zero :: proc "contextless" (p: rawptr, n: int) {
	crypto.zero_explicit(p, n)
}

derive :: proc "contextless" (master: []u8, salt: []u8, info: string, out: []u8) {
	context = runtime.default_context()
	hkdf.extract_and_expand(hash.Algorithm.SHA256, salt, master, transmute([]u8)info, out)
}

key_set_id :: proc "contextless" (k: ^Key) {
	nothing: [SALT_SIZE]u8
	derive(k.bytes[:], nothing[:], INFO_KEY_ID, k.id[:])
}

hex_digit :: proc "contextless" (c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

key_parse :: proc "contextless" (text: []u8, k: ^Key) -> bool {
	body := text
	if len(body) == 2 * KEY_SIZE + 1 && body[len(body) - 1] == '\n' {
		body = body[:len(body) - 1]
	}
	if len(body) != 2 * KEY_SIZE {
		return false
	}
	for i in 0 ..< KEY_SIZE {
		hi, ok_hi := hex_digit(body[2 * i])
		lo, ok_lo := hex_digit(body[2 * i + 1])
		if !ok_hi || !ok_lo {
			zero(&k.bytes, KEY_SIZE)
			return false
		}
		k.bytes[i] = hi << 4 | lo
	}
	key_set_id(k)
	return true
}

key_wipe :: proc "contextless" (k: ^Key) {
	zero(k, size_of(Key))
}

salt_draw :: proc "contextless" (salt: ^[SALT_SIZE]u8) {
	runtime.rand_bytes(salt[:])
}

header_bytes :: proc "contextless" (h: Header) -> (out: [HEADER_SIZE]u8) {
	magic := MAGIC
	for i in 0 ..< len(magic) {
		out[i] = magic[i]
	}
	out[8] = u8(h.kind)
	out[9] = h.algorithm
	for i in 0 ..< KEY_ID_SIZE {
		out[10 + i] = h.key_id[i]
	}
	for i in 0 ..< SALT_SIZE {
		out[26 + i] = h.salt[i]
	}
	return
}

looks_encrypted :: proc "contextless" (b: []u8) -> bool {
	magic := MAGIC
	n := min(len(b), len(magic))
	if n == 0 {
		return false
	}
	for i in 0 ..< n {
		if b[i] != magic[i] {
			return false
		}
	}
	return true
}

header_parse :: proc "contextless" (b: []u8) -> (h: Header, res: Header_Result) {
	if !looks_encrypted(b) {
		return h, .Not_Encrypted
	}
	if len(b) < HEADER_SIZE {
		return h, .Short
	}
	k := b[8]
	if k < u8(Kind.Snapshot) || k > u8(Kind.Manifest) {
		return h, .Bad_Kind
	}
	h.kind = Kind(k)
	h.algorithm = b[9]
	if h.algorithm != ALGORITHM_AES_256_GCM {
		return h, .Bad_Algorithm
	}
	for i in 0 ..< KEY_ID_SIZE {
		h.key_id[i] = b[10 + i]
	}
	for i in 0 ..< SALT_SIZE {
		h.salt[i] = b[26 + i]
	}
	return h, .Ok
}

same_key_id :: proc "contextless" (a: [KEY_ID_SIZE]u8, b: [KEY_ID_SIZE]u8) -> bool {
	diff: u8 = 0
	for i in 0 ..< KEY_ID_SIZE {
		diff |= a[i] ~ b[i]
	}
	return diff == 0
}

nonce_of :: proc "contextless" (index: u64, last: bool) -> (n: [NONCE_SIZE]u8) {
	for i in 0 ..< 8 {
		n[i] = u8(index >> (8 * uint(i)))
	}
	n[8] = FLAG_LAST if last else 0
	return
}

length_word :: proc "contextless" (n: int, continues: bool) -> (w: [LENGTH_SIZE]u8) {
	v := u32(n) & LENGTH_MASK
	if continues {
		v |= CONTINUES
	}
	for i in 0 ..< LENGTH_SIZE {
		w[i] = u8(v >> (8 * uint(i)))
	}
	return
}

length_value :: proc "contextless" (b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

aad_of :: proc "contextless" (header: ^[HEADER_SIZE]u8, word: []u8) -> (a: [HEADER_SIZE + LENGTH_SIZE]u8) {
	for i in 0 ..< HEADER_SIZE {
		a[i] = header[i]
	}
	for i in 0 ..< LENGTH_SIZE {
		a[HEADER_SIZE + i] = word[i]
	}
	return
}

Sealer :: struct {
	gcm:    aes.Context_GCM,
	header: [HEADER_SIZE]u8,
	salt:   [SALT_SIZE]u8,
	kind:   Kind,
	limit:  int,
	index:  u64,
	closed: bool,
	ready:  bool,
}

sealer_init :: proc "contextless" (s: ^Sealer, key: ^Key, kind: Kind, salt: [SALT_SIZE]u8) {
	context = runtime.default_context()
	sealer_destroy(s)
	s.kind = kind
	s.salt = salt
	s.limit = MANIFEST_MAX if kind == .Manifest else SEGMENT_MAX
	s.header = header_bytes(Header{kind = kind, algorithm = ALGORITHM_AES_256_GCM, key_id = key.id, salt = salt})
	file_key: [KEY_SIZE]u8
	derive(key.bytes[:], s.salt[:], kind_info(kind), file_key[:])
	aes.init_gcm(&s.gcm, file_key[:])
	zero(&file_key, KEY_SIZE)
	s.index = 0
	s.closed = false
	s.ready = true
}

sealer_destroy :: proc "contextless" (s: ^Sealer) {
	if s.ready {
		aes.reset_gcm(&s.gcm)
	}
	zero(s, size_of(Sealer))
}

seal_segment_into :: proc "contextless" (s: ^Sealer, plain: []u8, out: []u8, last: bool, continues: bool) -> bool {
	n := len(plain)
	if !s.ready || s.closed || n > s.limit || len(out) != n + SEGMENT_OVERHEAD || (last && continues) {
		return false
	}
	context = runtime.default_context()
	word := length_word(n, continues)
	for i in 0 ..< LENGTH_SIZE {
		out[i] = word[i]
	}
	aad := aad_of(&s.header, word[:])
	nonce := nonce_of(s.index, last)
	aes.seal_gcm(&s.gcm, out[LENGTH_SIZE:][:n], out[LENGTH_SIZE + n:][:TAG_SIZE], nonce[:], aad[:], plain)
	s.index += 1
	if last {
		s.closed = true
	}
	return true
}

seal_segment :: proc(s: ^Sealer, plain: []u8, out: ^[dynamic]u8, last: bool, continues: bool) -> bool {
	start := len(out)
	resize(out, start + len(plain) + SEGMENT_OVERHEAD)
	if !seal_segment_into(s, plain, out[start:], last, continues) {
		resize(out, start)
		return false
	}
	return true
}

seal_batch :: proc(s: ^Sealer, plain: []u8, out: ^[dynamic]u8) -> bool {
	rest := plain
	for len(rest) > 0 {
		n := min(len(rest), s.limit)
		if !seal_segment(s, rest[:n], out, false, n < len(rest)) {
			return false
		}
		rest = rest[n:]
	}
	return true
}

seal_whole :: proc(key: ^Key, kind: Kind, salt: [SALT_SIZE]u8, plain: []u8, out: ^[dynamic]u8) -> bool {
	s: Sealer
	sealer_init(&s, key, kind, salt)
	defer sealer_destroy(&s)
	if len(plain) > s.limit {
		return false
	}
	append(out, ..s.header[:])
	return seal_segment(&s, plain, out, true, false)
}

write_all :: proc "contextless" (fd: linux.Fd, data: []u8) -> (written: int, err: linux.Errno) {
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

File_Writer :: struct {
	s:         Sealer,
	fd:        linux.Fd,
	plain:     [^]u8,
	plain_len: int,
	out:       [^]u8,
	started:   bool,
	failed:    bool,
	errno:     linux.Errno,
	written:   i64,
}

@(private)
buffer_alloc :: proc "contextless" (n: int) -> [^]u8 {
	p := ([^]u8)(runtime.heap_alloc(n, false))
	if p == nil {
		runtime.panic_contextless("seal: out of memory")
	}
	return p
}

@(private)
buffer_free :: proc "contextless" (p: [^]u8, n: int) {
	if p != nil {
		zero(p, n)
		runtime.heap_free(p)
	}
}

file_writer_init :: proc "contextless" (w: ^File_Writer, fd: linux.Fd, key: ^Key, kind: Kind, salt: [SALT_SIZE]u8) {
	w^ = {}
	w.fd = fd
	sealer_init(&w.s, key, kind, salt)
	w.plain = buffer_alloc(SEGMENT_MAX)
	w.out = buffer_alloc(SEGMENT_MAX + SEGMENT_OVERHEAD)
}

file_writer_destroy :: proc "contextless" (w: ^File_Writer) {
	buffer_free(w.plain, SEGMENT_MAX)
	buffer_free(w.out, SEGMENT_MAX + SEGMENT_OVERHEAD)
	sealer_destroy(&w.s)
	w^ = {}
}

@(private)
file_put :: proc "contextless" (w: ^File_Writer, data: []u8) {
	if w.failed {
		return
	}
	n, err := write_all(w.fd, data)
	w.written += i64(n)
	if err != .NONE {
		w.failed = true
		w.errno = err
	}
}

@(private)
file_start :: proc "contextless" (w: ^File_Writer) {
	if !w.started {
		w.started = true
		file_put(w, w.s.header[:])
	}
}

@(private)
file_emit :: proc "contextless" (w: ^File_Writer, last: bool) {
	out := w.out[:w.plain_len + SEGMENT_OVERHEAD]
	if !seal_segment_into(&w.s, w.plain[:w.plain_len], out, last, false) {
		w.failed = true
		w.errno = .EINVAL
		return
	}
	w.plain_len = 0
	file_put(w, out)
}

file_write :: proc "contextless" (w: ^File_Writer, data: []u8) -> bool {
	file_start(w)
	rest := data
	for len(rest) > 0 && !w.failed {
		if w.plain_len == SEGMENT_MAX {
			file_emit(w, false)
			continue
		}
		n := min(SEGMENT_MAX - w.plain_len, len(rest))
		runtime.mem_copy_non_overlapping(&w.plain[w.plain_len], raw_data(rest), n)
		w.plain_len += n
		rest = rest[n:]
	}
	return !w.failed
}

file_finish :: proc "contextless" (w: ^File_Writer) -> bool {
	file_start(w)
	if !w.failed {
		file_emit(w, true)
	}
	return !w.failed
}

Mode :: enum u8 {
	Closed,
	Live,
	Bounded,
}

State :: enum u8 {
	Open,
	End,
	Torn,
	Damaged,
	Failed,
}

File_Reader :: struct {
	gcm:       aes.Context_GCM,
	header:    [HEADER_SIZE]u8,
	kind:      Kind,
	mode:      Mode,
	fd:        linux.Fd,
	size:      i64,
	offset:    i64,
	index:     u64,
	cipher:    [^]u8,
	plain:     [^]u8,
	plain_pos: int,
	plain_len: int,
	plain_off: i64,
	state:     State,
	closed:    bool,
	batch_end: i64,
	segment:   u64,
	cut:       i64,
	reason:    string,
	errno:     linux.Errno,
	ready:     bool,
	on_fail:   proc "contextless" (r: ^File_Reader),
	user:      rawptr,
}

reader_init :: proc "contextless" (r: ^File_Reader, fd: linux.Fd, size: i64, key: ^Key, header: [HEADER_SIZE]u8, kind: Kind, mode: Mode) {
	context = runtime.default_context()
	r^ = {}
	r.fd = fd
	r.size = size
	r.header = header
	hdr := header
	r.kind = kind
	r.mode = mode
	r.offset = HEADER_SIZE
	r.batch_end = HEADER_SIZE
	salt := hdr[26:][:SALT_SIZE]
	file_key: [KEY_SIZE]u8
	derive(key.bytes[:], salt, kind_info(kind), file_key[:])
	aes.init_gcm(&r.gcm, file_key[:])
	zero(&file_key, KEY_SIZE)
	r.cipher = buffer_alloc(SEGMENT_MAX + SEGMENT_OVERHEAD)
	r.plain = buffer_alloc(SEGMENT_MAX)
	r.ready = true
	if size < HEADER_SIZE {
		reader_fail(r, .Torn, "the file ends inside its encryption header")
		r.cut = 0
	}
}

reader_destroy :: proc "contextless" (r: ^File_Reader) {
	if r.ready {
		aes.reset_gcm(&r.gcm)
	}
	buffer_free(r.cipher, SEGMENT_MAX + SEGMENT_OVERHEAD)
	buffer_free(r.plain, SEGMENT_MAX)
	r.cipher = nil
	r.plain = nil
	r.ready = false
}

@(private)
reader_fail :: proc "contextless" (r: ^File_Reader, state: State, reason: string) {
	if r.state != .Open {
		return
	}
	r.state = state
	r.reason = reason
	r.segment = r.index
	r.cut = r.offset
	if r.on_fail != nil {
		r.on_fail(r)
	}
}

@(private)
read_at :: proc "contextless" (r: ^File_Reader, dst: []u8, at: i64) -> bool {
	done := 0
	for done < len(dst) {
		n, err := linux.pread(r.fd, dst[done:], at + i64(done))
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			r.errno = err
			reader_fail(r, .Failed, "the file cannot be read")
			return false
		}
		if n <= 0 {
			r.errno = .EIO
			reader_fail(r, .Failed, "the file became shorter while it was read")
			return false
		}
		done += n
	}
	return true
}

@(private)
batch_complete :: proc "contextless" (r: ^File_Reader) -> (complete: bool, ok: bool) {
	at := r.offset
	for {
		if r.size - at < LENGTH_SIZE {
			return false, true
		}
		word: [LENGTH_SIZE]u8
		if !read_at(r, word[:], at) {
			return false, false
		}
		v := length_value(word[:])
		n := i64(v & LENGTH_MASK)
		if n > SEGMENT_MAX {
			reader_fail(r, .Damaged, "a segment declares a length above the limit")
			return false, false
		}
		next := at + LENGTH_SIZE + n + TAG_SIZE
		if next > r.size {
			return false, true
		}
		if v & CONTINUES == 0 {
			r.batch_end = next
			return true, true
		}
		at = next
	}
}

@(private)
reader_next :: proc "contextless" (r: ^File_Reader) -> bool {
	context = runtime.default_context()
	if r.state != .Open {
		return false
	}
	if r.offset == r.size {
		if r.closed || r.mode != .Closed {
			r.state = .End
			r.cut = r.offset
			return false
		}
		reader_fail(r, .Torn, "the file ends before its closing segment")
		return false
	}
	if r.closed {
		reader_fail(r, .Damaged, "bytes follow the closing segment")
		return false
	}
	rest := r.size - r.offset
	if rest < SEGMENT_OVERHEAD {
		reader_fail(r, .Torn, "the last segment is incomplete")
		return false
	}
	word: [LENGTH_SIZE]u8
	if !read_at(r, word[:], r.offset) {
		return false
	}
	v := length_value(word[:])
	n := int(v & LENGTH_MASK)
	continues := v & CONTINUES != 0
	if n > SEGMENT_MAX {
		reader_fail(r, .Damaged, "a segment declares a length above the limit")
		return false
	}
	if rest < i64(n + SEGMENT_OVERHEAD) {
		reader_fail(r, .Torn, "the last segment is incomplete")
		return false
	}
	if continues && r.kind != .Incremental {
		reader_fail(r, .Damaged, "a segment of a closed file is marked as continued")
		return false
	}
	if continues && r.offset >= r.batch_end {
		complete, good := batch_complete(r)
		if !good {
			return false
		}
		if !complete {
			if r.mode == .Live {
				reader_fail(r, .Torn, "the last write batch is incomplete")
			} else {
				reader_fail(r, .Damaged, "a write batch is incomplete")
			}
			return false
		}
	}
	whole := r.cipher[:n + SEGMENT_OVERHEAD]
	if !read_at(r, whole, r.offset) {
		return false
	}
	aad := aad_of(&r.header, whole[:LENGTH_SIZE])
	ct := whole[LENGTH_SIZE:][:n]
	tag := whole[LENGTH_SIZE + n:][:TAG_SIZE]
	last := false
	nonce := nonce_of(r.index, false)
	if !aes.open_gcm(&r.gcm, r.plain[:n], nonce[:], aad[:], ct, tag) {
		nonce = nonce_of(r.index, true)
		if !aes.open_gcm(&r.gcm, r.plain[:n], nonce[:], aad[:], ct, tag) {
			reader_fail(r, .Damaged, "a segment fails its authentication check")
			return false
		}
		last = true
	}
	if last && continues {
		reader_fail(r, .Damaged, "the closing segment is marked as continued")
		return false
	}
	r.offset += i64(n + SEGMENT_OVERHEAD)
	r.index += 1
	r.plain_off += i64(r.plain_len)
	r.plain_pos = 0
	r.plain_len = n
	if last {
		r.closed = true
		if r.offset != r.size {
			r.offset -= i64(n + SEGMENT_OVERHEAD)
			r.index -= 1
			r.plain_len = 0
			reader_fail(r, .Damaged, "bytes follow the closing segment")
			return false
		}
	}
	return true
}

read :: proc "contextless" (r: ^File_Reader, dst: []u8) -> int {
	done := 0
	for done < len(dst) {
		if r.plain_pos == r.plain_len {
			if !reader_next(r) {
				break
			}
			continue
		}
		k := min(len(dst) - done, r.plain_len - r.plain_pos)
		runtime.mem_copy_non_overlapping(&dst[done], &r.plain[r.plain_pos], k)
		r.plain_pos += k
		done += k
	}
	return done
}

peek :: proc "contextless" (r: ^File_Reader, n: int) -> []u8 {
	for r.plain_pos == r.plain_len {
		if !reader_next(r) {
			return nil
		}
	}
	return r.plain[r.plain_pos:][:min(n, r.plain_len - r.plain_pos)]
}

buffered :: proc "contextless" (r: ^File_Reader) -> i64 {
	return i64(r.plain_len - r.plain_pos)
}

remaining_bound :: proc "contextless" (r: ^File_Reader) -> i64 {
	return max(r.size - r.offset, 0) + buffered(r)
}

plain_offset :: proc "contextless" (r: ^File_Reader) -> i64 {
	return r.plain_off + i64(r.plain_pos)
}

finish :: proc "contextless" (r: ^File_Reader) -> bool {
	if buffered(r) > 0 {
		reader_fail(r, .Damaged, "decrypted bytes follow the end of the data")
		return false
	}
	for r.state == .Open {
		if reader_next(r) && r.plain_len > 0 {
			reader_fail(r, .Damaged, "decrypted bytes follow the end of the data")
			return false
		}
	}
	return r.state == .End
}

open_whole :: proc(key: ^Key, data: []u8, kind: Kind, out: ^[dynamic]u8) -> (ok: bool, reason: string) {
	h, res := header_parse(data)
	if res != .Ok || h.kind != kind {
		return false, "the file is not an encrypted file of the expected kind"
	}
	if !same_key_id(h.key_id, key.id) {
		return false, "the file was written with another key"
	}
	rest := data[HEADER_SIZE:]
	if len(rest) < SEGMENT_OVERHEAD {
		return false, "the file ends before its closing segment"
	}
	v := length_value(rest[:LENGTH_SIZE])
	n := int(v & LENGTH_MASK)
	limit := MANIFEST_MAX if kind == .Manifest else SEGMENT_MAX
	if v & CONTINUES != 0 || n > limit || len(rest) != n + SEGMENT_OVERHEAD {
		return false, "the file does not hold exactly one closing segment"
	}
	context = runtime.default_context()
	gcm: aes.Context_GCM
	file_key: [KEY_SIZE]u8
	derive(key.bytes[:], h.salt[:], kind_info(kind), file_key[:])
	aes.init_gcm(&gcm, file_key[:])
	zero(&file_key, KEY_SIZE)
	defer aes.reset_gcm(&gcm)
	header: [HEADER_SIZE]u8
	for i in 0 ..< HEADER_SIZE {
		header[i] = data[i]
	}
	aad := aad_of(&header, rest[:LENGTH_SIZE])
	nonce := nonce_of(0, true)
	start := len(out)
	resize(out, start + n)
	if !aes.open_gcm(&gcm, out[start:][:n], nonce[:], aad[:], rest[LENGTH_SIZE:][:n], rest[LENGTH_SIZE + n:][:TAG_SIZE]) {
		resize(out, start)
		return false, "the file fails its authentication check"
	}
	return true, ""
}
