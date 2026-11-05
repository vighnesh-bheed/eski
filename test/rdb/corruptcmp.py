import os
import random
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dataset
import resp

COUNTS = {"PASS": 0, "FAIL": 0}
CONFIGS = ("sanitize-dump-payload", "hash-max-listpack-entries")


def report(ok, name, want=None, got=None):
    if ok:
        COUNTS["PASS"] += 1
        print("PASS\t%s" % name)
    else:
        COUNTS["FAIL"] += 1
        print("FAIL\t%s\t%s\t%s" % (name, str(want)[:300], str(got)[:300]))
    sys.stdout.flush()


def tcl_bytes(s):
    out = bytearray()
    simple = {"n": 10, "t": 9, "r": 13, "a": 7, "b": 8, "f": 12, "v": 11}
    i = 0
    while i < len(s):
        ch = s[i]
        if ch != "\\":
            out += ch.encode("latin-1")
            i += 1
            continue
        nxt = s[i + 1]
        if nxt == "x":
            j = i + 2
            while j < len(s) and j < i + 4 and s[j] in "0123456789abcdefABCDEF":
                j += 1
            out.append(int(s[i + 2:j], 16))
            i = j
        elif nxt in "01234567":
            j = i + 1
            while j < len(s) and j < i + 4 and s[j] in "01234567":
                j += 1
            out.append(int(s[i + 1:j], 8) & 255)
            i = j
        elif nxt in simple:
            out.append(simple[nxt])
            i += 2
        else:
            out += nxt.encode("latin-1")
            i += 2
    return bytes(out)


RESTORE = re.compile(r'\br\s+restore\s+(\S+)\s+(\d+)\s+("(?:[^"\\]|\\.)*"|\$\w+)(\s+replace)?', re.I)
CONFIG = re.compile(r'\br\s+config\s+set\s+(\S+)\s+(\S+)')
VARIABLE = re.compile(r'^set\s+(\w+)\s+("(?:[^"\\]|\\.)*")\s*$', re.M)


def parse_suite(path):
    text = open(path, encoding="latin-1").read()
    variables = {m.group(1): tcl_bytes(m.group(2)[1:-1]) for m in VARIABLE.finditer(text)}
    tests = []
    starts = [m.start() for m in re.finditer(r'(?m)^test \{', text)]
    for n, start in enumerate(starts):
        block = text[start:starts[n + 1] if n + 1 < len(starts) else len(text)]
        name = block[6:block.index("}")]
        steps = []
        for line in block.split("\n"):
            m = CONFIG.search(line)
            if m:
                steps.append(("config", m.group(1), m.group(2)))
            if "set-skip-checksum-validation 1" in line:
                steps.append(("skip",))
            m = RESTORE.search(line)
            if m:
                arg = m.group(3)
                payload = variables.get(arg[1:]) if arg.startswith("$") else tcl_bytes(arg[1:-1])
                if payload is not None:
                    steps.append(("restore", m.group(1), m.group(2), payload, bool(m.group(4))))
        if any(s[0] == "restore" for s in steps):
            tests.append((name, steps, "Bad data format" in block))
    return tests


def norm(r):
    if isinstance(r, resp.Error):
        return "ERR:" + str(r)
    if isinstance(r, bytes):
        return r.decode("latin-1")
    if isinstance(r, list):
        return [norm(x) for x in r]
    return r


def content(c, key):
    t = norm(c.call("TYPE", key))
    if t == "none":
        return ("none",)
    out = [t, norm(c.call("OBJECT", "ENCODING", key))]
    if t == "string":
        out.append(norm(c.call("GET", key)))
    elif t == "list":
        out.append(norm(c.call("LRANGE", key, "0", "-1")))
    elif t == "set":
        out.append(sorted(norm(c.call("SMEMBERS", key))))
    elif t == "zset":
        out.append(norm(c.call("ZRANGE", key, "0", "-1", "WITHSCORES")))
    elif t == "hash":
        flat = norm(c.call("HGETALL", key))
        out.append(sorted(zip(flat[0::2], flat[1::2])))
    elif t == "stream":
        out.append(norm(c.call("XRANGE", key, "-", "+")))
        out.append(norm(c.call("XLEN", key)))
        groups = norm(c.call("XINFO", "GROUPS", key))
        out.append(len(groups) if isinstance(groups, list) else groups)
    return tuple(out)


def alive(c):
    try:
        return c.call("PING") == "PONG"
    except (OSError, EOFError):
        return False


