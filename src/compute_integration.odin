package main

import "base:runtime"
import cp "compute"
import "core:mem"
import "core:sys/linux"
import ow "owner"
import vt "vsettype"

COMPUTE_LCS_MIN_CELLS :: 1_048_576

Compute_Kind :: enum u8 {
	Lcs,
	Vsim,
	Vadd_Cas,
}

Compute_Task :: struct {
	job:        cp.Job,
	kind:       Compute_Kind,
	region:     []u8,
	argv:       [][]u8,
	fd:         linux.Fd,
	client_id:  i64,
	token:      u64,
	own:        u64,
	cmd:        ^Command,
	stats:      ^Cmd_Hot,
	scope:      Access_Resume,
	set:        vt.Vset,
	pinned:     bool,
	answered:   bool,
	suppressed: bool,
	slot:       int,
	extra:      int,
	reserved:   int,
	digest:     u64,
	coordinated: bool,
}

Lcs_Task :: struct {
	using base: Compute_Task,
	a:          []u8,
	b:          []u8,
	table:      [^]u32,
	text:       [^]u8,
	cells:      int,
	want:       Lcs_Want,
}

compute_pool: cp.Pool
compute_threads: i64
compute_max_memory: i64 = 128 * 1024 * 1024
compute_tasks: [cp.CAPACITY]^Compute_Task
compute_reserved: int
compute_pending: int
compute_next_token: u64
compute_submitted: i64
compute_completed: i64
compute_cancelled: i64
compute_fallbacks: i64
compute_worker_ns: i64
compute_restart: bool
compute_registered: bool
compute_ready: [dynamic]^Compute_Task
compute_coordinated: int
compute_coordinated_bytes: int
compute_settle_ticks: u64

compute_event_fd :: proc() -> linux.Fd {
	return cp.completion_fd(&compute_pool) if compute_registered else -1
}

compute_note_deferred :: proc(c: ^Conn, cmd: ^Command, stats: ^Cmd_Hot, ticks: u64) -> bool {
	if task := c.compute; task != nil {
		task.cmd = cmd
		task.stats = stats
		task.own += ticks
		return true
	}
	return false
}

compute_own_ticks :: #force_inline proc "contextless" (t0: u64, settled: u64) -> u64 {
	total := mono_now() - t0
	spent := compute_settle_ticks - settled
	return total - spent if spent < total else 0
}

compute_worker_ticks :: proc "contextless" (task: ^Compute_Task) -> u64 {
	ns := u128(max(task.job.elapsed_ns, 0))
	return u64(ns * u128(mono_ticks_per_us) / 1000)
}

compute_feed_deferred :: proc "contextless" (c: ^Conn) -> bool {
	return c.compute != nil && c.compute.kind == .Vadd_Cas
}

compute_worker_enter :: proc() {
	vset_worker_enter()
	diagnostics_thread_enter()
}

compute_worker_leave :: proc() {
	diagnostics_thread_leave()
	vset_worker_leave()
}

compute_start :: proc() {
	compute_restart = false
	if pst.in_child {
		return
	}
	vset_threads_install()
	if compute_threads == 0 {
		return
	}
	if !cp.init(&compute_pool, int(compute_threads), compute_worker_enter, compute_worker_leave, diagnostics_worker_failure()) {
		return
	}
	if !compute_registered {
		fd := cp.completion_fd(&compute_pool)
		if epoll_set(fd, .ADD, false, 0) != .NONE {
			cp.stop(&compute_pool)
			return
		}
		compute_registered = true
	}
}

compute_before_fork :: proc() {
	if compute_threads > 0 && !pst.in_child {
		cp.stop(&compute_pool)
		compute_restart = true
	}
}

compute_owner_pending :: proc(c: ^Conn, o: ow.Owner) -> bool {
	return c.compute != nil && c.compute.scope.owner == o
}

