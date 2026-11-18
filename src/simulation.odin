package main

import "core:sys/linux"
import "sysclock"

SIMULATION :: sysclock.SIMULATION

Simulation_Transport :: struct {
	read: proc(fd: linux.Fd, bytes: []u8) -> (int, linux.Errno),
	write: proc(fd: linux.Fd, bytes: []u8) -> (int, linux.Errno),
	close: proc(fd: linux.Fd),
}

when SIMULATION {

	simulation_transport: Simulation_Transport
	simulation_aof_sink: proc(db: i32, bytes: []u8)
	simulation_aof_db := i32(-1)

	simulation_init :: proc(transport: Simulation_Transport, seed: u64, scoped, with_owners: bool) {
		simulation_transport = transport
		config_init()
		debug_hash_seed = i64(seed & u64(max(i64))) | 1
		label_stream_seed = debug_hash_seed
		rng_state = u64(debug_hash_seed) << 1 | 1
		clear(&pst.save_params)
		cfg.enable_debug_command = 1
		if scoped {
			label_levels_set({transmute([]u8)string("U,S")})
			if with_owners {
				owners_setting_set({transmute([]u8)string("yes")})
			}
		}
		label_scheme_startup()
		mono_init()
		update_clock()
		srv.start_ms = srv.now_ms
		db_init()
		block_init()
		argv_init()
		commands_init()
		srv.conns = make([dynamic]^Conn, 16)
		if scoped {
			simulation_acl_user("visible", "U", "owner:visible" if with_owners else "")
			simulation_acl_user("hidden", "U" if with_owners else "S", "owner:hidden" if with_owners else "")
		}
		acl_startup()
		hash_store_init()
		stats_init()
		info_init()
		persist_init_commands()
		persist_update_gate()
	}

	@(private)
	simulation_acl_user :: proc(name, marking, owner_rule: string) {
		rules := []string{"user", name, "on", "nopass", "~*", "&*", "+@all", "clearance:U" if marking == "U" else "clearance:S", owner_rule}
		argv := make([][]u8, len(rules), context.temp_allocator)
		for rule, i in rules {
			argv[i] = transmute([]u8)rule
		}
		used := len(argv) - 1 if owner_rule == "" else len(argv)
		_, problem := acl_config_directive(argv[:used])
		assert(problem == "")
	}

	simulation_accept :: proc(fd: linux.Fd, kind: Conn_Kind) {
		c := conn_allocate(fd, kind)
		c.local_peer = true
		conn_register(c)
	}

	simulation_time :: proc(ms: i64) {
		sysclock.simulation_set(ms * 1_000_000)
		update_clock()
	}

	simulation_event :: proc(fd: linux.Fd, events: linux.EPoll_Event_Set) -> bool {
		if srv.conns[fd] != nil {
			handle_event(srv.conns[fd], events)
		}
		if aof.feed || len(aof.deferred) > 0 || len(aof.buf) > 0 {
			aof_before_sleep()
		}
		return srv.conns[fd] != nil
	}

	simulation_pending :: proc(fd: linux.Fd) -> bool {
		c := srv.conns[fd]
		return c != nil && c.wlen > c.wpos
	}

	simulation_cron :: proc() {
		db_tick()
		server_cron()
		if aof.feed {
			aof_before_sleep()
		}
	}

	simulation_capture :: proc(sink: proc(db: i32, bytes: []u8)) {
		simulation_aof_sink = sink
		aof.fd = 1 if sink != nil else -1
		aof.state = .Enabled if sink != nil else .Disabled
		aof.fsync = .No
		aof.auto_pct = 0
		aof.selected_db = -1
		simulation_aof_db = -1
		aof_update_feed()
	}

	simulation_clear :: proc() {
		db_flush_all()
		search_definitions_clear()
		pst.dirty = 0
		pst.dirty_explicit = false
	}
}
