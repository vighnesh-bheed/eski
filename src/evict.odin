package main

import "base:intrinsics"
import "core:bytes"
import "core:math"
import lb "label"

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
REQUEST_ARGUMENT_BYTES :: 32
QUEUED_COMMAND_BYTES :: 20

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
memory_arrival_over: bool

@(private = "file")
Pool_Entry :: struct {
	idle: u64,
	key:  [dynamic]u8,
	db:   ^Db,
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
@(private = "file")
evict_arriving: int

evict_pool_forget :: proc(db: ^Db) {
	for &pe in evict_pool {
		if pe.db == db {
			pe.used = false
			pe.idle = 0
			pe.db = nil
		}
	}
}

@(private = "file")
@(cold)
evict_owner_draws :: #force_no_inline proc(volatile: bool, shared: int) -> int {
	weight := Owner_Weight.Expires if volatile else .Keys
	if owner_sampler[weight].mass == 0 {
		return 0
	}
	owned := owner_expires_total if volatile else owner_keys_total
	if owned <= 0 {
		return 0
	}
	draws := max(1, (maxmemory_samples * owned + owned + shared - 1) / max(owned + shared, 1))
	for _ in 0 ..< draws {
		p := owner_sampler_pick(weight)
		if p == nil {
			break
		}
		evict_pool_populate(owner_db(p), volatile)
	}
	return owned
}

evict_policy_parse :: proc(s: []u8) -> (Evict_Policy, bool) {
	for name, p in EVICT_POLICY_NAMES {
		if eq_nocase(s, name) {
			return p, true
		}
	}
	return .Noeviction, false
}

evict_policy_changed :: proc() {
	counts_hits, ranks_by_access := false, false
	switch maxmemory_policy {
	case .Volatile_Lfu, .Allkeys_Lfu:
		counts_hits, ranks_by_access = true, true
	case .Volatile_Lru, .Allkeys_Lru:
		ranks_by_access = true
	case .Volatile_Random, .Volatile_Ttl, .Allkeys_Random, .Noeviction:
	}
	access_counts_hits = counts_hits
	evict_no_shared_ints = ranks_by_access && maxmemory_bytes != 0
}

shared_int_ok :: #force_inline proc "contextless" (v: []u8) -> bool {
	n, ok := parse_i64(v)
	return !ok || n < 0 || n >= SHARED_INTEGER_LIMIT
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

request_bytes :: #force_inline proc "contextless" (argv: [][]u8) -> (total: int) {
	for a in argv {
		total += len(a) + REQUEST_ARGUMENT_BYTES
	}
	return
}

memory_state_over :: #force_inline proc "contextless" () -> (over: bool, tofree: int) {
	if maxmemory_bytes == 0 {
		return
	}
	reported := mem_used() + evict_arriving + tx_queued_extra
	if u64(reported) <= maxmemory_bytes {
		return
	}
	used := max(reported - mem_not_counted(), 0)
	if u64(used) <= maxmemory_bytes {
		return
	}
	return true, used - int(maxmemory_bytes)
}

memory_state_over_current :: #force_inline proc "contextless" (arriving := 0) -> bool {
	if maxmemory_bytes == 0 || u64(mem_used_current() + arriving + tx_queued_extra) <= maxmemory_bytes {
		return false
	}
	return memory_state_over_exact(arriving)
}

@(cold)
memory_state_over_exact :: #force_no_inline proc "contextless" (arriving: int) -> bool {
	saved := evict_arriving
	evict_arriving = arriving
	over, _ := memory_state_over()
	evict_arriving = saved
	return over
}

@(private = "file")
evict_memory_ok :: proc() -> bool {
	over, _ := memory_state_over()
	return !over
}

@(private = "file")
evict_pool_insert :: proc(db: ^Db, s: Evict_Sample) {
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
	pool[k].db = db
	pool[k].used = true
}

@(private = "file")
evict_score :: #force_inline proc() -> Evict_Score {
	#partial switch maxmemory_policy {
	case .Volatile_Lru, .Allkeys_Lru:
		return .Lru
	case .Volatile_Lfu, .Allkeys_Lfu:
		return .Lfu
	}
	return .Ttl
}

@(private = "file")
evict_pool_populate :: proc(db: ^Db, volatile: bool) {
	score := evict_score()
	n := db_evict_sample(db, evict_samples[:maxmemory_samples], volatile, score)
	for i in 0 ..< n {
		evict_pool_insert(db, evict_samples[i])
	}
}

