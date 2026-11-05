import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dataset
import rdbcmp
import resp
import snapshot

ORDER_FREE = (b"hashtable",)


def report(ok, name, want="", got=""):
    if ok:
        print("PASS\t%s" % name)
    else:
        print("FAIL\t%s\t%s\t%s" % (name, str(want)[:200], str(got)[:200]))
    sys.stdout.flush()


def norm(r):
    if isinstance(r, resp.Error):
        return "ERR:" + str(r)
    return r


def payload(body, version=12):
    d = body + bytes([version, 0])
    return d + rdbcmp.crc64(d).to_bytes(8, "little")


def keys_of(c):
    out = []
    for db in range(16):
        c.check("SELECT", db)
        for k in sorted(c.check("KEYS", "*")):
            out.append((db, k))
    c.check("SELECT", 0)
    return out


def info_of(c, db, k):
    c.check("SELECT", db)
    t = c.check("TYPE", k)
    enc = c.check("OBJECT", "ENCODING", k)
    dig = snapshot.content(c, k, t)
    x = c.check("XINFO", "STREAM", k, "FULL") if t == "stream" else None
    if x is not None:
        for n, item in enumerate(x[:-1]):
            if item == b"radix-tree-nodes":
                x[n + 1] = 0
    return t, enc, dig, x


def dirty(c):
    for line in c.call("INFO", "persistence").decode().split("\r\n"):
        if line.startswith("rdb_changes_since_last_save:"):
            return int(line.split(":")[1])
    return None


