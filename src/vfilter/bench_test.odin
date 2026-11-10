package vfilter

import "core:log"
import "core:os"
import "core:testing"
import "core:time"

BENCH_ENVIRONMENT :: "ESKI_VFILTER_BENCH"
BENCH_EXPRESSION :: `.year >= 1980 and .rating > 8.0 and .genre == "action"`
BENCH_ATTRIBUTE :: `{"year":1985,"rating":8.5,"genre":"action","director":"Spielberg","tags":["classic","adventure"]}`
BENCH_EVALUATIONS :: 20_000_000

@(test)
bench_three_clause_evaluation :: proc(t: ^testing.T) {
	if _, enabled := os.lookup_env(BENCH_ENVIRONMENT, context.temp_allocator); !enabled {
		return
	}
	program, _, err := compile(BENCH_EXPRESSION)
	defer program_destroy(&program)
	testing.expect(t, err == .None)
	attribute, _ := attribute_make(BENCH_ATTRIBUTE)
	defer attribute_destroy(&attribute)
	hits := 0
	for _ in 0 ..< 100_000 {
		if evaluate(&program, &attribute) {
			hits += 1
		}
	}
	start := time.tick_now()
	for _ in 0 ..< BENCH_EVALUATIONS {
		if evaluate(&program, &attribute) {
			hits += 1
		}
	}
	elapsed := time.tick_since(start)
	seconds := time.duration_seconds(elapsed)
	log.infof("vfilter bench: %d evaluations in %.3f s, %.0f evaluations per second, %.1f ns each", BENCH_EVALUATIONS, seconds, f64(BENCH_EVALUATIONS) / seconds, seconds * 1e9 / f64(BENCH_EVALUATIONS))
	testing.expect_value(t, hits, BENCH_EVALUATIONS + 100_000)
}
