import argparse
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import statistics
import sys

sys.dont_write_bytecode = True

SCHEMA = 'eski-testbed-dataset-v1'
PHASES = ('calibration', 'benchmark')
METRICS = ('ops', 'p99', 'mem')


class CombineError(ValueError):
    pass


def load(path):
    return json.loads(Path(path).read_text())


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def finite(value, positive=False):
    if type(value) not in (int, float):
        return None
    if not math.isfinite(value) or value < 0 or (positive and value == 0):
        return None
    return value


def inside(root, name):
    path = (root / name).resolve()
    if not path.is_relative_to(root.resolve()) or PurePosixPath(name).is_absolute():
        raise CombineError('path escapes the results: ' + name)
    return path


def integrity(results, attempt):
    directory = attempt.get('directory')
    expected = attempt.get('artifacts_sha256')
    if not directory or not expected:
        return 'unverified', ['no durable artifact inventory']
    base = inside(results, directory)
    inventory_path = base / 'artifacts.json'
    if not inventory_path.is_file() or sha(inventory_path) != expected:
        return 'failed', ['artifact inventory sha256 differs from the checkpoint']
    for name, item in sorted(load(inventory_path).items()):
        path = inside(base, name)
        if not path.is_file() or sha(path) != item.get('sha256') or path.stat().st_size != item.get('bytes'):
            return 'failed', ['artifact changed after the case: ' + name]
    return 'verified', []


def reasons_of(attempt, details, record):
    found = []
    for value in [*(details.get('reasons') or []), details.get('error'), record.get('error'), record.get('skipped'),
                  (details.get('target') or {}).get('reason'), attempt.get('interruption_reason')]:
        if value:
            found.append(str(value))
    return list(dict.fromkeys(found))


def measurement(results, phase, row):
    results = results / phase / 'results'
    attempt = row['attempts'][-1] if row.get('attempts') else {}
    result_path = inside(results, attempt['directory']) / 'result.json' if attempt.get('directory') else None
    if result_path is not None and result_path.is_file():
        stored = load(result_path)
        attempt = dict(stored, artifacts_sha256=attempt.get('artifacts_sha256'))
    details = attempt.get('details') or {}
    record = details.get('record') or {}
    telemetry = attempt.get('telemetry') or {}
    state = row.get('state', 'missing')
    checked, problems = integrity(results, attempt) if attempt else ('unverified', ['no attempt recorded'])
    reasons = reasons_of(attempt, details, record) + problems
    if state != 'successful':
        reasons.insert(0, 'case ' + state)
    peaks = [peak.get('memory_peak_bytes') for peak in telemetry.get('server_pre_stop_cgroup_peaks') or []
             if PurePosixPath(str(peak.get('artifact_dir') or '')).parts[-2:] == ('run', row['target'])]
    peaks = [value for value in peaks if finite(value, True) is not None]
    annotations = sorted(details.get('annotations') or [])
    values = dict(ops=finite(record.get('ops_per_sec'), True), p50=finite(record.get('p50_ms')), p99=finite(record.get('p99_ms')),
                  p999=finite(record.get('p999_ms')), max_ms=finite(record.get('max_ms')), mem=peaks[-1] if peaks else None,
                  client_cores=finite(record.get('client_cpu_cores')), client_utilization_pct=finite(details.get('client_utilization_pct')))
    missing = [name for name in METRICS if values[name] is None]
    if state == 'successful' and missing:
        reasons.append('missing measurement: ' + ', '.join(missing))
    included = state == 'successful' and checked == 'verified' and not missing
    return dict(phase=phase, workload=row['key'], name=row['name'], index=row['index'], engine=row['target'], repetition=row['repetition'],
                state=state, included=included, reasons=list(dict.fromkeys(reasons)), annotations=annotations,
                client_limited='client_limited' in annotations, integrity=checked, attempts=len(row.get('attempts') or []),
                version=(details.get('target') or {}).get('version'), started_at=attempt.get('started_at'), finished_at=attempt.get('finished_at'),
                directory=attempt.get('directory'), **values)


def stats(values):
    if not values:
        return None
    return dict(median=statistics.median(values), min=min(values), max=max(values), values=values)


def summarize(rows, workloads, engines, repetitions):
    summary = []
    for workload in workloads:
        for engine in engines:
            cell = [row for row in rows if row['workload'] == workload['key'] and row['engine'] == engine['target']]
            valid = [row for row in cell if row['included']]
            entry = dict(workload=workload['key'], name=workload['name'], index=workload['index'], engine=engine['target'],
                         planned=repetitions, recorded=len(cell), repetitions=len(valid), client_limited=sum(row['client_limited'] for row in valid),
                         excluded=[dict(repetition=row['repetition'], state=row['state'], reasons=row['reasons'], ops=row['ops'], p99=row['p99'], mem=row['mem'])
                                   for row in cell if not row['included']])
            for metric in METRICS:
                entry[metric] = stats([row[metric] for row in valid])
            summary.append(entry)
    return summary


def machine_context(protocol, identity):
    host = protocol.get('machine') or identity.get('host') or {}
    config = protocol.get('resources') or identity.get('config') or {}
    topology = host.get('topology') or {}
    memory = host.get('mem_total') or ''
    words = memory.split()
    hardware = host.get('hardware') or {}
    return dict(cpu_model=host.get('cpu_model'), kernel=host.get('kernel'), machine=host.get('machine'), online_cpus=host.get('online_cpus'),
                mem_total_bytes=int(words[1]) * 1024 if len(words) > 1 and words[1].isdigit() else None,
                product=' '.join(value for value in (hardware.get('sys_vendor'), hardware.get('product_name')) if value) or None,
                cpus=config.get('cpus'), topology=topology, server_memory=config.get('server_memory'), client_memory=config.get('client_memory'),
                maxmemory=config.get('maxmemory'), dragonfly_threads=config.get('dragonfly_threads'),
                frequency_policy=host.get('frequency_policy'), sensor=config.get('sensor'))


