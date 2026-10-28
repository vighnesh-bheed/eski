package persistence

import "base:runtime"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import j "../../src"
import "../../src/rdb"

Image :: struct {
	w: rdb.Writer,
}

image_begin :: proc(img: ^Image, magic: string = "REDIS0012", checksum: bool = true) {
	rdb.writer_init_mem(&img.w, false, checksum)
	rdb.put_raw(&img.w, transmute([]u8)magic)
}

image_db :: proc(img: ^Image, id: u64, size: u64, expires: u64) {
	rdb.put_u8(&img.w, rdb.OPCODE_SELECTDB)
	rdb.put_len(&img.w, id)
	rdb.put_u8(&img.w, rdb.OPCODE_RESIZEDB)
	rdb.put_len(&img.w, size)
	rdb.put_len(&img.w, expires)
}

image_string :: proc(img: ^Image, key: string, value: string) {
	rdb.put_type(&img.w, rdb.TYPE_STRING)
	rdb.put_string(&img.w, transmute([]u8)key)
	rdb.put_string(&img.w, transmute([]u8)value)
}

image_end :: proc(img: ^Image) -> []u8 {
	rdb.put_trailer(&img.w)
	out := strings.clone(string(rdb.writer_bytes(&img.w)), context.temp_allocator)
	rdb.writer_destroy(&img.w)
	return transmute([]u8)out
}

@(test)
every_opcode_is_accepted :: proc(t: ^testing.T) {
	server_reset()
	img: Image
	image_begin(&img)
	rdb.put_header(&img.w, 1, 2, false)
	img.w.len = 0
	image_begin(&img)
	rdb.put_aux(&img.w, "redis-ver", transmute([]u8)string("7.4.11"))
	rdb.put_aux(&img.w, "made-up-field", transmute([]u8)string("ignored"))
	rdb.put_aux_int(&img.w, "aof-base", 0)
	rdb.put_u8(&img.w, rdb.OPCODE_FUNCTION2)
	rdb.put_string(&img.w, transmute([]u8)string("#!lua name=lib\nredis.register_function('f', function() return 1 end)"))
	image_db(&img, 0, 4, 2)
	rdb.put_u8(&img.w, rdb.OPCODE_SLOT_INFO)
	rdb.put_len(&img.w, 1)
	rdb.put_len(&img.w, 4)
	rdb.put_len(&img.w, 2)
	far := unix_ms() + 3_600_000
	rdb.put_u8(&img.w, rdb.OPCODE_EXPIRETIME_MS)
	rdb.put_ms(&img.w, far)
	image_string(&img, "ms", "a")
	rdb.put_u8(&img.w, rdb.OPCODE_EXPIRETIME)
	secs := u32(far / 1000 + 60)
	rdb.put_raw(&img.w, {u8(secs), u8(secs >> 8), u8(secs >> 16), u8(secs >> 24)})
	image_string(&img, "secs", "b")
	rdb.put_u8(&img.w, rdb.OPCODE_IDLE)
	rdb.put_len(&img.w, 500)
	image_string(&img, "idle", "c")
	rdb.put_u8(&img.w, rdb.OPCODE_FREQ)
	rdb.put_u8(&img.w, 77)
	image_string(&img, "freq", "d")
	rdb.put_type(&img.w, rdb.TYPE_LIST_QUICKLIST_2)
	rdb.put_string(&img.w, transmute([]u8)string("empty-list"))
	rdb.put_len(&img.w, 0)
	image_db(&img, 5, 1, 0)
	image_string(&img, "five", "e")
	data := image_end(&img)
	testing.expect_value(t, load_image(data), j.Load_Result.Ok)
	testing.expect_value(t, j.pst.last_load_loaded, 5)
	expect_reply(t, cmd("GET", "ms"), bulk("a"), "ms expire")
	ttl := cmd("PTTL", "ms")
	testing.expectf(t, strings.has_prefix(ttl, ":35") || strings.has_prefix(ttl, ":36"), "pttl %q", ttl)
	secs_ttl := cmd("TTL", "secs")
	testing.expectf(t, secs_ttl == ":3660\r\n" || secs_ttl == ":3659\r\n", "legacy seconds expire %q", secs_ttl)
	expect_reply(t, cmd("OBJECT", "IDLETIME", "idle"), integer(500), "idle opcode")
	expect_reply(t, cmd("EXISTS", "empty-list"), integer(0), "empty key skipped")
	expect_reply(t, cmd("SELECT", "5"), "+OK\r\n", "select")
	expect_reply(t, cmd("GET", "five"), bulk("e"), "db 5")
	expect_reply(t, cmd("SELECT", "0"), "+OK\r\n", "select")
	server_reset()
	j.maxmemory_policy = .Allkeys_Lfu
	j.evict_policy_changed()
	testing.expect_value(t, load_image(data), j.Load_Result.Ok)
	expect_reply(t, cmd("OBJECT", "FREQ", "freq"), integer(77), "freq opcode")
	server_reset()
	old: Image
	image_begin(&old, "REDIS0004")
	image_db(&old, 0, 1, 0)
	image_string(&old, "old", "v")
	rdb.put_u8(&old.w, rdb.OPCODE_EOF)
	ancient := strings.clone(string(rdb.writer_bytes(&old.w)), context.temp_allocator)
	rdb.writer_destroy(&old.w)
	testing.expect_value(t, load_image(transmute([]u8)ancient), j.Load_Result.Ok)
	expect_reply(t, cmd("GET", "old"), bulk("v"), "version 4 without checksum")
	server_reset()
	expired: Image
	image_begin(&expired)
	image_db(&expired, 0, 2, 1)
	rdb.put_u8(&expired.w, rdb.OPCODE_EXPIRETIME_MS)
	rdb.put_ms(&expired.w, 1000)
	image_string(&expired, "gone", "x")
	image_string(&expired, "kept", "y")
	exp_data := image_end(&expired)
	dir := test_dir()
	defer cleanup_dir(dir)
	testing.expect(t, write_file(join_path(dir, "dump.rdb"), exp_data))
	enter_dir(dir)
	testing.expect_value(t, j.persist_rdb_load(false, false), j.Load_Result.Ok)
	leave_dir()
	testing.expect_value(t, j.pst.last_load_expired, 1)
	testing.expect_value(t, j.pst.last_load_loaded, 1)
	expect_reply(t, cmd("DBSIZE"), integer(1), "expired skipped")
	server_reset()
	testing.expect_value(t, load_image(exp_data), j.Load_Result.Ok)
	testing.expect_value(t, j.db_size_of(&j.dbs[0]), 2)
	server_reset()
}

