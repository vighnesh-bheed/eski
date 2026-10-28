#+private
package rax

import "base:intrinsics"

Node :: struct {
	count:  u16,
	cap:    u16,
	level:  u8,
	varlen: bool,
	spare:  u16,
	plen:   u32,
	width:  u32,
	size:   u32,
	voff:   u32,
}

NODE_HEADER :: size_of(Node)
INNER_HEADER :: NODE_HEADER + size_of(rawptr)
HEAD_BYTES :: 16
LINEAR_LIMIT :: 64
CACHE_LINE :: 64
PROBE_COPY :: 64
PROBE_SLACK :: 16

Probe_Buffer :: [PROBE_COPY + PROBE_SLACK]u8
TAIL_PAD :: 8
LEAF_LIMIT :: 2040
INNER_LIMIT :: 4088
SCRATCH_BYTES :: 4096
MAX_ENTRY_COUNT :: 65535
PATTERN_MAX :: 64

node_body :: #force_inline proc "contextless" (n: ^Node) -> int {
	return NODE_HEADER if n.level == 0 else INNER_HEADER
}

level_body :: #force_inline proc "contextless" (level: u8) -> int {
	return NODE_HEADER if level == 0 else INNER_HEADER
}

level_limit :: #force_inline proc "contextless" (level: u8) -> int {
	return LEAF_LIMIT if level == 0 else INNER_LIMIT
}

align8 :: #force_inline proc "contextless" (x: int) -> int {
	return (x + 7) &~ 7
}

node_bytes :: #force_inline proc "contextless" (n: ^Node) -> [^]u8 {
	return cast([^]u8)n
}

node_first :: #force_inline proc "contextless" (n: ^Node) -> ^Node {
	return (cast(^^Node)&node_bytes(n)[NODE_HEADER])^
}

node_set_first :: #force_inline proc "contextless" (n: ^Node, c: ^Node) {
	(cast(^^Node)&node_bytes(n)[NODE_HEADER])^ = c
}

node_prefix :: #force_inline proc "contextless" (n: ^Node) -> [^]u8 {
	return node_bytes(n)[node_body(n):]
}

pattern_slots :: #force_inline proc "contextless" (n: ^Node) -> int {
	return node_body(n) + 2 * int(n.plen) + int(n.width)
}

pattern_used :: #force_inline proc "contextless" (body: int, length: int, k: int, count: int) -> int {
	return align8(body + 2 * length + k + count * k) + count * size_of(rawptr)
}

pattern_key_copy :: proc "contextless" (n: ^Node, i: int, dst: [^]u8) #no_bounds_check {
	b := node_bytes(n)
	body := node_body(n)
	length := int(n.plen)
	k := int(n.width)
	if length > 0 {
		intrinsics.mem_copy_non_overlapping(dst, &b[body], length)
	}
	pos := b[body + 2 * length:]
	slot := b[body + 2 * length + k + i * k:]
	for t in 0 ..< k {
		dst[pos[t]] = slot[t]
	}
}

pattern_matches :: proc "contextless" (n: ^Node, s: [^]u8, sroom: int) -> bool #no_bounds_check {
	b := node_bytes(n)
	body := node_body(n)
	length := int(n.plen)
	tmpl := b[body:]
	cmask := b[body + length:]
	for off := 0; off < length; off += 8 {
		d := (probe_word(s[off:], sroom - off) ~ load_be(tmpl[off:])) & load_be(cmask[off:]) & mask_top64(length - off)
		if d != 0 {
			return false
		}
	}
	return true
}

load_be :: #force_inline proc "contextless" (p: [^]u8) -> u64 {
	return intrinsics.byte_swap(intrinsics.unaligned_load(cast(^u64)p))
}

probe_word :: #force_inline proc "contextless" (p: [^]u8, avail: int) -> u64 #no_bounds_check {
	if avail >= 8 {
		return load_be(p)
	}
	v: u64 = 0
	for i in 0 ..< avail {
		v |= u64(p[i]) << u64(56 - 8 * i)
	}
	return v
}

