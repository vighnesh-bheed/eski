import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True

SCHEMA = 'eski-testbed-design-v1'
PLAN_SCHEMA = 'eski-exam-plan-v1'
EXPERIMENT_SCHEMA = 'eski-exam-experiment-v1'
TARGETS = ('eski-docker', 'eski', 'redis', 'valkey', 'dragonfly')
PHASES = ('calibration', 'benchmark')
TYPES = {
    'string': dict(dataset='string', required=('dbsize', 'get', 'set', 'strlen')),
    'hash': dict(dataset='hash', required=('dbsize', 'hget', 'hlen', 'hset', 'hstrlen')),
    'set': dict(dataset='set', required=('dbsize', 'sadd', 'scard', 'sismember')),
    'zset': dict(dataset='zset', required=('dbsize', 'zadd', 'zcard', 'zscore')),
}
GATES = ('sensor_chip', 'sensor_label', 'cool_temp_c', 'max_temp_c', 'min_idle', 'min_rest', 'stable_seconds', 'max_wait',
         'sample_seconds', 'min_free_bytes', 'max_client_utilization_pct', 'max_latency_seconds')
POWER_SOURCES = ('mains', 'no-power-supply-devices')
RESOURCES = ('server_cpus', 'client_cpus', 'control_cpus', 'server_memory', 'client_memory', 'maxmemory', 'resource_policy')
KEY = re.compile(r'[a-z0-9][a-z0-9.-]*$')


def load(path):
    return json.loads(Path(path).read_text())


def positive(value):
    return type(value) is int and value > 0


def validate(design):
    if design.get('schema') != SCHEMA:
        raise ValueError('design schema must be ' + SCHEMA)
    engines = design.get('engines')
    if not isinstance(engines, list) or not engines:
        raise ValueError('design needs engines')
    targets = [engine.get('target') for engine in engines]
    if len(set(targets)) != len(targets) or not set(targets) <= set(TARGETS):
        raise ValueError('engine targets must be unique and among ' + ', '.join(TARGETS))
    for engine in engines:
        if not engine.get('label') or not isinstance(engine.get('image'), str) or not engine['image']:
            raise ValueError('every engine needs a label and an image')
        if engine['target'] != 'eski-docker' and '@sha256:' not in engine['image']:
            raise ValueError('engine image must be pinned by digest: ' + engine['target'])
    if '@sha256:' not in (design.get('load_generator') or {}).get('image', ''):
        raise ValueError('the load generator image must be pinned by digest')
    if '@sha256:' not in str(design.get('cli_image') or ''):
        raise ValueError('the cli_image used for health checks must be pinned by digest')
    redis = next((engine['image'] for engine in engines if engine['target'] == 'redis'), None)
    if redis is not None and redis != design['cli_image']:
        raise ValueError('the cli_image must be the redis engine image when redis is measured')
    resources = design.get('resources') or {}
    missing = [name for name in RESOURCES if name not in resources]
    gates = design.get('gates') or {}
    missing += [name for name in GATES if name not in gates]
    if missing:
        raise ValueError('design lacks ' + ', '.join(missing))
    if gates.get('power_source', 'mains') not in POWER_SOURCES:
        raise ValueError('gates.power_source must be one of ' + ', '.join(POWER_SOURCES))
    if 'idle_watch_seconds' in gates and (type(gates['idle_watch_seconds']) is not int or gates['idle_watch_seconds'] < 0):
        raise ValueError('gates.idle_watch_seconds must be a non-negative integer number of seconds')
    dataset = design.get('dataset') or {}
    client = design.get('client') or {}
    for name, value in (('dataset.keys', dataset.get('keys')), ('dataset.members', dataset.get('members')), ('client.threads', client.get('threads')),
                        ('client.connections_per_thread', client.get('connections_per_thread')), ('client.warmup_seconds', client.get('warmup_seconds')),
                        ('client.test_seconds', client.get('test_seconds')), ('client.timeout_seconds', client.get('timeout_seconds')),
                        ('client.preload_pipeline', client.get('preload_pipeline')), ('repetitions', design.get('repetitions'))):
        if not positive(value):
            raise ValueError(name + ' must be a positive integer')
    if not all(positive(key) and key <= dataset['keys'] for key in dataset.get('sample_keys') or [0]):
        raise ValueError('dataset.sample_keys must lie within the key range')
    workloads = design.get('workloads')
    if not isinstance(workloads, list) or not workloads:
        raise ValueError('design needs workloads')
    keys = set()
    for workload in workloads:
        key = workload.get('key')
        if not isinstance(key, str) or not KEY.match(key) or key in keys:
            raise ValueError('workload keys must be unique lowercase names: ' + str(key))
        keys.add(key)
        if workload.get('type') not in TYPES or not workload.get('name'):
            raise ValueError('workload %s needs a name and a type among %s' % (key, ', '.join(TYPES)))
        if not positive(workload.get('data_size')) or not positive(workload.get('pipeline')):
            raise ValueError('workload %s needs a positive data_size and pipeline' % key)
        if workload['type'] == 'string':
            if not re.fullmatch(r'\d+:\d+', str(workload.get('ratio'))) or workload['ratio'] == '0:0':
                raise ValueError('string workload %s needs a set:get ratio' % key)
        elif not isinstance(workload.get('command'), str) or '__key__' not in workload['command']:
            raise ValueError('workload %s needs a command with __key__' % key)
    calibration = design.get('calibration') or {}
    if not calibration.get('workloads') or not set(calibration['workloads']) <= keys or not positive(calibration.get('repetitions')):
        raise ValueError('calibration needs known workloads and a positive repetition count')
    return design


