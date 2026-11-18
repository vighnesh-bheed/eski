package changelog

import "core:encoding/hex"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

Directory :: struct {
	fd: linux.Fd,
	writer: linux.Fd,
}

@(private)
WIRE_PREFIX :: "eski-change-segment-"

@(private)
WIRE_SUFFIX :: ".log"

@(private)
WIRE_SIZE :: len(WIRE_PREFIX) + 32 + 1 + 16 + len(WIRE_SUFFIX)

@(private)
WRITER_NAME :: "eski-change-writer.lock"

@(private)
HEX :: "0123456789abcdef"

@(private)
name_on_disk :: proc(name: File_Name, out: ^[WIRE_SIZE + 1]u8) -> cstring {
	#partial switch name.kind {
	case .Epoch:
		return "eski-change-epoch"
	case .Pending:
		return "eski-change-pending"
	}
	digits := HEX
	copy(out[:], WIRE_PREFIX)
	for byte, i in name.segment.epoch {
		out[len(WIRE_PREFIX) + 2 * i] = digits[byte >> 4]
		out[len(WIRE_PREFIX) + 2 * i + 1] = digits[byte & 15]
	}
	dash := len(WIRE_PREFIX) + 32
	out[dash] = '-'
	for i in 0 ..< 16 {
		out[dash + 1 + i] = digits[(name.segment.position >> uint(4 * (15 - i))) & 15]
	}
	copy(out[WIRE_SIZE - len(WIRE_SUFFIX):], WIRE_SUFFIX)
	out[WIRE_SIZE] = 0
	return cstring(raw_data(out[:]))
}

@(private)
parse_segment :: proc(name: string) -> (id: Cursor, ok: bool) {
	if len(name) != WIRE_SIZE || !strings.has_prefix(name, WIRE_PREFIX) || !strings.has_suffix(name, WIRE_SUFFIX) {
		return
	}
	dash := len(WIRE_PREFIX) + 32
	if name[dash] != '-' {
		return
	}
	for byte in transmute([]u8)name[len(WIRE_PREFIX):WIRE_SIZE - len(WIRE_SUFFIX)] {
		if byte != '-' && !(byte >= '0' && byte <= '9') && !(byte >= 'a' && byte <= 'f') {
			return
		}
	}
	if _, decoded := hex.decode_into_buffer(transmute([]u8)name[len(WIRE_PREFIX):dash], id.epoch[:]); !decoded {
		return
	}
	id.position, ok = strconv.parse_u64(name[dash + 1:dash + 17], 16)
	return
}

@(private)
dirfd :: proc(state: rawptr) -> linux.Fd {
	return (^Directory)(state).fd
}

@(private)
os_status :: proc(err: linux.Errno) -> Status {
	if err == .NONE {
		return .Ok
	}
	return .Missing if err == .ENOENT else .IO
}

@(private)
private_file :: proc(fd: linux.Fd) -> bool {
	st: linux.Stat
	return linux.fstat(fd, &st) == .NONE && st.mode & linux.S_IFMT == linux.S_IFREG &&
	       transmute(u32)st.mode & 0o7777 == 0o600 && st.uid == linux.geteuid() && st.nlink == 1
}

directory_open :: proc(directory: ^Directory, path: string) -> Status {
	directory^ = {fd = -1, writer = -1}
	if path == "" || strings.contains_rune(path, 0) {
		return .Invalid
	}
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	fd, err := linux.open(cpath, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if err != .NONE {
		return os_status(err)
	}
	st: linux.Stat
	if linux.fstat(fd, &st) != .NONE || transmute(u32)st.mode & 0o7777 != 0o700 || st.uid != linux.geteuid() {
		linux.close(fd)
		return .Invalid
	}
	directory.fd = fd
	return .Ok
}

directory_close :: proc(directory: ^Directory) {
	if directory.writer >= 0 {
		linux.close(directory.writer)
	}
	if directory.fd >= 0 {
		linux.close(directory.fd)
	}
	directory^ = {fd = -1, writer = -1}
}

@(private)
flock :: proc(fd: linux.Fd, op: linux.FLock_Op) -> linux.Errno {
	for {
		err := linux.flock(fd, op)
		if err != .EINTR {
			return err
		}
	}
}

directory_lock :: proc(directory: ^Directory, exclusive: bool) -> Status {
	return os_status(flock(directory.fd, {.EX} if exclusive else {.SH}))
}

directory_unlock :: proc(directory: ^Directory) {
	flock(directory.fd, {.UN})
}

directory_claim :: proc(directory: ^Directory) -> Status {
	flags := linux.Open_Flags{.RDWR, .NOFOLLOW, .NONBLOCK, .CLOEXEC}
	fd, err := linux.openat(directory.fd, WRITER_NAME, flags + {.CREAT, .EXCL}, {.IRUSR, .IWUSR})
	if err == .NONE {
		if linux.fchmod(fd, {.IRUSR, .IWUSR}) != .NONE {
			linux.close(fd)
			return .IO
		}
	} else if err == .EEXIST {
		fd, err = linux.openat(directory.fd, WRITER_NAME, flags)
	}
	if err != .NONE {
		return os_status(err)
	}
	if !private_file(fd) || flock(fd, {.EX, .NB}) != .NONE {
		linux.close(fd)
		return .IO
	}
	directory.writer = fd
	return .Ok
}

@(private)
directory_at_tail :: proc(directory: ^Directory) -> Status {
	fd, err := linux.openat(directory.fd, WRITER_NAME, {.NOFOLLOW, .NONBLOCK, .CLOEXEC})
	if err != .NONE {
		return .Offline if err == .ENOENT else .IO
	}
	defer linux.close(fd)
	if !private_file(fd) {
		return .Invalid
	}
	#partial switch flock(fd, {.EX, .NB}) {
	case .EAGAIN:
		return .End
	case .NONE:
		return .Offline
	case:
		return .IO
	}
}

