package bitmap_harness

import "core:fmt"
import "core:os"

checks: int
failures: int

check :: proc(cond: bool, format: string, args: ..any, loc := #caller_location) -> bool {
	checks += 1
	if !cond {
		failures += 1
		if failures <= 60 {
			fmt.eprintf("FAIL %s:%d: ", loc.file_path, loc.line)
			fmt.eprintfln(format, ..args)
		}
	}
	return cond
}

usage :: proc() {
	fmt.eprintln("usage: bitmap-test [unit] | gen <dir> | compare <dir> | compare-server <dir> | bench <megabytes> [iterations] | benchdata <megabytes> <file>")
}

main :: proc() {
	args := os.args[1:]
	mode := "unit"
	if len(args) > 0 {
		mode = args[0]
	}
	code := 0
	switch mode {
	case "unit":
		code = run_unit()
	case "gen":
		if len(args) < 2 {
			usage()
			os.exit(2)
		}
		code = run_gen(args[1])
	case "compare":
		if len(args) < 2 {
			usage()
			os.exit(2)
		}
		code = run_compare(args[1])
	case "compare-server":
		if len(args) < 2 {
			usage()
			os.exit(2)
		}
		code = run_compare_server(args[1])
	case "bench":
		if len(args) < 2 {
			usage()
			os.exit(2)
		}
		code = run_bench(args[1:])
	case "benchdata":
		if len(args) < 3 {
			usage()
			os.exit(2)
		}
		code = run_benchdata(args[1], args[2])
	case:
		usage()
		code = 2
	}
	os.exit(code)
}

run_unit :: proc() -> int {
	unit_reference_consistency()
	if failures > 0 {
		fmt.printfln("bitmap unit tests: %d checks, %d FAILED", checks, failures)
		return 1
	}
	fmt.printfln("bitmap unit tests: %d checks, all passed", checks)
	return 0
}
