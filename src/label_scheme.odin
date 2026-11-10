package main

import "core:sys/linux"
import lb "label"

LABEL_SCHEME_PERSISTENCE :: "a label scheme needs persistence off: set save \"\", appendonly no and no save in shutdown-on-sigterm or shutdown-on-sigint first"
LABEL_PERSISTENCE_ON :: "persistence stays off while a label scheme is configured"
LABEL_SCHEME_MEMCACHED :: "a label scheme needs the memcached endpoint off, because its requests carry no label"

Label_Name_Kind :: enum u8 {
	Level,
	Compartment,
	Trust,
}

label_audit_file: string
label_token_audience: string
label_context_idle: i64 = 3600
label_context_cap: i64 = 1000
label_scheme_runtime: bool

@(private = "file")
label_audit_fd: linux.Fd = -1

@(private = "file")
label_checkpoint: [Label_Name_Kind][dynamic]string

@(private = "file")
label_checkpoint_taken: bool

special_label_levels := Config_Special{label_levels_set, label_levels_get, label_levels_rewrite}
special_label_compartments := Config_Special{label_compartments_set, label_compartments_get, label_compartments_rewrite}
special_label_trusts := Config_Special{label_trusts_set, label_trusts_get, label_trusts_rewrite}

@(private = "file")
label_kind_names :: proc(c: ^lb.Config, kind: Label_Name_Kind) -> []lb.Name {
	switch kind {
	case .Level:
		return c.levels[:]
	case .Compartment:
		return c.compartments[:]
	case .Trust:
		return c.trusts[:]
	}
	return nil
}

label_scheme_names :: proc(kind: Label_Name_Kind, out: ^[dynamic]string) {
	clear(out)
	for n in label_kind_names(&label_scheme, kind) {
		append(out, lb.config_name(&label_scheme, n))
	}
}

@(private = "file")
label_split_names :: proc(value: []u8, out: ^[dynamic]string) -> string {
	clear(out)
	if len(value) == 0 {
		return ""
	}
	start := 0
	for i in 0 ..= len(value) {
		if i < len(value) && value[i] != ',' {
			continue
		}
		normal: lb.Normal
		if !lb.normalise(string(value[start:i]), &normal) {
			return "label names are at most 64 bytes"
		}
		if normal.length == 0 {
			return "label names must not be empty"
		}
		text := string(clone_bytes(normal.bytes[:normal.length]))
		if !lb.name_canonical(text) {
			return "label names use letters, digits, '-', '_' and single inner spaces"
		}
		append(out, text)
		start = i + 1
	}
	return ""
}

@(private = "file")
label_build :: proc(lists: [Label_Name_Kind][]string, out: ^lb.Config) -> string {
	lb.config_init(out)
	for n in lists[.Level] {
		if eq_nocase(transmute([]u8)n, "context") || eq_nocase(transmute([]u8)n, "token") {
			lb.config_destroy(out)
			return "CONTEXT and TOKEN are reserved and cannot name a level"
		}
		if e := lb.config_add_level(out, n); e != .None {
			lb.config_destroy(out)
			return label_config_error_text(e)
		}
	}
	for n in lists[.Compartment] {
		if e := lb.config_add_compartment(out, n); e != .None {
			lb.config_destroy(out)
			return label_config_error_text(e)
		}
	}
	for n in lists[.Trust] {
		if e := lb.config_add_trust(out, n); e != .None {
			lb.config_destroy(out)
			return label_config_error_text(e)
		}
	}
	if len(out.levels) == 0 {
		lb.config_destroy(out)
		return "a label scheme needs at least one level"
	}
	return ""
}

