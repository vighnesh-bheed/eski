import argparse
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "rdb"))
import resp


def memory(client):
    return dict(line.split(":", 1) for line in client.check("INFO", "memory").decode().splitlines() if ":" in line)


def stats(client):
    result = client.check("MEMORY", "STATS")
    return dict(zip(result[::2], result[1::2]))


def empty_tables(client):
    for _ in range(1000):
        if stats(client)[b"overhead.db.hashtable.lut"] == 0 and int(memory(client)["lazyfree_pending_objects"]) == 0:
            return
        time.sleep(0.001)
    raise AssertionError("detached table ownership did not drain")


def ready(port, process):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("test server exited during startup")
        try:
            return resp.Client(port)
        except OSError:
            time.sleep(0.01)
    raise RuntimeError("test server did not become ready")


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", type=Path, default=Path("bin/eski"))
    parser.add_argument("--port", type=int, default=6731)
    args = parser.parse_args()
    binary = args.server.resolve()
    checked = 0
    with tempfile.TemporaryDirectory(prefix="eski-storage-server-") as temporary:
        work = Path(temporary)
        with (work / "server.log").open("wb") as log:
            def start():
                return subprocess.Popen([str(binary), "--port", str(args.port), "--dir", str(work), "--save", "", "--appendonly", "no"], cwd=work, stdout=log, stderr=log)

            process = start()
            client = ready(args.port, process)
            try:
                for protocol in (2, 3):
                    client.check("HELLO", protocol)
                    client.check("FLUSHALL", "SYNC")
                    empty_tables(client)
                    assert stats(client)[b"overhead.db.hashtable.lut"] == 0, (protocol, stats(client))
                    client.check("SET", "a", "b")
                    table = stats(client)
                    db = dict(zip(table[b"db.0"][::2], table[b"db.0"][1::2]))
                    assert table[b"overhead.db.hashtable.lut"] == db[b"overhead.hashtable.main"] == 4096
                    client.check("DEL", "a")
                    assert stats(client)[b"overhead.db.hashtable.lut"] == 4096
                    client.check("FLUSHDB", "SYNC")
                    empty_tables(client)
                    assert stats(client)[b"overhead.db.hashtable.lut"] == 0, (protocol, stats(client))
                    checked += 4
                    client.check("SET", b"k" * 5000, b"v" * 5000)
                    assert stats(client)[b"dataset.bytes"] == 10024
                    client.check("FLUSHDB", "SYNC")
                    empty_tables(client)
                    assert stats(client)[b"dataset.bytes"] == 0
                    checked += 2
                    time.sleep(0.15)
                    info = memory(client)
                    assert int(info["used_memory_rss"]) > 0 and int(info["allocator_allocated"]) > 0
                    assert all(float(info[name]) == 0 for name in ("allocator_active", "allocator_resident", "allocator_muzzy", "allocator_frag_ratio", "allocator_rss_ratio", "rss_overhead_ratio"))
                    checked += 2
                    client.check("CONFIG", "SET", "maxmemory", int(info["used_memory"]) + 1024 * 1024)
                    commands = []
                    for i in range(48):
                        commands.extend([("MULTI",), ("FLUSHDB", "SYNC"), ("SET", "keep", b"x" * 5000), ("EXEC",)])
                    replies = client.pipeline(commands)
                    for i in range(0, len(replies), 4):
                        assert replies[i:i + 4] == ["OK", "QUEUED", "QUEUED", ["OK", "OK"]], repr(replies[i:i + 4])
                    assert client.check("GET", "keep") == b"x" * 5000
                    client.check("CONFIG", "SET", "maxmemory", 0)
                    checked += 49
                    client.check("FLUSHDB", "ASYNC")
                    client.check("SET", "post-flush", "present")
                    for _ in range(100):
                        if int(memory(client)["lazyfree_pending_objects"]) == 0:
                            break
                        time.sleep(0.01)
                    assert client.check("GET", "post-flush") == b"present"
                    assert int(memory(client)["lazyfree_pending_objects"]) == 0
                    checked += 2
                client.check("SET", "persisted", b"payload\x00" * 900)
                client.check("BGSAVE")
                client.check("FLUSHDB", "ASYNC")
                client.check("SET", "new-parent", "kept")
                for _ in range(1000):
                    persistence = client.check("INFO", "persistence")
                    if b"rdb_bgsave_in_progress:0\r\n" in persistence:
                        break
                    time.sleep(0.01)
                assert client.check("GET", "new-parent") == b"kept"
                assert b"rdb_last_bgsave_status:ok\r\n" in persistence
                checked += 2
                client.check("SAVE")
                client.close()
                stop(process)
                process = start()
                client = ready(args.port, process)
                assert client.check("GET", "new-parent") == b"kept"
                assert stats(client)[b"overhead.db.hashtable.lut"] >= 4096
                checked += 2
                print("PASS storage server RESP2/RESP3, pipelined flush/write and persistence checks=%d" % checked)
            except Exception:
                sys.stderr.write((work / "server.log").read_text(errors="replace")[-6000:])
                raise
            finally:
                client.close()
                if process.poll() is None:
                    stop(process)


if __name__ == "__main__":
    main()
