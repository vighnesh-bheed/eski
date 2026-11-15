import argparse
import json
import os
import random
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HOST = "127.0.0.1"
HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")


class Conn:
    def __init__(self, port, timeout=120):
        self.s = socket.create_connection((HOST, port), timeout=timeout)
        self.buf = b""

    def close(self):
        self.s.close()

    def send(self, cmds):
        out = bytearray()
        for c in cmds:
            out += b"*%d\r\n" % len(c)
            for a in c:
                if isinstance(a, str):
                    a = a.encode()
                elif isinstance(a, (int, float)):
                    a = str(a).encode()
                out += b"$%d\r\n%s\r\n" % (len(a), a)
        self.s.sendall(out)

    def fill(self):
        d = self.s.recv(1 << 20)
        if not d:
            raise EOFError("the server closed the connection")
        self.buf += d

    def line(self, at):
        while True:
            i = self.buf.find(b"\r\n", at)
            if i >= 0:
                return i
            self.fill()

    def end(self, at):
        e = self.line(at)
        kind = self.buf[at:at + 1]
        head = self.buf[at + 1:e]
        if kind in b"+-:,_#(":
            return e + 2
        if kind in b"$=!":
            n = int(head)
            if n < 0:
                return e + 2
            while len(self.buf) < e + 2 + n + 2:
                self.fill()
            return e + 2 + n + 2
        if kind in b"*~>%|":
            n = int(head)
            if n < 0:
                return e + 2
            if kind in b"%|":
                n *= 2
            p = e + 2
            for _ in range(n):
                p = self.end(p)
            return p
        raise ValueError("unexpected reply %r" % self.buf[at:at + 40])

    def read(self):
        stop = self.end(0)
        r = self.buf[:stop]
        self.buf = self.buf[stop:]
        return r

    def call(self, *c):
        self.send([c])
        return self.read()

    def many(self, cmds, batch=2000):
        out = []
        for i in range(0, len(cmds), batch):
            part = cmds[i:i + batch]
            self.send(part)
            out += [self.read() for _ in part]
        return out


def bulk(raw):
    e = raw.index(b"\r\n")
    n = int(raw[1:e])
    if n < 0:
        return None
    return raw[e + 2:e + 2 + n]


def array_bulks(raw):
    e = raw.index(b"\r\n")
    n = int(raw[1:e])
    out = []
    at = e + 2
    for _ in range(max(n, 0)):
        nl = raw.index(b"\r\n", at)
        ln = int(raw[at + 1:nl])
        out.append(raw[nl + 2:nl + 2 + ln])
        at = nl + 2 + ln + 2
    return out


def parse(raw, at=0):
    e = raw.index(b"\r\n", at)
    kind = raw[at:at + 1]
    head = raw[at + 1:e]
    if kind in b"+-":
        return head, e + 2
    if kind == b":":
        return int(head), e + 2
    if kind == b"$":
        n = int(head)
        if n < 0:
            return None, e + 2
        return raw[e + 2:e + 2 + n], e + 2 + n + 2
    n = int(head)
    out = []
    p = e + 2
    for _ in range(max(n, 0)):
        v, p = parse(raw, p)
        out.append(v)
    return out, p


class Server:
    def __init__(self, binary, port, folder, extra=()):
        self.binary = binary
        self.port = port
        self.folder = folder
        self.extra = list(extra)
        self.proc = None

    def start(self, expect_failure=False):
        os.makedirs(self.folder, exist_ok=True)
        log = open(os.path.join(self.folder, "server.log"), "ab")
        args = [self.binary, "--port", str(self.port), "--bind", HOST, "--dir", self.folder, "--save", "", "--enable-debug-command", "yes"]
        if "--appendonly" not in self.extra:
            args += ["--appendonly", "no"]
        self.proc = subprocess.Popen(args + self.extra, stdout=log, stderr=log)
        for _ in range(600):
            if self.proc.poll() is not None:
                if expect_failure:
                    return None
                raise RuntimeError("the server on port %d exited with %d" % (self.port, self.proc.returncode))
            try:
                c = Conn(self.port)
                if c.call("PING") == b"+PONG\r\n":
                    if expect_failure:
                        self.stop()
                        raise RuntimeError("the server on port %d started from a file it should refuse" % self.port)
                    return c
                c.close()
            except OSError:
                pass
            time.sleep(0.05)
        raise RuntimeError("the server on port %d did not answer" % self.port)

    def stop(self):
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc = None

    def log(self):
        try:
            with open(os.path.join(self.folder, "server.log"), "rb") as f:
                return f.read().decode("utf-8", "replace")
        except OSError:
            return ""