label_config_error_text :: proc(e: lb.Config_Error) -> string {
	switch e {
	case .None:
		return ""
	case .Empty_Name:
		return "label names must not be empty"
	case .Name_Too_Long:
		return "label names are at most 64 bytes"
	case .Invalid_Name:
		return "label names use letters, digits, '-', '_' and single inner spaces"
	case .Duplicate_Name:
		return "label names must be distinct"
	case .Too_Many_Levels:
		return "a label scheme has at most 256 levels"
	case .Too_Many_Compartments:
		return "a label scheme has at most 256 compartments"
	case .Too_Many_Trusts:
		return "a label scheme has at most 256 trust levels"
	case .Unknown_Index, .Out_Of_Memory:
		return "label scheme update failed"
	}
	return "label scheme update failed"
}

@(private = "file")
label_persistence_on :: proc() -> bool {
	return len(pst.save_params) > 0 || aof.wanted || (cfg.shutdown_on_sigterm | cfg.shutdown_on_sigint) & SHUTDOWN_SAVE != 0
}

@(private = "file")
label_set_kind :: proc(kind: Label_Name_Kind, args: [][]u8) -> (bool, string) {
	if len(args) != 1 {
		return false, "wrong number of arguments"
	}
	incoming := make([dynamic]string, context.temp_allocator)
	if e := label_split_names(args[0], &incoming); e != "" {
		return false, e
	}
	lists: [Label_Name_Kind][dynamic]string
	for k in Label_Name_Kind {
		lists[k] = make([dynamic]string, context.temp_allocator)
		label_scheme_names(k, &lists[k])
	}
	if label_scheme_runtime {
		before := label_checkpoint[kind][:] if label_checkpoint_taken else lists[kind][:]
		if len(incoming) < len(before) {
			return false, "label scheme names can be added and renamed, never removed or reordered"
		}
		for name, i in incoming {
			if i < len(before) && name == before[i] {
				continue
			}
			for k in Label_Name_Kind {
				names := label_checkpoint[k][:] if label_checkpoint_taken else lists[k][:]
				for old in names {
					if old == name && (k == kind || (kind != .Trust && k != .Trust)) {
						return false, "a renamed or added label name must be new to the scheme"
					}
				}
			}
		}
	}
	clear(&lists[kind])
	append(&lists[kind], ..incoming[:])
	fresh: lb.Config
	views: [Label_Name_Kind][]string
	for k in Label_Name_Kind {
		views[k] = lists[k][:]
	}
	if e := label_build(views, &fresh); e != "" {
		return false, e
	}
	changed := len(label_kind_names(&fresh, kind)) != len(label_kind_names(&label_scheme, kind))
	if !changed {
		for n, i in label_kind_names(&fresh, kind) {
			if lb.config_name(&fresh, n) != lb.config_name(&label_scheme, label_kind_names(&label_scheme, kind)[i]) {
				changed = true
				break
			}
		}
	}
	if !changed {
		lb.config_destroy(&fresh)
		return false, ""
	}
	lb.config_destroy(&label_scheme)
	label_scheme = fresh
	return true, ""
}

@(private = "file")
label_get_kind :: proc(kind: Label_Name_Kind, b: ^[dynamic]u8) {
	for n, i in label_kind_names(&label_scheme, kind) {
		if i > 0 {
			sb_byte(b, ',')
		}
		sb_str(b, lb.config_name(&label_scheme, n))
	}
}

@(private = "file")
label_rewrite_kind :: proc(kind: Label_Name_Kind, rs: ^Rewrite_State, cf: ^Config) {
	value := make([dynamic]u8, context.temp_allocator)
	label_get_kind(kind, &value)
	force := len(label_kind_names(&label_scheme, kind)) > 0
	if kind == .Level {
		force = len(label_scheme.levels) != 1 || lb.config_level_name(&label_scheme, 0) != lb.DEFAULT_LEVEL
	}
	line := rewrite_line_buf(rs)
	sb_str(&line, cf.name)
	sb_byte(&line, ' ')
	sds_repr(&line, value[:])
	config_rewrite_line(rs, cf.name, string(line[:]), force)
}

label_levels_set :: proc(args: [][]u8) -> (bool, string) {
	return label_set_kind(.Level, args)
}

