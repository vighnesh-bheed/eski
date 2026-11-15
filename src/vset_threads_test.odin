package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import cp "compute"
import lb "label"
import vt "vsettype"

@(private = "file")
Pin_Test :: struct {
	c:          Conn,
	out:        Conn,
	kept_hook:  vt.Write_Hook,
	kept_role:  Vset_Role,
	kept_tasks: [cp.CAPACITY]^Compute_Task,
}

@(private = "file")
Blocker :: struct {
	entered: u32,
	release: u32,
}

@(private = "file")
blocker_work :: proc "contextless" (job: ^cp.Job) {
	b := (^Blocker)(job.data)
	intrinsics.atomic_store_explicit(&b.entered, 1, .Release)
	for intrinsics.atomic_load_explicit(&b.release, .Acquire) == 0 {
		linux.sched_yield()
	}
}

@(private = "file")
gated_vsim :: proc "contextless" (job: ^cp.Job) {
	task := cast(^Vsim_Task)job.data
	gate := (^Blocker)(uintptr(task.extra))
	intrinsics.atomic_store_explicit(&gate.entered, 1, .Release)
	for intrinsics.atomic_load_explicit(&gate.release, .Acquire) == 0 {
		linux.sched_yield()
	}
	vsim_worker(job)
}

@(private = "file")
pin_open :: proc(p: ^Pin_Test) -> bool {
	if len(dbs) == 0 {
		db_init()
	}
	db_cur = &dbs[0]
	db_flush_all()
	p.c = Conn{fd = 7, id = 9001, db = db_cur, resp = 2, wcap = 1 << 16}
	p.c.wbuf = cast([^]u8)runtime.heap_alloc(p.c.wcap)
	p.out = Conn{fd = -1, db = db_cur, resp = 2, wcap = 1 << 16}
	p.out.wbuf = cast([^]u8)runtime.heap_alloc(p.out.wcap)
	p.kept_hook = vt.write_hook
	p.kept_role = vset_role
	p.kept_tasks = compute_tasks
	vt.write_hook = vset_write_hook
	vset_role = .Coordinator
	return cp.init(&compute_pool, 1, vset_worker_enter, vset_worker_leave)
}

@(private = "file")
pin_close :: proc(p: ^Pin_Test) {
	cp.stop(&compute_pool)
	for job := cp.poll(&compute_pool); job != nil; job = cp.poll(&compute_pool) {
		if job.procedure == blocker_work {
			continue
		}
		task := cast(^Compute_Task)job.data
		compute_release(task)
	}
	cp.destroy(&compute_pool)
	compute_pool = {}
	db_flush_all()
	vt.write_hook = p.kept_hook
	vset_role = p.kept_role
	compute_tasks = p.kept_tasks
	runtime.heap_free(p.c.wbuf)
	runtime.heap_free(p.out.wbuf)
	stats_reset()
}

@(private = "file")
pin_run :: proc(c: ^Conn, handler: Command_Proc, args: ..string) -> string {
	argv := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		argv[i] = transmute([]u8)a
	}
	c.wlen = 0
	c.wpos = 0
	saved := context.allocator
	context.allocator = runtime.heap_allocator()
	db_cur = c.db
	handler(c, argv)
	context.allocator = saved
	return strings.clone(string(c.wbuf[:c.wlen]), context.temp_allocator)
}

@(private = "file")
pin_fill :: proc(c: ^Conn, key: string, n: int) -> vt.Vset {
	for i in 0 ..< n {
		x := f32(i % 17) / 17
		y := f32(i % 5) / 5
		pin_run(c, cmd_vadd, "VADD", key, "VALUES", "3", fmt.tprintf("%f", x), fmt.tprintf("%f", y), fmt.tprintf("%f", 1 - x), fmt.tprintf("e%d", i), "SETATTR", fmt.tprintf(`{{"a":%d}}`, i % 4))
	}
	e := db_find_notouch(transmute([]u8)key)
	if e == nil {
		return nil
	}
	return cast(vt.Vset)entry_object(e, .Vectorset)
}

@(private = "file")
pin_vector := [3]f32{0.3, 0.6, 0.2}

@(private = "file")
pin_query :: proc() -> vt.Search_Request {
	return vt.Search_Request{kind = .Vector, vector = pin_vector[:], count = 7, use_filter = true, filter = ".a >= 1"}
}

@(private = "file")
pin_inline_reply :: proc(out: ^Conn, s: vt.Vset, req: ^vt.Search_Request, scores, attribs: bool) -> string {
	hits: [dynamic]vt.Hit
	defer delete(hits)
	sc: vt.Scratch
	vt.scratch_init(&sc)
	defer vt.scratch_destroy(&sc)
	vt.search(s, req, &sc, &hits)
	out.wlen = 0
	out.wpos = 0
	vset_reply_hits(out, s, hits[:], scores, attribs)
	return strings.clone(string(out.wbuf[:out.wlen]), context.temp_allocator)
}

