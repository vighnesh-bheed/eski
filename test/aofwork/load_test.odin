package aofwork

import "base:runtime"
import "core:strings"
import "core:testing"
import j "../../src"

use_dir :: proc(dir: string) {
	j.aof.dirname = dir
}

reset_dir :: proc() {
	j.aof.dirname = "appendonlydir"
}

load_manifest_dir :: proc(dir: string) -> j.Aof_Load_Result {
	use_dir(dir)
	m: j.Aof_Manifest
	exists, ok := j.aof_manifest_load_from_disk(&m)
	if !exists || !ok {
		j.aof_manifest_free(&m)
		return .Open_Err
	}
	j.aof_manifest_set(m)
	flush_all()
	return j.aof_load_all(false)
}

db_size :: proc(db: int) -> int {
	return j.db_size_of(&j.dbs[db])
}

INCR_OK :: "*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n"

write_incr_dir :: proc(name: string, incr: string, base: string = "") -> string {
	dir := fresh_dir(name)
	if len(base) > 0 {
		write_file(path_join({dir, "appendonly.aof.1.base.aof"}), transmute([]u8)base)
		write_file(path_join({dir, "appendonly.aof.manifest"}), transmute([]u8)string("file appendonly.aof.1.base.aof seq 1 type b\nfile appendonly.aof.1.incr.aof seq 1 type i\n"))
	} else {
		write_file(path_join({dir, "appendonly.aof.manifest"}), transmute([]u8)string("file appendonly.aof.1.incr.aof seq 1 type i\n"))
	}
	write_file(path_join({dir, "appendonly.aof.1.incr.aof"}), transmute([]u8)incr)
	return dir
}

@(test)
load_truncated_and_corrupt :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	defer reset_dir()
	defer j.aof.load_truncated = true
	c := new_client(0)

	cut := INCR_OK + "*3\r\n$3\r\nSET\r\n$1\r\nb\r\n$1"
	dir := write_incr_dir("trunc-yes", cut)
	j.aof.load_truncated = true
	res := load_manifest_dir(dir)
	testing.expect_value(t, res, j.Aof_Load_Result.Truncated)
	testing.expect_value(t, file_size(path_join({dir, "appendonly.aof.1.incr.aof"})), i64(len(INCR_OK)))
	testing.expect_value(t, run(c, "GET", "a"), "$1\r\n1\r\n")
	testing.expect_value(t, run(c, "EXISTS", "b"), ":0\r\n")
	logs := log_text()
	testing.expect(t, strings.contains(logs, "!!! Warning: short read while loading the AOF file appendonly.aof.1.incr.aof!!!"))
	testing.expect(t, strings.contains(logs, "AOF appendonly.aof.1.incr.aof loaded anyway because aof-load-truncated is enabled"))

	dir = write_incr_dir("trunc-no", cut)
	j.aof.load_truncated = false
	res = load_manifest_dir(dir)
	testing.expect_value(t, res, j.Aof_Load_Result.Failed)
	testing.expect_value(t, file_size(path_join({dir, "appendonly.aof.1.incr.aof"})), i64(len(cut)))
	testing.expect(t, strings.contains(log_text(), "Unexpected end of file reading the append only file appendonly.aof.1.incr.aof. Eski has no AOF repair tool. You can: 1) Make a backup of your AOF file, then remove the incomplete command at its end by hand. 2) Alternatively you can set the 'aof-load-truncated' configuration option to yes and restart the server."))
	j.aof.load_truncated = true

	multi := INCR_OK + "*1\r\n$5\r\nMULTI\r\n*3\r\n$3\r\nSET\r\n$1\r\nc\r\n$1\r\n3\r\n"
	dir = write_incr_dir("trunc-multi", multi)
	res = load_manifest_dir(dir)
	testing.expect_value(t, res, j.Aof_Load_Result.Truncated)
	testing.expect_value(t, file_size(path_join({dir, "appendonly.aof.1.incr.aof"})), i64(len(INCR_OK)))
	testing.expect_value(t, run(c, "EXISTS", "c"), ":0\r\n")
	testing.expect(t, strings.contains(log_text(), "Revert incomplete MULTI/EXEC transaction in AOF file appendonly.aof.1.incr.aof"))

	whole := INCR_OK + "*1\r\n$5\r\nMULTI\r\n*3\r\n$3\r\nSET\r\n$1\r\nc\r\n$1\r\n3\r\n*1\r\n$4\r\nEXEC\r\n#TS:1700000000\r\n*3\r\n$3\r\nSET\r\n$1\r\nd\r\n$1\r\n4\r\n"
	dir = write_incr_dir("whole-multi", whole)
	res = load_manifest_dir(dir)
	testing.expect_value(t, res, j.Aof_Load_Result.Ok)
	testing.expect_value(t, run(c, "GET", "c"), "$1\r\n3\r\n")
	testing.expect_value(t, run(c, "GET", "d"), "$1\r\n4\r\n")

	bad := INCR_OK + "+bogus\r\n"
	dir = write_incr_dir("corrupt", bad)
	res = load_manifest_dir(dir)
	testing.expect_value(t, res, j.Aof_Load_Result.Failed)
	testing.expect(t, strings.contains(log_text(), "Bad file format reading the append only file appendonly.aof.1.incr.aof: make a backup of your AOF file, then repair it by hand. Eski has no AOF repair tool."))

	bad_len := INCR_OK + "*1\r\n$3\r\nSETX\r\n"
	dir = write_incr_dir("corrupt-len", bad_len)
	testing.expect_value(t, load_manifest_dir(dir), j.Aof_Load_Result.Failed)

	unknown := INCR_OK + "*1\r\n$9\r\nnosuchcmd\r\n"
	dir = write_incr_dir("unknown-cmd", unknown)
	testing.expect_value(t, load_manifest_dir(dir), j.Aof_Load_Result.Failed)
	testing.expect(t, strings.contains(log_text(), "Unknown command 'nosuchcmd' reading the append only file appendonly.aof.1.incr.aof"))

	dir = write_incr_dir("trunc-not-last", INCR_OK, INCR_OK + "*2\r\n$3\r\nDEL")
	testing.expect_value(t, load_manifest_dir(dir), j.Aof_Load_Result.Failed)
	testing.expect(t, strings.contains(log_text(), "Fatal error: the truncated file is not the last file"))

	dir = write_incr_dir("empty-files", "", "")
	testing.expect_value(t, load_manifest_dir(dir), j.Aof_Load_Result.Empty)

	dir = fresh_dir("missing-files")
	write_file(path_join({dir, "appendonly.aof.manifest"}), transmute([]u8)string("file appendonly.aof.1.base.aof seq 1 type b\nfile appendonly.aof.1.incr.aof seq 1 type i\n"))
	write_file(path_join({dir, "appendonly.aof.1.incr.aof"}), transmute([]u8)string(INCR_OK))
	testing.expect_value(t, load_manifest_dir(dir), j.Aof_Load_Result.Failed)
}
