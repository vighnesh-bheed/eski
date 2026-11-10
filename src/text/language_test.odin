package text

import "core:strings"
import "core:testing"

@(test)
documented_languages :: proc(t: ^testing.T) {
	testing.expect_value(t, len(Language), 31)
	for l in Language {
		name := language_name(l)
		got, ok := language_parse(transmute([]u8)name)
		testing.expect(t, ok)
		testing.expect_value(t, got, l)
		upper := strings.to_upper(name, context.temp_allocator)
		got, ok = language_parse(transmute([]u8)upper)
		testing.expect(t, ok)
		testing.expect_value(t, got, l)
	}
	for name in ([?]string{"eNgLiSh", "English", "GERMAN", "German"}) {
		_, ok := language_parse(transmute([]u8)name)
		testing.expectf(t, ok, "%q is accepted", name)
	}
}

@(test)
rejected_languages :: proc(t: ^testing.T) {
	for name in ([?]string{"en", "porter", "klingon", "esperanto", "estonian", "polish", "ukrainian", "", "english ", "kraaj", " english", "englis", "englishh"}) {
		_, ok := language_parse(transmute([]u8)name)
		testing.expectf(t, !ok, "%q is rejected", name)
	}
	testing.expect_value(t, document_language(transmute([]u8)string("klingon"), .English), Language.English)
	testing.expect_value(t, document_language(transmute([]u8)string(""), .English), Language.English)
	testing.expect_value(t, document_language(transmute([]u8)string("GERMAN"), .English), Language.German)
	testing.expect_value(t, document_language(transmute([]u8)string("x"), .French), Language.French)
}
