import argparse
import hashlib
import json
import mmap
import os
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess
import tempfile


PATTERN = re.compile(rb"(?:0|-?[1-9][0-9]*)")
MINIMUM = -(1 << 63)
MAXIMUM = (1 << 63) - 1


def expected(raw):
    if len(raw) > 20 or PATTERN.fullmatch(raw) is None:
        return 0, False
    value = int(raw)
    return (value, True) if MINIMUM <= value <= MAXIMUM else (0, False)


def corpus(seed):
    cases = {b"", b"-", b"+", b"0", b"-0", b"00", b"+0"}
    cases.update(bytes([x]) for x in range(256))
    cases.update(bytes([x, y]) for x in range(256) for y in range(256))
    for number in range(-10000, 10001):
        raw = str(number).encode()
        cases.update((raw, b"+" + raw, b"0" + raw, raw + b"\x00", b" " + raw, raw + b" "))
    for boundary in (MINIMUM, MAXIMUM, -(1 << 64), 1 << 64):
        for delta in range(-2048, 2049):
            cases.add(str(boundary + delta).encode())
    for power in range(65):
        for delta in range(-3, 4):
            for sign in (-1, 1):
                cases.add(str(sign * ((1 << power) + delta)).encode())
    for raw in (b"1", b"-1", b"1234567890", b"-1234567890", str(MINIMUM).encode(), str(MAXIMUM).encode()):
        for position in range(len(raw)):
            for byte in range(256):
                cases.add(raw[:position] + bytes([byte]) + raw[position + 1:])
    rng = random.Random(seed)
    for _ in range(100000):
        cases.add(str(rng.randrange(MINIMUM, MAXIMUM + 1)).encode())
    for _ in range(100000):
        raw = bytes(rng.randrange(48, 58) for _ in range(rng.randrange(33)))
        cases.add((b"-" if rng.getrandbits(1) else b"") + raw)
    for _ in range(50000):
        cases.add(rng.randbytes(rng.randrange(49)))
    for size in (21, 32, 63, 64, 65, 255, 4095, 4096, 4097, 100000):
        for prefix in (b"", b"-", b"0", b"+"):
            cases.add(prefix + b"9" * size)
            cases.add(prefix + b"0" * size)
    return sorted(cases)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--odin", default=os.environ.get("ODIN") or shutil.which("odin") or str(Path.home() / "odin/current/odin"))
    parser.add_argument("--seed", type=int, default=20261025)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    cases = corpus(args.seed)
    digest = hashlib.sha256()
    accepted = 0
    with tempfile.TemporaryDirectory(prefix="eski-integer-") as temporary:
        temporary = Path(temporary)
        fixture = temporary / "corpus.bin"
        with fixture.open("wb") as output:
            header = struct.pack("<8sII", b"EINTv1\x00\x00", mmap.PAGESIZE, len(cases))
            output.write(header)
            digest.update(header)
            for raw in cases:
                value, ok = expected(raw)
                accepted += ok
                record = struct.pack("<IBq", len(raw), ok, value) + raw
                output.write(record)
                digest.update(record)
        results = []
        for mode, flags in (("debug", ["-debug"]), ("release", ["-o:speed"])):
            executable = temporary / mode
            subprocess.run([args.odin, "build", "test/integer", "-vet", "-strict-style", "-thread-count:2", *flags, f"-out:{executable}"], cwd=root, check=True)
            run = subprocess.run([str(executable), str(fixture)], check=True, text=True, capture_output=True)
            match = re.fullmatch(r"cases=(\d+) checks=(\d+) guarded=(\d+)\n", run.stdout)
            if match is None or int(match[1]) != len(cases):
                raise RuntimeError(f"Unexpected test result: {run.stdout!r}")
            results.append(dict(mode=mode, cases=int(match[1]), checks=int(match[2]), guarded=int(match[3])))
    report = dict(seed=args.seed, cases=len(cases), accepted=accepted, rejected=len(cases) - accepted, corpus_sha256=digest.hexdigest(), modes=results)
    encoded = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded)
    print(encoded, end="")


if __name__ == "__main__":
    main()