@(private = "file")
pin_submit :: proc(p: ^Pin_Test, s: vt.Vset, req: ^vt.Search_Request) -> ^Vsim_Task {
	sc := vset_scratch_get()
	q, f := vt.search_prepare(s, req, sc)
	if f.err != .None {
		return nil
	}
	argv := []([]u8){transmute([]u8)string("VSIM"), transmute([]u8)string("v")}
	p.c.compute = nil
	if !vset_vsim_submit(&p.c, argv, s, nil, q, req, true, true, sc) {
		return nil
	}
	task := cast(^Vsim_Task)p.c.compute
	p.c.compute = nil
	return task
}

@(test)
vsim_formatter_writes_the_inline_reply_bytes :: proc(t: ^testing.T) {
	p: Pin_Test
	testing.expect(t, pin_open(&p))
	defer pin_close(&p)
	s := pin_fill(&p.out, "v", 60)
	testing.expect(t, s != nil)
	sc: vt.Scratch
	vt.scratch_init(&sc)
	defer vt.scratch_destroy(&sc)
	hits: [dynamic]vt.Hit
	defer delete(hits)
	req := pin_query()
	req.use_filter = false
	vt.search(s, &req, &sc, &hits)
	testing.expect(t, len(hits) == 7)
	for resp in ([]u8{2, 3}) {
		for flags in 0 ..< 4 {
			scores := flags & 1 != 0
			attribs := flags & 2 != 0
			p.out.resp = resp
			p.out.wlen = 0
			vset_reply_hits(&p.out, s, hits[:], scores, attribs)
			want := string(p.out.wbuf[:p.out.wlen])
			task := Vsim_Task{resp = resp, scores = scores, attribs = attribs}
			task.set = s
			vset_format_hits(&task, hits[:])
			testing.expectf(t, string(task.reply[:]) == want, "RESP%d scores %v attribs %v differ", resp, scores, attribs)
			delete(task.reply)
		}
	}
	empty := Vsim_Task{resp = 3}
	empty.set = s
	vset_format_hits(&empty, nil)
	testing.expect_value(t, string(empty.reply[:]), "*0\r\n")
	delete(empty.reply)
}

@(test)
quiesce_withdraws_a_queued_search_and_answers_it_before_the_write :: proc(t: ^testing.T) {
	p: Pin_Test
	testing.expect(t, pin_open(&p))
	defer pin_close(&p)
	s := pin_fill(&p.out, "v", 80)
	req := pin_query()
	want := pin_inline_reply(&p.out, s, &req, true, true)
	b: Blocker
	blocker := cp.Job{procedure = blocker_work, data = &b}
	testing.expect(t, cp.submit(&compute_pool, &blocker))
	for intrinsics.atomic_load_explicit(&b.entered, .Acquire) == 0 {
		thread.yield()
	}
	withdrawn := vset_withdrawn
	task := pin_submit(&p, s, &req)
	testing.expect(t, task != nil)
	if task == nil {
		intrinsics.atomic_store_explicit(&b.release, 1, .Release)
		return
	}
	testing.expect(t, task.pinned && vset_pins_live == 1 && vset_pins_on(s) == 1 && cp.reading(&task.job))
	before := vt.card(s)
	testing.expect_value(t, pin_run(&p.out, cmd_vadd, "VADD", "v", "VALUES", "3", "0.3", "0.6", "0.2", "fresh", "SETATTR", `{"a":3}`), ":1\r\n")
	testing.expect_value(t, vt.card(s), before + 1)
	testing.expect(t, !task.pinned && vset_pins_live == 0 && vset_pins_on(s) == 0)
	testing.expect(t, task.answered && vset_withdrawn == withdrawn + 1 && !cp.reading(&task.job))
	testing.expect(t, string(task.reply[:]) == want)
	testing.expect(t, vset_task_answered(task))
	testing.expect(t, pin_inline_reply(&p.out, s, &req, true, true) != want)
	intrinsics.atomic_store_explicit(&b.release, 1, .Release)
}

