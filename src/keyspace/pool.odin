package keyspace

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import "core:sys/linux"
import "core:thread"

CAPACITY :: 64
MAX_WORKERS :: 64

Op :: enum u8 {
	Get,
	Set,
}

Job_State :: enum u32 {
	Idle,
	Admitted,
	Queued,
	Running,
	Completed,
}

Value :: struct {
	pool:       ^Pool,
	refs:       u64,
	bytes:      []u8,
	allocation: []u8,
}

Record :: struct {
	db:          int,
	key:         string,
	owner:       int,
	caller_next: ^Record,
	exists:      bool,
	value:       ^Value,
	clock:       u32,
	changed:     bool,
	touched:     bool,
	pool:        ^Pool,
	allocation:  []u8,
}

Job :: struct {
	record:       ^Record,
	op:           Op,
	value:        ^Value,
	clock:        u32,
	touch:        bool,
	data:         rawptr,
	result:       ^Value,
	result_found: bool,
	elapsed_ns:   i64,
	state:        Job_State,
}

@(private)
Shard :: struct {
	ready:  sync.Cond,
	queued: [CAPACITY]^Job,
	head:   int,
	len:    int,
	parked: bool,
}

Pool :: struct {
	mutex:        sync.Mutex,
	quiescent:    sync.Cond,
	shards:       [MAX_WORKERS]Shard,
	threads:      [MAX_WORKERS]^thread.Thread,
	configured:   int,
	nthreads:     int,
	parked:       int,
	queued:       int,
	running:      int,
	initialized:  bool,
	accepting:    bool,
	paused:       bool,
	stopping:     bool,
	fd:           linux.Fd,
	completed:    [CAPACITY]^Job,
	done_head:    int,
	done_len:     int,
	outstanding:  int,
	records:      int,
	memory_limit: int,
	memory_bytes: int,
}

@(private)
Allocation_Header :: struct {
	pool:     ^Pool,
	charge:   int,
	size:     int,
	reserved: uintptr,
}

#assert(size_of(Allocation_Header) % 16 == 0)
#assert(align_of(Value) <= 16)
#assert(align_of(Record) <= 16)

@(private = "file")
clock_ns :: proc "contextless" () -> i64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return i64(ts.time_sec) * 1_000_000_000 + i64(ts.time_nsec)
}

memory_used :: proc "contextless" (p: ^Pool) -> int {
	return intrinsics.atomic_load_explicit(&p.memory_bytes, .Acquire) if p != nil else 0
}

allocate :: proc "contextless" (p: ^Pool, size: int) -> []u8 {
	if p == nil || size <= 0 || size > max(int) - size_of(Allocation_Header) {
		return nil
	}
	charge := size + size_of(Allocation_Header)
	sync.mutex_lock(&p.mutex)
	limit := p.memory_limit
	initialized := p.initialized
	sync.mutex_unlock(&p.mutex)
	if !initialized || charge > limit {
		return nil
	}
	used := intrinsics.atomic_load_explicit(&p.memory_bytes, .Relaxed)
	for {
		if used > limit - charge {
			return nil
		}
		previous, ok := intrinsics.atomic_compare_exchange_weak_explicit(&p.memory_bytes, used, used + charge, .Acq_Rel, .Relaxed)
		if ok {
			break
		}
		used = previous
	}
	base := runtime.heap_alloc(charge, false)
	if base == nil {
		intrinsics.atomic_sub_explicit(&p.memory_bytes, charge, .Release)
		return nil
	}
	header := cast(^Allocation_Header)base
	header^ = Allocation_Header{pool = p, charge = charge, size = size}
	payload := cast([^]u8)(uintptr(base) + uintptr(size_of(Allocation_Header)))
	return payload[:size]
}

