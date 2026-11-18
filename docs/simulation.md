# Deterministic simulation and native AOF restart

Run from the repository root on Linux with the normal Eski build dependencies and Python 3.11 or later. The simulator builds a separate executable with `ESKI_SIMULATION` enabled. Each case starts a fresh worker so its engine globals, virtual time and simulated file state start clean.

```sh
work=$(mktemp -d)
python3 -IB test/simulation/exercise.py build --output "$work/eski-simulation"
python3 -IB test/simulation/exercise.py virtual --binary "$work/eski-simulation" \
  --out "$work/virtual" --first-seed 8 --seeds 1 --steps 2
```

Each seed has seven worker traces. `summary.json` records the binary hash, host metadata, effective settings and outcome outside the traces. The runner compares the visible reply lines in each pair of label and owner traces. A failed worker records its seed, chronological events and failed property. Its stderr has a separate file. A failing worker does not stop the run: every seed runs, `completed_seeds` counts the seeds whose seven workers all passed, `failed_seeds` lists the others and `failures` holds one row per failing worker with its seed, case, variant, step count, trace and stderr file names, the error and the command that replays it. `--max-failures N` (default 64, 0 for no limit) stops after that many failing workers and says so in `stopped_early`, so a worker that fails everywhere cannot hold the host for every seed's timeout. To replay one case or compare traces byte for byte, use the same worker, case, seed, step count and variant.

```sh
"$work/eski-simulation" network 8 2 base > "$work/replay.trace"
cmp "$work/virtual/8-network-base.trace" "$work/replay.trace"
"$work/eski-simulation" labels 8 2 hidden
```

| Case | Exercised behavior |
| --- | --- |
| `network` | Seeded delayed fragments and bounded writes through the normal RESP and memcached parser, dispatch and reply paths. Mixed pipelines, string and hash writes, JSON paths, a hash text index, a counter model with transactions, shared memcached values and virtual expiry. Reset and write-side half-close occur after completed exchanges. |
| `disk` | Shared change-log framing, recovery and cursor reads on a bounded virtual disk. File data and directory entries have separate durable state. Short writes, write and sync errors, a lying sync, sector-bounded append tears, truncate failures, segment rolling, retention and complete-record checksum failure exercise the same log code used with a real directory. The prefix oracle checks the true durable boundary, including when the device reports a successful sync it did not perform. |
| `restart` | Actual canonical AOF mutation batches enter the virtual change log with their starting database. A whole `MULTI` group survives a simulated crash and reload through the real AOF command loader. A deliberately lying final sync leaves an incomplete tail outside the recovered state. The loaded database agrees with the observed results of the durable batches. |
| `labels`, `owners` | Authenticated scope twins compare exact visible replies with and without additional hidden application keys. Both twins read the same visible value and observe the shadow key as missing. |

Virtual I/O covers the single-threaded engine, the simulated wall and monotonic clock, and the change-log disk interface. TLS, real sockets and epoll, worker concurrency, electrical power loss, kernel writeback and physical device guarantees are outside this model. The virtual AOF capture uses the production canonical command bytes. The production change log mirrors successful AOF writes and starts a new epoch on restart. The AOF remains responsible for production recovery. [Change log](change-log.md)

## Native restart check

Run with a stock Eski executable built from the same source. The fixture creates a private data directory and starts only loopback servers. It uses `appendfsync always`, disables periodic snapshots and automatic rewrites, acknowledges ordinary Redis transactions, then kills each generation and verifies the reopened AOF. Every committed transaction updates two string keys. An acknowledged queue entry without `EXEC` must remain absent. Process termination exercises the real filesystem syscalls and replay paths while the native OS continues running.

```sh
python3 -IB test/simulation/exercise.py native --binary ./bin/eski \
  --out "$work/native" --ports 7850-7859 --cycles 1 --transactions 3
```

The native output retains `native.trace`, `summary.json`, the server log and disposable AOF data. Choose an unused port range when other local test jobs share the host. If `--ports` is omitted the fixture chooses ephemeral loopback ports. Each output directory must be new. For a longer run, raise virtual `--seeds` and `--steps`, and native `--cycles` and `--transactions`. Virtual `--measure` records the rate of generated model iterations, including worker startup and trace I/O. The fixed disk and restart work contributes to elapsed time while the iteration count covers the network scenario and the four scope workers.
