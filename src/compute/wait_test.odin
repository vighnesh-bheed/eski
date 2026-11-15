package compute

import "base:intrinsics"
import "core:testing"
import "core:thread"

@(test)
pool_withdraw_takes_only_queued_jobs_and_completes_them_at_once :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 1))
	defer destroy(&p)
	entered, release: u32
	data := [3]Test_Data{{entered = &entered, release = &release}, {}, {}}
	jobs := [3]Job{{procedure = test_work, data = &data[0]}, {procedure = test_work, data = &data[1]}, {procedure = test_work, data = &data[2]}}
	testing.expect(t, submit(&p, &jobs[0]))
	testing.expect(t, wait_for(&entered, 1))
	testing.expect(t, submit(&p, &jobs[1]) && submit(&p, &jobs[2]))
	testing.expect(t, reading(&jobs[0]) && reading(&jobs[1]) && reading(&jobs[2]))
	testing.expect(t, !withdraw(&p, &jobs[0]))
	testing.expect(t, withdraw(&p, &jobs[2]))
	testing.expect(t, !withdraw(&p, &jobs[2]))
	testing.expect(t, !reading(&jobs[2]) && cancelled(&jobs[2]))
	testing.expect(t, poll(&p) == &jobs[2])
	intrinsics.atomic_store_explicit(&release, 1, .Release)
	wait_done(&p, &jobs[0])
	testing.expect(t, !reading(&jobs[0]) && data[0].value == 42)
	wait_done(&p, &jobs[1])
	testing.expect(t, !reading(&jobs[1]) && data[1].calls == 1)
	testing.expect(t, data[2].calls == 0)
	got := 0
	for job := poll(&p); job != nil; job = poll(&p) {
		testing.expect(t, job == &jobs[0] || job == &jobs[1])
		got += 1
	}
	testing.expect_value(t, got, 2)
	testing.expect(t, pending(&p) == 0)
	testing.expect(t, !withdraw(&p, nil) && !withdraw(nil, &jobs[0]))
	wait_done(&p, &jobs[0])
}

Waiter :: struct {
	pool:  ^Pool,
	job:   ^Job,
	done:  u32,
}

waiter_main :: proc(data: rawptr) {
	w := (^Waiter)(data)
	wait_done(w.pool, w.job)
	intrinsics.atomic_store_explicit(&w.done, 1, .Release)
}

@(test)
pool_wait_done_blocks_until_the_worker_releases_the_job :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 1))
	defer destroy(&p)
	entered, release: u32
	data := Test_Data{entered = &entered, release = &release}
	job := Job{procedure = test_work, data = &data}
	testing.expect(t, submit(&p, &job))
	testing.expect(t, wait_for(&entered, 1))
	w := Waiter{pool = &p, job = &job}
	th := thread.create_and_start_with_data(&w, waiter_main)
	for _ in 0 ..< 200 {
		thread.yield()
	}
	testing.expect(t, intrinsics.atomic_load_explicit(&w.done, .Acquire) == 0)
	testing.expect(t, reading(&job))
	intrinsics.atomic_store_explicit(&release, 1, .Release)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, intrinsics.atomic_load_explicit(&w.done, .Acquire) == 1)
	testing.expect(t, !reading(&job) && data.value == 42)
	testing.expect(t, poll(&p) == &job)
}

@(test)
pool_stop_runs_queued_jobs_so_wait_done_returns :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 1))
	defer destroy(&p)
	entered, release: u32
	data := [2]Test_Data{{entered = &entered, release = &release}, {}}
	jobs := [2]Job{{procedure = test_work, data = &data[0]}, {procedure = test_work, data = &data[1]}}
	testing.expect(t, submit(&p, &jobs[0]))
	testing.expect(t, wait_for(&entered, 1))
	testing.expect(t, submit(&p, &jobs[1]))
	intrinsics.atomic_store_explicit(&release, 1, .Release)
	stop(&p)
	testing.expect(t, !reading(&jobs[0]) && !reading(&jobs[1]))
	wait_done(&p, &jobs[1])
	for job := poll(&p); job != nil; job = poll(&p) {
	}
	testing.expect(t, pending(&p) == 0)
}