free :: proc "contextless" (p: ^Pool, region: []u8) -> bool {
	if len(region) == 0 {
		return true
	}
	if p == nil {
		return false
	}
	header := cast(^Allocation_Header)(uintptr(raw_data(region)) - uintptr(size_of(Allocation_Header)))
	if header.pool != p || header.size != len(region) {
		return false
	}
	charge := header.charge
	runtime.heap_free(header)
	intrinsics.atomic_sub_explicit(&p.memory_bytes, charge, .Release)
	return true
}

value_new :: proc "contextless" (p: ^Pool, bytes: []u8) -> ^Value {
	if len(bytes) > max(int) - size_of(Value) {
		return nil
	}
	region := allocate(p, size_of(Value) + len(bytes))
	if len(region) == 0 {
		return nil
	}
	v := cast(^Value)raw_data(region)
	v^ = Value{pool = p, refs = 1, bytes = region[size_of(Value):], allocation = region}
	if len(bytes) > 0 {
		intrinsics.mem_copy_non_overlapping(raw_data(v.bytes), raw_data(bytes), len(bytes))
	}
	return v
}

value_data :: proc "contextless" (v: ^Value) -> []u8 {
	return v.bytes if v != nil else nil
}

value_retain :: proc "contextless" (v: ^Value) -> ^Value {
	if v != nil {
		intrinsics.atomic_add_explicit(&v.refs, 1, .Relaxed)
	}
	return v
}

value_release :: proc "contextless" (v: ^Value) {
	if v == nil {
		return
	}
	if intrinsics.atomic_sub_explicit(&v.refs, 1, .Acq_Rel) == 1 {
		p := v.pool
		region := v.allocation
		free(p, region)
	}
}

record_new :: proc "contextless" (p: ^Pool, db: int, key: []u8, owner: int, exists: bool, seed: []u8, lru: u32) -> ^Record {
	if p == nil || db < 0 || owner < 0 || len(key) > max(int) - size_of(Record) {
		return nil
	}
	sync.mutex_lock(&p.mutex)
	valid := p.initialized && owner < p.configured
	sync.mutex_unlock(&p.mutex)
	if !valid {
		return nil
	}
	region := allocate(p, size_of(Record) + len(key))
	if len(region) == 0 {
		return nil
	}
	seed_value: ^Value
	if exists {
		seed_value = value_new(p, seed)
		if seed_value == nil {
			free(p, region)
			return nil
		}
	}
	r := cast(^Record)raw_data(region)
	key_bytes := region[size_of(Record):]
	if len(key) > 0 {
		intrinsics.mem_copy_non_overlapping(raw_data(key_bytes), raw_data(key), len(key))
	}
	r^ = Record{db = db, key = transmute(string)key_bytes, owner = owner, exists = exists, value = seed_value, clock = lru, pool = p, allocation = region}
	sync.mutex_lock(&p.mutex)
	p.records += 1
	sync.mutex_unlock(&p.mutex)
	return r
}

record_free :: proc "contextless" (p: ^Pool, r: ^Record) -> bool {
	if r == nil {
		return true
	}
	if p == nil || r.pool != p {
		return false
	}
	sync.mutex_lock(&p.mutex)
	if !p.paused || p.accepting || p.queued != 0 || p.running != 0 || p.outstanding != 0 {
		sync.mutex_unlock(&p.mutex)
		return false
	}
	p.records -= 1
	sync.mutex_unlock(&p.mutex)
	value_release(r.value)
	region := r.allocation
	return free(p, region)
}

@(private = "file")
execute_job :: proc "contextless" (job: ^Job) {
	r := job.record
	switch job.op {
	case .Get:
		job.result_found = r.exists
		if r.exists {
			job.result = value_retain(r.value)
			if job.touch {
				r.clock = job.clock
				r.touched = true
			}
		}
	case .Set:
		old := r.value
		created := !r.exists
		r.value = value_retain(job.value)
		r.exists = true
		r.changed = true
		if created || job.touch {
			r.clock = job.clock
			r.touched = true
		}
		value_release(old)
		job.result_found = true
	}
}

