import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdbcmp

CHARSET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"


def length(n):
    if n < 64:
        return bytes([n])
    if n < 16384:
        return bytes([0x40 | (n >> 8), n & 0xFF])
    if n <= 0xFFFFFFFF:
        return b"\x80" + n.to_bytes(4, "big")
    return b"\x81" + n.to_bytes(8, "big")


def string(s):
    if isinstance(s, str):
        s = s.encode()
    return length(len(s)) + s


def header():
    out = b"REDIS0012"
    for k, v in ((b"redis-ver", b"7.4.11"), (b"redis-bits", b"64"), (b"ctime", b"1700000000"), (b"used-mem", b"1000000"), (b"aof-base", b"0")):
        out += b"\xfa" + string(k) + string(v)
    return out


def finish(body):
    data = body + b"\xff"
    return data + rdbcmp.crc64(data).to_bytes(8, "little")


def module_id(name, ver):
    v = 0
    for ch in name:
        v = (v << 6) | CHARSET.index(ch)
    return (v << 10) | ver


def write(path, data):
    with open(path, "wb") as fh:
        fh.write(data)


def stream_record(data, wanted):
    p = rdbcmp.Parser(data)
    p.raw(9)
    while True:
        op = p.u8()
        if op == 250:
            p.string()
            p.string()
            continue
        if op == 254:
            p.length()
            continue
        if op == 251:
            p.length()
            p.length()
            continue
        if op == 252:
            p.raw(8)
            continue
        if op == 255:
            raise ValueError("stream key not found")
        key = p.string()
        if op != 21 or key[1:] != wanted:
            rdbcmp.parse_value(p, op)
            continue
        rec = {"key": key, "nodes": [], "groups": []}
        n, _ = p.length()
        for _ in range(n):
            rec["nodes"].append((p.string(), p.string()))
        rec["meta"] = [p.length()[0] for _ in range(8)]
        ng, _ = p.length()
        for _ in range(ng):
            g = {"name": p.string(), "last": (p.length()[0], p.length()[0]), "read": p.length()[0], "pel": [], "consumers": []}
            npel, _ = p.length()
            for _ in range(npel):
                g["pel"].append((p.raw(16), p.raw(8), p.length()[0]))
            nc, _ = p.length()
            for _ in range(nc):
                c = {"name": p.string(), "seen": p.raw(8), "active": p.raw(8), "pel": []}
                k, _ = p.length()
                for _ in range(k):
                    c["pel"].append(p.raw(16))
                g["consumers"].append(c)
            rec["groups"].append(g)
        return rec


def stream_encode(rec, version):
    out = bytes([version]) + rec["key"] + length(len(rec["nodes"]))
    for k, v in rec["nodes"]:
        out += k + v
    meta = rec["meta"] if version != 15 else rec["meta"][:3]
    for m in meta:
        out += length(m)
    out += length(len(rec["groups"]))
    for g in rec["groups"]:
        out += g["name"] + length(g["last"][0]) + length(g["last"][1])
        if version != 15:
            out += length(g["read"])
        out += length(len(g["pel"]))
        for raw, t, n in g["pel"]:
            out += raw + t + length(n)
        out += length(len(g["consumers"]))
        for c in g["consumers"]:
            out += c["name"] + c["seen"]
            if version == 21:
                out += c["active"]
            out += length(len(c["pel"])) + b"".join(c["pel"])
    return out


