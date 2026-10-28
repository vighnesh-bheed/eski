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
    with tempfile.TemporaryDirectory(prefix="eski-set-idle-") as temporary:
        work = Path(temporary)
        with (work / "server.log").open("wb") as log:
            process = subprocess.Popen([str(binary), "--port", str(args.port), "--dir", str(work), "--save", "", "--appendonly", "no", "--enable-debug-command", "yes"], cwd=work, stdout=log, stderr=log)
            client = storage_server.ready(args.port, process)
            try:
                client.check("DEBUG", "SET-ACTIVE-EXPIRE", 0)
                for protocol, size, database in ((2, 3072, 3), (3, 12288, 7)):
                    client.check("HELLO", protocol)
                    client.check("SELECT", database)
                    client.check("FLUSHALL", "SYNC")
                    for first in range(0, size, 256):
                        fields = []
                        for i in range(first, min(size, first + 256)):
                            fields.append(b"member:%06d" % i)
                        client.check("SADD", "idle-set", *fields)
                    before = client.check("MEMORY", "USAGE", "idle-set", "SAMPLES", 0)
                    new_member = b"member:%06d\x00tail" % size
                    client.check("SADD", "idle-set", new_member)
                    active = client.check("MEMORY", "USAGE", "idle-set", "SAMPLES", 0)
                    settled_ceiling = before + (size // 3 * 4) * 16 + 256
                    if active <= settled_ceiling:
                        raise AssertionError(("fixture did not retain a dual-bank growth", protocol, size, before, active, settled_ceiling))
                    started = time.monotonic()
                    time.sleep(args.idle_seconds)
                    after = client.check("MEMORY", "USAGE", "idle-set", "SAMPLES", 0)
                    elapsed = time.monotonic() - started
                    if after > settled_ceiling:
                        raise AssertionError(("idle migration did not finish with field expiry disabled", protocol, size, active, after, settled_ceiling, elapsed))
                    assert client.check("SCARD", "idle-set") == size + 1
                    assert client.check("SISMEMBER", "idle-set", new_member) == 1
                    rows.append(dict(protocol=protocol, database=database, members=size, active_bytes=active, settled_bytes=after, idle_observation_seconds=elapsed, command_free_sleep_seconds=args.idle_seconds))
            finally:
                client.close()
                storage_server.stop(process)
    print(json.dumps(dict(checks=8, cases=rows, limit="Completion is measured after a command-free idle interval; this is an upper bound, not a precise completion timestamp or event-loop latency measurement."), sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
