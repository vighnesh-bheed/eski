package listtype

import lp "../listpack"
import "core:fmt"
import "core:sync"
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
charge_value :: proc(r: ^Charge_Rng, buf: []u8) -> []u8 {
	if charge_below(r, 3) == 0 {
		return transmute([]u8)fmt.bprintf(buf, "%d", charge_below(r, 100000))
	}
	widths := [?]int{0, 1, 10, 60, 200, 700, 1500}
	n := min(widths[charge_below(r, len(widths))], len(buf))
	for i in 0 ..< n {
		buf[i] = u8('a' + charge_below(r, 3))
	}
	return buf[:n]
}

@(test)
the_running_charge_of_a_list_equals_its_content :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	saved_fill, saved_threshold := list_max_listpack_size, plain_node_threshold
	defer {
		list_max_listpack_size = saved_fill
		plain_node_threshold = saved_threshold
	}
	r := charge_rng_make("list charge")
	buf, pivot: [1600]u8
	seen: [Encoding]bool
	saw_plain := false
	for fill in ([?]int{3, -1, -2}) {
		list_max_listpack_size = fill
		plain_node_threshold = 1000
		l := create()
		for step in 0 ..< 4000 {
			seen[l.encoding] = true
			switch charge_below(&r, 12) {
			case 0, 1, 2, 3:
				v := charge_value(&r, buf[:])
				values := [1][]u8{v}
				widen_for_values(l, values[:])
				push(l, v, .Head if charge_below(&r, 2) == 0 else .Tail)
			case 4, 5:
				if length(l) > 0 {
					pop_discard(l, .Head if charge_below(&r, 2) == 0 else .Tail)
					narrow_if_possible(l)
				}
			case 6:
				if length(l) > 0 {
					p, ok := index(l, charge_below(&r, length(l)))
					if ok {
						digits: [lp.DECIMAL_BUFFER_BYTES]u8
						pv := value_bytes(p, &digits)
						n := copy(pivot[:], pv)
						linsert(l, charge_below(&r, 2) == 0, pivot[:n], charge_value(&r, buf[:]))
					}
				}
			case 7:
				if length(l) > 0 {
					lset(l, charge_below(&r, length(l)), charge_value(&r, buf[:]))
				}
			case 8:
				lrem(l, charge_below(&r, 5) - 2, charge_value(&r, buf[:]))
				narrow_if_possible(l)
			case 9:
				if charge_below(&r, 10) == 0 {
					ltrim(l, charge_below(&r, 3), charge_below(&r, 40))
					narrow_if_possible(l)
				}
			case 10:
				if length(l) > 2 && charge_below(&r, 6) == 0 {
					delete_range(l, charge_below(&r, length(l) - 1), 1 + charge_below(&r, 3))
					narrow_if_possible(l)
				}
			case 11:
				if charge_below(&r, 40) == 0 {
					d := dup(l)
					testing.expect_value(t, charge(d), content_memory(d))
					destroy(d)
				}
			}
			seen[l.encoding] = true
			if l.encoding == .Quicklist {
				for x := l.ql.head; x != nil; x = x.next {
					saw_plain ||= x.plain
				}
			}
			if !testing.expect_value(t, charge(l), content_memory(l)) {
				fmt.printfln("list charge differs at step %d, fill %d, encoding %s", step, fill, encoding_name(l))
				break
			}
		}
		destroy(l)
	}
	testing.expect(t, seen[.Listpack] && seen[.Quicklist] && saw_plain, "the workload visits both encodings and plain nodes")
}
