#!/usr/bin/env bash
set -uo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BENCH_DIR")"
RESULTS_ROOT="$BENCH_DIR/results"

REDIS_IMAGE="${BENCH_REDIS_IMAGE:-docker.io/library/redis:7}"
VALKEY_IMAGE="${BENCH_VALKEY_IMAGE:-docker.io/valkey/valkey:8}"
DRAGONFLY_IMAGE="${BENCH_DRAGONFLY_IMAGE:-docker.dragonflydb.io/dragonflydb/dragonfly}"
MEMTIER_IMAGE="${BENCH_MEMTIER_IMAGE:-docker.io/redislabs/memtier_benchmark:latest}"
ESKI_BIN="${ESKI_BIN:-$ROOT_DIR/bin/eski}"
ESKI_IMAGE="${BENCH_ESKI_IMAGE:-eski:local}"
SERVER_CPUS="${BENCH_SERVER_CPUS:-0-3}"
CLIENT_CPUS="${BENCH_CLIENT_CPUS:-4-9}"
DRAGONFLY_THREADS="${BENCH_DRAGONFLY_THREADS:-4}"
SERVER_MEMORY="${BENCH_SERVER_MEMORY:-}"
CLIENT_MEMORY="${BENCH_CLIENT_MEMORY:-}"
SERVER_MAXMEMORY="${BENCH_SERVER_MAXMEMORY:-}"
FILL_SETTLE_TIMEOUT="${BENCH_FILL_SETTLE_TIMEOUT:-60}"
FILL_SETTLE_STABLE=3
READY_TIMEOUT=30
SPEC_VERSION="0.3.46"
SPEC_SHA256="763f7dd9d453050c0cebe174437e244eeaf9a185e64de18f70bad20ed07e0ca0"
SPEC_URL="https://github.com/redis/redis-benchmarks-specification/archive/refs/tags/v${SPEC_VERSION}.tar.gz"
SPEC_TREE_NAME="redis-benchmarks-specification-$SPEC_VERSION"
SPEC_CACHE="${BENCH_SPEC_CACHE:-$BENCH_DIR/.spec}"
SPEC_TOOL="$BENCH_DIR/spec.py"
SPEC_SUITES="${BENCH_SPEC_SUITES:-}"
SPEC_MEMTIER_IMAGE="${BENCH_SPEC_MEMTIER_IMAGE:-}"
SPEC_DEFAULT_MEMTIER_IMAGE="docker.io/redislabs/memtier_benchmark:edge"
SPEC_CLIENT_TIMEOUT="${BENCH_SPEC_CLIENT_TIMEOUT:-1800}"
SPEC_PRELOAD_TIMEOUT="${BENCH_SPEC_PRELOAD_TIMEOUT:-3600}"
SPEC_CHECK_TIMEOUT="${BENCH_SPEC_CHECK_TIMEOUT:-60}"
SPEC_QUICK_TEST_TIME=5

declare -A PORT=(
  [redis]="${BENCH_PORT_REDIS:-6379}"
  [valkey]="${BENCH_PORT_VALKEY:-6380}"
  [dragonfly]="${BENCH_PORT_DRAGONFLY:-6381}"
  [eski]="${BENCH_PORT_ESKI:-6399}"
  [eski-docker]="${BENCH_PORT_ESKI_DOCKER:-6400}"
)
declare -A IMAGE=(
  [redis]="$REDIS_IMAGE"
  [valkey]="$VALKEY_IMAGE"
  [dragonfly]="$DRAGONFLY_IMAGE"
  [eski]=""
  [eski-docker]="$ESKI_IMAGE"
)
ALL_TARGETS=(redis valkey dragonfly eski eski-docker)
DEFAULT_TARGETS=(redis valkey dragonfly eski)
ALL_SCENARIOS=(mixed_p1 mixed_p16 mixed_p64 get_p1 set_p1 conn1_p1 conn500_p1 fill10m rb_p1 rb_p16)

RUN_ID="${BENCH_RUN_ID:-$$-$RANDOM}"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "run.sh: error: BENCH_RUN_ID may only contain letters, digits, '.', '_' and '-'" >&2; exit 1; }
RUN_TAG="eski-bench=$RUN_ID"
declare -A LOCKED_IMAGE=()
ESKI_PID=""
LOGS_PID=""
CURRENT_CONTAINER=""
RUN_DIR=""
FINISHED=0
FAILED_TARGETS=()
MOUNT_OPT=""
SPEC_TREE=""
PLAN=""
PLAN_COUNT=0
PLAN_IMAGES=()
SERVER_EXTRA=()
BOOTED_EXTRA=""
BOOT_ERROR=""
BOOT_TAIL=""
ITEM_BOOT_FAILED=0
ESKI_IMAGE_ID=""
ESKI_IMAGE_INFO=""
SERVER_ARGV=()
SERVER_ARTIFACT=""

IFS= read -r -d '' PY_HELPER <<'PY' || true
import csv
import json
import math
import re
import sys
from pathlib import Path


def num(v):
    if v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def pct(block, key):
    return num(((block or {}).get("Percentile Latencies") or {}).get(key))


def ms(v):
    return "-" if v is None else f"{v:.3f}"


def append(run_dir, rec):
    with open(Path(run_dir) / "records.jsonl", "a") as f:
        f.write(json.dumps(rec) + "\n")


def log_tail(path, n=6):
    p = Path(path)
    if not p.exists():
        return ""
    text = p.read_text(errors="replace").replace("\r", "\n")
    lines = [l for l in text.splitlines() if l.strip()]
    return "\n".join(lines[-n:])


def parse_info(path):
    out = {}
    p = Path(path)
    if not p.exists():
        return out
    for line in p.read_text(errors="replace").splitlines():
        line = line.strip()
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        out[k.strip()] = v.strip()
    return out


def parse_int(path):
    p = Path(path)
    if not p.exists():
        return None
    m = re.search(r"-?\d+", p.read_text())
    return int(m.group(0)) if m else None


def memtier_base(run_dir, target, scenario):
    raw = Path(run_dir) / target / f"{scenario}.json"
    data = json.loads(raw.read_text())
    stats = data.get("ALL STATS")
    if stats is None:
        merged = [k for k in data if k.startswith("AGGREGATED AVERAGE RESULTS")]
        if not merged:
            raise KeyError("ALL STATS")
        stats = data[merged[0]]
    tot = stats["Totals"]
    for label, block in stats.items():
        if isinstance(block, dict):
            for field in ("Errors", "Errors/sec", "Command Errors", "Connection Errors", "Connection Errors/sec"):
                value = num(block.get(field))
                if field in block and (value is None or not math.isfinite(value) or value != 0):
                    raise ValueError(f"{label} reports {field}={block[field]}")
    throughput = num(tot.get("Ops/sec"))
    if throughput is None or not math.isfinite(throughput) or throughput <= 0:
        raise ValueError("memtier reports no completed operations")
    cfg = data.get("configuration") or {}
    cpu = stats.get("CPU") or {}
    runtime = stats.get("Runtime") or {}
    threads = cfg.get("threads")
    clients = cfg.get("clients")
    hits = num(tot.get("Hits/sec"))
    misses = num(tot.get("Misses/sec"))
    duration = num(runtime.get("Total duration"))
    rec = {
        "target": target,
        "scenario": scenario,
        "tool": "memtier_benchmark",
        "ops_per_sec": num(tot.get("Ops/sec")),
        "p50_ms": pct(tot, "p50.00"),
        "p99_ms": pct(tot, "p99.00"),
        "p999_ms": pct(tot, "p99.90"),
        "avg_ms": num(tot.get("Average Latency", tot.get("Latency"))),
        "max_ms": num(tot.get("Max Latency")),
        "count": tot.get("Count"),
        "hits_per_sec": hits,
        "misses_per_sec": misses,
        "get_hit_ratio": (hits / (hits + misses)) if hits is not None and misses is not None and hits + misses > 0 else None,
        "connection_errors": tot.get("Connection Errors"),
        "threads": threads,
        "clients_per_thread": clients,
        "connections": threads * clients if threads and clients else None,
        "pipeline": cfg.get("pipeline"),
        "ratio": cfg.get("ratio"),
        "key_pattern": cfg.get("key_pattern"),
        "key_maximum": cfg.get("key_maximum"),
        "data_size": cfg.get("data_size"),
        "test_time_s": cfg.get("test_time") or None,
        "duration_s": duration / 1000.0 if duration is not None else None,
        "client_cpu_cores": num(cpu.get("cpu_cores_used")),
        "client_cpu_peak_pct": num(cpu.get("peak_cpu_utilization_pct")),
        "raw": f"{target}/{scenario}.json",
    }
    return rec, stats


def line_for(rec):
    return (
        f"{rec['ops_per_sec']:>12,.0f} ops/sec  p50 {ms(rec.get('p50_ms'))}  "
        f"p99 {ms(rec.get('p99_ms'))}  p99.9 {ms(rec.get('p999_ms'))} ms"
    )


def mode_memtier(run_dir, target, scenario):
    rec, _ = memtier_base(run_dir, target, scenario)
    append(run_dir, rec)
    extra = ""
    if rec["get_hit_ratio"] is not None:
        extra = f"  hit {rec['get_hit_ratio'] * 100:.1f}%"
    print(line_for(rec) + f"  ({rec['connections']} conns){extra}")


def settle_record(path):
    info = parse_info(path)
    trace = []
    for key, value in info.items():
        if key.startswith("sample_"):
            parts = value.split()
            seconds = num(parts[0]) if parts else None
            used = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
            rehashing = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else None
            trace.append([seconds, used, rehashing])
    settled = {"yes": True, "no": False}.get(info.get("settled"))
    samples = info.get("settle_samples", "")
    timeout = info.get("settle_timeout_s", "")
    return {
        "settled": settled,
        "settle_s": num(info.get("settle_s")),
        "settle_samples": int(samples) if samples.isdigit() else None,
        "settle_timeout_s": int(timeout) if timeout.isdigit() else None,
        "settle_trace": trace,
    }


