
lifecycle_bio_pending :: proc() -> i32 {
	return intrinsics.atomic_load_explicit(&aof_bio_jobs_pending, .Acquire)
}

lifecycle_bio_reset :: proc() -> bool {
	return aof_bio_thread == nil && aof_bio_head == 0 && aof_bio_tail == 0 && aof_bio_pending_fsync == 0 && aof_bio_jobs_pending == 0
}