@(test)
signature_and_version_rejections :: proc(t: ^testing.T) {
	server_reset()
	cases := []string{"RADIS0012", "REDIS0013", "REDIS0000", "REDIS00x2", "redis0012"}
	for magic in cases {
		img: Image
		image_begin(&img, magic)
		image_db(&img, 0, 1, 0)
		image_string(&img, "k", "v")
		data := image_end(&img)
		testing.expectf(t, load_image(data) == .Failed, "%s accepted", magic)
		testing.expect_value(t, j.db_size_of(&j.dbs[0]), 0)
	}
	for v in 1 ..= 12 {
		buf: [8]u8
		digits := itoa(buf[:], i64(v))
		magic := strings.concatenate({"REDIS", strings.repeat("0", 4 - len(digits), context.temp_allocator), digits}, context.temp_allocator)
		img: Image
		image_begin(&img, magic)
		image_db(&img, 0, 1, 0)
		image_string(&img, "k", "v")
		data := image_end(&img)
		if v < 5 {
			data = data[:len(data) - 8]
		}
		server_reset()
		testing.expectf(t, load_image(data) == .Ok, "version %d refused", v)
	}
	server_reset()
}

child_image: []u8
child_merge: bool

child_load :: proc() {
	context.allocator = runtime.heap_allocator()
	server_ready()
	j.db_flush_all()
	result := load_image(child_image)
	if result == .Ok {
		result = load_image(child_image, child_merge)
	}
	linux.exit_group(0 if result == .Ok else 3)
}

child_dir: string

child_load_disk :: proc() {
	context.allocator = runtime.heap_allocator()
	server_ready()
	j.db_flush_all()
	enter_dir(child_dir)
	result := j.persist_rdb_load(false, false)
	linux.exit_group(0 if result == .Ok else 3)
}

expect_fatal :: proc(t: ^testing.T, data: []u8, label: string, want: int = 1, merge := false, loc := #caller_location) {
	child_image = data
	child_merge = merge
	exited, code := run_in_child(child_load)
	testing.expectf(t, exited && code == want, "%s: exited=%v code=%d want %d", label, exited, code, want, loc = loc)
}