@(test)
the_write_hook_waits_for_a_running_search :: proc(t: ^testing.T) {
	p: Pin_Test
	testing.expect(t, pin_open(&p))
	defer pin_close(&p)
	s := pin_fill(&p.out, "v", 80)
	req := pin_query()
	want := pin_inline_reply(&p.out, s, &req, true, true)
	gate: Blocker
	b: Blocker
	blocker := cp.Job{procedure = blocker_work, data = &b}
	testing.expect(t, cp.submit(&compute_pool, &blocker))
	for intrinsics.atomic_load_explicit(&b.entered, .Acquire) == 0 {
		thread.yield()
	}
	task := pin_submit(&p, s, &req)
	testing.expect(t, task != nil)
	if task == nil {
		intrinsics.atomic_store_explicit(&b.release, 1, .Release)
		return
	}
	task.job.procedure = gated_vsim
	task.extra = int(uintptr(&gate))
	intrinsics.atomic_store_explicit(&b.release, 1, .Release)
	for intrinsics.atomic_load_explicit(&gate.entered, .Acquire) == 0 {
		thread.yield()
	}
	testing.expect(t, intrinsics.atomic_load_explicit(&task.job.state, .Acquire) == .Running)
	Opener :: struct {
		gate:  ^Blocker,
		waits: i64,
		done:  u32,
	}
	opener := Opener{gate = &gate, waits = intrinsics.atomic_load_explicit(&vset_waited, .Acquire)}
	th := thread.create_and_start_with_data(&opener, proc(data: rawptr) {
		o := (^Opener)(data)
		for intrinsics.atomic_load_explicit(&vset_waited, .Acquire) == o.waits && intrinsics.atomic_load_explicit(&o.done, .Acquire) == 0 {
			thread.yield()
		}
		intrinsics.atomic_store_explicit(&o.gate.release, 1, .Release)
	})
	testing.expect_value(t, pin_run(&p.out, cmd_vrem, "VREM", "v", "e3"), ":1\r\n")
	intrinsics.atomic_store_explicit(&opener.done, 1, .Release)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, intrinsics.atomic_load_explicit(&vset_waited, .Acquire) > opener.waits)
	testing.expect(t, !task.pinned && vset_pins_live == 0 && !cp.reading(&task.job))
	testing.expect(t, !task.answered && string(task.reply[:]) == want)
	task.extra = 0
}

@(test)
a_closed_connection_leaves_a_withdrawn_search_unanswered :: proc(t: ^testing.T) {
	p: Pin_Test
	testing.expect(t, pin_open(&p))
	defer pin_close(&p)
	s := pin_fill(&p.out, "v", 40)
	req := pin_query()
	b: Blocker
	blocker := cp.Job{procedure = blocker_work, data = &b}
	testing.expect(t, cp.submit(&compute_pool, &blocker))
	for intrinsics.atomic_load_explicit(&b.entered, .Acquire) == 0 {
		thread.yield()
	}
	task := pin_submit(&p, s, &req)
	testing.expect(t, task != nil)
	if task == nil {
		intrinsics.atomic_store_explicit(&b.release, 1, .Release)
		return
	}
	p.c.compute = task
	compute_conn_closed(&p.c)
	testing.expect(t, p.c.compute == nil && cp.cancelled(&task.job) && task.pinned)
	pin_run(&p.out, cmd_del, "DEL", "v")
	testing.expect(t, !task.pinned && vset_pins_live == 0 && !task.answered && len(task.reply) == 0)
	testing.expect(t, !vset_task_answered(task))
	testing.expect(t, db_find_notouch(transmute([]u8)string("v")) == nil)
	intrinsics.atomic_store_explicit(&b.release, 1, .Release)
}

@(test)
a_flush_settles_every_pinned_search_first :: proc(t: ^testing.T) {
	p: Pin_Test
	testing.expect(t, pin_open(&p))
	defer pin_close(&p)
	s := pin_fill(&p.out, "v", 40)
	r := pin_fill(&p.out, "w", 30)
	req := pin_query()
	want_s := pin_inline_reply(&p.out, s, &req, true, true)
	want_r := pin_inline_reply(&p.out, r, &req, true, true)
	b: Blocker
	blocker := cp.Job{procedure = blocker_work, data = &b}
	testing.expect(t, cp.submit(&compute_pool, &blocker))
	for intrinsics.atomic_load_explicit(&b.entered, .Acquire) == 0 {
		thread.yield()
	}
	one := pin_submit(&p, s, &req)
	two := pin_submit(&p, r, &req)
	testing.expect(t, one != nil && two != nil && vset_pins_live == 2)
	if one == nil || two == nil {
		intrinsics.atomic_store_explicit(&b.release, 1, .Release)
		return
	}
	db_flush_all()
	testing.expect(t, vset_pins_live == 0 && one.answered && two.answered)
	testing.expect(t, string(one.reply[:]) == want_s && string(two.reply[:]) == want_r)
	intrinsics.atomic_store_explicit(&b.release, 1, .Release)
}

