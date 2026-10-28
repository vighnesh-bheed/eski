import argparse
import json
import random
import re
import secrets
import socket
import subprocess
import sys
import time

DEFAULT_IMAGE = "eski:local"
BINARY = "/usr/local/bin/eski"
DATA_DIR = "/data"
DEFAULT_PORT = "6399/tcp"
DOC_FILES = ("THIRD_PARTY_NOTICES.md", "ODIN-LICENSE", "build-info.txt")
FORBIDDEN_PATHS = ("/opt/odin", "/build", "/src", "/out")
FORBIDDEN_TOOLS = ("odin", "clang", "cc", "gcc", "ld")
SERVER_ARGS = ("--save", "3600 1")
SHUTDOWN_LINES = (
    "Received SIGTERM scheduling shutdown...",
    "User requested shutdown...",
    "Saving the final RDB snapshot before exiting.",
    "DB saved on disk",
    "is now ready to exit, bye bye...",
)
BAD_LOG_MARKERS = (
    "Error trying to save",
    "can't exit",
    "Failed opening",
    "Short read",
    "Bad file format",
    "Wrong signature",
    "Internal error in RDB",
    "Killing it",
)
LOADED = re.compile(r"Done loading RDB, keys loaded: (\d+), keys expired: (\d+)\.")
SECOND_DB = 5
PORT_RANGE = (16000, 60999)


class CheckFailure(Exception):
    pass


class ReplyError:
    def __init__(self, message):
        self.message = message

    def __eq__(self, other):
        return isinstance(other, ReplyError) and other.message == self.message

    def __repr__(self):
        return f"ReplyError({self.message!r})"


def encode(args):
    out = bytearray(b"*%d\r\n" % len(args))
    for arg in args:
        if isinstance(arg, str):
            arg = arg.encode()
        elif isinstance(arg, int):
            arg = str(arg).encode()
        out += b"$%d\r\n" % len(arg)
        out += arg
        out += b"\r\n"
    return bytes(out)


class Conn:
    def __init__(self, sock):
        self.sock = sock
        self.buf = bytearray()

    @classmethod
    def connect(cls, port, timeout=30.0):
        sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        return cls(sock)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def _fill(self):
        chunk = self.sock.recv(1 << 16)
        if not chunk:
            raise ConnectionError("the server closed the connection")
        self.buf += chunk

    def _line(self):
        while True:
            i = self.buf.find(b"\r\n")
            if i >= 0:
                line = bytes(self.buf[:i])
                del self.buf[: i + 2]
                return line
            self._fill()

    def _exact(self, n):
        while len(self.buf) < n + 2:
            self._fill()
        data = bytes(self.buf[:n])
        if self.buf[n : n + 2] != b"\r\n":
            raise ConnectionError("bulk string without its terminator")
        del self.buf[: n + 2]
        return data

    def reply(self):
        line = self._line()
        kind, rest = line[:1], line[1:]
        if kind == b"+":
            return rest.decode()
        if kind == b"-":
            return ReplyError(rest.decode(errors="replace"))
        if kind == b":":
            return int(rest)
        if kind == b"$":
            n = int(rest)
            return None if n < 0 else self._exact(n)
        if kind == b"*":
            n = int(rest)
            return None if n < 0 else [self.reply() for _ in range(n)]
        raise ConnectionError(f"unexpected reply {line[:40]!r}")

    def call(self, *args):
        self.sock.sendall(encode(args))
        return self.reply()

    def must(self, *args):
        reply = self.call(*args)
        if isinstance(reply, ReplyError):
            raise CheckFailure(f"{' '.join(str(a) for a in args[:3])} failed: {reply.message}")
        return reply


def text(value):
    if isinstance(value, bytes):
        return value.decode(errors="replace")
    if isinstance(value, list):
        return [text(v) for v in value]
    return value


def pairs(flat):
    return {flat[i]: flat[i + 1] for i in range(0, len(flat), 2)}