def mode_fill(run_dir, target, scenario, keys_requested):
    rec, stats = memtier_base(run_dir, target, scenario)
    sets = stats.get("Sets") or {}
    rec["p50_ms"] = pct(sets, "p50.00")
    rec["p99_ms"] = pct(sets, "p99.00")
    rec["p999_ms"] = pct(sets, "p99.90")
    tdir = Path(run_dir) / target
    info = parse_info(tdir / f"{scenario}.info_memory.txt")
    dbsize = parse_int(tdir / f"{scenario}.dbsize.txt")
    used = int(info["used_memory"]) if info.get("used_memory", "").isdigit() else None
    rss = int(info["used_memory_rss"]) if info.get("used_memory_rss", "").isdigit() else None
    rec.update({
        "keys_requested": int(keys_requested),
        "dbsize": dbsize,
        "used_memory": used,
        "used_memory_rss": rss,
        "bytes_per_key_rss": (rss / dbsize) if rss is not None and dbsize else None,
        "bytes_per_key_used": (used / dbsize) if used is not None and dbsize else None,
    })
    rec.update(settle_record(tdir / f"{scenario}.settle.txt"))
    append(run_dir, rec)
    bpk = rec["bytes_per_key_rss"]
    bpk_s = "-" if bpk is None else f"{bpk:.1f}"
    rss_s = "-" if rss is None else f"{rss / 1048576:.1f}"
    db_s = "-" if dbsize is None else f"{dbsize:,}"
    wait_s = "-" if rec["settle_s"] is None else f"{rec['settle_s']:.1f}"
    settle_line = f"settled after {wait_s} s" if rec["settled"] else f"not settled after {wait_s} s"
    print(line_for(rec) + f"  dbsize {db_s}  rss {rss_s} MiB  {bpk_s} B/key rss  {settle_line}")


def rb_rows(path):
    commands = []
    with open(path, newline="") as f:
        for row in csv.reader(f):
            if len(row) < 8 or row[0] == "test":
                continue
            vals = [num(x) for x in row[1:8]]
            if vals[0] is None:
                continue
            commands.append({
                "command": row[0],
                "ops_per_sec": vals[0],
                "avg_ms": vals[1],
                "min_ms": vals[2],
                "p50_ms": vals[3],
                "p95_ms": vals[4],
                "p99_ms": vals[5],
                "max_ms": vals[6],
            })
    if not commands:
        raise ValueError("no rows in redis-benchmark CSV")
    return commands


def rb_totals(commands):
    inv = sum(1.0 / c["ops_per_sec"] for c in commands if c["ops_per_sec"])
    return {
        "ops_per_sec": (len(commands) / inv) if inv else None,
        "p50_ms": max((c["p50_ms"] for c in commands if c["p50_ms"] is not None), default=None),
        "p99_ms": max((c["p99_ms"] for c in commands if c["p99_ms"] is not None), default=None),
        "p999_ms": None,
        "max_ms": max((c["max_ms"] for c in commands if c["max_ms"] is not None), default=None),
        "aggregation": "ops_per_sec = total requests / total time across all commands; p50_ms and p99_ms = worst command",
    }


def rb_record(run_dir, target, name):
    commands = rb_rows(Path(run_dir) / target / f"{name}.csv")
    rec = {"target": target, "scenario": name, "tool": "redis-benchmark"}
    rec.update(rb_totals(commands))
    rec["commands"] = commands
    rec["raw"] = f"{target}/{name}.csv"
    return rec


def mode_rb(run_dir, target, scenario, requests, pipeline):
    commands = rb_rows(Path(run_dir) / target / f"{scenario}.csv")
    totals = rb_totals(commands)
    rec = {
        "target": target,
        "scenario": scenario,
        "tool": "redis-benchmark",
        "ops_per_sec": totals["ops_per_sec"],
        "p50_ms": totals["p50_ms"],
        "p99_ms": totals["p99_ms"],
        "p999_ms": None,
        "aggregation": totals["aggregation"],
        "requests_per_command": int(requests),
        "pipeline": int(pipeline),
        "connections": 50,
        "commands": commands,
        "raw": f"{target}/{scenario}.csv",
    }
    append(run_dir, rec)
    by = {c["command"]: c["ops_per_sec"] for c in commands}
    parts = "  ".join(f"{k} {by[k]:,.0f}" for k in ("SET", "GET") if k in by)
    print(f"{rec['ops_per_sec']:>12,.0f} ops/sec  (all {len(commands)} commands)  {parts}")


def mode_error(run_dir, target, scenario, message, log):
    rec = {
        "target": target,
        "scenario": scenario,
        "error": message,
        "ops_per_sec": None,
        "p50_ms": None,
        "p99_ms": None,
        "p999_ms": None,
        "log": log,
        "log_tail": log_tail(Path(run_dir) / log) if log else "",
    }
    append(run_dir, rec)
    print(f"FAILED: {message} (see {Path(run_dir) / log})")


def server_versions(info):
    out = {k: info[k] for k in ("redis_version", "valkey_version", "dragonfly_version", "server_name", "redis_mode", "os", "arch_bits", "multiplexing_api", "io_threads_active") if k in info}
    native = info.get("valkey_version") or info.get("dragonfly_version") or info.get("eski_version") or info.get("redis_version")
    if native:
        out["version"] = native
    return out


def mode_summary(run_dir, complete):
    run_dir = Path(run_dir)
    meta = json.loads((run_dir / "meta.base.json").read_text())
    targets = {}
    versions = {}
    for name in meta.get("targets_requested", []):
        tdir = run_dir / name
        tj = tdir / "target.json"
        entry = json.loads(tj.read_text()) if tj.exists() else {"status": "not_run"}
        info = parse_info(tdir / "info_server.txt")
        if info:
            entry.update(server_versions(info))
            versions[name] = entry.get("version")
        targets[name] = entry
    meta["targets"] = targets
    meta["versions"] = versions
    meta["complete"] = complete == "true"
    plan = run_dir / "plan.json"
    if plan.exists():
        data = json.loads(plan.read_text())
        meta["suites"] = data.get("suites") or {}
        meta["plan_items"] = len(data.get("items") or [])
    records = []
    rj = run_dir / "records.jsonl"
    if rj.exists():
        for line in rj.read_text().splitlines():
            if line.strip():
                records.append(json.loads(line))
    out = {"meta": meta, "records": records}
    tmp = run_dir / "summary.json.tmp"
    tmp.write_text(json.dumps(out, indent=2) + "\n")
    tmp.replace(run_dir / "summary.json")


def load_item(plan, index):
    return json.loads(Path(plan).read_text())["items"][int(index)]


def item_outputs(item):
    runs = int(item.get("runs") or 1)
    return [item["key"] if runs == 1 else f"{item['key']}.run{r}" for r in range(1, runs + 1)]


def item_identity(item, target):
    return {
        "target": target,
        "scenario": item["name"],
        "suite": item["suite"],
        "display": item.get("display") or item["name"],
    }


def item_setup(run_dir, target, item):
    p = Path(run_dir) / target / f"{item['key']}.setup.json"
    return json.loads(p.read_text()) if p.exists() else None


def mode_item(run_dir, target, plan, index):
    item = load_item(plan, index)
    measured = item["clients"][-1]
    per_run = []
    for name in item_outputs(item):
        if measured["tool"] == "memtier_benchmark":
            rec, _ = memtier_base(run_dir, target, name)
        else:
            rec = rb_record(run_dir, target, name)
        per_run.append(rec)
    rec = dict(per_run[0])
    if len(per_run) > 1:
        for field in ("ops_per_sec", "p50_ms", "p99_ms", "p999_ms", "avg_ms"):
            vals = [r.get(field) for r in per_run]
            rec[field] = sum(vals) / len(vals) if all(v is not None for v in vals) else None
        maxes = [r.get("max_ms") for r in per_run if r.get("max_ms") is not None]
        rec["max_ms"] = max(maxes) if maxes else None
        rec["runs"] = [{k: r.get(k) for k in ("ops_per_sec", "p50_ms", "p99_ms", "p999_ms", "max_ms", "raw", "commands") if k in r} for r in per_run]
        rec.pop("commands", None)
        rec["aggregation"] = f"ops_per_sec and latencies are the mean of {len(per_run)} runs"
    rec.update(item_identity(item, target))
    rec["client"] = {k: measured.get(k) for k in ("tool", "image", "argv", "cpus", "requested_cpus", "declared_test_time", "test_time", "removed", "added") if k in measured}
    if len(item["clients"]) > 1:
        rec["other_clients"] = [{k: c.get(k) for k in ("tool", "image", "argv", "cpus")} for c in item["clients"][:-1]]
    if item.get("preload"):
        rec["preload"] = {k: item["preload"].get(k) for k in ("tool", "image", "argv", "cpus")}
    if item.get("warmup"):
        rec["warmup"] = {k: item["warmup"].get(k) for k in ("tool", "image", "argv", "cpus")}
        rec["warmup"]["measurement_scope"] = "raw client output kept; excluded from the timed throughput and latency; included in the case telemetry and the lifetime memory peak"
    rec["case"] = item.get("info") or {}
    setup = item_setup(run_dir, target, item)
    if setup is not None:
        rec["setup"] = setup
    append(run_dir, rec)
    extra = ""
    if setup and setup.get("config_rejected"):
        extra = "  config rejected: " + ", ".join(sorted(setup["config_rejected"]))
    print(line_for(rec) + extra)


def mode_item_error(run_dir, target, plan, index, message, log):
    item = load_item(plan, index)
    rec = item_identity(item, target)
    rec.update({
        "error": message,
        "ops_per_sec": None,
        "p50_ms": None,
        "p99_ms": None,
        "p999_ms": None,
        "log": log,
        "log_tail": log_tail(Path(run_dir) / log) if log else "",
        "case": item.get("info") or {},
    })
    setup = item_setup(run_dir, target, item)
    if setup is not None:
        rec["setup"] = setup
    append(run_dir, rec)
    print(f"FAILED: {message}" + (f" (see {Path(run_dir) / log})" if log else ""))


def mode_item_skip(run_dir, target, plan, index, reason):
    item = load_item(plan, index)
    rec = item_identity(item, target)
    rec.update({"skipped": reason, "ops_per_sec": None, "p50_ms": None, "p99_ms": None, "p999_ms": None, "case": item.get("info") or {}})
    append(run_dir, rec)
    print(f"skipped: {reason}")


def item_mode(mode, args):
    if mode == "item_error":
        mode_item_error(*args)
        return
    if mode == "item_skip":
        mode_item_skip(*args)
        return
    try:
        mode_item(*args)
    except (OSError, ValueError, KeyError, TypeError, IndexError) as e:
        item = load_item(args[2], args[3])
        out = item_outputs(item)[0]
        ext = "json" if item["clients"][-1]["tool"] == "memtier_benchmark" else "csv"
        mode_item_error(args[0], args[1], args[2], args[3], f"could not parse {args[1]}/{out}.{ext}: {e}", f"{args[1]}/{out}.log")