SHAPES = [
    ("rt:q8", "Q8", 16, None, 16, 900, False),
    ("rt:fp32", "NOQUANT", 12, None, 8, 900, False),
    ("rt:bin4", "BIN", 8, None, 4, 900, True),
    ("rt:bin16", "BIN", 16, None, 16, 700, True),
    ("rt:q8m4", "Q8", 3, None, 4, 600, False),
    ("rt:fp32m32", "NOQUANT", 32, None, 32, 400, False),
    ("rt:reduce", "Q8", 12, 6, 6, 500, False),
]


def vector(r, dim, coarse):
    if coarse:
        return [str(r.randrange(3) - 1) for _ in range(dim)]
    return ["%.3f" % r.uniform(-1, 1) for _ in range(dim)]


def vadd(key, quant, dim, reduce, m, values, name, attr=None, ef=None):
    c = ["VADD", key]
    if reduce:
        c += ["REDUCE", str(reduce)]
    c += ["VALUES", str(dim)] + values + [name, quant, "M", str(m)]
    if ef:
        c += ["EF", str(ef)]
    if attr is not None:
        c += ["SETATTR", attr]
    return c


def writes(r, rounds, existing_only=False):
    cmds = []
    for key, quant, dim, reduce, m, n, coarse in SHAPES:
        for _ in range(rounds if existing_only else n * 2):
            k = r.random()
            name = "n%d" % r.randrange(n)
            if k < 0.55:
                attr = json.dumps({"g": r.randrange(3)}) if r.random() < 0.5 else None
                cmds.append(vadd(key, quant, dim, reduce, m, vector(r, dim, coarse), name, attr))
            elif k < 0.8:
                cmds.append(["VREM", key, name])
            else:
                cmds.append(["VSETATTR", key, name, json.dumps({"g": r.randrange(3)}) if r.random() < 0.8 else ""])
    return cmds


def build(c, seed):
    r = random.Random(seed)
    got = c.many(writes(r, 0))
    errors = [x for x in got if x.startswith(b"-")]
    if errors:
        raise RuntimeError("the build was refused: %r" % errors[:3])


def wide(c, key, n, drop):
    r = random.Random(n)
    cmds = []
    for i in range(n):
        cmds.append(vadd(key, "Q8", 2, None, 4, vector(r, 2, False), "w%d" % i, ef=1))
    for name in drop:
        cmds.append(["VREM", key, name])
    got = c.many(cmds)
    if any(x.startswith(b"-") for x in got):
        raise RuntimeError("the wide build was refused")


def probe_set(c, key, r, sample=None):
    names = [x.decode() for x in array_bulks(c.call("VRANGE", key, "-", "+"))]
    if sample is not None and len(names) > sample:
        pick = sorted(r.sample(names, sample))
    else:
        pick = names
    dim = int(c.call("VDIM", key)[1:-2])
    info = c.call("VINFO", key)
    input_dim = dim
    parts, _ = parse(info)
    for i in range(0, len(parts) - 1, 2):
        if parts[i] == b"projection-input-dim" and int(parts[i + 1] or 0) > 0:
            input_dim = int(parts[i + 1])
    coarse = b"bin" in info
    cmds = [["VCARD", key], ["VDIM", key], ["VRANGE", key, "-", "+", "7"], ["VRANGE", key, "[n1", "(n3"]]
    for name in pick:
        cmds += [["VEMB", key, name], ["VEMB", key, name, "RAW"], ["VGETATTR", key, name], ["VISMEMBER", key, name], ["VLINKS", key, name], ["VLINKS", key, name, "WITHSCORES"]]
    for i in range(min(400, 4 * len(pick))):
        q = ["VSIM", key]
        if r.random() < 0.25:
            q += ["ELE", r.choice(names)]
        else:
            q += ["VALUES", str(input_dim)] + vector(r, input_dim, coarse)
        q += ["COUNT", str(r.choice([1, 5, 10, 50]))]
        ef = r.choice([0, 10, 40, 200])
        if ef:
            q += ["EF", str(ef)]
        if r.random() < 0.3:
            q += ["FILTER", ".g == 1"]
            fe = r.choice([0, 5, 30])
            if fe:
                q += ["FILTER-EF", str(fe)]
        if r.random() < 0.2:
            q += ["EPSILON", "0.3"]
        if r.random() < 0.15:
            q.append("TRUTH")
        if r.random() < 0.5:
            q.append("WITHSCORES")
        if r.random() < 0.3:
            q.append("WITHATTRIBS")
        cmds.append(q)
    return cmds


