package main

import "base:runtime"
import C "core:c"
import "core:sys/linux"

foreign import tls_system { "system:ssl", "system:crypto" }

TLS_Password_Fn :: #type proc "c" (buffer: [^]u8, size, writing: C.int, userdata: rawptr) -> C.int

@(default_calling_convention = "c")
foreign tls_system {
	TLS_server_method :: proc() -> rawptr ---
	SSL_CTX_new :: proc(method: rawptr) -> rawptr ---
	SSL_CTX_free :: proc(ctx: rawptr) ---
	SSL_CTX_use_certificate_chain_file :: proc(ctx: rawptr, path: cstring) -> C.int ---
	SSL_CTX_use_PrivateKey_file :: proc(ctx: rawptr, path: cstring, kind: C.int) -> C.int ---
	SSL_CTX_check_private_key :: proc(ctx: rawptr) -> C.int ---
	SSL_CTX_load_verify_locations :: proc(ctx: rawptr, file, directory: cstring) -> C.int ---
	SSL_CTX_set_verify :: proc(ctx: rawptr, mode: C.int, callback: rawptr) ---
	SSL_CTX_set_options :: proc(ctx: rawptr, options: u64) -> u64 ---
	SSL_CTX_set_cipher_list :: proc(ctx: rawptr, text: cstring) -> C.int ---
	SSL_CTX_set_ciphersuites :: proc(ctx: rawptr, text: cstring) -> C.int ---
	SSL_CTX_ctrl :: proc(ctx: rawptr, command: C.int, value: C.long, pointer: rawptr) -> C.long ---
	SSL_CTX_set_timeout :: proc(ctx: rawptr, timeout: C.long) -> C.long ---
	SSL_CTX_set_session_id_context :: proc(ctx: rawptr, bytes: [^]u8, size: C.uint) -> C.int ---
	SSL_CTX_set_default_passwd_cb :: proc(ctx: rawptr, callback: TLS_Password_Fn) ---
	SSL_CTX_set_default_passwd_cb_userdata :: proc(ctx, userdata: rawptr) ---
	SSL_CTX_set0_tmp_dh_pkey :: proc(ctx, parameters: rawptr) -> C.int ---
	BIO_new_file :: proc(path, mode: cstring) -> rawptr ---
	BIO_free :: proc(bio: rawptr) -> C.int ---
	PEM_read_bio_Parameters :: proc(bio: rawptr, output: ^rawptr) -> rawptr ---
	EVP_PKEY_free :: proc(parameters: rawptr) ---
	SSL_new :: proc(ctx: rawptr) -> rawptr ---
	SSL_free :: proc(ssl: rawptr) ---
	SSL_set_fd :: proc(ssl: rawptr, fd: C.int) -> C.int ---
	SSL_accept :: proc(ssl: rawptr) -> C.int ---
	SSL_get_error :: proc(ssl: rawptr, result: C.int) -> C.int ---
	SSL_read_ex :: proc(ssl: rawptr, buffer: rawptr, size: C.size_t, read: ^C.size_t) -> C.int ---
	SSL_write_ex :: proc(ssl: rawptr, buffer: rawptr, size: C.size_t, written: ^C.size_t) -> C.int ---
	SSL_pending :: proc(ssl: rawptr) -> C.int ---
	SSL_shutdown :: proc(ssl: rawptr) -> C.int ---
	ERR_clear_error :: proc() ---
	ERR_get_error :: proc() -> C.ulong ---
	ERR_error_string_n :: proc(code: C.ulong, output: [^]u8, size: C.size_t) ---
}

TLS_Connection :: struct {
	ssl: rawptr,
	ready: bool,
	handshake_out: bool,
	read_request: int,
	read_length: int,
	read_position: int,
	read_wants_out: bool,
	write_length: int,
	write_wants_in: bool,
	pending_listed: bool,
	pending_pass: u64,
	pending_prev: ^Conn,
	pending_next: ^Conn,
	read_buffer: [16384]u8,
	write_buffer: [16384]u8,
}

tls_context: rawptr
tls_fds: [CONFIG_BIND_MAX]linux.Fd
tls_fd_count: int

transport_tls_listener :: proc(fd: linux.Fd) -> bool {
	for listener in tls_fds[:tls_fd_count] { if listener == fd { return true } }
	return false
}

tls_password :: proc "c" (buffer: [^]u8, size, writing: C.int, userdata: rawptr) -> C.int {
	context = runtime.default_context()
	if userdata == nil || size <= 0 { return 0 }
	password := cast(^string)userdata
	n := min(len(password^), int(size))
	copy(buffer[:n], password^)
	return C.int(n)
}