mask_top64 :: #force_inline proc "contextless" (bytes: int) -> u64 {
	if bytes <= 0 {
		return 0
	}
	if bytes >= 8 {
		return max(u64)
	}
	return ~(max(u64) >> u64(8 * bytes))
}

mask_top128 :: #force_inline proc "contextless" (bytes: int) -> u128 {
	if bytes <= 0 {
		return 0
	}
	if bytes >= 16 {
		return max(u128)
	}
	return ~(max(u128) >> u128(8 * bytes))
}

cmp_span :: proc "contextless" (t: [^]u8, tavail: int, k: [^]u8, m: int) -> int #no_bounds_check {
	i := 0
	for i + 8 <= m {
		x := load_be(t[i:])
		y := load_be(k[i:])
		if x != y {
			return -1 if x < y else 1
		}
		i += 8
	}
	rest := m - i
	if rest > 0 {
		shift := u64(64 - 8 * rest)
		x := probe_word(t[i:], tavail - i) >> shift
		y := load_be(k[i:]) >> shift
		if x != y {
			return -1 if x < y else 1
		}
	}
	return 0
}

cmp_key :: #force_inline proc "contextless" (t: [^]u8, tl: int, troom: int, k: [^]u8, kl: int) -> int {
	c := cmp_span(t, troom, k, min(tl, kl))
	if c != 0 {
		return c
	}
	if tl < kl {
		return -1
	}
	if tl > kl {
		return 1
	}
	return 0
}

Var_View :: struct {
	b:     [^]u8,
	hints: int,
	offs:  int,
	ptrs:  int,
	top:   int,
	count: int,
}

var_view :: #force_inline proc "contextless" (n: ^Node) -> Var_View {
	h := node_body(n) + int(n.plen)
	c := int(n.cap)
	return Var_View{node_bytes(n), h, h + 4 * c, h + 8 * c, int(n.voff), int(n.count)}
}

vv_start :: #force_inline proc "contextless" (v: Var_View, i: int) -> int {
	return int(intrinsics.unaligned_load(cast(^u32)&v.b[v.offs + 4 * i]))
}

vv_end :: #force_inline proc "contextless" (v: Var_View, i: int) -> int {
	if i == 0 {
		return v.top
	}
	return vv_start(v, i - 1)
}

vv_ptr :: #force_inline proc "contextless" (v: Var_View, i: int) -> rawptr {
	return intrinsics.unaligned_load(cast(^rawptr)&v.b[v.ptrs + 8 * i])
}

vv_set :: #force_inline proc "contextless" (v: Var_View, i: int, hint: u32, start: int, p: rawptr) {
	intrinsics.unaligned_store(cast(^u32)&v.b[v.hints + 4 * i], hint)
	intrinsics.unaligned_store(cast(^u32)&v.b[v.offs + 4 * i], u32(start))
	intrinsics.unaligned_store(cast(^rawptr)&v.b[v.ptrs + 8 * i], p)
}

vv_set_ptr :: #force_inline proc "contextless" (v: Var_View, i: int, p: rawptr) {
	intrinsics.unaligned_store(cast(^rawptr)&v.b[v.ptrs + 8 * i], p)
}

vv_shift_starts :: #force_inline proc "contextless" (v: Var_View, from: int, to: int, delta: int) #no_bounds_check {
	for j in from ..< to {
		p := cast(^u32)&v.b[v.offs + 4 * j]
		intrinsics.unaligned_store(p, u32(int(intrinsics.unaligned_load(p)) + delta))
	}
}

suffix_hint :: #force_inline proc "contextless" (p: [^]u8, n: int) -> u32 #no_bounds_check {
	v: u32 = 0
	for j in 0 ..< min(n, 4) {
		v |= u32(p[j]) << u32(24 - 8 * j)
	}
	return v
}