def dataset(gen):
    p = f"g{gen}:"
    binary = bytes(range(256)) + f"gen{gen}".encode()
    large = ("eski-" * 40000 + str(gen)).encode()
    stream_ids = [f"{1000 + i}-{gen}" for i in range(60)]
    writes = [
        ("SET", p + "string", f"value-{gen}"),
        ("SET", p + "integer", str(1234567 + gen)),
        ("INCRBY", p + "integer", "10"),
        ("SET", p + "binary", binary),
        ("SET", p + "large", large),
        ("SET", p + "volatile", "expires-later", "EX", "86400"),
        ("SETBIT", p + "bitmap", "7", "1"),
        ("SETBIT", p + "bitmap", "100", "1"),
        ("SETBIT", p + "bitmap", "4000", "1"),
        ("PFADD", p + "hll", *[f"visitor-{i}" for i in range(1000)]),
        ("RPUSH", p + "list:small", "a", "b", "c", str(gen)),
        ("RPUSH", p + "list:large", *[f"item-{i}" for i in range(1000)], "x" * 5000),
        ("HSET", p + "hash:small", "name", "eski", "gen", str(gen), "empty", ""),
        ("HSET", p + "hash:large", *[v for i in range(1000) for v in (f"field-{i}", f"value-{i}")]),
        ("HSET", p + "hash:ttl", "keep", "1", "lapse", "2"),
        ("HEXPIRE", p + "hash:ttl", "86400", "FIELDS", "1", "lapse"),
        ("SADD", p + "set:int", *[str(i * 7 + gen) for i in range(100)]),
        ("SADD", p + "set:small", "red", "green", "blue"),
        ("SADD", p + "set:large", *[f"member-{i}" for i in range(1000)]),
        ("ZADD", p + "zset:small", "1", "one", "2.5", "two", "-3", "minus"),
        ("ZADD", p + "zset:large", *[v for i in range(1000) for v in (str(i / 4 - 50), f"zm-{i}")]),
        ("GEOADD", p + "geo", "13.361389", "38.115556", "Palermo", "15.087269", "37.502669", "Catania", "2.349014", "48.864716", "Paris"),
    ]
    for i, sid in enumerate(stream_ids):
        writes.append(("XADD", p + "stream", sid, "n", str(i), "gen", str(gen)))
    writes += [
        ("XGROUP", "CREATE", p + "stream", "readers", "0"),
        ("XGROUP", "CREATECONSUMER", p + "stream", "readers", "idle"),
        ("XREADGROUP", "GROUP", "readers", "alice", "COUNT", "10", "STREAMS", p + "stream", ">"),
        ("XACK", p + "stream", "readers", stream_ids[0], stream_ids[1], stream_ids[2]),
    ]
    second = [
        ("SET", p + "db5:string", f"db5-{gen}"),
        ("RPUSH", p + "db5:list", "x", "y", "z"),
    ]
    expect = {
        0: {
            p + "string": ("string", f"value-{gen}".encode()),
            p + "integer": ("string", str(1234577 + gen).encode()),
            p + "binary": ("string", binary),
            p + "large": ("string", large),
            p + "volatile": ("string", b"expires-later"),
            p + "bitmap": ("string", None),
            p + "hll": ("string", None),
            p + "list:small": ("list", [b"a", b"b", b"c", str(gen).encode()]),
            p + "list:large": ("list", [f"item-{i}".encode() for i in range(1000)] + [b"x" * 5000]),
            p + "hash:small": ("hash", {b"name": b"eski", b"gen": str(gen).encode(), b"empty": b""}),
            p + "hash:large": ("hash", {f"field-{i}".encode(): f"value-{i}".encode() for i in range(1000)}),
            p + "hash:ttl": ("hash", {b"keep": b"1", b"lapse": b"2"}),
            p + "set:int": ("set", sorted(str(i * 7 + gen).encode() for i in range(100))),
            p + "set:small": ("set", sorted([b"red", b"green", b"blue"])),
            p + "set:large": ("set", sorted(f"member-{i}".encode() for i in range(1000))),
            p + "zset:small": ("zset", None),
            p + "zset:large": ("zset", None),
            p + "geo": ("zset", None),
            p + "stream": ("stream", None),
        },
        SECOND_DB: {
            p + "db5:string": ("string", f"db5-{gen}".encode()),
            p + "db5:list": ("list", [b"x", b"y", b"z"]),
        },
    }
    return {0: writes, SECOND_DB: second}, expect


