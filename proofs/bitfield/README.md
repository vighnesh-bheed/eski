# Optional BITFIELD proof pilot

This standalone Lean 4 project checks properties of an explicit model of Eski's BITFIELD arithmetic and change counting. It also compares the executable Lean model and actual Odin bitmap package with independent Python integer and bit-at-a-time expectations. The server build has no Lean dependency.

There is no verified translation from Odin to Lean. The theorems establish properties of the Lean definitions; the executable comparisons supply finite evidence about the current Odin implementation. A passing bridge and a matching source fingerprint do not prove equivalence between the implementation and the model.

## Run

Requirements are Python 3.11 or newer, the repository's Odin toolchain, and the official Lean **4.35.0** Linux x86-64 toolchain including Lake. The package uses Lean core and Std, with no downloaded Lean packages or mathlib. The version is pinned in [lean-toolchain](lean-toolchain).

With Lean and Lake already on PATH, run from the repository root:

```sh
python3 proofs/bitfield/verify.py
```

For an unpacked local toolchain:

```sh
LEAN_BIN_DIR=/absolute/path/lean-4.35.0-linux/bin python3 proofs/bitfield/verify.py
```

The verifier builds the Lean library and executable, prints and checks every theorem's axiom dependencies, builds the actual Odin bridge with vet and strict style, checks source fingerprints, runs the deterministic corpus, and requires rejection of controlled bad dirty counts, bytes, and replies. It uses nice level 10, one allowed CPU on Linux, one Lean runtime thread, and Odin's `-thread-count:2`. It starts no server, changes no installed executable, and runs no performance benchmark or full server suite.

Builds, generated traces, axiom output, actual results and `receipt.json` stay in ignored `.lake/` and `.build/` directories beneath this package. An alternative receipt/output directory can be selected with `--output /absolute/path`.

To acquire the pinned compiler without a global install, download and unpack the official release into a directory of your choice:

```sh
curl -fL https://github.com/leanprover/lean4/releases/download/v4.35.0/lean-4.35.0-linux.tar.zst -o lean-4.35.0-linux.tar.zst
printf '%s  %s\n' 7289597a44543246c9227b8cae501767e095ce17f6d448b95fc4a8dc97268f6d lean-4.35.0-linux.tar.zst | sha256sum -c -
tar --zstd -xf lean-4.35.0-linux.tar.zst
```

