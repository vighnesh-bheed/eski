# Build, run and test

## Build

The server uses Linux system calls and epoll. The supplied container build targets Linux amd64 and pins its compiler archive and distribution packages in [Dockerfile](../Dockerfile). Native builds need Odin, clang and Python. Build scripts choose `ODIN` when set, then `odin` on PATH, then `$HOME/odin/current/odin`. The compiler selected must be executable; clang must be on PATH.

Run from the repository root:

```sh
./build.sh check
./build.sh
```

`check` type-checks the source, test and benchmark packages with vet and strict style and scans Odin source for comments. The default build is the optimized release executable at `bin/eski`. `./build.sh debug` and `./build.sh sanitizer` replace that same output with a debug or address-sanitized build. Rebuild release before comparing performance. A compiler can be selected explicitly with `ODIN=/path/to/odin ./build.sh`.

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

The separate keyspace-worker implementation is currently uncompiled and untested. Its startup controls are `--keyspace-threads N` (0 through 64, default 0) and `--keyspace-max-memory N` (default 128 MiB). They target only guarded GET/plain SET and are immutable after startup, hidden from wildcard CONFIG discovery and inspectable by exact name: `CONFIG GET keyspace-threads` and `CONFIG GET keyspace-max-memory`. The memory budget is for admitted directory/value/task allocations, not process RSS. Keep this stage disabled until it has been verified; the [threading guide](threading.md#keyspace-workers-unverified) explains the exclusions and reconciliation cost.

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

The runtime image runs as its unprivileged Eski user and uses `/data`. A named volume preserves local persistence across replacement containers. `bench/image.sh` builds and verifies an image manifest and can export/import an image archive; use `bash bench/image.sh --help` for its options. The image's documentation directory carries the project and applicable third-party licence notices.

## Verification

```sh
bash test/run_packages.sh
./test/conformance/run.sh --suite redis --baseline test/conformance/baseline-redis.json
bash test/smoke.sh
```

The package runner executes native unit packages in debug, address-sanitizer and release modes, then runs the Python harness drivers. It writes temporary binaries and removes them on exit. Individual packages can be tested with `odin test src/listpack -debug`; drivers such as `python3 -I test/request_parser/run.py` include their own boundary and model checks.

The threading driver can target a separate executable with `python3 -I test/threading/run.py --server /path/to/eski`. The package runner uses `ESKI_THREADING_BIN` for this driver when set, otherwise the current `bin/eski`; it runs correctness checks only. `python3 -I -m unittest discover -s test/threading -p 'test_*.py'` checks its protocol/model/measurement helpers. The [threading guide](threading.md#correctness-checks) includes native overlap tests, loading fallback checks, separate thread/address-sanitized builds and an explicitly opt-in bounded performance tool.

Those threading tools cover the earlier LCS stage. No build, runtime, sanitizer, compatibility or performance verification has been performed for the new keyspace-worker source. The recorded LCS qualification at `83024e3` and the committed conformance/benchmark inputs remain separate evidence; a passing result from them does not qualify the new path.

Conformance downloads the pinned upstream Tcl test suite and verifies its archive hash. It prefers a native Tcl interpreter and can use Docker when needed. `--baseline` fails when a previously passing test regresses. Without that option, the runner applies its stricter failure policy. It restarts Eski for each unit; `--external HOST:PORT` instead uses an existing server. Results and unit logs go to `test/conformance/results/`. See `./test/conformance/run.sh --help` for unit selection, tags, Tcl selection, ports and timeouts. The [generated conformance page](conformance.md) separates the baseline from the recorded expanded run and explains the current failures.

Run conformance before smoke on a fresh clone so smoke can use the downloaded corrupt-payload fixtures. Smoke starts its own Eski and reference containers, compares protocol replies, checks persistence and tests the memcached endpoint. `ESKI_SMOKE_PORT`, `ESKI_SMOKE_REF_PORT`, `ESKI_SMOKE_MC_PORT` and `ESKI_SMOKE_MC_REF_PORT` change its ports. `ESKI_REDIS_IMAGE` and `ESKI_MEMCACHED_IMAGE` select references. The optional `ESKI_SMOKE_BENCH=1` step is a functional benchmark invocation, not the dedicated comparison method.

Native comparison harnesses include `bash test/listtype/compare.sh`, `bash test/hashtype/compare.sh`, `bash test/settype/compare.sh`, `bash test/zsettype/compare.sh`, `bash test/bitmap/compare.sh`, `bash test/hll/compare.sh`, `bash test/geo/compare.sh` and `bash test/streamtype/compare.sh`. They build their drivers, start reference containers and compare generated operation sequences. Persistence-specific commands include `bash test/rdb/roundtrip.sh` and `bash test/aof/roundtrip.sh`. The group pages link the most relevant checks.

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
