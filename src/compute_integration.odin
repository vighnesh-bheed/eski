package main

import cp "compute"
import "core:mem"
import "core:sys/linux"
import ow "owner"

COMPUTE_LCS_MIN_CELLS :: 1_048_576

Lcs_Task :: struct {
	job:       cp.Job,
	region:    []u8,
	a:         []u8,
	b:         []u8,
	argv:      [][]u8,
	table:     [^]u32,
	text:      [^]u8,
	cells:     int,
	want:      Lcs_Want,
	fd:        linux.Fd,
	client_id: i64,
	token:     u64,
	start:     u64,
	cmd:       ^Command,
	stats:     ^Cmd_Hot,
	suppressed: bool,
	slot:      int,
}

compute_pool: cp.Pool
compute_threads: i64
compute_max_memory: i64 = 128 * 1024 * 1024
compute_tasks: [cp.CAPACITY]^Lcs_Task
compute_scopes: [cp.CAPACITY]ow.Scope
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

compute_event_fd :: proc() -> linux.Fd {
	return cp.completion_fd(&compute_pool) if compute_registered else -1
}

compute_note_deferred :: proc(c: ^Conn, cmd: ^Command, stats: ^Cmd_Hot, start: u64) -> bool {
	if task := c.compute; task != nil {
		task.cmd = cmd
		task.stats = stats
		task.start = start
		return true
	}
	return false
}

compute_start :: proc() {
	compute_restart = false
	if compute_threads == 0 || pst.in_child {
		return
	}
	if !cp.init(&compute_pool, int(compute_threads), diagnostics_thread_enter, diagnostics_thread_leave, diagnostics_worker_failure()) {
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
	return c.compute != nil && compute_scopes[c.compute.slot].owner == o
}

compute_conn_closed :: proc(c: ^Conn) {
	if task := c.compute; task != nil {
		cp.cancel(&task.job)
		c.compute = nil
	}
}

compute_release :: proc(task: ^Lcs_Task) {
	compute_tasks[task.slot] = nil
	compute_pending -= 1
	compute_reserved -= len(task.region)
	region := task.region
	mem_free(raw_data(region))
}

compute_shutdown :: proc() {
	if compute_threads == 0 && !compute_registered && compute_pending == 0 {
		return
	}
	for task in compute_tasks {
		if task != nil {
			cp.cancel(&task.job)
		}
	}
	cp.stop(&compute_pool)
	for job := cp.poll(&compute_pool); job != nil; job = cp.poll(&compute_pool) {
		task := cast(^Lcs_Task)job.data
		if int(task.fd) >= 0 && int(task.fd) < len(srv.conns) {
			c := srv.conns[task.fd]
			if c != nil && c.id == task.client_id && c.compute == task {
				c.compute = nil
			}
		}
		compute_cancelled += 1
		compute_release(task)
	}
	if compute_registered {
		epoll_set(cp.completion_fd(&compute_pool), .DEL, false, 0)
		compute_registered = false
	}
	cp.destroy(&compute_pool)
	compute_restart = false
}

compute_tick :: proc() {
	if pst.in_child {
		return
	}
	if compute_restart {
		compute_start()
	}
	if !compute_registered && compute_pending == 0 {
		return
	}
	cp.drain_notifications(&compute_pool)
	for _ in 0 ..< cp.CAPACITY {
		job := cp.poll(&compute_pool)
		if job == nil {
			break
		}
		task := cast(^Lcs_Task)job.data
		compute_worker_ns += job.elapsed_ns
		c: ^Conn
		if int(task.fd) >= 0 && int(task.fd) < len(srv.conns) {
			c = srv.conns[task.fd]
		}
		valid := c != nil && c.id == task.client_id && c.compute == task && c.compute_token == task.token
		if !valid || cp.cancelled(job) {
			compute_cancelled += 1
			if valid {
				c.compute = nil
			}
			compute_release(task)
			continue
		}
		c.compute = nil
		c.atime_ms = max(c.atime_ms, lua_connection_clock())
		if !task.suppressed {
			lcs_reply(c, task.a, task.b, task.table, task.text, task.cells, task.want)
		}
		saved_stat := stat_cur
		stat_cur = &task.stats.stats
		if labels_on {
			access_resume(compute_scopes[task.slot])
		}
		stat_call_slow(c, task.cmd, task.stats, task.argv, mono_now() - task.start)
		if labels_on {
			access_reset_to_bottom()
		}
		stat_cur = saved_stat
		compute_completed += 1
		compute_release(task)
		process_input(c)
		conn_flush(c)
	}
}

compute_info :: proc(b: ^[dynamic]u8) {
	info_line_int(b, "compute_threads_configured", compute_threads)
	info_line_int(b, "compute_threads_active", i64(cp.active_workers(&compute_pool)))
	info_line_int(b, "compute_jobs_pending", i64(compute_pending))
	info_line_int(b, "compute_memory_reserved", i64(compute_reserved))
	info_line_int(b, "compute_jobs_submitted", compute_submitted)
	info_line_int(b, "compute_jobs_completed", compute_completed)
	info_line_int(b, "compute_jobs_cancelled", compute_cancelled)
	info_line_int(b, "compute_sync_fallbacks", compute_fallbacks)
	info_line_int(b, "compute_worker_nanoseconds", compute_worker_ns)
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
	if lua_active != nil || tx_exec_conn != nil || pst.loading || aof.loading || pst.in_child || c.fd < 0 || .Tracking in c.ps || compute_pending >= cp.CAPACITY || cp.active_workers(&compute_pool) == 0 {
		compute_fallbacks += 1
		return false
	}
	bytes := u128(size_of(Lcs_Task)) + u128(len(argv)) * size_of([]u8) + u128(len(a)) + u128(len(b)) + 3 + u128(cells) * size_of(u32) + u128(min(len(a), len(b)))
	for arg in argv {
		bytes += u128(len(arg))
	}
	page := u128(mem.PAGE_SIZE)
	bytes = (bytes + page - 1) / page * page
	if bytes > u128(max(int)) || bytes > u128(compute_max_memory) || u128(compute_reserved) > u128(compute_max_memory) - bytes {
		compute_fallbacks += 1
		return false
	}
	block := mem_alloc(int(bytes))
	if block == nil {
		compute_fallbacks += 1
		return false
	}
	region := block[:int(bytes)]
	task := cast(^Lcs_Task)raw_data(region)
	task^ = Lcs_Task{}
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
	task.fd = c.fd
	task.client_id = c.id
	compute_next_token += 1
	if compute_next_token == 0 {
		compute_next_token += 1
	}
	task.token = compute_next_token
	task.suppressed = c.reply & {.Off, .Skip} != {}
	task.job.procedure = lcs_worker
	task.job.data = task
	for old, i in compute_tasks {
		if old == nil {
			task.slot = i
			break
		}
	}
	if !cp.submit(&compute_pool, &task.job) {
		mem_free(raw_data(region))
		compute_fallbacks += 1
		return false
	}
	compute_tasks[task.slot] = task
	compute_scopes[task.slot] = access_scope() if labels_on else ow.SHARED_BOTTOM
	compute_pending += 1
	compute_reserved += len(region)
	mem_note_peak()
	compute_submitted += 1
	c.compute = task
	c.compute_token = task.token
	return true
}
