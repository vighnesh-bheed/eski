import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile


DIRECT_MODES = ("grow", "quiet", "shrink", "score-update", "random-settled", "random-active", "random-rank")
STANDARD_MODES = ("grow", "quiet", "shrink", "host-tick", "host-small-retired")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(source, work, label, odin, template, host=False):
    work.mkdir()
    shutil.copytree(source / "src", work / "src")
    source_hashes = {str(path.relative_to(source)): sha256(path) for path in sorted((source / "src").rglob("*.odin"))}
    bounded = "\tresize:" in (source / "src/zsettype/skiplist.odin").read_text()
    bridge = None
    if host:
        if not bounded:
            raise SystemExit("the real host tick requires the bounded candidate")
        program = work / "src"
        (program / "main.odin").write_text(template.replace('"../../src/zsettype"', '"zsettype"'))
        command_file = program / "cmd_zset.odin"
        unpatched = command_file.read_text()
        needle = 'zset_sync :: #force_inline proc "contextless" (db: ^Db, z: zt.Zset) {'
        if unpatched.count(needle) != 1:
            raise SystemExit("expected exactly one real zset_sync for the temporary host benchmark bridge")
        addition = '\nzset_bench_sync :: proc(z: zt.Zset) {\n\tzset_sync(db_cur, z)\n}\n'
        command_file.write_text(unpatched + addition)
        bridge = {"needle": needle, "unpatched_sha256": source_hashes["src/cmd_zset.odin"],
                  "copied_with_bridge_sha256": sha256(command_file), "appended_definition": addition}
    else:
        program = work / "program"
        program.mkdir()
        (program / "main.odin").write_text(template.replace('"../../src/zsettype"', '"../src/zsettype"'))
    binary = work / "zset-resize"
    command = [odin, "build", str(program), "-o:speed", "-thread-count:2", "-vet", "-strict-style",
               "-define:ZSET_BOUNDED=" + str(bounded).lower(), "-define:ZSET_HOST=" + str(host).lower(), "-out:" + str(binary)]
    subprocess.run(command, check=True, timeout=180)
    return {"label": label, "source": str(source), "bounded": bounded, "host": host, "binary": str(binary),
            "binary_sha256": sha256(binary), "source_sha256": source_hashes, "build_argv": command,
            "temporary_bridge": bridge, "copied_main_sha256": sha256(program / "main.odin")}


def distribution(values):
    ordered = sorted(values)
    if not ordered:
        return {"calls": 0}
    return {"calls": len(values), "first_ns": values[0], "p50_ns": statistics.median(ordered),
            "p99_ns": ordered[min(len(ordered) - 1, int(len(ordered) * .99))], "max_ns": ordered[-1], "total_ns": sum(ordered)}


def measure(target, size, mode, round_number, cpu, samples):
    command = [target["binary"], str(size), mode, str(samples)]
    if cpu is not None:
        command = ["taskset", "-c", str(cpu), *command]
    result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=300, cwd=Path(target["binary"]).parent)
    row = json.loads(result.stdout)
    row.update(label=target["label"], round=round_number, mode=mode, argv=command, idle_observation=None)
    row["clock_baseline"] = distribution(row["clock_baseline_ns"])
    for phase in row["phases"]:
        phase.update(distribution(phase["nanoseconds"]))
        if not phase["migration_work_measured"]:
            for name in ("scanned", "moved", "probes", "max_grant_scanned", "max_grant_moved"):
                phase[name] = None
        if not phase["release_work_measured"]:
            phase["released_bytes"] = phase["max_release_bytes"] = None
        if not target["bounded"]:
            for name in ("mapped_peak", "retired_peak", "metadata_peak"):
                phase[name] = None
            phase["before"]["retired_records"] = phase["after"]["retired_records"] = None
    if mode.startswith("random-"):
        phase = next(p for p in row["phases"] if p["name"] == mode)
        assert phase["calls"] == min(size, samples)
        assert phase["before"]["ordered_members"] == phase["after"]["ordered_members"] == size + 1
        expected_active = target["bounded"] and mode != "random-settled"
        assert phase["before"]["active"] == phase["after"]["active"] == expected_active
        assert phase["active_calls"] == (phase["calls"] if expected_active else 0)
    if mode == "score-update":
        phase = next(p for p in row["phases"] if p["name"] == mode)
        assert phase["calls"] == size and not phase["after"]["active"]
        if target["bounded"]:
            assert 0 < phase["completed_after_calls"] <= size
    primary = row["phases"][1] if target["host"] else next((p for p in row["phases"] if p["name"] == mode), row["phases"][0])
    print("%s round=%d members=%d mode=%s phase=%s calls=%d max_ns=%d" %
          (target["label"], round_number, size, mode, primary["name"], primary["calls"], primary.get("max_ns", 0)), flush=True)
    return row


