package request_parser

Inline_Scan :: struct {
	argc:           int,
	decoded_length: int,
	kind:           Kind,
	fault:          Fault,
	needs_owner:    bool,
	capacity_miss:  bool,
}

inline_leading_space :: #force_inline proc "contextless" (byte: u8) -> bool {
	return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' || byte == 11 || byte == 12
}

inline_word_space :: #force_inline proc "contextless" (byte: u8) -> bool {
	return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n'
}

inline_hex :: #force_inline proc "contextless" (byte: u8) -> (u8, bool) {
	if byte >= '0' && byte <= '9' {
		return byte - '0', true
	}
	if byte >= 'a' && byte <= 'f' {
		return byte - 'a' + 10, true
	}
	if byte >= 'A' && byte <= 'F' {
		return byte - 'A' + 10, true
	}
	return 0, false
}

inline_byte :: #force_inline proc "contextless" (output: []u8, written: ^int, byte: u8, $write: bool) {
	when write {
		#no_bounds_check {
			output[written^] = byte
		}
	}
	written^ += 1
}

inline_tokens :: #force_no_inline proc "contextless" (line: []u8, scratch: ^Scratch, output: []u8, $emit, $decode: bool, $framed: bool, frame_end: ^int = nil) -> Inline_Scan {
	cursor := 0
	written := 0
	count := 0
	needs_owner := false
	for cursor < len(line) {
		for cursor < len(line) {
			byte := line[cursor]
			when framed {
				if byte == 0 {
					return {kind = .Incomplete}
				}
				if byte == '\n' {
					frame_end^ = cursor + 1
					return {kind = .Command, argc = count, decoded_length = written, needs_owner = needs_owner}
				}
			}
			if !inline_leading_space(byte) {
				break
			}
			cursor += 1
		}
		if cursor == len(line) {
			break
		}
		start := cursor
		decoded_start := written
		_ = start
		_ = decoded_start
		quote := u8(0)
		finished := false
		for cursor < len(line) && !finished {
			byte := line[cursor]
			when framed {
				if byte == 0 || (byte == '\n' && quote != 0) {
					return {kind = .Incomplete}
				}
			}
			if quote == 0 {
				if inline_word_space(byte) {
					break
				}
				if byte == '"' || byte == '\'' {
					quote = byte
					needs_owner = true
					cursor += 1
				} else {
					inline_byte(output, &written, byte, emit && decode)
					cursor += 1
				}
			} else if byte == quote {
				cursor += 1
				if cursor < len(line) && !inline_leading_space(line[cursor]) {
					when framed {
						return {kind = .Incomplete}
					} else {
						return {kind = .Error, fault = .Unbalanced_Quotes}
					}
				}
				quote = 0
				finished = true
			} else if quote == '"' && byte == '\\' {
				if cursor + 1 == len(line) {
					return {kind = .Error, fault = .Unbalanced_Quotes}
				}
				next := line[cursor + 1]
				when framed {
					if next == 0 || next == '\n' {
						return {kind = .Incomplete}
					}
				}
				if next == 'x' && len(line) - cursor >= 4 {
					when framed {
						if line[cursor + 2] == 0 || line[cursor + 2] == '\n' || line[cursor + 3] == 0 || line[cursor + 3] == '\n' {
							return {kind = .Incomplete}
						}
					}
					high, high_valid := inline_hex(line[cursor + 2])
					low, low_valid := inline_hex(line[cursor + 3])
					if high_valid && low_valid {
						inline_byte(output, &written, high * 16 + low, emit && decode)
						cursor += 4
						continue
					}
				}
				switch next {
				case 'a':
					next = 7
				case 'b':
					next = 8
				case 't':
					next = '\t'
				case 'n':
					next = '\n'
				case 'r':
					next = '\r'
				}
				inline_byte(output, &written, next, emit && decode)
				cursor += 2
			} else if quote == '\'' && byte == '\\' && len(line) - cursor >= 2 && line[cursor + 1] == '\'' {
				inline_byte(output, &written, u8('\''), emit && decode)
				cursor += 2
			} else {
				inline_byte(output, &written, byte, emit && decode)
				cursor += 1
			}
		}
		if quote != 0 {
			return {kind = .Error, fault = .Unbalanced_Quotes}
		}
		when emit {
			if count >= len(scratch.args) {
				return {kind = .Incomplete, capacity_miss = true}
			}
			when decode {
				scratch.args[count] = output[decoded_start:written]
			} else {
				scratch.args[count] = line[start:cursor]
			}
		}
		count += 1
	}
	when framed {
		return {kind = .Incomplete}
	} else {
		return {kind = .Command, argc = count, decoded_length = written, needs_owner = needs_owner}
	}
}

