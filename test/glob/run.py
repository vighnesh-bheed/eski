import argparse
from collections import Counter
import gzip
import hashlib
import itertools
import json
import mmap
import os
from pathlib import Path
import random
import re
import struct
import subprocess
import sys
import tempfile

SEED = 0x92C1EA4D
MAGIC = b"EGLOB001"
BATCH_SIZE = 10000
MAX_CASE_BYTES = 100000
CORPUS_PAGE_SIZE = 4096


def corpus(page_size):
    pairs = []
    seen = set()
    categories = Counter()

    def add(category, pattern, text):
        pair = (bytes(pattern), bytes(text))
        if len(pair[0]) + len(pair[1]) > MAX_CASE_BYTES:
            raise RuntimeError("case exceeds the oracle byte bound")
        if pair not in seen:
            seen.add(pair)
            pairs.append(pair)
            categories[category] += 1

    for pattern in range(256):
        for text in range(256):
            add("exhaustive_single_byte", bytes([pattern]), bytes([text]))
    add("empty", b"", b"")
    for value in range(256):
        add("empty", bytes([value]), b"")
        add("empty", b"", bytes([value]))

    pattern_alphabet = (0, 65, 97, 128, 255, 42, 63, 92)
    text_alphabet = (0, 65, 97, 128, 255)
    short_patterns = [bytes(p) for n in range(4) for p in itertools.product(pattern_alphabet, repeat=n)]
    short_texts = [bytes(t) for n in range(3) for t in itertools.product(text_alphabet, repeat=n)]
    for pattern in short_patterns:
        for text in short_texts:
            add("bounded_subset_exhaustive", pattern, text)

    class_patterns = [
        b"[", b"[]", b"[^]", b"[]]", b"[!]", b"[!a]", b"[-]", b"[a-]",
        b"[-a]", b"[a-z]", b"[z-a]", b"[A-z]", b"[z-A]", b"[\\]",
        b"[\\]]", b"[a\\]", b"[a\\-c]", b"[a-b-c]", b"[a--b]", b"[[",
        b"[[a", b"[\\", b"[^^]", b"[^", b"[--]", b"[--/]", b"[/-0]",
        b"[\x00-\xff]", b"[\x80-\xff]", b"[\xff-\x80]", b"[\x7f-\x80]",
        b"[\x80-\x7f]", b"[^\x00]", b"[^\xff]", b"[^\x80-\xff]",
        b"[a]b", b"[^a]b", b"[a", b"[^a", b"[a\\", b"[a-b", b"[^a-b",
        b"[\\-]", b"[\\^]", b"[\\[]", b"[a\\]]", b"[a]\\", b"[a]*",
        b"[a]?", b"[a][", b"[\\\x80-\xff]", b"[\xff-\\\x80]",
    ]
    for pattern in class_patterns:
        for text in [b""] + [bytes([value]) for value in range(256)]:
            add("malformed_and_classes", pattern, text)
        for text in (b"", b"a", b"A", b"z", b"-", b"]", b"\x00", b"\x80", b"\xff", b"ab"):
            add("class_context", b"Q" + pattern + b"Z", b"Q" + text + b"Z")

    endpoints = (0, 45, 65, 97, 127, 128, 254, 255)
    for low in endpoints:
        for high in endpoints:
            for negate in (b"", b"^"):
                pattern = b"[" + negate + bytes([low]) + b"-" + bytes([high]) + b"]"
                for value in range(256):
                    add("range_signed_boundaries", pattern, bytes([value]))
                add("range_signed_boundaries", pattern, b"")

    for value in range(256):
        byte = bytes([value])
        for text in (byte, b"", b"\x00", b"\xff", b"a", b"A", b"\\"):
            add("escape_binary", b"\\" + byte, text)
        add("escape_binary", b"\\" + byte + b"?", byte + b"\x80")
        add("escape_binary", b"*\\" + byte + b"Z", b"prefix" + byte + b"Z")
        add("escape_binary", b"a" + byte + b"\\", b"a" + byte + b"\\")
    for pattern in (b"\\", b"a\\", b"*\\", b"?\\", b"\\\\", b"\\*", b"\\?", b"\\["):
        for text in (b"", b"\\", b"a\\", b"*", b"?", b"[", b"\x00\\", b"\x80\\"):
            add("trailing_escapes", pattern, text)

    lengths = (1, 2, 3, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 255, 256, 511, 512, 1023, 1024)
    for length in lengths:
        for last in (b"Z", b"Y", b"z"):
            add("retries_and_late_mismatch", b"*aZ", b"a" * length + last)
            add("retries_and_late_mismatch", b"a*b*Z", b"a" * length + b"b" * length + last)
            add("retries_and_late_mismatch", b"*ab*abZ", b"ab" * length + last)
            add("retries_and_late_mismatch", b"*\\*Z", b"x" * length + b"*" + last)
        add("retries_and_late_mismatch", b"*" + b"a" * length + b"Z", b"a" * length + b"Z")
        add("retries_and_late_mismatch", b"*?Z", b"x" * length + b"Z")
        add("retries_and_late_mismatch", b"*[a-z]Z", b"x" * length + b"Z")
    for stars in range(1, 9):
        for suffix in (b"Z", b"Y"):
            add("short_star_chains", b"*a" * stars + b"Z", b"a" * stars + suffix)
    for stars in (999, 1000, 1001, 1002):
        add("nonterminal_star_cutoff", b"*a" * stars + b"Z", b"a" * stars + b"Z")
        add("nonterminal_star_cutoff", b"*?" * stars + b"Z", b"a" * stars + b"Z")
        add("nonterminal_star_cutoff", b"*A" * stars + b"Z", b"a" * stars + b"z")
        add("consecutive_stars", b"*" * stars + b"a", b"a")
        add("terminal_stars", b"a" + b"*" * stars, b"a")

    boundary_lengths = sorted({0, 1, 2, 15, 16, 17, 31, 32, 33, 63, 64, 65, page_size - 1, page_size, page_size + 1, 2 * page_size - 1, 2 * page_size, 2 * page_size + 1, 32768})
    for length in boundary_lengths:
        literal = b"a" * length
        add("slice_boundaries", literal, literal)
        add("slice_boundaries", literal, literal[:-1] + b"b" if literal else b"b")
        add("slice_boundaries", b"*", literal)
        add("slice_boundaries", b"?" * length, literal)
        add("slice_boundaries", b"*" + literal + b"Z", literal + b"Z")
        add("slice_boundaries", b"\\" * (2 * length), b"\\" * length)
        add("slice_boundaries", b"[a]" * min(length, 10000), b"a" * min(length, 10000))
    for boundary in (4096, 16384, 65536):
        for length in (boundary - 1, boundary, boundary + 1):
            add("linux_page_lengths", b"*", b"a" * length)
            add("linux_page_lengths", b"*" * length + b"a", b"a")

    rng = random.Random(SEED)
    for _ in range(4000):
        pattern = bytes(rng.randrange(256) for _ in range(rng.randrange(65)))
        text = bytes(rng.randrange(256) for _ in range(rng.randrange(65)))
        add("random_binary", pattern, text)
    pattern_bytes = b"abAB*?[]^-\\\x00\x7f\x80\xff"
    text_bytes = b"abAB[]^-\\\x00\x7f\x80\xff"
    for _ in range(6000):
        pattern = bytes(rng.choice(pattern_bytes) for _ in range(rng.randrange(33)))
        text = bytes(rng.choice(text_bytes) for _ in range(rng.randrange(33)))
        add("random_syntax", pattern, text)
    subset_bytes = b"aAbB*?\\\x00\x80\xff"
    for _ in range(4000):
        pattern = bytes(rng.choice(subset_bytes) for _ in range(rng.randrange(13)))
        text = bytes(rng.choice(text_bytes) for _ in range(rng.randrange(9)))
        add("random_bounded_subset", pattern, text)
    for _ in range(2000):
        text = bytes(rng.randrange(256) for _ in range(rng.randrange(13)))
        pieces = []
        for byte in text:
            if rng.randrange(4) == 0:
                pieces.append(b"*")
            if rng.randrange(4) == 0:
                pieces.append(b"?")
            else:
                pieces.append((b"\\" if byte in b"*?\\[" else b"") + bytes([byte]))
        if rng.randrange(2):
            pieces.append(b"*")
        pattern = b"".join(pieces)
        add("constructed_matches", pattern, text)
        add("constructed_mutations", pattern, text + b"!")
    return pairs, dict(sorted(categories.items()))


