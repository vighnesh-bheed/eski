import argparse
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("debug", "release"), default="debug")
    parser.add_argument("--sanitize", choices=("address", "thread"))
    parser.add_argument("--mapping-only", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    odin = os.environ.get("ODIN") or shutil.which("odin") or str(Path.home() / "odin/current/odin")
    dependency_mode = args.sanitize or "release"
    subprocess.run(["bash", str(root / "tools/build_lua.sh"), dependency_mode], check=True, cwd=root, timeout=180)
    subprocess.run(["bash", str(root / "tools/build_diagnostics.sh"), dependency_mode], check=True, cwd=root, timeout=180)
    with tempfile.TemporaryDirectory(prefix="eski-storage-test-") as temporary:
        (Path(temporary) / ".build").symlink_to(root / ".build", target_is_directory=True)
        work = Path(temporary) / "src"
        shutil.copytree(root / "src", work)
        shutil.copyfile(root / "test/storage/main.odin", work / "main.odin")
        declarations = []
        harness = (work / 'main.odin').read_text()
        for name in ('VERSION', 'REDIS_COMPAT_VERSION'):
            pattern = r'^' + name + r'\s*::\s*"[^"\n]+"'
            version = re.search(pattern, (root / 'src/main.odin').read_text(), re.MULTILINE)
            if version is None:
                raise SystemExit('source version declaration is missing: ' + name)
            harness, replaced = re.subn(pattern, lambda match: version.group(0), harness, flags=re.MULTILINE)
            if replaced > 1:
                raise SystemExit('duplicate harness version declaration: ' + name)
            if replaced == 0:
                declarations.append(version.group(0))
        (work / 'main.odin').write_text(harness)
        with (work / 'main.odin').open('a') as handle:
            handle.write('\n' + '\n'.join(declarations) + '\n')
        store = work / "store.odin"
        with store.open("a") as handle:
            handle.write("\nstorage_test_release_chunk :: proc() {\n\tgraveyard_step(-1)\n}\n")
            handle.write("\nstorage_test_dead_chunk :: proc() {\n\tdead_step()\n}\n")
        lazy = work / "lazyfree.odin"
        needle = 'lazyfree_run :: proc "contextless" (job: ^Lazy_Job) {\n'
        actual = lazy.read_text()
        if actual.count(needle) != 1:
            raise SystemExit("expected exactly one actual lazyfree_run entry for the test barrier")
        lazy.write_text(actual.replace(needle, needle + "\tstorage_test_worker_gate()\n", 1) + '\nstorage_test_worker_idle :: proc "contextless" () -> bool {\n\treturn intrinsics.atomic_load_explicit(&lazy_jobs, .Acquire) == 0\n}\n')
        memory = work / "memory.odin"
        actual_memory = memory.read_text()
        if actual_memory.count('mem_sample :: proc() {') != 1:
            raise SystemExit("expected exactly one actual memory sampler for the test getter")
        memory.write_text(actual_memory + '\nstorage_test_memory_sample :: proc() -> (allocated: int, rss: i64, libc_allocated: int) {\n\tmi := mallinfo2()\n\tmem_sample()\n\treturn mem_sample_allocated, mem_sample_rss, int(mi.uordblks + mi.hblkhd)\n}\n')
        with (work / "stats.odin").open("a") as handle:
            handle.write('\nstorage_test_error_memory :: proc() -> int {\n\tn := 0\n\tif cap(stat_errors) > 0 { n = int(runtime.map_total_allocation_size_from_value(stat_errors)) }\n\tfor code in stat_errors { n += len(code) }\n\treturn n\n}\n')
        binary = Path(temporary) / "storage-test"
        flags = ["-debug" if args.mode == "debug" else "-o:speed"]
        if args.sanitize:
            flags.append("-sanitize:" + args.sanitize)
        subprocess.run([odin, "build", str(work), *flags, "-thread-count:2", "-vet", "-strict-style", "-out:" + str(binary)], check=True, timeout=180)
        if args.mapping_only:
            subprocess.run([str(binary), "mapping-lifetime"], check=True, timeout=10, cwd=temporary)
            return
        subprocess.run([str(binary)], check=True, timeout=60, cwd=temporary)
        for capacity in (-1, 0, 15, 17, 1 << 62):
            result = subprocess.run([str(binary), "invalid", str(capacity)], capture_output=True, text=True, timeout=10, cwd=temporary)
            if result.returncode != 1 or result.stderr != "eski: invalid key table capacity\n":
                raise SystemExit("invalid capacity %d: status=%d stdout=%r stderr=%r" % (capacity, result.returncode, result.stdout, result.stderr))
        print("PASS %s storage capacity guards: 5" % args.mode, flush=True)


if __name__ == "__main__":
    main()
