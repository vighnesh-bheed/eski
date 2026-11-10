package ftquery

import "core:mem"
import "core:strings"

Token_Kind :: enum u8 {
	End,
	Term,
	Number,
	Stopword,
	Prefix,
	Suffix,
	Infix,
	Star,
	Modifier,
	Param,
	Arrow,
	Lp,
	Rp,
	Lb,
	Rb,
	Lsqb,
	Rsqb,
	Colon,
	Semicolon,
	Or,
	Minus,
	Tilde,
	Quote,
	Percent,
	Wildcard,
	Phrase,
	Phrase_Prefix,
	Param_Prefix,
	Param_Suffix,
	Param_Infix,
	Ismissing,
	Eq,
	Ne,
	Gt,
	Ge,
	Lt,
	Le,
}

Token :: struct {
	kind:  Token_Kind,
	pos:   int,
	end:   int,
	text:  string,
	raw:   string,
	near:  string,
	quirk: bool,
}

Lexer :: struct {
	text:      string,
	at:        int,
	dialect:   int,
	near:      string,
	last_pos:  int,
	compound:  int,
	wildcard:  bool,
	schema:    ^Schema,
	hooks:     ^Hooks,
	allocator: mem.Allocator,
}

is_alnum :: #force_inline proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

is_digit :: #force_inline proc "contextless" (c: u8) -> bool {
	return c >= '0' && c <= '9'
}

is_term_byte :: #force_inline proc "contextless" (c: u8) -> bool {
	return is_alnum(c) || c == '_' || c >= 0x80
}

is_space :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}

is_escapable :: #force_inline proc "contextless" (c: u8) -> bool {
	return !is_alnum(c) && c < 0x80 && c != 0
}

word_end :: proc "contextless" (text: string, start: int) -> (end: int, escaped: bool) {
	i := start
	for i < len(text) {
		c := text[i]
		if is_term_byte(c) {
			i += 1
		} else if c == '\\' && i + 1 < len(text) && is_escapable(text[i + 1]) {
			i += 2
			escaped = true
		} else {
			break
		}
	}
	return i, escaped
}

word_starts :: #force_inline proc "contextless" (text: string, at: int) -> bool {
	if at >= len(text) {
		return false
	}
	c := text[at]
	if is_term_byte(c) {
		return true
	}
	return c == '\\' && at + 1 < len(text) && is_escapable(text[at + 1])
}

unescape :: proc(raw: string, allocator: mem.Allocator) -> string {
	has := false
	for i in 0 ..< len(raw) {
		if raw[i] == '\\' {
			has = true
			break
		}
	}
	if !has {
		return raw
	}
	out, err := make([]u8, len(raw), allocator)
	if err != nil {
		return raw
	}
	n := 0
	for i in 0 ..< len(raw) {
		if raw[i] == '\\' && i + 1 < len(raw) && is_escapable(raw[i + 1]) {
			continue
		}
		out[n] = raw[i]
		n += 1
	}
	return string(out[:n])
}

in_place_near :: proc(raw: string, unescaped: string, allocator: mem.Allocator) -> string {
	if len(raw) == len(unescaped) {
		return raw
	}
	out, err := make([]u8, len(raw), allocator)
	if err != nil {
		return raw
	}
	copy(out, unescaped)
	copy(out[len(unescaped):], raw[len(unescaped):])
	return string(out)
}

digits_end :: proc "contextless" (text: string, at: int) -> int {
	i := at
	for i < len(text) && is_digit(text[i]) {
		i += 1
	}
	return i
}

inf_at :: proc "contextless" (text: string, at: int, fold: bool) -> bool {
	if at + 3 > len(text) {
		return false
	}
	w := text[at:at + 3]
	if fold {
		return ascii_equal_fold(w, "inf")
	}
	return w == "inf"
}

exponent_end :: proc "contextless" (text: string, at: int) -> int {
	if at < len(text) && (text[at] == 'e' || text[at] == 'E') {
		j := at + 1
		if j < len(text) && (text[j] == '+' || text[j] == '-') {
			j += 1
		}
		k := digits_end(text, j)
		if k > j {
			return k
		}
	}
	return at
}

