package main

import "base:runtime"
import "core:sys/linux"
import "core:testing"
import lb "label"
import ow "owner"

@(private = "file")
scope_fixture_open :: proc(t: ^testing.T, owners: bool) {
	access_init()
	lb.config_destroy(&label_scheme)
	lb.table_destroy(&label_table)
	lb.config_init(&label_scheme)
	for name in ([]string{"U", "C", "S"}) {
		testing.expect_value(t, lb.config_add_level(&label_scheme, name), lb.Config_Error.None)
	}
	for name in ([]string{"A", "B"}) {
		testing.expect_value(t, lb.config_add_compartment(&label_scheme, name), lb.Config_Error.None)
	}
	for name in ([]string{"WEB", "VETTED"}) {
		testing.expect_value(t, lb.config_add_trust(&label_scheme, name), lb.Config_Error.None)
	}
	lb.table_init(&label_table)
	access_scheme_changed()
	labels_on = true
	owners_on = owners
	label_scheme_labelled = true
	access = {}
}

@(private = "file")
scope_fixture_close :: proc() {
	access = {}
	labels_on = false
	owners_on = false
	label_scheme_labelled = false
	lb.config_destroy(&label_scheme)
	lb.table_destroy(&label_table)
	lb.config_default(&label_scheme)
	lb.table_init(&label_table)
	access_scheme_changed()
}

@(private = "file")
words :: proc(list: ..string) -> [][]u8 {
	out := make([][]u8, len(list), context.temp_allocator)
	for s, i in list {
		out[i] = transmute([]u8)s
	}
	return out
}

@(private = "file")
marking_of :: proc(t: ^testing.T, text: string) -> lb.Label {
	l, f := lb.parse(&label_scheme, text)
	testing.expect_value(t, f.error, lb.Parse_Error.None)
	return l
}

@(test)
scoped_records_parse_in_label_only_mode :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	scope_fixture_open(t, false)
	defer scope_fixture_close()
	scope, inner, reason := aof_parse_scope(words("LABEL", "AS", "S//A", "SET", "k", "v"))
	testing.expect_value(t, reason, "")
	testing.expect_value(t, string(scope.marking), "S//A")
	testing.expect_value(t, scope.word, Aof_Word.None)
	testing.expect_value(t, len(inner), 3)
	_, _, reason = aof_parse_scope(words("LABEL", "AS", "S", "OWNER", "u1", "SET", "k", "v"))
	testing.expect(t, reason != "", "an owner word in label-only mode is refused")
	_, _, reason = aof_parse_scope(words("LABEL", "AS", "S", "SHARED", "SET", "k", "v"))
	testing.expect(t, reason != "", "a shared word in label-only mode is refused")
	cases := [][]string {
		{"LABEL", "AS", "S"},
		{"LABEL", "AS", "S", "LABEL", "AS", "U", "SET", "k", "v"},
		{"LABEL", "AS", "S", "LABEL", "SESSION", "U"},
		{"LABEL", "AS", "S", "MULTI"},
		{"LABEL", "AS", "S", "EXEC"},
		{"LABEL", "AS", "S", "SELECT", "1"},
		{"LABEL", "AS", "S", "ESKI-ACCESS", "1", "1", "0"},
		{"LABEL", "AS", "S", "ESKI-VSET-SEED", "5"},
		{"LABEL", "AS", "S", "SWAPDB", "0", "1"},
		{"LABEL", "AS", "S", "FUNCTION", "FLUSH"},
		{"LABEL", "AS", "S", "LABEL", "QUOTA", "C", "LIMIT", "5"},
		{"LABEL", "AS", "S", "GET", "k"},
		{"LABEL", "AS", "S", "EVAL", "return 1", "0"},
		{"LABEL", "AS", "S", "NOSUCHCOMMAND"},
	}
	for c in cases {
		_, _, why := aof_parse_scope(words(..c))
		testing.expectf(t, why != "", "%v is refused", c)
	}
	_, _, reason = aof_parse_scope(words("LABEL", "AS", "S", "LABEL", "DECLASSIFY", "k", "U"))
	testing.expect_value(t, reason, "")
	_, _, reason = aof_parse_scope(words("LABEL", "AS", "S", "PFCOUNT", "h"))
	testing.expect_value(t, reason, "")
}

