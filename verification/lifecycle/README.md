# Fork and shutdown lifecycle verification

This optional area eight gate exhaustively explores two finite lifecycle abstractions and runs focused checks against the actual Odin procedures and the qualified release server. It establishes bounded transition properties and tested implementation agreement. It does not prove the executable or unrestricted concurrent execution.

Run from the repository root with the existing Odin and clang toolchains and native release build inputs:

```sh
python3 -I verification/lifecycle/verify.py --output /tmp/eski-lifecycle-check
```

`--output` must be absolute. `--server` selects an existing release executable; its bytes must match the qualified checkpoint. `--tsan-server` optionally runs the same three owned server fixtures on the source-matched qualified instrumented artifact. The aggregate race-check gate supplies independent instrumentation controls. This verifier uses no suppressions, downloads, containers, global installation or performance workloads. Real compilation and runtime checks share `verification/check.lock` beneath the build directory with area seven; compilation additionally acquires the existing compiler lock. Odin runs with two compiler threads, vet and strict style; commands use nice 10 and one allowed CPU.

The verifier removes its previous success receipt before checking inputs. Runtime source drift, executable drift, missing native inputs, failed checks, a surviving mutant, a cap, or an unexpected deadlock fails the gate. Success is written only after fresh model and runtime checks complete. The receipt contains source, helper, tool, native input and executable hashes, transition and invariant coverage, terminal counts, declared bounds, replayed counterexamples and actual outcomes.

## Source correspondence

| Actual source | Abstract boundary and exercised behavior |
| --- | --- |
| `src/keyspace/pool.odin` | Admission closure, accepted jobs, running work, parked threads, pause, stop wakeup, worker leave callbacks, actual join, restart and destruction |
| `src/keyspace_integration.odin` | The fence pauses workers, collects completions, reconciles records and publishes ordered effects before `keyspace_before_fork` stops and joins the pool |
| `src/compute/pool.odin`, `src/compute_integration.odin` | Stop drains accepted computation and joins callback lifetimes before fork or resource release |
| `src/lazyfree.odin` | `lazy_jobs` covers queued and active callbacks through their final side effects; Release decrement and Acquire drain; child eventfd, queue, counter and dead-thread reset |
| `src/aof.odin` | Separate all-kind BIO queued plus active count, including close and unlink; Release completion and Acquire drain; child thread and queue reset; rewrite fork barriers |
| `src/runtime_fork.odin` | Legacy drains, exact prior signal mask capture, blocking SIGALRM, ordinary libc fork and registered hooks, child reset, mask restoration in both processes and on fork error |
| `src/diagnostics.odin`, `src/diagnostics_native/diagnostics.c` | Child main TID and timer/report state reset; diagnostic worker lifetimes and signal-mask assumptions |
| `src/runtime_operations.odin` | Both legacy services drain before syslog-open mutation, closelog and borrowed ident destruction |
| `src/cmd_persist.odin`, `src/lua_debug.odin`, `src/config.odin`, `src/main.odin` | Persistence/debugger fork callers, shutdown joins and early-startup/daemon lifecycle context |

The source manifest pins these files, and the repository source digest pins the full qualified runtime inputs. The release checkpoint has source SHA-256 `9f9d5e5f8f79a74747a4da5a9c3c528892f9d2a974fc25a76b1171453ef7335d` and executable SHA-256 `6296faf2f8b6f0c2cd52dbafc1b2af15bb5f7b516590d261e07caff462459a0d`.

## Finite state spaces

The pool model enumerates one or two workers, zero through two possible accepted mutations, one fork, failed fork, or shutdown, and four prior signal-mask classes. Its 72 parameter scenarios include every reachable state and outgoing progress transition from open admission. Worker states distinguish idle, executing, parked after admission closure, exited after the leave callback, and joined. The source also calls ordinary open-admission condition waiting parked; the abstraction folds that wait into idle and reserves its parked marker for the pause acknowledgement. Each job distinguishes unaccepted, queued, running, completed, reconciled and effects published. Disconnect remains independent of the accepted job and cannot cancel its mutation. A snapshot includes every accepted mutation only after coordinator reconciliation and effect publication. Parent resume, independent child reset, libc hooks and exact saved-mask restoration are explicit transitions.

The separate legacy model enumerates one possible job in each of lazyfree and BIO, with unaccepted, queued, active and completed stages. Callback logging/effects precede completion publication. Closing producer admission does not discard accepted jobs. Logger flag, ident and resource teardown requires both queues and active callbacks to drain. The model includes the previously faulty class where the queue is empty while an active callback still owns logger access.

