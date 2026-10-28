import json
import sys

ORDER_FREE = {"hashtable"}


def load(path):
    with open(path) as fh:
        return json.load(fh)


def has_groups(xinfo):
    for i in range(0, len(xinfo) - 1, 2):
        if xinfo[i] == "groups":
            return bool(xinfo[i + 1])
    return False


def loaded_equal(field, x, y):
    if field == "encoding" and x["type"] == "string" and x["encoding"] == "raw" and y["encoding"] in ("int", "embstr"):
        return True
    if field == "dump" and x["encoding"] == "listpackex" and x["dump"][2:18] != y["dump"][2:18] and y["dump"][2:18] == "0" * 16:
        return x["dump"][:2] + x["dump"][18:-20] == y["dump"][:2] + y["dump"][18:-20]
    return False


def main():
    left_path, right_path, label = sys.argv[1], sys.argv[2], sys.argv[3]
    checks = sys.argv[4].split(",")
    loaded = len(sys.argv) > 5 and sys.argv[5] == "--loaded"
    normalised = []
    a = load(left_path)
    b = load(right_path)
    failures = []
    matrix = {}
    if "digest" in checks and a["digest"] != b["digest"]:
        failures.append("dataset digest %s != %s" % (a["digest"], b["digest"]))
    keys = sorted(set(a["keys"]) | set(b["keys"]))
    for k in keys:
        x = a["keys"].get(k)
        y = b["keys"].get(k)
        if x is None or y is None:
            failures.append("key %s missing on the %s side" % (k, "left" if x is None else "right"))
            continue
        cell = matrix.setdefault((x["type"], x["encoding"]), [0, 0])
        cell[0] += 1
        bad = []
        for field in ("type", "encoding", "pexpiretime", "digest", "field_ttls"):
            if x.get(field) != y.get(field):
                if loaded and loaded_equal(field, x, y):
                    normalised.append("%s %s: %r on the live side, %r after the load" % (k, field, x.get(field), y.get(field)))
                    continue
                bad.append("%s %r != %r" % (field, x.get(field), y.get(field)))
        if "xinfo" in checks and x.get("xinfo") != y.get("xinfo"):
            bad.append("XINFO STREAM FULL differs")
        if "dump" in checks and x.get("dump") is not None and y.get("dump") is not None:
            if x["type"] == "stream" and x.get("xinfo") and has_groups(x["xinfo"]) and "xinfo" not in checks:
                pass
            elif x["encoding"] not in ORDER_FREE and x["dump"] != y["dump"]:
                if loaded and loaded_equal("dump", x, y):
                    normalised.append("%s dump: listpackex minExpire header %s on the live side, 0 after the load" % (k, x["dump"][2:18]))
                else:
                    bad.append("dump payload differs")
        if bad:
            cell[1] += 1
            failures.append("key %s: %s" % (k, "; ".join(bad)))
    print("%s: %d keys compared" % (label, len(keys)))
    for (t, e), (n, f) in sorted(matrix.items()):
        print("  %-8s %-12s %4d keys  %s" % (t, e, n, "ok" if f == 0 else "%d FAILED" % f))
    for n in normalised:
        print("  note " + n)
    for f in failures[:40]:
        print("  FAIL " + f)
    if failures:
        print("%s: %d failures" % (label, len(failures)))
        sys.exit(1)
    print("%s: identical" % label)


main()
