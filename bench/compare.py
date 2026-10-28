import argparse
import json
import re
import sys
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent
RESULTS_DIR = BENCH_DIR / "results"
TARGET_ORDER = ["redis", "valkey", "dragonfly", "eski", "eski-docker"]
SCENARIO_ORDER = [
    "mixed_p1",
    "mixed_p16",
    "mixed_p64",
    "get_p1",
    "set_p1",
    "conn1_p1",
    "conn500_p1",
    "fill10m",
    "rb_p1",
    "rb_p16",
]
RB_SCENARIOS = ["rb_p1", "rb_p16"]
RB_COMMAND_ORDER = ["PING_INLINE", "PING_MBULK", "SET", "GET", "INCR", "MSET (10 keys)"]
BASE = "redis"
CHALLENGER = "eski"
CONTAINER = "eski-docker"
RATIOS = [(CHALLENGER, BASE), (CONTAINER, BASE), (CONTAINER, CHALLENGER)]


def die(msg):
    print(f"compare.py: {msg}", file=sys.stderr)
    sys.exit(1)


def latest_run():
    if not RESULTS_DIR.is_dir():
        die(f"no results directory at {RESULTS_DIR}")
    runs = sorted(p for p in RESULTS_DIR.iterdir() if p.is_dir() and (p / "summary.json").is_file())
    if not runs:
        die(f"no runs with a summary.json under {RESULTS_DIR}; run bench/run.sh first")
    return runs[-1]


def resolve(arg):
    if arg is None:
        return latest_run()
    p = Path(arg)
    if p.is_file() and p.name == "summary.json":
        return p.parent
    if p.is_dir():
        return p
    q = RESULTS_DIR / arg
    if q.is_dir():
        return q
    die(f"results directory not found: {arg}")


def order(items, preferred):
    items = list(dict.fromkeys(items))
    known = [x for x in preferred if x in items]
    return known + sorted(x for x in items if x not in preferred)


class Run:
    def __init__(self, path):
        self.path = path
        f = path / "summary.json"
        if not f.is_file():
            die(f"{f} does not exist")
        try:
            data = json.loads(f.read_text())
        except json.JSONDecodeError as e:
            die(f"{f} is not valid JSON: {e}")
        self.meta = data.get("meta") or {}
        self.records = {}
        for r in data.get("records") or []:
            self.records[(r.get("target"), r.get("scenario"))] = r
        self.targets = order([t for t, _ in self.records], TARGET_ORDER)
        self.scenarios = order([s for (_, s), r in self.records.items() if not r.get("suite")], SCENARIO_ORDER)
        self.suites = self.meta.get("suites") or {}

    def suite_names(self, suite):
        return list(dict.fromkeys(s for (_, s), r in self.records.items() if r.get("suite") == suite))

    def get(self, target, scenario):
        return self.records.get((target, scenario))

    def value(self, target, scenario, field):
        r = self.get(target, scenario)
        if not r or r.get("error"):
            return None
        return r.get(field)

    def rb_command(self, target, scenario, command):
        r = self.get(target, scenario)
        if not r or r.get("error"):
            return None
        for c in r.get("commands") or []:
            if c.get("command") == command:
                return c
        return None


def f_ops(v):
    return "-" if v is None else f"{v:,.0f}"


def f_ms(v):
    if v is None:
        return "-"
    if v >= 100:
        return f"{v:.1f}"
    if v >= 10:
        return f"{v:.2f}"
    return f"{v:.3f}"


def f_delta(cur, old):
    if cur is None or old is None or old == 0:
        return "n/a"
    return f"{(cur - old) / old * 100:+.1f}%"


def f_ratio(a, b):
    if a is None or b is None or b == 0:
        return "-"
    return f"{a / b:.2f}x"


def ratio_pairs(targets):
    return [(a, b) for a, b in RATIOS if a in targets and b in targets]


def f_mib(v):
    return "-" if v is None else f"{v / 1048576:,.1f}"


def f_num(v, digits=1):
    return "-" if v is None else f"{v:,.{digits}f}"


def f_int(v):
    return "-" if v is None else f"{int(v):,}"


