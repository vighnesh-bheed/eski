package rax_test

import rx "../../src/rax"
import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"

main :: proc() {
}

Ref_Entry :: struct {
	key:   string,
	value: uintptr,
}

Reference :: struct {
	items: [dynamic]Ref_Entry,
}

key_compare :: proc(a: string, b: string) -> int {
	n := min(len(a), len(b))
	if n > 0 {
		c := runtime.memory_compare(raw_data(a), raw_data(b), n)
		if c != 0 {
			return c
		}
	}
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return 0
}

ref_lower :: proc(ref: ^Reference, key: string) -> (int, bool) {
	lo := 0
	hi := len(ref.items)
	for lo < hi {
		mid := (lo + hi) / 2
		if key_compare(ref.items[mid].key, key) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(ref.items) && ref.items[lo].key == key
}

ref_find :: proc(ref: ^Reference, key: string) -> (uintptr, bool) {
	idx, exact := ref_lower(ref, key)
	if !exact {
		return 0, false
	}
	return ref.items[idx].value, true
}

ref_insert :: proc(ref: ^Reference, key: string, value: uintptr) -> (bool, uintptr) {
	idx, exact := ref_lower(ref, key)
	if exact {
		prev := ref.items[idx].value
		ref.items[idx].value = value
		return false, prev
	}
	inject_at(&ref.items, idx, Ref_Entry{strings.clone(key), value})
	return true, 0
}

ref_remove :: proc(ref: ^Reference, key: string) -> (bool, uintptr) {
	idx, exact := ref_lower(ref, key)
	if !exact {
		return false, 0
	}
	prev := ref.items[idx].value
	delete(ref.items[idx].key)
	ordered_remove(&ref.items, idx)
	return true, prev
}

ref_destroy :: proc(ref: ^Reference) {
	for e in ref.items {
		delete(e.key)
	}
	delete(ref.items)
}

ref_seek :: proc(ref: ^Reference, op: string, key: string) -> int {
	n := len(ref.items)
	lo, exact := ref_lower(ref, key)
	pos := -1
	switch op {
	case "^":
		pos = 0
	case "$":
		pos = n - 1
	case "=":
		pos = lo if exact else -1
	case ">=":
		pos = lo
	case ">":
		pos = lo + 1 if exact else lo
	case "<=":
		pos = lo if exact else lo - 1
	case "<":
		pos = lo - 1
	}
	if pos < 0 || pos >= n {
		return -1
	}
	return pos
}

SEEK_OPS :: [?]string{"^", "$", "=", ">", ">=", "<", "<="}

bytes_of :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

id_key :: proc(ms: u64, seq: u64) -> [16]u8 {
	k: [16]u8
	for i in 0 ..< 8 {
		k[i] = u8(ms >> u64(56 - 8 * i))
		k[8 + i] = u8(seq >> u64(56 - 8 * i))
	}
	return k
}

id_string :: proc(ms: u64, seq: u64, allocator := context.temp_allocator) -> string {
	k := id_key(ms, seq)
	return strings.clone(string(k[:]), allocator)
}

Key_Kind :: enum {
	Tiny,
	Id_Random,
	Id_Sequential,
	Name,
	Long,
	Long_Chain,
	Width_63,
	Width_64,
	Width_65,
}

Key_Source :: struct {
	seq:  u64,
	base: string,
}

key_source_destroy :: proc(src: ^Key_Source) {
	delete(src.base)
}

gen_key :: proc(src: ^Key_Source, kind: Key_Kind) -> string {
	switch kind {
	case .Tiny:
		alphabet := [?]u8{0x00, 0x01, 'a', 'b', 0xfe, 0xff}
		n := rand.int_max(7)
		b := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			b[i] = alphabet[rand.int_max(len(alphabet))]
		}
		return string(b)
	case .Id_Random:
		return id_string(1_700_000_000_000 + u64(rand.int_max(4000)), u64(rand.int_max(3)))
	case .Id_Sequential:
		src.seq += u64(1 + rand.int_max(3))
		return id_string(1_700_000_000_000 + src.seq / 4, src.seq % 4)
	case .Name:
		n := 1 + rand.int_max(40)
		b := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			b[i] = u8('a' + rand.int_max(5))
		}
		return string(b)
	case .Long:
		if len(src.base) == 0 {
			src.base = strings.repeat("L", 9000)
		}
		n := 4097 + rand.int_max(4000)
		b := make([]u8, n, context.temp_allocator)
		copy(b, src.base[:n])
		tail := 1 + rand.int_max(3)
		for i in 0 ..< tail {
			b[n - 1 - i] = u8(rand.int_max(256))
		}
		return string(b)
	case .Long_Chain:
		if len(src.base) == 0 {
			src.base = strings.repeat("L", 9000)
		}
		n := 4090 + rand.int_max(40)
		return strings.clone(src.base[:n], context.temp_allocator)
	case .Width_63, .Width_64, .Width_65:
		n := 63 + int(kind) - int(Key_Kind.Width_63)
		b := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			b[i] = 'F'
		}
		choices := [?]u8{0x00, 0x7f, 0xff, 'E', 'G'}
		for _ in 0 ..< 1 + rand.int_max(3) {
			b[rand.int_max(n)] = choices[rand.int_max(len(choices))]
		}
		return string(b)
	}
	return ""
}

