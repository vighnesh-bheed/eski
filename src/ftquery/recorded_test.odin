package ftquery

import "core:testing"

@(test)
recorded_cases_reproduce :: proc(t: ^testing.T) {
	reproduced := 0
	for c in RECORDED_CASES {
		got, is_error, ok := run_case(c)
		defer delete(got)
		if !ok {
			testing.expectf(t, false, "case %d: no schema for index %s", c.id, c.index)
			continue
		}
		if is_error == c.error && got == c.expect {
			reproduced += 1
			continue
		}
		testing.expectf(t, false, "case %d %q dialect %d: got %q want %q", c.id, c.query, c.dialect, got, c.expect)
	}
	testing.expect_value(t, reproduced, len(RECORDED_CASES))
	testing.expect_value(t, len(RECORDED_CASES), 252)
}
