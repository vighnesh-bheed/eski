# Scheduling and lifecycle verification

Areas 7 and 8 complement the [Lean model contracts](../proofs/README.md) with bounded exhaustive state exploration and targeted checks of actual Odin code.

| Area | Project | Main checks |
| --- | --- | --- |
| 7. Worker scheduling | [Scheduling](scheduling/README.md) | Conflicting record ownership, accepted order, publication, rollback/retry and writes after disconnect |
| 8. Fork and shutdown | [Lifecycle](lifecycle/README.md) | Reconciliation, park versus join, active callbacks, fork snapshots, child reset and logger teardown |

## Run

From the repository root, with the existing Odin/clang toolchain and prepared native dependencies:

```sh
python3 -I verification/verify.py --server /absolute/path/to/qualified/eski
```

Add `--tsan-server /absolute/path/to/qualified/eski-tsan` for the targeted server checks under ThreadSanitizer. The scheduling project always builds its small instrumented harness and requires its deliberate race control to demonstrate working instrumentation. Supplied server executables and runtime source must match the explicitly pinned qualified checkpoint; these checks stop on drift instead of silently testing another build.

The aggregate runs each area sequentially, validates complete exploration, invariant inventories, mutation witnesses, source/tool identities and actual check outcomes, and writes a success receipt only after all selected areas pass. Use `--area scheduling` or `--area lifecycle` for one area, `--list` to show the grouping and `--output /absolute/path` for a dedicated artifact directory. Default outputs stay under ignored `verification/.build/areas-seven-eight/`. Compiler and runtime probes share repository locks and use owned temporary data and processes.

The individual READMEs state exact bounds, source-to-model mappings and tested paths. Exhaustion covers every reachable state of those finite models, including their declared input scenarios. It does not prove the model is a formal refinement of the executable, cover arbitrary job counts, establish universal weak-memory safety or show that every operating-system call succeeds. Progress assumptions and environmental stuttering are explicit. Deliberately broken model rules must produce replayable counterexamples; exploration caps cannot count as success.

Performance analysis and benchmarking, area 10, remain a separate stage. These checks make no speed or memory-efficiency claim.