@(test)
scoped_records_parse_in_owner_mode :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	scope_fixture_open(t, true)
	defer scope_fixture_close()
	scope, inner, reason := aof_parse_scope(words("LABEL", "AS", "C", "OWNER", "u1", "RPUSH", "l", "a"))
	testing.expect_value(t, reason, "")
	testing.expect_value(t, scope.word, Aof_Word.User)
	testing.expect_value(t, string(scope.owner), "u1")
	testing.expect_value(t, string(inner[0]), "RPUSH")
	scope, _, reason = aof_parse_scope(words("LABEL", "AS", "C", "SHARED", "DEL", "k"))
	testing.expect_value(t, reason, "")
	testing.expect_value(t, scope.word, Aof_Word.Shared)
	scope, _, reason = aof_parse_scope(words("LABEL", "AS", "C", "FLUSHALL"))
	testing.expect_value(t, reason, "")
	testing.expect_value(t, scope.word, Aof_Word.None)
	long: [129]u8
	for &b in long {
		b = 'x'
	}
	bad := [][]u8{transmute([]u8)string("*"), transmute([]u8)string("a b"), long[:], transmute([]u8)string(""), transmute([]u8)string("tab\there")}
	for id in bad {
		argv := [][]u8{transmute([]u8)string("LABEL"), transmute([]u8)string("AS"), transmute([]u8)string("C"), transmute([]u8)string("OWNER"), id, transmute([]u8)string("SET"), transmute([]u8)string("k"), transmute([]u8)string("v")}
		_, _, why := aof_parse_scope(argv)
		testing.expectf(t, why != "", "owner id %q is refused", string(id))
	}
	_, _, reason = aof_parse_scope(words("LABEL", "AS", "C", "OWNER"))
	testing.expect(t, reason != "", "an owner word without an id is refused")
}

@(test)
operator_records_have_fixed_shapes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	scope_fixture_open(t, true)
	defer scope_fixture_close()
	good := [][]string {
		{"FUNCTION", "LOAD", "code"},
		{"FUNCTION", "DELETE", "lib"},
		{"FUNCTION", "FLUSH"},
		{"FUNCTION", "RESTORE", "payload"},
		{"SWAPDB", "0", "1"},
		{"OWNERS", "FORGET", "u1"},
		{"OWNERS", "QUOTA", "u1", "LIMIT", "10"},
		{"LABEL", "QUOTA", "C", "LIMIT", "10"},
		{"LABEL", "QUOTA", "C", "TRUST", "VETTED", "LIMIT", "10"},
		{"CONFIG", "SET", "label-levels", "U,C,S,TS"},
		{"CONFIG", "SET", "label-compartments", "A,B,C"},
		{"CONFIG", "SET", "label-trust-levels", "WEB,VETTED,HIGH"},
	}
	for g in good {
		testing.expectf(t, aof_operator_record(words(..g)), "%v is an operator record", g)
	}
	bad := [][]string {
		{"FUNCTION", "LIST"},
		{"SWAPDB", "0"},
		{"OWNERS", "INFO", "u1"},
		{"OWNERS", "QUOTA", "u1"},
		{"LABEL", "QUOTA", "C"},
		{"LABEL", "QUOTA", "C", "TRUST", "VETTED"},
		{"CONFIG", "SET", "maxmemory", "1"},
		{"CONFIG", "SET", "owners", "no"},
		{"SET", "k", "v"},
		{"FLUSHALL"},
	}
	for b in bad {
		testing.expectf(t, !aof_operator_record(words(..b)), "%v is not an operator record", b)
	}
	owners_on = false
	testing.expect(t, !aof_operator_record(words("OWNERS", "FORGET", "u1")), "owner records need owner mode")
}

