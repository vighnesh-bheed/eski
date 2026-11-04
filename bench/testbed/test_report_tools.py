import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import statistics
import tarfile
import tempfile
import unittest
import xml.etree.ElementTree as ElementTree


def module(name):
    spec = importlib.util.spec_from_file_location('eski_testbed_' + name, Path(__file__).with_name(name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


combine = module('combine')
charts = module('charts')
page = module('page')
collect = module('collect')

ENGINES = [dict(target='eski-docker', label='Eski', reference='eski:local', image_id='sha256:' + '1' * 64),
           dict(target='redis', label='Redis 7.4.12', reference='redis@sha256:' + '2' * 64, image_id='sha256:' + '2' * 64),
           dict(target='valkey', label='Valkey 8.1.11', reference='valkey@sha256:' + '3' * 64, image_id='sha256:' + '3' * 64),
           dict(target='dragonfly', label='Dragonfly 2.0.2', reference='dragonfly@sha256:' + '4' * 64, image_id='sha256:' + '4' * 64)]
WORKLOADS = [dict(key='get64-p1', name='GET 64 B, pipeline 1'), dict(key='mixed64-p16', name='SET and GET 1:1, 64 B, pipeline 16')]
BASE = {'eski-docker': 200000.0, 'redis': 160000.0, 'valkey': 150000.0, 'dragonfly': 100000.0}
SPECIAL = {('benchmark', 'mixed64-p16', 'valkey', 2): 'thermal', ('benchmark', 'get64-p1', 'dragonfly', 3): 'failed',
           ('benchmark', 'get64-p1', 'eski-docker', 1): 'limited'}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def dump(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True))


def values(phase, workload, engine, repetition):
    factor = 10 if workload == 'mixed64-p16' else 1
    ops = BASE[engine] * factor * (1 + 0.01 * repetition)
    return dict(ops_per_sec=ops, p50_ms=0.1 + 0.01 * repetition, p99_ms=0.2 + 0.02 * repetition + (0.1 if engine == 'dragonfly' else 0),
                p999_ms=0.5, max_ms=3.0, client_cpu_cores=1.2), 20 * 1024 ** 2 + repetition * 1024 ** 2 + list(BASE).index(engine) * 4 * 1024 ** 2


def make_results(root):
    protocol = dict(schema='eski-exam-protocol-v1', root='comparison-v1', engines=ENGINES,
                    design=dict(title='Fixture comparison', repetitions=4, workloads=WORKLOADS, engines=[dict(target=e['target'], label=e['label']) for e in ENGINES],
                                dataset=dict(keys=100000), client=dict(threads=2, connections_per_thread=16, test_seconds=60, warmup_seconds=10),
                                gates=dict(cool_temp_c=55, max_temp_c=90, min_idle=95, stable_seconds=10, min_rest=30, max_client_utilization_pct=85, max_latency_seconds=120),
                                methodology=dict(scope='Fixture scope text.', fill='Fixture fill text.'), load_generator=dict(label='memtier_benchmark 2.5.2')),
                    machine=dict(cpu_model='Fixture CPU @ 2.20GHz', kernel='6.12.0', machine='x86_64', online_cpus='0-11', mem_total='MemTotal:       16000000 kB',
                                 hardware=dict(sys_vendor='Fixture', product_name='Laptop'), frequency_policy={'1': dict(scaling_governor='powersave', scaling_driver='intel_pstate', energy_performance_preference='balance_performance')}),
                    resources=dict(cpus=dict(server=[1], client=[3, 4], control=[5, 11]), server_memory='8g', client_memory='2g', maxmemory=6442450944, dragonfly_threads=1))
    dump(root / 'protocol.json', protocol)
    dump(root / 'control' / 'workflow.json', dict(status='DONE WITH EXCLUSIONS', reason='fixture', started_at=1.0, finished_at=2.0))
    expected = {}
    for phase, workloads, repetitions in (('calibration', WORKLOADS[1:], 1), ('benchmark', WORKLOADS, 4)):
        cases = []
        for repetition in range(1, repetitions + 1):
            for index, workload in enumerate(WORKLOADS):
                if workload not in workloads:
                    continue
                for engine in BASE:
                    case_id = '%06d-r%03d-%s' % (index, repetition, engine)
                    directory = 'cases/%s/attempt-001' % case_id
                    base = root / phase / 'results' / directory
                    record, peak = values(phase, workload['key'], engine, repetition)
                    record.update(target=engine, scenario=workload['name'], suite='testbed', version='fixture-' + engine)
                    kind = SPECIAL.get((phase, workload['key'], engine, repetition))
                    state, reasons, annotations = 'successful', [], []
                    if kind == 'thermal':
                        state, reasons = 'invalid', ['thermal_throttling']
                    if kind == 'failed':
                        state = 'failed'
                        record = dict(target=engine, scenario=workload['name'], suite='testbed', error='memtier failed', ops_per_sec=None)
                    if kind == 'limited':
                        annotations = ['client_limited']
                    attempt = dict(directory=directory, state=state, started_at=10.0, finished_at=80.0, returncode=0, cleanup=dict(ok=True),
                                   details=dict(record=record, target=dict(status='ok', version='fixture-' + engine), reasons=reasons, annotations=annotations,
                                                client_utilization_pct=90.0 if kind == 'limited' else 60.0),
                                   telemetry=dict(server_pre_stop_cgroup_peaks=[dict(artifact_dir='/x/probe-cache/probe', memory_peak_bytes=999 * 1024 ** 3),
                                                                                dict(artifact_dir='/x/' + directory + '/run/' + engine, memory_peak_bytes=peak)]))
                    dump(base / 'result.json', attempt)
                    dump(base / 'run' / 'records.jsonl', record)
                    inventory = {str(path.relative_to(base)): dict(sha256=sha(path), bytes=path.stat().st_size) for path in sorted(base.rglob('*')) if path.is_file()}
                    dump(base / 'artifacts.json', inventory)
                    cases.append(dict(id=case_id, index=index, key=workload['key'], name=workload['name'], suite='testbed', target=engine, repetition=repetition,
                                      state=state, attempts=[dict(attempt, artifacts_sha256=sha(base / 'artifacts.json'))]))
                    if phase == 'benchmark':
                        expected[(workload['key'], engine, repetition)] = (state == 'successful', record.get('ops_per_sec'), record.get('p99_ms'), peak)
        dump(root / phase / 'results' / 'checkpoint.json', dict(schema='eski-exam-v1', state='finished-with-nonsuccess', identity='f' * 64, cases=cases))
        dump(root / phase / 'results' / 'identity.json', dict(sha256='f' * 64, host=protocol['machine'], config=protocol['resources']))
    return expected


def make_fill(path):
    dump(path, dict(schema='eski-testbed-fill-v1', stamp='20261028-120000', design=dict(keys=10000000, data_size=64, pipeline=32),
                    machine=dict(cpu_model='Fixture CPU @ 2.20GHz'), resources=dict(server_cpus='1'),
                    engines=[dict(target='eski-docker', label='Eski', status='valid', dbsize=10000000, bytes_per_key_rss=96.5, bytes_per_key_used=90.1, ops_per_sec=1.8e6, max_ms=31.2,
                                  settled=True, settle_s=5.43, settle_samples=6, settle_timeout_s=60),
                             dict(target='redis', label='Redis 7.4.12', status='valid', dbsize=10000000, bytes_per_key_rss=120.0, bytes_per_key_used=110.0, ops_per_sec=1.5e6, max_ms=40.0,
                                  settled=False, settle_s=60.38, settle_samples=61, settle_timeout_s=60),
                             dict(target='valkey', label='Valkey 8.1.11', status='valid', dbsize=10000000, bytes_per_key_rss=100.0, bytes_per_key_used=95.0, ops_per_sec=1.6e6, max_ms=35.0,
                                  settled=True, settle_s=3.41, settle_samples=4, settle_timeout_s=60),
                             dict(target='dragonfly', label='Dragonfly 2.0.2', status='failed', error='harness exit 1, None keys')]))


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / 'results'
        self.expected = make_results(self.root)
        self.fill = Path(self.temporary.name) / 'fill' / 'fill.json'
        make_fill(self.fill)
        self.dataset = combine.combine(self.root, self.fill)

    def tearDown(self):
        self.temporary.cleanup()

    def test_combine_counts_medians_and_exclusions(self):
        dataset = self.dataset
        self.assertEqual(dataset['counts'], dict(planned=32, valid=30, excluded=2, client_limited=1))
        self.assertEqual(dataset['phases']['calibration'], dict(state='finished-with-nonsuccess', planned=4, valid=4, excluded=0))
        cells = {(cell['workload'], cell['engine']): cell for cell in dataset['summary']}
        self.assertEqual(len(cells), 8)
        for (workload, engine), cell in cells.items():
            valid = [(ops, p99, mem) for (w, e, _), (ok, ops, p99, mem) in sorted(self.expected.items()) if w == workload and e == engine and ok]
            self.assertEqual(cell['repetitions'], len(valid))
            self.assertAlmostEqual(cell['ops']['median'], statistics.median(v[0] for v in valid))
            self.assertAlmostEqual(cell['p99']['median'], statistics.median(v[1] for v in valid))
            self.assertEqual(cell['mem']['median'], statistics.median(v[2] for v in valid))
            self.assertEqual(cell['ops']['min'], min(v[0] for v in valid))
            self.assertEqual(cell['ops']['max'], max(v[0] for v in valid))
        thermal = cells[('mixed64-p16', 'valkey')]
        self.assertEqual(thermal['repetitions'], 3)
        self.assertEqual(thermal['excluded'][0]['repetition'], 2)
        self.assertIn('thermal_throttling', thermal['excluded'][0]['reasons'])
        self.assertIsNotNone(thermal['excluded'][0]['ops'])
        failed = cells[('get64-p1', 'dragonfly')]['excluded'][0]
        self.assertEqual(failed['state'], 'failed')
        self.assertIn('memtier failed', failed['reasons'])
        self.assertIsNone(failed['ops'])
        self.assertEqual(cells[('get64-p1', 'eski-docker')]['client_limited'], 1)
        self.assertEqual(len(dataset['exclusions']), 2)
        self.assertEqual(dataset['engines'][0]['observed_versions'], ['fixture-eski-docker'])
        self.assertEqual(dataset['machine']['cpus'], dict(server=[1], client=[3, 4], control=[5, 11]))
        self.assertEqual(dataset['machine']['mem_total_bytes'], 16000000 * 1024)
        self.assertEqual(dataset['fill']['engines'][0]['bytes_per_key_rss'], 96.5)
        self.assertEqual([(row['settled'], row['settle_s'], row['settle_timeout_s']) for row in dataset['fill']['engines']],
                         [(True, 5.43, 60), (False, 60.38, 60), (True, 3.41, 60), (None, None, None)])
        self.assertEqual(dataset['run']['workflow_status'], 'DONE WITH EXCLUSIONS')
        self.assertTrue(all(row['mem'] < 100 * 1024 ** 2 for row in dataset['rows'] if row['mem']))
        json.dumps(dataset, allow_nan=False)

    def test_combine_rejects_tampered_artifacts(self):
        target = next((self.root / 'benchmark' / 'results' / 'cases').glob('000000-r001-redis/attempt-001'))
        (target / 'run' / 'records.jsonl').write_text('{}')
        dataset = combine.combine(self.root)
        row = next(row for row in dataset['rows'] if row['phase'] == 'benchmark' and row['workload'] == 'get64-p1' and row['engine'] == 'redis' and row['repetition'] == 1)
        self.assertFalse(row['included'])
        self.assertEqual(row['integrity'], 'failed')
        self.assertTrue(any('artifact changed' in reason for reason in row['reasons']))
        self.assertIsNone(dataset['fill'])

    def test_charts_render_both_themes_with_fixed_engine_colours(self):
        output = Path(self.temporary.name) / 'charts'
        written = charts.render(self.dataset, output)
        names = sorted(path.name for path in written)
        self.assertEqual(names, sorted(name + suffix + '.svg' for name in ('throughput', 'latency-p99', 'memory', 'fill-bytes-per-key') for suffix in ('', '-dark')))
        for path in written:
            text = path.read_text()
            ElementTree.fromstring(text)
            self.assertNotRegex(text, r'(?:href|src)=|url\(|@import')
            self.assertEqual(re.findall(r'https?://[^"\s]+', text), ['http://www.w3.org/2000/svg'])
        light, dark = (output / 'throughput.svg').read_text(), (output / 'throughput-dark.svg').read_text()
        for slot, engine in enumerate(('eski-docker', 'redis', 'valkey', 'dragonfly')):
            self.assertIn('fill="%s"' % charts.SERIES['light'][slot], light)
            self.assertIn('fill="%s"' % charts.SERIES['dark'][slot], dark)
            self.assertEqual(charts.color(engine, list(reversed(self.dataset['engines'])), charts.paint('light')), charts.SERIES['light'][slot])
        self.assertIn('#fcfcfb', light)
        self.assertIn('#1a1a19', dark)
        root = ElementTree.fromstring(light)
        circles = [element for element in root.iter('{http://www.w3.org/2000/svg}circle') if element.get('r') == '4']
        self.assertEqual(len(circles), 2)
        for slot in range(4):
            self.assertEqual(len(re.findall(r'<path d="M[^"]*" fill="%s"/>' % charts.SERIES['light'][slot], light)), len(WORKLOADS))
        fill = (output / 'fill-bytes-per-key.svg').read_text()
        self.assertIn('96.5 B per key', fill)
        self.assertIn('not measured: harness exit 1', fill)
        self.assertIn('worst request 31.2 ms, memory read 5.4 s after the fill</title>', fill)
        self.assertIn('memory not settled within 60 s, last read 60.4 s after the fill</title>', fill)
        self.assertIn('Fixture CPU', light)
        self.assertIn('excluded repetition 2', (output / 'latency-p99.svg').read_text())

    def test_excluded_values_stay_on_scale_unless_far_outside(self):
        engines = [dict(target='eski-docker', label='Eski'), dict(target='redis', label='Redis 7.4.12')]
        excluded = [dict(repetition=n, state='invalid', reasons=['thermal_throttling'], ops=1.7e6 + n, p99=0.4, mem=1.0) for n in range(1, 5)]
        dataset = dict(engines=engines, workloads=[dict(key='w', name='w', index=0)],
                       summary=[dict(workload='w', engine='eski-docker', repetitions=0, client_limited=0, excluded=excluded, ops=None, p99=None, mem=None),
                                dict(workload='w', engine='redis', repetitions=4, client_limited=0, excluded=[dict(repetition=1, state='invalid', reasons=['timing_anomaly'], ops=5e9, p99=1.0, mem=1.0)],
                                     ops=dict(median=1.07e6, min=1.06e6, max=1.08e6, values=[1.06e6, 1.07e6, 1.07e6, 1.08e6]), p99=None, mem=None)])
        text = '\n'.join(charts.panel(dataset, dataset['workloads'][0], 'ops', 0, 0, 300, 200, charts.paint('light')))
        self.assertEqual(text.count('<circle'), 4)
        self.assertEqual(text.count('l4 7 h-8 z'), 1)
        self.assertIn('no valid run', text)

    def test_tick_and_label_arithmetic(self):
        self.assertEqual(charts.nice_ticks(4.2), [0, 2, 4, 6])
        self.assertEqual(charts.nice_ticks(200000), [0, 50000, 100000, 150000, 200000])
        self.assertEqual(charts.nice_ticks(0), [0, 1])
        self.assertEqual(charts.compact(1250000, 'ops'), '1.25M')
        self.assertEqual(charts.compact(2000000, 'ops'), '2M')
        self.assertEqual(charts.compact(150000, 'ops'), '150K')
        self.assertEqual(charts.compact(0.2714, 'p99'), '0.271')
        self.assertEqual(charts.exact(123456.7, 'ops'), '123,457 ops/s')
        self.assertEqual(charts.exact(3 * 1024 ** 2, 'mem'), '3.0 MiB')

    def test_page_is_self_contained_and_complete(self):
        text = page.build(self.dataset)
        self.assertTrue(text.startswith('<!doctype html>'))
        self.assertNotRegex(text, r'<script|<link|(?:href|src)=|url\(|@import')
        self.assertEqual(set(re.findall(r'https?://[^"\s]+', text)), {'http://www.w3.org/2000/svg'})
        self.assertEqual(text.count('<svg'), len(WORKLOADS) * 3 + 1)
        self.assertEqual(text.count('<tr class='), len(self.dataset['rows']))
        self.assertIn('thermal throttling', text)
        self.assertIn('memtier failed', text)
        self.assertIn('Fixture CPU @ 2.20GHz', text)
        self.assertIn('server 1, client 3,4, controller 5,11', text)
        self.assertIn('prefers-color-scheme: dark', text)
        self.assertIn('30 of 32 planned measurements are valid, 2 are excluded and 1 valid ones were client limited', text)
        cells = {(cell['workload'], cell['engine']): cell for cell in self.dataset['summary']}
        ratio = cells[('get64-p1', 'eski-docker')]['ops']['median'] / cells[('get64-p1', 'redis')]['ops']['median']
        self.assertIn('%.2fx Redis 7.4.12' % ratio, text)
        self.assertIn('Fixture fill text.', text)
        self.assertIn('Settle: Eski memory read 5.4 s after the fill; Redis 7.4.12 memory not settled within 60 s, last read 60.4 s after the fill; '
                      'Valkey 8.1.11 memory read 3.4 s after the fill.', text)
        self.assertIn('<title>Eski Engine Comparison</title>', text)
        self.assertIn('<p><b>Power gate.</b> The power gate was mains: a power supply device of type Mains had to be present', text)

    def test_power_gate_is_recorded_and_named_in_the_methodology(self):
        self.assertEqual(self.dataset['machine']['power_source'], 'mains')
        protocol = json.loads((self.root / 'protocol.json').read_text())
        protocol['resources']['power_source'] = 'no-power-supply-devices'
        dump(self.root / 'protocol.json', protocol)
        dataset = combine.combine(self.root, self.fill)
        self.assertEqual(dataset['machine']['power_source'], 'no-power-supply-devices')
        text = page.build(dataset)
        self.assertIn('<p><b>Power gate.</b> The power gate was no-power-supply-devices: the machine had to expose no power supply device at all', text)
        self.assertNotIn('The power gate was mains', text)
        recorded = json.loads((Path(__file__).with_name('runs') / 'comparison-v1' / 'dataset.json').read_text())
        self.assertNotIn('power_source', recorded['machine'])
        text = page.build(recorded)
        self.assertIn('This fill predates the settle step: its memory was read as soon as the load generator returned.', text)
        self.assertLess(text.index('<p><b>Gates.</b>'), text.index('<p><b>Power gate.</b> The power gate was mains:'))
        self.assertLess(text.index('<p><b>Power gate.</b>'), text.index('<p><b>Quality.</b>'))

    def archive(self, extra=None, traversal=False):
        exports = self.root / 'exports'
        exports.mkdir(exist_ok=True)
        files = sorted(path for path in self.root.rglob('*') if path.is_file() and 'exports' not in path.parts)
        inventory = {str(path.relative_to(self.root)): dict(sha256=sha(path), bytes=path.stat().st_size) for path in files}
        dump(exports / 'inventory.json', inventory)
        archive = Path(self.temporary.name) / 'results.tar.gz'
        with tarfile.open(archive, 'w:gz') as handle:
            for path in files + [exports / 'inventory.json']:
                handle.add(path, arcname=str(path.relative_to(self.root)))
            if extra:
                data = b'unlisted'
                info = tarfile.TarInfo(extra)
                info.size = len(data)
                handle.addfile(info, io.BytesIO(data))
            if traversal:
                info = tarfile.TarInfo('../escape.txt')
                info.size = 1
                handle.addfile(info, io.BytesIO(b'x'))
        receipt = dict(schema='eski-exam-export-v1', archive='results.tar.gz', sha256=sha(archive), bytes=archive.stat().st_size, files=len(inventory),
                       inventory='exports/inventory.json')
        return archive, receipt

    def test_collector_verifies_hashes_and_refuses_tampering(self):
        archive, receipt = self.archive()
        destination = Path(self.temporary.name) / 'collected' / 'results'
        result = collect.verify(archive, receipt, destination)
        self.assertEqual(result['sha256'], receipt['sha256'])
        self.assertEqual(result['files'], receipt['files'])
        self.assertEqual(sha(destination / 'protocol.json'), sha(self.root / 'protocol.json'))
        self.assertEqual(combine.combine(destination)['counts'], self.dataset['counts'])
        with self.assertRaisesRegex(collect.CollectError, 'never overwritten'):
            collect.verify(archive, receipt, destination)
        with self.assertRaisesRegex(collect.CollectError, 'differs from the receipt'):
            collect.verify(archive, dict(receipt, sha256='0' * 64), Path(self.temporary.name) / 'other')
        corrupted = Path(self.temporary.name) / 'corrupted.tar.gz'
        data = bytearray(archive.read_bytes())
        data[len(data) // 2] ^= 0xFF
        corrupted.write_bytes(bytes(data))
        with self.assertRaises(collect.CollectError):
            collect.verify(corrupted, receipt, Path(self.temporary.name) / 'corrupt')
        extra, extra_receipt = self.archive(extra='control/unlisted.txt')
        with self.assertRaisesRegex(collect.CollectError, 'differs from the inventory'):
            collect.verify(extra, extra_receipt, Path(self.temporary.name) / 'extra')
        self.assertFalse((Path(self.temporary.name) / '.extra.partial').exists())
        hostile, hostile_receipt = self.archive(traversal=True)
        with self.assertRaisesRegex(collect.CollectError, 'escapes'):
            collect.verify(hostile, hostile_receipt, Path(self.temporary.name) / 'hostile')
        self.assertFalse((Path(self.temporary.name) / 'escape.txt').exists())
        with self.assertRaisesRegex(collect.CollectError, 'schema'):
            collect.check_receipt(dict(receipt, schema='other'))
        with self.assertRaisesRegex(collect.CollectError, 'plain'):
            collect.check_receipt(dict(receipt, archive='../results.tar.gz'))

    def test_command_line_tools_write_their_outputs(self):
        output = Path(self.temporary.name) / 'cli'
        dataset_path = output / 'dataset.json'
        self.assertEqual(combine.main(['--results', str(self.root), '--fill', str(self.fill.parent), '--out', str(dataset_path)]), 0)
        self.assertEqual(json.loads(dataset_path.read_text())['counts']['valid'], 30)
        self.assertEqual(charts.main(['--dataset', str(dataset_path), '--out', str(output / 'svg')]), 0)
        self.assertEqual(len(list((output / 'svg').glob('*.svg'))), 8)
        self.assertEqual(page.main(['--dataset', str(dataset_path), '--out', str(output / 'report.html')]), 0)
        self.assertIn('<main>', (output / 'report.html').read_text())
        self.assertEqual(combine.main(['--results', str(output / 'missing'), '--out', str(output / 'never.json')]), 2)


if __name__ == '__main__':
    unittest.main()