probe_hint :: #force_inline proc "contextless" (t: [^]u8, tl: int) -> u32 {
	return u32(probe_word(t, tl) >> 32)
}

prefetch_skeleton :: #force_inline proc "contextless" (b: [^]u8, base: int, count: int, stride: int) {
	for k in 1 ..= 7 {
		intrinsics.prefetch_read_data(&b[base + ((count * k) >> 3) * stride], 3)
	}
}

prefetch_span :: #force_inline proc "contextless" (b: [^]u8, from: int, to: int) {
	line := uintptr(&b[from]) &~ uintptr(CACHE_LINE - 1)
	last := uintptr(&b[to])
	for line < last {
		intrinsics.prefetch_read_data(rawptr(line), 3)
		line += CACHE_LINE
	}
}

entry_key :: #force_inline proc "contextless" (n: ^Node, i: int) -> ([^]u8, int) {
	v := var_view(n)
	start := vv_start(v, i)
	return v.b[start:], vv_end(v, i) - start
}

entry_ptr :: #force_inline proc "contextless" (n: ^Node, i: int) -> rawptr {
	b := node_bytes(n)
	if !n.varlen {
		return (cast([^]rawptr)&b[n.voff])[i]
	}
	return vv_ptr(var_view(n), i)
}

entry_set_ptr :: #force_inline proc "contextless" (n: ^Node, i: int, p: rawptr) {
	b := node_bytes(n)
	if !n.varlen {
		(cast([^]rawptr)&b[n.voff])[i] = p
		return
	}
	vv_set_ptr(var_view(n), i, p)
}

child_at :: #force_inline proc "contextless" (n: ^Node, ci: int) -> ^Node {
	if ci == 0 {
		return node_first(n)
	}
	return cast(^Node)entry_ptr(n, ci - 1)
}

set_child :: #force_inline proc "contextless" (n: ^Node, ci: int, c: ^Node) {
	if ci == 0 {
		node_set_first(n, c)
		return
	}
	entry_set_ptr(n, ci - 1, c)
}

var_bottom :: #force_inline proc "contextless" (n: ^Node) -> int {
	if n.count == 0 {
		return int(n.voff)
	}
	return vv_start(var_view(n), int(n.count) - 1)
}

var_heap_free :: #force_inline proc "contextless" (n: ^Node) -> int {
	return var_bottom(n) - (node_body(n) + int(n.plen) + int(n.cap) * HEAD_BYTES)
}

node_used :: proc "contextless" (n: ^Node) -> int {
	count := int(n.count)
	if !n.varlen {
		return pattern_used(node_body(n), int(n.plen), int(n.width), count)
	}
	return node_body(n) + int(n.plen) + count * HEAD_BYTES + (int(n.voff) - var_bottom(n)) + TAIL_PAD
}

prefix_equal :: #force_inline proc "contextless" (n: ^Node, s: [^]u8, sl: int, sroom: int) -> bool {
	plen := int(n.plen)
	if sl < plen {
		return false
	}
	return cmp_span(s, sroom, node_prefix(n), plen) == 0
}

pick :: #force_inline proc "contextless" (cond: bool, v: int) -> int {
	return v & -int(transmute(u8)cond)
}

probe_prepare :: #force_inline proc "contextless" (buf: ^Probe_Buffer, s: []u8) -> ([^]u8, int, int) {
	sl := len(s)
	if sl <= PROBE_COPY {
		if sl > 0 {
			intrinsics.mem_copy_non_overlapping(&buf[0], raw_data(s), sl)
		}
		intrinsics.mem_zero(&buf[sl], PROBE_SLACK)
		return &buf[0], sl, sl + PROBE_SLACK
	}
	return raw_data(s), sl, sl
}

