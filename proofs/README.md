# Formal verification projects

The first phase groups correctness work for areas 1–6 and 9. Each project pairs an executable Lean model with mathematical specifications, kernel-checked theorems, an axiom audit and comparisons against actual Odin code. The individual project documentation defines the covered contracts, assumptions and remaining obligations.

| Group | Areas | Project |
| --- | --- | --- |
| Storage | 1. Hash-table resizing; 6. Memory accounting | [Storage](storage/README.md) |
| Command state | 2. Worker rollback; 3. Expiry and persistence | [Effects](effects/README.md) |
| Encoding | 4. Request parsing; 5. Packed data codecs | [Encoding](encoding/README.md) |
| Arithmetic | 9. Bit and integer operations | [Bitfields](bitfield/README.md) |

Areas 7 and 8, worker scheduling and fork/shutdown, form a later concurrency and lifecycle verification phase. Area 10 covers performance analysis and measurement; benchmarks remain deferred.

## Recorded coverage

The first phase contains 173 named contract theorems. The complete kernel inventory additionally checks generated declarations. The comparison counts below use different units and should be read by row.

| Area | Named theorems | Actual Odin comparison evidence |
| --- | --- | --- |
| 1. Hash-table resizing | 39 | 9,080 table operations, including partial migration, collisions, deletions and swaps |
| 2. Worker rollback | 18 | Five internal-failure, success and ordinary command-error fixtures |
| 3. Expiry and persistence | 25 | 7,958 hash-operation steps, ten ordinary-key translation fixtures and two exact-deadline fixtures |
| 4. Request parsing | 16 | 1,629 arithmetic guards and 4,042 fragmented-input prefix checks |
| 5. Packed codecs | 26 | 11,376 codec, decode, validation and traversal rows |
| 6. Memory accounting | 14 | 1,539 accounting operations and rollback/ownership checks |
| 9. Bit and integer operations | 35 | 49,629 programs containing 100,155 operations |

These checks passed in a fresh aggregate rebuild with Lean 4.35.0 and the repository's Odin toolchain. Each project records its own source, artifact and corpus identities. Validation/traversal rows, whole-parser fast/slow comparisons, ordinary-key translator fixtures and actual Odin correspondence remain tests where the individual documentation says so; their presence does not extend the formal proof claims.

## Run the first phase

Use the pinned Lean 4.35.0 toolchain, Odin and Python 3.11 or newer. The [bitfield instructions](bitfield/README.md#run) describe obtaining the official compiler without a global installation. The effects project also needs the existing release Lua and diagnostics native archives prepared by the [normal dependency build](../docs/build-run-test.md#build); its verifier reads those inputs without rebuilding them. These projects use Lean core and Std; they do not add a server build or runtime dependency.

From the repository root:

```sh
LEAN_BIN_DIR=/absolute/path/lean-4.35.0-linux/bin python3 -I proofs/verify.py
```

The aggregate runner verifies projects sequentially. Use `--clean` for a fresh rebuild, `--project storage` to select one project, `--list` to show the grouping and `--output /absolute/path` to select an artifact directory. Default artifacts remain under ignored `proofs/.build/phase-one/`, with a separate project log and receipt plus an aggregate receipt. The aggregate receipt is produced only after every selected project succeeds and its theorem assumptions, source fingerprints, per-area evidence and executable identities pass validation.

## Audit coverage

The shared [audit runner](kernel_audit.py) uses [Lean's loaded environment](KernelAudit.lean) to inspect declarations by their source module. It recursively builds and imports every project Lean module, including `Main`, and checks the dependency closure of every project-origin declaration against `propext`, `Classical.choice` and `Quot.sound`. Project axioms, admitted proofs and native-evaluation proof axioms are rejected, including declarations outside the usual namespace or absent from the printed contract manifest. Private and generated declarations are included. A module that cannot be inventoried stops verification.

The printed contract manifest names the mathematical results used in each area's evidence. Receipts distinguish those named theorems from the larger kernel theorem inventory, which also includes generated results. `kernel-inventory.json` records module, source, compiled-artifact and audit-tool identities; the aggregate runner checks that inventory and its agreement with the named manifest. Source text layout is not used to decide which declarations require dependency checks.

Formal proofs apply to the Lean definitions. Actual Odin comparisons provide finite evidence of correspondence. The project documents distinguish proved properties from tested behavior and do not establish a verified translation of the Odin executable. Memory accounting concerns charged or reserved bytes, with the specific ledger described by the storage project; it does not measure process RSS or bytes per stored key. Performance benefits require separate implementation changes and measurements.
