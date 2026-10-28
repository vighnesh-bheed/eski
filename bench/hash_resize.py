import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile


def prepare(source, work, label, odin, template, host=False):
    work.mkdir()
    shutil.copytree(source / "src", work / "src")
    hashes = {str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted((source / "src").rglob("*.odin"))}
    bounded = "resize:" in (source / "src/hashtype/table.odin").read_text()
    if host:
        program = work / "src"
        (program / "main.odin").write_text(template.replace('"../../src/hashtype"', '"hashtype"'))
        command_file = program / "cmd_hash.odin"
        actual = command_file.read_text()
        needle = 'hash_sync :: #force_inline proc "contextless" (db: ^Db, h: ht.Hash) {'
        if actual.count(needle) != 1:
            raise SystemExit("expected exactly one real hash_sync for the temporary host benchmark bridge")
        command_file.write_text(actual + '\nhash_bench_sync :: proc(h: ht.Hash) {\n\thash_sync(db_cur, h)\n}\n')
    else:
        program = work / "program"
        program.mkdir()
        (program / "main.odin").write_text(template.replace('"../../src/hashtype"', '"../src/hashtype"'))
    binary = work / "hash-resize"
    subprocess.run([odin, "build", str(program), "-o:speed", "-thread-count:2", "-vet", "-strict-style", "-define:HASH_BOUNDED=" + str(bounded).lower(), "-define:HASH_HOST=" + str(host).lower(), "-out:" + str(binary)], check=True, timeout=180)
    return dict(label=label, source=str(source), bounded=bounded, host=host, binary=str(binary), binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), source_sha256=hashes)


def measure(target, size, mode, round_number, cpu):
    command = [target["binary"], str(size), mode]
    if cpu is not None:
        command = ["taskset", "-c", str(cpu), *command]
    result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=300)
    row = json.loads(result.stdout)
    row.update(label=target["label"], round=round_number, mode=mode)
    for phase in row["phases"]:
        durations = sorted(phase["nanoseconds"])
        phase["calls"] = len(durations)
        if durations:
            phase.update(first_ns=phase["nanoseconds"][0], p50_ns=statistics.median(durations), p99_ns=durations[min(len(durations) - 1, int(len(durations) * .99))], max_ns=durations[-1], total_ns=sum(durations))
        if not phase["migration_work_measured"]:
            for name in ("scanned", "moved", "probes", "max_grant_scanned", "max_grant_moved"):
                phase[name] = None
        if not phase["release_work_measured"]:
            phase["released_bytes"] = phase["max_release_bytes"] = None
    primary = row["phases"][1] if target["host"] else row["phases"][0]
    print("%s round=%d fields=%d mode=%s phase=%s max_ns=%d" % (target["label"], round_number, size, mode, primary["name"], primary.get("max_ns", 0)), flush=True)
    return row


def main():
    parser = argparse.ArgumentParser(description="Measure actual native hash threshold operations; coordinate the CPU window before running. Paired sources compile once each and run AB/BA alternating rounds.")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--baseline-source", type=Path)
    parser.add_argument("--candidate-source", type=Path)
    parser.add_argument("--host-tick", action="store_true", help="also compile a candidate-only full-source fixture timing the actual host hash_resize_tick")
    parser.add_argument("--label", default="hash-resize")
    parser.add_argument("--sizes", default="98304,786432")
    parser.add_argument("--rounds", type=int, default=4)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    paired = args.baseline_source is not None and args.candidate_source is not None
    if (args.source is not None) == paired or (not paired and (args.baseline_source or args.candidate_source)):
        parser.error("provide --source or both --baseline-source and --candidate-source")
    sources = [("baseline", args.baseline_source.resolve()), ("candidate", args.candidate_source.resolve())] if paired else [(args.label, args.source.resolve())]
    sizes = [int(value) for value in args.sizes.split(",")]
    if args.rounds < 1 or any(n < 12 or n % 3 or (n // 3 * 4) & (n // 3 * 4 - 1) for n in sizes):
        parser.error("sizes must be three quarters of powers of two and rounds must be positive")
    root = Path(__file__).resolve().parents[1]
    odin = os.environ.get("ODIN") or shutil.which("odin") or str(Path.home() / "odin/current/odin")
    template = (root / "bench/hash_resize/main.odin").read_text()
    rows = []
    execution_order = []
    with tempfile.TemporaryDirectory(prefix="eski-hash-resize-bench-") as temporary:
        work = Path(temporary)
        targets = [prepare(source, work / label, label, odin, template) for label, source in sources]
        host_target = None
        if args.host_tick:
            candidate = targets[-1]
            if not candidate["bounded"]:
                parser.error("--host-tick needs a bounded candidate source")
            host_target = prepare(Path(candidate["source"]), work / "host", candidate["label"] + "-host", odin, template, host=True)
        for round_number in range(1, args.rounds + 1):
            order = targets if round_number % 2 else list(reversed(targets))
            for size in sizes:
                for mode in ("grow", "quiet", "shrink"):
                    for target in order:
                        execution_order.append(dict(round=round_number, fields=size, mode=mode, label=target["label"]))
                        rows.append(measure(target, size, mode, round_number, args.cpu))
                if host_target:
                    for mode in ("host-tick", "host-small-retired"):
                        execution_order.append(dict(round=round_number, fields=size, mode=mode, label=host_target["label"]))
                        rows.append(measure(host_target, size, mode, round_number, args.cpu))
        identities = [{key: value for key, value in target.items() if key != "binary"} for target in targets + ([host_target] if host_target else [])]
    output = dict(label=args.label, paired=paired, cpu=args.cpu, targets=identities, compiler=odin, template_sha256=hashlib.sha256(template.encode()).hexdigest(), execution_order=execution_order, rows=rows, host_budget=dict(source_scans=4096, moved_entries=256, context_visits=128, productive_grants=64, grants_per_db_visit=16, pending_wait_ms=10, migration_soft_nanoseconds=150000, release_soft_nanoseconds=50000, release_bytes=2 << 20, release_calls=16) if args.host_tick else None, limits="Core write durations are not whole request durations. allocated_peak is Hash memory_usage; mapped/retired/metadata peaks are package counters. Direct quiet phases use foreground 64-scan/4-move grants. Release has a 2 MiB/16-call cap; migration and release have separate soft deadlines, with one-call release progress even after its deadline. Host phases call the real hash_resize_tick and its accounting/retirement path; internal work counts are unavailable. Null work counters are unmeasured. Probes and OS faults/syscalls remain variable. Fault totals include harness bookkeeping. Construction, TTL vectors, conversion and nonempty destruction are outside measured phases.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n")


if __name__ == "__main__":
    main()