def common_argv(design, workload):
    dataset, client = design['dataset'], design['client']
    return ['--protocol=redis', '--key-minimum=1', '--key-maximum=%d' % dataset['keys'], '--key-prefix=' + dataset['key_prefix'],
            '--data-size=%d' % workload['data_size'], '--hide-histogram', '--print-percentiles=' + client['percentiles']]


def preload_argv(design, workload):
    members = design['dataset']['members']
    kind = workload['type']
    if kind == 'string':
        load_args = ['--ratio=1:0', '--key-pattern=P:P']
    else:
        if kind == 'hash':
            command = 'HSET __key__ ' + ' '.join('field:%d __data__' % n for n in range(1, members + 1))
        elif kind == 'set':
            command = 'SADD __key__ ' + ' '.join('member:%d' % n for n in range(1, members + 1))
        else:
            command = 'ZADD __key__ ' + ' '.join('%d member:%d' % (n, n) for n in range(1, members + 1))
        load_args = ['--command', command, '--command-key-pattern=P']
    return common_argv(design, workload) + load_args + ['--threads=1', '--clients=1', '--requests=%d' % design['dataset']['keys'],
                                                       '--pipeline=%d' % design['client']['preload_pipeline']]


def timed_argv(design, workload, seconds):
    client = design['client']
    if workload['type'] == 'string':
        pattern = ['--ratio=' + workload['ratio'], '--key-pattern=R:R']
    else:
        pattern = ['--command', workload['command'], '--command-key-pattern=R']
    return common_argv(design, workload) + pattern + ['--threads=%d' % client['threads'], '--clients=%d' % client['connections_per_thread'],
                                                     '--pipeline=%d' % workload['pipeline'], '--distinct-client-seed', '--run-count=1',
                                                     '--test-time=%d' % seconds]


