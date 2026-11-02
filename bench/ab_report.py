import argparse
import collections
import importlib.util
import json
import math
import statistics
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('eski_ab', Path(__file__).with_name('ab.py'))
ab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ab)

FLOOR_SCHEMA = 'eski-local-ab-floor-v1'
DEFAULT_FLOOR = Path(__file__).with_name('ab_floor.json')
STEP = 0.005


def load(root):
    root = Path(root)
    data = json.loads((root / 'summary.json').read_text())
    rows = json.loads((root / 'rows.json').read_text())
    return data['meta'], data['summary'], rows


def is_aa(meta):
    return meta['binaries']['A']['sha256'] == meta['binaries']['B']['sha256'] and meta['binaries']['A'].get('extra') == meta['binaries']['B'].get('extra')


def floor_value(low, high):
    spread = max(1 - low, high - 1, 0.0)
    return round(math.ceil(round(spread / STEP, 6)) * STEP, 3)


def floor_record(meta, summary, rows):
    if not is_aa(meta):
        raise ValueError('a floor comes only from an A/A session of one binary against itself')
    loads = [float(r['loadavg'].split()[0]) for r in rows if r.get('loadavg')]
    workloads = {}
    for key, s in summary.items():
        if not s['clean_pairs']:
            workloads[key] = dict(clean_pairs=0, pairs=len(s.get('pairs', [])), median=None, min=None, max=None, floor=None)
            continue
        workloads[key] = dict(clean_pairs=s['clean_pairs'], pairs=len(s.get('pairs', [])), median=s['cpu_ratio_median'], min=s['cpu_ratio_min'],
                              max=s['cpu_ratio_max'], floor=floor_value(s['cpu_ratio_min'], s['cpu_ratio_max']), verdict=s['verdict'])
    return dict(schema=FLOOR_SCHEMA, session=meta['label'], date=time.strftime('%Y-%m-%d', time.localtime(meta['started'])),
                binary_sha256=meta['binaries']['A']['sha256'], cpu_model=meta.get('cpu_model'), kernel=meta.get('kernel'),
                governor=meta.get('governor'), epp=meta.get('epp'), no_turbo=meta.get('no_turbo'), cpus=meta['cpus'], mode=meta.get('mode', 'sequential'),
                rounds=meta['rounds'], seconds=meta['seconds'], warmup=meta['warmup'], limits=meta.get('limits'),
                load=[min(loads), max(loads)] if loads else None, workloads=workloads)


def read_floor(path):
    path = Path(path)
    if path.is_dir():
        meta, summary, rows = load(path)
        return floor_record(meta, summary, rows)
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or value.get('schema') != FLOOR_SCHEMA:
        raise ValueError('%s is not a floor record' % path)
    return value


def reading(median, floor):
    if median is None:
        return 'insufficient'
    if floor is None:
        return 'no floor'
    if median < 1 - floor:
        return 'lower than the floor'
    if median > 1 + floor:
        return 'higher than the floor'
    return 'within the floor'


def fmt(m):
    return '%.0f [%.0f, %.0f]' % (m['median'], m['min'], m['max']) if m else 'n/a'


