import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen
import resp

T = 4102444800000
ANY = (0, 0)
V5 = (5, 0)
V74 = (7, 4)
VERSIONS = ["3.2.12", "4.0.14", "5.0.14", "6.0.20", "6.2.14", "7.0.15", "7.4.11"]
REPO = os.environ.get("ESKI_CORPUS_IMAGE_REPO", "docker.io/library/redis")
BASE_PORT = int(os.environ.get("ESKI_CORPUS_PORT", "6641"))
VARIANTS = [
    ("dump-compress.rdb", "yes", "noeviction", ANY),
    ("dump-nocompress.rdb", "no", "noeviction", ANY),
    ("dump-lru.rdb", "yes", "allkeys-lru", V5),
    ("dump-lfu.rdb", "yes", "allkeys-lfu", V5),
]


def command_log():
    log = []

    def add(since, *args):
        log.append((since, args))

    def ttl(key, offset):
        add(ANY, "PEXPIREAT", key, T + offset)

    add(ANY, "FLUSHALL")
    add(ANY, "SELECT", 0)
    strings = [
        ("str:embstr", b"hello world"),
        ("str:int", b"12345"),
        ("str:negint", b"-7"),
        ("str:bigint", b"9223372036854775807"),
        ("str:int8", b"100"),
        ("str:int16", b"30000"),
        ("str:int32", b"2000000000"),
        ("str:leading-zero", b"007"),
        ("str:lzf", b"abc" * 600),
        ("str:text", gen.gen("text", 21, 3000)),
        ("str:random", gen.gen("rand", 22, 300)),
        ("str:binary", bytes(range(256))),
        ("str:empty", b""),
        ("str:long", gen.gen("period", 23, 70000)),
        ("str:large", gen.gen("mixed", 24, 300000)),
    ]
    for key, value in strings:
        add(ANY, "SET", key, value)
    add(ANY, "SET", "str:ttl", "expires")
    ttl("str:ttl", 0)
    add(ANY, "RPUSH", "list:small", "a", "b", "c", "1", "2", "-3", "x" * 70)
    add(ANY, "RPUSH", "list:long", *["item%d" % i for i in range(600)])
    add(ANY, "RPUSH", "list:large-values", *["v" * 5000 for _ in range(30)])
    add(ANY, "RPUSH", "list:ttl", "p", "q")
    ttl("list:ttl", 1)
    add(ANY, "SADD", "set:integers", "1", "2", "3", "4294967296", "-100", "70000")
    add(ANY, "SADD", "set:strings", "a", "b", "c")
    add(ANY, "SADD", "set:many-strings", *["m%d" % i for i in range(700)])
    add(ANY, "SADD", "set:many-integers", *[str(i * 7) for i in range(700)])
    add(ANY, "SADD", "set:ttl", "1", "2")
    ttl("set:ttl", 2)
    add(ANY, "ZADD", "zset:small", 1.5, "a", -2, "b", 3, "c", 0, "d")
    add(ANY, "ZADD", "zset:infinite", "inf", "p", "-inf", "n", 0, "z", 1e300, "huge", -1e-300, "tiny")
    add(ANY, "ZADD", "zset:many", *[x for i in range(300) for x in (i * 0.5 - 17, "z%d" % i)])
    add(ANY, "ZADD", "zset:ttl", 1, "a")
    ttl("zset:ttl", 3)
    add(ANY, "HMSET", "hash:small", "f1", "v1", "f2", "42", "f3", "")
    add(ANY, "HMSET", "hash:many", *[x for i in range(600) for x in ("k%d" % i, "v%d" % i)])
    add(ANY, "HMSET", "hash:large-value", "k", "z" * 3000, "j", "small")
    add(ANY, "HMSET", "hash:ttl", "a", "1")
    ttl("hash:ttl", 4)
    add(V74, "HMSET", "hash:field-ttl", "f1", "v1", "f2", "v2", "f3", "v3")
    add(V74, "HPEXPIREAT", "hash:field-ttl", T + 5, "FIELDS", 2, "f1", "f2")
    add(V74, "HMSET", "hash:field-ttl-many", *[x for i in range(600) for x in ("k%d" % i, "v%d" % i)])
    add(V74, "HPEXPIREAT", "hash:field-ttl-many", T + 6, "FIELDS", 1, "k599")
    add(ANY, "PFADD", "hll:sparse", "a", "b", "c")
    add(ANY, "PFADD", "hll:dense", *["e%d" % i for i in range(10000)])
    add(ANY, "SETBIT", "bitmap", 100, 1)
    add(ANY, "SETBIT", "bitmap", 7, 1)
    add(ANY, "GEOADD", "geo", 13.361389, 38.115556, "Palermo", 15.087269, 37.502669, "Catania")
    for i in range(1, 51):
        add(V5, "XADD", "stream:plain", "%d-0" % (1000 + i), "f", "v%d" % i)
    add(V5, "XGROUP", "CREATE", "stream:plain", "g1", "0")
    add(V5, "XGROUP", "CREATE", "stream:plain", "g2", "$")
    add(V5, "XREADGROUP", "GROUP", "g1", "c1", "COUNT", 8, "STREAMS", "stream:plain", ">")
    add(V5, "XACK", "stream:plain", "g1", "1001-0")
    for i in range(1, 301):
        add(V5, "XADD", "stream:nodes", "%d-%d" % (i, i % 3), "f", "v%d" % i, "g", str(i))
    add(V5, "XGROUP", "CREATE", "stream:nodes", "g", "0")
    add(V5, "XREADGROUP", "GROUP", "g", "c", "COUNT", 120, "STREAMS", "stream:nodes", ">")
    add(V5, "XADD", "stream:empty", "1-1", "a", "1")
    add(V5, "XDEL", "stream:empty", "1-1")
    add(V5, "XGROUP", "CREATE", "stream:empty", "g", "$")
    for i in range(30):
        add(V5, "XADD", "stream:trimmed", "%d-0" % (100 + i), "a", str(i))
    add(V5, "XTRIM", "stream:trimmed", "MAXLEN", 10)
    add(V5, "XADD", "stream:ttl", "5-5", "a", "b")
    ttl("stream:ttl", 7)
    add(ANY, "SELECT", 3)
    add(ANY, "SET", "db3:key", "value")
    add(ANY, "RPUSH", "db3:list", "a")
    add(ANY, "SET", "db3:ttl", "value")
    ttl("db3:ttl", 8)
    add(ANY, "SELECT", 15)
    add(ANY, "SET", "db15:key", "last")
    add(ANY, "SELECT", 0)
    return log


