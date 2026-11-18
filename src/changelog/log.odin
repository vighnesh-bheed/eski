package changelog

import "core:slice"

Limits :: struct {
	segment_bytes: i64,
	retain_bytes: i64,
}

Segment :: struct {
	cursor: Cursor,
	size: i64,
}

Log :: struct {
	disk: Disk,
	limits: Limits,
	next: Cursor,
	segments: [dynamic]Segment,
	bytes: i64,
	stopped: bool,
}

close :: proc(log: ^Log) {
	delete(log.segments)
	log^ = {}
}

@(private)
valid_limits :: proc(limits: Limits) -> bool {
	return limits.segment_bytes >= SEGMENT_HEADER_SIZE + FRAME_HEADER_SIZE + 1 && limits.retain_bytes >= limits.segment_bytes
}

@(private)
read_epoch :: proc(disk: Disk) -> (Epoch, Status) {
	file, opened := disk.open(disk.state, {kind = .Epoch}, .Read)
	if opened != .Ok {
		return {}, opened
	}
	defer disk.close(disk.state, file)
	size, sized := disk.size(disk.state, file)
	if sized != .Ok {
		return {}, sized
	}
	if size != EPOCH_HEADER_SIZE {
		return {}, .Corrupt
	}
	header: [EPOCH_HEADER_SIZE]u8
	if status := read_full(disk, file, 0, header[:]); status != .Ok {
		return {}, status
	}
	epoch, valid := decode_epoch(header[:])
	return epoch, .Ok if valid else .Corrupt
}

@(private)
list_segments :: proc(disk: Disk, epoch: Epoch, ids: ^[dynamic]Cursor) -> Status {
	if status := disk.list(disk.state, ids); status != .Ok {
		return status
	}
	kept := 0
	for id in ids^ {
		if id.epoch == epoch {
			if id.position == 0 {
				return .Corrupt
			}
			ids[kept] = id
			kept += 1
		}
	}
	resize(ids, kept)
	if kept == 0 {
		return .Corrupt
	}
	slice.sort_by(ids[:], proc(a, b: Cursor) -> bool { return a.position < b.position })
	return .Ok
}

@(private)
open_segment :: proc(disk: Disk, id: Cursor, mode: Open_Mode) -> (File, i64, Status) {
	file, status := disk.open(disk.state, {.Segment, id}, mode)
	if status != .Ok {
		return {}, 0, .Corrupt if status == .Missing else status
	}
	size: i64
	size, status = disk.size(disk.state, file)
	if status == .Ok {
		if size < SEGMENT_HEADER_SIZE {
			status = .Corrupt
		} else {
			header: [SEGMENT_HEADER_SIZE]u8
			status = read_full(disk, file, 0, header[:])
			if status == .Ok && header != encode_segment(id) {
				status = .Corrupt
			}
		}
	}
	if status != .Ok {
		disk.close(disk.state, file)
	}
	return file, size, status
}

@(private)
read_frame :: proc(disk: Disk, file: File, offset, size: i64, position: u64, buffer: ^[dynamic]u8) -> (i32, i64, Status) {
	if offset == size {
		return 0, offset, .End
	}
	if size - offset < FRAME_HEADER_SIZE {
		return 0, offset, .Incomplete
	}
	header: [FRAME_HEADER_SIZE]u8
	if status := read_full(disk, file, offset, header[:]); status != .Ok {
		return 0, offset, status
	}
	n, db, checksum, status := decode_frame(header[:], position)
	if status != .Ok {
		return 0, offset, status
	}
	payload := offset + FRAME_HEADER_SIZE
	if i64(n) > size - payload {
		return 0, offset, .Incomplete
	}
	if resize(buffer, n) != nil {
		return 0, offset, .IO
	}
	if status = read_full(disk, file, payload, buffer[:]); status != .Ok {
		return 0, offset, status
	}
	if crc32c(buffer[:]) != checksum {
		return 0, offset, .Corrupt
	}
	return db, payload + i64(n), .Ok
}

