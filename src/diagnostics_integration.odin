package main

import "base:intrinsics"
import "base:runtime"

diagnostic_dispatch_depth: int

diagnostics_worker_failure :: proc "contextless" () -> runtime.Assertion_Failure_Proc {
	if intrinsics.atomic_load_explicit(&diagnostic_initialized, .Acquire) != 0 {
		return diagnostics_assertion_failure
	}
	return nil
}

diagnostics_command_begin :: proc(name: string, arguments: [][]u8) {
	if diagnostic_dispatch_depth == 0 { diagnostics_capture_command(name, arguments) }
	diagnostic_dispatch_depth += 1
}

diagnostics_command_end :: proc() {
	diagnostic_dispatch_depth -= 1
	if diagnostic_dispatch_depth == 0 { diagnostics_capture_command("", nil) }
}