def median_of(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def render(meta, summary, rows, floor=None):
    out = []
    p = out.append
    mode = meta.get('mode', 'sequential')
    cpus = meta['cpus']
    lanes = 'lanes server %s / client %s and server %s / client %s' % (cpus['server'], cpus['client'], cpus.get('server_b'), cpus.get('client_b')) if mode == 'concurrent' else 'server CPUs %s, client CPUs %s' % (cpus['server'], cpus['client'])
    p('Session %s (%s mode): binaries A %s (%s) and B %s (%s), %s, %d rounds of %d s after %d s warmup.' % (
        meta['label'], mode, Path(meta['binaries']['A']['path']).name, meta['binaries']['A']['sha256'][:12], Path(meta['binaries']['B']['path']).name,
        meta['binaries']['B']['sha256'][:12], lanes, meta['rounds'], meta['seconds'], meta['warmup']))
    p('')
    p('| Workload | Clean %s | A ns/cmd median [min, max] | B ns/cmd median [min, max] | B/A paired median [min, max] | Task-only B/A | Excluded runs (reasons) | reads, writes, epoll per cmd | Server MHz median | Client-limited runs | Lane bias |' % ('swap pairs' if mode == 'concurrent' else 'pairs'))
    p('| --- | ---: | ---: | ---: | ---: | ---: | --- | --- | ---: | ---: | ---: |')
    for key, s in summary.items():
        sel = [r for r in rows if r['workload'] == key]
        reasons = collections.Counter(reason for e in s['excluded'] for reason in e['reasons'])
        rs = '%d (%s)' % (len(s['excluded']), ', '.join('%s %d' % kv for kv in sorted(reasons.items()))) if s['excluded'] else '0'
        if s.get('pairs_excluded_frequency'):
            rs += '; %d pairs frequency' % len(s['pairs_excluded_frequency'])
        sysc = ', '.join('%.4f' % v if v is not None else 'n/a' for v in (median_of([r['syscr_per_cmd'] for r in sel]), median_of([r['syscw_per_cmd'] for r in sel]),
                                                                           median_of([r['el_cycles_per_cmd'] for r in sel])))
        mhz = median_of([r['freq_mean_khz'] for r in sel if r['freq_mean_khz']])
        ratio = '%.3f [%.3f, %.3f]' % (s['cpu_ratio_median'], s['cpu_ratio_min'], s['cpu_ratio_max']) if s['cpu_ratio_median'] else 'insufficient'
        task = '%.3f' % s['task_ratio_median'] if s.get('task_ratio_median') else 'n/a'
        bias = '%.3f' % s['slot_bias_median'] if s.get('slot_bias_median') else 'n/a'
        p('| %s | %d | %s | %s | %s | %s | %s | %s | %s | %d | %s |' % (key, s['clean_pairs'], fmt(s['A']), fmt(s['B']), ratio, task, rs, sysc,
                                                                    '%.0f' % (mhz / 1000) if mhz else 'n/a', s.get('client_limited_runs', 0), bias))
    p('')
    p('Unfiltered view (every completed pair, noise flags ignored; for calibrating the filter, not for claims):')
    for key in summary:
        sel = [r for r in rows if r['workload'] == key]
        by = {(r['round'], r['variant']): r for r in sel}
        ratios = [by[(n, 'B')]['cpu_ns_per_cmd'] / by[(n, 'A')]['cpu_ns_per_cmd'] for n in sorted({r['round'] for r in sel}) if (n, 'A') in by and (n, 'B') in by]
        if ratios and mode == 'concurrent':
            swaps = [(ratios[i] * ratios[i + 1]) ** 0.5 for i in range(0, len(ratios) - 1, 2)]
            if swaps:
                p('  %s: %d rounds, %d swap pairs, swap-pair B/A median %.3f [%.3f, %.3f]' % (key, len(ratios), len(swaps), statistics.median(swaps), min(swaps), max(swaps)))
        elif ratios:
            p('  %s: %d pairs, B/A median %.3f [%.3f, %.3f]' % (key, len(ratios), statistics.median(ratios), min(ratios), max(ratios)))
    if mode == 'concurrent' and any(s.get('pairs') for s in summary.values()):
        p('')
        p('Swap pairs (B/A CPU ratio, B/A server MHz ratio and its deviation from the workload median of %s):' % 'paired MHz ratios')
        for key, s in summary.items():
            parts = []
            for pair in s.get('pairs', []):
                state = 'clean' if pair['clean'] else ', '.join(pair['reasons'])
                freq = 'MHz %.3f (%+.1f%%)' % (pair['freq_ratio'], 100 * pair['freq_deviation']) if pair.get('freq_ratio') and pair.get('freq_deviation') is not None else 'MHz n/a'
                parts.append('r%d-%d %.3f %s %s' % (pair['rounds'][0], pair['rounds'][1], pair['cpu_ratio'], freq, state))
            p('  %s: %s' % (key, '; '.join(parts)))
    p('')
    p('Thermal counters (only the server core\'s own throttle events exclude a run, above %s per second; package events are recorded and never exclude):' % meta.get('limits', {}).get('core_throttle_per_s', ab.LIMITS['concurrent']['core_throttle_per_s']))
    for key in summary:
        sel = [r for r in rows if r['workload'] == key]
        core = [r.get('throttle_delta', 0) for r in sel]
        package = [r['package_throttle_delta'] for r in sel if 'package_throttle_delta' in r]
        p('  %s: core events per run median %s max %s, runs with core events %d of %d; package events per run %s' % (
            key, median_of(core), max(core) if core else 'n/a', sum(1 for v in core if v), len(core),
            'median %s max %s' % (median_of(package), max(package)) if package else 'not recorded separately'))
    p('')
    ops = {k: (s['A_ops_median'], s['B_ops_median'], s['ops_ratio_median']) for k, s in summary.items()}
    p('Throughput medians (ops/s, clean runs): ' + '; '.join('%s A %s B %s ratio %s' % (k, round(a) if a else 'n/a', round(b) if b else 'n/a', r) for k, (a, b, r) in ops.items()))
    loads = [float(r['loadavg'].split()[0]) for r in rows if r.get('loadavg')]
    if loads:
        p('1-minute load during the session: %.2f to %.2f. Wall time %.1f min.' % (min(loads), max(loads), (meta.get('finished', meta['started']) - meta['started']) / 60))
    own = floor_record(meta, summary, rows) if is_aa(meta) else None
    if own is not None:
        p('')
        noun = 'swap pairs' if mode == 'concurrent' else 'pairs'
        p('A/A floor stated by this session (half-width around 1 of the range of clean %s, rounded up to %.1f percent):' % (noun, 100 * STEP))
        p('')
        p('| Workload | Clean %s | B/A median [min, max] | Floor | Median within floor |' % noun)
        p('| --- | ---: | ---: | ---: | --- |')
        for key, w in own['workloads'].items():
            if w['floor'] is None:
                p('| %s | 0 | insufficient | n/a | n/a |' % key)
            else:
                p('| %s | %d%s | %.3f [%.3f, %.3f] | %.1f%% | %s |' % (key, w['clean_pairs'], ' (insufficient)' if w.get('verdict') == 'insufficient' else '', w['median'], w['min'], w['max'],
                                                                     100 * w['floor'], 'yes' if abs(w['median'] - 1) <= w['floor'] else 'no'))
    if floor is not None:
        p('')
        p('Against the A/A floor of session %s (%s, binary %s, server CPUs %s and %s):' % (floor['session'], floor['date'], floor['binary_sha256'][:12], floor['cpus']['server'], floor['cpus'].get('server_b')))
        for key, s in summary.items():
            w = floor['workloads'].get(key)
            f = w['floor'] if w else None
            median = s['cpu_ratio_median']
            p('  %s: B/A %s, floor %s, %s' % (key, '%.3f' % median if median else 'insufficient', '%.1f%%' % (100 * f) if f is not None else 'not recorded', reading(median, f)))
    return '\n'.join(out) + '\n'


def parser():
    p = argparse.ArgumentParser(description='Report a local A/B session and its A/A floor.')
    p.add_argument('session')
    p.add_argument('--floor', help='floor record or A/A session directory; defaults to bench/ab_floor.json when it exists')
    p.add_argument('--no-floor', action='store_true')
    p.add_argument('--recompute', action='store_true', help='recompute the summary from rows.json with the current default rules')
    p.add_argument('--write-floor', help='write the floor record of this A/A session to the given path')
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    meta, summary, rows = load(args.session)
    if args.recompute:
        summary = ab.summarize_session(rows, meta, ab.limits_for(meta.get('mode', 'sequential')))
    if args.write_floor:
        Path(args.write_floor).write_text(json.dumps(floor_record(meta, summary, rows), indent=1) + '\n')
    floor = None
    if not args.no_floor:
        if args.floor:
            floor = read_floor(args.floor)
        elif DEFAULT_FLOOR.is_file():
            floor = read_floor(DEFAULT_FLOOR)
    sys.stdout.write(render(meta, summary, rows, floor))


if __name__ == '__main__':
    main()
