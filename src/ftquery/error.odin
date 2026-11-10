package ftquery

import "core:fmt"
import "core:strings"

Error_Code :: enum u8 {
	None,
	Syntax,
	Param_Not_Found,
	Numeric_Value_Invalid,
	Option_Invalid,
	Value_Bad,
	Param_Dup,
	Hybrid_Attr_Non_Hybrid,
	Hybrid_Policy_Bad,
	Adhoc_Batch_Size_Irrelevant,
	Range_Attr_Non_Range,
	Index_Exists,
	Field_Dup,
	Query_Bad,
	Parse_Args,
	Out_Of_Memory,
}

ERROR_WORDS := [Error_Code]string {
	.None                   = "",
	.Syntax                 = "SEARCH_SYNTAX",
	.Param_Not_Found        = "SEARCH_PARAM_NOT_FOUND",
	.Numeric_Value_Invalid  = "SEARCH_NUMERIC_VALUE_INVALID",
	.Option_Invalid         = "SEARCH_OPTION_INVALID",
	.Value_Bad              = "SEARCH_VALUE_BAD",
	.Param_Dup              = "SEARCH_PARAM_DUP",
	.Hybrid_Attr_Non_Hybrid = "SEARCH_HYBRID_ATTR_NON_HYBRID",
	.Hybrid_Policy_Bad      = "SEARCH_HYBRID_POLICY_BAD",
	.Adhoc_Batch_Size_Irrelevant = "SEARCH_ADHOC_BATCH_SIZE_IRRELEVANT",
	.Range_Attr_Non_Range   = "SEARCH_RANGE_ATTR_NON_RANGE",
	.Index_Exists           = "SEARCH_INDEX_EXISTS",
	.Field_Dup              = "SEARCH_FIELD_DUP",
	.Query_Bad              = "SEARCH_QUERY_BAD",
	.Parse_Args             = "SEARCH_PARSE_ARGS",
	.Out_Of_Memory          = "OOM",
}

Error :: struct {
	code:    Error_Code,
	message: string,
}

VECTOR_PARAMS_SUFFIX :: " (Error parsing vector similarity parameters)"

error_reply :: proc(err: Error, allocator := context.allocator) -> string {
	if err.code == .None {
		return ""
	}
	return strings.concatenate({ERROR_WORDS[err.code], " ", err.message}, allocator)
}

near_bytes :: proc(builder: ^strings.Builder, near: string) {
	for i in 0 ..< len(near) {
		if near[i] == 0 {
			return
		}
		strings.write_byte(builder, near[i])
	}
}

syntax_message :: proc(prefix: string, offset: int, near: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, prefix)
	strings.write_string(&builder, " at offset ")
	strings.write_int(&builder, offset)
	strings.write_string(&builder, " near ")
	near_bytes(&builder, near)
	return strings.to_string(builder)
}

plain_message :: proc(args: ..any, allocator := context.allocator) -> string {
	return fmt.aprint(..args, sep = "", allocator = allocator)
}
