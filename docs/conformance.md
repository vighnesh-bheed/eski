# Conformance records

Generated from `test/conformance/baseline-redis.json` and `docs/data/conformance-redis.json`. Both identify the Redis 7.4.11 test suite, archive SHA256 `e973da69febfea096ab94690b44bf976482788a1b5e070df373b4f27697d57d4`, with tag filter `-needs:repl`. The baseline records 1504 passes and 6 failures in 28 units. The expanded snapshot records 2082 passes, 0 failures and 137 skips in 43 units. The baseline gate preserves 1504 of 1504 baseline passes, with 0 regressions.

A baseline PASS checks the preserved passing tests in its compared units. It does not claim that every selected upstream test passes. No test failures or unit errors were recorded in the expanded snapshot. Skipped tests and omitted fixtures do not establish coverage. A unit with zero passing tests does not establish coverage; external-server mode can omit blocks that require suite-managed servers. Managed fixtures and resource limits are described in [build, run and test](build-run-test.md#verification) and [scripting](scripting.md#verification).

## Reproduce and refresh

Build with `./build.sh`, then run `./test/conformance/run.sh --suite redis --tags "-needs:repl" --baseline test/conformance/baseline-redis.json`. Run `./test/conformance/run.sh --suite redis --tags "-needs:repl"` without the baseline to apply the strict failure rule. Refresh the public snapshot from an actual run with `python3 -I test/readme_tables.py --record-conformance test/conformance/results/latest-redis.json`, then run `python3 -I test/readme_tables.py --check`. The refresh keeps aggregate counts, exact failing test identities, authored reasons and the baseline comparison, while omitting local paths, raw assertion code and stack traces. The preserved snapshot was generated at `2026-10-31T05:00:39Z`; reruns can change timings and expose different outcomes.

## Protected historical baseline

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

## Expanded recorded snapshot

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

## Recorded failures

No test failures were recorded.

Eski is an independent project, not affiliated with, endorsed or certified by Redis Ltd. Redis is a registered trademark of Redis Ltd.; any rights therein are reserved to Redis Ltd.
