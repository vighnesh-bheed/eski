import argparse
import hashlib
import json
import os
import random
import statistics
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test", "rdb"))
import resp


def receive(sock, length):
    while length:
        data = sock.recv(min(length, 65536))
        if not data:
            raise EOFError("connection closed during SORT benchmark")
        length -= len(data)


def encoded_reply(values):
    return b"*%d\r\n" % len(values) + b"".join(b"$%d\r\n%s\r\n" % (len(v), v) for v in values)


def run(client, request, reply_length, pipeline, seconds):
    batch = request * pipeline
    batch_length = reply_length * pipeline
    latencies = []
    count = 0
    start = time.perf_counter_ns()
    deadline = start + int(seconds * 1e9)
    now = start
    while now < deadline:
        before = time.perf_counter_ns()
        client.sock.sendall(batch)
        receive(client.sock, batch_length)
        now = time.perf_counter_ns()
        latencies.append((now - before) / 1e6)
        count += pipeline
    elapsed = (now - start) / 1e9
    latencies.sort()
    return {
        "operations": count,
        "elapsed_seconds": elapsed,
        "ops_per_second": count / elapsed,
        "batch_median_ms": statistics.median(latencies),
        "batch_p99_ms": latencies[min(len(latencies) - 1, int(len(latencies) * 0.99))],
        "batch_max_ms": max(latencies),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", action="append", required=True, metavar="NAME:PORT")
    parser.add_argument("--seconds", type=float, default=5)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--pipeline", type=int, default=1)
    parser.add_argument("--size", type=int, default=300)
    parser.add_argument("--prefix-bytes", type=int, default=256)
    parser.add_argument("--output")
    args = parser.parse_args()
    if args.seconds <= 0 or min(args.rounds, args.pipeline, args.size) < 1 or args.prefix_bytes < 0:
        parser.error("durations, rounds, pipeline and size must be positive; prefix length must be nonnegative")
    targets = [(name, int(port)) for name, port in (target.rsplit(":", 1) for target in args.target)]
    if len(set(name for name, _ in targets)) != len(targets):
        parser.error("target names must be unique")
    clients = {name: resp.Client(port) for name, port in targets}
    key = "bench:sort:%d" % os.getpid()
    rows = []
    shapes = {
        "short": [b"v%06d" % i for i in range(args.size)],
        "long-prefix": [b"x" * args.prefix_bytes + b":%06d" % i for i in range(args.size)],
        "binary": [b"%06d\x00tail\xff\x80" % i for i in range(args.size)],
    }
    try:
        for client in clients.values():
            client.sock.settimeout(max(10, args.seconds * 2))
        for shape, values in shapes.items():
            random.Random(1729).shuffle(values)
            for client in clients.values():
                client.check("DEL", key)
                client.check("RPUSH", key, *values)
            expected = sorted(values, key=lambda value: value.split(b"\x00", 1)[0])
            for mode, limit in (("full", ()), ("limit", ("LIMIT", 0, 1))):
                command = ("SORT", key, "ALPHA", *limit)
                selected = expected[:1] if limit else expected
                reply = encoded_reply(selected)
                request = resp.Client._encode(command)
                for name, client in clients.items():
                    if client.check(*command) != selected:
                        raise AssertionError("%s %s %s SORT returned unexpected bytes" % (name, shape, mode))
                    run(client, request, len(reply), args.pipeline, min(0.25, args.seconds))
                for round_number in range(args.rounds):
                    order = list(clients)
                    random.Random(1729 + round_number).shuffle(order)
                    for name in order:
                        result = run(clients[name], request, len(reply), args.pipeline, args.seconds)
                        if clients[name].check(*command) != selected:
                            raise AssertionError("%s SORT result changed after timing" % name)
                        row = {"target": name, "shape": shape, "mode": mode, "round": round_number + 1, "pipeline": args.pipeline, "list_size": args.size, "reply_bytes": len(reply), "reply_sha256": hashlib.sha256(reply).hexdigest(), **result}
                        rows.append(row)
                        print(json.dumps(row), flush=True)
    finally:
        for client in clients.values():
            try:
                client.check("DEL", key)
            finally:
                client.close()
        if args.output:
            with open(args.output, "w") as handle:
                json.dump({"parameters": vars(args), "results": rows}, handle, indent=2)


if __name__ == "__main__":
    main()
