package main

Keyspace_Owner :: struct {
	quota:     i64,
	quota_set: bool,
}

Owner_Counts :: struct {
	keys:     i64,
	elements: i64,
	bytes:    i64,
}

Owner_Info :: struct {
	keys:       i64,
	elements:   i64,
	bytes:      i64,
	partitions: i64,
	labels:     i64,
	quota:      i64,
}

Owner_Totals :: struct {
	holding:    i64,
	partitions: i64,
	bytes:      i64,
}

keyspace_owner_forget :: proc(e: ^Owner_Entry) -> Owner_Counts {
	return {}
}

keyspace_owner_info :: proc(e: ^Owner_Entry) -> Owner_Info {
	quota := e.keyspace.quota if e.keyspace.quota_set else owner_quota_default
	return Owner_Info{quota = quota}
}

keyspace_owner_quota :: proc(e: ^Owner_Entry, set: bool, limit: i64) -> (quota: i64, used: i64) {
	if set {
		e.keyspace.quota = limit
		e.keyspace.quota_set = limit > 0
	}
	quota = e.keyspace.quota if e.keyspace.quota_set else owner_quota_default
	return quota, 0
}

keyspace_owners_totals :: proc() -> Owner_Totals {
	return {}
}