label_levels_get :: proc(b: ^[dynamic]u8) {
	label_get_kind(.Level, b)
}

label_levels_rewrite :: proc(rs: ^Rewrite_State, cf: ^Config) {
	label_rewrite_kind(.Level, rs, cf)
}

label_compartments_set :: proc(args: [][]u8) -> (bool, string) {
	return label_set_kind(.Compartment, args)
}

label_compartments_get :: proc(b: ^[dynamic]u8) {
	label_get_kind(.Compartment, b)
}

label_compartments_rewrite :: proc(rs: ^Rewrite_State, cf: ^Config) {
	label_rewrite_kind(.Compartment, rs, cf)
}

label_trusts_set :: proc(args: [][]u8) -> (bool, string) {
	return label_set_kind(.Trust, args)
}

label_trusts_get :: proc(b: ^[dynamic]u8) {
	label_get_kind(.Trust, b)
}

label_trusts_rewrite :: proc(rs: ^Rewrite_State, cf: ^Config) {
	label_rewrite_kind(.Trust, rs, cf)
}

label_scheme_apply :: proc() -> string {
	labelled := lb.config_labelled(&label_scheme)
	if label_scheme_runtime && labelled && label_persistence_on() {
		return LABEL_SCHEME_PERSISTENCE
	}
	if label_scheme_runtime && labelled && mc_port != 0 {
		return LABEL_SCHEME_MEMCACHED
	}
	labels_on = labelled
	access_scheme_changed()
	return ""
}

label_persistence_refusal :: proc(enabling: bool) -> string {
	if enabling && label_scheme_runtime && labels_on {
		return LABEL_PERSISTENCE_ON
	}
	return ""
}

label_scheme_checkpoint :: proc() {
	for k in Label_Name_Kind {
		for s in label_checkpoint[k] {
			delete(s)
		}
		clear(&label_checkpoint[k])
		for n in label_kind_names(&label_scheme, k) {
			append(&label_checkpoint[k], string(clone_bytes(transmute([]u8)lb.config_name(&label_scheme, n))))
		}
	}
	label_checkpoint_taken = true
}

label_scheme_committed :: proc(c: ^Conn) {
	if !label_checkpoint_taken {
		return
	}
	label_checkpoint_taken = false
	now := make([dynamic]string, context.temp_allocator)
	kinds := [Label_Name_Kind]string {
		.Level       = "levels",
		.Compartment = "compartments",
		.Trust       = "trust-levels",
	}
	for k in Label_Name_Kind {
		label_scheme_names(k, &now)
		same := len(now) == len(label_checkpoint[k])
		for i in 0 ..< min(len(now), len(label_checkpoint[k])) {
			if now[i] != label_checkpoint[k][i] {
				same = false
			}
		}
		if same {
			continue
		}
		before := make([dynamic]u8, context.temp_allocator)
		after := make([dynamic]u8, context.temp_allocator)
		for s, i in label_checkpoint[k] {
			if i > 0 {
				sb_byte(&before, ',')
			}
			sb_str(&before, s)
		}
		for s, i in now {
			if i > 0 {
				sb_byte(&after, ',')
			}
			sb_str(&after, s)
		}
		label_audit(c, "scheme-change", "kind", kinds[k], "before", string(before[:]), "after", string(after[:]))
	}
}

label_scheme_abandon :: proc() {
	label_checkpoint_taken = false
}

