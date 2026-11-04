import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


DOCKER = '''#!{python}
import hashlib
import json
import os
import sys
from pathlib import Path
a = sys.argv[1:]
with open(os.environ["FAKE_DOCKER_LOG"], "a") as f:
    f.write(json.dumps(a) + "\\n")
def iid(ref):
    return ref if ref.startswith("sha256:") else "sha256:" + hashlib.sha256(ref.encode()).hexdigest()
if a[:2] == ["image", "inspect"]:
    if "--format" in a:
        print(iid(a[-1]))
    else:
        print(json.dumps([{{"Id": iid(a[-1]), "Config": {{}}}}]))
elif a[:2] == ["container", "inspect"]:
    sys.exit(1)
elif a[0] == "inspect":
    if "-f" in a:
        print("true")
    elif "--format" in a and "{{{{.State.Pid}}}}" in a:
        print("")
    else:
        print(json.dumps({{"CpusetCpus": "6", "Memory": 1073741824, "MemorySwap": 1073741824, "NetworkMode": "host"}}))
elif a[0] in ("version", "info"):
    print("29.0.0")
elif a[0] == "run":
    if "-d" in a:
        print("owned-container")
    elif "--entrypoint" in a:
        print("name=eski\\nversion=eski v=0.1.0\\nbinary_sha256=" + "b" * 64)
    elif "redis-cli" in a:
        cmd = a[a.index("redis-cli") + 5:]
        filled = Path(os.environ["FAKE_DOCKER_LOG"] + ".filled")
        replies = {{"PING": "PONG", "FLUSHALL": "OK", "DBSIZE": os.environ.get("FAKE_DBSIZE", "0") if filled.exists() else "0"}}
        if cmd[:1] == ["FLUSHALL"]:
            filled.unlink(missing_ok=True)
        if cmd == ["INFO", "memory"] and os.environ.get("FAKE_USED_MEMORY"):
            counter = Path(os.environ["FAKE_DOCKER_LOG"] + ".samples")
            index = int(counter.read_text()) if counter.exists() else 0
            counter.write_text(str(index + 1))
            values = os.environ["FAKE_USED_MEMORY"].split(",")
            value = values[min(index, len(values) - 1)]
            rehashing = os.environ.get("FAKE_REHASHING", "-").split(",")
            rehash = rehashing[min(index, len(rehashing) - 1)]
            if value != "-":
                used = int(value) + max(0, index - len(values) + 1) * int(os.environ.get("FAKE_MEMORY_GROWTH", "0"))
                print("# Memory\\nused_memory:%d\\nused_memory_human:fixture\\nused_memory_rss:%d" % (used, used + 500))
                if rehash != "-":
                    print("mem_overhead_db_hashtable_rehashing:" + rehash)
        elif cmd[:1] == ["INFO"]:
            print("redis_version:7.0.0\\neski_version:0.1.0")
        else:
            print(replies.get(cmd[0], ""))
    elif any(v.startswith("--json-out-file=") for v in a):
        mount = a[a.index("-v") + 1].split(":")[0]
        output = next(v.split("=", 1)[1] for v in a if v.startswith("--json-out-file="))
        Path(os.environ["FAKE_DOCKER_LOG"] + ".filled").touch()
        if os.environ.get("FAKE_WARMUP_FAILURE") and ".warmup." in output:
            sys.exit(1)
        errors = int(os.environ.get("FAKE_MEMTIER_ERRORS", "0"))
        total = {{"Ops/sec": 1000, "Connection Errors": errors, "Percentile Latencies": {{"p50.00": 0.1, "p99.00": 0.2}}}}
        Path(mount, Path(output).name).write_text(json.dumps({{"ALL STATS": {{"Totals": total}}, "configuration": {{"threads": 1, "clients": 1}}}}))
    elif "--version" in a:
        print("memtier_benchmark v=2.5.2")
'''

