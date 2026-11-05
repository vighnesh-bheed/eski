import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import resp


def hexs(b):
    if isinstance(b, str):
        b = b.encode()
    return b.hex()


def plain(v):
    if isinstance(v, bytes):
        return v.decode("latin-1")
    if isinstance(v, (list, tuple)):
        return [plain(x) for x in v]
    return v


def content(c, k, t):
    if t == "string":
        v = c.check("GET", k)
        body = [v]
    elif t == "list":
        body = c.check("LRANGE", k, 0, -1)
    elif t == "set":
        body = sorted(c.check("SMEMBERS", k))
    elif t == "zset":
        body = c.check("ZRANGE", k, 0, -1, "WITHSCORES")
    elif t == "hash":
        flat = c.check("HGETALL", k)
        body = sorted(zip(flat[0::2], flat[1::2]))
    elif t == "stream":
        body = c.check("XRANGE", k, "-", "+")
    else:
        body = [t]
    h = hashlib.sha1()
    h.update(json.dumps(plain(body), sort_keys=True).encode())
    return h.hexdigest()


def take(c, databases, with_dump):
    out = {"keys": {}}
    for db in range(databases):
        c.check("SELECT", db)
        keys = c.check("KEYS", "*")
        for k in sorted(keys):
            cmds = [("TYPE", k), ("OBJECT", "ENCODING", k), ("PEXPIRETIME", k)]
            if with_dump:
                cmds.append(("DUMP", k))
            r = c.pipeline(cmds)
            entry = {
                "db": db,
                "type": r[0],
                "encoding": r[1].decode() if isinstance(r[1], bytes) else str(r[1]),
                "pexpiretime": r[2],
                "digest": content(c, k, r[0]),
            }
            if with_dump:
                entry["dump"] = hexs(r[3]) if isinstance(r[3], bytes) else None
            if r[0] == "stream":
                entry["xinfo"] = plain(c.check("XINFO", "STREAM", k, "FULL"))
            if r[0] == "hash":
                fields = c.check("HKEYS", k)
                if fields:
                    ttls = c.check("HPEXPIRETIME", k, "FIELDS", len(fields), *fields)
                    entry["field_ttls"] = sorted([hexs(f), t] for f, t in zip(fields, ttls))
            out["keys"]["%d:%s" % (db, hexs(k))] = entry
    c.check("SELECT", 0)
    whole = hashlib.sha1()
    for name in sorted(out["keys"]):
        e = out["keys"][name]
        whole.update(("%s %s %s %s\n" % (name, e["type"], e["digest"], e["pexpiretime"])).encode())
    out["digest"] = whole.hexdigest()
    return out


if __name__ == "__main__":
    port = int(sys.argv[1])
    path = sys.argv[2]
    with_dump = len(sys.argv) > 3 and sys.argv[3] == "dump"
    c = resp.Client(port)
    snap = take(c, 16, with_dump)
    with open(path, "w") as fh:
        json.dump(snap, fh, sort_keys=True)
    print("snapshot of port %d: %d keys, digest %s" % (port, len(snap["keys"]), snap["digest"]))
