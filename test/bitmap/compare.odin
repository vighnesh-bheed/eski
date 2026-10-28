package bitmap_harness

import "core:fmt"
import "core:os"
import "core:strings"

Case_Result :: struct {
	name:       string,
	commands:   int,
	mismatches: int,
	errors:     int,
}

run_compare :: proc(dir: string) -> int {
	return run_compare_mode(dir, false)
}

run_compare_server :: proc(dir: string) -> int {
	return run_compare_mode(dir, true)
}

run_compare_mode :: proc(dir: string, server: bool) -> int {
	list_path := path_in(dir, "cases.txt")
	list, lerr := os.read_entire_file(list_path, context.allocator)
	if lerr != nil {
		fmt.eprintfln("cannot read %s: %v", list_path, lerr)
		return 1
	}
	defer delete(list)
	results := make([dynamic]Case_Result)
	defer delete(results)
	failed := false
	iter := string(list)
	for line in strings.split_lines_iterator(&iter) {
		name := strings.trim_space(line)
		if len(name) == 0 {
			continue
		}
		res: Case_Result
		ok: bool
		if server {
			res, ok = compare_server_case(dir, name)
		} else {
			res, ok = compare_case(dir, name)
		}
		if !ok {
			failed = true
		}
		append(&results, res)
		free_all(context.temp_allocator)
	}
	fmt.println()
	fmt.printfln("%-16s %10s %12s %12s", "case", "commands", "errors", "mismatches")
	total, total_err, total_bad := 0, 0, 0
	for r in results {
		fmt.printfln("%-16s %10s %12s %12s", r.name, num(r.commands), num(r.errors), num(r.mismatches))
		total += r.commands
		total_err += r.errors
		total_bad += r.mismatches
	}
	fmt.printfln("%-16s %10s %12s %12s", "total", num(total), num(total_err), num(total_bad))
	if failed || total_bad > 0 {
		fmt.println("bitmap compare FAILED")
		return 1
	}
	if server {
		fmt.println("bitmap compare: every eski server reply is identical to Redis")
	} else {
		fmt.println("bitmap compare: every package reply is identical to Redis")
	}
	return 0
}

num :: proc(v: int) -> string {
	return fmt.tprintf("%d", v)
}

path_in :: proc(dir: string, name: string) -> string {
	return fmt.tprintf("%s/%s", dir, name)
}

compare_case :: proc(dir: string, name: string) -> (res: Case_Result, ok: bool) {
	res.name = name
	script_path := path_in(dir, fmt.tprintf("%s.script", name))
	redis_path := path_in(dir, fmt.tprintf("%s.redis", name))
	script, serr := os.read_entire_file(script_path, context.allocator)
	if serr != nil {
		fmt.eprintfln("cannot read %s: %v", script_path, serr)
		return res, false
	}
	defer delete(script)
	expected, rerr := os.read_entire_file(redis_path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("cannot read %s: %v", redis_path, rerr)
		return res, false
	}
	defer delete(expected)
	cmds, pok := parse_commands(script)
	defer {
		for c in cmds {
			delete(c)
		}
		delete(cmds)
	}
	if !pok {
		fmt.eprintfln("%s: malformed script", name)
		return res, false
	}
	e := emu_make()
	defer emu_destroy(&e)
	pos := 0
	shown := 0
	ok = true
	for argv, i in cmds {
		got := emu_exec(&e, argv)
		end, eok := reply_end(expected, pos)
		if !eok {
			fmt.eprintfln("%s: Redis reply stream ended early at command %d", name, i)
			res.commands = i
			return res, false
		}
		want := expected[pos:end]
		pos = end
		res.commands += 1
		if len(want) > 0 && want[0] == '-' {
			res.errors += 1
		}
		if string(got) != string(want) {
			res.mismatches += 1
			if shown < 12 {
				shown += 1
				fmt.printfln("MISMATCH %s #%d: %s", name, i, render_command(argv))
				fmt.printfln("  redis: %s", escape_bytes(want, 160))
				fmt.printfln("  eski: %s", escape_bytes(got, 160))
			}
		}
		if i % 1000 == 0 {
			free_all(context.temp_allocator)
		}
	}
	if pos != len(expected) {
		fmt.eprintfln("%s: %d unread bytes in the Redis reply stream", name, len(expected) - pos)
		ok = false
	}
	fmt.printfln("compared %-14s %7s commands, %d mismatches", name, num(res.commands), res.mismatches)
	return res, ok && res.mismatches == 0
}

compare_server_case :: proc(dir: string, name: string) -> (res: Case_Result, ok: bool) {
	res.name = name
	script_path := path_in(dir, fmt.tprintf("%s.srv.script", name))
	redis_path := path_in(dir, fmt.tprintf("%s.srv.redis", name))
	eski_path := path_in(dir, fmt.tprintf("%s.srv.eski", name))
	script, serr := os.read_entire_file(script_path, context.allocator)
	if serr != nil {
		fmt.eprintfln("cannot read %s: %v", script_path, serr)
		return res, false
	}
	defer delete(script)
	expected, rerr := os.read_entire_file(redis_path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("cannot read %s: %v", redis_path, rerr)
		return res, false
	}
	defer delete(expected)
	actual, jerr := os.read_entire_file(eski_path, context.allocator)
	if jerr != nil {
		fmt.eprintfln("cannot read %s: %v", eski_path, jerr)
		return res, false
	}
	defer delete(actual)
	cmds, pok := parse_commands(script)
	defer {
		for c in cmds {
			delete(c)
		}
		delete(cmds)
	}
	if !pok {
		fmt.eprintfln("%s: malformed script", name)
		return res, false
	}
	epos, apos, shown := 0, 0, 0
	ok = true
	for argv, i in cmds {
		eend, eok := reply_end(expected, epos)
		aend, aok := reply_end(actual, apos)
		if !eok || !aok {
			fmt.eprintfln("%s: reply stream ended early at command %d (redis %v, eski %v)", name, i, eok, aok)
			return res, false
		}
		want := expected[epos:eend]
		got := actual[apos:aend]
		epos = eend
		apos = aend
		res.commands += 1
		if len(want) > 0 && want[0] == '-' {
			res.errors += 1
		}
		if string(got) != string(want) {
			res.mismatches += 1
			if shown < 12 {
				shown += 1
				fmt.printfln("MISMATCH %s #%d: %s", name, i, render_command(argv))
				fmt.printfln("  redis: %s", escape_bytes(want, 160))
				fmt.printfln("  eski: %s", escape_bytes(got, 160))
			}
		}
		if i % 1000 == 0 {
			free_all(context.temp_allocator)
		}
	}
	if epos != len(expected) || apos != len(actual) {
		fmt.eprintfln("%s: unread reply bytes (redis %d, eski %d)", name, len(expected) - epos, len(actual) - apos)
		ok = false
	}
	fmt.printfln("server   %-14s %7s commands, %d mismatches", name, num(res.commands), res.mismatches)
	return res, ok && res.mismatches == 0
}
