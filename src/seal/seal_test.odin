package seal

import "core:crypto/aes"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:sys/linux"
import "core:testing"

@(private = "file")
unhex :: proc(s: string) -> []u8 {
	out := make([]u8, len(s) / 2, context.temp_allocator)
	for i in 0 ..< len(out) {
		hi, _ := hex_digit(s[2 * i])
		lo, _ := hex_digit(s[2 * i + 1])
		out[i] = hi << 4 | lo
	}
	return out
}

@(private = "file")
tohex :: proc(b: []u8) -> string {
	digits := "0123456789abcdef"
	out := make([]u8, 2 * len(b), context.temp_allocator)
	for c, i in b {
		out[2 * i] = digits[c >> 4]
		out[2 * i + 1] = digits[c & 15]
	}
	return string(out)
}

@(private = "file")
same :: proc(a: []u8, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

@(private = "file")
test_key :: proc(first: u8 = 0) -> (k: Key) {
	for i in 0 ..< KEY_SIZE {
		k.bytes[i] = first + u8(i)
	}
	key_set_id(&k)
	return
}

@(private = "file")
test_salt :: proc(first: u8) -> (s: [SALT_SIZE]u8) {
	for i in 0 ..< SALT_SIZE {
		s[i] = first + u8(i)
	}
	return
}

@(private = "file")
pattern :: proc(n: int, seed: int = 7) -> []u8 {
	out := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		out[i] = u8((i * 31 + seed) ~ (i >> 9))
	}
	return out
}

@(private = "file")
memory_file :: proc(data: []u8) -> linux.Fd {
	fd, err := linux.memfd_create("seal-test", {})
	if err != .NONE {
		return -1
	}
	write_all(fd, data)
	return fd
}

@(private = "file")
seal_file_bytes :: proc(key: ^Key, kind: Kind, salt: [SALT_SIZE]u8, plain: []u8, pieces: int = 1) -> []u8 {
	fd, err := linux.memfd_create("seal-test", {})
	if err != .NONE {
		return nil
	}
	defer linux.close(fd)
	w: File_Writer
	file_writer_init(&w, fd, key, kind, salt)
	step := max(len(plain) / max(pieces, 1), 1)
	at := 0
	for at < len(plain) {
		n := min(step, len(plain) - at)
		file_write(&w, plain[at:][:n])
		at += n
	}
	file_finish(&w)
	file_writer_destroy(&w)
	sb: linux.Stat
	linux.fstat(fd, &sb)
	out := make([]u8, int(sb.size), context.temp_allocator)
	linux.pread(fd, out, 0)
	return out
}

@(private = "file")
Opened :: struct {
	state: State,
	plain: []u8,
	cut:   i64,
	keyed: bool,
}

@(private = "file")
open_bytes :: proc(key: ^Key, data: []u8, kind: Kind, mode: Mode) -> (o: Opened) {
	h, res := header_parse(data)
	if res != .Ok {
		o.state = .Damaged
		return
	}
	if h.kind != kind || !same_key_id(h.key_id, key.id) {
		o.state = .Damaged
		return
	}
	o.keyed = true
	fd := memory_file(data)
	defer linux.close(fd)
	header: [HEADER_SIZE]u8
	copy(header[:], data[:HEADER_SIZE])
	r: File_Reader
	reader_init(&r, fd, i64(len(data)), key, header, kind, mode)
	defer reader_destroy(&r)
	out: [dynamic]u8
	out.allocator = context.temp_allocator
	chunk: [4096]u8
	for {
		n := read(&r, chunk[:])
		if n == 0 {
			break
		}
		append(&out, ..chunk[:n])
	}
	if r.state == .Open {
		finish(&r)
	}
	o.state = r.state
	o.plain = out[:]
	o.cut = r.cut
	return
}

@(private = "file")
segment_starts :: proc(data: []u8) -> []int {
	out: [dynamic]int
	out.allocator = context.temp_allocator
	at := HEADER_SIZE
	for at + LENGTH_SIZE <= len(data) {
		append(&out, at)
		n := int(length_value(data[at:][:LENGTH_SIZE]) & LENGTH_MASK)
		at += n + SEGMENT_OVERHEAD
	}
	return out[:]
}

