package main

import "base:intrinsics"
import "base:runtime"
import cp "compute"
import "fpconv"
import lb "label"
import "vmath"
import vt "vsettype"

Vset_Role :: enum u8 {
	Other,
	Coordinator,
	Worker,
}

Vsim_Task :: struct {
	using base: Compute_Task,
	request:    vt.Search_Request,
	query:      vmath.Query,
	detached:   vt.Detached_View,
	labelled:   bool,
	resp:       u8,
	scores:     bool,
	attribs:    bool,
	searched:   bool,
	formatted:  bool,
	failure:    vt.Failure,
	hits:       []vt.Hit,
	hit_count:  int,
	reply:      [dynamic]u8,
}

Vset_Cas_Task :: struct {
	using base: Compute_Task,
	plan:       vt.Cas_Plan,
	target:     ^vt.Partition,
}

@(thread_local)
vset_role: Vset_Role

@(thread_local)
vset_worker_scratch: vt.Scratch

VSET_THREAD_MIN_VISIBLE :: 64

vset_pins_live: int
vset_pin_slots: [cp.CAPACITY]uintptr
vset_handlers_threaded: bool
vset_quiesce_scratch: vt.Scratch
vset_commit_task: ^Vset_Cas_Task
vset_withdrawn: i64
vset_waited: i64
vset_held: [dynamic]^Compute_Task

vset_search_wide :: proc "contextless" (visible: int) -> bool {
	return visible >= VSET_THREAD_MIN_VISIBLE
}

vset_cas_visible :: proc "contextless" (s: vt.Vset, label: lb.Id, owner: vt.Owner) -> int {
	if !labels_on {
		return vt.card(s)
	}
	p := vt.part_at_scope(s, label, owner)
	if p == nil {
		return 0
	}
	return p.count
}

vset_write_paused :: proc "contextless" () -> bool {
	return srv.pause_end_ms > srv.now_ms
}

vset_hold :: proc(task: ^Compute_Task) {
	if vset_held == nil {
		vset_held = make([dynamic]^Compute_Task, 0, 16, runtime.heap_allocator())
	}
	append(&vset_held, task)
}

vset_held_next :: proc() -> ^Compute_Task {
	if len(vset_held) == 0 || vset_write_paused() {
		return nil
	}
	task := vset_held[0]
	ordered_remove(&vset_held, 0)
	return task
}

vset_held_drop :: proc() -> ^Compute_Task {
	if len(vset_held) == 0 {
		return nil
	}
	return pop(&vset_held)
}

vset_threads_install :: proc() {
	vset_role = .Coordinator
	if compute_threads > 0 || ODIN_DEBUG {
		intrinsics.volatile_store(&vt.write_hook, vset_write_hook)
	}
	if compute_threads > 0 && !vset_handlers_threaded {
		vset_handlers_threaded = true
		vset_handlers_install()
	}
}

vset_worker_enter :: proc() {
	vset_role = .Worker
}

vset_worker_leave :: proc() {
	if vset_worker_scratch.ready {
		vt.scratch_destroy(&vset_worker_scratch)
	}
	vset_role = .Other
}

vset_worker_scratch_get :: proc() -> ^vt.Scratch {
	if !vset_worker_scratch.ready {
		vt.scratch_init(&vset_worker_scratch, runtime.heap_allocator())
	}
	return &vset_worker_scratch
}

vset_quiesce_scratch_get :: proc() -> ^vt.Scratch {
	if !vset_quiesce_scratch.ready {
		vt.scratch_init(&vset_quiesce_scratch, runtime.heap_allocator())
	}
	return &vset_quiesce_scratch
}

vset_write_hook :: proc(s: vt.Vset) {
	if vset_role != .Coordinator {
		vset_hook_foreign(s)
		return
	}
	if vset_pins_live == 0 {
		return
	}
	vset_quiesce(s)
}

vset_hook_foreign :: proc(s: vt.Vset) {
	if refusal := vset_foreign_refusal(s); refusal != "" {
		store_fatal(refusal)
	}
}

vset_foreign_refusal :: proc "contextless" (s: vt.Vset) -> string {
	if vset_role == .Worker {
		return "a vector set write ran on a compute worker"
	}
	key := uintptr(s)
	if key == 0 {
		return ""
	}
	for i in 0 ..< cp.CAPACITY {
		if intrinsics.atomic_load_explicit(&vset_pin_slots[i], .Acquire) == key {
			return "a vector set was changed off the coordinator while a search read it"
		}
	}
	return ""
}