def main():
    mode = sys.argv[1]
    args = sys.argv[2:]
    if mode == "validate_memtier":
        try:
            memtier_base(*args)
        except (OSError, ValueError, KeyError, TypeError) as e:
            raise SystemExit(f"invalid memtier result: {e}")
        return
    if mode == "summary":
        mode_summary(*args)
        return
    if mode in ("item", "item_error", "item_skip"):
        item_mode(mode, args)
        return
    if mode == "error":
        mode_error(*args)
        return
    run_dir, target, scenario = args[0], args[1], args[2]
    try:
        if mode == "memtier":
            mode_memtier(run_dir, target, scenario)
        elif mode == "fill":
            mode_fill(run_dir, target, scenario, args[3])
        elif mode == "rb":
            mode_rb(run_dir, target, scenario, args[3], args[4])
        else:
            raise SystemExit(f"unknown mode {mode}")
    except (OSError, ValueError, KeyError, TypeError) as e:
        ext = "csv" if mode == "rb" else "json"
        mode_error(run_dir, target, scenario, f"could not parse {target}/{scenario}.{ext}: {e}", f"{target}/{scenario}.log")


main()
PY

usage() {
  cat <<EOF
usage: bench/run.sh [--quick] [--targets redis,valkey,dragonfly,eski,eski-docker] [--scenarios a,b,c|none] [--label name]
                    [--spec] [--spec-cases a,b,c] [--spec-test-time N] [--spec-list] [--plan FILE]

  --quick           5 s timed scenarios, fill10m uses 1M keys, smaller redis-benchmark runs,
                    specification cases capped at ${SPEC_QUICK_TEST_TIME} s of test time
  --targets         comma separated subset of: ${ALL_TARGETS[*]}
                    (default: ${DEFAULT_TARGETS[*]}); eski runs the native binary at ESKI_BIN,
                    eski-docker runs the container image BENCH_ESKI_IMAGE built by bench/image.sh
                    with the same arguments and CPU pinning, so the two measure container overhead
  --scenarios       comma separated subset of: ${ALL_SCENARIOS[*]}, or none
  --label           suffix for the results directory name
  --spec            also run every applicable test case of the Redis benchmarks specification
                    v$SPEC_VERSION, fetched into bench/.spec and verified by sha256; a case is
                    applicable when eski implements every command it tests and sends
  --spec-cases      only these specification cases (names or shell globs); implies --spec
  --spec-test-time  cap the declared test time of every specification case at N seconds
  --spec-list       fetch the specification, probe eski, print the applicable and skipped
                    cases with the missing commands, and exit without benchmarking
  --plan            also run the items of a plan file written by bench/pts.sh

environment overrides (defaults in brackets):
  BENCH_SERVER_CPUS [0-3]  BENCH_CLIENT_CPUS [4-9]  BENCH_DRAGONFLY_THREADS [4]
  BENCH_SERVER_MEMORY, BENCH_CLIENT_MEMORY [no cap]  memory and swap cap of every server and client container
  BENCH_SERVER_MAXMEMORY [unset]  maxmemory in bytes given to every server
  BENCH_FILL_SETTLE_TIMEOUT [60]  fill10m polls INFO memory once a second after the fill and reads it once used_memory
                                  is unchanged for $FILL_SETTLE_STABLE consecutive samples that report no keyspace rehash
                                  (mem_overhead_db_hashtable_rehashing 0 or absent), waiting at most this many seconds
  BENCH_OUTPUT_DIR [bench/results/<stamp>]  absolute fresh results directory
  BENCH_RUN_ID [pid-random]  label value of every container this run owns
  BENCH_SPEC_CACHE [bench/.spec]  BENCH_OWNER_EVENTS [unset]  ownership events file read by bench/exam.sh
  BENCH_PORT_REDIS [6379]  BENCH_PORT_VALKEY [6380]  BENCH_PORT_DRAGONFLY [6381]  BENCH_PORT_ESKI [6399]
  ESKI_BIN [$ROOT_DIR/bin/eski]  BENCH_ESKI_IMAGE [eski:local]  BENCH_PORT_ESKI_DOCKER [6400]
  BENCH_SPEC_MEMTIER_IMAGE [the run_image each case declares]
  BENCH_SPEC_PRELOAD_TIMEOUT [3600]  BENCH_SPEC_CLIENT_TIMEOUT [1800, for cases without a test time]
  BENCH_SPEC_CHECK_TIMEOUT [60, how long the keyspace check waits]  BENCH_SPEC_SUITES [the pinned release]
EOF
}

say() { printf '%s\n' "$*"; }
die() { printf 'run.sh: error: %s\n' "$*" >&2; exit 1; }

contains() {
  local needle=$1; shift
  local x
  for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

select_from() {
  local kind=$1 arg=$2; shift 2
  local -a all=("$@") wanted=() out=()
  local x
  IFS=',' read -r -a wanted <<<"$arg"
  for x in "${wanted[@]}"; do
    [ -z "$x" ] && continue
    contains "$x" "${all[@]}" || die "unknown $kind '$x' (valid: ${all[*]})"
  done
  for x in "${all[@]}"; do
    contains "$x" "${wanted[@]}" && out+=("$x")
  done
  [ "${#out[@]}" -gt 0 ] || die "no $kind selected"
  printf '%s\n' "${out[@]}"
}

QUICK=0
LABEL=""
TARGETS_ARG=""
SCENARIOS_ARG=""
SPEC=0
SPEC_CASES=""
SPEC_TEST_TIME=""
SPEC_LIST=0
PLAN_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --targets) [ $# -ge 2 ] || die "--targets needs a value"; TARGETS_ARG=$2; shift ;;
    --targets=*) TARGETS_ARG=${1#--targets=} ;;
    --scenarios) [ $# -ge 2 ] || die "--scenarios needs a value"; SCENARIOS_ARG=$2; shift ;;
    --scenarios=*) SCENARIOS_ARG=${1#--scenarios=} ;;
    --label) [ $# -ge 2 ] || die "--label needs a value"; LABEL=$2; shift ;;
    --label=*) LABEL=${1#--label=} ;;
    --spec) SPEC=1 ;;
    --spec-cases) [ $# -ge 2 ] || die "--spec-cases needs a value"; SPEC=1; SPEC_CASES=$2; shift ;;
    --spec-cases=*) SPEC=1; SPEC_CASES=${1#--spec-cases=} ;;
    --spec-test-time) [ $# -ge 2 ] || die "--spec-test-time needs a value"; SPEC_TEST_TIME=$2; shift ;;
    --spec-test-time=*) SPEC_TEST_TIME=${1#--spec-test-time=} ;;
    --spec-list) SPEC_LIST=1 ;;
    --plan) [ $# -ge 2 ] || die "--plan needs a value"; PLAN_ARG=$2; shift ;;
    --plan=*) PLAN_ARG=${1#--plan=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

[[ -z "$LABEL" || "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || die "label may only contain letters, digits, '.', '_' and '-'"
[[ -z "$SPEC_TEST_TIME" || "$SPEC_TEST_TIME" =~ ^[1-9][0-9]*$ ]] || die "--spec-test-time needs a positive number of seconds"
if [ -n "$PLAN_ARG" ]; then
  [ -f "$PLAN_ARG" ] || die "plan file not found: $PLAN_ARG"
  PLAN_ARG=$(cd "$(dirname "$PLAN_ARG")" && pwd)/$(basename "$PLAN_ARG")
fi
[[ -z "$SERVER_MAXMEMORY" || "$SERVER_MAXMEMORY" =~ ^[1-9][0-9]*$ ]] || die "BENCH_SERVER_MAXMEMORY must be a positive byte count"
[[ "$FILL_SETTLE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "BENCH_FILL_SETTLE_TIMEOUT must be a positive number of seconds"
[[ -z "$SERVER_MEMORY" || "$SERVER_MEMORY" =~ ^[1-9][0-9]*[bkmgBKMG]?$ ]] || die "BENCH_SERVER_MEMORY must be a docker memory size such as 8g"
[[ -z "$CLIENT_MEMORY" || "$CLIENT_MEMORY" =~ ^[1-9][0-9]*[bkmgBKMG]?$ ]] || die "BENCH_CLIENT_MEMORY must be a docker memory size such as 2g"

if [ -n "$TARGETS_ARG" ]; then
  mapfile -t TARGETS < <(select_from target "$TARGETS_ARG" "${ALL_TARGETS[@]}") || exit 1
  [ "${#TARGETS[@]}" -gt 0 ] || exit 1
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi
if [ "$SCENARIOS_ARG" = none ]; then
  SCENARIOS=()
elif [ -n "$SCENARIOS_ARG" ]; then
  mapfile -t SCENARIOS < <(select_from scenario "$SCENARIOS_ARG" "${ALL_SCENARIOS[@]}") || exit 1
  [ "${#SCENARIOS[@]}" -gt 0 ] || exit 1
else
  SCENARIOS=("${ALL_SCENARIOS[@]}")
fi

if [ "$QUICK" = 1 ]; then
  T=5; FILL_KEYS=1000000; RB_P1_N=100000; RB_P16_N=300000
else
  T=15; FILL_KEYS=10000000; RB_P1_N=200000; RB_P16_N=1000000
fi

COMMON_ARGS=(--data-size=64 --key-maximum=1000000 --key-pattern=R:R --distinct-client-seed "--test-time=$T")
PREFILL_ARGS=(--ratio=1:0 --key-pattern=P:P --requests=allkeys --key-maximum=1000000 --pipeline=32 --threads=4 --clients=5 --data-size=64)
FILL_ARGS=(--ratio=1:0 --key-pattern=P:P --requests=allkeys "--key-maximum=$FILL_KEYS" --pipeline=32 --threads=4 --clients=5 --data-size=64)

scenario_args() {
  case "$1" in
    mixed_p1) echo "--ratio=1:1 --pipeline=1 --threads=5 --clients=10" ;;
    mixed_p16) echo "--ratio=1:1 --pipeline=16 --threads=5 --clients=10" ;;
    mixed_p64) echo "--ratio=1:1 --pipeline=64 --threads=5 --clients=10" ;;
    get_p1) echo "--ratio=0:1 --pipeline=1 --threads=5 --clients=10" ;;
    set_p1) echo "--ratio=1:0 --pipeline=1 --threads=5 --clients=10" ;;
    conn1_p1) echo "--ratio=1:1 --pipeline=1 --threads=1 --clients=1" ;;
    conn500_p1) echo "--ratio=1:1 --pipeline=1 --threads=10 --clients=50" ;;
  esac
}

