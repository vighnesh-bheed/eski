# Server management

`CONFIG GET pattern ...` inspects settings, `CONFIG SET name value ...` applies eligible runtime changes, `CONFIG RESETSTAT` resets statistics, and `CONFIG REWRITE` writes supported settings back to the startup configuration file. A runtime change does not automatically persist to that file. Immutable settings require restart; protected settings have an additional configuration gate. Invalid values are rejected by the same typed configuration definitions used at startup. See [build and run](build-run-test.md) for files, stdin and CLI overrides.

```sh
redis-cli -p 6399 CONFIG GET maxmemory maxmemory-policy appendonly
redis-cli -p 6399 CONFIG SET maxmemory 256mb maxmemory-policy allkeys-lru
redis-cli -p 6399 INFO memory
redis-cli -p 6399 DBSIZE
```

`DBSIZE` counts keys in the selected database. `FLUSHDB` and `FLUSHALL` remove one or every local database and accept synchronous/asynchronous release modes. `SWAPDB` swaps two local databases. These commands can invalidate watched keys and client-side caches. Use them with the permissions and data-loss consequences appropriate to the application.

Lua uses dynamic `lua-max-memory`, `lua-max-output`, `lua-max-bridge-memory` and `lua-max-cache-memory` controls with a 4096-byte minimum. Output defaults to 512 MiB; the other three default to the host signed-integer maximum, so applications can configure explicit budgets. Inspect them by exact CONFIG GET names; wildcard discovery omits them. They bound requested VM, output, bridge and source-cache bytes rather than process RSS. `busy-reply-threshold` (`lua-time-limit`) defaults to 5000 ms and enables restricted BUSY/KILL service after that threshold. Zero disables this service, so ordinary shutdown waits for script completion. The [scripting guide](scripting.md#optional-resource-controls) explains errors, signals and the post-write no-save escape.

`set-proc-title yes` is the startup default and updates Linux process listings from `proc-title-template`; runtime template changes refresh the displayed title. Placeholders include `{title}`, `{listen-addr}`, `{port}`, `{tls-port}`, `{unixsocket}`, `{config-file}` and `{server-mode}`. The title retains the executable launch name, while the listen address identifies the TCP/TLS listener or Unix socket. `set-proc-title no` preserves the original command line.

## Runtime configuration

Startup and runtime logger messages obey `loglevel` and use `logfile` when configured. `syslog-enabled yes` also sends normal logger messages through libc syslog, using `syslog-ident` and `syslog-facility`. `always-show-logo yes` emits Eski's startup logo through that logger.

`supervised systemd` uses `NOTIFY_SOCKET` for readiness and graceful-stop notifications, including Linux abstract sockets whose names begin with `@`. `supervised upstart` uses the `UPSTART_JOB` environment and the stop/continue readiness handshake. `supervised auto` detects those environments, preferring Upstart when both are present. A detected supervisor suppresses daemonization. A missing or invalid supervisor environment produces a warning and leaves the process unsupervised; `INFO server` reports the selected mode in `process_supervised`.

`disable-thp yes`, the default, disables transparent huge pages for this process through Linux `prctl`; it leaves the host-wide policy alone. `socket-mark-id` requests Linux `SO_MARK` on TCP listeners and outgoing MIGRATE sockets. A nonzero mark needs the relevant kernel capability; failure is logged. `bind-source-addr` remains accepted distributed configuration metadata: the reference uses it for replication and related excluded connections, and it does not change MIGRATE's connection source or cache.

`server-cpulist` applies CPU affinity to the coordinator before worker creation. `bio-cpulist` applies to the actual AOF and lazy-free background threads; `bgsave-cpulist` and `aof-rewrite-cpulist` apply to their corresponding forked children. Lists accept CPU numbers, comma-separated ranges and range strides such as `0-6:2`. Empty lists retain inherited affinity. Invalid syntax or a mask rejected by the kernel produces a warning and preserves inherited affinity.

`activerehashing` controls idle coordinator database-table migration. Request-driven migration and maintenance inside individual data types continue independently. `activedefrag yes` is explicitly rejected because the libc allocator lacks the required relocation support; `jemalloc-bg-thread` remains allocator compatibility metadata in this build. Socket I/O stays on the coordinator; compatibility `io-threads` settings do not select the [compute or keyspace workers](threading.md).

## Memory and eviction

`maxmemory 0` is unlimited. A nonzero value works with `maxmemory-policy`: `noeviction`, `allkeys-lru`, `allkeys-lfu`, `allkeys-random`, `volatile-lru`, `volatile-lfu`, `volatile-random` or `volatile-ttl`. Volatile policies consider expiring keys. LRU/LFU policies use sampled/access metadata rather than a complete sorted history. `maxmemory-samples` and eviction effort settings affect this work. When no eligible key can be evicted, allocation-requiring writes can fail.

This accounting limit is not an operating-system RSS limit. Allocator capacity, fragmentation, connection buffers and persistence/fork overhead can make process or container usage differ from reported key memory. `MEMORY USAGE`, `STATS`, `DOCTOR` and `PURGE` expose diagnostics/maintenance; `MEMORY MALLOC-STATS` reports that allocator statistics are unavailable. `INFO memory` has a documented overhead-accounting difference in the baseline. Lazy-free settings and `UNLINK` move eligible release work out of the immediate operation, but do not make every deletion constant-time.

## Introspection and diagnostics

`COMMAND`, `COMMAND COUNT`, `LIST`, `INFO`, `DOCS`, `GETKEYS` and `GETKEYSANDFLAGS` describe the command registry and its key specifications. Generated [commands](commands.md) come from `COMMAND DOCS`; registered compatibility commands still need the limitations stated here. `INFO` offers server, clients, memory, persistence, stats, commandstats, latencystats, keyspace and other supported sections. Field presence is not a claim that replication or clustering exists.

`TIME` returns server time. `SLOWLOG` supports `GET`, `LEN` and `RESET`; `LATENCY` supports event/history, graph, doctor, reset and histogram diagnostics. Configure the relevant thresholds before expecting samples. `MONITOR` streams observed commands and can impose significant output work. `DEBUG` is disabled by default and intended for development/testing; its availability is controlled by `enable-debug-command`.

### Native watchdog and crash reports

`watchdog-period` sets an automatic diagnostic threshold in milliseconds; zero disables automatic reports. The watchdog watches active coordinator work and is disarmed during idle waits. A manual `SIGALRM` requests a nonfatal report even with the automatic watchdog disabled. `crash-log-enabled` controls native report output. Reports contain actual Eski stack addresses and available executable symbols; stripped binaries retain address traces. Sanitizer builds preserve their sanitizer fatal-signal handlers.

The reporter records the coordinator command name, argument count and bounded argument sizes, without argument contents. `hide-user-data-from-log yes` also redacts those sizes. `crash-memcheck-enabled` enables a bounded check of the reporter's owned read-only scratch region; dataset and general heap validation are outside that check. `use-exit-on-panic yes` selects exit status 1 for controlled assertion/panic paths. `DEBUG LOG message` writes a normal warning-level message when DEBUG is enabled. The [build instructions](build-run-test.md) describe the native diagnostic dependency and verification commands.

`FUNCTION` loads, lists, deletes, flushes, dumps and restores executable libraries; `FCALL` and `FCALL_RO` invoke their registered functions. Lua evaluation, persistent libraries and interactive debugging use the documented [scripting API](scripting.md). Modules, replication, Sentinel and Cluster remain excluded even where a config name or metadata category is accepted. The separate Rust coordination product is not part of this executable.

Verify with `bash test/run_packages.sh`, `bash test/smoke.sh` and `./test/conformance/run.sh --suite redis --units info,info-command,introspection,introspection-2,latency-monitor,slowlog,limits,maxmemory,memefficiency,lazyfree`. [Conformance](conformance.md) distinguishes accounting/introspection differences from tests requiring excluded features.

Eski is an independent project, not affiliated with, endorsed or certified by Redis Ltd. Redis is a registered trademark of Redis Ltd.; any rights therein are reserved to Redis Ltd.
