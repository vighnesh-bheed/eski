package stem_english

Probe_Index :: struct {
	docs:  []string,
	terms: []string,
}

@(rodata)
PROBE_MINSTEM := Probe_Index {
	{"fly", "its", "abs", "a\xc3\xa9s", "\xc3\xb1ies", "\xc3\xa9ies", "\xc3\xb1abs", "na\xc3\xafves", "caf\xc3\xa9s", "\xc3\xa9bbed", "skies", "ties", "cats", "runs", "a1ing", "aaaa", "yyyy", "sky", "dying"},
	{"+a1e", "+a\xc3\xa9", "+caf\xc3\xa9", "+cat", "+die", "+na\xc3\xafv", "+run", "+sky", "+tie", "+yyyi", "+\xc3\xa9ie", "+\xc3\xb1ab", "+\xc3\xb1ie", "a1ing", "aaaa", "abs", "a\xc3\xa9s", "caf\xc3\xa9s", "cats", "dying", "fly", "its", "na\xc3\xafves", "runs", "skies", "sky", "ties", "yyyy", "\xc3\xa9bbed", "\xc3\xa9ies", "\xc3\xb1abs", "\xc3\xb1ies"},
}

@(rodata)
PROBE_MINSTEM_SINGLE := [?]Probe_Index {
	{{"fly"}, {"fly"}},
	{{"a\xc3\xa9s"}, {"+a\xc3\xa9", "a\xc3\xa9s"}},
	{{"\xc3\xa9ies"}, {"+\xc3\xa9ie", "\xc3\xa9ies"}},
	{{"\xc3\xb1abs"}, {"+\xc3\xb1ab", "\xc3\xb1abs"}},
	{{"\xc4\xb0s"}, {"+i\xcc\x87", "i\xcc\x87s"}},
	{{"a\xe2\x84\xaas"}, {"aks"}},
	{{"\xc4\xb0es"}, {"+i\xcc\x87e", "i\xcc\x87es"}},
	{{"a\xe2\x84\xa6s"}, {"+a\xcf\x89", "a\xcf\x89s"}},
	{{"\xe2\x84\xaaits"}, {"+kit", "kits"}},
	{{"\xc4\xb0ts"}, {"+i\xcc\x87t", "i\xcc\x87ts"}},
	{{"ab\x01s"}, {"abs"}},
}

@(rodata)
PROBE_ESCAPED_STEMS := Probe_Index {
	{"\\'skies don\\'t \\'apostrophe' it\\'s"},
	{"'apostrophe", "'skies", "+apostroph", "+it", "+ski", "don't", "it's"},
}

@(rodata)
PROBE_SUPPLEMENTARY_STEMS := Probe_Index {
	{"\xf0\x90\x90\x80ings \xf0\x9f\x98\x80ing a\xf0\x9f\x98\x80s"},
	{"+a\xef\x98\x80", "+\xd0\xa8ing", "a\xef\x98\x80s", "\xd0\xa8ings", "\xef\x98\x80ing"},
}