@(private)
scan_segment :: proc(disk: Disk, id: Cursor, tail: bool, buffer: ^[dynamic]u8) -> (u64, i64, Status) {
	file, size, opened := open_segment(disk, id, .Update if tail else .Read)
	if opened != .Ok {
		return 0, 0, opened
	}
	defer disk.close(disk.state, file)
	offset := i64(SEGMENT_HEADER_SIZE)
	position := id.position
	for {
		_, next_offset, status := read_frame(disk, file, offset, size, position, buffer)
		#partial switch status {
		case .Ok:
			offset = next_offset
			position += 1
		case .End:
			return position, offset, .Ok
		case .Incomplete:
			if !tail {
				return 0, 0, .Corrupt
			}
			if disk.truncate(disk.state, file, offset) != .Ok || disk.sync(disk.state, file) != .Ok {
				return 0, 0, .IO
			}
			return position, offset, .Ok
		case:
			return 0, 0, status
		}
	}
}

recover :: proc(log: ^Log, disk: Disk, limits: Limits) -> (status: Status) {
	if !valid_limits(limits) || len(log.segments) != 0 {
		return .Invalid
	}
	epoch: Epoch
	epoch, status = read_epoch(disk)
	if status != .Ok {
		return
	}
	ids: [dynamic]Cursor
	defer delete(ids)
	if status = list_segments(disk, epoch, &ids); status != .Ok {
		return
	}
	next := ids[0].position
	buffer: [dynamic]u8
	defer delete(buffer)
	log^ = {disk = disk, limits = limits}
	defer if status != .Ok {
		close(log)
	}
	for id, i in ids {
		if id.position != next {
			return .Corrupt
		}
		size: i64
		next, size, status = scan_segment(disk, id, i == len(ids) - 1, &buffer)
		if status != .Ok {
			return
		}
		if (i < len(ids) - 1 && next == id.position) || size > max(i64) - log.bytes {
			return .Corrupt
		}
		append(&log.segments, Segment{id, size})
		log.bytes += size
	}
	log.next = {epoch, next}
	return .Ok
}

begin :: proc(log: ^Log, disk: Disk, epoch: Epoch, limits: Limits) -> (status: Status) {
	if epoch == {} || !valid_limits(limits) || len(log.segments) != 0 {
		return .Invalid
	}
	current, existing := read_epoch(disk)
	if existing != .Missing && existing != .Ok {
		return existing
	}
	if existing == .Ok && current == epoch {
		return .Invalid
	}
	ids: [dynamic]Cursor
	defer delete(ids)
	if status = disk.list(disk.state, &ids); status != .Ok {
		return
	}
	for id in ids {
		if id.epoch == epoch {
			return .Invalid
		}
	}
	log^ = {disk = disk, limits = limits, next = {epoch, 1}}
	defer if status != .Ok {
		close(log)
	}
	if status = roll(log); status != .Ok {
		return
	}
	header := encode_epoch(epoch)
	if status = replace_file(disk, {kind = .Epoch}, header[:]); status != .Ok {
		return
	}
	for id in ids {
		if status = disk.remove(disk.state, {.Segment, id}); status != .Ok {
			return
		}
	}
	if len(ids) > 0 {
		status = disk.sync_dir(disk.state)
	}
	return
}

@(private)
roll :: proc(log: ^Log) -> Status {
	if log.bytes > max(i64) - SEGMENT_HEADER_SIZE {
		return .Too_Large
	}
	header := encode_segment(log.next)
	if status := replace_file(log.disk, {.Segment, log.next}, header[:]); status != .Ok {
		return status
	}
	append(&log.segments, Segment{log.next, SEGMENT_HEADER_SIZE})
	log.bytes += SEGMENT_HEADER_SIZE
	return .Ok
}

@(private)
prune :: proc(log: ^Log) -> Status {
	disk := log.disk
	removed := 0
	for log.bytes > log.limits.retain_bytes && removed < len(log.segments) - 1 {
		old := log.segments[removed]
		if status := disk.remove(disk.state, {.Segment, old.cursor}); status != .Ok {
			return status
		}
		if status := disk.sync_dir(disk.state); status != .Ok {
			return status
		}
		log.bytes -= old.size
		removed += 1
	}
	remove_range(&log.segments, 0, removed)
	return .Ok
}

