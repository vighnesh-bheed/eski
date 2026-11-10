package vmath

import "base:runtime"
import "core:math"
import "core:testing"

@(test)
project_rng_known_answers :: proc(t: ^testing.T) {
	state: u64
	testing.expect_value(t, splitmix64(&state), u64(0xe220a8397b1dcdaf))
	r: Rng
	rng_seed(&r, 0)
	zero := [?]u64{0x99ec5f36cb75f2b4, 0xbf6e1f784956452a, 0x1a5f849d4933e6e0, 0x6aa594f1262d2d2c}
	for want in zero {
		testing.expect_value(t, rng_next(&r), want)
	}
	rng_seed(&r, 20261106)
	dated := [?]u64{0x2206b4d147803110, 0xf46d8aa80ce56314, 0xa43552b2999fa0f5, 0xbeb216a54a09efec}
	for want in dated {
		testing.expect_value(t, rng_next(&r), want)
	}
}

@(test)
project_gaussian_moments :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 41)
	n := 200_000
	sum: f64
	sum2: f64
	for _ in 0 ..< n {
		g := rng_gaussian(&r)
		sum += g
		sum2 += g * g
	}
	mean := sum / f64(n)
	variance := sum2 / f64(n) - mean * mean
	testing.expectf(t, abs(mean) < 0.01, "mean %v", mean)
	testing.expectf(t, abs(variance - 1) < 0.02, "variance %v", variance)
	for _ in 0 ..< 1000 {
		u := rng_f64(&r)
		testing.expect(t, u >= 0 && u < 1)
	}
}

@(test)
project_shape_and_determinism :: proc(t: ^testing.T) {
	a: Projection
	b: Projection
	c: Projection
	testing.expect_value(t, projection_init_gaussian(&a, 300, 64, 7), nil)
	testing.expect_value(t, projection_init_gaussian(&b, 300, 64, 7), nil)
	testing.expect_value(t, projection_init_gaussian(&c, 300, 64, 8), nil)
	defer projection_destroy(&a)
	defer projection_destroy(&b)
	defer projection_destroy(&c)
	testing.expect_value(t, len(a.data), 300 * 64)
	testing.expect_value(t, a.input, 300)
	testing.expect_value(t, a.output, 64)
	testing.expect(t, transmute(string)a.data == transmute(string)b.data)
	testing.expect(t, transmute(string)a.data != transmute(string)c.data)
	sum2: f64
	for w in a.data {
		sum2 += f64(w) * f64(w)
	}
	testing.expectf(t, abs(sum2 / f64(len(a.data)) * 64 - 1) < 0.05, "entry variance %v", sum2 / f64(len(a.data)))
	loaded: Projection
	testing.expect_value(t, projection_load(&loaded, 300, 64, a.data, .Gaussian), nil)
	defer projection_destroy(&loaded)
	testing.expect(t, transmute(string)loaded.data == transmute(string)a.data)
	testing.expect(t, raw_data(loaded.data) != raw_data(a.data))
	bad: Projection
	invalid := runtime.Allocator_Error.Invalid_Argument
	testing.expect_value(t, projection_init_gaussian(&bad, 3, 4, 1), invalid)
	testing.expect_value(t, projection_init(&bad, 3, 0), invalid)
	testing.expect_value(t, projection_init(&bad, 3, 4), invalid)
	testing.expect_value(t, projection_load(&bad, 300, 64, a.data[1:], .Gaussian), invalid)
	same: Projection
	testing.expect_value(t, projection_init(&same, 3, 3), nil)
	projection_destroy(&same)
}

@(test)
project_apply_normalises_and_preserves_length :: proc(t: ^testing.T) {
	p: Projection
	testing.expect_value(t, projection_init_gaussian(&p, 768, 128, 99), nil)
	defer projection_destroy(&p)
	r: Rng
	rng_seed(&r, 42)
	ratio: f64
	rounds := 200
	for _ in 0 ..< rounds {
		x := test_raw_vector(&r, 768)
		y := make([]f32, 128, context.temp_allocator)
		raw := make([]f32, 128, context.temp_allocator)
		norm := projection_apply(&p, x, y)
		projection_project(&p, x, raw)
		testing.expect_value(t, norm, l2_norm(raw))
		for v, i in raw {
			testing.expect_value(t, y[i], v / norm)
		}
		unit := dot_f32_ref(y, y)
		testing.expectf(t, abs(f64(unit) - 1) < 1e-5, "projected vector sum of squares %v", unit)
		for j in 0 ..< 128 {
			want: f64
			row := projection_row(&p, j)
			for i in 0 ..< 768 {
				want += f64(row[i]) * f64(x[i])
			}
			testing.expectf(t, abs(f64(raw[j]) - want) <= 1e-3 * (1 + abs(want)), "row %d: %v against %v", j, raw[j], want)
		}
		xn := f64(l2_norm(x))
		ratio += (f64(norm) * f64(norm)) / (xn * xn)
	}
	ratio /= f64(rounds)
	testing.expectf(t, abs(ratio - 1) < 0.05, "mean squared length ratio %v", ratio)
	short := make([]f32, 10, context.temp_allocator)
	out := make([]f32, 128, context.temp_allocator)
	testing.expect_value(t, projection_apply(&p, short, out), f32(0))
	cosine_drift: f64
	for _ in 0 ..< 50 {
		x := test_unit_vector(&r, 768)
		z := test_unit_vector(&r, 768)
		for i in 0 ..< 768 {
			z[i] = x[i] + 0.5 * z[i]
		}
		normalise(z, z)
		px := make([]f32, 128, context.temp_allocator)
		pz := make([]f32, 128, context.temp_allocator)
		projection_apply(&p, x, px)
		projection_apply(&p, z, pz)
		cosine_drift = max(cosine_drift, abs(f64(dot_f32_ref(px, pz)) - f64(dot_f32_ref(x, z))))
	}
	testing.expectf(t, cosine_drift < 0.25, "cosine drift %v", cosine_drift)
	testing.expect(t, !math.is_nan(cosine_drift))
}

@(test)
project_hadamard_construction :: proc(t: ^testing.T) {
	p: Projection
	testing.expect_value(t, projection_init(&p, 64, 16), nil)
	defer projection_destroy(&p)
	testing.expect_value(t, p.kind, Projection_Kind.Hadamard)
	c := f32(0.125)
	for j in 0 ..< 16 {
		row := projection_row(&p, j)
		for i in 0 ..< 64 {
			testing.expect_value(t, abs(row[i]), c)
		}
		for k in 0 ..< 16 {
			other := projection_row(&p, k)
			s: f64
			for i in 0 ..< 64 {
				s += f64(row[i]) * f64(other[i])
			}
			testing.expectf(t, abs(s - (1 if j == k else 0)) < 1e-6, "rows %d and %d: %v", j, k, s)
		}
	}
	testing.expect_value(t, projection_row(&p, 3)[5], -c)
	testing.expect_value(t, projection_row(&p, 6)[6], c)
	testing.expect_value(t, hadamard_scale(8), f32(0.35355338))
	q: Projection
	testing.expect_value(t, projection_init(&q, 64, 16), nil)
	defer projection_destroy(&q)
	testing.expect(t, transmute(string)p.data == transmute(string)q.data)
}
