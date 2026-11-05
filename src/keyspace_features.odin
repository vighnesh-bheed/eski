package main

import ks "keyspace"

keyspace_features_blocked :: proc(db: int, key: []u8) -> bool {
	if db < 0 || db >= len(block_keys) {
		return false
	}
	blocked := block_keys[db][string(key)]
	return blocked != nil && len(blocked.waiters) > 0
}

keyspace_features_aof :: proc(task: ^Keyspace_Task) {
	if !aof.feed || task.rolled_back {
		return
	}
	started := !aof.in_tx
	if started {
		aof_tx_begin(&task.client, nil, nil)
	}
	defer {
		if started {
			aof_tx_end()
		}
	}
	for event in task.events {
		if event.kind == .Notify && event.class == .Expired && event.always {
			args := [2][]u8{transmute([]u8)string("DEL"), event.key}
			aof_feed_argv_direct(event.db, args[:])
		}
	}
	if task.failed || (task.dirty == 0 && task.subexpired == 0) {
		return
	}
	if task.hash_aof_ready {
		aof_keyspace_hash(task)
		return
	}
	if task.op == .Set && len(task.argv) == 3 && task.ok {
		args := [3][]u8{transmute([]u8)string("SET"), task.argv[1], task.argv[2]}
		aof_feed_argv_direct(task.client.db.id, args[:])
		return
	}
	for state in task.poststates {
		if !state.exists {
			args := [2][]u8{transmute([]u8)string("DEL"), state.key}
			aof_feed_argv_direct(state.db, args[:])
			continue
		}
		if state.payload == nil {
			store_fatal("keyspace durable snapshot ownership invariant")
		}
		text: [24]u8
		n := format_i64(raw_data(text[:]), state.expires)
		args := [6][]u8{transmute([]u8)string("RESTORE"), state.key, text[:n], ks.value_data(state.payload), transmute([]u8)string("REPLACE"), transmute([]u8)string("ABSTTL")}
		aof_feed_argv_direct(state.db, args[:])
	}
}

keyspace_features_publish :: proc(task: ^Keyspace_Task, source: ^Conn) {
	if task.rolled_back {
		return
	}
	saved_source, saved_db, saved_stat := ps_exec, db_cur, stat_cur
	defer {
		ps_exec, db_cur, stat_cur = saved_source, saved_db, saved_stat
	}
	ps_exec, db_cur, stat_cur = source, task.client.db, nil
	if source != nil && source.pubsub != nil {
		source.pubsub.mark = source.wlen-source.wpos
	}
	keyspace_features_aof(task)
	for event in task.events {
		if task.failed && !event.always {
			continue
		}
		if event.db < 0 || event.db >= len(dbs) {
			store_fatal("keyspace event database invariant")
		}
		db := &dbs[event.db]
		for _ in 0..<max(1, event.repeat) {
			switch event.kind {
			case .Invalidate:
				watch_touch(event.key, db, true, event.exists)
				if tracking_on {
					tracking_invalidate_key(event.key, event.attributed)
				}
			case .Notify:
				notify_in(event.class, event.name, event.key, db)
			case .Wake:
				block_signal_key(db, event.key, event.object_type)
			}
		}
	}
	if !task.failed && len(monitors) > 0 {
		monitor_feed(&task.client, task.command, task.argv)
	}
}

keyspace_features_after_reply :: proc(task: ^Keyspace_Task, source: ^Conn) {
	if source == nil || task.failed {
		return
	}
	saved := ps_exec
	defer ps_exec = saved
	ps_exec = source
	injected := task.suppressed && source.reply == {}
	if injected {
		source.reply += {.Skip}
	}
	tx_reply_managed = false
	pubsub_after(source, task.command, task.argv)
	if injected {
		source.reply -= {.Skip}
	}
	if client_buckets_on {
		client_bucket_track(source)
	}
}
