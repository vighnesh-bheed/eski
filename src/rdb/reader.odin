package rdb

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"

READER_BUF :: 1 << 20

SCRATCH_SLOTS :: 4

Status :: enum u8 {
	Ok,
	Empty_Key,
	Short_Read,
	Corrupt,
}

Scratch :: struct {
	data: [^]u8,
	cap:  int,
}

Reader :: struct {
	fd:         linux.Fd,
	from_file:  bool,
	lenient:    bool,
	buf:        [^]u8,
	cap:        int,
	pos:        int,
	end:        int,
	owned:      bool,
	crc:        u64,
	crc_pos:    int,
	checksum:   bool,
	consumed:   i64,
	limit:      i64,
	eof:        bool,
	status:     Status,
	reason:     [512]u8,
	reason_len: int,
	scratch:    [SCRATCH_SLOTS]Scratch,
	lzf_in:     Scratch,
	progress:   proc "contextless" (r: ^Reader),
	next_tick:  i64,
	tick_every: i64,
	user:       rawptr,
}

@(private)
r_alloc :: proc "contextless" (n: int) -> [^]u8 {
	p := ([^]u8)(runtime.heap_alloc(max(n, 1), false))
	if p == nil {
		runtime.panic_contextless("rdb: out of memory")
	}
	return p
}

reader_init_file :: proc "contextless" (r: ^Reader, fd: linux.Fd, checksum: bool) {
	r^ = {}
	r.fd = fd
	r.from_file = true
	r.checksum = checksum
	r.buf = r_alloc(READER_BUF)
	r.cap = READER_BUF
	r.owned = true
}

@(private)
reader_remaining :: proc "contextless" (r: ^Reader) -> i64 {
	if !r.from_file {
		return i64(r.end - r.pos)
	}
	if r.limit > 0 {
		return r.limit - reader_offset(r)
	}
	stat: linux.Stat
	if linux.fstat(r.fd, &stat) != .NONE || .IFREG not_in stat.mode {
		return max(i64)
	}
	position, err := linux.lseek(r.fd, 0, .CUR)
	if err != .NONE {
		return max(i64)
	}
	return i64(stat.size) - position + i64(r.end - r.pos)
}

@(private)
LZF_MAX_RATIO :: 100

reader_init_mem :: proc "contextless" (r: ^Reader, data: []u8, checksum: bool) {
	r^ = {}
	r.fd = -1
	r.buf = raw_data(data)
	r.cap = len(data)
	r.end = len(data)
	r.checksum = checksum
}

reader_destroy :: proc "contextless" (r: ^Reader) {
	if r.owned && r.buf != nil {
		runtime.heap_free(r.buf)
	}
	for &s in r.scratch {
		if s.data != nil {
			runtime.heap_free(s.data)
		}
		s = {}
	}
	if r.lzf_in.data != nil {
		runtime.heap_free(r.lzf_in.data)
	}
	r.lzf_in = {}
	r.buf = nil
	r.owned = false
	r.cap = 0
	r.pos = 0
	r.end = 0
}

reader_offset :: proc "contextless" (r: ^Reader) -> i64 {
	return r.consumed + i64(r.pos)
}

reader_reason :: proc "contextless" (r: ^Reader) -> string {
	return string(r.reason[:r.reason_len])
}

@(private)
reason_append :: proc "contextless" (r: ^Reader, s: string) {
	room := len(r.reason) - r.reason_len
	n := min(room, len(s))
	for i in 0 ..< n {
		r.reason[r.reason_len + i] = s[i]
	}
	r.reason_len += n
}

@(private)
reason_append_u64 :: proc "contextless" (r: ^Reader, v: u64) {
	tmp: [24]u8
	at := len(tmp)
	x := v
	for {
		at -= 1
		tmp[at] = u8(x % 10) + '0'
		x /= 10
		if x == 0 {
			break
		}
	}
	reason_append(r, string(tmp[at:]))
}

corrupt :: proc "contextless" (r: ^Reader, msg: string, num: u64 = 0, with_num: bool = false, tail: string = "") {
	if r.status != .Ok {
		return
	}
	r.status = .Corrupt
	r.reason_len = 0
	reason_append(r, msg)
	if with_num {
		reason_append_u64(r, num)
	}
	reason_append(r, tail)
}

corrupt_append :: proc "contextless" (r: ^Reader, s: string) {
	reason_append(r, s)
}

short_read :: proc "contextless" (r: ^Reader) {
	if r.status != .Ok {
		return
	}
	r.status = .Short_Read
	r.reason_len = 0
	reason_append(r, "Unexpected EOF reading RDB file")
}

ok :: #force_inline proc "contextless" (r: ^Reader) -> bool {
	return r.status == .Ok
}

