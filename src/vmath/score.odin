package vmath

distance_from_dot :: #force_inline proc "contextless" (dot: f32) -> f32 {
	return 1 - dot
}

q8_scale :: #force_inline proc "contextless" (range_a: f32, range_b: f32) -> f32 {
	return (range_a / Q8_SCALE) * (range_b / Q8_SCALE)
}

distance_q8 :: #force_inline proc "contextless" (idot: i64, range_a: f32, range_b: f32, dim: int) -> f32 {
	scale := q8_scale(range_a, range_b)
	d: f32
	if dim >= Q8_FUSED_MIN {
		d = fma_f32(-scale, f32(idot), 1)
	} else {
		d = 1 - scale * f32(idot)
	}
	return clamp(d, 0, 2)
}

distance_bin :: #force_inline proc "contextless" (hamming: u64, dim: int) -> f32 {
	return (f32(hamming) / f32(dim)) * 2
}

score_from_distance :: #force_inline proc "contextless" (d: f32) -> f64 {
	return 1 - f64(d) / 2
}

score_bin :: #force_inline proc "contextless" (hamming: u64, dim: int) -> f64 {
	return score_from_distance(distance_bin(hamming, dim))
}

edge_score :: #force_inline proc "contextless" (score: f64) -> f32 {
	return f32(score)
}
