# Build, run and test

## Build

The server uses Linux system calls and epoll. Its host implementation is Odin and its embedded Lua runtime is C, with the Lua MIT notice retained in [third-party notices](../THIRD_PARTY_NOTICES.md#lua515). The supplied container build targets Linux amd64 and pins its compiler archive and distribution packages in [Dockerfile](../Dockerfile). Native builds need Odin, clang, OpenSSL 3 and libunwind development libraries, GNU ar, sha256sum, flock and Python. On Ubuntu, the library development packages are `libssl-dev` and `libunwind-dev`; libunwind also depends on liblzma. Build scripts choose `ODIN` when set, then `odin` on PATH, then `$HOME/odin/current/odin`. The compiler selected must be executable; clang must be on PATH.

Run from the repository root:

```sh
./build.sh check
./build.sh
```

The build first verifies and compiles the pinned Lua 5.1.5 sources and permissively licensed helper modules from Valkey, local patches and protection shim vendored under `third_party/lua`. Normal native builds download nothing. Generated static archives live under `.build/lua`; unchanged, hash-verified dependencies are reused. `ESKI_LUA_CC` and `ESKI_LUA_AR` select the C compiler and archiver when needed.

`check` type-checks the source, test and benchmark packages with vet and strict style and scans Odin source for comments. The default build is the optimized release executable at `bin/eski`. `./build.sh debug`, `./build.sh sanitizer` and `./build.sh thread-sanitizer` replace that same output with a debug, address-sanitized or thread-sanitized build. The VM and shim are instrumented together for either sanitizer mode. Rebuild release before comparing performance. A compiler can be selected explicitly with `ODIN=/path/to/odin ./build.sh`.

Prepare dependencies before invoking Odin directly:

```sh
bash tools/build_lua.sh all
bash tools/build_diagnostics.sh all
```

Both helpers also accept `release`, `address` or `thread` to prepare one archive. Debug and ordinary builds use the release archives. The Odin bindings select the address or thread archives through `ODIN_SANITIZER_FLAGS` when the matching sanitizer is enabled. The original C diagnostic bridge builds separately under `.build/diagnostics` and dynamically links the system libunwind library. Its cache identity covers preprocessed header contents and the actual linked library. Keep `.build` beside `src` when copying the source into another build directory; the storage test driver preserves this layout automatically.

## Run and configure

```sh
mkdir -p /tmp/eski-data
./bin/eski --bind 127.0.0.1 --port 6399 --dir /tmp/eski-data
```

The default RESP port is 6399. Bind loopback explicitly for a local instance: the default configuration has neither authentication nor protected-mode enforcement enabled. Persistent files use `dir`, which must exist. Snapshot scheduling and append-only persistence are off until configured; see [persistence](persistence.md).

The command-line forms are:

```sh
./bin/eski
./bin/eski /path/to/eski.conf
./bin/eski /path/to/eski.conf --port 6399 --loglevel verbose
./bin/eski -
./bin/eski /path/to/eski.conf --port 6399 -
./bin/eski -v
./bin/eski --version
./bin/eski -h
./bin/eski --help
```

`-` requests configuration from standard input. Configuration options can be passed as `--name value`; the `-p` shortcut is accepted for `--port`. A configuration file uses whitespace-separated directives and supports quoted arguments. Command-line directives are applied through the same configuration loader. Check actual values with `CONFIG GET`; use [server management](server.md) for runtime changes and immutable or protected settings. The CLI version output includes the project licence, while protocol version fields retain their protocol meaning.

Optional LCS compute workers use `--compute-threads 2 --compute-max-memory 128mb`. They are disabled by default and both controls are startup-only. They parallelize eligible calculations over owned snapshots while the coordinator keeps keyspace and connection ownership. See [threading](threading.md) for fallback behavior, INFO counters and the current scope.

The separate keyspace pool executes eligible commands across all supported datatype families, including string options/TTL, atomic multi-key work and nonblocking stream groups. Enable it with `--keyspace-threads N` (0 through 64, default 0) and `--keyspace-max-memory N` (default 128 MiB; zero forces coordinator execution). Both are startup-only, hidden from wildcard CONFIG discovery and inspectable by exact name. The budget covers admitted worker allocations/reservations, not process RSS. AOF and observers retain ordered coordinator publication; blocked keys, Memcached metadata, actual pressure and global operations take coordinator boundaries. See [threading](threading.md#keyspace-workers) for precise admission and memory costs.

For example:

```sh
printf 'bind 127.0.0.1\nport 6399\nmaxmemory 256mb\nmaxmemory-policy allkeys-lru\n' | ./bin/eski -
```

## Container

```sh
docker build -t eski:local .
docker volume create eski-data
docker run --rm --name eski -p 127.0.0.1:6399:6399 \
  -v eski-data:/data eski:local --bind 0.0.0.0 --port 6399 --appendonly yes
```

The runtime image runs as its unprivileged Eski user and uses `/data`. A named volume preserves local persistence across replacement containers. `bench/image.sh` builds and verifies an image manifest and can export/import an image archive; use `bash bench/image.sh --help` for its options. Its source identity covers Odin source, the vendored Lua runtime and patches, and the dependency build scripts. The image's documentation directory carries the project and applicable third-party licence notices, and its build-info records the Lua source, manifest and compiled library hashes. The Ubuntu base and linked system libraries retain their distribution licences, including glibc's LGPL terms; the project's Apache-2.0 licence does not relicense those packages.

## Verification

```sh
bash test/run_packages.sh
./test/conformance/run.sh --suite redis --baseline test/conformance/baseline-redis.json
bash test/smoke.sh
```

The package runner prepares all three Lua archives, executes native unit packages in debug, address-sanitizer and release modes, then runs the Python harness drivers. It writes temporary test binaries and removes them on exit. Individual packages can be tested with `odin test src/listpack -debug`; drivers such as `python3 -I test/request_parser/run.py` include their own boundary and model checks.

The LCS driver can target a separate executable with `python3 -I test/threading/run.py --server /path/to/eski`. Current datatype coverage uses `python3 -I test/threading/full_keyspace.py --server /path/to/eski`; observer/AOF/blocked-key integration uses `python3 -I test/threading/features.py --server /path/to/eski`; memory/LFU/Memcached coverage uses `python3 -I test/compatibility/memory_threading.py --server /path/to/eski`. These correctness drivers never rebuild or benchmark the supplied binary. The feature driver skips only independent Redis replay unless `--reference-port PORT` names an explicitly disposable, empty local reference. The [threading coverage matrix](threading.md#keyspace-correctness-checks) describes each driver and sanitizer use. The package runner explicitly includes the broad datatype/feature, lifecycle, memory, transport, field-expiry AOF and Lua debugger drivers. Set `ESKI_TEST_BIN=/path/to/eski` when invoking `test/run_packages.sh` to select one existing candidate for server-based drivers; otherwise it uses `ESKI_THREADING_BIN` or `bin/eski`, with the legacy scripting-specific override preserved.

The scripting driver is `python3 -I test/scripting/run.py --server /path/to/eski`, with separate Function and debugger drivers under `test/functions` and `test/scripting`. The package runner uses `ESKI_TEST_BIN` for one prepared executable across server drivers, with the older per-driver environment settings retained as fallbacks. Cases cover source/cache behavior, persistent library state, command effects, persistence, ACL/read-only policy, Lua libraries, optional resource limits, BUSY/KILL lifetime, observers and worker boundaries. These drivers do not collect benchmarks. Reference-port modes require disposable reference instances and clear their data/cache state. See the [scripting verification commands](scripting.md#verification).

Qualification uses separate native, whole-node and upstream checkpoints. The counts below overlap between harnesses and should be read by row.

| Checkpoint | Recorded result |
| --- | --- |
| Native packages | 84 package/mode runs across debug, address-sanitizer and release, with 2,175 passing test executions. The affected main package was subsequently retested with its added logging regression: 36 cases in each mode. |
| Python package phase | All 44 driver runs passed on the prepared release candidate. This phase was executed separately from the native checkpoint. |
| Redis external-server suite | All 43 selected units passed with workers disabled and with two keyspace workers: 2,082 passes, zero failures, 137 skips and zero unit errors per run. All 1,504 historical baseline passes were preserved; the compared units now contain 1,528 passes. |
| Managed scripting and Functions | 433 passes, zero failures, 41 skips and zero unit errors across the two upstream units. |
| Managed command and server units | 2,233 passes, zero failures, 91 skips and zero unit errors across 51 units, including AOF rewrite, networking, client eviction, output buffers and shutdown. |
| Managed persistence integration | 104 passes with no failures, skips or unit errors across RDB, multipart AOF and AOF integration. Utility assertions used a separately supplied, pinned reference checker. |
| Smoke | 2,428 passes and zero failures with workers disabled and with two keyspace workers, including corrupt payloads, every datatype, persistence and Memcached. The optional benchmark step was disabled. |
| Whole-node sanitizers | Ten drivers passed in each of address-sanitizer and thread-sanitizer builds. Separate field-expiry/AOF/metadata checks passed across release and both sanitizers with workers disabled and enabled. |

The final build passed the affected main-package tests, configuration/logging stress, whole-node sanitizers and container checks after the logging concurrency and shutdown fixes. The broad upstream and smoke counts are from the preceding checkpoints; each run retains its own source and executable identity. Strict checking covers 52 packages. The broad container checkpoint passed 23 portable Lua cases, 19 Function cases and 168 functional assertions; subsequent image checks cover the final configuration/logging changes, transport, scripts, Functions and persistence replacements.

Managed mode starts isolated Eski processes from pristine, checksum-verified upstream test files. The adapter replaces Redis-specific readiness-log matching with actual endpoint readiness and omits unconditional distributed TLS setup. Test assertions remain unchanged. For example:

```sh
./test/conformance/run.sh --suite redis --managed --server "$PWD/bin/eski" \
  --units scripting,functions \
  --tags "-needs:repl -cluster -needs:cluster -large-memory"
```

The 51-unit managed run includes the curated 43 units plus `aofrw`, `client-eviction`, `obuf-limits`, `oom-score-adj`, `printver`, `replybufsize`, `shutdown` and `violations`. Use `--client /path/to/redis-cli` for tests that need the external CLI. Persistence integration selects `integration/rdb,integration/aof-multi-part,integration/aof`; utility assertions can use `--aof-checker test/conformance/aof_checker.py` with `ESKI_AOF_CHECKER_IMAGE` set to an immutable, already-local reference image ID or digest. The wrapper runs that utility without network access on owned fixture files and records its identity. The Eski server and runtime image bundle no Redis executable or server implementation source. `--tls` creates real managed fixture certificates and requires the native Tcl TLS package. See the runner's `--help` for exact selection and fixture options.

The recorded managed filter is `-needs:repl -cluster -needs:cluster -large-memory`; it does not suppress the broad `repl` tag. Modules, replication, Sentinel and Cluster are outside the product scope. Exact exclusions are recorded in `test/conformance/known-failures.txt`. Allocator and storage-representation assertions retain their actual semantics: Eski reports its own table/memory counts, and this libc build rejects active defragmentation instead of pretending to enable it. Skips, omitted units and resource limits do not establish coverage.

Two upstream JSON encoding cases over 2 GB remain unqualified after an isolated 14 GiB memory limit ended in a kernel OOM kill. Four separate upstream large escape-sequence/newline cases passed on the unchanged Lua runtime; they do not establish the JSON boundary. See [scripting verification](scripting.md#verification). Historical LCS measurements and the committed benchmark dataset describe their recorded source. Expanded keyspace/Lua performance benchmarking is deferred.

Conformance downloads the pinned upstream Tcl test suite and verifies its archive hash. It prefers a native Tcl interpreter and can use Docker when needed. `--baseline` fails when a previously passing test regresses. Without that option, the runner applies its stricter failure policy. It restarts Eski for each unit; `--external HOST:PORT` instead uses an existing server. Results and unit logs go to `test/conformance/results/`. See `./test/conformance/run.sh --help` for unit selection, tags, Tcl selection, ports and timeouts. The [generated conformance page](conformance.md) separates the baseline from the recorded expanded run and explains the recorded skips and coverage limits.

Run conformance before smoke on a fresh clone so smoke can use the downloaded corrupt-payload fixtures. Smoke starts its own Eski and reference containers, compares protocol replies, checks persistence and tests the memcached endpoint. `ESKI_SMOKE_PORT`, `ESKI_SMOKE_REF_PORT`, `ESKI_SMOKE_MC_PORT` and `ESKI_SMOKE_MC_REF_PORT` change its ports. `ESKI_REDIS_IMAGE` and `ESKI_MEMCACHED_IMAGE` select references. The optional `ESKI_SMOKE_BENCH=1` step is a functional benchmark invocation, not the dedicated comparison method.

Native comparison harnesses include `bash test/listtype/compare.sh`, `bash test/hashtype/compare.sh`, `bash test/settype/compare.sh`, `bash test/zsettype/compare.sh`, `bash test/bitmap/compare.sh`, `bash test/hll/compare.sh`, `bash test/geo/compare.sh` and `bash test/streamtype/compare.sh`. They build their drivers, start reference containers and compare generated operation sequences. Persistence-specific commands include `bash test/rdb/roundtrip.sh` and `bash test/aof/roundtrip.sh`. The group pages link the most relevant checks.

## Optional bitfield proofs

The standalone [bitfield proof pilot](../proofs/bitfield/README.md) uses a pinned Lean toolchain to check arithmetic and mutation-accounting properties of an executable model. Its comparison harness runs the model and the actual Odin bitmap package against an independent integer and bit-by-bit reference. The proof project is separate from the server build and introduces no server runtime dependency.

With the pinned Lean toolchain and Odin on PATH:

```sh
python3 proofs/bitfield/verify.py
```

The project documents its theorem domains, compatibility edge cases and implementation boundary. Model proofs and finite implementation comparisons provide different evidence; they do not establish formal verification of the compiled Odin server. Follow the project instructions to run its focused verification separately from the ordinary package and conformance suites.

## Generate the published tables

```sh
python3 -I test/readme_tables.py
python3 -I test/readme_tables.py --check
```

The generator queries `COMMAND DOCS` from a temporary Eski instance, reads the tracked baseline and observed conformance snapshot, and reads `bench/testbed/runs/comparison-v1/dataset.json`. It updates the generated pages, README tables and SVG badges. Check mode reports drift without changing those files. It cleans up the temporary server; `--server HOST:PORT` uses an existing instance instead, and `--server-binary PATH` selects another binary.

After a real conformance run, refresh its sanitized published snapshot with:

```sh
python3 -I test/readme_tables.py --record-conformance test/conformance/results/latest-redis.json
python3 -I test/readme_tables.py --check
```

The inputs can be selected with `--baseline PATH`, `--observed-conformance PATH` and `--benchmark-results DIRECTORY_OR_DATASET_JSON`. The generated tables are historical measurements from those inputs, not a substitute for running the current tree's checks.

## Benchmark and exam workflow

`bash bench/run.sh --help` describes native and container targets, scenario selection, specification cases, plan files and CPU/memory overrides. A quick functional run is `bash bench/run.sh --quick --targets eski --scenarios get_p1 --label local`; use the scenario names printed by its help if changing that selection. `bash bench/pts.sh --help` describes the fixed profile invocations.

The dedicated-machine workflow is defined by `bench/testbed/design.json`. `python3 -I bench/testbed/plans.py --out /tmp/eski-plans` renders plans. `python3 -I bench/testbed/install.py install --help` describes installation over SSH; installation creates a new run root and does not start it. The installed `exam.sh` starts once on its first no-argument invocation; later no-argument calls show status. Use `exam.sh status`, `inspect`, `resume` and `collect` according to `exam.sh help`. Do not treat repeated invocations as independent runs.

Use `python3 -I bench/testbed/collect.py --help` for receipt-verified collection. `combine.py` produces the dataset, `charts.py` renders SVGs and `page.py` builds the standalone report. Every tool exposes its required paths with `--help`. The [benchmark page](benchmarks.md) describes the committed run's workload, equal resource assignments, exclusions and client-limited observations.