@(test)
a_queued_cas_prepare_withdrawn_by_a_writer_leaves_no_hint :: proc(t: ^testing.T) {
	p: Pin_Test
	testing.expect(t, pin_open(&p))
	defer pin_close(&p)
	s := pin_fill(&p.out, "v", 60)
	b: Blocker
	blocker := cp.Job{procedure = blocker_work, data = &b}
	testing.expect(t, cp.submit(&compute_pool, &blocker))
	for intrinsics.atomic_load_explicit(&b.entered, .Acquire) == 0 {
		thread.yield()
	}
	add := vt.Add_Request{name = transmute([]u8)string("cas"), vector = []f32{0.5, 0.5, 0.5}, quant = .Q8}
	argv := []([]u8){transmute([]u8)string("VADD"), transmute([]u8)string("v")}
	p.c.compute = nil
	testing.expect(t, vset_cas_submit(&p.c, argv, s, &add, lb.BOTTOM_ID, vt.SHARED, vset_scratch_get()))
	task := cast(^Vset_Cas_Task)p.c.compute
	p.c.compute = nil
	if task == nil {
		intrinsics.atomic_store_explicit(&b.release, 1, .Release)
		return
	}
	testing.expect(t, task.pinned && task.target != nil && task.plan.ready)
	pin_run(&p.out, cmd_vadd, "VADD", "v", "VALUES", "3", "0.1", "0.1", "0.1", "other")
	testing.expect(t, !task.pinned && vset_pins_live == 0 && task.plan.cache.count == 0)
	testing.expect(t, task.answered && vset_task_answered(task) && cp.cancelled(&task.job))
	intrinsics.atomic_store_explicit(&b.release, 1, .Release)
}

@(test)
pin_digest_and_foreign_checks_find_what_they_guard :: proc(t: ^testing.T) {
	p: Pin_Test
	testing.expect(t, pin_open(&p))
	defer pin_close(&p)
	s := pin_fill(&p.out, "v", 30)
	task := Compute_Task{slot = 5}
	vset_pin(&task, s)
	testing.expect(t, vset_pin_intact(&task))
	testing.expect(t, vset_foreign_refusal(s) != "")
	kept := vset_role
	vset_role = .Other
	testing.expect(t, vset_foreign_refusal(s) != "" && vset_foreign_refusal(nil) == "")
	vset_role = .Worker
	testing.expect(t, vset_foreign_refusal(nil) != "")
	vset_role = kept
	vt.write_hook = nil
	pin_run(&p.out, cmd_vsetattr, "VSETATTR", "v", "e2", `{"a":99}`)
	vt.write_hook = vset_write_hook
	when ODIN_DEBUG {
		testing.expect(t, !vset_pin_intact(&task))
	}
	task.digest = vt.state_digest(s)
	vset_unpin(&task)
	testing.expect(t, vset_pins_live == 0 && vset_foreign_refusal(s) == "")
	testing.expect(t, vset_pin_slots[5] == 0)
}

@(private = "file")
Rules_Kept :: struct {
	force:    bool,
	commit:   ^Vset_Cas_Task,
	lua:      ^Lua_Invocation,
	exec:     ^Conn,
	loading:  bool,
	replay:   bool,
	child:    bool,
	pending:  int,
	reserved: int,
	max:      i64,
	fallback: i64,
}

@(private = "file")
rules_keep :: proc() -> Rules_Kept {
	return Rules_Kept {
		force = vset_force_single_threaded,
		commit = vset_commit_task,
		lua = lua_active,
		exec = tx_exec_conn,
		loading = pst.loading,
		replay = aof.loading,
		child = pst.in_child,
		pending = compute_pending,
		reserved = compute_reserved,
		max = compute_max_memory,
		fallback = compute_fallbacks,
	}
}

@(private = "file")
rules_restore :: proc(k: Rules_Kept) {
	vset_force_single_threaded = k.force
	vset_commit_task = k.commit
	lua_active = k.lua
	tx_exec_conn = k.exec
	pst.loading = k.loading
	aof.loading = k.replay
	pst.in_child = k.child
	compute_pending = k.pending
	compute_reserved = k.reserved
	compute_max_memory = k.max
	compute_fallbacks = k.fallback
}

@(test)
the_visible_size_threshold_is_one_named_constant :: proc(t: ^testing.T) {
	testing.expect(t, VSET_THREAD_MIN_VISIBLE > 0)
	testing.expect(t, !vset_search_wide(0))
	testing.expect(t, !vset_search_wide(VSET_THREAD_MIN_VISIBLE - 1))
	testing.expect(t, vset_search_wide(VSET_THREAD_MIN_VISIBLE))
	testing.expect(t, vset_search_wide(VSET_THREAD_MIN_VISIBLE * 100))
}

