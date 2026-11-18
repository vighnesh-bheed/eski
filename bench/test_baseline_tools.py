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
            concurrent = ab_floor_run.measurement_roles('2,3', '4-7')
            sequential = ab_floor_run.measurement_roles('2', '4-7')
        self.assertEqual(concurrent['mode'], 'concurrent')
        self.assertEqual((concurrent['server'], concurrent['server_b'], concurrent['client_b']), ('2', '3', '6,7'))
        self.assertEqual(sequential['mode'], 'sequential')
        self.assertNotIn(int(concurrent['control']), {2, 3, 4, 5, 6, 7})

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