scenario_flags() {
  case "$1" in
    fill10m) echo "memtier ${FILL_ARGS[*]}" ;;
    rb_p1) echo "redis-benchmark -t ping,set,get,incr,mset -n $RB_P1_N -c 50 -P 1 -r 1000000 -d 64 --csv" ;;
    rb_p16) echo "redis-benchmark -t ping,set,get,incr,mset -n $RB_P16_N -c 50 -P 16 -r 1000000 -d 64 --csv" ;;
    *) echo "memtier $(scenario_args "$1") ${COMMON_ARGS[*]}" ;;
  esac
}

py() { python3 -c "$PY_HELPER" "$@"; }

rcli() {
  local port=$1; shift
  timeout 30 docker run --pull=never --rm --label "$RUN_TAG" --network=host "$(image_id "$REDIS_IMAGE")" \
    redis-cli -h 127.0.0.1 -p "$port" "$@" 2>/dev/null | tr -d '\r'
}

port_busy() { [ -n "$(ss -ltnH "sport = :$1" 2>/dev/null)" ]; }

port_owner() {
  local who
  who=$(docker ps --filter "publish=$1" --format '{{.Names}}' 2>/dev/null | paste -sd, -)
  [ -n "$who" ] && { echo "container $who"; return; }
  who=$(ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'users:(([^)]*' | head -n1 | sed 's/users:((//')
  [ -n "$who" ] && { echo "process $who"; return; }
  echo "unknown owner"
}

isolated_cpus() { cat /sys/fs/cgroup/cpuset.cpus.isolated 2>/dev/null || true; }

docker_cpus() {
  cat /sys/fs/cgroup/system.slice/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || true
}

power_profile() {
  local p=""
  if command -v powerprofilesctl >/dev/null 2>&1; then
    p=$(powerprofilesctl get 2>/dev/null)
  elif command -v tuned-adm >/dev/null 2>&1; then
    p=$(tuned-adm active 2>/dev/null | sed -n 's/^Current active profile: //p')
  fi
  [ -z "$p" ] && [ -r /sys/firmware/acpi/platform_profile ] && p=$(cat /sys/firmware/acpi/platform_profile)
  echo "${p:-unknown}"
}

ac_online() {
  local f
  for f in /sys/class/power_supply/*/type; do
    [ "$(cat "$f" 2>/dev/null)" = Mains ] || continue
    cat "$(dirname "$f")/online" 2>/dev/null && return
  done
  echo unknown
}

image_id() {
  if [ -n "${LOCKED_IMAGE[$1]:-}" ]; then
    printf '%s\n' "${LOCKED_IMAGE[$1]}"
  else
    docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || echo unknown
  fi
}

lock_image() {
  local id
  [ -n "${LOCKED_IMAGE[$1]:-}" ] && return 0
  id=$(docker image inspect --format '{{.Id}}' "$1" 2>/dev/null) || die "docker image $1 is not present locally; run: docker pull $1"
  LOCKED_IMAGE[$1]=$id
}

observe() {
  [ -n "${BENCH_OWNER_EVENTS:-}" ] || return 0
  local command=$1 kind=$2 role=$3
  shift 3
  if [ "$command" = watch ]; then
    exec python3 -I "$BENCH_DIR/exam_metrics.py" "$command" --events "$BENCH_OWNER_EVENTS" --kind "$kind" --role "$role" "$@" >>"${BENCH_OWNER_EVENTS}.log" 2>&1
  fi
  python3 -I "$BENCH_DIR/exam_metrics.py" "$command" --events "$BENCH_OWNER_EVENTS" --kind "$kind" --role "$role" "$@" >>"${BENCH_OWNER_EVENTS}.log" 2>&1
}

need_prefill() {
  local s
  for s in "${SCENARIOS[@]}"; do
    case "$s" in mixed_*|get_p1|set_p1|conn*) return 0 ;; esac
  done
  return 1
}

stop_eski() {
  [ -n "$ESKI_PID" ] || return 0
  observe hook before-stop server --pid "$ESKI_PID" --artifact-dir "$SERVER_ARTIFACT"
  if kill -0 "$ESKI_PID" 2>/dev/null; then
    kill -TERM "$ESKI_PID" 2>/dev/null
    local i
    for i in $(seq 1 50); do
      kill -0 "$ESKI_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$ESKI_PID" 2>/dev/null
  fi
  wait "$ESKI_PID" 2>/dev/null
  ESKI_PID=""
}

forget_container() {
  local name=$1 i
  for i in $(seq 1 100); do
    docker container inspect "$name" >/dev/null 2>&1 || return 0
    docker rm -f "$name" >/dev/null 2>&1
    sleep 0.2
  done
  return 1
}

stop_logs() {
  [ -n "$LOGS_PID" ] || return 0
  local i
  for i in $(seq 1 30); do
    kill -0 "$LOGS_PID" 2>/dev/null || break
    sleep 0.1
  done
  kill "$LOGS_PID" 2>/dev/null
  wait "$LOGS_PID" 2>/dev/null
  LOGS_PID=""
}

write_summary() {
  [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/meta.base.json" ] || return 0
  py summary "$RUN_DIR" "$1"
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  stop_eski
  if [ -n "$CURRENT_CONTAINER" ]; then
    observe hook before-stop server --container "$CURRENT_CONTAINER" --artifact-dir "$SERVER_ARTIFACT"
    docker rm -f "$CURRENT_CONTAINER" >/dev/null 2>&1
  fi
  local leftovers
  leftovers=$(docker ps -aq --filter "label=$RUN_TAG" 2>/dev/null)
  [ -n "$leftovers" ] && docker rm -f $leftovers >/dev/null 2>&1
  stop_logs
  if [ "$FINISHED" = 0 ] && [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/meta.base.json" ]; then
    write_summary false
    say "partial results written to $RUN_DIR/summary.json"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'printf "\ninterrupted, cleaning up\n" >&2; exit 130' INT TERM

check_cpuset() {
  local cpus=$1 role=$2 err
  if ! err=$(docker run --pull=never --rm --label "$RUN_TAG" --cpuset-cpus="$cpus" "$(image_id "$REDIS_IMAGE")" true 2>&1); then
    printf 'run.sh: error: docker cannot pin the %s to CPUs %s\n  docker said: %s\n' "$role" "$cpus" "$(printf '%s' "$err" | head -n1)" >&2
    printf '  CPUs docker may use right now: %s; CPUs isolated by a cpuset partition: %s\n' "$(docker_cpus)" "$(isolated_cpus)" >&2
    printf '  power profile: %s, AC online: %s\n' "$(power_profile)" "$(ac_online)" >&2
    printf '  If intel_lpmd has parked the P-cores (balanced or battery power profile), switch to the performance\n  profile on AC power, or override with BENCH_SERVER_CPUS / BENCH_CLIENT_CPUS.\n' >&2
    exit 1
  fi
}

preflight() {
  local c t img
  for c in docker python3 jq ss taskset timeout; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
  docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (rootful docker is required for --cpuset-cpus)"
  local -a imgs=("$REDIS_IMAGE" "$MEMTIER_IMAGE")
  contains valkey "${TARGETS[@]}" && imgs+=("$VALKEY_IMAGE")
  contains dragonfly "${TARGETS[@]}" && imgs+=("$DRAGONFLY_IMAGE")
  for img in "${imgs[@]}"; do
    lock_image "$img"
  done
  if contains eski-docker "${TARGETS[@]}"; then
    docker image inspect "$ESKI_IMAGE" >/dev/null 2>&1 ||
      die "docker image $ESKI_IMAGE for target eski-docker is not present locally; build it with bench/image.sh or set BENCH_ESKI_IMAGE"
    lock_image "$ESKI_IMAGE"
    ESKI_IMAGE_ID=$(image_id "$ESKI_IMAGE")
    ESKI_IMAGE_INFO=$(docker run --pull=never --rm --label "$RUN_TAG" --entrypoint /bin/cat "$ESKI_IMAGE_ID" /usr/share/doc/eski/build-info.txt 2>/dev/null) ||
      die "docker image $ESKI_IMAGE has no /usr/share/doc/eski/build-info.txt; build it with bench/image.sh"
  fi
  if docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q selinux; then
    MOUNT_OPT=":z"
  fi
  check_cpuset "$SERVER_CPUS" "servers (BENCH_SERVER_CPUS)"
  check_cpuset "$CLIENT_CPUS" "clients (BENCH_CLIENT_CPUS)"
  for t in "${TARGETS[@]}"; do
    [ "$t" = eski ] && [ ! -x "$ESKI_BIN" ] && continue
    if port_busy "${PORT[$t]}"; then
      local var="BENCH_PORT_${t^^}"
      var=${var//-/_}
      die "port ${PORT[$t]} for target '$t' is already in use ($(port_owner "${PORT[$t]}")); stop it or set $var to a free port"
    fi
  done
}

plan_images_json() {
  local img ver tools
  local -a triples=()
  for img in "${PLAN_IMAGES[@]}"; do
    ver=""
    tools=$(jq -r --arg image "$img" '[.items[] | (.clients[]?, .preload?, .warmup?) | select(. != null and .image == $image) | .tool] | unique | join(",")' "$PLAN")
    case "$tools" in
      *memtier_benchmark*) ver=$(docker run --pull=never --rm --label "$RUN_TAG" "$(image_id "$img")" --version 2>&1 | head -n1) ;;
      *redis-benchmark*) ver=$(docker run --pull=never --rm --label "$RUN_TAG" "$(image_id "$img")" redis-benchmark --version 2>&1 | head -n1) ;;
      *)
        case "$img" in
          *memtier*) ver=$(docker run --pull=never --rm --label "$RUN_TAG" "$(image_id "$img")" --version 2>&1 | head -n1) ;;
        esac ;;
    esac
    triples+=("$img" "$(image_id "$img")" "$ver")
  done
  if [ "${#triples[@]}" -eq 0 ]; then
    echo '{}'
    return
  fi
  printf '%s\n' "${triples[@]}" | jq -R . | jq -s '. as $a | reduce range(0; $a | length; 3) as $i ({}; . + {($a[$i]): {image_id: $a[$i + 1], version: $a[$i + 2]}})'
}

write_meta() {
  local memtier_version eski_sha="" eski_mtime=""
  memtier_version=$(docker run --pull=never --rm --label "$RUN_TAG" "$(image_id "$MEMTIER_IMAGE")" --version 2>&1 | head -n1)
  local -a flag_pairs=()
  local s
  for s in "${SCENARIOS[@]}"; do
    flag_pairs+=("$s" "$(scenario_flags "$s")")
  done
  local flags_json='{}' scenarios_json='[]'
  if [ "${#SCENARIOS[@]}" -gt 0 ]; then
    flags_json=$(printf '%s\n' "${flag_pairs[@]}" | jq -R . | jq -s '. as $a | reduce range(0; $a | length; 2) as $i ({}; . + {($a[$i]): $a[$i + 1]})' 2>/dev/null)
    [ -n "$flags_json" ] || flags_json='{}'
    scenarios_json=$(printf '%s\n' "${SCENARIOS[@]}" | jq -R . | jq -s .)
  fi
  local prefill_flags="memtier ${PREFILL_ARGS[*]}"
  jq -n \
    --arg date "$(date -Iseconds)" \
    --arg run_id "$(basename "$RUN_DIR")" \
    --arg label "$LABEL" \
    --arg cpu_model "$(grep -m1 'model name' /proc/cpuinfo | sed 's/^[^:]*: *//')" \
    --arg cpu_count "$(nproc --all)" \
    --arg kernel "$(uname -r)" \
    --arg os "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")" \
    --argjson quick "$([ "$QUICK" = 1 ] && echo true || echo false)" \
    --argjson test_time "$T" \
    --argjson fill_keys "$FILL_KEYS" \
    --argjson settle_timeout "$FILL_SETTLE_TIMEOUT" --argjson settle_stable "$FILL_SETTLE_STABLE" \
    --arg server_cpus "$SERVER_CPUS" \
    --arg client_cpus "$CLIENT_CPUS" \
    --arg memtier_version "$memtier_version" \
    --arg memtier_image "$MEMTIER_IMAGE" \
    --arg memtier_image_id "$(image_id "$MEMTIER_IMAGE")" \
    --arg cli_image "$REDIS_IMAGE" \
    --arg server_memory "$SERVER_MEMORY" --arg client_memory "$CLIENT_MEMORY" --arg server_maxmemory "$SERVER_MAXMEMORY" \
    --arg docker_version "$(docker version --format '{{.Server.Version}}' 2>/dev/null)" \
    --arg isolated "$(isolated_cpus)" \
    --arg docker_cpus "$(docker_cpus)" \
    --arg power_profile "$(power_profile)" \
    --arg ac_online "$(ac_online)" \
    --arg loadavg "$(cut -d' ' -f1-3 /proc/loadavg)" \
    --arg prefill "$prefill_flags" \
    --arg common "--server=127.0.0.1 --protocol=redis --hide-histogram --print-percentiles 50,99,99.9" \
    --argjson flags "$flags_json" \
    --argjson targets "$(printf '%s\n' "${TARGETS[@]}" | jq -R . | jq -s .)" \
    --argjson scenarios "$scenarios_json" \
    --argjson plan_items "$PLAN_COUNT" \
    --argjson plan_images "$(plan_images_json)" \
    --argjson spec_cap "$(spec_cap)" \
    --arg spec_memtier_image "$SPEC_MEMTIER_IMAGE" \
    '{
      date: $date, run_id: $run_id, label: $label,
      cpu_model: $cpu_model, cpu_count: ($cpu_count | tonumber), kernel: $kernel, os: $os,
      quick: $quick, test_time_s: $test_time, fill_keys: $fill_keys,
      fill_settle_timeout_s: $settle_timeout, fill_settle_stable_samples: $settle_stable,
      server_cpus: $server_cpus, client_cpus: $client_cpus,
      server_container_memory: (if $server_memory != "" then $server_memory else null end),
      client_container_memory: (if $client_memory != "" then $client_memory else null end),
      server_maxmemory_bytes: (if $server_maxmemory != "" then ($server_maxmemory | tonumber) else null end),
      memtier_version: $memtier_version, memtier_image: $memtier_image, memtier_image_id: $memtier_image_id,
      cli_image: $cli_image, docker_version: $docker_version,
      isolated_cpus_at_start: $isolated, docker_cpus_at_start: $docker_cpus,
      power_profile: $power_profile, ac_online: $ac_online, loadavg_at_start: $loadavg,
      memtier_common_flags: $common, prefill_flags: $prefill, scenario_flags: $flags,
      targets_requested: $targets, scenarios_requested: $scenarios,
      plan_items: $plan_items, plan_images: $plan_images, spec_test_time_cap_s: (if $spec_cap > 0 then $spec_cap else null end),
      spec_memtier_image_override: (if $spec_memtier_image != "" then $spec_memtier_image else null end)
    }' >"$RUN_DIR/meta.base.json"
}

