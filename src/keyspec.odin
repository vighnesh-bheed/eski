package main

Cmd_Flag :: enum u32 {
	Admin,
	Allow_Busy,
	Asking,
	Blocking,
	Denyoom,
	Fast,
	Loading,
	May_Replicate,
	Noscript,
	No_Async_Loading,
	No_Auth,
	No_Mandatory_Keys,
	No_Multi,
	Protected,
	Pubsub,
	Readonly,
	Sentinel,
	Skip_Monitor,
	Skip_Slowlog,
	Stale,
	Touches_Arbitrary_Keys,
	Write,
	Module,
}

Cmd_Flags :: bit_set[Cmd_Flag;u32]

Key_Flag :: enum u16 {
	Ro,
	Rw,
	Ow,
	Rm,
	Access,
	Update,
	Insert,
	Delete,
	Not_Key,
	Incomplete,
	Variable_Flags,
}

Key_Flags :: bit_set[Key_Flag;u16]

Key_Search :: enum u8 {
	Index,
	Keyword,
	Unknown,
}

Key_Find :: enum u8 {
	Range,
	Keynum,
	Unknown,
}

Getkeys_Proc :: enum u8 {
	None,
	Bitfield,
	Blmpop,
	Eval,
	Function,
	Georadius,
	Lmpop,
	Migrate,
	Set,
	Sintercard,
	Sort,
	Sort_Ro,
	Xread,
	Zmpop,
	Zunion_Inter_Diff,
	Zunion_Inter_Diff_Store,
}

Key_Spec :: struct {
	search:  Key_Search,
	pos:     i32,
	keyword: string,
	from:    i32,
	find:    Key_Find,
	a:       i32,
	b:       i32,
	c:       i32,
	flags:   Key_Flags,
}

Cmd_Spec :: struct {
	name:    string,
	arity:   i32,
	flags:   Cmd_Flags,
	getkeys: Getkeys_Proc,
	first:   i32,
	last:    i32,
	step:    i32,
	specs:   []Key_Spec,
}

@(private = "file")
spec_index: map[string]int
@(private = "file")
spec_containers: map[string]bool
@(private = "file")
spec_name_buf: [96]u8

@(private = "file")
spec_index_build :: proc() {
	for s, i in cmd_specs {
		spec_index[s.name] = i
		for ch, j in transmute([]u8)s.name {
			if ch == '|' {
				spec_containers[s.name[:j]] = true
				break
			}
		}
	}
}

cmd_spec_lookup :: proc(cmd: ^Command, argv: [][]u8) -> ^Cmd_Spec {
	if len(spec_index) == 0 {
		spec_index_build()
	}
	name := cmd.name
	if len(argv) >= 2 && spec_containers[name] {
		sub := argv[1]
		if len(name) + 1 + len(sub) > len(spec_name_buf) {
			return nil
		}
		n := copy(spec_name_buf[:], name)
		spec_name_buf[n] = '|'
		n += 1
		for b in sub {
			spec_name_buf[n] = lower(b)
			n += 1
		}
		if i, ok := spec_index[string(spec_name_buf[:n])]; ok {
			return &cmd_specs[i]
		}
		return nil
	}
	if i, ok := spec_index[name]; ok {
		return &cmd_specs[i]
	}
	return nil
}

@(private = "file")
generic_get_keys :: proc(store_ofs, count_ofs, first_ofs, step: int, argv: [][]u8, out: ^[dynamic]int) {
	argc := len(argv)
	if count_ofs >= argc {
		return
	}
	num := int(c_atoi(argv[count_ofs]))
	if num < 1 || num > (argc - first_ofs) / step {
		return
	}
	for i in 0 ..< num {
		append(out, first_ofs + i * step)
	}
	if store_ofs != 0 {
		append(out, store_ofs)
	}
}

