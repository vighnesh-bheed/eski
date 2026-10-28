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
    parser.add_argument("--port", type=int, default=6735)
    args = parser.parse_args()
    binary = args.server.resolve()
    cases = []
    with tempfile.TemporaryDirectory(prefix="eski-slab-server-") as temporary:
        work = Path(temporary)
        with (work / "server.log").open("wb") as log:
            process = subprocess.Popen([str(binary), "--port", str(args.port), "--dir", str(work), "--save", "", "--appendonly", "no", "--enable-debug-command", "yes"], cwd=work, stdout=log, stderr=log)
            client = storage_server.ready(args.port, process)
            try:
                client.check("DEBUG", "SET-ACTIVE-EXPIRE", 0)
                for protocol, database in ((2, 3), (3, 7)):
                    client.check("HELLO", protocol)
                    client.check("SELECT", database)
                    client.check("FLUSHALL", "SYNC")
                    client.check("SET", "i", b"inline")
                    heap_key, heap_value = b"heap\x00" * 1000, b"value\x00" * 1000
                    client.check("SET", heap_key, heap_value)
                    assert client.check("HSET", "h", "field", b"object\x00value") == 1
                    keeper = bytes(range(96))
                    client.check("SET", "keep", keeper)
                    keys = [b"r%05d" % i for i in range(512)]
                    short, long = bytes(range(64)), bytes(range(256)) * 2
                    assert client.pipeline([("SET", key, short) for key in keys]) == ["OK"] * len(keys)
                    assert client.pipeline([("DEL", key) for key in keys]) == [1] * len(keys)
                    time.sleep(2)
                    assert client.check("GET", "keep") == keeper
                    assert client.pipeline([("SET", key, long) for key in keys]) == ["OK"] * len(keys)
                    assert client.pipeline([("GET", key) for key in keys]) == [long] * len(keys)
                    assert client.pipeline([("DEL", key) for key in keys]) == [1] * len(keys)
                    assert client.check("DEL", "keep") == 1
                    time.sleep(2)
                    assert client.check("DBSIZE") == 3
                    assert client.check("GET", "i") == b"inline"
                    assert client.check("GET", heap_key) == heap_value
                    assert client.check("HGET", "h", "field") == b"object\x00value"
                    client.check("SET", "fresh", keeper)
                    assert client.check("GET", "fresh") == keeper
                    info = storage_server.memory(client)
                    client.check("CONFIG", "SET", "maxmemory", int(info["used_memory"]) + 2 * 1024 * 1024)
                    sequence = []
                    for _ in range(8):
                        sequence.extend([("MULTI",), ("FLUSHDB", "SYNC"), ("SET", "fresh", keeper), ("EXEC",)])
                    replies = client.pipeline(sequence)
                    assert all(replies[i:i + 4] == ["OK", "QUEUED", "QUEUED", ["OK", "OK"]] for i in range(0, len(replies), 4))
                    assert client.check("GET", "fresh") == keeper
                    client.check("CONFIG", "SET", "maxmemory", 0)
                    cases.append(dict(protocol=protocol, database=database, keys=512, binary_value_lengths=[64, 96, 512, 6000], command_free_partial_seconds=2, command_free_zero_seconds=2))
            finally:
                client.close()
                storage_server.stop(process)
    print(json.dumps(dict(checks=30, cases=cases, limits="Wire correctness and quiet lifecycle proof only. Native descriptor, ownership and mapping-specific RSS fixtures establish allocator reuse/reclaim; these commands do not expose internal run counters or claim throughput."), sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