@(private = "file")
notify_completion :: proc "contextless" (fd: linux.Fd) {
	one := u64(1)
	for {
		_, err := linux.write(fd, ([^]u8)(&one)[:size_of(one)])
		if err != .EINTR {
			return
		}
	}
}

@(private = "file")
worker_main :: proc(t: ^thread.Thread) {
	p := cast(^Pool)t.data
	shard := &p.shards[t.user_index]
	for {
		sync.mutex_lock(&p.mutex)
		for shard.len == 0 && !p.stopping {
			if !shard.parked {
				shard.parked = true
				p.parked += 1
				sync.cond_broadcast(&p.quiescent)
			}
			sync.cond_wait(&shard.ready, &p.mutex)
		}
		if shard.parked {
			shard.parked = false
			p.parked -= 1
		}
		if shard.len == 0 {
			sync.mutex_unlock(&p.mutex)
			return
		}
		job := shard.queued[shard.head]
		shard.queued[shard.head] = nil
		shard.head = (shard.head + 1) % CAPACITY
		shard.len -= 1
		p.queued -= 1
		p.running += 1
		intrinsics.atomic_store_explicit(&job.state, .Running, .Release)
		sync.mutex_unlock(&p.mutex)
		start := clock_ns()
		execute_job(job)
		job.elapsed_ns = max(clock_ns() - start, 0)
		sync.mutex_lock(&p.mutex)
		p.completed[(p.done_head + p.done_len) % CAPACITY] = job
		p.done_len += 1
		p.running -= 1
		intrinsics.atomic_store_explicit(&job.state, .Completed, .Release)
		sync.mutex_unlock(&p.mutex)
		notify_completion(p.fd)
	}
}

init :: proc(p: ^Pool, workers, max_memory: int) -> bool {
	if p == nil || workers < 1 || workers > MAX_WORKERS || max_memory < 0 {
		return false
	}
	sync.mutex_lock(&p.mutex)
	if p.initialized || p.nthreads != 0 || p.outstanding != 0 || p.records != 0 || memory_used(p) != 0 {
		sync.mutex_unlock(&p.mutex)
		return false
	}
	fd, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if err != .NONE {
		sync.mutex_unlock(&p.mutex)
		return false
	}
	p.fd = fd
	p.configured = workers
	p.memory_limit = max_memory
	p.initialized = true
	p.paused = true
	p.accepting = false
	p.stopping = false
	sync.mutex_unlock(&p.mutex)
	if !resume(p) {
		destroy(p)
		return false
	}
	return true
}

resume :: proc(p: ^Pool) -> bool {
	if p == nil {
		return false
	}
	sync.mutex_lock(&p.mutex)
	if !p.initialized || !p.paused && !p.accepting {
		sync.mutex_unlock(&p.mutex)
		return false
	}
	if p.accepting {
		sync.mutex_unlock(&p.mutex)
		return true
	}
	workers := p.configured
	if p.nthreads != 0 {
		p.paused = false
		p.accepting = true
		sync.mutex_unlock(&p.mutex)
		return true
	}
	p.stopping = false
	sync.mutex_unlock(&p.mutex)
	for i in 0 ..< workers {
		t := thread.create(worker_main, name = "eski-keyspace")
		if t == nil {
			stop(p)
			return false
		}
		t.data = p
		t.user_index = i
		sync.mutex_lock(&p.mutex)
		p.threads[i] = t
		p.nthreads = i + 1
		sync.mutex_unlock(&p.mutex)
		thread.start(t)
	}
	sync.mutex_lock(&p.mutex)
	p.paused = false
	p.accepting = true
	sync.mutex_unlock(&p.mutex)
	return true
}

