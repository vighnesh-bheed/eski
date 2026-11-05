import argparse
from collections import Counter
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


MAXIMUM = (1 << 63) - 1
BULK_MAX = 512 * 1024 * 1024
FAULTS = {b"invalid multibulk length": 1, b"invalid bulk length": 2, b"unauthenticated multibulk length": 3, b"unauthenticated bulk length": 4, b"unbalanced quotes in request": 6, b"too big mbulk count string": 7, b"too big bulk count string": 8, b"too big inline request": 9}


def frame(args):
    return b"*" + str(len(args)).encode() + b"\r\n" + b"".join(b"$" + str(len(arg)).encode() + b"\r\n" + arg + b"\r\n" for arg in args)


def cases(root, seed):
    output = []
    categories = Counter()

    def add(data, kind, args=(), consumed=0, fault=0, error_byte=0, inline=False, auth=False, bulk_max=BULK_MAX, base=0, need=-1, category="generated"):
        output.append((data, int(inline) | (128 if auth else 0), kind, fault, error_byte, bulk_max, base, consumed, need, tuple(args)))
        categories[category] += 1

    def complete(args, base=0):
        data = frame(args)
        add(data, 1, args, len(data), base=base, category="valid-array")
        add(data + frame([b"PING"]), 1, args, len(data), base=base, category="pipeline")
        points = range(len(data)) if len(data) <= 256 else sorted(set(range(min(32, len(data)))) | {len(data) - n for n in range(1, 5)} | {len(data) // 2} | {n for n in (4095, 4096, 4097, 16383, 16384, 16385, 65535, 65536, 65537) if n < len(data)})
        for cut in points:
            add(data[:cut], 0, base=base, category="array-fragment")

    rng = random.Random(seed)
    for args in ([], [b"PING"], [b"ECHO", b""], [b"ECHO", bytes(range(256))], [b"SET", b"key\x00", b"a\r\nb\x00"], [b"MGET"] + [str(i).encode() for i in range(257)]):
        complete(args)
    for size in (0, 1, 2, 7, 15, 31, 63, 64, 65, 127, 128, 255, 256, 1023, 4095, 4096, 4097, 16383, 16384, 16385, 65535, 65536, 65537, 131071, 131072, 131073):
        payload = (bytes(range(256)) * ((size + 255) // 256))[:size]
        complete([b"ECHO", payload], base=19)
    for _ in range(1500):
        args = [rng.randbytes(rng.randrange(65)) for _ in range(rng.randrange(13))]
        data = frame(args)
        add(data, 1, args, len(data), base=rng.randrange(4096), category="random-array")
        cut = rng.randrange(len(data))
        add(data[:cut], 0, category="random-fragment")
    for byte in range(256):
        value = bytes([byte])
        data = b"*" + value + b"\r\n"
        if byte == 0 or 49 <= byte <= 57:
            add(data, 0, category="count-byte")
        elif byte == 48:
            add(data, 1, consumed=4, category="count-byte")
        else:
            add(data, 2, fault=1, category="count-byte")
        data = b"*1\r\n$" + value + b"\r\n"
        add(data, 0 if byte == 0 or 48 <= byte <= 57 else 2, fault=0 if byte == 0 or 48 <= byte <= 57 else 2, category="length-byte")
        data = b"*1\r\n" + value + b"\r\n"
        if byte == 0:
            add(data, 0, category="prefix-byte")
        elif byte == 36:
            add(data, 2, fault=2, category="prefix-byte")
        else:
            add(data, 2, fault=5, error_byte=byte, category="prefix-byte")
        data = b"*1\r" + value + b"$4\r" + value + b"PING" + value + value
        add(data, 1, [b"PING"], len(data), category="permissive-framing")
    for value in (b"0", b"-1", b"-2", b"-9223372036854775808"):
        data = b"*" + value + b"\r\n"
        for auth in (False, True):
            add(data + frame([b"PING"]), 1, consumed=len(data), auth=auth, category="empty-array")
    for value in (b"", b"-0", b"00", b"01", b"+1", b" 1", b"1 ", b"1x", b"--1", b"2147483648", b"9223372036854775807", b"9223372036854775808", b"-9223372036854775809"):
        add(b"*" + value + b"\r\n", 2, fault=1, category="bad-array-length")
    for value in (b"", b"-1", b"-0", b"00", b"01", b"+1", b" 1", b"1 ", b"1x", b"536870913", b"9223372036854775807", b"9223372036854775808"):
        add(b"*1\r\n$" + value + b"\r\n", 2, fault=2, category="bad-bulk-length")
    for value in (10, 11, 2147483647):
        add(b"*" + str(value).encode() + b"\r\n", 0 if value <= 10 else 2, fault=0 if value <= 10 else 3, auth=True, category="auth-count")
    for value in (0, 16384, 16385, BULK_MAX, BULK_MAX + 1):
        data = b"*1\r\n$" + str(value).encode() + b"\r\n"
        fault = 2 if value > BULK_MAX else 4 if value > 16384 else 0
        add(data, 2 if fault else 0, fault=fault, auth=True, category="auth-length")
    for start, inline, fault in ((b"*", False, 7), (b"*1\r\n$", False, 8), (b"ECHO ", True, 9)):
        header_start = 4 if start == b"*1\r\n$" else 0
        for size in (65535, 65536, 65537):
            data = start + b"A" * (size - (len(start) - header_start))
            add(data, 2 if size > 65536 else 0, fault=fault if size > 65536 else 0, inline=inline, category="unbounded-size")
        data = start + b"x\x00" + b"A" * 65536 + b"\r\n"
        add(data, 2, fault=fault, inline=inline, category="nul-unbounded-size")
    add(b"*" + b"1" * 70000 + b"\r\n", 2, fault=1, category="complete-long-header")
    add(b"*1\r\n$" + b"1" * 70000 + b"\r\n", 2, fault=2, category="complete-long-header")
    add(b"*1\r\n!" + b"A" * 70000 + b"\r\n", 2, fault=5, error_byte=33, category="complete-long-header")
    for base in (0, 17, 4096, MAXIMUM - 3):
        data = b"*1\r\n$9223372036854775807\r\n"
        add(data, 2, fault=2, bulk_max=MAXIMUM, base=base, category="native-overflow")
    for size in (65536, 65537, 70000):
        data = b"ECHO " + b"A" * (size - 5) + b"\r\n"
        add(data, 1, [b"ECHO", b"A" * (size - 5)], len(data), inline=True, category="complete-long-inline")
    golden = json.loads((root / "reference-inline.json").read_text())["cases"]
    for row in golden:
        data, reply = bytes.fromhex(row["request_hex"]), bytes.fromhex(row["reply_hex"])
        if not reply:
            add(data, 0, inline=True, category="reference-inline")
            continue
        if reply[:1] == b"$":
            end = reply.index(b"\r\n")
            length = int(reply[1:end])
            add(data, 1, [b"ECHO", reply[end + 2:end + 2 + length]], data.index(b"\n") + 1, inline=True, category="reference-inline")
            continue
        message = reply[1:reply.index(b"\r\n")]
        if message.startswith(b"ERR Protocol error: "):
            detail = message.removeprefix(b"ERR Protocol error: ")
            add(data, 2, fault=FAULTS[detail], inline=True, category="reference-inline")
            continue
        if b"wrong number of arguments" not in message:
            raise ValueError("unclassified reference command error")
        line = data[:data.index(b"\n")]
        if line.endswith(b"\r"):
            line = line[:-1]
        if line == b"ECHO ":
            args = [b"ECHO"]
        elif line == b"ECHO foo\\ bar":
            args = [b"ECHO", b"foo\\", b"bar"]
        elif line == b"ECHO abc\rdef":
            args = [b"ECHO", b"abc", b"def"]
        elif line in [b"ECHO A" + bytes([c]) + b"B" for c in (9, 13, 32)] or line in [b'ECHO "A"' + bytes([c]) + b"B" for c in (9, 11, 12, 13, 32)]:
            args = [b"ECHO", b"A", b"B"]
        else:
            raise ValueError("unclassified reference arity: " + repr(line))
        add(data, 1, args, data.index(b"\n") + 1, inline=True, category="reference-inline")
    for size in (0, 1, 2, 15, 63, 64, 65, 255, 256, 1024):
        value = (bytes(range(256)) * ((size + 255) // 256))[:size]
        encoded = b"".join(b"\\x" + f"{byte:02x}".encode() for byte in value)
        data = b'ECHO "' + encoded + b'"\r\n'
        add(data, 1, [b"ECHO", value], len(data), inline=True, category="generated-inline-hex")
        points = range(len(data)) if len(data) <= 256 else range(min(48, len(data)))
        for cut in points:
            add(data[:cut], 0, inline=True, category="inline-fragment")
    return output, dict(categories)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--odin", default=os.environ.get("ODIN") or shutil.which("odin") or str(Path.home() / "odin/current/odin"))
    parser.add_argument("--seed", type=int, default=20261025)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    root = here.parents[1]
    vectors, categories = cases(here, args.seed)
    maximum = max(len(c[0]) for c in vectors)
    results = []
    with tempfile.TemporaryDirectory(prefix="eski-request-parser-") as temporary:
        temporary = Path(temporary)
        fixture = temporary / "cases.bin"
        with fixture.open("wb") as stream:
            stream.write(struct.pack("<8sIII", b"ERSP001\x00", mmap.PAGESIZE, len(vectors), maximum))
            for data, flags, kind, fault, byte, bulk_max, base, consumed, need, arguments in vectors:
                stream.write(struct.pack("<IBBBBqqIqI", len(data), flags, kind, fault, byte, bulk_max, base, consumed, need, len(arguments)))
                stream.write(data)
                for argument in arguments:
                    stream.write(struct.pack("<I", len(argument)))
                    stream.write(argument)
        digest = hashlib.sha256(fixture.read_bytes()).hexdigest()
        for mode, flags in (("debug", ["-debug"]), ("release", ["-o:speed"])):
            binary = temporary / mode
            subprocess.run([args.odin, "build", "test/request_parser", "-vet", "-strict-style", "-thread-count:2", *flags, "-out:" + str(binary)], cwd=root, check=True)
            run = subprocess.run([str(binary), str(fixture)], text=True, capture_output=True)
            if run.returncode:
                raise RuntimeError(f"{mode} failed: {run.returncode}\n{run.stdout}\n{run.stderr}")
            expected = f"cases={len(vectors)} readonly_guard_calls={len(vectors) * 4} failures=0\n"
            if run.stdout != expected:
                raise RuntimeError("unexpected checker output: " + run.stdout)
            results.append({"mode": mode, "cases": len(vectors), "readonly_guard_calls": len(vectors) * 4, "allocation_states": ["cold", "reused"]})
            print(mode + ": " + run.stdout.strip())
    report = {"seed": args.seed, "page_size": mmap.PAGESIZE, "fixture_sha256": digest, "reference_inline_sha256": hashlib.sha256((here / "reference-inline.json").read_bytes()).hexdigest(), "categories": categories, "modes": results}
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
