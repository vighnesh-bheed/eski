import contextlib
import io
import json
import os
import socket
import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import check


GOOD_SHUTDOWN = """1:M 28 Oct 2026 20:57:32.507 * Done loading RDB, keys loaded: 23, keys expired: 0.
1:M 28 Oct 2026 20:57:32.507 * DB loaded from disk: 0.000 seconds
eski 0.1.0 listening on 0.0.0.0:16391 pid 1
1:M 28 Oct 2026 20:57:33.203 # Received SIGTERM scheduling shutdown...
1:M 28 Oct 2026 20:57:33.210 # User requested shutdown...
1:M 28 Oct 2026 20:57:33.210 * Saving the final RDB snapshot before exiting.
1:M 28 Oct 2026 20:57:33.210 * DB saved on disk
1:M 28 Oct 2026 20:57:33.210 # Eski is now ready to exit, bye bye...
"""

GOOD_CONFIG = {
    "User": "10001:10001",
    "WorkingDir": "/data",
    "Volumes": {"/data": {}},
    "Entrypoint": ["/usr/local/bin/eski"],
    "ExposedPorts": {"6399/tcp": {}},
    "StopSignal": "SIGTERM",
}


FAKE_DOCKER = '''#!{python}
import json
import os
import sys
args = sys.argv[1:]
with open(os.environ["FAKE_DOCKER_LOG"], "a") as f:
    f.write(json.dumps(args) + "\\n")
config = json.loads(os.environ["FAKE_DOCKER_CONFIG"])
if args[:2] == ["image", "inspect"]:
    print(json.dumps([{{"Id": "sha256:" + "ab" * 32, "Config": config}}]))
elif args[0] == "run" and "-d" in args:
    print("docker: cannot start the server", file=sys.stderr)
    sys.exit(125)
elif args[0] == "run" and "--entrypoint" in args:
    print(os.environ.get("FAKE_DOCKER_LISTING", "LICENSE THIRD_PARTY_NOTICES.md ODIN-LICENSE build-info.txt"))
elif args[0] == "run":
    print(os.environ.get("FAKE_DOCKER_VERSION", "eski v=0.1.0 license=Apache-2.0"))
elif args[:2] == ["volume", "create"]:
    print(args[-1])
elif args[0] == "ps":
    print("c0ffee")
'''


def serve(chunks):
    a, b = socket.socketpair()

    def writer():
        for chunk in chunks:
            b.sendall(chunk)
        b.close()

    t = threading.Thread(target=writer)
    t.start()
    return check.Conn(a), t


class RespTest(unittest.TestCase):
    def test_encode_handles_text_bytes_and_numbers(self):
        self.assertEqual(check.encode(["SET", b"k\r\n", 5]), b"*3\r\n$3\r\nSET\r\n$3\r\nk\r\n\r\n$1\r\n5\r\n")

    def test_replies_split_across_reads(self):
        data = b"+OK\r\n-ERR bad\r\n:42\r\n$-1\r\n$0\r\n\r\n*2\r\n*1\r\n$3\r\nabc\r\n:7\r\n$4\r\na\r\nb\r\n"
        conn, t = serve([data[i:i + 3] for i in range(0, len(data), 3)])
        try:
            self.assertEqual(conn.reply(), "OK")
            self.assertEqual(conn.reply(), check.ReplyError("ERR bad"))
            self.assertEqual(conn.reply(), 42)
            self.assertIsNone(conn.reply())
            self.assertEqual(conn.reply(), b"")
            self.assertEqual(conn.reply(), [[b"abc"], 7])
            self.assertEqual(conn.reply(), b"a\r\nb")
            with self.assertRaises(ConnectionError):
                conn.reply()
        finally:
            conn.close()
            t.join()

    def test_must_raises_on_error_replies(self):
        class Canned(check.Conn):
            def call(self, *args):
                return check.ReplyError("WRONGTYPE Operation against a key holding the wrong kind of value")

        with self.assertRaises(check.CheckFailure) as caught:
            Canned(None).must("GET", "k")
        self.assertIn("WRONGTYPE", str(caught.exception))


