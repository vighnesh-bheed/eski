# Transactions and blocking

`MULTI` begins a queue of commands on one connection. Valid commands reply `QUEUED` until `EXEC` runs the queue or `DISCARD` drops it. Execution does not interleave another foreground client's commands. A command rejected while queuing can make the transaction abort at `EXEC`. A runtime error appears in that command's result slot; earlier successful changes remain applied and later queued commands can still run. There is no rollback.

Use one persistent client connection for this example; separate `redis-cli` invocations do not share transaction state:

```text
MULTI
SET demo:balance 100
INCRBY demo:balance 25
GET demo:balance
EXEC
```

## Optimistic checks

`WATCH key ...` marks keys before reading them. A relevant change, including deletion or expiry, invalidates the watch and causes `EXEC` to return an aborted/null transaction reply. `UNWATCH`, successful execution or discarding the transaction clears watched state. Watch the keys, read them, calculate the proposed change, then queue and execute it on the same connection. Retry after an aborted transaction. This protects the watched-key condition; it does not create general snapshot isolation for unrelated keys.

```text
WATCH demo:balance
GET demo:balance
MULTI
SET demo:balance 150
EXEC
```

`SELECT` changes the connection's selected local database. Keep database changes explicit when designing transactions and watches. A reconnect creates a fresh connection without the old queued or watched state.

## Blocking commands

Blocking list, sorted-set and stream reads register a wait when used normally. Timeouts or relevant mutations wake the connection, and disconnect cleanup releases its wait state. A blocking command executed from a transaction does not pause the transaction until another client writes; it returns its immediate result when no eligible data is available. `CLIENT UNBLOCK` can end a client's wait using timeout or error behaviour.

Atomic foreground execution is separate from durability. A successful `EXEC` does not acknowledge a replica, and local AOF synchronization depends on [persistence settings](persistence.md). Lua and executable functions are excluded; applications cannot submit server-side scripts to combine arbitrary logic here.

Verify with `bash test/run_packages.sh`, `bash test/smoke.sh` and `./test/conformance/run.sh --suite redis --units multi,type/list-2,type/zset,type/stream-cgroups`. The [conformance report](conformance.md) records remaining supported-behaviour differences and tests requiring excluded features.
