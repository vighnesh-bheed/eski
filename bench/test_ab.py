import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout


sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('eski_ab_tool', Path(__file__).with_name('ab.py'))
ab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ab)
REPORT_SPEC = importlib.util.spec_from_file_location('eski_ab_report', Path(__file__).with_name('ab_report.py'))
report = importlib.util.module_from_spec(REPORT_SPEC)
REPORT_SPEC.loader.exec_module(report)
SHA_A = 'a' * 64
SHA_B = 'b' * 64
LEGACY_FIELDS = {'ac', 'client_foreign_pct', 'client_limited', 'client_own', 'client_task_cores', 'cluster_busy_pct', 'commands', 'cpu_ns_per_cmd',
                 'el_cycles_per_cmd', 'freq_mean_khz', 'freq_min_khz', 'loadavg', 'memtier', 'per_thread_ns', 'round', 'server_cpu_columns_s',
                 'server_foreign_pct', 'server_irq_ns_per_cmd', 'server_ops', 'server_own_s', 'slot', 'syscr_per_cmd', 'syscw_per_cmd', 'target_ops',
                 'task_ns_per_cmd', 'temp_max_c', 'throttle_delta', 'user_share', 'variant', 'vol_per_cmd', 'wall_s', 'workload'}


def row(rnd, variant, cpu, freq=4000000, workload='get64-p1-r3k', target=96000, ops=96000.0, core=0, package=0, server_foreign=2.0, client_foreign=3.0, ac=None, legacy=False):
    lane = 1 if (rnd % 2 == 1) == (variant == 'A') else 2
    value = dict(round=rnd, variant=variant, workload=workload, slot=dict(server_cpus=str(lane), client_cpus='10,11' if lane == 1 else '12,13', port=39400 + lane - 1),
                 commands=1920000, wall_s=20.0, server_ops=96000, memtier=dict(ops=ops, p50=0.1, p99=0.2, p999=0.3), target_ops=target,
                 cpu_ns_per_cmd=cpu, task_ns_per_cmd=round(cpu * 0.6, 1), server_irq_ns_per_cmd=round(cpu * 0.4, 1), per_thread_ns={'eski': cpu * 0.6},
                 user_share=0.3, vol_per_cmd=0.09, syscr_per_cmd=1.0, syscw_per_cmd=1.0, el_cycles_per_cmd=0.1, server_cpu_columns_s={}, server_own_s=1.0,
                 server_foreign_pct=server_foreign, cluster_busy_pct=None, client_task_cores=1.0, client_own=0.9, client_foreign_pct=client_foreign,
                 freq_mean_khz=freq, freq_min_khz=freq // 2, temp_max_c=80.0, throttle_delta=core, ac={'AC': '1'} if ac is None else ac,
                 loadavg='2.10 2.00 1.90 1/100 1', client_limited=False)
    if not legacy:
        value.update(package_throttle_delta=package, core_throttle_ms=core, package_throttle_ms=0)
    return value


def session(cost_a=1000.0, cost_b=1000.0, rounds=8, lane_bias=1.05, freq=None, workload='get64-p1-r3k', **extra):
    rows = []
    for rnd in range(1, rounds + 1):
        for variant, cost in (('A', cost_a), ('B', cost_b)):
            lane = 1 if (rnd % 2 == 1) == (variant == 'A') else 2
            f = freq(rnd, variant, lane) if freq else 4000000
            rows.append(row(rnd, variant, round(cost * (lane_bias if lane == 1 else 1.0), 1), freq=f, workload=workload, **extra))
    return rows


def meta(sha_b=SHA_A, mode='concurrent', label='aa-test', limits=None):
    return dict(schema=ab.SCHEMA, label=label, started=1793000000.0, finished=1793001200.0, mode=mode, rounds=8, seconds=20, warmup=5,
                binaries=dict(A=dict(path='/x/eski-a', sha256=SHA_A, extra=[]), B=dict(path='/x/eski-b', sha256=sha_b, extra=[])),
                cpus=dict(server='1', client='10,11', server_b='2', client_b='12,13', control='14', cluster='1-2'),
                cpu_model='test cpu', kernel='test', governor='performance', epp='performance', no_turbo='0',
                limits=dict(ab.LIMITS[mode]) if limits is None else limits)