tls_error :: proc(message: string) -> string {
	buffer: [256]u8
	ERR_error_string_n(ERR_get_error(), raw_data(buffer[:]), C.size_t(len(buffer)))
	length := 0
	for length < len(buffer) && buffer[length] != 0 { length += 1 }
	plog(LOG_WARNING, message, ": ", string(buffer[:length]))
	return "Unable to update TLS configuration. Check server logs."
}

tls_build_context :: proc() -> (ctx: rawptr, good: bool) {
	ERR_clear_error()
	ctx = SSL_CTX_new(TLS_server_method())
	if ctx == nil { return }
	defer { if !good { SSL_CTX_free(ctx); ctx = nil } }
	if cfg.tls_cert_file == "" || cfg.tls_key_file == "" { tls_error("TLS requires certificate and private key files"); return }
	path: [4096]u8
	if SSL_CTX_use_certificate_chain_file(ctx, persist_cstr(cfg.tls_cert_file, path[:])) != 1 { tls_error("Loading TLS certificate failed"); return }
	password := cfg.tls_key_file_pass
	SSL_CTX_set_default_passwd_cb(ctx, tls_password)
	SSL_CTX_set_default_passwd_cb_userdata(ctx, &password)
	key_ok := SSL_CTX_use_PrivateKey_file(ctx, persist_cstr(cfg.tls_key_file, path[:]), 1) == 1
	SSL_CTX_set_default_passwd_cb_userdata(ctx, nil)
	SSL_CTX_set_default_passwd_cb(ctx, nil)
	if !key_ok || SSL_CTX_check_private_key(ctx) != 1 { tls_error("Loading TLS private key failed"); return }
	if cfg.tls_ca_cert_file != "" || cfg.tls_ca_cert_dir != "" {
		directory: [4096]u8
		file_name: cstring
		directory_name: cstring
		if cfg.tls_ca_cert_file != "" { file_name = persist_cstr(cfg.tls_ca_cert_file, path[:]) }
		if cfg.tls_ca_cert_dir != "" { directory_name = persist_cstr(cfg.tls_ca_cert_dir, directory[:]) }
		if SSL_CTX_load_verify_locations(ctx, file_name, directory_name) != 1 { tls_error("Loading TLS CA locations failed"); return }
	} else if cfg.tls_auth_clients != 0 { tls_error("TLS client authentication requires a CA certificate file or directory"); return }
	verify: C.int
	if cfg.tls_auth_clients != 0 { verify = 1 }
	if cfg.tls_auth_clients == 1 { verify |= 2 }
	SSL_CTX_set_verify(ctx, verify, nil)
	disabled := u64(1)<<25 | u64(1)<<26 | u64(1)<<28 | u64(1)<<17
	if cfg.tls_protocols != "" {
		disabled |= u64(1)<<27 | u64(1)<<29
		parts: [dynamic][]u8
		defer delete(parts)
		config_split_spaces(transmute([]u8)cfg.tls_protocols, &parts)
		for protocol in parts {
			switch {
			case eq_nocase(protocol, "tlsv1"): disabled &= ~(u64(1)<<26)
			case eq_nocase(protocol, "tlsv1.1"): disabled &= ~(u64(1)<<28)
			case eq_nocase(protocol, "tlsv1.2"): disabled &= ~(u64(1)<<27)
			case eq_nocase(protocol, "tlsv1.3"): disabled &= ~(u64(1)<<29)
			case:
				plog(LOG_WARNING, "Invalid tls-protocols specified. Use a combination of 'TLSv1', 'TLSv1.1', 'TLSv1.2' and 'TLSv1.3'.")
				return
			}
		}
	}
	if cfg.tls_prefer_server_ciphers { disabled |= u64(1)<<22 }
	SSL_CTX_set_options(ctx, disabled)
	SSL_CTX_ctrl(ctx, 33, 1, nil)
	SSL_CTX_ctrl(ctx, 118, 1, nil)
	if cfg.tls_ciphers != "" && SSL_CTX_set_cipher_list(ctx, persist_cstr(cfg.tls_ciphers, path[:])) != 1 { tls_error("Invalid TLS cipher list"); return }
	if cfg.tls_ciphersuites != "" && SSL_CTX_set_ciphersuites(ctx, persist_cstr(cfg.tls_ciphersuites, path[:])) != 1 { tls_error("Invalid TLS 1.3 cipher list"); return }
	if cfg.tls_dh_params_file != "" {
		bio := BIO_new_file(persist_cstr(cfg.tls_dh_params_file, path[:]), "r")
		if bio == nil { tls_error("Loading TLS DH parameters failed"); return }
		parameters := PEM_read_bio_Parameters(bio, nil)
		BIO_free(bio)
		if parameters == nil { tls_error("Parsing TLS DH parameters failed"); return }
		if SSL_CTX_set0_tmp_dh_pkey(ctx, parameters) != 1 { EVP_PKEY_free(parameters); tls_error("Applying TLS DH parameters failed"); return }
	}
	SSL_CTX_ctrl(ctx, 44, 2 if cfg.tls_session_caching else 0, nil)
	SSL_CTX_ctrl(ctx, 42, C.long(cfg.tls_session_cache_size), nil)
	SSL_CTX_set_timeout(ctx, C.long(cfg.tls_session_cache_timeout))
	identity := [4]u8{'e', 's', 'k', 'i'}
	if SSL_CTX_set_session_id_context(ctx, raw_data(identity[:]), C.uint(len(identity))) != 1 { tls_error("Configuring TLS sessions failed"); return }
	good = true
	return
}