append_record :: proc(log: ^Log, db: i32, payload: []u8) -> (status: Status) {
	if log.stopped || len(log.segments) == 0 {
		return .Offline
	}
	defer log.stopped = status != .Ok
	if len(payload) == 0 || db < -1 {
		return .Invalid
	}
	if len(payload) > MAX_PAYLOAD || log.next.position == max(u64) {
		return .Too_Large
	}
	frame_bytes := i64(FRAME_HEADER_SIZE + len(payload))
	current := &log.segments[len(log.segments) - 1]
	if current.size > SEGMENT_HEADER_SIZE && frame_bytes > log.limits.segment_bytes - current.size {
		if status = roll(log); status != .Ok {
			return
		}
		current = &log.segments[len(log.segments) - 1]
	}
	if frame_bytes > max(i64) - log.bytes {
		return .Too_Large
	}
	disk := log.disk
	file, opened := disk.open(disk.state, {.Segment, current.cursor}, .Update)
	if opened != .Ok {
		return opened
	}
	defer disk.close(disk.state, file)
	size, sized := disk.size(disk.state, file)
	if sized != .Ok {
		return sized
	}
	if size != current.size {
		return .Corrupt
	}
	header := encode_frame(log.next.position, db, payload)
	status = write_full(disk, file, current.size, header[:])
	if status == .Ok {
		status = write_full(disk, file, current.size + FRAME_HEADER_SIZE, payload)
	}
	if status == .Ok {
		status = disk.sync(disk.state, file)
	}
	if status != .Ok {
		if disk.truncate(disk.state, file, current.size) != .Ok || disk.sync(disk.state, file) != .Ok {
			return .IO
		}
		return
	}
	current.size += frame_bytes
	log.bytes += frame_bytes
	log.next.position += 1
	return prune(log)
}

first :: proc(disk: Disk) -> (Cursor, Status) {
	epoch, status := read_epoch(disk)
	if status != .Ok {
		return {}, status
	}
	ids: [dynamic]Cursor
	defer delete(ids)
	if status = list_segments(disk, epoch, &ids); status != .Ok {
		return {}, status
	}
	return ids[0], .Ok
}

read :: proc(disk: Disk, cursor: Cursor, buffer: ^[dynamic]u8) -> (Record, Status) {
	if cursor.epoch == {} || cursor.position == 0 {
		return {}, .Invalid
	}
	epoch, status := read_epoch(disk)
	if status != .Ok {
		return {}, status
	}
	if cursor.epoch != epoch {
		return {}, .Wrong_Epoch
	}
	ids: [dynamic]Cursor
	defer delete(ids)
	if status = list_segments(disk, epoch, &ids); status != .Ok {
		return {}, status
	}
	if cursor.position < ids[0].position {
		return {}, .Stale
	}
	index := len(ids) - 1
	for index > 0 && ids[index].position > cursor.position {
		index -= 1
	}
	id := ids[index]
	file, size, opened := open_segment(disk, id, .Read)
	if opened != .Ok {
		return {}, opened
	}
	defer disk.close(disk.state, file)
	offset := i64(SEGMENT_HEADER_SIZE)
	for position := id.position; position <= cursor.position; position += 1 {
		db, next_offset, frame_status := read_frame(disk, file, offset, size, position, buffer)
		#partial switch frame_status {
		case .Ok:
			if position == cursor.position {
				return {cursor, db, buffer[:]}, .Ok
			}
			offset = next_offset
		case .End:
			if index < len(ids) - 1 {
				return {}, .Corrupt
			}
			return {}, .End if position == cursor.position else .Ahead
		case .Incomplete:
			return {}, .Incomplete if index == len(ids) - 1 else .Corrupt
		case:
			return {}, frame_status
		}
	}
	return {}, .Corrupt
}
