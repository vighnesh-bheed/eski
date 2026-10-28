package main

import "core:math"

Evict_Policy :: enum u8 {
	Volatile_Lru,
	Volatile_Lfu,
	Volatile_Random,
	Volatile_Ttl,
	Allkeys_Lru,
	Allkeys_Lfu,
	Allkeys_Random,
	Noeviction,
}

EVICT_POLICY_NAMES := [Evict_Policy]string {
	.Volatile_Lru    = "volatile-lru",
	.Volatile_Lfu    = "volatile-lfu",
	.Volatile_Random = "volatile-random",
	.Volatile_Ttl    = "volatile-ttl",
	.Allkeys_Lru     = "allkeys-lru",
	.Allkeys_Lfu     = "allkeys-lfu",
	.Allkeys_Random  = "allkeys-random",
	.Noeviction      = "noeviction",
}

ERR_EVICT_POLICY :: "argument(s) must be one of the following: volatile-lru, volatile-lfu, volatile-random, volatile-ttl, allkeys-lru, allkeys-lfu, allkeys-random, noeviction"
EVPOOL_SIZE :: 16
EVICT_CHECK_EVERY :: 16

Evict_Result :: enum u8 {
	Ok,
	Running,
	Fail,
}

maxmemory_policy := Evict_Policy.Noeviction
maxmemory_samples := 5
stat_evicted_keys: i64
stat_evicted_clients: i64
stat_eviction_exceeded_us: i64
stat_eviction_exceeded_since: i64
evict_no_shared_ints: bool
evict_timer: bool

@(private = "file")
Pool_Entry :: struct {
	idle: u64,
	key:  [dynamic]u8,
	dbid: int,
	used: bool,
}

@(private = "file")
evict_pool: [EVPOOL_SIZE]Pool_Entry
@(private = "file")
evict_samples: [64]Evict_Sample
@(private = "file")
evict_next_db: int
@(private = "file")
evict_key: [dynamic]u8

evict_policy_parse :: proc(s: []u8) -> (Evict_Policy, bool) {
	for name, p in EVICT_POLICY_NAMES {
		if eq_nocase(s, name) {
			return p, true
		}
	}
	return .Noeviction, false
}

evict_policy_changed :: proc() {
	lfu_policy = maxmemory_policy == .Volatile_Lfu || maxmemory_policy == .Allkeys_Lfu
	evict_no_shared_ints = maxmemory_bytes != 0 && maxmemory_policy != .Noeviction && maxmemory_policy != .Volatile_Random && maxmemory_policy != .Allkeys_Random && maxmemory_policy != .Volatile_Ttl
}

shared_int_ok :: #force_inline proc "contextless" (v: []u8) -> bool {
	n, ok := parse_i64(v)
	return !ok || n < 0 || n >= OBJ_SHARED_INTEGERS
}

@(private = "file")
evict_volatile :: #force_inline proc() -> bool {
	return maxmemory_policy <= .Volatile_Ttl
}

@(private = "file")
evict_time_limit_us :: proc() -> i64 {
	t := cfg.maxmemory_eviction_tenacity
	if t <= 10 {
		return 50 * t
	}
	if t < 100 {
		return i64(500.0 * math.pow(1.15, f64(t) - 10.0))
	}
	return max(i64)
}

memory_state_over :: #force_inline proc "contextless" () -> (over: bool, tofree: int) {
	if maxmemory_bytes == 0 {
		return
	}
	reported := mem_used()
	if u64(reported) <= maxmemory_bytes {
		return
	}
	used := max(reported - mem_not_counted(), 0)
	if u64(used) <= maxmemory_bytes {
		return
	}
	return true, used - int(maxmemory_bytes)
}

@(private = "file")
evict_memory_ok :: proc() -> bool {
	over, _ := memory_state_over()
	return !over
}

@(private = "file")
evict_pool_insert :: proc(dbid: int, s: Evict_Sample) {
	pool := &evict_pool
	k := 0
	for k < EVPOOL_SIZE && pool[k].used && pool[k].idle < s.score {
		k += 1
	}
	if k == 0 && pool[EVPOOL_SIZE - 1].used {
		return
	}
	if k < EVPOOL_SIZE && !pool[k].used {
	} else if !pool[EVPOOL_SIZE - 1].used {
		spare := pool[EVPOOL_SIZE - 1].key
		for j := EVPOOL_SIZE - 1; j > k; j -= 1 {
			pool[j] = pool[j - 1]
		}
		pool[k].key = spare
	} else {
		k -= 1
		spare := pool[0].key
		for j in 0 ..< k {
			pool[j] = pool[j + 1]
		}
		pool[k].key = spare
	}
	clear(&pool[k].key)
	append(&pool[k].key, ..s.key)
	pool[k].idle = s.score
	pool[k].dbid = dbid
	pool[k].used = true
}

@(private = "file")
evict_pool_populate :: proc(db: ^Db, volatile: bool) {
	score: Evict_Score
	#partial switch maxmemory_policy {
	case .Volatile_Lru, .Allkeys_Lru:
		score = .Lru
	case .Volatile_Lfu, .Allkeys_Lfu:
		score = .Lfu
	case:
		score = .Ttl
	}
	n := db_evict_sample(db, evict_samples[:maxmemory_samples], volatile, score)
	for i in 0 ..< n {
		evict_pool_insert(db.id, evict_samples[i])
	}
}