@(test)
the_cas_size_rule_reads_the_whole_set_only_without_labels :: proc(t: ^testing.T) {
	p: Pin_Test
	testing.expect(t, pin_open(&p))
	defer pin_close(&p)
	small := pin_fill(&p.out, "small", VSET_THREAD_MIN_VISIBLE - 1)
	wide := pin_fill(&p.out, "wide", VSET_THREAD_MIN_VISIBLE)
	testing.expect_value(t, vset_cas_visible(small, lb.BOTTOM_ID, vt.SHARED), VSET_THREAD_MIN_VISIBLE - 1)
	testing.expect_value(t, vset_cas_visible(wide, lb.BOTTOM_ID, vt.SHARED), VSET_THREAD_MIN_VISIBLE)
	testing.expect(t, !vset_search_wide(vset_cas_visible(small, lb.BOTTOM_ID, vt.SHARED)))
	testing.expect(t, vset_search_wide(vset_cas_visible(wide, lb.BOTTOM_ID, vt.SHARED)))
	testing.expect_value(t, vset_cas_visible(nil, lb.BOTTOM_ID, vt.SHARED), 0)
}

@(test)
every_state_rule_keeps_a_search_inline :: proc(t: ^testing.T) {
	p: Pin_Test
	testing.expect(t, pin_open(&p))
	defer pin_close(&p)
	kept := rules_keep()
	defer rules_restore(kept)
	vset_force_single_threaded = false
	vset_commit_task = nil
	lua_active = nil
	tx_exec_conn = nil
	pst.loading = false
	aof.loading = false
	pst.in_child = false
	compute_pending = 0
	compute_reserved = 0
	c := Conn {
		fd   = 7,
		id   = 9101,
		kind = .Redis,
	}
	testing.expect(t, vset_thread_ready(&c))
	testing.expect(t, compute_admits(&c))
	room, ok := compute_room(1)
	testing.expect(t, ok && room == 4096)

	vset_force_single_threaded = true
	testing.expect(t, !vset_thread_ready(&c))
	vset_force_single_threaded = false
	testing.expect(t, vset_thread_ready(&c))

	cas: Vset_Cas_Task
	vset_commit_task = &cas
	testing.expect(t, !vset_thread_ready(&c))
	vset_commit_task = nil

	c.kind = .Memcached
	testing.expect(t, !vset_thread_ready(&c))
	c.kind = .Redis

	c.txf += {.Multi}
	testing.expect(t, !vset_thread_ready(&c))
	c.txf -= {.Multi}

	busy := Task_Probe{}
	c.compute = &busy.base
	testing.expect(t, !vset_thread_ready(&c))
	c.compute = nil
	testing.expect(t, vset_thread_ready(&c))

	refused :: proc(t: ^testing.T, c: ^Conn, what: string) {
		before := compute_fallbacks
		testing.expectf(t, !compute_admits(c), "%s did not refuse admission", what)
		testing.expectf(t, compute_fallbacks == before + 1, "%s was not counted as a fallback", what)
	}
	coordinated :: proc(t: ^testing.T, c: ^Conn, what: string) {
		before := compute_fallbacks
		testing.expectf(t, compute_admits(c), "%s must not decide inline, it is not the caller's own state", what)
		testing.expectf(t, !compute_capacity(), "%s did not refuse the pool", what)
		_, pooled := compute_route(1)
		testing.expectf(t, !pooled && compute_fallbacks == before + 1, "%s did not route the job to the coordinator once", what)
	}
	script: Lua_Invocation
	lua_active = &script
	refused(t, &c, "a script")
	lua_active = nil
	tx_exec_conn = &c
	refused(t, &c, "EXEC")
	tx_exec_conn = nil
	pst.in_child = true
	refused(t, &c, "running inside a child process")
	pst.in_child = false
	c.fd = -1
	refused(t, &c, "a connection without a descriptor")
	c.fd = 7
	c.ps += {.Tracking}
	refused(t, &c, "client tracking")
	c.ps -= {.Tracking}
	pst.loading = true
	coordinated(t, &c, "loading a snapshot")
	pst.loading = false
	aof.loading = true
	coordinated(t, &c, "replaying the log")
	aof.loading = false
	compute_pending = cp.CAPACITY
	coordinated(t, &c, "64 pending jobs")
	compute_pending = 0
	cp.stop(&compute_pool)
	coordinated(t, &c, "a pool stopped for a fork")
	testing.expect(t, cp.init(&compute_pool, 1, vset_worker_enter, vset_worker_leave))
	kept_max := compute_max_memory
	compute_max_memory = 0
	before_budget := compute_fallbacks
	_, pooled := compute_route(1)
	testing.expect(t, compute_admits(&c) && compute_capacity() && !pooled && compute_fallbacks == before_budget + 1)
	compute_max_memory = kept_max
	testing.expect(t, compute_admits(&c) && compute_capacity())
}

