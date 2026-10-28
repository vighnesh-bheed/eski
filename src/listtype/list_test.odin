package listtype

import "core:testing"
import "core:sync"

test_lock: sync.Mutex
import lp "../listpack"
import "../rdb"

assert_model :: proc(t: ^testing.T, l: List, expected: []string) {
	testing.expect_value(t, length(l), len(expected))
	testing.expect_value(t, memory_usage(l), memory_recount(l))
	for dir in Where {
		begin := 0
		step := 1
		if dir == .Head {
			begin = len(expected)-1
			step = -1
		}
		it := iterator(l, begin, dir)
		e: List_Entry
		buf: [21]u8
		count := 0
		idx := begin
		for iter_next(&it, &e) {
			if idx < 0 || idx >= len(expected) {
				testing.expect(t, false)
				break
			}
			testing.expect_value(t, string(value_bytes(entry_value(&it, &e), &buf)), expected[idx])
			idx += step
			count += 1
		}
		testing.expect_value(t, count, len(expected))
	}
	if l.encoding == .Quicklist {
		q := l.ql
		count := 0
		nodes := 0
		prev: ^Node
		for n := q.head; n != nil; n = n.next {
			testing.expect_value(t, n.prev, prev)
			testing.expect(t, n.count > 0)
			if n.plain {
				testing.expect_value(t, n.count, 1)
			} else {
				testing.expect_value(t, n.count, int(lp.lp_length(n.entry)))
				testing.expect_value(t, n.sz, lp.lp_bytes(n.entry))
			}
			count += n.count
			nodes += 1
			prev = n
		}
		testing.expect_value(t, q.tail, prev)
		testing.expect_value(t, q.count, count)
		testing.expect_value(t, q.len, nodes)
	}
}

model_insert :: proc(model: []string, n: ^int, at: int, value: string) {
	for i := n^; i > at; i -= 1 {
		model[i] = model[i-1]
	}
	model[at] = value
	n^ += 1
}

model_remove :: proc(model: []string, n: ^int, at: int) {
	for i := at; i+1 < n^; i += 1 {
		model[i] = model[i+1]
	}
	n^ -= 1
}

random_word :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1442695040888963407
	return state^
}

@(test)
mutation_model :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	oldfill := list_max_listpack_size
	oldthreshold := packed_threshold
	defer {
		list_max_listpack_size = oldfill
		packed_threshold = oldthreshold
	}
	big := make([]u8, 9001)
	defer delete(big)
	for &b in big {
		b = 'z'
	}
	values := [?]string{"", "0", "-1", "01", "9223372036854775807", "-9223372036854775808", "a\x00b", "value", string(big)}
	for fill in ([?]int{1, 2, 4, -1, -2}) {
		list_max_listpack_size = fill
		packed_threshold = 0
		l := create()
		model: [4096]string
		n := 0
		state: u64 = 71
		defer destroy(l)
		for _ in 0..<1600 {
			choice := random_word(&state)
			value := values[int(random_word(&state)%u64(len(values)))]
			op := int(choice%7)
			if n == 0 || op < 2 {
				where_ := Where.Head
				at := 0
				if op == 1 {
					where_ = .Tail
					at = n
				}
				try_conversion_append(l, len(value), 1)
				push(l, transmute([]u8)value, where_)
				model_insert(model[:], &n, at, value)
			} else if op == 2 {
				at := int(random_word(&state)%u64(n))
				testing.expect(t, lset(l, at, transmute([]u8)value))
				model[at] = value
			} else if op == 3 {
				at := int(random_word(&state)%u64(n))
				it := iterator(l, at, .Tail)
				e: List_Entry
				testing.expect(t, iter_next(&it, &e))
				entry_delete(&it, &e)
				model_remove(model[:], &n, at)
				try_conversion(l, .Shrinking)
			} else if op == 4 {
				at := int(random_word(&state)%u64(n))
				after := choice&8 != 0
				where_ := Where.Head
				if after {
					where_ = .Tail
				}
				it := iterator(l, at, .Tail)
				e: List_Entry
				testing.expect(t, iter_next(&it, &e))
				entry_insert(&it, &e, transmute([]u8)value, where_)
				target := at
				if after {
					target += 1
				}
				model_insert(model[:], &n, target, value)
				try_conversion(l, .Auto)
			} else if op == 5 {
				tail := choice&16 != 0
				where_ := Where.Head
				at := 0
				if tail {
					where_ = .Tail
					at = n-1
				}
				pop_discard(l, where_)
				model_remove(model[:], &n, at)
				try_conversion(l, .Shrinking)
			} else {
				at := int(random_word(&state)%u64(n))
				amount := min(int(random_word(&state)%5)+1, n-at)
				delete_range(l, at, amount)
				for _ in 0..<amount {
					model_remove(model[:], &n, at)
				}
				try_conversion(l, .Shrinking)
			}
			assert_model(t, l, model[:n])
			if choice%41 == 0 {
				d := dup(l)
				assert_model(t, d, model[:n])
				push(d, transmute([]u8)string("disjoint"), .Tail)
				testing.expect_value(t, length(l), n)
				destroy(d)
			}
		}
	}
}