def masked(cmd, reply):
    if cmd[0] == "VINFO":
        parts = reply.split(b"\r\n")
        for i, x in enumerate(parts):
            if x.endswith(b"vset-uid") and i + 1 < len(parts):
                parts[i + 1] = b":_"
        return b"\r\n".join(parts)
    return reply


def corpus(port, keys, seed, sample=None):
    out = {}
    c2 = Conn(port)
    c3 = Conn(port)
    c3.call("HELLO", "3")
    try:
        for key in keys:
            r = random.Random("%s:%s" % (seed, key))
            cmds = probe_set(c2, key, r, sample)
            cmds.append(["VINFO", key])
            r2 = c2.many(cmds)
            resp3 = [x for x in cmds if x[0] in ("VLINKS", "VSIM", "VINFO", "VEMB")][:300]
            r3 = c3.many(resp3)
            out[key] = ([(tuple(a), masked(a, b)) for a, b in zip(cmds, r2)], [(tuple(a), masked(a, b)) for a, b in zip(resp3, r3)], bulk(c2.call("DUMP", key)))
    finally:
        c2.close()
        c3.close()
    return out


def same_corpus(name, a, b, failures):
    for key in a:
        if key not in b:
            failures.append("%s: %s is missing" % (name, key))
            continue
        ra2, ra3, da = a[key]
        rb2, rb3, db = b[key]
        diff = [(x[0], x[1], y[1]) for x, y in zip(ra2 + ra3, rb2 + rb3) if x != y]
        if len(ra2) != len(rb2) or len(ra3) != len(rb3):
            failures.append("%s: %s probes differ in number" % (name, key))
        if diff:
            cmd, x, y = diff[0]
            failures.append("%s: %s has %d differing replies, first %s: %r against %r" % (name, key, len(diff), " ".join(cmd)[:120], x[:160], y[:160]))
        if da != db:
            failures.append("%s: %s serialises differently (%d and %d bytes)" % (name, key, len(da or b""), len(db or b"")))


def keys_of(c):
    return sorted(x.decode() for x in array_bulks(c.call("KEYS", "rt:*")))


def wait_idle(c, field):
    for _ in range(2400):
        info = c.call("INFO", "persistence")
        if (field + ":0").encode() in info:
            return
        time.sleep(0.05)
    raise RuntimeError("%s did not finish" % field)


def path_pair(args, name, original, make, seed, sample_keys, failures, report):
    other_server, other = make()
    try:
        keys = keys_of(original)
        if keys_of(other) != keys:
            failures.append("%s: the key list differs" % name)
        plain = [k for k in keys if k not in sample_keys]
        a = corpus(args.port, plain, seed)
        b = corpus(other_server.port, plain, seed)
        a.update(corpus(args.port, sample_keys, seed, 300))
        b.update(corpus(other_server.port, sample_keys, seed, 300))
        same_corpus(name + " after the load", a, b, failures)
        report.append("%s: %d keys, %d replies compared after the load" % (name, len(a), sum(len(v[0]) + len(v[1]) for v in a.values())))
        w = writes(random.Random(seed + 1), 300, existing_only=True)
        ra = original.many(w)
        rb = other.many(w)
        if ra != rb:
            failures.append("%s: the same further writes answered differently" % name)
        a = corpus(args.port, plain, seed + 2)
        b = corpus(other_server.port, plain, seed + 2)
        same_corpus(name + " after further writes", a, b, failures)
        report.append("%s: %d further writes, %d replies compared afterwards" % (name, len(w), sum(len(v[0]) + len(v[1]) for v in a.values())))
    finally:
        other.close()
        other_server.stop()


