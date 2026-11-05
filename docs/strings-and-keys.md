# Strings

Strings hold binary-safe byte sequences. `SET`, `GET`, `MSET` and `MGET` provide ordinary access; `SETNX`, `MSETNX`, `SETEX` and `PSETEX` cover conditional or expiring writes. `GETDEL`, `GETEX` and `GETSET` combine a read with a change. String range and numeric operations reject collection values; an ordinary `SET` can replace a collection key. Missing-key replies depend on the operation: for example, `GET` is null and `STRLEN` is zero.

`SET` accepts `NX` or `XX`, `GET`, `KEEPTTL`, `IFEQ expected-value` and the `EX`, `PX`, `EXAT` or `PXAT` expiry forms, subject to their mutual-exclusion checks. A successful ordinary replacement removes an existing TTL unless it supplies a new expiry or uses `KEEPTTL`. `GETEX` accepts those expiry forms or `PERSIST`. Keys and arguments remain bytes; command names and option keywords are case-insensitive.

```sh
redis-cli -p 6399 SET demo:session token NX EX 60
redis-cli -p 6399 GET demo:session
redis-cli -p 6399 SET demo:session replacement XX GET KEEPTTL
redis-cli -p 6399 GETEX demo:session PERSIST
redis-cli -p 6399 MSET demo:first Ada demo:last Lovelace
redis-cli -p 6399 MGET demo:first demo:last
```

`APPEND`, `STRLEN`, `SETRANGE`, `GETRANGE` and its `SUBSTR` alias operate on byte offsets. Ranges use inclusive endpoints and accept negative offsets from the end. Extending a string with `SETRANGE` fills the gap with zero bytes. Use a binary-safe client when reading such values.

`INCR`, `DECR`, `INCRBY` and `DECRBY` parse signed integers and reject invalid values or overflow. `INCRBYFLOAT` performs decimal numeric updates and rejects invalid/non-finite results. `LCS` finds the longest common subsequence of two strings; `LEN`, `IDX`, `MINMATCHLEN` and `WITHMATCHLEN` select length or matching-range output. Large range writes and LCS requests can consume substantial foreground time and memory.

See [keyspace](keyspace.md) for deletion, expiry, copying and scans, and the generated [command reference](commands.md) for arities and option metadata. Verify with `bash test/run_packages.sh`, then select the `type/string` and `type/incr` units using `./test/conformance/run.sh --suite redis --units type/string,type/incr`. The [conformance report](conformance.md) describes the distinction between recorded compatibility and full parity.

Eski is an independent project, not affiliated with, endorsed or certified by Redis Ltd. Redis is a registered trademark of Redis Ltd.; any rights therein are reserved to Redis Ltd.
