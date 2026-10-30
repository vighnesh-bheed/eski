# Threading

Eski has two separate opt-in worker paths. The earlier LCS compute stage was qualified at `83024e3`. At checkpoint `78eb2f1`, the guarded GET/plain SET keyspace path passed native ownership and external correctness checks, address/thread sanitizers, and the package, smoke and baseline compatibility gates in both worker configurations. Subsequent [Lua integration](scripting.md) is qualified separately and fences worker state before script execution. No keyspace-worker benchmark has been run or speedup claimed; prior LCS measurements remain separate evidence.

## Keyspace workers

This stage targets GET and exactly three-argument `SET key value` on strings without expiry or absent keys. Each key belongs to one worker, which performs its reads and value replacement in FIFO order. The coordinator owns routing, sockets, normal command/ACL admission, statistics and reply delivery. Workers are disabled by default.

The startup settings are `keyspace-threads` (0 through 64, default 0) and `keyspace-max-memory` (default 128 MiB; zero forces coordinator fallback). Both are immutable after startup and hidden from wildcard CONFIG discovery, including `CONFIG GET '*'` and `CONFIG GET 'keyspace-*'`. Exact-name inspection uses `CONFIG GET keyspace-threads` and `CONFIG GET keyspace-max-memory`; CONFIG SET cannot change them. These settings are independent of LCS `compute-threads` and the compatibility `io-threads` setting.

Workers own independent current values while the coordinator retains legacy copies. Each connection waits for its pending operation before executing a later pipeline command. A GET result retains its immutable value until the coordinator copies the reply. An accepted SET continues if its client disconnects; losing the connection discards delivery, not an executed write.

The pool accepts at most 64 outstanding jobs, including completed results awaiting coordinator reclamation. Its Linux worker thread name is `eski-keyspace`, separate from the LCS workers named `eski-compute`. These names describe intended roles; thread names or configured counts alone do not prove simultaneous command execution.

Options such as NX, XX, GET, KEEPTTL and expiry forms are outside this path. Expiring or nonstring entries, entries carrying memcached item metadata, multi-key commands, transactions and the rest of the command surface use the coordinator. Watching/tracking/notifications, blocked consumers, monitors/pubsub, memory-pressure policies, LFU, memcached, AOF, pause/loading and persistence lifecycle state also prevent worker admission. Normal command errors and feature behavior remain the responsibility of the coordinator path, after pending work is reconciled; these fallbacks do not supply parallel execution of those features.

Before a legacy command or feature can observe the keyspace, a barrier freezes admission, drains accepted jobs and reconciles worker-owned values and access metadata. Reconciliation transfers state without executing SET again; GET-only entries retain their encoding. Save/fork/shutdown paths require a reconciled view, and workers join before raw forks or destruction. Dedicated correctness checks exercise these boundaries. Barriers can stall foreground work and erase the benefit of short bursts of eligible commands.

The budget bounds admitted requested bytes for directory records, copied keys, values and task/result storage, including their allocation headers. Owned records and values remain charged between jobs until a barrier reclaims them; zero pending jobs does not imply zero pool memory. Coordinator ready-ticket bookkeeping is accounted separately and sits outside that pool cap. It is not a process-RSS limit. Old legacy copies and current worker values coexist until reconciliation; reply references may retain overwritten values, and libc can retain freed heap allocations afterward. Consequently RSS can grow temporarily and remain elevated after the pool drains. Database storage, socket buffers, thread resources and allocator overhead have their own costs.

`INFO server` adds these observations for the keyspace path. INFO itself takes the legacy barrier, so pending jobs, records and pool bytes describe the post-drain state rather than live occupancy.

