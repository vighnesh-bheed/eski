import json
import sys

MASK = ("seen-time", "active-time")


def mask(v):
    if isinstance(v, list):
        out = []
        i = 0
        while i < len(v):
            x = v[i]
            if isinstance(x, str) and x in MASK and i + 1 < len(v):
                out.append(x)
                out.append("*")
                i += 2
                continue
            out.append(mask(x))
            i += 1
        return out
    return v


def main():
    a = json.load(open(sys.argv[1]))
    b = json.load(open(sys.argv[2]))
    label = sys.argv[3]
    fields = sys.argv[4].split(",")
    failures = []
    if "digest" in fields and a["digest"] != b["digest"]:
        failures.append("dataset digest %s != %s" % (a["digest"], b["digest"]))
    keys = sorted(set(a["keys"]) | set(b["keys"]))
    types = {}
    for k in keys:
        x = a["keys"].get(k)
        y = b["keys"].get(k)
        if x is None or y is None:
            failures.append("key %s only on the %s side" % (k, "right" if x is None else "left"))
            continue
        types[x["type"]] = types.get(x["type"], 0) + 1
        bad = []
        for f in ("type", "pexpiretime", "digest", "field_ttls", "encoding"):
            if f == "encoding" and "encoding" not in fields:
                continue
            if f == "encoding" and x.get("type") == "string" and {x.get(f), y.get(f)} <= {"raw", "embstr", "int"}:
                continue
            if x.get(f) != y.get(f):
                bad.append("%s %r != %r" % (f, x.get(f), y.get(f)))
        if "xinfo" in fields and mask(x.get("xinfo")) != mask(y.get("xinfo")):
            bad.append("XINFO STREAM FULL differs")
        if bad:
            failures.append("key %s: %s" % (k, "; ".join(bad)))
    summary = ", ".join("%s %d" % (t, n) for t, n in sorted(types.items()))
    for f in failures[:30]:
        print("  FAIL " + f)
    if failures:
        print("%s: %d keys, %d failures" % (label, len(keys), len(failures)))
        sys.exit(1)
    print("%s: %d keys identical (%s)" % (label, len(keys), summary))


main()