@(test)
seed_records_hold_one_seed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	v, ok := aof_parse_seed(transmute([]u8)string("18446744073709551615"))
	testing.expect(t, ok)
	testing.expect_value(t, v, max(u64))
	for bad in ([]string{"", "0", "01", "18446744073709551616", "99999999999999999999", "1a", "-1", "123456789012345678901"}) {
		_, good := aof_parse_seed(transmute([]u8)bad)
		testing.expectf(t, !good, "%q is not a seed", bad)
	}
	b: [dynamic]u8
	defer delete(b)
	aof_seed_into(&b, 42)
	testing.expect_value(t, string(b[:]), "*2\r\n$14\r\nESKI-VSET-SEED\r\n$2\r\n42\r\n")
	clear(&b)
	aof_seed_into(&b, max(u64))
	testing.expect_value(t, string(b[:]), "*2\r\n$14\r\nESKI-VSET-SEED\r\n$20\r\n18446744073709551615\r\n")
}

@(test)
marker_and_heads_have_fixed_bytes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	scope_fixture_open(t, true)
	defer scope_fixture_close()
	b: [dynamic]u8
	defer delete(b)
	aof_marker_into(&b)
	testing.expect_value(t, string(b[:]), "*4\r\n$11\r\nESKI-ACCESS\r\n$1\r\n1\r\n$1\r\n1\r\n$1\r\n1\r\n")
	id, err := lb.table_intern(&label_table, marking_of(t, "S//A;VETTED"))
	testing.expect_value(t, err, lb.Error.None)
	e, oerr := owner_intern(transmute([]u8)string("user-7"))
	testing.expect_value(t, oerr, ow.Error.None)
	defer owner_drop(e.number)
	clear(&b)
	aof_put_head(&b, Aof_Head{label = id, word = .User, owner = e.number})
	testing.expect_value(t, string(b[:]), "$5\r\nLABEL\r\n$2\r\nAS\r\n$11\r\nS//A;VETTED\r\n$5\r\nOWNER\r\n$6\r\nuser-7\r\n")
	testing.expect_value(t, aof_head_words(Aof_Head{word = .User}), 5)
	clear(&b)
	aof_put_head(&b, Aof_Head{label = id, word = .Shared})
	testing.expect_value(t, string(b[:]), "$5\r\nLABEL\r\n$2\r\nAS\r\n$11\r\nS//A;VETTED\r\n$6\r\nSHARED\r\n")
	testing.expect_value(t, aof_head_words(Aof_Head{word = .Shared}), 4)
	clear(&b)
	aof_put_head(&b, Aof_Head{label = id})
	testing.expect_value(t, string(b[:]), "$5\r\nLABEL\r\n$2\r\nAS\r\n$11\r\nS//A;VETTED\r\n")
	testing.expect_value(t, aof_head_words(Aof_Head{}), 3)
	owners_on = false
	label_scheme_labelled = true
	clear(&b)
	aof_marker_into(&b)
	testing.expect_value(t, string(b[:]), "*4\r\n$11\r\nESKI-ACCESS\r\n$1\r\n1\r\n$1\r\n1\r\n$1\r\n0\r\n")
}

@(test)
maintenance_forms_are_single_deletions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect(t, aof_maintenance_form(words("DEL", "k")))
	testing.expect(t, aof_maintenance_form(words("unlink", "k")))
	testing.expect(t, aof_maintenance_form(words("HDEL", "h", "f")))
	testing.expect(t, !aof_maintenance_form(words("DEL", "a", "b")))
	testing.expect(t, !aof_maintenance_form(words("HDEL", "h", "f", "g")))
	testing.expect(t, !aof_maintenance_form(words("SET", "k", "v")))
}

