package rdb

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"

WRITER_BUF :: 1 << 20

WRITER_DIRECT :: 256 << 10

Writer :: struct {
	fd:         linux.Fd,
	to_file:    bool,
	buf:        [^]u8,
	len:        int,
	cap:        int,
	crc_pos:    int,
	crc:        u64,
	checksum:   bool,
	compress:   bool,
	flushed:    i64,
	failed:     bool,
	errno:      linux.Errno,
	lzf_buf:    [^]u8,
	lzf_cap:    int,
	lzf_context: Lzf_Context,
	sync_every: i64,
	synced:     i64,
}

@(private)
w_alloc :: proc "contextless" (n: int) -> [^]u8 {
	p := ([^]u8)(runtime.heap_alloc(max(n, 1), false))
	if p == nil {
		runtime.panic_contextless("rdb: out of memory")
	}
	return p
}

writer_init_file :: proc "contextless" (w: ^Writer, fd: linux.Fd, compress: bool, checksum: bool) {
	w^ = {}
	w.fd = fd
	w.to_file = true
	w.buf = w_alloc(WRITER_BUF)
	w.cap = WRITER_BUF
	w.compress = compress
	w.checksum = checksum
}

writer_init_mem :: proc "contextless" (w: ^Writer, compress: bool, checksum: bool, initial: int = 4096) {
	w^ = {}
	w.fd = -1
	w.cap = max(initial, 64)
	w.buf = w_alloc(w.cap)
	w.compress = compress
	w.checksum = checksum
}

writer_destroy :: proc "contextless" (w: ^Writer) {
	lzf_context_destroy(&w.lzf_context)
	if w.buf != nil {
		runtime.heap_free(w.buf)
	}
	if w.lzf_buf != nil {
		runtime.heap_free(w.lzf_buf)
	}
	w.buf = nil
	w.lzf_buf = nil
	w.len = 0
	w.cap = 0
	w.lzf_cap = 0
	w.crc_pos = 0
}

writer_bytes :: proc "contextless" (w: ^Writer) -> []u8 {
	return w.buf[:w.len]
}

writer_processed :: proc "contextless" (w: ^Writer) -> i64 {
	return w.flushed + i64(w.len)
}

@(private)
crc_catch_up :: proc "contextless" (w: ^Writer) {
	if w.checksum && w.len > w.crc_pos {
		w.crc = crc64(w.crc, w.buf[w.crc_pos:w.len])
	}
	w.crc_pos = w.len
}

@(private)
write_all :: proc "contextless" (w: ^Writer, data: []u8) {
	rest := data
	for len(rest) > 0 && !w.failed {
		n, err := linux.write(w.fd, rest)
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			w.failed = true
			w.errno = err
			return
		}
		if n <= 0 {
			w.failed = true
			w.errno = .ENOSPC
			return
		}
		rest = rest[n:]
	}
}

@(private)
sync_if_due :: proc "contextless" (w: ^Writer) {
	if w.sync_every > 0 && !w.failed && w.flushed - w.synced >= w.sync_every {
		linux.fdatasync(w.fd)
		w.synced = w.flushed
	}
}

writer_flush :: proc "contextless" (w: ^Writer) -> bool {
	if !w.to_file {
		return !w.failed
	}
	crc_catch_up(w)
	if w.len > 0 {
		write_all(w, w.buf[:w.len])
		w.flushed += i64(w.len)
		w.len = 0
		w.crc_pos = 0
		sync_if_due(w)
	}
	return !w.failed
}

@(private)
grow :: proc "contextless" (w: ^Writer, need: int) {
	if w.to_file {
		writer_flush(w)
		if need <= w.cap {
			return
		}
	}
	size := max(w.cap * 2, w.len + need, 64)
	fresh := ([^]u8)(runtime.heap_resize(w.buf, size))
	if fresh == nil {
		runtime.panic_contextless("rdb: out of memory")
	}
	w.buf = fresh
	w.cap = size
}

put_raw :: proc "contextless" (w: ^Writer, data: []u8) {
	n := len(data)
	if n == 0 {
		return
	}
	if w.to_file && n >= WRITER_DIRECT {
		writer_flush(w)
		if w.checksum {
			w.crc = crc64(w.crc, data)
		}
		write_all(w, data)
		w.flushed += i64(n)
		sync_if_due(w)
		return
	}
	if w.len + n > w.cap {
		grow(w, n)
	}
	intrinsics.mem_copy_non_overlapping(&w.buf[w.len], raw_data(data), n)
	w.len += n
}

put_u8 :: proc "contextless" (w: ^Writer, b: u8) {
	if w.len + 1 > w.cap {
		grow(w, 1)
	}
	w.buf[w.len] = b
	w.len += 1
}

put_type :: put_u8

