package hashtype

ERR_HASH_VALUE_NOT_INTEGER :: "hash value is not an integer"

ERR_INCR_OVERFLOW :: "increment or decrement would overflow"

ERR_HASH_VALUE_NOT_FLOAT :: "hash value is not a float"

ERR_INCR_NAN_OR_INFINITY :: "increment would produce NaN or Infinity"

ERR_VALUE_NOT_INTEGER :: "value is not an integer or out of range"

ERR_VALUE_NOT_FLOAT :: "value is not a valid float"

ERR_VALUE_NAN_OR_INFINITY :: "value is NaN or Infinity"

ERR_VALUE_OUT_OF_RANGE :: "value is out of range"

ERR_HRANDFIELD_COUNT_RANGE :: "value is out of range, value must between -9223372036854775807 and 9223372036854775807"

ERR_SYNTAX :: "syntax error"

ERR_INVALID_CURSOR :: "invalid cursor"

ERR_NOVALUES_ONLY_HSCAN :: "NOVALUES option can only be used in HSCAN"

ERR_OUT_OF_MEMORY :: "out of memory"

ERR_INVALID_EXPIRE_NEGATIVE :: "invalid expire time, must be >= 0"

ERR_INVALID_EXPIRE_TIME_FMT :: "invalid expire time in '%s' command"

ERR_FIELDS_MISSING :: "Mandatory argument FIELDS is missing or not at the right position"

ERR_NUMFIELDS_EXPIRE :: "Parameter `numFields` should be greater than 0"

ERR_NUMFIELDS_POSITIVE :: "Number of fields must be a positive integer"

ERR_NUMFIELDS_MISMATCH :: "The `numfields` parameter must match the number of arguments"

WRONGTYPE_ERROR :: "WRONGTYPE Operation against a key holding the wrong kind of value"

Error :: enum u8 {
	None,
	Hash_Value_Not_Integer,
	Increment_Overflow,
	Hash_Value_Not_Float,
	Increment_Nan_Or_Infinity,
	Value_Not_Integer,
	Value_Not_Float,
	Value_Nan_Or_Infinity,
	Value_Out_Of_Range,
	Hrandfield_Count_Range,
	Syntax,
	Invalid_Cursor,
	Novalues_Only_Hscan,
	Out_Of_Memory,
	Invalid_Expire_Negative,
	Invalid_Expire_Time,
	Fields_Missing,
	Numfields_Expire,
	Numfields_Positive,
	Numfields_Mismatch,
}

ERROR_MESSAGES := [Error]string {
	.None                      = "",
	.Hash_Value_Not_Integer    = ERR_HASH_VALUE_NOT_INTEGER,
	.Increment_Overflow        = ERR_INCR_OVERFLOW,
	.Hash_Value_Not_Float      = ERR_HASH_VALUE_NOT_FLOAT,
	.Increment_Nan_Or_Infinity = ERR_INCR_NAN_OR_INFINITY,
	.Value_Not_Integer         = ERR_VALUE_NOT_INTEGER,
	.Value_Not_Float           = ERR_VALUE_NOT_FLOAT,
	.Value_Nan_Or_Infinity     = ERR_VALUE_NAN_OR_INFINITY,
	.Value_Out_Of_Range        = ERR_VALUE_OUT_OF_RANGE,
	.Hrandfield_Count_Range    = ERR_HRANDFIELD_COUNT_RANGE,
	.Syntax                    = ERR_SYNTAX,
	.Invalid_Cursor            = ERR_INVALID_CURSOR,
	.Novalues_Only_Hscan       = ERR_NOVALUES_ONLY_HSCAN,
	.Out_Of_Memory             = ERR_OUT_OF_MEMORY,
	.Invalid_Expire_Negative   = ERR_INVALID_EXPIRE_NEGATIVE,
	.Invalid_Expire_Time       = ERR_INVALID_EXPIRE_TIME_FMT,
	.Fields_Missing            = ERR_FIELDS_MISSING,
	.Numfields_Expire          = ERR_NUMFIELDS_EXPIRE,
	.Numfields_Positive        = ERR_NUMFIELDS_POSITIVE,
	.Numfields_Mismatch        = ERR_NUMFIELDS_MISMATCH,
}

ERR_INVALID_EXPIRE_TIME_PREFIX :: "invalid expire time in '"

ERR_INVALID_EXPIRE_TIME_SUFFIX :: "' command"

error_message :: proc "contextless" (e: Error) -> string {
	return ERROR_MESSAGES[e]
}