| Field | Meaning |
| --- | --- |
| `keyspace_threads_configured` | Startup worker setting; zero disables this path. |
| `keyspace_threads_active` | Existing worker threads, including parked threads. |
| `keyspace_jobs_pending` | Accepted jobs awaiting coordinator completion handling. |
| `keyspace_memory_used` | Charged pool allocation bytes; excludes separate coordinator ready-ticket storage. |
| `keyspace_records` | Owned key records awaiting reconciliation. |
| `keyspace_jobs_submitted` | Cumulative accepted worker requests. |
| `keyspace_jobs_completed` | Cumulative handled worker completions, including clients whose replies cannot be delivered. |
| `keyspace_gets` | Completed worker GET requests. |
| `keyspace_sets` | Completed worker SET requests, including disconnected clients' committed writes. |
| `keyspace_sync_fallbacks` | Candidate requests rejected by record classification, startup, capacity, byte budget or submission after the global eligibility checks; excludes disabled/feature-excluded requests and other command forms. |
| `keyspace_barriers` | Reconciliation barriers that encountered owned records or pending jobs. |
| `keyspace_worker_nanoseconds` | Sum of worker service elapsed durations, measured as wall time rather than CPU time. |

Command latency/statistics include queueing and coordinator completion delay. Distinct worker IDs and measured CPU activity would be needed to establish CPU parallelism; neither counters nor service wall time provide that evidence on their own.

## Keyspace correctness checks

Ten native ownership tests pass in strict debug, ASan with leak detection and TSan. They exercise FIFO histories, immutable GET references across later SETs, bounded outstanding jobs, rejection, allocation/refcount reclamation and pause/stop/restart. The dedicated 20-case external driver passes against release, address-sanitized and thread-sanitized servers.

```sh
odin test src/keyspace -debug -vet -strict-style -define:ODIN_TEST_THREADS=1
python3 -I test/threading/keyspace.py
```

The driver covers binary/empty values, storage boundaries, pipeline/RESP/database order, reply suppression, half-close, disconnected writes, counters, TTL/type/SET-option fallbacks, read-only import and No-Touch behavior. It also checks ACL/renamed commands, transactions/WATCH, tracking/notifications/monitoring, blocking/pause/memory policies, rejected admissions, memcached, RDB saves/forks/reloads and automatic saves, AOF enable/rewrite/restart/disable, and shutdown persistence. It uses isolated localhost servers and temporary data directories. `--server /path/to/eski` selects a binary; otherwise `ESKI_THREADING_BIN` or `bin/eski` is used. `--case 'test_*snapshot*'` selects a method glob. The package runner includes this driver once per run and never starts a benchmark.

At `78eb2f1`, both worker configurations preserved all 1,504 Tcl baseline passes with zero regressions and retained the existing 20 expanded failures. The package gate passed all 90 runs, and smoke passed all 2,428 checks in each configuration. These receipts precede Lua integration. Dedicated passes cover the executed correctness and lifetime checks; they do not establish throughput or universal race safety. Broader worker execution of commands and features remains future work, and distributed management is a separate layer.

## LCS compute workers

Eski can run the dynamic-programming computation of large LCS requests on worker threads. In this earlier stage, the coordinator owns the live keyspace, sockets, argument checks, ACL, expiry/access updates, transactions, notifications and replies. It provides CPU parallelism between eligible LCS requests from different connections; its qualified scope leaves GET, SET and other keyspace commands on the coordinator.

Compute workers are disabled by default. Enable them at startup:

```sh
./bin/eski --bind 127.0.0.1 --port 6399 --compute-threads 2 --compute-max-memory 128mb
```

`compute-threads` accepts 0 through 64; 0 disables offloading. `compute-max-memory` defaults to 128 MiB. Both settings are immutable after startup. `io-threads` is a separate compatibility setting and does not select these compute workers.

Inspect these settings by exact name:

```sh
redis-cli -p 6399 CONFIG GET compute-threads
redis-cli -p 6399 CONFIG GET compute-max-memory
```

