# Lists

Lists store ordered byte strings and allow duplicates. `LPUSH`, `RPUSH`, `LPUSHX` and `RPUSHX` add elements; `LINSERT` adds relative to a pivot. `LLEN`, `LINDEX`, `LRANGE` and `LPOS` inspect a list. `LSET`, `LTRIM` and `LREM` replace or remove elements. Index/range commands accept negative positions from the tail, and range endpoints are inclusive.

`LPOP` and `RPOP` accept an optional count. `LMPOP` searches keys in order and pops from the requested `LEFT` or `RIGHT` end, with optional `COUNT`. `LMOVE` selects the source and destination ends; `RPOPLPUSH` is its right-to-left compatibility form. A move can use the same key as both source and destination.

```sh
redis-cli -p 6399 RPUSH demo:queue first second third
redis-cli -p 6399 LRANGE demo:queue 0 -1
redis-cli -p 6399 LPOS demo:queue second RANK 1 COUNT 1
redis-cli -p 6399 LMOVE demo:queue demo:processing LEFT RIGHT
redis-cli -p 6399 LPOP demo:queue 2
```

## Blocking operations

`BLPOP`, `BRPOP`, `BLMPOP`, `BLMOVE` and `BRPOPLPUSH` wait when no eligible source element exists. Timeouts accept fractional seconds; zero waits without a timeout. Relevant writes wake waiting clients, and a disconnected client releases its wait state. Use two terminals to try `BLPOP demo:jobs 5` and then `RPUSH demo:jobs work`.

Blocking commands inside `MULTI`/`EXEC` do not suspend execution while waiting for another client; an unavailable element produces the command's immediate empty result. Multi-key operations inspect their key list in order. List removal, expiry and destination wrong-type errors must be handled as part of the application protocol rather than assuming every wakeup returns work.

Large indexed/range/removal operations can traverse many elements on the foreground loop. These lists provide local queue primitives, not replicated delivery or consumer acknowledgement. Use [streams](streams.md) when pending-entry tracking is needed.

Verify with `bash test/listtype/compare.sh`, `bash test/run_packages.sh` and `./test/conformance/run.sh --suite redis --units type/list,type/list-2,type/list-3`. The recorded expanded suite includes a real dirty-counter difference involving blocked list moves/pops, plus tests requiring replication. See [conformance](conformance.md) for the exact cases.