def main():
    jp, rp, proto = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    j = resp.Client(jp)
    r = resp.Client(rp)
    if proto == "3":
        j.check("HELLO", "3")
        r.check("HELLO", "3")
    dataset.build(j)
    dataset.build(r)
    pj = proto
    report(norm(j.call("DUMP", "no:such:key")) == norm(r.call("DUMP", "no:such:key")), "RESP%s DUMP of a missing key" % pj)
    exact = 0
    crossed = 0
    for db, k in keys_of(j):
        j.check("SELECT", db)
        r.check("SELECT", db)
        a = j.check("DUMP", k)
        b = r.check("DUMP", k)
        tj, ej, dj, xj = info_of(j, db, k)
        tr, er, dr, xr = info_of(r, db, k)
        ttl_j = max(j.check("PTTL", k), 0)
        ttl_r = max(r.check("PTTL", k), 0)
        grouped = tj == "stream" and xj is not None and any(x == b"groups" and xj[n + 1] for n, x in enumerate(xj[:-1]))
        order_free = ej in ORDER_FREE or grouped
        name = "RESP%s DUMP db%d %r %s/%s" % (pj, db, k[:30], tj, ej.decode() if isinstance(ej, bytes) else ej)
        if a == b:
            exact += 1
            report(True, name + " payload bytes")
        elif not order_free:
            report(False, name + " payload bytes", b.hex()[:120], a.hex()[:120])
        else:
            crossed += 1
            r.check("RESTORE", "__x", str(ttl_j), a, "REPLACE")
            got = info_of(r, db, b"__x")
            same = got[2] == dr and got[1] == er and (tj != "stream" or got[3] == xj)
            report(same, name + " eski payload restored into the reference", (er, dr), (got[1], got[2]))
            r.check("DEL", "__x")
        j.check("RESTORE", "__y", str(ttl_j), a, "REPLACE")
        r.check("RESTORE", "__y", str(ttl_r), b, "REPLACE")
        gj = info_of(j, db, b"__y")
        gr = info_of(r, db, b"__y")
        dump_j = j.check("DUMP", "__y")
        dump_r = r.check("DUMP", "__y")
        same = gj[0] == gr[0] and gj[1] == gr[1] and gj[2] == gr[2] and gj[2] == dj
        same = same and (order_free or dump_j == dump_r)
        same = same and (tj != "stream" or gj[3] == xj)
        report(same, name + " restore round trip matches the reference", (gr[1], gr[2], dump_r.hex()[:60]), (gj[1], gj[2], dump_j.hex()[:60]))
        j.check("RESTORE", "__z", str(ttl_r), b, "REPLACE")
        gz = info_of(j, db, b"__z")
        same = gz[1] == gr[1] and gz[2] == gr[2] and (order_free or j.check("DUMP", "__z") == dump_r)
        same = same and (tj != "stream" or gz[3] == xr)
        report(same, name + " reference payload restored into eski", (gr[1], gr[2]), (gz[1], gz[2]))
        j.check("DEL", "__y", "__z")
        r.check("DEL", "__y")
    j.check("SELECT", 0)
    r.check("SELECT", 0)
    j.check("FLUSHALL")
    r.check("FLUSHALL")
    for c in (j, r):
        c.check("SET", "foo", "bar")
        c.check("RPUSH", "lst", "a", "b")
    p = r.check("DUMP", "foo")
    now = int(time.time() * 1000)
    cases = [
        ("RESTORE", "x", "0", p, "bogus"),
        ("RESTORE", "x", "0", p, "IDLETIME"),
        ("RESTORE", "x", "0", p, "IDLETIME", "-1"),
        ("RESTORE", "x", "0", p, "IDLETIME", "abc"),
        ("RESTORE", "x", "0", p, "FREQ", "256"),
        ("RESTORE", "x", "0", p, "FREQ", "-1"),
        ("RESTORE", "x", "0", p, "IDLETIME", "5", "FREQ", "5"),
        ("RESTORE", "x", "-1", p),
        ("RESTORE", "x", "abc", p),
        ("RESTORE", "foo", "0", p),
        ("RESTORE", "foo", "-1", b"garbage"),
        ("RESTORE", "foo", "abc", b"garbage", "REPLACE"),
        ("RESTORE", "y", "0", b"garbage"),
        ("RESTORE", "y", "0", b""),
        ("RESTORE", "y", "0", p[:-1] + bytes([p[-1] ^ 1])),
        ("RESTORE", "y", "0", payload(b"\x00\x03bar", 13)),
        ("RESTORE", "y1", "0", payload(b"\x00\x03bar", 1)),
        ("RESTORE", "y2", "0", payload(b"\x00\x03barzz")),
        ("RESTORE", "y3", "0", payload(b"\x02\x00")),
        ("RESTORE", "y4", "0", payload(b"\x07\x01")),
        ("RESTORE", "y5", "0", payload(b"\x1e\x00")),
        ("RESTORE", "y6", "0", payload(b"\x00")),
        ("RESTORE", "y7", "0", payload(b"\x00\x05ab")),
        ("RESTORE", "y8", "0", payload(b"\xfc" + bytes(8) + b"\x00\x03bar")),
        ("RESTORE", "y9", "0", payload(b"\x0b\x0c\x02\x00\x00\x00\x02\x00\x00\x00\x02\x00\x01\x00")),
        ("RESTORE", "z1", "0", payload(b"\x0b\x08\x02\x00\x00\x00\x00\x00\x00\x00")),
        ("RESTORE", "z2", "0", payload(b"\x02\x02\x01a\x01a")),
        ("RESTORE", "z3", "0", payload(b"\x14\x07\x07\x00\x00\x00\x00\x00\xff")),
        ("RESTORE", "z4", "0", b"\x00\x81\xff\xff\xff\xff\xff\xff\xff\xf7\x0c\x00" + bytes(8)),
        ("RESTORE", "z5", "9223372036854775807", p),
        ("RESTORE", "z6", str(now - 1000), p, "ABSTTL"),
        ("RESTORE", "foo", str(now - 1000), p, "ABSTTL", "REPLACE"),
        ("RESTORE", "z7", "100000", p, "REPLACE", "REPLACE"),
        ("RESTORE", "z8", "0", p, "IDLETIME", "1", "IDLETIME", "2"),
        ("RESTORE", "lst", "0", p),
        ("DUMP",),
        ("DUMP", "a", "b"),
        ("RESTORE", "z", "0"),
    ]
    for t in cases:
        dj, dr = dirty(j), dirty(r)
        a = (norm(j.call(*t)), "dirty +%d" % (dirty(j) - dj))
        b = (norm(r.call(*t)), "dirty +%d" % (dirty(r) - dr))
        report(a == b, "RESP%s %s" % (pj, " ".join(x if isinstance(x, str) else "<%d bytes>" % len(x) for x in t)), b, a)
    idle_j = j.call("OBJECT", "IDLETIME", "z8")
    idle_r = r.call("OBJECT", "IDLETIME", "z8")
    report(isinstance(idle_j, int) and idle_j >= 2 and abs(idle_j - idle_r) <= 1, "RESP%s idle time restored" % pj, idle_r, idle_j)
    for k in ("foo", "y1", "y2", "y7", "y9", "z5", "z6", "z7", "z8"):
        a = (j.call("EXISTS", k), j.call("TYPE", k), j.call("GET", k) if j.call("TYPE", k) == "string" else None)
        b = (r.call("EXISTS", k), r.call("TYPE", k), r.call("GET", k) if r.call("TYPE", k) == "string" else None)
        report(a == b, "RESP%s state of %s after the restores" % (pj, k), b, a)
    report(0 < j.call("PTTL", "z7") <= 100000, "RESP%s relative ttl restored" % pj, "(0, 100000]", j.call("PTTL", "z7"))
    for c in (j, r):
        c.check("CONFIG", "SET", "sanitize-dump-payload", "yes")
    for t in [
        ("RESTORE", "s1", "0", payload(b"\x0b\x0c\x02\x00\x00\x00\x02\x00\x00\x00\x02\x00\x01\x00")),
        ("RESTORE", "s2", "0", payload(b"\x14\x0d\x0d\x00\x00\x00\x02\x00\x81\x61\x02\x81\x61\x02\xff")),
        ("RESTORE", "s3", "0", payload(b"\x10\x0d\x0d\x00\x00\x00\x02\x00\x81\x61\x02\x81\x62\x02\xff")),
        ("RESTORE", "s4", "0", payload(b"\x10\x11\x11\x00\x00\x00\x04\x00\x81\x61\x02\x81\x62\x02\x81\x61\x02\x81\x62\x02\xff")),
    ]:
        a = norm(j.call(*t))
        b = norm(r.call(*t))
        report(a == b, "RESP%s sanitize-dump-payload yes %s" % (pj, t[1]), b, a)
    for c in (j, r):
        c.check("CONFIG", "SET", "sanitize-dump-payload", "no")
    a = norm(j.call("RESTORE", "s5", "0", payload(b"\x14\x0d\x0d\x00\x00\x00\x02\x00\x81\x61\x02\x81\x61\x02\xff")))
    b = norm(r.call("RESTORE", "s5", "0", payload(b"\x14\x0d\x0d\x00\x00\x00\x02\x00\x81\x61\x02\x81\x61\x02\xff")))
    report(a == b and j.call("SCARD", "s5") == r.call("SCARD", "s5"), "RESP%s sanitize-dump-payload no keeps a duplicate listpack" % pj, b, a)
    for c in (j, r):
        c.check("CONFIG", "SET", "maxmemory-policy", "allkeys-lfu")
        c.call("DEL", "f")
    a = (norm(j.call("RESTORE", "f", "0", p, "FREQ", "100")), j.call("OBJECT", "FREQ", "f"))
    b = (norm(r.call("RESTORE", "f", "0", p, "FREQ", "100")), r.call("OBJECT", "FREQ", "f"))
    report(a == b, "RESP%s FREQ restored under allkeys-lfu" % pj, b, a)
    for c in (j, r):
        c.check("CONFIG", "SET", "maxmemory-policy", "noeviction")
    j.check("FLUSHALL")
    r.check("FLUSHALL")
    print("SUMMARY\t%d keys with identical payload bytes, %d hashtable or grouped stream keys checked by cross restore" % (exact, crossed))


if __name__ == "__main__":
    main()
