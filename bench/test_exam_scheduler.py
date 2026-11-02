import copy
import csv
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('eski_exam_scheduler', Path(__file__).with_name('exam_scheduler.py'))
scheduler = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scheduler)
m = scheduler.metrics
IMAGE = 'sha256:' + 'a' * 64


def sample():
    return dict(package=dict(available=True, celsius=40), idle_pct=dict(cpu=100), ac_online={'AC': 1},
                throttle={'cpu0': 7}, throttle_delta={'cpu0': 0}, counter_resets=[], external_cpu=[], owned_processes=[],
                availability=dict(cpu=True, process_scan=True, ac=True, throttle=True))


def server_sample():
    value = sample()
    value.update(ac_online={}, power_supply={})
    value['availability'].update(ac=False, power_supply=True)
    return value


def laptop_sample():
    value = sample()
    value['power_supply'] = {'AC': dict(type='Mains', online=1), 'BAT0': dict(type='Battery', online=None)}
    value['availability']['power_supply'] = True
    return value


class Clock:
    latest = 100

    def __init__(self):
        self.at = Clock.latest

    def time(self):
        return 1_000_000 + self.at

    def monotonic(self):
        return self.at

    def sleep(self, delay):
        self.at += delay
        Clock.latest = max(Clock.latest, self.at)
        time.sleep(.01)


class Reader:
    chip, label = 'coretemp', 'Package id 0'

    def __init__(self, cpus, rows=None):
        self.cpus, self.rows, self.calls = cpus, rows or [], 0
        self.callback = None

    def topology(self, roles):
        return {str(c): dict(role=r, siblings=[c]) for r, cpus in roles.items() for c in cpus}

    def sample(self, *args):
        self.calls += 1
        value = copy.deepcopy(self.rows[min(self.calls - 1, len(self.rows) - 1)] if self.rows else sample())
        value['idle_pct'].update({'cpu%d' % c: value['idle_pct']['cpu'] for c in self.cpus})
        value.setdefault('frequency_policy', {'cpu' + cpu: policy for cpu, policy in m.frequency_policy(self.cpus).items()})
        if self.callback:
            self.callback(args)
        return value


HARNESS = '''exec python3 - "$@" <<'PY'
import json,os,sys,time
from pathlib import Path
target=sys.argv[sys.argv.index('--targets')+1]
plan=json.loads(Path(sys.argv[sys.argv.index('--plan')+1]).read_text())
item=plan['items'][0]
key=item['key']
root=Path(os.environ['BENCH_OUTPUT_DIR']);root.mkdir()
record=dict(target=target,scenario=item['name'],suite=item['suite'],ops_per_sec=1)
if key=='skip':record['skipped']='unsupported'
if key=='fail':record['error']='real fake command failure'
if key=='invalid':record['ops_per_sec']=0
if key=='partial':
 (root/'records.jsonl').write_text('{"target":')
 sys.exit(0)
(root/'records.jsonl').write_text(json.dumps(record)+'\\n')
(root/'plan.json').write_text(json.dumps(plan))
(root/'summary.json').write_text(json.dumps(dict(meta=dict(complete=True,targets={target:dict(status='ok',image_id='sha256:'+'a'*64)}))))
(root/'original-argv.json').write_text(json.dumps(item['clients'][0]['argv']))
(root/'dragonfly-threads.txt').write_text(os.environ['BENCH_DRAGONFLY_THREADS'])
if key in ('bound','slow','sane'):
 ev=os.environ.get('BENCH_OWNER_EVENTS')
 if ev:Path(ev).write_text(json.dumps(dict(event='owner',role='client',pid=os.getpid(),process=dict(start_ticks=1),artifact_dir='run/'+target+'/'+key))+'\\n')
 d=root/target;d.mkdir()
 (d/(key+'.json')).write_text(json.dumps({'ALL STATS':{'Totals':{'Max Latency':4294519.77 if key=='slow' else 12.5,'Time-Serie':[{'second':1,'Max Latency':0.5}]}}}))
if key=='wait':time.sleep(10)
sys.exit(7 if key=='fail' else 130 if key=='signal' else 0)
PY
'''


class SchedulerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / 'bench').mkdir()
        (self.root / 'bench/run.sh').write_text(HARNESS)
        self.profile = dict(schema='eski-exam-profile-v1', source_revision='declared-source',
                            files={'bench/run.sh': scheduler.sha(self.root / 'bench/run.sh')},
                            images={k: IMAGE for k in ('redis', 'valkey', 'cli', 'memtier', 'original:edge')})
        scheduler.atomic(self.root / 'profile.json', self.profile)
        self.cpus = sorted(os.sched_getaffinity(0))[:3]
        if len(self.cpus) < 3:
            self.skipTest('three allowed logical CPUs needed for explicit affinity validation')
        self.reader = Reader(self.cpus)
        self.args = scheduler.parser().parse_args(['run', '--plan', str(self.root / 'plan.json'), '--profile', str(self.root / 'profile.json'),
                                                '--output', str(self.root / 'results'), '--targets', 'redis,valkey',
                                                '--server-cpus', str(self.cpus[0]), '--client-cpus', str(self.cpus[1]), '--control-cpus', str(self.cpus[2]),
                                                '--stable-seconds', '0', '--min-rest', '0', '--sample-seconds', '.2', '--max-wait', '1',
                                                '--min-free-bytes', '0', '--host-lock', str(self.root / 'host.lock')])
        self.set_plan(['good'])
        self.cleanups = []

    def tearDown(self):
        self.temporary.cleanup()

    def set_plan(self, keys):
        self.plan = dict(suites={'source': {'release': 'pinned'}}, items=[dict(key=k, name=k, suite='source', runs=2,
                         clients=[dict(tool='memtier_benchmark', image='original:edge', cpus='4-13', requested_cpus=1,
                                       argv=['--test-time=37', '--threads=10', '--data-size=123'])]) for k in keys])
        scheduler.atomic(self.root / 'plan.json', self.plan)

    def scheduler(self):
        model = scheduler.validate(self.args, self.reader)
        return scheduler.Scheduler(self.args, model, self.reader, Clock(), lambda run_id: self.cleanups.append(run_id) or {'ok': True})

    def test_success_rotation_durability_resume(self):
        self.set_plan(['first', 'second'])
        self.args.repetitions = 2
        engine = self.scheduler()
        with patch.object(scheduler.os, 'fsync', wraps=os.fsync) as sync:
            state = engine.run()
        self.assertEqual(state['state'], 'finished')
        self.assertGreater(sync.call_count, 30)
        self.assertEqual([r['target'] for r in state['cases']], ['redis', 'valkey', 'valkey', 'redis', 'valkey', 'redis', 'redis', 'valkey'])
        self.assertEqual(len(self.cleanups), 8)
        self.assertTrue(all(len(r['attempts']) == 1 for r in state['cases']))
        for row in state['cases']:
            directory = engine.output / row['attempts'][0]['directory']
            self.assertEqual(scheduler.load(directory / 'run/original-argv.json'), self.plan['items'][row['index']]['clients'][0]['argv'])
            self.assertTrue((directory / 'artifacts.json').exists())
        self.assertEqual(self.scheduler().run(True)['state'], 'finished')
        self.assertEqual(len(self.cleanups), 8)
        with self.assertRaisesRegex(ValueError, 'checkpoint exists'):
            self.scheduler().run()

    def test_four_repetitions_balance_every_engine_position(self):
        self.set_plan(['first', 'second', 'third'])
        targets = ['redis', 'valkey', 'dragonfly', 'eski-docker']
        rows = scheduler.schedule(self.plan, targets, 4)
        for index in range(3):
            orders = [[row['target'] for row in rows if row['index'] == index and row['repetition'] == repetition] for repetition in range(1, 5)]
            for position in range(4):
                self.assertEqual({order[position] for order in orders}, set(targets))
        self.assertEqual(rows, scheduler.schedule(self.plan, targets, 4))

    def test_warmup_is_resolved_without_changing_original_declarations(self):
        self.plan['items'][0]['warmup'] = dict(tool='memtier_benchmark', image='original:edge', requested_cpus=1,
                                              argv=['--randomize=123', '--test-time=3', '--key-maximum=1000'])
        scheduler.atomic(self.root / 'plan.json', self.plan)
        original = copy.deepcopy(self.plan)
        model = scheduler.validate(self.args, self.reader)
        resolved = scheduler.resolved_plan(model, {'index': 0}, [self.cpus[1]])['items'][0]
        self.assertEqual(model['plan'], original)
        self.assertEqual(resolved['warmup']['argv'], original['items'][0]['warmup']['argv'])
        self.assertEqual(resolved['warmup']['image'], IMAGE)
        self.assertEqual(resolved['warmup']['cpus'], str(self.cpus[1]))
        self.assertEqual(resolved['clients'][0]['argv'], original['items'][0]['clients'][0]['argv'])
        self.plan['items'][0]['warmup']['requested_cpus'] = 2
        scheduler.atomic(self.root / 'plan.json', self.plan)
        with self.assertRaisesRegex(ValueError, 'warmup CPU request'):
            self.scheduler()

    def test_dragonfly_thread_count_is_explicit_and_immutable(self):
        self.profile['dragonfly_threads'] = 1
        scheduler.atomic(self.root / 'profile.json', self.profile)
        engine = self.scheduler()
        self.assertEqual(engine.model['identity']['config']['dragonfly_threads'], 1)
        state = engine.run()
        for row in state['cases']:
            self.assertEqual((engine.output / row['attempts'][0]['directory'] / 'run/dragonfly-threads.txt').read_text(), '1')
        for value in (0, 2, True, '1'):
            self.profile['dragonfly_threads'] = value
            scheduler.atomic(self.root / 'profile.json', self.profile)
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'dragonfly_threads'):
                self.scheduler()

    def test_declared_frequency_policy_change_holds_before_launch(self):
        engine = self.scheduler()
        original = self.reader.sample
        def changed(*args):
            value = original(*args)
            value['frequency_policy']['cpu' + str(self.cpus[0])]['scaling_max_freq'] = '1'
            return value
        self.reader.sample = changed
        state = engine.run()
        self.assertEqual(state['state'], 'paused')
        self.assertIn('frequency_policy_changed', state['pause']['reasons'])
        self.assertEqual(self.cleanups, [])

    def test_policy_change_between_admission_and_case_invalidates_measurement(self):
        engine = self.scheduler()
        original = self.reader.sample
        def changed(*args):
            value = original(*args)
            if args:
                value['frequency_policy']['cpu' + str(self.cpus[0])]['scaling_min_freq'] = '1'
            return value
        self.reader.sample = changed
        state = engine.run()
        self.assertTrue(all(row['state'] == 'invalid' for row in state['cases']))
        self.assertTrue(all('frequency_policy_changed' in row['attempts'][0]['details']['reasons'] for row in state['cases']))

    def test_failed_skipped_invalid_partial_never_retried(self):
        self.set_plan(['fail', 'skip', 'invalid', 'partial'])
        state = self.scheduler().run()
        self.assertEqual([r['state'] for r in state['cases']], ['failed', 'failed', 'skipped', 'skipped', 'invalid', 'invalid', 'invalid', 'invalid'])
        self.assertEqual(state['state'], 'finished-with-nonsuccess')
        self.assertEqual(self.scheduler().run(True)['cases'], state['cases'])
        self.assertEqual(len(self.cleanups), 8)

    def test_identity_changes_rejected_without_new_execution(self):
        self.scheduler().run()
        self.args.maxmemory += 1
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            self.scheduler().run(True)
        self.args.maxmemory -= 1
        self.profile['source_revision'] = 'different-source'
        scheduler.atomic(self.root / 'profile.json', self.profile)
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            self.scheduler().run(True)
        (self.root / 'bench/run.sh').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            self.scheduler()

    def test_plan_and_image_identity_changes(self):
        self.scheduler().run()
        self.set_plan(['different'])
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            self.scheduler().run(True)
        self.set_plan(['good'])
        self.profile['images'] = {k: 'sha256:' + 'b' * 64 for k in self.profile['images']}
        scheduler.atomic(self.root / 'profile.json', self.profile)
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            self.scheduler().run(True)

    def test_kernel_lock_rejects_concurrent_output_or_host(self):
        with scheduler.Lock(self.args.host_lock):
            with self.assertRaisesRegex(ValueError, 'another runner'):
                self.scheduler().run()
        with scheduler.Lock(self.root / 'results/.scheduler.lock'):
            with self.assertRaisesRegex(ValueError, 'another runner'):
                self.scheduler().run()
        self.assertFalse((self.root / 'results/checkpoint.json').exists())

    def test_gate_timeout_and_sensor_missing_pause_not_skip(self):
        bad = sample()
        bad['package']['celsius'] = 75
        self.reader.rows = [bad]
        state = self.scheduler().run()
        self.assertEqual(state['state'], 'paused')
        self.assertEqual(state['cases'][0]['state'], 'pending')
        self.assertIn('package_temperature', state['pause']['reasons'])
        self.reader.rows = [dict(sample(), package=dict(available=False))]
        state = self.scheduler().run(True)
        self.assertIn('package_sensor_unavailable', state['pause']['reasons'])
        self.assertEqual(self.cleanups, [])

    def test_stable_window_rest_ac_idle_and_disk(self):
        self.args.stable_seconds = .4
        self.args.min_rest = .4
        self.args.max_wait = 2
        self.reader.rows = [dict(sample(), ac_online={'AC': 0}), dict(sample(), idle_pct={'cpu': 20}), sample()]
        engine = self.scheduler()
        state = engine.run()
        self.assertEqual(state['state'], 'finished')
        gates = [json.loads(s) for s in (engine.output / 'gates.jsonl').read_text().splitlines()]
        self.assertTrue(any('ac_not_online' in r['problems'] for r in gates))
        self.assertTrue(any('cpu_not_idle' in r['problems'] for r in gates))
        self.assertTrue(any('minimum_rest' in r['problems'] for r in gates))
        self.args.output = self.root / 'disk-results'
        self.args.min_free_bytes = 1 << 62
        state = self.scheduler().run()
        self.assertEqual(state['pause']['reasons'], ['disk_pressure'])

    def test_interruption_requires_explicit_preserved_attempt(self):
        self.set_plan(['wait'])
        engine = self.scheduler()
        self.reader.callback = lambda args: setattr(engine, 'interrupted', True) if args and args[0] else None
        state = engine.run()
        self.assertEqual(state['state'], 'paused')
        self.assertEqual(state['cases'][0]['state'], 'interrupted')
        self.reader.callback = None
        self.assertEqual(self.scheduler().run(True)['state'], 'paused')
        self.assertEqual(len(self.cleanups), 1)
        self.set_plan(['signal'])
        self.args.output = self.root / 'signal-results'
        state = self.scheduler().run()
        self.assertEqual(state['cases'][0]['state'], 'interrupted')
        self.args.retry_interrupted = True
        state = self.scheduler().run(True)
        self.assertEqual(len(state['cases'][0]['attempts']), 2)
        self.assertTrue(all(a['state'] == 'interrupted' for a in state['cases'][0]['attempts']))

    def test_corrupt_completed_artifact_is_not_trusted(self):
        state = self.scheduler().run()
        case = self.root / 'results' / state['cases'][0]['attempts'][0]['directory']
        (case / 'run/records.jsonl').write_text('tampered')
        with self.assertRaisesRegex(ValueError, 'artifact changed'):
            self.scheduler().run(True)

    def test_resource_policy_and_paths(self):
        self.plan['items'][0]['clients'][0]['requested_cpus'] = 10
        scheduler.atomic(self.root / 'plan.json', self.plan)
        with self.assertRaisesRegex(ValueError, 'CPU requests exceed'):
            self.scheduler()
        self.args.resource_policy = 'allow-oversubscription'
        state = self.scheduler().run()
        self.assertTrue(state['cases'][0]['attempts'][0]['resource_admission']['oversubscribed'])
        with self.assertRaisesRegex(ValueError, 'escapes workspace'):
            scheduler.contained(self.root, '../outside')

    def test_failed_cleanup_blocks_new_cases_and_resume(self):
        engine = self.scheduler()
        engine.cleanup = lambda _: {'ok': False}
        state = engine.run()
        self.assertEqual(state['state'], 'paused')
        self.assertEqual(state['cases'][0]['state'], 'invalid')
        self.assertEqual(state['cases'][1]['state'], 'pending')
        other = self.scheduler()
        other.cleanup = lambda _: {'ok': False}
        with self.assertRaisesRegex(ValueError, 'cleanup incomplete'):
            other.run(True)

    def test_crash_between_identity_and_checkpoint_is_recoverable(self):
        engine = self.scheduler()
        engine.output.mkdir()
        scheduler.atomic(engine.output / 'identity.json', engine.model['identity'])
        scheduler.atomic(engine.output / 'original-plan.json', engine.model['plan'])
        self.assertEqual(engine.run(True)['state'], 'finished')

    def test_summary_done_is_distinct_from_passed_and_missing(self):
        self.set_plan(['good', 'fail', 'skip', 'invalid'])
        state = self.scheduler().run()
        summary = scheduler.load(self.root / 'results/summary.json')
        self.assertTrue(summary['done'])
        self.assertFalse(summary['passed'])
        self.assertEqual(summary['status'], 'DONE WITH FAILURES')
        self.assertEqual(summary['counts']['valid'], 2)
        self.assertEqual(summary['counts']['failed'], 2)
        self.assertEqual(summary['counts']['skipped'], 2)
        self.assertEqual(summary['counts']['invalid'], 2)
        self.assertEqual(summary['counts']['missing'], 0)
        self.assertTrue((self.root / 'results/report.md').exists())
        self.assertTrue((self.root / 'results/index.json').exists())
        state['cases'][0]['state'] = 'interrupted'
        state['state'] = 'paused'
        view = scheduler.status_view(state)
        self.assertEqual(view['status'], 'INTERRUPTED')
        self.assertFalse(view['done'])
        self.assertEqual(view['counts']['missing'], 1)
        self.assertEqual(scheduler.status_view(None)['status'], 'NOT STARTED')

    def test_measurement_report_keeps_nonsuccess_blank_and_scopes_peaks(self):
        cases = scheduler.schedule(self.plan, ['redis', 'valkey', 'dragonfly', 'eski-docker'], 1)
        for row, state in zip(cases, ['successful', 'invalid', 'failed', 'skipped']):
            row['state'] = state
            record = dict(ops_per_sec=1234, p50_ms=.1, p99_ms=.9, p999_ms=float('nan'), max_ms=float('inf'), count=42)
            if state == 'failed':
                record['error'] = 'client failed'
            if state == 'skipped':
                record['skipped'] = 'unsupported command'
            row['attempts'] = [dict(directory='raw/' + row['target'], state=state, cleanup={'ok': True},
                                    details=dict(record=record, reasons=['thermal_throttling'] if state == 'invalid' else []),
                                    telemetry=dict(server_pre_stop_cgroup_peaks=[
                                        dict(artifact_dir='/owned/probe-cache/probe-' + row['target'], memory_peak_bytes=99999999),
                                        dict(artifact_dir='/owned/run/' + row['target'], memory_peak_bytes=88888),
                                        dict(artifact_dir='/owned/run/' + row['target'], memory_peak_bytes=65536)],
                                        process_sampled_maxima=[dict(sampled_max_rss_bytes=1024), dict(sampled_max_rss_bytes=512)]))]
        output = self.root / 'reports'
        output.mkdir()
        scheduler.publish(output, dict(cases=cases, identity='synthetic', state='finished-with-nonsuccess'))
        with (output / 'measurements.csv').open(newline='') as handle:
            measurements = list(csv.DictReader(handle))
        self.assertEqual(len(measurements), 4)
        valid = measurements[0]
        self.assertEqual(valid['ops_per_sec'], '1234')
        self.assertEqual(valid['count'], '42')
        self.assertEqual(valid['p50_ms'], '0.1')
        self.assertEqual(valid['p999_ms'], '')
        self.assertEqual(valid['max_ms'], '')
        self.assertEqual(valid['server_cgroup_peak_bytes'], '65536')
        self.assertIn('excludes command-probe', valid['server_cgroup_peak_scope'])
        self.assertEqual(valid['owned_process_sampled_max_rss_bytes'], '1024')
        self.assertIn('not summed', valid['sampled_rss_scope'])
        numeric = ('ops_per_sec', 'p50_ms', 'p99_ms', 'p999_ms', 'max_ms', 'count', 'server_cgroup_peak_bytes', 'owned_process_sampled_max_rss_bytes')
        for invalid in measurements[1:]:
            self.assertTrue(all(invalid[field] == '' for field in numeric))
            self.assertTrue(invalid['reason'])
        with (output / 'comparisons.csv').open(newline='') as handle:
            comparisons = list(csv.DictReader(handle))
        self.assertEqual(len(comparisons), 1)
        self.assertEqual(comparisons[0]['redis_ops_per_sec'], '1234')
        for target in ('valkey', 'dragonfly', 'eski-docker'):
            self.assertEqual(comparisons[0][target + '_ops_per_sec'], '')
        report = (output / 'report.md').read_text()
        self.assertIn('[Measurements and latency/memory scopes](measurements.csv)', report)
        self.assertIn('[Per-case engine comparisons](comparisons.csv)', report)
        self.assertIn('1,234.00', report)
        self.assertIn('invalid (unavailable)', report)

    def test_checkpoint_schedule_mutation_is_rejected(self):
        self.scheduler().run()
        path = self.root / 'results/checkpoint.json'
        checkpoint = scheduler.load(path)
        checkpoint['cases'].reverse()
        scheduler.atomic(path, checkpoint)
        with self.assertRaisesRegex(ValueError, 'case order or identity changed'):
            self.scheduler().run(True)

    def test_running_crash_recovery_checks_pid_generation(self):
        engine = self.scheduler()
        engine.output.mkdir()
        engine.initialize(False)
        owned = subprocess.Popen(['sleep', '10'], start_new_session=True)
        unrelated = subprocess.Popen(['sleep', '10'], start_new_session=True)
        try:
            proc = m.process(owned.pid)
            row = engine.state['cases'][0]
            row['state'] = 'running'
            row['attempts'] = [dict(run_id='owned-test-run', state='running', harness_process=proc,
                                    boot_id=m.read('/proc/sys/kernel/random/boot_id'))]
            engine.save('simulated-crash')
            state = self.scheduler().run(True)
            self.assertEqual(state['cases'][0]['state'], 'interrupted')
            self.assertEqual(owned.wait(timeout=2), -signal.SIGTERM)
            self.assertIsNone(unrelated.poll())
            self.assertEqual(self.cleanups, ['owned-test-run'])
        finally:
            for child in (owned, unrelated):
                if child.poll() is None:
                    scheduler.stop_group(child)

    def test_reused_pid_is_not_signalled_on_recovery(self):
        engine = self.scheduler()
        engine.output.mkdir()
        engine.initialize(False)
        unrelated = subprocess.Popen(['sleep', '10'], start_new_session=True)
        try:
            proc = m.process(unrelated.pid)
            proc['start_ticks'] -= 1
            row = engine.state['cases'][0]
            row['state'] = 'running'
            row['attempts'] = [dict(run_id='old-test-run', state='running', harness_process=proc,
                                    boot_id=m.read('/proc/sys/kernel/random/boot_id'))]
            engine.save('simulated-reused-pid')
            self.assertEqual(self.scheduler().run(True)['state'], 'paused')
            self.assertIsNone(unrelated.poll())
        finally:
            scheduler.stop_group(unrelated)

    def test_sampler_write_failure_stops_owned_child(self):
        self.set_plan(['wait'])
        engine = self.scheduler()
        original = m.append_json
        def failing(path, value):
            if Path(path).name == 'metrics.jsonl':
                raise OSError('injected disk write failure')
            original(path, value)
        with patch.object(m, 'append_json', side_effect=failing):
            with self.assertRaisesRegex(OSError, 'disk write failure'):
                engine.run()
        pid = engine.state['cases'][0]['attempts'][0]['harness_process']['pid']
        self.assertIsNone(m.process(pid))
        self.assertEqual(len(self.cleanups), 1)
        self.assertEqual(scheduler.load(engine.output / 'checkpoint.json')['cases'][0]['state'], 'running')

    def test_thermal_case_is_invalid_and_never_favorably_retried(self):
        original = self.reader.sample
        def hot(*args):
            value = original(*args)
            if args:
                value['package']['celsius'] = 100
            return value
        self.reader.sample = hot
        state = self.scheduler().run()
        self.assertTrue(all(row['state'] == 'invalid' for row in state['cases']))
        self.assertTrue(all('package_temperature' in row['attempts'][0]['details']['reasons'] for row in state['cases']))
        self.assertEqual(self.scheduler().run(True)['cases'], state['cases'])


    def owning_reader(self, cores):
        original = self.reader.sample
        def seen(*args):
            value = original(*args)
            if len(args) > 1:
                for owner in args[1]:
                    if owner.get('role') == 'client':
                        value['owned_processes'] = [dict(pid=owner['pid'], start_ticks=1, cpu_cores=cores, comm='memtier_benchma', rss_bytes=1)]
            return value
        self.reader.sample = seen

    def test_client_headroom_rule_annotates_a_client_limited_measurement(self):
        self.set_plan(['bound'])
        self.args.max_client_utilization_pct = 50
        self.owning_reader(0.9)
        state = self.scheduler().run()
        row = state['cases'][0]
        self.assertEqual(row['state'], 'successful')
        self.assertEqual(row['attempts'][0]['details']['annotations'], ['client_limited'])
        self.assertAlmostEqual(row['attempts'][0]['details']['client_utilization_pct'], 90)
        quality = row['attempts'][0]['telemetry']['measurement_quality']['client_headroom']
        self.assertEqual(quality['budget_cores'], 1)
        self.assertEqual(quality['annotations'], ['client_limited'])
        self.assertEqual(self.scheduler().run(True)['cases'], state['cases'])
        self.args.max_client_utilization_pct = 95
        self.args.output = self.root / 'results-ok'
        state = self.scheduler().run()
        self.assertEqual(state['cases'][0]['state'], 'successful')
        self.assertEqual(state['cases'][0]['attempts'][0]['details']['annotations'], [])

    def test_client_headroom_rule_requires_observed_ownership(self):
        self.set_plan(['good'])
        self.args.max_client_utilization_pct = 85
        state = self.scheduler().run()
        self.assertEqual(state['cases'][0]['state'], 'invalid')
        self.assertIn('client_ownership_unobserved', state['cases'][0]['attempts'][0]['details']['reasons'])

    def test_latency_sanity_rule_invalidates_histogram_range_artifacts(self):
        self.set_plan(['slow', 'sane'])
        self.args.max_latency_seconds = 120
        state = self.scheduler().run()
        states = {row['key']: row for row in state['cases']}
        self.assertEqual(states['slow']['state'], 'invalid')
        self.assertIn('timing_anomaly', states['slow']['attempts'][0]['details']['reasons'])
        offending = states['slow']['attempts'][0]['telemetry']['measurement_quality']['latency_sanity']['files'][0]['offending']
        self.assertEqual(offending[0]['ms'], 4294519.77)
        self.assertEqual(states['sane']['state'], 'successful')
        self.assertEqual(states['sane']['attempts'][0]['telemetry']['measurement_quality']['latency_sanity']['files'][0]['max_ms'], 12.5)
        self.assertEqual(self.scheduler().run(True)['cases'], state['cases'])

    def test_latency_sanity_rule_requires_raw_client_output(self):
        self.set_plan(['good'])
        self.args.max_latency_seconds = 120
        state = self.scheduler().run()
        self.assertEqual(state['cases'][0]['state'], 'invalid')
        self.assertIn('latency_sanity_unmeasured', state['cases'][0]['attempts'][0]['details']['reasons'])

    def case_samples(self, engine, row):
        return [json.loads(line) for line in (engine.output / row['attempts'][0]['directory'] / 'metrics.jsonl').read_text().splitlines()]

    def test_mains_power_source_is_the_default_and_keeps_the_mains_rule(self):
        self.assertEqual(self.args.power_source, 'mains')
        self.assertEqual(self.scheduler().model['identity']['config']['power_source'], 'mains')
        undeclared = type('Args', (), dict(max_temp_c=90))()
        for args in (self.args, undeclared):
            with self.subTest(args=args):
                self.assertEqual(scheduler.sample_problems(laptop_sample(), args), [])
                self.assertEqual(scheduler.sample_problems(dict(laptop_sample(), ac_online={'AC': 0}), args), ['ac_not_online'])
                self.assertEqual(scheduler.sample_problems(server_sample(), args), ['ac_sensor_unavailable'])
        self.args.power_source = 'battery'
        with self.assertRaisesRegex(ValueError, 'power source must be one of mains, no-power-supply-devices'):
            self.scheduler()

    def test_no_power_supply_devices_accepts_only_an_empty_readable_class(self):
        self.args.power_source = 'no-power-supply-devices'
        self.assertEqual(scheduler.sample_problems(server_sample(), self.args), [])
        cases = [({'BAT0': dict(type='Battery', online=None)}, ['battery_present']),
                 ({'AC': dict(type='Mains', online=1)}, ['mains_present']),
                 ({'ucsi-source-psy-USBC000:001': dict(type='USB', online=1)}, ['power_supply_device_present']),
                 ({'BAT0': dict(type='Battery', online=None), 'AC': dict(type='Mains', online=0), 'unknown': dict(type=None, online=None)},
                  ['battery_present', 'mains_present', 'power_supply_device_present'])]
        for devices, expected in cases:
            with self.subTest(devices=devices):
                self.assertEqual(scheduler.sample_problems(dict(server_sample(), power_supply=devices), self.args), expected)
        self.assertEqual(scheduler.sample_problems(laptop_sample(), self.args), ['battery_present', 'mains_present'])
        unreadable = server_sample()
        unreadable['power_supply'] = None
        unreadable['availability']['power_supply'] = False
        for row in (unreadable, sample()):
            with self.subTest(row=row):
                self.assertEqual(scheduler.sample_problems(row, self.args), ['power_supply_telemetry_unavailable'])

    def test_no_power_supply_devices_holds_a_laptop_before_any_case(self):
        self.args.power_source = 'no-power-supply-devices'
        self.reader.rows = [laptop_sample()]
        state = self.scheduler().run()
        self.assertEqual(state['state'], 'paused')
        self.assertEqual(state['cases'][0]['state'], 'pending')
        self.assertEqual(state['pause']['reasons'], ['battery_present', 'mains_present'])
        self.assertEqual(self.cleanups, [])

    def test_battery_appearing_mid_case_invalidates_under_no_power_supply_devices(self):
        self.args.power_source = 'no-power-supply-devices'
        self.reader.rows = [server_sample()]
        original = self.reader.sample
        def battery(*args):
            value = original(*args)
            if args:
                value['power_supply'] = {'BAT0': dict(type='Battery', online=None)}
            return value
        self.reader.sample = battery
        engine = self.scheduler()
        state = engine.run()
        self.assertEqual(engine.model['identity']['config']['power_source'], 'no-power-supply-devices')
        self.assertTrue(all(row['state'] == 'invalid' for row in state['cases']))
        self.assertTrue(all('battery_present' in row['attempts'][0]['details']['reasons'] for row in state['cases']))
        gates = [json.loads(line) for line in (engine.output / 'gates.jsonl').read_text().splitlines()]
        self.assertTrue(gates)
        for record in gates:
            self.assertEqual((record['problems'], record['sample']['power_source'], record['sample']['power_supply']), ([], 'no-power-supply-devices', {}))
        for row in state['cases']:
            samples = self.case_samples(engine, row)
            self.assertTrue(samples)
            self.assertTrue(all(value['power_source'] == 'no-power-supply-devices' and 'BAT0' in value['power_supply'] for value in samples))

    def test_server_without_power_supply_devices_measures_under_its_declared_gate(self):
        self.args.power_source = 'no-power-supply-devices'
        self.reader.rows = [server_sample()]
        state = self.scheduler().run()
        self.assertEqual(state['state'], 'finished')
        self.assertTrue(all(row['state'] == 'successful' for row in state['cases']))

    def test_mains_device_disappearing_mid_case_invalidates_under_mains(self):
        original = self.reader.sample
        def unplugged(*args):
            value = original(*args)
            if args:
                value['ac_online'] = {}
                value['availability']['ac'] = False
            return value
        self.reader.sample = unplugged
        engine = self.scheduler()
        state = engine.run()
        self.assertTrue(all(row['state'] == 'invalid' for row in state['cases']))
        self.assertTrue(all('ac_sensor_unavailable' in row['attempts'][0]['details']['reasons'] for row in state['cases']))
        for row in state['cases']:
            self.assertTrue(all(value['power_source'] == 'mains' for value in self.case_samples(engine, row)))