vset_pin :: proc(task: ^Compute_Task, s: vt.Vset) {
	task.set = s
	task.pinned = true
	vset_pins_live += 1
	if task.slot >= 0 {
		intrinsics.atomic_store_explicit(&vset_pin_slots[task.slot], uintptr(s), .Release)
	}
	when ODIN_DEBUG {
		task.digest = vt.state_digest(s)
	}
}

vset_unpin :: proc(task: ^Compute_Task) {
	if !task.pinned {
		return
	}
	if !vset_pin_intact(task) {
		store_fatal("a vector set changed while a search read it")
	}
	task.pinned = false
	vset_pins_live -= 1
	if task.slot >= 0 {
		intrinsics.atomic_store_explicit(&vset_pin_slots[task.slot], 0, .Release)
	}
}

vset_pin_intact :: proc(task: ^Compute_Task) -> bool {
	when ODIN_DEBUG {
		return !task.pinned || vt.state_digest(task.set) == task.digest
	} else {
		return true
	}
}

vset_pins_on :: proc "contextless" (s: vt.Vset) -> int {
	n := 0
	for task in compute_tasks {
		if task != nil && task.pinned && task.set == s {
			n += 1
		}
	}
	for task in compute_ready {
		if task.pinned && task.set == s {
			n += 1
		}
	}
	return n
}

vset_settle :: proc(task: ^Compute_Task) {
	if !task.pinned {
		return
	}
	start := mono_now()
	own: u64 = 0
	for cp.reading(&task.job) {
		live := !cp.cancelled(&task.job)
		if cp.withdraw(&compute_pool, &task.job) {
			vset_withdrawn += 1
			if live && task.kind == .Vsim {
				ran := mono_now()
				vset_vsim_run(cast(^Vsim_Task)task, vset_quiesce_scratch_get())
				own += mono_now() - ran
			}
			task.answered = live
			break
		}
		intrinsics.atomic_add_explicit(&vset_waited, 1, .Release)
		cp.wait_done(&compute_pool, &task.job)
	}
	if task.kind == .Vsim && (task.answered || !cp.cancelled(&task.job)) {
		formatting := mono_now()
		if vset_vsim_hold_reply(cast(^Vsim_Task)task) {
			own += mono_now() - formatting
		}
	}
	vset_unpin(task)
	task.own += own
	compute_settle_ticks += mono_now() - start
}

vset_quiesce :: proc(s: vt.Vset) {
	if vset_pins_live == 0 || s == nil {
		return
	}
	for task in compute_tasks {
		if task != nil && task.pinned && task.set == s {
			vset_settle(task)
		}
	}
	for task in compute_ready {
		if task.pinned && task.set == s {
			vset_settle(task)
		}
	}
}

vset_quiesce_all :: proc() {
	if vset_pins_live == 0 {
		return
	}
	for task in compute_tasks {
		if task != nil && task.pinned {
			vset_settle(task)
		}
	}
	for task in compute_ready {
		if task.pinned {
			vset_settle(task)
		}
	}
}

vset_task_answered :: proc "contextless" (task: ^Compute_Task) -> bool {
	return task.kind != .Lcs && task.answered
}

vset_task_release :: proc(task: ^Compute_Task) {
	vset_settle(task)
	switch task.kind {
	case .Vsim:
		t := cast(^Vsim_Task)task
		delete(t.reply)
		t.reply = nil
		vt.view_detached_destroy(&t.detached)
	case .Vadd_Cas:
		t := cast(^Vset_Cas_Task)task
		vt.cas_discard(&t.plan)
	case .Lcs:
	}
}

vset_thread_ready :: proc(c: ^Conn) -> bool {
	return !vset_force_single_threaded && vset_commit_task == nil && c.compute == nil && c.kind == .Redis && .Multi not_in c.txf
}

vset_original_argv :: proc(argv: [][]u8) -> ([][]u8, bool) {
	if argc <= 0 || len(argv_buf) < argc || len(argv) == 0 {
		return nil, false
	}
	base := uintptr(raw_data(argv_buf))
	at := uintptr(raw_data(argv))
	if at < base {
		return nil, false
	}
	start := int((at - base) / size_of([]u8))
	if (at - base) % size_of([]u8) != 0 || start >= argc || start + len(argv) != argc {
		return nil, false
	}
	return argv_buf[:argc], true
}

