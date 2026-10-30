# Eski documentation

Eski is a single-node in-memory engine written in Odin. Redis protocol clients can use its implemented command surface, and an optional second listener speaks the memcached text protocol. The generated inventory and conformance results describe the tested surface; accepted compatibility settings or registered stubs do not imply a replication, scripting or cluster implementation.

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

## Running the engine

| Topic | Page |
| --- | --- |
| RESP, connections and client controls | [Connections and protocol](connections-and-protocol.md) |
| Optional LCS compute workers and guarded GET/plain SET workers | [Threading](threading.md) |
| Configuration, introspection, memory limits and eviction | [Server management](server.md) |
| Users, selectors, key patterns and authentication | [ACL](acl.md) |
| Snapshots, append-only files and payload transfer | [Persistence](persistence.md) |
| Shared-keyspace text endpoint | [Memcached](memcached.md) |

The [roadmap](../ROADMAP.md) states the verification conditions and the work still ahead. Performance tables describe the committed run, with its exclusions and client limits; conformance baseline success means its recorded passing tests were preserved. Neither result is an unrestricted compatibility or deployment-safety claim.

The default-disabled keyspace-worker path has passed native ownership tests and its dedicated external correctness driver, including sanitizer runs. The full package gate, smoke and baseline compatibility checks also pass with workers disabled and enabled. Its guarded GET/plain SET scope is separate from the previously qualified LCS stage; no keyspace-worker performance result is claimed.

Eski is licensed under [Apache-2.0](../LICENSE). Third-party components retain their own terms; see [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
