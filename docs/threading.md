# Threading

Eski has two independent, opt-in worker paths: keyspace commands and the compute pool, which runs large LCS calculations and vector set searches. Both are disabled by default. The current keyspace implementation has dedicated datatype, feature, memory-policy and sanitizer checks. The [verification record](build-run-test.md#verification) also covers upstream compatibility, Lua and persistence; each result applies to its executed cases and documented exclusions. Benchmarking of the expanded keyspace path against other servers is deferred; the dated figures below compare two Eski builds on the development machine and make no claim about other servers. Earlier LCS measurements describe the earlier compute stage.

## Keyspace workers

Keyspace workers execute eligible string, list, hash, set, sorted-set, geo, stream, bitmap and HyperLogLog commands. This includes string options and TTL operations, atomic multi-key reads/writes and algebra, nonblocking stream/group operations, and COPY, RENAME, MOVE, DUMP and RESTORE. The coordinator still owns command/ACL admission, sockets, replies, statistics, observers and persistence publication.

Enable workers explicitly, starting with a small count and a budget appropriate to the stored values:

```sh
./bin/eski --bind 127.0.0.1 --port 6399 \
  --keyspace-threads 2 --keyspace-max-memory 128mb
```

| Startup option | Default | Meaning |
| --- | --- | --- |
| `keyspace-threads` | `0` | Worker count, from 0 through 64; zero disables this path. |
| `keyspace-max-memory` | 128 MiB | Budget for admitted worker allocations and reservations; zero forces coordinator execution. |

These settings are immutable after startup and hidden from wildcard CONFIG discovery, including `CONFIG GET '*'` and `CONFIG GET 'keyspace-*'`. Inspect them by exact name with `CONFIG GET keyspace-threads` and `CONFIG GET keyspace-max-memory`. They are independent of LCS `compute-threads` and the compatibility `io-threads` setting. No particular count or budget is a measured performance recommendation.

Measurements with `bench/ab.py` on the development machine on 3 November 2026 compared that day's development build with the reference build of 1 November 2026 by server CPU time per command; [local relative measurement](benchmarks.md#local-relative-measurement) describes the tool. With two keyspace workers and the server on three efficiency cores, GET of 64-byte values at pipeline depth sixteen cost 0.188 of the reference's server CPU per command at 7.6 times its throughput, GET at depth one cost 0.625, and PING cost 0.339. With workers disabled, the seven default workloads of the tool cost 0.73 to 0.88 of the reference. A single outstanding command cannot pipeline, so a lone constant-time string, key or single-field hash command now runs on the coordinator, as described below; an indicative sequential session on 4 November 2026 measured GET and SET of 64-byte values at depth one with two workers at 0.72 and 0.70 of the preceding development build's server CPU per command, about the cost with workers disabled, while depth sixteen stayed within 1 percent. Request-reply clients of the other datatypes still pay the worker hand-off, so the worker mode remains aimed at pipelined or batch clients.

Each database/key identity has an owner. Commands touching multiple owners wait for all required owners and execute once, preserving atomic key changes and owner order. Disjoint owners can execute commands concurrently. A connection can hold up to 16 accepted commands at once, so a pipeline keeps the workers busy instead of waiting for each completion, and a later command of the same connection observes an earlier one through owner order. The connection stops parsing its pipeline at that bound, or while all 64 pool slots hold accepted commands, and resumes as the coordinator publishes completions; a connection with nothing in flight waits in arrival order for a free slot instead of taking a coordinator fallback. Accepting a command does not wake its owner at once: the coordinator records each parked owner it queues work for and signals every such owner once at the end of its event dispatch, again before it sleeps in epoll, and before any barrier, pause, stop, fork preparation, shutdown or other blocking wait, so the commands of one pipeline reach a parked worker in a single wake and no accepted command waits for a signal that is never sent. Only the timing of the wake moves; accepted, owner and reply order are unchanged. A constant-time command that is the last complete request in its connection's read buffer stays on the coordinator while no job is accepted and unpublished: when the pool also owns no records it takes the ordinary command path without a barrier, and otherwise the coordinator runs the prepared worker task itself against the owned records and publishes its reply at once, with a failure taking the same ordered retry as a failed worker job. One outstanding command offers nothing to overlap, so this avoids the thread hand-off without changing accepted, owner or reply order. The constant-time commands are the string and key operations of the classification from GET through PERSIST naming one key, and the hash operations naming one field, meaning an argument count equal to the command's minimum arity, except HGETALL, HKEYS, HVALS, HRANDFIELD and HSCAN; list, set, sorted-set, geo, stream, bitmap, HyperLogLog and key relocation commands, and every command followed by further buffered input, keep using the workers. The coordinator publishes completions, effects and replies in accepted order. A command that is not a worker candidate fences before it runs, and an arity, ACL, memory, persistence or protocol error first drains the connection's accepted commands, so replies leave each socket in request order. An accepted mutation survives client disconnect; delivery is discarded when its original connection no longer exists, and commands still unparsed when the connection is reset or killed are not run.

Workers use independently owned values and datatype clones, not mutable legacy table/slab pointers or socket buffers. The coordinator retains an older database view until reconciliation and finds each owned record through a hash index that doubles in size as records accumulate. Each index slot holds the low 32 bits of the key hash mixed with the database number, the key length and the record, so a lookup compares the slot and then the key bytes, which sit at a fixed offset after the record, without reading the record's other fields; because the database mix multiplies by an odd constant, equal slot hashes for equal key bytes imply the same database. While records are owned, the scan ahead of a pipelined batch also prefetches the index slots and the records of the keys it has already hashed. That scan starts only after a request has been parsed and only when the read buffer holds input after it, so a read holding a single request skips it and takes the ordinary command lookup. Keys longer than 4 GiB stay on the coordinator. A barrier drains accepted work, visits every owned record, imports values and metadata without executing those commands again, then releases their storage and returns the index to its fixed initial table. A barrier with no owned records, accepted jobs, staged completions or retries returns at once without pausing the pool, so commands that stay on the coordinator do not wait on an empty pool. Background fork paths join workers before forking; the parent can start workers again while its child writes the independent snapshot. Loading, script/transaction execution and shutdown retain their explicit lifecycle boundaries.

### Features and coordinator boundaries

| Situation | Execution behavior |
| --- | --- |
| AOF, WATCH, tracking including NOLOOP, notifications and MONITOR | Eligible commands remain worker candidates; the coordinator publishes ordered effects and persistence records. |
| Other connections blocked on keys | Unrelated keys remain worker candidates. A command touching a registered blocked key reconciles and uses existing coordinator wakeup behavior. Blocking commands themselves stay on the coordinator. |
| Memcached endpoint enabled | Ordinary keys remain candidates. Keys carrying Memcached item metadata use the coordinator; Memcached input retains its coordinator barrier. |
| Maxmemory, client limits or LFU configured | Configuration alone does not disable workers. Actual pressure or ongoing eviction takes coordinator execution; LFU access uses captured policy/time and private worker random state. |
| CLIENT PAUSE | Commands already permitted by pause admission can use workers. Expired keys and hashes use the coordinator during the pause to preserve frozen physical expiry. |
| SCAN, KEYS, RANDOMKEY, global operations, EXEC and Lua/functions | Coordinator barriers provide a consistent database view. Transactions and scripts execute atomically with respect to worker commands. |
| Persistence commands and physical storage diagnostics, including OBJECT and MEMORY inspection | Coordinator barriers retain authoritative lifecycle and storage accounting. |
| Loading, a persistence child, a held/subscribed connection or transaction execution | Coordinator execution. Tracking alone does not exclude a connection. |
| Full pool or a connection at its 16-command bound | The connection pauses parsing until publication frees a slot; there is no coordinator fallback and no barrier. |
| A lone constant-time string, key or single-field hash command with nothing else buffered on its connection and no accepted unpublished job | Coordinator execution: the ordinary path when no records are owned, otherwise the worker kernel against the owned records with immediate publication. Pipelined commands and the other datatypes keep using workers. |
| Classification, validation or allocation failure | Coordinator execution or ordered legacy retry after reconciliation. Accepted admission is preserved during retry. |

The pool accepts at most 64 outstanding jobs, including completed results awaiting coordinator reclamation. The coordinator keeps at most 64 accepted commands unpublished and at most 16 of them from one connection, which leaves room for four connections at full pipeline depth and stops one deep pipeline from holding every slot. The pool's Linux thread name is `eski-keyspace`; LCS threads use `eski-compute`. Barriers, serialization and cloned data can make short bursts costly. Thread names, counters and callback wall time do not establish speedup.

### Memory and AOF representation

The worker budget charges requested bytes for records, copied arguments, immutable strings, datatype clones, task/results, temporary reservations and the record index once it outgrows its fixed initial table of 512 slots. An index growth that does not fit the budget takes the same coordinator fallback as a record that does not fit. Conservative undo, decode and serialization reservations can force coordinator fallback even when the final value would fit. Owned records and results remain charged until reclaimed; zero pending jobs does not imply zero pool memory. Coordinator ready and capacity-wait tickets are accounted separately.

This is not a process-RSS limit. Legacy database objects and independent worker objects can coexist, replies can retain overwritten values, and libc or retired allocation services can retain storage after logical release. Database storage, socket buffers, threads and allocator overhead have additional costs. AOF capture also needs an undo copy and immutable postimage before allowing later owner work; snapshot failure restores worker state and retries the original accepted command once through the coordinator.

Plain worker SET commands retain canonical SET records. Worker hash commands publish canonical translated command effects, including individual `HDEL` records for fields actually expired and absolute `HPEXPIREAT` deadlines for successful field-expiry changes and retained HINCRBYFLOAT field deadlines. Collection reads that only filter expired fields do not create expiry deletions. Other eligible commands may use transaction-grouped `RESTORE ... REPLACE ABSTTL` postimages and explicit deletions. The log therefore need not contain the original command spelling or match coordinator AOF bytes. These representations preserve durable values, absolute TTLs and datatype metadata and have independent replay checks. Normal no-op/dirty accounting still controls propagation; an internal allocation change without a durable mutation is not automatically persisted. Keep normal AOF recovery and rewrite procedures from [persistence](persistence.md).

### Observation

`INFO server` adds the fields below. INFO itself reconciles state, so pending counts and pool bytes are observations after that barrier rather than live occupancy. With a label scheme or owner mode, a caller below top reads every field as zero except `keyspace_threads_configured`, whose value it also reads for `keyspace_threads_active`, as for the compute fields.

| Field | Meaning |
| --- | --- |
| `keyspace_threads_configured` | Startup worker count; zero disables this path. |
| `keyspace_threads_active` | Existing worker threads, including parked threads. |
| `keyspace_jobs_pending` | Accepted jobs awaiting coordinator completion handling. |
| `keyspace_memory_used` | Charged pool bytes; excludes separate ticket storage. |
| `keyspace_records` | Owned key records awaiting reconciliation. |
| `keyspace_jobs_submitted` | Cumulative accepted worker requests; excludes commands the coordinator executes itself. |
| `keyspace_jobs_completed` | Handled worker completions, including disconnected clients and retries. |
| `keyspace_gets`, `keyspace_sets` | Successfully completed worker GET and SET requests. |
| `keyspace_sync_fallbacks` | Resource/submission failures and failed accepted jobs sent to legacy retry, including a failed coordinator execution against owned records; not every coordinator-routed command, and not a connection paused by the pool or per-connection bound. |
| `keyspace_inline` | Eligible lone constant-time commands the coordinator executed itself while no job was accepted and unpublished, through the ordinary path or against owned records. |
| `keyspace_barriers` | Reconciliation barriers that encountered owned records or pending jobs. |
| `keyspace_worker_signals` | Wake signals sent to parked workers. Each owner with newly queued work is signalled at most once per signal point, so a pipeline normally costs one signal per owner rather than one per command. |
| `keyspace_worker_nanoseconds` | Sum of worker service wall time, not CPU time. |

Successful deferred command latency includes queueing and coordinator completion delay. These counters help establish admission and cleanup; they do not replace a controlled performance measurement.

## Keyspace correctness checks

The current whole-node datatype driver has 26 cases. The feature driver has 16 cases, with only independent reference-server replay skipped unless an explicit reference port is supplied. Because a lone constant-time command no longer reaches the workers, the worker-mode drivers queue a PING behind each single string, key or hash command they send, which keeps that command on the worker path, and the keyspace driver checks the coordinator path, execution against owned records and the `keyspace_inline` counter directly. Four memory/frontend cases cover configured limits, actual pressure, LFU and Memcached interactions. Dedicated whole-node address/thread sanitizer runs cover these integrations. Native ownership tests additionally exercise FIFO histories, multi-owner scheduling, deferred owner signals, immutable references, capacity, cancellation, restart and allocation reclamation.

| Check | Coverage |
| --- | --- |
| `test/threading/full_keyspace.py` | All datatype families/options, multi-key atomicity, RESP2/3, TTL, cross-database identity, COPY/RENAME/MOVE, DUMP/RESTORE and malformed restore payloads. |
| `test/threading/features.py` | WATCH, tracking/NOLOOP, notifications/monitor ordering, blocked keys, pause/expiry, accepted disconnects, AOF restart, snapshot rollback, pressure/error replay, pipelined retries and reply suppression. |
| `test/compatibility/memory_threading.py` | Under-budget admission, LFU/No-Touch, OOM recovery and Memcached metadata/CAS/flush boundaries. |
| `test/compatibility/hfe_aof.py` | Canonical field-expiry persistence, immediate/lazy deletion, prechecks and database ownership after move/copy/swap. |
| `test/threading/keyspace.py` | Lifecycle, ownership, admission counters, replies, persistence and shared-endpoint boundaries. |
| `src/keyspace` native tests | Ownership, multi-owner ordering, deferred owner signals, bounded storage, cancellation and lifecycle. |

Use an already-built executable; these drivers do not compile it or run benchmarks:

```sh
odin test src/keyspace -debug -vet -strict-style -define:ODIN_TEST_THREADS=1
python3 -I test/threading/full_keyspace.py --server /path/to/eski
python3 -I test/threading/features.py --server /path/to/eski
python3 -I test/compatibility/memory_threading.py --server /path/to/eski
```

The drivers own isolated localhost servers and temporary data directories. `--case 'test_*pattern*'` selects a method glob in the datatype/feature drivers. For independent AOF interoperability, provide an explicitly disposable, empty local reference-server instance:

```sh
python3 -I test/threading/features.py --server /path/to/eski \
  --case '*external_redis*' --reference-port PORT
```

That case requires every reference database to be empty, then replays active RESP AOF files and checks values, absolute TTLs, field expiry, stream pending entries and cross-database state. The reference is modified by replay. Its no-dirty bitmap and passive-expiry checks distinguish intended propagation from byte-for-byte command equivalence.

For whole-node sanitizer checks, first prepare the matching Lua archive as described in [build, run and test](build-run-test.md), build with `-sanitize:address` or `-sanitize:thread`, and pass that executable to the same drivers. No suppressions are required by the recorded whole-node worker checks. Sanitizer success covers exercised paths, not universal race safety. The [verification record](build-run-test.md#verification) separates these checks from the upstream fixture modes, resource limits and historical LCS measurements.

## LCS compute workers

Eski can run the dynamic-programming computation of large LCS requests on worker threads. For the LCS computation, the coordinator owns the live keyspace, sockets, argument checks, ACL, expiry/access updates, transactions, notifications and replies. It provides CPU parallelism between eligible LCS requests from different connections; it remains independent of the keyspace command pool.

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

There are at most 64 outstanding jobs on the pool across queued, running and completed work awaiting coordinator reclamation. The memory setting bounds their reserved snapshot, workspace and task bytes; a job the coordinator computes because the pool cannot take it is outside both bounds, and its bytes belong to its connection, which has at most one job. It is not a process-RSS limit: the database, connection buffers, synchronous commands and allocator overhead have separate accounting.

Freed heap workspaces can remain in libc's allocator arenas after `compute_memory_reserved` returns to zero. The reservation cap bounds admitted live requested regions; it does not bound allocator-retained RSS. Compare reservation counters with process RSS and its high-water mark when assessing the allocation and memory tradeoff.

Small requests run synchronously. Eligible requests also use the synchronous path when execution is inside a transaction or a script or when the source connection has client tracking enabled; tracked sources stay synchronous so a cache invalidation cannot overtake their delayed snapshot reply. When the request would be offloaded and only the state of the whole server prevents it (the queue is full, the job does not fit the reservation limit, the pool is stopped for a fork or did not start, or the server is loading), the coordinator computes it at once but completes it as a job: the reply waits for the next completion pass, a kill or close drops it, and statistics and the slow log entry are recorded then, exactly as for a job a worker finished. Only the request and its connection choose the synchronous path, so a client cannot tell from its replies how busy the pool is. These paths preserve the original LCS results and errors, and can consume coordinator time.

## Completion and lifecycle

The coordinator validates the connection identity and job token before writing a result. Closing or killing a client cancels its pending job; snapshots and workspace remain owned until the worker acknowledges completion. A reused socket descriptor cannot receive the earlier client's result. CLIENT REPLY OFF/SKIP can suppress the normal reply without leaking the job. Keyspace blocking clients use their existing waiter registry and do not occupy compute workers.

MONITOR records an admitted LCS once at admission, in execution order. Command statistics and slowlog handling occur once when the coordinator completes the deferred command. The duration recorded is the job's own work: the accepting command, the computation on a worker or on the coordinator, and writing the reply. Time spent waiting in the queue or while the coordinator serves other connections is not part of it. An already accepted snapshot can finish during CLIENT PAUSE, while later pipelined commands still obey the pause rules. Active computation is distinct from an idle connection.

Before an RDB background save or AOF background rewrite forks, compute admission stops and accepted work finishes; workers are joined before the fork. The parent can resume workers afterward, and the child does not restart them. Shutdown cancels pending work and joins workers before reclaiming their storage. These boundaries can add time to save/rewrite initiation or shutdown; the raw fork timing statistic covers the fork itself. Existing lazy-free and persistence I/O services have their own lifecycle paths.

A first SIGINT or SIGTERM requests orderly coordinator shutdown. A second SIGINT forces immediate process exit with status 1, including when the coordinator is stuck in a command. That forced path bypasses worker joining and temporary-file cleanup, so unfinished snapshot/rewrite files can remain for recovery or removal.

## Runtime observations

`INFO server` exposes the following counters:

| Field | Meaning |
| --- | --- |
| `compute_threads_configured` | Startup worker setting; zero disables offloading. |
| `compute_threads_active` | Currently active compute worker threads; zero while the pool is stopped for a fork. |
| `compute_jobs_pending` | Accepted jobs awaiting coordinator reclamation, including cancelled jobs still owned by workers and jobs the coordinator computed itself. |
| `compute_memory_reserved` | Bytes reserved for outstanding jobs on the pool; returns to zero after reclamation. A job the coordinator computed reserves nothing. |
| `compute_jobs_submitted` | Cumulative accepted jobs, both those handed to a worker and those the coordinator computed and completed as a job. |
| `compute_jobs_completed` | Successful computations handled for a valid connection, including deliberately suppressed replies. |
| `compute_jobs_cancelled` | Cancelled or invalid/disconnected completions reclaimed. |
| `compute_sync_fallbacks` | Eligible requests with workers configured that the coordinator computed, either at once on the synchronous path or as a job the pool could not take. Small requests and disabled mode do not increment it. |
| `compute_worker_nanoseconds` | Sum of callback elapsed durations. This is wall time in workers, not measured CPU time. |

The counters cover `VSIM` and `VADD CAS` jobs as well as LCS. With labels or owners on, a caller below the top label, or without the operator right in owner mode, reads zero for every counter except the configured thread count, because the numbers would otherwise show how much work other scopes have hidden on the pool. Such a caller reads the configured count as `compute_threads_active` too, because the live count drops while a fork that another scope's write or a save point caused is in progress.

The OS thread name is `eski-compute`. Distinct thread IDs and their `/proc` CPU counters distinguish compute activity from socket and background I/O activity. Summed callback durations alone do not prove simultaneous CPU execution.

## Vector search on compute workers

With `compute-threads` above 0, `VSIM` and the search half of `VADD` with `CAS` run on the compute pool beside LCS. The coordinator does everything that touches a connection or the keyspace, in the command's normal place: it parses the command, finds the key (counting the hit or miss and refreshing the key's access time, answering `WRONGTYPE` or an empty reply for a missing key), opens the caller's view of the set when labels or owners are on, builds the query vector, compiles the filter and answers every error at that point. Only a request that passed all of that is handed to a worker. The worker searches the set through copies the coordinator made and a scratch area of its own and records the hits in room the job reserved for them. The coordinator writes the reply from those hits straight into the connection's output when it takes the finished job, records the command's statistics and slow log entry and goes on with the connection's pipeline. A connection has at most one pending job, so its next command waits, and another connection's commands do not. The reply is byte for byte the reply the coordinator would have produced at the same point of the command order, and `NOTHREAD` asks for exactly that.

### What is pinned and what waits

A job pins the vector set it reads. A pinned set cannot change or be freed until the job's reply has been written, so a threaded search, and the names and attributes in its reply, show the set as it was when the command ran. Every command that changes or frees a set therefore settles the pins on it first: `VADD`, `VREM` and `VSETATTR`, deleting the key by `DEL`, `UNLINK`, expiry or eviction, `RENAME` and `MOVE` when they split a set between labels or owners, `OWNERS FORGET`, `LABEL DECLASSIFY`, the flush commands, `DEBUG RELOAD`, loading, and the hand-off of a large set to the lazy-free thread. A job that is still queued is taken out of the queue and searched on the coordinator before the write, so a writer never waits behind unrelated jobs; a job that is running is waited for; and a search that has finished but whose reply is not yet written has its reply written into the job, which keeps it until the job is published as usual. While it waits the coordinator serves nobody else, because a reply published in the meantime would overtake the write. The time a command spends settling other connections' jobs this way is left out of that command's own duration before its statistics, latency samples and slow log entry are recorded, and is counted in the settled job's duration instead. Reads of the set (`VCARD`, `VEMB`, `VLINKS`, `VINFO`, `VRANGE`, `VISMEMBER`, `VRANDMEMBER`, `VGETATTR`, `MEMORY USAGE`, `DUMP` and other searches) change nothing and run beside a job. A fork joins the pool first, which finishes the queued jobs, and the server restarts the workers afterwards while the child never starts any; shutdown cancels what is pending and joins the workers before anything is freed.

### When a search stays on the coordinator

A search runs on the coordinator, by the same procedure and with the same results, in these cases:

| Case | Reason |
| --- | --- |
| `NOTHREAD` is given | The caller asked for it. |
| `vset-force-single-threaded-execution` is `yes` | Both `VSIM` and `VADD CAS` stay on the coordinator. |
| `compute-threads` is 0 | No pool exists, and the commands behave exactly as they did before workers were added. |
| The set has fewer than 64 elements the caller can see | A hand-off costs more than such a search. The number is a constant of the server, `VSET_THREAD_MIN_VISIBLE`. |
| `MULTI` with `EXEC`, a script, a function | They cannot wait for a worker. |
| The command comes from the log's replay or another source without a connection | Replay runs every record inline. |
| The connection has client tracking on | An invalidation must not overtake the search's reply. |

Every row depends only on the command, the connection and the caller's own view; none of them reads anything about other clients' work or data. The size rule counts what the caller's own scope may see: the elements of the key's view for `VSIM`, and for `VADD CAS` the elements of the caller's own partition, never the number of elements the set holds in all. Two servers that differ only in data a reader cannot see therefore make the same choice for that reader.

The state of the whole server never moves a search to the inline path. When 64 jobs are pending, when the job does not fit `compute-max-memory`, while the pool is stopped for a fork or did not start, or while the server loads, a search that the rows above would hand to a worker runs on the coordinator at once and is then completed as a job: a `VSIM` keeps its hits and the pin until its reply is written at the next completion pass, and a `VADD CAS` searches nothing and commits there as the plain `VADD` it is, as a commit whose search was taken back by a writer does. The reply, the moment it is written or committed, its cancellation by a kill, a close or `OWNERS FORGET`, a `CLIENT PAUSE` that holds the commit, the log record, `MONITOR`, the statistics and the slow log entry are then those of a job a worker finished at once, so a client cannot tell from anything it reads whether other clients filled the pool; what remains is how long things take. Such a job is not counted in `compute-max-memory`: its bytes belong to its connection, which has at most one job. `compute_sync_fallbacks` counts both kinds of search the coordinator took; a search that the first four rows keep inline never reaches it.

`vset-force-single-threaded-execution` is read for every command, so `CONFIG SET` changes it at once in both directions. A job that was handed to a worker before the setting was switched on still finishes and, for `CAS`, still commits. Like the other settings the 7.4 server lacks, it is left out of pattern forms of `CONFIG GET` and can be read by exact name.

### VADD with CAS

`VADD ... CAS` is a `VADD` that takes effect when its search has finished. The coordinator checks the request as for a plain `VADD`, copies it and hands the neighbour search to a worker, writing nothing and answering nothing yet; the log, `MONITOR` and the dirty counter do not move at that point. When the job is finished the coordinator runs the whole command again as if the client had just sent it: login and ACL check, label and owner arrival, memory admission and eviction, the write rule, the partition and its quota, the log record, statistics, notifications and `WATCH` invalidation. A refusal at that point is answered and writes nothing, and with labels on a commit whose scope arrival yields differs from the scope the job was accepted under answers `ERR invalid label`. The commit uses the recorded neighbour distances only when the set is the same object with the same version; otherwise it runs as a plain `VADD`, so a write that landed in between costs the saving and never correctness. The reply, the log record (the command as given, so a replay runs it inline and builds the same graph), `MONITOR` and the keyspace effects are those of the `VADD` at the moment of the commit, which is why `MONITOR` shows a `CAS` at its commit and a `VSIM` at its admission, and replaying that order on a server that keeps everything on the coordinator reproduces every reply and the whole dataset.

A commit does not run while a `CLIENT PAUSE` in `WRITE` or `ALL` mode is in force. The finished job waits, its client waits for the reply as for a write sent during the pause, and the held commits run when the pause ends, in the order their searches finished. A threaded `VSIM` is a read and is answered during a `WRITE` pause. Killing the connection of a held commit, or forgetting its owner, drops it; a client that only closed its end keeps the commit, as for any accepted write.

### Cancellation and deferred scope

Closing or killing a client cancels its pending job, and `OWNERS FORGET` closes the connections whose pending job belongs to the forgotten owner. A cancelled job leaves no reply, no statistic, no slow log entry, no log record and no change in the keyspace; its pin, memory and slot return. Every job remembers the label and owner it was accepted under. The statistics and the slow log entry of a finished job are recorded at that scope, so a reader below it never sees the entry of work it could not see, and the entry is not stamped with whoever happened to run last. If the scope can no longer be entered (the label is no longer valid, the owner was forgotten), the reply is still written and no statistic or slow log entry is recorded.

`compute-max-memory` counts every byte a job holds from its submission to its reply, reserved before the job is handed to a worker: the task with its argument, query and filter copies, room for the hits (the smaller of `COUNT` and the number of elements in the partitions the caller can see), the view copy, and for `CAS` the plan with a distance cache of fixed size (twice the smaller of `EF` times `M` and four times the partition's elements, rounded up to a power of two and at most 2^20 entries). A worker allocates nothing else per job: the cache never grows, and when it is full the search stops recording and the commit computes the distances it lacks. Each worker keeps one scratch area for its searches, the same structures the coordinator keeps for its own searches, freed when the worker stops. A reply is formatted on the coordinator into the client's output, where the client output limits and `maxmemory-clients` see it; only a reply that a writer had to settle before the job was published waits in the job, until the end of that turn of the event loop.

## Correctness checks

Build a separate executable to avoid replacing a server under test:

```sh
odin build src -o:speed -out:/tmp/eski-threading
python3 -I test/threading/run.py --server /tmp/eski-threading
python3 -I -m unittest discover -s test/threading -p 'test_*.py'
```

The black-box driver uses isolated localhost ports and temporary data directories. It compares enabled and disabled result modes against independent LCS expectations, then checks argument/ACL behavior, snapshots, pipeline and protocol order, reply suppression, transaction fallback, tracking/monitoring, cancellation, socket reuse, pressure, blocking clients and persistence lifecycle boundaries. Signal regressions require clean SIGTERM/SIGINT exits with workers disabled or busy, and direct those signals to an actual compute thread through libc's `tgkill` when that symbol is available. A separate held-coordinator case requires prompt exact exit 1 after a second SIGINT. Cleanup rejects unexpected nonzero exits or forced kills and includes the server log tail in its failure diagnostic; only that explicitly asserted double-interrupt case accepts status 1. `--case 'test_*snapshot*'` selects a method glob; the whole correctness run has a 180-second limit by default. The package runner discovers this driver and uses `ESKI_THREADING_BIN` when set, otherwise `bin/eski`. It never starts the performance mode or rebuilds that binary.

`test/threading/vsim.py` checks vector searches and `CAS` insertions on the pool and runs against a release, an address sanitizer and a thread sanitizer build with `--compute-threads 0` and `2`. It compares each threaded search with the same search sent with `NOTHREAD` in one pipeline, over every quantisation, with holes and twins, filters, label views and owner views, while other connections write to other sets. It replays the order that `MONITOR` shows for writers and readers on one set on a second server that keeps everything on the coordinator and requires the same reply to every command and the same dataset. It runs random `CAS` streams against a server without workers and against one forced inline. It has one test for each rule of the table above, tests for client kill, `OWNERS FORGET`, `DEL`, `UNLINK`, `FLUSHALL`, `RENAME`, `MOVE`, a snapshot fork, a log rewrite, `DEBUG RELOAD`, `SHUTDOWN` and a termination signal during jobs, for `CLIENT PAUSE`, for the slow log, statistics and replies that a low reader sees with and without hidden deferred work, and for statistics and slow log entries of work done on workers against work done inline. A failing case prints the seed that reproduces it (`--seed`), and its tests wait for events, never for durations. When it is given a thread sanitizer build it also builds and runs the planted race of `verification/scheduling/race_control.odin` and requires the report. The pin protocol has a bounded model, `python3 -I verification/pins/verify.py --output /absolute/path`.

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

## Historical LCS performance comparison

The tool and measurements in this section belong to the earlier LCS compute stage. Expanded keyspace-worker benchmarking is deferred. LCS performance collection is explicitly opt-in through a separate tool. Supply an already-built candidate and a preserved previous release executable. Select separate server, client and controller physical cores from the machine's topology. The example below uses an explicit ordered worker list and separate coordinator CPU; adapt it to the machine rather than copying CPU numbers blindly.

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

The LCS comparison measures snapshot computation and supplies no performance result for the expanded keyspace worker implementation. No distributed control plane is implemented here. See the [roadmap](../ROADMAP.md).

Eski is an independent project, not affiliated with, endorsed or certified by Redis Ltd. Redis is a registered trademark of Redis Ltd.; any rights therein are reserved to Redis Ltd.
