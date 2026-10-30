# Persistence

Eski offers local RDB snapshots and append-only files (AOF). Neither is enabled as an automatic durability policy in a fresh configuration: there are no default scheduled snapshot points and `appendonly` is off. Choose a writable existing `dir`; the default snapshot name is `dump.rdb`. A matching persistence file can be loaded at startup even when no automatic snapshot schedule is configured.

## Snapshots

`SAVE` writes a synchronous snapshot and can block foreground work. `BGSAVE` uses a background child; `BGSAVE SCHEDULE` can schedule work when another persistence child is active. `LASTSAVE` and `INFO persistence` expose status. Set `save seconds changes` rules for scheduled snapshots. `stop-writes-on-bgsave-error` can reject writes after a configured snapshot failure, so monitor failures rather than treating the last client write reply as a successful backup.

```sh
mkdir -p /tmp/eski-data
./bin/eski --bind 127.0.0.1 --port 6399 --dir /tmp/eski-data --save 60 1000
```

From another terminal, write a value, request `BGSAVE`, wait for `INFO persistence` to show completion and then verify a controlled restart. Background work still has fork, copy-on-write, memory and I/O costs. Keep backups separately from a working directory that an operator can overwrite.

## Append-only files

`appendonly yes` enables an AOF in `appenddirname` (default `appendonlydir`) using `appendfilename` (default `appendonly.aof`) and its manifest/base/incremental files. `appendfsync always`, `everysec` or `no` selects synchronization policy; the default is `everysec`. A successful write reply is not necessarily an fsync acknowledgement with the latter policies. Preserve the whole AOF directory rather than selecting a single file from an active multi-file set.

```sh
./bin/eski --bind 127.0.0.1 --port 6399 --dir /tmp/eski-data \
  --appendonly yes --appendfsync everysec
```

`BGREWRITEAOF` compacts the log with a background rewrite; related rewrite thresholds and incremental-fsync options tune scheduling/I/O. Startup validates manifests and payloads and applies the configured truncated-tail policy. Inspect logs and `INFO persistence` when a load/rewrite fails. `WAITAOF` can request local AOF synchronization, but reports zero replica acknowledgements; a local request fails if AOF is disabled. `WAIT` likewise reports no replicas. No network replication exists.

[Lua evaluation](scripting.md) records translated command effects, including successful writes before a later script error, rather than EVALSHA or cached source. Script effects form an AOF group and join an enclosing MULTI group; relative expiry keeps its absolute deadline on replay. The source cache is ephemeral and absent from RDB/AOF, so a restart can return NOSCRIPT even when the script's stored data was restored.

## Payload transfer and shutdown

`DUMP` returns a serialized key payload without its key TTL. `RESTORE key ttl payload` validates that payload and accepts `REPLACE`, `ABSTTL`, `IDLETIME` and `FREQ` under their option checks. Use a binary-safe client. `MIGRATE` transfers keys to another endpoint using payload restore, with `COPY`, `REPLACE`, `AUTH`, `AUTH2` and multi-key `KEYS` forms. Transfer is an explicit client operation; it does not establish continuous replication or cluster failover.

`SHUTDOWN` supports save/no-save and related shutdown controls. A deliberate `NOSAVE` can discard changes not present in durable files. Never use shutdown or restore as an unreviewed probe against an existing instance.

Verify with `bash test/rdb/roundtrip.sh`, `bash test/aof/roundtrip.sh`, `bash test/run_packages.sh`, `bash test/smoke.sh` and `./test/conformance/run.sh --suite redis --units dump`. These include codec, ownership, restart and corruption cases. The [build/test guide](build-run-test.md) explains how smoke obtains corrupt-payload comparison fixtures.
