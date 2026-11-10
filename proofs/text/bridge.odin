package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import se "../../src/stem_english"
import tx "../../src/text"

nat :: proc(s: string) -> int {
	v, ok := strconv.parse_i64(s, 10)
	assert(ok && v >= 0)
	return int(v)
}

unhex :: proc(s: string) -> []u8 {
	if s == "-" {
		return nil
	}
	out := make([]u8, len(s) / 2)
	for i in 0 ..< len(out) {
		v, ok := strconv.parse_u64(s[2 * i:2 * i + 2], 16)
		assert(ok)
		out[i] = u8(v)
	}
	return out
}

write_hex :: proc(b: ^strings.Builder, bytes: []u8) {
	if len(bytes) == 0 {
		strings.write_byte(b, '-')
		return
	}
	for x in bytes {
		fmt.sbprintf(b, "%02x", x)
	}
}

bit :: proc(v: bool) -> string {
	return "1" if v else "0"
}

stub_stem :: proc "contextless" (word: []u8, out: []u8) -> (stem: []u8, ok: bool) {
	if len(out) < 3 * len(word) + 20 {
		return nil, false
	}
	n := len(word)
	if n >= 3 && word[n - 3] == 'i' && word[n - 2] == 'n' && word[n - 1] == 'g' {
		n -= 3
	} else if n >= 1 && word[n - 1] == 's' {
		n -= 1
	}
	copy(out, word[:n])
	return out[:n], true
}

State :: struct {
	stops:    [8]tx.Stop_Words,
	built:    [8]bool,
	analyzer: tx.Analyzer,
	stemmers: tx.Stemmers,
	stub:     tx.Stemmers,
	terms:    tx.Terms,
}

write_stop :: proc(b: ^strings.Builder, r: int, sw: ^tx.Stop_Words) {
	fmt.sbprintf(b, "SB|%d|", r)
	words := tx.stop_words_list(sw)
	if len(words) == 0 {
		strings.write_byte(b, '-')
	}
	for w, i in words {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		if len(w) == 0 {
			strings.write_byte(b, '.')
		} else {
			write_hex(b, transmute([]u8)w)
		}
	}
	fmt.sbprintf(b, "|%d|", len(sw.slots))
	for s, i in sw.slots {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, "%d", s)
	}
	fmt.sbprintf(b, "|%016x|%016x.%016x.%016x.%016x|%s", sw.lengths, sw.firsts[0], sw.firsts[1], sw.firsts[2], sw.firsts[3], bit(tx.stop_words_reported(sw)))
}

stop_at :: proc(st: ^State, reg: string) -> ^tx.Stop_Words {
	if reg == "-" {
		return nil
	}
	r := nat(reg)
	assert(st.built[r])
	return &st.stops[r]
}

replace_stop :: proc(st: ^State, r: int, fresh: ^tx.Stop_Words) {
	if st.built[r] {
		tx.stop_words_destroy(&st.stops[r])
	}
	st.stops[r] = fresh^
	st.built[r] = true
}

