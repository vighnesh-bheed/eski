package stem_english

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import tx "../text"

BENCH_ENV :: "ESKI_STEM_BENCH"

BENCH_ROUNDS :: 5

BENCH_CORPUS_BYTES :: 8 << 20

bench_vocabulary :: proc() -> []string {
	words := make([dynamic]string, 0, VOCABULARY_WORDS)
	text := VOCABULARY
	for w in strings.split_lines_iterator(&text) {
		append(&words, w)
	}
	return words[:]
}

@(test)
bench_stemmer :: proc(t: ^testing.T) {
	if _, enabled := os.lookup_env(BENCH_ENV, context.temp_allocator); !enabled {
		return
	}
	words := bench_vocabulary()
	defer delete(words)
	bytes := 0
	for w in words {
		bytes += len(w)
	}
	buf: [256]u8
	sink := 0
	best := max(f64)
	for _ in 0 ..< BENCH_ROUNDS {
		start := time.tick_now()
		for _ in 0 ..< 4 {
			for w in words {
				s, _ := stem(transmute([]u8)w, buf[:])
				sink += len(s)
			}
		}
		best = min(best, time.duration_seconds(time.tick_since(start)))
	}
	count := 4 * len(words)
	log.infof("stem the Snowball vocabulary: %.1f M words/s, %.1f ns per word, %.0f MB/s (average word %.1f bytes)", f64(count) / best / 1e6, best * 1e9 / f64(count), f64(4 * bytes) / best / (1 << 20), f64(bytes) / f64(len(words)))
	testing.expect(t, sink > 0)
}

@(test)
bench_pipeline_with_stems :: proc(t: ^testing.T) {
	if _, enabled := os.lookup_env(BENCH_ENV, context.temp_allocator); !enabled {
		return
	}
	words := bench_vocabulary()
	defer delete(words)
	r := Rng{0xBE7C_57E1}
	corpus := make([dynamic]u8, 0, BENCH_CORPUS_BYTES + 64)
	defer delete(corpus)
	for len(corpus) < BENCH_CORPUS_BYTES {
		w := words[rng_below(&r, len(words))]
		if rng_below(&r, 8) == 0 {
			append(&corpus, strings.to_upper(w, context.temp_allocator))
		} else {
			append(&corpus, w)
		}
		append(&corpus, " " if rng_below(&r, 6) != 0 else ", ")
	}
	f: Fixture
	fixture_init(&f, .Default)
	defer fixture_destroy(&f)
	best := max(f64)
	terms := 0
	stems := 0
	for _ in 0 ..< BENCH_ROUNDS {
		start := time.tick_now()
		count := 0
		stemmed := 0
		for at := 0; at < len(corpus); at += 4096 {
			tx.terms_clear(&f.terms)
			tx.analyze(&f.analyzer, corpus[at:min(at + 4096, len(corpus))], tx.DEFAULT_FIELD, &f.terms)
			count += len(f.terms.list)
			for term in f.terms.list {
				if term.kind == .Stem {
					stemmed += 1
				}
			}
		}
		best = min(best, time.duration_seconds(time.tick_since(start)))
		terms = count
		stems = stemmed
	}
	mb := f64(len(corpus)) / (1 << 20)
	log.infof("tokenize, fold, stop words and stem, 4 KB fields: %.0f MB/s, %.1f M terms/s (%d terms, %d stems), %.1f ns per term", mb / best, f64(terms) / best / 1e6, terms, stems, best * 1e9 / f64(terms))
	testing.expect(t, terms > 0)
}