put_len :: proc "contextless" (w: ^Writer, n: u64) {
	tmp: [9]u8
	size := 0
	switch {
	case n < 1 << 6:
		tmp[0] = u8(n)
		size = 1
	case n < 1 << 14:
		tmp[0] = u8(n >> 8) | (LEN_14BIT << 6)
		tmp[1] = u8(n)
		size = 2
	case n <= u64(max(u32)):
		tmp[0] = LEN_32BIT
		for i in 0 ..< 4 {
			tmp[1 + i] = u8(n >> (8 * uint(3 - i)))
		}
		size = 5
	case:
		tmp[0] = LEN_64BIT
		for i in 0 ..< 8 {
			tmp[1 + i] = u8(n >> (8 * uint(7 - i)))
		}
		size = 9
	}
	put_raw(w, tmp[:size])
}

put_ms :: proc "contextless" (w: ^Writer, t: i64) {
	tmp: [8]u8
	v := u64(t)
	for i in 0 ..< 8 {
		tmp[i] = u8(v >> (8 * uint(i)))
	}
	put_raw(w, tmp[:])
}

put_double_bin :: proc "contextless" (w: ^Writer, d: f64) {
	put_ms(w, i64(transmute(u64)d))
}

put_lzf_blob :: proc "contextless" (w: ^Writer, data: []u8, uncompressed_len: int) {
	put_u8(w, 0xC0 | ENC_LZF)
	put_len(w, u64(len(data)))
	put_len(w, u64(uncompressed_len))
	put_raw(w, data)
}

@(private)
COMPRESS_FROM_BYTES :: 21

@(private)
COMPRESS_HEADROOM :: 4

@(private)
lzf_scratch :: proc "contextless" (w: ^Writer, room: int) -> []u8 {
	if room > w.lzf_cap {
		if w.lzf_buf != nil {
			runtime.heap_free(w.lzf_buf)
		}
		w.lzf_cap = max(room, 4096)
		w.lzf_buf = w_alloc(w.lzf_cap)
	}
	return w.lzf_buf[:room]
}

@(private)
put_lzf_string :: proc "contextless" (w: ^Writer, s: []u8) -> bool {
	if len(s) < COMPRESS_FROM_BYTES {
		return false
	}
	out := lzf_scratch(w, len(s) - COMPRESS_HEADROOM)
	packed := lzf_compress_with_context(&w.lzf_context, s, out)
	if packed > 0 {
		put_lzf_blob(w, out[:packed], len(s))
	}
	return packed > 0
}

@(private)
put_short_integer :: proc "contextless" (w: ^Writer, s: []u8) -> bool {
	if len(s) == 0 || len(s) > 11 {
		return false
	}
	value, numeric := string2ll(s)
	if !numeric {
		return false
	}
	packed: [5]u8
	width := encode_integer(value, &packed)
	if width > 0 {
		put_raw(w, packed[:width])
	}
	return width > 0
}

put_string :: proc "contextless" (w: ^Writer, s: []u8) {
	if !put_short_integer(w, s) && !(w.compress && put_lzf_string(w, s)) {
		put_len(w, u64(len(s)))
		put_raw(w, s)
	}
}

put_ll_string :: proc "contextless" (w: ^Writer, v: i64) {
	enc: [5]u8
	n := encode_integer(v, &enc)
	if n > 0 {
		put_raw(w, enc[:n])
		return
	}
	text: [24]u8
	k := ll2string(text[:], v)
	put_len(w, u64(k))
	put_raw(w, text[:k])
}

put_aux :: proc "contextless" (w: ^Writer, key: string, val: []u8) {
	put_u8(w, OPCODE_AUX)
	put_string(w, transmute([]u8)key)
	put_string(w, val)
}

put_aux_int :: proc "contextless" (w: ^Writer, key: string, v: i64) {
	put_u8(w, OPCODE_AUX)
	put_string(w, transmute([]u8)key)
	put_ll_string(w, v)
}

put_header :: proc "contextless" (w: ^Writer, ctime: i64, used_mem: i64, aof_base: bool) {
	magic: [9]u8 = {'R', 'E', 'D', 'I', 'S', '0', '0', '0', '0'}
	version := RDB_VERSION
	for i := 8; i >= 5 && version > 0; i -= 1 {
		magic[i] = u8('0' + version % 10)
		version /= 10
	}
	put_raw(w, magic[:])
	put_aux(w, "redis-ver", transmute([]u8)string(WRITER_VERSION_TEXT))
	put_aux_int(w, "redis-bits", 64)
	put_aux_int(w, "ctime", ctime)
	put_aux_int(w, "used-mem", used_mem)
	put_aux_int(w, "aof-base", 1 if aof_base else 0)
}

writer_checksum :: proc "contextless" (w: ^Writer) -> u64 {
	crc_catch_up(w)
	return w.crc
}

put_trailer :: proc "contextless" (w: ^Writer) {
	put_u8(w, OPCODE_EOF)
	sum: u64 = 0
	if w.checksum {
		sum = writer_checksum(w)
	}
	put_ms(w, i64(sum))
}