@(test)
iterator_mutations :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	oldfill := list_max_listpack_size
	defer {
		list_max_listpack_size = oldfill
	}
	list_max_listpack_size = 2
	for ql in ([?]bool{false, true}) {
		l := create()
		if ql {
			destroy(l)
			l = create_quicklist()
		}
		for v in ([?]string{"a", "b", "c", "d", "e"}) {
			push(l, transmute([]u8)v, .Tail)
		}
		for direction in Where {
			d := dup(l)
			at := 0
			if direction == .Head {
				at = -1
			}
			it := iterator(d, at, direction)
			entry: List_Entry
			seen := 0
			for iter_next(&it, &entry) {
				entry_insert(&it, &entry, transmute([]u8)string("new"), .Tail)
				seen += 1
			}
			testing.expect_value(t, seen, 5)
			testing.expect_value(t, length(d), 10)
			destroy(d)
			d = dup(l)
			it = iterator(d, at, direction)
			seen = 0
			for iter_next(&it, &entry) {
				entry_delete(&it, &entry)
				seen += 1
			}
			testing.expect_value(t, seen, 5)
			testing.expect_value(t, length(d), 0)
			testing.expect_value(t, memory_usage(d), memory_recount(d))
			destroy(d)
		}
		destroy(l)
	}
}

@(test)
parsers_and_commands :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	bad := [?]string{"", "+1", " 1", "01", "-0", "9223372036854775808", "-9223372036854775809", "1\x00"}
	for v in bad {
		_, ok := parse_long(transmute([]u8)v)
		testing.expect(t, !ok)
	}
	v, ok := parse_long(transmute([]u8)string("-9223372036854775808"))
	testing.expect(t, ok)
	testing.expect_value(t, v, min(i64))
	rankargs := [][]u8{transmute([]u8)string("rank"), transmute([]u8)string("-9223372036854775808")}
	_, err := parse_lpos_args(rankargs)
	testing.expect_value(t, err, Error.Long_Range)
	oldfill := list_max_listpack_size
	defer {
		list_max_listpack_size = oldfill
	}
	list_max_listpack_size = 2
	l := create_quicklist()
	defer destroy(l)
	for value in ([?]string{"a", "b", "a", "c", "a"}) {
		push(l, transmute([]u8)value, .Tail)
	}
	positions: [dynamic]int
	defer delete(positions)
	lpos(l, transmute([]u8)string("a"), -2, 0, 4, &positions)
	testing.expect_value(t, len(positions), 1)
	testing.expect_value(t, positions[0], 2)
	testing.expect_value(t, lrem(l, min(int), transmute([]u8)string("a")), 3)
	assert_model(t, l, []string{"b", "c"})
	ltrim(l, min(int), max(int))
	assert_model(t, l, []string{"b", "c"})
	ltrim(l, 4, -99)
	assert_model(t, l, nil)
}