label_scheme_startup :: proc() {
	access_init()
	labels_on = lb.config_labelled(&label_scheme)
	access_scheme_changed()
	if labels_on && label_persistence_on() {
		config_fatal(0, "", LABEL_SCHEME_PERSISTENCE)
	}
	if labels_on && mc_port != 0 {
		config_fatal(0, "", LABEL_SCHEME_MEMCACHED)
	}
	if label_audit_file != "" {
		buf: [4096]u8
		fd, err := linux.open(persist_cstr(label_audit_file, buf[:]), {.WRONLY, .CREAT, .APPEND, .CLOEXEC}, {.IRUSR, .IWUSR})
		if err != .NONE {
			config_fatal(0, "", concat_temp("Can't open the label audit file: ", errno_text(err)))
		}
		linux.fchmod(fd, {.IRUSR, .IWUSR})
		label_audit_fd = fd
	}
	label_scheme_runtime = true
	if labels_on {
		levels := make([dynamic]u8, context.temp_allocator)
		comps := make([dynamic]u8, context.temp_allocator)
		trusts := make([dynamic]u8, context.temp_allocator)
		label_get_kind(.Level, &levels)
		label_get_kind(.Compartment, &comps)
		label_get_kind(.Trust, &trusts)
		label_audit(nil, "scheme-load", "levels", string(levels[:]), "compartments", string(comps[:]), "trust-levels", string(trusts[:]))
	}
}

@(private = "file")
label_json_string :: proc(b: ^[dynamic]u8, s: string) {
	hexd := "0123456789abcdef"
	sb_byte(b, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch {
		case ch == '"' || ch == '\\':
			sb_byte(b, '\\')
			sb_byte(b, ch)
		case ch < 0x20 || ch >= 0x7f:
			sb_str(b, "\\u00")
			sb_byte(b, hexd[ch >> 4])
			sb_byte(b, hexd[ch & 15])
		case:
			sb_byte(b, ch)
		}
	}
	sb_byte(b, '"')
}

label_audit_active :: #force_inline proc "contextless" () -> bool {
	return label_audit_fd >= 0
}

label_audit :: proc(c: ^Conn, event: string, details: ..string) {
	if label_audit_fd < 0 {
		return
	}
	b := make([dynamic]u8, context.temp_allocator)
	sec, usec := now_realtime()
	sb_str(&b, "{\"time\":")
	sb_int(&b, sec * 1000 + usec / 1000)
	sb_str(&b, ",\"login\":")
	who := "(server)"
	if c != nil {
		who = acl_user_name(c)
	}
	label_json_string(&b, who)
	if c != nil {
		sb_str(&b, ",\"client\":")
		sb_int(&b, c.id)
		sb_str(&b, ",\"addr\":")
		label_json_string(&b, string(c.addr[:c.addr_len]))
	}
	sb_str(&b, ",\"event\":")
	label_json_string(&b, event)
	sb_str(&b, ",\"details\":{")
	for i := 0; i + 1 < len(details); i += 2 {
		if i > 0 {
			sb_byte(&b, ',')
		}
		label_json_string(&b, details[i])
		sb_byte(&b, ':')
		label_json_string(&b, details[i + 1])
	}
	sb_str(&b, "}}\n")
	rest := b[:]
	for len(rest) > 0 {
		n, err := linux.write(label_audit_fd, rest)
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			plog(LOG_WARNING, "Writing the label audit file failed: ", errno_text(err))
			return
		}
		rest = rest[n:]
	}
	linux.fsync(label_audit_fd)
}

label_audit_declassify :: proc(c: ^Conn, key: []u8, element: []u8, from, to: lb.Id) {
	before := make([dynamic]u8, context.temp_allocator)
	after := make([dynamic]u8, context.temp_allocator)
	access_format(&before, from)
	access_format(&after, to)
	label_audit(c, "declassify", "key", string(key), "element", string(element), "from", string(before[:]), "to", string(after[:]))
}

label_audit_acl :: proc(c: ^Conn, event: string, username: []u8, rules: [][]u8) {
	if label_audit_fd < 0 {
		return
	}
	text := make([dynamic]u8, context.temp_allocator)
	for r, i in rules {
		if i > 0 {
			sb_byte(&text, ' ')
		}
		if len(r) > 0 && (r[0] == '>' || r[0] == '<' || r[0] == '#' || r[0] == '!') {
			sb_byte(&text, r[0])
			sb_str(&text, "(redacted)")
			continue
		}
		sb_bytes(&text, r)
	}
	label_audit(c, event, "user", string(username), "rules", string(text[:]))
}