class MetricsTests(unittest.TestCase):
    def test_physical_sibling_overlap(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for cpu in (0, 6):
                path = root / f'sys/devices/system/cpu/cpu{cpu}/topology'
                path.mkdir(parents=True)
                (path / 'thread_siblings_list').write_text('0,6')
            with self.assertRaisesRegex(ValueError, 'physical siblings overlap'):
                m.Reader(root=root).topology({'server': {0}, 'client': {6}})

    def test_sensor_reenumeration_and_wrong_sensor(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'sys/class/hwmon/hwmon9'
            path.mkdir(parents=True)
            for name, value in [('name', 'coretemp'), ('temp1_label', 'Package id 0'), ('temp1_input', '45000')]:
                (path / name).write_text(value)
            reader = m.Reader(str(root / 'sys/class/hwmon/hwmon6/temp1_input'), root=root)
            self.assertEqual(reader.sensor()['celsius'], 45)
            (path / 'temp1_label').write_text('GPU')
            self.assertFalse(reader.sensor()['available'])

    def test_counters_pid_reuse_disappearance_and_cgroup_values(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'proc').mkdir()
            cpu = root / 'sys/devices/system/cpu/cpu0/thermal_throttle'
            cpu.mkdir(parents=True)
            throttle = cpu / 'core_throttle_count'
            throttle.write_text('5')
            (root / 'proc/stat').write_text('cpu 10 0 0 90 0 0 0 0\n')
            proc = root / 'proc/123'
            proc.mkdir()
            def write_process(start, ticks):
                fields = ['S', '1', '123'] + ['0'] * 19
                fields[11], fields[12], fields[19], fields[21] = str(ticks), '0', str(start), '4'
                (proc / 'stat').write_text('123 (a name with ) paren) ' + ' '.join(fields))
                (proc / 'cgroup').write_text('0::/owned')
            write_process(10, 20)
            group = root / 'sys/fs/cgroup/owned'
            group.mkdir(parents=True)
            (group / 'memory.peak').write_text('4096')
            reader = m.Reader(root=root)
            owner = dict(pid=123, process=m.process(123, root / 'proc'), role='server', container='ours', cgroup={'path': '/owned'})
            reader.sample(123, [owner])
            throttle.write_text('3')
            write_process(11, 1)
            (root / 'proc/stat').write_text('cpu 1 0 0 9 0 0 0 0\n')
            row = reader.sample(123, [owner])
            self.assertTrue(row['counter_resets'])
            self.assertEqual(row['owned_cgroups'][0]['status'], 'disappeared-or-reused')
            self.assertEqual(m.cgroup_snapshot(123, root / 'proc', root / 'sys')['memory.peak'], 4096)
            (proc / 'stat').unlink()
            throttle.unlink()
            row = reader.sample(123, [owner])
            self.assertTrue(any('throttle_disappeared' in s for s in row['counter_resets']))

    def test_validity_throttle_external_and_owned_attribution(self):
        args = type('Args', (), dict(max_temp_c=90))()
        row = sample()
        row['throttle_delta'] = {'cpu0': 1}
        row['external_cpu'] = [dict(pid=123, start_ticks=20, comm='rustc', cgroup='0::/external')]
        self.assertEqual(scheduler.validity([row], [], args), ['external_cpu_activity', 'thermal_throttling'])
        owner = dict(pid=123, process={'start_ticks': 20})
        self.assertEqual(scheduler.validity([row], [owner], args), ['thermal_throttling'])

    def test_missing_and_unreadable_sensors_cannot_pass(self):
        args = type('Args', (), dict(max_temp_c=90))()
        variants = [dict(ac_online={}), dict(ac_online={'AC': None}), dict(throttle={}),
                    dict(throttle={'cpu0': None}), dict(throttle_delta={}),
                    dict(availability=dict(cpu=False, process_scan=True, ac=True))]
        for update in variants:
            with self.subTest(update=update):
                row = dict(sample(), **update)
                self.assertTrue(scheduler.validity([row], [], args))
        row = sample()
        row['throttle']['cpu0'] = 100000
        self.assertEqual(scheduler.validity([row], [], args), [])

    def test_unreadable_throttle_counter_retains_missing_delta(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'sys/devices/system/cpu/cpu0/thermal_throttle'
            path.mkdir(parents=True)
            counter = path / 'core_throttle_count'
            counter.write_text('7')
            reader = m.Reader(root=root)
            first = reader.sample()
            self.assertFalse(first['throttle_delta'])
            counter.write_text('unreadable')
            second = reader.sample()
            self.assertIsNone(next(iter(second['throttle'].values())))
            self.assertFalse(second['throttle_delta'])
            counter.write_text('7')
            self.assertFalse(reader.sample()['throttle_delta'])
            self.assertEqual(next(iter(reader.sample()['throttle_delta'].values())), 0)

    def test_partial_jsonl_tail_is_preserved_and_separated(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'events.jsonl'
            path.write_text('{"partial":')
            m.append_json(path, {'event': 'new'})
            rows = scheduler.owner_rows(path)
            self.assertEqual(rows[0]['event'], 'malformed')
            self.assertTrue(rows[1]['recovered_partial_tail'])


    def test_reader_lists_every_power_supply_device(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            reader = m.Reader(root=root)
            row = reader.sample()
            self.assertIsNone(row['power_supply'])
            self.assertFalse(row['availability']['power_supply'])
            self.assertFalse(row['availability']['ac'])
            supplies = root / 'sys/class/power_supply'
            supplies.mkdir(parents=True)
            row = reader.sample()
            self.assertEqual(row['power_supply'], {})
            self.assertTrue(row['availability']['power_supply'])
            for name, kind, online in (('AC', 'Mains', '1'), ('BAT0', 'Battery', None)):
                (supplies / name).mkdir()
                (supplies / name / 'type').write_text(kind + '\n')
                if online:
                    (supplies / name / 'online').write_text(online + '\n')
            row = reader.sample()
            self.assertEqual(row['power_supply'], {'AC': dict(type='Mains', online=1), 'BAT0': dict(type='Battery', online=None)})
            self.assertEqual(row['ac_online'], {'AC': 1})
            self.assertTrue(row['availability']['ac'])
            self.assertEqual(m.power_supplies(root / 'sys'), row['power_supply'])


if __name__ == '__main__':
    unittest.main()
