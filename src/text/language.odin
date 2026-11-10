package text

Language :: enum u8 {
	Arabic,
	Armenian,
	Basque,
	Catalan,
	Chinese,
	Danish,
	Dutch,
	English,
	Finnish,
	French,
	German,
	Greek,
	Hindi,
	Hungarian,
	Indonesian,
	Irish,
	Italian,
	Lithuanian,
	Malay,
	Nepali,
	Norwegian,
	Portuguese,
	Romanian,
	Russian,
	Serbian,
	Spanish,
	Swedish,
	Tagalog,
	Tamil,
	Turkish,
	Yiddish,
}

DEFAULT_LANGUAGE :: Language.English

LANGUAGE_NAMES := [Language]string {
	.Arabic     = "arabic",
	.Armenian   = "armenian",
	.Basque     = "basque",
	.Catalan    = "catalan",
	.Chinese    = "chinese",
	.Danish     = "danish",
	.Dutch      = "dutch",
	.English    = "english",
	.Finnish    = "finnish",
	.French     = "french",
	.German     = "german",
	.Greek      = "greek",
	.Hindi      = "hindi",
	.Hungarian  = "hungarian",
	.Indonesian = "indonesian",
	.Irish      = "irish",
	.Italian    = "italian",
	.Lithuanian = "lithuanian",
	.Malay      = "malay",
	.Nepali     = "nepali",
	.Norwegian  = "norwegian",
	.Portuguese = "portuguese",
	.Romanian   = "romanian",
	.Russian    = "russian",
	.Serbian    = "serbian",
	.Spanish    = "spanish",
	.Swedish    = "swedish",
	.Tagalog    = "tagalog",
	.Tamil      = "tamil",
	.Turkish    = "turkish",
	.Yiddish    = "yiddish",
}

Stemmers :: [Language]Stem_Proc

language_name :: proc "contextless" (l: Language) -> string {
	return LANGUAGE_NAMES[l]
}

language_parse :: proc "contextless" (name: []u8) -> (l: Language, ok: bool) {
	outer: for candidate in Language {
		want := LANGUAGE_NAMES[candidate]
		if len(want) != len(name) {
			continue
		}
		for i in 0 ..< len(name) {
			if ascii_lower(name[i]) != want[i] {
				continue outer
			}
		}
		return candidate, true
	}
	return DEFAULT_LANGUAGE, false
}

document_language :: proc "contextless" (value: []u8, fallback: Language) -> Language {
	l, ok := language_parse(value)
	return l if ok else fallback
}
