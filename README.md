# Eski

![Conformance baseline](docs/img/conformance.svg)
![Recorded benchmark ratio](docs/img/benchmark-ratio.svg)

Eski is a free and open source in-memory data store for a single machine, written in Odin and accessed through the Redis protocol. It implements strings, hashes with field expiry, lists, sets, sorted sets, geospatial operations, bitmaps, HyperLogLog, streams, pub/sub, transactions, persistence and an optional memcached text endpoint. Scripting, executable functions, modules, replication, Sentinel and Cluster are outside this repository's scope. Compatibility is measured by the checks below; a baseline pass is a regression result over a recorded set of tests.

## Try it

Build on Linux with Odin, clang and Python available. The compiler release used by the container build is pinned in [Dockerfile](Dockerfile).

```sh
./build.sh check
./build.sh
./bin/eski --bind 127.0.0.1 --port 6399
```

In another terminal, use a Redis protocol client:

```sh
redis-cli -p 6399 SET demo:message hello
redis-cli -p 6399 GET demo:message
redis-cli -p 6399 HSET demo:user name Ada
redis-cli -p 6399 HGETALL demo:user
```

The example binds to loopback explicitly. Configure network access and [ACLs](docs/acl.md) before exposing a listener. Authentication and persistence are opt-in; [build, run and test](docs/build-run-test.md) covers compiler discovery, configuration files, containers, durability and every verification layer.

## How it works

The coordinator runs on a single event-loop thread. Linux epoll reports ready sockets, each connection keeps its input and output buffers, and the parser retains incomplete requests until more bytes arrive. Complete arguments reach a command registry whose entries connect handlers with arity, flags, key specifications and argument metadata. Handlers operate on the selected database and write typed RESP replies. Optional [compute workers](docs/threading.md) run expensive LCS calculations over owned input snapshots. Pipelining preserves each connection's command order. Workers are disabled by default.

