package geospatial

import "core:fmt"
import "core:os"
import "core:testing"

report_mismatch :: proc(t: ^testing.T, index: int, line: string, got, want: string) {
	if t == nil {
		fmt.eprintf("command %d %s\n got  %q\n want %q\n", index, line, got, want)
		return
	}
	testing.expectf(t, false, "command %d %s\n got  %q\n want %q", index, line, got, want)
}

split_command :: proc(line: string, argv: ^[dynamic][]u8) {
	clear(argv)
	start := 0
	for i in 0 ..= len(line) {
		if i == len(line) || line[i] == '|' {
			append(argv, transmute([]u8)line[start:i])
			start = i + 1
		}
	}
}

replay_fixture :: proc(t: ^testing.T, script: []string, replies: []string) -> (mismatched: int) {
	m: Model
	model_init(&m)
	defer model_destroy(&m)
	argv := make([dynamic][]u8)
	defer delete(argv)
	for line, i in script {
		split_command(line, &argv)
		if !run_command(&m, argv[:]) {
			continue
		}
		if string(m.out[:]) != replies[i] {
			mismatched += 1
			if mismatched <= 10 {
				report_mismatch(t, i, line[:min(len(line), 300)], string(m.out[:min(len(m.out), 400)]), replies[i][:min(len(replies[i]), 400)])
			}
		}
	}
	return
}

@(test)
replay_fixture_resp2 :: proc(t: ^testing.T) {
	testing.expect_value(t, len(MINI_RESP2_SCRIPT), len(MINI_RESP2_REPLIES))
	testing.expect_value(t, replay_fixture(t, MINI_RESP2_SCRIPT[:], MINI_RESP2_REPLIES[:]), 0)
}

@(test)
replay_fixture_resp3 :: proc(t: ^testing.T) {
	testing.expect_value(t, len(MINI_RESP3_SCRIPT), len(MINI_RESP3_REPLIES))
	testing.expect_value(t, replay_fixture(t, MINI_RESP3_SCRIPT[:], MINI_RESP3_REPLIES[:]), 0)
}

main :: proc() {
	failed := replay_fixture(nil, MINI_RESP2_SCRIPT[:], MINI_RESP2_REPLIES[:]) + replay_fixture(nil, MINI_RESP3_SCRIPT[:], MINI_RESP3_REPLIES[:])
	fmt.printf("fixture replay mismatched %d\n", failed)
	if failed != 0 {
		os.exit(1)
	}
}
