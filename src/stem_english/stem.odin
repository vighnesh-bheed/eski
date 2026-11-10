package stem_english

Rule :: struct {
	suffix:      string,
	replacement: string,
	check:       Check,
}

Check :: enum u8 {
	Region,
	Region2,
	Preceded_L,
	Li_Ending,
	Preceded_S_T,
}

Exception :: struct {
	word: string,
	stem: string,
}

@(rodata)
EXCEPTIONS := [?]Exception {
	{"skis", "ski"},
	{"skies", "sky"},
	{"dying", "die"},
	{"lying", "lie"},
	{"tying", "tie"},
	{"idly", "idl"},
	{"gently", "gentl"},
	{"ugly", "ugli"},
	{"early", "earli"},
	{"only", "onli"},
	{"singly", "singl"},
	{"sky", "sky"},
	{"news", "news"},
	{"howe", "howe"},
	{"atlas", "atlas"},
	{"cosmos", "cosmos"},
	{"bias", "bias"},
	{"andes", "andes"},
}

@(rodata)
INVARIANT_AFTER_1A := [?]string{"inning", "outing", "canning", "herring", "earring", "proceed", "exceed", "succeed"}

@(rodata)
REGION_PREFIXES := [?]string{"gener", "commun", "arsen"}

@(rodata)
STEP2_N := [?]Rule{{"ization", "ize", .Region}, {"ational", "ate", .Region}, {"tional", "tion", .Region}, {"ation", "ate", .Region}}

@(rodata)
STEP2_S := [?]Rule{{"fulness", "ful", .Region}, {"ousness", "ous", .Region}, {"iveness", "ive", .Region}}

@(rodata)
STEP2_I := [?]Rule {
	{"biliti", "ble", .Region},
	{"lessli", "less", .Region},
	{"entli", "ent", .Region},
	{"aliti", "al", .Region},
	{"ousli", "ous", .Region},
	{"iviti", "ive", .Region},
	{"fulli", "ful", .Region},
	{"enci", "ence", .Region},
	{"anci", "ance", .Region},
	{"abli", "able", .Region},
	{"alli", "al", .Region},
	{"bli", "ble", .Region},
	{"ogi", "og", .Preceded_L},
	{"li", "", .Li_Ending},
}

@(rodata)
STEP2_M := [?]Rule{{"alism", "al", .Region}}

@(rodata)
STEP2_R := [?]Rule{{"izer", "ize", .Region}, {"ator", "ate", .Region}}

@(rodata)
STEP3_L := [?]Rule{{"ational", "ate", .Region}, {"tional", "tion", .Region}, {"ical", "ic", .Region}, {"ful", "", .Region}}

@(rodata)
STEP3_E := [?]Rule{{"alize", "al", .Region}, {"icate", "ic", .Region}, {"ative", "", .Region2}}

@(rodata)
STEP3_I := [?]Rule{{"iciti", "ic", .Region}}

@(rodata)
STEP3_S := [?]Rule{{"ness", "", .Region}}

@(rodata)
STEP4_T := [?]Rule{{"ement", "", .Region2}, {"ment", "", .Region2}, {"ant", "", .Region2}, {"ent", "", .Region2}}

@(rodata)
STEP4_E := [?]Rule {
	{"ance", "", .Region2},
	{"ence", "", .Region2},
	{"able", "", .Region2},
	{"ible", "", .Region2},
	{"ate", "", .Region2},
	{"ive", "", .Region2},
	{"ize", "", .Region2},
}

@(rodata)
STEP4_M := [?]Rule{{"ism", "", .Region2}}

@(rodata)
STEP4_I := [?]Rule{{"iti", "", .Region2}}

@(rodata)
STEP4_S := [?]Rule{{"ous", "", .Region2}}

@(rodata)
STEP4_N := [?]Rule{{"ion", "", .Preceded_S_T}}

@(rodata)
STEP4_L := [?]Rule{{"al", "", .Region2}}

