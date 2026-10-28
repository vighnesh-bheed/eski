package listtype_harness

import "core:fmt"
import "core:os"

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

usage :: proc() {
	fmt.eprintln("usage: listtype-test [unit] | gen <dir> | compare <dir> | compare-server <dir>")
}

main :: proc() {
	args := os.args[1:]
	mode := "unit" if len(args) == 0 else args[0]
	ok := false
	switch mode {
	case "unit":
		ok = run_unit()
	case "gen":
		if len(args) < 2 {
			usage()
			os.exit(2)
		}
		ok = run_gen(args[1])
	case "compare":
		if len(args) < 2 {
			usage()
			os.exit(2)
		}
		ok = run_compare(args[1])
	case "compare-server":
		if len(args) < 2 {
			usage()
			os.exit(2)
		}
		ok = run_compare(args[1], true)
	case:
		usage()
		os.exit(2)
	}
	os.exit(0 if ok else 1)
}
