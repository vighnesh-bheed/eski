package notifications

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import m "../../src"

wire :: proc(args: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "*%d\r\n", len(args))
	for a in args {
		bulk(&b, a)
	}
	return strings.to_string(b)
}

sock_send :: proc(cl: Client, parts: ..string) {
	data := strings.concatenate(parts, context.temp_allocator)
	n, err := linux.write(cl.peer, transmute([]u8)data)
	assert(err == .NONE && n == len(data))
	m.conn_read(cl.c)
}

sock_recv :: proc(cl: Client) -> string {
	m.conn_flush(cl.c)
	b := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	for {
		n, err := linux.recv(cl.peer, buf[:], {.DONTWAIT})
		if err != .NONE || n <= 0 {
			break
		}
		strings.write_bytes(&b, buf[:n])
	}
	return strings.to_string(b)
}

@(test)
test_socket_round_trip :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_setup()
	cl := client_open()
	w := client_open()
	sock_send(cl, wire("HELLO", "3"))
	testing.expect(t, strings.has_prefix(sock_recv(cl), "%7\r\n$6\r\nserver\r\n"))
	testing.expect_value(t, cl.c.resp, 3)
	sock_send(cl, wire("CLIENT", "TRACKING", "ON"), wire("GET", "sk:zz"))
	expect_bytes(t, sock_recv(cl), "+OK\r\n_\r\n")
	expect_bytes(t, run(w, "SET sk:zz 1"), "+OK\r\n")
	expect_bytes(t, sock_recv(cl), push_inv("sk:zz"))
	sock_send(cl, wire("GET", "sk:zz"), wire("SET", "sk:zz", "2"), wire("GET", "sk:zz"))
	expect_bytes(t, sock_recv(cl), strings.concatenate({"$1\r\n1\r\n+OK\r\n", push_inv("sk:zz"), "$1\r\n2\r\n"}, context.temp_allocator))
	sock_send(cl, wire("MULTI"), wire("GET", "sk:m"), wire("SET", "sk:m", "1"), wire("EXEC"), wire("PING"))
	expect_bytes(t, sock_recv(cl), strings.concatenate({"+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n_\r\n+OK\r\n", push_inv("sk:m"), "+PONG\r\n"}, context.temp_allocator))
	sub := client_open()
	r2 := client_open()
	sock_send(sub, wire("SUBSCRIBE", "__redis__:invalidate"))
	expect_bytes(t, sock_recv(sub), "*3\r\n$9\r\nsubscribe\r\n$20\r\n__redis__:invalidate\r\n:1\r\n")
	sock_send(r2, wire("CLIENT", "TRACKING", "ON", "REDIRECT", fmt.tprintf("%d", sub.c.id)), wire("GET", "sk:r"), wire("CLIENT", "TRACKINGINFO"))
	expect_bytes(t, sock_recv(r2), strings.concatenate({"+OK\r\n$-1\r\n", trackinginfo_reply(false, {"on"}, sub.c.id, {})}, context.temp_allocator))
	expect_bytes(t, run(w, "SET sk:r 1"), "+OK\r\n")
	expect_bytes(t, sock_recv(sub), msg_inv("sk:r"))
	expect_bytes(t, sock_recv(r2), "")
	b := client_open()
	sock_send(b, wire("HELLO", "3"))
	sock_recv(b)
	sock_send(b, wire("CLIENT", "TRACKING", "ON", "BCAST", "PREFIX", "sk:b"), wire("SET", "sk:b1", "1"), wire("SET", "sk:b2", "1"))
	sleep_cycle()
	expect_bytes(t, sock_recv(b), strings.concatenate({"+OK\r\n+OK\r\n+OK\r\n", push_inv("sk:b1", "sk:b2")}, context.temp_allocator))
	client_close(b)
	client_close(r2)
	client_close(sub)
	client_close(w)
	client_close(cl)
	env_check_clean(t)
}
