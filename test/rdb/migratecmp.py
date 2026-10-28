import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import resp


def norm(r):
    if isinstance(r, resp.Error):
        return "ERR:" + str(r)
    if isinstance(r, bytes):
        return r.decode("latin-1")
    if isinstance(r, list):
        return [norm(x) for x in r]
    return r


def cached(c):
    for line in c.call("INFO", "stats").decode().split("\r\n"):
        if line.startswith("migrate_cached_sockets:"):
            return int(line.split(":")[1])
    return None


def dirty(c):
    for line in c.call("INFO", "persistence").decode().split("\r\n"):
        if line.startswith("rdb_changes_since_last_save:"):
            return int(line.split(":")[1])
    return None


def scenario(src_port, dst_port, auth, idle_wait):
    a = resp.Client(src_port)
    b = resp.Client(dst_port)
    out = []
    host = "127.0.0.1"
    dst = str(dst_port)

    def step(label, *args, target=True):
        da = dirty(a)
        db = dirty(b) if target else 0
        reply = norm(a.call(*args))
        row = (label, reply, "source dirty +%d" % (dirty(a) - da))
        if target:
            row += ("target dirty +%d" % (dirty(b) - db),)
        out.append(row)

    a.call("FLUSHALL")
    b.call("FLUSHALL")
    out.append(("cached at start", cached(a)))
    a.call("SET", "k1", "v1")
    a.call("SET", "k2", "v2")
    a.call("SET", "k3", "v3")
    a.call("SET", "ttlk", "v")
    a.call("PEXPIRE", "ttlk", "5000")
    a.call("RPUSH", "big", *[("item %d" % i) for i in range(20000)])
    a.call("HSET", "h", "f1", "a", "f2", "b")
    a.call("XADD", "st", "1-1", "x", "y")
    a.call("XGROUP", "CREATE", "st", "g", "0")
    step("missing key", "MIGRATE", host, dst, "nokey", "0", "1000")
    step("move", "MIGRATE", host, dst, "k1", "0", "1000")
    step("copy", "MIGRATE", host, dst, "k2", "0", "1000", "COPY")
    step("copy onto busy key", "MIGRATE", host, dst, "k2", "0", "1000", "COPY")
    step("copy replace", "MIGRATE", host, dst, "k2", "0", "1000", "COPY", "REPLACE")
    step("ttl key", "MIGRATE", host, dst, "ttlk", "0", "1000")
    step("large list", "MIGRATE", host, dst, "big", "0", "10000")
    step("hash", "MIGRATE", host, dst, "h", "0", "1000")
    step("stream with group", "MIGRATE", host, dst, "st", "0", "1000", "COPY")
    step("bad target db", "MIGRATE", host, dst, "k3", "99", "1000", "COPY")
    step("other db", "MIGRATE", host, dst, "k3", "5", "1000", "COPY")
    step("db not integer", "MIGRATE", host, dst, "k3", "abc", "1000")
    step("timeout not integer", "MIGRATE", host, dst, "k3", "0", "abc")
    step("syntax before numbers", "MIGRATE", host, dst, "k3", "0", "abc", "bogus")
    step("auth without password", "MIGRATE", host, dst, "k3", "0", "1000", "AUTH")
    step("auth2 without password", "MIGRATE", host, dst, "k3", "0", "1000", "AUTH2", "u")
    step("keys with non empty key", "MIGRATE", host, dst, "k3", "0", "1000", "KEYS", "k3")
    step("keys all missing", "MIGRATE", host, dst, "", "0", "1000", "KEYS", "nokey1", "nokey2")
    step("empty key without keys", "MIGRATE", host, dst, "", "0", "1000")
    step("refused port", "MIGRATE", host, "1", "k3", "0", "300")
    step("non numeric port", "MIGRATE", host, "abc", "k3", "0", "300")
    step("unresolvable host", "MIGRATE", "nosuchhost.invalid", dst, "k3", "0", "300")
    out.append(("target keys", sorted(norm(b.call("KEYS", "*")))))
    out.append(("target ttl in range", 4000 <= b.call("PTTL", "ttlk") <= 5000))
    out.append(("target list length", b.call("LLEN", "big")))
    out.append(("target stream groups", len(b.call("XINFO", "GROUPS", "st"))))
    b.call("SELECT", "5")
    out.append(("target db 5", norm(b.call("GET", "k3"))))
    b.call("SELECT", "0")
    out.append(("source keys", sorted(norm(a.call("KEYS", "*")))))
    out.append(("cached after moves", cached(a)))
    a.call("MSET", "m1", "1", "m2", "2", "m3", "3")
    b.call("SET", "m2", "busy")
    step("keys with one busy", "MIGRATE", host, dst, "", "0", "1000", "KEYS", "m1", "nokey", "m2", "m3")
    out.append(("source after partial", sorted(norm(a.call("KEYS", "m*")))))
    if auth:
        a.call("SET", "k4", "v4")
        a.call("SET", "k5", "v5")
        b.call("CONFIG", "SET", "requirepass", "secret")
        step("wrong auth", "MIGRATE", host, dst, "k4", "0", "1000", "AUTH", "bad")
        step("good auth", "MIGRATE", host, dst, "k4", "0", "1000", "AUTH", "secret")
        step("auth2", "MIGRATE", host, dst, "k5", "0", "1000", "AUTH2", "default", "secret")
        b2 = resp.Client(dst_port)
        b2.call("AUTH", "secret")
        b2.call("CONFIG", "SET", "requirepass", "")
    a.call("SET", "k6", "v6")
    pauser = resp.Client(dst_port)
    pauser.call("CLIENT", "PAUSE", "1500", "ALL")
    t0 = time.time()
    step("read timeout", "MIGRATE", host, dst, "k6", "0", "300", target=False)
    out.append(("timeout honoured", 0.25 <= time.time() - t0 <= 1.0))
    out.append(("cached after timeout", cached(a)))
    time.sleep(1.6)
    step("after the timeout", "MIGRATE", host, dst, "k6", "0", "1000")
    out.append(("cached after reconnect", cached(a)))
    if idle_wait:
        time.sleep(11.5)
        out.append(("cached after 11 seconds idle", cached(a)))
    a.call("FLUSHALL")
    b.call("FLUSHALL")
    return out


if __name__ == "__main__":
    src, dst = int(sys.argv[1]), int(sys.argv[2])
    auth = "auth" in sys.argv[3:]
    idle = "idle" in sys.argv[3:]
    for row in scenario(src, dst, auth, idle):
        print("\t".join([row[0]] + [repr(x) for x in row[1:]]))
