package text

@(rodata)
PROBE_ESCAPES := [?]Probe_Doc {
	{"\\\xc3\xa9t\xc3\xa9", {"\xc3\xa9t\xc3\xa9"}, false},
	{"ab\\", {"ab"}, false},
	{"\\\\\\\\", {"\\\\"}, false},
	{"a\\ b", {"a b"}, false},
	{"\\Abc", {"abc"}, false},
	{"x\\\x0ay", {"xy"}, false},
	{"x\\\x09y", {"xy"}, false},
	{"x\\\x01y", {"xy"}, false},
	{"\\-5", {"-5"}, false},
	{"\\_u", {"_u"}, false},
	{"pre\\\xc3\x89post", {"pre\xc3\xa9post"}, false},
	{"\\\\x", {"\\x"}, false},
	{"tail\\\\", {"tail\\"}, false},
	{"e\\.g", {"e.g"}, false},
	{"\\ lead", {" lead"}, false},
	{"trail\\ ", {"trail "}, false},
	{"\\\\ \\\\", {"\\"}, false},
	{"\\,\\,", {",,"}, false},
	{"q\\\x7fr", {"qr"}, false},
	{"\\\xf0\x9f\x98\x80z", {"\xef\x98\x80z"}, false},
	{"\\'skies", {"'skies"}, false},
	{"don\\'t", {"don't"}, false},
}

@(rodata)
PROBE_NUL := [?]Probe_Doc {
	{"abc\x00def ghi", {"abc"}, false},
	{"\x00abc", {}, false},
	{"abc \x00 def", {"abc"}, false},
	{"abc\\\x00def", {"abc"}, false},
}

Probe_Stop :: struct {
	words: []string,
	list:  []string,
	terms: []string,
}

PROBE_STOP_DOC :: "c a b zeta alpha mid beta x \xc3\xa9cole \xcf\x83\xce\xbf\xcf\x86\xce\xbf\xcf\x83 foo bar the fox dog i\xcc\x87stanbul aa ab ba aab d e"

@(rodata)
PROBE_STOP_LISTS := [?]Probe_Stop {
	{{"c", "a", "b"}, {"a", "b", "c"}, {"aa", "aab", "ab", "alpha", "ba", "bar", "beta", "d", "dog", "e", "foo", "fox", "i\xcc\x87stanbul", "mid", "the", "x", "zeta", "\xc3\xa9cole", "\xcf\x83\xce\xbf\xcf\x86\xce\xbf\xcf\x83"}},
	{{"Zeta", "alpha", "Mid", "beta"}, {"alpha", "beta", "mid", "zeta"}, {"a", "aa", "aab", "ab", "b", "ba", "bar", "c", "d", "dog", "e", "foo", "fox", "i\xcc\x87stanbul", "the", "x", "\xc3\xa9cole", "\xcf\x83\xce\xbf\xcf\x86\xce\xbf\xcf\x83"}},
	{{"x", "x"}, {"x"}, {"a", "aa", "aab", "ab", "alpha", "b", "ba", "bar", "beta", "c", "d", "dog", "e", "foo", "fox", "i\xcc\x87stanbul", "mid", "the", "zeta", "\xc3\xa9cole", "\xcf\x83\xce\xbf\xcf\x86\xce\xbf\xcf\x83"}},
	{{"\xc3\x89COLE", "\xce\xa3\xce\x9f\xce\xa6\xce\x9f\xce\xa3"}, {"\xc3\xa9cole", "\xcf\x83\xce\xbf\xcf\x86\xce\xbf\xcf\x83"}, {"a", "aa", "aab", "ab", "alpha", "b", "ba", "bar", "beta", "c", "d", "dog", "e", "foo", "fox", "i\xcc\x87stanbul", "mid", "the", "x", "zeta"}},
	{{"foo-bar"}, {"foo-bar"}, {"a", "aa", "aab", "ab", "alpha", "b", "ba", "bar", "beta", "c", "d", "dog", "e", "foo", "fox", "i\xcc\x87stanbul", "mid", "the", "x", "zeta", "\xc3\xa9cole", "\xcf\x83\xce\xbf\xcf\x86\xce\xbf\xcf\x83"}},
	{{""}, {""}, {"a", "aa", "aab", "ab", "alpha", "b", "ba", "bar", "beta", "c", "d", "dog", "e", "foo", "fox", "i\xcc\x87stanbul", "mid", "the", "x", "zeta", "\xc3\xa9cole", "\xcf\x83\xce\xbf\xcf\x86\xce\xbf\xcf\x83"}},
	{{"THE", "Fox", "dog"}, {"dog", "fox", "the"}, {"a", "aa", "aab", "ab", "alpha", "b", "ba", "bar", "beta", "c", "d", "e", "foo", "i\xcc\x87stanbul", "mid", "x", "zeta", "\xc3\xa9cole", "\xcf\x83\xce\xbf\xcf\x86\xce\xbf\xcf\x83"}},
	{{"\xc4\xb0stanbul"}, {"i\xcc\x87stanbul"}, {"a", "aa", "aab", "ab", "alpha", "b", "ba", "bar", "beta", "c", "d", "dog", "e", "foo", "fox", "mid", "the", "x", "zeta", "\xc3\xa9cole", "\xcf\x83\xce\xbf\xcf\x86\xce\xbf\xcf\x83"}},
	{{"b", "B"}, {"b"}, {"a", "aa", "aab", "ab", "alpha", "ba", "bar", "beta", "c", "d", "dog", "e", "foo", "fox", "i\xcc\x87stanbul", "mid", "the", "x", "zeta", "\xc3\xa9cole", "\xcf\x83\xce\xbf\xcf\x86\xce\xbf\xcf\x83"}},
	{{"e", "d", "c", "b", "a"}, {"a", "b", "c", "d", "e"}, {"aa", "aab", "ab", "alpha", "ba", "bar", "beta", "dog", "foo", "fox", "i\xcc\x87stanbul", "mid", "the", "x", "zeta", "\xc3\xa9cole", "\xcf\x83\xce\xbf\xcf\x86\xce\xbf\xcf\x83"}},
	{{"aa", "a", "ab", "b", "ba", "aab"}, {"a", "aa", "aab", "ab", "b", "ba"}, {"alpha", "bar", "beta", "c", "d", "dog", "e", "foo", "fox", "i\xcc\x87stanbul", "mid", "the", "x", "zeta", "\xc3\xa9cole", "\xcf\x83\xce\xbf\xcf\x86\xce\xbf\xcf\x83"}},
}