number_length :: proc "contextless" (text: string, at: int, dialect: int, allow_inf := true) -> int {
	i := at
	c := text[i]
	signed := false
	if c == '-' || c == '+' || (c == '\'' && dialect < 2) {
		signed = true
		i += 1
		if i >= len(text) {
			return 0
		}
	}
	if allow_inf && inf_at(text, i, dialect >= 2) {
		return i + 3 - at
	}
	if c == '\'' {
		return 0
	}
	if dialect < 2 {
		if signed && c == '+' {
			return 0
		}
		j := digits_end(text, i)
		if j == i {
			return 0
		}
		if j < len(text) && text[j] == '.' {
			k := digits_end(text, j + 1)
			if k > j + 1 {
				j = k
			}
		}
		return exponent_end(text, j) - at
	}
	j := digits_end(text, i)
	if j > i {
		if j < len(text) && text[j] == '.' {
			j = digits_end(text, j + 1)
		}
	} else {
		if i < len(text) && text[i] == '.' {
			k := digits_end(text, i + 1)
			if k == i + 1 {
				return 0
			}
			j = k
		} else {
			return 0
		}
	}
	return exponent_end(text, j) - at
}

closing_quote :: proc "contextless" (text: string, at: int, quote: u8) -> int {
	last := -1
	for i in at ..< len(text) {
		if text[i] != quote {
			continue
		}
		last = i
		if i > at && text[i - 1] == '\\' {
			continue
		}
		break
	}
	return last
}

strict_closing_quote :: proc "contextless" (text: string, at: int, quote: u8) -> int {
	i := at
	for i < len(text) {
		c := text[i]
		if c == '\\' {
			i += 2
			continue
		}
		if c == quote {
			return i
		}
		i += 1
	}
	return -1
}

unescape_all :: proc(raw: string, allocator: mem.Allocator) -> string {
	has := false
	for i in 0 ..< len(raw) {
		if raw[i] == '\\' {
			has = true
			break
		}
	}
	if !has {
		return raw
	}
	out, err := make([]u8, len(raw), allocator)
	if err != nil {
		return raw
	}
	n := 0
	i := 0
	for i < len(raw) {
		if raw[i] == '\\' && i + 1 < len(raw) {
			i += 1
		}
		out[n] = raw[i]
		n += 1
		i += 1
	}
	return string(out[:n])
}

lexer_token :: proc(l: ^Lexer, kind: Token_Kind, pos, end: int, text, raw: string, sets_near: bool) -> Token {
	if sets_near {
		l.near = raw
	}
	if kind == .Prefix || kind == .Suffix || kind == .Infix {
		l.wildcard = false
	}
	l.last_pos = pos
	return Token{kind = kind, pos = pos, end = end, text = text, raw = raw, near = l.near, quirk = l.wildcard}
}

lexer_punct :: proc(l: ^Lexer, kind: Token_Kind, pos: int) -> Token {
	l.at = pos + 1
	return lexer_token(l, kind, pos, pos + 1, "", "", false)
}

normalize_term :: proc(l: ^Lexer, text: string) -> string {
	if l.hooks != nil && l.hooks.normalize != nil {
		return l.hooks.normalize(l.hooks.user, text, l.allocator)
	}
	return ascii_normalize(nil, text, l.allocator)
}

comparison_at :: proc "contextless" (text: string, at: int) -> (kind: Token_Kind, size: int) {
	if at >= len(text) {
		return .End, 0
	}
	c := text[at]
	next: u8 = text[at + 1] if at + 1 < len(text) else 0
	switch c {
	case '=':
		if next == '=' {
			return .Eq, 2
		}
	case '!':
		if next == '=' {
			return .Ne, 2
		}
	case '>':
		if next == '=' {
			return .Ge, 2
		}
		return .Gt, 1
	case '<':
		if next == '=' {
			return .Le, 2
		}
		return .Lt, 1
	}
	return .End, 0
}

lex_word :: proc(l: ^Lexer, start: int) -> Token {
	text := l.text
	end, _ := word_end(text, start)
	if end == start + 1 && text[start] == '_' && !(end < len(text) && text[end] == '*') {
		l.at = end
		return lex_next(l)
	}
	num := 0
	plain := 0
	if is_digit(text[start]) || text[start] == 'i' || text[start] == 'I' {
		num = number_length(text, start, l.dialect)
		plain = number_length(text, start, l.dialect, false)
	}
	if plain > 0 && plain >= end - start && start + plain < len(text) && text[start + plain] == '*' {
		raw := text[start:start + plain]
		l.at = start + plain + 1
		return lexer_token(l, .Prefix, start, l.at, raw, raw, true)
	}
	if end < len(text) && text[end] == '*' && end - start >= num {
		raw := text[start:end]
		l.at = end + 1
		return lexer_token(l, .Prefix, start, end + 1, unescape(raw, l.allocator), raw, true)
	}
	if num > 0 && num >= end - start {
		return lex_number(l, start, num)
	}
	if l.dialect >= 2 && text[start] == 'w' && end == start + 1 && end < len(text) && (text[end] == '\'' || text[end] == '"') {
		close := strict_closing_quote(text, end + 1, text[end])
		if close > end + 1 {
			raw := text[end + 1:close]
			l.at = close + 1
			near := raw[1:] if raw[0] == '$' else raw
			tok := lexer_token(l, .Wildcard, start + 2, close + 1, unescape_all(raw, l.allocator), near, true)
			tok.raw = raw
			l.wildcard = true
			return tok
		}
	}
	raw := text[start:end]
	l.at = end
	value := unescape(raw, l.allocator)
	if l.dialect >= 2 && ascii_equal_fold(value, "ismissing") && len(raw) == len(value) {
		return lexer_token(l, .Ismissing, start, end, value, raw, true)
	}
	folded := normalize_term(l, value)
	if l.schema != nil && schema_is_stopword(l.schema, folded) {
		return lexer_token(l, .Stopword, start, end, value, raw, true)
	}
	return lexer_token(l, .Term, start, end, value, raw, true)
}