@(test)
codec_roundtrip :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	oldfill := list_max_listpack_size
	defer {
		list_max_listpack_size = oldfill
	}
	list_max_listpack_size = 2
	for fill in ([?]int{2, -2}) {
		list_max_listpack_size = fill
		l := create()
		defer destroy(l)
		expected := []string{"a", "-2", "", "c\x00d", "9223372036854775807"}
		for value in expected {
			try_conversion_append(l, len(value), 1)
			push(l, transmute([]u8)value, .Tail)
		}
		w: rdb.Writer
		rdb.writer_init_mem(&w, false, false)
		defer rdb.writer_destroy(&w)
		rdb_save(&w, l)
		bytes := rdb.writer_bytes(&w)
		for n in 0..=len(bytes) {
			r: rdb.Reader
			rdb.reader_init_mem(&r, bytes[:n], false)
			restored := rdb_load(&r, rdb.TYPE_LIST_QUICKLIST_2, true)
			if n == len(bytes) {
				testing.expect(t, restored != nil)
				if restored != nil {
					assert_model(t, restored, expected)
				}
			} else {
				testing.expect(t, restored == nil)
				testing.expect(t, r.status != .Ok)
			}
			destroy(restored)
			rdb.reader_destroy(&r)
		}
	}
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	defer rdb.writer_destroy(&w)
	rdb.put_len(&w, 3)
	for v in ([?]string{"x", "3", ""}) {
		rdb.put_string(&w, transmute([]u8)v)
	}
	r: rdb.Reader
	rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
	l := rdb_load(&r, rdb.TYPE_LIST, true)
	testing.expect(t, l != nil)
	if l != nil {
		assert_model(t, l, []string{"x", "3", ""})
		destroy(l)
	}
	rdb.reader_destroy(&r)
}

@(test)
boundaries_and_nested_iterators :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	oldfill := list_max_listpack_size
	olddepth := list_compress_depth
	oldthreshold := packed_threshold
	defer {
		list_max_listpack_size = oldfill
		list_compress_depth = olddepth
		packed_threshold = oldthreshold
	}
	for fill in ([?]int{0, 1, 2, 17, -1, -5}) {
		q := ql_new(fill, 999999)
		testing.expect_value(t, q.compress, COMPRESS_MAX)
		testing.expect_value(t, q.fill, clamp_fill(fill))
		ql_release(q)
	}
	testing.expect(t, set_packed_threshold(0))
	testing.expect(t, !is_large_element(1, -2))
	testing.expect(t, set_packed_threshold(1))
	testing.expect(t, is_large_element(1, -2))
	testing.expect(t, !is_large_element(0, -2))
	testing.expect(t, !set_packed_threshold(PACKED_THRESHOLD_LIMIT+1))
	testing.expect(t, set_packed_threshold(32))
	q := ql_new(3, 0)
	payload: [32]u8
	for &b in payload {
		b = 'p'
	}
	push_tail(q, payload[:31])
	push_tail(q, payload[:])
	testing.expect(t, !q.head.plain)
	testing.expect(t, q.tail.plain)
	testing.expect_value(t, q.len, 2)
	ql_release(q)
	packed_threshold = 0
	list_max_listpack_size = 3
	list_compress_depth = 4
	l := create_quicklist()
	defer destroy(l)
	model: [4096]string
	n := 0
	for _ in 0..<97 {
		push(l, transmute([]u8)string("seed"), .Tail)
		model_insert(model[:], &n, n, "seed")
	}
	assert_model(t, l, model[:n])
	list_max_listpack_size = 1
	list_compress_depth = 0
	testing.expect_value(t, l.ql.fill, 3)
	testing.expect_value(t, l.ql.compress, 4)
	for i := 96; i >= 0; i -= 1 {
		direction := Where.Tail
		if i%2 != 0 {
			direction = .Head
		}
		it := iterator(l, i, direction)
		entry: List_Entry
		testing.expect(t, iter_next(&it, &entry))
		entry_insert(&it, &entry, transmute([]u8)string("inserted"), .Head)
		model_insert(model[:], &n, i, "inserted")
		nextentry: List_Entry
		exists := iter_next(&it, &nextentry)
		expectedidx := i+2
		if direction == .Head {
			expectedidx = i-1
		}
		testing.expect_value(t, exists, expectedidx >= 0 && expectedidx < n)
		if exists {
			buf: [21]u8
			testing.expect_value(t, string(value_bytes(entry_value(&it, &nextentry), &buf)), model[expectedidx])
			entry_delete(&it, &nextentry)
			model_remove(model[:], &n, expectedidx)
		}
		assert_model(t, l, model[:n])
	}
	huge := make([]u8, 70000)
	defer delete(huge)
	for &b in huge {
		b = 'h'
	}
	testing.expect(t, lset(l, 3, huge))
	model[3] = string(huge)
	assert_model(t, l, model[:n])
	testing.expect(t, lset(l, 3, transmute([]u8)string("small")))
	model[3] = "small"
	assert_model(t, l, model[:n])
	d := dup(l)
	defer destroy(d)
	testing.expect_value(t, d.ql.len, l.ql.len)
	a := l.ql.head
	b := d.ql.head
	for a != nil {
		testing.expect(t, a != b && a.entry != b.entry)
		testing.expect_value(t, a.count, b.count)
		testing.expect_value(t, a.plain, b.plain)
		a = a.next
		b = b.next
	}
}

