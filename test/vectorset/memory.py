import argparse
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cases
from compare import Conn, ServerGone, esc, text

MODES = ["NOQUANT", "Q8", "BIN"]
DIMS = [8, 32, 300]
COUNTS = [1, 100, 1000]


def endpoint(spec):
    host, _, port = spec.rpartition(":")
    if not host:
        host = "127.0.0.1"
    return host, int(port)


def integer(node):
    if node.kind != b":":
        raise ServerGone("expected an integer reply, got %s" % esc(node.raw[:100]))
    return int(node.value)


def serialized_length(node):
    value = text(node)
    if node.kind != b"+" or value is None or b"serializedlength:" not in value:
        return None
    return int(value.split(b"serializedlength:")[1].split()[0])


def vectors(seed, mode, dim, count):
    rng = random.Random(seed * 1000003 + MODES.index(mode) * 100003 + dim * 1009 + count)
    return [[rng.uniform(-1.0, 1.0) for _ in range(dim)] for _ in range(count)]


def measure(spec, seed, m, modes, dims, counts, prefix):
    host, port = endpoint(spec)
    conn = Conn(port, 2, 120, host)
    rows = []
    for mode in modes:
        for dim in dims:
            row = {"mode": mode, "dim": dim, "usage": {}, "serialized": {}}
            for count in counts:
                key = ("%sm_%s_%d_%d" % (prefix, mode, dim, count)).encode()
                conn.call([b"DEL", key])
                cmds = []
                for i, vec in enumerate(vectors(seed, mode, dim, count)):
                    cmds.append([b"VADD", key, b"FP32", cases.fp32(vec), b"e%d" % i, mode.encode(), b"M", b"%d" % m])
                for i in range(0, len(cmds), 200):
                    for node in conn.pipeline(cmds[i:i + 200]):
                        if node.kind not in (b":", b"#"):
                            raise ServerGone("VADD failed on %s: %s" % (label(spec), esc(node.raw[:100])))
                row["usage"][count] = integer(conn.call([b"MEMORY", b"USAGE", key]))
                row["serialized"][count] = serialized_length(conn.call([b"DEBUG", b"OBJECT", key]))
                conn.call([b"DEL", key])
            rows.append(row)
    conn.close()
    return rows


def slope(values, low, high):
    if values.get(low) is None or values.get(high) is None or high == low:
        return None
    return (values[high] - values[low]) / float(high - low)


def fmt(x, digits=1):
    if x is None:
        return "n/a"
    if isinstance(x, float):
        return "%.*f" % (digits, x)
    return str(x)


def label(spec):
    host, port = endpoint(spec)
    return "%s:%d" % (host, port)


def table(spec, rows, counts, out):
    low, high = counts[-2], counts[-1]
    out.write("server %s\n" % label(spec))
    head = ["mode", "dim"] + ["usage %d" % c for c in counts] + ["bytes/vector", "serialized bytes/vector"]
    out.write("| " + " | ".join(head) + " |\n")
    out.write("|" + "---|" * len(head) + "\n")
    for row in rows:
        cells = [row["mode"], str(row["dim"])] + [fmt(row["usage"].get(c)) for c in counts]
        cells += [fmt(slope(row["usage"], low, high)), fmt(slope(row["serialized"], low, high))]
        out.write("| " + " | ".join(cells) + " |\n")
    out.write("bytes/vector is (usage at %d - usage at %d) / %d\n" % (high, low, high - low))


def margins(candidate, reference, counts):
    low, high = counts[-2], counts[-1]
    out = []
    for a, b in zip(candidate, reference):
        sa = slope(a["usage"], low, high)
        sb = slope(b["usage"], low, high)
        entry = {"mode": a["mode"], "dim": a["dim"], "candidate_slope": sa, "reference_slope": sb,
                 "slope_margin": (sa - sb) / sb if sa is not None and sb else None, "usage_margin": {}}
        for c in counts:
            ua, ub = a["usage"].get(c), b["usage"].get(c)
            entry["usage_margin"][c] = (ua - ub) / float(ub) if ua is not None and ub else None
        out.append(entry)
    return out


def pct(x):
    return "n/a" if x is None else "%+.1f%%" % (100.0 * x)


