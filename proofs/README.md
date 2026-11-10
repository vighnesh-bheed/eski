# Formal verification projects

The first phase groups correctness work for areas 1–6 and 9. Each project pairs an executable Lean model with mathematical specifications, kernel-checked theorems, an axiom audit and comparisons against actual Odin code. The individual project documentation defines the covered contracts, assumptions and remaining obligations.

| Group | Areas | Project |
| --- | --- | --- |
| Storage | 1. Hash-table resizing; 6. Memory accounting | [Storage](storage/README.md) |
| Command state | 2. Worker rollback; 3. Expiry and persistence | [Effects](effects/README.md) |
| Encoding | 4. Request parsing; 5. Packed data codecs | [Encoding](encoding/README.md) |
| Arithmetic | 9. Bit and integer operations | [Bitfields](bitfield/README.md) |

Areas 7 and 8, worker scheduling and fork/shutdown, have separate [bounded concurrency and lifecycle checks](../verification/README.md). Area 10 covers performance analysis and measurement; benchmarks remain deferred.

The vector packages have their own project, [Vectors](vector/README.md), which the aggregate runner includes after the first phase. It covers the Hadamard projection, int8 quantisation, binary encoding, scores and the arena free list in `src/vmath`, the candidate heaps, the visited set, the graph links, the link encoding and the twin chains in `src/hnsw`, and compiled filter programs in `src/vfilter`. Its receipt names its areas instead of numbering them.

## Recorded coverage

The first phase contains 278 named contract theorems. The complete kernel inventory additionally checks generated declarations. The comparison counts below use different units and should be read by row.

| Area | Named theorems | Actual Odin comparison evidence |
| --- | --- | --- |
| 1. Hash-table resizing | 132 | 12,275 table operations and 2,254 SCAN rounds, including non-power-of-two capacities, growth and shrink rules, timed keys, partial migration, collisions, deletions and swaps |
| 2. Worker rollback | 18 | Five internal-failure, success and ordinary command-error fixtures |
| 3. Expiry and persistence | 27 | 7,958 hash-operation steps, ten ordinary-key translation fixtures and two exact-deadline fixtures |
| 4. Request parsing | 16 | 1,629 arithmetic guards and 4,042 fragmented-input prefix checks |
| 5. Packed codecs | 26 | 11,376 codec, decode, validation and traversal rows |
| 6. Memory accounting | 24 | 1,527 pool accounting operations and rollback/ownership checks, plus table-byte, timed-key and key-cell counters on each of the 12,275 table rows |
| 9. Bit and integer operations | 35 | 49,629 programs containing 100,155 operations |

These checks passed in a fresh aggregate rebuild over the source tree of development commit 21ca928 on 7 November 2026 with Lean 4.35.0 and the repository's Odin toolchain. Each project records its own source, artifact and corpus identities. Validation/traversal rows, whole-parser fast/slow comparisons, ordinary-key translator fixtures and actual Odin correspondence remain tests where the individual documentation says so; their presence does not extend the formal proof claims.

## Run the proof projects

