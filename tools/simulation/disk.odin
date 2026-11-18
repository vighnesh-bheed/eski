package simulation

import log "../../src/changelog"

DISK_FILES :: 64
DISK_FILE_BYTES :: 64 * 1024
SECTOR_BYTES :: 512

Fault :: enum {
	None,
	Write,
	Sync,
	Lie_Sync,
	Directory_Sync,
	Truncate,
}

Inode :: struct {
	used: bool,
	opens: int,
	bytes: [dynamic]u8,
	durable: [dynamic]u8,
}

Entry :: struct {
	inode: int,
	name: log.File_Name,
}

Disk_Model :: struct {
	inodes: [DISK_FILES]Inode,
	names: [DISK_FILES]Entry,
	durable_names: [DISK_FILES]Entry,
	fault: Fault,
	fault_after: int,
	short_write: int,
	lie_count: int,
}

disk_io :: proc(disk: ^Disk_Model) -> log.Disk {
	return {
		state = disk,
		list = disk_list,
		open = disk_open,
		close = disk_close,
		size = disk_size,
		read = disk_read,
		write = disk_write,
		truncate = disk_truncate,
		sync = disk_sync,
		sync_dir = disk_sync_dir,
		rename = disk_rename,
		remove = disk_remove,
	}
}

disk_destroy :: proc(disk: ^Disk_Model) {
	for &page in disk.inodes {
		delete(page.bytes)
		delete(page.durable)
	}
	disk^ = {}
}

entry_for :: proc(names: ^[DISK_FILES]Entry, name: log.File_Name) -> int {
	for entry, i in names {
		if entry.inode != 0 && entry.name == name {
			return i
		}
	}
	return -1
}

free_entry :: proc(names: ^[DISK_FILES]Entry) -> int {
	for entry, i in names {
		if entry.inode == 0 {
			return i
		}
	}
	return -1
}

inode_linked :: proc(names: ^[DISK_FILES]Entry, id: int) -> bool {
	for entry in names {
		if entry.inode == id {
			return true
		}
	}
	return false
}

inode_unref :: proc(disk: ^Disk_Model, id: int) {
	node := &disk.inodes[id - 1]
	if node.opens != 0 || inode_linked(&disk.names, id) || inode_linked(&disk.durable_names, id) {
		return
	}
	delete(node.bytes)
	delete(node.durable)
	node^ = {}
}

allocate_inode :: proc(disk: ^Disk_Model) -> int {
	for &node, i in disk.inodes {
		if !node.used {
			node.used = true
			return i + 1
		}
	}
	return 0
}

file_inode :: proc(state: rawptr, file: log.File) -> ^Inode {
	index := int(file) - 1
	require(index >= 0 && index < DISK_FILES, "disk descriptor lies within its bounds")
	node := &(^Disk_Model)(state).inodes[index]
	require(node.opens > 0, "disk descriptor is open")
	return node
}

hit_fault :: proc(disk: ^Disk_Model, fault: Fault) -> bool {
	if disk.fault != fault {
		return false
	}
	if disk.fault_after > 0 {
		disk.fault_after -= 1
		return false
	}
	disk.fault = .None
	trace("disk inject %v", fault)
	return true
}

disk_list :: proc(state: rawptr, ids: ^[dynamic]log.Cursor) -> log.Status {
	for entry in (^Disk_Model)(state).names {
		if entry.inode != 0 && entry.name.kind == .Segment {
			append(ids, entry.name.segment)
		}
	}
	return .Ok
}

disk_open :: proc(state: rawptr, name: log.File_Name, mode: log.Open_Mode) -> (log.File, log.Status) {
	disk := (^Disk_Model)(state)
	index := entry_for(&disk.names, name)
	if mode == .Create {
		if index >= 0 {
			return 0, .IO
		}
		index = free_entry(&disk.names)
		if index < 0 {
			return 0, .IO
		}
		id := allocate_inode(disk)
		if id == 0 {
			return 0, .IO
		}
		disk.names[index] = {id, name}
	}
	if index < 0 {
		return 0, .Missing
	}
	id := disk.names[index].inode
	disk.inodes[id - 1].opens += 1
	return log.File(id), .Ok
}

disk_close :: proc(state: rawptr, file: log.File) {
	file_inode(state, file).opens -= 1
	inode_unref((^Disk_Model)(state), int(file))
}

disk_size :: proc(state: rawptr, file: log.File) -> (i64, log.Status) {
	return i64(len(file_inode(state, file).bytes)), .Ok
}

disk_read :: proc(state: rawptr, file: log.File, offset: i64, data: []u8) -> (int, log.Status) {
	node := file_inode(state, file)
	if offset < 0 || offset > i64(len(node.bytes)) {
		return 0, .IO
	}
	return copy(data, node.bytes[int(offset):]), .Ok
}

