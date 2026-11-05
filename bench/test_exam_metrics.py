import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest


def module(name):
    spec = importlib.util.spec_from_file_location('eski_' + name, Path(__file__).with_name(name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


m = module('exam_metrics')
scheduler = module('exam_scheduler')
SOFTIRQS = '                    CPU0       CPU1\n          HI:          1          2\n       TIMER:        100        200\n      NET_RX:         10         20\n       SCHED:          5          6\n'
INTERRUPTS = '            CPU0       CPU1\n   1:          3          4  IR-IO-APIC    1-edge      i8042\n LOC:         10         20   Local timer interrupts\n ERR:          0\n MIS:          0\n'


def stat_line(pid, comm, ticks, start, flags=0, processor=1):
    fields = ['S', '1', str(pid)] + ['0'] * 49
    fields[6], fields[11], fields[12], fields[19], fields[21], fields[36] = str(flags), str(ticks), '0', str(start), '4', str(processor)
    return '%d (%s) %s' % (pid, comm, ' '.join(fields))


def series(counts):
    return {'ALL STATS': {'Totals': {'Time-Serie': {str(index): {'Count': count} for index, count in enumerate(counts)}}}}


class MetricsTests(unittest.TestCase):
    def fake_root(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / 'proc').mkdir()
        (root / 'proc/stat').write_text('cpu 10 0 10 70 0 0 10 0\ncpu0 5 0 5 35 0 0 5 0\ncpu1 5 0 5 35 0 0 5 0\n')
        (root / 'proc/softirqs').write_text(SOFTIRQS)
        (root / 'proc/interrupts').write_text(INTERRUPTS)
        (root / 'proc/cmdline').write_text('BOOT_IMAGE=/vmlinuz root=/dev/sda1 nosmt modprobe.blacklist=i915\n')
        (root / 'proc/modules').write_text('xfs 1 0 - Live 0x0\ni915 2 0 - Live 0x0\n')
        (root / 'proc/sys/kernel').mkdir(parents=True)
        (root / 'proc/sys/kernel/timer_migration').write_text('1\n')
        return root

    def test_eight_cpu_fields_softirqs_and_interrupts_are_sampled_with_deltas(self):
        root = self.fake_root()
        reader = m.Reader(root=root)
        first = reader.sample()
        self.assertEqual(first['cpu_fields']['cpu1'], [5, 0, 5, 35, 0, 0, 5, 0])
        self.assertEqual(first['cpu_ticks']['cpu1'], (50, 35))
        self.assertEqual(first['cpu_share_pct'], {})
        self.assertEqual(first['softirqs']['NET_RX'], {'cpu0': 10, 'cpu1': 20})
        self.assertEqual(first['interrupts'], {'cpu0': 13, 'cpu1': 24})
        self.assertIsNone(first['softirq_delta'])
        self.assertIsNone(first['interrupt_delta'])
        self.assertTrue(first['availability']['softirqs'] and first['availability']['interrupts'])
        (root / 'proc/stat').write_text('cpu 20 0 20 140 0 0 20 0\ncpu0 10 0 10 70 0 0 10 0\ncpu1 5 0 55 35 0 10 45 0\n')
        (root / 'proc/softirqs').write_text(SOFTIRQS.replace('        10         20', '        11         70'))
        (root / 'proc/interrupts').write_text(INTERRUPTS.replace(' LOC:         10         20', ' LOC:         10         29'))
        second = reader.sample()
        share = second['cpu_share_pct']['cpu1']
        self.assertEqual((share['system'], share['irq'], share['softirq'], share['idle'], share['user']), (50, 10, 40, 0, 0))
        self.assertEqual(second['cpu_share_pct']['cpu0']['idle'], 70)
        self.assertEqual(second['softirq_delta']['NET_RX'], {'cpu0': 1, 'cpu1': 50})
        self.assertEqual(second['softirq_delta']['TIMER'], {'cpu0': 0, 'cpu1': 0})
        self.assertEqual(second['interrupt_delta'], {'cpu0': 0, 'cpu1': 9})
        self.assertEqual(sorted(second['cpu_fields']), ['cpu', 'cpu0', 'cpu1'])
        (root / 'proc/stat').write_text('cpu 20 0 20 140 0 0 20 0\ncpu0 10 0 10 70 0 0 10 0\ncpu1 5 0 55 30 0 10 45 0\n')
        third = reader.sample()
        self.assertIsNone(third['cpu_share_pct']['cpu1'])
        self.assertIn('cpu:cpu1', third['counter_resets'])
        (root / 'proc/softirqs').unlink()
        (root / 'proc/interrupts').unlink()
        fourth = reader.sample()
        self.assertIsNone(fourth['softirqs'])
        self.assertIsNone(fourth['softirq_delta'])
        self.assertFalse(fourth['availability']['interrupts'])

    def test_process_records_last_cpu_and_kernel_thread_flag(self):
        root = self.fake_root()
        for pid, comm, flags, processor in ((7, 'kworker/1:0+events', 0x00200040, 1), (8, 'memtier_benchma', 0x00400000, 3)):
            (root / 'proc' / str(pid)).mkdir()
            (root / 'proc' / str(pid) / 'stat').write_text(stat_line(pid, comm, 50, 100, flags, processor))
        worker, client = m.process(7, root / 'proc'), m.process(8, root / 'proc')
        self.assertEqual((worker['comm'], worker['processor'], worker['kthread']), ('kworker/1:0+events', 1, True))
        self.assertEqual((client['comm'], client['processor'], client['kthread']), ('memtier_benchma', 3, False))
        short = root / 'proc/9'
        short.mkdir()
        (short / 'stat').write_text('9 (old) S 1 9 ' + ' '.join(['0'] * 19))
        self.assertIsNone(m.process(9, root / 'proc')['processor'])
        reader = m.Reader(root=root)
        reader.sample()
        (root / 'proc/7/stat').write_text(stat_line(7, 'kworker/1:0+events', 50 + os.sysconf('SC_CLK_TCK'), 100, 0x00200040, 1))
        reader.previous_time -= 1
        external = reader.sample()['external_cpu']
        self.assertEqual([(proc['comm'], proc['processor'], proc['kthread']) for proc in external], [('kworker/1:0+events', 1, True)])
        self.assertGreaterEqual(external[0]['cpu_cores'], .5)

    def test_machine_inventory_names_display_drivers(self):
        root = self.fake_root()
        inventory = m.machine_inventory(root)
        self.assertEqual(inventory['cmdline'], 'BOOT_IMAGE=/vmlinuz root=/dev/sda1 nosmt modprobe.blacklist=i915')
        self.assertEqual(inventory['modules'], ['i915', 'xfs'])
        self.assertEqual(inventory['drm'], dict(available=False, entries=None, cards={}))
        self.assertEqual(inventory['timer_migration'], 1)
        self.assertEqual(m.display_drivers(inventory), ['i915'])
        drm = root / 'sys/class/drm'
        (drm / 'card0/device').mkdir(parents=True)
        (drm / 'renderD128').mkdir()
        (drm / 'version').write_text('drm 1.1.0\n')
        (root / 'sys/bus/pci/drivers/ast').mkdir(parents=True)
        (drm / 'card0/device/driver').symlink_to('../../../../bus/pci/drivers/ast')
        (drm / 'card1').mkdir()
        inventory = m.machine_inventory(root)
        self.assertEqual(inventory['drm'], dict(available=True, entries=['card0', 'card1', 'renderD128', 'version'], cards={'card0': 'ast', 'card1': None}))
        self.assertEqual(m.display_drivers(inventory), ['ast', 'card1', 'i915'])
        (root / 'proc/modules').write_text('xfs 1 0 - Live 0x0\n')
        (drm / 'card1').rmdir()
        (drm / 'card0/device/driver').unlink()
        (drm / 'card0').rename(drm / 'card9')
        self.assertEqual(m.display_drivers(m.machine_inventory(root)), ['card9'])
        (drm / 'card9').rename(root / 'card9')
        self.assertEqual(m.display_drivers(m.machine_inventory(root)), [])

    def test_memtier_series_finds_stall_windows(self):
        steady = [150000] * 60
        result = m.memtier_series(series(steady + [40]))
        self.assertEqual((result['available'], result['seconds'], result['steady_ops_per_sec'], result['stall_seconds'], result['stall_windows']), (True, 60, 150000, 0, 0))
        self.assertEqual(result['per_second_ops'], steady)
        self.assertEqual(result['min_second_ratio'], 1)
        stalled = steady[:10] + [60000] * 14 + steady[24:40] + [50000] * 12 + steady[52:]
        result = m.memtier_series(series(stalled + [40]))
        self.assertEqual((result['stall_seconds'], result['stall_windows'], result['seconds']), (26, 2, 60))
        self.assertAlmostEqual(result['min_second_ratio'], 50000 / 150000)
        self.assertEqual(result['steady_ops_per_sec'], 150000)
        self.assertFalse(m.memtier_series({'ALL STATS': {'Totals': {'Time-Serie': [{'second': 1}]}}})['available'])
        self.assertFalse(m.memtier_series({'ALL STATS': {'Totals': {'Time-Serie': {'0': {'Latency': 1}}}}})['available'])
        self.assertFalse(m.memtier_series({})['available'])
        self.assertEqual(m.memtier_series({'AGGREGATED AVERAGE RESULTS (2 runs)': {'Totals': {'Time-Serie': {'0': {'Count': 5}, '1': {'Count': 5}}}}})['per_second_ops'], [5, 5])

    def test_scheduler_reads_the_series_and_role_shares_of_the_timed_window(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary)
            row = dict(key='get64-p1')
            self.assertFalse(scheduler.throughput_series(run, row)['available'])
            (run / 'redis').mkdir()
            (run / 'redis/get64-p1.json').write_text(json.dumps(series([100] * 5 + [10] * 3 + [100] * 4)))
            result = scheduler.throughput_series(run, row)
            self.assertEqual((result['path'], result['stall_windows'], result['stall_seconds'], result['steady_ops_per_sec']), ('redis/get64-p1.json', 1, 3, 100))
            (run / 'redis/get64-p1.json').write_text('{')
            self.assertEqual(scheduler.throughput_series(run, row)['reason'], 'unreadable raw timed client output')
        share = lambda idle: dict(user=0, nice=0, system=(100 - idle) / 2, idle=idle, iowait=0, irq=0, softirq=(100 - idle) / 2, steal=0)
        owner = dict(role='client', artifact_dir='/x/run/redis/get64-p1', pid=50, process=dict(start_ticks=9))
        timed = dict(pid=50, start_ticks=9)
        samples = [dict(cpu_share_pct={'cpu1': share(100), 'cpu3': share(100)}, owned_processes=[]),
                   dict(cpu_share_pct={'cpu1': share(0), 'cpu3': share(40), 'cpu4': share(60)}, owned_processes=[timed]),
                   dict(cpu_share_pct={'cpu1': share(10), 'cpu3': None, 'cpu4': share(80)}, owned_processes=[timed]),
                   dict(cpu_share_pct={'cpu1': share(20), 'cpu3': share(50), 'cpu4': share(70)}, owned_processes=[timed])]
        roles = dict(server={1}, client={3, 4}, control={10})
        result = scheduler.role_cpu_shares(samples, roles, [owner], 'get64-p1')
        self.assertEqual((result['window'], result['samples']), ('timed client lifetime', 3))
        self.assertEqual((result['roles']['server']['idle'], result['roles']['server']['system'], result['roles']['server']['softirq']), (10, 45, 45))
        self.assertEqual(result['roles']['client']['idle'], 60)
        self.assertIsNone(result['roles']['control']['idle'])
        whole = scheduler.role_cpu_shares(samples, roles)
        self.assertEqual((whole['window'], whole['samples'], whole['roles']['server']['idle']), ('whole case', 4, 15))


if __name__ == '__main__':
    unittest.main()
