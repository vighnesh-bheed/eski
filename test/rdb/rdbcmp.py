import sys

POLY = 0xAD93D23594C935A9
MASKED_AUX = {b"ctime", b"used-mem"}
TYPE_NAMES = {
    0: "string", 1: "list", 2: "set", 3: "zset", 4: "hash", 5: "zset2", 9: "hash-zipmap", 10: "list-ziplist",
    11: "set-intset", 12: "zset-ziplist", 13: "hash-ziplist", 14: "list-quicklist", 15: "stream", 16: "hash-listpack",
    17: "zset-listpack", 18: "list-quicklist2", 19: "stream-listpacks2", 20: "set-listpack", 21: "stream-listpacks3", 24: "hash-table-ex",
    25: "hash-listpack-ex",
}


def crc_table():
    table = []
    for n in range(256):
        crc = 0
        c = n
        for i in range(8):
            bit = crc & 0x8000000000000000
            if c & (1 << i):
                bit = not bit
            crc = (crc << 1) & 0xFFFFFFFFFFFFFFFF
            if bit:
                crc ^= POLY
        r = 0
        for i in range(64):
            if crc & (1 << i):
                r |= 1 << (63 - i)
        table.append(r)
    return table


TABLE = crc_table()


def crc64(data):
    crc = 0
    for b in data:
        crc = TABLE[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc


class Parser:
    def __init__(self, data):
        self.d = data
        self.i = 0

    def u8(self):
        b = self.d[self.i]
        self.i += 1
        return b

    def raw(self, n):
        s = self.d[self.i:self.i + n]
        if len(s) != n:
            raise ValueError("short read at %d" % self.i)
        self.i += n
        return s

    def length(self):
        b = self.u8()
        t = b >> 6
        if t == 3:
            return b & 0x3F, True
        if t == 0:
            return b & 0x3F, False
        if t == 1:
            return ((b & 0x3F) << 8) | self.u8(), False
        if b == 0x80:
            return int.from_bytes(self.raw(4), "big"), False
        if b == 0x81:
            return int.from_bytes(self.raw(8), "big"), False
        raise ValueError("bad length byte %d at %d" % (b, self.i - 1))

    def string(self):
        start = self.i
        n, enc = self.length()
        if enc:
            if n in (0, 1, 2):
                self.raw(1 << n)
            elif n == 3:
                clen, _ = self.length()
                self.length()
                self.raw(clen)
            else:
                raise ValueError("bad string encoding %d" % n)
        else:
            self.raw(n)
        return self.d[start:self.i]

    def span(self, start):
        return self.d[start:self.i]


def parse_value(p, t):
    start = p.i
    if t in (0, 9, 10, 11, 12, 13, 16, 17, 20):
        p.string()
        return ("seq", p.span(start))
    if t == 25:
        p.raw(8)
        p.string()
        return ("seq", p.span(start))
    if t in (1, 2):
        n, _ = p.length()
        head = p.span(start)
        items = [p.string() for _ in range(n)]
        if t == 1:
            return ("seq", head + b"".join(items))
        return ("set", head, sorted(items))
    if t == 3:
        n, _ = p.length()
        for _ in range(n):
            p.string()
            b = p.u8()
            if b < 253:
                p.raw(b)
        return ("seq", p.span(start))
    if t == 4:
        n, _ = p.length()
        head = p.span(start)
        items = [p.string() + p.string() for _ in range(n)]
        return ("set", head, sorted(items))
    if t == 5:
        n, _ = p.length()
        for _ in range(n):
            p.string()
            p.raw(8)
        return ("seq", p.span(start))
    if t == 14:
        n, _ = p.length()
        for _ in range(n):
            p.string()
        return ("seq", p.span(start))
    if t == 18:
        n, _ = p.length()
        for _ in range(n):
            p.length()
            p.string()
        return ("seq", p.span(start))
    if t == 24:
        p.raw(8)
        n, _ = p.length()
        head = p.span(start)
        items = []
        for _ in range(n):
            s = p.i
            p.length()
            p.string()
            p.string()
            items.append(p.span(s))
        return ("set", head, sorted(items))
    if t in (15, 19, 21):
        return parse_stream(p, t, start)
    raise ValueError("unsupported type %d" % t)


MASKED_TIMES = [0]


def parse_stream(p, t, start):
    out = bytearray()
    mark = p.i
    nodes, _ = p.length()
    for _ in range(nodes):
        p.string()
        p.string()
    for _ in range(3 if t == 15 else 8):
        p.length()
    ngroups, _ = p.length()
    for _ in range(ngroups):
        p.string()
        p.length()
        p.length()
        if t != 15:
            p.length()
        npel, _ = p.length()
        for _ in range(npel):
            p.raw(16)
            out += p.d[mark:p.i]
            p.raw(8)
            out += b"<time>"
            MASKED_TIMES[0] += 1
            mark = p.i
            p.length()
        nc, _ = p.length()
        for _ in range(nc):
            p.string()
            out += p.d[mark:p.i]
            p.raw(8)
            out += b"<seen>"
            MASKED_TIMES[0] += 1
            if t == 21:
                p.raw(8)
                out += b"<active>"
                MASKED_TIMES[0] += 1
            mark = p.i
            n, _ = p.length()
            p.raw(16 * n)
    out += p.d[mark:p.i]
    return ("seq", bytes(out))


def parse(data):
    if data[:5] != b"REDIS":
        raise ValueError("bad magic")
    p = Parser(data)
    magic = p.raw(9)
    aux = []
    sections = []
    cur = None
    pending = b""
    while True:
        op = p.u8()
        if op == 250:
            k = p.string()
            v = p.string()
            aux.append((k, v))
            continue
        if op == 254:
            s = p.i - 1
            p.length()
            cur = {"select": p.span(s), "resize": b"", "records": []}
            sections.append(cur)
            continue
        if op == 251:
            s = p.i - 1
            p.length()
            p.length()
            cur["resize"] = p.span(s)
            continue
        if op in (252, 253, 248, 249):
            s = p.i - 1
            if op == 252:
                p.raw(8)
            elif op == 253:
                p.raw(4)
            elif op == 248:
                p.length()
            else:
                p.raw(1)
            pending += p.span(s)
            continue
        if op == 255:
            break
        if op in (245, 246, 247):
            raise ValueError("function or module opcode %d" % op)
        key = p.string()
        val = parse_value(p, op)
        cur["records"].append((pending, op, key, val))
        pending = b""
    body_end = p.i
    trailer = p.raw(8)
    if p.i != len(data):
        raise ValueError("trailing bytes after the checksum")
    stored = int.from_bytes(trailer, "little")
    return {"magic": magic, "aux": aux, "sections": sections, "crc_ok": stored == 0 or stored == crc64(data[:body_end]), "crc": stored}


def aux_view(aux):
    return [(k, b"<masked>" if decode_plain(k) in MASKED_AUX else v) for k, v in aux]


def decode_plain(s):
    if s and s[0] >> 6 == 0:
        return s[1:]
    return s


def record_key(r):
    pending, t, key, val = r
    if val[0] == "seq":
        return (pending, t, key, val[1])
    return (pending, t, key, val[1], tuple(val[2]))


def main():
    a = parse(open(sys.argv[1], "rb").read())
    b = parse(open(sys.argv[2], "rb").read())
    failures = []
    if a["magic"] != b["magic"]:
        failures.append("magic %r != %r" % (a["magic"], b["magic"]))
    if not a["crc_ok"]:
        failures.append("checksum of %s does not verify" % sys.argv[1])
    if not b["crc_ok"]:
        failures.append("checksum of %s does not verify" % sys.argv[2])
    if aux_view(a["aux"]) != aux_view(b["aux"]):
        failures.append("aux fields differ: %r vs %r" % (aux_view(a["aux"]), aux_view(b["aux"])))
    if len(a["sections"]) != len(b["sections"]):
        failures.append("database section count %d != %d" % (len(a["sections"]), len(b["sections"])))
    per_type = {}
    for sa, sb in zip(a["sections"], b["sections"]):
        if sa["select"] != sb["select"]:
            failures.append("SELECTDB %r != %r" % (sa["select"], sb["select"]))
            continue
        if sa["resize"] != sb["resize"]:
            failures.append("RESIZEDB %r != %r in %r" % (sa["resize"], sb["resize"], sa["select"]))
        ra = {}
        for r in sa["records"]:
            ra.setdefault(r[2], []).append(r)
        rb = {}
        for r in sb["records"]:
            rb.setdefault(r[2], []).append(r)
        for key in sorted(set(ra) | set(rb)):
            xa = ra.get(key, [])
            xb = rb.get(key, [])
            t = (xa or xb)[0][1]
            name = TYPE_NAMES.get(t, str(t))
            cell = per_type.setdefault(name, [0, 0, 0])
            cell[0] += 1
            if [record_key(r) for r in xa] != [record_key(r) for r in xb]:
                cell[1] += 1
                failures.append("record for key %r type %s differs" % (key[:40], name))
            elif xa and xa[0][3][0] == "set":
                cell[2] += 1
    total = sum(len(s["records"]) for s in a["sections"])
    print("byte comparison: %d records in %d database sections, %d aux fields (ctime and used-mem masked), %d stream group times masked" % (total, len(a["sections"]), len(a["aux"]), MASKED_TIMES[0]))
    for name, (n, bad, unordered) in sorted(per_type.items()):
        note = " (element order normalised)" if unordered else ""
        print("  %-18s %4d records  %s%s" % (name, n, "identical" if bad == 0 else "%d DIFFER" % bad, note))
    for f in failures[:30]:
        print("  FAIL " + f)
    if failures:
        print("byte comparison: %d differences" % len(failures))
        sys.exit(1)
    print("byte comparison: identical")


if __name__ == "__main__":
    main()
