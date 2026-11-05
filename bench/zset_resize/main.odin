package main

import zt "../../src/zsettype"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/linux"
import "core:time"

BOUNDED :: #config(ZSET_BOUNDED, false)
HOST :: #config(ZSET_HOST, false)

Bank_State :: struct {
	active:          bool,
	target_cap:      int,
	source_cap:      int,
	source_live:     int,
	source_cursor:   int,
	ordered_members: int,
	indexed_members: int,
	retired_records: int,
}

Phase :: struct {
	name:                   string,
	migration_work_measured: bool,
	release_work_measured:   bool,
	nanoseconds:            [dynamic]i64,
	service_wall_ns:        i64,
	allocated_peak:         int,
	mapped_peak:            int,
	retired_peak:           int,
	metadata_peak:          int,
	minor_faults:           int,
	scanned:                int,
	moved:                  int,
	probes:                 int,
	max_grant_scanned:      int,
	max_grant_moved:        int,
	released_bytes:         int,
	max_release_bytes:      int,
	active_calls:           int,
	completed_after_calls:  int,
	before:                 Bank_State,
	after:                  Bank_State,
}

Retirement_Fixture :: struct {
	records:             int,
	source_cap:          int,
	target_cap:          int,
	live_per_target:     int,
	source_bytes:        int,
	expected_bytes:      int,
	before_records:      int,
	after_records:       int,
	before_retired:      int,
	after_retired:       int,
	actual_released:     int,
}

Result :: struct {
	bounded:            bool,
	initial_members:    int,
	initial_cap:        int,
	read_samples:       int,
	checksum:           f64,
	clock_baseline_ns:  [dynamic]i64,
	retirement_fixture: Retirement_Fixture,
	phases:             [dynamic]Phase,
}

bytes :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

key :: proc(buf: []u8, i: int) -> []u8 {
	return bytes(fmt.bprintf(buf, "member:%012d", i))
}

faults :: proc() -> int {
	r: linux.RUsage
	assert(linux.getrusage(.SELF, &r) == .NONE)
	return r.minflt_word
}

bank_state :: proc(h: zt.Zset) -> (s: Bank_State) {
	s.target_cap = h.sl.cap
	s.ordered_members = h.sl.length
	s.indexed_members = h.sl.count
	when BOUNDED {
		if r := h.sl.resize; r != nil {
			s.active = true
			s.source_cap = r.old_cap
			s.source_live = r.old_count
			s.source_cursor = r.cursor
		}
		for r := zt.resize_retired_head; r != nil; r = r.next {
			s.retired_records += 1
		}
	}
	return
}

sample :: proc(p: ^Phase, h: zt.Zset) {
	p.allocated_peak = max(p.allocated_peak, zt.memory_usage(h))
	when HOST {
		p.allocated_peak = max(p.allocated_peak, db_cur.heap_bytes)
	}
	when BOUNDED {
		mapped, retired, metadata := zt.maintenance_memory()
		p.mapped_peak = max(p.mapped_peak, mapped)
		p.retired_peak = max(p.retired_peak, retired)
		p.metadata_peak = max(p.metadata_peak, metadata)
	}
}

record :: proc(p: ^Phase, elapsed: time.Duration, h: zt.Zset) {
	append(&p.nanoseconds, i64(elapsed))
	sample(p, h)
}

active :: proc(h: zt.Zset) -> bool {
	when BOUNDED {
		return h.sl.resize != nil
	} else {
		return false
	}
}

add_member :: proc(h: zt.Zset, member: []u8, score: f64) {
	out, _, ok := zt.add(h, score, member, {})
	assert(ok && .Added in out)
}

make_initial :: proc(n: int) -> zt.Zset {
	h := zt.create_skiplist(n - 1)
	buf: [32]u8
	for i in 0 ..< n {
		add_member(h, key(buf[:], i), f64(i))
	}
	assert(n == h.sl.cap / 4 * 3 && !active(h))
	return h
}

clock_baseline :: proc(result: ^Result) {
	reserve(&result.clock_baseline_ns, 64)
	for _ in 0 ..< 64 {
		start := time.tick_now()
		elapsed := time.tick_since(start)
		append(&result.clock_baseline_ns, i64(elapsed))
	}
}

emit :: proc(result: ^Result) {
	out, err := json.marshal(result^)
	assert(err == nil)
	fmt.println(string(out))
	delete(out)
	for phase in result.phases {
		delete(phase.nanoseconds)
	}
	delete(result.phases)
	delete(result.clock_baseline_ns)
}