def fold(byte):
    return byte + 32 if 65 <= byte <= 90 else byte


def state_set_match(pattern, text, nocase):
    if not text:
        return not pattern
    tokens = []
    index = 0
    while index < len(pattern):
        byte = pattern[index]
        index += 1
        if byte == 92:
            if index < len(pattern):
                byte = pattern[index]
                index += 1
            tokens.append((0, fold(byte) if nocase else byte))
        elif byte == 42:
            tokens.append((2, 0))
        elif byte == 63:
            tokens.append((1, 0))
        else:
            tokens.append((0, fold(byte) if nocase else byte))

    def closure(states):
        result = set(states)
        pending = list(states)
        while pending:
            position = pending.pop()
            if position < len(tokens) and tokens[position][0] == 2 and position + 1 not in result:
                result.add(position + 1)
                pending.append(position + 1)
        return result

    states = closure({0})
    for byte in text:
        value = fold(byte) if nocase else byte
        following = set()
        for position in states:
            if position == len(tokens):
                continue
            kind, literal = tokens[position]
            if kind == 2:
                following.add(position)
            elif kind == 1 or literal == value:
                following.add(position + 1)
        states = closure(following)
        if not states:
            return False
    return len(tokens) in states


def compatibility_results(pairs, executable):
    path = Path(executable)
    command = [sys.executable, str(path)] if path.suffix == ".py" else [str(path)]
    results = []
    batches = (len(pairs) + BATCH_SIZE - 1) // BATCH_SIZE
    for offset in range(0, len(pairs), BATCH_SIZE):
        batch = pairs[offset:offset + BATCH_SIZE]
        request = [{"pattern_hex": pattern.hex(), "text_hex": text.hex()} for pattern, text in batch]
        completed = subprocess.run(command, input=json.dumps(request, separators=(",", ":")), text=True, capture_output=True, timeout=10, check=True)
        response = json.loads(completed.stdout)
        if not isinstance(response, list) or len(response) != len(batch):
            raise RuntimeError("invalid compatibility oracle response length")
        for result in response:
            if not isinstance(result, dict) or type(result.get("match")) is not bool or type(result.get("nocase_match")) is not bool:
                raise RuntimeError("invalid compatibility oracle booleans")
            results.append(int(result["match"]) | (int(result["nocase_match"]) << 1))
        print(f"oracle batch {offset // BATCH_SIZE + 1}/{batches}", flush=True)
    return results


