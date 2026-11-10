package vset_owners

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import lbl "../../../src/label"
import vt "../../../src/vsettype"

DIM :: 128
POOL :: 4096

Rng :: struct {
	s: u64,
}

next :: proc(r: ^Rng) -> u64 {
	r.s += 0x9E3779B97F4A7C15
	z := r.s
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

unit :: proc(r: ^Rng) -> f32 {
	return f32(f64(next(r) >> 11) * (1.0 / 9007199254740992.0)) * 2 - 1
}

fill :: proc(r: ^Rng, x: []f32) {
	for &v in x {
		v = unit(r)
	}
}

Env :: struct {
	table:   lbl.Table,
	vis:     lbl.Visibility,
	shared:  u64,
	streams: []u64,
	sc:      vt.Scratch,
}

failures: int

expect :: proc(ok: bool, what: string) {
	if !ok {
		failures += 1
		fmt.eprintfln("vset owners: check failed: %s", what)
	}
}

env_init :: proc(e: ^Env, owners: int) {
	lbl.table_init(&e.table)
	lbl.visibility_build(&e.vis, &e.table, lbl.BOTTOM)
	e.streams = make([]u64, owners + 2)
	for &st, i in e.streams {
		st = u64(i + 1) * 0x2545F4914F6CDD1D
	}
	e.shared = 0x51
	vt.scratch_init(&e.sc)
}

access :: proc(e: ^Env, o: int) -> vt.Access {
	a := vt.Access{label = lbl.BOTTOM_ID, visibility = &e.vis, table = &e.table, stream = &e.shared}
	if o > 0 {
		a.owner = vt.Owner(o)
		a.stream = &e.streams[o]
	}
	return a
}

new_set :: proc(e: ^Env, x: []f32) -> vt.Vset {
	a := access(e, 0)
	req := vt.Add_Request{vector = x, quant = .Q8}
	s, f := vt.create_at(&req, &a)
	expect(f.err == .None, "create the set")
	return s
}

add :: proc(e: ^Env, s: vt.Vset, o: int, name: string, x: []f32) {
	a := access(e, o)
	req := vt.Add_Request{name = transmute([]u8)name, vector = x, quant = .Q8}
	_, f := vt.add_at(s, &a, &req, &e.sc)
	expect(f.err == .None, "add an element")
}

view_count :: proc(e: ^Env, s: vt.Vset, o: int) -> int {
	a := access(e, o)
	v, err := vt.view_open(s, &a, &e.sc)
	expect(err == .None, "open a view")
	return vt.view_size(&v)
}

creation :: proc(n: int) {
	e: Env
	env_init(&e, n)
	r := Rng{s = 7}
	x := make([]f32, DIM)
	defer delete(x)
	fill(&r, x)
	s := new_set(&e, x)
	base := vt.memory_usage(s)
	seen := view_count(&e, s, 0)
	vectors := make([]f32, DIM * POOL)
	defer delete(vectors)
	for &v in vectors {
		v = unit(&r)
	}
	start := time.tick_now()
	for o in 1 ..= n {
		at := (o % POOL) * DIM
		add(&e, s, o, "doc", vectors[at:at + DIM])
	}
	took := time.tick_since(start)
	expect(vt.owner_count(s) == n, "every owner holds a partition")
	expect(view_count(&e, s, 0) == seen, "the shared reader sees no owner element")
	expect(view_count(&e, s, n / 2 + 1) == seen + 1, "an owner sees its element and the shared ones")
	total := vt.memory_usage(s) - base
	o := vt.Owner(n / 2 + 1)
	part := vt.part_at_scope(s, lbl.BOTTOM_ID, o)
	expect(part != nil, "an owner's partition exists")
	fmt.printfln("{{\"probe\":\"create\",\"owners\":%d,\"bytes_per_owner\":%.1f,\"owner_bytes_per_owner\":%.1f,\"index_bytes_per_owner\":%.1f,\"one_owner_memory\":%d,\"one_partition\":%d,\"shared_bytes\":%d,\"create_us_per_owner\":%.3f}}",
		n, f64(total) / f64(n), f64(vt.owner_bytes(s)) / f64(n), f64(vt.index_bytes(s)) / f64(n), vt.owner_memory(s, o),
		vt.scope_memory(s, lbl.BOTTOM_ID, o), vt.shared_bytes(s), time.duration_microseconds(took) / f64(n))
	start = time.tick_now()
	for k in 1 ..= n {
		vt.remove_owner(s, vt.Owner(k))
	}
	took = time.tick_since(start)
	expect(vt.memory_usage(s) == base, "forgetting every owner returns the set to its bytes before them")
	expect(vt.owner_count(s) == 0, "no owner is left")
	fmt.printfln("{{\"probe\":\"forget\",\"owners\":%d,\"forget_us_per_owner\":%.3f,\"memory_after\":%d,\"memory_before\":%d}}",
		n, time.duration_microseconds(took) / f64(n), vt.memory_usage(s), base)
	vt.destroy(s)
}

Stats :: struct {
	median: f64,
	mean:   f64,
	p99:    f64,
}

stats_of :: proc(samples: []f64) -> Stats {
	slice.sort(samples)
	sum := 0.0
	for v in samples {
		sum += v
	}
	return Stats{median = samples[len(samples) / 2], mean = sum / f64(len(samples)), p99 = samples[len(samples) * 99 / 100]}
}

query :: proc(e: ^Env, s: vt.Vset, o: int, rounds: int, probe: string, want_size: int) {
	a := access(e, o)
	r := Rng{s = 99}
	q := make([]f32, DIM)
	defer delete(q)
	opens := make([]f64, rounds)
	defer delete(opens)
	sims := make([]f64, rounds)
	defer delete(sims)
	hits := make([dynamic]vt.Hit)
	defer delete(hits)
	size := 0
	for i in 0 ..< rounds {
		fill(&r, q)
		t0 := time.tick_now()
		v, err := vt.view_open(s, &a, &e.sc)
		t1 := time.tick_now()
		expect(err == .None, "open a view")
		req := vt.Search_Request{kind = .Vector, vector = q, count = 10}
		clear(&hits)
		f := vt.view_search(&v, &req, &e.sc, &hits)
		t2 := time.tick_now()
		expect(f.err == .None, "search a view")
		expect(len(hits) == min(10, want_size), "a search returns its count")
		opens[i] = time.duration_microseconds(time.tick_diff(t0, t1))
		sims[i] = time.duration_microseconds(time.tick_diff(t1, t2))
		size = vt.view_size(&v)
	}
	expect(size == want_size, "the view holds the visible elements")
	so := stats_of(opens)
	ss := stats_of(sims)
	fmt.printfln("{{\"probe\":\"%s\",\"view_elements\":%d,\"view_open_us\":{{\"median\":%.3f,\"mean\":%.3f,\"p99\":%.3f}},\"vsim_count10_us\":{{\"median\":%.3f,\"mean\":%.3f,\"p99\":%.3f}}}}",
		probe, size, so.median, so.mean, so.p99, ss.median, ss.mean, ss.p99)
}

others_present :: proc(others, shared, rounds: int) {
	e: Env
	env_init(&e, others + 1)
	r := Rng{s = 11}
	x := make([]f32, DIM)
	defer delete(x)
	fill(&r, x)
	s := new_set(&e, x)
	seen := view_count(&e, s, 0)
	for k in 0 ..< shared {
		fill(&r, x)
		add(&e, s, 0, fmt.tprintf("shared%d", k), x)
	}
	observer := others + 1
	for k in 0 ..< 100 {
		fill(&r, x)
		add(&e, s, observer, fmt.tprintf("own%d", k), x)
	}
	free_all(context.temp_allocator)
	query(&e, s, observer, rounds, "observer_without_other_owners", seen + shared + 100)
	for o in 1 ..= others {
		fill(&r, x)
		add(&e, s, o, "doc", x)
	}
	query(&e, s, observer, rounds, "observer_beside_other_owners", seen + shared + 100)
	vt.destroy(s)
}

big_shared :: proc(n, rounds: int) {
	e: Env
	env_init(&e, 4)
	r := Rng{s = 13}
	x := make([]f32, DIM)
	defer delete(x)
	fill(&r, x)
	s := new_set(&e, x)
	seen := view_count(&e, s, 0)
	start := time.tick_now()
	for k in 0 ..< n {
		fill(&r, x)
		add(&e, s, 0, fmt.tprintf("shared%d", k), x)
		free_all(context.temp_allocator)
	}
	fmt.printfln("{{\"probe\":\"build_shared_graph\",\"elements\":%d,\"seconds\":%.3f}}", n, time.duration_seconds(time.tick_since(start)))
	for k in 0 ..< 100 {
		fill(&r, x)
		add(&e, s, 1, fmt.tprintf("own%d", k), x)
	}
	free_all(context.temp_allocator)
	query(&e, s, 0, rounds, "shared_reader", seen + n)
	query(&e, s, 2, rounds, "owner_without_own_data", seen + n)
	query(&e, s, 1, rounds, "owner_with_100_own_elements", seen + n + 100)
	vt.destroy(s)
}

collisions :: proc(shared, rounds: int) {
	e: Env
	env_init(&e, 4)
	r := Rng{s = 17}
	x := make([]f32, DIM)
	defer delete(x)
	fill(&r, x)
	s := new_set(&e, x)
	seen := view_count(&e, s, 0)
	for k in 0 ..< shared {
		fill(&r, x)
		add(&e, s, 0, fmt.tprintf("shared%d", k), x)
	}
	for k in 0 ..< 100 {
		fill(&r, x)
		add(&e, s, 1, fmt.tprintf("own%d", k), x)
	}
	free_all(context.temp_allocator)
	query(&e, s, 1, rounds, "owner_names_not_held_as_shared", seen + shared + 100)
	fill(&r, x)
	add(&e, s, 0, "own7", x)
	query(&e, s, 1, rounds, "owner_name_also_held_as_shared", seen + shared + 100)
	vt.destroy(s)
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
	which := os.args[1] if len(os.args) > 1 else "all"
	owners := arg_int(2, 2000)
	graph := arg_int(3, 1000)
	rounds := arg_int(4, 200)
	known := false
	for w in strings.split(which, ",") {
		switch w {
		case "all", "create", "others", "collide", "big":
			known = true
		}
	}
	if !known {
		fmt.eprintln("usage: vset-owners all|create|others|collide|big [owners] [shared graph elements] [rounds]")
		os.exit(2)
	}
	all := which == "all"
	if all || strings.contains(which, "create") {
		creation(owners)
	}
	if all || strings.contains(which, "others") {
		others_present(owners, 1000, rounds)
	}
	if all || strings.contains(which, "collide") {
		collisions(1000, rounds)
	}
	if all || strings.contains(which, "big") {
		big_shared(graph, rounds)
	}
	if failures > 0 {
		fmt.eprintfln("vset owners: %d checks failed", failures)
		os.exit(1)
	}
}