def fill_result(path):
    if path is None:
        return None
    path = Path(path)
    if path.is_dir():
        candidates = sorted(path.rglob('fill.json'))
        if len(candidates) != 1:
            raise CombineError('expected exactly one fill.json under ' + str(path))
        path = candidates[0]
    value = load(path)
    if value.get('schema') != 'eski-testbed-fill-v1':
        raise CombineError('unsupported fill schema')
    return dict(stamp=value.get('stamp'), design=value.get('design'), machine=value.get('machine'), resources=value.get('resources'),
                started_at=value.get('started_at'), finished_at=value.get('finished_at'), source_sha256=sha(path),
                engines=[{key: entry.get(key) for key in ('target', 'label', 'status', 'error', 'dbsize', 'used_memory', 'used_memory_rss', 'bytes_per_key_rss',
                                                           'bytes_per_key_used', 'cgroup_peak_bytes', 'bytes_per_key_cgroup_peak', 'ops_per_sec', 'p99_ms',
                                                           'max_ms', 'version', 'image_id', 'package_c_before', 'package_c_after')}
                         for entry in value.get('engines') or []])


def combine(results, fill=None, collected=None):
    results = Path(results)
    protocol_path = results / 'protocol.json'
    if not protocol_path.is_file():
        raise CombineError('no protocol.json in ' + str(results))
    protocol = load(protocol_path)
    design = protocol.get('design') or {}
    engines = protocol.get('engines') or [dict(target=item['target'], label=item['label']) for item in design.get('engines') or []]
    workloads = [dict(key=item['key'], name=item['name'], index=index) for index, item in enumerate(design.get('workloads') or [])]
    rows, phases = [], {}
    for phase in PHASES:
        checkpoint_path = results / phase / 'results' / 'checkpoint.json'
        if not checkpoint_path.is_file():
            phases[phase] = dict(state='not started', planned=0)
            continue
        checkpoint = load(checkpoint_path)
        phase_rows = [measurement(results, phase, row) for row in checkpoint.get('cases') or []]
        rows += phase_rows
        phases[phase] = dict(state=checkpoint.get('state'), planned=len(phase_rows), valid=sum(row['included'] for row in phase_rows),
                             excluded=sum(not row['included'] for row in phase_rows))
    identity_path = results / 'benchmark' / 'results' / 'identity.json'
    identity = load(identity_path) if identity_path.is_file() else {}
    benchmark = [row for row in rows if row['phase'] == 'benchmark']
    for engine in engines:
        seen = sorted({row['version'] for row in rows if row['engine'] == engine['target'] and row['version']})
        engine['observed_versions'] = seen
    workflow_path = results / 'control' / 'workflow.json'
    workflow = load(workflow_path) if workflow_path.is_file() else {}
    run = dict(root=protocol.get('root'), protocol_sha256=sha(protocol_path), workflow_status=workflow.get('status'), workflow_reason=workflow.get('reason'),
               started_at=workflow.get('started_at'), finished_at=workflow.get('finished_at'), identity=identity.get('sha256'),
               archive=dict((load(collected) if collected else {}).get('receipt') or {}) or None)
    exclusions = [dict(workload=row['workload'], engine=row['engine'], repetition=row['repetition'], phase=row['phase'], state=row['state'], reasons=row['reasons'])
                  for row in rows if not row['included']]
    return dict(schema=SCHEMA, title=design.get('title'), run=run, design=dict(repetitions=design.get('repetitions'), dataset=design.get('dataset'),
                client=design.get('client'), gates=design.get('gates'), methodology=design.get('methodology'), calibration=design.get('calibration'),
                load_generator=design.get('load_generator'), source=protocol.get('source')),
                machine=machine_context(protocol, identity), engines=engines, workloads=workloads, phases=phases, rows=rows,
                summary=summarize(benchmark, workloads, engines, design.get('repetitions') or 0), exclusions=exclusions, fill=fill_result(fill),
                counts=dict(planned=len(benchmark), valid=sum(row['included'] for row in benchmark), excluded=sum(not row['included'] for row in benchmark),
                            client_limited=sum(row['client_limited'] for row in benchmark if row['included'])))


def main(argv=None):
    parser = argparse.ArgumentParser(description='Build dataset.json from a collected results archive and a fill result.')
    parser.add_argument('--results', type=Path, required=True, help='directory extracted by collect.py from the results archive')
    parser.add_argument('--fill', type=Path, help='fill.json, or the directory collect.py extracted from the fill archive')
    parser.add_argument('--collected', type=Path, help='the .collected.json written by collect.py for the results archive')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(argv)
    collected = args.collected
    if collected is None:
        guess = args.results.with_name(args.results.name + '.collected.json')
        collected = guess if guess.is_file() else None
    try:
        dataset = combine(args.results, args.fill, collected)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('combine.py: error: ' + str(error), file=sys.stderr)
        return 2
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(dataset, indent=1, sort_keys=True, allow_nan=False) + '\n')
    print('%s: %d measurements, %d valid, %d excluded, %d summary cells, fill %s' % (
        args.out, dataset['counts']['planned'], dataset['counts']['valid'], dataset['counts']['excluded'], len(dataset['summary']),
        'present' if dataset['fill'] else 'absent'))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