@(test)
legacy_and_corrupt_codecs :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	zip := [?]u8{17,0,0,0, 13,0,0,0, 2,0, 0,1,'a', 3,1,'b', 255}
	for kind in ([?]int{rdb.TYPE_LIST_ZIPLIST, rdb.TYPE_LIST_QUICKLIST}) {
		w: rdb.Writer
		rdb.writer_init_mem(&w, false, false)
		if kind == rdb.TYPE_LIST_QUICKLIST {
			rdb.put_len(&w, 1)
		}
		rdb.put_string(&w, zip[:])
		bytes := rdb.writer_bytes(&w)
		for n in 0..=len(bytes) {
			reader: rdb.Reader
			rdb.reader_init_mem(&reader, bytes[:n], false)
			l := rdb_load(&reader, kind, true)
			if n == len(bytes) {
				testing.expect(t, l != nil)
				if l != nil {
					assert_model(t, l, []string{"a", "b"})
					if kind == rdb.TYPE_LIST_ZIPLIST {
						testing.expect_value(t, l.encoding, Encoding.Quicklist)
					}
				}
			} else {
				testing.expect(t, l == nil)
				testing.expect(t, reader.status != .Ok)
			}
			destroy(l)
			rdb.reader_destroy(&reader)
		}
		rdb.writer_destroy(&w)
	}
	for mode in 0..<4 {
		w: rdb.Writer
		rdb.writer_init_mem(&w, false, false)
		if mode == 0 {
			rdb.put_len(&w, 0)
		} else {
			rdb.put_len(&w, 1)
			container := 2
			if mode == 1 {
				container = 9
			}
			rdb.put_len(&w, u64(container))
			if mode == 2 {
				rdb.put_string(&w, transmute([]u8)string("invalid"))
			} else if mode == 3 {
				rdb.put_string(&w, nil)
			}
		}
		reader: rdb.Reader
		rdb.reader_init_mem(&reader, rdb.writer_bytes(&w), false)
		l := rdb_load(&reader, rdb.TYPE_LIST_QUICKLIST_2, true)
		testing.expect(t, l == nil)
		expected := rdb.Status.Corrupt
		if mode == 0 {
			expected = .Empty_Key
		} else if mode == 3 {
			expected = .Short_Read
		}
		testing.expect_value(t, reader.status, expected)
		destroy(l)
		rdb.reader_destroy(&reader)
		rdb.writer_destroy(&w)
	}
}

@(test)
conversion_adoption_and_plain_codec :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	oldfill := list_max_listpack_size
	oldthreshold := packed_threshold
	defer {
		list_max_listpack_size = oldfill
		packed_threshold = oldthreshold
	}
	packed_threshold = 0
	list_max_listpack_size = 4
	l := create()
	defer destroy(l)
	for _ in 0..<4 {
		try_conversion_append(l, 1, 1)
		push(l, transmute([]u8)string("1"), .Tail)
	}
	testing.expect_value(t, l.encoding, Encoding.Listpack)
	adopted := l.lp
	try_conversion_append(l, 1, 1)
	testing.expect_value(t, l.encoding, Encoding.Quicklist)
	testing.expect_value(t, l.ql.head.entry, adopted)
	testing.expect_value(t, l.ql.count, 4)
	try_conversion(l, .Shrinking)
	testing.expect_value(t, l.encoding, Encoding.Quicklist)
	delete_range(l, 2, 2)
	try_conversion(l, .Shrinking)
	testing.expect_value(t, l.encoding, Encoding.Listpack)
	assert_model(t, l, []string{"1", "1"})
	list_max_listpack_size = 1
	try_conversion(l, .Growing)
	testing.expect_value(t, l.encoding, Encoding.Quicklist)
	list_max_listpack_size = 8
	try_conversion(l, .Growing)
	testing.expect_value(t, l.encoding, Encoding.Quicklist)
	try_conversion(l, .Auto)
	testing.expect_value(t, l.encoding, Encoding.Listpack)
	q := ql_new(-2, 0)
	pack := lp.lp_new(0)
	pack = lp.lp_append(pack, transmute([]u8)string("owned"))
	append_listpack(q, pack)
	testing.expect_value(t, q.head.entry, pack)
	testing.expect_value(t, q.mem, ql_memory_recount(q))
	ql_release(q)
	raw := make([]u8, 8193)
	defer delete(raw)
	for &b in raw {
		b = 0x80
	}
	plain := create_quicklist()
	defer destroy(plain)
	push(plain, raw, .Tail)
	testing.expect(t, plain.ql.head.plain)
	writer: rdb.Writer
	rdb.writer_init_mem(&writer, false, false)
	defer rdb.writer_destroy(&writer)
	rdb_save(&writer, plain)
	reader: rdb.Reader
	rdb.reader_init_mem(&reader, rdb.writer_bytes(&writer), false)
	restored := rdb_load(&reader, rdb.TYPE_LIST_QUICKLIST_2, true)
	testing.expect(t, restored != nil)
	if restored != nil {
		testing.expect(t, restored.ql.head.plain)
		assert_model(t, restored, []string{string(raw)})
		destroy(restored)
	}
	rdb.reader_destroy(&reader)
}

