package ftquery

import "core:testing"

@(test)
probe_cases_reproduce :: proc(t: ^testing.T) {
	reproduced := 0
	for c in PROBE_CASES {
		got, is_error, ok := run_case(c)
		defer delete(got)
		if !ok {
			testing.expectf(t, false, "probe %d: no schema for index %s", c.id, c.index)
			continue
		}
		if is_error == c.error && got == c.expect {
			reproduced += 1
			continue
		}
		testing.expectf(t, false, "probe %d %q dialect %d verbatim %v: got %q want %q", c.id, c.query, c.dialect, c.verbatim, got, c.expect)
	}
	testing.expect_value(t, reproduced, len(PROBE_CASES))
	testing.expect_value(t, len(PROBE_CASES), 7383)
	testing.expect_value(t, PROBE_IMAGE_DIGEST, "sha256:f245f4c83b84a9e9a0588da1c9456e579455310f0945d5db52cd2ba27f2000cc")
}