They are hidden from wildcard discovery, including `CONFIG GET '*'` and `CONFIG GET 'compute-*'`. Exact-name queries remain available, and CONFIG SET rejects changes even when the requested value equals the current value. The compute INFO counters below remain visible.

## Admission and ownership

An LCS request becomes eligible when its DP table has at least 1,048,576 cells, counting the extra row and column. The coordinator checks both keys and options, copies both input strings and allocates the complete DP/output workspace before submitting a job. Workers read those immutable snapshots and write their private workspace without accessing connections or live database objects. LEN, ordinary string replies, IDX, MINMATCHLEN, WITHMATCHLEN and RESP2/RESP3 retain their existing semantics.

Each connection has at most one pending computation. Its next pipelined command waits until the coordinator handles that completion, so a later SET, SELECT or HELLO cannot overtake LCS. Other connections can continue making progress. Deleting, overwriting or expiring the original keys cannot change the accepted snapshot or free a worker's input storage.

There are at most 64 outstanding jobs across queued, running and completed work awaiting coordinator reclamation. The memory setting bounds their reserved snapshot, workspace and task bytes. It is not a process-RSS limit: the database, connection buffers, synchronous commands and allocator overhead have separate accounting.

Freed heap workspaces can remain in libc's allocator arenas after `compute_memory_reserved` returns to zero. The reservation cap bounds admitted live requested regions; it does not bound allocator-retained RSS. Compare reservation counters with process RSS and its high-water mark when assessing the allocation and memory tradeoff.

Small requests run synchronously. Eligible requests also use the synchronous path when execution is inside a transaction or loading, when the source connection has client tracking enabled, or when pool startup, queue admission or the reservation limit prevents offloading. These fallbacks preserve the original LCS results and errors, and can consume coordinator time. Tracked sources stay synchronous so a cache invalidation cannot overtake their delayed snapshot reply.

## Completion and lifecycle

The coordinator validates the connection identity and job token before writing a result. Closing or killing a client cancels its pending job; snapshots and workspace remain owned until the worker acknowledges completion. A reused socket descriptor cannot receive the earlier client's result. CLIENT REPLY OFF/SKIP can suppress the normal reply without leaking the job. Keyspace blocking clients use their existing waiter registry and do not occupy compute workers.

MONITOR records an admitted LCS once at admission, in execution order. Command statistics and slowlog handling occur once when the coordinator completes the deferred command; its elapsed duration includes queueing and completion delay. An already accepted snapshot can finish during CLIENT PAUSE, while later pipelined commands still obey the pause rules. Active computation is distinct from an idle connection.

Before an RDB background save or AOF background rewrite forks, compute admission stops and accepted work finishes; workers are joined before the fork. The parent can resume workers afterward, and the child does not restart them. Shutdown cancels pending work and joins workers before reclaiming their storage. These boundaries can add time to save/rewrite initiation or shutdown; the raw fork timing statistic covers the fork itself. Existing lazy-free and persistence I/O services have their own lifecycle paths.

A first SIGINT or SIGTERM requests orderly coordinator shutdown. A second SIGINT forces immediate process exit with status 1, including when the coordinator is stuck in a command. That forced path bypasses worker joining and temporary-file cleanup, so unfinished snapshot/rewrite files can remain for recovery or removal.

## Runtime observations

`INFO server` exposes the following counters:

| Field | Meaning |
| --- | --- |
| `compute_threads_configured` | Startup worker setting; zero disables offloading. |
| `compute_threads_active` | Currently active compute worker threads. |
| `compute_jobs_pending` | Accepted jobs awaiting coordinator reclamation, including cancelled jobs still owned by workers. |
| `compute_memory_reserved` | Bytes reserved for outstanding asynchronous jobs; returns to zero after reclamation. |
| `compute_jobs_submitted` | Cumulative accepted asynchronous jobs. |
| `compute_jobs_completed` | Successful computations handled for a valid connection, including deliberately suppressed replies. |
| `compute_jobs_cancelled` | Cancelled or invalid/disconnected completions reclaimed. |
| `compute_sync_fallbacks` | Eligible requests with workers configured that took a synchronous fallback. Small requests and disabled mode do not increment it. |
| `compute_worker_nanoseconds` | Sum of callback elapsed durations. This is wall time in workers, not measured CPU time. |

