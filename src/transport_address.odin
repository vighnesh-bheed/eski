package main

import "core:sys/linux"
import "core:sys/posix"

Transport_Kind :: enum u8 { Plain, Unix, Tls }

transport_unix_fd: linux.Fd = -1
transport_primary_name: [128]u8

transport_listener_kind :: proc(fd: linux.Fd) -> Transport_Kind {
	if fd == transport_unix_fd { return .Unix }
	return .Tls if transport_tls_listener(fd) else .Plain
}

transport_is_listener :: proc(fd: linux.Fd) -> bool {
	if fd == transport_unix_fd || transport_tls_listener(fd) { return true }
	for listener in srv.lfds[:srv.nlfd] {
		if listener == fd { return true }
	}
	return false
}

transport_ipv6 :: proc(name: string) -> (ip: [16]u8, ok: bool) {
	text := name
	if text == "::*" { text = "::" }
	buffer: [128]u8
	if len(text) >= len(buffer) { return }
	ok = posix.inet_pton(.INET6, persist_cstr(text, buffer[:]), &ip) == .SUCCESS
	return
}

transport_format :: proc(output: []u8, address: ^linux.Sock_Addr_Any) -> int {
	#partial switch address.family {
	case .INET:
		return format_addr(output, address.ipv4.sin_addr, int(address.ipv4.sin_port))
	case .INET6:
		text: [64]u8
		if posix.inet_ntop(.INET6, &address.ipv6.sin6_addr, raw_data(text[:]), posix.socklen_t(len(text))) == nil { return 0 }
		n := 0
		output[n] = '['; n += 1
		for byte in text {
			if byte == 0 { break }
			output[n] = byte; n += 1
		}
		if address.ipv6.sin6_scope_id != 0 {
			output[n] = '%'; n += 1
			n += format_i64(&output[n], i64(address.ipv6.sin6_scope_id))
		}
		output[n] = ']'; output[n + 1] = ':'; n += 2
		n += format_i64(&output[n], i64(address.ipv6.sin6_port))
		return n
	case .UNIX:
		n := copy(output, cfg.unixsocket)
		output[n] = ':'; output[n + 1] = '0'
		return n + 2
	}
	return 0
}

transport_peer_local :: proc(address: ^linux.Sock_Addr_Any) -> bool {
	#partial switch address.family {
	case .UNIX: return true
	case .INET: return address.ipv4.sin_addr[0] == 127
	case .INET6:
		ip := address.ipv6.sin6_addr
		loopback := ip[15] == 1
		for byte in ip[:15] { loopback = loopback && byte == 0 }
		if loopback { return true }
		mapped := ip[10] == 255 && ip[11] == 255 && ip[12] == 127
		for byte in ip[:10] { mapped = mapped && byte == 0 }
		return mapped
	}
	return false
}

transport_listen_v6 :: proc(ip: [16]u8, port: int) -> (linux.Fd, linux.Errno) {
	fd, err := linux.socket(.INET6, .STREAM, {.NONBLOCK, .CLOEXEC}, .TCP)
	if err != .NONE { return fd, err }
	runtime_socket_mark(fd)
	one: i32 = 1
	linux.setsockopt(fd, linux.SOL_SOCKET, linux.Socket_Option.REUSEADDR, &one)
	linux.setsockopt(fd, 41, 26, &one)
	address := linux.Sock_Addr_In6{sin6_family = .INET6, sin6_port = u16be(port), sin6_addr = ip}
	if problem := linux.bind(fd, &address); problem != .NONE { linux.close(fd); return fd, problem }
	if problem := linux.listen(fd, i32(clamp(cfg.tcp_backlog, 0, i64(max(i32))))); problem != .NONE { linux.close(fd); return fd, problem }
	return fd, .NONE
}

transport_listen_unix :: proc() -> bool {
	if cfg.unixsocket == "" { return true }
	address: linux.Sock_Addr_Un
	address.sun_family = .UNIX
	if len(cfg.unixsocket) >= len(address.sun_path) { plog(LOG_WARNING, "Unix socket path is too long"); return false }
	path: [128]u8
	name := persist_cstr(cfg.unixsocket, path[:])
	linux.unlink(name)
	fd, problem := linux.socket(.UNIX, .STREAM, {.NONBLOCK, .CLOEXEC}, .HOPOPT)
	if problem != .NONE { return false }
	copy(address.sun_path[:], cfg.unixsocket)
	if linux.bind(fd, &address) != .NONE || linux.listen(fd, i32(clamp(cfg.tcp_backlog, 0, i64(max(i32))))) != .NONE {
		linux.close(fd)
		return false
	}
	if cfg.unixsocketperm != 0 && linux.chmod(name, transmute(linux.Mode)u32(cfg.unixsocketperm)) != .NONE {
		linux.close(fd); linux.unlink(name); return false
	}
	transport_unix_fd = fd
	return true
}

transport_close_listeners :: proc(unlink_path := true) {
	for fd in tls_fds[:tls_fd_count] { linux.close(fd) }
	tls_fd_count = 0
	if tls_context != nil { SSL_CTX_free(tls_context); tls_context = nil }
	if transport_unix_fd >= 0 {
		linux.close(transport_unix_fd)
		transport_unix_fd = -1
		path: [128]u8
		if unlink_path { linux.unlink(persist_cstr(cfg.unixsocket, path[:])) }
	}
}