vset_probe :: proc(key: []u8) -> vt.Vset {
	db := cur_db()
	if db == nil {
		return nil
	}
	l := lookup_make(key)
	saved := store_no_touch
	store_no_touch = true
	t, i := db_locate_slot(db, &l)
	store_no_touch = saved
	if i < 0 {
		return nil
	}
	if db.expires > 0 && slot_deadline(db, t, i) != 0 {
		return nil
	}
	kp := &t.slots[i].key
	vp := &t.slots[i].val
	if kp.small.tag.val_form != FORM_OBJECT || vp.slab.info.type != .Vectorset {
		return nil
	}
	return cast(vt.Vset)rawptr(vp.ref.addr)
}

vset_copy_argv :: proc(region: []u8, offset: ^int, argv: [][]u8) -> [][]u8 {
	out := (cast([^][]u8)(&region[offset^]))[:len(argv)]
	offset^ += len(argv) * size_of([]u8)
	for arg, i in argv {
		out[i] = region[offset^:offset^ + len(arg)]
		copy(out[i], arg)
		offset^ += len(arg)
	}
	return out
}

vset_argv_bytes :: proc "contextless" (argv: [][]u8) -> u128 {
	n := u128(len(argv)) * size_of([]u8)
	for arg in argv {
		n += u128(len(arg))
	}
	return n
}

vset_vsim_submit :: proc(c: ^Conn, argv: [][]u8, s: vt.Vset, view: ^vt.View, q: vmath.Query, req: ^vt.Search_Request, scores: bool, attribs: bool, sc: ^vt.Scratch) -> bool {
	if s == nil || !compute_admits(c) {
		return false
	}
	arena := &s.arena if view == nil else &view.parts[0].part.arena
	qbytes := max(vmath.query_bytes(arena), 8)
	count := req.count if req.count > 0 else vt.COUNT_DEFAULT
	elements := vt.card(s) if view == nil else vt.view_elements(view)
	room := max(min(count, elements), 0)
	bytes := u128(size_of(Vsim_Task)) + vset_argv_bytes(argv) + u128(qbytes) + u128(vmath.ARENA_ALIGN) + u128(len(req.filter)) + u128(align_of(vt.Hit)) + u128(room) * size_of(vt.Hit)
	total, sized := compute_pages(bytes)
	if !sized {
		compute_fallbacks += 1
		return false
	}
	detached := vt.view_detach_bytes(view, sc) if view != nil else 0
	reserved, pooled := compute_route(u128(total) + u128(detached))
	block := mem_alloc(total)
	if block == nil {
		compute_fallbacks += 1
		return false
	}
	region := block[:total]
	task := cast(^Vsim_Task)raw_data(region)
	task^ = Vsim_Task{}
	task.kind = .Vsim
	task.region = region
	offset := size_of(Vsim_Task)
	task.argv = vset_copy_argv(region, &offset, argv)
	text := region[offset:offset + len(req.filter)]
	copy(text, req.filter)
	offset += len(req.filter)
	aligned := (uintptr(raw_data(region)) + uintptr(offset) + uintptr(vmath.ARENA_ALIGN - 1)) & ~uintptr(vmath.ARENA_ALIGN - 1)
	offset = int(aligned - uintptr(raw_data(region)))
	qcopy := region[offset:offset + qbytes]
	intrinsics.mem_copy_non_overlapping(raw_data(qcopy), q.data, qbytes)
	offset += qbytes
	at := (uintptr(raw_data(region)) + uintptr(offset) + uintptr(align_of(vt.Hit) - 1)) & ~uintptr(align_of(vt.Hit) - 1)
	task.hits = (cast([^]vt.Hit)rawptr(at))[:room]
	task.query = q
	task.query.data = raw_data(qcopy)
	task.request = req^
	task.request.vector = nil
	task.request.element = nil
	task.request.filter = string(text)
	task.resp = c.resp
	task.scores = scores
	task.attribs = attribs
	task.labelled = view != nil
	compute_bind(c, task)
	if pooled {
		detach_ok := true
		if view != nil {
			d, ok := vt.view_detach(view, sc, runtime.heap_allocator())
			if ok {
				task.detached = d
				task.extra = d.bytes
			}
			detach_ok = ok
		}
		if detach_ok {
			task.reserved = reserved
			task.job.procedure = vsim_worker
			task.job.data = task
			vset_pin(task, s)
			if cp.submit(&compute_pool, &task.job) {
				compute_admitted(c, task)
				return true
			}
			vset_unpin(task)
		}
		vt.view_detached_destroy(&task.detached)
		task.extra = 0
		task.reserved = 0
		compute_fallbacks += 1
	}
	hits := vset_task_hits(task)
	if view != nil {
		task.failure = vt.view_search_query(view, task.query, &task.request, sc, &hits)
	} else {
		task.failure = vt.search_query(s, task.query, &task.request, sc, &hits)
	}
	task.hit_count = len(hits)
	task.searched = true
	task.slot = -1
	vset_pin(task, s)
	compute_coordinate(c, task)
	return true
}

