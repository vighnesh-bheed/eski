package persistence

import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import j "../../src"

wait_quiet :: proc() -> bool {
	for _ in 0 ..< 600 {
		if j.pst.child_pid == 0 && !j.pst.bgsave_scheduled && !j.aof.rewrite_scheduled {
			return true
		}
		ts := linux.Time_Spec {
			time_nsec = 10_000_000,
		}
		linux.nanosleep(&ts, nil)
		j.persist_cron()
	}
	return false
}

latest_base :: proc(dir: string) -> string {
	entries, err := os.read_all_directory_by_path(join_path(dir, "appendonlydir"), context.temp_allocator)
	if err != nil {
		return ""
	}
	best := ""
	for e in entries {
		if strings.has_suffix(e.name, ".base.rdb") && e.name > best {
			best = e.fullpath
		}
	}
	return best
}

@(test)
aof_hooks_through_persistence :: proc(t: ^testing.T) {
	server_reset()
	dir := test_dir()
	defer cleanup_dir(dir)
	enter_dir(dir)
	defer leave_dir()
	j.config_reading_file = true
	appendonly := j.config_lookup(transmute([]u8)string("appendonly"))
	j.config_set_value(appendonly, transmute([]u8)string("yes"))
	j.config_reading_file = false
	j.persist_startup()
	testing.expect(t, j.aof.started)
	testing.expect_value(t, j.aof.state, j.Aof_Status.Enabled)
	populate_all_types()
	cmd("DEL", "nokey")
	digest := cmd("DEBUG", "DIGEST")
	j.aof_flush(true)
	expect_reply(t, cmd("DEBUG", "LOADAOF"), "+OK\r\n", "loadaof")
	expect_reply(t, cmd("DEBUG", "DIGEST"), digest, "digest after loadaof")
	expect_reply(t, cmd("BGREWRITEAOF"), "+Background append only file rewriting started\r\n", "rewrite")
	testing.expect(t, j.pst.child_pid != 0 && j.pst.child_aof)
	testing.expect_value(t, info_field("rdb_bgsave_in_progress"), "0")
	expect_reply(t, cmd("BGSAVE"), "-ERR Another child process is active (AOF?): can't BGSAVE right now. Use BGSAVE SCHEDULE in order to schedule a BGSAVE whenever possible.\r\n", "bgsave behind rewrite")
	expect_reply(t, cmd("BGSAVE", "SCHEDULE"), "+Background saving scheduled\r\n", "schedule behind rewrite")
	expect_reply(t, cmd("SAVE"), "+OK\r\n", "save during rewrite")
	testing.expect(t, wait_quiet())
	testing.expect_value(t, info_field("aof_last_bgrewrite_status"), "ok")
	testing.expect_value(t, info_field("aof_rewrites"), "1")
	testing.expect_value(t, info_field("rdb_last_bgsave_status"), "ok")
	testing.expect(t, file_exists(join_path(dir, "dump.rdb")))
	base := latest_base(dir)
	testing.expect(t, len(base) > 0)
	data, ok := read_file(base)
	testing.expect(t, ok)
	w := walk_rdb(data)
	testing.expectf(t, w.ok, "base walk %s on %s (%d bytes)", w.reason, base, len(data))
	if !w.ok {
		entries, _ := os.read_all_directory_by_path(join_path(dir, "appendonlydir"), context.temp_allocator)
		for e in entries {
			testing.expectf(t, false, "entry %s size %d", e.name, e.size)
		}
		manifest, _ := read_file(join_path(dir, "appendonlydir/appendonly.aof.manifest"))
		testing.expectf(t, false, "manifest %q", string(manifest))
	}
	aof_base, _ := walk_aux(&w, "aof-base")
	testing.expect_value(t, aof_base, "1")
	testing.expect_value(t, len(w.keys), 11)
	walk_destroy(&w)
	delete(data)
	cmd("SET", "after-rewrite", "1")
	digest = cmd("DEBUG", "DIGEST")
	j.aof_flush(true)
	expect_reply(t, cmd("DEBUG", "LOADAOF"), "+OK\r\n", "loadaof after rewrite")
	expect_reply(t, cmd("DEBUG", "DIGEST"), digest, "digest after second loadaof")
	expect_reply(t, cmd("CONFIG", "SET", "appendonly", "no"), "+OK\r\n", "appendonly off")
	testing.expect_value(t, j.aof.state, j.Aof_Status.Disabled)
	empty := test_dir()
	defer cleanup_dir(empty)
	enter_dir(empty)
	expect_reply(t, cmd("DEBUG", "LOADAOF"), "-ERR Error trying to load the AOF files, check server logs.\r\n", "loadaof without files")
	server_reset()
}
