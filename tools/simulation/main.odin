package simulation

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/linux"
import engine "../../src"

#assert(engine.SIMULATION)

case_name: string
case_seed: u64
event_number: int

trace :: proc(format: string, args: ..any) {
	event_number += 1
	fmt.printf("%06d ", event_number)
	fmt.printfln(format, ..args)
}

require :: proc(ok: bool, property: string, location := #caller_location) {
	if !ok {
		trace("FAIL case=%s seed=%d property=%s line=%d", case_name, case_seed, property, location.line)
		linux.exit_group(1)
	}
}

main :: proc() {
	if len(os.args) != 5 {
		fmt.eprintln("usage: eski-simulation CASE SEED STEPS VARIANT")
		linux.exit_group(2)
	}
	case_name = os.args[1]
	seed, parsed := strconv.parse_u64(os.args[2], 10)
	steps, sized := strconv.parse_int(os.args[3], 10)
	variant := os.args[4]
	if !parsed || !sized || steps < 1 || steps > 4096 || (variant != "base" && variant != "hidden") {
		fmt.eprintln("invalid seed, steps (1..4096) or variant (base, hidden)")
		linux.exit_group(2)
	}
	case_seed = seed
	trace("case=%s seed=%d steps=%d variant=%s", case_name, seed, steps, variant)
	switch case_name {
	case "network":
		run_network(seed, steps)
	case "disk":
		run_disk(seed)
	case "restart":
		run_restart(seed)
	case "labels":
		run_visibility(seed, steps, false, variant == "hidden")
	case "owners":
		run_visibility(seed, steps, true, variant == "hidden")
	case:
		require(false, "known case")
	}
	trace("PASS case=%s seed=%d", case_name, seed)
}