command_keys :: proc(spec: ^Cmd_Spec, argv: [][]u8, out: ^[dynamic]int) {
	clear(out)
	argc := len(argv)
	switch spec.getkeys {
	case .Sintercard, .Zunion_Inter_Diff, .Lmpop, .Zmpop:
		generic_get_keys(0, 1, 2, 1, argv, out)
		return
	case .Zunion_Inter_Diff_Store:
		generic_get_keys(1, 2, 3, 1, argv, out)
		return
	case .Eval, .Function, .Blmpop:
		generic_get_keys(0, 2, 3, 1, argv, out)
		return
	case .Sort_Ro, .Set, .Bitfield:
		append(out, 1)
		return
	case .Sort:
		append(out, 1)
		store := -1
		skips := [?]struct {
			name: string,
			skip: int,
		}{{"limit", 2}, {"get", 1}, {"by", 1}}
		for i := 2; i < argc; i += 1 {
			for s in skips {
				if eq_nocase(argv[i], s.name) {
					i += s.skip
					break
				} else if eq_nocase(argv[i], "store") && i + 1 < argc {
					store = i + 1
					i += 1
					break
				}
			}
		}
		if store >= 0 {
			append(out, store)
		}
		return
	case .Georadius:
		append(out, 1)
		stored := -1
		for i := 5; i < argc; i += 1 {
			if (eq_nocase(argv[i], "store") || eq_nocase(argv[i], "storedist")) && i + 1 < argc {
				stored = i + 1
				i += 1
			}
		}
		if stored >= 0 {
			append(out, stored)
		}
		return
	case .Migrate:
		first, num := 3, 1
		if argc > 6 {
			outer: for i := 6; i < argc; i += 1 {
				if eq_nocase(argv[i], "keys") {
					if len(argv[3]) > 0 {
						num = 0
					} else {
						first = i + 1
						num = argc - first
					}
					break outer
				}
				switch {
				case eq_nocase(argv[i], "auth"):
					i += 1
				case eq_nocase(argv[i], "auth2"):
					i += 2
				}
			}
		}
		for i in 0 ..< num {
			append(out, first + i)
		}
		return
	case .Xread:
		streams := -1
		scan: for i := 1; i < argc; i += 1 {
			switch {
			case eq_nocase(argv[i], "block"), eq_nocase(argv[i], "count"):
				i += 1
			case eq_nocase(argv[i], "group"):
				i += 2
			case eq_nocase(argv[i], "noack"):
			case eq_nocase(argv[i], "streams"):
				streams = i
				break scan
			case:
				break scan
			}
		}
		if streams < 0 {
			return
		}
		num := argc - streams - 1
		if num == 0 || num % 2 != 0 {
			return
		}
		num /= 2
		for i in streams + 1 ..< argc - num {
			append(out, i)
		}
		return
	case .None:
	}
	if spec.first == 0 {
		return
	}
	first := int(spec.first)
	last := int(spec.last)
	if last >= 0 {
		last += first
	} else {
		last += argc
	}
	step := max(int(spec.step), 1)
	for j := first; j <= last; j += step {
		if j >= argc || j < first {
			clear(out)
			return
		}
		append(out, j)
	}
}

