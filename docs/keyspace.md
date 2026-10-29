# Keyspace

Each connection selects one logical database with `SELECT`; keys are binary-safe names in that database. `EXISTS`, `TYPE`, `TOUCH` and `OBJECT` inspect them. `DEL` deletes immediately and `UNLINK` schedules eligible storage for lazy release. `RENAME` replaces a destination; `RENAMENX` requires the destination to be absent. `COPY` accepts `DB` and `REPLACE`, and `MOVE` moves a key to another logical database. These are local databases in one process.

## Expiry

`EXPIRE`/`PEXPIRE` set relative seconds/milliseconds; `EXPIREAT`/`PEXPIREAT` set absolute deadlines. `NX`, `XX`, `GT` and `LT` condition the change. `TTL` and `PTTL` return remaining time, while `EXPIRETIME` and `PEXPIRETIME` return an absolute deadline. Their negative sentinel replies distinguish a missing key from a persistent key. `PERSIST` removes a key's expiry. Expiry is checked on access and through an active sweep; a deadline is not a scheduling guarantee for delivery of an event.

```sh
redis-cli -p 6399 SET demo:temporary value
redis-cli -p 6399 EXPIRE demo:temporary 60 NX
redis-cli -p 6399 TTL demo:temporary
redis-cli -p 6399 COPY demo:temporary demo:copy REPLACE
redis-cli -p 6399 PERSIST demo:copy
redis-cli -p 6399 TYPE demo:copy
```

## Discovery and sorting

`KEYS pattern` visits the keyspace and returns the matching names in one reply. `RANDOMKEY` chooses a present key. `SCAN cursor` supports `MATCH`, `COUNT` and `TYPE`; continue until its returned cursor is zero. `COUNT` is a work hint. Scanning while the keyspace changes can return duplicates and is not a snapshot, so applications should tolerate repeated names.

`SORT` and `SORT_RO` accept ascending/descending numeric or `ALPHA` ordering, `LIMIT`, `BY` and `GET` patterns. `SORT` can write a result with `STORE`; `SORT_RO` cannot. External lookups require permission for their key patterns. Ordering and window membership for tied sort values have known differences from reference behaviour; do not depend on an unspecified tie order. Package checks include ACL and inline/encoded-value cases.

`WAIT` and `WAITAOF` are compatibility commands, not replication. `WAIT` validates arguments and reports zero replicas. `WAITAOF` can wait for local AOF synchronization and reports zero replica acknowledgements; requesting a local acknowledgement with AOF disabled is an error. See [persistence](persistence.md).

Verify storage/expiry/sort ownership with `bash test/run_packages.sh`, and run `./test/conformance/run.sh --suite redis --units keyspace,expire,sort`. Some selected tests require excluded replication or scripting; [conformance](conformance.md) records those separately from implementation differences.
