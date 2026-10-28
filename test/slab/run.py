import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import re
import select
import subprocess
import tempfile


def mapping(pid, base, size):
    total = {name: 0 for name in ("Rss", "Pss", "AnonHugePages", "Private_Dirty", "Shared_Dirty")}
    total.update(mappings=0, no_huge_pages=True, partial_vmas=0, covered_bytes=0)
    if not base or not size:
        return total
    selected = False
    for line in Path("/proc/%d/smaps" % pid).read_text().splitlines():
        match = re.match(r"^([0-9a-f]+)-([0-9a-f]+) ", line)
        if match:
            start, end = (int(value, 16) for value in match.groups())
            selected = start < base + size and end > base
            total["mappings"] += int(selected)
            if selected:
                coverage = max(0, min(end, base + size) - max(start, base))
                total["covered_bytes"] += coverage
                total["partial_vmas"] += int(coverage != end - start)
        elif selected and ":" in line:
            name, value = line.split(":", 1)
            if name in total:
                total[name] += int(value.split()[0])
            elif name == "VmFlags":
                total["no_huge_pages"] &= "nh" in value.split()
    if total["partial_vmas"]:
        total["intersecting_vma_upper_bounds_kib"] = {name: total[name] for name in ("Rss", "Pss", "AnonHugePages", "Private_Dirty", "Shared_Dirty")}
        for name in total["intersecting_vma_upper_bounds_kib"]:
            total[name] = None
    return total


def resident_check(binary):
    process = subprocess.Popen([str(binary), "resident"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    rows = []
    try:
        for phase in ("filled", "dirty", "reclaimed", "reused", "retired"):
            if not select.select([process.stdout], [], [], 10)[0]:
                raise RuntimeError("resident fixture timed out at " + phase)
            line = process.stdout.readline()
            if not line:
                process.wait(timeout=10)
                raise RuntimeError("resident fixture exited at %s status=%s stderr=%s" % (phase, process.returncode, process.stderr.read()))
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise RuntimeError("invalid resident fixture output at %s: %r" % (phase, line)) from error
            assert row["phase"] == phase, row
            row["payload_mapping"] = mapping(process.pid, row["base"], row["payload_virtual"])
            row["metadata_mapping"] = mapping(process.pid, row["metadata"], row["metadata_virtual"])
            row["process_resident_pages"] = int(Path("/proc/%d/statm" % process.pid).read_text().split()[1])
            rows.append(row)
            process.stdin.write("x")
            process.stdin.flush()
        process.wait(timeout=10)
        if process.returncode:
            raise RuntimeError(process.stderr.read())
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
    filled, dirty, reclaimed, reused, retired = rows
    assert all(not row["payload_mapping"]["partial_vmas"] and not row["metadata_mapping"]["partial_vmas"] for row in rows), ("numeric RSS proof requires complete VMA attribution", rows)
    assert all(row["payload_mapping"]["covered_bytes"] == row["payload_virtual"] and row["metadata_mapping"]["covered_bytes"] == row["metadata_virtual"] for row in rows)
    assert all(row["payload_mapping"]["AnonHugePages"] == 0 and row["payload_mapping"]["no_huge_pages"] and row["metadata_mapping"]["no_huge_pages"] for row in rows)
    assert filled["payload_mapping"]["Rss"] - reclaimed["payload_mapping"]["Rss"] >= 768, rows
    assert reused["payload_mapping"]["Rss"] - reclaimed["payload_mapping"]["Rss"] >= 768, rows
    assert filled["base"] == dirty["base"] == reclaimed["base"] == reused["base"] and filled["top"] == reused["top"], rows
    assert reclaimed["live"] == 24 and reclaimed["empty"] == 16 and reused["empty"] == 0, rows
    assert retired["owned"] == 0 and retired["base"] == 0 and retired["metadata"] == 0 and retired["payload_virtual"] == 0 and retired["metadata_virtual"] == 0, rows
    print("PASS actual mapping RSS and NOHUGEPAGE policy " + json.dumps(rows, sort_keys=True), flush=True)


def compiler():
    configured = os.environ.get("ODIN")
    found = configured or shutil.which("odin") or str(Path.home() / "odin/current/odin")
    if not Path(found).is_file():
        raise SystemExit("Odin compiler not found; set ODIN")
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("debug", "release", "both"), default="both")
    parser.add_argument("--source", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    source = args.source or root / "src/slab.odin"
    modes = ("debug", "release") if args.mode == "both" else (args.mode,)
    odin = compiler()
    with tempfile.TemporaryDirectory(prefix="eski-slab-test-") as temporary:
        work = Path(temporary)
        shutil.copyfile(source, work / "slab.odin")
        shutil.copyfile(root / "test/slab/main.odin", work / "main.odin")
        shutil.copyfile(root / "src/memory_storage.odin", work / "memory_storage.odin")
        shutil.copyfile(root / "src/slab_runs.odin", work / "slab_runs.odin")
        shutil.copyfile(root / "test/slab/reclaim.odin", work / "reclaim.odin")
        source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        if hashlib.sha256((work / "slab.odin").read_bytes()).hexdigest() != source_hash:
            raise SystemExit("allocator source copy differs")
        for mode in modes:
            binary = work / ("slab-test-" + mode)
            optimization = "-debug" if mode == "debug" else "-o:speed"
            accounting = "true" if "storage_unmap" in source.read_text() else "false"
            subprocess.run([odin, "build", str(work), optimization, "-thread-count:2", "-vet", "-strict-style", "-define:SLAB_STORAGE_ACCOUNTING=" + accounting, "-out:" + str(binary)], check=True, timeout=120)
            subprocess.run([str(binary)], check=True, timeout=30)
            subprocess.run([str(binary), "cow"], check=True, timeout=30)
            resident_check(binary)
            for c in range(36):
                result = subprocess.run([str(binary), "exhaust", str(c)], capture_output=True, text=True, timeout=10)
                if result.returncode != 1 or not result.stdout.startswith("READY %d " % c) or result.stderr != "eski: value slab exhausted\n":
                    raise SystemExit("unexpected exhaustion for %s class %d: status=%d stdout=%r stderr=%r" % (mode, c, result.returncode, result.stdout, result.stderr))
            print("PASS %s actual allocator; 36 final-run exhaustion checks; source_sha256=%s run_metadata_sha256=%s" % (mode, source_hash, hashlib.sha256((work / "slab_runs.odin").read_bytes()).hexdigest()), flush=True)


if __name__ == "__main__":
    main()
