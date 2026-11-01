# Recorded benchmark comparison

Generated from `bench/testbed/runs/comparison-v1/dataset.json`, schema `eski-testbed-dataset-v1`. The benchmark phase contains 128 planned repetitions, 124 valid, 4 excluded and 84 included client-limited measurements. The medians and ranges below are recomputed from included benchmark rows; calibration and excluded rows do not enter them.

## Reproduce the tables

Run `python3 -I test/readme_tables.py --benchmark-results bench/testbed/runs/comparison-v1` and verify with `python3 -I test/readme_tables.py --check`. To render the recorded charts and report, run `python3 -I bench/testbed/charts.py --dataset bench/testbed/runs/comparison-v1/dataset.json --out bench/testbed/runs/comparison-v1/charts` and `python3 -I bench/testbed/page.py --dataset bench/testbed/runs/comparison-v1/dataset.json --out bench/testbed/runs/comparison-v1/report.html`. A new physical experiment uses `bench/testbed/design.json` with the plan, install and collection tools described in [build-run-test.md](build-run-test.md). It requires a dedicated machine satisfying those gates; generating tables does not launch that experiment. The [recorded report](../bench/testbed/runs/comparison-v1/report.html), [dataset](../bench/testbed/runs/comparison-v1/dataset.json) and collection receipts are committed together.

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

Excluded values have no median or badge score. Each exclusion retains its recorded reason; client_limited is a separate annotation on included measurements.

## Fill measurement

The separate fill workload uses 10,000,000 generated keys of 64 bytes at pipeline 32. The stored-key count in the receipt is retained as measured.

| Engine | Stored keys | RSS bytes/key | Used bytes/key | Container peak bytes/key | Fill ops/s | p99 ms | Worst request ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Eski | 10,000,001 | 122.96 | 121.99 | 128.49 | 1,689,637 | 4.191 | 31.231 |
| Redis | 10,000,001 | 166.46 | 163.44 | 166.06 | 919,163 | 1.479 | 3.535 |
| Valkey | 10,000,001 | 138.65 | 134.93 | 138.11 | 877,642 | 2.495 | 4.927 |
| Dragonfly | 10,000,001 | 106.79 | 101.70 | 106.46 | 716,687 | 1.215 | 2.335 |
