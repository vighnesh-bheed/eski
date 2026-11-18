package sysclock

import "core:c"
import "core:sys/linux"

SIMULATION :: #config(ESKI_SIMULATION, false)

when SIMULATION {
	simulation_ns: i64

	simulation_set :: proc "contextless" (elapsed_ns: i64) {
		simulation_ns = elapsed_ns
	}
}

foreign import libc_clock "system:c"

@(default_calling_convention = "c")
foreign libc_clock {
	clock_gettime :: proc(clock: c.int, ts: ^linux.Time_Spec) -> c.int ---
}

read :: proc "contextless" (clock: linux.Clock_Id) -> (ts: linux.Time_Spec, err: linux.Errno) {
	when SIMULATION {
		#partial switch clock {
		case .REALTIME:
			ts.time_sec = uint(1_700_000_000 + simulation_ns / 1_000_000_000)
		case .MONOTONIC:
			ts.time_sec = uint(simulation_ns / 1_000_000_000)
		case:
			return {}, .EINVAL
		}
		ts.time_nsec = uint(simulation_ns % 1_000_000_000)
		return ts, .NONE
	}
	if clock_gettime(c.int(clock), &ts) == 0 {
		return ts, .NONE
	}
	return linux.clock_gettime(clock)
}

realtime :: #force_inline proc "contextless" () -> (ts: linux.Time_Spec, err: linux.Errno) {
	return read(.REALTIME)
}

monotonic :: #force_inline proc "contextless" () -> (ts: linux.Time_Spec, err: linux.Errno) {
	return read(.MONOTONIC)
}