compute_conn_closed :: proc(c: ^Conn) {
	if task := c.compute; task != nil {
		cp.cancel(&task.job)
		c.compute = nil
	}
}

compute_admits :: proc(c: ^Conn) -> bool {
	if lua_active != nil || tx_exec_conn != nil || pst.in_child || c.fd < 0 || .Tracking in c.ps {
		compute_fallbacks += 1
		return false
	}
	return true
}

compute_capacity :: proc() -> bool {
	return !pst.loading && !aof.loading && compute_pending < cp.CAPACITY && cp.active_workers(&compute_pool) > 0
}

compute_route :: proc(bytes: u128) -> (reserved: int, pooled: bool) {
	if !compute_capacity() {
		compute_fallbacks += 1
		return 0, false
	}
	return compute_room(bytes)
}

compute_pages :: proc "contextless" (bytes: u128) -> (total: int, ok: bool) {
	page := u128(mem.PAGE_SIZE)
	rounded := (bytes + page - 1) / page * page
	if rounded > u128(max(int)) {
		return 0, false
	}
	return int(rounded), true
}

compute_room :: proc(bytes: u128) -> (rounded: int, ok: bool) {
	total, fits := compute_pages(bytes)
	if !fits || u128(total) > u128(compute_max_memory) || u128(compute_reserved) > u128(compute_max_memory) - u128(total) {
		compute_fallbacks += 1
		return 0, false
	}
	return total, true
}

compute_free_slot :: proc() -> int {
	for old, i in compute_tasks {
		if old == nil {
			return i
		}
	}
	return -1
}

compute_bind :: proc(c: ^Conn, task: ^Compute_Task) {
	task.fd = c.fd
	task.client_id = c.id
	compute_next_token += 1
	if compute_next_token == 0 {
		compute_next_token += 1
	}
	task.token = compute_next_token
	task.suppressed = c.reply & {.Off, .Skip} != {}
	task.slot = compute_free_slot()
	if labels_on {
		task.scope = access_resume_capture()
	}
}

compute_admitted :: proc(c: ^Conn, task: ^Compute_Task) {
	compute_tasks[task.slot] = task
	compute_pending += 1
	if task.reserved == 0 {
		task.reserved = len(task.region) + task.extra
	}
	compute_reserved += task.reserved
	mem_note_peak()
	compute_submitted += 1
	c.compute = task
	c.compute_token = task.token
}

compute_coordinate :: proc(c: ^Conn, task: ^Compute_Task) {
	task.coordinated = true
	task.slot = -1
	task.reserved = 0
	if compute_ready == nil {
		compute_ready = make([dynamic]^Compute_Task, 0, 16, runtime.heap_allocator())
	}
	append(&compute_ready, task)
	compute_coordinated += 1
	compute_coordinated_bytes += len(task.region) + task.extra
	mem_note_peak()
	compute_submitted += 1
	c.compute = task
	c.compute_token = task.token
}

compute_release :: proc(task: ^Compute_Task) {
	if task.slot >= 0 && compute_tasks[task.slot] == task {
		compute_tasks[task.slot] = nil
	}
	if task.coordinated {
		compute_coordinated -= 1
		compute_coordinated_bytes -= len(task.region) + task.extra
	} else {
		compute_pending -= 1
		compute_reserved -= task.reserved
	}
	if task.kind != .Lcs {
		vset_task_release(task)
	}
	region := task.region
	mem_free(raw_data(region))
}

compute_drop :: proc(task: ^Compute_Task) {
	c := compute_task_conn(task)
	if c != nil && c.id == task.client_id && c.compute == task {
		c.compute = nil
	}
	compute_cancelled += 1
	compute_release(task)
}

