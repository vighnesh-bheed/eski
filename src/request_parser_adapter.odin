package main

import request_parser "request_parser"
import "base:intrinsics"

Request_Inline_Owner :: request_parser.Inline_Owner

Request_Partial_Owner :: struct {
	prefix: []u8,
	required: int,
}

request_partial_close :: proc(c: ^Conn) {
	owner := c.partial_owner
	if owner == nil { return }
	if c.fd >= 0 { conn_mem -= size_of(Request_Partial_Owner) + len(owner.prefix) }
	mem_free(raw_data(owner.prefix))
	free(owner)
	c.partial_owner = nil
}

request_partial_save :: proc(c: ^Conn, prefix, required: int) {
	owner := new(Request_Partial_Owner)
	owner.prefix = mem_alloc(prefix)[:prefix]
	copy(owner.prefix, c.rbuf[c.rpos:c.rpos + prefix])
	owner.required = required
	c.partial_owner = owner
	if c.fd >= 0 { conn_mem += size_of(Request_Partial_Owner) + prefix }
	remaining := c.rlen - c.rpos - prefix
	if remaining > 0 { intrinsics.mem_copy(&c.rbuf[c.rpos], &c.rbuf[c.rpos + prefix], remaining) }
	c.rlen -= prefix
}

request_partial_restore :: proc(c: ^Conn) {
	owner := c.partial_owner
	prefix := len(owner.prefix)
	if c.rlen + prefix > c.rcap { conn_read_resize(c, c.rlen + prefix) }
	remaining := c.rlen - c.rpos
	if remaining > 0 { intrinsics.mem_copy(&c.rbuf[c.rpos + prefix], &c.rbuf[c.rpos], remaining) }
	copy(c.rbuf[c.rpos:c.rpos + prefix], owner.prefix)
	c.rlen += prefix
	request_partial_close(c)
}

argv_init :: proc() {
	scratch := request_parser.Scratch{args = argv_buf}
	request_parser.ensure_args(&scratch, 64)
	argv_buf = scratch.args
	argc = 0
}

request_inline_memory :: #force_inline proc "contextless" (c: ^Conn) -> int {
	return request_parser.inline_charge(c.inline_owner) + (size_of(Request_Partial_Owner) + len(c.partial_owner.prefix) if c.partial_owner != nil else 0)
}

request_inline_close :: proc(c: ^Conn) {
	request_partial_close(c)
	charge := request_parser.inline_release(&c.inline_owner)
	if c.fd >= 0 {
		conn_mem -= charge
	}
}

parse_command :: proc(c: ^Conn) -> Parse_Result {
	c.need = 0
	if c.partial_owner != nil {
		if c.rlen - c.rpos < c.partial_owner.required {
			c.need = c.rpos + c.partial_owner.required
			argc = 0
			return .Incomplete
		}
		request_partial_restore(c)
	}
	input := c.rbuf[c.rpos:c.rlen]
	if len(input) == 0 {
		argc = 0
		return .Incomplete
	}
	scratch := request_parser.Scratch{args = argv_buf}
	result: request_parser.Result
	if input[0] == '*' {
		limits := request_parser.Limits{
			bulk_max = cfg.proto_max_bulk_len,
			base_offset = c.rpos,
			unauthenticated = c.mbulk_max == 0,
			unauth_array_max = ACL_UNAUTH_MBULK,
			unauth_bulk_max = ACL_UNAUTH_BULK,
		}
		result = request_parser.parse_array(input, &scratch, limits)
	} else {
		tracked := c.fd >= 0
		before := 0
		if tracked {
			before = request_inline_memory(c)
		}
		result = request_parser.parse_inline(input, &scratch, &c.inline_owner, {})
		if tracked {
			conn_mem += request_inline_memory(c) - before
		}
	}
	argv_buf = scratch.args
	switch result.kind {
	case .Command:
		argc = result.argc
		c.rpos += result.consumed
		return .Command
	case .Incomplete:
		argc = 0
		if result.payload > 0 {
			request_partial_save(c, result.payload, result.need - result.payload)
			result.need -= result.payload
		}
		if result.need > 0 && result.need <= max(int) - c.rpos {
			c.need = c.rpos + result.need
		}
		return .Incomplete
	case .Error:
		argc = 0
		request_parse_error(c, result.fault, result.error_byte)
		return .Error
	}
	unreachable()
}

request_parse_error :: #force_no_inline proc(c: ^Conn, fault: request_parser.Fault, error_byte: u8) {
	keyspace_settle(c)
	stat_cur = nil
	c.close_after = true
	if fault == .Expected_Bulk {
		byte := error_byte
		if byte == '\r' || byte == '\n' {
			byte = ' '
		}
		character := [1]u8{byte}
		reply_error_parts(c, "ERR Protocol error: expected '$', got '", string(character[:]), "'")
	} else {
		reply_error_parts(c, "ERR Protocol error: ", request_parser.fault_detail(fault))
	}
}