The OS thread name is `eski-compute`. Distinct thread IDs and their `/proc` CPU counters distinguish compute activity from socket and background I/O activity. Summed callback durations alone do not prove simultaneous CPU execution.

## Correctness checks

Build a separate executable to avoid replacing a server under test:

```sh
odin build src -o:speed -out:/tmp/eski-threading
python3 -I test/threading/run.py --server /tmp/eski-threading
python3 -I -m unittest discover -s test/threading -p 'test_*.py'
```

The black-box driver uses isolated localhost ports and temporary data directories. It compares enabled and disabled result modes against independent LCS expectations, then checks argument/ACL behavior, snapshots, pipeline and protocol order, reply suppression, transaction fallback, tracking/monitoring, cancellation, socket reuse, pressure, blocking clients and persistence lifecycle boundaries. Signal regressions require clean SIGTERM/SIGINT exits with workers disabled or busy, and direct those signals to an actual compute thread through libc's `tgkill` when that symbol is available. A separate held-coordinator case requires prompt exact exit 1 after a second SIGINT. Cleanup rejects unexpected nonzero exits or forced kills and includes the server log tail in its failure diagnostic; only that explicitly asserted double-interrupt case accepts status 1. `--case 'test_*snapshot*'` selects a method glob; the whole correctness run has a 180-second limit by default. The package runner discovers this driver and uses `ESKI_THREADING_BIN` when set, otherwise `bin/eski`. It never starts the performance mode or rebuilds that binary.

The compute package also has native ownership, capacity, cancellation, restart and deterministic worker-overlap tests. Main-package tests cover loading fallback explicitly; an ordinary AOF restart does not replay a read-only LCS request. Run those packages with `odin test src/compute -debug` and `odin test src -debug`. Keep the normal smoke and baseline conformance gates from [build, run and test](build-run-test.md).

Use separate diagnostic builds for thread races and memory lifetime errors:

```sh
odin build src -debug -sanitize:thread -out:/tmp/eski-threading-tsan
python3 -I test/threading/run.py --server /tmp/eski-threading-tsan
odin build src -debug -sanitize:address -out:/tmp/eski-threading-asan
python3 -I test/threading/run.py --server /tmp/eski-threading-asan
```

The compiler's `-thread-count` option controls compilation, independently of the runtime `compute-threads` setting. Diagnostic success supplements the ordering and ownership checks; it does not replace them.

Storage release uses libc-intercepted `munmap` so sanitizers observe the end of a mapping's lifetime before its virtual address is reused. The [storage harness](../test/storage/run.py) includes a mapping-only control that distinguishes shadow history across legal, nonoverlapping mapping lifetimes from accesses that overlap within a live allocation. This lifetime bookkeeping keeps ordinary race detection enabled; it adds no synchronization between otherwise independent storage accesses.

DEBUG SLEEP also uses libc's intercepted sleep boundary so diagnostic runtimes can deliver application signal callbacks while the coordinator is held. The double-interrupt regression retains its prompt-exit deadline under instrumentation.

## Bounded performance comparison

Performance collection is explicitly opt-in through a separate tool. Supply an already-built candidate and a preserved previous release executable. Select separate server, client and controller physical cores from the machine's topology. The example below uses an explicit ordered worker list and separate coordinator CPU; adapt it to the machine rather than copying CPU numbers blindly.

```sh
taskset -c 7 python3 -I test/threading/perf.py \
  --server /tmp/eski-threading --baseline /tmp/eski-before-threading \
  --server-cpus 0,1,2,4,6 --worker-cpus 0,2,4,6 --coordinator-cpu 1 \
  --client-cpus 3,5 --output /tmp/eski-lcs-results \
  --require-parallel
```