compute_shutdown :: proc() {
	if compute_threads == 0 && !compute_registered && compute_pending == 0 && len(compute_ready) == 0 && len(vset_held) == 0 {
		return
	}
	for task in compute_tasks {
		if task != nil {
			cp.cancel(&task.job)
		}
	}
	for task in compute_ready {
		cp.cancel(&task.job)
	}
	for task in vset_held {
		cp.cancel(&task.job)
	}
	cp.stop(&compute_pool)
	for job := cp.poll(&compute_pool); job != nil; job = cp.poll(&compute_pool) {
		compute_drop(cast(^Compute_Task)job.data)
	}
	for task := vset_held_drop(); task != nil; task = vset_held_drop() {
		compute_drop(task)
	}
	for len(compute_ready) > 0 {
		compute_drop(pop(&compute_ready))
	}
	if compute_registered {
		epoll_set(cp.completion_fd(&compute_pool), .DEL, false, 0)
		compute_registered = false
	}
	cp.destroy(&compute_pool)
	compute_restart = false
}

compute_scoped_stats :: proc(c: ^Conn, task: ^Compute_Task) {
	saved_stat := stat_cur
	stat_cur = &task.stats.stats
	entered := !labels_on || access_resume_enter(task.scope)
	published := mono_now()
	switch task.kind {
	case .Lcs:
		if !task.suppressed {
			t := cast(^Lcs_Task)task
			lcs_reply(c, t.a, t.b, t.table, t.text, t.cells, t.want)
		}
	case .Vsim:
		vset_vsim_publish(c, task)
	case .Vadd_Cas:
	}
	if entered {
		stat_call_slow(c, task.cmd, task.stats, task.argv, task.own + compute_worker_ticks(task) + (mono_now() - published))
	}
	if labels_on {
		if entered {
			access_resume_leave()
		} else {
			access_reset_to_bottom()
		}
	}
	stat_cur = saved_stat
}

compute_task_conn :: proc(task: ^Compute_Task) -> ^Conn {
	if int(task.fd) >= 0 && int(task.fd) < len(srv.conns) {
		return srv.conns[task.fd]
	}
	return nil
}

compute_handle :: proc(task: ^Compute_Task) {
	c := compute_task_conn(task)
	valid := c != nil && c.id == task.client_id && c.compute == task && c.compute_token == task.token
	if !valid || (cp.cancelled(&task.job) && !vset_task_answered(task)) {
		compute_cancelled += 1
		if valid {
			c.compute = nil
		}
		compute_release(task)
		return
	}
	if task.kind == .Vadd_Cas && vset_write_paused() {
		vset_hold(task)
		return
	}
	c.compute = nil
	c.atime_ms = max(c.atime_ms, lua_connection_clock())
	if task.kind == .Vadd_Cas {
		vset_cas_commit(c, task)
	} else {
		compute_scoped_stats(c, task)
	}
	compute_completed += 1
	compute_release(task)
	process_input(c)
	conn_flush(c)
}

compute_tick :: proc() {
	if pst.in_child {
		return
	}
	if compute_restart {
		compute_start()
	}
	if !compute_registered && compute_pending == 0 && len(compute_ready) == 0 && len(vset_held) == 0 {
		return
	}
	cp.drain_notifications(&compute_pool)
	for task := vset_held_next(); task != nil; task = vset_held_next() {
		compute_handle(task)
	}
	compute_ready_run()
	for _ in 0 ..< cp.CAPACITY {
		job := cp.poll(&compute_pool)
		if job == nil {
			break
		}
		compute_worker_ns += job.elapsed_ns
		compute_handle(cast(^Compute_Task)job.data)
	}
}

compute_ready_run :: proc() {
	for len(compute_ready) > 0 {
		n := len(compute_ready)
		for _ in 0 ..< n {
			if len(compute_ready) == 0 {
				break
			}
			task := compute_ready[0]
			ordered_remove(&compute_ready, 0)
			compute_handle(task)
		}
		if len(compute_ready) > 0 && compute_registered {
			cp.notify(&compute_pool)
			return
		}
	}
}

