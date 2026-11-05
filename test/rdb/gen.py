import sys

MASK = (1 << 64) - 1
WORDS = [b"the", b"quick", b"brown", b"fox", b"jumps", b"over", b"lazy", b"dog", b"redis", b"jetty", b"listpack", b"quicklist", b"\n", b"0123456789"]


class Rng:
    def __init__(self, seed):
        self.x = (seed * 0x9E3779B97F4A7C15 + 1) & MASK
        if self.x == 0:
            self.x = 1

    def next(self):
        x = self.x
        x ^= (x << 13) & MASK
        x ^= x >> 7
        x ^= (x << 17) & MASK
        self.x = x
        return x


def gen(pattern, seed, length):
    r = Rng(seed)
    out = bytearray()
    if pattern == "rand":
        while len(out) < length:
            out.append(r.next() >> 56)
    elif pattern == "text":
        while len(out) < length:
            out += WORDS[r.next() % len(WORDS)]
            out += b" "
    elif pattern == "run":
        out = bytearray(b"a" * length)
    elif pattern == "period":
        p = 1 + r.next() % 300
        base = bytearray(r.next() >> 56 for _ in range(p))
        while len(out) < length:
            out += base
    elif pattern == "mixed":
        while len(out) < length:
            if len(out) < 16 or r.next() % 3 == 0:
                n = 1 + r.next() % 64
                for _ in range(n):
                    out.append(r.next() >> 56)
            else:
                off = 1 + r.next() % min(len(out), 8200)
                n = 3 + r.next() % 300
                start = len(out) - off
                for i in range(n):
                    out.append(out[start + i])
    else:
        raise ValueError(pattern)
    return bytes(out[:length])


SPECS = []
for pattern in ["rand", "text", "run", "period", "mixed"]:
    for length in [21, 22, 23, 24, 25, 30, 33, 34, 40, 50, 64, 100, 255, 256, 257, 300, 1000, 4096, 8191, 8192, 8193, 8200, 16384, 65535, 65536, 100000, 300000]:
        for seed in [1, 7]:
            SPECS.append((pattern, seed * 1000 + length, length))


if __name__ == "__main__":
    sys.stdout.buffer.write(gen(sys.argv[1], int(sys.argv[2]), int(sys.argv[3])))
