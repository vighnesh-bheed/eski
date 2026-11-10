package vsetargs

MODULE_NAME :: "vectorset"
MODULE_VERSION :: 1

Cmd_Group :: enum u8 {
	Generic,
	String,
	List,
	Set,
	Sorted_Set,
	Hash,
	Pubsub,
	Transactions,
	Connection,
	Server,
	Scripting,
	Hyperloglog,
	Cluster,
	Sentinel,
	Geo,
	Stream,
	Bitmap,
	Module,
}

Acl_Cat :: enum u8 {
	Keyspace,
	Read,
	Write,
	Set,
	Sortedset,
	List,
	Hash,
	String,
	Bitmap,
	Hyperloglog,
	Geo,
	Stream,
	Pubsub,
	Admin,
	Fast,
	Slow,
	Blocking,
	Dangerous,
	Connection,
	Transaction,
	Scripting,
}

Acl_Cats :: bit_set[Acl_Cat;u32]

Doc_Flag :: enum u8 {
	Deprecated,
	Syscmd,
}

Doc_Flags :: bit_set[Doc_Flag;u8]

Arg_Kind :: enum u8 {
	String,
	Integer,
	Double,
	Key,
	Pattern,
	Unix_Time,
	Pure_Token,
	Oneof,
	Block,
}

Arg_Flag :: enum u8 {
	Optional,
	Multiple,
	Multiple_Token,
}

Arg_Flags :: bit_set[Arg_Flag;u8]

Cmd_Arg :: struct {
	name:             string,
	display:          string,
	token:            Maybe(string),
	summary:          string,
	since:            string,
	deprecated_since: string,
	args:             []Cmd_Arg,
	key_spec:         Maybe(u8),
	kind:             Arg_Kind,
	flags:            Arg_Flags,
}

Cmd_History :: struct {
	since:   string,
	changes: string,
}

Cmd_Doc :: struct {
	name:             string,
	summary:          string,
	since:            string,
	complexity:       string,
	deprecated_since: string,
	replaced_by:      string,
	tips:             []string,
	notes:            []string,
	history:          []Cmd_History,
	args:             []Cmd_Arg,
	acl:              Acl_Cats,
	group:            Cmd_Group,
	doc_flags:        Doc_Flags,
	module:           string,
}

Cmd_Flag :: enum u32 {
	Admin,
	Allow_Busy,
	Asking,
	Blocking,
	Denyoom,
	Fast,
	Loading,
	May_Replicate,
	Noscript,
	No_Async_Loading,
	No_Auth,
	No_Mandatory_Keys,
	No_Multi,
	Protected,
	Pubsub,
	Readonly,
	Sentinel,
	Skip_Monitor,
	Skip_Slowlog,
	Stale,
	Touches_Arbitrary_Keys,
	Write,
	Module,
}

Cmd_Flags :: bit_set[Cmd_Flag;u32]

Key_Flag :: enum u16 {
	Ro,
	Rw,
	Ow,
	Rm,
	Access,
	Update,
	Insert,
	Delete,
	Not_Key,
	Incomplete,
	Variable_Flags,
}

Key_Flags :: bit_set[Key_Flag;u16]

Key_Search :: enum u8 {
	Index,
	Keyword,
	Unknown,
}

Key_Find :: enum u8 {
	Range,
	Keynum,
	Unknown,
}

Getkeys_Proc :: enum u8 {
	None,
}

Key_Spec :: struct {
	search:  Key_Search,
	pos:     i32,
	keyword: string,
	from:    i32,
	find:    Key_Find,
	a:       i32,
	b:       i32,
	c:       i32,
	flags:   Key_Flags,
}

Cmd_Spec :: struct {
	name:    string,
	arity:   i32,
	flags:   Cmd_Flags,
	getkeys: Getkeys_Proc,
	first:   i32,
	last:    i32,
	step:    i32,
	specs:   []Key_Spec,
}

