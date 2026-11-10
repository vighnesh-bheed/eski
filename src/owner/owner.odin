package owner

import lb "../label"

Owner :: distinct u32

SHARED :: Owner(0)

EVERY :: Owner(max(u32))

FIRST_USER :: Owner(1)

LAST_USER :: Owner(max(u32) - 1)

TEXT_MAX :: 128

Scope :: struct {
	label: lb.Id,
	owner: Owner,
}

SHARED_BOTTOM :: Scope{lb.BOTTOM_ID, SHARED}

is_user :: #force_inline proc "contextless" (o: Owner) -> bool {
	return o != SHARED && o != EVERY
}

sees :: #force_inline proc "contextless" (reader, data: Owner) -> bool {
	return reader == data || data == SHARED || reader == EVERY
}

rank :: proc "contextless" (reader, a, b: Owner) -> int {
	if a == b || !is_user(reader) {
		return 0
	}
	if a == reader && b == SHARED {
		return 1
	}
	if b == reader && a == SHARED {
		return -1
	}
	return 0
}

text_valid :: proc "contextless" (text: []u8) -> bool {
	if len(text) == 0 || len(text) > TEXT_MAX {
		return false
	}
	for b in text {
		if b <= ' ' || b > '~' {
			return false
		}
	}
	return true
}
