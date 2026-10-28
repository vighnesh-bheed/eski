package hll

import "core:math"

HLL_ALPHA_INF :: 0.721347520444481703680

HLL_LLROUND_OVERFLOW :: u64(0x8000000000000000)

hll_sigma :: proc "contextless" (x: f64) -> f64 {
	if x == 1 {
		return math.inf_f64(1)
	}
	power := x
	weight := 1.0
	sum := x
	for {
		power *= power
		previous := sum
		sum += power * weight
		weight += weight
		if sum == previous {
			return sum
		}
	}
}

hll_tau :: proc "contextless" (x: f64) -> f64 {
	if x == 0 || x == 1 {
		return 0
	}
	root := x
	weight := 1.0
	sum := 1 - x
	for {
		root = math.sqrt(root)
		previous := sum
		weight *= 0.5
		gap := 1 - root
		sum -= gap * gap * weight
		if sum == previous {
			return sum / 3
		}
	}
}

llround_to_u64 :: proc "contextless" (x: f64) -> u64 {
	if !(x > -9223372036854775808.0 && x < 9223372036854775808.0) {
		return HLL_LLROUND_OVERFLOW
	}
	whole := math.trunc(x)
	fraction := x - whole
	if fraction >= 0.5 {
		whole += 1
	} else if fraction <= -0.5 {
		whole -= 1
	}
	return u64(i64(whole))
}

estimate_from_histo :: proc "contextless" (reghisto: ^[64]int) -> u64 {
	m :: f64(HLL_REGISTERS)
	z := m * hll_tau((m - f64(reghisto[HLL_Q + 1])) / m)
	for k := HLL_Q; k >= 1; k -= 1 {
		z += f64(reghisto[k])
		z *= 0.5
	}
	z += m * hll_sigma(f64(reghisto[0]) / m)
	return llround_to_u64(HLL_ALPHA_INF * m * m / z)
}

hll_estimate :: proc "contextless" (buf: []u8, invalid: ^bool) -> u64 {
	if !hll_is_valid(buf) {
		invalid^ = true
		return 0
	}
	reghisto: [64]int
	if buf[4] == HLL_DENSE {
		dense_reg_histo(buf[HLL_HDR_SIZE:], &reghisto)
	} else if !sparse_reg_histo(buf, &reghisto) {
		invalid^ = true
		return 0
	}
	return estimate_from_histo(&reghisto)
}

hll_estimate_raw :: proc "contextless" (regs: ^[HLL_REGISTERS]u8) -> u64 {
	reghisto: [64]int
	raw_reg_histo(regs, &reghisto)
	return estimate_from_histo(&reghisto)
}