def checks(design, workload):
    dataset = design['dataset']
    replies = [dict(argv=['DBSIZE'], equals=dataset['keys'])]
    for number in dataset.get('sample_keys') or []:
        key = dataset['key_prefix'] + str(number)
        middle = 'member:%d' % ((dataset['members'] + 1) // 2)
        kind = workload['type']
        if kind == 'string':
            replies.append(dict(argv=['STRLEN', key], equals=workload['data_size']))
        elif kind == 'hash':
            replies += [dict(argv=['HLEN', key], equals=dataset['members']),
                        dict(argv=['HSTRLEN', key, 'field:%d' % ((dataset['members'] + 1) // 2)], equals=workload['data_size'])]
        elif kind == 'set':
            replies += [dict(argv=['SCARD', key], equals=dataset['members']), dict(argv=['SISMEMBER', key, middle], equals=1)]
        else:
            replies += [dict(argv=['ZCARD', key], equals=dataset['members']),
                        dict(argv=['ZSCORE', key, middle], equals=str((dataset['members'] + 1) // 2))]
    return dict(keyspacelen=dataset['keys'], replies=replies)


def tested_commands(workload):
    if workload['type'] == 'string':
        writes, reads = (int(part) for part in workload['ratio'].split(':'))
        return sorted((['set'] if writes else []) + (['get'] if reads else []))
    return [workload['command'].split()[0].lower()]


def client_entry(design, argv, seconds, cpus):
    entry = dict(tool='memtier_benchmark', image='memtier', cpus=cpus, requested_cpus=design['client']['threads'],
                 timeout=design['client']['timeout_seconds'], argv=argv)
    if seconds is not None:
        entry.update(declared_test_time=seconds, test_time=seconds)
    return entry


def plan_item(design, workload):
    client, cpus = design['client'], design['resources']['client_cpus']
    kind = TYPES[workload['type']]
    test, warmup = client['test_seconds'], client['warmup_seconds']
    preload = dict(tool='memtier_benchmark', image='memtier', cpus=cpus, requested_cpus=1, timeout=client['timeout_seconds'],
                   argv=preload_argv(design, workload))
    return dict(key=workload['key'], name=workload['name'], display=workload['name'], suite=design['suite'], runs=1,
                fresh_server=True, flush_each_run=False, config=[], init_commands=[], init_lua=[],
                required_commands=sorted(set(kind['required']) | set(tested_commands(workload))),
                preload=preload, check=checks(design, workload),
                warmup=client_entry(design, timed_argv(design, workload, warmup), warmup, cpus),
                clients=[client_entry(design, timed_argv(design, workload, test), test, cpus)],
                info=dict(dataset_name='%d-keys-%s' % (design['dataset']['keys'], kind['dataset']), tested_commands=tested_commands(workload),
                          tested_groups=[kind['dataset']], test_time_s=test, declared_test_time_s=test, warmup_s=warmup,
                          connections=client['threads'] * client['connections_per_thread'], pipeline=workload['pipeline'],
                          data_size=workload['data_size'], clients=1))


def phase_workloads(design, phase):
    if phase == 'benchmark':
        return design['workloads']
    wanted = design['calibration']['workloads']
    return [workload for workload in design['workloads'] if workload['key'] in wanted]


def plan(design, phase):
    validate(design)
    return dict(schema=PLAN_SCHEMA, items=[plan_item(design, workload) for workload in phase_workloads(design, phase)])


def experiment(design, phase):
    validate(design)
    resources, gates = design['resources'], design['gates']
    value = dict(schema=EXPERIMENT_SCHEMA, targets=[engine['target'] for engine in design['engines']],
                 repetitions=design['repetitions'] if phase == 'benchmark' else design['calibration']['repetitions'])
    value.update({name: resources[name] for name in RESOURCES})
    value.update({name: gates[name] for name in GATES})
    value['power_source'] = gates.get('power_source', 'mains')
    if 'idle_watch_seconds' in gates:
        value['idle_watch_seconds'] = gates['idle_watch_seconds']
    return value


def encode(value):
    return (json.dumps(value, indent=1, sort_keys=True, allow_nan=False) + '\n').encode()


def write(design, output):
    output = Path(output)
    written = {}
    for phase in PHASES:
        directory = output / phase
        directory.mkdir(parents=True, exist_ok=True)
        for name, value in (('plan.json', plan(design, phase)), ('experiment.json', experiment(design, phase))):
            data = encode(value)
            (directory / name).write_bytes(data)
            written[phase + '/' + name] = hashlib.sha256(data).hexdigest()
    return written


def main(argv=None):
    parser = argparse.ArgumentParser(description='Write the plan and experiment files of both phases from the test bed design.')
    parser.add_argument('--design', type=Path, default=Path(__file__).with_name('design.json'))
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        written = write(load(args.design), args.out)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('plans.py: error: ' + str(error), file=sys.stderr)
        return 2
    for name, value in sorted(written.items()):
        print('%s  %s' % (value, args.out / name))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
