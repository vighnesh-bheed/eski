import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


def module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


HERE = Path(__file__).resolve().parent
plans = module(HERE / 'plans.py', 'eski_testbed_plans')
spec = module(HERE.parent / 'spec.py', 'eski_bench_spec')
scheduler = module(HERE.parent / 'exam_scheduler.py', 'eski_exam_scheduler')
workflow = module(HERE.parent / 'exam_workflow.py', 'eski_exam_workflow')
DESIGN = json.loads((HERE / 'design.json').read_text())


class PlanTests(unittest.TestCase):
    def write(self, design=DESIGN):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        written = plans.write(design, temporary.name)
        return Path(temporary.name), written

    def test_design_names_four_pinned_engines_eight_workloads_and_four_repetitions(self):
        plans.validate(DESIGN)
        self.assertEqual([engine['target'] for engine in DESIGN['engines']], ['eski-docker', 'redis', 'valkey', 'dragonfly'])
        self.assertEqual(DESIGN['engines'][0]['image'], 'bench/image.json')
        self.assertTrue(all('@sha256:' in engine['image'] for engine in DESIGN['engines'][1:]))
        self.assertEqual(len(DESIGN['workloads']), 8)
        self.assertEqual(DESIGN['repetitions'], 4)
        self.assertEqual(DESIGN['calibration']['repetitions'], 1)

    def test_files_are_deterministic_and_complete(self):
        first, written = self.write()
        second, again = self.write()
        self.assertEqual(written, again)
        self.assertEqual(sorted(written), ['benchmark/experiment.json', 'benchmark/plan.json', 'calibration/experiment.json', 'calibration/plan.json'])
        for name in written:
            self.assertEqual((first / name).read_bytes(), (second / name).read_bytes())

    def test_experiments_match_the_workflow_fields(self):
        root, _ = self.write()
        for phase, repetitions in (('calibration', 1), ('benchmark', 4)):
            value = json.loads((root / phase / 'experiment.json').read_text())
            self.assertEqual(set(value), set(workflow.EXPERIMENT_FIELDS) | {'schema', 'power_source'})
            self.assertIn('power_source', workflow.OPTIONAL_FIELDS)
            self.assertEqual(value['power_source'], 'mains')
            self.assertEqual(value['repetitions'], repetitions)
            self.assertEqual(value['targets'], ['eski-docker', 'redis', 'valkey', 'dragonfly'])
            self.assertEqual(value['server_cpus'], DESIGN['resources']['server_cpus'])
            self.assertEqual(value['max_latency_seconds'], DESIGN['gates']['max_latency_seconds'])

    def test_items_validate_and_fit_the_client_pool(self):
        root, _ = self.write()
        benchmark = json.loads((root / 'benchmark' / 'plan.json').read_text())['items']
        calibration = json.loads((root / 'calibration' / 'plan.json').read_text())['items']
        self.assertEqual([item['key'] for item in benchmark], [workload['key'] for workload in DESIGN['workloads']])
        self.assertEqual([item['key'] for item in calibration], DESIGN['calibration']['workloads'])
        self.assertEqual(calibration[0], next(item for item in benchmark if item['key'] == calibration[0]['key']))
        pool = sorted(scheduler.metrics.cpu_set(DESIGN['resources']['client_cpus']))
        keys = DESIGN['dataset']['keys']
        for item in benchmark:
            spec.validate_item(item, item['key'])
            self.assertTrue(all(need <= len(pool) for need in scheduler.client_needs(item['clients'] + [item['warmup']], pool)))
            timed, warmup, preload = item['clients'][0]['argv'], item['warmup']['argv'], item['preload']['argv']
            self.assertIn('--test-time=%d' % DESIGN['client']['test_seconds'], timed)
            self.assertIn('--test-time=%d' % DESIGN['client']['warmup_seconds'], warmup)
            self.assertEqual([arg for arg in timed if not arg.startswith('--test-time')], [arg for arg in warmup if not arg.startswith('--test-time')])
            self.assertIn('--requests=%d' % keys, preload)
            self.assertIn('--distinct-client-seed', timed)
            self.assertNotIn('--randomize', ' '.join(timed))
            self.assertEqual(item['check']['keyspacelen'], keys)
            self.assertEqual(item['check']['replies'][0], dict(argv=['DBSIZE'], equals=keys))
            self.assertTrue(item['fresh_server'])
            self.assertFalse(item['flush_each_run'])
            self.assertEqual(item['clients'][0]['image'], 'memtier')
        zscore = next(item for item in benchmark if item['key'] == 'zscore16-p1')
        self.assertIn(dict(argv=['ZSCORE', 'testbed:50000', 'member:8'], equals='8'), zscore['check']['replies'])
        self.assertIn('ZADD __key__ 1 member:1', ' '.join(zscore['preload']['argv']))
        self.assertEqual(zscore['required_commands'], ['dbsize', 'zadd', 'zcard', 'zscore'])
        mixed = next(item for item in benchmark if item['key'] == 'mixed64-p16')
        self.assertIn('--pipeline=16', mixed['clients'][0]['argv'])
        self.assertIn('--ratio=1:1', mixed['clients'][0]['argv'])
        self.assertEqual(mixed['info']['tested_commands'], ['get', 'set'])
        hget = next(item for item in benchmark if item['key'] == 'hget16-p1')
        self.assertIn(dict(argv=['HSTRLEN', 'testbed:1', 'field:8'], equals=64), hget['check']['replies'])

    def test_power_source_defaults_to_mains_and_accepts_the_server_value(self):
        self.assertEqual(plans.POWER_SOURCES, scheduler.POWER_SOURCES)
        self.assertEqual(DESIGN['gates']['power_source'], 'mains')
        undeclared = copy.deepcopy(DESIGN)
        del undeclared['gates']['power_source']
        server = copy.deepcopy(DESIGN)
        server['gates']['power_source'] = 'no-power-supply-devices'
        for design, expected in ((DESIGN, 'mains'), (undeclared, 'mains'), (server, 'no-power-supply-devices')):
            for phase in plans.PHASES:
                with self.subTest(expected=expected, phase=phase):
                    self.assertEqual(plans.experiment(design, phase)['power_source'], expected)
                    arguments = scheduler.parser().parse_args(['run', '--output', 'unused', '--power-source', plans.experiment(design, phase)['power_source']])
                    self.assertEqual(arguments.power_source, expected)
        self.assertEqual(plans.plan(undeclared, 'benchmark'), plans.plan(DESIGN, 'benchmark'))
        for value in ('battery', None, ''):
            broken = copy.deepcopy(DESIGN)
            broken['gates']['power_source'] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'gates.power_source must be one of mains, no-power-supply-devices'):
                plans.validate(broken)

    def test_tracked_designs_validate_and_can_be_published(self):
        designs = sorted((HERE / 'designs').glob('*.json'))
        self.assertTrue(designs)
        for path in [HERE / 'design.json'] + designs:
            with self.subTest(design=path.name):
                design = json.loads(path.read_text())
                root, _ = self.write(design)
                roles = [scheduler.metrics.cpu_set(design['resources'][name]) for name in ('server_cpus', 'client_cpus', 'control_cpus')]
                self.assertEqual(sum(map(len, roles)), len(set.union(*roles)))
                self.assertNotIn(0, set.union(*roles))
                pool = sorted(roles[1])
                for item in json.loads((root / 'benchmark' / 'plan.json').read_text())['items']:
                    spec.validate_item(item, item['key'])
                    self.assertTrue(all(need <= len(pool) for need in scheduler.client_needs(item['clients'] + [item['warmup']], pool)))
                experiment = json.loads((root / 'benchmark' / 'experiment.json').read_text())
                self.assertEqual(experiment['power_source'], design['gates'].get('power_source', 'mains'))
                self.assertLessEqual({'eski-docker', 'redis'}, set(experiment['targets']))
                self.assertIn('get64-p1', [workload['key'] for workload in design['workloads']])

    def test_invalid_designs_are_rejected(self):
        cases = []
        unpinned = copy.deepcopy(DESIGN)
        unpinned['engines'][1]['image'] = 'docker.io/library/redis:7'
        cases.append((unpinned, 'pinned'))
        duplicate = copy.deepcopy(DESIGN)
        duplicate['workloads'][1]['key'] = duplicate['workloads'][0]['key']
        cases.append((duplicate, 'unique'))
        kind = copy.deepcopy(DESIGN)
        kind['workloads'][0]['type'] = 'list'
        cases.append((kind, 'type'))
        calibration = copy.deepcopy(DESIGN)
        calibration['calibration']['workloads'] = ['unknown']
        cases.append((calibration, 'calibration'))
        gates = copy.deepcopy(DESIGN)
        del gates['gates']['min_rest']
        cases.append((gates, 'min_rest'))
        target = copy.deepcopy(DESIGN)
        target['engines'][0]['target'] = 'keydb'
        cases.append((target, 'targets'))
        for design, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                plans.validate(design)

    def test_command_line_writes_the_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assertEqual(plans.main(['--out', temporary]), 0)
            self.assertTrue((Path(temporary) / 'benchmark' / 'plan.json').is_file())
            broken = Path(temporary) / 'broken.json'
            broken.write_text(json.dumps(dict(DESIGN, schema='other')))
            self.assertEqual(plans.main(['--design', str(broken), '--out', temporary]), 2)


if __name__ == '__main__':
    unittest.main()
