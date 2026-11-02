package zsettype

import lp "../listpack"

ZRANDMEMBER_SUB_STRATEGY_MUL :: 3

ZRANDMEMBER_RANDOM_SAMPLE_LIMIT :: 1000

item_from_entry :: proc "contextless" (e: lp.Element) -> Item {
	if e.text == nil {
		return Item{ival = e.number, is_int = true}
	}
	return Item{str = e.text[:int(e.text_len)]}
}

score_from_entry :: proc "contextless" (e: lp.Element) -> f64 {
	if e.text == nil {
		return f64(e.number)
	}
	return score_from_lp_string(e.text[:int(e.text_len)])
}

random_element :: proc(z: Zset) -> Item {
	if length(z) == 0 {
		return {}
	}
	if z.encoding == .Skiplist {
		return item_from_node(dict_random_node(z.sl))
	}
	p := lp.lp_seek(z.lp, i64(rand_below(u64(length(z)))) * 2)
	item := item_from_lp(p)
	item.score = zzl_score(lp.lp_next(z.lp, p))
	return item
}

random_with_repeats :: proc(z: Zset, count: int, out: ^[dynamic]Item) {
	if length(z) == 0 {
		return
	}
	for _ in 0 ..< count {
		append(out, random_element(z))
	}
}

random_unique :: proc(z: Zset, count: int, out: ^[dynamic]Item) {
	n := length(z)
	remaining := min(count, n)
	it := iter_make(z, count >= n)
	item: Item
	for iter_next(&it, &item) {
		if rand_below(u64(n)) < u64(remaining) {
			append(out, item)
			remaining -= 1
		}
		n -= 1
		if remaining == 0 {
			break
		}
	}
}

scan_node :: proc(user: rawptr, n: ^Node) {
	out := cast(^[dynamic]Item)user
	append(out, Item{str = node_member(n)}, Item{score = n.score, g17 = true})
}

scan :: proc(z: Zset, cursor: u64, count: int, out: ^[dynamic]Item) -> u64 {
	if z.encoding == .Listpack {
		for p := lp.lp_first(z.lp); p != nil; p = lp.lp_next(z.lp, p) {
			append(out, item_from_entry(lp.lp_get_entry(p)))
		}
		return 0
	}
	if length(z) == 0 {
		return 0
	}
	wanted := max(count, 1)
	visits := max(int) if wanted > max(int) / 10 else wanted * 10
	first := len(out)
	v := cursor
	for ; visits > 0; visits -= 1 {
		v = dict_scan_bucket(z.sl, v, scan_node, out)
		if v == 0 || (len(out) - first) / 2 >= wanted {
			break
		}
	}
	return v
}

scan_value_bytes :: proc "contextless" (it: ^Item, buf: ^[G17_MAX]u8) -> []u8 {
	if it.g17 {
		n := format_g17(buf[:], it.score)
		return buf[:n]
	}
	if it.is_int {
		n := lp.ll2string(raw_data(buf[:]), it.ival)
		return buf[:n]
	}
	return it.str
}