@(private)
crc_upto_pos :: proc "contextless" (r: ^Reader) {
	if r.checksum && r.pos > r.crc_pos {
		r.crc = crc64(r.crc, r.buf[r.crc_pos:r.pos])
	}
	r.crc_pos = r.pos
}

reader_checksum :: proc "contextless" (r: ^Reader) -> u64 {
	crc_upto_pos(r)
	return r.crc
}

@(private)
fill :: proc "contextless" (r: ^Reader, n: int) -> bool {
	if r.end - r.pos >= n {
		return true
	}
	if !r.from_file || r.eof {
		return false
	}
	crc_upto_pos(r)
	remaining := r.end - r.pos
	if r.pos > 0 {
		if remaining > 0 {
			intrinsics.mem_copy(r.buf, &r.buf[r.pos], remaining)
		}
		r.consumed += i64(r.pos)
		r.pos = 0
		r.end = remaining
		r.crc_pos = 0
	}
	if n > r.cap {
		grown := max(n, r.cap * 2)
		fresh := ([^]u8)(runtime.heap_resize(r.buf, grown))
		if fresh == nil {
			runtime.panic_contextless("rdb: out of memory")
		}
		r.buf = fresh
		r.cap = grown
	}
	for r.end < n {
		want := r.cap - r.end
		if r.limit > 0 {
			allowed := r.limit - (r.consumed + i64(r.end))
			if allowed <= 0 {
				r.eof = true
				break
			}
			want = int(min(i64(want), allowed))
		}
		got, err := linux.read(r.fd, r.buf[r.end:r.end + want])
		if err == .EINTR {
			continue
		}
		if err != .NONE || got <= 0 {
			r.eof = true
			break
		}
		r.end += got
	}
	if r.progress != nil && r.tick_every > 0 && r.consumed >= r.next_tick {
		r.next_tick = r.consumed + r.tick_every
		r.progress(r)
	}
	return r.end - r.pos >= n
}

take :: proc "contextless" (r: ^Reader, n: int) -> ([]u8, bool) {
	if n < 0 {
		corrupt(r, "Invalid length")
		return nil, false
	}
	if !fill(r, n) {
		short_read(r)
		return nil, false
	}
	s := r.buf[r.pos:r.pos + n]
	r.pos += n
	return s, true
}

@(private)
take_into :: proc "contextless" (r: ^Reader, dst: [^]u8, n: int) -> bool {
	done := 0
	for done < n {
		avail := r.end - r.pos
		if avail == 0 {
			if !fill(r, 1) {
				short_read(r)
				return false
			}
			continue
		}
		k := min(avail, n - done)
		intrinsics.mem_copy_non_overlapping(&dst[done], &r.buf[r.pos], k)
		r.pos += k
		done += k
	}
	return true
}

get_u8 :: proc "contextless" (r: ^Reader) -> (u8, bool) {
	if r.end - r.pos < 1 && !fill(r, 1) {
		short_read(r)
		return 0, false
	}
	b := r.buf[r.pos]
	r.pos += 1
	return b, true
}

get_type :: proc "contextless" (r: ^Reader) -> int {
	b, good := get_u8(r)
	if !good {
		return -1
	}
	return int(b)
}

get_len_enc :: proc "contextless" (r: ^Reader) -> (v: u64, encoded: bool, good: bool) {
	first, got := get_u8(r)
	if !got {
		return LENERR, false, false
	}
	switch first >> 6 {
	case LEN_6BIT:
		return u64(first & 63), false, true
	case LEN_14BIT:
		second, more := get_u8(r)
		if !more {
			return LENERR, false, false
		}
		return u64(first & 63) << 8 | u64(second), false, true
	case ENCVAL:
		return u64(first & 63), true, true
	}
	width := 0
	if first == LEN_32BIT {
		width = 4
	} else if first == LEN_64BIT {
		width = 8
	} else {
		corrupt(r, "Unknown length encoding ", u64(first), true, " in rdbLoadLen()")
		return LENERR, false, false
	}
	bytes, more := take(r, width)
	if !more {
		return LENERR, false, false
	}
	for b in bytes {
		v = v << 8 | u64(b)
	}
	return v, false, true
}

get_len :: proc "contextless" (r: ^Reader) -> u64 {
	v, _, good := get_len_enc(r)
	if !good {
		return LENERR
	}
	return v
}

get_ms :: proc "contextless" (r: ^Reader) -> (i64, bool) {
	bytes, good := take(r, 8)
	if !good {
		return 0, false
	}
	v: u64 = 0
	for i in 0 ..< 8 {
		v |= u64(bytes[i]) << (8 * uint(i))
	}
	return i64(v), true
}

get_u32_le :: proc "contextless" (r: ^Reader) -> (u32, bool) {
	bytes, good := take(r, 4)
	if !good {
		return 0, false
	}
	return u32(bytes[0]) | u32(bytes[1]) << 8 | u32(bytes[2]) << 16 | u32(bytes[3]) << 24, true
}

