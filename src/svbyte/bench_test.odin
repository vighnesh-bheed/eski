package svbyte

import "core:log"
import "core:os"
import "core:testing"
import "core:time"

BENCH_ENV :: "ESKI_SVBYTE_BENCH"

BENCH_VALUES :: 1 << 16

BENCH_BUDGET :: 200 * time.Millisecond

bench_sink: u32

bench_decode :: proc(k: Kernels, data: []u8, out: []u32, delta: bool) -> f64 {
	rounds := 0
	start := time.tick_now()
	for time.tick_since(start) < BENCH_BUDGET {
		if delta {
			k.decode_delta(data, out, 0)
		} else {
			k.decode(data, out)
		}
		bench_sink += out[len(out) - 1]
		rounds += 1
	}
	return f64(rounds * len(out)) / time.duration_seconds(time.tick_since(start))
}

bench_shape :: proc(name: string, values: []u32) {
	sorted := make([]u32, len(values))
	defer delete(sorted)
	acc := u32(0)
	for v, i in values {
		acc += v
		sorted[i] = acc
	}
	buf := make([]u8, max_encoded(len(values)) + 16)
	defer delete(buf)
	size := encode_delta(sorted, 0, buf)
	out := make([]u32, len(values))
	defer delete(out)
	for level in Level {
		if !level_supported(level) {
			continue
		}
		k := kernels_for(level)
		plain := bench_decode(k, buf[:size + 16], out, false)
		delta := bench_decode(k, buf[:size + 16], out, true)
		log.infof("stream vbyte %s, %d values, %.2f bytes per value, level %v: decode %.0f M values/s (%.2f GB/s out), delta decode %.0f M values/s", name, len(values), f64(size) / f64(len(values)), level, plain / 1e6, plain * 4 / 1e9, delta / 1e6)
	}
}

@(test)
bench_decode_throughput :: proc(t: ^testing.T) {
	if _, enabled := os.lookup_env(BENCH_ENV, context.temp_allocator); !enabled {
		return
	}
	r := Rng{0xBE7C}
	gaps := make([]u32, BENCH_VALUES)
	defer delete(gaps)
	for &g in gaps {
		g = 1 + u32(rng_below(&r, 200))
	}
	bench_shape("dense doc gaps 1..200", gaps)
	for &g in gaps {
		g = 1 + u32(rng_below(&r, 1 << 14))
	}
	bench_shape("sparse doc gaps 1..16384", gaps)
	mixed := random_values(&r, BENCH_VALUES)
	defer delete(mixed)
	bench_shape("uniform byte lengths", mixed)
}
