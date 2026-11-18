import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.dont_write_bytecode = True
import ab_floor_run
import baseline_run
import guard
import search_bench
import stock_exam


class NormalizationTests(unittest.TestCase):
    def test_ties_keep_scores_and_complete_groups(self):
        first = [('a', '3'), ('c', '2'), ('b', '2'), ('d', '1'), ('e', '1')]
        second = [('a', '3'), ('b', '2'), ('c', '2'), ('f', '1'), ('d', '1')]
        self.assertEqual(search_bench.tie_view(first), search_bench.tie_view(second))
        self.assertNotEqual(search_bench.tie_view(first), search_bench.tie_view([('a', '3'), ('b', '2'), ('x', '2'), ('d', '1'), ('e', '1')]))
        self.assertNotEqual(search_bench.tie_view(first), search_bench.tie_view([('a', '3.1'), ('c', '2'), ('b', '2'), ('d', '1'), ('e', '1')]))

    def test_scored_reply(self):
        reply = [5, 'k1', '0.5', 'k2', '0.25']
        self.assertEqual(search_bench.scored_view(reply), [5, 'score-ties', [['0.5', ['k1']], ['0.25', 1]]])
        self.assertEqual(search_bench.scored_view(['error', 'x']), ['error', 'x'])

    def test_projection_ignores_field_order_only(self):
        a = [2, 'k1', ['title', 'x', 'num', '1'], 'k2', ['title', 'y', 'num', '2']]
        b = [2, 'k1', ['num', '1', 'title', 'x'], 'k2', ['num', '2', 'title', 'y']]
        c = [2, 'k2', ['num', '2', 'title', 'y'], 'k1', ['num', '1', 'title', 'x']]
        self.assertEqual(search_bench.projection_view(a), search_bench.projection_view(b))
        self.assertNotEqual(search_bench.projection_view(a), search_bench.projection_view(c))

    def test_named_differences_stay_narrow(self):
        ties_a = [[5, 'k1', '0.5', 'k2', '0.25', 'k3', '0.25']]
        ties_b = [[5, 'k1', '0.5', 'k3', '0.25', 'k4', '0.25']]
        scored = [[5, 'k1', '0.6', 'k2', '0.25', 'k3', '0.25']]
        self.assertTrue(search_bench.within_difference('score-ties', ties_a, ties_b))
        self.assertFalse(search_bench.within_difference('score-ties', ties_a, scored))
        self.assertTrue(search_bench.within_difference('number-array-format', ['[-0.2451171875,0.5]'], ['[-0.2451,0.5]']))
        self.assertFalse(search_bench.within_difference('number-array-format', ['[-0.2451171875,0.5]'], ['[-0.2451,0.6]']))
        self.assertFalse(search_bench.within_difference(None, ['a'], ['b']))

    def test_approximate_neighbours_stay_narrow(self):
        eski = [[10, 'k1', [['d', '1.2']], 'k2', [['d', '1.9']], 'k3', [['d', '2.4']]]]
        other = [[10, 'k1', [['d', '1.2']], 'k4', [['d', '1.8']], 'k3', [['d', '2.4']]]]
        self.assertTrue(search_bench.within_difference('hnsw', eski, other))
        self.assertFalse(search_bench.within_difference('hnsw', eski, [[10, 'k1', [['d', '1.3']], 'k4', [['d', '1.8']], 'k3', [['d', '2.4']]]]))
        self.assertFalse(search_bench.within_difference('hnsw', eski, [[10, 'k1', [['d', '1.2']], 'k3', [['d', '2.4']]]]))
        self.assertFalse(search_bench.within_difference('hnsw', eski, [[9, 'k1', [['d', '1.2']], 'k4', [['d', '1.8']], 'k3', [['d', '2.4']]]]))
        self.assertFalse(search_bench.within_difference('hnsw', eski, [['exception', 'ERR broken']]))
        vsim = [['e1', '0.9', 'e2', '0.8']]
        self.assertTrue(search_bench.within_difference('hnsw', vsim, [['e1', '0.9', 'e7', '0.85']]))
        self.assertFalse(search_bench.within_difference('hnsw', vsim, [['e1', '0.91', 'e7', '0.85']]))
        self.assertFalse(search_bench.within_difference('hnsw', vsim, [['e1', '0.9', 'e1', '0.9']]))

    def test_hybrid_drops_execution_time(self):
        reply = ['total_results', 2, 'results', [['__key', 'a', '__score', '0.5'], ['__key', 'b', '__score', '0.5']], 'warnings', [], 'execution_time', '0.1']
        other = ['total_results', 2, 'results', [['__key', 'b', '__score', '0.5'], ['__key', 'a', '__score', '0.5']], 'warnings', [], 'execution_time', '9']
        self.assertEqual(search_bench.hybrid_view(reply), search_bench.hybrid_view(other))
        self.assertNotIn('execution_time', str(search_bench.hybrid_view(reply)))


