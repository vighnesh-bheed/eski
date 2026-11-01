package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import bm "../../src/bitmap"
import ints "../../src/integer"

number :: proc(s: string) -> i64 {
	v, ok := strconv.parse_i64(s, 10)
	assert(ok)
	return v
}

parser_checks :: proc() {
	cases := []string{"i0", "u0", "i65", "u64", "i08", "I8", "u-1"}
	for s in cases {
		_, _, err := bm.parse_bitfield_type(transmute([]u8)s)
		assert(err == .Bitfield_Type)
	}
	_, _, err := bm.parse_bitfield_type(transmute([]u8)string("i64"))
	assert(err == .None)
	_, _, err = bm.parse_bitfield_type(transmute([]u8)string("u63"))
	assert(err == .None)
	for s in ([]string{"9223372036854775808", "-9223372036854775809", "01", "-0"}) {
		_, ierr := bm.parse_integer(transmute([]u8)s)
		assert(ierr == .Not_Integer)
		_, ok := ints.parse_i64(transmute([]u8)s)
		assert(!ok)
	}
	for s in ([]string{"-9223372036854775808", "9223372036854775807"}) {
		_, ierr := bm.parse_integer(transmute([]u8)s)
		assert(ierr == .None)
		_, ok := ints.parse_i64(transmute([]u8)s)
		assert(ok)
	}
	data := []u8{0xa5, 0x5a}
	for bits in ([]u64{0, 65}) {
		assert(bm.get_unsigned_bitfield(data, 0, bits) == 0)
		assert(bm.get_signed_bitfield(data, 0, bits) == 0)
		bm.set_unsigned_bitfield(data, 0, bits, max(u64))
		assert(data[0] == 0xa5 && data[1] == 0x5a)
	}
}

main :: proc() {
	assert(len(os.args) == 2)
	parser_checks()
	input, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	defer delete(input)
	lines := strings.split(string(input), "\n")
	defer delete(lines)
	buf: []u8
	capacity := 0
	defer bm.free_bytes(&buf, bm.RAW_HEAP_ALLOCATOR, &capacity)
	prog: bm.Bitfield_Program
	defer bm.bitfield_program_destroy(&prog)
	for line in lines {
		if len(line) == 0 {
			continue
		}
		fields := strings.split(line, " ")
		defer delete(fields)
		switch fields[0] {
		case "R":
			assert(len(fields) == 2)
			bm.free_bytes(&buf, bm.RAW_HEAP_ALLOCATOR, &capacity)
			if fields[1] != "-" {
				bytes := strings.split(fields[1], ",")
				defer delete(bytes)
				assert(bm.grow_zero(&buf, len(bytes), bm.RAW_HEAP_ALLOCATOR, &capacity) == .None)
				for b, i in bytes {
					n := number(b)
					assert(n >= 0 && n <= 255)
					buf[i] = u8(n)
				}
			}
		case "P":
			assert((len(fields) - 1) % 6 == 0)
			clear(&prog.ops)
			for i := 1; i < len(fields); i += 6 {
				op: bm.Bitfield_Op
				switch fields[i] {
				case "G": op.opcode = .Get
				case "S": op.opcode = .Set
				case "I": op.opcode = .Incrby
				case: panic("invalid opcode")
				}
				op.signed = fields[i + 1] == "1"
				width := number(fields[i + 2])
				assert(width > 0 && width <= (64 if op.signed else 63))
				op.bits = u8(width)
				offset := number(fields[i + 3])
				assert(offset >= 0 && offset <= 4096)
				op.offset = u64(offset)
				op.value = number(fields[i + 4])
				switch fields[i + 5] {
				case "W": op.overflow = .Wrap
				case "S": op.overflow = .Sat
				case "F": op.overflow = .Fail
				case: panic("invalid mode")
				}
				append(&prog.ops, op)
			}
			changes, xerr := bm.bitfield_execute(&buf, &prog, bm.RAW_HEAP_ALLOCATOR, &capacity)
			assert(xerr == .None)
			fmt.printf("%d|", changes)
			if len(buf) == 0 {
				fmt.print("-")
			} else {
				for b, i in buf {
					if i > 0 { fmt.print(",") }
					fmt.printf("%d", b)
				}
			}
			fmt.print("|")
			for r, i in prog.replies {
				if i > 0 { fmt.print(",") }
				if r.null { fmt.print("n") } else { fmt.printf("%d", r.value) }
			}
			fmt.println()
		case:
			panic("invalid trace line")
		}
	}
}
