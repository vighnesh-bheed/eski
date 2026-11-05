import argparse
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rdb"))
import resp


UNSET = object()


def normalize(value):
    if isinstance(value, resp.Error):
        return ("error", str(value))
    return value


class Suite:
    def __init__(self, eski_port, reference_port, protocol, baseline_port=None):
        self.clients = [resp.Client(eski_port), resp.Client(reference_port)]
        self.baseline = resp.Client(baseline_port) if baseline_port else None
        if self.baseline:
            self.clients.append(self.baseline)
        self.prefix = "sort:compare:%d:%d:" % (os.getpid(), protocol)
        self.keys = set()
        self.passed = 0
        self.normalized = 0
        for client in self.clients:
            client.sock.settimeout(10)
            client.check("HELLO", protocol)

    def close(self):
        for client in self.clients:
            try:
                if self.keys:
                    client.check("DEL", *sorted(self.keys))
            finally:
                client.close()

    def key(self, name):
        key = (self.prefix + name).encode()
        self.keys.add(key)
        return key

    def check(self, *args, expected=UNSET, equivalent=None):
        actual, reference = [normalize(c.call(*args)) for c in self.clients[:2]]
        if self.baseline:
            baseline = normalize(self.baseline.call(*args))
            if actual != baseline:
                raise AssertionError("%r eski=%s baseline=%s" % (args[:8], repr(actual)[:1200], repr(baseline)[:1200]))
        if not (equivalent(actual, reference) if equivalent else actual == reference):
            raise AssertionError("%r eski=%s reference=%s" % (args[:8], repr(actual)[:1200], repr(reference)[:1200]))
        if expected is not UNSET and actual != expected:
            raise AssertionError("%r got=%s expected=%s" % (args[:8], repr(actual)[:1200], repr(expected)[:1200]))
        self.passed += 1
        self.normalized += equivalent is not None
        return actual

    def collection(self, kind, name, values):
        key = self.key(name)
        self.check("DEL", key)
        if kind == "list":
            self.check("RPUSH", key, *values)
        elif kind == "set":
            self.check("SADD", key, *values)
        else:
            self.check("ZADD", key, *[x for i, value in enumerate(values) for x in (i, value)])
        return key

    def direct(self, kind, name, values):
        key = self.collection(kind, name, values)
        destination = self.key("destination")
        for direction in ("ASC", "DESC"):
            for limit in ((), ("LIMIT", 0, 0), ("LIMIT", 0, 3), ("LIMIT", 2, 5), ("LIMIT", -2, 4), ("LIMIT", len(values) + 2, 3), ("LIMIT", 1, -1)):
                options = ("ALPHA", direction, *limit)
                self.check("SORT", key, *options)
                self.check("SORT_RO", key, *options)
                self.check("SORT", key, *options, "GET", "#")
                self.check("SORT", key, *options, "STORE", destination)
                self.check("LRANGE", destination, 0, -1)
        for direction in ("ASC", "DESC"):
            self.check("SORT", key, "ALPHA", direction, "STORE", destination, expected=len(values))
            self.check("LRANGE", destination, 0, -1, expected=sorted(values, reverse=direction == "DESC"))
            self.check("SORT", key, "BY", "#", "ALPHA", direction, "STORE", destination)
            self.check("LRANGE", destination, 0, -1)
            if kind != "set":
                self.check("SORT", key, "BY", "#", "ALPHA", direction, "LIMIT", 1, 5, "GET", "#")
                self.check("SORT_RO", key, "BY", "#", "ALPHA", direction, "GET", "#")

    def by(self, kind, count, ties):
        members = [b"m%03d" % i for i in range(count)]
        random.Random(1729).shuffle(members)
        key = self.collection(kind, "by:%s:%d:%d" % (kind, count, ties), members)
        weight = self.key("weight:*")
        hash_weight = self.key("hash:*") + b"->field"
        payload = self.key("payload:*")
        weights = {}
        payloads = {}
        for i, member in enumerate(members):
            suffix = member.decode()
            wkey = self.key("weight:" + suffix)
            hkey = self.key("hash:" + suffix)
            pkey = self.key("payload:" + suffix)
            self.check("DEL", wkey, hkey, pkey)
            if i % 13 != 0 and (ties or i != 0):
                value = b"common-prefix-" * (1 + i % 4) + b"%04d\x00tail\xff" % i
                if ties:
                    value = (b"", b"a\x00second", b"a\x00first", b"same", b"same")[i % 5]
                self.check("SET", wkey, value)
                self.check("HSET", hkey, "field", value)
                weights[member] = value
            elif not ties and i != 0:
                value = b"unique-%04d" % i
                self.check("SET", wkey, value)
                self.check("HSET", hkey, "field", value)
                weights[member] = value
            if i % 7:
                payloads[member] = b"payload\x00" + member + b"\xff"
                self.check("SET", pkey, payloads[member])
        destination = self.key("destination")
        for pattern in (weight, hash_weight):
            for direction in ("ASC", "DESC"):
                for limit in ((), ("LIMIT", 0, 0), ("LIMIT", 0, 3), ("LIMIT", 2, 5), ("LIMIT", count // 2, 7), ("LIMIT", count + 1, 3), ("LIMIT", -2, 4), ("LIMIT", 1, -1)):
                    options = ("BY", pattern, "ALPHA", direction, *limit, "GET", "#", "GET", payload)
                    equivalent = None
                    expected = UNSET
                    if ties and not limit:
                        def equivalent(a, b):
                            key_order = lambda reply: [(m in weights, weights.get(m, b"").split(b"\x00", 1)[0]) for m in reply[::2]]
                            return key_order(a) == key_order(b) and sorted(zip(a[::2], a[1::2])) == sorted(zip(b[::2], b[1::2]))
                        ordered = sorted(members, key=lambda m: (m in weights, weights.get(m, b"").split(b"\x00", 1)[0]), reverse=direction == "DESC")
                        expected = [x for member in ordered for x in (member, payloads.get(member))]
                    elif ties:
                        def equivalent(a, b):
                            key_order = lambda reply: [(m in weights, weights.get(m, b"").split(b"\x00", 1)[0]) for m in reply[::2]]
                            consistent = lambda reply: all(p == payloads.get(m) for m, p in zip(reply[::2], reply[1::2]))
                            return key_order(a) == key_order(b) and consistent(a) and consistent(b) and len(set(a[::2])) == len(a[::2])
                    self.check("SORT", key, *options, expected=expected, equivalent=equivalent)
                    self.check("SORT_RO", key, *options, expected=expected, equivalent=equivalent)
                    self.check("SORT", key, *options, "STORE", destination)
                    if ties and not limit:
                        def equivalent(a, b):
                            key_order = lambda reply: [(m in weights, weights.get(m, b"")) for m in reply[::2]]
                            return key_order(a) == key_order(b) and sorted(zip(a[::2], a[1::2])) == sorted(zip(b[::2], b[1::2]))
                        ordered = sorted(members, key=lambda m: (m in weights, weights.get(m, b"")), reverse=direction == "DESC")
                        expected = [x for member in ordered for x in (member, payloads.get(member, b""))]
                    elif ties:
                        def equivalent(a, b):
                            key_order = lambda reply: [(m in weights, weights.get(m, b"")) for m in reply[::2]]
                            consistent = lambda reply: all(p == payloads.get(m, b"") for m, p in zip(reply[::2], reply[1::2]))
                            return key_order(a) == key_order(b) and consistent(a) and consistent(b) and len(set(a[::2])) == len(a[::2])
                    self.check("LRANGE", destination, 0, -1, expected=expected if ties and not limit else UNSET, equivalent=equivalent)

    def numeric(self, kind):
        values = [b"2", b"1", b"1.0", b"01", b"-0", b"0", b"1e0", b"10", b"-2", b"1\x00second", b"1\x00first"]
        key = self.collection(kind, "numeric:" + kind, values)
        destination = self.key("destination")
        for direction in ("ASC", "DESC"):
            self.check("SORT", key, direction)
            self.check("SORT_RO", key, direction, "LIMIT", 1, 5)
            self.check("SORT", key, direction, "STORE", destination)
            self.check("LRANGE", destination, 0, -1)
            self.check("SORT", key, "BY", "nosort", "ALPHA", direction, "STORE", destination)
            self.check("LRANGE", destination, 0, -1)
        if kind != "set":
            self.check("SORT", key, "BY", "nosort", "ALPHA", "DESC", "LIMIT", 2, 4)
            self.check("SORT_RO", key, "BY", "nosort", "ALPHA", "LIMIT", 1, 3, "GET", "#")

    def stable(self):
        values = [b"a\x00second", b"", b"a", b"a\x00first", b"\x00suffix", b"b", b"", b"a\x00second"]
        key = self.collection("list", "stable", values)
        for direction in ("ASC", "DESC"):
            expected = sorted(values, key=lambda value: value.split(b"\x00", 1)[0], reverse=direction == "DESC")
            self.check("SORT", key, "ALPHA", direction, expected=expected, equivalent=lambda a, b: sorted(a) == sorted(b) and [v.split(b"\x00", 1)[0] for v in a] == [v.split(b"\x00", 1)[0] for v in b])
            self.check("SORT_RO", key, "ALPHA", direction, "LIMIT", 1, 5, expected=expected[1:6], equivalent=lambda a, b: [v.split(b"\x00", 1)[0] for v in a] == [v.split(b"\x00", 1)[0] for v in b])

    def run(self):
        small = [b"", b"a\x00left", b"b\x00right", b"prefix", b"prefixa", b"z", b"\x7f", b"\x80", b"\xff"]
        long = [b"a" * n + ending for n in (7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 1024, 4096, 16385) for ending in (b"b", b"c\x00full\xff", b"\xff")]
        large = [b"%04d\x00suffix" % i for i in range(300)]
        random.Random(42).shuffle(long)
        random.Random(43).shuffle(large)
        for kind in ("list", "set", "zset"):
            self.direct(kind, kind + ":small", small)
            self.direct(kind, kind + ":long", long)
            self.direct(kind, kind + ":large", large)
            self.numeric(kind)
            self.by(kind, 49, False)
            self.by(kind, 301, False)
        self.stable()
        for count in (5, 7, 8, 41, 49, 301):
            self.by("list", count, True)
        missing = self.key("missing")
        self.check("DEL", missing)
        self.check("SORT", missing, "ALPHA", expected=[])
        self.check("SORT_RO", missing, "ALPHA", "DESC", "LIMIT", 1, 2, expected=[])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("eski_port", type=int)
    parser.add_argument("reference_port", type=int)
    parser.add_argument("--baseline-port", type=int)
    args = parser.parse_args()
    passed = 0
    normalized = 0
    for protocol in (2, 3):
        suite = Suite(args.eski_port, args.reference_port, protocol, args.baseline_port)
        try:
            suite.run()
            passed += suite.passed
            normalized += suite.normalized
            print("RESP%d SORT comparisons passed: %d exact reference, %d equal-group reference" % (protocol, suite.passed - suite.normalized, suite.normalized))
        finally:
            suite.close()
    print("passed: %d failed: 0" % passed)
    print("exact reference: %d equal-group reference: %d" % (passed - normalized, normalized))
    if args.baseline_port:
        print("exact baseline: %d" % passed)


if __name__ == "__main__":
    main()