@(rodata)
COMMAND_SPECS := [Command]Cmd_Spec {
	.Vadd        = {"VADD", -5, {.Write, .Denyoom, .Module}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	.Vcard       = {"VCARD", 2, {.Readonly, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	.Vdim        = {"VDIM", 2, {.Readonly, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	.Vemb        = {"VEMB", -3, {.Readonly, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	.Vgetattr    = {"VGETATTR", 3, {.Readonly, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	.Vinfo       = {"VINFO", 2, {.Readonly, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	.Vismember   = {"VISMEMBER", 3, {.Readonly, .Module}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	.Vlinks      = {"VLINKS", -3, {.Readonly, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	.Vrandmember = {"VRANDMEMBER", -2, {.Readonly, .Module}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	.Vrange      = {"VRANGE", -4, {.Readonly, .Module}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	.Vrem        = {"VREM", 3, {.Write, .Module}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	.Vsetattr    = {"VSETATTR", 4, {.Write, .Module, .Fast}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
	.Vsim        = {"VSIM", -4, {.Readonly, .Module}, .None, 1, 0, 1, {{.Index, 1, "", 0, .Range, 0, 1, 0, {.Rw, .Access, .Update}}}},
}

@(rodata)
COMMAND_DOCS := [Command]Cmd_Doc {
	.Vadd = {
		name = "VADD",
		summary = "Stores a vector under an element name, creating the vector set on first use and replacing the vector of an element that is already present.",
		since = "8.0.0",
		group = .Module,
		module = MODULE_NAME,
		args = {
			{name = "key", kind = .Key, key_spec = 0},
			{name = "reduce", kind = .Block, token = "REDUCE", flags = {.Optional}, args = {{name = "dim", kind = .Integer}}},
			{
				name = "format",
				kind = .Oneof,
				args = {{name = "fp32", kind = .Pure_Token, token = "FP32"}, {name = "values", kind = .Pure_Token, token = "VALUES"}},
			},
			{name = "vector", kind = .String},
			{name = "element", kind = .String},
			{name = "cas", kind = .Pure_Token, token = "CAS", flags = {.Optional}},
			{
				name = "quant_type",
				kind = .Oneof,
				flags = {.Optional},
				args = {
					{name = "noquant", kind = .Pure_Token, token = "NOQUANT"},
					{name = "bin", kind = .Pure_Token, token = "BIN"},
					{name = "q8", kind = .Pure_Token, token = "Q8"},
				},
			},
			{name = "build-exploration-factor", kind = .Integer, token = "EF", flags = {.Optional}},
			{name = "attributes", kind = .String, token = "SETATTR", flags = {.Optional}},
			{name = "numlinks", kind = .Integer, token = "M", flags = {.Optional}},
		},
	},
	.Vcard = {
		name = "VCARD",
		summary = "Counts the elements stored in a vector set, answering 0 for a missing key.",
		since = "8.0.0",
		group = .Module,
		module = MODULE_NAME,
		args = {{name = "key", kind = .Key, key_spec = 0}},
	},
	.Vdim = {
		name = "VDIM",
		summary = "Reports how many components each stored vector has, which after a REDUCE projection is the reduced size.",
		since = "8.0.0",
		group = .Module,
		module = MODULE_NAME,
		args = {{name = "key", kind = .Key, key_spec = 0}},
	},
	.Vemb = {
		name = "VEMB",
		summary = "Reads back the stored vector of an element as numbers, or with RAW in the encoded form the set keeps.",
		since = "8.0.0",
		group = .Module,
		module = MODULE_NAME,
		args = {
			{name = "key", kind = .Key, key_spec = 0},
			{name = "element", kind = .String},
			{name = "raw", kind = .Pure_Token, token = "RAW", flags = {.Optional}},
		},
	},
	.Vgetattr = {
		name = "VGETATTR",
		summary = "Fetches the JSON text attached to an element, or null when the element carries none.",
		since = "8.0.0",
		group = .Module,
		module = MODULE_NAME,
		args = {{name = "key", kind = .Key, key_spec = 0}, {name = "element", kind = .String}},
	},
	.Vinfo = {
		name = "VINFO",
		summary = "Describes the quantization, dimensions, element and attribute counts and graph parameters of a vector set.",
		since = "8.0.0",
		group = .Module,
		module = MODULE_NAME,
		args = {{name = "key", kind = .Key, key_spec = 0}},
	},
	.Vismember = {
		name = "VISMEMBER",
		summary = "Tells whether the named element belongs to the vector set at the key.",
		since = "8.2.0",
		group = .Module,
		module = MODULE_NAME,
		args = {{name = "key", kind = .Key, key_spec = 0}, {name = "element", kind = .String}},
	},
	.Vlinks = {
		name = "VLINKS",
		summary = "Lists, for each graph layer the element sits on, the elements it links to, optionally with their similarity scores.",
		since = "8.0.0",
		group = .Module,
		module = MODULE_NAME,
		args = {
			{name = "key", kind = .Key, key_spec = 0},
			{name = "element", kind = .String},
			{name = "withscores", kind = .Pure_Token, token = "WITHSCORES", flags = {.Optional}},
		},
	},
	.Vrandmember = {
		name = "VRANDMEMBER",
		summary = "Picks an element at random, or with a count that many, all distinct when the count is positive and possibly repeated when it is negative.",
		since = "8.0.0",
		group = .Module,
		module = MODULE_NAME,
		args = {{name = "key", kind = .Key, key_spec = 0}, {name = "count", kind = .Integer, flags = {.Optional}}},
	},
	.Vrange = {
		name = "VRANGE",
		summary = "Lists the element names that sort between two bounds, in byte order, up to an optional count.",
		since = "8.4.0",
		group = .Module,
		module = MODULE_NAME,
		args = {
			{name = "key", kind = .Key, key_spec = 0},
			{name = "start", kind = .String},
			{name = "end", kind = .String},
			{name = "count", kind = .Integer, flags = {.Optional}},
		},
	},
	.Vrem = {
		name = "VREM",
		summary = "Takes the named element, its vector and its attribute out of the set, and deletes the key when no element is left.",
		since = "8.0.0",
		group = .Module,
		module = MODULE_NAME,
		args = {{name = "key", kind = .Key, key_spec = 0}, {name = "element", kind = .String}},
	},
	.Vsetattr = {
		name = "VSETATTR",
		summary = "Replaces the JSON text attached to an existing element, and clears it when given an empty string.",
		since = "8.0.0",
		group = .Module,
		module = MODULE_NAME,
		args = {
			{name = "key", kind = .Key, key_spec = 0},
			{name = "element", kind = .String},
			{name = "json", kind = .String},
		},
	},
	.Vsim = {
		name = "VSIM",
		summary = "Searches a vector set for the elements closest to a query vector or to an existing element.",
		since = "8.0.0",
		group = .Module,
		module = MODULE_NAME,
		args = {
			{name = "key", kind = .Key, key_spec = 0},
			{
				name = "format",
				kind = .Oneof,
				args = {
					{name = "ele", kind = .Pure_Token, token = "ELE"},
					{name = "fp32", kind = .Pure_Token, token = "FP32"},
					{name = "values", kind = .Pure_Token, token = "VALUES"},
				},
			},
			{name = "vector_or_element", kind = .String},
			{name = "withscores", kind = .Pure_Token, token = "WITHSCORES", flags = {.Optional}},
			{name = "withattribs", kind = .Pure_Token, token = "WITHATTRIBS", flags = {.Optional}},
			{name = "count", kind = .Integer, token = "COUNT", flags = {.Optional}},
			{name = "max_distance", kind = .Double, token = "EPSILON", flags = {.Optional}},
			{name = "search-exploration-factor", kind = .Integer, token = "EF", flags = {.Optional}},
			{name = "expression", kind = .String, token = "FILTER", flags = {.Optional}},
			{name = "max-filtering-effort", kind = .Integer, token = "FILTER-EF", flags = {.Optional}},
			{name = "truth", kind = .Pure_Token, token = "TRUTH", flags = {.Optional}},
			{name = "nothread", kind = .Pure_Token, token = "NOTHREAD", flags = {.Optional}},
		},
	},
}

command_name :: proc "contextless" (cmd: Command) -> string {
	return COMMAND_SPECS[cmd].name
}

command_lookup :: proc "contextless" (name: []u8) -> (cmd: Command, ok: bool) {
	for spec, candidate in COMMAND_SPECS {
		if token_is(name, spec.name) && len(name) == len(spec.name) {
			return candidate, true
		}
	}
	return .Vadd, false
}