vsim_worker :: proc "contextless" (job: ^cp.Job) {
	context = runtime.default_context()
	task := cast(^Vsim_Task)job.data
	vset_vsim_run(task, vset_worker_scratch_get())
}

vset_task_hits :: proc "contextless" (task: ^Vsim_Task) -> [dynamic]vt.Hit {
	raw := runtime.Raw_Dynamic_Array {
		data      = raw_data(task.hits),
		len       = 0,
		cap       = len(task.hits),
		allocator = runtime.nil_allocator(),
	}
	return transmute([dynamic]vt.Hit)raw
}

vset_vsim_run :: proc(task: ^Vsim_Task, sc: ^vt.Scratch) {
	hits := vset_task_hits(task)
	f: vt.Failure
	if task.labelled {
		f = vt.view_search_query(&task.detached.view, task.query, &task.request, sc, &hits)
	} else {
		f = vt.search_query(task.set, task.query, &task.request, sc, &hits)
	}
	task.failure = f
	task.hit_count = len(hits) if f.err == .None else 0
	task.searched = true
}

vset_vsim_hold_reply :: proc(task: ^Vsim_Task) -> bool {
	if !task.searched || task.formatted || task.failure.err != .None {
		return false
	}
	task.formatted = true
	if task.suppressed {
		return false
	}
	vset_format_hits(task, task.hits[:task.hit_count])
	return true
}

vf_head :: proc(b: ^[dynamic]u8, prefix: u8, n: int) {
	tmp: [24]u8
	append(b, prefix)
	k := format_i64(raw_data(tmp[:]), i64(n))
	append(b, ..tmp[:k])
	append(b, '\r', '\n')
}

vf_map :: proc(b: ^[dynamic]u8, pairs: int, resp3: bool) {
	if resp3 {
		vf_head(b, '%', pairs)
	} else {
		vf_head(b, '*', 2 * pairs)
	}
}

vf_bulk :: proc(b: ^[dynamic]u8, s: []u8) {
	vf_head(b, '$', len(s))
	append(b, ..s)
	append(b, '\r', '\n')
}

vf_null :: proc(b: ^[dynamic]u8, resp3: bool) {
	if resp3 {
		append(b, '_', '\r', '\n')
	} else {
		append(b, '$', '-', '1', '\r', '\n')
	}
}

vf_double :: proc(b: ^[dynamic]u8, v: f64, resp3: bool) {
	tmp: [fpconv.DOUBLE_STR_MAX]u8
	n := fpconv.format_double(tmp[:], v)
	text := tmp[:n]
	if !resp3 {
		vf_bulk(b, text)
		return
	}
	for x, i in text {
		if x == 0 {
			text = text[:i]
			break
		}
	}
	append(b, ',')
	for x in text {
		append(b, ' ' if x == '\r' || x == '\n' else x)
	}
	append(b, '\r', '\n')
}

vf_name :: proc "contextless" (task: ^Vsim_Task, h: vt.Hit) -> []u8 {
	if task.labelled {
		return vt.hit_name(task.set, h)
	}
	return vt.element_name(task.set, h.slot)
}

vf_attribute :: proc(b: ^[dynamic]u8, task: ^Vsim_Task, h: vt.Hit, resp3: bool) {
	text: string
	ok: bool
	if task.labelled {
		text, ok = vt.hit_attribute(task.set, h)
	} else {
		text, ok = vt.element_attribute(task.set, h.slot)
	}
	if ok {
		vf_bulk(b, transmute([]u8)text)
	} else {
		vf_null(b, resp3)
	}
}

vset_format_hits :: proc(task: ^Vsim_Task, hits: []vt.Hit) {
	task.reply = make([dynamic]u8, 0, 16 + 24 * len(hits), runtime.heap_allocator())
	b := &task.reply
	resp3 := task.resp >= RESP3
	n := len(hits)
	switch {
	case task.scores && task.attribs:
		if resp3 {
			vf_head(b, '%', n)
		} else {
			vf_head(b, '*', 3 * n)
		}
		for h in hits {
			vf_bulk(b, vf_name(task, h))
			if resp3 {
				vf_head(b, '*', 2)
			}
			vf_double(b, h.score, resp3)
			vf_attribute(b, task, h, resp3)
		}
	case task.scores:
		vf_map(b, n, resp3)
		for h in hits {
			vf_bulk(b, vf_name(task, h))
			vf_double(b, h.score, resp3)
		}
	case task.attribs:
		vf_map(b, n, resp3)
		for h in hits {
			vf_bulk(b, vf_name(task, h))
			vf_attribute(b, task, h, resp3)
		}
	case:
		vf_head(b, '*', n)
		for h in hits {
			vf_bulk(b, vf_name(task, h))
		}
	}
}