@(rodata)
STEP4_R := [?]Rule{{"er", "", .Region2}}

@(rodata)
STEP4_C := [?]Rule{{"ic", "", .Region2}}

Step :: enum u8 {
	Two,
	Three,
	Four,
}

rules_for :: proc "contextless" (step: Step, last: u8) -> []Rule {
	switch step {
	case .Two:
		switch last {
		case 'n':
			return STEP2_N[:]
		case 's':
			return STEP2_S[:]
		case 'i':
			return STEP2_I[:]
		case 'm':
			return STEP2_M[:]
		case 'r':
			return STEP2_R[:]
		}
	case .Three:
		switch last {
		case 'l':
			return STEP3_L[:]
		case 'e':
			return STEP3_E[:]
		case 'i':
			return STEP3_I[:]
		case 's':
			return STEP3_S[:]
		}
	case .Four:
		switch last {
		case 't':
			return STEP4_T[:]
		case 'e':
			return STEP4_E[:]
		case 'm':
			return STEP4_M[:]
		case 'i':
			return STEP4_I[:]
		case 's':
			return STEP4_S[:]
		case 'n':
			return STEP4_N[:]
		case 'l':
			return STEP4_L[:]
		case 'r':
			return STEP4_R[:]
		case 'c':
			return STEP4_C[:]
		}
	}
	return nil
}

Word :: struct {
	b:  []u8,
	n:  int,
	p1: int,
	p2: int,
}

is_vowel :: #force_inline proc "contextless" (c: u8) -> bool {
	switch c {
	case 'a', 'e', 'i', 'o', 'u', 'y':
		return true
	}
	return false
}

is_continuation :: #force_inline proc "contextless" (c: u8) -> bool {
	return c & 0xC0 == 0x80
}

is_li_ending :: #force_inline proc "contextless" (c: u8) -> bool {
	switch c {
	case 'c', 'd', 'e', 'g', 'h', 'k', 'm', 'n', 'r', 't':
		return true
	}
	return false
}

is_double :: #force_inline proc "contextless" (c: u8) -> bool {
	switch c {
	case 'b', 'd', 'f', 'g', 'm', 'n', 'p', 'r', 't':
		return true
	}
	return false
}

unit_end :: #force_inline proc "contextless" (b: []u8, n: int, i: int) -> int #no_bounds_check {
	j := i + 1
	for j < n && is_continuation(b[j]) {
		j += 1
	}
	return j
}

unit_before :: #force_inline proc "contextless" (b: []u8, i: int) -> int #no_bounds_check {
	j := i - 1
	for j > 0 && is_continuation(b[j]) {
		j -= 1
	}
	return j
}

units_at_most :: proc "contextless" (b: []u8, n: int, limit: int) -> bool #no_bounds_check {
	count := 0
	i := 0
	for i < n {
		count += 1
		if count > limit {
			return false
		}
		i = unit_end(b, n, i)
	}
	return true
}

has_vowel :: proc "contextless" (b: []u8, end: int) -> bool #no_bounds_check {
	for i in 0 ..< end {
		if is_vowel(b[i]) {
			return true
		}
	}
	return false
}

ends_with :: #force_inline proc "contextless" (w: ^Word, s: string) -> bool #no_bounds_check {
	if len(s) > w.n {
		return false
	}
	base := w.n - len(s)
	for i := len(s) - 1; i >= 0; i -= 1 {
		if w.b[base + i] != s[i] {
			return false
		}
	}
	return true
}

push :: #force_inline proc "contextless" (w: ^Word, s: string) #no_bounds_check {
	copy(w.b[w.n:], s)
	w.n += len(s)
}

region_after :: proc "contextless" (w: ^Word, from: int) -> int #no_bounds_check {
	i := from
	for i < w.n && !is_vowel(w.b[i]) {
		i = unit_end(w.b, w.n, i)
	}
	if i >= w.n {
		return w.n
	}
	i = unit_end(w.b, w.n, i)
	for i < w.n && is_vowel(w.b[i]) {
		i = unit_end(w.b, w.n, i)
	}
	if i >= w.n {
		return w.n
	}
	return unit_end(w.b, w.n, i)
}

