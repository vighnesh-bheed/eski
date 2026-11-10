package hnsw

import "core:math"

UNIT_53 :: 1.0 / f64(u64(1) << 53)

rng_next :: #force_inline proc "contextless" (state: ^u64) -> u64 {
	state^ += 0x9E3779B97F4A7C15
	z := state^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

rng_uniform :: #force_inline proc "contextless" (state: ^u64) -> f64 {
	return f64((rng_next(state) >> 11) + 1) * UNIT_53
}

level_for :: proc "contextless" (uniform, level_log: f64) -> int {
	l := math.floor(math.ln(uniform) / level_log)
	if l >= f64(LEVEL_CAP) {
		return LEVEL_CAP
	}
	return int(l)
}

random_level :: proc "contextless" (ix: ^Index) -> int {
	return level_for(rng_uniform(&ix.rng), ix.level_log)
}