def check_refused(name, server, failures, needle):
    os.makedirs(server.folder, exist_ok=True)
    log = open(os.path.join(server.folder, "server.log"), "ab")
    args = [server.binary, "--port", str(server.port), "--bind", HOST, "--dir", server.folder, "--save", "", "--appendonly", "no"] + server.extra
    proc = subprocess.Popen(args, stdout=log, stderr=log)
    try:
        code = proc.wait(60)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        failures.append("%s: the server kept running" % name)
        return
    if code == 0:
        failures.append("%s: the server exited cleanly instead of refusing the file" % name)
    elif needle not in server.log():
        failures.append("%s: the refusal does not say %r" % (name, needle))


def v1_expected(c, failures, name):
    with open(os.path.join(FIXTURES, "v1-expected.json")) as f:
        expect = json.load(f)
    for key, rows in sorted(expect.items()):
        cmds = [row[0] for row in rows]
        got = c.many(cmds)
        diff = [(cmd, bytes.fromhex(want), have) for (cmd, want), have in zip(rows, got) if bytes.fromhex(want) != have]
        if diff:
            cmd, want, have = diff[0]
            failures.append("%s: %s has %d differing replies, first %s: %r against %r" % (name, key, len(diff), " ".join(cmd)[:100], want[:120], have[:120]))


def varint(v):
    out = bytearray()
    while v >= 0x80:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return bytes(out)


def skip_varint(b, at):
    while b[at] & 0x80:
        at += 1
    return at + 1


def rdb_len(n):
    if n < 1 << 6:
        return bytes([n])
    if n < 1 << 14:
        return bytes([0x40 | (n >> 8), n & 0xFF])
    if n < 1 << 32:
        return b"\x80" + n.to_bytes(4, "big")
    return b"\x81" + n.to_bytes(8, "big")


def read_rdb_len(b, at):
    x = b[at]
    if x >> 6 == 0:
        return x & 0x3F, at + 1
    if x >> 6 == 1:
        return ((x & 0x3F) << 8) | b[at + 1], at + 2
    if x == 0x80:
        return int.from_bytes(b[at + 1:at + 5], "big"), at + 5
    return int.from_bytes(b[at + 1:at + 9], "big"), at + 9


def unwrap(dump):
    module, at = read_rdb_len(dump, 1)
    _, at = read_rdb_len(dump, at)
    n, at = read_rdb_len(dump, at)
    return module, dump[at:at + n], dump[at + n:]


def lzf_literals(data):
    out = bytearray()
    for i in range(0, len(data), 32):
        chunk = data[i:i + 32]
        out.append(len(chunk) - 1)
        out += chunk
    return bytes(out)


def wrap(module, payload, tail, lzf=False):
    out = b"\x07" + rdb_len(module) + rdb_len(5)
    if lzf:
        packed = lzf_literals(payload)
        out += b"\xc3" + rdb_len(len(packed)) + rdb_len(len(payload)) + packed
    else:
        out += rdb_len(len(payload)) + payload
    return out + tail


def v2_counter(payload, value):
    at = 6
    for _ in range(3):
        at = skip_varint(payload, at)
    if payload[4] & 1:
        at = skip_varint(payload, at)
    at = skip_varint(payload, at)
    return payload[:at] + varint(value) + payload[skip_varint(payload, at):]


def v1_field(payload, index, value):
    at = 5
    for _ in range(index):
        at = skip_varint(payload, at)
    return payload[:at] + varint(value) + payload[skip_varint(payload, at):]


def refused(reply):
    return reply.startswith(b"-")