search_slots64 :: #force_inline proc "contextless" (
	kb: [^]u8,
	count: int,
	k: int,
	tw: u64,
	m: int,
	tie: int,
	upper: bool,
) -> (
	int,
	bool,
) #no_bounds_check {
	wm := mask_top64(m)
	inclusive := tie > 0 || (upper && tie == 0)
	base := 0
	length := count
	if inclusive {
		for length > 1 {
			half := length >> 1
			base += pick((load_be(kb[(base + half - 1) * k:]) & wm) <= tw, half)
			length -= half
		}
		if (load_be(kb[base * k:]) & wm) <= tw {
			base += 1
		}
	} else {
		for length > 1 {
			half := length >> 1
			base += pick((load_be(kb[(base + half - 1) * k:]) & wm) < tw, half)
			length -= half
		}
		if (load_be(kb[base * k:]) & wm) < tw {
			base += 1
		}
	}
	exact := false
	if !upper && tie == 0 && base < count {
		exact = (load_be(kb[base * k:]) & wm) == tw
	}
	return base, exact
}

slot128 :: #force_inline proc "contextless" (p: [^]u8, wm: u128) -> u128 {
	return ((u128(load_be(p)) << 64) | u128(load_be(p[8:]))) & wm
}

search_slots128 :: #force_inline proc "contextless" (
	kb: [^]u8,
	count: int,
	k: int,
	tw: u128,
	m: int,
	tie: int,
	upper: bool,
) -> (
	int,
	bool,
) #no_bounds_check {
	wm := mask_top128(m)
	inclusive := tie > 0 || (upper && tie == 0)
	base := 0
	length := count
	if inclusive {
		for length > 1 {
			half := length >> 1
			base += pick(slot128(kb[(base + half - 1) * k:], wm) <= tw, half)
			length -= half
		}
		if slot128(kb[base * k:], wm) <= tw {
			base += 1
		}
	} else {
		for length > 1 {
			half := length >> 1
			base += pick(slot128(kb[(base + half - 1) * k:], wm) < tw, half)
			length -= half
		}
		if slot128(kb[base * k:], wm) < tw {
			base += 1
		}
	}
	exact := false
	if !upper && tie == 0 && base < count {
		exact = slot128(kb[base * k:], wm) == tw
	}
	return base, exact
}

search_slots_wide :: proc "contextless" (
	kb: [^]u8,
	count: int,
	k: int,
	probe: [^]u8,
	m: int,
	tie: int,
	upper: bool,
) -> (
	int,
	bool,
) #no_bounds_check {
	before :: #force_inline proc "contextless" (slot: [^]u8, probe: [^]u8, m: int, tie: int, upper: bool) -> bool {
		c := cmp_span(probe, m, slot, m)
		if c == 0 {
			c = tie
		}
		return c > 0 || (upper && c == 0)
	}
	base := 0
	length := count
	for length > 1 {
		half := length >> 1
		if before(kb[(base + half - 1) * k:], probe, m, tie, upper) {
			base += half
		}
		length -= half
	}
	if before(kb[base * k:], probe, m, tie, upper) {
		base += 1
	}
	exact := !upper && tie == 0 && base < count && cmp_span(probe, m, kb[base * k:], m) == 0
	return base, exact
}

Pattern_Probe :: struct {
	kb:   int,
	k:    int,
	m:    int,
	tie:  int,
	w64:  u64,
	w128: u128,
	wide: [PATTERN_MAX + 8]u8,
}