target_status() {
  local t=$1 status=$2 reason=$3 started=$4
  local tdir="$RUN_DIR/$t" image="" iid="" bin="" sha="" mtime="" info="" argv_json=null limits_json=null
  if [ "$t" = eski ]; then
    bin=$ESKI_BIN
    if [ -f "$ESKI_BIN" ]; then
      sha=$(sha256sum "$ESKI_BIN" | cut -d' ' -f1)
      mtime=$(date -Iseconds -r "$ESKI_BIN")
    fi
    limits_json=$(jq -n --arg cpus "$SERVER_CPUS" '{pinning: "taskset", cpuset_cpus: $cpus, memory_bytes: 0}')
  else
    image=${IMAGE[$t]}
    iid=$(image_id "$image")
  fi
  if [ "$t" = eski-docker ] && [ -n "$ESKI_IMAGE_INFO" ]; then
    iid=$ESKI_IMAGE_ID
    info=$ESKI_IMAGE_INFO
    sha=$(sed -n 's/^binary_sha256=//p' <<<"$info" | head -n 1)
    printf '%s\n' "$info" >"$tdir/image-build-info.txt"
  fi
  if [ "${#SERVER_ARGV[@]}" -gt 0 ]; then
    argv_json=$(printf '%s\n' "${SERVER_ARGV[@]}" | jq -R . | jq -s .)
  fi
  if [ -s "$tdir/container-hostconfig.json" ]; then
    limits_json=$(jq '{pinning: "docker", cpuset_cpus: .CpusetCpus, memory_bytes: .Memory, memory_swap_bytes: .MemorySwap,
      nano_cpus: .NanoCpus, cpu_quota: .CpuQuota, pids_limit: .PidsLimit, network_mode: .NetworkMode}' \
      "$tdir/container-hostconfig.json" 2>/dev/null) || limits_json=null
  fi
  jq -n \
    --arg status "$status" --arg reason "$reason" \
    --argjson port "${PORT[$t]}" --arg cpus "$SERVER_CPUS" \
    --arg image "$image" --arg image_id "$iid" \
    --arg binary "$bin" --arg sha "$sha" --arg mtime "$mtime" \
    --arg started "$started" --arg finished "$(date -Iseconds)" \
    --arg iso "$(isolated_cpus)" \
    --arg info "$info" --argjson argv "$argv_json" --argjson limits "$limits_json" \
    --arg maxmemory "$SERVER_MAXMEMORY" \
    '{status: $status, reason: $reason, port: $port, cpus: $cpus, started_at: $started, finished_at: $finished, isolated_cpus_at_end: $iso,
      maxmemory_bytes: (if $maxmemory != "" then ($maxmemory | tonumber) else null end)}
     + (if $image != "" then {image: $image, image_id: $image_id} else {} end)
     + (if $binary != "" then {binary: $binary, binary_sha256: $sha, binary_mtime: $mtime} else {} end)
     + (if $info != "" then {binary_sha256: $sha, image_build_info: $info} else {} end)
     + (if $argv != null then {server_argv: $argv} else {} end)
     + (if $limits != null then {limits: $limits} else {} end)' \
    >"$tdir/target.json"
}

start_server() {
  local t=$1 port=$2 tdir=$3
  local -a persist=(--save "" --appendonly no) limit=() memory=()
  [ -n "$SERVER_MAXMEMORY" ] && limit=(--maxmemory "$SERVER_MAXMEMORY")
  SERVER_ARTIFACT=$tdir
  if [ "$t" = eski ]; then
    SERVER_ARGV=(taskset -c "$SERVER_CPUS" "$ESKI_BIN" --port "$port" "${persist[@]}" "${limit[@]}" "${SERVER_EXTRA[@]}")
    "${SERVER_ARGV[@]}" >"$tdir/server.log" 2>&1 &
    ESKI_PID=$!
    observe hook start server --pid "$ESKI_PID" --artifact-dir "$tdir"
    return 0
  fi
  CURRENT_CONTAINER="bench-$t-$RUN_ID"
  forget_container "$CURRENT_CONTAINER" || return 1
  [ -n "$SERVER_MEMORY" ] && memory=(--memory="$SERVER_MEMORY" --memory-swap="$SERVER_MEMORY")
  local -a base=(docker run --pull=never --rm -d --name "$CURRENT_CONTAINER" --label "$RUN_TAG" --network=host --cpuset-cpus="$SERVER_CPUS"
    "${memory[@]}" --workdir=/data --tmpfs /data:rw,mode=1777)
  case "$t" in
    redis)
      SERVER_ARGV=("${base[@]}" "$(image_id "$REDIS_IMAGE")" redis-server --port "$port" "${persist[@]}" --protected-mode no "${limit[@]}" "${SERVER_EXTRA[@]}") ;;
    valkey)
      SERVER_ARGV=("${base[@]}" "$(image_id "$VALKEY_IMAGE")" valkey-server --port "$port" "${persist[@]}" --protected-mode no "${limit[@]}" "${SERVER_EXTRA[@]}") ;;
    dragonfly)
      [ -n "$SERVER_MAXMEMORY" ] && limit=(--maxmemory="$SERVER_MAXMEMORY")
      SERVER_ARGV=("${base[@]}" --ulimit memlock=-1 "$(image_id "$DRAGONFLY_IMAGE")" dragonfly --port="$port" \
        "${limit[@]}" --proactor_threads="$DRAGONFLY_THREADS" --dbfilename= --logtostderr --version_check=false) ;;
    eski-docker)
      SERVER_ARGV=("${base[@]}" "$ESKI_IMAGE_ID" --port "$port" "${persist[@]}" "${limit[@]}" "${SERVER_EXTRA[@]}") ;;
  esac
  "${SERVER_ARGV[@]}" >"$tdir/start.log" 2>&1 || return 1
  docker inspect --format '{{json .HostConfig}}' "$CURRENT_CONTAINER" >"$tdir/container-hostconfig.json" 2>/dev/null
  observe hook start server --container "$CURRENT_CONTAINER" --artifact-dir "$tdir"
  docker logs -f "$CURRENT_CONTAINER" >"$tdir/server.log" 2>&1 &
  LOGS_PID=$!
  return 0
}

server_alive() {
  if [ "$1" = eski ]; then
    [ -n "$ESKI_PID" ] && kill -0 "$ESKI_PID" 2>/dev/null
  else
    [ -n "$CURRENT_CONTAINER" ] && [ "$(docker inspect -f '{{.State.Running}}' "$CURRENT_CONTAINER" 2>/dev/null)" = true ]
  fi
}

