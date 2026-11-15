package streamtype

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
charge_name :: proc(r: ^Charge_Rng, buf: []u8, kinds: int) -> []u8 {
	n := 1 + charge_below(r, 3) * 7
	k := charge_below(r, kinds)
	for i in 0 ..< n {
		buf[i] = u8('a' + k)
	}
	return buf[:n]
}

@(test)
the_running_charge_of_a_stream_equals_its_content :: proc(t: ^testing.T) {
	saved_bytes, saved_entries, saved_room := stream_node_max_bytes, stream_node_max_entries, charge_room
	defer {
		stream_node_max_bytes = saved_bytes
		stream_node_max_entries = saved_entries
		charge_room = saved_room
	}
	r := charge_rng_make("stream charge")
	value, gname, cname: [300]u8
	ids: [dynamic]ID
	defer delete(ids)
	node_bytes := [5]int{4096, 300, 0, 120, 0}
	node_entries := [5]i64{100, 5, 0, 3, 1000}
	widths := [4]int{1, 9, 60, 250}
	saw_wide_count := false
	for round in 0 ..< 5 {
		stream_node_max_bytes = node_bytes[round]
		stream_node_max_entries = node_entries[round]
		set_charge_room(true)
		s := create()
		clear(&ids)
		now := u64(1000)
		saw_groups := false
		for step in 0 ..< 3000 {
			switch charge_below(&r, 14) {
			case 0, 1, 2, 3:
				n := widths[charge_below(&r, 4)]
				for i in 0 ..< n {
					value[i] = u8('a' + charge_below(&r, 26))
				}
				fv: [4][]u8
				fv[0] = transmute([]u8)string("field")
				fv[1] = value[:n]
				fv[2] = transmute([]u8)string("other") if charge_below(&r, 3) == 0 else transmute([]u8)string("f2")
				fv[3] = value[:charge_below(&r, n + 1)]
				now += u64(charge_below(&r, 3))
				pairs := 2 if charge_below(&r, 2) == 0 else 4
				id, res := append_entry(s, fv[:pairs], .Generated, {}, now)
				if res == .Ok {
					append(&ids, id)
				}
			case 4:
				if len(ids) > 0 {
					delete_item(s, ids[charge_below(&r, len(ids))])
				}
			case 5:
				if round < 4 && charge_below(&r, 6) == 0 {
					spec := Trim_Spec{rule = .Max_Len, max_len = i64(charge_below(&r, 30)), nearly = charge_below(&r, 2) == 0}
					trim(s, &spec)
				}
			case 6:
				add_group(s, charge_name(&r, gname[:], 3), ID_MIN, 0)
			case 7:
				if charge_below(&r, 10) == 0 {
					drop_group(s, charge_name(&r, gname[:], 3))
				}
			case 8, 9:
				if g := find_group(s, charge_name(&r, gname[:], 3)); g != nil && len(ids) > 0 {
					m, _ := member_for(s, g, charge_name(&r, cname[:], 4), i64(now))
					for _ in 0 ..< 1 + charge_below(&r, 3) {
						group_deliver(s, g, m, ids[charge_below(&r, len(ids))], charge_below(&r, 8) == 0, i64(now))
					}
				}
			case 10:
				if g := find_group(s, charge_name(&r, gname[:], 3)); g != nil && len(ids) > 0 {
					ack(s, g, ids[charge_below(&r, len(ids))])
				}
			case 11:
				if g := find_group(s, charge_name(&r, gname[:], 3)); g != nil && len(ids) > 0 {
					m, _ := member_for(s, g, charge_name(&r, cname[:], 4), i64(now))
					opts := Claim_Options{flags = {.Force} if charge_below(&r, 2) == 0 else {}}
					claim_entry(s, g, m, ids[charge_below(&r, len(ids))], &opts, i64(now))
				}
			case 12:
				if g := find_group(s, charge_name(&r, gname[:], 3)); g != nil {
					if m := find_member(g, charge_name(&r, cname[:], 4)); m != nil {
						drop_member(s, g, m)
					}
				}
			case 13:
				if charge_below(&r, 40) == 0 {
					d := dup(s)
					testing.expect_value(t, charge(d), content_memory(d))
					destroy(d)
				}
			}
			saw_groups ||= s.groups != nil && s.groups.stored > 0
			if t, found := find_tail(s); found {
				saw_wide_count ||= node_header(t.node).count > 127
			}
			if !testing.expect_value(t, charge(s), content_memory(s)) {
				fmt.printfln("stream charge differs at step %d of round %d", step, round)
				break
			}
		}
		testing.expect(t, saw_groups, "the workload creates consumer groups")
		destroy(s)
	}
	testing.expect(t, saw_wide_count, "a node's entry count grows past one byte")
}