def print_table(title, header, rows, note=None):
    if not rows:
        return
    ncol = len(header)
    part_w = [None] * ncol
    for row in rows:
        for i, cell in enumerate(row):
            if isinstance(cell, tuple):
                ws = [len(x) for x in cell[0]]
                part_w[i] = ws if part_w[i] is None else [max(a, b) for a, b in zip(part_w[i], ws)]

    def render(i, cell):
        if not isinstance(cell, tuple):
            return cell
        parts, seps = cell
        out = parts[0].rjust(part_w[i][0])
        for k in range(1, len(parts)):
            out += seps[k - 1] + parts[k].rjust(part_w[i][k])
        return out

    rows = [[render(i, c) for i, c in enumerate(row)] for row in rows]
    widths = [max([len(header[i])] + [len(r[i]) for r in rows]) for i in range(ncol)]

    def fmt(row):
        parts = []
        for i, cell in enumerate(row):
            parts.append(cell.ljust(widths[i]) if i == 0 else cell.rjust(widths[i]))
        return "  ".join(parts).rstrip()

    print(title)
    print(fmt(header))
    print("  ".join("-" * w for w in widths))
    for row in rows:
        print(fmt(row))
    if note:
        print(note)
    print()


def describe(run, name):
    m = run.meta
    print(f"{name:<9}{run.path}")
    mode = "quick" if m.get("quick") else "full"
    print(f"{'date':<9}{m.get('date', '?')}  ({mode}, {m.get('test_time_s', '?')} s per timed scenario, fill {f_int(m.get('fill_keys'))} keys)")
    print(f"{'machine':<9}{m.get('cpu_model', '?')}, kernel {m.get('kernel', '?')}, power {m.get('power_profile', '?')} (AC {m.get('ac_online', '?')})")
    print(f"{'pinning':<9}servers on cpus {m.get('server_cpus', '?')}, clients on cpus {m.get('client_cpus', '?')}, load at start {m.get('loadavg_at_start', '?')}")
    targets = m.get("targets") or {}
    versions = []
    notes = []
    for t in order(list(targets), TARGET_ORDER):
        entry = targets[t] or {}
        status = entry.get("status")
        if status in ("skipped", "failed", "not_run"):
            notes.append(f"{t} {status}: {entry.get('reason') or 'no reason recorded'}")
            continue
        v = entry.get("version") or entry.get("redis_version") or "?"
        if t == "dragonfly" and entry.get("redis_version"):
            v = f"{v} (redis_version {entry['redis_version']})"
        versions.append(f"{t} {v}")
    mv = re.search(r"v=(\S+)", m.get("memtier_version") or "")
    memtier = mv.group(1) if mv else "?"
    versions.append(f"memtier {memtier}")
    for image, entry in sorted((m.get("plan_images") or {}).items()):
        pv = re.search(r"v=(\S+)", (entry or {}).get("version") or "")
        if pv:
            versions.append(f"{image.rsplit('/', 1)[-1]} {pv.group(1)}")
    print(f"{'versions':<9}{', '.join(versions)}")
    container = targets.get(CONTAINER) or {}
    if container.get("image_id"):
        print(f"{'image':<9}{CONTAINER} {container.get('image')} {container['image_id'][:19]}, binary sha256 {(container.get('binary_sha256') or '?')[:16]}")
        native = (targets.get(CHALLENGER) or {}).get("binary_sha256")
        if native and container.get("binary_sha256") and native != container["binary_sha256"]:
            notes.append(f"{CHALLENGER} and {CONTAINER} run different binaries, so {CONTAINER}/{CHALLENGER} mixes build differences into the "
                         "container overhead; point ESKI_BIN at the binary bench/image.sh --extract copies out of the image")
    for n in notes:
        print(f"{'note':<9}{n}")
    spec = (m.get("suites") or {}).get("spec")
    if spec:
        cap = spec.get("quick_test_time_cap_s")
        line = f"Redis benchmarks specification {spec.get('release')}"
        if spec.get("sha256"):
            line += f" (sha256 {spec['sha256'][:16]}...)"
        line += f", {spec.get('planned', 0)} of {spec.get('case_files', '?')} cases run, {len(spec.get('skipped') or [])} skipped"
        if cap:
            line += f", test time capped at {cap} s"
        print(f"{'spec':<9}{line}")
    pts = (m.get("suites") or {}).get("pts")
    if pts:
        profiles = ", ".join(x.get("profile", "?") for x in pts.get("profiles") or [])
        print(f"{'pts':<9}{profiles}; {pts.get('note', '')}".rstrip("; "))
    if m.get("complete") is False:
        print(f"{'note':<9}run did not complete (interrupted or still running); results are partial")
    print()