def encode_fixture(pairs, flags, page_size):
    maximum = max(max(len(pattern), len(text)) for pattern, text in pairs)
    output = bytearray(struct.pack("<8sIII", MAGIC, page_size, len(pairs), maximum))
    for (pattern, text), flag in zip(pairs, flags, strict=True):
        output.extend(struct.pack("<IIB", len(pattern), len(text), flag))
        output.extend(pattern)
        output.extend(text)
    return bytes(output)


def decode_fixture(raw, expected_pairs, page_size):
    if len(raw) < 20:
        raise RuntimeError("truncated fixture")
    magic, stored_page_size, count, maximum = struct.unpack_from("<8sIII", raw)
    if magic != MAGIC or stored_page_size != page_size or count != len(expected_pairs):
        raise RuntimeError("fixture header differs from deterministic generation")
    offset = 20
    flags = []
    for index, expected in enumerate(expected_pairs):
        pattern_size, text_size, flag = struct.unpack_from("<IIB", raw, offset)
        offset += 9
        pattern = raw[offset:offset + pattern_size]
        offset += pattern_size
        text = raw[offset:offset + text_size]
        offset += text_size
        if (pattern, text) != expected or flag > 3 or max(pattern_size, text_size) > maximum:
            raise RuntimeError(f"fixture case {index} differs from deterministic generation")
        flags.append(flag)
    if offset != len(raw):
        raise RuntimeError("unexpected trailing fixture bytes")
    return flags


def independent_checks(pairs, flags):
    checked = 0
    for index, ((pattern, text), flag) in enumerate(zip(pairs, flags, strict=True)):
        if b"[" in pattern or len(pattern) > 12 or len(text) > 8:
            continue
        for mode in range(2):
            actual = state_set_match(pattern, text, bool(mode))
            expected = bool(flag & (1 << mode))
            if actual != expected:
                raise RuntimeError(f"state-set disagreement case={index} pattern={pattern.hex()} text={text.hex()} nocase={bool(mode)} expected={expected} actual={actual}")
        checked += 1
    return checked


