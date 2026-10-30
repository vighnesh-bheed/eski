package main

import "base:intrinsics"
import "base:runtime"
import "fpconv"

MBULK_MAX :: 2147483647

Parse_Result :: enum u8 {
	Incomplete,
	Command,
	Error,
}

argv_buf: [][]u8
argc: int

wbuf_grow :: proc(c: ^Conn, n: int) {
	if c.wpos > 0 {
		rem := c.wlen - c.wpos
		if rem > 0 {
			intrinsics.mem_copy(c.wbuf, &c.wbuf[c.wpos], rem)
		}
		c.wlen = rem
		c.wpos = 0
		if c.wlen + n <= c.wcap {
			return
		}
	}
	floor := 256 if lua_effect_owner(c) else WBUF_INIT
	newcap := max(c.wcap * 2, c.wlen + n, floor)
	newcap = min(newcap, lua_capture_capacity(c))
	stat_reply_buffer_expands += 1
	c.wbuf = ([^]u8)(runtime.heap_resize(c.wbuf, newcap))
	if c.fd >= 0 {
		conn_mem += newcap - c.wcap
	}
	c.wcap = newcap
}

wb_reserve :: #force_inline proc(c: ^Conn, n: int) -> [^]u8 #no_bounds_check {
	if c.wlen + n > c.wcap {
		wbuf_grow(c, n)
	}
	return &c.wbuf[c.wlen]
}


RESP2 :: 2
RESP3 :: 3

@(private = "file")
reply_raw :: proc(c: ^Conn, s: []u8) #no_bounds_check {
	n := len(s)
	if n == 0 {
		return
	}
	if !lua_capture_allow(c, n) {
		return
	}
	p := wb_reserve(c, n)
	intrinsics.mem_copy_non_overlapping(p, raw_data(s), n)
	c.wlen += n
}

@(private = "file")
reply_str :: #force_inline proc(c: ^Conn, s: string) {
	reply_raw(c, transmute([]u8)s)
}

@(private = "file")
reply_line :: proc(c: ^Conn, prefix: u8, s: []u8) #no_bounds_check {
	n := len(s)
	if !lua_capture_allow(c, n+3) {
		return
	}
	p := wb_reserve(c, n + 3)
	p[0] = prefix
	if n > 0 {
		intrinsics.mem_copy_non_overlapping(&p[1], raw_data(s), n)
	}
	p[n + 1] = '\r'
	p[n + 2] = '\n'
	c.wlen += n + 3
}

@(private = "file")
reply_prefixed_int :: #force_inline proc(c: ^Conn, prefix: u8, v: i64) #no_bounds_check {
	if !lua_capture_allow(c, 24) {
		return
	}
	p := wb_reserve(c, 24)
	p[0] = prefix
	n := format_i64(&p[1], v)
	p[n + 1] = '\r'
	p[n + 2] = '\n'
	c.wlen += n + 3
}

reply_ok :: #force_inline proc(c: ^Conn) {
	reply_str(c, "+OK\r\n")
}

reply_simple :: proc(c: ^Conn, s: string) {
	reply_line(c, '+', transmute([]u8)s)
}

reply_error :: proc(c: ^Conn, msg: string) {
	reply_line(c, '-', transmute([]u8)msg)
	stat_error_reply(c, transmute([]u8)msg)
}

reply_error_bytes :: proc(c: ^Conn, msg: []u8) {
	reply_line(c, '-', msg)
	stat_error_reply(c, msg)
}

reply_error_parts :: proc(c: ^Conn, parts: ..string) #no_bounds_check {
	n := 3
	for s in parts {
		n += len(s)
	}
	if !lua_capture_allow(c, n) {
		return
	}
	p := wb_reserve(c, n)
	p[0] = '-'
	o := 1
	for s in parts {
		if len(s) > 0 {
			intrinsics.mem_copy_non_overlapping(&p[o], raw_data(s), len(s))
			o += len(s)
		}
	}
	p[o] = '\r'
	p[o + 1] = '\n'
	c.wlen += n
	stat_error_reply(c, p[1:o])
}

reply_int :: proc(c: ^Conn, v: i64) {
	reply_prefixed_int(c, ':', v)
}

reply_bool :: proc(c: ^Conn, v: bool) {
	if c.resp >= RESP3 {
		reply_str(c, "#t\r\n" if v else "#f\r\n")
	} else {
		reply_str(c, ":1\r\n" if v else ":0\r\n")
	}
}

reply_null :: #force_inline proc(c: ^Conn) {
	if c.resp >= RESP3 {
		reply_str(c, "_\r\n")
	} else {
		reply_str(c, "$-1\r\n")
	}
}

reply_null_array :: proc(c: ^Conn) {
	if c.resp >= RESP3 {
		reply_str(c, "_\r\n")
	} else {
		reply_str(c, "*-1\r\n")
	}
}

reply_array :: proc(c: ^Conn, count: int) {
	reply_prefixed_int(c, '*', i64(count))
}

reply_map :: proc(c: ^Conn, pairs: int) {
	if c.resp >= RESP3 {
		reply_prefixed_int(c, '%', i64(pairs))
	} else {
		reply_prefixed_int(c, '*', i64(pairs) * 2)
	}
}