@(test)
observed_parse_errors :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	for input in ([?]string{"bad", "-1", "9223372036854775808", "01"}) {
		_, err := parse_pop_count(transmute([]u8)input)
		testing.expect_value(t, err, Error.Must_Be_Positive)
	}
	for option in ([?]string{"count", "maxlen", "rank"}) {
		args := [][]u8{transmute([]u8)option, transmute([]u8)string("bad")}
		_, err := parse_lpos_args(args)
		expected := Error.Not_Integer
		if option == "count" {
			expected = .Count_Negative
		} else if option == "maxlen" {
			expected = .Maxlen_Negative
		}
		testing.expect_value(t, err, expected)
	}
	for input in ([?]string{"bad", "0", "-1", "9223372036854775808"}) {
		args := [][]u8{transmute([]u8)string("lmpop"), transmute([]u8)input, transmute([]u8)string("key"), transmute([]u8)string("left")}
		_, err := parse_mpop_args(args, 1)
		testing.expect_value(t, err, Error.Numkeys)
		args = [][]u8{transmute([]u8)string("lmpop"), transmute([]u8)string("1"), transmute([]u8)string("key"), transmute([]u8)string("left"), transmute([]u8)string("count"), transmute([]u8)input}
		_, err = parse_mpop_args(args, 1)
		testing.expect_value(t, err, Error.Count_Positive)
	}
	_, err := config_parse(.Max_Listpack_Size, transmute([]u8)string("2147483648"))
	testing.expect_value(t, err, "argument must be between -2147483648 and 2147483647 inclusive")
	_, err = config_parse(.Compress_Depth, transmute([]u8)string("-1"))
	testing.expect_value(t, err, "argument must be between 0 and 2147483647 inclusive")
	_, err = config_parse(.Compress_Depth, transmute([]u8)string("bad"))
	testing.expect_value(t, err, "argument couldn't be parsed into an integer")
}

@(test)
observed_conversion_entrypoints :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	oldfill := list_max_listpack_size
	defer {
		list_max_listpack_size = oldfill
	}
	huge := make([]u8, 9000)
	defer delete(huge)
	for &b in huge {
		b = 'x'
	}
	for fill in ([?]int{1, 2, -2}) {
		list_max_listpack_size = fill
		for mode in 0..<5 {
			l := create()
			for value in ([]string{"a", "b"}) {
				try_conversion_append(l, len(value), 1)
				push(l, transmute([]u8)value, .Tail)
			}
			if mode == 0 {
				testing.expect(t, linsert(l, false, transmute([]u8)string("b"), huge))
				assert_model(t, l, []string{"a", string(huge), "b"})
				testing.expect_value(t, l.ql.len, 3)
				testing.expect(t, l.ql.head.next.plain)
			} else if mode == 1 {
				testing.expect(t, lset(l, 0, huge))
				assert_model(t, l, []string{string(huge), "b"})
				testing.expect_value(t, l.ql.len, 2)
				testing.expect(t, l.ql.head.plain)
			} else if mode == 2 {
				testing.expect(t, !linsert(l, false, transmute([]u8)string("absent"), huge))
				testing.expect_value(t, l.encoding, Encoding.Quicklist)
				assert_model(t, l, []string{"a", "b"})
			} else if mode == 3 {
				testing.expect(t, !lset(l, 100, huge))
				testing.expect_value(t, l.encoding, Encoding.Quicklist)
				assert_model(t, l, []string{"a", "b"})
			} else {
				testing.expect(t, lset(l, 4294967296, transmute([]u8)string("wrap")))
				assert_model(t, l, []string{"wrap", "b"})
				_, found := index(l, 4294967296)
				testing.expect(t, !found)
			}
			destroy(l)
		}
	}
}

