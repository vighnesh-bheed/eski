package bitmap

ERR_BIT_VALUE :: "bit is not an integer or out of range"
ERR_BIT_OFFSET :: "bit offset is not an integer or out of range"
ERR_NOT_INTEGER :: "value is not an integer or out of range"
ERR_BIT_ARGUMENT :: "The bit argument must be 1 or 0."
ERR_BITOP_NOT :: "BITOP NOT must be called with a single source key."
ERR_BITFIELD_TYPE :: "Invalid bitfield type. Use something like i16 u8. Note that u64 is not supported but i64 is."
ERR_OVERFLOW_TYPE :: "Invalid OVERFLOW type specified"
ERR_SYNTAX :: "syntax error"
ERR_BITFIELD_RO :: "BITFIELD_RO only supports the GET subcommand"
ERR_OUT_OF_MEMORY :: "out of memory"

Error :: enum u8 {
	None,
	Bit_Value,
	Bit_Offset,
	Not_Integer,
	Bit_Argument,
	Bitop_Not_Arity,
	Bitfield_Type,
	Overflow_Type,
	Syntax,
	Bitfield_Read_Only,
	Out_Of_Memory,
}

ERROR_MESSAGES := [Error]string {
	.None               = "",
	.Bit_Value          = ERR_BIT_VALUE,
	.Bit_Offset         = ERR_BIT_OFFSET,
	.Not_Integer        = ERR_NOT_INTEGER,
	.Bit_Argument       = ERR_BIT_ARGUMENT,
	.Bitop_Not_Arity    = ERR_BITOP_NOT,
	.Bitfield_Type      = ERR_BITFIELD_TYPE,
	.Overflow_Type      = ERR_OVERFLOW_TYPE,
	.Syntax             = ERR_SYNTAX,
	.Bitfield_Read_Only = ERR_BITFIELD_RO,
	.Out_Of_Memory      = ERR_OUT_OF_MEMORY,
}

error_message :: proc "contextless" (e: Error) -> string {
	if e > max(Error) {
		return ""
	}
	return ERROR_MESSAGES[e]
}
