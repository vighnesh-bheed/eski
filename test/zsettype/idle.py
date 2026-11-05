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
    with tempfile.TemporaryDirectory(prefix="eski-zset-idle-") as temporary:
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
                    keys = ("idle-zset-a", "idle-zset-b")
                    for key in keys:
                        for first in range(0, size, 256):
                            fields = []
                            for i in range(first, min(size, first + 256)):
                                fields.extend((i, b"member:%06d" % i))
                            client.check("ZADD", key, *fields)
                    before = [client.check("MEMORY", "USAGE", key, "SAMPLES", 0) for key in keys]
                    member = b"member:%06d\x00tail" % size
                    assert client.pipeline([("ZADD", key, size + 1, member) for key in keys]) == [1, 1]
                    active = client.pipeline([("MEMORY", "USAGE", key, "SAMPLES", 0) for key in keys])
                    ceilings = [value + (size // 3 * 4) * 8 + 1024 for value in before]
                    if any(value <= ceiling for value, ceiling in zip(active, ceilings)):
                        raise AssertionError(("fixture did not retain two active zset dictionary jobs", protocol, database, size, before, active, ceilings))
                    started = time.monotonic()
                    time.sleep(args.idle_seconds)
                    after = client.pipeline([("MEMORY", "USAGE", key, "SAMPLES", 0) for key in keys])
                    elapsed = time.monotonic() - started
                    if any(value > ceiling for value, ceiling in zip(after, ceilings)):
                        raise AssertionError(("idle zset jobs did not finish with active expiry disabled", protocol, database, size, active, after, ceilings, elapsed))
                    for key in keys:
                        assert client.check("ZCARD", key) == size + 1
                        assert float(client.check("ZSCORE", key, member)) == size + 1
                    rows.append(dict(protocol=protocol, database=database, members_per_job=size, jobs=2, active_bytes=active, settled_bytes=after, idle_observation_seconds=elapsed, command_free_sleep_seconds=args.idle_seconds))
            finally:
                client.close()
                storage_server.stop(process)
    print(json.dumps(dict(checks=16, cases=rows, limit="Both jobs complete within a command-free idle observation interval; this is an upper bound, not an exact completion timestamp or event-loop latency measurement."), sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
