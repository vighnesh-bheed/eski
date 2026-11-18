package changelog

import "core:encoding/endian"

Epoch :: [16]u8

Cursor :: struct {
	epoch: Epoch,
	position: u64,
}

Record :: struct {
	cursor: Cursor,
	db: i32,
	payload: []u8,
}

Status :: enum {
	Ok,
	End,
	Offline,
	Missing,
	Invalid,
	Corrupt,
	Incomplete,
	Wrong_Epoch,
	Stale,
	Ahead,
	Too_Large,
	IO,
}

MAX_PAYLOAD :: 1 << 30

SEGMENT_HEADER_SIZE :: 36

FRAME_HEADER_SIZE :: 28

@(private)
EPOCH_HEADER_SIZE :: 28

@(private)
SEGMENT_MAGIC :: "ESKICS01"

@(private)
EPOCH_MAGIC :: "ESKICE01"

@(private)
FRAME_MAGIC :: 0x31464c43

@(private)
crc_table := make_crc_table()

@(private)
make_crc_table :: proc "contextless" () -> (table: [256]u32) {
	for &entry, i in table {
		crc := u32(i)
		for _ in 0 ..< 8 {
			crc = (crc >> 1) ~ (0x82f63b78 if crc & 1 != 0 else 0)
		}
		entry = crc
	}
	return
}

crc32c :: proc(data: []u8) -> u32 {
	crc := max(u32)
	for byte in data {
		crc = (crc >> 8) ~ crc_table[u8(crc) ~ byte]
	}
	return ~crc
}

@(private)
encode_epoch :: proc(epoch: Epoch) -> (out: [EPOCH_HEADER_SIZE]u8) {
	copy(out[:8], EPOCH_MAGIC)
	id := epoch
	copy(out[8:24], id[:])
	endian.unchecked_put_u32le(out[24:], crc32c(out[:24]))
	return
}

@(private)
decode_epoch :: proc(data: []u8) -> (epoch: Epoch, ok: bool) {
	copy(epoch[:], data[8:24])
	return epoch, epoch != {} && string(data[:8]) == EPOCH_MAGIC && endian.unchecked_get_u32le(data[24:]) == crc32c(data[:24])
}

@(private)
encode_segment :: proc(id: Cursor) -> (out: [SEGMENT_HEADER_SIZE]u8) {
	copy(out[:8], SEGMENT_MAGIC)
	epoch := id.epoch
	copy(out[8:24], epoch[:])
	endian.unchecked_put_u64le(out[24:32], id.position)
	endian.unchecked_put_u32le(out[32:], crc32c(out[:32]))
	return
}

@(private)
encode_frame :: proc(position: u64, db: i32, payload: []u8) -> (out: [FRAME_HEADER_SIZE]u8) {
	endian.unchecked_put_u32le(out[:4], FRAME_MAGIC)
	endian.unchecked_put_u32le(out[4:8], u32(len(payload)))
	endian.unchecked_put_u64le(out[8:16], position)
	endian.unchecked_put_u32le(out[16:20], u32(db))
	endian.unchecked_put_u32le(out[20:24], crc32c(payload))
	endian.unchecked_put_u32le(out[24:], crc32c(out[:24]))
	return
}

@(private)
decode_frame :: proc(data: []u8, position: u64) -> (n: int, db: i32, checksum: u32, status: Status) {
	if endian.unchecked_get_u32le(data[:4]) != FRAME_MAGIC || endian.unchecked_get_u32le(data[24:]) != crc32c(data[:24]) {
		return 0, 0, 0, .Corrupt
	}
	n = int(endian.unchecked_get_u32le(data[4:8]))
	db = i32(endian.unchecked_get_u32le(data[16:20]))
	if n <= 0 || n > MAX_PAYLOAD || db < -1 || endian.unchecked_get_u64le(data[8:16]) != position || position == max(u64) {
		return 0, 0, 0, .Corrupt
	}
	return n, db, endian.unchecked_get_u32le(data[20:24]), .Ok
}
