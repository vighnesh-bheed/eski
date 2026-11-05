# Sets

Sets contain unique binary-safe members without an application-visible order. `SADD` and `SREM` change membership; `SMOVE` transfers one member between keys. `SISMEMBER`, `SMISMEMBER`, `SCARD` and `SMEMBERS` inspect a set. Removing its last member removes the key. An operation that requires a set rejects a key of another type.

```sh
redis-cli -p 6399 SADD demo:team Ada Grace Katherine
redis-cli -p 6399 SADD demo:oncall Grace Linus
redis-cli -p 6399 SMISMEMBER demo:team Ada Linus
redis-cli -p 6399 SINTER demo:team demo:oncall
redis-cli -p 6399 SUNIONSTORE demo:everyone demo:team demo:oncall
```

`SINTER`, `SUNION` and `SDIFF` return intersection, union and difference. Their `...STORE` variants replace a destination set. `SINTERCARD numkeys key ...` computes an intersection count and accepts `LIMIT` to stop once the count reaches a bound. Key order matters for difference: the first set supplies candidates removed by later sets.

`SPOP` removes one random member or an optional number of distinct members. `SRANDMEMBER` samples without removal; a positive count requests distinct members, while a negative count allows repeats. Sampling is unsuitable as a reproducible order or a cryptographic randomness interface.

`SSCAN key cursor` supports `MATCH` and `COUNT`. Continue with each returned cursor until zero, and tolerate duplicates while data changes. A packed/integer representation may return many members in one step; `COUNT` remains a hint. `SMEMBERS` and the non-store algebra commands can create large replies, so prefer scans or bounded work when the data size is uncertain.

Storage can switch between compact and indexed representations as values change. The key remains a set across those transitions; internal encoding names and member iteration order are not application contracts.

Verify with `bash test/settype/compare.sh`, `python3 -I test/settype/run.py`, `bash test/run_packages.sh` and `./test/conformance/run.sh --suite redis --units type/set`. The [command reference](commands.md) lists supported forms and [conformance](conformance.md) qualifies compatibility claims.
