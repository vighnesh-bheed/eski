package ftindex

import "core:strings"
import "core:unicode/utf8"
import ftq "../ftquery"
import "../glob"

Pattern :: struct {
	node: ^ftq.Node,
	query, word: [dynamic]rune,
	row, next: []int,
}

pattern_init :: proc(b: ^Builder, node: ^ftq.Node) -> Pattern {
	out := Pattern{node = node}
	if node.kind == .Fuzzy {
		out.query = make([dynamic]rune, b.a)
		out.word = make([dynamic]rune, b.a)
		for ch in node.text {
			append(&out.query, ch)
		}
		out.row = make([]int, len(out.query) + 1, b.a)
		out.next = make([]int, len(out.query) + 1, b.a)
	}
	return out
}

pattern_eligible :: proc(node: ^ftq.Node, minimum: int) -> bool {
	#partial switch node.kind {
	case .Prefix, .Infix, .Suffix:
		return utf8.rune_count_in_string(node.text) >= minimum
	case:
		return true
	}
}

pattern_matches :: proc(pattern: ^Pattern, term: string) -> bool {
	node := pattern.node
	#partial switch node.kind {
	case .Prefix: return strings.has_prefix(term, node.text)
	case .Suffix: return strings.has_suffix(term, node.text)
	case .Infix: return strings.contains(term, node.text)
	case .Wildcard_Pattern: return glob.glob_match(transmute([]u8)node.text, transmute([]u8)term, false)
	case .Fuzzy: return fuzzy_matches(pattern, term)
	case:
		return false
	}
}

fuzzy_matches :: proc(pattern: ^Pattern, term: string) -> bool {
	clear(&pattern.word)
	for ch in term {
		append(&pattern.word, ch)
	}
	q, w := pattern.query[:], pattern.word[:]
	cap := pattern.node.distance
	if abs(len(q) - len(w)) > cap {
		return false
	}
	row, next := pattern.row, pattern.next
	for &x, i in row {
		x = i
	}
	for ch, i in w {
		next[0] = i + 1
		best := next[0]
		for expected, j in q {
			next[j+1] = min(row[j+1] + 1, next[j] + 1, row[j] + int(expected != ch))
			best = min(best, next[j+1])
		}
		if best > cap {
			return false
		}
		row, next = next, row
	}
	return row[len(q)] <= cap
}
