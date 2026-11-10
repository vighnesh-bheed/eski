# Build, run and test

## Build

The server uses Linux system calls and epoll. Its host implementation is Odin and its embedded Lua runtime is C, with the Lua MIT notice retained in [third-party notices](../THIRD_PARTY_NOTICES.md#lua515). The supplied container build targets Linux amd64 and pins its compiler archive and distribution packages in [Dockerfile](../Dockerfile). Native builds need Odin, clang, OpenSSL 3 and libunwind development libraries, GNU ar, sha256sum, flock and Python. On Ubuntu, the library development packages are `libssl-dev` and `libunwind-dev`; libunwind also depends on liblzma. The label and owner test drivers also need the `openssl` command line of OpenSSL 3, which signs their tokens; on Ubuntu it is the `openssl` package. Build scripts choose `ODIN` when set, then `odin` on PATH, then `$HOME/odin/current/odin`. The compiler selected must be executable; clang must be on PATH.

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

The compiler's default target for amd64 is x86-64-v2, so every build needs a processor with SSE4.2 and POPCNT. The vector kernels of the vector set type pick a faster path at run time from the processor's CPUID and XGETBV reports: AVX2 when FMA, POPCNT and F16C are also present, then AVX-VNNI and AVX-VNNI-INT8 for 8-bit vectors, and a portable path otherwise. Graph traversal uses the fastest available kernel, while the scores that VSIM reports are computed in one fixed summation order on every path, so they do not depend on the processor.

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

The LCS driver can target a separate executable with `python3 -I test/threading/run.py --server /path/to/eski`. Current datatype coverage uses `python3 -I test/threading/full_keyspace.py --server /path/to/eski`; observer/AOF/blocked-key integration uses `python3 -I test/threading/features.py --server /path/to/eski`; memory/LFU/Memcached coverage uses `python3 -I test/compatibility/memory_threading.py --server /path/to/eski`. These correctness drivers never rebuild or benchmark the supplied binary. The feature driver skips only independent reference-server replay unless `--reference-port PORT` names an explicitly disposable, empty local reference. The [threading coverage matrix](threading.md#keyspace-correctness-checks) describes each driver and sanitizer use. The package runner explicitly includes the broad datatype/feature, lifecycle, memory, transport, field-expiry AOF and Lua debugger drivers. Set `ESKI_TEST_BIN=/path/to/eski` when invoking `test/run_packages.sh` to select one existing candidate for server-based drivers; otherwise it uses `ESKI_THREADING_BIN` or `bin/eski`, with the legacy scripting-specific override preserved.

The scripting driver is `python3 -I test/scripting/run.py --server /path/to/eski`, with separate Function and debugger drivers under `test/functions` and `test/scripting`. The package runner uses `ESKI_TEST_BIN` for one prepared executable across server drivers, with the older per-driver environment settings retained as fallbacks. Cases cover source/cache behavior, persistent library state, command effects, persistence, ACL/read-only policy, Lua libraries, optional resource limits, BUSY/KILL lifetime, observers and worker boundaries. These drivers do not collect benchmarks. Reference-port modes require disposable reference instances and clear their data/cache state. See the [scripting verification commands](scripting.md#verification).

Qualification uses separate native, whole-node and upstream checkpoints. The counts below overlap between harnesses and should be read by row.

| Checkpoint | Recorded result |
| --- | --- |
| Native packages | 84 package/mode runs across debug, address-sanitizer and release, with 2,175 passing test executions. The affected main package was subsequently retested with its added logging regression: 36 cases in each mode. |
| Python package phase | All 44 driver runs passed on the prepared release candidate. This phase was executed separately from the native checkpoint. |
| Upstream conformance suite, external-server mode | All 43 selected units passed with workers disabled and with two keyspace workers: 2,082 passes, zero failures, 137 skips and zero unit errors per run. All 1,504 historical baseline passes were preserved; the compared units now contain 1,528 passes. |
| Managed scripting and Functions | 433 passes, zero failures, 41 skips and zero unit errors across the two upstream units. |
| Managed command and server units | 2,233 passes, zero failures, 91 skips and zero unit errors across 51 units, including AOF rewrite, networking, client eviction, output buffers and shutdown. |
| Managed persistence integration | 104 passes with no failures, skips or unit errors across RDB, multipart AOF and AOF integration. Utility assertions used a separately supplied, pinned reference checker. |
| Smoke | 2,428 passes and zero failures with workers disabled and with two keyspace workers, including corrupt payloads, every datatype, persistence and Memcached. The optional benchmark step was disabled. |
| Whole-node sanitizers | Ten drivers passed in each of address-sanitizer and thread-sanitizer builds. Separate field-expiry/AOF/metadata checks passed across release and both sanitizers with workers disabled and enabled. |

The final build passed the affected main-package tests, configuration/logging stress, whole-node sanitizers and container checks after the logging concurrency and shutdown fixes. The broad upstream and smoke counts are from the preceding checkpoints; each run retains its own source and executable identity. Strict checking covers 52 packages. The broad container checkpoint passed 23 portable Lua cases, 19 Function cases and 168 functional assertions; subsequent image checks cover the final configuration/logging changes, transport, scripts, Functions and persistence replacements.

Managed mode starts isolated Eski processes from pristine, checksum-verified upstream test files. The adapter replaces the upstream suite's readiness-log matching with actual endpoint readiness and omits unconditional distributed TLS setup. Test assertions remain unchanged. For example:

```sh
./test/conformance/run.sh --suite redis --managed --server "$PWD/bin/eski" \
  --units scripting,functions \
  --tags "-needs:repl -cluster -needs:cluster -large-memory"
```

The 51-unit managed run includes the curated 43 units plus `aofrw`, `client-eviction`, `obuf-limits`, `oom-score-adj`, `printver`, `replybufsize`, `shutdown` and `violations`. Use `--client /path/to/redis-cli` for tests that need the external CLI. Persistence integration selects `integration/rdb,integration/aof-multi-part,integration/aof`; utility assertions can use `--aof-checker test/conformance/aof_checker.py` with `ESKI_AOF_CHECKER_IMAGE` set to an immutable, already-local reference image ID or digest. The wrapper runs that utility without network access on owned fixture files and records its identity. The Eski server and runtime image bundle no upstream server executable or implementation source. `--tls` creates real managed fixture certificates and requires the native Tcl TLS package. See the runner's `--help` for exact selection and fixture options.

The recorded managed filter is `-needs:repl -cluster -needs:cluster -large-memory`; it does not suppress the broad `repl` tag. Modules, replication, Sentinel and Cluster are outside the product scope. Exact exclusions are recorded in `test/conformance/known-failures.txt`. Allocator and storage-representation assertions retain their actual semantics: Eski reports its own table/memory counts, and this libc build rejects active defragmentation instead of pretending to enable it. Skips, omitted units and resource limits do not establish coverage.

Two upstream JSON encoding cases over 2 GB remain unqualified after an isolated 14 GiB memory limit ended in a kernel OOM kill. Four separate upstream large escape-sequence/newline cases passed on the unchanged Lua runtime; they do not establish the JSON boundary. See [scripting verification](scripting.md#verification). Historical LCS measurements and the committed benchmark dataset describe their recorded source. Expanded keyspace/Lua performance benchmarking is deferred.

Conformance downloads the pinned upstream Tcl test suite and verifies its archive hash. It prefers a native Tcl interpreter and can use Docker when needed. `--baseline` fails when a previously passing test regresses. Without that option, the runner applies its stricter failure policy. It restarts Eski for each unit; `--external HOST:PORT` instead uses an existing server. Results and unit logs go to `test/conformance/results/`. See `./test/conformance/run.sh --help` for unit selection, tags, Tcl selection, ports and timeouts. The [generated conformance page](conformance.md) separates the baseline from the recorded expanded run and explains the recorded skips and coverage limits.

Run conformance before smoke on a fresh clone so smoke can use the downloaded corrupt-payload fixtures. Smoke starts its own Eski and reference containers, compares protocol replies, checks persistence and tests the memcached endpoint. `ESKI_SMOKE_PORT`, `ESKI_SMOKE_REF_PORT`, `ESKI_SMOKE_MC_PORT` and `ESKI_SMOKE_MC_REF_PORT` change its ports. `ESKI_REDIS_IMAGE` and `ESKI_MEMCACHED_IMAGE` select references. The raw socket comparisons of pub/sub, transactions, ACL and MONITOR log only the first 400 characters of each side of a difference; both full strings go to `ESKI_SMOKE_FULL_DIR`, or to a new directory under `TMPDIR` that smoke keeps, and a `full:` line under the failure names the two files. Their steps that contain `FLUSHALL` or `FLUSHDB` wait for every reply of the flushing connection before the next step. The optional `ESKI_SMOKE_BENCH=1` step is a functional benchmark invocation, not the dedicated comparison method.

Native comparison harnesses include `bash test/listtype/compare.sh`, `bash test/hashtype/compare.sh`, `bash test/settype/compare.sh`, `bash test/zsettype/compare.sh`, `bash test/bitmap/compare.sh`, `bash test/hll/compare.sh`, `bash test/geo/compare.sh` and `bash test/streamtype/compare.sh`. They build their drivers, start reference containers and compare generated operation sequences. Persistence-specific commands include `bash test/rdb/roundtrip.sh` and `bash test/aof/roundtrip.sh`. The group pages link the most relevant checks.

### Vector set checks

The vector set group has three checks against the reference image `docker.io/library/redis@sha256:f245f4c83b84a9e9a0588da1c9456e579455310f0945d5db52cd2ba27f2000cc` (server 8.10.3 with vector set module version 1). Every container they start is capped with `--memory 2g --memory-swap 2g`, `--maxmemory 1gb`, `--client-output-buffer-limit "normal 64mb 32mb 60"`, `--save ""` and `--appendonly no`, and no case sends a count beyond a thousand, because the reference builds the whole reply of a negative random-member count.

```sh
bash test/vectorset/compare.sh
python3 -I test/vectorset/compare.py --list
python3 -I test/vectorset/compare.py --normalisations
./test/conformance/run.sh --suite vectorset --baseline test/conformance/baseline-vectorset.json
python3 -I test/vectorset/memory.py 127.0.0.1:PORT 127.0.0.1:REFERENCE_PORT --max-margin 0.1
```

The reply comparison replays 1,193 recorded cases, 709 in RESP2 and 484 in RESP3, together with their setup commands, keyspace notification drains, an ACL category scan and eight logins built from category and command rules, 1,521 compared steps in all. The case inputs are committed in `test/vectorset/cases.py`; the reference replies are not, because each run compares live against a fresh capped container. Smoke runs it after the memcached checks; `ESKI_SMOKE_VSET=0` skips it, `ESKI_SMOKE_VSET_REF_PORT` moves the reference (default: the smoke port plus 30) and `ESKI_VSET_IMAGE` selects another image. `test/vectorset/compare.sh` runs the same comparison on its own, starting `bin/eski` and the container on `ESKI_VSET_PORT` and `ESKI_VSET_REF_PORT` (6481 and 6482), with `ESKI_VSET_SERVER` for another binary, `ESKI_VSET_EXTERNAL=1` for an already running server, and `--sections`, `--quiet` or `--summary PATH` passed to the driver. Replies are compared byte for byte except where a value cannot match by design:

| Normalisation | Applied to | Why | Still compared |
| --- | --- | --- | --- |
| `type` | INFO server, DUMP | server identity fields; DUMP payloads use Eski's own serialization and are restored on the server that produced them | the reply type |
| `integer`, `ttl` | MEMORY USAGE, COMMAND COUNT, TTL | sizes are compared by `test/vectorset/memory.py`; the reference image loads other modules; the clock | an integer, or the exact bytes of anything else, including -1 and -2 |
| `sorted`, `acl-listing`, `module-list` | COMMAND LIST, ACL CAT read and write, MODULE LIST | hash order; listings of the other modules' commands | the names; the vector set commands each listing names, none on the reference and exactly that category's commands on Eski; the whole vectorset module entry |
| `acl-metadata`, `acl-scan`, `acl-login` | COMMAND INFO and COMMAND GETKEYSANDFLAGS of the vector set commands, the scan of every ACL category, the logins | Eski puts the vector set commands in `@read` or `@write` and `@fast` or `@slow` and declares the read commands' key read-only, a deliberate difference from the reference, which lists them in no category and declares every key `RW access update` | every other byte of the metadata, with the categories and key flags checked against each server's documented value; for each login, which commands ran and which were refused for the command or the key, against each server's documented verdicts |
| `docs-summary` | COMMAND DOCS of the vector set commands | Eski words the summaries itself | every other byte of the reply, with the summary checked to be a string in the same place |
| `debug-object` | DEBUG OBJECT | address, serialized length and LRU clock | refcount, encoding and the field layout |
| `scan`, `scan-partial` | SCAN | table order, and the subset a partial page returns | the sorted keys of a complete scan; that a partial page holds only vector sets without repeats |
| `vinfo` | VINFO | random HNSW levels and the server-wide set counter | every field except max-level and vset-uid |
| `vsim`, `exec-vsim` | VSIM without TRUTH, directly, from Lua and inside EXEC | the graph orders equal scores and picks which tied members a COUNT cut keeps | every name, score and attribute in order, names sorted inside groups of equal scores, a cut tie group by its size and score; scores for replies without WITHSCORES come from the same query with WITHSCORES on the same server; TRUTH replies compare exactly |
| `vrandmember` | VRANDMEMBER | random sampling | the reply type and count, membership, distinctness for positive counts, and the sorted names when the whole set comes back |
| `vlinks`, `vlinks-graph` | VLINKS | neighbour order and the levels above layer 0 | the sorted complete layer 0 list with scores on the small sets; the reply shape on the 300-element sets |

The package runner checks these normalisations on fixed replies with `test/vectorset/test_compare.py`.

The conformance suite `vectorset` downloads the Redis 8.10.3 source release from `https://github.com/redis/redis/archive/refs/tags/8.10.3.tar.gz` at run time, checks its SHA-256 `85ae62e175cc76f638015fa18cb384b549b6808a765425d9e9d47466f69532ea`, extracts only `modules/vector-sets/test.py` and `modules/vector-sets/tests` into the ignored `test/conformance/.vectorset`, installs the pinned redis Python client into a virtual environment there, and runs the unit against one server. It starts `bin/eski` on a free port by default; `--external 127.0.0.1:PORT` uses a running server, `--reference` starts the capped reference image instead, and `./test/conformance/vectorset.sh --help` lists the rest. The unit's runner connects only to the primary port and a replica port; the harness passes a closed replica port, so the unit's replication test skips itself. `test/conformance/vectorset-exclusions.json` records that exclusion and one more with their reasons: the unit expects the rewrite of an append-only file without an RDB preamble to fail for a vector set, while Eski rewrites each vector set exactly as a RESTORE of its serialized payload, so that test fails on Eski by design. `test/conformance/reference-vectorset.json` records the reference run, 42 passes and one skip of 43 tests, and `test/conformance/baseline-vectorset.json` the Eski run it is gated against; `--baseline test/conformance/reference-vectorset.json` lists every reference pass Eski does not yet reproduce. Summaries keep test titles, counts and one-line failure reasons, never the unit's files or tracebacks.

`test/vectorset/memory.py` measures MEMORY USAGE at 1, 100 and 1,000 elements of 8, 32 and 300 dimensions in NOQUANT, Q8 and BIN with M 16, elements named `e0` to `e999` and float32 components drawn with a fixed seed, and prints the table with bytes per vector, the usage slope from 100 to 1,000 elements, and the same slope of DEBUG OBJECT's serialized length. Given a candidate and a reference it reports the relative margin of every slope and usage, the largest one either way, and the largest excess over the reference; `--max-margin` fails the run only when the candidate uses more than the reference by more than that fraction somewhere, so using less memory always passes.

### Labelled-mode gate

```sh
./test/labelled/run.sh --keyspace-threads 0
./test/labelled/run.sh --mode owners-user --keyspace-threads 0
./test/labelled/run.sh --mode owners-shared --keyspace-threads 2
./test/labelled/run.sh --mode owners-only-user --keyspace-threads 2 --conformance-reference SUMMARY.json --scripting-reference SUMMARY.json --vectorset-reference SUMMARY.json
./test/labelled/run.sh --keyspace-threads 2 --vectorset-reference SUMMARY.json vectorset compare
```

The gate shows that a server with a label scheme, owner mode or both, used by one login, behaves like the same binary without them except for the documented refusals and differences. It runs five runners, or the ones it is given: the 7.4.11 suite with its curated units, the suite's scripting unit, the vector set unit, the vector set reply comparison and smoke, against a server started through `test/labelled/eski.sh` in one of four modes, and checks every difference from labels-off against that mode's expected files:

| Mode | Server | Default login | Expected files |
| --- | --- | --- | --- |
| `labelled` (default) | the scheme | `clearance:*`: every unprefixed command runs at the top label | `test/labelled/expected/RUNNER.json` |
| `owners-shared` | the scheme and `owners yes` | `clearance:* owner-operator` and no owner rule: every command runs as `SHARED` at the top label, with the operator scope | `test/labelled/expected/owners-shared/` |
| `owners-user` | the scheme and `owners yes` | `owner:suite-user owner-operator clearance:*`: the whole suite runs as one user at the top label | `test/labelled/expected/owners-user/` |
| `owners-only-user` | `owners yes` without a scheme | `owner:suite-user owner-operator`: the whole suite runs as one user at the only label | `test/labelled/expected/owners-only-user/` |

The wrapper executes `bin/eski`, or `ESKI_LABELLED_BINARY`, with the runner's own arguments followed by its own, so its settings win over a runner's command line and configuration files: `save ""`, `appendonly no`, both shutdown options at `default` and `memcached-port 0`, because a scheme and owner mode refuse persistence and the memcached endpoint; in the modes with a scheme, the levels `UNCLASSIFIED`, `CONFIDENTIAL` and `SECRET`, the compartments `A` and `B` and the trust levels `WEB` and `VETTED`; `owners yes` in the owner modes; and a `user default on nopass sanitize-payload ~* &* +@all` declaration with the mode's rules from the table. `ESKI_LABELLED_MODE` selects the mode (`labelled`, `owners-shared`, `owners-user` or `owners-only-user`, and `off` for the same binary with none of them), and the gate sets it from `--mode`. `ESKI_LABELLED_DIR` names a directory the wrapper starts the server in when the runner passes neither a configuration file nor `--dir`, and the gate sets it to an empty `server-dir` under its output directory: the labels-off reference runs leave their data files in the working directory, and a server with a scheme or owner mode refuses to start where a data file exists. `ESKI_LABELLED_KEYSPACE_THREADS` adds `--keyspace-threads`, and the gate sets it from its own option. The suite, its scripting unit and the vector set unit receive the wrapper through `--server`, the reply comparison through `ESKI_VSET_SERVER` and smoke through `ESKI_SMOKE_BINARY`, which smoke also uses for the servers it starts with its own configuration files and ACL files.

The suite, the scripting unit and the vector set unit are compared test by test with a labels-off run of the same binary and worker mode, which the gate runs first unless `--conformance-reference`, `--scripting-reference` or `--vectorset-reference` names that run's summary; the references do not depend on the mode, so one labels-off run serves all four. A difference is a test that passed labels-off and does not pass in the mode. The reply comparison and smoke pass with no failures labels-off, so each failure in the mode is a difference. `test/labelled/check.py --mode MODE` prints every difference the mode's file does not list and every listed difference that no longer occurs, and fails on either, so the lists stay exact; it also refuses a file written for another runner or mode, a category without an id, a reason or a documentation link, and a link to a page or section of `docs` that does not exist. Entries are exact test names; only smoke's corrupt-payload and dump families, whose names carry generated payloads, are listed as `patterns`, and every case in them sends `RESTORE`. Each file groups its entries by category with the reason and the documentation that covers it; [labels.md](labels.md#what-the-labelled-gate-records) lists the categories and their counts. `--out DIR` keeps the logs and summaries, and smoke's full differing strings in `smoke-full`.

## Optional formal verification

The optional [formal verification projects](../proofs/README.md) group hash-table migration and memory accounting, worker rollback and expiry-aware persistence, request parsing and packed codecs, and bitfield arithmetic. Each project uses the pinned Lean toolchain to check properties of an executable model and compares selected behavior against actual Odin code with independent expectations. These projects are separate from the server build and introduce no server runtime dependency.

With the pinned Lean toolchain and Odin on PATH:

```sh
python3 -I proofs/verify.py
```

Each project documents its theorem domains, compatibility edge cases and implementation boundary. The aggregate runner verifies projects sequentially and records evidence for each covered area. Model proofs and finite implementation comparisons provide different evidence; they do not establish formal verification of the compiled Odin server. Follow the project instructions to run focused verification separately from the ordinary package and conformance suites.

Worker scheduling and fork/shutdown have separate [bounded state-space and runtime checks](../verification/README.md):

```sh
python3 -I verification/verify.py --server /absolute/path/to/qualified/eski
```

Add `--tsan-server /absolute/path/to/qualified/eski-tsan` for the targeted instrumented server checks. The scheduling harness also builds its own ThreadSanitizer control and requires the deliberate race to be detected. Supplied binaries must match the projects' pinned qualified checkpoint. These checks cover the documented finite scenarios, source-informed models and targeted real paths; they do not establish unbounded concurrency or universal race freedom. The runners start and clean up their own small local fixtures and perform no benchmarks.

## Generate the published tables

```sh
python3 -I test/readme_tables.py
python3 -I test/readme_tables.py --check
```

The generator queries `COMMAND DOCS` from a temporary Eski instance, reads the tracked baseline and observed conformance snapshot, and reads the dataset of the recorded run under `bench/testbed/runs` with the latest finish time. It updates the generated pages, README tables and SVG badges. Check mode reports drift without changing those files. It cleans up the temporary server; `--server HOST:PORT` uses an existing instance instead, and `--server-binary PATH` selects another binary.

After a real conformance run, refresh its sanitized published snapshot with:

```sh
python3 -I test/readme_tables.py --record-conformance test/conformance/results/latest-redis.json
python3 -I test/readme_tables.py --check
```

The inputs can be selected with `--baseline PATH`, `--observed-conformance PATH` and `--benchmark-results DIRECTORY_OR_DATASET_JSON`. The generated tables are historical measurements from those inputs, not a substitute for running the current tree's checks.

## Benchmark and exam workflow

`bash bench/run.sh --help` describes native and container targets, scenario selection, specification cases, plan files and CPU/memory overrides. A quick functional run is `bash bench/run.sh --quick --targets eski --scenarios get_p1 --label local`; use the scenario names printed by its help if changing that selection. `bash bench/pts.sh --help` describes the fixed profile invocations.

The dedicated-machine workflow is defined by `bench/testbed/design.json` and the server designs in `bench/testbed/designs/`; [run the comparison on a new machine](benchmarks.md#run-the-comparison-on-a-new-machine) lists the machine requirements and every command from a fresh machine to the published tables. `python3 -I bench/testbed/plans.py --out /tmp/eski-plans` renders plans. Its `gates.power_source` declares the power gate: `mains`, the default when it is absent, requires an online Mains power supply device in every sample, as on a laptop; `no-power-supply-devices` admits a server that exposes no power supply device and still holds the gate or invalidates the case when a battery, mains or other power supply device appears. `python3 -I bench/testbed/install.py install --help` describes installation over SSH; installation creates a new run root and does not start it. The installed `exam.sh` starts once on its first no-argument invocation; later no-argument calls show status. Use `exam.sh status`, `inspect`, `resume` and `collect` according to `exam.sh help`. Do not treat repeated invocations as independent runs.

Use `python3 -I bench/testbed/collect.py --help` for receipt-verified collection. `combine.py` produces the dataset, `charts.py` renders SVGs and `page.py` builds the standalone report. Every tool exposes its required paths with `--help`. `test/readme_tables.py` takes the run name from the dataset's `run.root`, expects that dataset at `bench/testbed/runs/<run>/dataset.json` and, without `--benchmark-results`, uses the recorded run there with the latest finish time. The [benchmark page](benchmarks.md) describes the committed run's workload, equal resource assignments, exclusions and client-limited observations.

### Labelled-mode A/B

[Local relative measurement](benchmarks.md#local-relative-measurement) with `bench/ab.py` compares two builds with labels off. The same workloads in label-only labelled mode run with the scheme of the labelled-mode gate, the memcached endpoint off and a default login at the top label, so that memtier's unprefixed commands run at one label; `bench/ab.py` already starts both servers with `save ""` and `appendonly no`:

```sh
LABELLED="--label-levels UNCLASSIFIED,CONFIDENTIAL,SECRET --label-compartments A,B --label-trust-levels WEB,VETTED --memcached-port 0 --user default on nopass ~* &* +@all clearance:*"
python3 -I bench/ab.py --a A_BINARY --b B_BINARY --label LABEL --out RESULTS --max-load 3 --extra-a "$LABELLED" --extra-b "$LABELLED"
python3 -I bench/ab_report.py RESULTS/LABEL --floor LABELLED_FLOOR
```

`--extra-a` and `--extra-b` are split on spaces and passed to the server without a shell, so the ACL rules need no quoting there. The floor in `bench/ab_floor.json` was recorded with labels off; labelled mode needs its own, recorded first from an A/A session of one build against itself with the same options and written with `--write-floor` to a file of its own, which `--floor` then names. The labels v1 binary accepts the same options, so A can be the labels v1 tree and B the candidate.

### Speed-pass harness

Timing on the shared development machine is not trusted, so the tools below run there at small sizes only, to show that they work and that what they check holds; their timing fields are recorded in their output files and read in a speed pass on a quiet machine with the conditions of [local relative measurement](benchmarks.md#local-relative-measurement). Each uses its own ports from 7650 by default, starts and stops its own servers by process id, and writes nothing into the checkout.

`bench/micro/store.py` measures the store's hot paths in process, without the network: insert, overwrite, hit, miss, remove and timed insert of 7-byte and 14-byte keys at a chosen key count, through the real store and table code of each source tree. `python3 -I bench/micro/store.py build --tree A=CHECKOUT_A --tree B=CHECKOUT_B --control A --work WORK` copies each tree's `src`, `third_party` and `tools` into WORK, adds the probe package `bench/micro/store` and builds it, and `--control A` builds A a second time with its source files laid out in another order, an identical-code control for layout effects; `run --work WORK --keys 20000 --reps 5 --rounds 8 --cpu N --out FILE` runs the builds in interleaved rounds, and `report FILE --base A` prints each phase in nanoseconds per operation for the base and as a ratio for the others, with the control's ratio as the noise band. It informs the store layout, the lookup forms and the role tests at the allocation points.

`bench/disasm.py` compares the machine code of procedures between two binaries, which load does not affect: `compare A B [PROC ...]` gives each procedure's instruction count in both and whether only displacements changed, `net A B [PROC ...]` lists the instructions added and removed, and `diff A B PROC` prints the changed hunks. Without names it covers the store and command hot paths. It judges a hot-path change while timing is not trusted, against the labels v1 binary or the parent build.

`bench/owners/scale.py` builds the owner scale shape: many users, each with one small key and one 128-dimension Q8 vector set element, beside a shared graph in the same set. While it loads it checks every user: its key reads back, its element is present, it counts the shared graph and its own element, it sees a shared element, it does not see its neighbour's element, and its view holds its key and the two shared keys; for a sample it also reads the vector back, finds its own element and a shared element by exact search, does not find its neighbour's element by searching with that vector, and is refused a search from the neighbour's element as from a missing one. It reports `used_memory`, allocator, resident and owner bytes per user. `--size smoke`, the default, loads 2,000 users beside 1,000 shared elements in seconds; `--size full` loads 300,000 users beside a 50,000-element graph. `--probes` adds the timing probes, recorded with `--out FILE`: the creation rate and the server CPU per user, the server's idle CPU without owners and with them, and the round trip of a user's `GET` and `VSIM` against a shared reader's, interleaved. It informs the memory per user and the cost of owner partitions under load.

`bench/owners/bytes.py --shape inline|small|hash|timed|two|five|vset --users N` reports the bytes per user of one data shape, the change in `used_memory`, `allocator_allocated`, the table lookup bytes of `MEMORY STATS`, resident memory and `owner_bytes`, after a warm-up of 2,000 users; `--extra "--owner-compact no"` measures the fixed partition form. It informs the compact partition and the savings listed for it.

`bench/owners/forms.py --users N --rounds R --out FILE` runs the compact owner partition and the fixed form (`owner-compact no`) of one binary in alternating order over the phases create, hit, miss, overwrite, ladder, compaction churn and remove, and records server CPU and wall time per phase; `--report FILE` prints the median server CPU per command of each phase in both forms. It judges the table ladder's allocations and the settle compaction.

`bench/owners/vset` is an in-process program over `src/vsettype` for the vector set owner shapes: the creation and forgetting of many owners with one element each, `view_open` and `VSIM` for one owner beside many others, a name an owner holds that is also shared, and a large shared graph seen by a shared reader, an owner without data and an owner with its own elements. Build it with `odin build bench/owners/vset -o:speed -out:WORK/vset-owners` and run `WORK/vset-owners all OWNERS GRAPH ROUNDS` (defaults 2,000, 1,000 and 200; the scale run is `all 300000 50000 4000`); it prints one JSON line per probe and exits non-zero when a check fails, such as a view of the wrong size or a set whose bytes do not return to their value before the owners. It informs the owner index, the collision scan and the compact blocks.

`bench/scripts/digest.py --a A --b B --out DIR` runs one fixed session of 1,093 script and function commands against two binaries with labels off and compares the replies byte for byte, so that a change to the script path is shown to keep every reply. `bench/scripts/load.py --binary A=PATH --binary B=PATH --mode off|labelled|owners --out FILE` is the matching load generator: `EVAL`, `EVALSHA`, `EVAL_RO` and `FCALL` of a one-key read and `GET` as the control, pipelined, binaries alternating per round, checking every reply and recording server CPU and wall time per workload; `--report FILE` prints the median server CPU per command and each binary's ratio to the first. Labelled mode measures the restore of the engine settings at the start of every run, owner mode the per-scope cache.

Eski is an independent project, not affiliated with, endorsed or certified by Redis Ltd. Redis is a registered trademark of Redis Ltd.; any rights therein are reserved to Redis Ltd.