A separate, default-disabled keyspace-worker path handles guarded GET and plain SET on strings without expiry. Workers own eligible values and serialize requests for each key; other commands and features use the coordinator after a reconciliation barrier. Native ownership tests and dedicated external correctness checks pass, including address and thread sanitizer runs. The full package gate, smoke and baseline compatibility checks pass with workers disabled and enabled. No keyspace-worker benchmark or speedup is claimed. The [threading guide](docs/threading.md#keyspace-workers) describes the tested scope and memory/latency costs.

Each event-loop iteration has a scratch allocation lifetime. Values and connection state that survive that iteration use owned storage instead. This separates transient parsing and reply work from data stored in the keyspace. Lazy freeing, bounded maintenance and persistence work have their own lifetimes; the foreground loop is not a promise that every command has constant latency.

The keyspace is an open-addressed table. Compact control bytes identify candidate slots before full key comparison, and slot metadata carries expiry and access information. Short keys and string values can fit in their handles. Larger payloads use slab or heap storage, while collection values point to type-specific objects. Growth moves table work incrementally so an operation need not rehash the complete database at once. Hash, set and sorted-set member tables also have bounded migration work that continues during quiet periods.

Expiry combines checks on access with periodic maintenance. The active sweep walks metadata and removes expired keys within its work budget. Hash fields have a separate deadline registry. Notifications, watched-key invalidation, client tracking and persistence feeds are tied to mutations so they observe the same keyspace changes. Memory limits add eviction and client-buffer policies; they do not turn the configured limit into an operating-system RSS cap.

The source is organized by command group. Files such as `src/cmd_string.odin`, `src/cmd_hash.odin` and `src/cmd_stream.odin` register handlers, with storage packages underneath and shared dispatch, reply, ACL and persistence services around them. RDB snapshots and append-only files provide local durability options. This repository remains a single-node engine; distributed coordination and managed operation belong to a separate layer. See the [architecture](docs/architecture.md) and [documentation index](docs/README.md).

## Compatibility and verification

The generated tables separate the checked-in baseline from the recorded expanded suite. Remaining differences include buffer accounting, selected pause/expiry behaviour, mutation counters and introspection replies, alongside tests requiring deliberately excluded features. The [conformance page](docs/conformance.md) names the failing tests and the commands that reproduce the runs. These records predate the current keyspace-worker changes; their dedicated correctness checks are described separately in the [threading guide](docs/threading.md#keyspace-correctness-checks).

<!-- BEGIN GENERATED CONFORMANCE -->

The recorded gate preserves **1504 / 1504 baseline passes** across 28 compared units, with **0 regressions**. The expanded recorded run has **2047 passes, 20 failures and 151 skips** across 43 units. Its remaining failures include excluded execution features and compatibility gaps; see the [recorded results and explanations](docs/conformance.md).

| Unit | Passed | Failed | Skipped | Unit errors |
| --- | ---: | ---: | ---: | ---: |
| acl | 85 | 0 | 9 | 0 |
| acl-v2 | 36 | 0 | 1 | 0 |
| auth | 7 | 0 | 2 | 0 |
| bitops | 49 | 0 | 2 | 0 |
| dump | 13 | 0 | 15 | 0 |
| expire | 62 | 2 | 6 | 0 |
| geo | 64 | 0 | 0 | 0 |
| hyperloglog | 27 | 0 | 1 | 0 |
| info | 21 | 1 | 4 | 0 |
| info-command | 3 | 0 | 0 | 0 |
| introspection | 34 | 0 | 18 | 0 |
| introspection-2 | 40 | 2 | 5 | 0 |
| keyspace | 59 | 0 | 0 | 0 |
| latency-monitor | 14 | 0 | 1 | 0 |
| lazyfree | 9 | 0 | 1 | 0 |
| maxmemory | 27 | 0 | 5 | 0 |
| memefficiency | 5 | 0 | 2 | 0 |
| multi | 42 | 0 | 21 | 0 |
| pubsub | 46 | 0 | 1 | 0 |
| slowlog | 16 | 0 | 2 | 0 |
| sort | 53 | 1 | 1 | 0 |
| tracking | 56 | 0 | 2 | 0 |
| type/hash | 75 | 0 | 0 | 0 |
| type/hash-field-expire | 112 | 0 | 14 | 0 |
| type/incr | 33 | 0 | 0 | 0 |
| type/set | 117 | 0 | 3 | 0 |
| type/string | 79 | 0 | 2 | 0 |
| type/zset | 320 | 0 | 2 | 0 |
| **Total** | **1504** | **6** | **120** | **0** |

<!-- END GENERATED CONFORMANCE -->

```sh
bash test/run_packages.sh
./test/conformance/run.sh --suite redis --baseline test/conformance/baseline-redis.json
bash test/smoke.sh
python3 -I test/readme_tables.py --check
```

The package runner exercises debug, sanitizer and release builds. Conformance downloads a checksum-verified test suite; fetching it before smoke enables the fixture-dependent corrupt-payload comparisons. Smoke also compares replies and persistence behaviour with reference containers. The generated documentation checks use a temporary local Eski instance and the committed measurement inputs. The [test guide](docs/build-run-test.md#verification) explains what each gate establishes.

## Recorded measurements

These results come from the committed [comparison-v1 dataset](bench/testbed/runs/comparison-v1/dataset.json). Every engine uses the same server CPU assignment and memory caps, separate client cores, a fresh dataset and a warmup before timing. The run records power, temperature, CPU-idle and load-generator limits. Invalid repetitions retain their reason, and client-limited measurements remain annotated. These measurements describe the recorded machine and workload; they establish no multicore scaling or universal throughput claim.

<!-- BEGIN GENERATED BENCHMARKS -->

Recorded medians from `bench/testbed/runs/comparison-v1`, using valid repetitions only. These are measurements from one machine, not a claim about every workload or deployment.

| Workload | Eski ops/s | Redis ops/s | Valkey ops/s | Dragonfly ops/s |
| --- | ---: | ---: | ---: | ---: |
| GET 64 B, pipeline 1 | 203,744 † | 185,291 † | 183,310 † | 115,306 |
| SET 64 B, pipeline 1 | 205,353 † | 179,676 † | 178,454 † | 111,261 |
| SET and GET 1:1, 64 B, pipeline 1 | 203,606 † | 180,511 † | 180,802 † | 112,313 |
| SET and GET 1:1, 64 B, pipeline 16 | excluded (4) | 1,072,454 | 1,084,969 | 644,218 |
| GET 1024 B, pipeline 1 | 192,703 † | 173,901 † | 174,958 † | 106,822 |
| HGET, 16 fields of 64 B, pipeline 1 | 189,570 † | 174,606 † | 175,334 † | 112,367 |
| SISMEMBER, 16 members, pipeline 1 | 196,644 † | 179,359 † | 182,302 † | 120,372 |
| ZSCORE, 16 members, pipeline 1 | 192,190 † | 178,279 † | 178,465 † | 117,307 |

† At least one included repetition was client limited. The observed GET 64 B pipeline 1 median throughput ratio is **1.10x Eski / Redis** (client limited). Client limits affect both measurements, so that ratio is not a guaranteed engine-speed ratio. Excluded repetitions receive no inferred score. [Method, ranges, images and exclusions](docs/benchmarks.md).

<!-- END GENERATED BENCHMARKS -->

Read the [benchmark method and tables](docs/benchmarks.md), the [self-contained report](bench/testbed/runs/comparison-v1/report.html) and the [recorded charts](bench/testbed/runs/comparison-v1/charts/throughput.svg). Reproduce the displayed tables and badges from the committed inputs with:

```sh
python3 -I test/readme_tables.py
python3 -I test/readme_tables.py --check
```

## Command groups

The following inventory is generated from the running server's `COMMAND DOCS` metadata. Registered compatibility stubs and behavioural limitations are explained in the linked group pages and [complete command reference](docs/commands.md).

<!-- BEGIN GENERATED COMMANDS -->

The running executable registers **229 top-level commands** and **319 commands including subcommands**. Compatibility stubs remain subject to the exclusions above. [Arguments and metadata summaries](docs/commands.md) come from `COMMAND DOCS`; every name below is cross-checked against `COMMAND LIST`.

| Group | Registered commands and subcommands |
| --- | --- |
| bitmap | `BITCOUNT`, `BITFIELD`, `BITFIELD_RO`, `BITOP`, `BITPOS`, `GETBIT`, `SETBIT` |
| connection | `AUTH`, `CLIENT`, `CLIENT CACHING`, `CLIENT GETNAME`, `CLIENT GETREDIR`, `CLIENT HELP`, `CLIENT ID`, `CLIENT INFO`, `CLIENT KILL`, `CLIENT LIST`, `CLIENT NO-EVICT`, `CLIENT NO-TOUCH`, `CLIENT PAUSE`, `CLIENT REPLY`, `CLIENT SETINFO`, `CLIENT SETNAME`, `CLIENT TRACKING`, `CLIENT TRACKINGINFO`, `CLIENT UNBLOCK`, `CLIENT UNPAUSE`, `ECHO`, `HELLO`, `PING`, `QUIT`, `RESET`, `SELECT` |
| generic | `COPY`, `DEL`, `DUMP`, `EXISTS`, `EXPIRE`, `EXPIREAT`, `EXPIRETIME`, `KEYS`, `MIGRATE`, `MOVE`, `OBJECT`, `OBJECT ENCODING`, `OBJECT FREQ`, `OBJECT HELP`, `OBJECT IDLETIME`, `OBJECT REFCOUNT`, `PERSIST`, `PEXPIRE`, `PEXPIREAT`, `PEXPIRETIME`, `PTTL`, `RANDOMKEY`, `RENAME`, `RENAMENX`, `RESTORE`, `SCAN`, `SORT`, `SORT_RO`, `TOUCH`, `TTL`, `TYPE`, `UNLINK`, `WAIT`, `WAITAOF` |
| geo | `GEOADD`, `GEODIST`, `GEOHASH`, `GEOPOS`, `GEORADIUS`, `GEORADIUS_RO`, `GEORADIUSBYMEMBER`, `GEORADIUSBYMEMBER_RO`, `GEOSEARCH`, `GEOSEARCHSTORE` |
| hash | `HDEL`, `HEXISTS`, `HEXPIRE`, `HEXPIREAT`, `HEXPIRETIME`, `HGET`, `HGETALL`, `HINCRBY`, `HINCRBYFLOAT`, `HKEYS`, `HLEN`, `HMGET`, `HMSET`, `HPERSIST`, `HPEXPIRE`, `HPEXPIREAT`, `HPEXPIRETIME`, `HPTTL`, `HRANDFIELD`, `HSCAN`, `HSET`, `HSETNX`, `HSTRLEN`, `HTTL`, `HVALS` |
| hyperloglog | `PFADD`, `PFCOUNT`, `PFDEBUG`, `PFMERGE`, `PFSELFTEST` |
| list | `BLMOVE`, `BLMPOP`, `BLPOP`, `BRPOP`, `BRPOPLPUSH`, `LINDEX`, `LINSERT`, `LLEN`, `LMOVE`, `LMPOP`, `LPOP`, `LPOS`, `LPUSH`, `LPUSHX`, `LRANGE`, `LREM`, `LSET`, `LTRIM`, `RPOP`, `RPOPLPUSH`, `RPUSH`, `RPUSHX` |
| pubsub | `PSUBSCRIBE`, `PUBLISH`, `PUBSUB`, `PUBSUB CHANNELS`, `PUBSUB HELP`, `PUBSUB NUMPAT`, `PUBSUB NUMSUB`, `PUBSUB SHARDCHANNELS`, `PUBSUB SHARDNUMSUB`, `PUNSUBSCRIBE`, `SPUBLISH`, `SSUBSCRIBE`, `SUBSCRIBE`, `SUNSUBSCRIBE`, `UNSUBSCRIBE` |
| scripting | `FUNCTION`, `FUNCTION DELETE`, `FUNCTION DUMP`, `FUNCTION FLUSH`, `FUNCTION HELP`, `FUNCTION KILL`, `FUNCTION LIST`, `FUNCTION LOAD`, `FUNCTION RESTORE`, `FUNCTION STATS` |
| server | `ACL`, `ACL CAT`, `ACL DELUSER`, `ACL DRYRUN`, `ACL GENPASS`, `ACL GETUSER`, `ACL HELP`, `ACL LIST`, `ACL LOAD`, `ACL LOG`, `ACL SAVE`, `ACL SETUSER`, `ACL USERS`, `ACL WHOAMI`, `BGREWRITEAOF`, `BGSAVE`, `COMMAND`, `COMMAND COUNT`, `COMMAND DOCS`, `COMMAND GETKEYS`, `COMMAND GETKEYSANDFLAGS`, `COMMAND HELP`, `COMMAND INFO`, `COMMAND LIST`, `CONFIG`, `CONFIG GET`, `CONFIG HELP`, `CONFIG RESETSTAT`, `CONFIG REWRITE`, `CONFIG SET`, `DBSIZE`, `DEBUG`, `FLUSHALL`, `FLUSHDB`, `INFO`, `LASTSAVE`, `LATENCY`, `LATENCY DOCTOR`, `LATENCY GRAPH`, `LATENCY HELP`, `LATENCY HISTOGRAM`, `LATENCY HISTORY`, `LATENCY LATEST`, `LATENCY RESET`, `MEMORY`, `MEMORY DOCTOR`, `MEMORY HELP`, `MEMORY MALLOC-STATS`, `MEMORY PURGE`, `MEMORY STATS`, `MEMORY USAGE`, `MONITOR`, `SAVE`, `SHUTDOWN`, `SLOWLOG`, `SLOWLOG GET`, `SLOWLOG HELP`, `SLOWLOG LEN`, `SLOWLOG RESET`, `SWAPDB`, `TIME` |
| set | `SADD`, `SCARD`, `SDIFF`, `SDIFFSTORE`, `SINTER`, `SINTERCARD`, `SINTERSTORE`, `SISMEMBER`, `SMEMBERS`, `SMISMEMBER`, `SMOVE`, `SPOP`, `SRANDMEMBER`, `SREM`, `SSCAN`, `SUNION`, `SUNIONSTORE` |
| sorted-set | `BZMPOP`, `BZPOPMAX`, `BZPOPMIN`, `ZADD`, `ZCARD`, `ZCOUNT`, `ZDIFF`, `ZDIFFSTORE`, `ZINCRBY`, `ZINTER`, `ZINTERCARD`, `ZINTERSTORE`, `ZLEXCOUNT`, `ZMPOP`, `ZMSCORE`, `ZPOPMAX`, `ZPOPMIN`, `ZRANDMEMBER`, `ZRANGE`, `ZRANGEBYLEX`, `ZRANGEBYSCORE`, `ZRANGESTORE`, `ZRANK`, `ZREM`, `ZREMRANGEBYLEX`, `ZREMRANGEBYRANK`, `ZREMRANGEBYSCORE`, `ZREVRANGE`, `ZREVRANGEBYLEX`, `ZREVRANGEBYSCORE`, `ZREVRANK`, `ZSCAN`, `ZSCORE`, `ZUNION`, `ZUNIONSTORE` |
| stream | `XACK`, `XADD`, `XAUTOCLAIM`, `XCLAIM`, `XDEL`, `XGROUP`, `XGROUP CREATE`, `XGROUP CREATECONSUMER`, `XGROUP DELCONSUMER`, `XGROUP DESTROY`, `XGROUP HELP`, `XGROUP SETID`, `XINFO`, `XINFO CONSUMERS`, `XINFO GROUPS`, `XINFO HELP`, `XINFO STREAM`, `XLEN`, `XPENDING`, `XRANGE`, `XREAD`, `XREADGROUP`, `XREVRANGE`, `XSETID`, `XTRIM` |
| string | `APPEND`, `DECR`, `DECRBY`, `GET`, `GETDEL`, `GETEX`, `GETRANGE`, `GETSET`, `INCR`, `INCRBY`, `INCRBYFLOAT`, `LCS`, `MGET`, `MSET`, `MSETNX`, `PSETEX`, `SET`, `SETEX`, `SETNX`, `SETRANGE`, `STRLEN`, `SUBSTR` |
| transactions | `DISCARD`, `EXEC`, `MULTI`, `UNWATCH`, `WATCH` |

<!-- END GENERATED COMMANDS -->

## Direction and licence

The next work is to close the documented compatibility gaps and measure the hot paths before selecting performance changes. Distributed management is outside this node's implementation. [ROADMAP.md](ROADMAP.md) lists the command-group milestones, their verification conditions and the measurement process.

Eski is licensed under [Apache-2.0](LICENSE). Third-party components retain their own terms, recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