@(private = "file")
evict_pick_pool :: proc() -> (db: ^Db, found: bool) {
	volatile := evict_volatile()
	for !found {
		total := 0
		for d in db_parts {
			keys := d.expires if volatile else db_size_of(d)
			if keys == 0 {
				continue
			}
			total += keys
			evict_pool_populate(d, volatile)
		}
		if owners_on {
			total += evict_owner_draws(volatile, total)
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
			d := p.db
			if d != nil && db_evict_has(d, p.key[:], volatile) {
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
	n := len(db_parts)
	volatile := evict_volatile()
	if owners_on {
		if d := evict_random_owner(volatile); d != nil {
			key: []u8
			ok: bool
			if volatile {
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
	}
	for _ in 0 ..< n {
		evict_next_db = (evict_next_db + 1) % n
		d := db_parts[evict_next_db]
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
evict_random_owner :: proc(volatile: bool) -> ^Db {
	weight := Owner_Weight.Expires if volatile else .Keys
	if owner_sampler[weight].mass == 0 {
		return nil
	}
	owned := owner_expires_total if volatile else owner_keys_total
	shared := 0
	for d in db_parts {
		shared += d.expires if volatile else db_size_of(d)
	}
	if owned <= 0 || int(rng_next() % u64(owned + shared)) >= owned {
		return nil
	}
	p := owner_sampler_pick(weight)
	return owner_db(p) if p != nil else nil
}

@(private = "file")
evict_delete :: proc(db: ^Db) -> int {
	owned := db.role & DB_ROLE_OWNER != 0
	if owned {
		owner_touch(db)
	}
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
	if owned && !label_active {
		owner_settle()
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

perform_evictions :: proc(arriving := 0) -> Evict_Result {
	if aof.loading || pst.loading || srv.pause_end_ms > srv.now_ms {
		return .Ok
	}
	if !memory_state_over_current(arriving) {
		return evict_update_metrics(.Ok)
	}
	return evict_over_limit(arriving)
}

@(private = "file")
@(cold)
evict_over_limit :: #force_no_inline proc(arriving: int) -> Evict_Result {
	keyspace_fence()
	evict_arriving = arriving
	defer evict_arriving = 0
	over, tofree := memory_state_over()
	if !over {
		return evict_update_metrics(.Ok)
	}
	tracking_delivery := tracking_eviction_begin()
	defer if tracking_delivery { tracking_eviction_end() }
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

@(private = "file")
Quota_Evict_Sample :: struct {
	rank:  u64,
	score: u64,
	key:   []u8,
}

@(private = "file")
quota_sample_before :: proc(a, b: Quota_Evict_Sample) -> bool {
	return a.rank < b.rank || (a.rank == b.rank && bytes.compare(a.key, b.key) < 0)
}

@(private = "file")
quota_sample_db :: proc(db: ^Db, out: []Quota_Evict_Sample, seed: u64, volatile: bool, score: Evict_Score, random: bool) -> int #no_bounds_check {
	n := 0
	for k in 0 ..< 2 {
		if k == 1 && db.rehash_idx < 0 {
			break
		}
		t := &db.t[k]
		for group in 0 ..< t.groups {
			occupied := group_full(group_load(t.ctrl, group))
			for occupied != 0 {
				slot := int(group << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(occupied))
				occupied &= occupied - 1
				kh := &t.slots[slot].key
				if volatile && !key_timed(kh^) {
					continue
				}
				key := key_bytes(kh, &db.slab)
				sample := Quota_Evict_Sample{rank = hash_bytes_seeded(key, seed), key = key}
				at := n
				if n == len(out) {
					at -= 1
					if !quota_sample_before(sample, out[at]) {
						continue
					}
				} else {
					n += 1
				}
				for at > 0 && quota_sample_before(sample, out[at - 1]) {
					out[at] = out[at - 1]
					at -= 1
				}
				if !random {
					due := key_deadline(kh^, &db.slab) if score == .Ttl else 0
					sample.score = slot_evict_rank(t.slots[slot].meta, t.slots[slot].val, due, score)
				}
				out[at] = sample
			}
		}
	}
	return n
}

@(private = "file")
quota_sample_wins :: proc(sample, best: Quota_Evict_Sample, d, best_db: ^Db) -> bool {
	if sample.score != best.score {
		return sample.score > best.score
	}
	if sample.rank != best.rank {
		return sample.rank < best.rank
	}
	if cmp := bytes.compare(sample.key, best.key); cmp != 0 {
		return cmp < 0
	}
	return d.id < best_db.id || (d.id == best_db.id && label_less(d.label, best_db.label))
}

@(private = "file")
evict_quota_pick :: proc(parts: []^Db) -> ^Db {
	volatile := evict_volatile()
	random := maxmemory_policy == .Allkeys_Random || maxmemory_policy == .Volatile_Random
	limit := 1 if random else maxmemory_samples
	score := evict_score()
	samples: [64]Quota_Evict_Sample
	best: Quota_Evict_Sample
	best_db: ^Db
	seed: u64
	for d in parts {
		if (d.expires if volatile else db_size_of(d)) == 0 {
			continue
		}
		if best_db == nil {
			seed = rng_next()
		}
		marking, _ := access_label_of(d.label)
		part_seed := label_mix(seed ~ (u64(d.id)*WY_P1) ~ lb.label_hash(marking))
		n := quota_sample_db(d, samples[:limit], part_seed, volatile, score, random)
		for sample in samples[:n] {
			if best_db == nil || quota_sample_wins(sample, best, d, best_db) {
				best, best_db = sample, d
			}
		}
	}
	if best_db != nil {
		clear(&evict_key)
		append(&evict_key, ..best.key)
	}
	return best_db
}

evict_in_owner :: proc(e: ^Owner_Entry, quota, retained: i64) {
	if aof.loading || pst.loading || maxmemory_policy == .Noeviction {
		return
	}
	owned := make([dynamic]^Owner_Part, context.temp_allocator)
	owner_parts_of(e, &owned)
	parts := make([]^Db, len(owned), context.temp_allocator)
	for p, i in owned {
		parts[i] = owner_db(p)
	}
	for i64(owner_used_live(e)) - retained > quota {
		db := evict_quota_pick(parts)
		if db == nil {
			return
		}
		evict_delete(db)
	}
}

evict_in_label :: proc(label: lb.Id, quota: int) {
	if aof.loading || pst.loading || maxmemory_policy == .Noeviction {
		return
	}
	parts := make([dynamic]^Db, context.temp_allocator)
	for i in 0 ..< len(label_dbs) {
		if p := label_part(i, label); p != nil {
			append(&parts, p)
		}
	}
	for label_used(label) > quota {
		db := evict_quota_pick(parts[:])
		if db == nil {
			return
		}
		evict_delete(db)
	}
}