def format_checks(binary, port, work, fixtures_loaded, failures, report):
    server = Server(binary, port, os.path.join(work, "format"))
    c = server.start()
    try:
        c.call("DEBUG", "SET-SKIP-CHECKSUM-VALIDATION", "1")
        c.many([["VADD", "fm", "VALUES", "4", str(0.1 * i), "0.2", "0.3", str(0.4 + i), "e%d" % i] for i in range(5)])
        module, payload, tail = unwrap(bulk(c.call("DUMP", "fm")))
        if c.call("RESTORE", "plain", "0", wrap(module, payload, tail)) != b"+OK\r\n":
            failures.append("format: a payload re-wrapped by the driver is refused, so the other checks mean nothing")
            return
        for value in (1 << 63, (1 << 63) + 1, (1 << 64) - 1):
            reply = c.call("RESTORE", "wrap%d" % value, "0", wrap(module, v2_counter(payload, value), tail))
            if not refused(reply) or c.call("EXISTS", "wrap%d" % value) != b":0\r\n":
                failures.append("format: a node counter of %d was not refused: %r" % (value, reply))
        reply = c.call("RESTORE", "lzf", "0", wrap(module, payload, tail, lzf=True))
        if not refused(reply) or c.call("EXISTS", "lzf") != b":0\r\n":
            failures.append("format: a payload stored as a compressed string was not refused: %r" % reply)
        reply = c.call("RESTORE", "near", "0", wrap(module, v2_counter(payload, (1 << 63) - 3), tail))
        if reply != b"+OK\r\n":
            failures.append("format: a node counter just below the limit was refused: %r" % reply)
        else:
            held = 0
            stopped = 0
            for i in range(5):
                added = c.call("VADD", "near", "VALUES", "4", "0.9", str(0.1 * i), "0.1", "0.1", "late%d" % i)
                if refused(added):
                    stopped += 1
                else:
                    held += 1
                again = c.call("RESTORE", "near-copy%d" % i, "0", bulk(c.call("DUMP", "near")))
                if again != b"+OK\r\n":
                    failures.append("format: after write %d at the node counter limit the set's own DUMP is refused: %r" % (i, again))
            if held == 0 or stopped == 0:
                failures.append("format: at the node counter limit %d writes were accepted and %d refused" % (held, stopped))
        edits = 0
        for name in ("q8", "fp32", "bin", "reduce") if fixtures_loaded else ():
            with open(os.path.join(FIXTURES, "v1-dump-%s.bin" % name), "rb") as fh:
                dump = fh.read()
            old_module, old_payload, old_tail = unwrap(dump)
            for label, edited in (("M 4097", v1_field(old_payload, 2, 4097)), ("M 5000", v1_field(old_payload, 2, 5000)), ("a node counter of 2^63", v1_field(old_payload, 4, 1 << 63))):
                edit_key = "old-edit:%s:%s" % (name, label)
                reply = c.call("RESTORE", edit_key, "0", wrap(old_module, edited, old_tail))
                if not refused(reply) or c.call("EXISTS", edit_key) != b":0\r\n":
                    failures.append("format: the %s version 1 payload with %s was not refused: %r" % (name, label, reply))
            edits += 3
        report.append("format: node counter limit, compressed payload string and %d version 1 edits checked on a server" % edits)
    finally:
        c.close()
        server.stop()


def seed_dump(binary, port, work, name, extra):
    server = Server(binary, port, os.path.join(work, name), extra)
    c = server.start()
    try:
        r = random.Random(5)
        got = c.many([["VADD", "seeded", "VALUES", "4"] + ["%.3f" % r.uniform(-1, 1) for _ in range(4)] + ["e%d" % i] for i in range(700)])
        if any(refused(x) for x in got):
            raise RuntimeError("the seed build was refused")
        return bulk(c.call("DUMP", "seeded"))
    finally:
        c.close()
        server.stop()


def seed_checks(binary, port, work, failures, report):
    pinned = ["--label-stream-seed", "77"]
    one = seed_dump(binary, port, work, "seed1", pinned)
    two = seed_dump(binary, port, work, "seed2", pinned)
    if one != two:
        failures.append("seed: two servers started with the same label-stream-seed and given the same commands built different graphs")
    free_one = seed_dump(binary, port, work, "seed3", [])
    free_two = seed_dump(binary, port, work, "seed4", [])
    if free_one == free_two:
        failures.append("seed: two servers started without the setting built the same graph")
    other = seed_dump(binary, port, work, "seed5", ["--label-stream-seed", "78"])
    if other == one:
        failures.append("seed: two different label-stream-seed values built the same graph")
    report.append("seed: equal graphs under one label-stream-seed, different graphs under two values and without the setting")


