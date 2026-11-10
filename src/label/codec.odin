package label

CODEC_MAGIC :: "ESLT"

CODEC_VERSION :: u8(2)

CODEC_VERSION_UNTRUSTED :: u8(1)

Codec_Error :: enum u8 {
	None,
	Truncated,
	Bad_Magic,
	Bad_Version,
	Bad_Level_Count,
	Bad_Compartment_Count,
	Bad_Trust_Count,
	Bad_Name,
	Duplicate_Name,
	Bad_Label_Count,
	Bad_Level,
	Bad_Compartment,
	Bad_Trust,
	Not_Bottom,
	Duplicate_Label,
	Trailing,
	Invalid_Label,
	Out_Of_Memory,
}

Reader :: struct {
	data: []u8,
	at:   int,
}

read_u8 :: proc "contextless" (r: ^Reader) -> (u8, bool) {
	if r.at >= len(r.data) {
		return 0, false
	}
	r.at += 1
	return r.data[r.at - 1], true
}

read_u16 :: proc "contextless" (r: ^Reader) -> (int, bool) {
	if len(r.data) - r.at < 2 {
		return 0, false
	}
	r.at += 2
	return int(r.data[r.at - 2]) | int(r.data[r.at - 1]) << 8, true
}

read_bytes :: proc "contextless" (r: ^Reader, n: int) -> ([]u8, bool) {
	if len(r.data) - r.at < n {
		return nil, false
	}
	r.at += n
	return r.data[r.at - n:r.at], true
}

encoded_size :: proc "contextless" (c: ^Config, t: ^Table) -> int {
	n := len(CODEC_MAGIC) + 1 + 2 + len(c.levels) + 2 + len(c.compartments) + 2 + len(c.trusts) + len(c.text) + 2
	for l in t.labels {
		n += 4 + compartment_count(l)
	}
	return n
}

put_u8 :: #force_inline proc(out: ^[dynamic]u8, v: u8) -> bool {
	_, err := append(out, v)
	return err == nil
}

put_u16 :: #force_inline proc(out: ^[dynamic]u8, v: int) -> bool {
	_, err := append(out, u8(v & 0xFF), u8(v >> 8))
	return err == nil
}

put_names :: proc(out: ^[dynamic]u8, c: ^Config, names: []Name) -> bool {
	if !put_u16(out, len(names)) {
		return false
	}
	for n in names {
		if !put_u8(out, u8(n.length)) {
			return false
		}
		if _, err := append(out, config_name(c, n)); err != nil {
			return false
		}
	}
	return true
}

put_label :: proc(out: ^[dynamic]u8, l: Label) -> bool {
	if !put_u8(out, l.level) || !put_u8(out, l.trust) || !put_u16(out, compartment_count(l)) {
		return false
	}
	for i := compartment_next(l, 0); i < COMPARTMENT_LIMIT; i = compartment_next(l, i + 1) {
		if !put_u8(out, u8(i)) {
			return false
		}
	}
	return true
}

put_all :: proc(out: ^[dynamic]u8, c: ^Config, t: ^Table) -> bool {
	if _, err := append(out, CODEC_MAGIC); err != nil {
		return false
	}
	if !put_u8(out, CODEC_VERSION) || !put_names(out, c, c.levels[:]) || !put_names(out, c, c.compartments[:]) || !put_names(out, c, c.trusts[:]) || !put_u16(out, len(t.labels)) {
		return false
	}
	for l in t.labels {
		if !put_label(out, l) {
			return false
		}
	}
	return true
}

encode :: proc(c: ^Config, t: ^Table, out: ^[dynamic]u8) -> Codec_Error {
	if len(t.labels) == 0 || t.labels[0] != BOTTOM {
		return .Invalid_Label
	}
	for l in t.labels {
		if !config_valid(c, l) {
			return .Invalid_Label
		}
	}
	start := len(out)
	if err := reserve(out, start + encoded_size(c, t)); err != nil {
		return .Out_Of_Memory
	}
	if !put_all(out, c, t) {
		resize(out, start)
		return .Out_Of_Memory
	}
	return .None
}

