package changelog

import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

@(test)
castagnoli_check_vector :: proc(t: ^testing.T) {
	testing.expect_value(t, crc32c(transmute([]u8)string("123456789")), u32(0xe3069283))
}

@(test)
retention_and_tail_validation :: proc(t: ^testing.T) {
	path, err := os.make_directory_temp("", "eski-changelog-*", context.allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	defer delete(path)
	defer os.remove_all(path)
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	if !testing.expect_value(t, linux.chmod(cpath, {.IRUSR, .IWUSR, .IXUSR}), linux.Errno.NONE) {
		return
	}
	directory: Directory
	if !testing.expect_value(t, directory_open(&directory, path), Status.Ok) {
		return
	}
	defer directory_close(&directory)
	if !testing.expect_value(t, directory_claim(&directory), Status.Ok) {
		return
	}
	disk := directory_disk(&directory)
	epoch: Epoch
	epoch[0] = 1
	limits := Limits{72, 144}
	log: Log
	defer close(&log)
	if !testing.expect_value(t, begin(&log, disk, epoch, limits), Status.Ok) {
		return
	}
	payload := transmute([]u8)string("12345678")
	for i in 0 ..< 3 {
		testing.expect_value(t, append_record(&log, i32(i), payload), Status.Ok)
	}
	kept, listed := directory_first(&directory)
	testing.expect_value(t, listed, Status.Ok)
	testing.expect_value(t, kept.position, u64(2))
	buffer: [dynamic]u8
	defer delete(buffer)
	_, stale := directory_read(&directory, {epoch, 1}, &buffer)
	testing.expect_value(t, stale, Status.Stale)
	record, read_ok := directory_read(&directory, kept, &buffer)
	testing.expect_value(t, read_ok, Status.Ok)
	testing.expect_value(t, record.db, i32(1))
	testing.expect_value(t, string(record.payload), "12345678")
	_, end := directory_read(&directory, {epoch, 4}, &buffer)
	testing.expect_value(t, end, Status.End)
	_, ahead := directory_read(&directory, {epoch, 5}, &buffer)
	testing.expect_value(t, ahead, Status.Ahead)
	other := epoch
	other[0] = 2
	_, wrong := directory_read(&directory, {other, 4}, &buffer)
	testing.expect_value(t, wrong, Status.Wrong_Epoch)
	tail := File_Name{.Segment, {epoch, 3}}
	file, opened := disk.open(disk.state, tail, .Update)
	if !testing.expect_value(t, opened, Status.Ok) {
		return
	}
	partial := encode_frame(4, 12, payload)
	_, written := disk.write(disk.state, file, 72, partial[:18])
	testing.expect_value(t, written, Status.Ok)
	testing.expect_value(t, disk.sync(disk.state, file), Status.Ok)
	disk.close(disk.state, file)
	_, truncated := directory_read(&directory, {epoch, 4}, &buffer)
	testing.expect_value(t, truncated, Status.Incomplete)
	close(&log)
	testing.expect_value(t, recover(&log, disk, limits), Status.Ok)
	testing.expect_value(t, log.next.position, u64(4))
	testing.expect_value(t, log.bytes, i64(144))
	file, opened = disk.open(disk.state, tail, .Update)
	if !testing.expect_value(t, opened, Status.Ok) {
		return
	}
	_, written = disk.write(disk.state, file, 72, partial[:])
	testing.expect_value(t, written, Status.Ok)
	_, written = disk.write(disk.state, file, 72 + FRAME_HEADER_SIZE, payload[:3])
	testing.expect_value(t, written, Status.Ok)
	testing.expect_value(t, disk.sync(disk.state, file), Status.Ok)
	disk.close(disk.state, file)
	_, truncated = directory_read(&directory, {epoch, 4}, &buffer)
	testing.expect_value(t, truncated, Status.Incomplete)
	close(&log)
	testing.expect_value(t, recover(&log, disk, limits), Status.Ok)
	testing.expect_value(t, log.next.position, u64(4))
	file, opened = disk.open(disk.state, tail, .Update)
	if !testing.expect_value(t, opened, Status.Ok) {
		return
	}
	damaged := [1]u8{'x'}
	_, written = disk.write(disk.state, file, 71, damaged[:])
	testing.expect_value(t, written, Status.Ok)
	testing.expect_value(t, disk.sync(disk.state, file), Status.Ok)
	disk.close(disk.state, file)
	close(&log)
	testing.expect_value(t, recover(&log, disk, limits), Status.Corrupt)
	file, opened = disk.open(disk.state, tail, .Read)
	if !testing.expect_value(t, opened, Status.Ok) {
		return
	}
	size, sized := disk.size(disk.state, file)
	disk.close(disk.state, file)
	testing.expect_value(t, sized, Status.Ok)
	testing.expect_value(t, size, i64(72))
}
