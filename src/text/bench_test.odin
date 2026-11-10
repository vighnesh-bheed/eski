package text

import "core:log"
import "core:os"
import "core:testing"
import "core:time"

BENCH_ENV :: "ESKI_TEXT_BENCH"

BENCH_BYTES :: 8 << 20

BENCH_ROUNDS :: 5

@(rodata)
BENCH_WORDS := [?]string {
	"the", "Redis", "vector", "search", "engine", "indexes", "documents", "and", "returns", "results",
	"Running", "queries", "over", "hashes", "with", "TEXT", "fields", "is", "fast", "because",
	"tokenization", "happens", "once", "per", "document", "at", "write", "time", "while", "stemming",
	"maps", "connected", "connecting", "connection", "to", "one", "stem", "so", "users", "find",
	"what", "they", "mean", "rather", "than", "what", "they", "typed", "a", "language",
	"model", "embeds", "every", "chunk", "into", "dense", "vectors", "of", "floating", "point",
	"numbers", "hybrid", "retrieval", "fuses", "lexical", "scores", "BM25", "ranks", "relevance", "jumped",
	"quickly", "over", "lazy", "dogs", "national", "generalization", "happiness", "agreed", "ponies", "caresses",
}

@(rodata)
BENCH_UNICODE_WORDS := [?]string {
	"\xce\xa3\xce\x8a\xce\xa3\xce\xa5\xce\xa6\xce\x9f\xce\xa3", "\xd0\x9c\xd0\x9e\xd0\xa1\xd0\x9a\xd0\x92\xd0\x90", "\xc3\x89COLE", "stra\xc3\x9fe", "\xe6\x9d\xb1\xe4\xba\xac\xe3\x82\xbf\xe3\x83\xaf\xe3\x83\xbc", "na\xc3\xafve", "\xc4\xb0stanbul", "\xc3\x85ngstr\xc3\xb6m",
}

@(rodata)
BENCH_GLUE := [?]string{" ", " ", " ", " ", ", ", ". ", " - ", "\n", "; ", " (", ") "}

bench_corpus :: proc(r: ^Rng, words: []string, size: int) -> []u8 {
	out := make([dynamic]u8, 0, size + 64)
	for len(out) < size {
		append(&out, words[rng_below(r, len(words))])
		append(&out, BENCH_GLUE[rng_below(r, len(BENCH_GLUE))])
	}
	return out[:]
}

Bench_Result :: struct {
	seconds: f64,
	tokens:  int,
}

bench_tokenize :: proc(corpus: []u8) -> Bench_Result {
	td: Doc_Tokenizer
	doc_tokenizer_init(&td)
	defer doc_tokenizer_destroy(&td)
	best := max(f64)
	tokens := 0
	for _ in 0 ..< BENCH_ROUNDS {
		start := time.tick_now()
		count := 0
		doc_tokenizer_reset(&td, corpus)
		tok: Token
		for doc_tokenizer_next(&td, &tok) {
			count += 1
		}
		best = min(best, time.duration_seconds(time.tick_since(start)))
		tokens = count
	}
	return {best, tokens}
}

bench_analyze :: proc(corpus: []u8, chunk: int) -> Bench_Result {
	f: Fixture
	fixture_init(&f, .Default)
	defer fixture_destroy(&f)
	best := max(f64)
	terms := 0
	for _ in 0 ..< BENCH_ROUNDS {
		start := time.tick_now()
		count := 0
		for at := 0; at < len(corpus); at += chunk {
			terms_clear(&f.terms)
			analyze(&f.analyzer, corpus[at:min(at + chunk, len(corpus))], Field{stem = false}, &f.terms)
			count += len(f.terms.list)
		}
		best = min(best, time.duration_seconds(time.tick_since(start)))
		terms = count
	}
	return {best, terms}
}

@(test)
bench_tokenizer_and_folding :: proc(t: ^testing.T) {
	if _, enabled := os.lookup_env(BENCH_ENV, context.temp_allocator); !enabled {
		return
	}
	r := Rng{0xBE7C_7E47}
	english := bench_corpus(&r, BENCH_WORDS[:], BENCH_BYTES)
	defer delete(english)
	unicode := bench_corpus(&r, BENCH_UNICODE_WORDS[:], BENCH_BYTES)
	defer delete(unicode)
	mb := f64(BENCH_BYTES) / (1 << 20)
	tok := bench_tokenize(english)
	log.infof("tokenize english: %.0f MB/s, %.1f M tokens/s, %.1f ns per token", mb / tok.seconds, f64(tok.tokens) / tok.seconds / 1e6, tok.seconds * 1e9 / f64(tok.tokens))
	an := bench_analyze(english, 4096)
	log.infof("tokenize, fold and drop stop words, english in 4 KB fields: %.0f MB/s, %.1f M terms/s, %.1f ns per term", mb / an.seconds, f64(an.tokens) / an.seconds / 1e6, an.seconds * 1e9 / f64(an.tokens))
	short := bench_analyze(english, 64)
	log.infof("the same in 64 byte fields: %.0f MB/s, %.1f M terms/s", mb / short.seconds, f64(short.tokens) / short.seconds / 1e6)
	tu := bench_tokenize(unicode)
	log.infof("tokenize non-ASCII: %.0f MB/s, %.1f M tokens/s", mb / tu.seconds, f64(tu.tokens) / tu.seconds / 1e6)
	au := bench_analyze(unicode, 4096)
	log.infof("tokenize and fold non-ASCII in 4 KB fields: %.0f MB/s, %.1f M terms/s, %.1f ns per term", mb / au.seconds, f64(au.tokens) / au.seconds / 1e6, au.seconds * 1e9 / f64(au.tokens))
	testing.expect(t, tok.tokens > 0 && an.tokens > 0 && tu.tokens > 0)
}
