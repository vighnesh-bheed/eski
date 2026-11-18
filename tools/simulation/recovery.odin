package simulation

import "core:fmt"
import engine "../../src"
import log "../../src/changelog"

make_epoch :: proc(seed: u64, scenario: u8) -> (epoch: log.Epoch) {
	for i in 0 ..< 8 {
		epoch[i] = u8(seed >> uint(8 * i))
	}
	epoch[8] = scenario
	return
}

disk_payload :: proc(index: int) -> string {
	return fmt.tprintf("resumable-record-%015d", index)
}

disk_put :: proc(writer: ^log.Log, position: int) -> log.Status {
	return log.append_record(writer, i32(position), transmute([]u8)disk_payload(position))
}

read_prefix :: proc(disk: log.Disk, epoch: log.Epoch, retained, lower, upper: int) {
	cursor, status := log.first(disk)
	require(status == .Ok && cursor.epoch == epoch && cursor.position == u64(retained), "recovery reports expected epoch and retention floor")
	scratch: [dynamic]u8
	defer delete(scratch)
	seen := retained - 1
	for {
		record, next_status := log.read(disk, cursor, &scratch)
		if next_status == .End {
			break
		}
		require(next_status == .Ok, "recovered records are entirely valid")
		seen += 1
		require(seen <= upper, "recovered prefix is bounded by generated records")
		require(record.db == i32(seen) && string(record.payload) == disk_payload(seen), "recovered sequence is an exact prefix")
		cursor.position += 1
	}
	trace("oracle prefix ends=%d true-sync=%d submitted=%d", seen, lower, upper)
	require(seen >= lower && seen <= upper, "recovered prefix contains the true synced boundary")
}

fault_case :: proc(seed: u64, fault: Fault, scenario: u8, tear: int = 0) {
	trace("fault scenario=%v tear=%d", fault, tear)
	disk: Disk_Model
	defer disk_destroy(&disk)
	disk.short_write = 9 + int(seed % 9)
	seam := disk_io(&disk)
	epoch := make_epoch(seed, scenario)
	limits := log.Limits{4096, 8192}
	if fault == .Directory_Sync {
		limits = {128, 512}
	}
	writer: log.Log
	defer log.close(&writer)
	require(log.begin(&writer, seam, epoch, limits) == .Ok, "new epoch is durable")
	require(disk_put(&writer, 1) == .Ok, "first baseline frame is durable")
	lower := 1
	if fault != .Directory_Sync {
		require(disk_put(&writer, 2) == .Ok, "second baseline frame is durable")
		lower = 2
	}
	disk.fault = fault
	if fault == .Write {
		disk.fault_after = 1
	}
	result := disk_put(&writer, lower + 1)
	if fault == .Lie_Sync {
		require(result == .Ok && disk.lie_count == 1, "the device falsely claims sync for the complete final record")
	} else {
		require(result == .IO && writer.stopped, "explicit I/O failure stops writer continuation")
		require(disk_put(&writer, lower + 2) == .Offline, "a stopped writer cannot reuse the position")
	}
	log.close(&writer)
	disk_crash(&disk, tear)
	if tear > 0 {
		disk.fault = .Truncate
		require(log.recover(&writer, seam, limits) == .IO, "failed truncate does not claim tail repair")
	}
	require(log.recover(&writer, seam, limits) == .Ok, "recover the last valid prefix with real framing")
	read_prefix(seam, epoch, 1, lower, lower)
	require(disk_put(&writer, lower + 1) == .Ok, "recovered writer reuses only its incomplete next position")
	read_prefix(seam, epoch, 1, lower + 1, lower + 1)
}

