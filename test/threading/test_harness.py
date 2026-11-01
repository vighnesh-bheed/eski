import argparse
import io
import itertools
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import support
import perf


class Fragmented:
    def __init__(self, data):
        self.data = data

    def recv(self, length):
        result, self.data = self.data[:min(length, 3)], self.data[min(length, 3):]
        return result


def reader(data):
    result = object.__new__(support.Client)
    result.socket = Fragmented(data)
    result.buffer = bytearray()
    result.pushes = []
    return result


class Harness(unittest.TestCase):
    def test_server_cleanup_rejects_a_nonzero_sanitizer_exit_and_preserves_diagnostic(self):
        server = support.Server(sys.executable)
        directory = server.directory
        server.process = Mock(pid=123456, poll=Mock(return_value=66), wait=Mock(return_value=66))
        (directory/'server.log').write_text('ThreadSanitizer: data race in owned job\n')
        with self.assertRaisesRegex(AssertionError, 'status 66.*expected clean exit 0') as failure:
            server.close()
        self.assertIn('ThreadSanitizer: data race', str(failure.exception))
        self.assertIsNone(server.process)
        self.assertFalse(directory.exists())

    def test_server_cleanup_reports_a_forced_kill_and_still_reaps(self):
        server = support.Server(sys.executable)
        directory = server.directory
        process = Mock(pid=123456, poll=Mock(return_value=None))
        process.wait.side_effect = [subprocess.TimeoutExpired('server', .01), -9]
        server.process = process
        (directory/'server.log').write_text('waiting for worker acknowledgement\n')
        try:
            with patch.object(support.os, 'killpg') as kill:
                with self.assertRaisesRegex(AssertionError, 'required SIGKILL') as failure:
                    server.stop(timeout=.01)
                self.assertEqual([entry.args[1] for entry in kill.call_args_list], [support.signal.SIGTERM, support.signal.SIGKILL])
            self.assertIn('worker acknowledgement', str(failure.exception))
            self.assertEqual(process.wait.call_count, 2)
            self.assertIsNone(server.process)
        finally:
            server.close()
        self.assertFalse(directory.exists())

    def test_expected_exit_one_is_limited_to_an_already_observed_exact_force_exit(self):
        server = support.Server(sys.executable)
        try:
            for status in (None, 0, 66, -11):
                server.process = Mock(pid=123456, poll=Mock(return_value=status), wait=Mock(return_value=status))
                with self.subTest(status=status):
                    with self.assertRaisesRegex(ValueError, 'already observed exact exit 1'):
                        server.stop(expected_exit=1)
            server.process = Mock(pid=123456, poll=Mock(return_value=1), wait=Mock(return_value=1))
            server.stop(expected_exit=1)
            self.assertIsNone(server.process)
        finally:
            server.close()

    def test_resp_preserves_push_types_and_binary_reply_order(self):
        client = reader(b'>2\r\n$10\r\ninvalidate\r\n*1\r\n$1\r\nx\r\n$4\r\na\x00\xffb\r\n-ERR wrong\r\n:7\r\n')
        self.assertEqual(client.reply(), b'a\x00\xffb')
        self.assertEqual(client.pushes, [[b'invalidate', [b'x']]])
        self.assertIsInstance(client.pushes[0], support.Push)
        self.assertIsInstance(client.reply(), support.ServerError)
        self.assertEqual(client.reply(), 7)
        mapped = reader(b'%2\r\n$3\r\nlen\r\n:4\r\n$7\r\nmatches\r\n*0\r\n').reply()
        self.assertEqual(mapped, {b'len': 4, b'matches': []})

    def test_resp_rejects_truncation_and_malformed_frames(self):
        for wire in (b'$5\r\nx', b'$1\r\nx!!', b'*1\r\n', b'?bad\r\n', b'$-2\r\n', b'#maybe\r\n'):
            with self.subTest(wire=wire):
                with self.assertRaises((ValueError, EOFError)):
                    reader(wire).read()
        self.assertEqual(support.encode(('ECHO', b'x\x00\r\n')), b'*2\r\n$4\r\nECHO\r\n$4\r\nx\x00\r\n\r\n')

    def test_lcs_oracle_matches_exhaustive_subsequence_enumeration(self):
        words = [bytes(values) for length in range(5) for values in itertools.product((0, 1), repeat=length)]
        for left in words:
            subsets = {bytes(left[at] for at in range(len(left)) if mask & (1 << at)) for mask in range(1 << len(left))}
            for right in words:
                expected = max(len(part) for part in subsets if support.is_subsequence(part, right))
                self.assertEqual(support.lcs_length(left, right), expected, (left, right))

    def test_thread_cpu_evidence_distinguishes_compute_from_io(self):
        before = {1: {'name': 'eski', 'ticks': 100}, 2: {'name': 'eski-compute', 'ticks': 100},
                  3: {'name': 'eski-compute', 'ticks': 200}}
        after = {1: {'name': 'eski', 'ticks': 110}, 2: {'name': 'eski-compute', 'ticks': 220},
                 3: {'name': 'eski-compute', 'ticks': 310}}
        rows = support.cpu_delta(before, after, 2, ticks_per_second=100)
        compute = [row for row in rows if row['name'] == 'eski-compute']
        self.assertEqual([row['tid'] for row in compute], [2, 3])
        self.assertAlmostEqual(sum(row['cpu_cores'] for row in compute), 1.15)
        self.assertAlmostEqual(rows[0]['cpu_cores'], .05)

    def test_perf_summary_keeps_workloads_exclusions_and_client_limits_separate(self):
        def row(configuration, workload, ops, valid=True, limited=False):
            return {'configuration': configuration, 'workload': workload, 'ops_per_second': ops, 'valid': valid,
                    'client_limited': limited, 'latency_ms': {'p99': 2}, 'compute_cpu_cores': 1.5,
                    'compute_tids_with_cpu': [2, 3]}
        cases = [row('baseline', 'lcs', 10), row('baseline', 'lcs', 40),
                 row('workers-2', 'lcs', 30, limited=True), row('workers-2', 'lcs', 60),
                 row('workers-2', 'lcs', 1000000, valid=False), row('baseline', 'get', 10000),
                 row('workers-2', 'get', 1000)]
        summary = {(entry['configuration'], entry['workload']): entry for entry in perf.summaries(cases)}
        self.assertEqual(len(summary), 4)
        self.assertEqual(summary[('workers-2', 'lcs')]['ops_median'], 45)
        self.assertEqual(summary[('workers-2', 'lcs')]['observed_ratio_to_baseline'], 1.8)
        self.assertEqual(summary[('workers-2', 'lcs')]['client_limited_repetitions'], 1)
        self.assertEqual(summary[('workers-2', 'get')]['observed_ratio_to_baseline'], .1)
        self.assertEqual(perf.percentile([1, 2, 3, 4], .5), 2)
        self.assertEqual(perf.percentile([1, 2, 3, 4], .99), 4)

    def test_perf_rejects_overlapping_cpu_sets_before_creating_outputs(self):
        self.assertEqual(perf.cpuset('1-3,6'), {1, 2, 3, 6})
        for text in ('', '-1', '3-1', '1-2-3', 'a'):
            with self.subTest(value=text):
                with self.assertRaises(argparse.ArgumentTypeError):
                    perf.cpuset(text)
        with tempfile.TemporaryDirectory(prefix='eski-threading-unit-') as directory:
            binary = Path(directory)/'binary'
            binary.write_text('not executed')
            output = Path(directory)/'output'
            result = subprocess.run([sys.executable, '-I', str(HERE/'perf.py'), '--server', str(binary), '--baseline', str(binary),
                                     '--output', str(output), '--server-cpus', '0,1', '--client-cpus', '1',
                                     '--worker-cpus', '0', '--coordinator-cpu', '1'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('must not overlap', result.stderr)
            self.assertFalse(output.exists())

    def test_perf_disabled_control_is_distinct_and_worker_counts_are_bounded(self):
        self.assertEqual(perf.worker_counts('0'), [0])
        self.assertEqual(perf.worker_counts('0,1,2,4,64'), [0, 1, 2, 4, 64])
        for value in ('', '-1', '65', '0,0', '1,1', '0,', 'a', '0.0'):
            with self.subTest(value=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    perf.worker_counts(value)
        configurations = perf.experiment_configurations(Path('candidate'), Path('previous'), perf.worker_counts('0,1,2,4'))
        self.assertEqual(configurations[0], ('baseline', Path('previous'), None))
        self.assertEqual(configurations[1], ('workers-0', Path('candidate'), 0))
        self.assertEqual(len({row[0] for row in configurations}), 5)
        self.assertEqual(len(configurations)*3*3, 45)
        self.assertEqual(len(perf.experiment_configurations(Path('candidate'), Path('previous'), [1, 2, 4]))*3*3, 36)
        def row(configuration, ops):
            return {'configuration': configuration, 'workload': 'lcs-many', 'ops_per_second': ops, 'valid': True,
                    'client_limited': False, 'latency_ms': {'p99': 2}, 'compute_cpu_cores': 0,
                    'compute_tids_with_cpu': []}
        summary = {entry['configuration']: entry for entry in perf.summaries([
            row('baseline', 10), row('baseline', 12), row('workers-0', 9), row('workers-0', 11)])}
        self.assertEqual(set(summary), {'baseline', 'workers-0'})
        self.assertEqual(summary['workers-0']['ops_median'], 10)
        self.assertAlmostEqual(summary['workers-0']['observed_ratio_to_baseline'], 10/11)
        self.assertEqual(summary['workers-0']['max_distinct_compute_tids_with_cpu'], 0)

    def test_perf_roles_match_serial_lcs_and_get_and_pin_workers_in_order(self):
        basic = {100: {'name': 'eski-compute'}, 109: {'name': 'background'}}
        for workers in (None, 0):
            plan = perf.thread_role_plan(100, basic, workers, 'lcs-many', [0, 2, 4, 6], 1)
            self.assertEqual(plan[100], {'role': 'coordinator', 'cpu': 0})
            self.assertEqual(plan[109], {'role': 'background', 'cpu': 1})
        threads = dict(basic)
        for tid in (108, 102, 110, 104, 107):
            threads[tid] = {'name': 'eski-compute'}
        plan = perf.thread_role_plan(100, threads, 5, 'lcs-many', [0, 2, 4, 6], 1)
        self.assertEqual(plan[100], {'role': 'coordinator', 'cpu': 1})
        self.assertEqual([plan[tid]['cpu'] for tid in (102, 104, 107, 108, 110)], [0, 2, 4, 6, 0])
        self.assertEqual(plan[109], {'role': 'background', 'cpu': 1})
        for workers in (None, 0, 1, 2, 4):
            plan = perf.thread_role_plan(100, threads, workers, 'get-control', [0, 2, 4, 6], 1)
            self.assertEqual(plan[100], {'role': 'coordinator', 'cpu': 0})
        active = dict(basic)
        active.update({102: {'name': 'eski-compute'}, 104: {'name': 'eski-compute'}})
        server = Mock(workers=2)
        server.process.pid = 100
        arguments = Mock(worker_cpus=[0, 2, 4, 6], coordinator_cpu=1)
        expected = perf.thread_role_plan(100, active, 2, 'lcs-many', arguments.worker_cpus, arguments.coordinator_cpu)
        observed = {tid: dict(value, affinity=[expected[tid]['cpu']]) for tid, value in active.items()}
        with patch.object(perf, 'observe_threads', side_effect=[active, observed]), patch.object(perf.os, 'sched_setaffinity') as pin:
            actual, unused = perf.assign_roles(server, arguments, 'lcs-many', require_workers=True)
        self.assertEqual(actual, expected)
        self.assertEqual({entry.args[0]: entry.args[1] for entry in pin.call_args_list}, {tid: {value['cpu']} for tid, value in expected.items()})

    def test_perf_role_validation_rejects_logical_and_smt_competition(self):
        server, client, controller = {0, 1, 2, 4, 6}, {3, 5}, {7}
        topology = {cpu: {cpu % 8, cpu % 8+8} for cpu in range(16)}
        perf.validate_roles(server, client, [0, 2, 4, 6], 1, controller, topology)
        self.assertEqual(perf.ordered_cpus('6,0,4,2'), [6, 0, 4, 2])
        for value in ('', '-1', '0,0', '0-3', 'x'):
            with self.subTest(value=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    perf.ordered_cpus(value)
        variations = [(server, {0}, [0, 2, 4, 6], 1, controller),
                      (server, client, [0, 2, 4, 6], 1, {0}),
                      (server, {8}, [0, 2, 4, 6], 1, controller),
                      (server, client, [0, 2, 4, 6], 1, {11}),
                      ({0, 1, 8}, {3}, [0, 8], 1, controller),
                      ({0, 2, 8}, {3}, [0, 2], 8, controller),
                      (server, client, [0, 2, 8], 1, controller),
                      (server, client, [0, 2, 4, 6], 0, controller)]
        for roles in variations:
            with self.subTest(roles=roles):
                with self.assertRaises(ValueError):
                    perf.validate_roles(*roles, topology)
        with self.assertRaisesRegex(ValueError, 'taskset'):
            perf.validate_roles(server, client, [0, 2, 4, 6], 1, {0}, topology)
        with tempfile.TemporaryDirectory(prefix='eski-role-validation-') as directory:
            output = Path(directory)/'not-created'
            arguments = ['--server', 'not-started', '--baseline', 'not-started', '--output', str(output),
                         '--server-cpus', '0,1', '--client-cpus', '2', '--worker-cpus', '0', '--coordinator-cpu', '1']
            with patch.object(perf.os, 'sched_getaffinity', return_value={0}), patch.object(perf, 'read_topology', return_value=({}, [])), \
                 patch.object(perf, 'Server') as server_factory, patch.object(sys, 'stderr', new_callable=io.StringIO) as stderr:
                with self.assertRaises(SystemExit) as failure:
                    perf.main(arguments)
                self.assertEqual(failure.exception.code, 2)
                self.assertIn('taskset', stderr.getvalue())
                server_factory.assert_not_called()
            self.assertFalse(output.exists())

    def test_perf_observations_retain_actual_affinity_cpu_faults_and_memory(self):
        fields = {3: 'S', 10: '7', 12: '1', 14: '120', 15: '30', 39: '6'}
        record = '123 (worker name) '+' '.join(fields.get(number, '0') for number in range(3, 53))
        with tempfile.TemporaryDirectory(prefix='eski-placement-unit-') as directory:
            root = Path(directory)
            task = root/'123/task/123'
            task.mkdir(parents=True)
            (task/'stat').write_text(record)
            (root/'123/status').write_text('Name:\teski\nVmRSS:\t16 kB\nVmHWM:\t32 kB\nVmSize:\t1024 kB\n')
            with patch.object(perf.os, 'sched_getaffinity', return_value={6}):
                observed = perf.observe_threads(123, root)
            self.assertEqual(observed[123]['affinity'], [6])
            self.assertEqual(observed[123]['last_cpu'], 6)
            self.assertEqual((observed[123]['utime'], observed[123]['stime'], observed[123]['ticks']), (120, 30, 150))
            self.assertEqual((observed[123]['minflt'], observed[123]['majflt']), (7, 1))
            plan = {123: {'role': 'compute', 'cpu': 6}}
            self.assertEqual(perf.placement_errors(observed, plan), [])
            self.assertEqual(perf.placement_rows(observed, plan)[0]['requested_cpu'], 6)
            observed[123]['affinity'] = [0, 6]
            self.assertTrue(perf.placement_errors(observed, plan))
            self.assertEqual(perf.process_memory(123, root), {'VmRSS': 16384, 'VmHWM': 32768, 'VmSize': 1048576})
            self.assertEqual(perf.process_memory(999, root), {'VmRSS': None, 'VmHWM': None, 'VmSize': None})

    def test_perf_frequency_metadata_detects_cap_change_without_governor_change(self):
        with tempfile.TemporaryDirectory(prefix='eski-frequency-unit-') as directory:
            root = Path(directory)
            for cpu, maximum in ((0, 5090000), (2, 2000000)):
                path = root/'devices/system/cpu'/('cpu%d' % cpu)/'cpufreq'
                path.mkdir(parents=True)
                for name, value in {'cpuinfo_min_freq': '623377', 'cpuinfo_max_freq': '5090000',
                                    'scaling_min_freq': '623377', 'scaling_max_freq': str(maximum),
                                    'scaling_governor': 'performance', 'energy_performance_preference': 'performance'}.items():
                    (path/name).write_text(value)
            before = perf.power_policy({0, 2}, root)
            self.assertEqual(before['cpu0/cpuinfo_max_freq'], before['cpu2/cpuinfo_max_freq'])
            self.assertNotEqual(before['cpu0/scaling_max_freq'], before['cpu2/scaling_max_freq'])
            (root/'devices/system/cpu/cpu2/cpufreq/scaling_max_freq').write_text('3000000')
            after = perf.power_policy({0, 2}, root)
            self.assertEqual(before['cpu2/scaling_governor'], after['cpu2/scaling_governor'])
            self.assertNotEqual(before, after)


if __name__ == '__main__':
    unittest.main()
