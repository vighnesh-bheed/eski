import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('eski_exam_workflow', Path(__file__).with_name('exam_workflow.py'))
workflow = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(workflow)
TARGETS = ['eski-docker', 'redis', 'valkey', 'dragonfly']


SCHEDULER = '''import hashlib,importlib.util,json,os,signal,sys,time
from pathlib import Path
s=importlib.util.spec_from_file_location('real_scheduler',os.environ['ESKI_TEST_REAL_SCHEDULER'])
real=importlib.util.module_from_spec(s);s.loader.exec_module(real)
atomic,atomic_bytes,status_view,metrics,Lock,TERMINAL,canonical=real.atomic,real.atomic_bytes,real.status_view,real.metrics,real.Lock,real.TERMINAL,real.canonical

def option(name):
 return sys.argv[sys.argv.index(name)+1]

def identity():
 workspace=Path(__file__).resolve().parent.parent
 profile=json.loads((workspace/'profile.json').read_text())
 for name,expected in profile['files'].items():
  if real.sha(workspace/name)!=expected:raise ValueError('profile file hash mismatch: '+name)
 cpus={role:sorted(metrics.cpu_set(option('--'+role+'-cpus'))) for role in ('server','client','control')}
 value=dict(plan_sha256=real.sha(option('--plan')),profile_sha256=real.sha(option('--profile')),
            config=dict(targets=option('--targets').split(','),repetitions=int(option('--repetitions')),cpus=cpus))
 value['sha256']=hashlib.sha256(canonical(value)).hexdigest()
 return value

def main():
 command=sys.argv[1]
 output=Path(option('--output'));phase=output.parent.name;root=output.parent.parent
 with (root/'control'/'calls.jsonl').open('a') as f:f.write(json.dumps(dict(phase=phase,command=command,argv=sys.argv[2:],affinity=sorted(os.sched_getaffinity(0))))+'\\n')
 value=identity()
 if command=='inspect':print(json.dumps(dict(identity=value)));return 0
 path=root/'control'/(phase+'-behavior.json')
 behavior=json.loads(path.read_text()) if path.exists() else {}
 stopped=False
 def stop(*_):
  nonlocal stopped
  stopped=True
 signal.signal(signal.SIGTERM,stop)
 signal.signal(signal.SIGINT,stop)
 (root/'control'/(phase+'.started')).touch()
 while behavior.get('wait') and not stopped:time.sleep(.01)
 output.mkdir(parents=True,exist_ok=True)
 rows=[]
 for target in value['config']['targets']:
  state='interrupted' if stopped else behavior.get('states',{}).get(target,'successful')
  rows.append(dict(id=target,key=phase,name=phase,suite='fixture',index=0,target=target,repetition=1,state=state,
                   attempts=[dict(state=state,directory='cases/'+target,cleanup={'ok':True})]))
 checkpoint=dict(cases=rows,state='paused' if stopped else 'finished',identity=value['sha256'])
 atomic(output/'checkpoint.json',checkpoint)
 atomic(output/'identity.json',value)
 (output/'raw-client.json').write_text(json.dumps(dict(fixture=True)))
 if behavior.get('mutate_profile'):
  profile_path=Path(__file__).resolve().parent.parent/'plans'/'benchmark'/'plan.json'
  profile_path.write_text(profile_path.read_text()+' ')
 return 130 if stopped else behavior.get('exitcode',0)

if __name__=='__main__':
 try:sys.exit(main())
 except Exception as error:print(str(error),file=sys.stderr);sys.exit(2)
'''


