package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Stat :: struct {
	total:    int,
	mismatch: int,
}

label_of :: proc(args: [][]u8) -> string {
	return strings.to_upper(string(args[0]), context.temp_allocator)
}

short :: proc(b: []u8, n := 300) -> string {
	s := fmt.tprintf("%q", string(b[:min(len(b), n)]))
	if len(b) > n {
		return fmt.tprintf("%s...(%d bytes)", s, len(b))
	}
	return s
}

run_compare :: proc(dir: string) -> bool {
	script, serr := os.read_entire_file(fmt.tprintf("%s/script.resp", dir), context.allocator)
	if serr != nil {
		fmt.eprintln("cannot read script.resp")
		return false
	}
	redis, rerr := os.read_entire_file(fmt.tprintf("%s/redis.out", dir), context.allocator)
	if rerr != nil {
		fmt.eprintln("cannot read redis.out")
		return false
	}
	eski, jerr := os.read_entire_file(fmt.tprintf("%s/eski.out", dir), context.allocator)
	if jerr != nil {
		fmt.eprintln("cannot read eski.out")
		return false
	}
	cmds, ok := parse_commands(script)
	if !ok {
		fmt.eprintln("malformed script")
		return false
	}
	stats := make(map[string]Stat)
	defer delete(stats)
	rpos, jpos := 0, 0
	mismatches, shown := 0, 0
	for args, idx in cmds {
		rr, rnext, rok := parse_reply(redis, rpos, context.temp_allocator)
		jr, jnext, jok := parse_reply(eski, jpos, context.temp_allocator)
		if !rok || !jok {
			fmt.eprintfln("cannot parse reply %d", idx)
			return false
		}
		rpos, jpos = rnext, jnext
		label := label_of(args)
		if label == "HELLO" {
			label = "HELLO (ignored)"
		}
		st := stats[label]
		st.total += 1
		same := string(rr.raw) == string(jr.raw) || label == "HELLO (ignored)"
		if !same {
			st.mismatch += 1
			mismatches += 1
			if shown < 25 {
				shown += 1
				parts := make([dynamic]string, context.temp_allocator)
				for a in args {
					append(&parts, short(a, 40))
				}
				fmt.eprintfln("MISMATCH #%d %s", idx, strings.join(parts[:], " ", context.temp_allocator))
				fmt.eprintfln("  redis: %s", short(rr.raw))
				fmt.eprintfln("  eski: %s", short(jr.raw))
			}
		}
		if label not_in stats {
			stats[strings.clone(label)] = st
		} else {
			stats[label] = st
		}
		free_all(context.temp_allocator)
	}
	if rpos != len(redis) || jpos != len(eski) {
		fmt.eprintln("trailing reply bytes")
		mismatches += 1
	}
	labels := make([dynamic]string)
	defer delete(labels)
	for k in stats {
		append(&labels, k)
	}
	slice.sort(labels[:])
	fmt.println("eski replies checked against redis")
	fmt.println("command                  count   mismatches")
	total := 0
	for l in labels {
		st := stats[l]
		total += st.total
		fmt.printfln("%-24s %-7d %d", l, st.total, st.mismatch)
	}
	fmt.printfln("%-24s %-7d %d", "TOTAL", total, mismatches)
	for k in stats {
		delete(k)
	}
	delete(cmds)
	delete(script)
	delete(redis)
	delete(eski)
	return mismatches == 0
}