cmd_specs := [?]Cmd_Spec {
	{"VADD", -5, {.Write, .Denyoom, .Module}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"VCARD", 2, {.Readonly, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"VDIM", 2, {.Readonly, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"VEMB", -3, {.Readonly, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"VGETATTR", 3, {.Readonly, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"VINFO", 2, {.Readonly, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"VISMEMBER", 3, {.Readonly, .Module}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"VLINKS", -3, {.Readonly, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"VRANDMEMBER", -2, {.Readonly, .Module}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"VRANGE", -4, {.Readonly, .Module}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"VREM", 3, {.Write, .Module}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"VSETATTR", 4, {.Write, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"VSIM", -4, {.Readonly, .Module}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"acl", -2, {.Sentinel}, .None, 0, 0, 0, nil},
	{"acl|cat", -2, {.Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"acl|deluser", -3, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"acl|dryrun", -4, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"acl|genpass", -2, {.Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"acl|getuser", 3, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"acl|help", 2, {.Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"acl|list", 2, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"acl|load", 2, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"acl|log", -2, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"acl|save", 2, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"acl|setuser", -3, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"acl|users", 2, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"acl|whoami", 2, {.Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"append", 3, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"asking", 1, {.Fast}, .None, 0, 0, 0, nil},
	{"auth", -2, {.Noscript, .Loading, .Stale, .Fast, .No_Auth, .Sentinel, .Allow_Busy}, .None, 0, 0, 0, nil},
	{"bgrewriteaof", 1, {.No_Async_Loading, .Admin, .Noscript}, .None, 0, 0, 0, nil},
	{"bgsave", -1, {.No_Async_Loading, .Admin, .Noscript}, .None, 0, 0, 0, nil},
	{"bitcount", -2, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"bitfield", -2, {.Write, .Denyoom}, .Bitfield, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update, .Access, .Variable_Flags}}}},
	{"bitfield_ro", -2, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"bitop", -4, {.Write, .Denyoom}, .None, 2, -1, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}, {.Index, 3, "", 0, .Range, -1, 1, 0, {.Ro, .Access}}}},
	{"bitpos", -3, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"blmove", 6, {.Write, .Denyoom, .Blocking}, .None, 1, 1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}, {.Index, 2, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"blmpop", -5, {.Write, .Blocking}, .Blmpop, 0, 0, 0, {{.Index, 2, "", 0, .Keynum, 0, 1, 1, {.Rw, .Access, .Delete}}}},
	{"blpop", -3, {.Write, .Blocking}, .None, 1, -2, 1, {{.Index, 1, "", 0, .Range, -2, 1, 0, {.Rw, .Access, .Delete}}}},
	{"brpop", -3, {.Write, .Blocking}, .None, 1, -2, 1, {{.Index, 1, "", 0, .Range, -2, 1, 0, {.Rw, .Access, .Delete}}}},
	{"brpoplpush", 4, {.Write, .Denyoom, .Blocking}, .None, 1, 1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}, {.Index, 2, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"bzmpop", -5, {.Write, .Blocking}, .Blmpop, 0, 0, 0, {{.Index, 2, "", 0, .Keynum, 0, 1, 1, {.Rw, .Access, .Delete}}}},
	{"bzpopmax", -3, {.Write, .Fast, .Blocking}, .None, 1, -2, 1, {{.Index, 1, "", 0, .Range, -2, 1, 0, {.Rw, .Access, .Delete}}}},
	{"bzpopmin", -3, {.Write, .Fast, .Blocking}, .None, 1, -2, 1, {{.Index, 1, "", 0, .Range, -2, 1, 0, {.Rw, .Access, .Delete}}}},
	{"client", -2, {.Sentinel}, .None, 0, 0, 0, nil},
	{"client|caching", 3, {.Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|getname", 2, {.Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|getredir", 2, {.Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|help", 2, {.Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|id", 2, {.Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|info", 2, {.Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|kill", -3, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|list", -2, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|no-evict", 3, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|no-touch", 3, {.Noscript, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"client|pause", -3, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|reply", 3, {.Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|setinfo", 4, {.Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|setname", 3, {.Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|tracking", -3, {.Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|trackinginfo", 2, {.Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|unblock", -3, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"client|unpause", 2, {.Admin, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"cluster", -2, {}, .None, 0, 0, 0, nil},
	{"cluster|addslots", -3, {.No_Async_Loading, .Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|addslotsrange", -4, {.No_Async_Loading, .Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|bumpepoch", 2, {.No_Async_Loading, .Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|count-failure-reports", 3, {.Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|countkeysinslot", 3, {.Stale}, .None, 0, 0, 0, nil},
	{"cluster|delslots", -3, {.No_Async_Loading, .Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|delslotsrange", -4, {.No_Async_Loading, .Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|failover", -2, {.No_Async_Loading, .Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|flushslots", 2, {.No_Async_Loading, .Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|forget", 3, {.No_Async_Loading, .Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|getkeysinslot", 4, {.Stale}, .None, 0, 0, 0, nil},
	{"cluster|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|info", 2, {.Stale}, .None, 0, 0, 0, nil},
	{"cluster|keyslot", 3, {.Stale}, .None, 0, 0, 0, nil},
	{"cluster|links", 2, {.Stale}, .None, 0, 0, 0, nil},
	{"cluster|meet", -4, {.No_Async_Loading, .Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|myid", 2, {.Stale}, .None, 0, 0, 0, nil},
	{"cluster|myshardid", 2, {.Stale}, .None, 0, 0, 0, nil},
	{"cluster|nodes", 2, {.Stale}, .None, 0, 0, 0, nil},
	{"cluster|replicas", 3, {.Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|replicate", 3, {.No_Async_Loading, .Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|reset", -2, {.Admin, .Stale, .Noscript}, .None, 0, 0, 0, nil},
	{"cluster|saveconfig", 2, {.No_Async_Loading, .Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|set-config-epoch", 3, {.No_Async_Loading, .Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|setslot", -4, {.No_Async_Loading, .Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|shards", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|slaves", 3, {.Admin, .Stale}, .None, 0, 0, 0, nil},
	{"cluster|slots", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"command", -1, {.Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"command|count", 2, {.Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"command|docs", -2, {.Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"command|getkeys", -3, {.Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"command|getkeysandflags", -3, {.Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"command|help", 2, {.Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"command|info", -2, {.Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"command|list", -2, {.Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"config", -2, {}, .None, 0, 0, 0, nil},
	{"config|get", -3, {.Admin, .Noscript, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"config|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"config|resetstat", 2, {.Admin, .Noscript, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"config|rewrite", 2, {.Admin, .Noscript, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"config|set", -4, {.Admin, .Noscript, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"context", -2, {}, .None, 0, 0, 0, nil},
	{"context|create", -2, {.Noscript, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"context|drop", 3, {.Noscript, .Loading, .Stale, .Fast}, .None, 0, 0, 0, nil},
	{"context|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"context|info", 3, {.Noscript, .Loading, .Stale, .Fast}, .None, 0, 0, 0, nil},
	{"copy", -3, {.Write, .Denyoom}, .None, 1, 1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}, {.Index, 2, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}}},
	{"dbsize", 1, {.Readonly, .Fast}, .None, 0, 0, 0, nil},
	{"debug", -2, {.Admin, .Noscript, .Loading, .Stale, .Protected}, .None, 0, 0, 0, nil},
	{"decr", 2, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"decrby", 3, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"del", -2, {.Write}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, -1, 1, 0, {.Rm, .Delete}}}},
	{"discard", 1, {.Noscript, .Loading, .Stale, .Fast, .Allow_Busy}, .None, 0, 0, 0, nil},
	{"dump", 2, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"echo", 2, {.Loading, .Stale, .Fast}, .None, 0, 0, 0, nil},
	{"eval", -3, {.Noscript, .Skip_Monitor, .May_Replicate, .No_Mandatory_Keys, .Stale}, .Eval, 0, 0, 0, {{.Index, 2, "", 0, .Keynum, 0, 1, 1, {.Rw, .Access, .Update}}}},
	{"eval_ro", -3, {.Noscript, .Skip_Monitor, .No_Mandatory_Keys, .Stale, .Readonly}, .Eval, 0, 0, 0, {{.Index, 2, "", 0, .Keynum, 0, 1, 1, {.Ro, .Access}}}},
	{"evalsha", -3, {.Noscript, .Skip_Monitor, .May_Replicate, .No_Mandatory_Keys, .Stale}, .Eval, 0, 0, 0, {{.Index, 2, "", 0, .Keynum, 0, 1, 1, {.Rw, .Access, .Update}}}},
	{"evalsha_ro", -3, {.Noscript, .Skip_Monitor, .No_Mandatory_Keys, .Stale, .Readonly}, .Eval, 0, 0, 0, {{.Index, 2, "", 0, .Keynum, 0, 1, 1, {.Ro, .Access}}}},
	{"exec", 1, {.Noscript, .Loading, .Stale, .Skip_Slowlog}, .None, 0, 0, 0, nil},
	{"exists", -2, {.Readonly, .Fast}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, -1, 1, 0, {.Ro}}}},
	{"expire", -3, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"expireat", -3, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"expiretime", 2, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"failover", -1, {.Admin, .Noscript, .Stale}, .None, 0, 0, 0, nil},
	{"fcall", -3, {.Noscript, .Skip_Monitor, .May_Replicate, .No_Mandatory_Keys, .Stale}, .Function, 0, 0, 0, {{.Index, 2, "", 0, .Keynum, 0, 1, 1, {.Rw, .Access, .Update}}}},
	{"fcall_ro", -3, {.Noscript, .Skip_Monitor, .No_Mandatory_Keys, .Stale, .Readonly}, .Function, 0, 0, 0, {{.Index, 2, "", 0, .Keynum, 0, 1, 1, {.Ro, .Access}}}},
	{"flushall", -1, {.Write}, .None, 0, 0, 0, nil},
	{"flushdb", -1, {.Write}, .None, 0, 0, 0, nil},
	{"function", -2, {}, .None, 0, 0, 0, nil},
	{"function|delete", 3, {.Noscript, .Write}, .None, 0, 0, 0, nil},
	{"function|dump", 2, {.Noscript}, .None, 0, 0, 0, nil},
	{"function|flush", -2, {.Noscript, .Write}, .None, 0, 0, 0, nil},
	{"function|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"function|kill", 2, {.Noscript, .Allow_Busy}, .None, 0, 0, 0, nil},
	{"function|list", -2, {.Noscript}, .None, 0, 0, 0, nil},
	{"function|load", -3, {.Noscript, .Write, .Denyoom}, .None, 0, 0, 0, nil},
	{"function|restore", -3, {.Noscript, .Write, .Denyoom}, .None, 0, 0, 0, nil},
	{"function|stats", 2, {.Noscript, .Allow_Busy}, .None, 0, 0, 0, nil},
	{"geoadd", -5, {.Write, .Denyoom}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"geodist", -4, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"geohash", -2, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"geopos", -2, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"georadius", -6, {.Write, .Denyoom}, .Georadius, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}, {.Keyword, 0, "STORE", 6, .Range, 0, 1, 0, {.Ow, .Update, .Incomplete}}, {.Keyword, 0, "STOREDIST", 6, .Range, 0, 1, 0, {.Ow, .Update, .Incomplete}}}},
	{"georadius_ro", -6, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"georadiusbymember", -5, {.Write, .Denyoom}, .Georadius, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}, {.Keyword, 0, "STORE", 5, .Range, 0, 1, 0, {.Ow, .Update, .Incomplete}}, {.Keyword, 0, "STOREDIST", 5, .Range, 0, 1, 0, {.Ow, .Update, .Incomplete}}}},
	{"georadiusbymember_ro", -5, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"geosearch", -7, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"geosearchstore", -8, {.Write, .Denyoom}, .None, 1, 1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}, {.Index, 2, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"get", 2, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"getbit", 3, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"getdel", 2, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}}},
	{"getex", -2, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"getrange", 4, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"getset", 3, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"hdel", -3, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Delete}}}},
	{"hello", -1, {.Noscript, .Loading, .Stale, .Fast, .No_Auth, .Sentinel, .Allow_Busy}, .None, 0, 0, 0, nil},
	{"hexists", 3, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"hexpire", -6, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"hexpireat", -6, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"hexpiretime", -5, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"hget", 3, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"hgetall", 2, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"hincrby", 4, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"hincrbyfloat", 4, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"hkeys", 2, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"hlen", 2, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"hmget", -3, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"hmset", -4, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"hpersist", -5, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"hpexpire", -6, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"hpexpireat", -6, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"hpexpiretime", -5, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"hpttl", -5, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"hrandfield", -2, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"hscan", -3, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"hset", -4, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"hsetnx", 4, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"hstrlen", 3, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"httl", -5, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"hvals", 2, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"incr", 2, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"incrby", 3, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"incrbyfloat", 3, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"info", -1, {.Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"keys", 2, {.Readonly}, .None, 0, 0, 0, nil},
	{"label", -2, {}, .None, 0, 0, 0, nil},
	{"label|as", -4, {.Noscript, .Loading, .Stale, .Fast}, .None, 0, 0, 0, nil},
	{"label|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"label|session", -3, {.Noscript, .Loading, .Stale, .Fast, .No_Multi}, .None, 0, 0, 0, nil},
	{"label|whoami", 2, {.Loading, .Stale, .Fast}, .None, 0, 0, 0, nil},
	{"lastsave", 1, {.Loading, .Stale, .Fast}, .None, 0, 0, 0, nil},
	{"latency", -2, {}, .None, 0, 0, 0, nil},
	{"latency|doctor", 2, {.Admin, .Noscript, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"latency|graph", 3, {.Admin, .Noscript, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"latency|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"latency|histogram", -2, {.Admin, .Noscript, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"latency|history", 3, {.Admin, .Noscript, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"latency|latest", 2, {.Admin, .Noscript, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"latency|reset", -2, {.Admin, .Noscript, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"lcs", -3, {.Readonly}, .None, 1, 1, 1, {{.Index, 1, "", 0, .Range, 1, 1, 0, {.Ro, .Access}}}},
	{"lindex", 3, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"linsert", 5, {.Write, .Denyoom}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"llen", 2, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"lmove", 5, {.Write, .Denyoom}, .None, 1, 1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}, {.Index, 2, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"lmpop", -4, {.Write}, .Lmpop, 0, 0, 0, {{.Index, 1, "", 0, .Keynum, 0, 1, 1, {.Rw, .Access, .Delete}}}},
	{"lolwut", -1, {.Readonly, .Fast}, .None, 0, 0, 0, nil},
	{"lpop", -2, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}}},
	{"lpos", -3, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"lpush", -3, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"lpushx", -3, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"lrange", 4, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"lrem", 4, {.Write}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Delete}}}},
	{"lset", 4, {.Write, .Denyoom}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"ltrim", 4, {.Write}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Delete}}}},
	{"memory", -2, {}, .None, 0, 0, 0, nil},
	{"memory|doctor", 2, {}, .None, 0, 0, 0, nil},
	{"memory|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"memory|malloc-stats", 2, {}, .None, 0, 0, 0, nil},
	{"memory|purge", 2, {}, .None, 0, 0, 0, nil},
	{"memory|stats", 2, {}, .None, 0, 0, 0, nil},
	{"memory|usage", -3, {.Readonly}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"mget", -2, {.Readonly, .Fast}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, -1, 1, 0, {.Ro, .Access}}}},
	{"migrate", -6, {.Write}, .Migrate, 3, 0, 1, {{.Index, 3, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}, {.Keyword, 0, "KEYS", -2, .Range, -1, 1, 0, {.Rw, .Access, .Delete, .Incomplete}}}},
	{"module", -2, {}, .None, 0, 0, 0, nil},
	{"module|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"module|list", 2, {.Admin, .Noscript}, .None, 0, 0, 0, nil},
	{"module|load", -3, {.No_Async_Loading, .Admin, .Noscript, .Protected}, .None, 0, 0, 0, nil},
	{"module|loadex", -3, {.No_Async_Loading, .Admin, .Noscript, .Protected}, .None, 0, 0, 0, nil},
	{"module|unload", 3, {.No_Async_Loading, .Admin, .Noscript, .Protected}, .None, 0, 0, 0, nil},
	{"monitor", 1, {.Admin, .Noscript, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"move", 3, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"mset", -3, {.Write, .Denyoom}, .None, 1, -1, 2, {{.Index, 1, "", 0, .Range, -1, 2, 0, {.Ow, .Update}}}},
	{"msetnx", -3, {.Write, .Denyoom}, .None, 1, -1, 2, {{.Index, 1, "", 0, .Range, -1, 2, 0, {.Ow, .Insert}}}},
	{"multi", 1, {.Noscript, .Loading, .Stale, .Fast, .Allow_Busy}, .None, 0, 0, 0, nil},
	{"object", -2, {}, .None, 0, 0, 0, nil},
	{"object|encoding", 3, {.Readonly}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"object|freq", 3, {.Readonly}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"object|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"object|idletime", 3, {.Readonly}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"object|refcount", 3, {.Readonly}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"persist", 2, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"pexpire", -3, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"pexpireat", -3, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"pexpiretime", 2, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"pfadd", -2, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"pfcount", -2, {.Readonly, .May_Replicate}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, -1, 1, 0, {.Rw, .Access}}}},
	{"pfdebug", 3, {.Write, .Denyoom, .Admin}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Rw, .Access}}}},
	{"pfmerge", -2, {.Write, .Denyoom}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Insert}}, {.Index, 2, "", 0, .Range, -1, 1, 0, {.Ro, .Access}}}},
	{"pfselftest", 1, {.Admin}, .None, 0, 0, 0, nil},
	{"ping", -1, {.Fast, .Sentinel}, .None, 0, 0, 0, nil},
	{"psetex", 4, {.Write, .Denyoom}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}}},
	{"psubscribe", -2, {.Pubsub, .Noscript, .Loading, .Stale, .Sentinel, .Denyoom}, .None, 0, 0, 0, nil},
	{"psync", -3, {.No_Async_Loading, .Admin, .No_Multi, .Noscript}, .None, 0, 0, 0, nil},
	{"pttl", 2, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"publish", 3, {.Pubsub, .Loading, .Stale, .Fast, .May_Replicate, .Sentinel}, .None, 0, 0, 0, nil},
	{"pubsub", -2, {}, .None, 0, 0, 0, nil},
	{"pubsub|channels", -2, {.Pubsub, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"pubsub|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"pubsub|numpat", 2, {.Pubsub, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"pubsub|numsub", -2, {.Pubsub, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"pubsub|shardchannels", -2, {.Pubsub, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"pubsub|shardnumsub", -2, {.Pubsub, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"punsubscribe", -1, {.Pubsub, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"quit", -1, {.Allow_Busy, .Noscript, .Loading, .Stale, .Fast, .No_Auth}, .None, 0, 0, 0, nil},
	{"randomkey", 1, {.Readonly, .Touches_Arbitrary_Keys}, .None, 0, 0, 0, nil},
	{"readonly", 1, {.Fast, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"readwrite", 1, {.Fast, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"rename", 3, {.Write}, .None, 1, 1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}, {.Index, 2, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}}},
	{"renamenx", 3, {.Write, .Fast}, .None, 1, 1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}, {.Index, 2, "", 0, .Range, 0, 1, 0, {.Ow, .Insert}}}},
	{"replconf", -1, {.Admin, .Noscript, .Loading, .Stale, .Allow_Busy}, .None, 0, 0, 0, nil},
	{"replicaof", 3, {.No_Async_Loading, .Admin, .Noscript, .Stale}, .None, 0, 0, 0, nil},
	{"reset", 1, {.Noscript, .Loading, .Stale, .Fast, .No_Auth, .Allow_Busy}, .None, 0, 0, 0, nil},
	{"restore", -4, {.Write, .Denyoom}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}}},
	{"restore-asking", -4, {.Write, .Denyoom, .Asking}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}}},
	{"role", 1, {.Noscript, .Loading, .Stale, .Fast, .Sentinel}, .None, 0, 0, 0, nil},
	{"rpop", -2, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}}},
	{"rpoplpush", 3, {.Write, .Denyoom}, .None, 1, 1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}, {.Index, 2, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"rpush", -3, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"rpushx", -3, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"sadd", -3, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"save", 1, {.No_Async_Loading, .Admin, .Noscript, .No_Multi}, .None, 0, 0, 0, nil},
	{"scan", -2, {.Readonly, .Touches_Arbitrary_Keys}, .None, 0, 0, 0, nil},
	{"scard", 2, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"script", -2, {}, .None, 0, 0, 0, nil},
	{"script|debug", 3, {.Noscript}, .None, 0, 0, 0, nil},
	{"script|exists", -3, {.Noscript}, .None, 0, 0, 0, nil},
	{"script|flush", -2, {.Noscript}, .None, 0, 0, 0, nil},
	{"script|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"script|kill", 2, {.Noscript, .Allow_Busy}, .None, 0, 0, 0, nil},
	{"script|load", 3, {.Noscript, .Stale}, .None, 0, 0, 0, nil},
	{"sdiff", -2, {.Readonly}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, -1, 1, 0, {.Ro, .Access}}}},
	{"sdiffstore", -3, {.Write, .Denyoom}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}, {.Index, 2, "", 0, .Range, -1, 1, 0, {.Ro, .Access}}}},
	{"select", 2, {.Loading, .Stale, .Fast}, .None, 0, 0, 0, nil},
	{"set", -3, {.Write, .Denyoom}, .Set, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update, .Variable_Flags}}}},
	{"setbit", 4, {.Write, .Denyoom}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"setex", 4, {.Write, .Denyoom}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}}},
	{"setnx", 3, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ow, .Insert}}}},
	{"setrange", 4, {.Write, .Denyoom}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"shutdown", -1, {.Admin, .Noscript, .Loading, .Stale, .No_Multi, .Sentinel, .Allow_Busy}, .None, 0, 0, 0, nil},
	{"sinter", -2, {.Readonly}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, -1, 1, 0, {.Ro, .Access}}}},
	{"sintercard", -3, {.Readonly}, .Sintercard, 0, 0, 0, {{.Index, 1, "", 0, .Keynum, 0, 1, 1, {.Ro, .Access}}}},
	{"sinterstore", -3, {.Write, .Denyoom}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}, {.Index, 2, "", 0, .Range, -1, 1, 0, {.Ro, .Access}}}},
	{"sismember", 3, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"slaveof", 3, {.No_Async_Loading, .Admin, .Noscript, .Stale}, .None, 0, 0, 0, nil},
	{"slowlog", -2, {}, .None, 0, 0, 0, nil},
	{"slowlog|get", -2, {.Admin, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"slowlog|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"slowlog|len", 2, {.Admin, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"slowlog|reset", 2, {.Admin, .Loading, .Stale}, .None, 0, 0, 0, nil},
	{"smembers", 2, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"smismember", -3, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"smove", 4, {.Write, .Fast}, .None, 1, 1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}, {.Index, 2, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"sort", -2, {.Write, .Denyoom}, .Sort, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}, {.Unknown, 0, "", 0, .Unknown, 0, 0, 0, {.Ro, .Access}}, {.Unknown, 0, "", 0, .Unknown, 0, 0, 0, {.Ow, .Update}}}},
	{"sort_ro", -2, {.Readonly}, .Sort_Ro, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}, {.Unknown, 0, "", 0, .Unknown, 0, 0, 0, {.Ro, .Access}}}},
	{"spop", -2, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}}},
	{"spublish", 3, {.Pubsub, .Loading, .Stale, .Fast, .May_Replicate}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Not_Key}}}},
	{"srandmember", -2, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"srem", -3, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Delete}}}},
	{"sscan", -3, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"ssubscribe", -2, {.Pubsub, .Noscript, .Loading, .Stale, .Denyoom}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, -1, 1, 0, {.Not_Key}}}},
	{"strlen", 2, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"subscribe", -2, {.Pubsub, .Noscript, .Loading, .Stale, .Sentinel, .Denyoom}, .None, 0, 0, 0, nil},
	{"substr", 4, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"sunion", -2, {.Readonly}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, -1, 1, 0, {.Ro, .Access}}}},
	{"sunionstore", -3, {.Write, .Denyoom}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}, {.Index, 2, "", 0, .Range, -1, 1, 0, {.Ro, .Access}}}},
	{"sunsubscribe", -1, {.Pubsub, .Noscript, .Loading, .Stale}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, -1, 1, 0, {.Not_Key}}}},
	{"swapdb", 3, {.Write, .Fast}, .None, 0, 0, 0, nil},
	{"sync", 1, {.No_Async_Loading, .Admin, .No_Multi, .Noscript}, .None, 0, 0, 0, nil},
	{"time", 1, {.Loading, .Stale, .Fast}, .None, 0, 0, 0, nil},
	{"touch", -2, {.Readonly, .Fast}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, -1, 1, 0, {.Ro}}}},
	{"ttl", 2, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"type", 2, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"unlink", -2, {.Write, .Fast}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, -1, 1, 0, {.Rm, .Delete}}}},
	{"unsubscribe", -1, {.Pubsub, .Noscript, .Loading, .Stale, .Sentinel}, .None, 0, 0, 0, nil},
	{"unwatch", 1, {.Noscript, .Loading, .Stale, .Fast, .Allow_Busy}, .None, 0, 0, 0, nil},
	{"wait", 3, {.Blocking}, .None, 0, 0, 0, nil},
	{"waitaof", 4, {.Blocking}, .None, 0, 0, 0, nil},
	{"watch", -2, {.Noscript, .Loading, .Stale, .Fast, .Allow_Busy}, .None, 1, -1, 1, {{.Index, 1, "", 0, .Range, -1, 1, 0, {.Ro}}}},
	{"xack", -4, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"xadd", -5, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"xautoclaim", -6, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Delete}}}},
	{"xclaim", -6, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"xdel", -3, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Delete}}}},
	{"xgroup", -2, {}, .None, 0, 0, 0, nil},
	{"xgroup|create", -5, {.Write, .Denyoom}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"xgroup|createconsumer", 5, {.Write, .Denyoom}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Rw, .Insert}}}},
	{"xgroup|delconsumer", 5, {.Write}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Rw, .Delete}}}},
	{"xgroup|destroy", 4, {.Write}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Rw, .Delete}}}},
	{"xgroup|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"xgroup|setid", -5, {.Write}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"xinfo", -2, {}, .None, 0, 0, 0, nil},
	{"xinfo|consumers", 4, {.Readonly}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"xinfo|groups", 3, {.Readonly}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"xinfo|help", 2, {.Loading, .Stale}, .None, 0, 0, 0, nil},
	{"xinfo|stream", -3, {.Readonly}, .None, 2, 0, 1, {{.Index, 2, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"xlen", 2, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"xpending", -3, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"xrange", -4, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"xread", -4, {.Blocking, .Readonly}, .Xread, 0, 0, 0, {{.Keyword, 0, "STREAMS", 1, .Range, -1, 1, 2, {.Ro, .Access, .Incomplete}}}},
	{"xreadgroup", -7, {.Blocking, .Write}, .Xread, 0, 0, 0, {{.Keyword, 0, "STREAMS", 4, .Range, -1, 1, 2, {.Ro, .Access, .Incomplete}}}},
	{"xrevrange", -4, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"xsetid", -3, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"xtrim", -4, {.Write}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Delete}}}},
	{"zadd", -4, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Update}}}},
	{"zcard", 2, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro}}}},
	{"zcount", 4, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zdiff", -3, {.Readonly}, .Zunion_Inter_Diff, 0, 0, 0, {{.Index, 1, "", 0, .Keynum, 0, 1, 1, {.Ro, .Access}}}},
	{"zdiffstore", -4, {.Write, .Denyoom}, .Zunion_Inter_Diff_Store, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}, {.Index, 2, "", 0, .Keynum, 0, 1, 1, {.Ro, .Access}}}},
	{"zincrby", 4, {.Write, .Denyoom, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	{"zinter", -3, {.Readonly}, .Zunion_Inter_Diff, 0, 0, 0, {{.Index, 1, "", 0, .Keynum, 0, 1, 1, {.Ro, .Access}}}},
	{"zintercard", -3, {.Readonly}, .Zunion_Inter_Diff, 0, 0, 0, {{.Index, 1, "", 0, .Keynum, 0, 1, 1, {.Ro, .Access}}}},
	{"zinterstore", -4, {.Write, .Denyoom}, .Zunion_Inter_Diff_Store, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}, {.Index, 2, "", 0, .Keynum, 0, 1, 1, {.Ro, .Access}}}},
	{"zlexcount", 4, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zmpop", -4, {.Write}, .Zmpop, 0, 0, 0, {{.Index, 1, "", 0, .Keynum, 0, 1, 1, {.Rw, .Access, .Delete}}}},
	{"zmscore", -3, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zpopmax", -2, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}}},
	{"zpopmin", -2, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Delete}}}},
	{"zrandmember", -2, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zrange", -4, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zrangebylex", -4, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zrangebyscore", -4, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zrangestore", -5, {.Write, .Denyoom}, .None, 1, 1, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}, {.Index, 2, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zrank", -3, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zrem", -3, {.Write, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Delete}}}},
	{"zremrangebylex", 4, {.Write}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Delete}}}},
	{"zremrangebyrank", 4, {.Write}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Delete}}}},
	{"zremrangebyscore", 4, {.Write}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Delete}}}},
	{"zrevrange", -4, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zrevrangebylex", -4, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zrevrangebyscore", -4, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zrevrank", -3, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zscan", -3, {.Readonly}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zscore", 3, {.Readonly, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ro, .Access}}}},
	{"zunion", -3, {.Readonly}, .Zunion_Inter_Diff, 0, 0, 0, {{.Index, 1, "", 0, .Keynum, 0, 1, 1, {.Ro, .Access}}}},
	{"zunionstore", -4, {.Write, .Denyoom}, .Zunion_Inter_Diff_Store, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Ow, .Update}}, {.Index, 2, "", 0, .Keynum, 0, 1, 1, {.Ro, .Access}}}},
}