def run_suite(j, r, path):
    tests = parse_suite(path)
    restores = sum(1 for _, steps, _ in tests for s in steps if s[0] == "restore")
    print("INFO\t%d tests with %d RESTORE payloads parsed from %s" % (len(tests), restores, os.path.basename(path)))
    for name, steps, expects_bad in tests:
        modes = ["yes"]
        written = [s[2] for s in steps if s[0] == "config" and s[1] == "sanitize-dump-payload"]
        if expects_bad and (not written or written[-1] == "no"):
            modes.append("no")
        for mode in modes:
            for c in (j, r):
                c.check("FLUSHALL")
                c.check("CONFIG", "SET", "sanitize-dump-payload", mode)
                c.check("CONFIG", "SET", "hash-max-listpack-entries", "128")
                c.check("DEBUG", "SET-SKIP-CHECKSUM-VALIDATION", "0")
            n = 0
            for s in steps:
                if s[0] == "config" and s[1] != "sanitize-dump-payload":
                    a, b = norm(j.call("CONFIG", "SET", s[1], s[2])), norm(r.call("CONFIG", "SET", s[1], s[2]))
                    report(a == b, "%s [sanitize %s] config set %s %s" % (name, mode, s[1], s[2]), b, a)
                elif s[0] == "skip":
                    j.check("DEBUG", "SET-SKIP-CHECKSUM-VALIDATION", "1")
                    r.check("DEBUG", "SET-SKIP-CHECKSUM-VALIDATION", "1")
                elif s[0] == "restore":
                    n += 1
                    args = ["RESTORE", s[1], s[2], s[3]] + (["REPLACE"] if s[4] else [])
                    a, b = norm(j.call(*args)), norm(r.call(*args))
                    label = "%s [sanitize %s] restore %d" % (name, mode, n)
                    report(a == b, label, b, a)
                    if a == "OK" and b == "OK" and mode == "yes":
                        x, y = content(j, s[1]), content(r, s[1])
                        report(x == y, label + " content", y, x)
            if not alive(j) or not alive(r):
                report(False, "%s [sanitize %s] both servers alive" % (name, mode), alive(r), alive(j))
                return False
    for c in (j, r):
        c.check("CONFIG", "SET", "hash-max-listpack-entries", "128")
    return True


def enc_len(n):
    if n < 64:
        return bytes([n])
    if n < 16384:
        return bytes([64 | (n >> 8), n & 255])
    return b"\x80" + n.to_bytes(4, "big")


def stream_payload(node, over):
    out = bytearray([21])

    def field(name, value):
        out.extend(over.get(name, enc_len(value)))

    def raw_id(ms, seq):
        out.extend(ms.to_bytes(8, "big") + seq.to_bytes(8, "big"))

    field("nodes", 1)
    out.extend(enc_len(16))
    raw_id(1, 1)
    out.extend(enc_len(len(node)) + node)
    for name, value in (("length", 2), ("last_ms", 1), ("last_seq", 2), ("first_ms", 1), ("first_seq", 1), ("maxdel_ms", 0), ("maxdel_seq", 0), ("added", 2), ("groups", 1)):
        field(name, value)
    out.extend(b"\x01g")
    for name, value in (("cg_ms", 1), ("cg_seq", 2), ("cg_read", 2), ("pel", 1)):
        field(name, value)
    raw_id(1, 2)
    out.extend((1700000000000).to_bytes(8, "little"))
    field("pel_count", 3)
    field("consumers", 1)
    out.extend(b"\x01c" + (1700000000000).to_bytes(8, "little") * 2)
    field("cpel", 1)
    raw_id(1, 2)
    out.extend(b"\x0c\x00" + bytes(8))
    return bytes(out)


def run_stream_fields(j, r):
    for c in (j, r):
        c.check("FLUSHALL")
        c.check("CONFIG", "SET", "sanitize-dump-payload", "yes")
        c.check("DEBUG", "SET-SKIP-CHECKSUM-VALIDATION", "1")
        c.check("XADD", "s", "1-1", "a", "1")
        c.check("XADD", "s", "1-2", "a", "2")
    p = r.check("DUMP", "s")
    node = p[20:20 + p[19]]
    names = ("nodes", "length", "last_ms", "last_seq", "first_ms", "first_seq", "maxdel_ms", "maxdel_seq", "added", "groups", "cg_ms", "cg_seq", "cg_read", "pel", "pel_count", "consumers", "cpel")
    for name in names:
        for raw in (b"\x82", b"\xbf", b"\xc0", b"\xc1", b"\xc5"):
            payload = stream_payload(node, {name: raw})
            a = norm(j.call("RESTORE", "k", "0", payload, "REPLACE"))
            b = norm(r.call("RESTORE", "k", "0", payload, "REPLACE"))
            same = a == b
            if same and a == "OK":
                x = norm(j.call("XINFO", "STREAM", "k", "FULL"))
                y = norm(r.call("XINFO", "STREAM", "k", "FULL"))
                same = x == y
                a, b = x, y
            report(same, "stream %s length field written as %s" % (name, raw.hex()), b, a)
    for c in (j, r):
        c.check("DEBUG", "SET-SKIP-CHECKSUM-VALIDATION", "0")
        c.check("CONFIG", "SET", "sanitize-dump-payload", "no")
        c.check("FLUSHALL")