def comparable_warnings(cur, other):
    out = []
    for key, label in (("quick", "quick mode"), ("test_time_s", "test time"), ("server_cpus", "server cpus"), ("client_cpus", "client cpus"), ("fill_keys", "fill keys")):
        a, b = cur.meta.get(key), other.meta.get(key)
        if a != b:
            out.append(f"WARNING: {label} differs ({a} vs {b}); deltas are not like-for-like")
    a, b = cur.suites.get("spec") or {}, other.suites.get("spec") or {}
    if a and b:
        for key, label in (("release", "specification release"), ("quick_test_time_cap_s", "specification test time cap")):
            if a.get(key) != b.get(key):
                out.append(f"WARNING: {label} differs ({a.get(key)} vs {b.get(key)}); deltas are not like-for-like")
    a, b = cur.suites.get("pts") or {}, other.suites.get("pts") or {}
    if a and b and (a.get("quick"), a.get("server_config")) != (b.get("quick"), b.get("server_config")):
        out.append("WARNING: openbenchmarking quick mode or server config differs; deltas are not like-for-like")
    return out


def main_table(run, other):
    targets = run.targets
    scenarios = run.scenarios
    ratios = ratio_pairs(targets)
    header = ["scenario"]
    for t in targets:
        header.append(f"{t} ops/s  p50/p99/p99.9 ms")
        if other:
            header.append(f"vs {t}")
    for a, b in ratios:
        header.append(f"{a}/{b}")
    rows = []
    for s in scenarios:
        row = [s]
        for t in targets:
            r = run.get(t, s)
            if r is None:
                cell = "-"
            elif r.get("error"):
                cell = "ERROR"
            else:
                parts = [f_ops(r.get("ops_per_sec")), f_ms(r.get("p50_ms")), f_ms(r.get("p99_ms")), f_ms(r.get("p999_ms"))]
                cell = (parts, ["  ", " / ", " / "])
            row.append(cell)
            if other:
                row.append(f_delta(run.value(t, s, "ops_per_sec"), other.value(t, s, "ops_per_sec")))
        for a, b in ratios:
            row.append(f_ratio(run.value(a, s, "ops_per_sec"), run.value(b, s, "ops_per_sec")))
        rows.append(row)
    note_parts = ["memtier latencies are per request; fill10m latencies are SET latencies"]
    if any(s in RB_SCENARIOS for s in scenarios):
        note_parts.append("rb_* rows: ops = total requests / total time over all commands, p50/p99 = worst command, no p99.9 from redis-benchmark")
    if other:
        note_parts.append(f"'vs <target>' = ops/sec change versus {other.path.name}")
    print_table("Throughput and latency (ops/sec, p50/p99/p99.9 in ms)", header, rows, "\n".join("  " + p for p in note_parts))


def fill_table(run, other):
    s = "fill10m"
    targets = [t for t in run.targets if run.get(t, s) is not None]
    if not targets:
        return
    ratios = ratio_pairs(targets)
    metrics = [
        ("ops/sec", "ops_per_sec", f_ops),
        ("SET p99 ms", "p99_ms", f_ms),
        ("SET p99.9 ms", "p999_ms", f_ms),
        ("dbsize", "dbsize", f_int),
        ("used_memory MiB", "used_memory", f_mib),
        ("used_memory_rss MiB", "used_memory_rss", f_mib),
        ("bytes_per_key_rss", "bytes_per_key_rss", f_num),
        ("bytes_per_key_used", "bytes_per_key_used", f_num),
    ]
    header = ["fill10m"]
    for t in targets:
        header.append(t)
        if other:
            header.append(f"vs {t}")
    for a, b in ratios:
        header.append(f"{a}/{b}")
    rows = []
    for label, field, fmt in metrics:
        row = [label]
        for t in targets:
            r = run.get(t, s)
            row.append("ERROR" if r.get("error") else fmt(r.get(field)))
            if other:
                row.append(f_delta(run.value(t, s, field), other.value(t, s, field)))
        for a, b in ratios:
            row.append(f_ratio(run.value(a, s, field), run.value(b, s, field)))
        rows.append(row)
    keys = run.meta.get("fill_keys")
    print_table(f"Bulk load of {f_int(keys)} keys (64-byte values), then INFO memory / DBSIZE", header, rows)