class Parsing(unittest.TestCase):
    def test_cpu_lists_expand_ranges_and_singles(self):
        self.assertEqual(ab.cpu_list('1'), [1])
        self.assertEqual(ab.cpu_list('10,11'), [10, 11])
        self.assertEqual(ab.cpu_list('6-9,14'), [6, 7, 8, 9, 14])

    def test_proc_stat_columns_are_read_per_cpu(self):
        text = 'cpu  1 2 3 4 5 6 7 8 9 10\ncpu0 1 0 2 100 0 3 4 0 0 0\ncpu1 5 1 6 200 0 7 8 0 0 0\nintr 1\n'
        times = ab.cpu_times(text)
        self.assertEqual(sorted(times), [0, 1])
        later = ab.cpu_times(text.replace('cpu1 5 1 6 200 0 7 8', 'cpu1 105 1 56 200 0 17 28'))
        delta = ab.cpu_delta(times, later, [1], 100)
        self.assertEqual((delta['user'], delta['system'], delta['irq'], delta['softirq']), (1.0, 0.5, 0.1, 0.2))

    def test_unknown_workloads_are_refused_before_any_work(self):
        with self.assertRaisesRegex(SystemExit, 'unknown workloads: nope'):
            ab.main(['--a', 'x', '--b', 'y', '--label', 'l', '--out', '/nonexistent', '--workloads', 'get64-p1-r3k,nope'])