ends_short_syllable :: proc "contextless" (b: []u8, m: int) -> bool #no_bounds_check {
	if m <= 0 {
		return false
	}
	last := unit_before(b, m)
	if last <= 0 {
		return false
	}
	prev := unit_before(b, last)
	if prev == 0 {
		return is_vowel(b[0]) && !is_vowel(b[last])
	}
	first := unit_before(b, prev)
	if is_vowel(b[first]) || !is_vowel(b[prev]) || is_vowel(b[last]) {
		return false
	}
	switch b[last] {
	case 'w', 'x', 'Y':
		return false
	}
	return true
}

is_short_word :: #force_inline proc "contextless" (w: ^Word) -> bool {
	return w.p1 >= w.n && ends_short_syllable(w.b, w.n)
}

prelude :: proc "contextless" (w: ^Word) #no_bounds_check {
	if w.n > 0 && w.b[0] == '\'' {
		copy(w.b[0:], w.b[1:w.n])
		w.n -= 1
	}
	if w.n > 0 && w.b[0] == 'y' {
		w.b[0] = 'Y'
	}
	for i in 1 ..< w.n {
		if w.b[i] == 'y' && is_vowel(w.b[i - 1]) {
			w.b[i] = 'Y'
		}
	}
}

mark_regions :: proc "contextless" (w: ^Word) {
	w.p1 = -1
	for prefix in REGION_PREFIXES {
		if len(prefix) <= w.n && w.b[0] == prefix[0] && string(w.b[:len(prefix)]) == prefix {
			w.p1 = len(prefix)
			break
		}
	}
	if w.p1 < 0 {
		w.p1 = region_after(w, 0)
	}
	w.p2 = region_after(w, w.p1)
}

step0 :: proc "contextless" (w: ^Word) #no_bounds_check {
	if w.n == 0 || (w.b[w.n - 1] != '\'' && w.b[w.n - 1] != 's') {
		return
	}
	switch {
	case ends_with(w, "'s'"):
		w.n -= 3
	case ends_with(w, "'s"):
		w.n -= 2
	case ends_with(w, "'"):
		w.n -= 1
	}
}

step1a :: proc "contextless" (w: ^Word) #no_bounds_check {
	if w.n == 0 || (w.b[w.n - 1] != 's' && w.b[w.n - 1] != 'd') {
		return
	}
	switch {
	case ends_with(w, "sses"):
		w.n -= 2
	case ends_with(w, "ied"), ends_with(w, "ies"):
		start := w.n - 3
		w.n = start
		if units_at_most(w.b, start, 1) {
			push(w, "ie")
		} else {
			push(w, "i")
		}
	case ends_with(w, "us"), ends_with(w, "ss"):
	case ends_with(w, "s"):
		start := w.n - 1
		if start > 0 && has_vowel(w.b, unit_before(w.b, start)) {
			w.n = start
		}
	}
}

invariant_after_1a :: proc "contextless" (w: ^Word) -> bool #no_bounds_check {
	if w.n < 6 || w.n > 7 {
		return false
	}
	s := string(w.b[:w.n])
	for x in INVARIANT_AFTER_1A {
		if len(x) == len(s) && x[len(x) - 1] == s[len(s) - 1] && s == x {
			return true
		}
	}
	return false
}