disk_write :: proc(state: rawptr, file: log.File, offset: i64, data: []u8) -> (int, log.Status) {
	disk := (^Disk_Model)(state)
	node := file_inode(state, file)
	if offset < 0 || offset > DISK_FILE_BYTES || hit_fault(disk, .Write) {
		return 0, .IO
	}
	count := len(data)
	if disk.short_write > 0 {
		count = min(count, disk.short_write)
	}
	end := int(offset) + count
	if end > DISK_FILE_BYTES {
		return 0, .IO
	}
	if end > len(node.bytes) {
		resize(&node.bytes, end)
	}
	copy(node.bytes[int(offset):end], data[:count])
	if count != len(data) {
		trace("disk short-write inode=%d offset=%d count=%d requested=%d", int(file), offset, count, len(data))
	}
	return count, .Ok
}

disk_truncate :: proc(state: rawptr, file: log.File, size: i64) -> log.Status {
	disk := (^Disk_Model)(state)
	if size < 0 || size > DISK_FILE_BYTES || hit_fault(disk, .Truncate) {
		return .IO
	}
	trace("disk truncate inode=%d size=%d", int(file), size)
	resize(&file_inode(state, file).bytes, int(size))
	return .Ok
}

disk_sync :: proc(state: rawptr, file: log.File) -> log.Status {
	disk := (^Disk_Model)(state)
	node := file_inode(state, file)
	if hit_fault(disk, .Sync) {
		return .IO
	}
	if hit_fault(disk, .Lie_Sync) {
		disk.lie_count += 1
		return .Ok
	}
	resize(&node.durable, len(node.bytes))
	copy(node.durable[:], node.bytes[:])
	trace("disk file-sync inode=%d bytes=%d", int(file), len(node.durable))
	return .Ok
}

disk_sync_dir :: proc(state: rawptr) -> log.Status {
	disk := (^Disk_Model)(state)
	if hit_fault(disk, .Directory_Sync) {
		return .IO
	}
	disk.durable_names = disk.names
	for &node, i in disk.inodes {
		if node.used {
			inode_unref(disk, i + 1)
		}
	}
	trace("disk directory-sync")
	return .Ok
}

disk_rename :: proc(state: rawptr, from, to: log.File_Name) -> log.Status {
	disk := (^Disk_Model)(state)
	from_slot := entry_for(&disk.names, from)
	if from_slot < 0 {
		return .Missing
	}
	to_slot := entry_for(&disk.names, to)
	if to_slot >= 0 && to_slot != from_slot {
		id := disk.names[to_slot].inode
		disk.names[to_slot] = {}
		inode_unref(disk, id)
	}
	disk.names[from_slot].name = to
	trace("disk rename %v to %v position=%d", from.kind, to.kind, to.segment.position)
	return .Ok
}

disk_remove :: proc(state: rawptr, name: log.File_Name) -> log.Status {
	disk := (^Disk_Model)(state)
	index := entry_for(&disk.names, name)
	if index < 0 {
		return .Missing
	}
	trace("disk unlink %v position=%d", name.kind, name.segment.position)
	id := disk.names[index].inode
	disk.names[index] = {}
	inode_unref(disk, id)
	return .Ok
}

disk_crash :: proc(disk: ^Disk_Model, tear: int = 0) {
	require(tear >= 0 && tear < SECTOR_BYTES, "tear length lies within one sector")
	trace("disk crash tear=%d", tear)
	disk.names = disk.durable_names
	for &node, i in disk.inodes {
		if !node.used {
			continue
		}
		node.opens = 0
		if !inode_linked(&disk.durable_names, i + 1) {
			inode_unref(disk, i + 1)
			continue
		}
		offset := len(node.durable)
		count := min(tear, len(node.bytes) - offset, SECTOR_BYTES - offset % SECTOR_BYTES)
		if count > 0 {
			append(&node.durable, ..node.bytes[offset:offset + count])
		}
		resize(&node.bytes, len(node.durable))
		copy(node.bytes[:], node.durable[:])
	}
	disk.fault = .None
	disk.fault_after = 0
}

disk_flip_byte :: proc(disk: ^Disk_Model, name: log.File_Name, at: int) {
	slot := entry_for(&disk.durable_names, name)
	require(slot >= 0, "corruption target has a durable directory entry")
	node := &disk.inodes[disk.durable_names[slot].inode - 1]
	require(at >= 0 && at < len(node.durable), "corruption target has a durable byte")
	node.durable[at] ~= 1
	trace("disk corrupt byte position=%d offset=%d", name.segment.position, at)
}