@(test)
observed_memory_grammar :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	oldthreshold := packed_threshold
	defer {
		packed_threshold = oldthreshold
	}
	for input in ([]string{"", "b", "k", "kb", "m", "mb", "g", "gb", "0"}) {
		testing.expect_value(t, parse_packed_threshold(transmute([]u8)input), Error.None)
		testing.expect_value(t, packed_threshold, 0)
	}
	for input in ([]string{"1", "01"}) {
		testing.expect_value(t, parse_packed_threshold(transmute([]u8)input), Error.None)
		testing.expect_value(t, packed_threshold, 1)
	}
	testing.expect_value(t, parse_packed_threshold(transmute([]u8)string("1KB")), Error.None)
	testing.expect_value(t, packed_threshold, 1024)
	for input in ([]string{"+1", " 1", "1 ", "1KiB", "0x10", "18446744073709551615", "18446744073709551616", "18446744073709551615kb"}) {
		testing.expect_value(t, parse_packed_threshold(transmute([]u8)input), Error.Packed_Threshold)
		testing.expect_value(t, packed_threshold, 1024)
	}
	long := make([]u8, 128)
	defer delete(long)
	for &b in long {
		b = '9'
	}
	testing.expect_value(t, parse_packed_threshold(long[:127]), Error.Packed_Threshold)
	testing.expect_value(t, parse_packed_threshold(long), Error.Packed_Threshold)
}

@(test)
observed_conversion_limits :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	oldfill := list_max_listpack_size
	defer {
		list_max_listpack_size = oldfill
	}
	_, err := parse_lrem_count(transmute([]u8)string("-9223372036854775808"))
	testing.expect_value(t, err, Error.Long_Range)
	_, err = parse_lrem_count(transmute([]u8)string("-9223372036854775807"))
	testing.expect_value(t, err, Error.None)
	limit, count := node_limit(17)
	testing.expect_value(t, limit, NO_LIMIT)
	testing.expect_value(t, count, 17)
	testing.expect(t, node_exceeds_limit(17, 8193, 1))
	testing.expect(t, is_large_element(8193, 17))
	list_max_listpack_size = 17
	l := create_quicklist()
	value := make([]u8, 2000)
	defer delete(value)
	for &b in value {
		b = 'x'
	}
	for _ in 0..<3 {
		push(l, value, .Tail)
	}
	testing.expect(t, l.ql.head.sz > 4096 && l.ql.head.sz < 8192)
	try_conversion(l, .Shrinking)
	testing.expect_value(t, l.encoding, Encoding.Listpack)
	assert_model(t, l, []string{string(value), string(value), string(value)})
	destroy(l)
	large := make([]u8, 9000)
	defer delete(large)
	for &b in large {
		b = 'y'
	}
	l = create()
	push(l, large, .Tail)
	try_conversion(l, .Auto)
	testing.expect_value(t, l.encoding, Encoding.Quicklist)
	try_conversion(l, .Auto)
	testing.expect_value(t, l.encoding, Encoding.Listpack)
	destroy(l)
}