@(test)
fatal_load_failures :: proc(t: ^testing.T) {
	server_reset()
	{
		img: Image
		image_begin(&img)
		image_db(&img, 0, 1, 0)
		image_string(&img, "k", "v")
		good := image_end(&img)
		expect_fatal(t, good, "loads twice without merge: duplicate key", 1)
		expect_fatal(t, good, "loads twice with merge", 0, true)
		bad_crc := make([]u8, len(good), context.temp_allocator)
		copy(bad_crc, good)
		bad_crc[len(bad_crc) - 1] ~= 0x55
		expect_fatal(t, bad_crc, "checksum mismatch", 1)
		zero_crc := make([]u8, len(good), context.temp_allocator)
		copy(zero_crc, good)
		for i in len(zero_crc) - 8 ..< len(zero_crc) {
			zero_crc[i] = 0
		}
		testing.expect_value(t, load_image(zero_crc), j.Load_Result.Ok)
		server_reset()
		j.pst.skip_checksum = true
		testing.expect_value(t, load_image(bad_crc), j.Load_Result.Ok)
		server_reset()
		for cut in ([]int{9, 12, len(good) - 9, len(good) - 4}) {
			expect_fatal(t, good[:cut], "truncated file", 1)
		}
	}
	{
		img: Image
		image_begin(&img)
		image_db(&img, 0, 1, 0)
		rdb.put_type(&img.w, 30)
		rdb.put_string(&img.w, transmute([]u8)string("k"))
		expect_fatal(t, image_end(&img), "unknown value type", 1)
	}
	{
		img: Image
		image_begin(&img)
		rdb.put_u8(&img.w, rdb.OPCODE_MODULE_AUX)
		rdb.put_len(&img.w, 0x12345678 << 10)
		expect_fatal(t, image_end(&img), "module aux", 1)
	}
	{
		img: Image
		image_begin(&img)
		rdb.put_u8(&img.w, rdb.OPCODE_FUNCTION_PRE_GA)
		expect_fatal(t, image_end(&img), "pre-release functions", 1)
	}
	{
		img: Image
		image_begin(&img)
		image_db(&img, 0, 1, 0)
		rdb.put_type(&img.w, rdb.TYPE_MODULE_2)
		rdb.put_string(&img.w, transmute([]u8)string("k"))
		rdb.put_len(&img.w, 77 << 10)
		expect_fatal(t, image_end(&img), "module value", 1)
	}
	{
		img: Image
		image_begin(&img)
		image_db(&img, 0, 1, 0)
		rdb.put_type(&img.w, rdb.TYPE_MODULE_PRE_GA)
		rdb.put_string(&img.w, transmute([]u8)string("k"))
		expect_fatal(t, image_end(&img), "pre-release module value", 1)
	}
	{
		img: Image
		image_begin(&img)
		image_db(&img, 99999, 1, 0)
		image_string(&img, "k", "v")
		expect_fatal(t, image_end(&img), "database out of range", 1)
	}
	{
		img: Image
		image_begin(&img)
		image_db(&img, 0, 1, 0)
		rdb.put_type(&img.w, rdb.TYPE_SET_LISTPACK)
		rdb.put_string(&img.w, transmute([]u8)string("k"))
		rdb.put_string(&img.w, transmute([]u8)string("not a listpack"))
		expect_fatal(t, image_end(&img), "corrupt listpack", 1)
	}
	{
		img: Image
		image_begin(&img)
		image_db(&img, 0, 1, 0)
		rdb.put_type(&img.w, rdb.TYPE_STRING)
		rdb.put_string(&img.w, transmute([]u8)string("k"))
		rdb.put_raw(&img.w, {0xC3, 0x02, 0x10, 0x00, 0x00})
		expect_fatal(t, image_end(&img), "corrupt lzf", 1)
	}
	{
		img: Image
		image_begin(&img)
		image_db(&img, 0, 1, 0)
		rdb.put_type(&img.w, rdb.TYPE_STRING)
		rdb.put_string(&img.w, transmute([]u8)string("k"))
		rdb.put_len(&img.w, 1 << 39)
		huge := image_end(&img)
		dir := test_dir()
		defer cleanup_dir(dir)
		testing.expect(t, write_file(join_path(dir, "dump.rdb"), huge))
		child_dir = dir
		exited, code := run_in_child(child_load_disk)
		testing.expectf(t, exited && code == 1, "huge length from disk: exited=%v code=%d", exited, code)
		expect_fatal(t, huge, "huge length in memory", 1)
	}
	server_reset()
}