wait_ready() {
  local t=$1 port=$2 deadline=$((SECONDS + READY_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    server_alive "$t" || return 2
    [ "$(rcli "$port" PING)" = PONG ] && return 0
    sleep 0.5
  done
  return 1
}

stop_server() {
  local t=$1
  if [ "$t" = eski ]; then
    stop_eski
  elif [ -n "$CURRENT_CONTAINER" ]; then
    observe hook before-stop server --container "$CURRENT_CONTAINER" --artifact-dir "$SERVER_ARTIFACT"
    docker stop -t 10 "$CURRENT_CONTAINER" >/dev/null 2>&1
    forget_container "$CURRENT_CONTAINER"
    CURRENT_CONTAINER=""
  fi
  stop_logs
}

clock_us() { printf -v "$1" '%s' "${EPOCHREALTIME//[!0-9]/}"; }

seconds_of() { printf '%d.%06d' $(($1 / 1000000)) $(($1 % 1000000)); }

settle_memory() {
  local port=$1 base=$2 start now tick used rehashing last="" stable=0 samples=0 settled=no elapsed=0
  local limit=$((FILL_SETTLE_TIMEOUT * 1000000))
  rm -f "$base.info_memory.txt" "$base.settle.txt"
  clock_us start
  tick=$start
  while :; do
    rcli "$port" INFO memory >"$base.info_sample.txt"
    clock_us now
    elapsed=$((now - start))
    samples=$((samples + 1))
    used=$(sed -n 's/^used_memory:\([0-9][0-9]*\)$/\1/p' "$base.info_sample.txt")
    rehashing=$(sed -n 's/^mem_overhead_db_hashtable_rehashing:\([0-9][0-9]*\)$/\1/p' "$base.info_sample.txt")
    printf 'sample_%d:%s %s %s\n' "$samples" "$(seconds_of "$elapsed")" "${used:--}" "${rehashing:--}" >>"$base.settle.txt"
    if [ -n "$used" ]; then
      mv -f "$base.info_sample.txt" "$base.info_memory.txt"
      if [ "$used" = "$last" ] && [ "${rehashing:-0}" = 0 ]; then stable=$((stable + 1)); else stable=0; fi
    else
      stable=0
    fi
    last=$used
    if [ "$stable" -ge "$FILL_SETTLE_STABLE" ]; then
      settled=yes
      break
    fi
    tick=$((tick + 1000000))
    [ $((tick - start)) -le "$limit" ] || break
    clock_us now
    [ "$tick" -gt "$now" ] && sleep "$(seconds_of $((tick - now)))"
  done
  rm -f "$base.info_sample.txt"
  printf 'settled:%s\nsettle_s:%s\nsettle_samples:%d\nsettle_timeout_s:%d\n' "$settled" "$(seconds_of "$elapsed")" "$samples" "$FILL_SETTLE_TIMEOUT" >>"$base.settle.txt"
}

flush() {
  local port=$1 i n
  [ "$(rcli "$port" FLUSHALL)" = OK ] || return 1
  for i in $(seq 1 60); do
    n=$(rcli "$port" DBSIZE)
    [ "$n" = 0 ] && return 0
    sleep 0.5
  done
  return 1
}

client_guard() {
  local rc=$1 cname=$2 log=$3
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    docker kill "$cname" >/dev/null 2>&1
    printf 'run.sh: stopped after the %ss time limit\n' "$MT_LIMIT" >>"$log"
  fi
  [ "$rc" = 0 ]
}

run_memtier() {
  local tdir=$1 port=$2 name=$3; shift 3
  local cname="bench-client-$$-$BASHPID-$RANDOM" rc observer=""
  local -a fixed=(--protocol=redis --hide-histogram --print-percentiles 50,99,99.9) guard=() memory=()
  [ "${MT_EXACT:-0}" = 1 ] && fixed=()
  [ -n "${MT_LIMIT:-}" ] && guard=(timeout --kill-after=30 "$MT_LIMIT")
  [ -n "$CLIENT_MEMORY" ] && memory=(--memory="$CLIENT_MEMORY" --memory-swap="$CLIENT_MEMORY")
  rm -f "$tdir/$name.json"
  if [ -n "${BENCH_OWNER_EVENTS:-}" ]; then
    observe watch start client --container "$cname" --artifact-dir "$tdir/$name" &
    observer=$!
  fi
  "${guard[@]}" docker run --pull=never --rm --name "$cname" --label "$RUN_TAG" --network=host --cpuset-cpus="${MT_CPUS:-$CLIENT_CPUS}" \
    "${memory[@]}" --user "$(id -u):$(id -g)" -v "$tdir:/out$MOUNT_OPT" "$(image_id "${MT_IMAGE:-$MEMTIER_IMAGE}")" \
    --server=127.0.0.1 --port="$port" "${fixed[@]}" --json-out-file="/out/$name.json" "$@" \
    >"$tdir/$name.log" 2>&1
  rc=$?
  if [ -n "$observer" ]; then kill "$observer" 2>/dev/null || true; wait "$observer" 2>/dev/null || true; fi
  client_guard "$rc" "$cname" "$tdir/$name.log" || return 1
  [ -s "$tdir/$name.json" ] && py validate_memtier "$(dirname "$tdir")" "$(basename "$tdir")" "$name" >>"$tdir/$name.log" 2>&1
}

run_rb_argv() {
  local tdir=$1 port=$2 name=$3; shift 3
  local cname="bench-client-$$-$BASHPID-$RANDOM" rc observer=""
  local -a guard=() memory=()
  [ -n "${MT_LIMIT:-}" ] && guard=(timeout --kill-after=30 "$MT_LIMIT")
  [ -n "$CLIENT_MEMORY" ] && memory=(--memory="$CLIENT_MEMORY" --memory-swap="$CLIENT_MEMORY")
  if [ -n "${BENCH_OWNER_EVENTS:-}" ]; then
    observe watch start client --container "$cname" --artifact-dir "$tdir/$name" &
    observer=$!
  fi
  "${guard[@]}" docker run --pull=never --rm --name "$cname" --label "$RUN_TAG" --network=host --cpuset-cpus="${MT_CPUS:-$CLIENT_CPUS}" \
    "${memory[@]}" "$(image_id "${MT_IMAGE:-$REDIS_IMAGE}")" redis-benchmark -h 127.0.0.1 -p "$port" "$@" \
    >"$tdir/$name.csv" 2>"$tdir/$name.log"
  rc=$?
  if [ -n "$observer" ]; then kill "$observer" 2>/dev/null || true; wait "$observer" 2>/dev/null || true; fi
  client_guard "$rc" "$cname" "$tdir/$name.log"
}

run_rb() {
  local tdir=$1 port=$2 name=$3 n=$4 p=$5
  run_rb_argv "$tdir" "$port" "$name" -t ping,set,get,incr,mset \
    -n "$n" -c 50 -P "$p" -r 1000000 -d 64 --csv || return 1
  grep -q '^"SET"' "$tdir/$name.csv"
}

run_tool() {
  local tdir=$1 port=$2 name=$3 tool=$4 image=$5 cpus=$6 limit=$7; shift 7
  case "$tool" in
    memtier_benchmark)
      MT_IMAGE=$image MT_CPUS=$cpus MT_LIMIT=$limit MT_EXACT=1 run_memtier "$tdir" "$port" "$name" "$@" ;;
    redis-benchmark)
      MT_IMAGE=$image MT_CPUS=$cpus MT_LIMIT=$limit run_rb_argv "$tdir" "$port" "$name" "$@" ;;
    *)
      printf 'run.sh: unsupported client tool %s\n' "$tool" >"$tdir/$name.log"
      return 1 ;;
  esac
}

progress() { printf '[%s] %-11s ' "$1" "$2"; }

run_scenario() {
  local t=$1 port=$2 tdir=$3 s=$4
  local -a args=()
  progress "$t" "$s"
  if ! server_alive "$t"; then
    py error "$RUN_DIR" "$t" "$s" "server is not running" "$t/server.log"
    return 1
  fi
  case "$s" in
    fill10m)
      if ! flush "$port"; then
        py error "$RUN_DIR" "$t" "$s" "FLUSHALL before fill failed" "$t/server.log"
        return 1
      fi
      if run_memtier "$tdir" "$port" "$s" "${FILL_ARGS[@]}"; then
        settle_memory "$port" "$tdir/$s"
        rcli "$port" DBSIZE >"$tdir/$s.dbsize.txt"
        py fill "$RUN_DIR" "$t" "$s" "$FILL_KEYS"
      else
        py error "$RUN_DIR" "$t" "$s" "memtier failed" "$t/$s.log"
      fi
      flush "$port" >/dev/null 2>&1
      ;;
    rb_p1|rb_p16)
      local n p
      if [ "$s" = rb_p1 ]; then n=$RB_P1_N; p=1; else n=$RB_P16_N; p=16; fi
      if ! flush "$port"; then
        py error "$RUN_DIR" "$t" "$s" "FLUSHALL before redis-benchmark failed" "$t/server.log"
        return 1
      fi
      if run_rb "$tdir" "$port" "$s" "$n" "$p"; then
        py rb "$RUN_DIR" "$t" "$s" "$n" "$p"
      else
        py error "$RUN_DIR" "$t" "$s" "redis-benchmark failed" "$t/$s.log"
      fi
      ;;
    *)
      read -r -a args <<<"$(scenario_args "$s")"
      if run_memtier "$tdir" "$port" "$s" "${args[@]}" "${COMMON_ARGS[@]}"; then
        py memtier "$RUN_DIR" "$t" "$s"
      else
        py error "$RUN_DIR" "$t" "$s" "memtier failed" "$t/$s.log"
      fi
      ;;
  esac
}

boot_server() {
  local t=$1 port=$2 tdir=$3
  BOOT_ERROR=""
  BOOT_TAIL=""
  if ! start_server "$t" "$port" "$tdir"; then
    BOOT_ERROR="could not start server: $(tail -n 3 "$tdir/start.log" 2>/dev/null | tr '\n' ' ')"
    stop_server "$t"
    return 1
  fi
  wait_ready "$t" "$port"
  case $? in
    0) ;;
    2)
      BOOT_ERROR="server exited during startup"
      BOOT_TAIL=$(tail -n 15 "$tdir/server.log" 2>/dev/null)
      stop_server "$t"
      return 1
      ;;
    *)
      BOOT_ERROR="no PONG within ${READY_TIMEOUT}s"
      stop_server "$t"
      return 1
      ;;
  esac
  BOOTED_EXTRA="${SERVER_EXTRA[*]}"
  rcli "$port" INFO server >"$tdir/info_server.txt"
  return 0
}