@(test)
observed_split_and_replace_boundaries :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	oldfill := list_max_listpack_size
	oldthreshold := packed_threshold
	defer {
		list_max_listpack_size = oldfill
		packed_threshold = oldthreshold
	}
	list_max_listpack_size = -3
	packed_threshold = 0
	l := create()
	for value in ([]string{"a", "b", "c"}) {
		push(l, transmute([]u8)value, .Tail)
	}
	z := make([]u8, 8190)
	y := make([]u8, 9000)
	defer delete(z)
	defer delete(y)
	for &b in z {
		b = 'Z'
	}
	for &b in y {
		b = 'Y'
	}
	try_conversion_append(l, len(z), 1)
	push(l, z, .Tail)
	testing.expect(t, linsert(l, true, transmute([]u8)string("b"), y))
	assert_model(t, l, []string{"a", "b", string(y), "c", string(z)})
	testing.expect_value(t, l.ql.len, 2)
	testing.expect_value(t, l.ql.head.count, 2)
	testing.expect_value(t, l.ql.tail.count, 3)
	testing.expect(t, l.ql.tail.sz > 16384)
	destroy(l)
	list_max_listpack_size = 4
	l = create_quicklist()
	for value in ([]string{"m20", "p3", "m22", "m23"}) {
		push(l, transmute([]u8)value, .Tail)
	}
	testing.expect(t, linsert(l, true, transmute([]u8)string("p3"), transmute([]u8)string("1")))
	assert_model(t, l, []string{"m20", "p3", "1", "m22", "m23"})
	testing.expect_value(t, l.ql.len, 2)
	testing.expect_value(t, l.ql.head.count, 2)
	testing.expect_value(t, l.ql.tail.count, 3)
	v := value_from_lp(lp.lp_first(l.ql.tail.entry))
	testing.expect(t, v.is_int && v.ival == 1)
	destroy(l)
	packed_threshold = 5
	l = create_quicklist()
	for values in ([][]string{{"bbbbbbbbbbbb", "bbbbbbbbbbb"}, {"c", "cccc"}}) {
		pack := lp.lp_new(0)
		for value in values {
			pack = lp.lp_append(pack, transmute([]u8)value)
		}
		append_listpack(l.ql, pack)
	}
	push(l, transmute([]u8)string("bbbbbbbbb"), .Tail)
	push(l, transmute([]u8)string("bbbbbbbbb"), .Tail)
	testing.expect_value(t, l.ql.len, 4)
	testing.expect(t, lset(l, 3, transmute([]u8)string("aaaaaaaaaaa")))
	assert_model(t, l, []string{"bbbbbbbbbbbb", "bbbbbbbbbbb", "c", "aaaaaaaaaaa", "bbbbbbbbb", "bbbbbbbbb"})
	testing.expect_value(t, l.ql.len, 4)
	testing.expect_value(t, l.ql.head.count, 3)
	testing.expect(t, l.ql.head.next.plain)
	destroy(l)
}

@(test)
observed_neighbor_merge_boundaries :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	oldfill := list_max_listpack_size
	oldthreshold := packed_threshold
	defer {
		list_max_listpack_size = oldfill
		packed_threshold = oldthreshold
	}
	list_max_listpack_size = 4
	packed_threshold = 0
	l := create_quicklist()
	for values in ([][]string{{"a", "b", "c", "pivot"}, {"d", "e"}}) {
		pack := lp.lp_new(0)
		for value in values {
			pack = lp.lp_append(pack, transmute([]u8)value)
		}
		append_listpack(l.ql, pack)
	}
	testing.expect(t, linsert(l, false, transmute([]u8)string("pivot"), transmute([]u8)string("x")))
	assert_model(t, l, []string{"a", "b", "c", "x", "pivot", "d", "e"})
	testing.expect_value(t, l.ql.len, 2)
	testing.expect_value(t, l.ql.head.count, 4)
	testing.expect_value(t, l.ql.tail.count, 3)
	destroy(l)
	l = create_quicklist()
	for values in ([][]string{{"prev"}, {"a", "pivot", "c", "d"}, {"next"}}) {
		pack := lp.lp_new(0)
		for value in values {
			pack = lp.lp_append(pack, transmute([]u8)value)
		}
		append_listpack(l.ql, pack)
	}
	large := make([]u8, 9000)
	defer delete(large)
	for &b in large {
		b = 'X'
	}
	testing.expect(t, linsert(l, true, transmute([]u8)string("pivot"), large))
	assert_model(t, l, []string{"prev", "a", "pivot", string(large), "c", "d", "next"})
	testing.expect_value(t, l.ql.len, 5)
	testing.expect_value(t, l.ql.head.count, 1)
	testing.expect_value(t, l.ql.head.next.count, 2)
	testing.expect(t, l.ql.head.next.next.plain)
	testing.expect_value(t, l.ql.tail.prev.count, 2)
	testing.expect_value(t, l.ql.tail.count, 1)
	destroy(l)
}