submit :: proc "contextless" (p: ^Pool, job: ^Job) -> bool {
	if p == nil || job == nil {
		return false
	}
	_, claimed := intrinsics.atomic_compare_exchange_strong_explicit(&job.state, .Idle, .Admitted, .Acquire, .Relaxed)
	if !claimed {
		return false
	}
	sync.mutex_lock(&p.mutex)
	r := job.record
	valid := p.accepting && p.outstanding < CAPACITY && r != nil && r.pool == p && r.owner >= 0 && r.owner < p.configured && job.result == nil
	if job.op == .Set {
		valid = valid && job.value != nil && job.value.pool == p
	} else if job.op == .Get {
		valid = valid && job.value == nil
	} else {
		valid = false
	}
	if !valid {
		sync.mutex_unlock(&p.mutex)
		intrinsics.atomic_store_explicit(&job.state, .Idle, .Release)
		return false
	}
	job.result_found = false
	job.elapsed_ns = 0
	shard := &p.shards[r.owner]
	shard.queued[(shard.head + shard.len) % CAPACITY] = job
	shard.len += 1
	p.queued += 1
	p.outstanding += 1
	intrinsics.atomic_store_explicit(&job.state, .Queued, .Release)
	sync.cond_signal(&shard.ready)
	sync.mutex_unlock(&p.mutex)
	return true
}

poll :: proc "contextless" (p: ^Pool) -> ^Job {
	if p == nil {
		return nil
	}
	sync.mutex_lock(&p.mutex)
	if p.done_len == 0 {
		sync.mutex_unlock(&p.mutex)
		return nil
	}
	job := p.completed[p.done_head]
	p.completed[p.done_head] = nil
	p.done_head = (p.done_head + 1) % CAPACITY
	p.done_len -= 1
	p.outstanding -= 1
	intrinsics.atomic_store_explicit(&job.state, .Idle, .Release)
	sync.mutex_unlock(&p.mutex)
	return job
}

pause :: proc "contextless" (p: ^Pool) {
	if p == nil {
		return
	}
	sync.mutex_lock(&p.mutex)
	p.accepting = false
	for p.queued != 0 || p.running != 0 || p.parked != p.nthreads {
		sync.cond_wait(&p.quiescent, &p.mutex)
	}
	p.paused = true
	sync.mutex_unlock(&p.mutex)
}

stop :: proc(p: ^Pool) {
	if p == nil {
		return
	}
	pause(p)
	sync.mutex_lock(&p.mutex)
	p.stopping = true
	n := p.nthreads
	for i in 0 ..< n {
		sync.cond_broadcast(&p.shards[i].ready)
	}
	sync.mutex_unlock(&p.mutex)
	for i in 0 ..< n {
		t := p.threads[i]
		thread.join(t)
		thread.destroy(t)
		p.threads[i] = nil
	}
	sync.mutex_lock(&p.mutex)
	p.nthreads = 0
	sync.mutex_unlock(&p.mutex)
}

destroy :: proc(p: ^Pool) -> bool {
	if p == nil {
		return true
	}
	stop(p)
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)
	if p.outstanding != 0 || p.records != 0 || memory_used(p) != 0 {
		return false
	}
	if p.initialized {
		linux.close(p.fd)
		p.fd = -1
		p.initialized = false
	}
	p.configured = 0
	p.memory_limit = 0
	return true
}

completion_fd :: proc "contextless" (p: ^Pool) -> linux.Fd {
	if p == nil {
		return -1
	}
	sync.mutex_lock(&p.mutex)
	fd := p.fd if p.initialized else linux.Fd(-1)
	sync.mutex_unlock(&p.mutex)
	return fd
}

drain_notifications :: proc "contextless" (p: ^Pool) {
	fd := completion_fd(p)
	if fd < 0 {
		return
	}
	buf: [8]u8
	for {
		_, err := linux.read(fd, buf[:])
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			return
		}
	}
}

active_workers :: proc "contextless" (p: ^Pool) -> int {
	if p == nil {
		return 0
	}
	sync.mutex_lock(&p.mutex)
	n := p.nthreads
	sync.mutex_unlock(&p.mutex)
	return n
}

pending :: proc "contextless" (p: ^Pool) -> int {
	if p == nil {
		return 0
	}
	sync.mutex_lock(&p.mutex)
	n := p.outstanding
	sync.mutex_unlock(&p.mutex)
	return n
}