pattern_probe :: #force_inline proc "contextless" (n: ^Node, s: [^]u8, sl: int, sroom: int, pp: ^Pattern_Probe) #no_bounds_check {
	b := node_bytes(n)
	body := node_body(n)
	length := int(n.plen)
	k := int(n.width)
	tmpl := b[body:]
	cmask := b[body + length:]
	pos := b[body + 2 * length:]
	lim := min(sl, length)
	c := lim
	for off := 0; off < lim; off += 8 {
		d := (probe_word(s[off:], sroom - off) ~ load_be(tmpl[off:])) & load_be(cmask[off:]) & mask_top64(lim - off)
		if d != 0 {
			c = off + int(intrinsics.count_leading_zeros(d) >> 3)
			break
		}
	}
	tie := 0
	if c < lim {
		tie = -1 if s[c] < tmpl[c] else 1
	} else if sl < length {
		tie = -1
	} else if sl > length {
		tie = 1
	}
	m := 0
	for m < k && int(pos[m]) < c {
		m += 1
	}
	pp.kb = body + 2 * length + k
	pp.k = k
	pp.m = m
	pp.tie = tie
	if k <= 8 {
		tw: u64 = 0
		for t in 0 ..< m {
			tw |= u64(s[pos[t]]) << u64(56 - 8 * t)
		}
		pp.w64 = tw
	} else if k <= 16 {
		tw: u128 = 0
		for t in 0 ..< m {
			tw |= u128(s[pos[t]]) << u128(120 - 8 * t)
		}
		pp.w128 = tw
	} else {
		for t in 0 ..< m {
			pp.wide[t] = s[pos[t]]
		}
	}
}

pattern_compare_slot :: #force_inline proc "contextless" (n: ^Node, pp: ^Pattern_Probe, i: int) -> int #no_bounds_check {
	slot := node_bytes(n)[pp.kb + i * pp.k:]
	c := 0
	if pp.k <= 8 {
		sw := load_be(slot) & mask_top64(pp.m)
		c = -1 if pp.w64 < sw else (1 if pp.w64 > sw else 0)
	} else if pp.k <= 16 {
		sw := slot128(slot, mask_top128(pp.m))
		c = -1 if pp.w128 < sw else (1 if pp.w128 > sw else 0)
	} else {
		c = cmp_span(&pp.wide[0], pp.m, slot, pp.m)
	}
	return pp.tie if c == 0 else c
}

search_pattern_with :: #force_inline proc "contextless" (n: ^Node, pp: ^Pattern_Probe, upper: bool) -> (int, bool) {
	b := node_bytes(n)
	count := int(n.count)
	if pp.k <= 8 {
		return search_slots64(b[pp.kb:], count, pp.k, pp.w64, pp.m, pp.tie, upper)
	}
	if pp.k <= 16 {
		return search_slots128(b[pp.kb:], count, pp.k, pp.w128, pp.m, pp.tie, upper)
	}
	return search_slots_wide(b[pp.kb:], count, pp.k, &pp.wide[0], pp.m, pp.tie, upper)
}

search_pattern :: proc "contextless" (n: ^Node, s: [^]u8, sl: int, sroom: int, upper: bool, cold: bool) -> (int, bool) #no_bounds_check {
	if cold {
		b := node_bytes(n)
		count := int(n.count)
		k := int(n.width)
		kb := node_body(n) + 2 * int(n.plen) + k
		if n.level == 0 {
			prefetch_span(b, kb, kb + count * k)
			prefetch_span(b, int(n.voff), int(n.voff) + count * size_of(rawptr))
		} else if count > 16 {
			prefetch_skeleton(b, kb, count, k)
		}
	}
	pp: Pattern_Probe = ---
	pattern_probe(n, s, sl, sroom, &pp)
	return search_pattern_with(n, &pp, upper)
}

var_compare_entry :: proc "contextless" (n: ^Node, i: int, s: [^]u8, sl: int, sroom: int) -> int #no_bounds_check {
	plen := int(n.plen)
	if plen > 0 {
		c := cmp_span(s, sroom, node_prefix(n), min(sl, plen))
		if c != 0 {
			return c
		}
		if sl < plen {
			return -1
		}
	}
	k, kl := entry_key(n, i)
	return cmp_key(s[plen:], sl - plen, sroom - plen, k, kl)
}