def tail_writes(gen):
    p = f"g{gen}:"
    writes = [
        ("SET", p + "after-save", f"final-save-{gen}"),
        ("LPUSH", p + "after-save:list", "1", "2", "3"),
    ]
    expect = {
        p + "after-save": ("string", f"final-save-{gen}".encode()),
        p + "after-save:list": ("list", [b"3", b"2", b"1"]),
    }
    return writes, expect


def read_key(conn, key, kind):
    if kind == "string":
        return conn.must("GET", key)
    if kind == "list":
        return conn.must("LRANGE", key, "0", "-1")
    if kind == "hash":
        return pairs(conn.must("HGETALL", key))
    if kind == "set":
        return sorted(conn.must("SMEMBERS", key))
    if kind == "zset":
        return conn.must("ZRANGE", key, "0", "-1", "WITHSCORES")
    if kind == "stream":
        return {
            "entries": conn.must("XRANGE", key, "-", "+"),
            "length": conn.must("XLEN", key),
            "groups": conn.must("XINFO", "GROUPS", key),
            "pending": conn.must("XPENDING", key, "readers", "-", "+", "100"),
            "consumers": [c for c in conn.must("XINFO", "CONSUMERS", key, "readers")],
        }
    raise CheckFailure(f"no reader for type {kind}")


def drop_idle(value):
    if isinstance(value, dict):
        consumers = []
        for entry in value.get("consumers") or []:
            fields = pairs(entry)
            consumers.append(sorted((k, v) for k, v in fields.items() if k not in (b"idle", b"inactive")))
        out = dict(value)
        out["consumers"] = consumers
        out["pending"] = [row[:2] + row[3:] if isinstance(row, list) and len(row) >= 4 else row for row in value.get("pending") or []]
        return out
    return value


def snapshot_key(conn, key, kind):
    actual = conn.must("TYPE", key)
    if actual != kind:
        raise CheckFailure(f"{key} has type {actual}, expected {kind}")
    extra = {}
    if kind == "string" and key.endswith(":hll"):
        extra["pfcount"] = conn.must("PFCOUNT", key)
    content = drop_idle(read_key(conn, key, kind))
    pttl = conn.must("PTTL", key)
    if kind == "string" and key.endswith(":bitmap"):
        extra["bitcount"] = conn.must("BITCOUNT", key)
    if kind == "zset" and key.endswith(":geo"):
        extra["dist"] = conn.must("GEODIST", key, "Palermo", "Catania", "km")
    if kind == "hash" and key.endswith(":ttl"):
        ttls = conn.must("HPTTL", key, "FIELDS", "2", "keep", "lapse")
        extra["field_ttl"] = [t > 0 if t >= 0 else t for t in ttls]
    return {"type": kind, "content": content, "volatile": pttl > 0 if pttl >= 0 else pttl, **extra}


def snapshot(conn, expected):
    out = {}
    for db, keys in sorted(expected.items()):
        conn.must("SELECT", str(db))
        for key, (kind, _) in sorted(keys.items()):
            out[(db, key)] = snapshot_key(conn, key, kind)
        out[(db, "<dbsize>")] = conn.must("DBSIZE")
    conn.must("SELECT", "0")
    return out


def check_intended(conn, expected):
    for db, keys in sorted(expected.items()):
        conn.must("SELECT", str(db))
        for key, (kind, value) in sorted(keys.items()):
            if value is None:
                continue
            got = read_key(conn, key, kind)
            if got != value:
                raise CheckFailure(f"{key} in db {db} holds {describe(got)}, expected {describe(value)}")
    conn.must("SELECT", "0")


def describe(value):
    shown = repr(value)
    return shown if len(shown) <= 120 else shown[:117] + "..."


