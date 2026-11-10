package label

import "core:math/bits"

LEVEL_LIMIT :: 256

COMPARTMENT_LIMIT :: 256

COMPARTMENT_WORDS :: COMPARTMENT_LIMIT / 64

NAME_MAX :: 64

MARKING_MAX :: 32_768

LABEL_LIMIT :: 65_535

Id :: distinct u16

ID_NONE :: Id(0xFFFF)

BOTTOM_ID :: Id(0)

Compartments :: [COMPARTMENT_WORDS]u64

Label :: struct {
	compartments: Compartments,
	level:        u8,
}

BOTTOM :: Label{}

Error :: enum u8 {
	None,
	Out_Of_Memory,
	Invalid_Label,
	Table_Full,
	Overflow,
	Underflow,
}

dominates :: #force_inline proc "contextless" (a, b: Label) -> bool {
	return dominance_bit(a, b) != 0
}

dominance_bit :: #force_inline proc "contextless" (a, b: Label) -> u64 {
	missing := u64(0)
	for w in 0 ..< COMPARTMENT_WORDS {
		missing |= b.compartments[w] &~ a.compartments[w]
	}
	return u64(a.level >= b.level) & u64(missing == 0)
}

join :: proc "contextless" (a, b: Label) -> (r: Label) {
	r.level = max(a.level, b.level)
	for w in 0 ..< COMPARTMENT_WORDS {
		r.compartments[w] = a.compartments[w] | b.compartments[w]
	}
	return r
}

meet :: proc "contextless" (a, b: Label) -> (r: Label) {
	r.level = min(a.level, b.level)
	for w in 0 ..< COMPARTMENT_WORDS {
		r.compartments[w] = a.compartments[w] & b.compartments[w]
	}
	return r
}

compartment_has :: #force_inline proc "contextless" (l: Label, c: int) -> bool {
	if c < 0 || c >= COMPARTMENT_LIMIT {
		return false
	}
	return l.compartments[c >> 6] >> uint(c & 63) & 1 != 0
}

compartment_add :: proc "contextless" (l: ^Label, c: int) -> bool {
	if c < 0 || c >= COMPARTMENT_LIMIT {
		return false
	}
	l.compartments[c >> 6] |= u64(1) << uint(c & 63)
	return true
}

compartment_remove :: proc "contextless" (l: ^Label, c: int) -> bool {
	if c < 0 || c >= COMPARTMENT_LIMIT {
		return false
	}
	l.compartments[c >> 6] &~= u64(1) << uint(c & 63)
	return true
}

compartment_count :: proc "contextless" (l: Label) -> (n: int) {
	for w in l.compartments {
		n += int(bits.count_ones(w))
	}
	return n
}

compartment_next :: proc "contextless" (l: Label, from: int) -> int {
	c := max(from, 0)
	for c < COMPARTMENT_LIMIT {
		w := l.compartments[c >> 6] >> uint(c & 63)
		if w != 0 {
			return c + int(bits.trailing_zeros(w))
		}
		c = (c | 63) + 1
	}
	return COMPARTMENT_LIMIT
}

compartment_highest :: proc "contextless" (l: Label) -> int {
	for w := COMPARTMENT_WORDS - 1; w >= 0; w -= 1 {
		if l.compartments[w] != 0 {
			return w * 64 + 63 - int(bits.leading_zeros(l.compartments[w]))
		}
	}
	return -1
}

label_make :: proc "contextless" (level: int, compartments: ..int) -> (l: Label, ok: bool) {
	if level < 0 || level >= LEVEL_LIMIT {
		return {}, false
	}
	l.level = u8(level)
	for c in compartments {
		if !compartment_add(&l, c) {
			return {}, false
		}
	}
	return l, true
}