quote :: proc(s: string) -> string {
	if len(s) > 48 {
		return fmt.tprintf("<%d bytes>", len(s))
	}
	return fmt.tprintf("%q", s)
}

check_walks :: proc(t: ^testing.T, r: ^rx.Rax, ref: ^Reference, where_: string) -> bool {
	it: rx.Iterator
	rx.start(&it, r)
	defer rx.stop(&it)
	rx.seek(&it, "^")
	i := 0
	for rx.next(&it) {
		if i >= len(ref.items) {
			testing.expectf(t, false, "%s: forward walk yielded extra key %s", where_, quote(string(rx.key(&it))))
			return false
		}
		e := ref.items[i]
		if string(rx.key(&it)) != e.key || uintptr(it.data) != e.value {
			testing.expectf(t, false, "%s: forward walk at %d got %s want %s", where_, i, quote(string(rx.key(&it))), quote(e.key))
			return false
		}
		i += 1
	}
	if i != len(ref.items) || !rx.eof(&it) {
		testing.expectf(t, false, "%s: forward walk stopped at %d of %d", where_, i, len(ref.items))
		return false
	}
	if rx.next(&it) || rx.prev(&it) {
		testing.expectf(t, false, "%s: eof after forward walk is not sticky", where_)
		return false
	}
	rx.seek(&it, "$")
	i = len(ref.items) - 1
	for rx.prev(&it) {
		if i < 0 {
			testing.expectf(t, false, "%s: reverse walk yielded extra key", where_)
			return false
		}
		e := ref.items[i]
		if string(rx.key(&it)) != e.key || uintptr(it.data) != e.value {
			testing.expectf(t, false, "%s: reverse walk at %d got %s want %s", where_, i, quote(string(rx.key(&it))), quote(e.key))
			return false
		}
		i -= 1
	}
	if i != -1 || !rx.eof(&it) {
		testing.expectf(t, false, "%s: reverse walk stopped at %d", where_, i)
		return false
	}
	return true
}

check_seek_walk :: proc(
	t: ^testing.T,
	it: ^rx.Iterator,
	ref: ^Reference,
	op: string,
	key: string,
	steps: int,
	where_: string,
) -> bool {
	want := ref_seek(ref, op, key)
	if !rx.seek(it, op, bytes_of(key)) {
		testing.expectf(t, false, "%s: seek %s %s returned false", where_, op, quote(key))
		return false
	}
	if want < 0 {
		if !rx.eof(it) || rx.next(it) || rx.prev(it) || !rx.eof(it) {
			testing.expectf(t, false, "%s: seek %s %s expected eof", where_, op, quote(key))
			return false
		}
		return true
	}
	if rx.eof(it) || string(rx.key(it)) != ref.items[want].key || uintptr(it.data) != ref.items[want].value {
		testing.expectf(t, false, "%s: seek %s %s positioned wrongly, want %s", where_, op, quote(key), quote(ref.items[want].key))
		return false
	}
	pos := want
	first := true
	for _ in 0 ..< steps {
		forward := rand.int_max(2) == 0
		ok := rx.next(it) if forward else rx.prev(it)
		if first {
			first = false
		} else {
			pos = pos + 1 if forward else pos - 1
		}
		if pos < 0 || pos >= len(ref.items) {
			if ok || !rx.eof(it) {
				testing.expectf(t, false, "%s: step past the end did not report eof (seek %s %s)", where_, op, quote(key))
				return false
			}
			if rx.next(it) || rx.prev(it) || !rx.eof(it) {
				testing.expectf(t, false, "%s: eof is not sticky (seek %s %s)", where_, op, quote(key))
				return false
			}
			return true
		}
		e := ref.items[pos]
		if !ok || string(rx.key(it)) != e.key || uintptr(it.data) != e.value {
			testing.expectf(t, false, "%s: step to %d after seek %s %s got %s want %s", where_, pos, op, quote(key), quote(string(rx.key(it))), quote(e.key))
			return false
		}
	}
	return true
}

seeded :: proc(seed: u64) -> rand.Default_Random_State {
	return rand.create(seed)
}