@(private = "file")
Task_Probe :: struct {
	base: Compute_Task,
}

@(test)
the_memory_budget_refuses_a_search_that_does_not_fit :: proc(t: ^testing.T) {
	kept := rules_keep()
	defer rules_restore(kept)
	compute_max_memory = 8192
	compute_reserved = 0
	before := compute_fallbacks
	rounded, ok := compute_room(10)
	testing.expect(t, ok && rounded == 4096)
	compute_reserved = 4096
	_, ok = compute_room(10)
	testing.expect(t, ok)
	compute_reserved = 4097
	_, ok = compute_room(10)
	testing.expect(t, !ok && compute_fallbacks == before + 1)
	compute_reserved = 0
	_, ok = compute_room(8193)
	testing.expect(t, !ok && compute_fallbacks == before + 2)
	compute_max_memory = 0
	_, ok = compute_room(1)
	testing.expect(t, !ok && compute_fallbacks == before + 3)
}

@(test)
held_commits_wait_for_the_pause_and_leave_in_order :: proc(t: ^testing.T) {
	kept_end := srv.pause_end_ms
	kept_now := srv.now_ms
	defer {
		srv.pause_end_ms = kept_end
		srv.now_ms = kept_now
	}
	srv.now_ms = 1_000_000
	srv.pause_end_ms = 0
	testing.expect(t, !vset_write_paused())
	srv.pause_end_ms = srv.now_ms + 5000
	testing.expect(t, vset_write_paused())
	srv.pause_end_ms = srv.now_ms
	testing.expect(t, !vset_write_paused())
	srv.pause_end_ms = srv.now_ms + 5000
	a, b, c: Compute_Task
	vset_hold(&a)
	vset_hold(&b)
	vset_hold(&c)
	testing.expect_value(t, len(vset_held), 3)
	testing.expect(t, vset_held_next() == nil)
	srv.pause_end_ms = 0
	testing.expect(t, vset_held_next() == &a)
	testing.expect(t, vset_held_next() == &b)
	srv.pause_end_ms = srv.now_ms + 5000
	testing.expect(t, vset_held_next() == nil)
	testing.expect_value(t, len(vset_held), 1)
	testing.expect(t, vset_held_drop() == &c)
	testing.expect(t, vset_held_drop() == nil)
	testing.expect_value(t, len(vset_held), 0)
}

@(test)
a_completed_cas_waits_for_the_pause_in_the_connection_table :: proc(t: ^testing.T) {
	p: Pin_Test
	testing.expect(t, pin_open(&p))
	defer pin_close(&p)
	s := pin_fill(&p.out, "v", 80)
	kept_end := srv.pause_end_ms
	kept_now := srv.now_ms
	kept_len := len(srv.conns)
	defer {
		srv.pause_end_ms = kept_end
		srv.now_ms = kept_now
		if kept_len == 0 {
			delete(srv.conns)
			srv.conns = nil
		} else {
			resize(&srv.conns, kept_len)
		}
	}
	if len(srv.conns) <= int(p.c.fd) {
		resize(&srv.conns, int(p.c.fd) + 1)
	}
	was := srv.conns[p.c.fd]
	srv.conns[p.c.fd] = &p.c
	defer srv.conns[p.c.fd] = was
	add := vt.Add_Request{name = transmute([]u8)string("held"), vector = []f32{0.5, 0.5, 0.5}, quant = .Q8}
	argv := []([]u8){transmute([]u8)string("VADD"), transmute([]u8)string("v")}
	p.c.compute = nil
	testing.expect(t, vset_cas_submit(&p.c, argv, s, &add, lb.BOTTOM_ID, vt.SHARED, vset_scratch_get()))
	task := cast(^Vset_Cas_Task)p.c.compute
	if task == nil {
		return
	}
	done: ^cp.Job
	for done == nil {
		cp.drain_notifications(&compute_pool)
		done = cp.poll(&compute_pool)
		if done == nil {
			thread.yield()
		}
	}
	testing.expect(t, done == &task.job)
	srv.now_ms = 2_000_000
	srv.pause_end_ms = srv.now_ms + 60_000
	completed := compute_completed
	cancelled := compute_cancelled
	compute_handle(&task.base)
	testing.expect_value(t, len(vset_held), 1)
	testing.expect(t, p.c.compute == &task.base)
	testing.expect_value(t, compute_completed, completed)
	testing.expect_value(t, compute_cancelled, cancelled)
	testing.expect_value(t, vt.card(s), 80)
	testing.expect(t, task.pinned || !cp.reading(&task.job))
	srv.pause_end_ms = 0
	next := vset_held_next()
	testing.expect(t, next == &task.base)
	compute_drop(next)
	testing.expect(t, p.c.compute == nil)
	testing.expect_value(t, compute_cancelled, cancelled + 1)
	testing.expect_value(t, len(vset_held), 0)
	testing.expect_value(t, vset_pins_live, 0)
	testing.expect_value(t, vt.card(s), 80)
}