drain :: proc(h: zt.Zset, result: ^Result) {
	when BOUNDED {
		p := Phase{name = "direct-foreground-grants-64-scans-4-moves", migration_work_measured = true, before = bank_state(h)}
		reserve(&p.nanoseconds, max(h.sl.length, 1))
		before_faults := faults()
		wall := time.tick_now()
		for h.sl.resize != nil {
			start := time.tick_now()
			work := zt.dict_step(h.sl, zt.RESIZE_WRITE_SCANS, zt.RESIZE_WRITE_MOVES)
			record(&p, time.tick_since(start), h)
			p.scanned += work.scanned
			p.moved += work.moved
			p.probes += work.probes
			p.max_grant_scanned = max(p.max_grant_scanned, work.scanned)
			p.max_grant_moved = max(p.max_grant_moved, work.moved)
		}
		p.service_wall_ns = i64(time.tick_since(wall))
		p.minor_faults = faults() - before_faults
		p.after = bank_state(h)
		append(&result.phases, p)
		p = Phase{name = "direct-release-2MiB-16-calls", release_work_measured = true, before = bank_state(h)}
		reserve(&p.nanoseconds, 128)
		before_faults = faults()
		wall = time.tick_now()
		for zt.maintenance_pending() {
			start := time.tick_now()
			released := zt.maintenance_release()
			record(&p, time.tick_since(start), h)
			p.released_bytes += released
			p.max_release_bytes = max(p.max_release_bytes, released)
		}
		p.service_wall_ns = i64(time.tick_since(wall))
		p.minor_faults = faults() - before_faults
		p.after = bank_state(h)
		append(&result.phases, p)
	}
}

direct_main :: proc() {
	assert(len(os.args) == 4)
	n, ok := strconv.parse_int(os.args[1])
	assert(ok && n >= 12 && n % 3 == 0)
	samples, got_samples := strconv.parse_int(os.args[3])
	assert(got_samples && samples > 0)
	mode := os.args[2]
	random := mode == "random-settled" || mode == "random-active" || mode == "random-rank"
	assert(random || mode == "grow" || mode == "quiet" || mode == "shrink" || mode == "score-update")
	zt.set_seed(0x738A0E43)
	h := make_initial(n)
	result := Result{bounded = BOUNDED, initial_members = n, initial_cap = h.sl.cap, read_samples = min(n, samples)}
	clock_baseline(&result)
	buf: [32]u8
	if random || mode == "score-update" {
		trigger := Phase{name = "growth-before-read-or-score-update", before = bank_state(h)}
		member := key(buf[:], n)
		before_faults := faults()
		start := time.tick_now()
		add_member(h, member, f64(n))
		record(&trigger, time.tick_since(start), h)
		trigger.minor_faults = faults() - before_faults
		trigger.after = bank_state(h)
		append(&result.phases, trigger)
		assert(h.sl.length == n + 1)
		when BOUNDED {
			assert(active(h))
		}
		if mode == "random-settled" {
			drain(h, &result)
			assert(!active(h))
		}
	}
	p := Phase{name = mode, before = bank_state(h)}
	reserve(&p.nanoseconds, n if mode == "score-update" || !random else result.read_samples)
	sample(&p, h)
	before_faults := faults()
	wall := time.tick_now()
	if random {
		for _ in 0 ..< result.read_samples {
			p.active_calls += int(active(h))
			start := time.tick_now()
			node: ^zt.Node
			when BOUNDED {
				node = zt.dict_random_node(h.sl, 0) if mode == "random-rank" else zt.dict_random_node(h.sl)
			} else {
				assert(mode != "random-rank")
				node = zt.dict_random_node(h.sl)
			}
			record(&p, time.tick_since(start), h)
			assert(node != nil && zt.dict_find(h.sl, zt.node_member(node), node.hash) == node)
			assert(node.score >= 0 && node.score <= f64(n))
			result.checksum += node.score
		}
	} else if mode == "score-update" {
		for i in 0 ..< n {
			member := key(buf[:], i)
			node := zt.dict_find(h.sl, member, zt.hash_member(member))
			was_active := active(h)
			p.active_calls += int(was_active)
			start := time.tick_now()
			out, _, added := zt.add(h, f64(n + 1 + i), member, {})
			record(&p, time.tick_since(start), h)
			assert(added && .Updated in out && zt.dict_find(h.sl, member, node.hash) == node)
			assert(node.score == f64(n + 1 + i))
			if was_active && !active(h) {
				p.completed_after_calls = i + 1
			}
		}
		assert(!active(h) && h.sl.length == n + 1)
	} else if mode == "shrink" {
		first := n - h.sl.cap / 8 - 1
		for i in 0 ..< first {
			assert(zt.del(h, key(buf[:], i)))
		}
		p.before = bank_state(h)
		before_faults = faults()
		wall = time.tick_now()
		for i in first ..< n {
			member := key(buf[:], i)
			p.active_calls += int(active(h))
			start := time.tick_now()
			removed := zt.del(h, member)
			record(&p, time.tick_since(start), h)
			assert(removed)
		}
		assert(h.sl.length == 0 && h.sl.count == 0)
	} else {
		calls := n / 3 if mode == "grow" else 1
		for i in n ..< n + calls {
			member := key(buf[:], i)
			p.active_calls += int(active(h))
			start := time.tick_now()
			add_member(h, member, f64(i))
			record(&p, time.tick_since(start), h)
		}
	}
	p.service_wall_ns = i64(time.tick_since(wall))
	p.minor_faults = faults() - before_faults
	p.after = bank_state(h)
	if random {
		assert(p.before == p.after)
	}
	append(&result.phases, p)
	drain(h, &result)
	zt.destroy(h)
	emit(&result)
}

