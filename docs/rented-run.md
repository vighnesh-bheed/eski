# One-host qualification and baseline

`tools/rented_run.py` takes one quiet Linux server from a clean checkout to a qualified correctness record and the timed baseline that later speed and memory work is compared against, and leaves a checksummed bundle behind. It is written for a rented machine that is used once: every stage keeps its own receipt, a failure costs that stage and nothing before it, the run survives a dropped terminal, and the summary ends with what is still owed and the command that completes it. The whole sequence can be rehearsed at toy size on a development machine first.

## Before renting

Stage these, and nothing else, where the server can fetch them:

| Item | Notes |
| --- | --- |
| The revision to qualify | A full commit id of this repository, pushed where the server can clone it. |
| The private search capture | The executable capture program, its recorded `observed.json` and their `SHA256SUMS`. Transfer them over a private channel; they never enter the repository. The capture is executable test input and must come from a trusted source. |
| A reviewed expected-difference file | Optional, and private like the capture, because it names capture cases. It lists the capture cases whose difference is reviewed and documented, each with the SHA-256 pair of both normalized replies (see [the search comparison](build-run-test.md#search-and-json-comparison)); without it every such difference fails `search-capture`. Stage it outside the checkout and pass it as `--expected`, so that a later change to it reruns only the capture comparison. |

No credential is needed. Everything else is downloaded on the server by `tools/host_setup.sh` before the clock starts, from public sources, checked by hash where a hash is pinned:

| Download | Source | Check |
| --- | --- | --- |
| Distribution packages | the distribution's archive | the distribution's signatures |
| The Odin release named in the [Dockerfile](../Dockerfile) | GitHub | SHA-256 |
| uv 0.12.19, CPython 3.12.14 and the packages of both client environments | PyPI and the uv Python builds | versions pinned by the lock files, compared after installation |
| Every image the run uses, by digest (`python3 -IB tools/rented_run.py images`) | Docker Hub and the GitHub container registry | digest |
| The Redis 7.4.11 test suite and the vector set unit, and the pinned redis client for that unit | GitHub and PyPI | SHA-256 of each archive |
| The archives the baseline plan reads (`python3 -IB tools/rented_run.py downloads`): today the Redis benchmarks specification v0.3.46 | GitHub | SHA-256 |

The run itself downloads nothing when these caches are in place; the only exception is the specification step, which downloads its archive into its own directory when the cache is missing. Rehearse on a development machine before renting (see [rehearsal](#rehearsal)).

## Host preparation

`tools/host_setup.sh` is written for Debian 13 and also accepts Ubuntu 24.04. It has three parts, and `downloads` and `status` besides. Each can run again; it prints `changed:` for what it did and `already:` for what it found in place.

```sh
sudo tools/host_setup.sh system "$USER"
tools/host_setup.sh user ~/eski-host
sudo tools/host_setup.sh quiet
sudo reboot
```

`system` installs the compiler and linker (clang, lld, binutils) with its sanitizer runtime (`libclang-rt-19-dev` on Debian 13, `libclang-rt-18-dev` on Ubuntu 24.04), the OpenSSL 3, libunwind and liblzma headers, Python with `venv`, Tcl 8.6, Docker, `jq`, `curl`, `tmux`, `iproute2` (`ss`), `util-linux` (`taskset`, `flock`), perf, `cpupower` and the sensor tools, starts Docker, adds the operator to the `docker` group (log in again afterwards) and keeps the operator's user services alive after logout. `user` installs the Odin release named in the [Dockerfile](../Dockerfile) after checking the archive's SHA-256, builds the Lua and diagnostics archives, creates the two client environments with uv 0.12.19 and CPython 3.12.14 so that every package is exactly the version in `test/compatibility/search_clients/requirements-modern.txt` and `requirements-llama.txt`, fetches the archives the baseline plan reads into `.build/downloads/` of the checkout and checks their SHA-256 (`tools/host_setup.sh downloads` does only this), pulls every image the run uses by digest (`python3 -IB tools/rented_run.py images` lists them), and fetches and verifies the conformance archives by running one small unit and the vector set unit against a throwaway build. `--no-docker` leaves out the images; it still fetches the conformance archives when native Tcl is installed, because they need no Docker then. It prints the `--modern-python` and `--llama-python` paths at the end.

`quiet` is the part that needs root and a reboot. It installs a unit that sets the performance governor at every boot, stops and disables the package timers (`apt-daily`, `apt-daily-upgrade`, `unattended-upgrades`), writes `/etc/sysctl.d/60-eski-perf.conf` with `kernel.perf_event_paranoid = 1` and `kernel.kptr_restrict = 0` and applies it at once, so that perf may record call graphs of the operator's own processes and resolve kernel symbols for the trace steps (Debian and Ubuntu default to values that refuse both), and adds `nosmt`, a blacklist of display drivers and `transparent_hugepage=madvise` to the kernel command line. On Ubuntu, perf comes from `linux-tools-generic`, which matches the generic kernel only; on another kernel flavour install `linux-tools-$(uname -r)` as well, or preflight reports the trace steps as unable to record. Reboot before correctness starts. A later reboot does not void correctness receipts, but a reboot between timed steps is reported (see [reboots](#reboots)).

`tools/host_setup.sh status` shows what is still missing without changing anything, including the perf settings and whether the plan's archives are cached. The `system` and `user --no-docker` parts were checked in a Debian 13 container and in an Ubuntu 24.04 container, each run twice: packages, Odin, the Lua and diagnostics archives, the client environments, a release build, an address-sanitizer package test and preflight, and in the Ubuntu container also the plan's archive and the conformance archives fetched with native Tcl and no Docker. A container cannot prove the Docker daemon, image pulls, the governor, the perf settings, the kernel command line or the reboot; check those on the server with `status` and preflight.

## Preflight

Collect the options once and run preflight. It builds nothing, starts no server and writes nothing; it prints a JSON report on standard output and a one-line time and disk estimate on standard error, and exits nonzero when anything would stop the run or its timing.

```sh
options=(
  --out ~/results
  --revision "$(git rev-parse HEAD)"
  --server-cpus 2 --client-cpus 4,6 --control-cpus 7
  --port-base 17840
  --modern-python ~/eski-host/clients/modern/bin/python
  --llama-python ~/eski-host/clients/llama/bin/python
  --capture ~/private/capture.py --observed ~/private/observed.json
  --input-sums ~/private/SHA256SUMS
  --expected ~/private/expected-differences.json
)
python3 -IB tools/rented_run.py preflight "${options[@]}"
```

Anything in `errors` stops the whole run: a dirty checkout or one at another revision, CPU lists that overlap or are not permitted, no CPU outside both roles for the controller of the timed steps (pass `--control-cpus` to choose it; by default the run takes the highest permitted CPU in neither role, CPU 0 only when nothing else is left), a busy port among the forty from `--port-base`, too little free space, output inside the checkout, a missing tool (Odin, Docker, clang, git, jq, taskset, openssl, bash, curl, ar, flock, ld, ss, timeout, tar, sha256sum, and native Tcl or the `eski-conformance-tcl:8.6` image), an Odin other than `dev-2026-10-nightly:84bc3fc`, a clang outside major versions 18 to 22, an address-sanitizer program that does not compile, link and run, missing libunwind, OpenSSL 3 or liblzma headers, a `python3 -m venv` that fails, a download the conformance caches do not hold yet and the network cannot reach, a private input that does not match `--input-sums`, a client environment that differs from its lock file, or an image that is not present. The tool itself needs Python 3.11 or later and says so plainly on an older one.

`timing_refusals` block only the timed baseline and cannot be overridden: output on tmpfs or ramfs, where sync timings mean nothing, and a baseline plan that does not load or breaks its contract. `quiet_findings` block only the timed baseline unless `--allow-noisy-host` is given: a governor other than performance on a role CPU, active simultaneous multithreading, server and client CPUs that share a physical core, a loaded display driver, an active package timer, and transparent huge pages set to `always`. Correctness never waits for a quiet host. `plan_findings` name a condition and the baseline steps it affects, and block nothing else: an archive the plan reads that is neither cached nor reachable (it affects `stock-spec`), and a host where perf cannot record a call graph (`call_graphs` holds the probe; it affects the seven trace steps, which then record a flat profile at most and stay owed until `quiet` has set the perf settings).

The report records what a later comparison needs: CPU model and microcode, kernel command line, governor and frequency limits, SMT state, huge page settings, memory size, and the device and filesystem of the output directory and the checkout. The estimate line gives two figures. The upper bound adds the baseline plan's own `estimate_seconds` to the bounds that the correctness stages' timeouts give, which no operator can plan with. The planning figure beside it sums the durations recorded in `tools/recorded_durations.json`, which names the machine and the revision they were recorded on, for builds, every functional step, the virtual and native stages and the probes, and for plan steps that have a recorded duration in the selected plan profile; a plan step without one counts with its own estimate, and the line names the stages that have no recorded duration and the figures that are only lower bounds because the recorded step ended early. It is a planning figure from another machine, not a bound, and the line says so. The estimate also states the disk needed before the baseline; [the plan page](baseline.md#time-and-disk) states the plan's own disk use.

## Starting the run

Start the run so that it survives a dropped SSH connection. In one line, inside tmux:

```sh
tmux new-session -d -s eski "python3 -IB tools/rented_run.py run $(printf '%q ' "${options[@]}")"
```

`tmux attach -t eski` shows it again. `--detach` starts the same run in its own session without tmux and returns at once, writing its output to a `detached-*.log` under `--out`. Do not pass the options inside the command line of a transient systemd unit: systemd expands `${...}` itself, so the run receives no options; start a unit through a script file instead. The run ignores the hangup of its terminal in any case and keeps its own output in `rented-run.log` in the run directory.

`run` repeats preflight, creates a new private `run-*` directory under `--out` and works through these stages in order. Each stage has its own log, and the SHA-256 of every log and report is recorded.

| Stage | What it does |
| --- | --- |
| Builds | The Lua and diagnostics archives, the release server `eski`, `eski-debug` (the same source and optimisation with debug information, for profiling only; it is never timed or qualified), the simulation worker and the change log reader, into `bin/`. |
| `functional` | [`test/functional/check.py`](build-run-test.md#combined-functional-check) with the full profile against `bin/eski`; the package suite runs as four steps, one per group of `test/run_packages.sh`, so a failed driver reruns without the sanitizer builds. |
| `virtual` | 256 deterministic simulation seeds of 128 steps; every failing worker is reported with its seed, case, variant, trace and the command that replays it. See [simulation](simulation.md). |
| `native` | 64 kill and restart cycles of 100 acknowledged transactions with `appendfsync always`. |
| `change-log-probe`, `search-json-probe` | Untimed checks that the change log mirror and the Search/JSON workload see the replies they will later time. |
| Baseline steps | The steps that `bench/baseline.py` returns for the plan profile, each run as its own stage. The [baseline measurement plan](baseline.md) lists them, their sizes and method, and [the contract with the run](baseline.md#the-contract-with-the-run) states what the run passes them and expects back. |
| `bundle` | Checksums and two archives beside the run directory (see [leaving the host](#leaving-the-host)). |

Once the builds that correctness needs have passed, every correctness stage runs even when an earlier one fails; a failed `eski-debug` build is owed but does not stop correctness. The baseline runs only when every correctness stage has passed and its receipt checks out, the checkout is unchanged, the images are the ones preflight saw and the host is quiet. Each baseline step runs even when an earlier one failed. `--plan-profile rehearsal` selects the plan's toy sizes, and `--only` and `--skip` take comma-separated step names or areas.

## Failures and resuming

The summary's `owed` list names every stage, functional step and baseline step that failed or did not run, each with the exact command that completes it, and the run prints the same list when it ends. To complete a run, resume its directory:

```sh
python3 -IB tools/rented_run.py run --resume ~/results/run-20261120-101500-abcd1234
```

A resumed run takes its settings from the directory, repeats preflight and refuses to continue when the checkout, the tools, the images, the interpreters, the private inputs or the correctness sizes differ from the first preflight. It then reruns only what failed or never ran and keeps every earlier receipt; a rerun stage keeps its earlier attempts and their logs, and a rerun baseline step's directory is kept as `<name>.attempt-N` beside the new one. Inside `functional`, the check is started with `--resume` on its previous output, so only its failed or missing steps run again; a step is reused only when the server binary, the step's command and its inputs are the same. Baseline sizes, CPU roles, ports, the plan profile and the selected steps are not part of that identity, so a baseline step can be rerun alone with `--only NAME`, and a broken competitor can be left out with `--skip`.

A full-size stock step whose measurement finished with some cases not valid is recorded as `measured`, not failed: every measurement is kept, the summary's `measured_with_exclusions` gives the number of excluded cases and the field of the step's report that lists them with their reasons, and its `owed` entry is marked `choice` with the command that would rerun it. Rerunning repeats the whole step, often hours, so a resume never reruns it on its own; name it in `--only` to rerun it. Such an entry alone does not make the run's exit status nonzero.

A reviewed change to the expected differences is passed as `--expected NEW-FILE` on the resumed run. It reruns the capture comparison and nothing else. The expected file holds only case ids with the SHA-256 pair of both normalized replies, and case ids whose reference reply does not repeat; [the search comparison](build-run-test.md#search-and-json-comparison) explains the format and the normalisation rules.

## Unqualified timing

`--allow-unqualified` lets the baseline run although correctness recorded failures. The summary then has `qualified: false` and an `unqualified` entry that names every failed stage and step, and each timed stage is marked `qualified: false` with `unqualified_because`; it stays so after correctness is completed later, until the step is timed again. A step timed with `--plan-profile rehearsal` is never qualified, whatever else holds. `--allow-noisy-host` lets timing proceed on a host with `quiet_findings` and records the findings with the timing. Without these flags the baseline waits for complete correctness and a quiet host.

## Reboots

Each stage records the boot it ran in. A reboot between correctness stages or after them does not void their receipts. When the timed stages of one run span more than one boot, `timed_stages_span_boots` is true and `timed_boots` lists the boots, so a comparison can treat those numbers with care.

## Leaving the host

The last stage writes `SHA256SUMS` over every file of the run directory except the private ones, packs them into `RUN.tar.gz` beside the directory and writes `RUN.tar.gz.sha256`. The private inputs and everything that holds captured commands or replies (`inputs/`, every `search-capture` directory and log) go into `RUN-private.tar.gz` with `SHA256SUMS.private` and `RUN-private.tar.gz.sha256`, readable by the owner only. Both archives are checked against their checksum lists after writing. The main bundle can be handled freely; keep the private one private.

```sh
cd ~/results
sha256sum -c RUN.tar.gz.sha256 RUN-private.tar.gz.sha256
python3 -IB tools/rented_run.py clean ~/results/RUN
```

`clean` checks the private bundle against its recorded checksum and its contents against `SHA256SUMS.private`, then removes the private copies from the run directory; the private bundle stays. `bundle RUN` packs a run directory again, for example after an interrupted run. Copy both bundles off the host, then delete the staged private inputs and the private bundle from the server.

## Rehearsal

`--rehearsal` runs the same sequence at toy size: the light functional profile, two virtual seeds of four steps, two native cycles of three transactions, the plan's rehearsal profile and a small change log probe. Capture inputs and client interpreters are optional, quiet findings are recorded but do not block timing, and tmpfs output is still refused. The summary has `rehearsal: true` and `qualifying: false`; a rehearsal directory resumes only as a rehearsal and its identity never matches a full run, so it can never serve as a correctness receipt.

```sh
python3 -IB tools/rented_run.py run --rehearsal --out /path/to/rehearsals \
  --revision "$(git rev-parse HEAD)" --server-cpus 2 --client-cpus 4,6 --port-base 17840
```

## Ports and processes

Every server the run assigns a port to uses the forty consecutive loopback ports from `--port-base`, and baseline steps receive the same range. Three parts choose their own: the upstream Tcl suites pick a base between 20032 and 55000 for their test servers and use ports up to 10,000 above it, the labelled conformance wrapper picks free server ports, and the package runners and some drivers take kernel-assigned ephemeral ports. Keep those ranges free of other services on the host. A SIGTERM to the run stops the running stage's whole process group, marks the stage interrupted and leaves a summary that lists what is owed; it does not pack a bundle, so run `bundle` or resume afterwards.

## The summary

`summary.json` in the run directory holds the first and the latest preflight, every invocation with its options, the stages with commands, exit statuses, boots, logs, reports and their SHA-256, earlier attempts, the binary hashes, the plan profile and context, `correctness` with its failures, `qualified`, the timing conditions, `measured_with_exclusions`, `owed` and the bundle hashes; each preflight also keeps its `plan_findings`, the call-graph probe and the planning figure. The bundled copy was written just before packing; the copy left in the run directory also records the bundle hashes. Compare optimisation runs from the same host with the same CPU roles, plan profile and image identities.
