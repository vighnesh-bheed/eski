package sysclock

import "core:c"
import "core:sys/linux"

foreign import libc_clock "system:c"

@(default_calling_convention = "c")
foreign libc_clock {
	clock_gettime :: proc(clock: c.int, ts: ^linux.Time_Spec) -> c.int ---
}

read :: proc "contextless" (clock: linux.Clock_Id) -> (ts: linux.Time_Spec, err: linux.Errno) {
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