@(private = "file")
evict_pick_pool :: proc() -> (db: ^Db, found: bool) {
	volatile := evict_volatile()
	for !found {
		total := 0
		for &d in dbs {
			keys := d.expires if volatile else db_size_of(&d)
			if keys == 0 {
				continue
			}
			total += keys
			evict_pool_populate(&d, volatile)
		}
		if total == 0 {
			return nil, false
		}
		for k := EVPOOL_SIZE - 1; k >= 0; k -= 1 {
			p := &evict_pool[k]
			if !p.used {
				continue
			}
			p.used = false
			p.idle = 0
			d := &dbs[p.dbid]
			if db_evict_has(d, p.key[:], volatile) {
				clear(&evict_key)
				append(&evict_key, ..p.key[:])
				return d, true
			}
		}
	}
	return
}

@(private = "file")
evict_pick_random :: proc() -> (db: ^Db, found: bool) {
	n := len(dbs)
	volatile := evict_volatile()
	for _ in 0 ..< n {
		evict_next_db = (evict_next_db + 1) % n
		d := &dbs[evict_next_db]
		key: []u8
		ok: bool
		if volatile {
			if d.expires == 0 {
				continue
			}
			ok = db_evict_sample(d, evict_samples[:1], true, .Ttl) == 1
			key = evict_samples[0].key
		} else {
			_, key, ok = db_sample_key(d)
		}
		if ok {
			clear(&evict_key)
			append(&evict_key, ..key)
			return d, true
		}
	}
	return nil, false
}

@(private = "file")
evict_delete :: proc(db: ^Db) -> int {
	before := mem_used()
	saved := lazy_set(cfg.lazyfree_lazy_eviction)
	del_start := latency_start()
	db_remove_in(db, evict_key[:])
	latency_end("eviction-del", del_start)
	lazy_mode = saved
	freed := before - mem_used()
	stat_evicted_keys += 1
	signal_key_expired(evict_key[:], db)
	notify_in(.Evicted, "evicted", evict_key[:], db)
	if aof.feed {
		aof_propagate_del(db, evict_key[:], cfg.lazyfree_lazy_eviction)
	}
	return freed
}

@(private = "file")
evict_update_metrics :: proc(r: Evict_Result) -> Evict_Result {
	if r == .Ok {
		if stat_eviction_exceeded_since != 0 {
			stat_eviction_exceeded_us += (now_ns() - stat_eviction_exceeded_since) / 1000
			stat_eviction_exceeded_since = 0
		}
	} else if stat_eviction_exceeded_since == 0 {
		stat_eviction_exceeded_since = now_ns()
	}
	return r
}

eviction_exceeded_current_us :: proc() -> i64 {
	if stat_eviction_exceeded_since == 0 {
		return 0
	}
	return (now_ns() - stat_eviction_exceeded_since) / 1000
}

eviction_exceeded_total_us :: proc() -> i64 {
	return stat_eviction_exceeded_us + eviction_exceeded_current_us()
}

perform_evictions :: proc() -> Evict_Result {
	if aof.loading || srv.pause_end_ms > srv.now_ms {
		return .Ok
	}
	over, tofree := memory_state_over()
	if !over {
		return evict_update_metrics(.Ok)
	}
	slab_checked := false
	if slab_zero_slabs > 0 {
		slab_checked = true
		slab_reclaim(now_ns() + WARM_BUSY_TICK_NS, true)
		over, tofree = memory_state_over()
		if !over {
			return evict_update_metrics(.Ok)
		}
	}
	if maxmemory_policy == .Noeviction {
		db_pressure_shrink(now_ns() + WARM_BUSY_TICK_NS)
		if evict_memory_ok() {
			return evict_update_metrics(.Ok)
		}
		return evict_update_metrics(.Fail)
	}
	limit := evict_time_limit_us()
	start := now_ns()
	cycle_start := latency_start()
	freed := 0
	keys := 0
	exhausted := false
	random := maxmemory_policy == .Allkeys_Random || maxmemory_policy == .Volatile_Random
	for freed < tofree {
		db: ^Db
		found: bool
		if random {
			db, found = evict_pick_random()
		} else {
			db, found = evict_pick_pool()
		}
		if !found {
			exhausted = true
			break
		}
		freed += evict_delete(db)
		if !slab_checked && slab_zero_slabs > 0 {
			slab_checked = true
			slab_before := mem_used()
			slab_reclaim(now_ns() + WARM_BUSY_TICK_NS, true)
			freed += slab_before - mem_used()
		}
		keys += 1
		if keys % EVICT_CHECK_EVERY == 0 {
			if evict_memory_ok() {
				break
			}
			if (now_ns() - start) / 1000 > limit {
				evict_timer = true
				break
			}
		}
	}
	result := Evict_Result.Fail
	if !exhausted {
		result = .Running if evict_timer else .Ok
	} else {
		lazy_start := latency_start()
		db_pressure_shrink(now_ns() + WARM_BUSY_TICK_NS)
		if evict_memory_ok() || lazyfree_wait(limit - (now_ns() - start) / 1000, evict_memory_ok) {
			result = .Ok
		}
		latency_end("eviction-lazyfree", lazy_start)
	}
	latency_end("eviction-cycle", cycle_start)
	return evict_update_metrics(result)
}

evict_timer_step :: proc() {
	if perform_evictions() != .Running {
		evict_timer = false
	}
}

evict_reset_stats :: proc() {
	stat_evicted_keys = 0
	stat_evicted_clients = 0
	stat_eviction_exceeded_us = 0
	stat_eviction_exceeded_since = 0
}