reply_set :: proc(c: ^Conn, count: int) {
	reply_prefixed_int(c, '~' if c.resp >= RESP3 else '*', i64(count))
}

reply_push :: proc(c: ^Conn, count: int) {
	reply_prefixed_int(c, '>' if c.resp >= RESP3 else '*', i64(count))
}

reply_attribute :: proc(c: ^Conn, pairs: int) -> bool {
	if c.resp < RESP3 {
		return false
	}
	reply_prefixed_int(c, '|', i64(pairs))
	return true
}

reply_bulk :: proc(c: ^Conn, s: []u8) #no_bounds_check {
	n := len(s)
	if !lua_capture_allow(c, n+26) {
		return
	}
	p := wb_reserve(c, n + 26)
	p[0] = '$'
	h := format_i64(&p[1], i64(n)) + 1
	p[h] = '\r'
	p[h + 1] = '\n'
	h += 2
	if n > 0 {
		intrinsics.mem_copy_non_overlapping(&p[h], raw_data(s), n)
	}
	p[h + n] = '\r'
	p[h + n + 1] = '\n'
	c.wlen += h + n + 2
}

reply_bulk_str :: #force_inline proc(c: ^Conn, s: string) {
	reply_bulk(c, transmute([]u8)s)
}

reply_bulk_int :: proc(c: ^Conn, v: i64) {
	tmp: [24]u8
	n := format_i64(&tmp[0], v)
	reply_bulk(c, tmp[:n])
}

reply_double :: proc(c: ^Conn, v: f64) {
	tmp: [fpconv.DOUBLE_STR_MAX]u8
	n := fpconv.format_double(tmp[:], v)
	if c.resp >= RESP3 {
		reply_line(c, ',', tmp[:n])
	} else {
		reply_bulk(c, tmp[:n])
	}
}

reply_double_text :: proc(c: ^Conn, s: []u8) {
	if c.resp >= RESP3 {
		reply_line(c, ',', s)
	} else {
		reply_bulk(c, s)
	}
}

reply_big_number :: proc(c: ^Conn, digits: []u8) {
	if c.resp >= RESP3 {
		reply_line(c, '(', digits)
	} else {
		reply_bulk(c, digits)
	}
}

reply_verbatim :: proc(c: ^Conn, s: []u8, format: string = "txt") #no_bounds_check {
	if c.resp < RESP3 {
		reply_bulk(c, s)
		return
	}
	reply_prefixed_int(c, '=', i64(len(s) + 4))
	if !lua_capture_allow(c, 4) {
		return
	}
	p := wb_reserve(c, 4)
	for i in 0 ..< 3 {
		p[i] = format[i] if i < len(format) else ' '
	}
	p[3] = ':'
	c.wlen += 4
	reply_raw(c, s)
	reply_str(c, "\r\n")
}

@(private = "file")
ERR_DEBUG_PROTOCOL :: "ERR Wrong protocol type name. Please use one of the following: string|integer|double|bignum|null|array|set|map|attrib|push|verbatim|true|false"

reply_debug_protocol :: proc(c: ^Conn, name: []u8) {
	switch {
	case eq_nocase(name, "string"):
		reply_bulk_str(c, "Hello World")
	case eq_nocase(name, "integer"):
		reply_int(c, 12345)
	case eq_nocase(name, "double"):
		reply_double(c, 3.141)
	case eq_nocase(name, "bignum"):
		reply_big_number(c, transmute([]u8)string("1234567999999999999999999999999999999"))
	case eq_nocase(name, "null"):
		reply_null(c)
	case eq_nocase(name, "array"):
		reply_array(c, 3)
		for i in 0 ..< 3 {
			reply_int(c, i64(i))
		}
	case eq_nocase(name, "set"):
		reply_set(c, 3)
		for i in 0 ..< 3 {
			reply_int(c, i64(i))
		}
	case eq_nocase(name, "map"):
		reply_map(c, 3)
		for i in 0 ..< 3 {
			reply_int(c, i64(i))
			reply_bool(c, i == 1)
		}
	case eq_nocase(name, "attrib"):
		if reply_attribute(c, 1) {
			reply_bulk_str(c, "key-popularity")
			reply_array(c, 2)
			reply_bulk_str(c, "key:123")
			reply_int(c, 90)
		}
		reply_bulk_str(c, "Some real reply following the attribute")
	case eq_nocase(name, "push"):
		if c.resp < RESP3 {
			reply_error(c, "ERR RESP2 is not supported by this command")
			return
		}
		reply_bulk_str(c, "Some real reply following the push reply")
		reply_push(c, 2)
		reply_bulk_str(c, "server-cpu-usage")
		reply_int(c, 42)
	case eq_nocase(name, "true"):
		reply_bool(c, true)
	case eq_nocase(name, "false"):
		reply_bool(c, false)
	case eq_nocase(name, "verbatim"):
		reply_verbatim(c, transmute([]u8)string("This is a verbatim\nstring"))
	case:
		reply_error(c, ERR_DEBUG_PROTOCOL)
	}
}
