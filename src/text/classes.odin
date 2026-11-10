package text

Class :: enum u8 {
	Term,
	Upper,
	Separator,
	Dropped,
	Escape,
	End,
	Tag_Space,
	Query_Break,
}

Classes :: bit_set[Class;u8]

@(rodata)
BYTE_CLASSES := #partial [256]Classes {
	0x00 = {.End},
	0x01 = {.Dropped, .Query_Break},
	0x02 = {.Dropped, .Query_Break},
	0x03 = {.Dropped, .Query_Break},
	0x04 = {.Dropped, .Query_Break},
	0x05 = {.Dropped, .Query_Break},
	0x06 = {.Dropped, .Query_Break},
	0x07 = {.Dropped, .Query_Break},
	0x08 = {.Dropped, .Query_Break},
	0x09 = {.Separator, .Tag_Space, .Query_Break},
	0x0A = {.Dropped, .Tag_Space, .Query_Break},
	0x0B = {.Dropped, .Tag_Space, .Query_Break},
	0x0C = {.Dropped, .Tag_Space, .Query_Break},
	0x0D = {.Dropped, .Tag_Space, .Query_Break},
	0x0E = {.Dropped, .Query_Break},
	0x0F = {.Dropped, .Query_Break},
	0x10 = {.Dropped, .Query_Break},
	0x11 = {.Dropped, .Query_Break},
	0x12 = {.Dropped, .Query_Break},
	0x13 = {.Dropped, .Query_Break},
	0x14 = {.Dropped, .Query_Break},
	0x15 = {.Dropped, .Query_Break},
	0x16 = {.Dropped, .Query_Break},
	0x17 = {.Dropped, .Query_Break},
	0x18 = {.Dropped, .Query_Break},
	0x19 = {.Dropped, .Query_Break},
	0x1A = {.Dropped, .Query_Break},
	0x1B = {.Dropped, .Query_Break},
	0x1C = {.Dropped, .Query_Break},
	0x1D = {.Dropped, .Query_Break},
	0x1E = {.Dropped, .Query_Break},
	0x1F = {.Dropped, .Query_Break},
	' ' = {.Separator, .Tag_Space, .Query_Break},
	'!' = {.Separator, .Query_Break},
	'"' = {.Separator, .Query_Break},
	'#' = {.Separator, .Query_Break},
	'$' = {.Separator, .Query_Break},
	'%' = {.Separator, .Query_Break},
	'&' = {.Separator, .Query_Break},
	'\'' = {.Separator, .Query_Break},
	'(' = {.Separator, .Query_Break},
	')' = {.Separator, .Query_Break},
	'*' = {.Separator, .Query_Break},
	'+' = {.Separator, .Query_Break},
	',' = {.Separator, .Query_Break},
	'-' = {.Separator, .Query_Break},
	'.' = {.Separator, .Query_Break},
	'/' = {.Separator, .Query_Break},
	'0' = {.Term},
	'1' = {.Term},
	'2' = {.Term},
	'3' = {.Term},
	'4' = {.Term},
	'5' = {.Term},
	'6' = {.Term},
	'7' = {.Term},
	'8' = {.Term},
	'9' = {.Term},
	':' = {.Separator, .Query_Break},
	';' = {.Separator, .Query_Break},
	'<' = {.Separator, .Query_Break},
	'=' = {.Separator, .Query_Break},
	'>' = {.Separator, .Query_Break},
	'?' = {.Separator, .Query_Break},
	'@' = {.Separator, .Query_Break},
	'A' = {.Upper},
	'B' = {.Upper},
	'C' = {.Upper},
	'D' = {.Upper},
	'E' = {.Upper},
	'F' = {.Upper},
	'G' = {.Upper},
	'H' = {.Upper},
	'I' = {.Upper},
	'J' = {.Upper},
	'K' = {.Upper},
	'L' = {.Upper},
	'M' = {.Upper},
	'N' = {.Upper},
	'O' = {.Upper},
	'P' = {.Upper},
	'Q' = {.Upper},
	'R' = {.Upper},
	'S' = {.Upper},
	'T' = {.Upper},
	'U' = {.Upper},
	'V' = {.Upper},
	'W' = {.Upper},
	'X' = {.Upper},
	'Y' = {.Upper},
	'Z' = {.Upper},
	'[' = {.Separator, .Query_Break},
	'\\' = {.Escape, .Query_Break},
	']' = {.Separator, .Query_Break},
	'^' = {.Separator, .Query_Break},
	'_' = {.Term},
	'`' = {.Separator, .Query_Break},
	'a' = {.Term},
	'b' = {.Term},
	'c' = {.Term},
	'd' = {.Term},
	'e' = {.Term},
	'f' = {.Term},
	'g' = {.Term},
	'h' = {.Term},
	'i' = {.Term},
	'j' = {.Term},
	'k' = {.Term},
	'l' = {.Term},
	'm' = {.Term},
	'n' = {.Term},
	'o' = {.Term},
	'p' = {.Term},
	'q' = {.Term},
	'r' = {.Term},
	's' = {.Term},
	't' = {.Term},
	'u' = {.Term},
	'v' = {.Term},
	'w' = {.Term},
	'x' = {.Term},
	'y' = {.Term},
	'z' = {.Term},
	'{' = {.Separator, .Query_Break},
	'|' = {.Separator, .Query_Break},
	'}' = {.Separator, .Query_Break},
	'~' = {.Separator, .Query_Break},
	0x7F = {.Dropped, .Query_Break},
	0x80 ..= 0xFF = {.Term},
}

DOC_BREAK :: Classes{.Separator, .End}

DOC_SPECIAL :: Classes{.Separator, .End, .Dropped, .Escape}

byte_classes :: #force_inline proc "contextless" (b: u8) -> Classes {
	return BYTE_CLASSES[b]
}

is_doc_separator :: #force_inline proc "contextless" (b: u8) -> bool {
	return .Separator in BYTE_CLASSES[b]
}

is_doc_dropped :: #force_inline proc "contextless" (b: u8) -> bool {
	return .Dropped in BYTE_CLASSES[b]
}

is_tag_space :: #force_inline proc "contextless" (b: u8) -> bool {
	return .Tag_Space in BYTE_CLASSES[b]
}

is_query_break :: #force_inline proc "contextless" (b: u8) -> bool {
	return .Query_Break in BYTE_CLASSES[b]
}

is_control :: #force_inline proc "contextless" (b: u8) -> bool {
	return b < 0x20 || b == 0x7F
}