def write_back(f, key, tag, failures):
    info, _ = parse(f.call("VINFO", key))
    fields = {info[j]: info[j + 1] for j in range(0, len(info) - 1, 2)}
    quant = {b"int8": "Q8", b"f32": "NOQUANT", b"bin": "BIN"}.get(fields.get(b"quant-type"))
    dim = fields.get(b"vector-dim")
    input_dim = fields.get(b"projection-input-dim") or 0
    m = fields.get(b"hnsw-m")
    if quant is None or not dim or not m:
        return
    width = input_dim if input_dim else dim
    r = random.Random(tag)
    cmds = []
    for k in range(6):
        cmd = ["VADD", key]
        if input_dim:
            cmd += ["REDUCE", str(dim)]
        cmd += ["VALUES", str(width)] + ["%.3f" % r.uniform(-1, 1) for _ in range(width)] + ["late%d" % k, quant, "M", str(m)]
        cmds.append(cmd)
    cmds.append(["VREM", key, "late1"])
    cmds.append(["VSETATTR", key, "late2", '{"g":1}'])
    f.many(cmds)
    again = f.call("RESTORE", key + ":again", "0", bulk(f.call("DUMP", key)), "REPLACE")
    if again != b"+OK\r\n":
        failures.append("fuzz: after an accepted payload and ordinary writes the set's own DUMP is refused (%s): %r" % (key, again[:80]))
    f.call("DEL", key + ":again")


def used_memory(c):
    for line in c.call("INFO", "memory").decode().splitlines():
        if line.startswith("used_memory:"):
            return int(line.split(":")[1])


def admission_checks(binary, port, work, failures, report):
    server = Server(binary, port, os.path.join(work, "admission"))
    c = server.start()
    try:
        r = random.Random(3)
        c.many([["VADD", "big", "VALUES", "2"] + ["%.3f" % r.uniform(-1, 1) for _ in range(2)] + ["e%d" % i, "M", "64"] for i in range(5000)])
        dump = bulk(c.call("DUMP", "big"))
        c.call("DEL", "big")
        base = used_memory(c)
        c.call("CONFIG", "SET", "maxmemory-policy", "allkeys-lru")
        c.call("CONFIG", "SET", "maxmemory", str(base + len(dump) + 100000))
        reply = c.call("RESTORE", "small", "0", dump)
        if reply != b"-OOM command not allowed when used memory > 'maxmemory'.\r\n" or c.call("EXISTS", "small") != b":0\r\n":
            failures.append("admission: a payload whose reservation exceeds maxmemory was not refused as a write over the limit: %r" % reply)
        c.call("CONFIG", "SET", "maxmemory", "0")
        c.call("CONFIG", "SET", "maxmemory", str(base + 8 * 1024 * 1024))
        c.many([["SET", "s%d" % i, "x" * 1000] for i in range(20000)])
        if c.call("SET", "probe", "x" * 1000) != b"+OK\r\n":
            failures.append("admission: a plain SET at the memory limit was refused")
        reply = c.call("RESTORE", "atlimit", "0", dump)
        if reply != b"+OK\r\n":
            failures.append("admission: a payload within the limits was refused at the memory limit: %r" % reply)
        report.append("admission: refused with the out-of-memory reply when the reservation exceeds maxmemory, accepted at the memory limit")
    finally:
        c.close()
        server.stop()