lex_number :: proc(l: ^Lexer, start, size: int) -> Token {
	raw := l.text[start:start + size]
	l.at = start + size
	return lexer_token(l, .Number, start, start + size, raw, raw, true)
}

local_token :: proc(l: ^Lexer, kind: Token_Kind, pos, end: int, text, raw: string) -> Token {
	return Token{kind = kind, pos = pos, end = end, text = text, raw = raw, near = raw, quirk = l.wildcard}
}

skip_spaces :: proc "contextless" (text: string, at: int) -> int {
	i := at
	for i < len(text) && is_space(text[i]) {
		i += 1
	}
	return i
}

compound_follows :: proc "contextless" (text: string, at: int, dialect: int) -> bool {
	i := skip_spaces(text, at)
	_, size := comparison_at(text, i)
	if size == 0 {
		return false
	}
	i = skip_spaces(text, i + size)
	if i >= len(text) {
		return false
	}
	if text[i] == '$' {
		return word_starts(text, i + 1)
	}
	c := text[i]
	if !(is_digit(c) || c == '-' || c == '+' || c == '.' || c == 'i' || c == 'I') {
		return false
	}
	return number_length(text, i, dialect) > 0
}

lex_compound :: proc(l: ^Lexer) -> Token {
	text := l.text
	start := skip_spaces(text, l.at)
	if l.compound == 2 {
		kind, size := comparison_at(text, start)
		l.at = start + size
		l.compound = 1
		return local_token(l, kind, start, start + size, "", "")
	}
	l.compound = 0
	if text[start] == '$' {
		end, _ := word_end(text, start + 1)
		raw := text[start + 1:end]
		l.at = end
		name := raw
		if end < len(text) && !is_space(text[end]) && text[end] != 0 {
			name = strings.concatenate({name, text[end:end + 1]}, l.allocator)
		}
		return local_token(l, .Param, start, end, name, raw)
	}
	size := number_length(text, start, l.dialect)
	raw := text[start:start + size]
	l.at = start + size
	return local_token(l, .Number, start, start + size, raw, raw)
}