step1b :: proc "contextless" (w: ^Word) #no_bounds_check {
	if w.n == 0 {
		return
	}
	switch w.b[w.n - 1] {
	case 'd', 'g', 'y':
	case:
		return
	}
	switch {
	case ends_with(w, "eedly"):
		if w.n - 5 >= w.p1 {
			w.n -= 3
		}
		return
	case ends_with(w, "eed"):
		if w.n - 3 >= w.p1 {
			w.n -= 1
		}
		return
	}
	cut := 0
	switch {
	case ends_with(w, "ingly"):
		cut = 5
	case ends_with(w, "edly"):
		cut = 4
	case ends_with(w, "ing"):
		cut = 3
	case ends_with(w, "ed"):
		cut = 2
	}
	if cut == 0 {
		return
	}
	start := w.n - cut
	if !has_vowel(w.b, start) {
		return
	}
	w.n = start
	switch {
	case ends_with(w, "at"), ends_with(w, "bl"), ends_with(w, "iz"):
		push(w, "e")
	case w.n >= 2 && w.b[w.n - 1] == w.b[w.n - 2] && is_double(w.b[w.n - 1]):
		w.n -= 1
	case is_short_word(w):
		push(w, "e")
	}
}

step1c :: proc "contextless" (w: ^Word) #no_bounds_check {
	if w.n < 2 {
		return
	}
	y := w.n - 1
	if w.b[y] != 'y' && w.b[y] != 'Y' {
		return
	}
	before := unit_before(w.b, y)
	if before > 0 && !is_vowel(w.b[before]) {
		w.b[y] = 'i'
	}
}

apply_rules :: proc "contextless" (w: ^Word, step: Step) #no_bounds_check {
	if w.n == 0 {
		return
	}
	for r in rules_for(step, w.b[w.n - 1]) {
		if !ends_with(w, r.suffix) {
			continue
		}
		start := w.n - len(r.suffix)
		if start < w.p1 {
			return
		}
		switch r.check {
		case .Region:
		case .Region2:
			if start < w.p2 {
				return
			}
		case .Preceded_L:
			if start < 1 || w.b[start - 1] != 'l' {
				return
			}
		case .Li_Ending:
			if start < 1 || !is_li_ending(w.b[start - 1]) {
				return
			}
		case .Preceded_S_T:
			if start < w.p2 || start < 1 || (w.b[start - 1] != 's' && w.b[start - 1] != 't') {
				return
			}
		}
		w.n = start
		push(w, r.replacement)
		return
	}
}

step5 :: proc "contextless" (w: ^Word) #no_bounds_check {
	if w.n < 1 {
		return
	}
	start := w.n - 1
	switch w.b[start] {
	case 'e':
		if start >= w.p2 || (start >= w.p1 && !ends_short_syllable(w.b, start)) {
			w.n = start
		}
	case 'l':
		if start >= w.p2 && start >= 1 && w.b[start - 1] == 'l' {
			w.n = start
		}
	}
}

postlude :: proc "contextless" (w: ^Word) #no_bounds_check {
	for i in 0 ..< w.n {
		if w.b[i] == 'Y' {
			w.b[i] = 'y'
		}
	}
}

exception :: proc "contextless" (word: []u8) -> (stem: string, found: bool) #no_bounds_check {
	if len(word) < 3 || len(word) > 6 {
		return "", false
	}
	s := string(word)
	for e in EXCEPTIONS {
		if len(e.word) == len(s) && e.word[0] == s[0] && s == e.word {
			return e.stem, true
		}
	}
	return "", false
}

stem :: proc "contextless" (word: []u8, out: []u8) -> (result: []u8, ok: bool) {
	if len(out) < len(word) {
		return nil, false
	}
	if s, found := exception(word); found {
		copy(out, s)
		return out[:len(s)], true
	}
	copy(out, word)
	w := Word {
		b = out,
		n = len(word),
	}
	if units_at_most(w.b, w.n, 2) {
		return out[:w.n], true
	}
	prelude(&w)
	mark_regions(&w)
	step0(&w)
	step1a(&w)
	if !invariant_after_1a(&w) {
		step1b(&w)
		step1c(&w)
		apply_rules(&w, .Two)
		apply_rules(&w, .Three)
		apply_rules(&w, .Four)
		step5(&w)
	}
	postlude(&w)
	return out[:w.n], true
}