`--worker-cpus` and `--coordinator-cpu` are required. Worker IDs preserve their comma-list order and must be distinct from the coordinator and contained in the server CPU set. Server/client sets and the tool's current controller affinity must be disjoint. Linux SMT sibling metadata, when available, also checks physical-core separation across those roles and between workers/coordinator; missing topology entries are recorded. Launch through `taskset` to place the controller before the tool validates roles or creates output.

For LCS, the preserved baseline and zero-worker candidate run their main thread on the first worker CPU. Enabled cases put the main coordinator on the coordinator CPU and pin named compute TIDs, sorted by ID, individually round-robin over the ordered worker list. Background threads use the coordinator CPU. GET runs the main thread on the first worker CPU in every configuration. The tool bootstraps and pins workers before excluded warmup, then verifies their placements before and during timing.

The default experiment runs the baseline and candidate with one, two and four workers. Each configuration gets three rotated repetitions of an eight-connection LCS workload, a one-connection LCS control and a GET64 control. LCS uses fixed 2,048-byte inputs, a known exact LEN result, pipeline 1 and a 256 MiB reservation cap. GET uses eight client processes and pipeline 16 against a preloaded 64-byte value. Each case has five seconds of warmup, fifteen seconds of timing and ten seconds of rest; the complete experiment stops at thirty minutes. CPU temperature telemetry must be available, and the tool stops at its temperature limit without hidden retries.

Add `--workers 0,1,2,4` to include the candidate's disabled compute path as `workers-0`, separately from the preserved `baseline` executable. This compares both paths with the same clients and method and expands the experiment from 36 to 45 cases under the same thirty-minute cap. The default worker list remains `1,2,4`; zero-worker results provide a control and do not count as parallel-execution evidence.

The output directory must be fresh. `results.json` retains binary hashes, settings, topology, per-case results, sampled latencies, exclusions, client CPU utilization and CPU time for each server thread. Per-TID observations record role, requested CPU, actual affinity, last processor, user/system ticks and minor/major faults before, during and after timing. Client/controller placement is retained too. Process `VmRSS`, `VmHWM` and `VmSize` are sampled and expressed in bytes; the high-water mark includes startup, preload and warmup. Affinity drift or changed server thread identities invalidates a case.

CPU policy snapshots include per-CPU `cpuinfo_min_freq`, `cpuinfo_max_freq`, `scaling_min_freq`, `scaling_max_freq` in kHz, plus governor and energy policy before/after timing. Changes invalidate the case; unavailable values are recorded. The tool reads these settings and never changes global frequency limits. Separate physical cores can have different capabilities or caps, so a common broad CPU set alone does not make baseline and worker placement comparable. Matching the baseline and first worker CPU controls that comparison; additional differently capped cores still limit how scaling results can be generalized.

Clients are independent Python processes with explicit affinities; this tool measures these closed-loop workloads, not maximum server capacity. It marks client-limited samples, and its pipelined latencies start at each batch send. Latencies use a bounded uniform sample reservoir per client.

`--require-parallel` requires a valid multi-worker LCS case with positive CPU time in at least two compute thread IDs and summed compute CPU above one core. A multi-worker timed case using synchronous fallback is excluded. Ratios compare matching workloads with the baseline; client limits can distort either measurement, so the ratio is an observed value rather than a lower bound on engine scaling. Summaries keep per-workload medians/ranges and exclusions separate. There is no overall score. The historical [benchmark tables](benchmarks.md) remain a separate experiment.

The LCS comparison measures snapshot computation and supplies no GET/plain SET speedup result. Broader worker execution still requires multi-key scheduling, transaction atomicity and coordinated expiry/eviction/persistence designs. No distributed control plane is implemented here. See the [roadmap](../ROADMAP.md).
