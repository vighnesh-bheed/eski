package listpack

import "core:testing"

@(test)
native_validation_cursor_and_bounded_size_observations :: proc(t: ^testing.T) {
	Step :: struct { before: int, after: int, result: bool }
	Fixture :: struct {
		wire: string,
		prefix: string,
		pattern: string,
		repeats: int,
		suffix: string,
		shallow: bool,
		deep: bool,
		first: int,
		steps: []Step,
		bad_sizes: []int,
	}
	fixtures := []Fixture{
		{"", "\x0c\x40\x00\x00\x02\x00\x82\x75\x3a\x03\xf0\xfa\x3f\x00\x00", "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x5b\x5c\x5d\x5e\x5f\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a\x7b\x7c\x7d\x7e\x7f\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb\xcc\xcd\xce\xcf\xd0\xd1\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xdb\xdc\xdd\xde\xdf\xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb\xec\xed\xee\xef\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff", 63, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x5b\x5c\x5d\x5e\x5f\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a\x7b\x7c\x7d\x7e\x7f\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb\xcc\xcd\xce\xcf\xd0\xd1\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xdb\xdc\xdd\xde\xdf\xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb\xec\xed\xee\xef\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\x7f\xff\xff", true, false, -999, {}, {0, 1, 2, 3, 4, 5, 6, 7, 16397}},
		{"\x0d\x00\x00\x00\x02\x00\x82\x75\x3a\x03\x00\x01\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 12, true}, {12, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 14}},
		{"\x0e\x00\x00\x00\x02\x00\x82\x75\x3a\x03\x00\x01\xff\xff", "", "", 0, "", true, false, -999, {}, {0, 1, 2, 3, 4, 5, 6, 7, 15}},
		{"\x11\x00\x00\x00\x02\x00\x82\x75\x3a\x03\xf0\xff\xff\xff\xff\x05\xff", "", "", 0, "", true, false, -999, {}, {0, 1, 2, 3, 4, 5, 6, 7, 18}},
		{"\x0d\x00\x00\x00\x03\x00\x82\x75\x3a\x03\x00\x01\xff", "", "", 0, "", true, false, -999, {}, {0, 1, 2, 3, 4, 5, 6, 7, 14}},
		{"\x0d\x00\x00\x00\x01\x00\x82\x75\x3a\x03\x00\x01\xff", "", "", 0, "", true, false, -999, {}, {0, 1, 2, 3, 4, 5, 6, 7, 14}},
		{"\x0e\x00\x00\x00\x02\x00\x82\x75\x3a\x03\x81\x31\x02\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 13, true}, {13, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 15}},
		{"\x0d\x00\x00\x00\x02\x00\x82\x75\x3a\x03\x01\x81\xff", "", "", 0, "", true, false, -999, {}, {0, 1, 2, 3, 4, 5, 6, 7, 14}},
		{"\x0d\x00\x00\x00\x02\x00\x82\x75\x3a\x03\xf5\x01\xff", "", "", 0, "", true, false, -999, {}, {0, 1, 2, 3, 4, 5, 6, 7, 14}},
		{"\x0f\x00\x00\x00\x02\x00\x82\x75\x3a\x03\x82\x61\x00\x83\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 14, true}, {14, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 16}},
		{"\x0e\x00\x00\x00\x02\x00\x82\x75\x3a\x03\x00\x01\xff", "", "", 0, "", false, false, -999, {}, {0, 1, 2, 3, 4, 5, 6, 7, 14}},
		{"\x0c\x00\x00\x00\x02\x00\x82\x75\x3a\x03\x00\x01\xff", "", "", 0, "", false, false, -999, {}, {0, 1, 2, 3, 4, 5, 6, 7, 14}},
		{"\x0d\x00\x00\x00\xff\xff\x82\x75\x3a\x03\x00\x01\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 12, true}, {12, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 14}},
		{"\x0e\x00\x00\x00\x02\x00\x82\x75\x3a\x03\xe0\x00\x02\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 13, true}, {13, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 15}},
		{"\x0f\x00\x00\x00\x02\x00\x82\x75\x3a\x03\xe0\x01\x7a\x03\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 14, true}, {14, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 16}},
		{"\x0e\x00\x00\x00\x02\x00\x82\x75\x3a\x03\xc0\x00\x82\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 13, true}, {13, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 15}},
		{"\x0e\x00\x00\x00\x02\x00\x82\x75\x3a\x03\xc0\x00\x02\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 13, true}, {13, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 15}},
		{"\x0f\x00\x00\x00\x02\x00\x82\x75\x3a\x03\xf1\x01\x00\x03\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 14, true}, {14, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 16}},
		{"\x10\x00\x00\x00\x02\x00\x82\x75\x3a\x03\xf2\x01\x00\x00\x04\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 15, true}, {15, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 17}},
		{"\x11\x00\x00\x00\x02\x00\x82\x75\x3a\x03\xf0\x00\x00\x00\x00\x05\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 16, true}, {16, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 18}},
		{"\x11\x00\x00\x00\x02\x00\x82\x75\x3a\x03\xf3\x01\x00\x00\x00\x05\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 16, true}, {16, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 18}},
		{"\x12\x00\x00\x00\x02\x00\x82\x75\x3a\x03\xf0\x01\x00\x00\x00\x7a\x06\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 17, true}, {17, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 19}},
		{"\x15\x00\x00\x00\x02\x00\x82\x75\x3a\x03\xf4\x01\x00\x00\x00\x00\x00\x00\x00\x09\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 20, true}, {20, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 22}},
		{"\x0d\x00\x00\x00\x02\x00\x82\x75\x3a\x03\x00\x81\xff", "", "", 0, "", true, true, 6, {{6, 10, true}, {10, 12, true}, {12, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 14}},
		{"\x0e\x00\x00\x00\x02\x00\x82\x75\x3a\x03\x00\x00\x81\xff", "", "", 0, "", true, false, -999, {}, {0, 1, 2, 3, 4, 5, 6, 7, 15}},
		{"\x0d\x00\x00\x00\x02\x00\x82\x75\x3a\x03\x00\x00\xff", "", "", 0, "", true, false, -999, {}, {0, 1, 2, 3, 4, 5, 6, 7, 14}},
		{"\x07\x00\x00\x00\xff\xff\xff", "", "", 0, "", true, true, -1, {}, {0, 1, 2, 3, 4, 5, 6, 8}},
		{"\x07\x00\x00\x00\x00\x00\xff", "", "", 0, "", true, true, -1, {}, {0, 1, 2, 3, 4, 5, 6, 8}},
		{"\x0b\x00\x00\x00\x02\x00\x80\x01\x00\x01\xff", "", "", 0, "", true, true, 6, {{6, 8, true}, {8, 10, true}, {10, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 12}},
		{"\x0b\x00\x00\x00\xff\xff\x80\x81\x00\x01\xff", "", "", 0, "", true, false, -999, {}, {0, 1, 2, 3, 4, 5, 6, 7, 12}},
		{"\x0b\x00\x00\x00\x02\x00\x80\x81\x00\x01\xff", "", "", 0, "", true, true, 6, {{6, 8, true}, {8, 10, true}, {10, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 12}},
		{"\x0b\x00\x00\x00\xff\xff\x00\x81\x00\x01\xff", "", "", 0, "", true, true, 6, {{6, 8, true}, {8, 10, true}, {10, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 12}},
		{"\x0b\x00\x00\x00\x02\x00\x00\x81\x00\x01\xff", "", "", 0, "", true, true, 6, {{6, 8, true}, {8, 10, true}, {10, -1, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 12}},
		{"", "\x07\x01\x01\x00\x80\x80\x80\x81", "\x00\x01", 32895, "\xff", true, true, 6, {{6, 8, true}, {8, 10, true}, {10, 12, true}, {12, 14, true}, {14, 16, true}, {16, 18, true}, {18, 20, true}, {20, 22, true}}, {0, 1, 2, 3, 4, 5, 6, 7, 65800}},
	}
	for fixture in fixtures {
		total := len(fixture.wire)
		if total == 0 {
			total = len(fixture.prefix) + len(fixture.pattern) * fixture.repeats + len(fixture.suffix)
		}
		storage := make([]u8, total + 1)
		defer delete(storage)
		if len(fixture.wire) != 0 {
			copy(storage, transmute([]u8)fixture.wire)
		} else {
			copy(storage, transmute([]u8)fixture.prefix)
			cursor := len(fixture.prefix)
			for _ in 0..<fixture.repeats {
				copy(storage[cursor:], transmute([]u8)fixture.pattern)
				cursor += len(fixture.pattern)
			}
			copy(storage[cursor:], transmute([]u8)fixture.suffix)
		}
		storage[total] = 255
		lp := raw_data(storage)
		testing.expect(t, lp_validate_integrity(lp, u64(total), false, nil, nil) == fixture.shallow)
		testing.expect(t, lp_validate_integrity(lp, u64(total), true, nil, nil) == fixture.deep)
		for size in fixture.bad_sizes {
			testing.expect(t, !lp_validate_integrity(lp, u64(size), true, nil, nil))
		}
		if fixture.first != -999 {
			cursor := lp_validate_first(lp)
			index := -1 if cursor == nil else pdiff(cursor, lp)
			testing.expect(t, index == fixture.first)
			if cursor != nil {
				next := lp_next(lp, cursor)
				if next != nil {
					testing.expect(t, lp_prev(lp, next) == cursor)
				}
			}
			for step in fixture.steps {
				index = -1 if cursor == nil else pdiff(cursor, lp)
				testing.expect(t, index == step.before)
				valid := lp_validate_next(lp, &cursor, u64(total))
				index = -1 if cursor == nil else pdiff(cursor, lp)
				testing.expect(t, valid == step.result && index == step.after)
			}
		}
	}
}

@(test)
redis_header_reverse_continuation_observations :: proc(t: ^testing.T) {
	Fixture :: struct { wire: string, accepted: bool, contents: []string }
	fixtures := []Fixture{
		{"\x0b\x00\x00\x00\x02\x00\x80\x01\x00\x01\xff", true, {"", "\x30"}},
		{"\x0b\x00\x00\x00\x02\x00\x80\x81\x00\x01\xff", true, {"", "\x30"}},
		{"\x0b\x00\x00\x00\xff\xff\x80\x81\x00\x01\xff", false, {}},
		{"\x0b\x00\x00\x00\x02\x00\x00\x81\x00\x01\xff", true, {"\x30", "\x30"}},
		{"\x0b\x00\x00\x00\xff\xff\x00\x81\x00\x01\xff", true, {"\x30", "\x30"}},
	}
	for fixture in fixtures {
		lp := raw_data(fixture.wire)
		testing.expect(t, lp_validate_integrity(lp, u64(len(fixture.wire)), true, nil, nil) == fixture.accepted)
		if fixture.accepted {
			cursor := lp_first(lp)
			for value in fixture.contents {
				buffer: [DECIMAL_BUFFER_BYTES]u8
				testing.expect(t, cursor != nil && string(lp_get_bytes(cursor, &buffer)) == value)
				cursor = lp_next(lp, cursor)
			}
			testing.expect(t, cursor == nil)
		}
	}
}
