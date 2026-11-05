# Hashes

A hash maps fields to binary-safe string values. `HSET` and its `HMSET` compatibility form write pairs; `HSETNX` writes only an absent field. Read with `HGET`, `HMGET`, `HGETALL`, `HKEYS`, `HVALS`, `HLEN`, `HEXISTS` and `HSTRLEN`. `HDEL` removes fields. Removing the last live field removes the hash key.

`HINCRBY` and `HINCRBYFLOAT` parse and update a field as a number, rejecting invalid values and integer overflow where applicable. `HRANDFIELD` supports a count and `WITHVALUES`; negative counts permit repeated selections. `HSCAN` supports `MATCH`, `COUNT` and `NOVALUES`. A cursor is not a snapshot, and `COUNT` is a hint rather than a fixed reply size.

```sh
redis-cli -p 6399 HSET demo:user name Ada visits 1
redis-cli -p 6399 HINCRBY demo:user visits 1
redis-cli -p 6399 HMGET demo:user name visits
redis-cli -p 6399 HSCAN demo:user 0 MATCH 'v*'
```

## Field expiry

Field deadlines are independent of the containing key's deadline. `HEXPIRE`, `HPEXPIRE`, `HEXPIREAT` and `HPEXPIREAT` accept `FIELDS count field ...` and conditional `NX`, `XX`, `GT` or `LT` expiry changes. `HTTL`, `HPTTL`, `HEXPIRETIME` and `HPEXPIRETIME` inspect each requested field; `HPERSIST` removes its deadline. These commands return a result per requested field, including missing-field and conditional-update outcomes.

```sh
redis-cli -p 6399 HEXPIRE demo:user 60 FIELDS 1 visits
redis-cli -p 6399 HTTL demo:user FIELDS 2 name visits
redis-cli -p 6399 HPERSIST demo:user FIELDS 1 visits
```

Expired fields disappear on access or active field-expiry maintenance. That maintenance runs up to ten times per second within the same time share as key expiry, which `active-expire-effort` raises, and deletes due fields in batches of up to 1,000; each batch emits one `hexpired` event for every hash it touched. When a change moves a hash's earliest field deadline by less than four seconds, maintenance keeps the time it had already scheduled, and `DUMP` and snapshots of a packed hash record that scheduled time. Replacing a field value with `HSET` clears that field's deadline; numeric updates preserve it. Deleting/expiring the whole key still removes all fields. Packed and table representations are internal choices; callers should use the logical replies and not depend on an `OBJECT ENCODING` result staying fixed as the hash grows.

Verify with `bash test/run_packages.sh`, `bash test/hashtype/compare.sh` and `./test/conformance/run.sh --suite redis --units type/hash,type/hash-field-expire`. The generated [command reference](commands.md) supplies option metadata and [conformance](conformance.md) records the tested scope.

Eski is an independent project, not affiliated with, endorsed or certified by Redis Ltd. Redis is a registered trademark of Redis Ltd.; any rights therein are reserved to Redis Ltd.
