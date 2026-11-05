
lifecycle_lazy_counts :: proc() -> (int, int) {
	sync.mutex_lock(&lazy_mutex)
	queued := len(lazy_queue) - lazy_head
	sync.mutex_unlock(&lazy_mutex)
	return queued, intrinsics.atomic_load_explicit(&lazy_jobs, .Acquire)
}

lifecycle_lazy_reset :: proc() -> bool {
	return lazy_efd == -1 && lazy_thread == nil && len(lazy_queue) == 0 && len(lazy_done) == 0 && lazy_head == 0 && lazy_jobs == 0 && lazy_pending_objs == 0 && lazy_pending_mem == 0 && lazy_pending_slab == 0 && lazy_blocked == 0
}