directory_first :: proc(directory: ^Directory) -> (Cursor, Status) {
	if status := directory_lock(directory, false); status != .Ok {
		return {}, status
	}
	defer directory_unlock(directory)
	return first(directory_disk(directory))
}

directory_read :: proc(directory: ^Directory, cursor: Cursor, buffer: ^[dynamic]u8) -> (Record, Status) {
	if status := directory_lock(directory, false); status != .Ok {
		return {}, status
	}
	defer directory_unlock(directory)
	record, status := read(directory_disk(directory), cursor, buffer)
	if status == .End {
		status = directory_at_tail(directory)
	}
	return record, status
}

random_epoch :: proc() -> (epoch: Epoch, status: Status) {
	for done := 0; done < len(epoch); {
		n, err := linux.getrandom(epoch[done:], {})
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			return {}, .IO
		}
		done += n
	}
	return epoch, .IO if epoch == {} else .Ok
}

directory_disk :: proc(directory: ^Directory) -> Disk {
	return {
		state = directory,
		list = directory_list,
		open = directory_open_file,
		close = directory_close_file,
		size = directory_size,
		read = directory_read_file,
		write = directory_write_file,
		truncate = directory_truncate,
		sync = directory_sync_file,
		sync_dir = directory_sync,
		rename = directory_rename,
		remove = directory_remove,
	}
}

@(private)
directory_list :: proc(state: rawptr, ids: ^[dynamic]Cursor) -> Status {
	fd, err := linux.openat(dirfd(state), ".", {.DIRECTORY, .CLOEXEC})
	if err != .NONE {
		return os_status(err)
	}
	defer linux.close(fd)
	chunk: [4096]u8
	for {
		n, list_err := linux.getdents(fd, chunk[:])
		if list_err == .EINTR {
			continue
		}
		if list_err != .NONE || n == 0 {
			return os_status(list_err)
		}
		offset := 0
		for entry in linux.dirent_iterate_buf(chunk[:n], &offset) {
			if id, ok := parse_segment(linux.dirent_name(entry)); ok {
				append(ids, id)
			}
		}
	}
}

@(private)
directory_open_file :: proc(state: rawptr, name: File_Name, mode: Open_Mode) -> (File, Status) {
	flags := linux.Open_Flags{.NOFOLLOW, .NONBLOCK, .CLOEXEC}
	switch mode {
	case .Read:
	case .Update:
		flags += {.RDWR}
	case .Create:
		flags += {.RDWR, .CREAT, .EXCL}
	}
	buf: [WIRE_SIZE + 1]u8
	fd, err := linux.openat(dirfd(state), name_on_disk(name, &buf), flags, {.IRUSR, .IWUSR})
	if err != .NONE {
		return {}, os_status(err)
	}
	if mode == .Create && linux.fchmod(fd, {.IRUSR, .IWUSR}) != .NONE || !private_file(fd) {
		linux.close(fd)
		return {}, .Invalid
	}
	return File(fd), .Ok
}

@(private)
directory_close_file :: proc(state: rawptr, file: File) {
	linux.close(linux.Fd(file))
}

@(private)
directory_size :: proc(state: rawptr, file: File) -> (i64, Status) {
	st: linux.Stat
	err := linux.fstat(linux.Fd(file), &st)
	return i64(st.size), os_status(err)
}

@(private)
directory_read_file :: proc(state: rawptr, file: File, offset: i64, data: []u8) -> (int, Status) {
	for {
		n, err := linux.pread(linux.Fd(file), data, offset)
		if err != .EINTR {
			return n, os_status(err)
		}
	}
}

@(private)
directory_write_file :: proc(state: rawptr, file: File, offset: i64, data: []u8) -> (int, Status) {
	for {
		n, err := linux.pwrite(linux.Fd(file), data, offset)
		if err != .EINTR {
			return n, os_status(err)
		}
	}
}

@(private)
directory_truncate :: proc(state: rawptr, file: File, size: i64) -> Status {
	for {
		err := linux.ftruncate(linux.Fd(file), size)
		if err != .EINTR {
			return os_status(err)
		}
	}
}

@(private)
sync_fd :: proc(fd: linux.Fd) -> Status {
	for {
		err := linux.fsync(fd)
		if err != .EINTR {
			return os_status(err)
		}
	}
}

@(private)
directory_sync_file :: proc(state: rawptr, file: File) -> Status {
	return sync_fd(linux.Fd(file))
}

@(private)
directory_sync :: proc(state: rawptr) -> Status {
	return sync_fd(dirfd(state))
}

@(private)
directory_rename :: proc(state: rawptr, from, to: File_Name) -> Status {
	from_buf, to_buf: [WIRE_SIZE + 1]u8
	fd := dirfd(state)
	return os_status(linux.renameat(fd, name_on_disk(from, &from_buf), fd, name_on_disk(to, &to_buf)))
}

@(private)
directory_remove :: proc(state: rawptr, name: File_Name) -> Status {
	buf: [WIRE_SIZE + 1]u8
	return os_status(linux.unlinkat(dirfd(state), name_on_disk(name, &buf), {}))
}
