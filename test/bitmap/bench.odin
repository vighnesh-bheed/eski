package bitmap_harness

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import bm "../../src/bitmap"

bench_fill :: proc(n: int) -> []u8 {
	buf := make([]u8, n)
	r := rng_make(0x5eed_b17c_0417)
	i := 0
	for ; i + 8 <= n; i += 8 {
		v := rng_next(&r)
		(^u64)(&buf[i])^ = v
	}
	for ; i < n; i += 1 {
		buf[i] = u8(rng_next(&r))
	}
	return buf
}

run_benchdata :: proc(mb_s: string, path: string) -> int {
	mb, ok := strconv.parse_int(mb_s)
	if !ok || mb <= 0 {
		fmt.eprintln("benchdata: megabytes must be a positive integer")
		return 2
	}
	buf := bench_fill(mb * 1024 * 1024)
	defer delete(buf)
	if err := os.write_entire_file(path, buf); err != nil {
		fmt.eprintfln("benchdata: cannot write %s: %v", path, err)
		return 1
	}
	fmt.printfln("wrote %d bytes to %s popcount %d", len(buf), path, bm.popcount(buf))
	return 0
}

run_bench :: proc(args: []string) -> int {
	mb, ok := strconv.parse_int(args[0])
	if !ok || mb <= 0 {
		fmt.eprintln("bench: megabytes must be a positive integer")
		return 2
	}
	iters := 20
	if len(args) > 1 {
		if v, iok := strconv.parse_int(args[1]); iok && v > 0 {
			iters = v
		}
	}
	n := mb * 1024 * 1024
	buf := bench_fill(n)
	defer delete(buf)
	want := naive_check_sample(buf)
	count := bm.popcount(buf)
	total: f64 = 0
	best := max(f64)
	for _ in 0 ..< iters {
		t := time.tick_now()
		c := bm.popcount(buf)
		d := time.duration_seconds(time.tick_since(t))
		if c != count {
			fmt.eprintln("bench: popcount changed between runs")
			return 1
		}
		total += d
		best = min(best, d)
	}
	mean := total / f64(iters)
	full := bm.bitcount(buf, 0, -1, .Byte)
	if full != count || want < 0 {
		fmt.eprintln("bench: bitcount and popcount disagree")
		return 1
	}
	fmt.printfln("eski bytes=%d iterations=%d count=%d mean_ms=%.3f best_ms=%.3f mean_bytes_per_sec=%.0f best_bytes_per_sec=%.0f", n, iters, count, mean * 1000, best * 1000, f64(n) / mean, f64(n) / best)
	return 0
}

naive_check_sample :: proc(buf: []u8) -> i64 {
	n := min(len(buf), 1 << 16)
	if bm.popcount(buf[:n]) != naive_popcount(buf[:n]) {
		return -1
	}
	return 0
}