@(test)
aes_256_gcm_known_answers :: proc(t: ^testing.T) {
	Case :: struct {
		key, iv, aad, plain, cipher, tag: string,
	}
	cases := [?]Case {
		{
			key = "0000000000000000000000000000000000000000000000000000000000000000",
			iv = "000000000000000000000000",
			tag = "530f8afbc74536b9a963b4f1c4cb738b",
		},
		{
			key = "0000000000000000000000000000000000000000000000000000000000000000",
			iv = "000000000000000000000000",
			plain = "00000000000000000000000000000000",
			cipher = "cea7403d4d606b6e074ec5d3baf39d18",
			tag = "d0d1c8a799996bf0265b98b5d48ab919",
		},
		{
			key = "feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308",
			iv = "cafebabefacedbaddecaf888",
			plain = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255",
			cipher = "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad",
			tag = "b094dac5d93471bdec1a502270e3cc6c",
		},
		{
			key = "feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308",
			iv = "cafebabefacedbaddecaf888",
			aad = "feedfacedeadbeeffeedfacedeadbeefabaddad2",
			plain = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39",
			cipher = "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662",
			tag = "76fc6ece0f4e1768cddf8853bb2d551b",
		},
	}
	for c in cases {
		key := unhex(c.key)
		plain := unhex(c.plain)
		ct := make([]u8, len(plain), context.temp_allocator)
		tag: [TAG_SIZE]u8
		gcm: aes.Context_GCM
		aes.init_gcm(&gcm, key)
		aes.seal_gcm(&gcm, ct, tag[:], unhex(c.iv), unhex(c.aad), plain)
		testing.expect_value(t, tohex(ct), c.cipher)
		testing.expect_value(t, tohex(tag[:]), c.tag)
		back := make([]u8, len(ct), context.temp_allocator)
		testing.expect(t, aes.open_gcm(&gcm, back, unhex(c.iv), unhex(c.aad), ct, tag[:]))
		testing.expect(t, same(back, plain))
		tag[0] ~= 1
		testing.expect(t, !aes.open_gcm(&gcm, back, unhex(c.iv), unhex(c.aad), ct, tag[:]))
		aes.reset_gcm(&gcm)
	}
	long_key := test_key()
	long := pattern(4219)
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, long_key.bytes[:])
	defer aes.reset_gcm(&gcm)
	first := make([]u8, len(long), context.temp_allocator)
	second := make([]u8, len(long), context.temp_allocator)
	tag_a, tag_b: [TAG_SIZE]u8
	nonce := nonce_of(5, false)
	aes.seal_gcm(&gcm, first, tag_a[:], nonce[:], nil, long)
	aes.seal_gcm(&gcm, second, tag_b[:], nonce[:], nil, long)
	testing.expect(t, same(first, second))
	testing.expect(t, same(tag_a[:], tag_b[:]))
	back := make([]u8, len(long), context.temp_allocator)
	testing.expect(t, aes.open_gcm(&gcm, back, nonce[:], nil, first, tag_a[:]))
	testing.expect(t, same(back, long))
}

