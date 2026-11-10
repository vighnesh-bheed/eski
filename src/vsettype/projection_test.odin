package vsettype

import "core:testing"
import "../vmath"

@(test)
projection_matches_the_materialised_hadamard_matrix_bit_for_bit :: proc(t: ^testing.T) {
	r := Test_Rng{state = 0x9A11}
	shapes := [][2]int{{1, 1}, {2, 1}, {3, 2}, {3, 3}, {8, 3}, {8, 8}, {16, 5}, {33, 7}, {64, 64}, {100, 31}, {300, 128}, {768, 257}, {1000, 999}}
	checked := 0
	for shape in shapes {
		input, output := shape[0], shape[1]
		p: vmath.Projection
		testing.expect_value(t, vmath.projection_init(&p, input, output), nil)
		x := make([]f32, input)
		a := make([]f32, output)
		b := make([]f32, output)
		for round in 0 ..< 6 {
			random_vector(&r, x)
			if round == 1 {
				x[0] = 1e30
			}
			if round == 2 {
				x[input - 1] = -1e-38
			}
			vmath.projection_project(&p, x, a)
			project(x, input, output, b)
			for j in 0 ..< output {
				if !testing.expectf(t, transmute(u32)a[j] == transmute(u32)b[j], "shape %v row %d: %v against %v", shape, j, b[j], a[j]) {
					break
				}
				checked += 1
			}
		}
		delete(x)
		delete(a)
		delete(b)
		vmath.projection_destroy(&p)
	}
	testing.expect(t, checked > 9000)
}

@(test)
projected_set_stores_the_normalised_projection :: proc(t: ^testing.T) {
	s := new_set(t, 8, .Q8, 0, 3)
	defer destroy(s)
	testing.expect(t, add_values(t, s, "a", {1, 2, 3, 4, 5, 6, 7, 8}, reduce = 3))
	slot, _ := find(s, bytes_of("a"))
	out: [3]f32
	values := embedding(s, slot, out[:])
	want := []f64{12.727922439575195, -1.4030780792236328, -2.8061561584472656}
	for v, i in values {
		testing.expectf(t, f64(v) == want[i], "component %d: %v against %v", i, v, want[i])
	}
	raw := raw_embedding(s, slot)
	testing.expect_value(t, string(raw.data), "\x7f\xf2\xe4")
	testing.expect_value(t, f64(raw.norm), 13.114877700805664)
	testing.expect_value(t, f64(raw.range), 0.9704949259757996)
	testing.expect_value(t, info(s).projection_input_dim, 8)
	testing.expect_value(t, dim(s), 3)
}
