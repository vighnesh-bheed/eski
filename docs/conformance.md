# Conformance records

Generated from `test/conformance/baseline-redis.json` and `docs/data/conformance-redis.json`. Both identify the Redis 7.4.11 test suite, archive SHA256 `e973da69febfea096ab94690b44bf976482788a1b5e070df373b4f27697d57d4`, with tag filter `-needs:repl`. The baseline records 1504 passes and 6 failures in 28 units. The expanded snapshot records 2051 passes, 16 failures and 151 skips in 43 units. The baseline gate preserves 1504 of 1504 baseline passes, with 0 regressions.

A baseline PASS checks the preserved passing tests in its compared units. It does not claim that every selected upstream test passes. Some upstream tests require excluded features, and others expose the compatibility gaps listed below. A unit with zero passing tests does not establish coverage; external-server mode can omit blocks that require suite-managed servers.

## Reproduce and refresh

Build with `./build.sh`, then run `./test/conformance/run.sh --suite redis --baseline test/conformance/baseline-redis.json`. Run `./test/conformance/run.sh --suite redis` without the baseline to apply the strict failure rule. Refresh the public snapshot from an actual run with `python3 -I test/readme_tables.py --record-conformance test/conformance/results/latest-redis.json`, then run `python3 -I test/readme_tables.py --check`. The refresh keeps aggregate counts, exact failing test identities, authored reasons and the baseline comparison, while omitting local paths, raw assertion code and stack traces. The preserved snapshot was generated at `2026-10-30T21:11:48Z`; reruns can change timings and expose different outcomes.

## Baseline units

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

## Expanded snapshot

| Unit | Passed | Failed | Skipped | Unit errors |
| --- | ---: | ---: | ---: | ---: |
| acl | 85 | 0 | 9 | 0 |
| acl-v2 | 36 | 0 | 1 | 0 |
| auth | 7 | 0 | 2 | 0 |
| bitfield | 18 | 0 | 1 | 0 |
| bitops | 49 | 0 | 2 | 0 |
| dump | 13 | 0 | 15 | 0 |
| expire | 62 | 2 | 6 | 0 |
| geo | 64 | 0 | 0 | 0 |
| hyperloglog | 27 | 0 | 1 | 0 |
| info | 21 | 1 | 4 | 0 |
| info-command | 3 | 0 | 0 | 0 |
| introspection | 34 | 0 | 18 | 0 |
| introspection-2 | 41 | 1 | 5 | 0 |
| keyspace | 59 | 0 | 0 | 0 |
| latency-monitor | 14 | 0 | 1 | 0 |
| lazyfree | 9 | 0 | 1 | 0 |
| limits | 0 | 0 | 1 | 0 |
| maxmemory | 27 | 0 | 5 | 0 |
| memefficiency | 5 | 0 | 2 | 0 |
| multi | 42 | 0 | 21 | 0 |
| networking | 0 | 0 | 4 | 0 |
| other | 24 | 1 | 5 | 0 |
| pause | 14 | 4 | 1 | 0 |
| protocol | 25 | 0 | 0 | 0 |
| pubsub | 46 | 0 | 1 | 0 |
| pubsubshard | 0 | 0 | 2 | 0 |
| querybuf | 0 | 3 | 0 | 0 |
| quit | 3 | 0 | 0 | 0 |
| scan | 25 | 0 | 1 | 0 |
| slowlog | 16 | 0 | 2 | 0 |
| sort | 53 | 1 | 1 | 0 |
| tracking | 56 | 0 | 2 | 0 |
| type/hash | 75 | 0 | 0 | 0 |
| type/hash-field-expire | 112 | 0 | 14 | 0 |
| type/incr | 33 | 0 | 0 | 0 |
| type/list | 280 | 3 | 12 | 0 |
| type/list-2 | 2 | 0 | 0 | 0 |
| type/list-3 | 11 | 0 | 0 | 0 |
| type/set | 117 | 0 | 3 | 0 |
| type/stream | 82 | 0 | 0 | 0 |
| type/stream-cgroups | 62 | 0 | 4 | 0 |
| type/string | 79 | 0 | 2 | 0 |
| type/zset | 320 | 0 | 2 | 0 |
| **Total** | **2051** | **16** | **151** | **0** |

## Recorded failures

| Unit and test | Category | Explanation |
| --- | --- | --- |
| expire::SCAN: Lazy-expire should not be wrapped in MULTI/EXEC | excluded feature | The test observes a replication stream; replication is outside the single-node scope. |
| expire::RANDOMKEY: Lazy-expire should not be wrapped in MULTI/EXEC | excluded feature | The test observes a replication stream; replication is outside the single-node scope. |
| info::memory: database and pubsub overhead and rehashing dict count | compatibility gap | The test assumes reference hash-table allocation sizes; Eski uses a different keyspace representation. |
| introspection-2::COMMAND LIST FILTERBY PATTERN - list all commands/subcommands | compatibility gap | The recorded command inventory differs; inspect the named assertion and the remaining function/cluster exclusions. |
| other::Coverage: HELP commands | excluded feature | The test asks for HELP on an excluded module command. |
| pause::Test RO scripts are not blocked by pause RO | excluded feature | The test requires executable function libraries, which are excluded. |
| pause::Test may-replicate commands are rejected in RO scripts | compatibility gap | The test exercises Lua scripting; this recorded assertion remains a compatibility gap. |
| pause::Test both active and passive expires are skipped during client pause | compatibility gap | The recorded pause/expiry behavior differs; this remains a compatibility gap. |
| pause::Test the randomkey command will not cause the server to get into an infinite loop during the client pause write | compatibility gap | The recorded pause/expiry behavior differs; this remains a compatibility gap. |
| querybuf::query buffer resized correctly | compatibility gap | The test assumes reference query-buffer allocation and resize behavior; Eski uses its own buffer policy. |
| querybuf::query buffer resized correctly when not idle | compatibility gap | The test assumes reference query-buffer allocation and resize behavior; Eski uses its own buffer policy. |
| querybuf::query buffer resized correctly with fat argv | compatibility gap | The test assumes reference query-buffer allocation and resize behavior; Eski uses its own buffer policy. |
| sort::SORT sorted set BY nosort works as expected from scripts | compatibility gap | The test exercises Lua scripting; this recorded assertion remains a compatibility gap. |
| type/list::SWAPDB wants to wake blocked client, but the key already expired | excluded feature | The test observes a replication stream; replication is outside the single-node scope. |
| type/list::MULTI + LPUSH + EXPIRE + DEBUG SLEEP on blocked client, key already expired | excluded feature | The test observes a replication stream; replication is outside the single-node scope. |
| type/list::BLPOP/BLMOVE should increase dirty | compatibility gap | The blocking list operation increased the dirty counter by 3 instead of the expected 2; this remains a compatibility gap. |