@(test)
the_compute_counters_read_zero_below_the_top_and_show_to_the_top :: proc(t: ^testing.T) {
	kept := rules_keep()
	kept_submitted, kept_completed, kept_cancelled, kept_ns := compute_submitted, compute_completed, compute_cancelled, compute_worker_ns
	kept_labels, kept_top := labels_on, access.top
	defer {
		rules_restore(kept)
		compute_submitted, compute_completed, compute_cancelled, compute_worker_ns = kept_submitted, kept_completed, kept_cancelled, kept_ns
		labels_on, access.top = kept_labels, kept_top
	}
	compute_submitted, compute_completed, compute_cancelled, compute_worker_ns = 41, 40, 1, 99
	compute_fallbacks, compute_pending, compute_reserved = 7, 2, 8192
	shown := [?]string{"compute_jobs_pending:2\r\n", "compute_memory_reserved:8192\r\n", "compute_jobs_submitted:41\r\n", "compute_jobs_completed:40\r\n", "compute_jobs_cancelled:1\r\n", "compute_sync_fallbacks:7\r\n", "compute_worker_nanoseconds:99\r\n"}
	hidden := [?]string{"compute_jobs_pending:0\r\n", "compute_memory_reserved:0\r\n", "compute_jobs_submitted:0\r\n", "compute_jobs_completed:0\r\n", "compute_jobs_cancelled:0\r\n", "compute_sync_fallbacks:0\r\n", "compute_worker_nanoseconds:0\r\n"}
	b := make([dynamic]u8, context.temp_allocator)
	kept_threads := compute_threads
	defer compute_threads = kept_threads
	compute_threads = 3
	labels_on, access.top = true, false
	compute_info(&b)
	testing.expect(t, strings.contains(string(b[:]), "compute_threads_active:3\r\n"), "a caller below the top reads the configured worker count")
	for line in hidden {
		testing.expectf(t, strings.contains(string(b[:]), line), "a caller below the top should read %s", line)
	}
	for line in shown {
		testing.expectf(t, !strings.contains(string(b[:]), line), "a caller below the top must not read %s", line)
	}
	clear(&b)
	labels_on, access.top = true, true
	compute_info(&b)
	testing.expect(t, strings.contains(string(b[:]), "compute_threads_active:0\r\n"), "the top reads the live worker count")
	for line in shown {
		testing.expectf(t, strings.contains(string(b[:]), line), "the top should read %s", line)
	}
	clear(&b)
	labels_on, access.top = false, false
	compute_info(&b)
	for line in shown {
		testing.expectf(t, strings.contains(string(b[:]), line), "a server without labels should read %s", line)
	}
}

@(test)
a_search_the_pool_cannot_take_runs_on_the_coordinator_and_answers_at_the_tick :: proc(t: ^testing.T) {
	p: Pin_Test
	testing.expect(t, pin_open(&p))
	defer pin_close(&p)
	s := pin_fill(&p.out, "v", 80)
	req := pin_query()
	want := pin_inline_reply(&p.out, s, &req, true, true)
	kept_pending := compute_pending
	defer compute_pending = kept_pending
	completed, cancelled := compute_completed, compute_cancelled
	for kill in ([]bool{false, true}) {
		compute_pending = cp.CAPACITY
		sc := vset_scratch_get()
		q, f := vt.search_prepare(s, &req, sc)
		testing.expect(t, f.err == .None)
		argv := []([]u8){transmute([]u8)string("VSIM"), transmute([]u8)string("v")}
		p.c.compute = nil
		p.c.wlen = 0
		p.c.wpos = 0
		testing.expect(t, vset_vsim_submit(&p.c, argv, s, nil, q, &req, true, true, sc))
		compute_pending = kept_pending
		slot := lookup_entry(argv[0])
		testing.expect(t, compute_note_deferred(&p.c, slot.cmd, slot.stats, 0))
		task := cast(^Vsim_Task)p.c.compute
		testing.expect(t, task != nil && task.coordinated && len(compute_ready) == 1 && compute_reserved == 0)
		if task == nil {
			return
		}
		testing.expect(t, p.c.wlen == 0 && task.searched && !task.formatted && len(task.reply) == 0 && task.pinned && vset_pins_on(s) == 1)
		testing.expect(t, task.hit_count <= len(task.hits) && len(task.hits) <= int(req.count))
		testing.expect_value(t, pin_run(&p.out, cmd_vsetattr, "VSETATTR", "v", "e9", `{"a":1}`), ":1\r\n")
		testing.expect(t, task.pinned == false && task.formatted && string(task.reply[:]) == want)
		if kill {
			compute_conn_closed(&p.c)
			compute_ready_run()
			testing.expect(t, p.c.wlen == 0 && compute_cancelled == cancelled + 1)
		} else {
			testing.expect(t, compute_ready[0] == &task.base)
			ordered_remove(&compute_ready, 0)
			p.c.compute = nil
			compute_scoped_stats(&p.c, task)
			compute_completed += 1
			compute_release(task)
			testing.expect_value(t, string(p.c.wbuf[:p.c.wlen]), want)
		}
		testing.expect(t, len(compute_ready) == 0 && vset_pins_live == 0 && p.c.compute == nil && compute_coordinated == 0)
	}
	testing.expect(t, compute_completed == completed + 1)
}

