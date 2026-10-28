package main

import st "../../src/settype"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/linux"
import "core:time"

BOUNDED :: #config(SET_BOUNDED, false)
HOST :: #config(SET_HOST, false)

Phase :: struct {
	name:              string,
	migration_work_measured: bool,
	release_work_measured: bool,
	released_bytes: int,
	max_release_bytes: int,
	nanoseconds:       [dynamic]i64,
	allocated_peak:    int,
	mapped_peak:       int,
	retired_peak:      int,
	metadata_peak:     int,
	minor_faults:      int,
	scanned:           int,
	moved:             int,
	probes:            int,
	max_grant_scanned: int,
	max_grant_moved:   int,
}

Result :: struct {
	bounded:        bool,
	initial_fields: int,
	initial_cap:    int,
	phases:         [dynamic]Phase,
}

bytes :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

key :: proc(buf: []u8, i: int) -> []u8 {
	return bytes(fmt.bprintf(buf, "field:%012d", i))
}

faults :: proc() -> int {
	r: linux.RUsage
	assert(linux.getrusage(.SELF, &r) == .NONE)
	return r.minflt_word
}

sample :: proc(p: ^Phase, h: st.Set) {
	p.allocated_peak = max(p.allocated_peak, st.memory_usage(h))
	when BOUNDED {
		mapped, retired, metadata := st.maintenance_memory()
		p.mapped_peak = max(p.mapped_peak, mapped)
		p.retired_peak = max(p.retired_peak, retired)
		p.metadata_peak = max(p.metadata_peak, metadata)
	}
}

record :: proc(p: ^Phase, elapsed: time.Duration, h: st.Set) {
	append(&p.nanoseconds, i64(elapsed))
	sample(p, h)
}

direct_main :: proc() {
	assert(len(os.args) == 3)
	n, ok := strconv.parse_int(os.args[1])
	assert(ok && n >= 12 && n % 3 == 0)
	mode := os.args[2]
	assert(mode == "grow" || mode == "shrink" || mode == "quiet")
	st.set_hash_seed(0x738A0E43)
	h := st.create_table(n - 1)
	buf: [32]u8
	for i in 0 ..< n {
		st.add(h, key(buf[:], i))
	}
	result := Result{bounded = BOUNDED, initial_fields = n, initial_cap = h.table.cap}
	assert(n == h.table.cap / 4 * 3)
	when BOUNDED {
		assert(h.table.resize == nil)
		for st.maintenance_pending() {
			st.maintenance_release()
		}
	}
	p := Phase{name = mode}
	reserve(&p.nanoseconds, n)
	sample(&p, h)
	before_faults := faults()
	if mode == "shrink" {
		first := n - h.table.cap / 8 - 1
		for i in 0 ..< first {
			st.remove(h, key(buf[:], i))
		}
		before_faults = faults()
		for i in first ..< n {
			field := key(buf[:], i)
			start := time.tick_now()
			st.remove(h, field)
			record(&p, time.tick_since(start), h)
		}
	} else {
		calls := n / 3 if mode == "grow" else 1
		for i in n ..< n + calls {
			field := key(buf[:], i)
			start := time.tick_now()
			st.add(h, field)
			record(&p, time.tick_since(start), h)
		}
	}
	p.minor_faults = faults() - before_faults
	append(&result.phases, p)
	when BOUNDED {
		quiet := Phase{name = "direct-foreground-grants-64-scans-4-moves", migration_work_measured = true}
		before_faults = faults()
		for h.table.resize != nil {
			start := time.tick_now()
			work := st.table_step(h.table, st.RESIZE_WRITE_SCANS, st.RESIZE_WRITE_MOVES)
			record(&quiet, time.tick_since(start), h)
			quiet.scanned += work.scanned
			quiet.moved += work.moved
			quiet.probes += work.probes
			quiet.max_grant_scanned = max(quiet.max_grant_scanned, work.scanned)
			quiet.max_grant_moved = max(quiet.max_grant_moved, work.moved)
		}
		quiet.minor_faults = faults() - before_faults
		append(&result.phases, quiet)
		release := Phase{name = "direct-release-2MiB-16-calls", release_work_measured = true}
		before_faults = faults()
		for st.maintenance_pending() {
			start := time.tick_now()
			released := st.maintenance_release()
			release.released_bytes += released
			release.max_release_bytes = max(release.max_release_bytes, released)
			record(&release, time.tick_since(start), h)
		}
		release.minor_faults = faults() - before_faults
		append(&result.phases, release)
	}
	out, err := json.marshal(result)
	assert(err == nil)
	fmt.println(string(out))
	delete(out)
	st.destroy(h)
	for phase in result.phases {
		delete(phase.nanoseconds)
	}
	delete(result.phases)
}

when HOST {
	VERSION :: "set-resize-bench"

	host_main :: proc() {
		assert(len(os.args) == 3)
		n, ok := strconv.parse_int(os.args[1])
		assert(ok && n >= 12)
		config_init()
		update_clock()
		db_init()
		active_expire_enabled = false
		st.set_hash_seed(0x738A0E43)
		h := st.create_table(n - 1)
		buf: [32]u8
		for i in 0 ..< n {
			st.add(h, key(buf[:], i))
		}
		assert(n == h.table.cap / 4 * 3 && h.table.resize == nil)
		h.acct = st.memory_usage(h)
		e, _ := db_upsert(bytes("set-bench"))
		entry_object_attach(e, h, .Set, .Hashtable, h.acct)
		result := Result{bounded = true, initial_fields = n, initial_cap = h.table.cap}
		small_retired := os.args[2] == "host-small-retired"
		trigger := Phase{name = "core-trigger-and-host-accounting"}
		field := key(buf[:], n)
		start := time.tick_now()
		if small_retired {
			for _ in 0 ..< 64 {
				t := st.table_make(256)
				st.table_add(t, bytes("one"))
				st.table_resize(t, 1024)
				for t.resize != nil {
					st.table_step(t, 64, 4)
				}
				st.table_free(t)
			}
			trigger.name = "prepare-64-small-retired-arrays"
		} else {
			st.add(h, field)
			set_bench_sync(h)
		}
		record(&trigger, time.tick_since(start), h)
		append(&result.phases, trigger)
		p := Phase{name = "actual-host-set_resize_tick"}
		if small_retired {
			p.name = "actual-host-small-retired-records"
			p.release_work_measured = true
		}
		reserve(&p.nanoseconds, n)
		sample(&p, h)
		before_faults := faults()
		for st.maintenance_pending() {
			_, before_retired, _ := st.maintenance_memory()
			start = time.tick_now()
			set_resize_tick()
			record(&p, time.tick_since(start), h)
			if small_retired {
				_, after_retired, _ := st.maintenance_memory()
				released := before_retired - after_retired
				assert(released > 0 && released <= st.RESIZE_RELEASE_CALLS * 8192)
				p.released_bytes += released
				p.max_release_bytes = max(p.max_release_bytes, released)
			}
			assert(h.acct == st.memory_usage(h) && db_cur.heap_bytes == h.acct)
		}
		p.minor_faults = faults() - before_faults
		append(&result.phases, p)
		out, err := json.marshal(result)
		assert(err == nil)
		fmt.println(string(out))
		delete(out)
		db_flush_all(false)
		for phase in result.phases {
			delete(phase.nanoseconds)
		}
		delete(result.phases)
	}
}

main :: proc() {
	when HOST {
		host_main()
	} else {
		direct_main()
	}
}