when HOST {
	VERSION :: "zset-resize-bench"

	host_main :: proc() {
		assert(len(os.args) == 4)
		n, ok := strconv.parse_int(os.args[1])
		assert(ok && n >= 12)
		config_init()
		update_clock()
		db_init()
		expiry_sweep_on = false
		zt.set_seed(0x738A0E43)
		h := make_initial(n)
		h.acct = zt.memory_usage(h)
		e, _ := db_upsert(bytes("zset-bench"))
		entry_object_attach(e, h, .Zset, .Skiplist, h.acct)
		result := Result{bounded = true, initial_members = n, initial_cap = h.sl.cap}
		clock_baseline(&result)
		small_retired := os.args[2] == "host-small-retired"
		assert(small_retired || os.args[2] == "host-tick")
		small: [64]zt.Zset
		trigger := Phase{name = "core-trigger-and-host-accounting", before = bank_state(h)}
		buf: [32]u8
		member := key(buf[:], n)
		start := time.tick_now()
		if small_retired {
			for i in 0 ..< len(small) {
				s := zt.create_skiplist(512)
				assert(s.sl.cap == 1024)
				for j in 0 ..< 512 {
					add_member(s, key(buf[:], j), f64(j))
				}
				zt.dict_resize(s.sl, 2048)
				for s.sl.resize != nil {
					zt.dict_step(s.sl, 64, 4)
				}
				assert(s.sl.cap == 2048 && s.sl.length == 512 && s.sl.count == 512)
				s.acct = zt.memory_usage(s)
				small_entry, _ := db_upsert(bytes(fmt.bprintf(buf[:], "r:%02d", i)))
				entry_object_attach(small_entry, s, .Zset, .Skiplist, s.acct)
				zset_bench_sync(s)
				small[i] = s
			}
			trigger.name = "prepare-64-live-targets-and-small-retired-arrays"
			_, retired, _ := zt.maintenance_memory()
			result.retirement_fixture = Retirement_Fixture{records = 64, source_cap = 1024, target_cap = 2048, live_per_target = 512, source_bytes = 8192, expected_bytes = 64 * 8192, before_records = bank_state(h).retired_records, before_retired = retired}
			assert(result.retirement_fixture.before_records == 64 && retired == 64 * 8192 && db_cur.zctx.resize_count == 0)
		} else {
			add_member(h, member, f64(n))
			zset_bench_sync(h)
			assert(h.sl.resize != nil && h.sl.resize.reg == db_cur.zctx && db_cur.zctx.resize_count == 1)
		}
		record(&trigger, time.tick_since(start), h)
		trigger.after = bank_state(h)
		append(&result.phases, trigger)
		p := Phase{name = "actual-host-zset_resize_tick", before = bank_state(h)}
		if small_retired {
			p.name = "actual-host-small-retired-records"
			p.release_work_measured = true
		}
		reserve(&p.nanoseconds, n)
		sample(&p, h)
		before_faults := faults()
		wall := time.tick_now()
		for zt.maintenance_pending() {
			_, before_retired, _ := zt.maintenance_memory()
			start = time.tick_now()
			zset_resize_tick()
			record(&p, time.tick_since(start), h)
			if small_retired {
				_, after_retired, _ := zt.maintenance_memory()
				released := before_retired - after_retired
				assert(released > 0 && released <= zt.RESIZE_RELEASE_CALLS * 8192 && db_cur.zctx.resize_count == 0)
				p.released_bytes += released
				p.max_release_bytes = max(p.max_release_bytes, released)
			}
			owner_bytes := zt.memory_usage(h)
			assert(h.acct == owner_bytes)
			for s in small {
				if s != nil {
					assert(s.acct == zt.memory_usage(s) && s.sl.resize == nil && s.sl.cap == 2048 && s.sl.length == 512)
					owner_bytes += s.acct
				}
			}
			assert(db_cur.heap_bytes == owner_bytes)
		}
		p.service_wall_ns = i64(time.tick_since(wall))
		p.minor_faults = faults() - before_faults
		p.after = bank_state(h)
		if small_retired {
			_, retired, _ := zt.maintenance_memory()
			result.retirement_fixture.after_records = p.after.retired_records
			result.retirement_fixture.after_retired = retired
			result.retirement_fixture.actual_released = p.released_bytes
			assert(p.released_bytes == 64 * 8192 && retired == 0 && p.after.retired_records == 0)
		}
		append(&result.phases, p)
		db_flush_all(false)
		for dead_len > 0 || graveyard_len > 0 || zt.maintenance_pending() {
			db_tick()
		}
		emit(&result)
	}
}

main :: proc() {
	when HOST {
		host_main()
	} else {
		direct_main()
	}
}