@(test)
a_writer_formats_a_finished_search_and_is_not_billed_for_it :: proc(t: ^testing.T) {
	p: Pin_Test
	testing.expect(t, pin_open(&p))
	defer pin_close(&p)
	s := pin_fill(&p.out, "v", 80)
	req := pin_query()
	want := pin_inline_reply(&p.out, s, &req, true, true)
	task := pin_submit(&p, s, &req)
	testing.expect(t, task != nil)
	if task == nil {
		return
	}
	testing.expect(t, task.reserved >= len(task.region) && compute_reserved >= task.reserved)
	cp.wait_done(&compute_pool, &task.job)
	testing.expect(t, !cp.reading(&task.job) && task.pinned && task.searched)
	testing.expect(t, !task.formatted && len(task.reply) == 0 && cap(task.reply) == 0)
	testing.expect(t, task.hit_count > 0 && task.hit_count <= len(task.hits) && len(task.hits) <= int(req.count))
	region := uintptr(raw_data(task.region))
	testing.expect(t, uintptr(raw_data(task.hits)) >= region && uintptr(raw_data(task.hits)) + uintptr(len(task.hits) * size_of(vt.Hit)) <= region + uintptr(len(task.region)))
	settled := compute_settle_ticks
	own := task.own
	testing.expect_value(t, pin_run(&p.out, cmd_vrem, "VREM", "v", "e3"), ":1\r\n")
	testing.expect(t, !task.pinned && vset_pins_live == 0 && task.formatted)
	testing.expect_value(t, string(task.reply[:]), want)
	testing.expect(t, compute_settle_ticks > settled && task.own > own)
	testing.expect(t, compute_own_ticks(mono_now(), compute_settle_ticks - (1 << 40)) == 0)
}

@(test)
the_cas_cache_is_reserved_at_submit_and_never_grows :: proc(t: ^testing.T) {
	p: Pin_Test
	testing.expect(t, pin_open(&p))
	defer pin_close(&p)
	s := pin_fill(&p.out, "v", 600)
	add := vt.Add_Request{name = transmute([]u8)string("cas"), vector = []f32{0.5, 0.5, 0.5}, quant = .Q8, ef = 400}
	argv := []([]u8){transmute([]u8)string("VADD"), transmute([]u8)string("v")}
	p.c.compute = nil
	testing.expect(t, vset_cas_submit(&p.c, argv, s, &add, lb.BOTTOM_ID, vt.SHARED, vset_scratch_get()))
	task := cast(^Vset_Cas_Task)p.c.compute
	p.c.compute = nil
	if task == nil {
		return
	}
	keys := len(task.plan.cache.keys)
	testing.expect(t, task.plan.cache.fixed && keys > 0 && keys == vt.cas_cache_bytes(&task.plan, task.target) / 8)
	testing.expect(t, task.reserved >= len(task.region) + vt.cas_plan_bytes(&task.plan) && task.extra == vt.cas_plan_bytes(&task.plan))
	cp.wait_done(&compute_pool, &task.job)
	testing.expect(t, len(task.plan.cache.keys) == keys && 2 * task.plan.cache.used <= keys && task.plan.cache.count > 0)
	small: vt.Distance_Cache
	vt.cache_init(&small)
	testing.expect(t, vt.cache_fix(&small, 1))
	for k in 0 ..< u32(500) {
		vt.cache_put(&small, k, f32(k))
	}
	testing.expect(t, len(small.keys) == 64 && small.used == 32 && vt.cache_reserve(&small, 100_000) && len(small.keys) == 64)
	vt.cache_destroy(&small)
	testing.expect(t, !small.fixed && small.keys == nil)
}
