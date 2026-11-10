package sorted

GALLOP_RATIO :: 32

lower_bound :: proc "contextless" (a: []u32, target: u32) -> int #no_bounds_check {
	lo, hi := 0, len(a)
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		if a[mid] < target {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

upper_bound :: proc "contextless" (a: []u32, target: u32) -> int #no_bounds_check {
	lo, hi := 0, len(a)
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		if a[mid] <= target {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

gallop :: proc "contextless" (a: []u32, from: int, target: u32) -> int #no_bounds_check {
	n := len(a)
	lo := max(from, 0)
	if lo >= n || a[lo] >= target {
		return lo
	}
	step := 1
	hi := lo + 1
	for hi < n && a[hi] < target {
		lo = hi
		step <<= 1
		hi = lo + step
	}
	if hi > n {
		hi = n
	}
	lo += 1
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		if a[mid] < target {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

intersect_reference :: proc "contextless" (a, b: []u32, out: []u32) -> int #no_bounds_check {
	i, j, k := 0, 0, 0
	for i < len(a) && j < len(b) {
		x, y := a[i], b[j]
		if x < y {
			i += 1
		} else if x > y {
			j += 1
		} else {
			out[k] = x
			k += 1
			i += 1
			j += 1
		}
	}
	return k
}

intersect_merge :: proc "contextless" (a, b: []u32, out: []u32) -> int #no_bounds_check {
	i, j, k := 0, 0, 0
	na, nb := len(a), len(b)
	for i < na && j < nb {
		x, y := a[i], b[j]
		out[k] = x
		k += int(x == y)
		i += int(x <= y)
		j += int(y <= x)
	}
	return k
}

intersect_gallop :: proc "contextless" (small, large: []u32, out: []u32) -> int #no_bounds_check {
	k, j := 0, 0
	for x in small {
		j = gallop(large, j, x)
		if j >= len(large) {
			break
		}
		if large[j] == x {
			out[k] = x
			k += 1
			j += 1
		}
	}
	return k
}

intersect_simd :: proc "contextless" (a, b: []u32, out: []u32) -> int {
	return kernels.intersect(a, b, out)
}

intersect :: proc "contextless" (a, b: []u32, out: []u32) -> int {
	if len(a) == 0 || len(b) == 0 {
		return 0
	}
	if len(a) * GALLOP_RATIO < len(b) {
		return intersect_gallop(a, b, out)
	}
	if len(b) * GALLOP_RATIO < len(a) {
		return intersect_gallop(b, a, out)
	}
	return kernels.intersect(a, b, out)
}

intersect_count :: proc "contextless" (a, b: []u32) -> int #no_bounds_check {
	i, j, k := 0, 0, 0
	na, nb := len(a), len(b)
	for i < na && j < nb {
		x, y := a[i], b[j]
		k += int(x == y)
		i += int(x <= y)
		j += int(y <= x)
	}
	return k
}

union_merge :: proc "contextless" (a, b: []u32, out: []u32) -> int #no_bounds_check {
	i, j, k := 0, 0, 0
	for i < len(a) && j < len(b) {
		x, y := a[i], b[j]
		if x < y {
			out[k] = x
			i += 1
		} else if x > y {
			out[k] = y
			j += 1
		} else {
			out[k] = x
			i += 1
			j += 1
		}
		k += 1
	}
	for ; i < len(a); i += 1 {
		out[k] = a[i]
		k += 1
	}
	for ; j < len(b); j += 1 {
		out[k] = b[j]
		k += 1
	}
	return k
}

difference_merge :: proc "contextless" (a, b: []u32, out: []u32) -> int #no_bounds_check {
	i, j, k := 0, 0, 0
	for i < len(a) {
		x := a[i]
		for j < len(b) && b[j] < x {
			j += 1
		}
		if j < len(b) && b[j] == x {
			j += 1
		} else {
			out[k] = x
			k += 1
		}
		i += 1
	}
	return k
}

is_strict :: proc "contextless" (a: []u32) -> bool #no_bounds_check {
	for i in 1 ..< len(a) {
		if a[i - 1] >= a[i] {
			return false
		}
	}
	return true
}