def diff_snapshots(before, after):
    problems = []
    for name in sorted(set(before) | set(after), key=str):
        if name not in after:
            problems.append(f"{name[1]} in db {name[0]} is missing")
        elif name not in before:
            problems.append(f"{name[1]} in db {name[0]} appeared")
        elif before[name] != after[name]:
            problems.append(f"{name[1]} in db {name[0]} changed from {describe(before[name])} to {describe(after[name])}")
    return problems


def merge(into, extra):
    for db, keys in extra.items():
        into.setdefault(db, {}).update(keys)
    return into


def count_keys(expected):
    return sum(len(keys) for keys in expected.values())


def write_all(conn, writes_by_db):
    for db, writes in sorted(writes_by_db.items()):
        conn.must("SELECT", str(db))
        for argv in writes:
            conn.must(*argv)
    conn.must("SELECT", "0")


def check_shutdown_log(log):
    problems = []
    pos = 0
    for line in SHUTDOWN_LINES:
        at = log.find(line, pos)
        if at < 0:
            problems.append(f"shutdown log lacks '{line}'" + (" after the previous step" if line in log else ""))
        else:
            pos = at + len(line)
    for marker in BAD_LOG_MARKERS:
        if marker in log:
            problems.append(f"log reports '{marker}'")
    return problems


def loaded_keys(log):
    found = LOADED.findall(log)
    if not found or "DB loaded from disk" not in log:
        return None
    return int(found[-1][0])


def check_image_config(config):
    problems = []
    user = (config.get("User") or "").strip()
    if user.split(":", 1)[0] in ("", "0", "root"):
        problems.append(f"the image runs as root (User={user!r})")
    if config.get("WorkingDir") != DATA_DIR:
        problems.append(f"the working directory is {config.get('WorkingDir')!r}, expected {DATA_DIR}")
    if DATA_DIR not in (config.get("Volumes") or {}):
        problems.append(f"{DATA_DIR} is not a volume")
    if config.get("Entrypoint") != [BINARY]:
        problems.append(f"the entry point is {config.get('Entrypoint')!r}, expected [{BINARY!r}]")
    if DEFAULT_PORT not in (config.get("ExposedPorts") or {}):
        problems.append(f"{DEFAULT_PORT} is not exposed")
    if config.get("StopSignal") not in (None, "", "SIGTERM", "15"):
        problems.append(f"the stop signal is {config.get('StopSignal')!r}, expected SIGTERM")
    return problems


def port_free(port):
    families = [(socket.AF_INET, "0.0.0.0")]
    if socket.has_ipv6:
        families.append((socket.AF_INET6, "::"))
    for family, host in families:
        try:
            s = socket.socket(family, socket.SOCK_STREAM)
        except OSError:
            continue
        try:
            if family == socket.AF_INET6:
                s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            s.bind((host, port))
        except OSError as e:
            if family == socket.AF_INET6 and e.errno in (97, 99):
                continue
            return False
        finally:
            s.close()
    return True


def free_port(rng=None, tries=200):
    rng = rng or random.SystemRandom()
    for _ in range(tries):
        port = rng.randint(*PORT_RANGE)
        if port_free(port):
            return port
    raise CheckFailure(f"no free port found in {PORT_RANGE[0]}-{PORT_RANGE[1]}")


def run_argv(image, name, label, volume, port):
    return ["run", "-d", "--name", name, "--label", label, "--network=host",
            "-v", f"{volume}:{DATA_DIR}", image, "--port", str(port), *SERVER_ARGS]


