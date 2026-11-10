package store_micro

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import eski "../../../src"

Keys :: struct {
	bytes: [dynamic]u8,
	ends:  [dynamic]int,
	n:     int,
}

Phase :: enum {
	Insert,
	Overwrite,
	Hit,
	Miss,
	Remove,
	Timed,
}

PHASE_NAMES := [Phase]string {
	.Insert    = "insert",
	.Overwrite = "overwrite",
	.Hit       = "hit",
	.Miss      = "miss",
	.Remove    = "remove",
	.Timed     = "timed",
}

sink: int

make_keys :: proc(prefix: string, count, width: int) -> (k: Keys) {
	buf: [64]u8
	for j in 0 ..< count {
		s := fmt.bprintf(buf[:], "%s%0*d", prefix, width, j)
		append(&k.bytes, ..transmute([]u8)s)
		append(&k.ends, len(k.bytes))
	}
	k.n = count
	return
}

key_at :: #force_inline proc(k: ^Keys, i: int) -> []u8 #no_bounds_check {
	start := 0 if i == 0 else k.ends[i - 1]
	return k.bytes[start:k.ends[i]]
}

permutation :: proc(n: int, seed: u64) -> []int {
	p := make([]int, n)
	for i in 0 ..< n {
		p[i] = i
	}
	x := seed | 1
	for i := n - 1; i > 0; i -= 1 {
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		j := int(x % u64(i + 1))
		p[i], p[j] = p[j], p[i]
	}
	return p
}

insert :: #force_no_inline proc(db: ^eski.Db, k, v: ^Keys) {
	for i in 0 ..< k.n {
		e, _ := eski.db_upsert_in(db, key_at(k, i))
		eski.entry_assign(e, key_at(v, i))
	}
}

insert_timed :: #force_no_inline proc(db: ^eski.Db, k, v: ^Keys) {
	at := eski.srv.now_ms + 86_400_000
	for i in 0 ..< k.n {
		e, _ := eski.db_upsert_timed_in(db, key_at(k, i), at)
		eski.entry_assign(e, key_at(v, i))
		eski.entry_set_expire(e, at)
	}
}

hit :: #force_no_inline proc(db: ^eski.Db, k: ^Keys, order: []int) -> int {
	found := 0
	for i in 0 ..< k.n {
		if e := eski.db_find_in(db, key_at(k, order[i])); e != nil {
			found += 1
			sink += len(e.val)
		}
	}
	return found
}

miss :: #force_no_inline proc(db: ^eski.Db, k: ^Keys) -> int {
	found := 0
	for i in 0 ..< k.n {
		if eski.db_find_in(db, key_at(k, i)) != nil {
			found += 1
		}
	}
	return found
}

remove :: #force_no_inline proc(db: ^eski.Db, k: ^Keys) -> int {
	gone := 0
	for i in 0 ..< k.n {
		if found, _ := eski.db_remove_in(db, key_at(k, i)); found {
			gone += 1
		}
	}
	return gone
}

per_op :: proc(t0, t1: i64, n: int) -> f64 {
	return f64(t1 - t0) / f64(n)
}

family :: proc(name, prefix, miss_prefix: string, width, n, reps: int) {
	k := make_keys(prefix, n, width)
	m := make_keys(miss_prefix, n, width)
	v := make_keys("val", n, 5)
	w := make_keys("vax", n, 5)
	order := permutation(n, 0x9E37_79B9_7F4A_7C15)
	samples: [Phase][dynamic]f64
	for r in 0 ..< reps {
		db := &eski.dbs[r % 4]
		eski.db_flush_in(db)
		t: [7]i64
		t[0] = eski.now_ns()
		insert(db, &k, &v)
		t[1] = eski.now_ns()
		insert(db, &k, &w)
		t[2] = eski.now_ns()
		hits := hit(db, &k, order)
		t[3] = eski.now_ns()
		misses := miss(db, &m)
		t[4] = eski.now_ns()
		removed := remove(db, &k)
		t[5] = eski.now_ns()
		insert_timed(db, &k, &v)
		t[6] = eski.now_ns()
		if hits != n || misses != 0 || removed != n {
			fmt.eprintfln("store micro: %s keys: %d hits, %d misses, %d removed of %d", name, hits, misses, removed, n)
			os.exit(3)
		}
		for p in Phase {
			append(&samples[p], per_op(t[int(p)], t[int(p) + 1], n))
		}
		eski.db_flush_in(db)
	}
	b := strings.builder_make()
	fmt.sbprintf(&b, "{{\"family\":\"%s\",\"keys\":%d", name, n)
	for p in Phase {
		fmt.sbprintf(&b, ",\"%s\":[", PHASE_NAMES[p])
		for x, i in samples[p] {
			fmt.sbprintf(&b, "%s%.3f", "," if i > 0 else "", x)
		}
		strings.write_string(&b, "]")
	}
	strings.write_string(&b, "}")
	fmt.println(strings.to_string(b))
}

arg_int :: proc(i: int, def: int) -> int {
	if len(os.args) > i {
		if v, ok := strconv.parse_int(os.args[i]); ok {
			return v
		}
	}
	return def
}

main :: proc() {
	eski.config_init()
	eski.db_init()
	eski.srv.now_ms = 1_700_000_000_000
	eski.access_seconds_now = 1000
	n := arg_int(1, 20000)
	reps := arg_int(2, 5)
	families := os.args[3] if len(os.args) > 3 else "short,long"
	for f in strings.split(families, ",") {
		switch f {
		case "short":
			family("short", "k", "m", 6, n, reps)
		case "long":
			family("long", "key:", "nokey:", 10, n, reps)
		case:
			fmt.eprintfln("store micro: unknown key family %s", f)
			os.exit(2)
		}
	}
}