def connect(port):
    for _ in range(100):
        try:
            c = resp.Client(port)
            if c.call("PING") == "PONG":
                return c
            c.close()
        except OSError:
            pass
        time.sleep(0.1)
    raise RuntimeError("nothing answers PING on port %d" % port)


def server_version(c):
    for line in c.check("INFO", "server").decode().split("\r\n"):
        if line.startswith("redis_version:"):
            return tuple(int(x) for x in line.split(":", 1)[1].split(".")[:2])
    raise RuntimeError("INFO server has no redis_version")


def replay(c, version, log):
    pending = [args for since, args in log if since <= version]
    for start in range(0, len(pending), 100):
        for args, reply in zip(pending[start:start + 100], c.pipeline(pending[start:start + 100])):
            if isinstance(reply, resp.Error):
                raise RuntimeError("%s failed: %s" % (args[0], reply))


def start_container(version, port, datadir):
    name = "eski-corpus-%s" % version
    subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(
        ["docker", "run", "--rm", "-d", "--name", name, "--network=host", "--user", "%d:%d" % (os.getuid(), os.getgid()),
         "-v", "%s:/data:z" % datadir, "%s:%s" % (REPO, version),
         "redis-server", "--port", str(port), "--bind", "127.0.0.1", "--dir", "/data", "--save", ""],
        check=True, stdout=subprocess.DEVNULL)
    return name


def generate(label, port, datadir, outdir, log, version=None):
    c = connect(port)
    version = version or server_version(c)
    replay(c, version, log)
    target = os.path.join(outdir, "rdb-" + label)
    os.makedirs(target, exist_ok=True)
    written = []
    for name, compression, policy, since in VARIANTS:
        if since > version:
            continue
        c.check("CONFIG", "SET", "rdbcompression", compression)
        c.check("CONFIG", "SET", "maxmemory-policy", policy)
        c.check("SAVE")
        shutil.copyfile(os.path.join(datadir, "dump.rdb"), os.path.join(target, name))
        written.append("%s %d bytes" % (name, os.path.getsize(os.path.join(target, name))))
    c.check("CONFIG", "SET", "rdbcompression", "yes")
    c.check("CONFIG", "SET", "maxmemory-policy", "noeviction")
    keyspace = [line.split(",avg_ttl")[0] for line in c.check("INFO", "keyspace").decode().split("\r\n") if line.startswith("db")]
    c.close()
    print("rdb-%s (redis %d.%d): %s; %s" % (label, version[0], version[1], ", ".join(written), " ".join(keyspace)))


def main():
    if len(sys.argv) < 2:
        print("usage: corpus.py OUT_DIR [VERSION | LABEL=PORT=DATA_DIR[=MAJOR.MINOR]]...", file=sys.stderr)
        sys.exit(2)
    outdir = sys.argv[1]
    specs = sys.argv[2:] or VERSIONS
    log = command_log()
    work = tempfile.mkdtemp(prefix="eski-corpus.")
    try:
        for index, spec in enumerate(specs):
            if "=" in spec:
                label, port, datadir, *given = spec.split("=")
                version = tuple(int(x) for x in given[0].split(".")) if given else None
                generate(label, int(port), datadir, outdir, log, version)
                continue
            datadir = os.path.join(work, spec)
            os.makedirs(datadir)
            name = start_container(spec, BASE_PORT + index, datadir)
            try:
                generate(spec, BASE_PORT + index, datadir, outdir, log)
            finally:
                subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
