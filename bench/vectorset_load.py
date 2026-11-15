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


class Conn:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=600)
        self.buf = b""

    def send(self, cmds):
        out = bytearray()
        for c in cmds:
            out += b"*%d\r\n" % len(c)
            for a in c:
                a = a if isinstance(a, bytes) else str(a).encode()
                out += b"$%d\r\n%s\r\n" % (len(a), a)
        self.s.sendall(out)

    def fill(self):
        d = self.s.recv(1 << 20)
        if not d:
            raise EOFError("the server closed the connection")
        self.buf += d

    def end(self, at):
        while True:
            e = self.buf.find(b"\r\n", at)
            if e >= 0:
                break
            self.fill()
        kind = self.buf[at:at + 1]
        if kind in b"+-:":
            return e + 2
        n = int(self.buf[at + 1:e])
        if kind == b"$":
            if n < 0:
                return e + 2
            while len(self.buf) < e + 2 + n + 2:
                self.fill()
            return e + 2 + n + 2
        p = e + 2
        for _ in range(max(n, 0)):
            p = self.end(p)
        return p

    def read(self):
        stop = self.end(0)
        r = self.buf[:stop]
        self.buf = self.buf[stop:]
        return r

    def many(self, cmds, batch=1000):
        out = []
        for i in range(0, len(cmds), batch):
            part = cmds[i:i + batch]
            self.send(part)
            out += [self.read() for _ in part]
        return out

    def call(self, *c):
        return self.many([list(c)])[0]


def bulk(raw):
    e = raw.index(b"\r\n")
    n = int(raw[1:e])
    return raw[e + 2:e + 2 + n]


def command_usec(c, name):
    for line in c.call("INFO", "commandstats").decode().splitlines():
        if line.startswith("cmdstat_%s:" % name):
            fields = dict(kv.split("=") for kv in line.split(":", 1)[1].split(","))
            return int(fields["calls"]), int(fields["usec"])
    return 0, 0


def start(binary, port, folder, cpu):
    os.makedirs(folder, exist_ok=True)
    log = open(os.path.join(folder, "server.log"), "ab")
    args = [binary, "--port", str(port), "--bind", "127.0.0.1", "--dir", folder, "--save", "", "--appendonly", "no"]
    if cpu is not None:
        args = ["taskset", "-c", str(cpu)] + args
    proc = subprocess.Popen(args, stdout=log, stderr=log)
    for _ in range(600):
        try:
            c = Conn(port)
            if c.call("PING") == b"+PONG\r\n":
                return proc, c
        except OSError:
            pass
        time.sleep(0.05)
    proc.terminate()
    raise SystemExit("the server did not answer")


def main():
    parser = argparse.ArgumentParser(description="Measure how long a vector set takes to load from its version 2 payload, which carries the graph, against rebuilding the same set with VADD, using the server's own command statistics. Coordinate the CPU window before running.")
    parser.add_argument("--server", default="bin/eski")
    parser.add_argument("--port", type=int, default=6499)
    parser.add_argument("--size", type=int, default=20000)
    parser.add_argument("--dim", type=int, default=64)
    parser.add_argument("--quant", default="Q8", choices=("Q8", "NOQUANT", "BIN"))
    parser.add_argument("--m", type=int, default=16)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--out")
    args = parser.parse_args()
    work = tempfile.mkdtemp(prefix="eski-vectorset-load.")
    proc = None
    try:
        proc, c = start(os.path.abspath(args.server), args.port, work, args.cpu)
        r = random.Random(args.size)
        vectors = [["%.4f" % r.uniform(-1, 1) for _ in range(args.dim)] for _ in range(args.size)]
        build = [["VADD", "load:origin", "VALUES", args.dim] + v + ["e%d" % i, args.quant, "M", args.m] for i, v in enumerate(vectors)]
        if any(x.startswith(b"-") for x in c.many(build)):
            raise SystemExit("building the set failed")
        payload = bulk(c.call("DUMP", "load:origin"))
        rows = []
        for n in range(args.rounds):
            c.call("CONFIG", "RESETSTAT")
            reply = c.call("RESTORE", "load:restored:%d" % n, 0, payload)
            if reply != b"+OK\r\n":
                raise SystemExit("RESTORE failed: %r" % reply)
            calls, restore_usec = command_usec(c, "restore")
            c.call("CONFIG", "RESETSTAT")
            again = [["VADD", "load:rebuilt:%d" % n] + cmd[2:] for cmd in build]
            c.many(again)
            vcalls, vadd_usec = command_usec(c, "vadd")
            same = c.call("VCARD", "load:restored:%d" % n) == c.call("VCARD", "load:rebuilt:%d" % n)
            rows.append({"round": n, "restore_calls": calls, "restore_usec": restore_usec, "vadd_calls": vcalls, "vadd_usec": vadd_usec, "same_card": same})
            c.many([["DEL", "load:restored:%d" % n], ["DEL", "load:rebuilt:%d" % n]])
        result = {"size": args.size, "dim": args.dim, "quant": args.quant, "m": args.m, "payload_bytes": len(payload), "rounds": rows}
        text = json.dumps(result, indent=2)
        if args.out:
            with open(args.out, "w") as f:
                f.write(text + "\n")
        print(text)
    finally:
        if proc is not None:
            proc.terminate()
            proc.wait()
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