read_name :: proc(r: ^Reader, c: ^Config, names: ^[dynamic]Name, own_namespace := false) -> Codec_Error {
	length, ok := read_u8(r)
	if !ok {
		return .Truncated
	}
	bytes, present := read_bytes(r, int(length))
	if !present {
		return .Truncated
	}
	if !name_canonical(string(bytes)) {
		return .Bad_Name
	}
	if own_namespace {
		if _, used := names_find(c, names[:], string(bytes)); used {
			return .Duplicate_Name
		}
	} else if config_name_used(c, string(bytes)) {
		return .Duplicate_Name
	}
	if name_store(c, names, bytes) != .None {
		return .Out_Of_Memory
	}
	return .None
}

decode_into :: proc(data: []u8, c: ^Config, t: ^Table) -> Codec_Error {
	r := Reader{data = data}
	magic, ok := read_bytes(&r, len(CODEC_MAGIC))
	if !ok {
		return .Truncated
	}
	if string(magic) != CODEC_MAGIC {
		return .Bad_Magic
	}
	version, has_version := read_u8(&r)
	if !has_version {
		return .Truncated
	}
	if version != CODEC_VERSION && version != CODEC_VERSION_UNTRUSTED {
		return .Bad_Version
	}
	levels, has_levels := read_u16(&r)
	if !has_levels {
		return .Truncated
	}
	if levels == 0 || levels > LEVEL_LIMIT {
		return .Bad_Level_Count
	}
	for _ in 0 ..< levels {
		if e := read_name(&r, c, &c.levels); e != .None {
			return e
		}
	}
	compartments, has_compartments := read_u16(&r)
	if !has_compartments {
		return .Truncated
	}
	if compartments > COMPARTMENT_LIMIT {
		return .Bad_Compartment_Count
	}
	for _ in 0 ..< compartments {
		if e := read_name(&r, c, &c.compartments); e != .None {
			return e
		}
	}
	trusts := 0
	if version == CODEC_VERSION {
		has_trusts: bool
		trusts, has_trusts = read_u16(&r)
		if !has_trusts {
			return .Truncated
		}
		if trusts > TRUST_LIMIT {
			return .Bad_Trust_Count
		}
		for _ in 0 ..< trusts {
			if e := read_name(&r, c, &c.trusts, true); e != .None {
				return e
			}
		}
	}
	count, has_count := read_u16(&r)
	if !has_count {
		return .Truncated
	}
	if count == 0 {
		return .Bad_Label_Count
	}
	for i in 0 ..< count {
		level, has_level := read_u8(&r)
		if !has_level {
			return .Truncated
		}
		if int(level) >= levels {
			return .Bad_Level
		}
		trust := u8(0)
		if version == CODEC_VERSION {
			has_trust: bool
			trust, has_trust = read_u8(&r)
			if !has_trust {
				return .Truncated
			}
			if int(trust) >= max(1, trusts) {
				return .Bad_Trust
			}
		}
		n, has_n := read_u16(&r)
		if !has_n {
			return .Truncated
		}
		if n > compartments {
			return .Bad_Compartment
		}
		ids, has_ids := read_bytes(&r, n)
		if !has_ids {
			return .Truncated
		}
		l := Label{level = level, trust = trust}
		previous := -1
		for id in ids {
			if int(id) >= compartments || int(id) <= previous {
				return .Bad_Compartment
			}
			compartment_add(&l, int(id))
			previous = int(id)
		}
		if i == 0 {
			if l != BOTTOM {
				return .Not_Bottom
			}
			continue
		}
		if _, found := table_find(t, l); found {
			return .Duplicate_Label
		}
		if _, e := table_intern(t, l); e != .None {
			return .Out_Of_Memory
		}
	}
	if r.at != len(data) {
		return .Trailing
	}
	return .None
}

decode :: proc(data: []u8, c: ^Config, t: ^Table, allocator := context.allocator) -> Codec_Error {
	config_init(c, allocator)
	if table_init(t, allocator) != .None {
		config_destroy(c)
		return .Out_Of_Memory
	}
	e := decode_into(data, c, t)
	if e != .None {
		config_destroy(c)
		table_destroy(t)
	}
	return e
}
