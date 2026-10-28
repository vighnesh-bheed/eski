package request_parser

Inline_Owner :: struct {
	storage: []u8,
}

inline_charge :: #force_inline proc "contextless" (owner: ^Inline_Owner) -> int {
	if owner == nil {
		return 0
	}
	return size_of(Inline_Owner) + len(owner.storage)
}

inline_reserve :: proc(slot: ^^Inline_Owner, wanted, limit: int) -> bool {
	if wanted < 0 || limit < 0 || wanted > limit || limit > max(int) - size_of(Inline_Owner) {
		return false
	}
	if wanted == 0 {
		return true
	}
	owner := slot^
	if owner != nil && wanted <= len(owner.storage) {
		return true
	}
	capacity := min(limit, max(64, wanted))
	if owner != nil && len(owner.storage) <= max(int) / 2 {
		capacity = min(limit, max(capacity, len(owner.storage) * 2))
	}
	replacement := make([]u8, capacity)
	if owner == nil {
		owner = new(Inline_Owner)
		slot^ = owner
	} else {
		copy(replacement, owner.storage)
		delete(owner.storage)
	}
	owner.storage = replacement
	return true
}

inline_release :: proc(slot: ^^Inline_Owner) -> int {
	owner := slot^
	if owner == nil {
		return 0
	}
	charge := inline_charge(owner)
	delete(owner.storage)
	free(owner)
	slot^ = nil
	return charge
}
