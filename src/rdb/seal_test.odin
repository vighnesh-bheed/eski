package rdb

import "core:sys/linux"
import "core:testing"
import "../seal"

@(private = "file")
fixture_key :: proc() -> (k: seal.Key) {
	for i in 0 ..< seal.KEY_SIZE {
		k.bytes[i] = u8(200 - i)
	}
	seal.key_set_id(&k)
	return
}

@(test)
a_sealed_writer_and_reader_carry_the_stream_unchanged :: proc(t: ^testing.T) {
	key := fixture_key()
	fd, err := linux.memfd_create("rdb-seal", {})
	testing.expect_value(t, err, linux.Errno.NONE)
	defer linux.close(fd)
	big := make([]u8, WRITER_DIRECT + 12345, context.temp_allocator)
	for &b, i in big {
		b = u8(i * 7 + 3)
	}
	salt: [seal.SALT_SIZE]u8
	salt[0] = 1
	sw: seal.File_Writer
	seal.file_writer_init(&sw, fd, &key, .Snapshot, salt)
	w: Writer
	writer_init_file(&w, fd, true, true)
	w.seal = &sw
	put_header(&w, 1, 2, false)
	put_u8(&w, OPCODE_SELECTDB)
	for i in 0 ..< 3000 {
		put_string(&w, transmute([]u8)string("a value that repeats a value that repeats"))
		put_len(&w, u64(i))
	}
	put_raw(&w, big)
	put_trailer(&w)
	testing.expect(t, writer_flush(&w))
	testing.expect(t, writer_seal_finish(&w))
	plain_bytes := writer_processed(&w)
	writer_destroy(&w)
	seal.file_writer_destroy(&sw)
	sb: linux.Stat
	linux.fstat(fd, &sb)
	head: [seal.HEADER_SIZE]u8
	linux.pread(fd, head[:], 0)
	h, res := seal.header_parse(head[:])
	testing.expect_value(t, res, seal.Header_Result.Ok)
	testing.expect_value(t, h.kind, seal.Kind.Snapshot)
	segments := (int(plain_bytes) + seal.SEGMENT_MAX - 1) / seal.SEGMENT_MAX
	testing.expect_value(t, i64(sb.size), i64(seal.HEADER_SIZE) + plain_bytes + i64(segments * seal.SEGMENT_OVERHEAD))
	sr: seal.File_Reader
	seal.reader_init(&sr, fd, i64(sb.size), &key, head, .Snapshot, .Closed)
	defer seal.reader_destroy(&sr)
	r: Reader
	reader_init_file(&r, fd, true)
	defer reader_destroy(&r)
	r.seal = &sr
	magic, got := take(&r, 9)
	testing.expect(t, got)
	testing.expect_value(t, string(magic[:5]), "REDIS")
	testing.expect(t, reader_remaining(&r) >= plain_bytes - 9)
	for {
		kind := get_type(&r)
		if kind != OPCODE_AUX {
			testing.expect_value(t, kind, int(OPCODE_SELECTDB))
			break
		}
		get_string(&r, 0)
		get_string(&r, 1)
	}
	for i in 0 ..< 3000 {
		s, good := get_string(&r, 0)
		testing.expect(t, good)
		testing.expect_value(t, string(s), "a value that repeats a value that repeats")
		testing.expect_value(t, get_len(&r), u64(i))
	}
	rest, taken := take(&r, len(big))
	testing.expect(t, taken)
	same := true
	for i in 0 ..< len(big) {
		if rest[i] != big[i] {
			same = false
			break
		}
	}
	testing.expect(t, same)
	testing.expect_value(t, get_type(&r), int(OPCODE_EOF))
	_, sum_ok := get_ms(&r)
	testing.expect(t, sum_ok)
	testing.expect(t, ok(&r))
	testing.expect(t, seal.finish(&sr))
}

@(test)
a_damaged_sealed_stream_marks_the_reader_corrupt :: proc(t: ^testing.T) {
	key := fixture_key()
	fd, _ := linux.memfd_create("rdb-seal", {})
	defer linux.close(fd)
	salt: [seal.SALT_SIZE]u8
	sw: seal.File_Writer
	seal.file_writer_init(&sw, fd, &key, .Snapshot, salt)
	w: Writer
	writer_init_file(&w, fd, false, false)
	w.seal = &sw
	data := make([]u8, 3 * seal.SEGMENT_MAX, context.temp_allocator)
	put_raw(&w, data)
	writer_flush(&w)
	writer_seal_finish(&w)
	writer_destroy(&w)
	seal.file_writer_destroy(&sw)
	flip := [1]u8{0x55}
	linux.pwrite(fd, flip[:], i64(seal.HEADER_SIZE + seal.SEGMENT_MAX + seal.SEGMENT_OVERHEAD + 100))
	sb: linux.Stat
	linux.fstat(fd, &sb)
	head: [seal.HEADER_SIZE]u8
	linux.pread(fd, head[:], 0)
	sr: seal.File_Reader
	seal.reader_init(&sr, fd, i64(sb.size), &key, head, .Snapshot, .Closed)
	defer seal.reader_destroy(&sr)
	r: Reader
	reader_init_file(&r, fd, false)
	defer reader_destroy(&r)
	r.seal = &sr
	_, got := take(&r, len(data))
	testing.expect(t, !got)
	testing.expect_value(t, r.status, Status.Corrupt)
	testing.expect_value(t, reader_reason(&r), "encrypted segment 1 of the data file fails its check")
	testing.expect_value(t, sr.state, seal.State.Damaged)
}