def corrupt(payload, rng):
    p = bytearray(payload)
    count = 2 if rng.random() > 0.9 else 1
    for _ in range(count):
        p[rng.randrange(len(p))] = rng.randrange(255)
    return bytes(p)


def run_fuzz(j, r, cycles, seed, extra):
    rng = random.Random(seed)
    for c in (j, r):
        c.check("FLUSHALL")
        c.check("CONFIG", "SET", "sanitize-dump-payload", "yes")
        c.check("DEBUG", "SET-SKIP-CHECKSUM-VALIDATION", "1")
        dataset.build(c)
        c.check("SELECT", "0")
    keys = sorted(x.decode("latin-1") for x in r.check("KEYS", "*"))
    corpus = [(k, p) for k, p in ((k, r.check("DUMP", k)) for k in keys) if p is not None]
    corpus += extra
    stats = {"rejected": 0, "accepted": 0, "differ": 0}
    for cycle in range(cycles):
        k, p = corpus[rng.randrange(len(corpus))]
        bad = corrupt(p, rng)
        try:
            a = norm(j.call("RESTORE", "_fz", "0", bad, "REPLACE"))
        except (OSError, EOFError):
            report(False, "fuzz cycle %d from %s payload %s left eski alive" % (cycle, k, bad.hex()), "alive", "connection lost")
            return
        try:
            b = norm(r.call("RESTORE", "_fz", "0", bad, "REPLACE"))
        except (OSError, EOFError):
            report(False, "fuzz cycle %d from %s payload %s left the reference alive" % (cycle, k, bad.hex()), "alive", "connection lost")
            return
        if a != b:
            stats["differ"] += 1
            report(False, "fuzz cycle %d from %s payload %s" % (cycle, k, bad.hex()), b, a)
        elif a == "OK":
            stats["accepted"] += 1
            try:
                x, y = content(j, "_fz"), content(r, "_fz")
            except (OSError, EOFError):
                report(False, "fuzz cycle %d from %s reading payload %s" % (cycle, k, bad.hex()), "alive", "connection lost")
                return
            if x != y:
                stats["differ"] += 1
                report(False, "fuzz cycle %d from %s content of payload %s" % (cycle, k, bad.hex()), y, x)
        else:
            stats["rejected"] += 1
        j.call("DEL", "_fz")
        r.call("DEL", "_fz")
        if not alive(j) or not alive(r):
            report(False, "fuzz cycle %d from %s payload %s left both servers alive" % (cycle, k, bad.hex()), alive(r), alive(j))
            return
    report(stats["differ"] == 0, "fuzz %d cycles over %d keys and suite payloads: %d rejected by both, %d accepted by both with the same content" % (cycles, len(corpus), stats["rejected"], stats["accepted"]), 0, stats["differ"])
    for c in (j, r):
        c.check("DEBUG", "SET-SKIP-CHECKSUM-VALIDATION", "0")
        c.check("CONFIG", "SET", "sanitize-dump-payload", "no")
        c.check("FLUSHALL")


def main():
    jp, rp, suite = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    cycles = int(sys.argv[4]) if len(sys.argv) > 4 else 2000
    seed = int(sys.argv[5]) if len(sys.argv) > 5 else 1
    j = resp.Client(jp)
    r = resp.Client(rp)
    path = os.path.join(suite, "tests", "integration", "corrupt-dump.tcl")
    if run_suite(j, r, path):
        run_stream_fields(j, r)
        extra = []
        for name, steps, _ in parse_suite(path):
            extra += [("suite payload %d of %s" % (n, name), x[3]) for n, x in enumerate(s for s in steps if s[0] == "restore")]
        run_fuzz(j, r, cycles, seed, extra)
    print("SUMMARY\t%d passed, %d failed" % (COUNTS["PASS"], COUNTS["FAIL"]))


if __name__ == "__main__":
    main()