spec_cap() {
  if [ "$SPEC" != 1 ]; then
    echo 0
  elif [ -n "$SPEC_TEST_TIME" ]; then
    echo "$SPEC_TEST_TIME"
  elif [ "$QUICK" = 1 ]; then
    echo "$SPEC_QUICK_TEST_TIME"
  else
    echo 0
  fi
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

fetch_spec() {
  local tree="$SPEC_CACHE/$SPEC_TREE_NAME" tarball="$SPEC_CACHE/$SPEC_TREE_NAME.tar.gz" stamp="$SPEC_CACHE/$SPEC_TREE_NAME.sha256"
  local got listing entry c
  if [ -n "$SPEC_SUITES" ]; then
    [ -d "$SPEC_SUITES" ] || die "BENCH_SPEC_SUITES=$SPEC_SUITES is not a directory"
    SPEC_TREE=$(cd "$SPEC_SUITES" && pwd)
    return 0
  fi
  SPEC_TREE=$tree
  if [ -d "$tree/redis_benchmarks_specification/test-suites" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$SPEC_SHA256" ]; then
    return 0
  fi
  for c in curl tar sha256sum; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
  mkdir -p "$SPEC_CACHE" || die "cannot create $SPEC_CACHE"
  if [ ! -f "$tarball" ] || [ "$(sha256_of "$tarball")" != "$SPEC_SHA256" ]; then
    say "fetching the Redis benchmarks specification v$SPEC_VERSION from $SPEC_URL"
    curl --fail --location --silent --show-error --retry 3 --output "$tarball.part" "$SPEC_URL" || die "download of $SPEC_URL failed"
    got=$(sha256_of "$tarball.part")
    [ "$got" = "$SPEC_SHA256" ] || die "sha256 mismatch for $SPEC_URL: expected $SPEC_SHA256, got $got (left in $tarball.part)"
    mv -f "$tarball.part" "$tarball" || die "cannot move $tarball.part into place"
  fi
  listing=$(tar -tzf "$tarball") || die "cannot list $tarball"
  while IFS= read -r entry; do
    case "$entry" in
      "$SPEC_TREE_NAME/"*) ;;
      *) die "unexpected path $entry in $tarball" ;;
    esac
    case "$entry" in
      *../*|*/..) die "unexpected path $entry in $tarball" ;;
    esac
  done <<<"$listing"
  tar -xzf "$tarball" -C "$SPEC_CACHE" --no-same-owner || die "cannot extract $tarball"
  [ -d "$tree/redis_benchmarks_specification/test-suites" ] || die "$tarball has no redis_benchmarks_specification/test-suites"
  printf '%s\n' "$SPEC_SHA256" >"$stamp"
}

probe_eski() {
  local out=$1; shift
  local port=${PORT[eski]} rc
  if [ ! -x "$ESKI_BIN" ] && contains eski-docker "${TARGETS[@]}"; then
    probe_eski_image "$out" "$@"
    return
  fi
  [ -x "$ESKI_BIN" ] || die "specification cases are chosen by the commands eski implements, so an eski binary is needed at $ESKI_BIN (build it, set ESKI_BIN or select the eski-docker target)"
  port_busy "$port" && die "port $port for the eski command probe is in use ($(port_owner "$port")); set BENCH_PORT_ESKI to a free port"
  mkdir -p "$SPEC_CACHE" || die "cannot create $SPEC_CACHE"
  (cd "$SPEC_CACHE" && exec "$ESKI_BIN" --port "$port") >"$SPEC_CACHE/eski-probe.log" 2>&1 &
  ESKI_PID=$!
  python3 -I "$SPEC_TOOL" probe --port "$port" --out "$out" "$@"
  rc=$?
  stop_eski
  return "$rc"
}

probe_eski_image() {
  local out=$1; shift
  local port=${PORT[eski-docker]} name="bench-probe-eski-$RUN_ID" iid rc
  iid=${ESKI_IMAGE_ID:-$(docker image inspect --format '{{.Id}}' "$ESKI_IMAGE" 2>/dev/null)}
  [ -n "$iid" ] || die "docker image $ESKI_IMAGE is not present locally; build it with bench/image.sh or set BENCH_ESKI_IMAGE"
  port_busy "$port" && die "port $port for the eski-docker command probe is in use ($(port_owner "$port")); set BENCH_PORT_ESKI_DOCKER to a free port"
  CURRENT_CONTAINER=$name
  if ! docker run --pull=never --rm -d --name "$name" --label "$RUN_TAG" --network=host "$iid" --port "$port" --save "" --appendonly no >/dev/null 2>&1; then
    CURRENT_CONTAINER=""
    die "cannot start $ESKI_IMAGE for the eski command probe"
  fi
  observe hook start server --container "$name" --artifact-dir "$SPEC_CACHE/probe-eski-docker"
  python3 -I "$SPEC_TOOL" probe --port "$port" --out "$out" "$@"
  rc=$?
  docker kill "$name" >/dev/null 2>&1
  CURRENT_CONTAINER=""
  return "$rc"
}

probe_reference() {
  local out=$1; shift
  local port=${PORT[redis]} name="bench-probe-$RUN_ID" rc
  port_busy "$port" && die "port $port for the reference command probe is in use ($(port_owner "$port")); set BENCH_PORT_REDIS to a free port"
  lock_image "$REDIS_IMAGE"
  CURRENT_CONTAINER=$name
  if ! docker run --pull=never --rm -d --name "$name" --label "$RUN_TAG" --network=host "$(image_id "$REDIS_IMAGE")" \
      redis-server --port "$port" --save "" --appendonly no >/dev/null 2>&1; then
    CURRENT_CONTAINER=""
    die "cannot start $REDIS_IMAGE for the reference command probe"
  fi
  observe hook start server --container "$name" --artifact-dir "$SPEC_CACHE/probe-redis"
  python3 -I "$SPEC_TOOL" probe --port "$port" --out "$out" "$@"
  rc=$?
  docker kill "$name" >/dev/null 2>&1
  CURRENT_CONTAINER=""
  return "$rc"
}

spec_release_args() {
  if [ -n "$SPEC_SUITES" ]; then
    printf '%s\n' --release "custom suites at $SPEC_TREE"
  else
    printf '%s\n' --release "v$SPEC_VERSION" --sha256 "$SPEC_SHA256" --url "$SPEC_URL"
  fi
}

build_plan() {
  local work=$1
  local -a probe_args=() plan_args=() release_args=()
  if [ "$SPEC" = 1 ]; then
    fetch_spec
    mapfile -t release_args < <(spec_release_args)
    probe_args+=(--tree "$SPEC_TREE")
    plan_args+=(--tree "$SPEC_TREE" "${release_args[@]}" --select "$SPEC_CASES" --quick-cap "$(spec_cap)")
  fi
  if [ -n "$PLAN_ARG" ]; then
    probe_args+=(--extra "$PLAN_ARG")
    plan_args+=(--extra "$PLAN_ARG")
  fi
  if [ "$SPEC" = 1 ] || { contains eski "${TARGETS[@]}" && [ -x "$ESKI_BIN" ]; } || contains eski-docker "${TARGETS[@]}"; then
    probe_eski "$work/eski_commands.json" "${probe_args[@]}" || die "probing the commands of eski failed"
    plan_args+=(--probe "$work/eski_commands.json")
  fi
  if [ "$SPEC" = 1 ]; then
    probe_reference "$work/reference_commands.json" "${probe_args[@]}" || die "probing the commands of $REDIS_IMAGE failed"
    plan_args+=(--reference "$work/reference_commands.json")
  fi
  python3 -I "$SPEC_TOOL" plan --out "$work/plan.json" --client-cpus "$CLIENT_CPUS" \
    --memtier-image "$SPEC_MEMTIER_IMAGE" --default-memtier-image "$SPEC_DEFAULT_MEMTIER_IMAGE" \
    --rb-image "$REDIS_IMAGE" --client-timeout "$SPEC_CLIENT_TIMEOUT" --preload-timeout "$SPEC_PRELOAD_TIMEOUT" \
    "${plan_args[@]}" || die "could not build the benchmark plan"
}

spec_list() {
  local c
  for c in python3 docker ss; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
  SPEC=1
  fetch_spec
  local -a release_args=()
  mapfile -t release_args < <(spec_release_args)
  probe_eski "$SPEC_CACHE/eski_commands.json" --tree "$SPEC_TREE" || die "probing the commands of eski failed"
  probe_reference "$SPEC_CACHE/reference_commands.json" --tree "$SPEC_TREE" || die "probing the commands of $REDIS_IMAGE failed"
  say ""
  python3 -I "$SPEC_TOOL" inventory --tree "$SPEC_TREE" --probe "$SPEC_CACHE/eski_commands.json" \
    --reference "$SPEC_CACHE/reference_commands.json" "${release_args[@]}"
}

prepare_plan() {
  local img
  build_plan "$RUN_DIR"
  PLAN="$RUN_DIR/plan.json"
  eval "$(python3 -I "$SPEC_TOOL" shell --plan "$PLAN" --summary)" || die "cannot read $PLAN"
  if [ "$PLAN_COUNT" = 0 ] && [ "$SPEC" = 0 ] && [ "${#SCENARIOS[@]}" = 0 ]; then
    die "the plan has no items and no scenarios are selected"
  fi
  for img in "${PLAN_IMAGES[@]}"; do
    lock_image "$img"
  done
}

item_out() {
  local r=$2 c=$3 last=$4 runs=$5 name=$1
  [ "$runs" -gt 1 ] && name="$name.run$r"
  [ "$c" -lt "$last" ] && name="$name.client$c"
  printf '%s' "$name"
}

