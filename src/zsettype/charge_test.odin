package zsettype

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
charge_member :: proc(r: ^Charge_Rng, buf: []u8) -> []u8 {
	widths := [?]int{1, 2, 9, 40, 63, 64, 65, 150}
	n := min(widths[charge_below(r, len(widths))], len(buf))
	buf[0] = u8('a' + charge_below(r, 6))
	for i in 1 ..< n {
		buf[i] = u8('a' + charge_below(r, 2))
	}
	return buf[:n]
}

@(test)
the_running_charge_of_a_sorted_set_equals_its_content :: proc(t: ^testing.T) {
	saved_entries, saved_value, saved_rng := zset_max_listpack_entries, zset_max_listpack_value, sl_rng
	defer {
		zset_max_listpack_entries = saved_entries
		zset_max_listpack_value = saved_value
		sl_rng = saved_rng
	}
	zset_max_listpack_entries = 16
	zset_max_listpack_value = 48
	r := charge_rng_make("sorted set charge")
	buf: [160]u8
	z := create_listpack()
	seen: [Encoding]bool
	for step in 0 ..< 9000 {
		seen[z.encoding] = true
		switch charge_below(&r, 12) {
		case 0, 1, 2, 3:
			add(z, f64(charge_below(&r, 100)), charge_member(&r, buf[:]), {})
		case 4:
			add(z, f64(charge_below(&r, 5)), charge_member(&r, buf[:]), {.Incr})
		case 5, 6:
			del(z, charge_member(&r, buf[:]))
		case 7:
			if charge_below(&r, 8) == 0 {
				remrange_by_rank(z, i64(charge_below(&r, 4)), i64(charge_below(&r, 8)))
			}
		case 8:
			if charge_below(&r, 8) == 0 {
				lo := f64(charge_below(&r, 100))
				spec := Range_Spec{min = lo, max = lo + 3}
				remrange_by_score(z, &spec)
			}
		case 9:
			pop(z, charge_below(&r, 2) == 0)
		case 10:
			if charge_below(&r, 30) == 0 {
				d := dup(z)
				testing.expect_value(t, charge(d), content_memory(d))
				destroy(d)
			}
		case 11:
			if charge_below(&r, 200) == 0 {
				destroy(z)
				z = create_listpack()
			} else if z.encoding == .Skiplist && length(z) <= zset_max_listpack_entries && charge_below(&r, 4) == 0 {
				convert_to_listpack(z)
			} else if z.encoding == .Listpack && charge_below(&r, 30) == 0 {
				convert_to_skiplist(z, length(z))
			}
		}
		seen[z.encoding] = true
		if !testing.expect_value(t, charge(z), content_memory(z)) {
			fmt.printfln("sorted set charge differs at step %d, encoding %s", step, encoding_name(z))
			break
		}
	}
	destroy(z)
	testing.expect(t, seen[.Listpack] && seen[.Skiplist], "the workload visits both encodings")
}
