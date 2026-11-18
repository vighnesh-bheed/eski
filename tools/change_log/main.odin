package main

import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:sys/linux"
import "../../src/changelog"

parse_position :: proc(arg: string) -> (u64, bool) {
	position: u64
	for byte in transmute([]u8)arg {
		if byte < '0' || byte > '9' {
			return 0, false
		}
		digit := u64(byte - '0')
		if position > (max(u64) - digit) / 10 {
			return 0, false
		}
		position = position * 10 + digit
	}
	return position, position != 0
}

print_cursor :: proc(cursor: changelog.Cursor) {
	id := cursor.epoch
	fmt.printfln("%s %d", string(hex.encode(id[:], context.temp_allocator)), cursor.position)
}

fail :: proc(status: changelog.Status) -> ! {
	fmt.eprintln(status)
	code := 1
	#partial switch status {
	case .End:
		code = 3
	case .Offline:
		code = 4
	case .Wrong_Epoch, .Stale, .Ahead:
		code = 5
	}
	linux.exit_group(i32(code))
}

main :: proc() {
	args := os.args
	first := len(args) == 3 && args[2] == "first"
	read := len(args) == 5 && args[2] == "read"
	if !first && !read {
		fmt.eprintln("usage: eski-change-log DIRECTORY first")
		fmt.eprintln("       eski-change-log DIRECTORY read EPOCH POSITION")
		linux.exit_group(2)
	}
	directory: changelog.Directory
	if status := changelog.directory_open(&directory, args[1]); status != .Ok {
		fail(status)
	}
	defer changelog.directory_close(&directory)
	if first {
		cursor, status := changelog.directory_first(&directory)
		if status != .Ok {
			fail(status)
		}
		print_cursor(cursor)
		return
	}
	cursor: changelog.Cursor
	if len(args[3]) != 32 {
		fail(.Invalid)
	}
	if _, ok := hex.decode_into_buffer(transmute([]u8)args[3], cursor.epoch[:]); !ok {
		fail(.Invalid)
	}
	position, parsed := parse_position(args[4])
	if !parsed {
		fail(.Invalid)
	}
	cursor.position = position
	buffer: [dynamic]u8
	defer delete(buffer)
	record, status := changelog.directory_read(&directory, cursor, &buffer)
	if status != .Ok {
		fail(status)
	}
	for written := 0; written < len(record.payload); {
		n, err := linux.write(1, record.payload[written:])
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			fail(.IO)
		}
		written += n
	}
	fmt.eprintfln("db=%d next=%d", record.db, record.cursor.position + 1)
}
