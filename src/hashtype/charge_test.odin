package hashtype

import "core:fmt"
import "core:testing"
import "core:time"

CHARGE_SEED :: #config(CHARGE_SEED, 0)

@(private = "file")
Charge_Rng :: struct {
	state: u64,
}

@(private = "file")
charge_rng_make :: proc(name: string) -> Charge_Rng {
	seed := u64(CHARGE_SEED)
	if seed == 0 {
		seed = u64(time.now()._nsec) | 1
	}
	fmt.printfln("%s seed %d (rerun with -define:CHARGE_SEED=%d)", name, seed, seed)
	return Charge_Rng{seed}
}

@(private = "file")
charge_below :: proc(r: ^Charge_Rng, n: int) -> int {
	r.state ~= r.state << 13
	r.state ~= r.state >> 7
	r.state ~= r.state << 17
	return int(r.state % u64(n))
}

@(private = "file")
charge_text :: proc(r: ^Charge_Rng, buf: []u8) -> []u8 {
	widths := [?]int{0, 1, 7, 20, 63, 64, 65, 200}
	n := min(widths[charge_below(r, len(widths))], len(buf))
	for i in 0 ..< n {
		buf[i] = u8('a' + charge_below(r, 26))
	}
	return buf[:n]
}

@(test)
the_running_charge_of_a_hash_equals_its_content :: proc(t: ^testing.T) {
	saved_entries, saved_value := hash_max_listpack_entries, hash_max_listpack_value
	defer {
		hash_max_listpack_entries = saved_entries
		hash_max_listpack_value = saved_value
	}
	hash_max_listpack_entries = 16
	hash_max_listpack_value = 48
	r := charge_rng_make("hash charge")
	h := create()
	defer destroy(h)
	fbuf, vbuf: [256]u8
	names: [40][8]u8
	for i in 0 ..< len(names) {
		fmt.bprintf(names[i][:], "f%05d", i)
	}
	now := u64(1000)
	saw_table, saw_resize, saw_vol := false, false, false
	for step in 0 ..< 6000 {
		field := names[charge_below(&r, len(names))][:6]
		if charge_below(&r, 5) == 0 {
			field = charge_text(&r, fbuf[:])
		}
		switch charge_below(&r, 10) {
		case 0, 1, 2:
			args := [2][]u8{field, charge_text(&r, vbuf[:])}
			hset(h, args[:])
		case 3:
			delete_field(h, field)
		case 4:
			if h.encoding == .Listpack {
				convert_to_ex(h)
			} else if h.encoding == .Hashtable {
				ensure_meta(h)
			}
			tally := expire_tally()
			retime_field(h, field, now + u64(1 + charge_below(&r, 50)), .None, now, &tally)
		case 5:
			out: [dynamic]i64
			fields := [1][]u8{field}
			persist_fields(h, fields[:], now, &out)
			delete(out)
		case 6:
			now += u64(charge_below(&r, 20))
			expire_if_needed(h, now)
		case 7:
			if charge_below(&r, 40) == 0 {
				d, _ := duplicate(h)
				testing.expect_value(t, charge(d), content_memory(d))
				destroy(d)
			}
		case 8:
			if charge_below(&r, 60) == 0 {
				reset(h)
			}
		case 9:
			if h.encoding != .Hashtable && charge_below(&r, 30) == 0 {
				convert(h)
			}
		}
		if h.encoding == .Hashtable {
			saw_table = true
			saw_resize ||= h.table.resize != nil
			saw_vol ||= h.table.vol_len > 0
		}
		if !testing.expect_value(t, charge(h), content_memory(h)) {
			fmt.printfln("hash charge differs at step %d, encoding %s", step, encoding_name(h))
			return
		}
	}
	testing.expect(t, saw_table && saw_resize && saw_vol, "the workload reaches a table that resizes and holds field deadlines")
}
