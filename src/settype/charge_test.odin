package settype

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
	if charge_below(r, 2) == 0 {
		return transmute([]u8)fmt.bprintf(buf, "%d", charge_below(r, 60) - 10)
	}
	widths := [?]int{0, 1, 5, 30, 63, 64, 65, 120}
	n := min(widths[charge_below(r, len(widths))], len(buf) - 1)
	buf[0] = u8('a' + charge_below(r, 4))
	for i in 1 ..< n {
		buf[i] = u8('a' + charge_below(r, 3))
	}
	return buf[:n]
}

@(test)
the_running_charge_of_a_set_equals_its_content :: proc(t: ^testing.T) {
	saved_intset, saved_entries, saved_value, saved_random := set_max_intset_entries, set_max_listpack_entries, set_max_listpack_value, set_random_state
	defer {
		set_max_intset_entries = saved_intset
		set_max_listpack_entries = saved_entries
		set_max_listpack_value = saved_value
		set_random_state = saved_random
		drain_maintenance()
	}
	set_max_intset_entries = 24
	set_max_listpack_entries = 16
	set_max_listpack_value = 48
	r := charge_rng_make("set charge")
	buf: [128]u8
	first := [1]u8{'1'}
	s := create(first[:], 1)
	seen: [Encoding]bool
	popped: Popped
	defer popped_destroy(&popped)
	for step in 0 ..< 9000 {
		seen[s.encoding] = true
		switch charge_below(&r, 11) {
		case 0, 1, 2, 3:
			add(s, charge_member(&r, buf[:]))
		case 4, 5:
			remove(s, charge_member(&r, buf[:]))
		case 6:
			if size(s) > 0 {
				popped_reset(&popped)
				pop_random(s, &popped)
			}
		case 7:
			if size(s) > 2 && charge_below(&r, 10) == 0 {
				popped_reset(&popped)
				fresh := spop_count(s, 1 + charge_below(&r, size(s) - 1), &popped)
				if fresh != nil {
					destroy(s)
					s = fresh
				}
			}
		case 8:
			if charge_below(&r, 30) == 0 {
				d := dup(s)
				testing.expect_value(t, charge(d), content_memory(d))
				destroy(d)
			}
		case 9:
			if s.encoding != .Hashtable && charge_below(&r, 20) == 0 {
				convert(s, .Hashtable)
			}
		case 10:
			if charge_below(&r, 400) == 0 {
				destroy(s)
				s = create(first[:], 1)
			}
		}
		seen[s.encoding] = true
		if !testing.expect_value(t, charge(s), content_memory(s)) {
			fmt.printfln("set charge differs at step %d, encoding %s", step, encoding_name(s))
			break
		}
	}
	destroy(s)
	testing.expect(t, seen[.Intset] && seen[.Listpack] && seen[.Hashtable], "the workload visits every encoding")
}