class Docker:
    def __init__(self, executable, label, verbose=False):
        self.exe = executable
        self.label = label
        self.verbose = verbose

    def run(self, *args, timeout=120, check=True):
        if self.verbose:
            print("docker " + " ".join(args), file=sys.stderr)
        try:
            proc = subprocess.run([self.exe, *args], capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise CheckFailure(f"docker {' '.join(args[:3])} did not finish within {timeout} s")
        if check and proc.returncode != 0:
            raise CheckFailure(f"docker {' '.join(args[:3])} failed: {(proc.stderr or proc.stdout).strip()[-400:]}")
        return proc

    def logs(self, name):
        proc = self.run("logs", name, check=False)
        return proc.stdout + proc.stderr

    def cleanup(self, volume, keep_volume):
        proc = self.run("ps", "-aq", "--filter", f"label={self.label}", check=False)
        ids = proc.stdout.split()
        if ids:
            self.run("rm", "-f", *ids, check=False)
        if volume and not keep_volume:
            self.run("volume", "rm", "-f", volume, check=False)


def check_image(docker, image):
    proc = docker.run("image", "inspect", image)
    data = json.loads(proc.stdout)
    if not data:
        raise CheckFailure(f"docker image inspect returned nothing for {image}")
    image_id = data[0].get("Id")
    problems = check_image_config(data[0].get("Config") or {})
    version = docker.run("run", "--rm", "--label", docker.label, image, "-v").stdout.strip()
    if not re.fullmatch(r"eski v=\S+", version):
        problems.append(f"-v printed {version!r}, expected 'eski v=<version>'")
    script = (
        "ls /usr/share/doc/eski; "
        + "".join(f"test ! -e {p} || echo found {p}; " for p in FORBIDDEN_PATHS)
        + "".join(f"command -v {t} >/dev/null 2>&1 && echo found {t}; " for t in FORBIDDEN_TOOLS)
        + "true"
    )
    listing = docker.run("run", "--rm", "--label", docker.label, "--entrypoint", "/bin/sh", image, "-c", script).stdout.split()
    for name in DOC_FILES:
        if name not in listing:
            problems.append(f"/usr/share/doc/eski lacks {name}")
    for i, word in enumerate(listing):
        if word == "found" and i + 1 < len(listing):
            problems.append(f"the runtime holds {listing[i + 1]}")
    if problems:
        raise CheckFailure("the image does not meet its contract: " + "; ".join(problems))
    return image_id, version


def wait_ready(docker, name, port, timeout):
    deadline = time.monotonic() + timeout
    last = "no attempt"
    while time.monotonic() < deadline:
        state = docker.run("inspect", "-f", "{{.State.Running}}", name, check=False).stdout.strip()
        if state != "true":
            raise CheckFailure(f"{name} exited during startup:\n{tail(docker.logs(name))}")
        try:
            conn = Conn.connect(port, timeout=5)
            try:
                reply = conn.call("PING")
            finally:
                conn.close()
            if reply == "PONG":
                return
            last = repr(reply)
        except OSError as e:
            last = str(e)
        time.sleep(0.2)
    raise CheckFailure(f"{name} did not answer PING on port {port} within {timeout} s ({last})")


def tail(log, n=15):
    lines = [line for line in log.splitlines() if line.strip()]
    return "\n".join("    " + line for line in lines[-n:])


def stop(docker, name, timeout):
    docker.run("kill", "--signal", "SIGTERM", name)
    code = docker.run("wait", name, timeout=timeout).stdout.strip()
    state = json.loads(docker.run("inspect", "-f", "{{json .State}}", name).stdout)
    log = docker.logs(name)
    docker.run("rm", name)
    problems = []
    if code != "0" or state.get("ExitCode") != 0:
        problems.append(f"exit code {code}")
    if state.get("OOMKilled"):
        problems.append("the container was killed for memory")
    problems += check_shutdown_log(log)
    if problems:
        raise CheckFailure(f"{name} did not shut down cleanly: " + "; ".join(problems) + f"\n{tail(log)}")
    return log


def check_files(docker, name):
    uid = docker.run("exec", name, "id", "-u").stdout.strip()
    if uid in ("", "0"):
        raise CheckFailure(f"{name} runs as uid {uid!r}")
    owner = docker.run("exec", name, "stat", "-c", "%u %s", f"{DATA_DIR}/dump.rdb").stdout.split()
    if len(owner) != 2 or owner[0] != uid or int(owner[1]) <= 0:
        raise CheckFailure(f"{DATA_DIR}/dump.rdb is not a non-empty file owned by uid {uid}: {owner}")
    return uid


def run_check(args, docker):
    image_id, version = check_image(docker, args.image)
    port = args.port or free_port()
    if not port_free(port):
        raise CheckFailure(f"port {port} is in use")
    volume = f"eski-check-{secrets.token_hex(6)}"
    docker.run("volume", "create", "--label", docker.label, volume)
    print(f"image   {args.image} {image_id} ({version})")
    print(f"volume  {volume}, port {port}, {args.replacements} replacements, server args {' '.join(SERVER_ARGS)}")
    expected = {}
    saved = None
    uid = None
    try:
        for k in range(args.replacements + 1):
            name = f"{volume}-{k}"
            docker.run(*run_argv(args.image, name, docker.label, volume, port))
            wait_ready(docker, name, port, args.ready_timeout)
            conn = Conn.connect(port)
            try:
                if k == 0:
                    if conn.must("DBSIZE") != 0:
                        raise CheckFailure("a fresh volume should start empty")
                else:
                    log = docker.logs(name)
                    loaded = loaded_keys(log)
                    if loaded != count_keys(expected):
                        raise CheckFailure(f"{name} loaded {loaded} keys, expected {count_keys(expected)}\n{tail(log)}")
                    problems = diff_snapshots(saved, snapshot(conn, expected))
                    if problems:
                        raise CheckFailure(f"{name} lost data after replacement {k}: " + "; ".join(problems[:10]))
                    check_intended(conn, expected)
                if k < args.replacements:
                    writes, intended = dataset(k)
                    write_all(conn, writes)
                    merge(expected, intended)
                    if conn.must("SAVE") != "OK":
                        raise CheckFailure("SAVE did not reply OK")
                    uid = check_files(docker, name)
                    after, after_intended = tail_writes(k)
                    write_all(conn, {0: after})
                    merge(expected, {0: after_intended})
                    check_intended(conn, expected)
                saved = snapshot(conn, expected)
            finally:
                conn.close()
            stop(docker, name, args.stop_timeout)
            kept = "generation 0" if k == 1 else f"generations 0-{k - 1}"
            if k == 0:
                print(f"start   {name}: wrote generation 0 ({count_keys(expected)} keys in db 0 and db {SECOND_DB}), SAVE, "
                      f"dump.rdb owned by uid {uid}, clean SIGTERM shutdown")
            elif k < args.replacements:
                print(f"replace {k}/{args.replacements} {name}: {kept} intact, wrote generation {k} "
                      f"({count_keys(expected)} keys), clean SIGTERM shutdown")
            else:
                print(f"replace {k}/{args.replacements} {name}: {kept} intact "
                      f"({count_keys(expected)} keys), clean SIGTERM shutdown")
    finally:
        docker.cleanup(volume, args.keep_volume)
    print(f"passed  {args.replacements} replacements on one volume, data and shutdown verified each time")


def parse_args(argv):
    ap = argparse.ArgumentParser(description="Check an Eski container image across real container replacements on one volume.")
    ap.add_argument("--image", default=DEFAULT_IMAGE, help=f"image to check (default {DEFAULT_IMAGE})")
    ap.add_argument("--replacements", type=int, default=3, help="container replacements on the same volume (default 3, at least 3)")
    ap.add_argument("--port", type=int, default=0, help=f"host port (default: a free port in {PORT_RANGE[0]}-{PORT_RANGE[1]})")
    ap.add_argument("--ready-timeout", type=float, default=30.0)
    ap.add_argument("--stop-timeout", type=float, default=60.0)
    ap.add_argument("--keep-volume", action="store_true", help="keep the volume for inspection")
    ap.add_argument("--docker", default="docker", help="docker executable")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)
    if args.replacements < 3:
        ap.error("--replacements must be at least 3")
    if args.port and not 1024 < args.port < 65536:
        ap.error("--port must be between 1025 and 65535")
    return args


def main(argv=None):
    args = parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)
    docker = Docker(args.docker, f"eski-container-check={secrets.token_hex(6)}", args.verbose)
    try:
        run_check(args, docker)
    except CheckFailure as e:
        print(f"FAILED: {e}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as e:
        print(f"FAILED: {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