Use the pinned Lean 4.35.0 toolchain, Odin and Python 3.11 or newer. The [bitfield instructions](bitfield/README.md#run) describe obtaining the official compiler without a global installation. The effects project also needs the existing release Lua and diagnostics native archives prepared by the [normal dependency build](../docs/build-run-test.md#build); its verifier reads those inputs without rebuilding them. These projects use Lean core and Std; they do not add a server build or runtime dependency.

From the repository root:

```sh
LEAN_BIN_DIR=/absolute/path/lean-4.35.0-linux/bin python3 -I proofs/verify.py --odin /absolute/path/odin
```

The aggregate runner verifies projects sequentially: `storage`, `effects`, `encoding`, `bitfield` and then `vector`. `--odin` puts the named compiler first on the `PATH` every project uses and is passed to the vector verifier, which otherwise finds Odin through `ODIN`, `PATH` or `~/odin/current/odin`. Use `--clean` for a fresh rebuild, `--project storage` or `--project bitfield vector` to select projects, `--list` to show the grouping and `--output /absolute/path` to select an artifact directory. Default artifacts remain under ignored `proofs/.build/phase-one/`, with a separate project log and receipt plus an aggregate receipt. The aggregate receipt is produced only after every selected project succeeds and its theorem assumptions, source fingerprints, per-area evidence and executable identities pass validation. The first-phase projects report numbered items and need comparison rows in every area. The vector project reports the named areas `projection`, `quantisation`, `heaps`, `visited`, `graph`, `arena` and `filter`; `filter` is proof only and must report zero comparison rows, and every other area must report some. The aggregate receipt lists the numbered items under `items` and the named areas under `areas`.

## Vector packages

The vector project contains 159 named contract theorems and 1,239 kernel-checked theorems. Its comparison rows run the Lean model and the actual imported `vmath` and `hnsw` procedures on one deterministic case file and check both against independent Python expectations.

| Area | Named theorems | Actual Odin comparison evidence |
| --- | --- | --- |
| Hadamard projection | 11 | 42 shapes, 36 accepted and 6 rejected, with 1,112,330 stored entries and 97,060 Gram entries; 24 accepted inputs are not powers of two and 15 shapes are not orthogonal |
| Quantisation, binary encoding and scores | 35 | 474 quantised vectors, 36 of them with an overflowing scale, 51 encoded vectors, 1,059 rounding cases including both infinities and NaN, 228 binary encodings, 228 Hamming pairs and 12 raw-word pairs, three of them with dirty padding |
| Candidate heaps | 14 | 8,014 min and max heap operations, with the whole array compared after each |
| Visited set | 16 | 15,188 operations in 43 sessions across 36 epoch wraps, six of them after 255 consecutive searches |
| Graph links, link encoding and twins | 61 | 76 sort rows, 11 width rows and 4,212 index operations in 64 sessions: 2,168 inserts, 812 of them twins, 230 twin removals, 149 promotions, 651 plain removals, 375 searches and 120 re-encodings, with 268 evictions, 100 adoptions and 172 relinks |
| Arena free list | 16 | 59 `live_norm` rows and 591 arena operations in 14 sessions, with 8 double frees, 32 invalid slots and 47 rejected norms |
| Filter programs | 6 | None; proof only |

The proofs establish that the Hadamard rows are orthogonal exactly when the row count is at most the largest power of two dividing the input dimension, so accepted non-power-of-two inputs can give non-orthogonal rows; that the int8 quantiser reconstructs within `range / 254` whenever its scale is finite, and stores all-zero codes, so a reconstruction error up to `range`, when `127 / range` overflows f32 as it does for every subnormal-only input; that the binary Hamming bound and the score range rest on the padding condition that `bin_padding_clear` checks exactly; that a live arena norm never has bit 31 set, so a free entry is never mistaken for a live slot, that `arena_free` rejects double frees and invalid slots, and that the free list is acyclic and ends at its terminator; that the heaps keep their order and return the extreme candidate; that the one-byte visited stamps report exactly the slots marked since the last begin, with the stamp array cleared every 255 searches; that insertion, eviction with adoption, removal and repair keep links two-way, duplicate free, within `M` and `2M` and free of self links and of the removed node, that no eviction leaves its victim without a link, and that searching every layer before linking builds the same graph; that re-encoding the links at a wider width leaves the adjacency unchanged; that the twin chains are acyclic, start at their head node, end at `NONE`, keep `next(prev(t)) = t`, the twin and live counts and a node entry at the top level, and that insert, remove and the attach, detach and promote steps keep these invariants together with graph well-formedness; and that a compiled filter reading a missing field evaluates to false while constant folding agrees with run-time evaluation. The [project documentation](vector/README.md) states the models, assumptions and the cases outside the proofs.

From the repository root:

```sh
python3 -I proofs/vector/verify.py --lean-bin /absolute/path/lean-4.35.0-linux/bin --odin /absolute/path/odin
```

`LEAN_BIN_DIR` and `ODIN` may replace the two options. Artifacts and `receipt.json` default to ignored `proofs/vector/.build/`; through the aggregate runner they go to `proofs/.build/phase-one/vector/`. These checks passed on 6 November 2026 with Lean 4.35.0 and Odin dev-2026-10-nightly:84bc3fc against the sources pinned in [source-sha256.json](vector/source-sha256.json).

## Audit coverage

The shared [audit runner](kernel_audit.py) uses [Lean's loaded environment](KernelAudit.lean) to inspect declarations by their source module. It recursively builds and imports every project Lean module, including `Main`, and checks the dependency closure of every project-origin declaration against `propext`, `Classical.choice` and `Quot.sound`. Project axioms, admitted proofs and native-evaluation proof axioms are rejected, including declarations outside the usual namespace or absent from the printed contract manifest. Private and generated declarations are included. A module that cannot be inventoried stops verification.

The printed contract manifest names the mathematical results used in each area's evidence. Receipts distinguish those named theorems from the larger kernel theorem inventory, which also includes generated results. `kernel-inventory.json` records module, source, compiled-artifact and audit-tool identities; the aggregate runner checks that inventory and its agreement with the named manifest. Source text layout is not used to decide which declarations require dependency checks.

Formal proofs apply to the Lean definitions. Actual Odin comparisons provide finite evidence of correspondence. The project documents distinguish proved properties from tested behavior and do not establish a verified translation of the Odin executable. Memory accounting concerns charged, reserved or requested bytes, with the pool ledger, table bytes and key cells described by the storage project; it does not measure process RSS or bytes per stored key. Performance benefits require separate implementation changes and measurements.
