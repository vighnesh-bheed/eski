# Byte-glob conformance and memory checks

This self-contained suite tests `glob.glob_match(pattern, text: []u8, nocase: bool) -> bool`. It imports the production module at `../../src/glob` and requires Linux, Python 3.10 or later, and the Odin compiler. It needs no network and no external oracle for normal runs.

From the repository root, run:

```sh
ODIN=/path/to/odin python3 test/glob/run.py
```

The runner verifies the compressed fixture hashes, reproduces its deterministic input order, checks a separate Python state-set oracle, and compiles and executes the native harness in debug and speed-optimized release modes. Every compiler invocation uses vet, strict style, and two threads. Temporary fixture copies and binaries are created inside the test folder and removed automatically.

The checked-in corpus contains 149,474 unique pattern/text pairs with seed `2462181965` (`0x92c1ea4d`). It includes all 65,536 one-byte pattern/text combinations, arbitrary binary bytes, empty slices, malformed classes, negation, reversed and signed-byte ranges, escaped bytes, trailing escapes, retries, late mismatches, repeated stars, the 1000/1001 nonterminal-star cutoff, and lengths around 4 KiB, 16 KiB and 64 KiB boundaries. Cases are deduplicated; `manifest.json` records category counts, source hashes and fixture hashes.

The independent state-set model checks 92,919 bounded, bracket-free cases in both case modes, for 185,838 comparisons. Each native build performs 597,896 guard placements and 1,195,792 matcher calls. A successful run reports zero failures in both builds. These results cover the glob API and guarded reads; they do not report server integration or throughput.

`cases.bin.gz` is 789,466 bytes. Its SHA256 is:

```text
10f90518185bba75ab2c1fecc8df17fa46e108d0131095d870a00136d1ff418b
```

The fixture consists of independently generated inputs and boolean outputs obtained by executing a byte-glob compatibility oracle through a JSON interface. Bracket behavior is captured from execution rather than inferred from shell syntax. The separate state-set model is described in `design.md`.

Fixture regeneration is optional and requires an explicitly supplied external executable:

```sh
python3 test/glob/run.py --refresh-oracle /path/to/compatibility-oracle --generate-only
```

A path ending in `.py` is executed with the current Python interpreter. Each invocation receives a JSON array of objects with `pattern_hex` and `text_hex` strings and must return an equal-length array with boolean `match` and `nocase_match` fields. Batches contain at most 10,000 cases, each case contains at most 100,000 combined bytes, and each invocation has a ten-second timeout. Regeneration also checks the independent state-set model before writing the fixture. It never inspects the supplied executable.

The corpus uses a canonical 4096-byte base for deterministic generation on every host. Guard mappings use the running Python's `mmap.PAGESIZE`, passed to the native harness in an ephemeral fixture header. The checked-in fixture remains unchanged when the host uses a different page size.