@(test)
the_scope_helper_sets_and_clears_the_access_state :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	scope_fixture_open(t, true)
	defer scope_fixture_close()
	e, err := owner_intern(transmute([]u8)string("resume-user"))
	testing.expect_value(t, err, ow.Error.None)
	defer owner_drop(e.number)
	s := Access_Resume{label = marking_of(t, "C//A"), owner = e.number, owner_named = true}
	testing.expect(t, access_resume_enter(s))
	testing.expect_value(t, access.label, s.label)
	testing.expect_value(t, access.owner, e.number)
	testing.expect(t, access.owner_entry == e)
	testing.expect(t, access.owner_named)
	testing.expect(t, !access.top && !access.label_top && !access.operator)
	testing.expect(t, label_active)
	got := access_resume_capture()
	testing.expect_value(t, got, s)
	access_resume_leave()
	testing.expect(t, !label_active)
	testing.expect_value(t, access.owner, ow.SHARED)
	testing.expect_value(t, access.label, lb.Label{})
	op := access_resume_operator()
	testing.expect(t, access_resume_enter(op))
	testing.expect(t, access.top && access.label_top && access.operator && !access.owner_named)
	testing.expect_value(t, access.owner, ow.SHARED)
	access_resume_leave()
	testing.expect(t, !access_resume_enter(Access_Resume{label = marking_of(t, "C"), owner = ow.Owner(999999)}))
	testing.expect(t, !access_resume_enter(Access_Resume{label = marking_of(t, "C"), owner = ow.EVERY}))
	testing.expect(t, access_resume_enter(Access_Resume{label = marking_of(t, "C"), owner = ow.EVERY, operator = true}))
	access_resume_leave()
	bad := marking_of(t, "C")
	bad.level = 9
	testing.expect(t, !access_resume_enter(Access_Resume{label = bad}))
	owners_on = false
	testing.expect(t, !access_resume_enter(Access_Resume{label = marking_of(t, "C"), owner = e.number}))
	testing.expect(t, access_resume_enter(Access_Resume{label = marking_of(t, "S//A/B"), operator = true}))
	testing.expect(t, access.top)
	access_resume_leave()
}

@(test)
log_file_names_are_told_from_other_files :: proc(t: ^testing.T) {
	saved := aof.filename
	defer aof.filename = saved
	aof.filename = "appendonly.aof"
	testing.expect(t, aof_is_log_file_name("appendonly.aof.1.base.rdb"))
	testing.expect(t, aof_is_log_file_name("appendonly.aof.12.incr.aof"))
	testing.expect(t, aof_is_log_file_name("appendonly.aof.3.base.aof"))
	testing.expect(t, !aof_is_log_file_name("appendonly.aof"))
	testing.expect(t, !aof_is_log_file_name("appendonly.aof.manifest"))
	testing.expect(t, !aof_is_log_file_name("appendonly.aof..incr.aof"))
	testing.expect(t, !aof_is_log_file_name("appendonly.aof.x.incr.aof"))
	testing.expect(t, !aof_is_log_file_name("appendonly.aof.1.incr.aof.bak"))
	testing.expect(t, !aof_is_log_file_name("appendonly.aof.1.history.aof"))
	testing.expect(t, !aof_is_log_file_name("notes.txt"))
	testing.expect(t, !aof_is_log_file_name("appendonly.aof.1234567890123456789.incr.aof"))
}

@(test)
only_the_three_scheme_settings_are_logged :: proc(t: ^testing.T) {
	testing.expect(t, aof_scheme_setting(transmute([]u8)string("label-levels")))
	testing.expect(t, aof_scheme_setting(transmute([]u8)string("LABEL-COMPARTMENTS")))
	testing.expect(t, aof_scheme_setting(transmute([]u8)string("Label-Trust-Levels")))
	testing.expect(t, !aof_scheme_setting(transmute([]u8)string("owners")))
	testing.expect(t, !aof_scheme_setting(transmute([]u8)string("maxmemory")))
	testing.expect(t, aof_operator_record(words("CONFIG", "SET", "label-levels", "U,C")))
	testing.expect(t, !aof_operator_record(words("CONFIG", "SET", "owners", "yes")))
	testing.expect(t, !aof_operator_record(words("CONFIG", "SET", "label-levels")))
	testing.expect(t, !aof_operator_record(words("CONFIG", "SET", "label-levels", "U", "label-compartments", "A")))
	testing.expect(t, !aof_operator_record(words("CONFIG", "GET", "label-levels")))
}

