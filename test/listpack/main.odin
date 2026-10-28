package main

import lp "../../src/listpack"
import "core:fmt"
import "core:os"
import "core:time"

checks: int
failures: int

check :: proc(cond: bool, what: string, loc := #caller_location) -> bool {
	checks += 1
	if !cond {
		failures += 1
		if failures <= 50 {
			fmt.eprintfln("FAIL %s (%s:%d)", what, loc.file_path, loc.line)
		}
	}
	return cond
}

b :: #force_inline proc(s: string) -> []u8 {
	return transmute([]u8)s
}

section :: proc(name: string, start: time.Tick, before: int) {
	fmt.printfln("  %-44s %-7d checks  %.1f ms", name, checks - before, time.duration_milliseconds(time.tick_since(start)))
}

main :: proc() {
	accurate := false
	for a in os.args[1:] {
		switch a {
		case "accurate", "--accurate":
			accurate = true
		case "unit":
		case:
			fmt.eprintln("usage: listpack-test [unit] [accurate]")
			os.exit(2)
		}
	}
	lp.lp_srand(0xC0FFEE)
	fmt.printfln("listpack-test (%s)", "accurate" if accurate else "default")
	t := time.tick_now()
	n := checks
	run_redis_table()
	section("Redis 7.4 byte table (DUMP captured)", t, n)
	t = time.tick_now()
	n = checks
	run_model_stress(accurate)
	section("random ops vs reference encoder", t, n)
	t = time.tick_now()
	n = checks
	run_corruption_fuzz(accurate)
	section("lpValidateIntegrity corruption fuzz", t, n)
	fmt.printfln("listpack-test: %d checks, %d failures", checks, failures)
	os.exit(0 if failures == 0 else 1)
}