search_var :: proc "contextless" (v: Var_View, t: [^]u8, tl: int, troom: int, upper: bool) -> (int, bool) #no_bounds_check {
	limit := 0 if upper else 1
	th := probe_hint(t, troom)
	count := v.count
	hints := cast([^]u32)&v.b[v.hints]
	below := 0
	if count <= LINEAR_LIMIT {
		narrow: u32 = 0
		for i in 0 ..< count {
			narrow += 1 if intrinsics.unaligned_load(&hints[i]) < th else 0
		}
		below = int(narrow)
	} else {
		length := count
		for length > 1 {
			half := length >> 1
			below += pick(intrinsics.unaligned_load(&hints[below + half - 1]) < th, half)
			length -= half
		}
		below += 1 if intrinsics.unaligned_load(&hints[below]) < th else 0
	}
	pos := below
	for pos < count && intrinsics.unaligned_load(&hints[pos]) == th {
		start := vv_start(v, pos)
		c := cmp_key(t, tl, troom, v.b[start:], vv_end(v, pos) - start)
		if c < limit {
			return pos, !upper && c == 0
		}
		pos += 1
	}
	return pos, false
}

node_search :: #force_inline proc "contextless" (n: ^Node, s: [^]u8, sl: int, sroom: int, upper: bool) -> (int, bool) {
	return node_lookup(n, s, sl, sroom, upper, true)
}

node_lookup :: proc "contextless" (n: ^Node, s: [^]u8, sl: int, sroom: int, upper: bool, cold: bool) -> (int, bool) #no_bounds_check {
	count := int(n.count)
	if count == 0 {
		return 0, false
	}
	if !n.varlen {
		return search_pattern(n, s, sl, sroom, upper, cold)
	}
	b := node_bytes(n)
	plen := int(n.plen)
	if plen > 0 {
		c := cmp_span(s, sroom, b[node_body(n):], min(sl, plen))
		if c < 0 {
			return 0, false
		}
		if c > 0 {
			return count, false
		}
		if sl < plen {
			return 0, false
		}
	}
	t := s[plen:] if s != nil else s
	tl := sl - plen
	troom := sroom - plen
	v := var_view(n)
	if cold {
		if n.level == 0 {
			prefetch_span(b, v.hints, v.hints + 4 * count)
			prefetch_span(b, v.offs, v.offs + 4 * count)
			prefetch_span(b, v.ptrs, v.ptrs + 8 * count)
		} else if count > LINEAR_LIMIT {
			prefetch_skeleton(b, v.hints, count, 4)
		}
	}
	return search_var(v, t, tl, troom, upper)
}

pattern_insert :: proc "contextless" (n: ^Node, idx: int, s: [^]u8, p: rawptr) #no_bounds_check {
	b := node_bytes(n)
	body := node_body(n)
	length := int(n.plen)
	k := int(n.width)
	count := int(n.count)
	pos := b[body + 2 * length:]
	kb := b[body + 2 * length + k:]
	vals := cast([^]rawptr)&b[n.voff]
	if idx < count {
		intrinsics.mem_copy(&kb[(idx + 1) * k], &kb[idx * k], (count - idx) * k)
		intrinsics.mem_copy(&vals[idx + 1], &vals[idx], (count - idx) * size_of(rawptr))
	}
	slot := kb[idx * k:]
	for t in 0 ..< k {
		slot[t] = s[pos[t]]
	}
	vals[idx] = p
	n.count = u16(count + 1)
}

pattern_remove :: proc "contextless" (n: ^Node, idx: int) #no_bounds_check {
	b := node_bytes(n)
	k := int(n.width)
	count := int(n.count)
	kb := b[pattern_slots(n):]
	vals := cast([^]rawptr)&b[n.voff]
	tail := count - idx - 1
	if tail > 0 {
		intrinsics.mem_copy(&kb[idx * k], &kb[(idx + 1) * k], tail * k)
		intrinsics.mem_copy(&vals[idx], &vals[idx + 1], tail * size_of(rawptr))
	}
	n.count = u16(count - 1)
}