class DatasetTest(unittest.TestCase):
    def test_every_type_is_written_in_two_databases(self):
        writes, expected = check.dataset(0)
        kinds = {kind for keys in expected.values() for kind, _ in keys.values()}
        self.assertEqual(kinds, {"string", "list", "hash", "set", "zset", "stream"})
        self.assertEqual(sorted(writes), [0, check.SECOND_DB])
        scripts = [argv for argv in writes[0] if argv[0] == "EVAL"]
        self.assertEqual(scripts, [("EVAL", "return redis.call('SET',KEYS[1],ARGV[1])", 1, "g0:script", "script-0")])
        self.assertEqual(expected[0][scripts[0][3]], ("string", scripts[0][4].encode()))
        for db in writes:
            effect_keys = {argv[3] if argv[0] == "EVAL" else argv[1] for argv in writes[db]}
            for key in expected[db]:
                self.assertIn(key, effect_keys)
        self.assertTrue(any(argv[0] == "PFADD" for argv in writes[0]))
        self.assertTrue(any(argv[0] == "GEOADD" for argv in writes[0]))
        self.assertTrue(any(argv[0] == "HEXPIRE" for argv in writes[0]))
        self.assertTrue(any("EX" in argv for argv in writes[0]))

    def test_generations_and_tails_do_not_collide(self):
        keys = []
        for gen in range(4):
            _, expected = check.dataset(gen)
            _, tail = check.tail_writes(gen)
            keys += [(db, k) for db, ks in expected.items() for k in ks] + [(0, k) for k in tail]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertEqual(check.dataset(2), check.dataset(2))

    def test_count_and_merge(self):
        total = check.merge({}, check.dataset(0)[1])
        check.merge(total, {0: check.tail_writes(0)[1]})
        self.assertEqual(check.count_keys(total), len(check.dataset(0)[1][0]) + len(check.dataset(0)[1][check.SECOND_DB]) + 2)

    def test_snapshot_differences_are_reported(self):
        before = {(0, "a"): {"content": b"1"}, (0, "b"): {"content": b"2"}}
        after = {(0, "a"): {"content": b"9"}, (0, "c"): {"content": b"3"}}
        problems = check.diff_snapshots(before, after)
        self.assertEqual(len(problems), 3)
        self.assertTrue(any("b in db 0 is missing" in p for p in problems))
        self.assertTrue(any("c in db 0 appeared" in p for p in problems))
        self.assertEqual(check.diff_snapshots(before, dict(before)), [])

    def test_consumer_idle_times_are_ignored(self):
        value = {"consumers": [[b"name", b"alice", b"pending", 7, b"idle", 5, b"inactive", 9]],
                 "pending": [[b"1000-0", b"alice", 123, 1]]}
        later = {"consumers": [[b"name", b"alice", b"pending", 7, b"idle", 500, b"inactive", 900]],
                 "pending": [[b"1000-0", b"alice", 99999, 1]]}
        self.assertEqual(check.drop_idle(value), check.drop_idle(later))


class LogTest(unittest.TestCase):
    def test_clean_shutdown_log(self):
        self.assertEqual(check.check_shutdown_log(GOOD_SHUTDOWN), [])

    def test_missing_or_misordered_lines(self):
        missing = GOOD_SHUTDOWN.replace("DB saved on disk", "nothing")
        self.assertTrue(any("DB saved on disk" in p for p in check.check_shutdown_log(missing)))
        lines = GOOD_SHUTDOWN.splitlines()
        swapped = "\n".join(lines[:3] + [lines[7], lines[3], lines[4], lines[5], lines[6]])
        self.assertTrue(any("after the previous step" in p for p in check.check_shutdown_log(swapped)))

    def test_save_errors_fail(self):
        bad = GOOD_SHUTDOWN + "1:M # Error trying to save the DB, can't exit.\n"
        problems = check.check_shutdown_log(bad)
        self.assertTrue(any("Error trying to save" in p for p in problems))

    def test_loaded_keys(self):
        self.assertEqual(check.loaded_keys(GOOD_SHUTDOWN), 23)
        self.assertIsNone(check.loaded_keys("eski 0.1.0 listening on 0.0.0.0:1 pid 1\n"))


