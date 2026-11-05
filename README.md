# Eski

![Conformance baseline](docs/img/conformance.svg)
![Recorded benchmark ratio](docs/img/benchmark-ratio.svg)

Eski is a free and open source in-memory data store for a single machine, with an Odin host and an embedded C Lua runtime, accessed through the Redis protocol. It implements strings, hashes with field expiry, lists, sets, sorted sets, geospatial operations, bitmaps, HyperLogLog, streams, pub/sub, transactions, persistence, Lua evaluation and an optional memcached text endpoint. Lua scripting, executable Function libraries and interactive debugging use Lua 5.1.5. IPv4, IPv6, Unix sockets and TLS serve the supported protocol. Modules, replication, Sentinel and Cluster are outside this repository's scope. See the [scripting guide](docs/scripting.md). Compatibility is measured by the checks below; a baseline pass is a regression result over a recorded set of tests.

## Try it

Build on Linux with Odin, clang, OpenSSL 3 and libunwind development libraries, GNU ar, sha256sum, flock and Python available. The compiler release used by the container build is pinned in [Dockerfile](Dockerfile); Lua sources and patches are vendored for offline dependency builds.

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
redis-cli -p 6399 EVAL 'return redis.call("INCR",KEYS[1])' 1 demo:counter
```

The example binds to loopback explicitly. Configure network access and [ACLs](docs/acl.md) before exposing a listener. Authentication and append-only persistence are opt-in; scheduled snapshots use the standard default save rules. [build, run and test](docs/build-run-test.md) covers compiler discovery, configuration files, containers, durability and every verification layer.

## How it works

The coordinator runs on a single event-loop thread. Linux epoll reports ready sockets, each connection keeps its input and output buffers, and the parser retains incomplete requests until more bytes arrive. Complete arguments reach a command registry whose entries connect handlers with arity, flags, key specifications and argument metadata. Handlers operate on the selected database and write typed RESP replies. Optional [compute workers](docs/threading.md) run expensive LCS calculations over owned input snapshots. Pipelining preserves each connection's command order. Workers are disabled by default.

The separate, default-disabled keyspace pool executes eligible commands across strings, lists, hashes, sets, sorted sets/geo, streams, bitmaps and HyperLogLog, including atomic multi-key work and TTL options. AOF, WATCH, tracking/NOLOOP, notifications, MONITOR and configured memory policies retain coordinator publication; unrelated blocked clients and Memcached keys do not disable the whole pool. Commands touching blocked keys or Memcached metadata, actual pressure and global operations use coordinator barriers. Dedicated datatype/feature checks, upstream comparisons and whole-node address/thread sanitizer runs exercise these boundaries. The [verification record](docs/build-run-test.md#verification) states the coverage and limits. Keyspace benchmarking against other servers is deferred. The [threading guide](docs/threading.md#keyspace-workers) explains startup options, fallbacks and memory/AOF costs, and records a dated comparison between Eski builds.

[Lua scripts and Functions](docs/scripting.md) run on the coordinator in persistent Lua 5.1.5 engines behind a protected C ABI. EVAL and Function libraries use separate engines; Function libraries share one VM and retain their closure state between calls. Builtin tables are read-only, and each invocation uses the caller's ACL and command-effect hooks. Successful writes survive a later script error, and AOF records their effects. SCRIPT manages the source cache and debugger, while FUNCTION manages executable libraries. The scripting guide describes configuration, cancellation, persistence and current qualification.

Each event-loop iteration has a scratch allocation lifetime. Values and connection state that survive that iteration use owned storage instead. This separates transient parsing and reply work from data stored in the keyspace. Lazy freeing, bounded maintenance and persistence work have their own lifetimes; the foreground loop is not a promise that every command has constant latency.

The keyspace is an open-addressed table. Compact control bytes identify candidate slots before full key comparison, and slot metadata carries expiry and access information. Short keys and string values can fit in their handles. Larger payloads use slab or heap storage, while collection values point to type-specific objects. Growth moves table work incrementally so an operation need not rehash the complete database at once. Hash, set and sorted-set member tables also have bounded migration work that continues during quiet periods.

Expiry combines checks on access with periodic maintenance. The active sweep walks metadata and removes expired keys within its work budget. Hash fields have a separate deadline registry. Notifications, watched-key invalidation, client tracking and persistence feeds are tied to mutations so they observe the same keyspace changes. Memory limits add eviction and client-buffer policies; they do not turn the configured limit into an operating-system RSS cap.

The source is organized by command group. Files such as `src/cmd_string.odin`, `src/cmd_hash.odin` and `src/cmd_stream.odin` register handlers, with storage packages underneath and shared dispatch, reply, ACL and persistence services around them. RDB snapshots and append-only files provide local durability options. This repository remains a single-node engine; distributed coordination and managed operation belong to a separate layer. See the [architecture](docs/architecture.md) and [documentation index](docs/README.md).

## Compatibility and verification

The generated tables compare the protected historical baseline with the recorded expanded Redis suite. Separate managed fixtures exercise server restarts, Lua/Functions, networking and persistence. The [verification record](docs/build-run-test.md#verification) describes those checks, allocator and storage-representation differences, and two unqualified Lua JSON cases over 2 GB. Skipped tests do not establish compatibility. The [conformance page](docs/conformance.md) records the suite results and reproduction commands; the [scripting](docs/scripting.md#verification) and [threading](docs/threading.md#keyspace-correctness-checks) guides describe their dedicated checks.

<!-- BEGIN GENERATED CONFORMANCE -->

The recorded gate preserves **1504 / 1504 baseline passes** across 28 compared units, with **0 regressions**. The expanded recorded run has **2082 passes, 0 failures and 137 skips** across 43 units, with **0 unit errors**. The observed run records **1528 passes in the 28 compared units**, including **24 additional passes** beyond the protected baseline. No test failures or unit errors were recorded; skipped tests do not establish coverage. See the [conformance record](docs/conformance.md).

| Unit | Passed | Failed | Skipped | Unit errors |
| --- | ---: | ---: | ---: | ---: |
| acl | 87 | 0 | 7 | 0 |
| acl-v2 | 36 | 0 | 1 | 0 |
| auth | 8 | 0 | 1 | 0 |
| bitfield | 18 | 0 | 1 | 0 |
| bitops | 49 | 0 | 2 | 0 |
| dump | 13 | 0 | 15 | 0 |
| expire | 62 | 0 | 8 | 0 |
| geo | 64 | 0 | 0 | 0 |
| hyperloglog | 27 | 0 | 1 | 0 |
| info | 24 | 0 | 2 | 0 |
| info-command | 3 | 0 | 0 | 0 |
| introspection | 36 | 0 | 16 | 0 |
| introspection-2 | 46 | 0 | 1 | 0 |
| keyspace | 59 | 0 | 0 | 0 |
| latency-monitor | 16 | 0 | 0 | 0 |
| lazyfree | 9 | 0 | 1 | 0 |
| limits | 0 | 0 | 1 | 0 |
| maxmemory | 27 | 0 | 5 | 0 |
| memefficiency | 5 | 0 | 2 | 0 |
| multi | 46 | 0 | 17 | 0 |
| networking | 0 | 0 | 4 | 0 |
| other | 24 | 0 | 6 | 0 |
| pause | 18 | 0 | 1 | 0 |
| protocol | 25 | 0 | 0 | 0 |
| pubsub | 47 | 0 | 0 | 0 |
| pubsubshard | 0 | 0 | 2 | 0 |
| querybuf | 3 | 0 | 0 | 0 |
| quit | 3 | 0 | 0 | 0 |
| scan | 25 | 0 | 1 | 0 |
| slowlog | 16 | 0 | 2 | 0 |
| sort | 54 | 0 | 1 | 0 |
| tracking | 58 | 0 | 0 | 0 |
| type/hash | 75 | 0 | 0 | 0 |
| type/hash-field-expire | 112 | 0 | 14 | 0 |
| type/incr | 33 | 0 | 0 | 0 |
| type/list | 281 | 0 | 14 | 0 |
| type/list-2 | 2 | 0 | 0 | 0 |
| type/list-3 | 11 | 0 | 0 | 0 |
| type/set | 117 | 0 | 3 | 0 |
| type/stream | 82 | 0 | 0 | 0 |
| type/stream-cgroups | 62 | 0 | 4 | 0 |
| type/string | 79 | 0 | 2 | 0 |
| type/zset | 320 | 0 | 2 | 0 |
| **Total** | **2082** | **0** | **137** | **0** |

<!-- END GENERATED CONFORMANCE -->

```sh
bash test/run_packages.sh
./test/conformance/run.sh --suite redis --baseline test/conformance/baseline-redis.json
bash test/smoke.sh
python3 -I test/readme_tables.py --check
```

The package runner exercises debug, sanitizer and release builds. Conformance downloads a checksum-verified test suite; fetching it before smoke enables the fixture-dependent corrupt-payload comparisons. Smoke also compares replies and persistence behaviour with reference containers. The generated documentation checks use a temporary local Eski instance and the committed measurement inputs. The [test guide](docs/build-run-test.md#verification) explains what each gate establishes.

## Recorded measurements

<!-- BEGIN GENERATED BENCHMARKS -->

These results come from the committed [cloud-v1 dataset](bench/testbed/runs/cloud-v1/dataset.json). Every engine uses the same server CPU assignment and memory caps, separate client cores, a fresh dataset and a warmup before timing. The run records power, temperature, CPU-idle and load-generator limits. Invalid repetitions retain their reason, and client-limited measurements remain annotated. These measurements describe the recorded machine and workload; they establish no multicore scaling or universal throughput claim.

Recorded medians from `bench/testbed/runs/cloud-v1`, using valid repetitions only. These are measurements from one machine, not a claim about every workload or deployment.

| Workload | Eski ops/s | Redis ops/s | Valkey ops/s | Dragonfly ops/s |
| --- | ---: | ---: | ---: | ---: |
| GET 64 B, pipeline 1 | 244,645 | 260,747 | 176,384 | 146,517 |
| SET 64 B, pipeline 1 | 241,782 | 251,949 | 247,855 | 117,723 |
| SET and GET 1:1, 64 B, pipeline 1 | 237,218 | 168,230 | 252,022 | 117,363 |
| SET and GET 1:1, 64 B, pipeline 16 | 2,179,538 | 988,890 | 1,448,979 | 629,804 |
| GET 1024 B, pipeline 1 | 259,063 | 239,505 | 171,395 | 132,166 |
| HGET, 16 fields of 64 B, pipeline 1 | 226,112 | 240,044 | 240,906 | 140,202 |
| SISMEMBER, 16 members, pipeline 1 | 271,875 | 224,084 | 254,385 | 153,949 |
| ZSCORE, 16 members, pipeline 1 | 265,661 | 164,437 | 168,386 | 114,097 |

† At least one included repetition was client limited. The observed GET 64 B pipeline 1 median throughput ratio is **0.94x Eski / Redis**. Client limits affect both measurements, so that ratio is not a guaranteed engine-speed ratio. Excluded repetitions receive no inferred score. [Method, ranges, images and exclusions](docs/benchmarks.md).

Read the [benchmark method and tables](docs/benchmarks.md), the [self-contained report](bench/testbed/runs/cloud-v1/report.html) and the [recorded charts](bench/testbed/runs/cloud-v1/charts/throughput.svg).

<!-- END GENERATED BENCHMARKS -->

Reproduce the displayed tables and badges from the committed inputs with:

```sh
python3 -I test/readme_tables.py
python3 -I test/readme_tables.py --check
```

[Run the comparison on a new machine](docs/benchmarks.md#run-the-comparison-on-a-new-machine) gives the commands that measure it again from a clone of this repository.

## Command groups

The following inventory is generated from the running server's `COMMAND DOCS` metadata. Registered compatibility stubs and behavioural limitations are explained in the linked group pages and [complete command reference](docs/commands.md).

<!-- BEGIN GENERATED COMMANDS -->

The running executable registers **237 top-level commands** and **333 commands including subcommands**. Compatibility stubs remain subject to the exclusions above. [Arguments and metadata summaries](docs/commands.md) come from `COMMAND DOCS`; every name below is cross-checked against `COMMAND LIST`.

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
| scripting | `EVAL`, `EVAL_RO`, `EVALSHA`, `EVALSHA_RO`, `FCALL`, `FCALL_RO`, `FUNCTION`, `FUNCTION DELETE`, `FUNCTION DUMP`, `FUNCTION FLUSH`, `FUNCTION HELP`, `FUNCTION KILL`, `FUNCTION LIST`, `FUNCTION LOAD`, `FUNCTION RESTORE`, `FUNCTION STATS`, `SCRIPT`, `SCRIPT DEBUG`, `SCRIPT EXISTS`, `SCRIPT FLUSH`, `SCRIPT HELP`, `SCRIPT KILL`, `SCRIPT LOAD` |
| server | `ACL`, `ACL CAT`, `ACL DELUSER`, `ACL DRYRUN`, `ACL GENPASS`, `ACL GETUSER`, `ACL HELP`, `ACL LIST`, `ACL LOAD`, `ACL LOG`, `ACL SAVE`, `ACL SETUSER`, `ACL USERS`, `ACL WHOAMI`, `BGREWRITEAOF`, `BGSAVE`, `COMMAND`, `COMMAND COUNT`, `COMMAND DOCS`, `COMMAND GETKEYS`, `COMMAND GETKEYSANDFLAGS`, `COMMAND HELP`, `COMMAND INFO`, `COMMAND LIST`, `CONFIG`, `CONFIG GET`, `CONFIG HELP`, `CONFIG RESETSTAT`, `CONFIG REWRITE`, `CONFIG SET`, `DBSIZE`, `DEBUG`, `FLUSHALL`, `FLUSHDB`, `INFO`, `LASTSAVE`, `LATENCY`, `LATENCY DOCTOR`, `LATENCY GRAPH`, `LATENCY HELP`, `LATENCY HISTOGRAM`, `LATENCY HISTORY`, `LATENCY LATEST`, `LATENCY RESET`, `LOLWUT`, `MEMORY`, `MEMORY DOCTOR`, `MEMORY HELP`, `MEMORY MALLOC-STATS`, `MEMORY PURGE`, `MEMORY STATS`, `MEMORY USAGE`, `MONITOR`, `SAVE`, `SHUTDOWN`, `SLOWLOG`, `SLOWLOG GET`, `SLOWLOG HELP`, `SLOWLOG LEN`, `SLOWLOG RESET`, `SWAPDB`, `TIME` |
| set | `SADD`, `SCARD`, `SDIFF`, `SDIFFSTORE`, `SINTER`, `SINTERCARD`, `SINTERSTORE`, `SISMEMBER`, `SMEMBERS`, `SMISMEMBER`, `SMOVE`, `SPOP`, `SRANDMEMBER`, `SREM`, `SSCAN`, `SUNION`, `SUNIONSTORE` |
| sorted-set | `BZMPOP`, `BZPOPMAX`, `BZPOPMIN`, `ZADD`, `ZCARD`, `ZCOUNT`, `ZDIFF`, `ZDIFFSTORE`, `ZINCRBY`, `ZINTER`, `ZINTERCARD`, `ZINTERSTORE`, `ZLEXCOUNT`, `ZMPOP`, `ZMSCORE`, `ZPOPMAX`, `ZPOPMIN`, `ZRANDMEMBER`, `ZRANGE`, `ZRANGEBYLEX`, `ZRANGEBYSCORE`, `ZRANGESTORE`, `ZRANK`, `ZREM`, `ZREMRANGEBYLEX`, `ZREMRANGEBYRANK`, `ZREMRANGEBYSCORE`, `ZREVRANGE`, `ZREVRANGEBYLEX`, `ZREVRANGEBYSCORE`, `ZREVRANK`, `ZSCAN`, `ZSCORE`, `ZUNION`, `ZUNIONSTORE` |
| stream | `XACK`, `XADD`, `XAUTOCLAIM`, `XCLAIM`, `XDEL`, `XGROUP`, `XGROUP CREATE`, `XGROUP CREATECONSUMER`, `XGROUP DELCONSUMER`, `XGROUP DESTROY`, `XGROUP HELP`, `XGROUP SETID`, `XINFO`, `XINFO CONSUMERS`, `XINFO GROUPS`, `XINFO HELP`, `XINFO STREAM`, `XLEN`, `XPENDING`, `XRANGE`, `XREAD`, `XREADGROUP`, `XREVRANGE`, `XSETID`, `XTRIM` |
| string | `APPEND`, `DECR`, `DECRBY`, `GET`, `GETDEL`, `GETEX`, `GETRANGE`, `GETSET`, `INCR`, `INCRBY`, `INCRBYFLOAT`, `LCS`, `MGET`, `MSET`, `MSETNX`, `PSETEX`, `SET`, `SETEX`, `SETNX`, `SETRANGE`, `STRLEN`, `SUBSTR` |
| transactions | `DISCARD`, `EXEC`, `MULTI`, `UNWATCH`, `WATCH` |

<!-- END GENERATED COMMANDS -->

## Direction and licence

The next stage is controlled performance measurement of the expanded worker and Lua implementation. The documented compatibility boundaries and unqualified resource cases remain explicit. Distributed management is outside this node's implementation. [ROADMAP.md](ROADMAP.md) lists the command-group milestones, their verification conditions and the measurement process.

Eski is licensed under [Apache-2.0](LICENSE). Third-party components retain their own terms, recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