row :: proc(st: ^State, line: string, b: ^strings.Builder) {
	f := strings.split(line, " ")
	strings.builder_reset(b)
	switch f[0] {
	case "BC":
		v := nat(f[1])
		fmt.sbprintf(b, "BC|%d|%d|%s", v, transmute(u8)tx.BYTE_CLASSES[v], bit(tx.is_control(u8(v))))
	case "TK":
		src := unhex(f[1])
		t: tx.Doc_Tokenizer
		tx.doc_tokenizer_init(&t)
		tx.doc_tokenizer_reset(&t, src)
		tok: tx.Token
		count := 0
		parts := strings.builder_make()
		for tx.doc_tokenizer_next(&t, &tok) {
			if count > 0 {
				strings.write_byte(&parts, ',')
			}
			write_hex(&parts, tok.text)
			fmt.sbprintf(&parts, ":%d:%d:%d", tok.start, tok.end, len(src) - len(tok.tail))
			count += 1
		}
		fmt.sbprintf(b, "TK|%d|", count)
		if count == 0 {
			strings.write_byte(b, '-')
		} else {
			strings.write_string(b, strings.to_string(parts))
		}
	case "FO":
		text := unhex(f[1])
		tail := unhex(f[2])
		out := make([dynamic]u8)
		tx.fold(text, tail, &out)
		strings.write_string(b, "FO|")
		write_hex(b, out[:])
	case "LT":
		block := nat(f[1])
		fmt.sbprintf(b, "LT|%d|", block)
		count := 0
		seq: [3]u32
		for k in 0 ..< 256 {
			cp := u32(block * 256 + k)
			n := tx.lower_full(cp, &seq)
			if n == 1 && seq[0] == cp {
				continue
			}
			if count > 0 {
				strings.write_byte(b, ',')
			}
			fmt.sbprintf(b, "%x:", cp)
			for i in 0 ..< n {
				if i > 0 {
					strings.write_byte(b, '.')
				}
				fmt.sbprintf(b, "%x", seq[i])
			}
			count += 1
		}
		if count == 0 {
			strings.write_byte(b, '-')
		}
	case "EU":
		cp := u32(nat(f[1]))
		buf: [4]u8
		w := tx.encode_unit(cp, &buf)
		dcp, next := tx.decode_unit(buf[:w], nil, 0)
		strings.write_string(b, "EU|")
		write_hex(b, buf[:w])
		fmt.sbprintf(b, "|%d|%d", dcp, next)
	case "TF":
		term := unhex(f[1])
		out := make([dynamic]u8)
		in_trie := tx.trie_form(term, &out)
		strings.write_string(b, "TF|")
		write_hex(b, out[:])
		fmt.sbprintf(b, "|%s|%d", bit(in_trie), tx.unit_count(term))
	case "SB":
		r := nat(f[1])
		fresh: tx.Stop_Words
		switch f[2] {
		case "d":
			assert(tx.stop_words_default(&fresh, heap) == .None)
		case "n":
			assert(tx.stop_words_none(&fresh, heap) == .None)
		case "c":
			words := make([dynamic][]u8)
			if f[3] != "-" {
				for w in strings.split(f[3], ",") {
					append(&words, nil if w == "." else unhex(w))
				}
			}
			assert(tx.stop_words_custom(&fresh, words[:], heap) == .None)
		case:
			panic("unknown stop mode")
		}
		replace_stop(st, r, &fresh)
		write_stop(b, r, &st.stops[r])
	case "SQ":
		sw := stop_at(st, f[1])
		term := unhex(f[2])
		fmt.sbprintf(b, "SQ|%s|%s|%s|%s", bit(tx.is_stop_word(sw, term)), bit(tx.query_drops_term(sw, term, .Plain, false)),
			bit(tx.query_drops_term(sw, term, .Plain, true)), bit(tx.query_drops_term(sw, term, .Prefix, false)))
	case "SM":
		word := unhex(f[1])
		buf := make([]u8, 2 * len(word) + 16)
		s, ok := se.stem(word, buf)
		assert(ok)
		strings.write_string(b, "SM|")
		write_hex(b, word)
		strings.write_byte(b, '|')
		write_hex(b, s)
	case "AN":
		sw := stop_at(st, f[1])
		mode := f[2]
		min_stem := nat(f[3])
		base := nat(f[4])
		text := unhex(f[5])
		stemmers := &st.stub if mode == "s" else &st.stemmers
		tx.analyzer_init(&st.analyzer, sw, stemmers)
		st.analyzer.min_stem = min_stem
		field := tx.Field{language = .English, stem = mode != "-", base = u32(base)}
		tx.terms_clear(&st.terms)
		last := tx.analyze(&st.analyzer, text, field, &st.terms)
		fmt.sbprintf(b, "AN|%d|", last)
		if len(st.terms.list) == 0 {
			strings.write_byte(b, '-')
		}
		for t, i in st.terms.list {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			write_hex(b, tx.term_bytes(&st.terms, t))
			fmt.sbprintf(b, ":%d:%d:%d:%s", t.position, t.start, t.end, "s" if t.kind == .Stem else "o")
		}
		tx.analyzer_destroy(&st.analyzer)
	case:
		panic("unknown case")
	}
}

heap: runtime.Allocator

main :: proc() {
	heap = context.allocator
	assert(len(os.args) == 2)
	input, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	lines := strings.split(string(input), "\n")
	st := new(State)
	st.stemmers[.English] = se.stem
	st.stub[.English] = stub_stem
	tx.terms_init(&st.terms)
	b := strings.builder_make()
	for line in lines {
		if len(line) == 0 {
			continue
		}
		context.allocator = context.temp_allocator
		row(st, line, &b)
		fmt.println(strings.to_string(b))
		free_all(context.temp_allocator)
	}
}
