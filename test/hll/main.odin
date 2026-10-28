package hll_harness

import "core:fmt"
import "core:os"

usage :: proc() {
	fmt.eprintln("usage: hll-test [unit | selftest | gen <dir> | compare <dir>]")
}

main :: proc() {
	args := os.args
	mode := "unit" if len(args) < 2 else args[1]
	ok := false
	switch mode {
	case "unit":
		ok = run_unit()
	case "selftest":
		ok = run_selftest_only()
	case "gen":
		if len(args) < 3 {
			usage()
			os.exit(2)
		}
		ok = run_gen(args[2])
	case "compare":
		if len(args) < 3 {
			usage()
			os.exit(2)
		}
		ok = run_compare(args[2])
	case:
		usage()
		os.exit(2)
	}
	os.exit(0 if ok else 1)
}