Probe_Stop_Doc :: struct {
	word:  string,
	doc:   string,
	list:  string,
	terms: []string,
}

@(rodata)
PROBE_STOP_SINGLE := [?]Probe_Stop_Doc {
	{"\xf0\x90\x90\x80", "\xf0\x90\x90\x80 \xf0\x90\x90\xa8 \xd0\xa8 \xd1\x88 zz", "\xf0\x90\x90\xa8", {"zz", "\xd1\x88"}},
	{"\xf0\x9f\x98\x80", "\xf0\x9f\x98\x80 \xef\x98\x80 zz", "\xf0\x9f\x98\x80", {"zz", "\xef\x98\x80"}},
	{"\xc4\xb0", "\xc4\xb0 i\xcc\x87 i zz", "i\xcc\x87", {"i", "zz"}},
	{"a-b", "a\\-b a-b zz", "a-b", {"a", "b", "zz"}},
	{"x y", "x\\ y x y zz", "x y", {"x", "y", "zz"}},
}

Probe_Length :: struct {
	name:    string,
	lengths: []int,
}

@(rodata)
PROBE_LONG_TOKENS := [?]Probe_Length {
	{"a254_I", {2, 2}},
	{"a253_I", {2, 2, 256}},
	{"a253_K", {2, 2, 254}},
	{"a252_K", {2, 2, 253}},
	{"a255_esc_b", {2, 2}},
	{"a254_esc_b", {2, 2, 255}},
	{"a254_ctl_b", {2, 2, 255}},
	{"a255_ctl_b", {2, 2}},
	{"a255", {2, 2, 255}},
	{"a256", {2, 2}},
	{"a250_emoji", {2, 2, 254}},
	{"a251_emoji", {2, 2, 255}},
	{"a252_emoji", {2, 2, 255}},
}

@(rodata)
PROBE_QUERY_SPLITS := [128]bool{true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, false, false, false, false, false, false, false, false, false, false, true, true, true, true, true, true, true, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true, true, true, true, false, true, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true, true, true, true, true}