@(test)
the_forget_fields_follow_the_log :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	scope_fixture_open(t, true)
	defer scope_fixture_close()
	saved_state, saved_seq, saved_in, saved_due, saved_delay, saved_confirmed := aof.state, access_forget_seq, access_forget_in_aof, access_forget_aof_due_ms, owners_forget_aof_delay, access_forget_aof_confirmed
	saved_dir, saved_file, saved_db := aof.dirname, aof.filename, cfg.dbfilename
	defer {
		aof.state, access_forget_seq, access_forget_in_aof, access_forget_aof_due_ms, owners_forget_aof_delay, access_forget_aof_confirmed = saved_state, saved_seq, saved_in, saved_due, saved_delay, saved_confirmed
		aof.dirname, aof.filename, cfg.dbfilename = saved_dir, saved_file, saved_db
	}
	aof.dirname = "/dev/null/appendonlydir"
	aof.filename = "/dev/null/appendonly.aof"
	cfg.dbfilename = "/dev/null/dump.rdb"
	owners_forget_aof_delay = 300
	access_forget_seq = 0
	access_forget_in_aof = 0
	access_forget_aof_confirmed = 0
	access_forget_aof_due_ms = 0
	aof.state = .Disabled
	access_forget_noted()
	access_forget_noted()
	testing.expect_value(t, access_forget_seq, u64(2))
	testing.expect(t, !aof_log_files_present())
	testing.expect_value(t, access_forget_in_aof_value(), u64(2))
	testing.expect(t, !access_forget_aof_uncovered())
	first_due := access_forget_aof_due_ms
	testing.expect(t, first_due != 0)
	aof.state = .Enabled
	testing.expect_value(t, access_forget_in_aof_value(), u64(0))
	testing.expect(t, access_forget_aof_uncovered())
	access_forget_noted()
	testing.expect_value(t, access_forget_aof_due_ms, first_due)
	access_aof_rewritten(2)
	testing.expect_value(t, access_forget_in_aof_value(), u64(0))
	aof_forget_confirm()
	testing.expect_value(t, access_forget_in_aof_value(), u64(2))
	testing.expect(t, access_forget_aof_uncovered())
	testing.expect(t, access_forget_aof_due_ms != 0)
	access_aof_rewritten(1)
	aof_forget_confirm()
	testing.expect_value(t, access_forget_in_aof_value(), u64(2))
	kept := Aof_File {
		seq  = 1,
		kind = .History,
	}
	append(&kept.name, "appendonly.aof.1.incr.aof")
	append(&aof.manifest.history, kept)
	access_aof_rewritten(3)
	testing.expect(t, !access_forget_aof_uncovered())
	testing.expect_value(t, access_forget_aof_due_ms, i64(0))
	aof_forget_confirm()
	testing.expect_value(t, access_forget_in_aof_value(), u64(2))
	testing.expect(t, access_forget_aof_unconfirmed())
	gone := pop(&aof.manifest.history)
	aof_file_free(&gone)
	aof_forget_confirm()
	testing.expect_value(t, access_forget_in_aof_value(), u64(3))
	testing.expect(t, !access_forget_aof_unconfirmed())
	access_forget_noted()
	access_forget_aof_due_ms = 0
	access_aof_failed()
	testing.expect(t, access_forget_aof_due_ms != 0)
	owners_forget_aof_delay = 0
	access_forget_aof_due_ms = 0
	access_aof_failed()
	testing.expect_value(t, access_forget_aof_due_ms, i64(0))
	access_forget_noted()
	testing.expect_value(t, access_forget_aof_due_ms, i64(0))
}