run_item() {
  local t=$1 port=$2 tdir=$3 i=$4 code
  ITEM_BOOT_FAILED=0
  if ! code=$(python3 -I "$SPEC_TOOL" shell --plan "$PLAN" --index "$i" --target "$t" --target-probe "$tdir/commands.json"); then
    progress "$t" "item $i"
    say "FAILED: could not read plan item $i"
    return 1
  fi
  eval "$code"
  progress "$t" "$IT_NAME"
  if [ -n "$IT_SKIP" ]; then
    py item_skip "$RUN_DIR" "$t" "$PLAN" "$i" "$IT_SKIP"
    return 0
  fi
  local fail="" log="" msg r c last=$((IT_CLIENTS - 1)) out
  local -a pids=() outs=() argv=()
  if [ "$IT_FRESH" = 1 ] || ! server_alive "$t" || [ "${IT_SERVER_ARGS[*]}" != "$BOOTED_EXTRA" ]; then
    stop_server "$t"
    SERVER_EXTRA=("${IT_SERVER_ARGS[@]}")
    if ! boot_server "$t" "$port" "$tdir"; then
      ITEM_BOOT_FAILED=1
      py item_error "$RUN_DIR" "$t" "$PLAN" "$i" "$BOOT_ERROR" "$t/server.log"
      return 1
    fi
  fi
  if ! flush "$port"; then
    fail="FLUSHALL failed"
    log="$t/server.log"
  fi
  if [ -z "$fail" ] && [ "$IT_SETUP" = 1 ] && ! python3 -I "$SPEC_TOOL" configure --plan "$PLAN" --index "$i" --target "$t" \
      --port "$port" --out "$tdir/$IT_KEY.setup.json" >>"$tdir/$IT_KEY.setup.log" 2>&1; then
    fail="CONFIG SET step failed"
    log="$t/$IT_KEY.setup.log"
  fi
  if [ -z "$fail" ] && [ -n "$IT_PRELOAD_TOOL" ] && ! run_tool "$tdir" "$port" "$IT_KEY.preload" "$IT_PRELOAD_TOOL" \
      "$IT_PRELOAD_IMAGE" "$IT_PRELOAD_CPUS" "$IT_PRELOAD_TIMEOUT" "${IT_PRELOAD_ARGV[@]}"; then
    fail="preload failed"
    log="$t/$IT_KEY.preload.log"
  fi
  if [ -z "$fail" ] && [ "$IT_SETUP" = 1 ] && ! msg=$(python3 -I "$SPEC_TOOL" seed --plan "$PLAN" --index "$i" --target "$t" \
      --port "$port" --out "$tdir/$IT_KEY.setup.json" --check-timeout "$SPEC_CHECK_TIMEOUT" 2>>"$tdir/$IT_KEY.setup.log"); then
    fail=${msg:-init commands or keyspace check failed}
    log="$t/$IT_KEY.setup.log"
  fi
  if [ -z "$fail" ] && [ -n "$IT_WARMUP_TOOL" ] && ! run_tool "$tdir" "$port" "$IT_KEY.warmup" "$IT_WARMUP_TOOL" \
      "$IT_WARMUP_IMAGE" "$IT_WARMUP_CPUS" "$IT_WARMUP_TIMEOUT" "${IT_WARMUP_ARGV[@]}"; then
    fail="warmup failed"
    log="$t/$IT_KEY.warmup.log"
  fi
  r=1
  while [ -z "$fail" ] && [ "$r" -le "$IT_RUNS" ]; do
    if [ "$r" -gt 1 ] && [ "$IT_FLUSH_EACH_RUN" = 1 ] && ! flush "$port"; then
      fail="FLUSHALL before run $r failed"
      log="$t/server.log"
      break
    fi
    pids=()
    outs=()
    for ((c = 0; c <= last; c++)); do
      eval "argv=(\"\${IT_CLIENT_ARGV_$c[@]}\")"
      out=$(item_out "$IT_KEY" "$r" "$c" "$last" "$IT_RUNS")
      run_tool "$tdir" "$port" "$out" "${IT_CLIENT_TOOL[$c]}" "${IT_CLIENT_IMAGE[$c]}" \
        "${IT_CLIENT_CPUS[$c]}" "${IT_CLIENT_TIMEOUT[$c]}" "${argv[@]}" &
      pids+=("$!")
      outs+=("$out")
    done
    for ((c = 0; c <= last; c++)); do
      if ! wait "${pids[$c]}" && [ -z "$fail" ]; then
        fail="${IT_CLIENT_TOOL[$c]} failed"
        [ "$last" -gt 0 ] && fail="${IT_CLIENT_TOOL[$c]} client $c of $IT_CLIENTS failed"
        log="$t/${outs[$c]}.log"
      fi
    done
    r=$((r + 1))
  done
  if [ -z "$fail" ]; then
    py item "$RUN_DIR" "$t" "$PLAN" "$i"
  else
    [ -f "$tdir/server.log" ] && cp "$tdir/server.log" "$tdir/$IT_KEY.server.log"
    py item_error "$RUN_DIR" "$t" "$PLAN" "$i" "$fail" "$log"
  fi
  [ "$IT_FRESH" = 1 ] && stop_server "$t"
  [ -z "$fail" ]
}

run_items() {
  local t=$1 port=$2 tdir=$3 i j boot_failures=0
  progress "$t" commands
  if python3 -I "$SPEC_TOOL" probe --port "$port" --extra "$PLAN" --out "$tdir/commands.json" --wait 5 >"$tdir/commands.log" 2>&1; then
    say "$(tail -n 1 "$tdir/commands.log")"
  else
    say "probe FAILED (see $tdir/commands.log); every plan item runs on this target"
  fi
  for ((i = 0; i < PLAN_COUNT; i++)); do
    run_item "$t" "$port" "$tdir" "$i"
    if [ "$ITEM_BOOT_FAILED" = 1 ]; then
      boot_failures=$((boot_failures + 1))
    else
      boot_failures=0
    fi
    if [ "$boot_failures" -ge 3 ]; then
      for ((j = i + 1; j < PLAN_COUNT; j++)); do
        progress "$t" "item $j"
        py item_error "$RUN_DIR" "$t" "$PLAN" "$j" "not run: the server failed to start three times in a row" "$t/server.log"
      done
      break
    fi
  done
}

run_target() {
  local t=$1 port=${PORT[$1]} tdir="$RUN_DIR/$1" started
  started=$(date -Iseconds)
  SERVER_ARGV=()
  mkdir -p "$tdir"
  if [ "$t" = eski ] && [ ! -x "$ESKI_BIN" ]; then
    say "[eski] SKIPPED: no executable eski binary at $ESKI_BIN (build it first); the other targets are unaffected"
    target_status "$t" skipped "no executable binary at $ESKI_BIN" "$started"
    return 0
  fi
  if [ "$t" = eski ] && ! taskset -c "$SERVER_CPUS" true 2>/dev/null; then
    say "[eski] FAILED: taskset cannot pin to CPUs $SERVER_CPUS from this shell (allowed: $(taskset -cp $$ 2>/dev/null | sed 's/.*: //'))"
    target_status "$t" failed "taskset cannot pin to CPUs $SERVER_CPUS" "$started"
    return 1
  fi
  if port_busy "$port"; then
    say "[$t] FAILED: port $port is already in use ($(port_owner "$port"))"
    target_status "$t" failed "port $port already in use" "$started"
    return 1
  fi
  say "[$t] starting on port $port, cpus $SERVER_CPUS"
  SERVER_EXTRA=()
  if ! boot_server "$t" "$port" "$tdir"; then
    if [ -n "$BOOT_TAIL" ]; then
      say "[$t] FAILED: $BOOT_ERROR; last log lines:"
      printf '%s\n' "$BOOT_TAIL" | sed 's/^/    /'
    else
      say "[$t] FAILED: $BOOT_ERROR"
    fi
    target_status "$t" failed "$BOOT_ERROR" "$started"
    return 1
  fi
  local ver
  ver=$(grep -E '^(valkey_version|dragonfly_version|eski_version):' "$tdir/info_server.txt" | head -n1)
  [ -n "$ver" ] || ver=$(grep -E '^redis_version:' "$tdir/info_server.txt" | head -n1)
  say "[$t] ready (${ver:-version unknown})"
  if need_prefill; then
    progress "$t" prefill
    if ! flush "$port"; then
      say "FAILED: FLUSHALL before prefill failed"
    elif run_memtier "$tdir" "$port" prefill "${PREFILL_ARGS[@]}"; then
      say "done, dbsize $(rcli "$port" DBSIZE)"
    else
      say "FAILED (see $tdir/prefill.log)"
    fi
  fi
  local s
  for s in "${SCENARIOS[@]}"; do
    run_scenario "$t" "$port" "$tdir" "$s"
  done
  [ "$PLAN_COUNT" -gt 0 ] && run_items "$t" "$port" "$tdir"
  if [ "$(isolated_cpus)" != "$ISOLATED_AT_START" ]; then
    say "[$t] WARNING: the isolated CPU set changed during the run ('$ISOLATED_AT_START' -> '$(isolated_cpus)'); pinning may not have held"
  fi
  stop_server "$t"
  target_status "$t" ok "" "$started"
  say "[$t] stopped"
  return 0
}

if [ "$SPEC_LIST" = 1 ]; then
  spec_list
  exit $?
fi

[ "${#SCENARIOS[@]}" -gt 0 ] || [ "$SPEC" = 1 ] || [ -n "$PLAN_ARG" ] || die "nothing to run: --scenarios none without --spec or --plan"

preflight

STAMP=$(date +%Y%m%d-%H%M%S)
if [ -n "${BENCH_OUTPUT_DIR:-}" ]; then
  [[ "$BENCH_OUTPUT_DIR" = /* ]] || die "BENCH_OUTPUT_DIR must be an absolute path"
  [ ! -e "$BENCH_OUTPUT_DIR" ] || die "BENCH_OUTPUT_DIR must name a directory that does not exist yet"
  RUN_DIR="$BENCH_OUTPUT_DIR"
else
  RUN_DIR="$RESULTS_ROOT/$STAMP${LABEL:+-$LABEL}"
fi
mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"
: >"$RUN_DIR/records.jsonl"
if [ "$SPEC" = 1 ] || [ -n "$PLAN_ARG" ]; then
  prepare_plan
fi
ISOLATED_AT_START=$(isolated_cpus)
write_meta

say "results:   $RUN_DIR"
say "targets:   ${TARGETS[*]}"
say "scenarios: ${SCENARIOS[*]:-none}"
say "mode:      $([ "$QUICK" = 1 ] && echo quick || echo full), ${T}s per timed scenario, servers on cpus $SERVER_CPUS, clients on cpus $CLIENT_CPUS"
if [ -n "$PLAN" ]; then
  say "plan:      $(python3 -I "$SPEC_TOOL" describe --plan "$PLAN")"
fi

BEGIN=$SECONDS
for t in "${TARGETS[@]}"; do
  run_target "$t" || FAILED_TARGETS+=("$t")
  write_summary false
done

FINISHED=1
write_summary true
say ""
say "summary:   $RUN_DIR/summary.json  ($(( (SECONDS - BEGIN) / 60 ))m$(( (SECONDS - BEGIN) % 60 ))s)"
say ""
python3 "$BENCH_DIR/compare.py" "$RUN_DIR"

if [ "${#FAILED_TARGETS[@]}" -gt 0 ]; then
  say "failed targets: ${FAILED_TARGETS[*]}" >&2
  exit 1
fi
exit 0
