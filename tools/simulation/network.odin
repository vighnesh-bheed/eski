package simulation

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import engine "../../src"
import "../../src/vmath"

LINKS :: 8

Link :: struct {
	input: []u8,
	output: [dynamic]u8,
	write_quota: int,
	eof: bool,
	alive: bool,
}

links: [LINKS]Link
network_rng: vmath.Rng
millis: i64

net_read :: proc(fd: linux.Fd, bytes: []u8) -> (int, linux.Errno) {
	link := &links[fd]
	if len(link.input) > 0 {
		count := copy(bytes, link.input)
		link.input = link.input[count:]
		return count, .NONE
	}
	return 0, .NONE if link.eof else .EAGAIN
}

net_write :: proc(fd: linux.Fd, bytes: []u8) -> (int, linux.Errno) {
	link := &links[fd]
	if link.write_quota == 0 {
		trace("write fd=%d blocked", fd)
		return 0, .EAGAIN
	}
	count := min(link.write_quota, len(bytes))
	link.write_quota -= count
	append(&link.output, ..bytes[:count])
	trace("write fd=%d bytes=%d requested=%d", fd, count, len(bytes))
	return count, .NONE
}

net_close :: proc(fd: linux.Fd) {
	links[fd].alive = false
	trace("close fd=%d", fd)
}

start_network :: proc(seed: u64, scoped := false, owners := false) {
	vmath.rng_seed(&network_rng, seed)
	engine.simulation_init({net_read, net_write, net_close}, seed, scoped, owners)
}

open_link :: proc(fd: linux.Fd, kind: engine.Conn_Kind) {
	require(!links[fd].alive, "link slot is free")
	links[fd].alive = true
	links[fd].eof = false
	links[fd].input = nil
	clear(&links[fd].output)
	engine.simulation_accept(fd, kind)
	trace("accept fd=%d protocol=%v", fd, kind)
}

advance :: proc(delay: i64) {
	millis += delay
	engine.simulation_time(millis)
}

packet :: proc(fd: linux.Fd, events: linux.EPoll_Event_Set, quota: int) {
	delay := 1 + i64(vmath.rng_next(&network_rng) % 7)
	advance(delay)
	link := &links[fd]
	link.write_quota = quota
	trace("network time=%d fd=%d mask=%v input=%d write_quota=%d", millis, fd, events, len(link.input), quota)
	alive := engine.simulation_event(fd, events)
	require(alive == link.alive, "virtual and engine link lifetimes agree")
}

deliver :: proc(fd: linux.Fd, input: string) {
	trace("input fd=%d bytes=%q", fd, input)
	bytes := transmute([]u8)input
	for offset := 0; offset < len(bytes); {
		require(links[fd].alive, "link survives data fragments")
		count := min(len(bytes) - offset, 1 + int(vmath.rng_next(&network_rng) % 19))
		links[fd].input = bytes[offset:offset + count]
		packet(fd, {.IN}, int(vmath.rng_next(&network_rng) % 15))
		require(len(links[fd].input) == 0, "each delivered fragment is consumed")
		offset += count
	}
}

drain :: proc(fd: linux.Fd) {
	for attempt := 0; links[fd].alive && engine.simulation_pending(fd); attempt += 1 {
		require(attempt < 256, "reply can be drained with bounded writable events")
		packet(fd, {.OUT}, 1 + int(vmath.rng_next(&network_rng) % 16))
	}
}

expect_output :: proc(fd: linux.Fd, expected, property: string, visible := false) {
	got := string(links[fd].output[:])
	trace("reply fd=%d expected=%q got=%q", fd, expected, got)
	if visible {
		fmt.printfln("OBS %q", got)
	}
	require(got == expected, property)
	clear(&links[fd].output)
}

exchange :: proc(fd: linux.Fd, input, expected, property: string, visible := false) {
	deliver(fd, input)
	drain(fd)
	expect_output(fd, expected, property, visible)
}

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

resp :: proc(args: ..string) -> string {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, ..transmute([]u8)fmt.tprintf("*%d\r\n", len(args)))
	for arg in args {
		append(&out, ..transmute([]u8)fmt.tprintf("$%d\r\n", len(arg)))
		append(&out, ..transmute([]u8)arg)
		append(&out, '\r', '\n')
	}
	return string(out[:])
}

bulk :: proc(text: string) -> string {
	return fmt.tprintf("$%d\r\n%s\r\n", len(text), text)
}

integer :: proc(value: int) -> string {
	return fmt.tprintf(":%d\r\n", value)
}

