# Roadmap

Eski implements a single-node command surface and verifies it through package tests, differential harnesses, smoke comparisons and an upstream-suite baseline gate. The generated [conformance report](docs/conformance.md) records the expanded suite and the preserved historical baseline. An implemented group remains subject to that evidence; it does not imply that every selected upstream test passes.

## Command-group milestones

| Group | Delivered scope and verification condition |
| --- | --- |
| Strings and keys | String writes, reads, ranges, numeric operations and lifecycle commands are implemented; completion requires the `type/string`, `type/incr` and `keyspace` units, the string tests and smoke comparisons to agree on the supported behaviour. See [strings](docs/strings-and-keys.md) and [keyspace](docs/keyspace.md). |
| Hashes | Field operations, scans, sampling and field expiry are implemented; completion requires `type/hash` and `type/hash-field-expire`, package tests and the native hash comparison to preserve replies and stored data. See [hashes](docs/hashes.md). |
| Lists | Mutation, movement and blocking pops are implemented; completion requires `type/list`, `type/list-2`, `type/list-3`, blocking tests and native comparison, including the mutation-counter cases recorded by the historical suite. See [lists](docs/lists.md). |
| Sets | Membership, sampling, algebra and codecs are implemented; completion requires `type/set`, package/storage tests and native comparisons over each representation. See [sets](docs/sets.md). |
| Sorted sets | Ranked/score/lexical ranges, algebra, sampling and blocking pops are implemented; completion requires `type/zset`, numerical/storage tests and native comparisons. See [sorted sets](docs/sorted-sets-and-geo.md). |
| Bitmaps and HyperLogLog | Bit operations, fields and probabilistic cardinality are implemented; completion requires `bitops`, `bitfield`, `hyperloglog` and the corresponding native/model checks. See [bitmaps and HLL](docs/bitmaps-and-hyperloglog.md). |
| Geospatial operations | Coordinate storage, distance and radius/shape searches are implemented; completion requires `geo` and the native coordinate/search comparison. See [geo](docs/sorted-sets-and-geo.md#geospatial-operations). |
| Streams | Record storage, trimming, reads and consumer groups are implemented; completion requires `type/stream`, `type/stream-cgroups`, storage/group tests and the stream comparison. See [streams](docs/streams.md). |
| Pub/sub, notifications and tracking | Subscription delivery and local invalidations are implemented; completion requires `pubsub`, `pubsubshard`, `tracking` and channel/output-buffer comparisons for the supported single-node behaviour. See [delivery and tracking](docs/pubsub-notifications-tracking.md). |
| Transactions and blocking | Queuing, watches and wait registries are implemented; completion requires `multi`, the blocking package tests and the supported blocking cases in list, sorted-set and stream checks. See [transactions](docs/transactions.md). |
| Lua scripts and Functions | Lua 5.1.5 EVAL/EVALSHA, read-only variants, source caching, executable Function libraries and interactive debugging are implemented. Dedicated lifecycle, ABI, sanitizer, persistence, ACL, cancellation and observer tests supplement managed upstream checks, with the resource boundary recorded in the scripting guide. See [scripting](docs/scripting.md). |
| Persistence | RDB, append-only files and payload transfer are implemented; completion requires `dump`, persistence/codec tests, restart/corruption checks and the smoke persistence round trips. See [persistence](docs/persistence.md). |
| Server and client management | Configuration, protocol negotiation, introspection and ACL are implemented; completion requires the protocol/auth/ACL/info/introspection units and documented accounting differences to be resolved or scoped explicitly. See [server](docs/server.md), [connections](docs/connections-and-protocol.md) and [ACL](docs/acl.md). |
| Memory limits and eviction | Server/client limits, eviction policies and lazy release are implemented; completion requires `maxmemory`, `memefficiency`, `lazyfree`, ownership tests and bounded-maintenance checks. See [memory management](docs/server.md#memory-and-eviction). |
| Memcached text | A separate text endpoint sharing string values is implemented; completion requires its differential text checks, cross-protocol checks and persistence smoke cases. See [memcached](docs/memcached.md). |

The current implementation resolves the earlier expanded-suite differences in list mutation counters, query-buffer resizing/accounting, pause/expiry interactions and introspection. The [verification record](docs/build-run-test.md#verification) describes the executed gates and remaining exclusions. Changes must retain supported reply and persistence behaviour and preserve the existing baseline pass set.

## Next milestone: vector sets

The reference server's version 8 added vector sets as a core data type: elements carry a vector instead of a score, a hierarchical navigable small world index answers similarity queries, three quantisation modes trade memory for recall, a filter expression over per-element JSON attributes narrows results, and similarity queries run on threads. The group is thirteen commands: VADD, VSIM, VREM, VCARD, VDIM, VEMB, VLINKS, VINFO, VSETATTR, VGETATTR, VRANDMEMBER, VISMEMBER and VRANGE.

Eski implements the group from the reference's documentation and from black-box comparison against its container only; the reference's source for this type is not permissively licensed and is never consulted. Permissively licensed libraries used as references are recorded with their notices. The work proceeds in this order: the contract capture, then the vector storage and distance kernels, the index, the filter language, the keyspace type, the commands, persistence with the graph and threaded queries, and finally a recorded recall against throughput comparison on one server core with the same gates and receipts as the command comparison.

| Group | Delivered scope and verification condition |
| --- | --- |
| Vector sets | Planned. Completion requires every captured reply case to match the reference byte for byte in both protocol versions, the reference's vector set test unit to run at run time through the conformance runner with its exclusions listed, package tests under the sanitizer for the kernels, the index and the filter language, snapshot and append-only round trips, and a committed dataset with the recall against throughput curves and bytes per vector. |

## Efficiency work

The first compute-worker stage offloads eligible large LCS calculations over coordinator-owned snapshots. It has bounded jobs/reservations, per-connection order, synchronous transaction/loading/tracked-source fallback and explicit cancellation/fork/shutdown ownership. That stage was qualified separately at `83024e3`; its [threading checks](docs/threading.md#correctness-checks) include deterministic kernel overlap, independent LCS expectations, external-client lifetime/order regressions, sanitizer coverage and a recorded bounded scaling comparison. Workers are opt-in. The existing benchmark tables describe their historical run.

The expanded keyspace pool now runs eligible commands across all datatype families with atomic multi-key scheduling, ordered effects and explicit coordinator barriers. AOF, WATCH, tracking, notifications, MONITOR and memory policies participate through the ownership contracts in the [threading guide](docs/threading.md#keyspace-workers). Per-key blocked/metadata boundaries and actual memory pressure retain coordinator fallback. Datatype, feature and memory integrations have passed whole-node address/thread sanitizer checks. Managed upstream checks add Lua/Functions, transport and persistence coverage. These establish the exercised paths; documented exclusions and two large JSON resource cases remain outside the passing evidence.

Expanded keyspace performance benchmarking is deferred. Historical LCS measurements and earlier conformance snapshots remain evidence for their recorded source. The separate Rust coordination layer does not supply single-process ownership or atomicity guarantees.

Trace and profile the accepted command path with the benchmark harness first. Use the measurements to choose one coherent improvement at a time, with its workload, allocation/memory effect and expected observable change stated before implementation. Compare each improvement against a clean recorded run under the same resource assignments and report the measured ratio for that workload. Keep negative results, client limits and excluded cases visible.

The dedicated-machine container exam follows measured improvements. Its frozen design, CPU assignments, equal memory caps, idle/temperature/power gates, rotated engine order and receipt-verified collection live under `bench/testbed`. The [benchmark documentation](docs/benchmarks.md) explains how the committed report was obtained and how to prepare another run. The roadmap promises no dates or universal performance target.

## Scope boundary

Eski remains a single-node engine. Lua 5.1 scripts, executable Function libraries and interactive debugging are included through an embedded C runtime. Modules, network replication, Sentinel and Cluster remain excluded. WAIT-related replies do not create replica durability. Local transactions, blocking operations and persistence remain part of the engine.

Distributed placement, routing, failover and managed operation belong to a separate coordination layer, planned in Rust. That layer is not implemented in this repository. Keeping this boundary explicit lets the engine's tests and measurements describe one node's actual guarantees.
