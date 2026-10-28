package rdb

RDB_VERSION :: 12

REDIS_VERSION :: "7.4.11"

LEN_6BIT :: 0
LEN_14BIT :: 1
LEN_32BIT :: 0x80
LEN_64BIT :: 0x81
ENCVAL :: 3
LENERR :: max(u64)

ENC_INT8 :: 0
ENC_INT16 :: 1
ENC_INT32 :: 2
ENC_LZF :: 3

TYPE_STRING :: 0
TYPE_LIST :: 1
TYPE_SET :: 2
TYPE_ZSET :: 3
TYPE_HASH :: 4
TYPE_ZSET_2 :: 5
TYPE_MODULE_PRE_GA :: 6
TYPE_MODULE_2 :: 7
TYPE_HASH_ZIPMAP :: 9
TYPE_LIST_ZIPLIST :: 10
TYPE_SET_INTSET :: 11
TYPE_ZSET_ZIPLIST :: 12
TYPE_HASH_ZIPLIST :: 13
TYPE_LIST_QUICKLIST :: 14
TYPE_STREAM_LISTPACKS :: 15
TYPE_HASH_LISTPACK :: 16
TYPE_ZSET_LISTPACK :: 17
TYPE_LIST_QUICKLIST_2 :: 18
TYPE_STREAM_LISTPACKS_2 :: 19
TYPE_SET_LISTPACK :: 20
TYPE_STREAM_LISTPACKS_3 :: 21
TYPE_HASH_METADATA_PRE_GA :: 22
TYPE_HASH_LISTPACK_EX_PRE_GA :: 23
TYPE_HASH_METADATA :: 24
TYPE_HASH_LISTPACK_EX :: 25

OPCODE_SLOT_INFO :: 244
OPCODE_FUNCTION2 :: 245
OPCODE_FUNCTION_PRE_GA :: 246
OPCODE_MODULE_AUX :: 247
OPCODE_IDLE :: 248
OPCODE_FREQ :: 249
OPCODE_AUX :: 250
OPCODE_RESIZEDB :: 251
OPCODE_EXPIRETIME_MS :: 252
OPCODE_EXPIRETIME :: 253
OPCODE_SELECTDB :: 254
OPCODE_EOF :: 255

MODULE_OPCODE_EOF :: 0
MODULE_OPCODE_UINT :: 2

QUICKLIST_NODE_CONTAINER_PLAIN :: 1
QUICKLIST_NODE_CONTAINER_PACKED :: 2

EB_EXPIRE_TIME_MAX :: u64(0x0000FFFFFFFFFFFF)
EB_EXPIRE_TIME_INVALID :: EB_EXPIRE_TIME_MAX + 1

is_object_type :: proc "contextless" (t: int) -> bool {
	return (t >= TYPE_STRING && t <= TYPE_MODULE_2) || (t >= TYPE_HASH_ZIPMAP && t <= TYPE_HASH_LISTPACK_EX)
}

string2ll :: proc "contextless" (s: []u8) -> (i64, bool) #no_bounds_check {
	n := len(s)
	if n == 0 || n > 20 {
		return 0, false
	}
	if n == 1 && s[0] == '0' {
		return 0, true
	}
	i := 0
	negative := false
	if s[0] == '-' {
		negative = true
		i = 1
		if n == 1 {
			return 0, false
		}
	}
	if s[i] < '1' || s[i] > '9' {
		return 0, false
	}
	magnitude: u64 = 0
	for ; i < n; i += 1 {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		digit := u64(c - '0')
		if magnitude > (max(u64) - digit) / 10 {
			return 0, false
		}
		magnitude = magnitude * 10 + digit
	}
	if negative {
		if magnitude > u64(max(i64)) + 1 {
			return 0, false
		}
		return i64(0 - magnitude), true
	}
	if magnitude > u64(max(i64)) {
		return 0, false
	}
	return i64(magnitude), true
}

ll2string :: proc "contextless" (dst: []u8, v: i64) -> int #no_bounds_check {
	magnitude: u64 = u64(v) if v >= 0 else u64(0) - u64(v)
	digits := 1
	for probe := magnitude; probe >= 10; probe /= 10 {
		digits += 1
	}
	total := digits + (1 if v < 0 else 0)
	if total > len(dst) {
		return 0
	}
	at := total
	for {
		at -= 1
		dst[at] = u8(magnitude % 10) + '0'
		magnitude /= 10
		if magnitude == 0 {
			break
		}
	}
	if v < 0 {
		dst[0] = '-'
	}
	return total
}

encode_integer :: proc "contextless" (value: i64, enc: ^[5]u8) -> int {
	if value >= i64(min(i8)) && value <= i64(max(i8)) {
		enc[0] = 0xC0 | ENC_INT8
		enc[1] = u8(value)
		return 2
	}
	if value >= i64(min(i16)) && value <= i64(max(i16)) {
		enc[0] = 0xC0 | ENC_INT16
		enc[1] = u8(value)
		enc[2] = u8(value >> 8)
		return 3
	}
	if value >= i64(min(i32)) && value <= i64(max(i32)) {
		enc[0] = 0xC0 | ENC_INT32
		enc[1] = u8(value)
		enc[2] = u8(value >> 8)
		enc[3] = u8(value >> 16)
		enc[4] = u8(value >> 24)
		return 5
	}
	return 0
}

MODULE_NAME_CHARSET :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

module_name_by_id :: proc "contextless" (id: u64, out: ^[9]u8) -> string {
	charset := MODULE_NAME_CHARSET
	bits := id >> 10
	for i := 8; i >= 0; i -= 1 {
		out[i] = charset[bits & 63]
		bits >>= 6
	}
	return string(out[:])
}
