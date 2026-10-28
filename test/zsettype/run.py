import argparse
import os
from pathlib import Path
import resource
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("debug", "release"), default="debug")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    odin = os.environ.get("ODIN") or shutil.which("odin") or str(Path.home() / "odin/current/odin")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryDirectory(prefix="eski-zset-test-") as temporary:
        binary = Path(temporary) / "zsettype-test"
        subprocess.run([odin, "build", str(root / "test/zsettype"), "-debug" if args.mode == "debug" else "-o:speed", "-thread-count:2", "-vet", "-strict-style", "-out:" + str(binary)], check=True, timeout=180)
        subprocess.run([str(binary), "unit"], check=True, timeout=60, cwd=root)
        for guard in ("negative", "overflow", "capacity", "generation"):
            result = subprocess.run([str(binary), "resize-guard", guard], capture_output=True, text=True, timeout=10, cwd=temporary)
            if result.returncode == 0 or "invalid zset resize state or allocation failure" not in result.stderr:
                raise SystemExit("resize guard %s: status=%d stdout=%r stderr=%r" % (guard, result.returncode, result.stdout, result.stderr))
        print("PASS %s zset resize guards: 4" % args.mode, flush=True)


if __name__ == "__main__":
    main()