tls_configure :: proc() -> bool {
	if cfg.tls_port == 0 && tls_context == nil { return true }
	if cfg.tls_port == 0 { SSL_CTX_free(tls_context); tls_context = nil; return true }
	ctx, good := tls_build_context()
	if !good { return false }
	old := tls_context
	tls_context = ctx
	if old != nil { SSL_CTX_free(old) }
	return true
}

transport_connection_init :: proc(c: ^Conn) -> bool {
	if c.transport != .Tls { return true }
	ssl := SSL_new(tls_context)
	if ssl == nil { return false }
	if SSL_set_fd(ssl, C.int(c.fd)) != 1 { SSL_free(ssl); return false }
	c.tls = new(TLS_Connection)
	c.tls.ssl = ssl
	conn_mem += size_of(TLS_Connection)
	return true
}

transport_connection_close :: proc(c: ^Conn) {
	if c.tls == nil { return }
	if c.tls.pending_listed { tls_pending_unlink(c) }
	if c.tls.ready && !c.lua_debug_detached { SSL_shutdown(c.tls.ssl) }
	SSL_free(c.tls.ssl)
	free(c.tls)
	c.tls = nil
	conn_mem -= size_of(TLS_Connection)
}

transport_handshake :: proc(c: ^Conn) -> bool {
	tls := c.tls
	if tls == nil || tls.ready { return true }
	ERR_clear_error()
	result := SSL_accept(tls.ssl)
	if result == 1 { tls.ready = true; tls.handshake_out = false; epoll_set(c.fd, .MOD, c.want_write, c.id); tls_pending_note(c); return true }
	problem := SSL_get_error(tls.ssl, result)
	if problem == 2 || problem == 3 {
		tls.handshake_out = problem == 3
		epoll_set(c.fd, .MOD, false, c.id)
		return false
	}
	c.close_after = true
	return false
}

transport_epoll :: proc(c: ^Conn, events: linux.EPoll_Event_Set) -> linux.EPoll_Event_Set {
	tls := c.tls
	if tls == nil { return events }
	if !tls.ready { return {.OUT} if tls.handshake_out else {.IN} }
	if tls.read_wants_out { return {.OUT} }
	if tls.write_length != 0 && tls.write_wants_in { return {.IN} }
	return events
}

conn_net_pending :: proc(c: ^Conn) -> bool {
	return c.tls != nil && c.tls.ready && (c.tls.read_position < c.tls.read_length || SSL_pending(c.tls.ssl) > 0)
}

tls_pending_link :: proc(c: ^Conn) {
	tls := c.tls
	tls.pending_prev, tls.pending_next = tls_pending_tail, nil
	if tls_pending_tail != nil { tls_pending_tail.tls.pending_next = c } else { tls_pending_head = c }
	tls_pending_tail = c
	tls.pending_listed = true
}

tls_pending_unlink :: proc(c: ^Conn) {
	tls := c.tls
	if tls.pending_prev != nil { tls.pending_prev.tls.pending_next = tls.pending_next } else { tls_pending_head = tls.pending_next }
	if tls.pending_next != nil { tls.pending_next.tls.pending_prev = tls.pending_prev } else { tls_pending_tail = tls.pending_prev }
	tls.pending_prev, tls.pending_next = nil, nil
	tls.pending_listed = false
}

tls_pending_note :: proc(c: ^Conn) {
	pending := conn_net_pending(c)
	if pending == c.tls.pending_listed { return }
	if pending { tls_pending_link(c) } else { tls_pending_unlink(c) }
}

conn_net_read :: proc(c: ^Conn, bytes: []u8) -> (int, linux.Errno) {
	if c.tls == nil { return linux.read(c.fd, bytes) }
	n, err := tls_net_read(c, bytes)
	tls_pending_note(c)
	return n, err
}

