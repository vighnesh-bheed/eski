# Recorded benchmark comparison

Generated from `bench/testbed/runs/comparison-v1/dataset.json`, schema `eski-testbed-dataset-v1`. The benchmark phase contains 128 planned repetitions, 124 valid, 4 excluded and 84 included client-limited measurements. The medians and ranges below are recomputed from included benchmark rows; calibration and excluded rows do not enter them.

## Reproduce the tables

Run `python3 -I test/readme_tables.py --benchmark-results bench/testbed/runs/comparison-v1` and verify with `python3 -I test/readme_tables.py --check`. To render the recorded charts and report, run `python3 -I bench/testbed/charts.py --dataset bench/testbed/runs/comparison-v1/dataset.json --out bench/testbed/runs/comparison-v1/charts` and `python3 -I bench/testbed/page.py --dataset bench/testbed/runs/comparison-v1/dataset.json --out bench/testbed/runs/comparison-v1/report.html`. A new physical experiment follows [run the comparison on a new machine](#run-the-comparison-on-a-new-machine) below; generating tables does not launch it. The [recorded report](../bench/testbed/runs/comparison-v1/report.html), [dataset](../bench/testbed/runs/comparison-v1/dataset.json) and collection receipts are committed together.

## Method and machine

Machine: Intel(R) Core(TM) i7-8750H CPU @ 2.20GHz; 15851.66 MiB RAM; server CPUs `1`, client CPUs `3,4`, controller CPUs `5,11`.

100,000 keys with numeric ids 1 to 100,000 under one prefix, loaded by one connection at pipeline 32 before every measurement. String workloads hold one value per key; HGET, SISMEMBER and ZSCORE keys hold 16 fields or members and read field or member 8. DBSIZE and sampled replies on keys 1, 50,000 and 99,999 are checked before the warmup.

Eski, Redis, Valkey and Dragonfly each run in a fresh container per measurement with the same CPU set, an 8 GiB memory and swap cap, 6 GiB maxmemory, persistence off and host loopback networking. Dragonfly runs one proactor thread on its single core.

A separate fill of 10,000,000 keys of 64 B at pipeline 32 per engine, with the same server core and memory caps, reports resident and used bytes per key and the worst request during the fill.

Before every case the CPU package must be at or below 55 C, the server and client CPUs at least 95 percent idle, the readings stable for 10 seconds and at least 30 seconds must have passed since the last case; an unmet gate after 600 seconds holds the run. During a case the machine must stay on AC power with readable telemetry, no thermal throttle counter increments, an unchanged frequency policy, a package at or below 90 C and no competing CPU load.

Docker CPU sets and memory caps separate the roles but share the kernel, the last level cache, memory bandwidth, power and cooling.

Closed loop client observed latency; p99 is the per run percentile, never pooled across runs.

The kernel memory.peak of the server container read just before it stops: it covers preload, warmup and the timed run and is not live key memory or process RSS.

Medians over the valid repetitions with the observed minimum and maximum. Excluded repetitions stay visible with their reason. There is no overall score and no cross workload average.

A measurement whose raw client output reports a maximum latency beyond 120 seconds is invalid as a histogram range artefact. The timed client's CPU share is recorded and a measurement above 85 percent of its two CPU budget is marked client limited, which makes its throughput a lower bound.

Four repetitions per workload and engine. The engine order rotates so that each engine takes every position once per workload. Failed, invalid and skipped cases are never retried silently.

10 seconds of warmup on the loaded dataset, excluded from the statistics, then one 60 second timed run with two client threads of 16 connections each, uniform random keys and pipeline 1 unless the workload names pipeline 16.

One physical server core without its hyperthread sibling for every engine, two separate physical cores for the load generator and one physical core for the controller. This is an end to end single core comparison on one machine; it does not measure multicore scaling or maximum capacity.

The pinned memtier_benchmark image with its default seed and distinct client seeds, so every engine and repetition sees the same key sequence policy.

## Engine identities

| Engine | Image reference | Measured image ID | Recorded version |
| --- | --- | --- | --- |
| Eski | `eski:local` | `sha256:1539a15f6ad985667f2f8f2f93e21a790ae7bc93dadde72dbcdfdbaefb942b79` | eski v=0.1.0 |
| Redis 7.4.12 | `docker.io/library/redis:7.4.12@sha256:b6b6e3dc0c0952737748e55d5d885272840c7e42ba41ab1d5489f693419882f5` | `sha256:b6b6e3dc0c0952737748e55d5d885272840c7e42ba41ab1d5489f693419882f5` | 7.4.12 |
| Valkey 8.1.11 | `docker.io/valkey/valkey:8.1.11@sha256:8f836008e0986c36adf50da714c7060cf689dbb335f61fe077939d90fa650809` | `sha256:8f836008e0986c36adf50da714c7060cf689dbb335f61fe077939d90fa650809` | 8.1.11 |
| Dragonfly 2.0.2 | `ghcr.io/dragonflydb/dragonfly:v2.0.2@sha256:061f00b201b58e12f974e4e96c761a881ee1c05e9d8ee967466a604b7299753b` | `sha256:061f00b201b58e12f974e4e96c761a881ee1c05e9d8ee967466a604b7299753b` | 2.0.2 |

## Valid benchmark measurements

| Workload | Engine | Valid / planned | Throughput median [min, max], ops/s | p99 median [min, max], ms | Container memory peak median, MiB | Client-limited valid runs |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| GET 64 B, pipeline 1 | Eski | 4 / 4 | 203,744 [202,301, 204,910] | 0.271 [0.263, 0.279] | 14.37 | 4 |
| GET 64 B, pipeline 1 | Redis 7.4.12 | 4 / 4 | 185,291 [183,879, 185,629] | 0.279 [0.279, 0.279] | 22.59 | 4 |
| GET 64 B, pipeline 1 | Valkey 8.1.11 | 4 / 4 | 183,310 [182,142, 184,854] | 0.283 [0.279, 0.287] | 20.65 | 4 |
| GET 64 B, pipeline 1 | Dragonfly 2.0.2 | 4 / 4 | 115,306 [114,576, 115,690] | 0.323 [0.319, 0.327] | 52.87 | 0 |
| SET 64 B, pipeline 1 | Eski | 4 / 4 | 205,353 [203,367, 206,402] | 0.259 [0.255, 0.263] | 14.37 | 4 |
| SET 64 B, pipeline 1 | Redis 7.4.12 | 4 / 4 | 179,676 [179,296, 180,733] | 0.287 [0.287, 0.287] | 22.49 | 4 |
| SET 64 B, pipeline 1 | Valkey 8.1.11 | 4 / 4 | 178,454 [177,636, 180,651] | 0.287 [0.287, 0.287] | 20.49 | 4 |
| SET 64 B, pipeline 1 | Dragonfly 2.0.2 | 4 / 4 | 111,261 [110,584, 112,741] | 0.335 [0.335, 0.343] | 52.79 | 0 |
| SET and GET 1:1, 64 B, pipeline 1 | Eski | 4 / 4 | 203,606 [202,798, 204,296] | 0.267 [0.255, 0.271] | 14.37 | 4 |
| SET and GET 1:1, 64 B, pipeline 1 | Redis 7.4.12 | 4 / 4 | 180,511 [179,773, 181,506] | 0.287 [0.287, 0.287] | 22.64 | 4 |
| SET and GET 1:1, 64 B, pipeline 1 | Valkey 8.1.11 | 4 / 4 | 180,802 [179,811, 182,852] | 0.283 [0.279, 0.287] | 20.59 | 4 |
| SET and GET 1:1, 64 B, pipeline 1 | Dragonfly 2.0.2 | 4 / 4 | 112,313 [111,892, 112,428] | 0.335 [0.335, 0.335] | 52.84 | 0 |
| SET and GET 1:1, 64 B, pipeline 16 | Eski | 0 / 4 | excluded | excluded | — | 0 |
| SET and GET 1:1, 64 B, pipeline 16 | Redis 7.4.12 | 4 / 4 | 1,072,454 [1,066,841, 1,074,650] | 0.659 [0.655, 0.663] | 22.63 | 0 |
| SET and GET 1:1, 64 B, pipeline 16 | Valkey 8.1.11 | 4 / 4 | 1,084,969 [1,079,172, 1,095,234] | 0.647 [0.639, 0.647] | 21.31 | 0 |
| SET and GET 1:1, 64 B, pipeline 16 | Dragonfly 2.0.2 | 4 / 4 | 644,218 [641,259, 648,192] | 0.947 [0.943, 0.951] | 58.35 | 0 |
| GET 1024 B, pipeline 1 | Eski | 4 / 4 | 192,703 [192,130, 193,783] | 0.291 [0.287, 0.295] | 112.80 | 4 |
| GET 1024 B, pipeline 1 | Redis 7.4.12 | 4 / 4 | 173,901 [172,454, 174,448] | 0.295 [0.295, 0.303] | 137.38 | 4 |
| GET 1024 B, pipeline 1 | Valkey 8.1.11 | 4 / 4 | 174,958 [173,182, 175,749] | 0.295 [0.295, 0.295] | 135.46 | 4 |
| GET 1024 B, pipeline 1 | Dragonfly 2.0.2 | 4 / 4 | 106,822 [106,428, 107,753] | 0.351 [0.351, 0.351] | 137.71 | 0 |
| HGET, 16 fields of 64 B, pipeline 1 | Eski | 4 / 4 | 189,570 [187,367, 191,895] | 0.299 [0.287, 0.303] | 134.24 | 4 |
| HGET, 16 fields of 64 B, pipeline 1 | Redis 7.4.12 | 4 / 4 | 174,606 [173,782, 175,110] | 0.295 [0.295, 0.295] | 137.40 | 4 |
| HGET, 16 fields of 64 B, pipeline 1 | Valkey 8.1.11 | 4 / 4 | 175,334 [172,533, 177,240] | 0.287 [0.287, 0.295] | 135.32 | 4 |
| HGET, 16 fields of 64 B, pipeline 1 | Dragonfly 2.0.2 | 4 / 4 | 112,367 [111,246, 112,858] | 0.331 [0.327, 0.335] | 245.95 | 0 |
| SISMEMBER, 16 members, pipeline 1 | Eski | 4 / 4 | 196,644 [195,662, 197,100] | 0.279 [0.271, 0.287] | 33.25 | 4 |
| SISMEMBER, 16 members, pipeline 1 | Redis 7.4.12 | 4 / 4 | 179,359 [176,937, 181,796] | 0.287 [0.279, 0.287] | 33.36 | 4 |
| SISMEMBER, 16 members, pipeline 1 | Valkey 8.1.11 | 4 / 4 | 182,302 [179,538, 184,069] | 0.279 [0.279, 0.287] | 31.21 | 4 |
| SISMEMBER, 16 members, pipeline 1 | Dragonfly 2.0.2 | 4 / 4 | 120,372 [120,276, 121,654] | 0.311 [0.311, 0.311] | 98.85 | 0 |
| ZSCORE, 16 members, pipeline 1 | Eski | 4 / 4 | 192,190 [190,354, 192,593] | 0.295 [0.295, 0.295] | 36.30 | 4 |
| ZSCORE, 16 members, pipeline 1 | Redis 7.4.12 | 4 / 4 | 178,279 [177,216, 178,875] | 0.287 [0.287, 0.287] | 36.38 | 4 |
| ZSCORE, 16 members, pipeline 1 | Valkey 8.1.11 | 4 / 4 | 178,465 [177,802, 180,976] | 0.287 [0.279, 0.287] | 34.44 | 4 |
| ZSCORE, 16 members, pipeline 1 | Dragonfly 2.0.2 | 4 / 4 | 117,307 [116,445, 118,714] | 0.319 [0.311, 0.319] | 70.88 | 0 |

Each p99 is a per-run percentile; the table takes the median of those percentiles and does not pool requests. Container memory peak covers preload, warmup and timing, so it is not process RSS or live key memory. Client-limited measurements remain included and annotated. Their observed throughput is limited by the load generator; a ratio between two such observations is not a lower bound on the true ratio between the engines. The badge reports only GET 64 B at pipeline 1: 1.10x observed Eski/Redis median throughput (client limited). There is no overall cross-workload score.

## Excluded repetitions

| Workload | Engine | Repetition | Reason |
| --- | --- | ---: | --- |
| SET and GET 1:1, 64 B, pipeline 16 | Eski | 1 | case invalid; thermal_throttling |
| SET and GET 1:1, 64 B, pipeline 16 | Eski | 2 | case invalid; thermal_throttling |
| SET and GET 1:1, 64 B, pipeline 16 | Eski | 3 | case invalid; thermal_throttling |
| SET and GET 1:1, 64 B, pipeline 16 | Eski | 4 | case invalid; thermal_throttling |

Excluded values have no median or badge score. Each exclusion retains its recorded reason; client_limited, kernel_thread_on_client_cpu and tail_stall are separate annotations on included measurements. The reason external_cpu_activity names a process outside the run, kernel_thread_on_reserved_cpu a per-CPU kernel thread busy on the server CPU and throughput_collapse a second of the timed run below half of the run's median per-second rate; the next paragraph of the machine requirements states the rules.

## Fill measurement

The separate fill workload uses 10,000,000 generated keys of 64 bytes at pipeline 32. The stored-key count in the receipt is retained as measured. This recorded fill predates the settle step and read memory as soon as the load generator returned; a fill now reads it once used memory has been stable for three seconds and the server reports no keyspace rehash in progress, at most sixty seconds after the fill.

| Engine | Stored keys | RSS bytes/key | Used bytes/key | Container peak bytes/key | Fill ops/s | p99 ms | Worst request ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Eski | 10,000,001 | 122.96 | 121.99 | 128.49 | 1,689,637 | 4.191 | 31.231 |
| Redis | 10,000,001 | 166.46 | 163.44 | 166.06 | 919,163 | 1.479 | 3.535 |
| Valkey | 10,000,001 | 138.65 | 134.93 | 138.11 | 877,642 | 2.495 | 4.927 |
| Dragonfly | 10,000,001 | 106.79 | 101.70 | 106.46 | 716,687 | 1.215 | 2.335 |

## Run the comparison on a new machine

The comparison can be measured again from a clone of this repository. A workstation with docker, python3 and ssh builds the Eski image and drives a separate test machine; the machine runs the exam unattended, and the workstation collects the archives, builds the dataset and regenerates this page. The engine images, the load generator and the jq packages are pinned by digest or sha256 in the design, so two runs of one design differ only in the machine and the Eski revision.

Three designs are tracked, with the same engines, workloads, dataset, repetitions and gates. `bench/testbed/design.json` is the laptop design: server CPU 1, client CPUs 3 and 4, controller CPUs 5 and 11, two client threads of 16 connections and the `mains` power gate. `bench/testbed/designs/cloud-two-client-cores.json` keeps that client for a server: server CPU 2, client CPUs 4 and 5, controller CPU 10 and the `no-power-supply-devices` power gate. `bench/testbed/designs/cloud-four-client-cores.json` spreads the same 32 connections over four client threads of 8 connections on client CPUs 4 to 7, so that the load generator limits fewer measurements; 84 of the 124 valid measurements above are client limited.

### Machine requirements

- One processor socket, or every role on one socket and memory node, on bare metal. A virtual machine usually exposes no CPU frequency policy and no package temperature, and `exam.sh inspect` rejects a role CPU without a readable frequency policy. Prefer a processor without separate performance and efficiency cores; otherwise put every role on one kind of core.
- The thermal and throttle telemetry the gates read. The package temperature comes from hwmon with the chip and label in `gates.sensor_chip` and `gates.sensor_label`, `coretemp` and `Package id 0` on Intel; the reader also accepts `k10temp` or `zenpower` with `Tctl` or `Tdie`. Every sample also needs the per-CPU counters under `/sys/devices/system/cpu/cpu*/thermal_throttle`, which Linux exposes on Intel processors; without them every case holds with `throttle_telemetry_unavailable`. Check `grep . /sys/class/hwmon/hwmon*/name` and `ls /sys/devices/system/cpu/cpu1/thermal_throttle` first.
- Simultaneous multithreading off with the `nosmt` kernel parameter, so that one CPU number is one physical core, and the graphics driver blacklisted with `modprobe.blacklist=i915`: add `nosmt modprobe.blacklist=i915` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, run `update-grub` and reboot. `/sys/devices/system/cpu/smt/control` then reads `off`, `lscpu` reports one thread per core and `ls /sys/class/drm` lists no `card*` entry. A server with another display driver, for example `ast` on a board with a BMC console or `amdgpu` or `nouveau` with a discrete card, blacklists that module instead. The installer reads `/proc/modules` and `/sys/class/drm` and refuses to install while a display driver is loaded; `--accept-display-driver` installs anyway on a machine that needs its display, and the dataset then records the accepted driver.
- No kernel work bound to a role CPU. The recorded run `cloud-v1` on a rented Supermicro E-2288G showed two throughput modes with the same engines and workloads: the Debian kernel had loaded the `i915` driver on a machine with nothing attached to its display outputs, and its delayed work ran as per-CPU bound kernel workers (`kworker/1:0+events`, `kworker/1:2+i915-unordered`) at a full core on the server CPU for 12 to 15 seconds at a time, recurring every 35 to 37 seconds for the whole six hours. While the worker ran, the server process fell to a few percent of its core, the first request on every connection waited about 545 ms and the case lost a fifth to almost half of its throughput; on a client CPU the same worker cost nothing measurable. Loopback has no interrupt, so interrupt affinity, `irqbalance`, `isolcpus` and receive packet steering play no part in it. The sampler had recorded the worker in every affected sample, but the validity rule exempted every kernel worker. The exam now records the kernel command line, the loaded modules, the DRM devices and `kernel.timer_migration` in the machine section of the dataset, keeps the eight CPU time fields, the softirq counters and the interrupt totals of every CPU in every sample, notes the last CPU of every sampled process, and keeps the per-second request counts of the timed client in the dataset row as `per_second_ops`, `steady_ops`, `stall_seconds` and `stall_windows`, so a collapse is visible in the report. Before the calibration the controller watches the idle machine for `gates.idle_watch_seconds` (600 in both cloud designs; the laptop design and local quick runs omit the key or set 0) and holds the run when any process outside the run, kernel threads included, uses a tenth of a core on a server or client CPU in any sample, naming the process and the CPU; the bursts recur every 35 to 37 seconds, so ten minutes catches them with certainty. `exam.sh status` pins itself to the controller CPU, so polling never disturbs the watch or a case.
- Debian 13. The installer fetches the jq packages pinned in the design's `tools.jq` (jq and libjq1 1.7.1-6+deb13u4, libonig5 6.9.9-1+b1) with `apt-get download`, checks their sha256 and unpacks them with `dpkg-deb` into the run root without root privileges. If the configured archive no longer offers these versions, add a snapshot.debian.org source dated while it did.
- docker with the ssh user in the `docker` group and access to the registries, because the installer pulls every pinned engine, load generator and CLI image that is missing and checks its digest; tmux, in which the exam runs detached; python3, `ss`, `taskset` and `timeout`. As root: `apt-get install docker.io tmux python3 iproute2 util-linux linux-cpupower` and `usermod -aG docker <user>`.
- Key-based ssh from the workstation: `ssh -o BatchMode=yes user@HOST true` must succeed, because the installer and the collector call ssh in batch mode.
- The power gate named by `gates.power_source`. `mains`, the laptop setting, requires an online Mains device under `/sys/class/power_supply` in every sample, so a laptop stays plugged in for the whole run; on battery the first case holds. `no-power-supply-devices`, the setting of both cloud designs, requires a machine that exposes no power supply device at all, so `ls /sys/class/power_supply` prints nothing; a server that lists an online Mains device uses `mains`.
- A quiet machine. Before every case the whole machine and each server and client CPU must be at least `gates.min_idle` (95) percent idle, no process outside the run may use a tenth of a core, the package must be at or below `gates.cool_temp_c` (55 C), `gates.min_rest` (30) seconds must have passed and `gates.min_free_bytes` (10 GiB) must be free under the run root, all for `gates.stable_seconds` (10) seconds; a gate unmet for `gates.max_wait` (600) seconds holds the run. Disable unattended upgrades and periodic timers, for example with `systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer`, and poll the status sparingly. If the idle package sits above about 45 C, raise `cool_temp_c` in a copy of the design and in its `methodology.gates` sentence.
- During a case the scheduler reads every machine sample and the raw timed client output. A process outside the run that uses a tenth of a core or more in any sample, or a known load generator or compiler at any share, invalidates the case with external_cpu_activity. Outside the run means not an owned process, not in the cgroup of a container the run started, not docker or systemd infrastructure (dockerd, containerd, containerd-shim, systemd, systemd-journal) and not a kernel thread, recognised by a parent PID of 2 (kthreadd) or a comm starting with kworker/, rcu_, rcuc/, rcub/, jbd2/, ksoftirqd/, migration/, kswapd, kcompactd or khugepaged. A process seen in a single sample below two percent of a core, one or two scheduler ticks, is ignored; this is the harness's own load generator version probe, which runs before any ownership record exists. Kernel threads bound to one CPU (kworker/N:, ksoftirqd/N, migration/N, rcuc/N, placed by the recorded processor when the sample has one and by the N in the name otherwise) are judged by that CPU: at or above a tenth of a core on a server CPU they invalidate the case with kernel_thread_on_reserved_cpu, on a client CPU they annotate it with kernel_thread_on_client_cpu, and unbound workers and kernel threads on other CPUs are exempt. Independently of any named cause, the per-second request counts of the timed client, without the trailing partial second, must all stay at or above half of the run's median or the case is invalid with throughput_collapse, and a run whose maximum latency exceeds 100 ms while its p99 is under 1 ms carries the tail_stall annotation. In the recorded run above a display driver's per-CPU kernel worker on the server CPU stalled 52 of 132 timed runs; the rules mark exactly those and agree with each other on every case, and three cases carry external_cpu_activity for genuine outside work, an apt-listchanges python3 and the systemd-logind, dbus and sshd work of ssh status checks, one of them without a stall.
- One frequency policy for the whole run. Set the governor once before the installation, for example with `cpupower frequency-set -g performance`, and leave it; the preflight records the policy of every role CPU, and a change holds the run or invalidates the case.
- Free ports 6379 for Redis, 6380 for Valkey, 6381 for Dragonfly and 6400 for Eski. The engines use host networking on these fixed ports, and the harness fails a case whose port is taken.
- CPU 0 outside every role, since the kernel places housekeeping work and many interrupts there. Choose the roles from `lscpu --extended=CPU,CORE,SOCKET,NODE,ONLINE`: with SMT off every CPU has its own core. Take one CPU for the server, as many CPUs as `client.threads` for the load generator and one for the controller, distinct, online and on one socket and node, and write them into `resources.server_cpus`, `resources.client_cpus` and `resources.control_cpus`. The cloud designs use server CPU 2, client CPUs 4 and 5 or 4 to 7 and controller CPU 10, which fit any machine with at least 11 cores. The scheduler refuses overlapping roles, roles that share a physical core and a client pool smaller than the client threads. When the core count of a role changes, change the matching sentence of the design's `methodology` too, because this page publishes it.
- Memory for the server and client container caps, `resources.server_memory` (8 GiB) and `resources.client_memory` (2 GiB). The fill of 10,000,000 keys needs about 1.7 GB in the largest engine, so 16 GiB of RAM is enough.

### Time

The recorded run above took 6.89 hours for 132 cases, with a median case of 80 seconds and a median gap of 110 seconds between cases, which the gates spend on rest, stability and cooling. On a server about 125 seconds per case is a fair planning figure: the 132 cases of four engines, eight workloads, four repetitions and the calibration take about 4.6 hours. The installation takes about 20 minutes and the fill a few minutes, so plan about 6 hours of machine time.

### Steps

The commands use `<revision>` for the Eski revision, `<name>` for the run name, `user@HOST` for the test machine and `<base>` for a directory on it, for example `/home/user/eski-exam`. The run name is a new plain directory name such as `cloud-v1`; it becomes the run root `<base>/<name>`, the `run.root` of the dataset and the directory under `bench/testbed/runs/`, whose name the table generator checks.

1. On the workstation, build and export the Eski image from a clean checkout of the revision. `image.sh` builds the Dockerfile at the repository root, which fetches its pinned build inputs from Docker Hub, snapshot.ubuntu.com and GitHub, checks the binary, version, licence and source tree inside the image, saves the image to `bench/results/image/eski-<id>.tar` with a `.sha256` file and records the image ID, binary sha256, source sha256, revision and archive in `bench/image.json`, which the installer reads.

   ```sh
   git checkout <revision>
   bash bench/image.sh --revision "$(git rev-parse HEAD)" --export bench/results/image
   ```

2. Copy a design, set its CPU roles and gates for the machine, and render its plans; the plan writer validates the design and stops on an error.

   ```sh
   cp bench/testbed/designs/cloud-four-client-cores.json bench/results/<name>-design.json
   python3 -I bench/testbed/plans.py --design bench/results/<name>-design.json --out bench/results/<name>-plans
   ```

3. Install the run root. The installer packs the runner, the plans, the design, the fill script, the image archive and itself into an overlay, streams it over ssh into `<base>/.overlays` and checks its sha256 on arrival. On the machine it refuses an existing root, verifies every file, fetches jq, loads the Eski image and checks the binary and source sha256 inside it, pulls the missing pinned images and checks their digests, runs the preflight `exam.sh inspect` and freezes `protocol.json` with the kernel command line, the loaded modules and the DRM devices in its machine section. It starts nothing. A loaded display driver stops the installation before anything is downloaded, with the module to blacklist in the message. A rejected preflight prints the reason and moves the root aside to `<base>/.failed-<name>-<time>`, so the same name can be installed again. The receipt, also kept as `<base>/<name>/install.json`, records the protocol sha256, the phase identities, every image ID and the planned measurement counts.

   ```sh
   python3 -I -B bench/testbed/install.py install --host user@HOST --root <name> --base <base> \
     --design bench/results/<name>-design.json --receipt bench/results/<name>-install.json
   ```

4. Check the installation, then start the exam. Before the start the status reads `Workflow: NOT STARTED` and shows the kernel command line, the display drivers, the package temperature, the power gate and the power supply devices, the CPU roles, the memory limits, every engine image ID and the Eski source revision. The first invocation without arguments starts the idle watch, the calibration phase and then the benchmark phase once, in a detached tmux session; every later invocation without arguments only prints the status. While the watch runs, the Reason line says so; a failed watch holds the run with the offending process and CPU on the Reason line and in `control/idle-watch.json`, and `exam.sh resume` repeats the watch after the fix.

   ```sh
   ssh user@HOST <base>/<name>/exam.sh status
   ssh user@HOST <base>/<name>/exam.sh
   ```

   Check progress with `exam.sh status` every few minutes at most. The calibration runs its workload once per engine and admits the benchmark only when every engine is valid. `DONE` and `DONE WITH EXCLUSIONS` continue below; an excluded repetition keeps its reason and is never retried. `HELD` and `INTERRUPTED` continue with `<base>/<name>/exam.sh resume` once the cause is gone. A gate hold during the calibration also reads "calibration did not pass for every engine" on the Reason line while the phase progress still shows cases remaining; its unmet gates are listed under `phase_status.pause_reasons` of `exam.sh status --json`, and it can be resumed. A calibration whose cases all finished with an invalid engine cannot be resumed; install a new root after the fix. Whenever the controller stops it writes `exports/results.tar.gz`, `exports/inventory.json` and `exports/receipt.json`; an export after a resume is `results-2.tar.gz`, and the collector takes the archive the receipt names.

5. After `DONE` or `DONE WITH EXCLUSIONS`, run the fill. It refuses while the controller is active, waits for each engine's cooling gate from the design's `fill` block, stores 10,000,000 keys of 64 B per engine with the server core and memory caps of the design, reads the memory once used memory has been stable for three seconds and the server reports no keyspace rehash in progress, polling once a second for at most sixty seconds after the fill, and writes `exports/fill-<stamp>.tar.gz` and `exports/fill-receipt.json`. It exits with status 1 when an engine's fill is not valid; that engine keeps its reason.

   ```sh
   ssh user@HOST <base>/<name>/fill.sh
   ```

6. Fetch both archives. Each fetch reads the receipt on the machine, copies the archive it names into `bench/results/<name>/`, checks its sha256 and size against the receipt, extracts it after refusing unsafe paths, verifies every file against the archive's inventory and writes `<stem>.receipt.json` and `<stem>.collected.json` beside it. The results land in `bench/results/<name>/results/` and the fill in `bench/results/<name>/fill-<stamp>/`; an archive that was already collected is never overwritten. After a resume the results stem is `results-2` or later, which then replaces `results` in the paths below.

   ```sh
   python3 -I -B bench/testbed/collect.py fetch --host user@HOST --root <name> --base <base> --kind results
   python3 -I -B bench/testbed/collect.py fetch --host user@HOST --root <name> --base <base> --kind fill
   ```

7. Combine them into the run directory. A measurement enters the dataset only when its case succeeded with an artifact inventory matching the checkpoint and finite throughput, p99 and memory.

   ```sh
   python3 -I -B bench/testbed/combine.py --results bench/results/<name>/results --fill bench/results/<name>/fill-<stamp> \
     --collected bench/results/<name>/results.collected.json --out bench/testbed/runs/<name>/dataset.json
   ```

8. Copy the receipts.

   ```sh
   cp bench/results/<name>/results.receipt.json bench/results/<name>/results.collected.json bench/testbed/runs/<name>/
   cp bench/results/<name>/fill-<stamp>.receipt.json bench/testbed/runs/<name>/fill.receipt.json
   cp bench/results/<name>-install.json bench/testbed/runs/<name>/install.receipt.json
   ```

9. Render the charts and the report.

   ```sh
   python3 -I bench/testbed/charts.py --dataset bench/testbed/runs/<name>/dataset.json --out bench/testbed/runs/<name>/charts
   python3 -I bench/testbed/page.py --dataset bench/testbed/runs/<name>/dataset.json --out bench/testbed/runs/<name>/report.html
   ```

10. Build the server as [build, run and test](build-run-test.md) describes and regenerate the tables. The generator starts `bin/eski` on a free local port to read the command inventory and rewrites the README tables, this page and the badges from the dataset; the ratio badge needs valid Eski and Redis repetitions of `get64-p1`. Without `--benchmark-results` it reads the recorded run with the latest finish time, so the check confirms that the new run is the published one. Commit the run directory and the regenerated files together.

    ```sh
    ./build.sh release
    python3 -I test/readme_tables.py --benchmark-results bench/testbed/runs/<name>
    python3 -I test/readme_tables.py --check
    ```

### Checking a run

The run directory lets a reader check the run. `dataset.json` holds every planned repetition of both phases with its state, reasons, client-limited annotation, attempt directory and values, the per-second request counts of its timed client with the steady rate and the stall seconds and windows derived from them, and the median CPU time shares of the server and client CPUs during the timed run, together with the machine with its kernel command line, loaded modules, DRM devices and `kernel.timer_migration` at installation and at launch, the result of the idle watch, the CPU roles, the frequency policy, the sensor, the power gate, the design with its methodology, the protocol sha256, the phase identity and the receipt of the results archive. `results.receipt.json` and `results.collected.json` give the sha256, size and file count of the results archive as the machine exported it and as the workstation verified it, `fill.receipt.json` does the same for the fill archive, and `install.receipt.json` ties the protocol sha256 and the image IDs to the installation.

The raw evidence stays in the archives, which are published with the run. Each case keeps its resolved plan, harness log, machine samples, ownership events and the raw memtier output under `<phase>/results/cases/<case>/attempt-<n>/`, every gate sample is in `<phase>/results/gates.jsonl`, where the phase is `calibration` or `benchmark`, and the idle watch samples are in `control/idle-watch-<launch>.jsonl`. Every machine sample carries the eight `/proc/stat` fields of every CPU with their shares since the previous sample, the `/proc/softirqs` counters and the `/proc/interrupts` totals per CPU with their deltas, and the last CPU and kernel-thread flag of every sampled process. A reader verifies a downloaded archive with `python3 -I bench/testbed/collect.py verify results.tar.gz --receipt bench/testbed/runs/<name>/results.receipt.json --extract <directory>` and rebuilds the dataset from it with `combine.py` to compare with the committed `dataset.json`.

## Local relative measurement

The recorded comparison above needs a dedicated machine and compares engines. A change to Eski itself is measured on the shared development machine with `bench/ab.py`, which reports the cost of a candidate build relative to its parent instead of absolute numbers. It reuses the pinned memtier image, the dataset of 100,000 keys of 64 B under one prefix and the server options of the test bed, and it complements the recorded comparison rather than replacing it.

### Method

Two lanes run at the same time on symmetric cores. Lane 1 places the server on CPU 1 and memtier on CPUs 10 and 11, lane 2 places the server on CPU 2 and memtier on CPUs 12 and 13, and the controller runs on CPU 14; each memtier instance uses two threads of 16 connections. Every round starts both servers fresh, preloads them, and for each workload runs a 5 second warmup and a 20 second measured run on both lanes together. Odd rounds put build A in lane 1 and even rounds swap the lanes.

The primary metric is server CPU time per command: the task time of every server thread plus the irq and softirq time of the server CPU, divided by the commands processed in the measured window. Softirq time is included because loopback receive work triggered by the server lands there. A swap pair is an odd round and the following even round; its ratio is the geometric mean of the two B/A ratios, which cancels a constant difference between the lanes. A session reports the median and range of the clean swap-pair ratios per workload, with task time only, throughput, system calls and event-loop cycles per command as secondary figures. A workload with fewer than three clean pairs is insufficient and the session is repeated later instead of being topped up with extra rounds.

The workloads are GET and SET of 64 B at pipeline 1 and 96,000 operations per second per lane, GET and SET at pipeline 16 and 640,000 operations per second, PING at pipeline 16 and 640,000 operations per second, GET at pipeline 1 and 32,000 operations per second, and unthrottled GET at pipeline 16. The fixed rates make both builds process the same offered load. Unthrottled GET at pipeline 1 and unthrottled SET at pipelines 1 and 16 can be selected with `--workloads` when one build cannot reach a fixed rate and its runs would be excluded under the rules below. The lanes share the last level cache and memory bandwidth, so ratios are slightly compressed toward 1, and throughput on this machine is limited by the load generator, so it is not claimed.

### Noise rules

A measured run is excluded when its lane delivers less than 98 percent of a fixed offered rate, when the server CPU carries more than 30 percent of foreign task time, when the machine runs on battery, or when the server core's own thermal throttle counter rises by more than 100 events per second of the window. Package throttle events are recorded but never exclude a run: under the performance governor the package counter of every CPU rises continuously, and swap-pair ratios stayed consistent through sustained core throttling of both lanes. A round is excluded when the two lanes differ by more than 5 points of server CPU foreign time or by more than 10 points of client CPU foreign time.

Frequency is judged per swap pair, not per run. The B/A ratio of mean server core frequency is formed like the CPU ratio, which cancels the lane frequency difference, and the pair is excluded when that ratio differs from the median over the session's pairs for the workload by more than 20 percent. At a fixed rate the two cores settle on different clocks from round to round without changing the CPU ratio, and a cheaper candidate lets its own core clock down in both lanes; because the lanes swap every round, a frequency shift shared by every pair comes from the build and is not treated as noise. Every exclusion keeps its reasons in `summary.json` and the report.

### Reference floor

The floor comes from A/A session `aa-pcores-20261102-2` of one release build against itself (sha256 `9d5541264d25`) on 2026-11-02: Intel(R) Core(TM) Ultra 7 265H, kernel 7.2.10-200.fc44.x86_64, governor performance with energy preference performance, servers on CPUs 1 and 2, 8 rounds of 20 seconds after 5 seconds of warmup, with a 1-minute load of 1.74 to 7.78. The floor of a workload is the half-width around 1 of its clean swap-pair range, rounded up to half a percent. A candidate median inside the floor is no measurable change. The floor applies to sessions on the same cores under the same governor; a change of machine, kernel, governor or compiler needs a new A/A session.

| Workload | Clean swap pairs | A/A swap-pair median [min, max] | Floor |
| --- | ---: | ---: | ---: |
| get64-p1-r3k | 4 | 0.998 [0.985, 1.005] | 1.5% |
| set64-p1-r3k | 4 | 0.997 [0.975, 1.037] | 4.0% |
| get64-p16-r20k | 4 | 0.986 [0.974, 1.008] | 3.0% |
| set64-p16-r20k | 4 | 1.010 [0.990, 1.026] | 3.0% |
| ping-p16-r20k | 4 | 1.000 [0.979, 1.029] | 3.0% |
| get64-p1-r1k | 4 | 0.973 [0.934, 1.001] | 7.0% |
| get64-p16-max | 4 | 1.004 [0.995, 1.007] | 1.0% |

### Commands

Build the parent and the candidate with `./build.sh release` from paths of identical length, because the compiler embeds source paths, and copy each binary out with its sha256. Check that the 1-minute load is low and that no build or test run is active, then run `python3 -I bench/ab.py --a <parent> --b <candidate> --label <label> --out <results> --workloads <list> --max-load 3`; the defaults are concurrent mode, eight rounds, the lanes above and ports 39400 and 39401. Report with `python3 -I bench/ab_report.py <results>/<label>`, which reads `bench/ab_floor.json` and states for every workload whether the median lies within, below or above the floor; `--recompute` applies the current rules to an older session. Record a new floor with an A/A session of one build against itself and `python3 -I bench/ab_report.py <results>/<label> --write-floor bench/ab_floor.json`. `--keys <n>` replaces the 100,000 keys with n keys, preloaded the same way and drawn from the same uniform range, for changes whose effect depends on a key space larger than the last level cache; the floor records its key count, and the report marks a reading against a floor from another key count as indicative only. The unit tests run with `python3 -I -B bench/test_ab.py`.
