package main

import "core:testing"
import "base:runtime"

@(test)
client_metadata_owned_capacity_and_release :: proc(t: ^testing.T) {
	baseline := client_metadata_total
	c := Conn{fd = -1}
	st := tx_state(&c)
	st.watched = make([dynamic]Watched_Key, 0, 33)
	ps := ps_state(&c)
	ps.trk_prefixes = make([dynamic][]u8, 0, 17)
	ps.deferred = make([dynamic]u8, 0, 257)
	ps.lists[.Channel] = make([dynamic]^Ps_Entry, 0, 19)
	client_metadata_sync(&c)
	expected := size_of(Tx_State) + cap(st.watched) * size_of(Watched_Key) + size_of(Ps_State) + cap(ps.trk_prefixes) * size_of([]u8) + cap(ps.deferred) + cap(ps.lists[.Channel]) * size_of(^Ps_Entry)
	testing.expect_value(t, client_metadata_memory(&c), expected)
	testing.expect_value(t, client_metadata_total - baseline, expected)
	client_metadata_sync(&c)
	testing.expect_value(t, client_metadata_total - baseline, expected)
	tx_conn_closed(&c)
	pubsub_conn_closed(&c)
	testing.expect_value(t, client_metadata_total, baseline)
}

@(test)
client_metadata_subscription_owner_transfer :: proc(t: ^testing.T) {
	saved_maps := ps_maps
	ps_maps = {}
	defer { for m in ps_maps { delete(m) }; ps_maps = saved_maps }
	baseline := client_metadata_total
	a, b := Conn{fd = -1}, Conn{fd = -1}
	name_text: string = "native-metadata-shared-subscription"
	name := transmute([]u8)name_text
	testing.expect(t, ps_subscribe(&a, .Channel, name))
	testing.expect(t, ps_subscribe(&b, .Channel, name))
	entry := ps_maps[.Channel][string(name)]
	shared := size_of(Ps_Entry) + len(name) + cap(entry.subs) * size_of(^Conn)
	testing.expect_value(t, a.pubsub.metadata_shared, shared)
	testing.expect_value(t, b.pubsub.metadata_shared, 0)
	testing.expect(t, ps_unsubscribe(&a, .Channel, name))
	testing.expect_value(t, a.pubsub.metadata_shared, 0)
	testing.expect_value(t, b.pubsub.metadata_shared, shared)
	pubsub_conn_closed(&a)
	pubsub_conn_closed(&b)
	testing.expect_value(t, client_metadata_total, baseline)
}

@(test)
client_metadata_tracking_prefix_owner_transfer :: proc(t: ^testing.T) {
	baseline := client_metadata_total
	a, b := Conn{fd = -1, id = -101}, Conn{fd = -1, id = -102}
	client_metadata_native_tracking(&a)
	client_metadata_native_tracking(&b)
	testing.expect(t, a.pubsub.metadata_shared > 0)
	testing.expect_value(t, b.pubsub.metadata_shared, 0)
	tracking_disable(&a)
	testing.expect_value(t, a.pubsub.metadata_shared, 0)
	testing.expect(t, b.pubsub.metadata_shared > 0)
	pubsub_conn_closed(&a)
	pubsub_conn_closed(&b)
	testing.expect_value(t, client_metadata_total, baseline)
}

client_metadata_native_tracking :: proc(c: ^Conn) {
	words := [6]string{"client", "tracking", "on", "bcast", "prefix", "native-metadata-prefix:"}
	args: [6][]u8
	for word, i in words { args[i] = transmute([]u8)word }
	client_tracking(c, args[:])
	conn_mem -= c.wcap
	runtime.heap_free(c.wbuf)
	c.wbuf = nil; c.wcap = 0; c.wlen = 0
}