def main():
    src, out = sys.argv[1], sys.argv[2]
    base = open(src, "rb").read()
    cases = []
    bad_crc = bytearray(base)
    bad_crc[-1] ^= 0xFF
    write(os.path.join(out, "crc.rdb"), bytes(bad_crc))
    cases.append(("crc", 1, "Wrong RDB checksum expected", 1, 1))
    body = header() + b"\xfe\x00\xfb\x01\x00" + b"\x00" + string("k") + string("v" * 100)
    write(os.path.join(out, "trunc.rdb"), body[: len(body) - 40])
    cases.append(("trunc", 1, "Short read or OOM loading DB. Unrecoverable error, aborting now.", 1, 1))
    write(os.path.join(out, "sig.rdb"), b"REDIX" + base[5:])
    cases.append(("sig", 1, "Wrong signature trying to load DB from file", 1, 1))
    write(os.path.join(out, "ver.rdb"), b"REDIS0013" + base[9:])
    cases.append(("ver", 1, "Can't handle RDB format version 13", 1, 1))
    mid = module_id("eski_test", 3)
    body = header() + b"\xfe\x00\xfb\x01\x00" + b"\x07" + string("m") + length(mid) + b"\x02\x05" + b"\x00"
    write(os.path.join(out, "module.rdb"), finish(body))
    cases.append(("module", 1, "The RDB file contains module data I can't load: no matching module type 'eski_test'", 1, 0))
    body = header() + b"\xf7" + length(mid) + b"\x02\x02" + b"\x00"
    write(os.path.join(out, "moduleaux.rdb"), finish(body))
    cases.append(("moduleaux", 1, "The RDB file contains AUX module data I can't load: no matching module 'eski_test'", 1, 1))
    lib = "#!lua name=eskilib\nredis.register_function('eskifn', function() return 1 end)\n"
    body = header() + b"\xf5" + string(lib) + b"\xfe\x00\xfb\x01\x00" + b"\x00" + string("k") + string("v")
    write(os.path.join(out, "function.rdb"), finish(body))
    cases.append(("function", 1, "Failed loading library", 0, 0))
    body = header() + b"\xfe\x00\xfb\x01\x00" + bytes([30]) + string("u") + string("v")
    write(os.path.join(out, "unknown.rdb"), finish(body))
    cases.append(("unknown", 1, "Unknown RDB encoding type 30", 1, 1))
    body = header() + b"\xfe\x00\xfb\x02\x00" + b"\x00" + string("x") + string("1") + b"\x00" + string("x") + string("2")
    write(os.path.join(out, "dupkey.rdb"), finish(body))
    cases.append(("dupkey", 1, "RDB has duplicated key 'x' in DB 0", 1, 139))
    body = header() + b"\xfe\x00\xfb\x03\x01" + b"\xfc" + (1000).to_bytes(8, "little") + b"\x00" + string("old") + string("gone")
    body += b"\x00" + string("live") + string("kept")
    body += b"\x02" + string("emptyset") + length(0)
    write(os.path.join(out, "expired.rdb"), finish(body))
    cases.append(("expired", 0, "Done loading RDB, keys loaded: 1, keys expired: 1, empty keys skipped: 1.", 1, 0))
    body = header() + b"\xfe\x00\xfb\x02\x00" + b"\xf8" + length(3600) + b"\x00" + string("idle") + string("v")
    body += b"\xf9\x07" + b"\x00" + string("freq") + string("v")
    write(os.path.join(out, "idle.rdb"), finish(body))
    cases.append(("idle", 0, "Done loading RDB, keys loaded: 2, keys expired: 0.", 1, 0))
    rec = stream_record(base, b"st:groups")
    for version in (15, 19, 21):
        body = header() + b"\xfe\x00\xfb\x01\x00" + stream_encode(rec, version)
        write(os.path.join(out, "stream%d.rdb" % version), finish(body))
    body = header() + b"\xfe\x00\xfb\x01\x00" + stream_encode(rec, 21)
    write(os.path.join(out, "streamtrunc.rdb"), body[: len(body) - 300])
    cases.append(("streamtrunc", 1, "Stream", 1, 1))
    dup = stream_encode(rec, 21)
    noempty = dict(rec)
    noempty["nodes"] = list(rec["nodes"]) + [rec["nodes"][0]]
    body = header() + b"\xfe\x00\xfb\x01\x00" + stream_encode(noempty, 21)
    write(os.path.join(out, "streamdupnode.rdb"), finish(body))
    cases.append(("streamdupnode", 1, "Listpack re-added with existing key", 1, 1))
    body = header() + b"\xfe\x00\xfb\x01\x00" + dup + b"\x15" + string("other") + dup[1 + len(rec["key"]):]
    write(os.path.join(out, "streamtwo.rdb"), finish(body))
    cases.append(("streamtwo", 0, "Done loading RDB, keys loaded: 2, keys expired: 0.", 1, 0))
    with open(os.path.join(out, "cases.txt"), "w") as fh:
        for name, code, msg, ref, refcode in cases:
            fh.write("%s\t%d\t%s\t%d\t%d\n" % (name, code, msg, ref, refcode))


if __name__ == "__main__":
    main()