run_network :: proc(seed: u64, steps: int) {
	start_network(seed)
	open_link(1, .Redis)
	open_link(2, .Memcached)
	exchange(1, cat(resp("SET", "counter", "0"), resp("HSET", "doc:1", "title", "alpha river")), "+OK\r\n:1\r\n", "Redis mixed pipeline preserves replies")
	exchange(1, cat(resp("JSON.SET", "json:1", "$", `{"title":"alpha","n":7}`), resp("JSON.GET", "json:1", "$.title")), cat("+OK\r\n", bulk(`["alpha"]`)), "JSON set and path read match model")
	exchange(1, cat(resp("FT.CREATE", "idx", "ON", "HASH", "PREFIX", "1", "doc:", "SCHEMA", "title", "TEXT"), resp("FT.SEARCH", "idx", "alpha", "NOCONTENT")), cat("+OK\r\n*2\r\n:1\r\n", bulk("doc:1")), "search query observes indexed hash")
	exchange(2, "set mc 9 0 2\r\n41\r\nget mc\r\n", "STORED\r\nVALUE mc 9 2\r\n41\r\nEND\r\n", "memcached storage uses flags and complete value")
	exchange(1, resp("GET", "mc"), bulk("41"), "Redis sees shared memcached keyspace")
	exchange(2, "incr mc 1\r\n", "42\r\n", "memcached arithmetic applies to stored value")
	exchange(1, resp("GET", "mc"), bulk("42"), "Redis sees memcached arithmetic")

	model_rng: vmath.Rng
	vmath.rng_seed(&model_rng, seed ~ 0x32a46b6755c1823d)
	counter := 0
	for _ in 0 ..< steps {
		amount := 1 + int(vmath.rng_next(&model_rng) % 99)
		counter += amount
		text := fmt.tprintf("%d", amount)
		if vmath.rng_next(&model_rng) & 1 == 0 {
			input := cat(resp("INCRBY", "counter", text), resp("GET", "counter"))
			exchange(1, input, cat(integer(counter), bulk(fmt.tprintf("%d", counter))), "string counter matches model")
		} else {
			input := cat(resp("MULTI"), resp("INCRBY", "counter", text), resp("GET", "counter"), resp("EXEC"))
			expected := cat("+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n", integer(counter), bulk(fmt.tprintf("%d", counter)))
			exchange(1, input, expected, "transaction results and final counter match model")
		}
		free_all(context.temp_allocator)
	}
	exchange(1, cat(resp("SET", "exp", "before", "PX", "5000"), resp("GET", "exp")), cat("+OK\r\n", bulk("before")), "TTL remains visible before expiry")
	exchange(2, "set mcexp 0 5 1\r\nx\r\n", "STORED\r\n", "memcached TTL accepted")
	advance(6000)
	trace("cron time=%d", millis)
	engine.simulation_cron()
	exchange(1, resp("GET", "exp"), "$-1\r\n", "virtual clock expiry removes Redis key")
	exchange(2, "get mcexp\r\n", "END\r\n", "virtual clock expiry removes memcached key")

	open_link(3, .Redis)
	exchange(3, resp("PING"), "+PONG\r\n", "ordinary command completes before reset")
	packet(3, {.ERR}, 0)
	require(!links[3].alive, "reset closes a completed Redis exchange")

	open_link(4, .Memcached)
	exchange(4, "get absent\r\n", "END\r\n", "ordinary memcached command completes before half-close")
	links[4].eof = true
	packet(4, {.IN}, 0)
	require(!links[4].alive, "half-close ends the completed memcached exchange")

	open_link(5, .Redis)
	exchange(5, resp("PING"), "+PONG\r\n", "ordinary Redis command completes before half-close")
	links[5].eof = true
	packet(5, {.IN}, 0)
	require(!links[5].alive, "half-close ends the completed Redis exchange")
}

run_visibility :: proc(seed: u64, steps: int, owners, hidden: bool) {
	start_network(seed, true, owners)
	open_link(1, .Redis)
	open_link(2, .Redis)
	exchange(1, resp("AUTH", "visible", "simulation"), "+OK\r\n", "authenticate the visible reader")
	exchange(2, resp("AUTH", "hidden", "simulation"), "+OK\r\n", "authenticate the hidden writer")
	if hidden {
		exchange(2, resp("SET", "key", "other"), "+OK\r\n", "hidden scope writes its own copy")
		exchange(2, resp("SET", "shadow", "other"), "+OK\r\n", "hidden scope writes a disjoint key")
		exchange(2, resp("GET", "key"), bulk("other"), "hidden writer sees its own value")
	}
	exchange(1, resp("SET", "key", "public"), "+OK\r\n", "visible scope initializes key independently")

	vmath.rng_seed(&network_rng, seed)
	for _ in 0 ..< steps {
		if owners {
			request := cat(resp("GET", "key"), resp("GET", "shadow"))
			exchange(1, request, cat(bulk("public"), "$-1\r\n"), "visible owner's replies omit another owner's keys", true)
		} else {
			request := cat(resp("GET", "key"), resp("GET", "shadow"))
			exchange(1, request, cat(bulk("public"), "$-1\r\n"), "low clearance replies omit high-labelled keys", true)
		}
		free_all(context.temp_allocator)
	}
}