run_disk :: proc(seed: u64) {
	fault_case(seed, .Write, 1)
	fault_case(seed, .Sync, 2)
	fault_case(seed, .Directory_Sync, 3)
	fault_case(seed, .Lie_Sync, 4)
	fault_case(seed, .Lie_Sync, 5, 1 + int(seed % 26))
	fault_case(seed, .Lie_Sync, 6, 29 + int(seed % 10))

	disk: Disk_Model
	defer disk_destroy(&disk)
	seam := disk_io(&disk)
	epoch := make_epoch(seed, 7)
	limits := log.Limits{128, 200}
	writer: log.Log
	defer log.close(&writer)
	require(log.begin(&writer, seam, epoch, limits) == .Ok, "retention case has a durable epoch")
	for pos in 1 ..= 4 {
		require(disk_put(&writer, pos) == .Ok, "rolled segment is synced before pruning previous history")
	}
	log.close(&writer)
	disk_crash(&disk)
	require(log.recover(&writer, seam, limits) == .Ok, "retained segments reopen")
	read_prefix(seam, epoch, 3, 4, 4)
	buffer: [dynamic]u8
	defer delete(buffer)
	_, stale := log.read(seam, {epoch, 2}, &buffer)
	require(stale == .Stale, "a pruned cursor reports stale")
	disk_flip_byte(&disk, {.Segment, {epoch, 4}}, log.SEGMENT_HEADER_SIZE + log.FRAME_HEADER_SIZE)
	disk_crash(&disk)
	_, corrupt := log.read(seam, {epoch, 4}, &buffer)
	require(corrupt == .Corrupt, "reader never exposes complete corrupt frame")
	log.close(&writer)
	require(log.recover(&writer, seam, limits) == .Corrupt, "complete frame integrity failure is not truncated")
}

restart_writer: log.Log

on_aof_batch :: proc(db: i32, bytes: []u8) {
	trace("canonical batch position=%d db=%d bytes=%q", restart_writer.next.position, db, string(bytes))
	require(log.append_record(&restart_writer, db, bytes) == .Ok, "canonical batch appends through shared framing")
}

run_restart :: proc(seed: u64) {
	start_network(seed)
	open_link(1, .Redis)
	disk: Disk_Model
	defer disk_destroy(&disk)
	seam := disk_io(&disk)
	epoch := make_epoch(seed, 8)
	limits := log.Limits{4096, 8192}
	defer log.close(&restart_writer)
	require(log.begin(&restart_writer, seam, epoch, limits) == .Ok, "canonical feed has a durable initial epoch")
	engine.simulation_capture(on_aof_batch)
	exchange(1, resp("SELECT", "2"), "+OK\r\n", "select simulated database 2")
	exchange(1, resp("SET", "counter", "5"), "+OK\r\n", "first selected-database write acknowledged")
	exchange(1, resp("MULTI"), "+OK\r\n", "transaction starts")
	exchange(1, resp("INCR", "counter"), "+QUEUED\r\n", "counter write waits for EXEC")
	exchange(1, resp("HSET", "doc", "title", "alpha"), "+QUEUED\r\n", "hash write waits for EXEC")
	exchange(1, resp("EXEC"), "*2\r\n:6\r\n:1\r\n", "both writes acknowledged atomically")
	true_next := restart_writer.next.position
	require(true_next == 3, "real canonical stream has two batches and whole MULTI group")
	disk.fault = .Lie_Sync
	exchange(1, resp("SET", "unsynced", "lost"), "+OK\r\n", "write returns although fake device lies")
	require(restart_writer.next.position == true_next + 1 && disk.lie_count == 1, "claimed mirror boundary exceeds true boundary")
	engine.simulation_capture(nil)
	log.close(&restart_writer)
	disk_crash(&disk, 1 + int(seed % 20))
	require(log.recover(&restart_writer, seam, limits) == .Ok, "canonical stream recovers torn last batch")
	require(restart_writer.next.position == true_next, "recovered canonical prefix reaches true sync and excludes lying tail")
	engine.simulation_clear()
	buffer: [dynamic]u8
	defer delete(buffer)
	cursor := log.Cursor{epoch, 1}
	for cursor.position < true_next {
		record, status := log.read(seam, cursor, &buffer)
		require(status == .Ok, "load a verified canonical batch")
		require(record.db == (-1 if cursor.position == 1 else 2), "starting selected database survives framing")
		require(engine.simulation_aof_replay(record.db, record.payload) == .Loaded, "real Eski AOF loader rebuilds the recovered batch")
		cursor.position += 1
	}
	exchange(1, cat(resp("GET", "counter"), resp("HGET", "doc", "title"), resp("GET", "unsynced")), cat(bulk("6"), bulk("alpha"), "$-1\r\n"), "engine state matches the true synced prefix")
	exchange(1, cat(resp("SELECT", "0"), resp("GET", "counter")), "+OK\r\n$-1\r\n", "replayed writes stay in their database")
}