The combined baseline currently has 73 scenarios, 8,038 states and 16,487 edges. Those totals sum distinct parameter spaces, including repeated mask classes for shutdown; they are not unique machine executions. Each state checks the relevant independent invariants, and the receipt counts each check. Every reachable state must have a terminal path. The progress graph must also be acyclic, with no unexpected nonterminal deadlocks. Coordinator wait states are counted separately. Waiting and scheduler stuttering are not progress edges; starvation and nonterminating callbacks remain possible outside the fair bounded scenario.

The invariants require joined callback lifetimes before freeing pool resources, no fork snapshot with live mutable worker owners, accepted mutations and their effects in the snapshot, libc atfork processing, fresh child TID/dead-thread state, exact parent/child mask restoration, parent resource ownership on resume, and all accepted shutdown effects before resource teardown. Park alone never proves callback lifetime termination.

State and time caps are enforced per scenario. Reaching either cap fails rather than pruning or reporting exhaustive success. The explorer uses no random sampling, symmetry reduction or hidden state filtering. Model transitions assume mutex publication, real joins and the actual Release/Acquire completion edges. They do not establish a universal weak-memory or race-freedom result. Parent and child reset/restore are serialized abstract phases; the model assumes fork provides separate copy-on-write address spaces and the established libc atfork context. It does not enumerate concurrent post-fork parent/child instructions, libc internals or inherited allocator/lock implementations.

The same explorer must reject and replay seven mutants: free resources while merely parked, ignore active legacy callbacks, fork before joining, fork before coordinator reconciliation, retain wrong child thread state, restore the wrong child mask, and replace libc fork with a raw-clone abstraction that omits registered hooks. Each receipt includes the initial state, transition labels, successor states and independently violated invariant. Mutation rejection is evidence of sensitivity to those omissions, not proof of model completeness.

## New implementation checks

`bridge.odin` builds in a private source overlay. All original runtime procedures remain byte-for-byte present. Only application main and existing top-level tests are omitted; the focused main is added, and small observation adapters are appended to the original lazyfree and AOF files to inspect file-private state. The verifier validates every overlay file against that exact transformation and records every hash. Imported keyspace and compute packages are the actual source packages.

The pool fixture submits a real Set, pauses and checks the published value and retained completion, proves callback leave has not occurred while parked, resumes without restarting callbacks, stops and observes matched enter/leave counts after actual joins, restarts the stopped pool with the same eventfd, then destroys only after releasing owned objects. A separate actual compute fixture drains two accepted jobs and joins before destruction.

The logger fixture holds an actual lazyfree release callback behind an atomic gate. It observes queue length zero with pending count one, starts actual operations shutdown and checks that teardown has not returned while the callback is blocked. It then releases the callback, joins shutdown and verifies the recorded callback log precedes the sole CLOSE and ident release. The timing observation is a controlled schedule; the source Release/Acquire edge supplies the ordering argument.

The fork fixture starts actual legacy services, registers real pthread atfork hooks, and invokes actual `runtime_fork` four times for alarm-blocked/unblocked and unrelated-signal-blocked/unblocked masks. Hooks observe the alarm blocked during fork. Each child checks exact saved-mask restoration, its new main TID, reset timer/report fields, cleared queues/counters/dead-thread pointers and closed lazyfree eventfd state. Each parent retains its own live service handles and diagnostic state. Every child is explicitly waited for and must exit zero.

Three bounded loopback server nodes exercise the release executable: eight real keyspace-worker mutations followed by BGSAVE, a later parent mutation after fork and successful worker resume, a clean reload that contains all eight pre-fork values and excludes the later parent value, and a lazyfree UNLINK plus SHUTDOWN pipeline with an actual background startup warning. A recording shim built from the existing test source captures syslog locally; the warning must precede the sole final CLOSE. Owned subprocesses are always cleaned up. Previous qualification results identify the artifacts but do not substitute for these fresh target executions.

The bridge does not exercise the complete server coordinator fence; the real snapshot fixture covers that composition for its finite inputs. The model abstracts one owner per mutation; multi-owner scheduling belongs to area seven. Fork failure is modeled but not injected into libc. Actual OOM, arbitrary syscall failure, infinite queues, unbounded jobs, machine-code refinement, full persistence durability and universal race safety remain outside this gate.