class Throttle(unittest.TestCase):
    def counters(self, root, cpu, core, core_ms, package, package_ms):
        base = root / ('devices/system/cpu/cpu%d/thermal_throttle' % cpu)
        base.mkdir(parents=True, exist_ok=True)
        for name, value in zip(ab.THROTTLE_FIELDS, (core, core_ms, package, package_ms)):
            (base / name).write_text('%d\n' % value)

    def test_core_and_package_counters_are_read_and_differenced_separately(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.counters(root, 1, 10, 12, 500, 900)
            before = {1: ab.throttle(1, root)}
            self.counters(root, 1, 13, 15, 620, 900)
            after = {1: ab.throttle(1, root)}
            self.assertEqual(ab.throttle_delta(before, after), dict(core_throttle_count=3, core_throttle_total_time_ms=3, package_throttle_count=120, package_throttle_total_time_ms=0))
            self.assertEqual(ab.throttle(5, root), {name: 0 for name in ab.THROTTLE_FIELDS})

    def test_rows_keep_every_legacy_field_and_split_core_from_package(self):
        class Sampled:
            freq, temp, cg_usage = [3000000, 4000000], [70.0], [(0.0, 0), (20.0, 18000000)]

        def snap(commands, run_ns, core, package):
            return dict(info=dict(total_commands_processed=str(commands), eventloop_cycles=str(commands // 10)),
                        threads={'eski': dict(run_ns=run_ns, utime=10, stime=20, vol=5, nonvol=0, n=1)}, io=dict(syscr=commands, syscw=commands),
                        throttle={1: dict(core_throttle_count=core, core_throttle_total_time_ms=core, package_throttle_count=package, package_throttle_total_time_ms=0)})

        cb = {1: [0] * 8, 10: [0] * 8, 11: [0] * 8}
        ca = {1: [100, 0, 200, 1700, 0, 0, 300, 0], 10: [900, 0, 100, 1000, 0, 0, 0, 0], 11: [900, 0, 100, 1000, 0, 0, 0, 0]}
        value = ab.make_row(1, 'A', 'get64-p1-r3k', 96000, dict(ops=96000.0), snap(1000, 0, 5, 100), snap(1921001, 2_000_000_000, 8, 400),
                            cb, ca, 0.0, 20.0, Sampled, [1], [10, 11], dict(server_cpus='1'), ac={'AC': '1'}, loadavg='1 1 1 1/1 1', tick=100)
        self.assertLessEqual(LEGACY_FIELDS, set(value))
        self.assertEqual((value['throttle_delta'], value['package_throttle_delta'], value['core_throttle_ms'], value['package_throttle_ms']), (3, 300, 3, 0))
        self.assertEqual(value['commands'], 1920000)
        self.assertAlmostEqual(value['cpu_ns_per_cmd'], (2e9 + 3e9) / 1920000, places=0)
        self.assertEqual(value['freq_mean_khz'], 3500000)
        self.assertEqual(value['server_foreign_pct'], 5.0)
        self.assertEqual(value['client_foreign_pct'], 5.0)


class Flags(unittest.TestCase):
    def test_package_events_never_exclude_and_core_events_exclude_above_the_rate(self):
        limits = ab.limits_for('concurrent')
        self.assertEqual(ab.flags(row(1, 'A', 1000, package=50000), limits), [])
        self.assertEqual(ab.flags(row(1, 'A', 1000, core=2000), limits), [])
        self.assertEqual(ab.flags(row(1, 'A', 1000, core=2001), limits), ['thermal_throttle'])
        strict = ab.limits_for('concurrent', dict(core_throttle_per_s=0))
        self.assertEqual(ab.flags(row(1, 'A', 1000, core=1), strict), ['thermal_throttle'])

    def test_foreign_load_offered_rate_and_power_source_are_kept(self):
        limits = ab.limits_for('concurrent')
        self.assertEqual(ab.flags(row(1, 'A', 1000, server_foreign=31.0), limits), ['server_cpu_foreign_load'])
        self.assertEqual(ab.flags(row(1, 'A', 1000, client_foreign=90.0), limits), [])
        self.assertEqual(ab.flags(row(1, 'A', 1000, client_foreign=16.0), ab.limits_for('sequential')), ['client_cpu_foreign_load'])
        self.assertEqual(ab.flags(row(1, 'A', 1000, ops=94000.0), limits), ['offered_rate_not_met'])
        self.assertEqual(ab.flags(row(1, 'A', 1000, ops=94000.0, target=None), limits), [])
        self.assertEqual(ab.flags(row(1, 'A', 1000, ac={'AC': '0'}), limits), ['ac_offline'])
        self.assertEqual(ab.flags(row(1, 'A', 1000, ac={}), limits), [])

    def test_recorded_limits_fill_missing_rules_from_the_defaults(self):
        old = dict(asym_foreign_pct=5.0, server_foreign_pct=30.0, client_foreign_pct=30.0, rate_fraction=0.98, freq_deviation=0.1, min_pairs=3)
        merged = ab.limits_for('concurrent', old)
        self.assertEqual(merged['client_foreign_pct'], 30.0)
        self.assertEqual(merged['freq_pair_tolerance'], 0.20)
        self.assertEqual(merged['core_throttle_per_s'], 100.0)


class Concurrent(unittest.TestCase):
    def test_identical_binaries_cancel_a_constant_lane_bias(self):
        result = ab.summarize_concurrent(session(), {})['get64-p1-r3k']
        self.assertEqual(result['clean_pairs'], 4)
        self.assertEqual(result['cpu_ratio_median'], 1.0)
        self.assertEqual(result['slot_bias_median'], round(1 / 1.05, 4))
        self.assertEqual(result['verdict'], 'ok')
        self.assertEqual(result['excluded'], [])

    def test_a_cheaper_candidate_is_recovered_through_the_lane_bias(self):
        result = ab.summarize_concurrent(session(cost_b=900.0), {})['get64-p1-r3k']
        self.assertAlmostEqual(result['cpu_ratio_median'], 0.9, places=3)
        self.assertEqual(len(result['round_ratios']), 8)

    def test_constant_lane_frequency_difference_is_not_noise(self):
        rows = session(freq=lambda rnd, variant, lane: 4400000 if lane == 1 else 3300000)
        result = ab.summarize_concurrent(rows, {})['get64-p1-r3k']
        self.assertEqual(result['clean_pairs'], 4)
        self.assertEqual(result['pairs_excluded_frequency'], [])
        self.assertEqual([p['freq_ratio'] for p in result['pairs']], [1.0] * 4)

    def test_a_candidate_that_lowers_its_own_clock_keeps_every_pair(self):
        rows = session(cost_b=800.0, freq=lambda rnd, variant, lane: 3200000 if variant == 'B' else 4000000)
        result = ab.summarize_concurrent(rows, {})['get64-p1-r3k']
        self.assertEqual(result['clean_pairs'], 4)
        self.assertEqual(result['freq_ratio_median'], 0.8)

    def test_one_pair_with_an_inconsistent_frequency_ratio_is_excluded_whole(self):
        def freq(rnd, variant, lane):
            return 2400000 if (rnd == 5 and lane == 1) else 4000000
        result = ab.summarize_concurrent(session(freq=freq), {})['get64-p1-r3k']
        self.assertEqual(result['clean_pairs'], 3)
        self.assertEqual(result['pairs_excluded_frequency'], [5])
        self.assertEqual([(e['round'], e['reasons']) for e in result['excluded']], [(5, ['frequency_difference']), (6, ['frequency_difference'])])
        self.assertEqual(result['clean_rounds'], [1, 2, 3, 4, 7, 8])
        pair = result['pairs'][2]
        self.assertFalse(pair['clean'])
        self.assertGreater(pair['freq_deviation'], 0.20)
        self.assertEqual(ab.summarize_concurrent(session(freq=freq), dict(freq_pair_tolerance=0.3))['get64-p1-r3k']['clean_pairs'], 4)

    def test_a_noisy_round_removes_its_swap_pair_and_keeps_the_reason(self):
        rows = session()
        next(r for r in rows if r['round'] == 3 and r['variant'] == 'B')['server_foreign_pct'] = 12.0
        next(r for r in rows if r['round'] == 8 and r['variant'] == 'A')['memtier']['ops'] = 90000.0
        result = ab.summarize_concurrent(rows, {})['get64-p1-r3k']
        self.assertEqual(result['clean_pairs'], 2)
        self.assertEqual([(e['round'], e['reasons']) for e in result['excluded']], [(3, ['asymmetric_server_foreign_load']), (8, ['offered_rate_not_met'])])
        self.assertEqual(result['verdict'], 'insufficient')
        self.assertEqual(ab.summarize_concurrent(rows, dict(min_pairs=2))['get64-p1-r3k']['verdict'], 'ok')

    def test_asymmetric_client_load_and_trailing_or_partial_rounds(self):
        rows = session(rounds=7)
        next(r for r in rows if r['round'] == 1 and r['variant'] == 'A')['client_foreign_pct'] = 14.0
        rows = [r for r in rows if not (r['round'] == 4 and r['variant'] == 'B')]
        result = ab.summarize_concurrent(rows, {})['get64-p1-r3k']
        self.assertEqual([(e['round'], e['reasons']) for e in result['excluded']], [(1, ['asymmetric_client_foreign_load'])])
        self.assertEqual([p['rounds'] for p in result['pairs']], [[1, 2], [5, 6]])
        self.assertEqual(result['clean_pairs'], 1)
        self.assertIn(7, result['clean_rounds'])

    def test_rows_from_before_the_split_still_summarize(self):
        rows = session(legacy=True, core=0)
        self.assertNotIn('package_throttle_delta', rows[0])
        result = ab.summarize_session(rows, meta(), None)['get64-p1-r3k']
        self.assertEqual(result['clean_pairs'], 4)
        self.assertEqual(result['package_throttle_runs'], 0)

    def test_workloads_are_summarized_separately_in_session_order(self):
        rows = session(workload='get64-p16-max', target=None) + session(workload='ping-p16-r20k', target=640000, ops=640000.0)
        self.assertEqual(list(ab.summarize_concurrent(rows, {})), ['get64-p16-max', 'ping-p16-r20k'])


class Sequential(unittest.TestCase):
    def test_sequential_pairs_use_the_per_pair_frequency_rule(self):
        rows = []
        for rnd in range(1, 5):
            rows.append(row(rnd, 'A', 1000.0, freq=4000000, client_foreign=1.0))
            rows.append(row(rnd, 'B', 950.0, freq=3000000 if rnd == 2 else 4000000, client_foreign=1.0))
        result = ab.summarize_session(rows, meta(mode='sequential'), None)['get64-p1-r3k']
        self.assertEqual(result['pairs_excluded_frequency'], [2])
        self.assertEqual(result['clean_pairs'], 3)
        self.assertEqual(result['cpu_ratio_median'], 0.95)
        self.assertEqual(result['verdict'], 'insufficient')


class Report(unittest.TestCase):
    def write_session(self, directory, rows, value):
        root = Path(directory) / value['label']
        root.mkdir()
        (root / 'rows.json').write_text(json.dumps(rows))
        (root / 'summary.json').write_text(json.dumps(dict(meta=value, summary=ab.summarize_session(copy.deepcopy(rows), value))))
        return root

    def test_floor_is_the_half_width_rounded_up_to_half_a_percent(self):
        self.assertEqual(report.floor_value(0.994, 1.022), 0.025)
        self.assertEqual(report.floor_value(0.99, 1.0), 0.01)
        self.assertEqual(report.floor_value(1.0, 1.0), 0.0)
        self.assertEqual(report.floor_value(0.9701, 1.0), 0.03)

    def test_readings_compare_the_median_with_the_floor(self):
        self.assertEqual(report.reading(0.97, 0.02), 'lower than the floor')
        self.assertEqual(report.reading(1.02, 0.02), 'within the floor')
        self.assertEqual(report.reading(1.03, 0.02), 'higher than the floor')
        self.assertEqual(report.reading(None, 0.02), 'insufficient')
        self.assertEqual(report.reading(0.9, None), 'no floor')

    def test_an_aa_session_states_its_floor_and_an_ab_session_reads_against_it(self):
        def freq(rnd, variant, lane):
            return 4000000 + (rnd * 10000 if variant == 'B' else 0)
        rows = session(cost_b=1000.0, freq=freq)
        for r in rows:
            if r['variant'] == 'B' and r['round'] in (3, 4):
                r['cpu_ns_per_cmd'] = round(r['cpu_ns_per_cmd'] * 1.02, 1)
        with tempfile.TemporaryDirectory() as directory:
            aa = self.write_session(directory, rows, meta())
            floor_path = Path(directory) / 'floor.json'
            out = io.StringIO()
            with redirect_stdout(out):
                report.main([str(aa), '--write-floor', str(floor_path), '--no-floor'])
            text = out.getvalue()
            self.assertIn('A/A floor stated by this session', text)
            self.assertIn('| get64-p1-r3k | 4 | 1.000 [1.000, 1.020] | 2.0% | yes |', text)
            floor = json.loads(floor_path.read_text())
            self.assertEqual(floor['schema'], report.FLOOR_SCHEMA)
            self.assertEqual(floor['workloads']['get64-p1-r3k']['floor'], 0.02)
            self.assertEqual(floor['binary_sha256'], SHA_A)
            self.assertEqual(report.read_floor(aa)['workloads'], floor['workloads'])
            ab_rows = session(cost_b=950.0)
            candidate = self.write_session(directory, ab_rows, meta(sha_b=SHA_B, label='ab-test'))
            out = io.StringIO()
            with redirect_stdout(out):
                report.main([str(candidate), '--floor', str(floor_path)])
            text = out.getvalue()
            self.assertNotIn('A/A floor stated by this session', text)
            self.assertIn('get64-p1-r3k: B/A 0.950, floor 2.0%, lower than the floor', text)
            with self.assertRaisesRegex(ValueError, 'A/A session'):
                report.floor_record(meta(sha_b=SHA_B), {}, ab_rows)
            with self.assertRaisesRegex(ValueError, 'not a floor record'):
                report.read_floor(candidate / 'rows.json')

    def test_report_keeps_the_legacy_table_and_reads_sequential_sessions_without_a_mode(self):
        rows = session(legacy=True)
        value = meta()
        summary = ab.summarize_session(copy.deepcopy(rows), value)
        text = report.render(value, summary, rows)
        self.assertIn('| Workload | Clean swap pairs | A ns/cmd median [min, max] | B ns/cmd median [min, max] | B/A paired median [min, max] | Task-only B/A | Excluded runs (reasons) | reads, writes, epoll per cmd | Server MHz median | Client-limited runs | Lane bias |', text)
        self.assertIn('package events per run not recorded separately', text)
        self.assertIn('swap-pair B/A median 1.000 [1.000, 1.000]', text)
        legacy = dict(value)
        legacy.pop('mode')
        sequential = []
        for rnd in range(1, 5):
            sequential += [row(rnd, 'A', 1000.0, client_foreign=1.0, legacy=True), row(rnd, 'B', 1000.0, client_foreign=1.0, legacy=True)]
        text = report.render(legacy, ab.summarize_session(copy.deepcopy(sequential), legacy), sequential)
        self.assertIn('(sequential mode)', text)
        self.assertIn('| Workload | Clean pairs |', text)

    def test_recompute_applies_current_rules_to_an_old_summary(self):
        rows = session(core=150, package=4000)
        old = meta(limits=dict(asym_foreign_pct=5.0, server_foreign_pct=30.0, client_foreign_pct=30.0, rate_fraction=0.98, freq_deviation=0.1, min_pairs=3, core_throttle_per_s=0))
        with tempfile.TemporaryDirectory() as directory:
            root = self.write_session(directory, rows, old)
            stored = json.loads((root / 'summary.json').read_text())['summary']['get64-p1-r3k']
            self.assertEqual(stored['clean_pairs'], 0)
            out = io.StringIO()
            with redirect_stdout(out):
                report.main([str(root), '--recompute', '--no-floor'])
            self.assertIn('| get64-p1-r3k | 4 |', out.getvalue())


if __name__ == '__main__':
    unittest.main()