@(test)
the_forget_counts_only_once_the_files_it_unlinks_are_gone :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	scope_fixture_open(t, true)
	defer scope_fixture_close()
	saved_dir, saved_seq, saved_in, saved_confirmed := aof.dirname, access_forget_seq, access_forget_in_aof, access_forget_aof_confirmed
	digits: [24]u8
	n := format_i64(&digits[0], i64(linux.getpid()))
	path: [dynamic]u8
	defer delete(path)
	append(&path, "/tmp/eski-forget-confirm-")
	append(&path, ..digits[:n])
	dbuf: [PERSIST_PATH_MAX]u8
	testing.expect_value(t, linux.mkdir(persist_cstr(string(path[:]), dbuf[:]), {.IRUSR, .IWUSR, .IXUSR}), linux.Errno.NONE)
	aof.dirname = string(path[:])
	defer {
		aof.dirname, access_forget_seq, access_forget_in_aof, access_forget_aof_confirmed = saved_dir, saved_seq, saved_in, saved_confirmed
		linux.rmdir(persist_cstr(string(path[:]), dbuf[:]))
	}
	name := "appendonly.aof.7.incr.aof"
	fbuf: [PERSIST_PATH_MAX]u8
	fd, err := linux.open(aof_cpath(name, fbuf[:]), {.WRONLY, .CREAT, .CLOEXEC}, {.IRUSR, .IWUSR})
	testing.expect_value(t, err, linux.Errno.NONE)
	linux.close(fd)
	awaited: [dynamic]u8
	append(&awaited, name)
	append(&aof_awaited, awaited)
	access_forget_seq = 3
	access_forget_in_aof = 3
	access_forget_aof_confirmed = 2
	aof_forget_confirm()
	testing.expect_value(t, access_forget_aof_confirmed, u64(2))
	testing.expect_value(t, len(aof_awaited), 1)
	aof_forget_confirm()
	testing.expect_value(t, access_forget_aof_confirmed, u64(3))
	testing.expect_value(t, len(aof_awaited), 0)
	st: linux.Stat
	testing.expect_value(t, linux.stat(aof_cpath(name, fbuf[:]), &st), linux.Errno.ENOENT)
}

@(test)
the_command_form_base_is_refused_while_a_scheme_is_configured :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	scope_fixture_open(t, false)
	defer scope_fixture_close()
	saved, saved_runtime := aof.preamble, label_scheme_runtime
	defer {
		aof.preamble, label_scheme_runtime = saved, saved_runtime
	}
	label_scheme_runtime = true
	aof.preamble = true
	testing.expect_value(t, label_preamble_apply(), "")
	testing.expect_value(t, label_persistence_refusal(true), "")
	aof.preamble = false
	testing.expect_value(t, label_preamble_apply(), LABEL_AOF_BASE)
	testing.expect_value(t, label_persistence_refusal(true), LABEL_AOF_BASE)
	testing.expect_value(t, label_persistence_refusal(false), "")
	labels_on = false
	testing.expect_value(t, label_preamble_apply(), "")
	testing.expect_value(t, label_persistence_refusal(true), "")
	labels_on = true
}

@(test)
the_marker_follows_the_forced_mode_of_a_mode_change :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	scope_fixture_open(t, false)
	defer scope_fixture_close()
	b: [dynamic]u8
	defer delete(b)
	aof_marker_into(&b)
	testing.expect_value(t, string(b[:]), "*4\r\n$11\r\nESKI-ACCESS\r\n$1\r\n1\r\n$1\r\n1\r\n$1\r\n0\r\n")
	access_save_forced = true
	access_save_forced_mode = Access_Mode{true, true}
	defer access_save_forced = false
	clear(&b)
	aof_marker_into(&b)
	testing.expect_value(t, string(b[:]), "*4\r\n$11\r\nESKI-ACCESS\r\n$1\r\n1\r\n$1\r\n1\r\n$1\r\n1\r\n")
	testing.expect(t, aof_private())
	access_save_forced = false
	testing.expect(t, aof_private())
	labels_on = false
	testing.expect(t, !aof_private())
	testing.expect_value(t, aof_mode_file(), linux.Mode{.IRUSR, .IWUSR, .IRGRP, .IROTH})
	labels_on = true
	testing.expect_value(t, aof_mode_file(), linux.Mode{.IRUSR, .IWUSR})
	testing.expect_value(t, aof_mode_dir(), linux.Mode{.IRUSR, .IWUSR, .IXUSR})
}
