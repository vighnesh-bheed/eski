package hashtype

EB_EXPIRE_TIME_MAX :: u64(0x0000FFFFFFFFFFFF)

EB_EXPIRE_TIME_INVALID :: EB_EXPIRE_TIME_MAX + 1

HFE_MAX_ABS_TIME_MSEC :: EB_EXPIRE_TIME_MAX >> 2

HASH_LP_NO_TTL :: 0

HASH_NEW_EXPIRE_DIFF_THRESHOLD :: 4000

HFE_DB_BASE_ACTIVE_EXPIRE_FIELDS_PER_SEC :: 10000

HSETEX_NO_FIELD :: -2

HSETEX_NO_CONDITION_MET :: 0

HSETEX_OK :: 1

HSETEX_DELETED :: 2

HFE_GET_NO_FIELD :: -2

HFE_GET_NO_TTL :: -1

HFE_PERSIST_NO_FIELD :: -2

HFE_PERSIST_NO_TTL :: -1

HFE_PERSIST_OK :: 1

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
