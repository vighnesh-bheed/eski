package main

import "core:sys/linux"
import "core:testing"
import "seal"

@(private = "file")
manifest_fixture :: proc() -> (m: Aof_Manifest) {
	m.base = Aof_File {
		seq  = 3,
		kind = .Base,
	}
	append(&m.base.name, "appendonly.aof.3.base.rdb")
	m.has_base = true
	m.base_seq = 3
	f := Aof_File {
		seq  = 7,
		kind = .Incr,
	}
	append(&f.name, "appendonly.aof.7.incr.aof")
	append(&m.incr, f)
	g := Aof_File {
		seq  = 8,
		kind = .Incr,
	}
	append(&g.name, "appendonly.aof.8.incr.aof")
	append(&m.incr, g)
	m.incr_seq = 8
	return
}

@(test)
manifest_lines_carry_salt_and_size_only_for_sealed_files :: proc(t: ^testing.T) {
	saved := seal_on
	defer seal_on = saved
	m := manifest_fixture()
	defer aof_manifest_free(&m)
	text: [dynamic]u8
	defer delete(text)
	seal_on = false
	aof_manifest_text(&m, &text)
	plain := "file appendonly.aof.3.base.rdb seq 3 type b\nfile appendonly.aof.7.incr.aof seq 7 type i\nfile appendonly.aof.8.incr.aof seq 8 type i\n"
	testing.expect_value(t, string(text[:]), plain)
	for i in 0 ..< seal.SALT_SIZE {
		m.base.salt[i] = u8(i)
		m.incr[0].salt[i] = u8(0xa0 + i)
		m.incr[1].salt[i] = u8(0x10 + i)
	}
	m.base.sealed = true
	m.incr[0].sealed = true
	m.incr[0].has_size = true
	m.incr[0].size = 4242
	m.incr[1].sealed = true
	seal_on = true
	aof_manifest_text(&m, &text)
	sealed := "file appendonly.aof.3.base.rdb seq 3 type b salt 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\nfile appendonly.aof.7.incr.aof seq 7 type i salt a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf size 4242\nfile appendonly.aof.8.incr.aof seq 8 type i salt 101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f\n"
	testing.expect_value(t, string(text[:]), sealed)
	back: Aof_Manifest
	ok, _ := aof_manifest_parse(text[:], &back)
	testing.expect(t, ok)
	testing.expect(t, back.base.sealed && back.base.salt == m.base.salt && !back.base.has_size)
	testing.expect(t, back.incr[0].sealed && back.incr[0].salt == m.incr[0].salt && back.incr[0].has_size && back.incr[0].size == 4242)
	testing.expect(t, back.incr[1].sealed && !back.incr[1].has_size)
	again: [dynamic]u8
	defer delete(again)
	aof_manifest_text(&back, &again)
	testing.expect_value(t, string(again[:]), sealed)
	aof_manifest_free(&back)
	bad := [?]string {
		"file a seq 1 type i salt 00\n",
		"file a seq 1 type i salt zz02030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\n",
		"file a seq 1 type i size -1\n",
		"file a seq 1 type i size x\n",
	}
	for b in bad {
		ok2, _ := aof_manifest_parse(transmute([]u8)b, &back)
		testing.expect(t, !ok2)
	}
	seal_on = false
	ok3, _ := aof_manifest_parse(transmute([]u8)string("file a seq 1 type i salt 00 size x\n"), &back)
	testing.expect(t, ok3)
	testing.expect(t, !back.incr[0].sealed && !back.incr[0].has_size)
	aof_manifest_free(&back)
}