def rb_table(run, other):
    scenarios = [s for s in run.scenarios if s in RB_SCENARIOS]
    if not scenarios:
        return
    targets = [t for t in run.targets if any(run.get(t, s) is not None for s in scenarios)]
    ratios = ratio_pairs(targets)
    header = ["redis-benchmark"]
    for t in targets:
        header.append(f"{t} ops/s  p50/p99 ms")
        if other:
            header.append(f"vs {t}")
    for a, b in ratios:
        header.append(f"{a}/{b}")
    rows = []
    for s in scenarios:
        commands = []
        for t in targets:
            r = run.get(t, s)
            if r and not r.get("error"):
                commands.extend(c.get("command") for c in r.get("commands") or [])
        for cmd in order(commands, RB_COMMAND_ORDER):
            row = [f"{s} {cmd}"]
            for t in targets:
                r = run.get(t, s)
                c = run.rb_command(t, s, cmd)
                if r is None:
                    row.append("-")
                elif r.get("error"):
                    row.append("ERROR")
                elif c is None:
                    row.append("-")
                else:
                    row.append(([f_ops(c.get("ops_per_sec")), f_ms(c.get("p50_ms")), f_ms(c.get("p99_ms"))], ["  ", " / "]))
                if other:
                    oc = other.rb_command(t, s, cmd)
                    row.append(f_delta(c.get("ops_per_sec") if c else None, oc.get("ops_per_sec") if oc else None))
            for a, b in ratios:
                ca = run.rb_command(a, s, cmd)
                cb = run.rb_command(b, s, cmd)
                row.append(f_ratio(ca.get("ops_per_sec") if ca else None, cb.get("ops_per_sec") if cb else None))
            rows.append(row)
    print_table("redis-benchmark per command (50 connections, ops/sec, p50/p99 in ms)", header, rows)


def suite_cell(r, with_p999):
    if r is None:
        return "-"
    if r.get("error"):
        return "ERROR"
    if r.get("skipped"):
        return "skip"
    parts = [f_ops(r.get("ops_per_sec")), f_ms(r.get("p50_ms")), f_ms(r.get("p99_ms"))]
    seps = ["  ", " / "]
    if with_p999:
        parts.append(f_ms(r.get("p999_ms")))
        seps.append(" / ")
    rejected = (r.get("setup") or {}).get("config_rejected")
    if rejected:
        parts[0] += "*"
    return (parts, seps)


def suite_table(run, other, suite, title, label_header, notes):
    names = run.suite_names(suite)
    if not names:
        return
    targets = [t for t in run.targets if any(run.get(t, n) is not None for n in names)]
    ratios = ratio_pairs(targets)
    with_p999 = any(run.value(t, n, "p999_ms") is not None for t in targets for n in names)
    lat = "p50/p99/p99.9 ms" if with_p999 else "p50/p99 ms"
    header = [label_header]
    for t in targets:
        header.append(f"{t} ops/s  {lat}")
        if other:
            header.append(f"vs {t}")
    for a, b in ratios:
        header.append(f"{a}/{b}")
    rows = []
    rejected = []
    for n in names:
        first = next((run.get(t, n) for t in targets if run.get(t, n) is not None), {}) or {}
        row = [first.get("display") or n]
        for t in targets:
            r = run.get(t, n)
            row.append(suite_cell(r, with_p999))
            if other:
                row.append(f_delta(run.value(t, n, "ops_per_sec"), other.value(t, n, "ops_per_sec")))
            bad = ((r or {}).get("setup") or {}).get("config_rejected")
            if bad:
                rejected.append(f"{t} {n}: " + ", ".join(sorted(bad)))
        for a, b in ratios:
            row.append(f_ratio(run.value(a, n, "ops_per_sec"), run.value(b, n, "ops_per_sec")))
        rows.append(row)
    notes = list(notes)
    skips = sorted({(t, n, run.get(t, n).get("skipped")) for t in targets for n in names if (run.get(t, n) or {}).get("skipped")})
    if skips:
        notes.append("skip = the target lacks a command the case sends: " + "; ".join(f"{t} {n} ({why})" for t, n, why in skips))
    if rejected:
        notes.append("* = CONFIG SET of a declared configuration parameter was rejected, so the case ran with defaults: " + "; ".join(rejected))
    if other:
        notes.append(f"'vs <target>' = ops/sec change versus {other.path.name}")
    print_table(title, header, rows, "\n".join("  " + x for x in notes))