def comparison(cand_spec, ref_spec, result, counts, out):
    out.write("candidate %s against reference %s\n" % (label(cand_spec), label(ref_spec)))
    head = ["mode", "dim", "bytes/vector candidate", "bytes/vector reference", "slope margin"] + ["usage margin at %d" % c for c in counts]
    out.write("| " + " | ".join(head) + " |\n")
    out.write("|" + "---|" * len(head) + "\n")
    for e in result:
        cells = [e["mode"], str(e["dim"]), fmt(e["candidate_slope"]), fmt(e["reference_slope"]), pct(e["slope_margin"])]
        cells += [pct(e["usage_margin"][c]) for c in counts]
        out.write("| " + " | ".join(cells) + " |\n")
    worst = largest(result, counts, abs)
    excess = largest(result, counts, lambda value: value)
    if worst:
        out.write("largest margin: %s (%s)\n" % (pct(worst[0]), worst[1]))
    if excess:
        out.write("largest excess over the reference: %s (%s)\n" % (pct(excess[0]), excess[1]))
    return excess


def largest(result, counts, key):
    best = None
    for e in result:
        for name, value in [("bytes/vector", e["slope_margin"])] + [("usage at %d" % c, e["usage_margin"][c]) for c in counts]:
            if value is not None and (best is None or key(value) > key(best[0])):
                best = (value, "%s %d %s" % (e["mode"], e["dim"], name))
    return best


def main(argv=None):
    parser = argparse.ArgumentParser(prog="memory.py", description="Measure MEMORY USAGE of vector sets at 1, 100 and 1000 elements of 8, 32 and 300 dimensions in NOQUANT, Q8 and BIN, print the table and the bytes per vector, and compare a candidate server with a reference.")
    parser.add_argument("servers", nargs="+", help="HOST:PORT or PORT; with two servers the first is the candidate and the second the reference")
    parser.add_argument("--seed", type=int, default=cases.SEED, help="seed of the random float32 components (default: %(default)s)")
    parser.add_argument("--m", type=int, default=16, help="M given to every VADD (default: %(default)s)")
    parser.add_argument("--modes", default=",".join(MODES))
    parser.add_argument("--dims", default=",".join(str(d) for d in DIMS))
    parser.add_argument("--counts", default=",".join(str(c) for c in COUNTS), help="element counts; the slope uses the last two")
    parser.add_argument("--prefix", default="eski:memory:", help="key prefix; each key is deleted before and after its measurement")
    parser.add_argument("--max-margin", type=float, help="fail when the candidate uses more than the reference by more than this fraction anywhere, for example 0.1; using less always passes")
    parser.add_argument("--json", help="write the measurements and margins to this path")
    args = parser.parse_args(argv)
    if len(args.servers) > 2:
        parser.error("give one server, or a candidate and a reference")
    modes = [m.strip().upper() for m in args.modes.split(",") if m.strip()]
    dims = [int(d) for d in args.dims.split(",") if d.strip()]
    counts = sorted(int(c) for c in args.counts.split(",") if c.strip())
    if any(m not in MODES for m in modes) or len(counts) < 2 or any(c < 1 or c > 1000 for c in counts):
        parser.error("modes must be among %s and at least two counts between 1 and 1000 are needed" % ",".join(MODES))
    results = []
    for spec in args.servers:
        try:
            rows = measure(spec, args.seed, args.m, modes, dims, counts, args.prefix)
        except (ServerGone, OSError, ValueError) as e:
            print("measurement on %s failed: %s" % (spec, e))
            return 1
        results.append(rows)
        table(spec, rows, counts, sys.stdout)
    report = {"seed": args.seed, "m": args.m, "counts": counts, "servers": [{"server": spec, "rows": rows} for spec, rows in zip(args.servers, results)]}
    status = 0
    if len(results) == 2:
        result = margins(results[0], results[1], counts)
        excess = comparison(args.servers[0], args.servers[1], result, counts, sys.stdout)
        report["margins"] = result
        if excess is not None:
            report["largest_excess"] = {"margin": excess[0], "where": excess[1]}
        if args.max_margin is not None and excess is not None and excess[0] > args.max_margin:
            print("the candidate uses %s more than the reference (%s), above %s" % (pct(excess[0]), excess[1], pct(args.max_margin)))
            status = 1
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=1)
            handle.write("\n")
    return status


if __name__ == "__main__":
    sys.exit(main())