inline_plain_tokens :: #force_inline proc(line: []u8, scratch: ^Scratch) -> (int, bool) {
	cursor := 0
	count := 0
	for cursor < len(line) {
		for cursor < len(line) && inline_leading_space(line[cursor]) {
			cursor += 1
		}
		if cursor == len(line) {
			break
		}
		start := cursor
		for cursor < len(line) && !inline_word_space(line[cursor]) {
			cursor += 1
		}
		if !ensure_args(scratch, count + 1) {
			return 0, false
		}
		scratch.args[count] = line[start:cursor]
		count += 1
	}
	return count, true
}

parse_inline_slow :: #force_no_inline proc(input: []u8, scratch: ^Scratch, owner: ^^Inline_Owner, limits: Limits) -> Result {
	line_end := -1
	has_quote := false
	for byte, index in input {
		if byte == 0 {
			break
		}
		if byte == '\n' {
			line_end = index
			break
		}
		has_quote = has_quote || byte == '"' || byte == '\''
	}
	if line_end < 0 {
		if len(input) > UNBOUNDED_MAX {
			return {kind = .Error, fault = .Inline_Too_Large}
		}
		return {kind = .Incomplete, need = len(input) + 1}
	}
	line_length := line_end
	if line_length > 0 && input[line_length - 1] == '\r' {
		line_length -= 1
	}
	line := input[:line_length]
	if !has_quote {
		count, stored := inline_plain_tokens(line, scratch)
		if !stored {
			return {kind = .Error, fault = .Inline_Too_Large}
		}
		return {kind = .Command, consumed = line_end + 1, argc = count}
	}
	if owner^ != nil && len(owner^.storage) >= len(line) {
		decoded := inline_tokens(line, scratch, owner^.storage, true, true, false)
		if !decoded.capacity_miss {
			return {kind = decoded.kind, consumed = line_end + 1 if decoded.kind == .Command else 0, argc = decoded.argc, fault = decoded.fault}
		}
	}
	validated := inline_tokens(line, nil, nil, false, false, false)
	if validated.kind != .Command {
		return {kind = validated.kind, fault = validated.fault}
	}
	if !ensure_args(scratch, validated.argc) {
		return {kind = .Error, fault = .Inline_Too_Large}
	}
	if validated.needs_owner {
		if !inline_reserve(owner, len(line), max(int) - size_of(Inline_Owner)) {
			return {kind = .Error, fault = .Inline_Too_Large}
		}
		inline_tokens(line, scratch, owner^.storage, true, true, false)
	} else {
		inline_tokens(line, scratch, nil, true, false, false)
	}
	return {kind = .Command, consumed = line_end + 1, argc = validated.argc}
}

parse_inline_quoted :: #force_no_inline proc(input: []u8, scratch: ^Scratch, owner: ^^Inline_Owner) -> Result {
	if owner^ != nil && len(owner^.storage) >= len(input) {
		consumed := 0
		decoded := inline_tokens(input, scratch, owner^.storage, true, true, true, &consumed)
		if decoded.kind == .Command {
			return {kind = .Command, consumed = consumed, argc = decoded.argc}
		}
	}
	return parse_inline_slow(input, scratch, owner, {})
}

parse_inline :: #force_inline proc(input: []u8, scratch: ^Scratch, owner: ^^Inline_Owner, limits: Limits) -> Result {
	cursor := 0
	count := 0
	for cursor < len(input) {
		for cursor < len(input) {
			byte := input[cursor]
			if byte == '\n' {
				return {kind = .Command, consumed = cursor + 1, argc = count}
			}
			if !inline_leading_space(byte) {
				break
			}
			cursor += 1
		}
		if cursor == len(input) {
			break
		}
		start := cursor
		for cursor < len(input) {
			byte := input[cursor]
			if byte == 0 {
				return parse_inline_slow(input, scratch, owner, limits)
			}
			if byte == '"' || byte == '\'' {
				return parse_inline_quoted(input, scratch, owner)
			}
			if inline_word_space(byte) {
				break
			}
			cursor += 1
		}
		if cursor == len(input) || count >= len(scratch.args) {
			return parse_inline_slow(input, scratch, owner, limits)
		}
		#no_bounds_check {
			scratch.args[count] = input[start:cursor]
		}
		count += 1
	}
	return parse_inline_slow(input, scratch, owner, limits)
}