PYTHON = '''#!{python}
import json
import os
import sys
from pathlib import Path
a = sys.argv[1:]
if len(a) > 2 and a[0] == "-I" and a[1].endswith("/spec.py") and a[2] == "probe":
    Path(a[a.index("--out") + 1]).write_text(json.dumps({{"method": "command_list", "server": "fixture", "implemented": ["get", "set"], "missing": [], "unprobed": []}}))
    print("probed fixture")
else:
    os.execv({python!r}, [{python!r}, *a])
'''


class RunnerHarnessTests(unittest.TestCase):
    def setUp(self):
        if not shutil.which('jq'):
            self.skipTest('jq is needed by bench/run.sh')
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        bench = self.root / 'bench'
        bench.mkdir()
        for name in ('run.sh', 'spec.py', 'exam_metrics.py'):
            shutil.copy2(Path(__file__).with_name(name), bench / name)
        tools = self.root / 'tools'
        tools.mkdir()
        (tools / 'docker').write_text(DOCKER.format(python=sys.executable))
        (tools / 'python3').write_text(PYTHON.format(python=sys.executable))
        (tools / 'ss').write_text('#!/usr/bin/env bash\nexit 0\n')
        (tools / 'taskset').write_text('#!/usr/bin/env bash\nexit 0\n')
        for tool in tools.iterdir():
            tool.chmod(0o755)
        self.log = self.root / 'docker.jsonl'
        self.output = self.root / 'out'
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], FAKE_DOCKER_LOG=str(self.log), ESKI_BIN='/no/native/eski',
                        BENCH_SERVER_CPUS='6', BENCH_CLIENT_CPUS='7', BENCH_ESKI_IMAGE='eski:fixture', BENCH_PORT_ESKI_DOCKER='6791',
                        BENCH_SERVER_MEMORY='1g', BENCH_CLIENT_MEMORY='256m', BENCH_SERVER_MAXMEMORY='700000000', BENCH_RUN_ID='exam-fixture',
                        BENCH_OUTPUT_DIR=str(self.output), BENCH_OWNER_EVENTS=str(self.root / 'owners.jsonl'), BENCH_SPEC_CACHE=str(self.root / 'cache'))
        client = {'tool': 'memtier_benchmark', 'image': 'memtier:fixture', 'cpus': '7', 'timeout': 10, 'argv': ['--ratio=0:1', '--test-time=15']}
        self.item = {'suite': 'testbed', 'name': 'fixture', 'key': 'fixture', 'fresh_server': True, 'required_commands': ['get', 'set'],
                     'preload': dict(client, argv=['--ratio=1:0', '--requests=100']), 'warmup': dict(client, argv=['--ratio=0:1', '--test-time=3']),
                     'clients': [client]}

    def tearDown(self):
        self.temporary.cleanup()

    def run_plan(self, code=0, **extra):
        plan = self.root / 'plan.json'
        plan.write_text(json.dumps({'items': [self.item]}))
        env = dict(self.env, **extra)
        done = subprocess.run(['bash', str(self.root / 'bench' / 'run.sh'), '--targets', 'eski-docker', '--scenarios', 'none', '--plan', str(plan)],
                              env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, code, done.stdout + done.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        summary = json.loads((self.output / 'summary.json').read_text()) if (self.output / 'summary.json').exists() else None
        return summary, calls

    def test_identical_caps_owned_names_and_persistence_off(self):
        summary, calls = self.run_plan()
        self.assertTrue(summary['meta']['complete'])
        target = summary['meta']['targets']['eski-docker']
        self.assertEqual(target['status'], 'ok')
        self.assertEqual(target['maxmemory_bytes'], 700000000)
        self.assertEqual(summary['meta']['server_container_memory'], '1g')
        servers = [call for call in calls if call[0] == 'run' and '--workdir=/data' in call]
        self.assertEqual(len(servers), 2)
        for argv in servers:
            for flag in ('--pull=never', '--memory=1g', '--memory-swap=1g', '--cpuset-cpus=6', '--tmpfs', '--label'):
                self.assertIn(flag, argv)
            self.assertEqual(argv[argv.index('--label') + 1], 'eski-bench=exam-fixture')
            self.assertEqual(argv[argv.index('--name') + 1], 'bench-eski-docker-exam-fixture')
            image = argv.index('--port') - 1
            self.assertTrue(argv[image].startswith('sha256:'))
            self.assertEqual(argv[image + 1:], ['--port', '6791', '--save', '', '--appendonly', 'no', '--maxmemory', '700000000'])
        probes = [call for call in calls if call[0] == 'run' and '-d' in call and '--workdir=/data' not in call]
        self.assertTrue(all('--pull=never' in call and call[-4:] == ['--save', '', '--appendonly', 'no'] for call in probes))
        clients = [call for call in calls if call[0] == 'run' and any(value.startswith('--json-out-file=') for value in call)]
        self.assertTrue(all('--memory=256m' in call and '--pull=never' in call and call[call.index('-v') + 2].startswith('sha256:') for call in clients))
        self.assertTrue(all(call[0] != 'run' or '--pull=never' in call for call in calls))
        owners = [json.loads(line) for line in (self.root / 'owners.jsonl').read_text().splitlines()]
        self.assertIn(('start', 'server', 'bench-eski-docker-exam-fixture'), {(o['event'], o['role'], o['container']) for o in owners})
        self.assertIn('before-stop', {o['event'] for o in owners})
        self.assertTrue(all(o['artifact_dir'] == str(self.output / 'eski-docker') for o in owners if o['role'] == 'server' and o['event'] == 'before-stop'))

    def test_warmup_precedes_the_timed_client_and_stays_out_of_the_record(self):
        summary, calls = self.run_plan()
        clients = [call for call in calls if call[0] == 'run' and any(value.startswith('--json-out-file=') for value in call)]
        outputs = [next(value for value in call if value.startswith('--json-out-file=')) for call in clients]
        self.assertEqual(outputs, ['--json-out-file=/out/fixture.preload.json', '--json-out-file=/out/fixture.warmup.json', '--json-out-file=/out/fixture.json'])
        records = summary['records']
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]['ops_per_sec'], 1000)
        self.assertEqual(records[0]['client']['argv'], self.item['clients'][0]['argv'])
        self.assertIn('excluded from the timed throughput', records[0]['warmup']['measurement_scope'])
        start = calls.index(clients[0])
        end = calls.index(clients[-1])
        self.assertFalse(any('FLUSHALL' in call or call[0] in ('stop', 'rm') for call in calls[start:end]))

    def test_warmup_failure_and_memtier_errors_fail_the_case(self):
        summary, calls = self.run_plan(FAKE_WARMUP_FAILURE='1')
        self.assertEqual(summary['records'][0]['error'], 'warmup failed')
        self.assertFalse(any('--json-out-file=/out/fixture.json' in call for call in calls))
        shutil.rmtree(self.output)
        self.log.unlink()
        summary, _ = self.run_plan(FAKE_MEMTIER_ERRORS='1')
        self.assertIn('error', summary['records'][0])
        self.assertIsNone(summary['records'][0]['ops_per_sec'])

    def run_fill(self, **extra):
        env = dict(self.env, FAKE_DBSIZE='1000', **extra)
        done = subprocess.run(['bash', str(self.root / 'bench' / 'run.sh'), '--quick', '--targets', 'eski-docker', '--scenarios', 'fill10m'],
                              env=env, capture_output=True, text=True, timeout=180)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        summary = json.loads((self.output / 'summary.json').read_text())
        self.assertEqual(len(summary['records']), 1)
        commands = [call[call.index('redis-cli') + 5:] for call in calls if 'redis-cli' in call]
        return summary, commands, done.stdout

    def test_fill_reads_memory_once_it_is_unchanged_for_three_samples_without_a_rehash(self):
        summary, commands, stdout = self.run_fill(FAKE_USED_MEMORY='5000,-,5000,5000,4000', FAKE_REHASHING='700,700,700,700,-')
        record = summary['records'][0]
        self.assertEqual(record['scenario'], 'fill10m')
        self.assertIs(record['settled'], True)
        self.assertEqual(record['settle_samples'], 8)
        self.assertEqual([sample[1:] for sample in record['settle_trace']],
                         [[5000, 700], [None, None], [5000, 700], [5000, 700], [4000, None], [4000, None], [4000, None], [4000, None]])
        self.assertGreaterEqual(record['settle_s'], 7.0)
        self.assertLess(record['settle_s'], 12.0)
        self.assertEqual(record['settle_s'], record['settle_trace'][-1][0])
        self.assertEqual(record['settle_timeout_s'], 60)
        self.assertEqual(record['used_memory'], 4000)
        self.assertEqual(record['used_memory_rss'], 4500)
        self.assertEqual(record['dbsize'], 1000)
        self.assertEqual(record['bytes_per_key_used'], 4.0)
        self.assertEqual(summary['meta']['fill_settle_timeout_s'], 60)
        self.assertEqual(summary['meta']['fill_settle_stable_samples'], 3)
        samples = [index for index, command in enumerate(commands) if command == ['INFO', 'memory']]
        self.assertEqual(len(samples), 8)
        self.assertEqual(commands[samples[-1] + 1], ['DBSIZE'])
        self.assertIn('settled after', stdout)

    def test_fill_that_never_settles_keeps_its_last_reading(self):
        summary, commands, stdout = self.run_fill(FAKE_USED_MEMORY='2000', FAKE_REHASHING='0', FAKE_MEMORY_GROWTH='7', BENCH_FILL_SETTLE_TIMEOUT='2')
        record = summary['records'][0]
        self.assertIs(record['settled'], False)
        self.assertNotIn('error', record)
        self.assertEqual(record['settle_samples'], 3)
        self.assertEqual([sample[1:] for sample in record['settle_trace']], [[2000, 0], [2007, 0], [2014, 0]])
        self.assertGreaterEqual(record['settle_s'], 2.0)
        self.assertLess(record['settle_s'], 6.0)
        self.assertEqual(record['settle_timeout_s'], 2)
        self.assertEqual(record['used_memory'], 2014)
        self.assertEqual(record['bytes_per_key_used'], 2.014)
        self.assertEqual(commands.count(['INFO', 'memory']), 3)
        self.assertIn('not settled after', stdout)
        shutil.rmtree(self.output)
        self.log.unlink()
        Path(str(self.log) + '.samples').unlink()
        summary, _, _ = self.run_fill(FAKE_USED_MEMORY='3000', FAKE_REHASHING='700', BENCH_FILL_SETTLE_TIMEOUT='2')
        record = summary['records'][0]
        self.assertIs(record['settled'], False)
        self.assertEqual([sample[1:] for sample in record['settle_trace']], [[3000, 700], [3000, 700], [3000, 700]])
        self.assertEqual(record['used_memory'], 3000)

    def test_output_directory_must_be_fresh_and_absolute(self):
        self.output.mkdir()
        self.run_plan(code=1)
        self.run_plan(code=1, BENCH_OUTPUT_DIR='relative/out')
        self.run_plan(code=1, BENCH_RUN_ID='bad id')
        self.run_plan(code=1, BENCH_OUTPUT_DIR=str(self.root / 'other'), BENCH_SERVER_MAXMEMORY='6g')
        self.run_plan(code=1, BENCH_OUTPUT_DIR=str(self.root / 'other'), BENCH_FILL_SETTLE_TIMEOUT='0')


if __name__ == '__main__':
    unittest.main()
