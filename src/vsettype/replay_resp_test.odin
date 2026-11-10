package vsettype

import "core:strconv"
import "core:strings"
import "../fpconv"

Resp :: struct {
	b:     strings.Builder,
	proto: int,
}

resp_reset :: proc(r: ^Resp, proto: int) {
	strings.builder_reset(&r.b)
	r.proto = proto
}

resp_text :: proc(r: ^Resp) -> string {
	return strings.to_string(r.b)
}

resp_line :: proc(r: ^Resp, prefix: u8, text: string) {
	strings.write_byte(&r.b, prefix)
	strings.write_string(&r.b, text)
	strings.write_string(&r.b, "\r\n")
}

resp_int :: proc(r: ^Resp, n: i64) {
	buf: [32]u8
	resp_line(r, ':', strconv.write_int(buf[:], n, 10))
}

resp_count :: proc(r: ^Resp, prefix: u8, n: int) {
	buf: [32]u8
	resp_line(r, prefix, strconv.write_int(buf[:], i64(n), 10))
}

resp_bool :: proc(r: ^Resp, v: bool) {
	if r.proto >= 3 {
		resp_line(r, '#', "t" if v else "f")
	} else {
		resp_int(r, 1 if v else 0)
	}
}

resp_bulk :: proc(r: ^Resp, data: []u8) {
	resp_count(r, '$', len(data))
	strings.write_bytes(&r.b, data)
	strings.write_string(&r.b, "\r\n")
}

resp_bulk_text :: proc(r: ^Resp, text: string) {
	resp_bulk(r, transmute([]u8)text)
}

resp_null :: proc(r: ^Resp) {
	if r.proto >= 3 {
		strings.write_string(&r.b, "_\r\n")
	} else {
		strings.write_string(&r.b, "$-1\r\n")
	}
}

resp_null_array :: proc(r: ^Resp) {
	if r.proto >= 3 {
		strings.write_string(&r.b, "_\r\n")
	} else {
		strings.write_string(&r.b, "*-1\r\n")
	}
}

resp_array :: proc(r: ^Resp, n: int) {
	resp_count(r, '*', n)
}

resp_map :: proc(r: ^Resp, n: int) {
	if r.proto >= 3 {
		resp_count(r, '%', n)
	} else {
		resp_count(r, '*', 2 * n)
	}
}

resp_status :: proc(r: ^Resp, text: string) {
	resp_line(r, '+', text)
}

resp_error :: proc(r: ^Resp, text: string) {
	resp_line(r, '-', text)
}

double_text :: proc(buf: []u8, v: f64) -> string {
	n := fpconv.format_double(buf, v)
	return string(buf[:n])
}

resp_double :: proc(r: ^Resp, v: f64) {
	buf: [fpconv.DOUBLE_STR_MAX]u8
	text := double_text(buf[:], v)
	if r.proto >= 3 {
		resp_line(r, ',', text)
	} else {
		resp_bulk_text(r, text)
	}
}