lex_next :: proc(l: ^Lexer) -> Token {
	text := l.text
	if l.compound > 0 {
		return lex_compound(l)
	}
	for l.at < len(text) && is_space(text[l.at]) {
		l.at += 1
	}
	for l.at < len(text) {
		start := l.at
		c := text[start]
		if is_space(c) {
			l.at += 1
			continue
		}
		next: u8 = text[start + 1] if start + 1 < len(text) else 0
		switch c {
		case '(':
			return lexer_punct(l, .Lp, start)
		case ')':
			return lexer_punct(l, .Rp, start)
		case '{':
			return lexer_punct(l, .Lb, start)
		case '}':
			return lexer_punct(l, .Rb, start)
		case '[':
			return lexer_punct(l, .Lsqb, start)
		case ']':
			return lexer_punct(l, .Rsqb, start)
		case ':':
			return lexer_punct(l, .Colon, start)
		case ';':
			return lexer_punct(l, .Semicolon, start)
		case '|':
			return lexer_punct(l, .Or, start)
		case '~':
			return lexer_punct(l, .Tilde, start)
		case '%':
			return lexer_punct(l, .Percent, start)
		case '=':
			if next == '>' {
				l.at = start + 2
				near_end := min(start + 3, len(text))
				raw := text[start + 1:near_end]
				return lexer_token(l, .Arrow, start, start + 2, "", raw, true)
			}
		case '-', '+', '.':
			plain := number_length(text, start, l.dialect, false)
			if plain > 0 && start + plain < len(text) && text[start + plain] == '*' {
				raw := text[start:start + plain]
				l.at = start + plain + 1
				return lexer_token(l, .Prefix, start, l.at, raw, raw, true)
			}
			size := number_length(text, start, l.dialect)
			if size > 0 {
				return lex_number(l, start, size)
			}
			if c == '-' {
				return lexer_punct(l, .Minus, start)
			}
		case '*':
			if l.dialect >= 2 && next == '$' && word_starts(text, start + 2) {
				end, _ := word_end(text, start + 2)
				raw := text[start + 2:end]
				value := raw
				kind := Token_Kind.Param_Suffix
				l.at = end
				if end < len(text) && text[end] == '*' {
					kind = .Param_Infix
					l.at = end + 1
				}
				tok := lexer_token(l, kind, start, l.at, value, raw, true)
				l.wildcard = true
				return tok
			}
			if l.dialect >= 2 && (next == '"' || next == '\'') {
				close := closing_quote(text, start + 2, next)
				if close >= 0 {
					raw := text[start + 2:close]
					value := unescape(raw, l.allocator)
					if close + 1 < len(text) && text[close + 1] == '*' {
						l.at = close + 2
						return lexer_token(l, .Infix, start, close + 2, value, raw, true)
					}
					l.at = close + 1
					return lexer_token(l, .Suffix, start, close + 1, value, raw, true)
				}
			}
			plain := 0
			if start + 1 < len(text) && (is_digit(next) || next == '-' || next == '+' || next == '.') {
				plain = number_length(text, start + 1, l.dialect, false)
			}
			word := 0
			if word_starts(text, start + 1) {
				word_stop, _ := word_end(text, start + 1)
				word = word_stop - start - 1
			}
			if plain > 0 || word > 0 {
				end := start + 1 + max(plain, word)
				raw := text[start + 1:end]
				value := raw if plain >= word else unescape(raw, l.allocator)
				if end < len(text) && text[end] == '*' {
					l.at = end + 1
					return lexer_token(l, .Infix, start, end + 1, value, raw, true)
				}
				l.at = end
				return lexer_token(l, .Suffix, start, end, value, raw, true)
			}
			return lexer_punct(l, .Star, start)
		case '@':
			if word_starts(text, start + 1) {
				end, _ := word_end(text, start + 1)
				raw := text[start + 1:end]
				value := unescape(raw, l.allocator)
				l.at = end
				if l.dialect >= 2 && compound_follows(text, end, l.dialect) {
					l.compound = 2
					return local_token(l, .Modifier, start, end, value, raw)
				}
				tok := lexer_token(l, .Modifier, start, end, value, raw, true)
				l.near = in_place_near(raw, value, l.allocator)
				return tok
			}
		case '$':
			if word_starts(text, start + 1) {
				end, _ := word_end(text, start + 1)
				raw := text[start + 1:end]
				if l.dialect >= 2 && end < len(text) && text[end] == '*' {
					l.at = end + 1
					tok := lexer_token(l, .Param_Prefix, start, end + 1, raw, raw, true)
					l.wildcard = true
					return tok
				}
				l.at = end
				return lexer_token(l, .Param, start, end, raw, raw, true)
			}
		case '"':
			if l.dialect >= 2 {
				close := closing_quote(text, start + 1, '"')
				if close >= 0 {
					return lex_phrase(l, start, close)
				}
			}
			return lexer_punct(l, .Quote, start)
		case '\'':
			if l.dialect >= 2 {
				close := closing_quote(text, start + 1, '\'')
				if close >= 0 {
					return lex_phrase(l, start, close)
				}
			} else if size := number_length(text, start, l.dialect); size > 0 {
				return lex_number(l, start, size)
			}
		case:
			if word_starts(text, start) {
				return lex_word(l, start)
			}
		}
		l.at = start + 1
	}
	return Token{kind = .End, pos = l.last_pos, end = len(text), near = l.near}
}

lex_phrase :: proc(l: ^Lexer, start, close: int) -> Token {
	raw := l.text[start + 1:close]
	if len(raw) > 0 && close + 1 < len(l.text) && l.text[close + 1] == '*' {
		l.at = close + 2
		return lexer_token(l, .Phrase_Prefix, start, close + 2, unescape(raw, l.allocator), raw, true)
	}
	l.at = close + 1
	return lexer_token(l, .Phrase, start, close + 1, raw, raw, true)
}

lex_all :: proc(l: ^Lexer, tokens: ^[dynamic]Token) -> bool {
	for {
		tok := lex_next(l)
		if _, err := append(tokens, tok); err != nil {
			return false
		}
		if tok.kind == .End {
			return true
		}
	}
}
