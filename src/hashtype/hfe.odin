package hashtype

import rdb "../rdb"

FIELD_DEADLINE_MAX :: rdb.FIELD_DEADLINE_MAX

DEADLINE_UNSET :: max(u64)

FIELD_DEADLINE_COMMAND_MAX :: u64(1 << 46) - 1

SCHEDULE_SLACK_MS :: 4000

EXPIRE_NO_FIELD :: -2

EXPIRE_CONDITION_UNMET :: 0

EXPIRE_SET :: 1

EXPIRE_DELETED :: 2

TTL_NO_FIELD :: -2

TTL_NO_DEADLINE :: -1

PERSIST_NO_FIELD :: -2

PERSIST_NO_DEADLINE :: -1

PERSIST_REMOVED :: 1

Expire_Condition :: enum u8 {
	None,
	NX,
	XX,
	GT,
	LT,
}

Ttl_Kind :: enum u8 {
	Ttl,
	Pttl,
	Expire_Time,
	Pexpire_Time,
}

Hfe_Meta :: struct {
	reg:        ^Registry,
	reg_index:  int,
	reg_expire: u64,
	key:        rawptr,
}

Reg_Item :: struct {
	expire: u64,
	h:      Hash,
}

Registry :: struct {
	items:        [^]Reg_Item,
	len:          int,
	cap:          int,
	resize_head:  ^Resize_State,
	resize_tail:  ^Resize_State,
	resize_count: int,
	owner:        rawptr,
	expired_hook: Field_Expired_Hook,
	resize_epoch: u64,
}

Expired_Hash :: struct {
	h:       Hash,
	key:     rawptr,
	fields:  int,
	emptied: bool,
}

field_expired_hook: Field_Expired_Hook

Expire_Args :: struct {
	expire_at: u64,
	cond:      Expire_Condition,
	fields:    [][]u8,
}

notify_field_expired :: proc(h: Hash, field: []u8) {
	if h.hfe != nil && h.hfe.reg != nil && h.hfe.reg.expired_hook != nil {
		h.hfe.reg.expired_hook(h, field)
	} else if field_expired_hook != nil {
		field_expired_hook(h, field)
	}
}
