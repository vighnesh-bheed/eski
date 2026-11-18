import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "storage"))
import server as storage_server


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", type=Path, default=Path("bin/eski"))
    parser.add_argument("--port", type=int, default=6732)
    parser.add_argument("--idle-seconds", type=float, default=2)
    args = parser.parse_args()
    if args.idle_seconds <= 0:
        parser.error("idle duration must be positive")
    binary = args.server.resolve()
    rows = []
    with tempfile.TemporaryDirectory(prefix="eski-hash-idle-") as temporary:
        work = Path(temporary)
        with (work / "server.log").open("wb") as log:
            process = subprocess.Popen([str(binary), "--port", str(args.port), "--bind", "127.0.0.1", "--dir", str(work), "--save", "", "--appendonly", "no", "--enable-debug-command", "yes"], cwd=work, stdout=log, stderr=log)
            client = storage_server.ready(args.port, process)
            try:
                client.check("DEBUG", "SET-ACTIVE-EXPIRE", 0)
                for protocol, size in ((2, 3072), (3, 12288)):
                    client.check("HELLO", protocol)
                    client.check("FLUSHALL", "SYNC")
                    for first in range(0, size, 256):
                        fields = []
                        for i in range(first, min(size, first + 256)):
                            fields.extend((b"field:%06d" % i, b"value\x00suffix"))
                        client.check("HSET", "idle-hash", *fields)
                    client.check("HSET", "idle-hash", b"field:%06d" % size, b"value\x00suffix")
                    active = storage_server.hash_table_banks(client.check("DEBUG", "HTSTATS-KEY", "idle-hash"))
                    if active != 2:
                        raise AssertionError(("fixture did not retain a dual-bank growth", protocol, size, active))
                    started = time.monotonic()
                    time.sleep(args.idle_seconds)
                    after = storage_server.hash_table_banks(client.check("DEBUG", "HTSTATS-KEY", "idle-hash"))
                    elapsed = time.monotonic() - started
                    if after != 1:
                        raise AssertionError(("idle migration did not finish with active expiry disabled", protocol, size, active, after, elapsed))
                    assert client.check("HLEN", "idle-hash") == size + 1
                    assert client.check("HGET", "idle-hash", b"field:%06d" % size) == b"value\x00suffix"
                    rows.append(dict(protocol=protocol, fields=size, active_banks=active, settled_banks=after, idle_observation_seconds=elapsed, command_free_sleep_seconds=args.idle_seconds))
            finally:
                client.close()
                storage_server.stop(process)
    print(json.dumps(dict(checks=8, cases=rows, limit="Completion is checked after a command-free idle interval; this is an upper observation bound, not a precise completion timestamp or event-loop latency measurement."), sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