TMUX = '''import json,os,sys
from pathlib import Path
control=Path(os.environ['ESKI_TEST_ROOT'])/'control'
control.mkdir(exist_ok=True)
with (control/'tmux-calls.jsonl').open('a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1]=='has-session':sys.exit(0 if (control/'tmux-alive').exists() else 1)
if (control/'tmux-fail').exists():print('fixture launch failure',file=sys.stderr);sys.exit(1)
(control/'tmux-alive').touch()
'''


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / 'root'
        self.control = self.root / 'control'
        self.control.mkdir(parents=True)
        self.cpus = sorted(os.sched_getaffinity(0))[:3]
        if len(self.cpus) < 3:
            self.skipTest('three allowed logical CPUs are needed')
        self.env = dict(os.environ, ESKI_TEST_ROOT=str(self.root), TMPDIR=self.temporary.name, PYTHONDONTWRITEBYTECODE='1',
                        ESKI_TEST_REAL_SCHEDULER=str(Path(__file__).with_name('exam_scheduler.py').resolve()))
        base = self.root / 'workspace'
        (base / 'bench').mkdir(parents=True)
        (base / 'bench' / 'exam_scheduler.py').write_text(SCHEDULER)
        for name in ('exam.sh', 'exam_workflow.py'):
            shutil.copy2(Path(__file__).with_name(name), base / 'bench' / name)
        (base / 'tools' / 'bin').mkdir(parents=True)
        self.executable(base / 'tools' / 'bin' / 'tmux', TMUX)
        (base / 'tools' / 'lib').mkdir()
        (base / 'tools' / 'lib' / 'libfixture.so.1.0.4').write_bytes(b'fixture library')
        (base / 'tools' / 'lib' / 'libfixture.so.1').symlink_to('libfixture.so.1.0.4')
        for phase, repetitions in (('calibration', 1), ('benchmark', 4)):
            directory = base / 'plans' / phase
            directory.mkdir(parents=True)
            config = dict(schema='eski-exam-experiment-v1', targets=TARGETS, server_cpus=str(self.cpus[0]), client_cpus=str(self.cpus[1]),
                          control_cpus=str(self.cpus[2]), server_memory='8g', client_memory='2g', maxmemory=6442450944, repetitions=repetitions,
                          sensor_chip='coretemp', sensor_label='Package id 0', cool_temp_c=55, max_temp_c=90, min_idle=95, min_rest=30,
                          stable_seconds=10, max_wait=600, sample_seconds=1, min_free_bytes=0, resource_policy='strict',
                          max_client_utilization_pct=85, max_latency_seconds=120)
            (directory / 'experiment.json').write_text(json.dumps(config))
            (directory / 'plan.json').write_text(json.dumps(dict(items=[dict(key=phase, name=phase, suite='fixture', clients=[])] * (1 if phase == 'calibration' else 2))))
        files = {str(path.relative_to(base)): workflow.digest(path) for path in sorted(base.rglob('*')) if path.is_file()}
        (base / 'profile.json').write_text(json.dumps(dict(schema='eski-exam-profile-v1', source_revision='fixture', source_sha256='0' * 64, tool_bin='tools/bin', files=files)))
        (self.root / 'engines.json').write_text(json.dumps(dict(engines=[dict(target=t, version='fixture ' + t, image_id='sha256:' + 'a' * 64) for t in TARGETS])))
        (self.root / 'design.json').write_text(json.dumps(dict(fixture=True)))
        identities = json.loads(self.invoke('inspect').stdout)['phases']
        protocol = dict(schema='eski-exam-protocol-v1', phases={phase: dict(identity=value['sha256'], plan_sha256=value['plan_sha256']) for phase, value in identities.items()})
        (self.root / 'protocol.json').write_text(json.dumps(protocol))
        self.reset()

    def tearDown(self):
        self.temporary.cleanup()

    def executable(self, path, code):
        path.write_text('#!' + sys.executable + '\n' + code)
        path.chmod(0o755)

    def invoke(self, *arguments, code=0):
        done = subprocess.run([sys.executable, '-B', str(Path(workflow.__file__)), '--root', str(self.root), *arguments],
                              env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, code, done.stdout + done.stderr)
        return done

    def reset(self):
        (self.control / 'calls.jsonl').write_text('')

    def calls(self, name='calls.jsonl'):
        path = self.control / name
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def launches(self):
        return sum(call[0] == 'new-session' for call in self.calls('tmux-calls.jsonl'))

    def runs(self):
        return [(call['phase'], call['command']) for call in self.calls() if call['command'] != 'inspect']

    def behavior(self, phase, **value):
        (self.control / (phase + '-behavior.json')).write_text(json.dumps(value))

    def state(self):
        return workflow.load(self.control / 'workflow.json')

    def start(self):
        self.invoke()
        self.assertEqual(self.state()['status'], 'STARTING')
        self.reset()

    def test_default_starts_once_and_status_never_starts(self):
        status = json.loads(self.invoke('status', '--json').stdout)
        self.assertEqual(status['status'], 'NOT STARTED')
        self.assertEqual(status['design']['benchmark'], dict(workloads=2, targets=4, repetitions=4, measurements=32))
        self.assertEqual(status['design']['calibration']['measurements'], 4)
        text = self.invoke('status').stdout
        self.assertTrue(text.startswith('Machine: '))
        self.assertIn('Design: 2 workloads x 4 engines x 4 repetitions = 32 measurements', text)
        self.assertIn('Engine eski-docker: fixture eski-docker', text)
        self.assertFalse((self.control / 'workflow.json').exists())
        self.assertEqual(self.launches(), 0)
        first = self.invoke()
        self.assertIn('Workflow: STARTING', first.stdout)
        self.assertTrue((self.control / 'frozen-launch.json').exists())
        self.invoke()
        self.invoke('--json')
        self.invoke('status')
        self.assertEqual(self.launches(), 1)
        self.assertEqual(self.runs(), [])
        (self.control / 'tmux-alive').unlink()
        self.assertEqual(json.loads(self.invoke('status', '--json').stdout)['status'], 'INTERRUPTED')
        self.assertEqual(self.launches(), 1)

    def test_tmux_failure_holds_without_retry(self):
        (self.control / 'tmux-fail').touch()
        self.invoke(code=2)
        self.assertEqual(self.state()['status'], 'HELD')
        self.invoke()
        self.assertEqual(self.launches(), 1)
        self.assertEqual(self.runs(), [])

    def test_every_calibration_engine_must_pass(self):
        self.behavior('calibration', states={'dragonfly': 'invalid'})
        self.start()
        self.invoke('_run', code=2)
        state = self.state()
        self.assertEqual(self.runs(), [('calibration', 'run')])
        self.assertEqual((state['status'], state['phase']), ('HELD', 'calibration'))
        self.assertFalse(state['phase_outcomes']['calibration']['checkpoint_passed'])
        self.assertTrue((self.root / 'exports' / 'results.tar.gz').is_file())
        self.invoke('resume', code=2)
        self.assertEqual(self.launches(), 1)

    def test_nonzero_calibration_exit_cannot_admit_the_benchmark(self):
        self.behavior('calibration', exitcode=7)
        self.start()
        self.invoke('_run', code=2)
        self.assertEqual(self.runs(), [('calibration', 'run')])
        self.assertEqual(self.state()['phase_outcomes']['calibration']['exitcode'], 7)
        self.assertEqual(self.state()['status'], 'HELD')

    def test_protocol_mismatch_prevents_start_and_any_phase(self):
        protocol = workflow.load(self.root / 'protocol.json')
        protocol['phases']['benchmark']['identity'] = 'changed'
        (self.root / 'protocol.json').write_text(json.dumps(protocol))
        self.invoke(code=2)
        self.assertFalse((self.control / 'workflow.json').exists())
        self.assertEqual(self.launches(), 0)

    def test_changed_input_after_calibration_prevents_the_benchmark(self):
        self.behavior('calibration', mutate_profile=True)
        self.start()
        self.invoke('_run', code=2)
        self.assertEqual(self.runs(), [('calibration', 'run')])
        self.assertEqual(self.state()['status'], 'HELD')

    def test_success_pins_controller_and_exports_with_receipt(self):
        self.start()
        self.invoke('_run')
        state = self.state()
        self.assertEqual(self.runs(), [('calibration', 'run'), ('benchmark', 'run')])
        self.assertEqual((state['status'], state['phase']), ('DONE', 'benchmark'))
        self.assertEqual(state['control_cpus'], [self.cpus[2]])
        self.assertTrue(all(call['affinity'] == self.cpus for call in self.calls()))
        receipt = workflow.load(self.root / 'exports' / 'receipt.json')
        archive = self.root / 'exports' / receipt['archive']
        self.assertEqual(receipt['sha256'], workflow.digest(archive))
        self.assertEqual(receipt['bytes'], archive.stat().st_size)
        self.assertEqual(receipt['workflow_status'], 'DONE')
        with tarfile.open(archive) as handle:
            names = set(handle.getnames())
            for name in ('protocol.json', 'engines.json', 'control/workflow.json', 'control/frozen-launch.json', 'calibration/results/raw-client.json',
                         'benchmark/results/checkpoint.json', 'workspace/profile.json', 'workspace/bench/exam_workflow.py',
                         'workspace/plans/benchmark/plan.json', 'exports/inventory.json'):
                self.assertIn(name, names)
            inventory = json.load(handle.extractfile('exports/inventory.json'))
        self.assertEqual(set(inventory), names - {'exports/inventory.json'})
        self.assertEqual(inventory['protocol.json']['sha256'], workflow.digest(self.root / 'protocol.json'))
        self.assertFalse(any(name.startswith('workspace/tools/') for name in names))
        self.assertEqual(receipt['tools_verified_not_archived'], 3)
        self.assertIsNone(receipt['exporter'])
        before = (self.control / 'workflow.json').read_bytes()
        self.invoke('_run', code=2)
        self.assertEqual((self.control / 'workflow.json').read_bytes(), before)
        self.invoke('resume', code=2)
        self.assertEqual(len(self.runs()), 2)
        text = self.invoke('status').stdout
        self.assertIn('Workflow: DONE', text)
        self.assertIn('Export: exports/results.tar.gz', text)

    def test_nonsuccess_benchmark_is_done_with_exclusions(self):
        self.behavior('benchmark', states={'valkey': 'invalid'}, exitcode=2)
        self.start()
        self.invoke('_run', code=2)
        self.assertEqual(self.state()['status'], 'DONE WITH EXCLUSIONS')

    def run_and_stop(self, phase):
        child = subprocess.Popen([sys.executable, '-B', str(Path(workflow.__file__)), '--root', str(self.root), '_run'],
                                 env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 20
            while not (self.control / (phase + '.started')).exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue((self.control / (phase + '.started')).exists())
            child.send_signal(signal.SIGTERM)
            output, error = child.communicate(timeout=20)
            self.assertEqual(child.returncode, 2, output + error)
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()

    def test_interruption_and_explicit_resume_keep_finished_phases(self):
        self.behavior('benchmark', wait=True)
        self.start()
        self.run_and_stop('benchmark')
        state = self.state()
        self.assertEqual((state['status'], state['phase']), ('INTERRUPTED', 'benchmark'))
        self.assertTrue((self.root / 'exports' / 'results.tar.gz').is_file())
        self.assertEqual(self.runs(), [('calibration', 'run'), ('benchmark', 'run')])
        self.behavior('benchmark')
        (self.control / 'tmux-alive').unlink()
        self.reset()
        self.invoke('resume')
        self.assertEqual(self.state()['status'], 'STARTING')
        self.assertEqual(self.launches(), 2)
        self.invoke('_run')
        self.assertEqual(self.runs(), [('benchmark', 'resume')])
        resumed = [call for call in self.calls() if call['command'] == 'resume'][0]
        self.assertIn('--retry-interrupted', resumed['argv'])
        self.assertEqual(self.state()['status'], 'DONE')
        self.assertEqual(self.state()['launches'], 2)
        self.assertTrue((self.root / 'exports' / 'results-2.tar.gz').is_file())
        self.assertEqual(workflow.load(self.root / 'exports' / 'receipt.json')['archive'], 'results-2.tar.gz')

    def test_signal_during_calibration_never_reaches_the_benchmark(self):
        self.behavior('calibration', wait=True)
        self.start()
        self.run_and_stop('calibration')
        self.assertEqual(self.runs(), [('calibration', 'run')])
        self.assertEqual((self.state()['status'], self.state()['phase']), ('INTERRUPTED', 'calibration'))

    def test_resume_requires_a_stopped_started_workflow(self):
        self.invoke('resume', code=2)
        self.start()
        self.invoke('resume', code=2)
        self.assertEqual(self.launches(), 1)

    def test_manual_collect_refuses_an_active_controller(self):
        self.invoke('collect', code=2)
        self.start()
        self.invoke('collect', code=2)
        (self.control / 'tmux-alive').unlink()
        receipt = json.loads(self.invoke('collect').stdout)
        self.assertEqual(receipt['archive'], 'results.tar.gz')

    def test_installed_wrapper_runs_only_inside_a_root(self):
        done = subprocess.run(['bash', str(self.root / 'workspace' / 'bench' / 'exam.sh'), 'status'], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('Workflow: NOT STARTED', done.stdout)
        self.assertFalse(list((self.root / 'workspace').rglob('__pycache__')))
        outside = Path(self.temporary.name) / 'bench'
        outside.mkdir()
        shutil.copy2(Path(__file__).with_name('exam.sh'), outside / 'exam.sh')
        done = subprocess.run(['bash', str(outside / 'exam.sh'), 'status'], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 2)
        self.assertIn('installed by bench/testbed/install.py', done.stderr)

    def profile_entry(self, name):
        path = self.root / 'workspace' / 'profile.json'
        profile = json.loads(path.read_text())
        profile['files'][name] = workflow.digest(self.root / 'workspace' / name)
        path.write_text(json.dumps(profile))

    def test_tool_links_are_verified_but_not_archived(self):
        files, notes = workflow.export_files(self.root)
        self.assertEqual(notes, dict(tools_verified_not_archived=3, exporter=None))
        self.assertFalse(any(path.is_relative_to(self.root / 'workspace' / 'tools') for path in files))
        self.assertIn(self.root / 'workspace' / 'bench' / 'exam_scheduler.py', files)
        library = self.root / 'workspace' / 'tools' / 'lib' / 'libfixture.so.1.0.4'
        library.write_bytes(b'changed library')
        with self.assertRaisesRegex(ValueError, 'changed before export: tools/lib/libfixture'):
            workflow.export_files(self.root)
        library.write_bytes(b'fixture library')
        link = self.root / 'workspace' / 'tools' / 'lib' / 'libfixture.so.1'
        link.unlink()
        link.symlink_to('../../plans/benchmark/plan.json')
        self.profile_entry('tools/lib/libfixture.so.1')
        with self.assertRaisesRegex(ValueError, 'outside the tools directory'):
            workflow.export_files(self.root)

    def test_links_outside_the_tools_directory_stay_unsafe(self):
        (self.root / 'workspace' / 'bench' / 'linked.py').symlink_to('exam_scheduler.py')
        self.profile_entry('bench/linked.py')
        with self.assertRaisesRegex(ValueError, 'unsafe workspace inventory entry: bench/linked.py'):
            workflow.export_files(self.root)

    def test_a_replaced_exporter_is_recorded_and_nothing_else_may_change(self):
        installed = self.root / 'workspace' / 'bench' / 'exam_workflow.py'
        recorded = workflow.digest(installed)
        installed.write_text(installed.read_text() + '\n')
        with patch.object(workflow, 'exporter_path', return_value=installed.resolve()):
            files, notes = workflow.export_files(self.root)
            self.assertIn(installed, files)
            self.assertEqual(notes['exporter'], dict(path='workspace/bench/exam_workflow.py', sha256=workflow.digest(installed), recorded_sha256=recorded, matches=False))
            plan = self.root / 'workspace' / 'plans' / 'benchmark' / 'plan.json'
            plan.write_text(plan.read_text() + ' ')
            with self.assertRaisesRegex(ValueError, 'changed before export: plans/benchmark/plan.json'):
                workflow.export_files(self.root)
        with self.assertRaisesRegex(ValueError, 'changed before export: bench/exam_workflow.py'):
            workflow.export_files(self.root)

    def test_experiment_fields_are_closed(self):
        path = self.root / 'workspace' / 'plans' / 'benchmark' / 'experiment.json'
        config = json.loads(path.read_text())
        config['unexpected'] = 1
        path.write_text(json.dumps(config))
        with self.assertRaisesRegex(ValueError, 'unknown'):
            workflow.experiment(self.root, 'benchmark')
        del config['unexpected']
        del config['min_rest']
        path.write_text(json.dumps(config))
        with self.assertRaisesRegex(ValueError, 'missing'):
            workflow.experiment(self.root, 'benchmark')

    def test_phase_arguments_follow_the_experiment(self):
        with patch.dict(os.environ, self.env, clear=True):
            executable, arguments, environment = workflow.phase_arguments(self.root, 'benchmark')
        self.assertEqual(executable[:3], ['taskset', '--cpu-list', ','.join(map(str, self.cpus))])
        self.assertEqual(arguments[arguments.index('--targets') + 1], ','.join(TARGETS))
        self.assertEqual(arguments[arguments.index('--repetitions') + 1], '4')
        self.assertEqual(arguments[arguments.index('--output') + 1], str(self.root / 'benchmark' / 'results'))
        self.assertTrue(environment['PATH'].startswith(str((self.root / 'workspace' / 'tools' / 'bin').resolve())))


    def test_power_source_is_optional_and_reaches_the_scheduler_and_status(self):
        with patch.dict(os.environ, self.env, clear=True):
            _, arguments, _ = workflow.phase_arguments(self.root, 'benchmark')
        self.assertNotIn('--power-source', arguments)
        status = json.loads(self.invoke('status', '--json').stdout)
        self.assertEqual(status['machine']['power_source'], 'mains')
        self.assertIn('Power gate: mains | power supply devices: ', self.invoke('status').stdout)
        path = self.root / 'workspace' / 'plans' / 'benchmark' / 'experiment.json'
        config = json.loads(path.read_text())
        config['power_source'] = 'no-power-supply-devices'
        path.write_text(json.dumps(config))
        self.assertEqual(workflow.experiment(self.root, 'benchmark')['power_source'], 'no-power-supply-devices')
        with patch.dict(os.environ, self.env, clear=True):
            _, arguments, _ = workflow.phase_arguments(self.root, 'benchmark')
        self.assertEqual(arguments[arguments.index('--power-source') + 1], 'no-power-supply-devices')
        status = json.loads(self.invoke('status', '--json').stdout)
        self.assertEqual(status['machine']['power_source'], 'no-power-supply-devices')
        self.assertIn('Power gate: no-power-supply-devices | power supply devices: ', self.invoke('status').stdout)

if __name__ == '__main__':
    unittest.main()
