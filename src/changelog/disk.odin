package changelog

File :: distinct int

File_Kind :: enum {
	Epoch,
	Pending,
	Segment,
}

File_Name :: struct {
	kind: File_Kind,
	segment: Cursor,
}

Open_Mode :: enum {
	Read,
	Update,
	Create,
}

Disk :: struct {
	state: rawptr,
	list: proc(state: rawptr, ids: ^[dynamic]Cursor) -> Status,
	open: proc(state: rawptr, name: File_Name, mode: Open_Mode) -> (File, Status),
	close: proc(state: rawptr, file: File),
	size: proc(state: rawptr, file: File) -> (i64, Status),
	read: proc(state: rawptr, file: File, offset: i64, data: []u8) -> (int, Status),
	write: proc(state: rawptr, file: File, offset: i64, data: []u8) -> (int, Status),
	truncate: proc(state: rawptr, file: File, size: i64) -> Status,
	sync: proc(state: rawptr, file: File) -> Status,
	sync_dir: proc(state: rawptr) -> Status,
	rename: proc(state: rawptr, from, to: File_Name) -> Status,
	remove: proc(state: rawptr, name: File_Name) -> Status,
}

@(private)
read_full :: proc(disk: Disk, file: File, offset: i64, buffer: []u8) -> Status {
	for done := 0; done < len(buffer); {
		count, status := disk.read(disk.state, file, offset + i64(done), buffer[done:])
		if status != .Ok {
			return status
		}
		if count <= 0 || count > len(buffer) - done {
			return .IO
		}
		done += count
	}
	return .Ok
}

@(private)
write_full :: proc(disk: Disk, file: File, offset: i64, buffer: []u8) -> Status {
	for done := 0; done < len(buffer); {
		count, status := disk.write(disk.state, file, offset + i64(done), buffer[done:])
		if status != .Ok {
			return status
		}
		if count <= 0 || count > len(buffer) - done {
			return .IO
		}
		done += count
	}
	return .Ok
}

@(private)
remove_if_present :: proc(disk: Disk, name: File_Name) -> Status {
	status := disk.remove(disk.state, name)
	return .Ok if status == .Missing else status
}

@(private)
replace_file :: proc(disk: Disk, name: File_Name, data: []u8) -> Status {
	pending := File_Name{kind = .Pending}
	if status := remove_if_present(disk, pending); status != .Ok {
		return status
	}
	file, opened := disk.open(disk.state, pending, .Create)
	if opened != .Ok {
		return opened
	}
	status := write_full(disk, file, 0, data)
	if status == .Ok {
		status = disk.sync(disk.state, file)
	}
	disk.close(disk.state, file)
	if status != .Ok {
		return status
	}
	if status = disk.rename(disk.state, pending, name); status != .Ok {
		return status
	}
	return disk.sync_dir(disk.state)
}