@(test)
the_previous_key_opens_files_only_while_the_server_starts :: proc(t: ^testing.T) {
	saved_on, saved_keys, saved_phase := seal_on, seal_keys, seal_startup_phase
	defer {
		seal_on = saved_on
		seal_keys = saved_keys
		seal_startup_phase = saved_phase
	}
	keys: Seal_Keys
	for i in 0 ..< seal.KEY_SIZE {
		keys.current.bytes[i] = u8(i)
		keys.previous.bytes[i] = u8(i + 1)
	}
	seal.key_set_id(&keys.current)
	seal.key_set_id(&keys.previous)
	keys.has_previous = true
	seal_keys = &keys
	seal_on = true
	seal_startup_phase = true
	k, use := seal_key_for(keys.current.id)
	testing.expect(t, k == &keys.current && use == .Current)
	k, use = seal_key_for(keys.previous.id)
	testing.expect(t, k == &keys.previous && use == .Previous)
	seal_startup_phase = false
	k, use = seal_key_for(keys.previous.id)
	testing.expect(t, k == nil && use == .None)
	other: seal.Key
	seal.key_set_id(&other)
	k, use = seal_key_for(other.id)
	testing.expect(t, k == nil)
	seal_on = false
	k, use = seal_key_for(keys.current.id)
	testing.expect(t, k == nil)
	seal_keys = &keys
	seal_wipe_keys()
	testing.expect(t, keys.current.bytes == {} && keys.previous.bytes == {})
}

@(private = "file")
drain_pipe :: proc(fd: linux.Fd, out: ^[dynamic]u8) {
	chunk: [8192]u8
	for {
		n, err := linux.read(fd, chunk[:])
		if err != .NONE || n <= 0 {
			return
		}
		append(out, ..chunk[:n])
	}
}

@(test)
a_failed_sealed_write_is_retried_with_the_same_bytes :: proc(t: ^testing.T) {
	saved_on, saved_keys, saved_fsync := seal_on, seal_keys, aof.fsync
	keys: Seal_Keys
	for i in 0 ..< seal.KEY_SIZE {
		keys.current.bytes[i] = u8(3 * i + 1)
	}
	seal.key_set_id(&keys.current)
	seal_keys = &keys
	seal_on = true
	aof.fsync = .No
	pipes: [2]linux.Fd
	testing.expect_value(t, linux.pipe2(&pipes, {.NONBLOCK, .CLOEXEC}), linux.Errno.NONE)
	defer {
		aof_seal_close()
		aof.fd = -1
		delete(aof.buf)
		aof.buf = nil
		aof.write_err = false
		linux.close(pipes[0])
		linux.close(pipes[1])
		seal_on = saved_on
		seal_keys = saved_keys
		aof.fsync = saved_fsync
	}
	testing.expect(t, aof_seal_prepare(pipes[1], "pipe"))
	aof_switch_fd(pipes[1])
	stream: [dynamic]u8
	defer delete(stream)
	expected: [dynamic]u8
	defer delete(expected)
	append(&expected, ..aof.buf[:])
	first := make([]u8, 3 * seal.SEGMENT_MAX + 999, context.temp_allocator)
	for &b, i in first {
		b = u8(i * 13 + 5)
	}
	append(&aof.buf, ..first)
	append(&expected, ..first)
	testing.expect(t, !aof_write_buffer())
	testing.expect(t, aof.write_err)
	drain_pipe(pipes[0], &stream)
	second := transmute([]u8)string("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n")
	append(&aof.buf, ..second)
	append(&expected, ..second)
	rounds := 0
	for !aof_write_buffer() {
		drain_pipe(pipes[0], &stream)
		rounds += 1
		testing.expect(t, rounds < 100)
		if rounds >= 100 {
			return
		}
	}
	drain_pipe(pipes[0], &stream)
	testing.expect(t, rounds > 0)
	testing.expect_value(t, len(aof.buf), 0)
	file, err := linux.memfd_create("retry", {})
	testing.expect_value(t, err, linux.Errno.NONE)
	defer linux.close(file)
	seal.write_all(file, stream[:])
	header: [seal.HEADER_SIZE]u8
	copy(header[:], stream[:seal.HEADER_SIZE])
	r: seal.File_Reader
	seal.reader_init(&r, file, i64(len(stream)), &keys.current, header, .Incremental, .Live)
	defer seal.reader_destroy(&r)
	back := make([]u8, len(expected) + 10, context.temp_allocator)
	n := seal.read(&r, back)
	testing.expect_value(t, r.state, seal.State.End)
	testing.expect_value(t, n, len(expected))
	testing.expect(t, string(back[:n]) == string(expected[:]))
	testing.expect_value(t, r.index, u64(5))
	testing.expect_value(t, len(stream), seal.HEADER_SIZE + len(expected) + 5 * seal.SEGMENT_OVERHEAD)
}