def run_native(odin, here, raw, pairs):
    common = ["-vet", "-strict-style", "-thread-count:2"]
    subprocess.run([odin, "check", str(here), *common], check=True, timeout=120)
    with tempfile.TemporaryDirectory(prefix="native-", dir=here) as temporary:
        directory = Path(temporary)
        fixture_path = directory / "cases.bin"
        native_raw = bytearray(raw)
        struct.pack_into("<I", native_raw, 8, mmap.PAGESIZE)
        fixture_path.write_bytes(native_raw)
        for mode, optimization in (("debug", ["-debug"]), ("release", ["-o:speed"])):
            binary = directory / f"glob-{mode}"
            subprocess.run([odin, "build", str(here), f"-out:{binary}", *common, *optimization], check=True, timeout=120)
            completed = subprocess.run([str(binary), str(fixture_path)], text=True, capture_output=True, timeout=120)
            if completed.returncode != 0:
                diagnostic = completed.stdout + completed.stderr
                match = re.search(r"case=(\d+)", diagnostic)
                if match:
                    pattern, text = pairs[int(match.group(1))]
                    diagnostic += f"pattern_hex={pattern.hex()}\ntext_hex={text.hex()}\n"
                raise RuntimeError(f"{mode} native failure status={completed.returncode}\n{diagnostic}")
            print(f"{mode}: {completed.stdout.strip()}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--odin", default=os.environ.get("ODIN", "odin"))
    parser.add_argument("--refresh-oracle", metavar="EXECUTABLE")
    parser.add_argument("--generate-only", action="store_true")
    args = parser.parse_args()
    if not sys.platform.startswith("linux"):
        raise RuntimeError("native guard-page checks require Linux")
    here = Path(__file__).resolve().parent
    page_size = mmap.PAGESIZE
    pairs, categories = corpus(CORPUS_PAGE_SIZE)
    fixture_path = here / "cases.bin.gz"
    manifest_path = here / "manifest.json"
    if args.refresh_oracle:
        flags = compatibility_results(pairs, args.refresh_oracle)
        raw = encode_fixture(pairs, flags, CORPUS_PAGE_SIZE)
        compressed = gzip.compress(raw, mtime=0)
        dp_count = independent_checks(pairs, flags)
        manifest = {
            "format": MAGIC.decode("ascii"),
            "generator_seed": SEED,
            "corpus_page_size": CORPUS_PAGE_SIZE,
            "cases": len(pairs),
            "categories": categories,
            "state_set_cases": dp_count,
            "state_set_comparisons": dp_count * 2,
            "guard_placements_per_build": len(pairs) * 4,
            "native_calls_per_build": len(pairs) * 8,
            "uncompressed_bytes": len(raw),
            "compressed_bytes": len(compressed),
            "fixture_sha256": hashlib.sha256(compressed).hexdigest(),
            "uncompressed_sha256": hashlib.sha256(raw).hexdigest(),
            "generator_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "native_harness_sha256": hashlib.sha256((here / "main.odin").read_bytes()).hexdigest(),
            "oracle_provenance": "Executable byte-glob compatibility oracle; JSON hex inputs and boolean outputs only",
        }
        fixture_path.write_bytes(compressed)
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    else:
        manifest = json.loads(manifest_path.read_text())
        compressed = fixture_path.read_bytes()
        raw = gzip.decompress(compressed)
        if hashlib.sha256(compressed).hexdigest() != manifest["fixture_sha256"] or hashlib.sha256(raw).hexdigest() != manifest["uncompressed_sha256"]:
            raise RuntimeError("fixture SHA256 mismatch")
        if manifest["generator_seed"] != SEED or manifest["categories"] != categories:
            raise RuntimeError("manifest differs from deterministic corpus generation")
        flags = decode_fixture(raw, pairs, CORPUS_PAGE_SIZE)
        dp_count = independent_checks(pairs, flags)
        if dp_count != manifest["state_set_cases"]:
            raise RuntimeError("independent oracle case count mismatch")
    print(f"seed={SEED} cases={len(pairs)} state_set_cases={dp_count} state_set_comparisons={dp_count * 2}", flush=True)
    print(f"fixture_sha256={manifest['fixture_sha256']} bytes={len(compressed)} raw_bytes={len(raw)} page_size={page_size}", flush=True)
    if not args.generate_only:
        run_native(args.odin, here, raw, pairs)


if __name__ == "__main__":
    main()
