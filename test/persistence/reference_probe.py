import argparse
import datetime
import os
import socket
import subprocess
import sys
import tempfile
import time


def resp(args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        if isinstance(a, str):
            a = a.encode()
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


def read(f):
    line = f.readline()
    if not line:
        raise ConnectionError("connection closed")
    t, body = line[:1], line[1:-2]
    if t in b"+-:":
        return (t.decode(), body)
    if t == b"$":
        n = int(body)
        if n < 0:
            return ("$", None)
        return ("$", f.read(n + 2)[:-2])
    if t == b"*":
        return ("*", [read(f) for _ in range(int(body))])
    return ("?", line)


class Client:
    def __init__(self, host, port, wait=10.0):
        deadline = time.monotonic() + wait
        while True:
            try:
                self.sock = socket.create_connection((host, port), 1)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise SystemExit("no server on %s:%d" % (host, port))
                time.sleep(0.1)
        self.file = self.sock.makefile("rb")

    def cmd(self, *args):
        self.sock.sendall(resp(args))
        return read(self.file)

    def close(self):
        self.sock.close()


def rdb_len(n):
    if n < 64:
        return bytes([n])
    if n < 16384:
        return bytes([0x40 | (n >> 8), n & 0xFF])
    if n < 1 << 32:
        return b"\x80" + n.to_bytes(4, "big")
    return b"\x81" + n.to_bytes(8, "big")


def rdb_str(b):
    return rdb_len(len(b)) + b


def start_eski(binary, port, work, extra=()):
    d = tempfile.mkdtemp(dir=work)
    log = open(os.path.join(d, "log"), "wb")
    p = subprocess.Popen([binary, "--port", str(port), "--dir", d, "--save", "", "--appendonly", "no", "--enable-debug-command", "yes", *extra], stdout=log, stderr=subprocess.STDOUT)
    return p, d


def start_reference(image, port, name, volume=None, extra=()):
    args = ["docker", "run", "-d", "--rm", "--network=host", "--name", name]
    if volume:
        args += ["-v", volume + ":/data", "--user", "%d:%d" % (os.getuid(), os.getgid())]
    args += [image, "redis-server", "--port", str(port), "--save", "", "--appendonly", "no", "--enable-debug-command", "yes", *extra]
    subprocess.run(args, check=True, capture_output=True)


def stop_reference(name):
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)


def image_id(image):
    out = subprocess.run(["docker", "inspect", image, "--format", "{{.Id}}"], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else "unknown"


def restore_half(reference, eski):
    for label, c in (("eski", eski), ("redis", reference)):
        print(label, "skip-checksum", c.cmd("DEBUG", "SET-SKIP-CHECKSUM-VALIDATION", "1"))
    reference.cmd("DEL", "h")
    reference.cmd("HSET", "h", "f", "v")
    print("hpexpireat", reference.cmd("HPEXPIREAT", "h", "4102444800000", "FIELDS", "1", "f"))
    _, dump = reference.cmd("DUMP", "h")
    print("dump type", dump[0], "len", len(dump))
    version, blob = dump[-10:-8], dump[9:-10]
    payloads = (
        ("type25", b"\x19" + dump[1:9] + blob + version + b"\x00" * 8),
        ("type23", b"\x17" + blob + version + b"\x00" * 8),
        ("type22", b"\x16" + rdb_len(1) + rdb_len(4102444800000) + rdb_str(b"f") + rdb_str(b"v") + version + b"\x00" * 8),
    )
    for name, payload in payloads:
        for label, c in (("eski", eski), ("redis", reference)):
            result = c.cmd("RESTORE", name, "0", payload, "REPLACE")
            print(label, name, "restore", result, "encoding", c.cmd("OBJECT", "ENCODING", name), "hpexpiretime", c.cmd("HPEXPIRETIME", name, "FIELDS", "1", "f"), "hgetall", c.cmd("HGETALL", name))


def file_half(args):
    volume = tempfile.mkdtemp(dir=args.work)
    os.chmod(volume, 0o777)
    rdb = b"REDIS0012" + b"\xfe\x00" + b"\xf4" + rdb_len(1) + rdb_len(4) + rdb_len(2) + b"\x00" + rdb_str(b"k") + rdb_str(b"v") + b"\xff" + b"\x00" * 8
    with open(os.path.join(volume, "slot.rdb"), "wb") as f:
        f.write(rdb)
    name = "eski-reference-probe-file-%d" % os.getpid()
    start_reference(args.image, args.file_port, name, volume, ("--dbfilename", "slot.rdb"))
    try:
        c = Client(args.host, args.file_port)
        print("redis opcode 244 file: GET k ->", c.cmd("GET", "k"), "DBSIZE", c.cmd("DBSIZE"))
        c.close()
    finally:
        stop_reference(name)
    work = tempfile.mkdtemp(dir=args.work)
    with open(os.path.join(work, "slot.rdb"), "wb") as f:
        f.write(rdb)
    log = open(os.path.join(work, "log"), "wb")
    p = subprocess.Popen([args.binary, "--port", str(args.file_port + 1), "--dir", work, "--dbfilename", "slot.rdb", "--save", "", "--appendonly", "no"], stdout=log, stderr=subprocess.STDOUT)
    try:
        c = Client("127.0.0.1", args.file_port + 1, 3.0)
        print("eski opcode 244 file: GET k ->", c.cmd("GET", "k"), "DBSIZE", c.cmd("DBSIZE"))
        c.close()
    except SystemExit:
        print("eski opcode 244 file: exit code", p.poll())
        with open(os.path.join(work, "log"), "rb") as f:
            print(f.read().decode(errors="replace")[-300:])
    finally:
        if p.poll() is None:
            p.terminate()
            p.wait()


def main():
    parser = argparse.ArgumentParser(description="probe the reference server for acceptance of RDB types 22 and 23 and opcode 244")
    parser.add_argument("--host", default="127.0.0.1", help="host of the servers this script starts and probes")
    parser.add_argument("--port", type=int, default=6610, help="port for the reference container; the Eski instance uses the next port")
    parser.add_argument("--file-port", type=int, default=6612, help="base port for the snapshot-file half; two consecutive ports are used")
    parser.add_argument("--image", default="docker.io/library/redis:7", help="reference server image")
    parser.add_argument("--binary", default="bin/eski", help="Eski executable")
    parser.add_argument("--work", default=None, help="scratch directory; a temporary one by default")
    args = parser.parse_args()
    args.work = args.work or tempfile.mkdtemp(prefix="eski-reference-probe.")
    print("image", args.image, image_id(args.image), "date", datetime.date.today().isoformat())
    name = "eski-reference-probe-%d" % os.getpid()
    start_reference(args.image, args.port, name)
    eski_proc, _ = start_eski(args.binary, args.port + 1, args.work)
    try:
        reference = Client(args.host, args.port)
        eski = Client(args.host, args.port + 1)
        _, info = reference.cmd("INFO", "server")
        version = [l for l in info.decode().splitlines() if l.startswith("redis_version:")]
        print("reference", version[0] if version else "unknown")
        restore_half(reference, eski)
        reference.close()
        eski.close()
    finally:
        stop_reference(name)
        eski_proc.terminate()
        eski_proc.wait()
    file_half(args)


if __name__ == "__main__":
    main()