@(test)
hkdf_sha256_known_answer :: proc(t: ^testing.T) {
	ikm := make([]u8, 22, context.temp_allocator)
	for &b in ikm {
		b = 0x0b
	}
	out: [42]u8
	hkdf.extract_and_expand(hash.Algorithm.SHA256, unhex("000102030405060708090a0b0c"), ikm, unhex("f0f1f2f3f4f5f6f7f8f9"), out[:])
	testing.expect_value(t, tohex(out[:]), "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
}

@(test)
key_text_rules :: proc(t: ^testing.T) {
	good := "000102030405060708090a0b0c0d0e0f101112131415161718191A1B1C1D1E1F"
	k: Key
	testing.expect(t, key_parse(transmute([]u8)good, &k))
	expect := test_key()
	testing.expect(t, same(k.bytes[:], expect.bytes[:]))
	testing.expect(t, same(k.id[:], expect.id[:]))
	testing.expect_value(t, tohex(k.id[:]), "1138b7c2b653dc1544c87a27cb7547b3")
	with_newline := concat(good, "\n")
	testing.expect(t, key_parse(transmute([]u8)with_newline, &k))
	bad := [?]string {
		"",
		good[:63],
		concat(good, "0"),
		concat(good, "\n\n"),
		concat(good, " "),
		concat(good, "\r\n"),
		concat(good[:62], "zz"),
		concat(" ", good[1:]),
	}
	for b in bad {
		testing.expect(t, !key_parse(transmute([]u8)b, &k))
	}
	other := test_key(1)
	testing.expect(t, !same_key_id(other.id, expect.id))
}

@(private = "file")
concat :: proc(a: string, b: string) -> string {
	out := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

@(test)
golden_envelope_bytes :: proc(t: ^testing.T) {
	key := test_key()
	salt := test_salt(0x40)
	sealed := seal_file_bytes(&key, .Snapshot, salt, transmute([]u8)string("eski"))
	testing.expect_value(t, tohex(sealed), GOLDEN_SNAPSHOT)
	s: Sealer
	sealer_init(&s, &key, .Incremental, test_salt(0x60))
	out: [dynamic]u8
	out.allocator = context.temp_allocator
	append(&out, ..s.header[:])
	seal_batch(&s, transmute([]u8)string("*1\r\n$4\r\nPING\r\n"), &out)
	sealer_destroy(&s)
	testing.expect_value(t, tohex(out[:]), GOLDEN_INCREMENTAL)
	manifest: [dynamic]u8
	manifest.allocator = context.temp_allocator
	seal_whole(&key, .Manifest, test_salt(0x80), transmute([]u8)string("file a seq 1 type i\n"), &manifest)
	testing.expect_value(t, tohex(manifest[:]), GOLDEN_MANIFEST)
}

GOLDEN_SNAPSHOT :: "45534b49454e433101011138b7c2b653dc1544c87a27cb7547b3404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f040000006974b6269c472fc75df93a267fa761511f3a4515"

GOLDEN_INCREMENTAL :: "45534b49454e433103011138b7c2b653dc1544c87a27cb7547b3606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f0e0000004378c4dde880441c9bd744c7a52ec2b7dc59777643afb8f331969c37427b"

GOLDEN_MANIFEST :: "45534b49454e433104011138b7c2b653dc1544c87a27cb7547b3808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f140000008c7e07f6d2c0d1eda0bd2581f1d3eb705752d201951fd1b3243ff8518e63a653b9b65741"

@(test)
round_trips_at_segment_boundaries :: proc(t: ^testing.T) {
	key := test_key()
	sizes := [?]int{0, 1, SEGMENT_MAX - 1, SEGMENT_MAX, SEGMENT_MAX + 1, 2 * SEGMENT_MAX, 3 * SEGMENT_MAX + 123}
	for n, i in sizes {
		plain := pattern(n, i)
		for pieces in ([?]int{1, 7}) {
			sealed := seal_file_bytes(&key, .Snapshot, test_salt(u8(i)), plain, pieces)
			segments := max((n + SEGMENT_MAX - 1) / SEGMENT_MAX, 1)
			testing.expect_value(t, len(sealed), HEADER_SIZE + n + segments * SEGMENT_OVERHEAD)
			o := open_bytes(&key, sealed, .Snapshot, .Closed)
			testing.expect_value(t, o.state, State.End)
			testing.expect(t, same(o.plain, plain))
		}
	}
}

@(test)
every_header_length_and_tag_bit_flip_is_refused :: proc(t: ^testing.T) {
	key := test_key()
	plain := pattern(2 * SEGMENT_MAX + 77)
	sealed := seal_file_bytes(&key, .Snapshot, test_salt(9), plain)
	starts := segment_starts(sealed)
	testing.expect_value(t, len(starts), 3)
	positions: [dynamic]int
	positions.allocator = context.temp_allocator
	for i in 0 ..< HEADER_SIZE {
		append(&positions, i)
	}
	for s, k in starts {
		n := int(length_value(sealed[s:][:LENGTH_SIZE]) & LENGTH_MASK)
		for i in 0 ..< LENGTH_SIZE {
			append(&positions, s + i)
		}
		for i in 0 ..< TAG_SIZE {
			append(&positions, s + LENGTH_SIZE + n + i)
		}
		append(&positions, s + LENGTH_SIZE + min(k * 101, n - 1))
	}
	flipped := make([]u8, len(sealed), context.temp_allocator)
	checked := 0
	for p in positions {
		for bit in 0 ..< 8 {
			copy(flipped, sealed)
			flipped[p] ~= u8(1) << uint(bit)
			o := open_bytes(&key, flipped, .Snapshot, .Closed)
			if o.state == .End {
				testing.expectf(t, false, "a flip of bit %d at byte %d was accepted", bit, p)
			}
			checked += 1
		}
	}
	testing.expect_value(t, checked, 8 * (HEADER_SIZE + 3 * (LENGTH_SIZE + TAG_SIZE + 1)))
}

@(test)
live_file_bit_flips_never_accept_changed_bytes :: proc(t: ^testing.T) {
	key := test_key()
	s: Sealer
	sealer_init(&s, &key, .Incremental, test_salt(3))
	data: [dynamic]u8
	data.allocator = context.temp_allocator
	append(&data, ..s.header[:])
	batches := [?]int{40, 9, SEGMENT_MAX + 10, 300}
	plain: [dynamic]u8
	plain.allocator = context.temp_allocator
	ends: [dynamic]int
	ends.allocator = context.temp_allocator
	for n, i in batches {
		b := pattern(n, i + 1)
		seal_batch(&s, b, &data)
		append(&plain, ..b)
		append(&ends, len(plain))
	}
	sealer_destroy(&s)
	o := open_bytes(&key, data[:], .Incremental, .Live)
	testing.expect_value(t, o.state, State.End)
	testing.expect(t, same(o.plain, plain[:]))
	flipped := make([]u8, len(data), context.temp_allocator)
	starts := segment_starts(data[:])
	positions: [dynamic]int
	positions.allocator = context.temp_allocator
	for i in 0 ..< HEADER_SIZE {
		append(&positions, i)
	}
	for st in starts {
		n := int(length_value(data[st:][:LENGTH_SIZE]) & LENGTH_MASK)
		for i in 0 ..< LENGTH_SIZE {
			append(&positions, st + i)
		}
		for i in 0 ..< TAG_SIZE {
			append(&positions, st + LENGTH_SIZE + n + i)
		}
		if n > 0 {
			append(&positions, st + LENGTH_SIZE + n / 2)
		}
	}
	for p in positions {
		for bit in 0 ..< 8 {
			copy(flipped, data[:])
			flipped[p] ~= u8(1) << uint(bit)
			got := open_bytes(&key, flipped, .Incremental, .Live)
			if !got.keyed {
				continue
			}
			testing.expect(t, got.state != .End)
			testing.expect(t, len(got.plain) < len(plain))
			testing.expect(t, same(got.plain, plain[:len(got.plain)]))
			if got.state == .Torn {
				at_end := len(got.plain) == 0
				for e in ends {
					if e == len(got.plain) {
						at_end = true
					}
				}
				testing.expect(t, at_end)
			}
		}
	}
}

@(test)
swapped_and_foreign_segments_are_refused :: proc(t: ^testing.T) {
	key := test_key()
	plain := pattern(3 * SEGMENT_MAX)
	sealed := seal_file_bytes(&key, .Snapshot, test_salt(1), plain)
	other := seal_file_bytes(&key, .Snapshot, test_salt(2), plain)
	starts := segment_starts(sealed)
	seg := SEGMENT_MAX + SEGMENT_OVERHEAD
	swapped := make([]u8, len(sealed), context.temp_allocator)
	copy(swapped, sealed)
	copy(swapped[starts[0]:][:seg], sealed[starts[1]:][:seg])
	copy(swapped[starts[1]:][:seg], sealed[starts[0]:][:seg])
	testing.expect_value(t, open_bytes(&key, swapped, .Snapshot, .Closed).state, State.Damaged)
	mixed := make([]u8, len(sealed), context.temp_allocator)
	copy(mixed, sealed)
	copy(mixed[starts[1]:][:seg], other[starts[1]:][:seg])
	testing.expect_value(t, open_bytes(&key, mixed, .Snapshot, .Closed).state, State.Damaged)
	header_swap := make([]u8, len(sealed), context.temp_allocator)
	copy(header_swap, sealed)
	copy(header_swap[:HEADER_SIZE], other[:HEADER_SIZE])
	testing.expect_value(t, open_bytes(&key, header_swap, .Snapshot, .Closed).state, State.Damaged)
	as_base := make([]u8, len(sealed), context.temp_allocator)
	copy(as_base, sealed)
	as_base[8] = u8(Kind.Base)
	testing.expect_value(t, open_bytes(&key, as_base, .Base, .Closed).state, State.Damaged)
	wrong := test_key(5)
	testing.expect(t, !open_bytes(&wrong, sealed, .Snapshot, .Closed).keyed)
	appended := make([]u8, len(sealed) + len(other) - HEADER_SIZE, context.temp_allocator)
	copy(appended, sealed)
	copy(appended[len(sealed):], other[HEADER_SIZE:])
	testing.expect_value(t, open_bytes(&key, appended, .Snapshot, .Closed).state, State.Damaged)
}

@(test)
truncation_at_every_boundary_of_a_closed_file_is_refused :: proc(t: ^testing.T) {
	key := test_key()
	plain := pattern(3 * SEGMENT_MAX + 5)
	sealed := seal_file_bytes(&key, .Base, test_salt(4), plain)
	starts := segment_starts(sealed)
	cuts: [dynamic]int
	cuts.allocator = context.temp_allocator
	for s in starts {
		append(&cuts, s, s + 1, s + LENGTH_SIZE, s + LENGTH_SIZE + 1)
	}
	append(&cuts, len(sealed) - 1, len(sealed) - TAG_SIZE)
	for c in cuts {
		o := open_bytes(&key, sealed[:c], .Base, .Closed)
		testing.expect(t, o.state == .Torn || o.state == .Damaged)
		testing.expect(t, len(o.plain) < len(plain))
		testing.expect(t, same(o.plain, plain[:len(o.plain)]))
	}
	for c in 0 ..< HEADER_SIZE {
		_, res := header_parse(sealed[:c])
		testing.expect(t, res != .Ok)
	}
	full := open_bytes(&key, sealed, .Base, .Closed)
	testing.expect_value(t, full.state, State.End)
	testing.expect(t, same(full.plain, plain))
}

@(test)
a_torn_live_tail_is_cut_at_the_start_of_its_write_batch :: proc(t: ^testing.T) {
	key := test_key()
	s: Sealer
	sealer_init(&s, &key, .Incremental, test_salt(6))
	data: [dynamic]u8
	data.allocator = context.temp_allocator
	append(&data, ..s.header[:])
	first := pattern(100, 1)
	seal_batch(&s, first, &data)
	batch_at := len(data)
	big := pattern(2 * SEGMENT_MAX + 50, 2)
	seal_batch(&s, big, &data)
	sealer_destroy(&s)
	starts := segment_starts(data[:])
	testing.expect_value(t, len(starts), 4)
	whole := open_bytes(&key, data[:], .Incremental, .Live)
	testing.expect_value(t, whole.state, State.End)
	testing.expect_value(t, len(whole.plain), 100 + len(big))
	for cut in ([?]int{starts[1] + 3, starts[2], starts[2] + 70, starts[3], len(data) - 1}) {
		o := open_bytes(&key, data[:cut], .Incremental, .Live)
		testing.expect_value(t, o.state, State.Torn)
		testing.expect_value(t, o.cut, i64(batch_at))
		testing.expect(t, same(o.plain, first))
		b := open_bytes(&key, data[:cut], .Incremental, .Bounded)
		testing.expect(t, b.state == .Damaged || b.state == .Torn)
	}
	long_word := make([]u8, len(data), context.temp_allocator)
	copy(long_word, data[:])
	long_word[starts[2] + 3] = 0x40
	damaged := open_bytes(&key, long_word, .Incremental, .Live)
	testing.expect_value(t, damaged.state, State.Damaged)
	testing.expect(t, same(damaged.plain, first))
	at_boundary := open_bytes(&key, data[:batch_at], .Incremental, .Live)
	testing.expect_value(t, at_boundary.state, State.End)
	testing.expect(t, same(at_boundary.plain, first))
	only_header := open_bytes(&key, data[:HEADER_SIZE], .Incremental, .Live)
	testing.expect_value(t, only_header.state, State.End)
	testing.expect_value(t, len(only_header.plain), 0)
}

@(test)
a_sealer_never_reuses_an_index_and_stops_after_closing :: proc(t: ^testing.T) {
	key := test_key()
	s: Sealer
	sealer_init(&s, &key, .Incremental, test_salt(8))
	out: [dynamic]u8
	out.allocator = context.temp_allocator
	for i in 0 ..< 5 {
		testing.expect_value(t, s.index, u64(i))
		testing.expect(t, seal_segment(&s, pattern(10, i), &out, false, false))
	}
	testing.expect(t, !seal_segment(&s, pattern(SEGMENT_MAX + 1), &out, false, false))
	testing.expect_value(t, s.index, u64(5))
	testing.expect(t, !seal_segment(&s, pattern(1), &out, true, true))
	testing.expect(t, seal_segment(&s, nil, &out, true, false))
	testing.expect(t, !seal_segment(&s, pattern(3), &out, false, false))
	testing.expect_value(t, s.index, u64(6))
	sealer_destroy(&s)
	a, b: Sealer
	sealer_init(&a, &key, .Incremental, test_salt(8))
	sealer_init(&b, &key, .Incremental, test_salt(9))
	x: [dynamic]u8
	y: [dynamic]u8
	x.allocator = context.temp_allocator
	y.allocator = context.temp_allocator
	seal_segment(&a, pattern(64), &x, false, false)
	seal_segment(&b, pattern(64), &y, false, false)
	testing.expect(t, !same(x[:], y[:]))
	sealer_destroy(&a)
	sealer_destroy(&b)
}

@(test)
a_manifest_is_one_closing_segment :: proc(t: ^testing.T) {
	key := test_key()
	text := transmute([]u8)string("file appendonly.aof.1.base.rdb seq 1 type b\n")
	sealed: [dynamic]u8
	sealed.allocator = context.temp_allocator
	testing.expect(t, seal_whole(&key, .Manifest, test_salt(11), text, &sealed))
	back: [dynamic]u8
	back.allocator = context.temp_allocator
	ok, _ := open_whole(&key, sealed[:], .Manifest, &back)
	testing.expect(t, ok)
	testing.expect(t, same(back[:], text))
	flipped := make([]u8, len(sealed), context.temp_allocator)
	for p in 0 ..< len(sealed) {
		copy(flipped, sealed[:])
		flipped[p] ~= 0x10
		clear(&back)
		good, _ := open_whole(&key, flipped, .Manifest, &back)
		testing.expect(t, !good)
	}
	for c in 0 ..< len(sealed) {
		clear(&back)
		good, _ := open_whole(&key, sealed[:c], .Manifest, &back)
		testing.expect(t, !good)
	}
	wrong := test_key(2)
	clear(&back)
	good, reason := open_whole(&wrong, sealed[:], .Manifest, &back)
	testing.expect(t, !good)
	testing.expect_value(t, reason, "the file was written with another key")
	clear(&back)
	good, _ = open_whole(&key, sealed[:], .Snapshot, &back)
	testing.expect(t, !good)
	too_big := make([]u8, MANIFEST_MAX + 1, context.temp_allocator)
	none: [dynamic]u8
	none.allocator = context.temp_allocator
	testing.expect(t, !seal_whole(&key, .Manifest, test_salt(1), too_big, &none))
}

@(test)
plain_bytes_are_not_taken_for_an_envelope :: proc(t: ^testing.T) {
	_, res := header_parse(transmute([]u8)string("REDIS0012"))
	testing.expect_value(t, res, Header_Result.Not_Encrypted)
	_, res = header_parse(transmute([]u8)string("*2\r\n$6\r\nSELECT\r\n"))
	testing.expect_value(t, res, Header_Result.Not_Encrypted)
	_, res = header_parse(transmute([]u8)string("ESKI"))
	testing.expect_value(t, res, Header_Result.Short)
	key := test_key()
	h := header_bytes(Header{kind = .Snapshot, algorithm = 2, key_id = key.id})
	_, res = header_parse(h[:])
	testing.expect_value(t, res, Header_Result.Bad_Algorithm)
	h = header_bytes(Header{kind = Kind(9), algorithm = 1, key_id = key.id})
	_, res = header_parse(h[:])
	testing.expect_value(t, res, Header_Result.Bad_Kind)
}