def spec_table(run, other):
    meta = run.suites.get("spec") or {}
    cap = meta.get("quick_test_time_cap_s")
    title = f"Redis benchmarks specification {meta.get('release', '')} by official test name (ops/sec, latency in ms)"
    notes = ["ops/sec and latency percentiles are memtier's Totals for the measured (last) client of each case"]
    if cap:
        notes.append(f"declared test times were capped at {cap} s, so these are not comparable with published numbers")
    suite_table(run, other, "spec", title, "test", notes)


def spec_skipped(run, other):
    meta = run.suites.get("spec")
    if not meta:
        return
    skipped = meta.get("skipped") or []
    scope = f"of {meta.get('selected')} selected" if meta.get("selection") else f"of {meta.get('case_files')}"
    print(f"Specification cases skipped ({len(skipped)} {scope} cases in {meta.get('release')}, {meta.get('applicable')} applicable to eski)")
    blocked = meta.get("skipped_by_missing_command") or {}
    if blocked:
        only = meta.get("only_blocker") or {}
        print("  missing commands, as cases blocked (cases where it is the only blocker):")
        line = "   "
        for c, n in blocked.items():
            part = f" {c} {n}" + (f" ({only[c]})" if only.get(c) else "") + ","
            if len(line) + len(part) > 110:
                print(line.rstrip(","))
                line = "   "
            line += part
        print(line.rstrip(","))
    ignored = meta.get("ignored_tested_commands") or {}
    if ignored:
        print("  ignored tested-commands names (never sent, unknown to the reference server): " + ", ".join(f"{c} ({n})" for c, n in ignored.items()))
    for f in meta.get("parse_failures") or []:
        print(f"  could not parse {f['file']}: {f['error']}")
    for s in sorted(skipped, key=lambda s: s["name"]):
        print(f"  {s['name']}: {s['reason']}")
    o = other.suites.get("spec") if other else None
    if o and not meta.get("selection") and not o.get("selection"):
        now = {s["name"] for s in skipped}
        before = {s["name"] for s in o.get("skipped") or []}
        gained = sorted(before - now)
        lost = sorted(now - before)
        if gained:
            print(f"  applicable now but skipped in {other.path.name}: " + ", ".join(gained))
        if lost:
            print(f"  skipped now but applicable in {other.path.name}: " + ", ".join(lost))
    print()


def pts_table(run, other):
    meta = run.suites.get("pts") or {}
    runs = sorted({x.get("times_to_run") for x in meta.get("profiles") or [] if x.get("times_to_run")})
    title = "OpenBenchmarking.org test profiles (ops/sec, latency in ms)"
    notes = []
    if runs and not meta.get("quick"):
        notes.append(f"each row is the mean of {', '.join(str(r) for r in runs)} runs, as the profile's TimesToRun sets it")
    if meta.get("quick"):
        notes.append("quick mode: " + (meta.get("quick_adjustments") or "shortened") + "; not comparable with published numbers")
    notes.append("redis-benchmark rows have no p99.9; memtier rows use the Totals of ALL STATS")
    suite_table(run, other, "pts", title, "profile", notes)


def errors(run):
    bad = [r for r in run.records.values() if r.get("error")]
    if not bad:
        return
    print("Errors")
    for r in sorted(bad, key=lambda r: (TARGET_ORDER.index(r["target"]) if r.get("target") in TARGET_ORDER else 99, r.get("scenario") or "")):
        print(f"  {r.get('target')} {r.get('scenario')}: {r.get('error')}" + (f" (log: {run.path / r['log']})" if r.get("log") else ""))
    print()


def main():
    ap = argparse.ArgumentParser(description="Compare eski benchmark results across targets and runs.")
    ap.add_argument("results_dir", nargs="?", help="results directory (default: latest under bench/results)")
    ap.add_argument("--against", metavar="OTHER_RESULTS_DIR", help="another results directory to compute ops/sec deltas against")
    args = ap.parse_args()
    run = Run(resolve(args.results_dir))
    other = Run(resolve(args.against)) if args.against else None
    describe(run, "run")
    if other:
        describe(other, "against")
        warnings = comparable_warnings(run, other)
        for w in warnings:
            print(w)
        if warnings:
            print()
    if not run.records:
        print("no records in this run")
        return
    main_table(run, other)
    fill_table(run, other)
    rb_table(run, other)
    spec_table(run, other)
    spec_skipped(run, other)
    pts_table(run, other)
    errors(run)


if __name__ == "__main__":
    main()
