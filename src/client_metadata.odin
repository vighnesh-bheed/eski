package main

import "base:runtime"

client_metadata_total: int

client_metadata_memory :: proc "contextless" (c: ^Conn) -> int {
	n := 0
	if s := c.tx; s != nil { n += size_of(Tx_State) + cap(s.watched) * size_of(Watched_Key) + s.watch_shared }
	if s := c.pubsub; s != nil {
		n += size_of(Ps_State) + cap(s.deferred) + cap(s.trk_prefixes) * size_of([]u8) + s.metadata_shared
		for kind in Ps_Kind { n += cap(s.lists[kind]) * size_of(^Ps_Entry) }
	}
	if c.label != nil { n += size_of(Access_Conn) }
	return n
}

client_metadata_sync :: proc(c: ^Conn) {
	before := 0
	if c.tx != nil { before += c.tx.metadata_accounted }
	if c.pubsub != nil { before += c.pubsub.metadata_accounted }
	if c.label != nil { before += c.label.accounted }
	after := client_metadata_memory(c)
	if c.tx != nil { c.tx.metadata_accounted = size_of(Tx_State) + cap(c.tx.watched) * size_of(Watched_Key) + c.tx.watch_shared }
	if c.label != nil { c.label.accounted = size_of(Access_Conn) }
	if c.pubsub != nil { c.pubsub.metadata_accounted = after - (c.tx.metadata_accounted if c.tx != nil else 0) - (c.label.accounted if c.label != nil else 0) }
	client_metadata_total += after - before
	if client_buckets_on { client_bucket_track(c) }
}

client_metadata_drop_tx :: proc(c: ^Conn) {
	client_metadata_total -= c.tx.metadata_accounted
	c.tx.metadata_accounted = 0
}

client_metadata_drop_ps :: proc(c: ^Conn) {
	client_metadata_total -= c.pubsub.metadata_accounted
	c.pubsub.metadata_accounted = 0
}

client_map_memory :: proc "contextless" (m: $M/map[$K]$V) -> int {
	return int(runtime.map_total_allocation_size_from_value(m)) if cap(m) > 0 else 0
}

client_registry_memory :: proc "contextless" () -> int {
	n := len(watch_dbs) * size_of(map[string]^Watch_Key) + cap(ps_patterns) * size_of(^Ps_Entry) + cap(ps_conns) * size_of(^Conn)
	for m in watch_dbs { n += client_map_memory(m) }
	for m in ps_maps { n += client_map_memory(m) }
	return n + pubsub_registry_memory() + tracking_registry_memory()
}

watch_metadata_adjust :: proc(wk: ^Watch_Key, sign: int) {
	if len(wk.watchers) == 0 { return }
	c := wk.watchers[0].c
	c.tx.watch_shared += sign * (size_of(Watch_Key) + len(wk.key) + cap(wk.watchers) * size_of(Watcher))
	client_metadata_sync(c)
}

ps_metadata_adjust :: proc(e: ^Ps_Entry, sign: int) {
	if len(e.subs) == 0 { return }
	c := e.subs[0]
	c.pubsub.metadata_shared += sign * (size_of(Ps_Entry) + len(e.name) + cap(e.subs) * size_of(^Conn))
	client_metadata_sync(c)
}
