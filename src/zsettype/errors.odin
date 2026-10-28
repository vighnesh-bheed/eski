package zsettype

WRONGTYPE_ERROR :: "WRONGTYPE Operation against a key holding the wrong kind of value"

Error :: enum u8 {
	None,
	Syntax,
	Not_Float,
	Not_Integer,
	Out_Of_Range,
	Xx_Nx,
	Gt_Lt_Nx,
	Incr_Pair,
	Nan_Result,
	Min_Max_Float,
	Min_Max_Lex,
	Limit_Rank,
	Withscores_Lex,
	Weight_Float,
	Limit_Negative,
	Must_Be_Positive,
	Numkeys,
	Count_Positive,
	Randmember_Range,
	At_Least_One_Key,
	Invalid_Cursor,
	Novalues,
	Wrong_Args,
}

ERROR_MESSAGES := [Error]string {
	.None             = "",
	.Syntax           = "syntax error",
	.Not_Float        = "value is not a valid float",
	.Not_Integer      = "value is not an integer or out of range",
	.Out_Of_Range     = "value is out of range",
	.Xx_Nx            = "XX and NX options at the same time are not compatible",
	.Gt_Lt_Nx         = "GT, LT, and/or NX options at the same time are not compatible",
	.Incr_Pair        = "INCR option supports a single increment-element pair",
	.Nan_Result       = "resulting score is not a number (NaN)",
	.Min_Max_Float    = "min or max is not a float",
	.Min_Max_Lex      = "min or max not valid string range item",
	.Limit_Rank       = "syntax error, LIMIT is only supported in combination with either BYSCORE or BYLEX",
	.Withscores_Lex   = "syntax error, WITHSCORES not supported in combination with BYLEX",
	.Weight_Float     = "weight value is not a float",
	.Limit_Negative   = "LIMIT can't be negative",
	.Must_Be_Positive = "value is out of range, must be positive",
	.Numkeys          = "numkeys should be greater than 0",
	.Count_Positive   = "count should be greater than 0",
	.Randmember_Range = "value is out of range, value must between -9223372036854775807 and 9223372036854775807",
	.At_Least_One_Key = "at least 1 input key is needed for '",
	.Invalid_Cursor   = "invalid cursor",
	.Novalues         = "NOVALUES option can only be used in HSCAN",
	.Wrong_Args       = "wrong number of arguments for '",
}

AT_LEAST_ONE_KEY_SUFFIX :: "' command"

WRONG_ARGS_SUFFIX :: "' command"

error_message :: proc "contextless" (e: Error) -> string {
	return ERROR_MESSAGES[e]
}