class ImageTest(unittest.TestCase):
    def test_contract(self):
        self.assertEqual(check.check_image_config(GOOD_CONFIG), [])
        for field, value, word in (("User", "", "root"), ("User", "0:0", "root"), ("WorkingDir", "/", "working directory"),
                                   ("Volumes", {}, "volume"), ("Entrypoint", ["/bin/sh"], "entry point"),
                                   ("ExposedPorts", {}, "exposed"), ("StopSignal", "SIGKILL", "stop signal")):
            config = dict(GOOD_CONFIG, **{field: value})
            problems = check.check_image_config(config)
            self.assertEqual(len(problems), 1, field)
            self.assertIn(word, problems[0])

    def test_run_argv_uses_host_network_volume_and_port(self):
        argv = check.run_argv("eski:local", "n", "l=1", "vol", 17001)
        self.assertIn("--network=host", argv)
        self.assertEqual(argv[argv.index("-v") + 1], "vol:/data")
        self.assertEqual(argv[argv.index("eski:local") + 1:], ["--port", "17001", *check.SERVER_ARGS])

    def test_free_port_avoids_ports_in_use(self):
        s = socket.socket()
        s.bind(("0.0.0.0", 0))
        s.listen()
        busy = s.getsockname()[1]
        try:
            self.assertFalse(check.port_free(busy))

            class Fixed:
                def __init__(self):
                    self.values = [busy, busy, 16001]

                def randint(self, lo, hi):
                    return self.values.pop(0)

            if check.port_free(16001):
                self.assertEqual(check.free_port(Fixed()), 16001)
        finally:
            s.close()

    def test_arguments(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                check.parse_args(["--replacements", "2"])
            with self.assertRaises(SystemExit):
                check.parse_args(["--port", "80"])
        self.assertEqual(check.parse_args([]).replacements, 3)


class CleanupTest(unittest.TestCase):
    def fake(self, tmp, config=None, listing=None, version=None):
        exe = Path(tmp) / "docker"
        exe.write_text(FAKE_DOCKER.format(python=sys.executable))
        exe.chmod(0o755)
        log = Path(tmp) / "calls.jsonl"
        env = {"FAKE_DOCKER_LOG": str(log), "FAKE_DOCKER_CONFIG": json.dumps(config or GOOD_CONFIG)}
        if listing is not None:
            env["FAKE_DOCKER_LISTING"] = listing
        if version is not None:
            env["FAKE_DOCKER_VERSION"] = version
        return exe, log, env

    def run_main(self, exe, env, extra=()):
        saved = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
                rc = check.main(["--docker", str(exe), "--port", str(check.free_port()), *extra])
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        return rc, err.getvalue()

    def test_failed_start_removes_containers_and_volume(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe, log, env = self.fake(tmp)
            rc, err = self.run_main(exe, env)
            self.assertEqual(rc, 1)
            self.assertIn("cannot start the server", err)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            created = next(c for c in calls if c[:2] == ["volume", "create"])
            label = created[created.index("--label") + 1]
            self.assertTrue(label.startswith("eski-container-check="))
            self.assertIn(["ps", "-aq", "--filter", f"label={label}"], calls)
            self.assertIn(["rm", "-f", "c0ffee"], calls)
            self.assertIn(["volume", "rm", "-f", created[-1]], calls)
            starts = [c for c in calls if c[0] == "run" and "-d" in c]
            self.assertEqual(len(starts), 1)
            self.assertIn("--network=host", starts[0])
            self.assertIn(f"{created[-1]}:/data", starts[0])

    def test_bad_image_stops_before_any_volume(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe, log, env = self.fake(tmp, config=dict(GOOD_CONFIG, User="root"), listing="THIRD_PARTY_NOTICES.md found /opt/odin")
            rc, err = self.run_main(exe, env)
            self.assertEqual(rc, 1)
            self.assertIn("runs as root", err)
            self.assertIn("lacks ODIN-LICENSE", err)
            self.assertIn("holds /opt/odin", err)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertFalse(any(c[:2] == ["volume", "create"] for c in calls))

    def test_missing_project_licence_stops_before_any_volume(self):
        cases = (
            ("eski v=0.1.0", None, "license=Apache-2.0"),
            ("eski v=0.1.0 license=MIT", None, "license=Apache-2.0"),
            (None, "THIRD_PARTY_NOTICES.md ODIN-LICENSE build-info.txt", "lacks LICENSE"),
        )
        for version, listing, expected in cases:
            with self.subTest(version=version, listing=listing), tempfile.TemporaryDirectory() as tmp:
                exe, log, env = self.fake(tmp, listing=listing, version=version)
                rc, err = self.run_main(exe, env)
                self.assertEqual(rc, 1)
                self.assertIn(expected, err)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertFalse(any(c[:2] == ["volume", "create"] for c in calls))


if __name__ == "__main__":
    unittest.main()
