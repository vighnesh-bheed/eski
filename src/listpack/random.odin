package listpack

import "base:intrinsics"
import "core:slice"

random_state: u64 = 11400714819323198485

lp_srand :: proc "contextless" (seed: u64) {
	intrinsics.atomic_store_explicit(&random_state, seed if seed != 0 else 11400714819323198485, .Relaxed)
}

lp_rand :: proc "contextless" () -> u32 {
	previous := intrinsics.atomic_load_explicit(&random_state, .Relaxed)
	for {
		state := previous
		state ~= state >> 12
		state ~= state << 25
		state ~= state >> 27
		observed, exchanged := intrinsics.atomic_compare_exchange_weak_explicit(&random_state, previous, state, .Relaxed, .Relaxed)
		if exchanged {
			return u32((state * 2685821657736338717) >> 33)
		}
		previous = observed
	}
}

random_below :: proc "contextless" (limit: u64) -> u64 {
	if limit <= 1 {
		return 0
	}
	threshold := (max(u64) - limit + 1) % limit
	for {
		value := u64(lp_rand()) << 33 | u64(lp_rand()) << 2 | u64(lp_rand() & 3)
		if value >= threshold {
			return value % limit
		}
	}
}

Pick :: struct {
	tuple: u64,
	slot:  int,
}

Tuple_Walk :: struct {
	pack:  [^]u8,
	at:    [^]u8,
	width: u64,
	index: u64,
}

tuple_walk :: proc(pack: [^]u8, width: int) -> Tuple_Walk {
	return {pack = pack, at = lp_first(pack), width = u64(width)}
}

tuple_skip :: proc(walk: ^Tuple_Walk, tuples: u64) {
	walk.at = seek_steps(walk.pack, walk.at, tuples * walk.width, false)
	walk.index += tuples
}

fill_tuple :: proc(pack: [^]u8, at: [^]u8, width: u64, key: ^Element, val: ^Element) {
	key^ = lp_get_entry(at)
	if val != nil && width > 1 {
		val^ = lp_get_entry(lp_next(pack, at))
	}
}

pick_before :: proc(a, b: Pick) -> bool {
	return a.tuple < b.tuple
}

fill_picks :: proc(pack: [^]u8, picks: []Pick, width: int, keys, vals: []Element) {
	slice.sort_by(picks, pick_before)
	walk := tuple_walk(pack, width)
	for pick in picks {
		tuple_skip(&walk, pick.tuple - walk.index)
		if walk.at == nil {
			return
		}
		val: ^Element = &vals[pick.slot] if len(vals) > 0 else nil
		fill_tuple(pack, walk.at, walk.width, &keys[pick.slot], val)
	}
}

draw_with_repeats :: proc(pack: [^]u8, tuples: u64, slots: int, width: int, keys, vals: []Element) {
	if tuples == 0 || slots <= 0 {
		return
	}
	picks := make([]Pick, slots)
	defer delete(picks)
	for &pick, slot in picks {
		pick = {tuple = random_below(tuples), slot = slot}
	}
	fill_picks(pack, picks, width, keys, vals)
}

lp_random_pair :: proc(lp: [^]u8, total_count: u64, key: ^Element, val: ^Element, stride: int) {
	if key == nil || lp == nil || stride <= 0 || total_count == 0 {
		return
	}
	walk := tuple_walk(lp, stride)
	tuples := min(lp_length(lp) / walk.width, total_count)
	if tuples == 0 {
		return
	}
	tuple_skip(&walk, random_below(tuples))
	if walk.at != nil {
		fill_tuple(lp, walk.at, walk.width, key, val)
	}
}

lp_random_entries :: proc(lp: [^]u8, entries: []Element) {
	if lp != nil {
		draw_with_repeats(lp, lp_length(lp), len(entries), 1, entries, nil)
	}
}

lp_random_pairs :: proc(lp: [^]u8, count: int, keys: []Element, vals: []Element, stride: int) {
	if lp == nil || stride <= 0 || count <= 0 {
		return
	}
	slots := min(count, len(keys), len(vals)) if len(vals) > 0 else min(count, len(keys))
	draw_with_repeats(lp, lp_length(lp) / u64(stride), slots, stride, keys, vals)
}

lp_random_pairs_unique :: proc(lp: [^]u8, count: int, keys: []Element, vals: []Element, stride: int) -> int {
	if lp == nil || stride < 2 || count <= 0 {
		return 0
	}
	walk := tuple_walk(lp, stride)
	tuples := lp_length(lp) / walk.width
	quota := min(u64(count), u64(len(keys)), tuples)
	if len(vals) > 0 {
		quota = min(quota, u64(len(vals)))
	}
	taken := 0
	for walk.at != nil && walk.index < tuples && u64(taken) < quota {
		if random_below(tuples - walk.index) < quota - u64(taken) {
			val: ^Element = &vals[taken] if len(vals) > 0 else nil
			fill_tuple(lp, walk.at, walk.width, &keys[taken], val)
			taken += 1
		}
		tuple_skip(&walk, 1)
	}
	return taken
}

lp_next_random :: proc(lp: [^]u8, p: [^]u8, index: ^u32, remaining: u32, stride: int) -> [^]u8 {
	if index == nil || p == nil || lp == nil || stride <= 0 || remaining == 0 {
		return nil
	}
	entries := lp_length(lp)
	width := u64(stride)
	start := u64(index^)
	boundary := (start + width - 1) / width * width
	if start >= entries || boundary >= entries {
		return nil
	}
	walk := Tuple_Walk{pack = lp, at = seek_steps(lp, p, boundary - start, false), width = width}
	candidates := (entries - boundary + width - 1) / width
	for walk.at != nil && walk.index < candidates {
		left := candidates - walk.index
		if u64(remaining) >= left || random_below(left) < u64(remaining) {
			index^ = u32(boundary + walk.index * width)
			return walk.at
		}
		tuple_skip(&walk, 1)
	}
	return nil
}