tls_net_read :: proc(c: ^Conn, bytes: []u8) -> (int, linux.Errno) {
	tls := c.tls
	if !tls.ready && !transport_handshake(c) { return 0, .ECONNRESET if c.close_after else .EAGAIN }
	if tls.write_length != 0 || len(bytes) == 0 { return 0, .EAGAIN }
	if tls.read_position == tls.read_length {
		tls.read_position, tls.read_length = 0, 0
		if tls.read_request == 0 { tls.read_request = min(len(bytes), len(tls.read_buffer)) }
		amount: C.size_t
		ERR_clear_error()
		result := SSL_read_ex(tls.ssl, raw_data(tls.read_buffer[:]), C.size_t(tls.read_request), &amount)
		if result != 1 {
			problem := SSL_get_error(tls.ssl, result)
			if problem == 2 || problem == 3 {
				tls.read_wants_out = problem == 3
				epoll_set(c.fd, .MOD, c.want_write, c.id)
				return 0, .EAGAIN
			}
			if problem == 6 { return 0, .NONE }
			return 0, .ECONNRESET
		}
		tls.read_request, tls.read_wants_out = 0, false
		epoll_set(c.fd, .MOD, c.want_write, c.id)
		tls.read_length = int(amount)
	}
	n := min(len(bytes), tls.read_length - tls.read_position)
	copy(bytes[:n], tls.read_buffer[tls.read_position:tls.read_position+n])
	tls.read_position += n
	return n, .NONE
}

conn_net_write :: proc(c: ^Conn, bytes: []u8) -> (int, linux.Errno) {
	if len(bytes) == 0 { return 0, .NONE }
	if c.tls == nil { return linux.write(c.fd, bytes) }
	n, err := tls_net_write(c, bytes)
	tls_pending_note(c)
	return n, err
}

tls_net_write :: proc(c: ^Conn, bytes: []u8) -> (int, linux.Errno) {
	tls := c.tls
	if !tls.ready && !transport_handshake(c) { return 0, .ECONNRESET if c.close_after else .EAGAIN }
	if tls.read_wants_out { return 0, .EAGAIN }
	if tls.write_length == 0 {
		tls.write_length = min(len(bytes), len(tls.write_buffer))
		copy(tls.write_buffer[:tls.write_length], bytes[:tls.write_length])
	}
	amount: C.size_t
	ERR_clear_error()
	result := SSL_write_ex(tls.ssl, raw_data(tls.write_buffer[:]), C.size_t(tls.write_length), &amount)
	if result != 1 {
		problem := SSL_get_error(tls.ssl, result)
		if problem == 2 || problem == 3 {
			tls.write_wants_in = problem == 2
			epoll_set(c.fd, .MOD, true, c.id)
			return 0, .EAGAIN
		}
		return 0, .ECONNRESET
	}
	tls.write_length, tls.write_wants_in = 0, false
	epoll_set(c.fd, .MOD, c.want_write, c.id)
	return int(amount), .NONE
}

conn_transport_close :: proc(c: ^Conn) {
	transport_connection_close(c)
}

conn_net_wait :: proc(c: ^Conn, for_write: bool, timeout_ms: i32) -> (ready: bool, err: linux.Errno) {
	want_write := for_write
	if tls := c.tls; tls != nil {
		if !tls.ready { want_write = tls.handshake_out
		} else if tls.read_wants_out { want_write = true
		} else if tls.write_length != 0 { want_write = !tls.write_wants_in
		} else if !for_write && conn_net_pending(c) { return true, .NONE }
	}
	fds := [1]linux.Poll_Fd{{fd = c.fd, events = {.OUT} if want_write else {.IN}}}
	count, problem := linux.poll(fds[:], timeout_ms)
	if problem != .NONE { return false, problem }
	return count > 0, .NONE
}

tls_pending_head: ^Conn
tls_pending_tail: ^Conn
tls_pending_pass: u64

transport_pending_input :: proc() -> bool {
	if tls_pending_head == nil { return false }
	tls_pending_pass += 1
	budget := 64
	processed := false
	for budget > 0 {
		c := tls_pending_head
		if c == nil || c.tls.pending_pass == tls_pending_pass { break }
		c.tls.pending_pass = tls_pending_pass
		if c != tls_pending_tail {
			tls_pending_unlink(c)
			tls_pending_link(c)
		}
		if c.tls.write_length == 0 && !c.tls.read_wants_out {
			conn_read(c)
			budget -= 1
			processed = true
		}
	}
	return processed
}

transport_connection_memory :: proc "contextless" (c: ^Conn) -> int {
	return size_of(TLS_Connection) if c.tls != nil else 0
}