get_double_bin :: proc "contextless" (r: ^Reader) -> (f64, bool) {
	bits, good := get_ms(r)
	if !good {
		return 0, false
	}
	return transmute(f64)u64(bits), true
}

@(private)
scratch_reserve :: proc "contextless" (s: ^Scratch, n: int) -> [^]u8 {
	if s.cap < n || s.data == nil {
		size := max(n, 64)
		if s.cap > 0 && size < s.cap * 2 && s.cap * 2 <= 1 << 26 {
			size = s.cap * 2
		}
		if s.data != nil {
			runtime.heap_free(s.data)
		}
		s.data = r_alloc(size)
		s.cap = size
	}
	return s.data
}

String_Kind :: enum u8 {
	Raw,
	Int,
	Lzf,
}

@(private)
MAX_STRING_BYTES :: u64(1) << 40

get_string_kind :: proc "contextless" (r: ^Reader, slot: int) -> (out: []u8, ival: i64, kind: String_Kind, good: bool) {
	index := slot if slot >= 0 && slot < SCRATCH_SLOTS else 0
	v, encoded, got := get_len_enc(r)
	if !got {
		return
	}
	if !encoded {
		if v > MAX_STRING_BYTES {
			corrupt(r, "Invalid string length ", v, true)
			return
		}
		if v > READER_BUF && i64(v) > reader_remaining(r) {
			short_read(r)
			return
		}
		n := int(v)
		if !r.from_file {
			s, taken := take(r, n)
			if !taken {
				return
			}
			return s, 0, .Raw, true
		}
		dst := scratch_reserve(&r.scratch[index], n)
		if !take_into(r, dst, n) {
			return
		}
		return dst[:n], 0, .Raw, true
	}
	switch v {
	case ENC_INT8:
		b, more := get_u8(r)
		if !more {
			return
		}
		ival = i64(i8(b))
	case ENC_INT16:
		bytes, more := take(r, 2)
		if !more {
			return
		}
		ival = i64(i16(u16(bytes[0]) | u16(bytes[1]) << 8))
	case ENC_INT32:
		bytes, more := take(r, 4)
		if !more {
			return
		}
		ival = i64(i32(u32(bytes[0]) | u32(bytes[1]) << 8 | u32(bytes[2]) << 16 | u32(bytes[3]) << 24))
	case ENC_LZF:
		clen := get_len(r)
		if !ok(r) {
			return
		}
		olen := get_len(r)
		if !ok(r) {
			return
		}
		if clen == 0 || olen == 0 || clen > MAX_STRING_BYTES || olen > MAX_STRING_BYTES || olen > clen * LZF_MAX_RATIO + 64 {
			corrupt(r, "Invalid LZF compressed string")
			return
		}
		if clen > READER_BUF && i64(clen) > reader_remaining(r) {
			short_read(r)
			return
		}
		packed: []u8
		if !r.from_file {
			s, taken := take(r, int(clen))
			if !taken {
				return
			}
			packed = s
		} else {
			src := scratch_reserve(&r.lzf_in, int(clen))
			if !take_into(r, src, int(clen)) {
				return
			}
			packed = src[:int(clen)]
		}
		dst := scratch_reserve(&r.scratch[index], int(olen))
		if lzf_decompress(packed, dst[:int(olen)]) != int(olen) {
			corrupt(r, "Invalid LZF compressed string")
			return
		}
		return dst[:int(olen)], 0, .Lzf, true
	case:
		corrupt(r, "Unknown RDB string encoding type ", v, true)
		return
	}
	dst := scratch_reserve(&r.scratch[index], 24)
	n := ll2string(dst[:24], ival)
	return dst[:n], ival, .Int, true
}

get_string :: proc "contextless" (r: ^Reader, slot: int) -> ([]u8, bool) {
	out, _, _, good := get_string_kind(r, slot)
	return out, good
}

get_double_str :: proc "contextless" (r: ^Reader) -> (f64, bool) {
	n, got := get_u8(r)
	if !got {
		return 0, false
	}
	switch n {
	case 253:
		return transmute(f64)u64(0x7FF8000000000000), true
	case 254:
		return transmute(f64)u64(0x7FF0000000000000), true
	case 255:
		return transmute(f64)u64(0xFFF0000000000000), true
	}
	text, taken := take(r, int(n))
	if !taken {
		return 0, false
	}
	value, parsed := parse_text_score(text)
	if !parsed {
		blank := true
		for c in text {
			if !is_c_space(c) {
				blank = false
				break
			}
		}
		if blank {
			r.status = .Short_Read
			return 0, false
		}
		corrupt(r, "Invalid double value")
		return 0, false
	}
	return value, true
}
