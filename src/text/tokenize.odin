package text

import "base:intrinsics"
import "core:simd"

Bytes16 :: #simd[16]u8

Doc_Tokenizer :: struct {
	src:   []u8,
	limit: int,
	pos:   int,
	buf:   [dynamic]u8,
}

doc_tokenizer_init :: proc(t: ^Doc_Tokenizer, allocator := context.allocator) {
	t^ = {}
	t.buf = make([dynamic]u8, allocator)
}

doc_tokenizer_destroy :: proc(t: ^Doc_Tokenizer) {
	delete(t.buf)
	t^ = {}
}

doc_tokenizer :: proc(t: ^Doc_Tokenizer) -> Tokenizer {
	return Tokenizer{data = t, reset = doc_reset, next = doc_next}
}

text_limit :: proc "contextless" (text: []u8) -> int {
	for b, i in text {
		if b == 0 {
			return i
		}
	}
	return len(text)
}

doc_tokenizer_reset :: proc(t: ^Doc_Tokenizer, text: []u8) {
	t.src = text
	t.limit = len(text)
	t.pos = 0
	clear(&t.buf)
}

doc_reset :: proc(data: rawptr, text: []u8) {
	doc_tokenizer_reset((^Doc_Tokenizer)(data), text)
}

doc_next :: proc(data: rawptr, token: ^Token) -> bool {
	return doc_tokenizer_next((^Doc_Tokenizer)(data), token)
}

doc_tokenizer_next :: proc(t: ^Doc_Tokenizer, token: ^Token) -> bool #no_bounds_check {
	src := t.src
	n := t.limit
	i := t.pos
	for {
		for i < n && (.Separator in BYTE_CLASSES[src[i]]) {
			i += 1
		}
		if i >= n || src[i] == 0 {
			t.limit = i
			t.pos = i
			return false
		}
		start := i
		j := scan_plain(src, i, n)
		if j >= n || BYTE_CLASSES[src[j]] & DOC_BREAK != {} {
			if j < n && src[j] == 0 {
				t.limit = j
			}
			token.text = src[start:j]
			token.tail = src[j:]
			token.start = start
			token.end = j
			t.pos = j
			return true
		}
		non_zero_resize(&t.buf, n - start)
		buf := t.buf[:]
		k := copy(buf, src[start:j])
		for j < n {
			b := src[j]
			c := BYTE_CLASSES[b]
			if c & DOC_BREAK != {} {
				if b == 0 {
					n = j
					t.limit = j
				}
				break
			}
			if .Dropped in c {
				j += 1
				continue
			}
			if .Escape in c {
				if j + 1 >= n || src[j + 1] == 0 {
					j += 1
					if j < n {
						n = j
						t.limit = j
					}
					break
				}
				e := src[j + 1]
				j += 2
				if !is_control(e) {
					buf[k] = e
					k += 1
				}
				continue
			}
			run := scan_plain(src, j + 1, n)
			k += copy(buf[k:], src[j:run])
			j = run
		}
		non_zero_resize(&t.buf, k)
		if len(t.buf) == 0 {
			i = j
			continue
		}
		token.text = t.buf[:]
		token.tail = src[min(start + len(t.buf), len(src)):]
		token.start = start
		token.end = j
		t.pos = j
		return true
	}
}

scan_plain_scalar :: proc "contextless" (src: []u8, from: int, limit: int) -> int #no_bounds_check {
	j := from
	for j < limit && BYTE_CLASSES[src[j]] & DOC_SPECIAL == {} {
		j += 1
	}
	return j
}

scan_plain :: proc "contextless" (src: []u8, from: int, limit: int) -> int #no_bounds_check {
	j := from
	for j + 16 <= limit {
		v := intrinsics.unaligned_load((^Bytes16)(&src[j]))
		high := simd.lanes_ge(v, Bytes16(0x80))
		digit := simd.lanes_le(v - Bytes16('0'), Bytes16(9))
		upper := simd.lanes_le(v - Bytes16('A'), Bytes16(25))
		lower := simd.lanes_le(v - Bytes16('a'), Bytes16(25))
		under := simd.lanes_eq(v, Bytes16('_'))
		plain := (high | digit) | (upper | lower) | under
		special := ~u32(transmute(u16)simd.extract_msbs(plain)) & 0xFFFF
		if special != 0 {
			return j + int(intrinsics.count_trailing_zeros(special))
		}
		j += 16
	}
	return scan_plain_scalar(src, j, limit)
}
