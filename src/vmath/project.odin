package vmath

import "base:intrinsics"
import "base:runtime"
import "core:math"

Rng :: struct {
	s:         [4]u64,
	spare:     f64,
	has_spare: bool,
}

Projection_Kind :: enum u8 {
	Hadamard,
	Gaussian,
}

Projection :: struct {
	data:      []f32,
	input:     int,
	output:    int,
	allocator: runtime.Allocator,
	kind:      Projection_Kind,
}

splitmix64 :: proc "contextless" (state: ^u64) -> u64 {
	state^ += 0x9E3779B97F4A7C15
	z := state^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

rng_seed :: proc "contextless" (r: ^Rng, seed: u64) {
	state := seed
	for i in 0 ..< 4 {
		r.s[i] = splitmix64(&state)
	}
	r.spare = 0
	r.has_spare = false
}

rotl64 :: #force_inline proc "contextless" (x: u64, k: uint) -> u64 {
	return (x << k) | (x >> (64 - k))
}

rng_next :: proc "contextless" (r: ^Rng) -> u64 {
	result := rotl64(r.s[1] * 5, 7) * 9
	t := r.s[1] << 17
	r.s[2] ~= r.s[0]
	r.s[3] ~= r.s[1]
	r.s[1] ~= r.s[2]
	r.s[0] ~= r.s[3]
	r.s[2] ~= t
	r.s[3] = rotl64(r.s[3], 45)
	return result
}

rng_f64 :: proc "contextless" (r: ^Rng) -> f64 {
	return f64(rng_next(r) >> 11) * (1.0 / 9007199254740992.0)
}

rng_gaussian :: proc "contextless" (r: ^Rng) -> f64 {
	if r.has_spare {
		r.has_spare = false
		return r.spare
	}
	for {
		u := 2 * rng_f64(r) - 1
		v := 2 * rng_f64(r) - 1
		s := u * u + v * v
		if s > 0 && s < 1 {
			m := math.sqrt(-2 * math.ln(s) / s)
			r.spare = v * m
			r.has_spare = true
			return u * m
		}
	}
}

projection_valid :: proc "contextless" (input: int, output: int) -> bool {
	return dim_valid(input) && output >= 1 && output <= input
}

hadamard_scale :: proc "contextless" (input: int) -> f32 {
	return f32(1 / math.sqrt(f64(input)))
}

hadamard_entry :: #force_inline proc "contextless" (row: int, col: int, scale: f32) -> f32 {
	return -scale if intrinsics.count_ones(uint(row & col)) & 1 != 0 else scale
}

projection_init :: proc(p: ^Projection, input: int, output: int, allocator := context.allocator) -> runtime.Allocator_Error {
	if !projection_valid(input, output) {
		return .Invalid_Argument
	}
	data, err := make([]f32, input * output, allocator)
	if err != nil {
		return err
	}
	scale := hadamard_scale(input)
	for j in 0 ..< output {
		for i in 0 ..< input {
			data[j * input + i] = hadamard_entry(j, i, scale)
		}
	}
	p^ = {data = data, input = input, output = output, allocator = allocator, kind = .Hadamard}
	return nil
}

projection_init_gaussian :: proc(p: ^Projection, input: int, output: int, seed: u64, allocator := context.allocator) -> runtime.Allocator_Error {
	if !projection_valid(input, output) {
		return .Invalid_Argument
	}
	data, err := make([]f32, input * output, allocator)
	if err != nil {
		return err
	}
	r: Rng
	rng_seed(&r, seed)
	scale := 1 / math.sqrt(f64(output))
	for &w in data {
		w = f32(rng_gaussian(&r) * scale)
	}
	p^ = {data = data, input = input, output = output, allocator = allocator, kind = .Gaussian}
	return nil
}

projection_load :: proc(p: ^Projection, input: int, output: int, data: []f32, kind: Projection_Kind, allocator := context.allocator) -> runtime.Allocator_Error {
	if !projection_valid(input, output) || len(data) != input * output {
		return .Invalid_Argument
	}
	owned, err := make([]f32, len(data), allocator)
	if err != nil {
		return err
	}
	copy(owned, data)
	p^ = {data = owned, input = input, output = output, allocator = allocator, kind = kind}
	return nil
}

projection_destroy :: proc(p: ^Projection) {
	if p.data != nil {
		delete(p.data, p.allocator)
	}
	p^ = {}
}

projection_row :: #force_inline proc "contextless" (p: ^Projection, row: int) -> []f32 {
	return p.data[row * p.input:][:p.input]
}

projection_project :: proc "contextless" (p: ^Projection, x: []f32, out: []f32) #no_bounds_check {
	n := p.input
	m := p.data
	j := 0
	for ; j + 4 <= p.output; j += 4 {
		r0 := m[j * n:]
		r1 := m[(j + 1) * n:]
		r2 := m[(j + 2) * n:]
		r3 := m[(j + 3) * n:]
		s0: f32
		s1: f32
		s2: f32
		s3: f32
		for i in 0 ..< n {
			s0 = s0 + r0[i] * x[i]
			s1 = s1 + r1[i] * x[i]
			s2 = s2 + r2[i] * x[i]
			s3 = s3 + r3[i] * x[i]
		}
		out[j] = s0
		out[j + 1] = s1
		out[j + 2] = s2
		out[j + 3] = s3
	}
	for ; j < p.output; j += 1 {
		r := m[j * n:]
		s: f32
		for i in 0 ..< n {
			s = s + r[i] * x[i]
		}
		out[j] = s
	}
}

projection_apply :: proc "contextless" (p: ^Projection, x: []f32, out: []f32) -> (norm: f32) {
	if len(x) < p.input || len(out) < p.output {
		return 0
	}
	projection_project(p, x, out)
	return normalise(out[:p.output], out[:p.output])
}