def main():
    ap = argparse.ArgumentParser(description="Reload vector sets through every persistence path and compare every reply before and after.")
    ap.add_argument("--server", default="bin/eski")
    ap.add_argument("--port", type=int, default=int(os.environ.get("ESKI_VSET_PORT", "6491")))
    ap.add_argument("--wide", action="store_true", help="also build graphs of 65,535 and 65,536 slots")
    ap.add_argument("--fuzz", type=int, default=600, help="mutated payloads to restore")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    binary = os.path.abspath(args.server)
    work = tempfile.mkdtemp(prefix="eski-graph-roundtrip.")
    failures = []
    report = []
    servers = []
    try:
        origin = Server(binary, args.port, os.path.join(work, "origin"))
        servers.append(origin)
        c = origin.start()
        build(c, 20261110)
        sample = []
        if args.wide:
            wide(c, "rt:wide65535", 65535, [])
            wide(c, "rt:wide65536", 65536, ["w65535", "w100", "w65534"])
            sample = ["rt:wide65535", "rt:wide65536"]
        report.append("built %d vector sets" % len(keys_of(c)))

        def from_snapshot():
            assert c.call("SAVE") == b"+OK\r\n"
            s = Server(binary, args.port + 1, os.path.join(work, "snapshot"))
            os.makedirs(s.folder, exist_ok=True)
            shutil.copyfile(os.path.join(origin.folder, "dump.rdb"), os.path.join(s.folder, "dump.rdb"))
            servers.append(s)
            return s, s.start()

        path_pair(args, "snapshot", c, from_snapshot, 11, sample, failures, report)

        def from_dump():
            s = Server(binary, args.port + 2, os.path.join(work, "restore"))
            servers.append(s)
            t = s.start()
            for key in keys_of(c):
                reply = t.call("RESTORE", key, "0", bulk(c.call("DUMP", key)))
                if reply != b"+OK\r\n":
                    failures.append("restore: %s answered %r" % (key, reply))
            return s, t

        path_pair(args, "dump and restore", c, from_dump, 21, sample, failures, report)

        def from_rewrite():
            assert c.call("CONFIG", "SET", "aof-use-rdb-preamble", "no") == b"+OK\r\n"
            assert c.call("CONFIG", "SET", "appendonly", "yes") == b"+OK\r\n"
            wait_idle(c, "aof_rewrite_in_progress")
            wait_idle(c, "aof_rewrite_scheduled")
            assert c.call("BGREWRITEAOF").startswith(b"+")
            wait_idle(c, "aof_rewrite_in_progress")
            s = Server(binary, args.port + 3, os.path.join(work, "rewrite"), ["--appendonly", "yes", "--aof-use-rdb-preamble", "no"])
            shutil.copytree(os.path.join(origin.folder, "appendonlydir"), os.path.join(s.folder, "appendonlydir"))
            base = [f for f in os.listdir(os.path.join(s.folder, "appendonlydir")) if ".base." in f]
            with open(os.path.join(s.folder, "appendonlydir", base[0]), "rb") as f:
                text = f.read()
            if b"$7\r\nRESTORE\r\n" not in text or b"VADD" in text:
                failures.append("rewrite: the base does not hold the sets as RESTORE commands")
            servers.append(s)
            return s, s.start()

        path_pair(args, "command-form rewrite", c, from_rewrite, 31, sample, failures, report)
        assert c.call("CONFIG", "SET", "appendonly", "no") == b"+OK\r\n"

        fz = Server(binary, args.port + 4, os.path.join(work, "fuzz"))
        servers.append(fz)
        f = fz.start()
        f.call("DEBUG", "SET-SKIP-CHECKSUM-VALIDATION", "1")
        r = random.Random(7)
        dumps = [bulk(c.call("DUMP", k)) for k in keys_of(c) if k not in sample]
        accepted = refused = 0
        for i in range(args.fuzz):
            d = bytearray(r.choice(dumps))
            body = len(d) - 10
            kind = r.randrange(4)
            if kind == 0:
                d[r.randrange(body)] ^= 1 << r.randrange(8)
            elif kind == 1:
                for _ in range(1 + r.randrange(6)):
                    d[r.randrange(body)] = r.randrange(256)
            elif kind == 2:
                at = r.randrange(body)
                d[at:at + 1 + r.randrange(8)] = b"\xff" * (1 + r.randrange(8))
            else:
                cut = r.randrange(20, body)
                d = d[:cut] + d[-10:]
            reply = f.call("RESTORE", "fz:%d" % i, "0", bytes(d), "REPLACE")
            if reply == b"+OK\r\n":
                accepted += 1
                f.many([["VCARD", "fz:%d" % i], ["VSIM", "fz:%d" % i, "ELE", "n1", "COUNT", "5"]])
                write_back(f, "fz:%d" % i, i, failures)
                f.call("DEL", "fz:%d" % i)
            elif reply.startswith(b"-"):
                refused += 1
            else:
                failures.append("fuzz: unexpected reply %r" % reply[:80])
        if f.call("PING") != b"+PONG\r\n":
            failures.append("fuzz: the server stopped answering")
        report.append("fuzz: %d mutated payloads restored with the checksum disabled, %d refused, %d accepted and written to, server alive" % (args.fuzz, refused, accepted))
        f.close()
        fz.stop()

        corrupt = Server(binary, args.port + 5, os.path.join(work, "corrupt"), ["--rdbchecksum", "no"])
        servers.append(corrupt)
        k = corrupt.start()
        k.call("RESTORE", "rt:only", "0", dumps[0])
        assert k.call("SAVE") == b"+OK\r\n"
        k.close()
        corrupt.stop()
        path = os.path.join(corrupt.folder, "dump.rdb")
        with open(path, "rb") as fh:
            good = fh.read()
        at = good.index(b"EVS")
        flips = 0
        for offset, mask in ((3, 0x40), (4, 0x40), (5, 0x40)):
            bad = bytearray(good)
            bad[at + offset] ^= mask
            with open(path, "wb") as fh:
                fh.write(bad)
            check_refused("snapshot corrupted at payload byte %d" % offset, corrupt, failures, "vector set")
            flips += 1
        _, held, _ = unwrap(dumps[0])
        plain_string = rdb_len(len(held)) + held
        packed = lzf_literals(held)
        compressed = b"\xc3" + rdb_len(len(packed)) + rdb_len(len(held)) + packed
        if good.count(plain_string) != 1:
            failures.append("snapshot: the payload string is not found once in the file")
        else:
            with open(path, "wb") as fh:
                fh.write(good.replace(plain_string, compressed))
            check_refused("snapshot with the payload stored as a compressed string", corrupt, failures, "plain string")
            flips += 1
        with open(path, "wb") as fh:
            fh.write(good)
        report.append("snapshot: %d corrupted files written with the checksum off, every start refused" % flips)

        old = Server(binary, args.port + 6, os.path.join(work, "v1"))
        servers.append(old)
        o = old.start()
        fixtures_loaded = True
        for name in ("q8", "fp32", "bin", "reduce"):
            with open(os.path.join(FIXTURES, "v1-dump-%s.bin" % name), "rb") as fh:
                reply = o.call("RESTORE", "fx:%s" % name, "0", fh.read())
            if reply != b"+OK\r\n":
                fixtures_loaded = False
                failures.append("version 1: RESTORE of the %s fixture answered %r" % (name, reply))
        v1_expected(o, failures, "version 1 restore")
        o.close()
        old.stop()
        snap = Server(binary, args.port + 7, os.path.join(work, "v1-file"))
        servers.append(snap)
        os.makedirs(snap.folder, exist_ok=True)
        shutil.copyfile(os.path.join(FIXTURES, "v1-snapshot.rdb"), os.path.join(snap.folder, "dump.rdb"))
        try:
            s1 = snap.start()
            v1_expected(s1, failures, "version 1 snapshot")
            s1.close()
        except RuntimeError as e:
            failures.append("version 1 snapshot: %s" % e)
        snap.stop()
        report.append("version 1: four DUMP payloads and one snapshot written by an earlier build compared")
        format_checks(binary, args.port + 8, work, fixtures_loaded, failures, report)
        seed_checks(binary, args.port + 9, work, failures, report)
        admission_checks(binary, args.port + 10, work, failures, report)
        c.close()
    except (OSError, RuntimeError, ValueError, AssertionError, EOFError) as e:
        failures.append("driver stopped: %r" % (e,))
    finally:
        for s in servers:
            s.stop()
        if args.keep:
            print("kept " + work, file=sys.stderr)
        else:
            shutil.rmtree(work, ignore_errors=True)
    for line in report:
        print(line)
    for line in failures:
        print("FAIL " + line)
    if failures:
        print("%d failure(s)" % len(failures))
        return 1
    print("graph round trip: every comparison equal")
    return 0


if __name__ == "__main__":
    sys.exit(main())