def summary(rows):
    groups = {}
    for row in rows:
        for phase in row["phases"]:
            if phase["calls"]:
                key = (row["label"], row["initial_members"], row["mode"], phase["name"])
                groups.setdefault(key, []).append(phase)
    result = []
    for (label, size, mode, name), phases in groups.items():
        item = {"label": label, "members": size, "mode": mode, "phase": name, "rounds": len(phases),
                "median_first_ns": statistics.median(p["first_ns"] for p in phases),
                "median_p50_ns": statistics.median(p["p50_ns"] for p in phases),
                "median_p99_ns": statistics.median(p["p99_ns"] for p in phases),
                "median_max_ns": statistics.median(p["max_ns"] for p in phases),
                "worst_max_ns": max(p["max_ns"] for p in phases),
                "median_total_ns": statistics.median(p["total_ns"] for p in phases),
                "bank_states": [{"before": p["before"], "after": p["after"], "active_calls": p["active_calls"],
                                 "completed_after_calls": p["completed_after_calls"]} for p in phases]}
        for field in ("allocated_peak", "mapped_peak", "retired_peak", "metadata_peak"):
            available = [p[field] for p in phases if p[field] is not None]
            item[field] = max(available) if available else None
        result.append(item)
    return result


def main():
    parser = argparse.ArgumentParser(description="Pair actual Zset operations in AB/BA rounds; coordinate the compiler and CPU windows before execution.")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--baseline-source", type=Path)
    parser.add_argument("--candidate-source", type=Path)
    parser.add_argument("--host-tick", action="store_true")
    parser.add_argument("--label", default="zset-resize")
    parser.add_argument("--sizes", default="98304,786432")
    parser.add_argument("--rounds", type=int, default=4)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--samples", type=int, default=16384)
    parser.add_argument("--modes", default=",".join(DIRECT_MODES))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    paired = args.baseline_source is not None and args.candidate_source is not None
    if (args.source is not None) == paired or (not paired and (args.baseline_source or args.candidate_source)):
        parser.error("provide --source or both --baseline-source and --candidate-source")
    sources = [("baseline", args.baseline_source.resolve()), ("candidate", args.candidate_source.resolve())] if paired else [(args.label, args.source.resolve())]
    sizes = [int(value) for value in args.sizes.split(",")]
    modes = list(dict.fromkeys(value for value in args.modes.split(",") if value))
    if args.rounds < 1 or args.samples < 1 or not modes or any(m not in DIRECT_MODES for m in modes):
        parser.error("positive rounds/samples and known nonempty modes are required")
    if any(n < 12 or n % 3 or (n // 3 * 4) & (n // 3 * 4 - 1) for n in sizes):
        parser.error("sizes must be three quarters of powers of two, at least 12")
    root = Path(__file__).resolve().parents[1]
    odin = os.environ.get("ODIN") or shutil.which("odin") or str(Path.home() / "odin/current/odin")
    odin = str(Path(odin).resolve())
    compiler_version = subprocess.run([odin, "version"], check=True, capture_output=True, text=True, timeout=10).stdout.strip()
    template_path = root / "bench/zset_resize/main.odin"
    template = template_path.read_text()
    rows, extra_rows, execution_order, excluded_modes = [], [], [], []
    with tempfile.TemporaryDirectory(prefix="eski-zset-resize-bench-") as temporary:
        work = Path(temporary)
        targets = [prepare(source, work / label, label, odin, template) for label, source in sources]
        host_target = prepare(Path(targets[-1]["source"]), work / "host", targets[-1]["label"] + "-host", odin, template, host=True) if args.host_tick else None
        for target in targets:
            if "random-rank" in modes and not target["bounded"]:
                excluded_modes.append({"label": target["label"], "mode": "random-rank", "reason": "candidate-only API forces the real rank fallback"})
        for round_number in range(1, args.rounds + 1):
            order = targets if round_number % 2 else list(reversed(targets))
            for size in sizes:
                for mode in modes:
                    for target in order:
                        if mode == "random-rank" and not target["bounded"]:
                            continue
                        execution_order.append({"round": round_number, "members": size, "mode": mode, "label": target["label"]})
                        row = measure(target, size, mode, round_number, args.cpu, args.samples)
                        (rows if mode in STANDARD_MODES else extra_rows).append(row)
                if host_target:
                    for mode in ("host-tick", "host-small-retired"):
                        execution_order.append({"round": round_number, "members": size, "mode": mode, "label": host_target["label"]})
                        rows.append(measure(host_target, size, mode, round_number, args.cpu, args.samples))
        identities = [{key: value for key, value in target.items() if key != "binary"} for target in targets + ([host_target] if host_target else [])]
    output = {"schema": "zset-resize-v1", "label": args.label, "paired": paired, "cpu": args.cpu, "samples": args.samples,
              "targets": identities, "compiler": odin, "compiler_sha256": sha256(Path(odin)), "compiler_version": compiler_version,
              "template_sha256": sha256(template_path), "runner_sha256": sha256(Path(__file__)),
              "execution_order": execution_order, "excluded_modes": excluded_modes, "rows": rows, "extra_rows": extra_rows,
              "host_budget": {"source_scans": 4096, "moved_entries": 256, "context_visits": 128, "productive_grants": 64,
                              "grants_per_db_visit": 16, "pending_wait_ms": 10, "migration_soft_nanoseconds": 150000,
                              "release_soft_nanoseconds": 50000, "release_bytes": 2 << 20, "release_calls": 16} if args.host_tick else None,
              "limits": "Operation vectors time actual APIs, not whole requests. Wall spans include untimed bookkeeping and are not idle/epoll observations. Allocation peaks are sampled owner/package states, not hidden transient allocator peaks. Score rows perform N reordered existing-member updates after a separately timed growth trigger; completion position allows matched-prefix comparison. Read rows sample min(N,samples) and preserve identical N+1 logical members; active state is observed, not inferred from the mode name. Candidate-only random-rank calls actual dict_random_node(sl,0). Baseline global mapping counters and unobserved work/release/syscalls are null. Source/target capacities and ordered counts are recorded. Host rows call real zset_resize_tick through exact temporary copied-source accounting bridge; internal scan/move counts are unavailable. Small-retirement targets keep 512 live nodes, preventing incidental shrink. Fault totals include bookkeeping. Construction, conversion and nonempty destruction are outside service measurements. Kernel/allocator/probe/skiplist costs remain variable; no hard whole-tick or latency guarantee."}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    args.output.with_name(args.output.stem + "-standard-summary.json").write_text(json.dumps(summary(rows), indent=2) + "\n")
    args.output.with_name(args.output.stem + "-extra-summary.json").write_text(json.dumps(summary(extra_rows), indent=2) + "\n")


if __name__ == "__main__":
    main()