class PlanningTests(unittest.TestCase):
    def test_json_requests_touch_only_their_connections_keys(self):
        corpus = search_bench.Corpus(64, 1)
        shapes = search_bench.shapes('json', corpus)
        plan = search_bench.plan_requests('json', corpus, shapes, 200, 4, 7)
        self.assertEqual(plan, search_bench.plan_requests('json', corpus, shapes, 200, 4, 7))
        for item in plan:
            key = item['request'][0][1]
            self.assertEqual(int(key[len(search_bench.JSON_PREFIX):]) % 4, item['owner'])
        self.assertEqual({item['shape'] for item in plan}, {shape['name'] for shape in shapes})

    def test_every_area_has_shapes_and_indexes(self):
        corpus = search_bench.Corpus(32, 2)
        for area in ('search-hash', 'search-json', 'full-text', 'vector-search', 'hybrid', 'aggregate', 'json'):
            self.assertTrue(search_bench.shapes(area, corpus))
            self.assertTrue(search_bench.index_specs(area))

    def test_spec_selection_one_case_per_group(self):
        def item(key, groups, keys, priority=1, cpus=1):
            return dict(key=key, info=dict(tested_groups=groups, priority=priority), preload=dict(argv=['--key-maximum=%d' % keys]),
                        clients=[dict(requested_cpus=cpus)])
        plan = dict(items=[item('a', ['string'], 1000), item('b', ['string'], 10), item('c', ['hash'], 100000), item('d', ['list'], 5, 2)])
        chosen, groups = stock_exam.spec_select(plan, 1, True)
        self.assertEqual([i['key'] for i in chosen['items']], ['c', 'd', 'b'])
        self.assertEqual(groups, ['hash', 'list', 'string'])
        chosen, groups = stock_exam.spec_select(plan, 1, True, 2)
        self.assertEqual(groups, ['list', 'string'])
        chosen, _ = stock_exam.spec_select(plan, 1, False)
        self.assertEqual([i['key'] for i in chosen['items']], ['c', 'd', 'b'])
        plan['items'].append(item('e', ['stream'], 1, cpus=8))
        chosen, groups = stock_exam.spec_select(plan, 1, False, 0, 4)
        self.assertNotIn('stream', groups)
        self.assertIn('stream', stock_exam.spec_select(plan, 1, False, 0, 8)[1])

    def test_timed_clients_keep_the_full_histogram(self):
        plan = dict(items=[dict(clients=[dict(argv=['--hide-histogram', '--print-percentiles=50,99', '--ratio=1:1'])])])
        argv = stock_exam.full_histogram(plan)['items'][0]['clients'][0]['argv']
        self.assertNotIn('--hide-histogram', argv)
        self.assertEqual(argv[-1], '--print-percentiles=' + stock_exam.PERCENTILES)

    def test_exam_verdict(self):
        noisy = dict(calibration=dict(counts=dict(invalid=4)), benchmark=dict(state='finished-with-nonsuccess', planned=8, counts=dict(invalid=8)))
        broken = dict(calibration=dict(counts=dict(failed=4)), benchmark=dict(state='finished-with-nonsuccess', planned=8, counts=dict(failed=4, invalid=4)))
        clean = dict(calibration=dict(counts=dict(successful=4)), benchmark=dict(state='finished', planned=8, counts=dict(successful=8)))
        self.assertEqual(stock_exam.verdict(noisy, True), 0)
        self.assertEqual(stock_exam.verdict(broken, True), 1)
        self.assertEqual(stock_exam.verdict(noisy, False), 1)
        self.assertEqual(stock_exam.verdict(clean, False), 0)

    def test_noise_floor_roles(self):
        with mock.patch.object(os, 'sched_getaffinity', return_value=set(range(12))):
            concurrent = ab_floor_run.measurement_roles('2,3', '4-7', '9')
            sequential = ab_floor_run.measurement_roles('2', '4-7', '8,10')
            for control in ('3', '6', '12'):
                with self.assertRaises(SystemExit, msg=control):
                    ab_floor_run.measurement_roles('2,3', '4-7', control)
        self.assertEqual(concurrent['mode'], 'concurrent')
        self.assertEqual((concurrent['server'], concurrent['server_b'], concurrent['client_b']), ('2', '3', '6,7'))
        self.assertEqual(sequential['mode'], 'sequential')
        self.assertEqual((concurrent['control'], sequential['control']), ('9', '8,10'))

    def test_stock_roles_take_the_given_controller(self):
        args = mock.Mock(server_cpus='2', client_cpus='4-7', control_cpus='9')
        with mock.patch.object(os, 'sched_getaffinity', return_value=set(range(12))):
            self.assertEqual(stock_exam.roles(args, 2), dict(server=[2], client=[4, 5], control=[9]))
            for control in ('2', '5', '13'):
                args.control_cpus = control
                with self.assertRaises(stock_exam.Refused, msg=control):
                    stock_exam.roles(args, 2)

    def test_excluded_cases_are_a_measurement_only_at_full_size(self):
        def phases(states, state='finished-with-nonsuccess'):
            rows = [dict(id='c%d' % i, workload='get64-p1', target='eski', repetition=i, state=s, reasons=['gate'] if s != 'successful' else [])
                    for i, s in enumerate(states)]
            return dict(benchmark=dict(state=state, planned=len(rows), counts={}, measurements=rows))
        result = dict(phases=phases(['successful', 'invalid', 'successful', 'skipped']))
        self.assertEqual(stock_exam.measured_verdict(result, False), 1)
        self.assertEqual(result['measured'], dict(excluded=2, valid=2, cases=4, list='phases.benchmark.excluded'))
        self.assertEqual([row['id'] for row in result['phases']['benchmark']['excluded']], ['c1', 'c3'])
        for states, state, advisory in ((['invalid', 'failed'], 'finished-with-nonsuccess', False),
                                        (['successful', 'invalid'], 'finished-with-nonsuccess', True),
                                        (['successful', 'successful'], 'finished', False),
                                        (['successful', 'pending'], 'paused', False)):
            result = dict(phases=phases(states, state))
            stock_exam.measured_verdict(result, advisory)
            self.assertNotIn('measured', result, (states, state, advisory))
        self.assertEqual(stock_exam.ADVISORY_PROFILES, ('rehearsal',))

    def test_the_specification_archive_comes_from_the_cache(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            archive = folder / 'spec.tar.gz'
            archive.write_bytes(b'not the archive')
            with mock.patch.object(stock_exam, 'SPEC_SHA256', stock_exam.sha(archive)):
                staged = stock_exam.stage_spec_archive(archive, folder / 'cache')
            self.assertEqual(staged['source'], 'cached')
            self.assertEqual((folder / 'cache/redis-benchmarks-specification-0.3.46.tar.gz').read_bytes(), b'not the archive')
            with self.assertRaisesRegex(stock_exam.Refused, 'does not match'):
                stock_exam.stage_spec_archive(archive, folder / 'cache-2')
            refused = mock.Mock(returncode=6, stdout='', stderr='curl: (6) Could not resolve host')
            with mock.patch.object(stock_exam.subprocess, 'run', return_value=refused):
                with self.assertRaisesRegex(stock_exam.Refused, 'neither cached .* nor reachable .*Could not resolve host'):
                    stock_exam.stage_spec_archive(folder / 'missing.tar.gz', folder / 'cache-3')
            reachable = mock.Mock(returncode=0, stdout='200', stderr='')
            with mock.patch.object(stock_exam.subprocess, 'run', return_value=reachable):
                self.assertEqual(stock_exam.stage_spec_archive(None, folder / 'cache-4')['source'], 'downloaded by the step')

    def test_a_full_size_step_is_stamped_qualifying(self):
        with tempfile.TemporaryDirectory() as folder:
            for profile, qualifying in (('full', True), ('rehearsal', False)):
                out = Path(folder) / profile
                args = mock.Mock(name='step', area='internal', profile=profile, out=out, artifact='step/result.json', repeat=1, keep_going=False,
                                 collect=[], server_cpus=None, client_cpus=None, sample_seconds=0, rep_timeout=60, eski=None, eski_port=None,
                                 eski_arg=[], guard_container=[], command=[sys.executable, '-c', 'pass'])
                args.name = 'step'
                (out / 'step').mkdir(parents=True)
                self.assertEqual(baseline_run.run(args, out / 'step'), 0)
                result = json.loads((out / 'step/result.json').read_text())
                self.assertEqual(result['qualifying'], qualifying)
                self.assertEqual(result['note'] is None, qualifying)

    def test_placeholders(self):
        self.assertEqual(baseline_run.substitute(['--out', '{dir}/run', 'x'], dict(dir='/d')), ['--out', '/d/run', 'x'])


class GuardTests(unittest.TestCase):
    def test_guard_stops_a_registered_process_and_skips_a_reused_pid(self):
        child = subprocess.Popen([sys.executable, '-c', 'import sys; sys.stdin.read()'], stdin=subprocess.PIPE)
        other = subprocess.Popen([sys.executable, '-c', 'import sys; sys.stdin.read()'], stdin=subprocess.PIPE)
        try:
            with tempfile.TemporaryDirectory() as folder:
                Path(folder, 'server-%d' % child.pid).write_text('%d %s\n' % (child.pid, guard.start_ticks(child.pid)))
                Path(folder, 'server-%d' % other.pid).write_text('%d %s\n' % (other.pid, guard.start_ticks(other.pid) + 1))
                actions = guard.clean(folder)
                self.assertEqual(sorted(a['result'] for a in actions), ['gone', 'stopped'])
                self.assertEqual(os.listdir(folder), [])
            self.assertIsNotNone(child.wait(timeout=30))
            self.assertIsNone(other.poll())
        finally:
            for process in (child, other):
                if process.poll() is None:
                    process.kill()
                process.wait()


if __name__ == '__main__':
    unittest.main()