var_make_room :: proc "contextless" (n: ^Node, tl: int) -> bool #no_bounds_check {
	count := int(n.count)
	capacity := int(n.cap)
	if count < capacity && var_heap_free(n) >= tl {
		return true
	}
	v := var_view(n)
	bottom := v.top if count == 0 else vv_start(v, count - 1)
	h := v.hints
	spare := bottom - (h + HEAD_BYTES * (count + 1)) - tl
	if spare < 0 {
		return false
	}
	avg := (v.top - bottom) / max(count, 1)
	grown := min(count + 1 + spare / (HEAD_BYTES + avg), MAX_ENTRY_COUNT)
	b := v.b
	if grown > capacity {
		intrinsics.mem_copy(&b[h + 8 * grown], &b[h + 8 * capacity], 8 * count)
		intrinsics.mem_copy(&b[h + 4 * grown], &b[h + 4 * capacity], 4 * count)
	} else if grown < capacity {
		intrinsics.mem_copy(&b[h + 4 * grown], &b[h + 4 * capacity], 4 * count)
		intrinsics.mem_copy(&b[h + 8 * grown], &b[h + 8 * capacity], 8 * count)
	}
	n.cap = u16(grown)
	return true
}

var_insert :: proc "contextless" (n: ^Node, idx: int, t: [^]u8, tl: int, p: rawptr) #no_bounds_check {
	v := var_view(n)
	b := v.b
	count := v.count
	end := vv_end(v, idx)
	bottom := v.top if count == 0 else vv_start(v, count - 1)
	if end > bottom && tl > 0 {
		intrinsics.mem_copy(&b[bottom - tl], &b[bottom], end - bottom)
	}
	tail := count - idx
	if tail > 0 {
		intrinsics.mem_copy(&b[v.hints + 4 * (idx + 1)], &b[v.hints + 4 * idx], 4 * tail)
		intrinsics.mem_copy(&b[v.offs + 4 * (idx + 1)], &b[v.offs + 4 * idx], 4 * tail)
		intrinsics.mem_copy(&b[v.ptrs + 8 * (idx + 1)], &b[v.ptrs + 8 * idx], 8 * tail)
		if tl > 0 {
			vv_shift_starts(v, idx + 1, count + 1, -tl)
		}
	}
	if tl > 0 {
		intrinsics.mem_copy_non_overlapping(&b[end - tl], t, tl)
	}
	vv_set(v, idx, suffix_hint(t, tl), end - tl, p)
	n.count = u16(count + 1)
}

var_remove :: proc "contextless" (n: ^Node, idx: int) #no_bounds_check {
	v := var_view(n)
	b := v.b
	count := v.count
	start := vv_start(v, idx)
	k := vv_end(v, idx) - start
	bottom := vv_start(v, count - 1)
	if start > bottom && k > 0 {
		intrinsics.mem_copy(&b[bottom + k], &b[bottom], start - bottom)
	}
	tail := count - idx - 1
	if tail > 0 {
		intrinsics.mem_copy(&b[v.hints + 4 * idx], &b[v.hints + 4 * (idx + 1)], 4 * tail)
		intrinsics.mem_copy(&b[v.offs + 4 * idx], &b[v.offs + 4 * (idx + 1)], 4 * tail)
		intrinsics.mem_copy(&b[v.ptrs + 8 * idx], &b[v.ptrs + 8 * (idx + 1)], 8 * tail)
		if k > 0 {
			vv_shift_starts(v, idx, count - 1, k)
		}
	}
	n.count = u16(count - 1)
}

entry_remove :: #force_inline proc "contextless" (n: ^Node, idx: int) {
	if n.varlen {
		var_remove(n, idx)
	} else {
		pattern_remove(n, idx)
	}
}