vset_reply_bytes :: proc(c: ^Conn, bytes: []u8) {
	n := len(bytes)
	if n == 0 || !lua_capture_allow(c, n) {
		return
	}
	p := wb_reserve(c, n)
	intrinsics.mem_copy_non_overlapping(p, raw_data(bytes), n)
	c.wlen += n
}

vset_vsim_publish :: proc(c: ^Conn, task: ^Compute_Task) {
	t := cast(^Vsim_Task)task
	before := c.wlen
	if t.failure.err != .None {
		vset_reply_failure(c, t.failure)
	} else if t.formatted {
		vset_reply_bytes(c, t.reply[:])
	} else if !task.suppressed {
		hits := t.hits[:t.hit_count]
		if t.labelled {
			vset_reply_named_hits(c, t.set, hits, t.scores, t.attribs)
		} else {
			vset_reply_hits(c, t.set, hits, t.scores, t.attribs)
		}
	}
	t.formatted = true
	if task.suppressed {
		c.wlen = before
	}
}

vset_cas_submit :: proc(c: ^Conn, original: [][]u8, s: vt.Vset, add: ^vt.Add_Request, label: lb.Id, owner: vt.Owner, sc: ^vt.Scratch) -> bool {
	if s == nil || !compute_admits(c) {
		return false
	}
	plan: vt.Cas_Plan
	target, failed := vt.cas_plan_begin(s, add, label, owner, labels_on, &plan, sc, runtime.heap_allocator())
	if failed.err != .None || target == nil {
		vt.cas_discard(&plan)
		return false
	}
	bytes := u128(size_of(Vset_Cas_Task)) + vset_argv_bytes(original)
	total, sized := compute_pages(bytes)
	if !sized {
		vt.cas_discard(&plan)
		compute_fallbacks += 1
		return false
	}
	reserved, pooled := compute_route(u128(total) + u128(vt.cas_plan_bytes(&plan)) + u128(vt.cas_cache_bytes(&plan, target)))
	block := mem_alloc(total)
	if block == nil {
		vt.cas_discard(&plan)
		compute_fallbacks += 1
		return false
	}
	region := block[:total]
	task := cast(^Vset_Cas_Task)raw_data(region)
	task^ = Vset_Cas_Task{}
	task.kind = .Vadd_Cas
	task.region = region
	offset := size_of(Vset_Cas_Task)
	task.argv = vset_copy_argv(region, &offset, original)
	task.plan = plan
	task.target = target
	compute_bind(c, task)
	if pooled {
		if vt.cas_plan_reserve(&task.plan, target) {
			task.extra = vt.cas_plan_bytes(&task.plan)
			task.reserved = reserved
			task.job.procedure = cas_worker
			task.job.data = task
			vset_pin(task, s)
			if cp.submit(&compute_pool, &task.job) {
				compute_admitted(c, task)
				return true
			}
			vset_unpin(task)
		}
		vt.cache_destroy(&task.plan.cache)
		task.reserved = 0
		compute_fallbacks += 1
	}
	task.extra = vt.cas_plan_bytes(&task.plan)
	compute_coordinate(c, task)
	return true
}

cas_worker :: proc "contextless" (job: ^cp.Job) {
	context = runtime.default_context()
	task := cast(^Vset_Cas_Task)job.data
	vt.cas_plan_record(&task.plan, task.target, vset_worker_scratch_get())
}

vset_cas_commit :: proc(c: ^Conn, task: ^Compute_Task) {
	t := cast(^Vset_Cas_Task)task
	vset_settle(task)
	saved := vset_commit_task
	vset_commit_task = t
	if task.suppressed && c.reply == {} {
		c.reply += {.Skip}
	}
	pending := c.wlen - c.wpos
	tx_reply_managed = false
	execute_slot(c, t.argv, lookup_entry(t.argv[0]))
	vset_commit_task = saved
	if !tx_reply_managed && c.reply & {.Off, .Skip} != {} {
		c.wlen = c.wpos + pending
	}
	c.reply -= {.Skip}
	if labels_on {
		access_reset_to_bottom()
	}
}

vset_commit_take :: proc(c: ^Conn) -> ^Vset_Cas_Task {
	t := vset_commit_task
	if t == nil || t.client_id != c.id {
		return nil
	}
	vset_commit_task = nil
	return t
}
