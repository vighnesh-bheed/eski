package label

DEFAULT_LEVEL :: "UNCLASSIFIED"

Config_Error :: enum u8 {
	None,
	Empty_Name,
	Name_Too_Long,
	Invalid_Name,
	Duplicate_Name,
	Too_Many_Levels,
	Too_Many_Compartments,
	Out_Of_Memory,
}

Name :: struct {
	offset: u32,
	length: u32,
}

Config :: struct {
	text:         [dynamic]u8,
	levels:       [dynamic]Name,
	compartments: [dynamic]Name,
}

Normal :: struct {
	bytes:  [NAME_MAX]u8,
	length: int,
}

config_init :: proc(c: ^Config, allocator := context.allocator) {
	c.text = make([dynamic]u8, 0, 0, allocator)
	c.levels = make([dynamic]Name, 0, 0, allocator)
	c.compartments = make([dynamic]Name, 0, 0, allocator)
}

config_destroy :: proc(c: ^Config) {
	delete(c.text)
	delete(c.levels)
	delete(c.compartments)
	c^ = Config{}
}

config_default :: proc(c: ^Config, allocator := context.allocator) -> Config_Error {
	config_init(c, allocator)
	return config_add_level(c, DEFAULT_LEVEL)
}

is_space :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == ' ' || b == '\t'
}

fold_upper :: #force_inline proc "contextless" (b: u8) -> u8 {
	return b - 32 if b >= 'a' && b <= 'z' else b
}

name_byte :: #force_inline proc "contextless" (b: u8) -> bool {
	return b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '-' || b == '_' || b == ' '
}

normalise :: proc "contextless" (raw: string, out: ^Normal) -> bool {
	n := 0
	pending := false
	for i in 0 ..< len(raw) {
		b := raw[i]
		if is_space(b) {
			pending = pending || n > 0
			continue
		}
		if pending {
			if n == NAME_MAX {
				out.length = n
				return false
			}
			out.bytes[n] = ' '
			n += 1
			pending = false
		}
		if n == NAME_MAX {
			out.length = n
			return false
		}
		out.bytes[n] = fold_upper(b)
		n += 1
	}
	out.length = n
	return true
}

normal_text :: #force_inline proc "contextless" (out: ^Normal) -> string {
	return string(out.bytes[:out.length])
}

name_canonical :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || len(name) > NAME_MAX {
		return false
	}
	for i in 0 ..< len(name) {
		b := name[i]
		if !name_byte(b) {
			return false
		}
		start := i == 0 || name[i - 1] == ' '
		if b == ' ' && (start || i == len(name) - 1) {
			return false
		}
		if (b == '-' || b == '_') && start {
			return false
		}
	}
	return true
}

config_name :: #force_inline proc "contextless" (c: ^Config, n: Name) -> string {
	return string(c.text[n.offset:][:n.length])
}

config_level_count :: #force_inline proc "contextless" (c: ^Config) -> int {
	return len(c.levels)
}

config_compartment_count :: #force_inline proc "contextless" (c: ^Config) -> int {
	return len(c.compartments)
}

config_level_name :: proc "contextless" (c: ^Config, level: int) -> string {
	if level < 0 || level >= len(c.levels) {
		return ""
	}
	return config_name(c, c.levels[level])
}

config_compartment_name :: proc "contextless" (c: ^Config, compartment: int) -> string {
	if compartment < 0 || compartment >= len(c.compartments) {
		return ""
	}
	return config_name(c, c.compartments[compartment])
}

names_find :: proc "contextless" (c: ^Config, names: []Name, canonical: string) -> (int, bool) {
	for n, i in names {
		if int(n.length) == len(canonical) && config_name(c, n) == canonical {
			return i, true
		}
	}
	return -1, false
}

config_find_level :: proc "contextless" (c: ^Config, raw: string) -> (int, bool) {
	normal: Normal
	if !normalise(raw, &normal) {
		return -1, false
	}
	return names_find(c, c.levels[:], normal_text(&normal))
}

config_find_compartment :: proc "contextless" (c: ^Config, raw: string) -> (int, bool) {
	normal: Normal
	if !normalise(raw, &normal) {
		return -1, false
	}
	return names_find(c, c.compartments[:], normal_text(&normal))
}

config_name_used :: proc "contextless" (c: ^Config, canonical: string) -> bool {
	_, level := names_find(c, c.levels[:], canonical)
	_, compartment := names_find(c, c.compartments[:], canonical)
	return level || compartment
}

name_check :: proc "contextless" (c: ^Config, raw: string, normal: ^Normal) -> Config_Error {
	if !normalise(raw, normal) {
		return .Name_Too_Long
	}
	if normal.length == 0 {
		return .Empty_Name
	}
	if !name_canonical(normal_text(normal)) {
		return .Invalid_Name
	}
	if config_name_used(c, normal_text(normal)) {
		return .Duplicate_Name
	}
	return .None
}

name_store :: proc(c: ^Config, names: ^[dynamic]Name, canonical: []u8) -> Config_Error {
	offset := len(c.text)
	if _, err := append(&c.text, ..canonical); err != nil {
		resize(&c.text, offset)
		return .Out_Of_Memory
	}
	if _, err := append(names, Name{u32(offset), u32(len(canonical))}); err != nil {
		resize(&c.text, offset)
		return .Out_Of_Memory
	}
	return .None
}

config_add_level :: proc(c: ^Config, raw: string) -> Config_Error {
	if len(c.levels) >= LEVEL_LIMIT {
		return .Too_Many_Levels
	}
	normal: Normal
	if e := name_check(c, raw, &normal); e != .None {
		return e
	}
	return name_store(c, &c.levels, normal.bytes[:normal.length])
}

config_add_compartment :: proc(c: ^Config, raw: string) -> Config_Error {
	if len(c.compartments) >= COMPARTMENT_LIMIT {
		return .Too_Many_Compartments
	}
	normal: Normal
	if e := name_check(c, raw, &normal); e != .None {
		return e
	}
	return name_store(c, &c.compartments, normal.bytes[:normal.length])
}

config_valid :: proc "contextless" (c: ^Config, l: Label) -> bool {
	if int(l.level) >= len(c.levels) {
		return false
	}
	return compartment_highest(l) < len(c.compartments)
}

config_top :: proc "contextless" (c: ^Config) -> (l: Label, ok: bool) {
	if len(c.levels) == 0 {
		return {}, false
	}
	l.level = u8(len(c.levels) - 1)
	for i in 0 ..< len(c.compartments) {
		compartment_add(&l, i)
	}
	return l, true
}
