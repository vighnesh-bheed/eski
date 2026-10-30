# Server management

`CONFIG GET pattern ...` inspects settings, `CONFIG SET name value ...` applies eligible runtime changes, `CONFIG RESETSTAT` resets statistics, and `CONFIG REWRITE` writes supported settings back to the startup configuration file. A runtime change does not automatically persist to that file. Immutable settings require restart; protected settings have an additional configuration gate. Invalid values are rejected by the same typed configuration definitions used at startup. See [build and run](build-run-test.md) for files, stdin and CLI overrides.

```sh
redis-cli -p 6399 CONFIG GET maxmemory maxmemory-policy appendonly
redis-cli -p 6399 CONFIG SET maxmemory 256mb maxmemory-policy allkeys-lru
redis-cli -p 6399 INFO memory
redis-cli -p 6399 DBSIZE
```

`DBSIZE` counts keys in the selected database. `FLUSHDB` and `FLUSHALL` remove one or every local database and accept synchronous/asynchronous release modes. `SWAPDB` swaps two local databases. These commands can invalidate watched keys and client-side caches. Use them with the permissions and data-loss consequences appropriate to the application.

Lua uses dynamic `lua-max-memory`, `lua-max-output`, `lua-max-bridge-memory` and `lua-max-cache-memory` controls, defaulting to 64/16/32/32 MiB with a 4096-byte minimum. Inspect them by exact CONFIG GET names; wildcard discovery omits them. They bound requested VM, output, bridge and source-cache bytes rather than process RSS. `busy-reply-threshold` (`lua-time-limit`) defaults to 5000 ms and enables restricted BUSY/KILL service after that threshold. Zero disables this service, so ordinary shutdown waits for script completion. The [scripting guide](scripting.md#resource-and-cancellation-controls) explains errors, signals and the post-write no-save escape.

## Memory and eviction

`maxmemory 0` is unlimited. A nonzero value works with `maxmemory-policy`: `noeviction`, `allkeys-lru`, `allkeys-lfu`, `allkeys-random`, `volatile-lru`, `volatile-lfu`, `volatile-random` or `volatile-ttl`. Volatile policies consider expiring keys. LRU/LFU policies use sampled/access metadata rather than a complete sorted history. `maxmemory-samples` and eviction effort settings affect this work. When no eligible key can be evicted, allocation-requiring writes can fail.

This accounting limit is not an operating-system RSS limit. Allocator capacity, fragmentation, connection buffers and persistence/fork overhead can make process or container usage differ from reported key memory. `MEMORY USAGE`, `STATS`, `DOCTOR` and `PURGE` expose diagnostics/maintenance; `MEMORY MALLOC-STATS` reports that allocator statistics are unavailable. `INFO memory` has a documented overhead-accounting difference in the baseline. Lazy-free settings and `UNLINK` move eligible release work out of the immediate operation, but do not make every deletion constant-time.

## Introspection and diagnostics

`COMMAND`, `COMMAND COUNT`, `LIST`, `INFO`, `DOCS`, `GETKEYS` and `GETKEYSANDFLAGS` describe the command registry and its key specifications. Generated [commands](commands.md) come from `COMMAND DOCS`; registered compatibility commands still need the limitations stated here. `INFO` offers server, clients, memory, persistence, stats, commandstats, latencystats, keyspace and other supported sections. Field presence is not a claim that replication or clustering exists.

`TIME` returns server time. `SLOWLOG` supports `GET`, `LEN` and `RESET`; `LATENCY` supports event/history, graph, doctor, reset and histogram diagnostics. Configure the relevant thresholds before expecting samples. `MONITOR` streams observed commands and can impose significant output work. `DEBUG` is disabled by default and intended for development/testing; its availability is controlled by `enable-debug-command`.

`FUNCTION` provides compatibility replies for an empty library set; it cannot load or execute application functions. Lua evaluation uses the documented [scripting subset](scripting.md); modules, replication, Sentinel and Cluster remain excluded even where a config name or metadata category is accepted. The separate Rust coordination product is not part of this executable.

Verify with `bash test/run_packages.sh`, `bash test/smoke.sh` and `./test/conformance/run.sh --suite redis --units info,info-command,introspection,introspection-2,latency-monitor,slowlog,limits,maxmemory,memefficiency,lazyfree`. [Conformance](conformance.md) distinguishes accounting/introspection differences from tests requiring excluded features.