compute_info :: proc(b: ^[dynamic]u8) {
	show := !labels_on || access.top
	info_line_int(b, "compute_threads_configured", compute_threads)
	info_line_int(b, "compute_threads_active", i64(cp.active_workers(&compute_pool)) if show else compute_threads)
	info_line_int(b, "compute_jobs_pending", i64(compute_pending + compute_coordinated) if show else 0)
	info_line_int(b, "compute_memory_reserved", i64(compute_reserved) if show else 0)
	info_line_int(b, "compute_jobs_submitted", compute_submitted if show else 0)
	info_line_int(b, "compute_jobs_completed", compute_completed if show else 0)
	info_line_int(b, "compute_jobs_cancelled", compute_cancelled if show else 0)
	info_line_int(b, "compute_sync_fallbacks", compute_fallbacks if show else 0)
	info_line_int(b, "compute_worker_nanoseconds", compute_worker_ns if show else 0)
}

lcs_worker :: proc "contextless" (job: ^cp.Job) {
	task := cast(^Lcs_Task)job.data
	lcs_fill(task.a, task.b, task.table, job)
}

lcs_fill :: proc "contextless" (a, b: []u8, table: [^]u32, job: ^cp.Job) #no_bounds_check {
	width := len(b) + 1
	for j in 0 ..< width {
		table[j] = 0
	}
	for i in 1 ..= len(a) {
		if job != nil && cp.cancelled(job) {
			return
		}
		row := i * width
		above := row - width
		table[row] = 0
		ai := a[i - 1]
		for j in 1 ..< width {
			if ai == b[j - 1] {
				table[row + j] = table[above + j - 1] + 1
			} else {
				table[row + j] = max(table[above + j], table[row + j - 1])
			}
		}
	}
}

lcs_try_compute :: proc(c: ^Conn, argv: [][]u8, a, b: []u8, cells: int, want: Lcs_Want) -> bool {
	if compute_threads == 0 || cells < COMPUTE_LCS_MIN_CELLS {
		return false
	}
	if !compute_admits(c) {
		return false
	}
	bytes := u128(size_of(Lcs_Task)) + u128(len(argv)) * size_of([]u8) + u128(len(a)) + u128(len(b)) + 3 + u128(cells) * size_of(u32) + u128(min(len(a), len(b)))
	for arg in argv {
		bytes += u128(len(arg))
	}
	total, sized := compute_pages(bytes)
	if !sized {
		compute_fallbacks += 1
		return false
	}
	reserved, pooled := compute_route(u128(total))
	block := mem_alloc(total)
	if block == nil {
		compute_fallbacks += 1
		return false
	}
	region := block[:total]
	task := cast(^Lcs_Task)raw_data(region)
	task^ = Lcs_Task{}
	task.kind = .Lcs
	task.region = region
	offset := size_of(Lcs_Task)
	task.argv = (cast([^][]u8)(&region[offset]))[:len(argv)]
	offset += len(argv) * size_of([]u8)
	for arg, i in argv {
		task.argv[i] = region[offset:offset + len(arg)]
		copy(task.argv[i], arg)
		offset += len(arg)
	}
	task.a = region[offset:offset + len(a)]
	copy(task.a, a)
	offset += len(a)
	task.b = region[offset:offset + len(b)]
	copy(task.b, b)
	offset += len(b)
	offset = (offset + 3) & ~int(3)
	task.table = cast([^]u32)(&region[offset])
	task.text = cast([^]u8)(uintptr(raw_data(region)) + uintptr(offset + cells * size_of(u32)))
	task.cells = cells
	task.want = want
	compute_bind(c, task)
	task.job.procedure = lcs_worker
	task.job.data = task
	if pooled {
		task.reserved = reserved
		if cp.submit(&compute_pool, &task.job) {
			compute_admitted(c, task)
			return true
		}
		compute_fallbacks += 1
	}
	lcs_fill(task.a, task.b, task.table, nil)
	compute_coordinate(c, task)
	return true
}
