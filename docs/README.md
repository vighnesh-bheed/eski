# Eski documentation

Eski is a single-node in-memory engine with an Odin host and embedded Lua 5.1.5 C runtime. RESP clients can use its implemented command surface, and an optional second listener speaks the memcached text protocol. Lua scripts, executable Function libraries and interactive debugging are implemented. The [verification record](build-run-test.md#verification) describes executed checks, exclusions and resource limits. Modules, replication, Sentinel and Cluster remain excluded.

Start with [build, run and test](build-run-test.md) and [architecture](architecture.md). Use the [generated command reference](commands.md) for the current registry and argument metadata, [conformance](conformance.md) for recorded coverage and differences, and [benchmarks](benchmarks.md) for measured workloads and methodology.

## Data and commands

| Topic | Page |
| --- | --- |
| String values, numeric operations, matching and sorting | [Strings and keys](strings-and-keys.md) |
| Databases, key lifecycle, expiry and scans | [Keyspace](keyspace.md) |
| Hash fields, scans and field expiry | [Hashes](hashes.md) |
| Lists, movement and blocking pops | [Lists](lists.md) |
| Set membership, algebra and sampling | [Sets](sets.md) |
| Sorted sets and geospatial searches | [Sorted sets and geo](sorted-sets-and-geo.md) |
| Bit operations and probabilistic cardinality | [Bitmaps and HyperLogLog](bitmaps-and-hyperloglog.md) |
| Stream records and consumer groups | [Streams](streams.md) |
| Subscription delivery, notifications and cache invalidation | [Pub/sub, notifications and tracking](pubsub-notifications-tracking.md) |
| Queued transactions, watches and blocked clients | [Transactions](transactions.md) |
| Lua scripts, Function libraries, debugging and cancellation | [Scripting](scripting.md) |

## Running the engine

| Topic | Page |
| --- | --- |
| RESP, connections and client controls | [Connections and protocol](connections-and-protocol.md) |
| Optional datatype workers and LCS compute workers | [Threading](threading.md) |
| Configuration, introspection, memory limits and eviction | [Server management](server.md) |
| Users, selectors, key patterns and authentication | [ACL](acl.md) |
| Snapshots, append-only files and payload transfer | [Persistence](persistence.md) |
| Shared-keyspace text endpoint | [Memcached](memcached.md) |

The [roadmap](../ROADMAP.md) states the verification conditions and the work still ahead. The optional [formal verification projects](../proofs/README.md) group selected storage, command-state, parser, codec and arithmetic properties in separate Lean models, with comparisons against the Odin implementation. Separate [scheduling and lifecycle checks](../verification/README.md) explore bounded concurrency models and exercise targeted release and instrumented runtime paths. Performance tables describe the committed run, with its exclusions and client limits; conformance baseline success means its recorded passing tests were preserved. Neither result is an unrestricted compatibility or deployment-safety claim.

The default-disabled keyspace pool executes eligible commands across all datatype families, with atomic multi-key scheduling and ordered coordinator effects. AOF, WATCH, tracking, notifications, MONITOR and memory policies have dedicated integration checks; blocked keys, Memcached metadata, pressure and global commands retain explicit coordinator boundaries. See the [threading coverage matrix](threading.md#keyspace-correctness-checks). Expanded keyspace performance benchmarking is deferred; historical LCS results are separate. Lua and full single-node compatibility qualification remain separate ongoing work described in [scripting](scripting.md#verification) and [conformance](conformance.md).

Eski is licensed under [Apache-2.0](../LICENSE). Third-party components retain their own terms; see [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
