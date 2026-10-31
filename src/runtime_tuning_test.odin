package main

import "core:testing"

@(test)
runtime_cpu_list_grammar :: proc(t: ^testing.T) {
	mask, valid := runtime_tuning_cpu_list("1-9:2,3,64,8191")
	testing.expect(t, valid)
	for cpu in 0..<RUNTIME_CPU_LIMIT {
		expected := cpu == 1 || cpu == 3 || cpu == 5 || cpu == 7 || cpu == 9 || cpu == 64 || cpu == 8191
		testing.expect(t, runtime_tuning_cpu_contains(&mask, cpu) == expected)
	}
	invalid_inputs := []string{"bad", "0-", "0,,1", "0-1:0", "8192", "0:2", "-1", "4-2", "1,", " 1", "999999999999999999999999999999"}
	for text in invalid_inputs {
		invalid, ok := runtime_tuning_cpu_list(text)
		testing.expect(t, !ok)
		for word in invalid { testing.expect(t, word == 0) }
	}
	empty, ok := runtime_tuning_cpu_list("")
	testing.expect(t, ok)
	for word in empty { testing.expect(t, word == 0) }
}

@(test)
runtime_cpu_affinity_changes_only_current_owned_thread :: proc(t: ^testing.T) {
	original, err := runtime_tuning_allowed()
	testing.expect(t, err == .NONE)
	if err != .NONE { return }
	defer testing.expect(t, runtime_tuning_apply(&original) == .NONE)
	chosen := -1
	for cpu in 0..<RUNTIME_CPU_LIMIT {
		if runtime_tuning_cpu_contains(&original, cpu) { chosen = cpu; break }
	}
	testing.expect(t, chosen >= 0)
	if chosen < 0 { return }
	single: Runtime_CPU_Mask
	single[chosen / 64] = u64(1) << uint(chosen % 64)
	testing.expect(t, runtime_tuning_apply(&single) == .NONE)
	actual, actual_err := runtime_tuning_allowed()
	testing.expect(t, actual_err == .NONE && actual == single)
	empty: Runtime_CPU_Mask
	testing.expect(t, runtime_tuning_apply(&empty) != .NONE)
	after, after_err := runtime_tuning_allowed()
	testing.expect(t, after_err == .NONE && after == single)
}