The official [release](https://github.com/leanprover/lean4/releases/tag/v4.35.0) and [release API metadata](https://api.github.com/repos/leanprover/lean4/releases/tags/v4.35.0) identify the 594,481,375-byte asset and its SHA-256 digest. Keep the compiler distribution's copyright and license files with it. The compiler is an external development dependency; this project does not vendor or redistribute it.

## Definitions and checked properties

[Arithmetic.lean](Bitfield/Arithmetic.lean) separates 64-bit word addition, truncation and signed interpretation from mathematical remainder, overflow direction and clamp specifications. [State.lean](Bitfield/State.lean) models big-endian byte windows, field reads/writes, overflow handling, replies, initial buffer growth and sequential execution. [Bitfield.lean](Bitfield.lean) contains the complete axiom audit manifest.

| Odin behavior | Lean definitions and theorem families | Domain and limits |
| --- | --- | --- |
| `unsigned_wrap`, `signed_wrap` | `word`, `wrapBits`; `narrow_word`, `wrap_refines`, `unsigned_wrap_modular`, `signed_wrap_modular`, wrap range theorems | 64-bit addition followed by field truncation equals unbounded integer addition modulo the field width. Signed specification uses balanced remainder `Int.bmod`; unsigned uses Euclidean remainder. Refinement assumes width at most 64; external types are u1..u63 and i1..i64. |
| Unsigned overflow checks and SAT | `unsignedDirection`, `directionSpec`, `unsigned_direction_refines`, `unsigned_sat_clamps` | Nonnegative base value, with either a canonical field value or zero increment. This covers canonical INCRBY and unsigned SET after reinterpretation as u64. |
| Narrow signed checks and SAT | `machineSigned`, `signedNarrowDirection`, `narrow_direction_refines`, `narrow_sat_clamps`, `narrow_headroom`, `narrow_incr_sat_clamps` | Mathematical clamp holds when both headroom differences fit i64. Width-derived headroom proves this for canonical i1..i63 INCRBY values. Arbitrary signed SET arguments need the stated headroom preconditions. |
| i64 signed checks and SAT | `signedWideDirection`, `wide_direction_refines`, `wide_sat_clamps` | Both operands are i64. The separate sign-guard proof includes min/max operands and mathematical sums outside i64. |
| FAIL rejection and preservation | `nextValue`, `finish`, `applyOp`; `fail_rejects_direction`, unsigned/narrow/wide FAIL refinements, `finish_failure_preserves`, `apply_failure_preserves` | An out-of-range INCRBY target yields no value, a null reply, no field write and no count. The program has already grown its buffer before applying operations; failure can therefore leave a longer zero-filled buffer. |
| Mutation/change count | `mask`, `changedWord`, `counted`; `mask_as_allOnes`, `mask_truncates`, `masked_xor_refines`, `counted_refines`, unchanged/grown theorems | The masked XOR predicate is equivalent to inequality of the stored low bits. A successful operation counts if those bits change or the whole program grew its buffer, including unchanged writes during growth. Failed writes and reads do not count. |
| Reads and sequential operations | `applyOp`, `runOps`, `execute`; `reads_preserve`, `runOps_append`, `all_reads_no_changes` | Reads preserve bytes and contribute zero changes. Sequential operations see preceding writes; change counts add. `runOps_append` retains the same per-program `grown` flag, whereas each separate `execute` recomputes growth. |

Proofs use kernel-checked rewriting, arithmetic reasoning, bit extensionality and ordinary `decide` for the finite width/mask facts. There are no admitted proofs or custom axioms. The verification command rejects any theorem dependency outside Lean's standard `propext`, `Classical.choice` and `Quot.sound`, including `sorryAx` and native-evaluation proof axioms. A successful Lean compilation alone is not the axiom audit.

## Compatibility exception

Signed SET with SAT is not mathematical clamp for every i64 argument. The existing implementation and existing tests intentionally preserve a wrapped-headroom behavior. For example, SET i8 with `-9223372036854775808` saturates to **127**, while mathematical clamp gives **-128**. `signed_set_sat_exception` checks this concrete counterexample in the Lean kernel. The bridge includes it and the adjacent transition values. No theorem claims unrestricted signed SET SAT equals clamp.

Unsigned SET first reinterprets its signed i64 argument as u64. Thus an unsigned negative SET argument can saturate upward; this differs from clamping the signed argument directly.

## Executable bridge and evidence boundary

[bridge.odin](bridge.odin) imports the actual bitmap package and calls `bitfield_execute`. [Main.lean](Main.lean) executes the Lean model against the same operation protocol. [verify.py](verify.py) computes expected values with Python unbounded arithmetic, constructs and reads each field one bit at a time, and compares the entire output buffer, every reply and the exact change count after each program. It does not obtain expected results from either executable or from the existing Odin reference model.

The deterministic seed `0xE5A1B17` generates **49,629 programs and 100,155 operations**: all 127 valid signed/unsigned widths, all eight bit alignments, WRAP/SAT/FAIL, signed i64 extrema, overflowing sums, SET, INCRBY, GET, partial byte windows and zero-filled reads beyond the end. Explicit and generated sequences include repeated writes, overlapping fields, unchanged values, buffer extension, failed writes that still grow, and reads between mutations. The generated portion has 900 sequential programs. Byte order, optimized extraction/deposit, window paths, growth allocation behavior and executable-to-model agreement are tested rather than formally proved.

The Odin bridge also checks representative invalid widths, invalid integer spellings and i64 parser limits, plus the low-level get/set no-op behavior for widths 0 and 65. These parser checks are tests, not parser proofs. The typed trace protocol accepts offsets only through 4096 and valid i64 arguments; the corpus uses small buffers. It bypasses textual BITFIELD parsing for the main traces.

[source-sha256.json](source-sha256.json) pins the relevant implementation, allocation/byte helpers, parsers, command dirty wiring and existing reference/test files. A change stops verification for review and model reconciliation. Updating a digest does not establish correctness or equivalence.

The pilot does not prove the Odin compiler, executable, pointer/memory safety, allocation failures, arbitrary malformed input, full parser/error compatibility, huge offsets or buffers, offset multiplication, server key creation, expiry, events/WATCH, persistence, concurrent ownership, transport or full-server dirty effects.
