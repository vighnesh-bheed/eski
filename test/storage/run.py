import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("debug", "release"), default="debug")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    odin = os.environ.get("ODIN") or shutil.which("odin") or str(Path.home() / "odin/current/odin")
    with tempfile.TemporaryDirectory(prefix="eski-storage-test-") as temporary:
        work = Path(temporary) / "src"
        shutil.copytree(root / "src", work)
        shutil.copyfile(root / "test/storage/main.odin", work / "main.odin")
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
        binary = Path(temporary) / "storage-test"
        subprocess.run([odin, "build", str(work), "-debug" if args.mode == "debug" else "-o:speed", "-thread-count:2", "-vet", "-strict-style", "-out:" + str(binary)], check=True, timeout=180)
        subprocess.run([str(binary)], check=True, timeout=60, cwd=temporary)
        for capacity in (-1, 0, 15, 17, 1 << 62):
            result = subprocess.run([str(binary), "invalid", str(capacity)], capture_output=True, text=True, timeout=10, cwd=temporary)
            if result.returncode != 1 or result.stderr != "eski: invalid key table capacity\n":
                raise SystemExit("invalid capacity %d: status=%d stdout=%r stderr=%r" % (capacity, result.returncode, result.stdout, result.stderr))
        print("PASS %s storage capacity guards: 5" % args.mode, flush=True)


if __name__ == "__main__":
    main()
