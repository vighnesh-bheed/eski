import argparse
from collections import defaultdict
from contextlib import contextmanager
import hashlib
import html
import json
import math
from pathlib import Path
import re
import socket
import statistics
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
BLOCKS = ('CONFORMANCE', 'BENCHMARKS', 'COMMANDS')
ENGINE_LABELS = {'eski-docker': 'Eski', 'eski': 'Eski', 'redis': 'Redis', 'valkey': 'Valkey', 'dragonfly': 'Dragonfly'}


class RespError(ValueError):
    pass


class Connection:
    def __init__(self, host, port, timeout=5):
        self.socket = socket.create_connection((host, port), timeout=timeout)
        self.file = self.socket.makefile('rb')

    def close(self):
        self.file.close()
        self.socket.close()

    def line(self):
        value = self.file.readline(1 << 20)
        if not value.endswith(b'\r\n'):
            raise RespError('incomplete RESP line')
        return value[:-2]

    def reply(self):
        prefix = self.file.read(1)
        if prefix == b'+':
            return self.line().decode('utf-8')
        if prefix == b'-':
            raise RespError(self.line().decode('utf-8', errors='replace'))
        if prefix == b':':
            return int(self.line())
        if prefix in (b'$', b'*', b'~', b'%'):
            count = int(self.line())
            if count == -1:
                return None
            if count < 0 or count > (16 << 20 if prefix == b'$' else 100000):
                raise RespError('invalid RESP length')
            if prefix == b'$':
                data = self.file.read(count)
                if len(data) != count or self.file.read(2) != b'\r\n':
                    raise RespError('incomplete RESP bulk string')
                return data.decode('utf-8')
            if prefix == b'%':
                return {self.reply(): self.reply() for _ in range(count)}
            return [self.reply() for _ in range(count)]
        raise RespError('unsupported or missing RESP reply type')

    def call(self, *arguments):
        values = [str(value).encode('utf-8') for value in arguments]
        wire = b'*%d\r\n' % len(values)
        wire += b''.join(b'$%d\r\n' % len(value) + value + b'\r\n' for value in values)
        self.socket.sendall(wire)
        return self.reply()


@contextmanager
def server_connection(binary, address=None):
    if address:
        host, separator, port = address.rpartition(':')
        if not separator or not host:
            raise ValueError('--server must be HOST:PORT')
        connection = Connection(host, int(port))
        try:
            yield connection
        finally:
            connection.close()
        return
    binary = Path(binary).resolve()
    if not binary.is_file():
        raise ValueError('server binary is missing; run ./build.sh or pass --server-binary')
    with tempfile.TemporaryDirectory(prefix='eski-docs-') as directory:
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        log_path = Path(directory) / 'server.log'
        with log_path.open('wb') as log:
            process = subprocess.Popen([str(binary), '--bind', '127.0.0.1', '--port', str(port), '--dir', directory,
                                        '--save', '', '--appendonly', 'no', '--loglevel', 'warning'],
                                       stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, cwd=directory)
            connection = None
            try:
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise ValueError('temporary server exited: ' + log_path.read_text(errors='replace').strip())
                    candidate = None
                    try:
                        candidate = Connection('127.0.0.1', port, timeout=0.3)
                        if candidate.call('PING') != 'PONG':
                            candidate.close()
                            raise ValueError('temporary server returned an unexpected PING reply')
                        candidate.socket.settimeout(10)
                        connection = candidate
                        break
                    except OSError:
                        if candidate is not None:
                            candidate.close()
                        time.sleep(0.05)
                    except Exception:
                        if candidate is not None:
                            candidate.close()
                        raise
                if connection is None:
                    raise ValueError('temporary server did not become ready')
                yield connection
            finally:
                if connection is not None:
                    connection.close()
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


def mapping(value, label):
    if isinstance(value, dict):
        return value
    if not isinstance(value, list) or len(value) % 2:
        raise ValueError(label + ' must contain key/value pairs')
    result = {}
    for position in range(0, len(value), 2):
        key = value[position]
        if not isinstance(key, str) or key in result:
            raise ValueError(label + ' has an invalid or duplicate key')
        result[key] = value[position + 1]
    return result


def command_inventory(connection):
    result = {}

    def visit(value):
        for name, metadata in mapping(value, 'COMMAND DOCS').items():
            fields = mapping(metadata, 'command metadata')
            key = name.lower()
            if key in result:
                raise ValueError('COMMAND DOCS contains duplicate command ' + key)
            if not isinstance(fields.get('group'), str) or not isinstance(fields.get('summary', ''), str):
                raise ValueError('command metadata lacks a group or summary')
            result[key] = fields
            if fields.get('subcommands'):
                visit(fields['subcommands'])

    visit(connection.call('COMMAND', 'DOCS'))
    registered = connection.call('COMMAND', 'LIST')
    if not isinstance(registered, list) or any(not isinstance(x, str) for x in registered):
        raise ValueError('COMMAND LIST returned invalid command names')
    registered = {name.lower() for name in registered}
    if set(result) != registered:
        missing = ', '.join(sorted(registered - set(result)))
        extra = ', '.join(sorted(set(result) - registered))
        raise ValueError('command inventory differs from registration; missing: %s; extra: %s' % (missing, extra))
    top = {name for name in result if '|' not in name}
    count = connection.call('COMMAND', 'COUNT')
    if count != len(top):
        raise ValueError('COMMAND COUNT disagrees with top-level command metadata')
    return dict(sorted(result.items()))


def argument_text(value):
    arg = mapping(value, 'command argument')
    kind = arg.get('type')
    children = arg.get('arguments') or []
    token = arg.get('token')
    name = str(arg.get('display_text') or arg.get('name') or 'value')
    if kind == 'oneof':
        text = '(' + ' | '.join(argument_text(child) for child in children) + ')'
    elif kind == 'block':
        text = ' '.join(argument_text(child) for child in children)
    elif kind == 'pure-token':
        text = str(token or name).upper()
    else:
        text = '<' + name + '>'
    if token and kind != 'pure-token':
        text = str(token).upper() + ' ' + text
    flags = arg.get('flags') or []
    if 'multiple' in flags:
        text += ' ...'
    if 'optional' in flags:
        text = '[' + text + ']'
    return text


def md(value):
    return str(value).replace('\r', ' ').replace('\n', ' ').replace('|', '\\|').replace('<', '&lt;').replace('>', '&gt;')


def table_code(value):
    text = str(value).replace('\r', ' ').replace('\n', ' ')
    fence = '`' * (max((len(match.group()) for match in re.finditer(r'`+', text)), default=0) + 1)
    if text.startswith('`') or text.endswith('`') or (text.startswith(' ') and text.endswith(' ') and text.strip()):
        text = ' ' + text + ' '
    return fence + text.replace('|', '\\|') + fence


def command_table(commands, compact=False):
    groups = defaultdict(list)
    for name, fields in commands.items():
        groups[fields['group']].append((name, fields))
    if compact:
        lines = ['| Group | Registered commands and subcommands |', '| --- | --- |']
        for group, items in sorted(groups.items()):
            names = ', '.join(table_code(name.upper().replace('|', ' ')) for name, _ in items)
            lines.append('| %s | %s |' % (md(group), names))
        return '\n'.join(lines)
    lines = []
    for group, items in sorted(groups.items()):
        lines.extend(['## ' + group.replace('_', ' ').title(), '', '| Command | Arguments | Metadata summary |', '| --- | --- | --- |'])
        for name, fields in items:
            arguments = ' '.join(argument_text(arg) for arg in fields.get('arguments') or [])
            summary = fields.get('summary', '')
            if name == 'script|debug':
                summary = 'Unsupported subcommand; script debugging is unavailable. ' + summary
            elif name.split('|')[0] in ('function', 'cluster', 'sentinel'):
                summary = 'Compatibility entry; excluded execution features remain unavailable. ' + summary
            lines.append('| %s | %s | %s |' % (table_code(name.upper().replace('|', ' ')), table_code(arguments) if arguments else '—', md(summary)))
        lines.append('')
    return '\n'.join(lines).rstrip()


def read_json(path):
    try:
        value = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise ValueError('cannot read JSON input %s: %s' % (path, error)) from error
    if not isinstance(value, dict):
        raise ValueError(str(path) + ' must contain a JSON object')
    return value


def count(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(label + ' must be a non-negative integer')
    return value


def validate_conformance(value, label):
    compact = value.get('schema') == 'eski-docs-conformance-v1'
    if value.get('schema') not in (2, 'eski-docs-conformance-v1') or not isinstance(value.get('units'), dict) or not isinstance(value.get('totals'), dict):
        raise ValueError(label + ' requires a supported conformance summary with units and totals')
    suite = value.get('suite')
    if not isinstance(suite, dict) or suite.get('name') != 'redis' or not isinstance(suite.get('tag'), str) or not suite['tag']:
        raise ValueError(label + ' must identify the Redis test suite')
    if not all(isinstance(name, str) and isinstance(unit, dict) for name, unit in value['units'].items()):
        raise ValueError(label + ' has an invalid unit record')
    if count(value['totals'].get('units_run'), label + ' units run') != len(value['units']):
        raise ValueError(label + ' unit count disagrees with its units')
    for metric in ('passed', 'failed', 'skipped', 'errored'):
        total = count(value['totals'].get(metric), label + ' total ' + metric)
        actual = sum(count(unit.get(metric, 0), label + ' unit ' + metric) for unit in value['units'].values())
        if total != actual:
            raise ValueError(label + ' totals disagree with its units for ' + metric)
    for name, unit in value['units'].items():
        if (not compact and not isinstance(unit.get('tests'), dict)) or not isinstance(unit.get('failures'), list):
            raise ValueError(label + ' unit ' + name + ' lacks test outcomes')
        if any(not isinstance(failure, dict) or not isinstance(failure.get('test'), str) for failure in unit['failures']):
            raise ValueError(label + ' unit ' + name + ' has an invalid failure identity')
        if not compact:
            if not all(isinstance(test, str) and isinstance(outcome, dict) for test, outcome in unit['tests'].items()):
                raise ValueError(label + ' unit ' + name + ' has invalid test outcomes')
        if compact:
            if set(unit) != {'passed', 'failed', 'skipped', 'errored', 'failures'} or len(unit['failures']) != unit['failed']:
                raise ValueError(label + ' compact unit has unexpected fields or failure counts')
            for failure in unit['failures']:
                if set(failure) != {'test', 'category', 'reason'} or not all(isinstance(v, str) for v in failure.values()):
                    raise ValueError(label + ' compact failure must contain an identity, category and authored reason')
    if compact:
        comparison = value.get('baseline')
        if not isinstance(comparison, dict) or not isinstance(comparison.get('regressions'), list) or not re.fullmatch(r'[0-9a-f]{64}', comparison.get('sha256', '')):
            raise ValueError(label + ' lacks a valid recorded baseline comparison')
        recorded = sorted(unit_name + '::' + failure['test'] for unit_name, unit in value['units'].items() for failure in unit['failures'])
        identities = value.get('failing_tests')
        if not isinstance(identities, list) or not all(isinstance(identity, str) for identity in identities) or sorted(identities) != recorded:
            raise ValueError(label + ' failing test identities disagree with its units')
    return value


def json_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def compact_summary(value, baseline):
    if value.get('schema') != 2:
        raise ValueError('--record-conformance requires a raw schema-2 runner result')
    expected, preserved, regressions = preserved_tests(baseline, value)
    units = {}
    for name, unit in sorted(value['units'].items()):
        record = {key: unit[key] for key in ('passed', 'failed', 'skipped', 'errored')}
        record['failures'] = []
        for failure in unit['failures']:
            title = failure['test']
            text = failure_explanation(name, title, str(failure.get('reason', '')))
            category = 'excluded feature' if any(token in text for token in ('excluded', 'outside the single-node scope')) else 'compatibility gap'
            record['failures'].append({'test': title, 'category': category, 'reason': text})
        units[name] = record
    return {'schema': 'eski-docs-conformance-v1', 'generated_at': value.get('generated_at'),
            'source_summary_sha256': json_digest(value), 'source_mode': value.get('mode'),
            'suite': {key: value['suite'][key] for key in ('name', 'tag', 'sha256', 'url', 'tags', 'external_skip_lifted') if key in value['suite']},
            'units': units, 'totals': {key: value['totals'][key] for key in ('units_run', 'passed', 'failed', 'skipped', 'errored')},
            'failing_tests': sorted(name + '::' + failure['test'] for name, unit in units.items() for failure in unit['failures']),
            'baseline': {'sha256': json_digest(baseline), 'units_compared': sorted(baseline['units']), 'baseline_passed': expected,
                         'current_passed': preserved, 'regressions': regressions}}


def preserved_tests(baseline, observed):
    if baseline['suite']['tag'] != observed['suite']['tag'] or baseline['suite'].get('sha256') != observed['suite'].get('sha256'):
        raise ValueError('baseline and observed conformance identify different suites')
    if baseline['suite'].get('tags') != observed['suite'].get('tags'):
        raise ValueError('baseline and observed conformance use different tag filters')
    if baseline.get('schema') != 2:
        raise ValueError('the baseline must be a raw schema-2 runner result')
    if observed.get('schema') == 'eski-docs-conformance-v1':
        comparison = observed['baseline']
        if comparison['sha256'] != json_digest(baseline) or comparison['units_compared'] != sorted(baseline['units']):
            raise ValueError('recorded comparison belongs to another baseline; refresh from a real run')
        expected = count(comparison.get('baseline_passed'), 'recorded baseline passes')
        preserved = count(comparison.get('current_passed'), 'recorded preserved passes')
        if expected != baseline['totals']['passed'] or preserved > expected:
            raise ValueError('recorded baseline comparison has impossible passing counts')
        if not all(isinstance(name, str) for name in comparison['regressions']):
            raise ValueError('recorded regressions must be test identities')
        if bool(expected - preserved) != bool(comparison['regressions']):
            raise ValueError('recorded preserved passes disagree with regressions')
        return expected, preserved, comparison['regressions']
    expected = 0
    preserved = 0
    regressions = []
    for unit_name, unit in baseline['units'].items():
        current = observed['units'].get(unit_name, {}).get('tests', {})
        for name, outcome in unit['tests'].items():
            passed = count(outcome.get('passed', 0), 'baseline test passes')
            expected += passed
            now = count(current.get(name, {}).get('passed', 0), 'observed test passes')
            preserved += min(now, passed)
            if now < passed:
                regressions.append(unit_name + '::' + name)
    if expected != baseline['totals']['passed']:
        raise ValueError('baseline passing test counts disagree with its total')
    return expected, preserved, regressions


def conformance_table(summary):
    lines = ['| Unit | Passed | Failed | Skipped | Unit errors |', '| --- | ---: | ---: | ---: | ---: |']
    for name, unit in sorted(summary['units'].items()):
        lines.append('| %s | %d | %d | %d | %d |' % (md(name), unit['passed'], unit['failed'], unit['skipped'], unit['errored']))
    totals = summary['totals']
    lines.append('| **Total** | **%d** | **%d** | **%d** | **%d** |' % tuple(totals[key] for key in ('passed', 'failed', 'skipped', 'errored')))
    return '\n'.join(lines)


def failure_explanation(unit, name, reason):
    text = (name + ' ' + reason).lower()
    if 'sync' in text or 'replication_stream' in text:
        return 'The test observes a replication stream; replication is outside the single-node scope.'
    if any(token in text for token in ('fcall', 'function load', 'function list', 'function dump',
                                       'function restore', 'function flush', 'function library',
                                       'function libraries', 'library metadata')):
        return 'The test requires executable function libraries, which are excluded.'
    if any(token in text for token in ('eval', 'script')):
        return 'The test exercises Lua scripting; this recorded assertion remains a compatibility gap.'
    if unit == 'introspection-2':
        return 'The recorded command inventory differs; inspect the named assertion and the remaining function/cluster exclusions.'
    if unit == 'querybuf':
        return 'The test assumes reference query-buffer allocation and resize behavior; Eski uses its own buffer policy.'
    if unit == 'info':
        return 'The test assumes reference hash-table allocation sizes; Eski uses a different keyspace representation.'
    if unit == 'other' and 'help' in text:
        return 'The test asks for HELP on an excluded module command.'
    if unit == 'type/list':
        return 'The blocking list operation increased the dirty counter by 3 instead of the expected 2; this remains a compatibility gap.'
    if unit == 'pause':
        return 'The recorded pause/expiry behavior differs; this remains a compatibility gap.'
    return 'A recorded assertion differs; rerun the named unit to inspect its current failure.'


def failure_table(summary):
    lines = ['| Unit and test | Category | Explanation |', '| --- | --- | --- |']
    for unit_name, unit in sorted(summary['units'].items()):
        for failure in unit['failures']:
            name = str(failure.get('test', ''))
            reason = str(failure.get('reason', ''))
            explanation = reason if summary.get('schema') == 'eski-docs-conformance-v1' else failure_explanation(unit_name, name, reason)
            category = failure.get('category', 'recorded difference')
            lines.append('| %s | %s | %s |' % (md(unit_name + '::' + name), md(category), md(explanation)))
    return '\n'.join(lines)


def finite_number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError(label + ' must be a finite non-negative number')
    return float(value)


def benchmark_cells(dataset):
    if dataset.get('schema') != 'eski-testbed-dataset-v1':
        raise ValueError('benchmark data requires eski-testbed-dataset-v1')
    if not isinstance(dataset.get('engines'), list) or not isinstance(dataset.get('workloads'), list) or not isinstance(dataset.get('rows'), list):
        raise ValueError('benchmark data lacks engines, workloads or rows')
    if any(not isinstance(row, dict) for row in dataset['engines'] + dataset['workloads'] + dataset['rows']):
        raise ValueError('benchmark records must be objects')
    if not isinstance(dataset.get('design'), dict) or not all(isinstance(row.get('name'), str) for row in dataset['workloads']):
        raise ValueError('benchmark design and workload names are required')
    method = dataset['design'].get('methodology', {})
    if not isinstance(method, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in method.items()):
        raise ValueError('benchmark methodology must contain named text descriptions')
    engines = [row.get('target') for row in dataset['engines']]
    workloads = [row.get('key') for row in dataset['workloads']]
    if not all(isinstance(name, str) and name for name in engines + workloads) or len(set(engines)) != len(engines) or len(set(workloads)) != len(workloads) or not engines or not workloads:
        raise ValueError('benchmark engines and workloads must be nonempty and unique')
    repetitions = count(dataset.get('design', {}).get('repetitions'), 'benchmark repetitions')
    if not repetitions:
        raise ValueError('benchmark repetitions must be positive')
    cells = {(w, e): {'included': [], 'excluded': [], 'client_limited': 0} for w in workloads for e in engines}
    seen = set()
    for row in dataset['rows']:
        if row.get('phase') != 'benchmark':
            continue
        key = row.get('workload'), row.get('engine')
        repetition = count(row.get('repetition'), 'benchmark repetition')
        identity = key + (repetition,)
        if key not in cells or not 1 <= repetition <= repetitions or identity in seen:
            raise ValueError('benchmark row has unknown or repeated engine/workload/repetition')
        seen.add(identity)
        if not isinstance(row.get('included'), bool):
            raise ValueError('benchmark row lacks an inclusion decision')
        if row['included']:
            if row.get('state') != 'successful' or row.get('integrity') != 'verified':
                raise ValueError('included benchmark rows must be successful and integrity verified')
            if not isinstance(row.get('client_limited'), bool):
                raise ValueError('included benchmark rows require a boolean client_limited annotation')
            for metric in ('ops', 'p99', 'mem'):
                finite_number(row.get(metric), 'benchmark ' + metric)
            cells[key]['included'].append(row)
            cells[key]['client_limited'] += int(bool(row.get('client_limited')))
        else:
            if not isinstance(row.get('reasons'), list) or not row['reasons'] or not all(isinstance(reason, str) and reason for reason in row['reasons']):
                raise ValueError('excluded benchmark row lacks its reasons')
            cells[key]['excluded'].append(row)
    planned = len(engines) * len(workloads) * repetitions
    if len(seen) != planned:
        raise ValueError('benchmark dataset does not contain every planned repetition')
    actual = {'planned': planned, 'valid': sum(len(c['included']) for c in cells.values()), 'excluded': sum(len(c['excluded']) for c in cells.values()), 'client_limited': sum(c['client_limited'] for c in cells.values())}
    if dataset.get('counts') != actual:
        raise ValueError('benchmark counts disagree with row inclusion decisions')
    for cell in cells.values():
        cell['included'].sort(key=lambda row: row['repetition'])
        cell['excluded'].sort(key=lambda row: row['repetition'])
        for metric in ('ops', 'p99', 'mem'):
            values = [float(row[metric]) for row in cell['included']]
            cell[metric] = {'median': statistics.median(values), 'min': min(values), 'max': max(values)} if values else None
    return cells


def engine_label(dataset, engine, versions=False):
    if not versions:
        return ENGINE_LABELS.get(engine['target'], engine['target'])
    return str(engine.get('label') or ENGINE_LABELS.get(engine['target'], engine['target']))


def numeric(value, metric):
    if value is None:
        return '—'
    if metric == 'ops':
        return '{:,.0f}'.format(value)
    if metric == 'mem':
        return '{:.2f}'.format(value / (1024 ** 2))
    return '{:.3f}'.format(value)


def benchmark_table(dataset, cells, brief=False):
    if brief:
        engines = dataset['engines']
        lines = ['| Workload | ' + ' | '.join(engine_label(dataset, engine) + ' ops/s' for engine in engines) + ' |', '| --- | ' + ' | '.join('---:' for _ in engines) + ' |']
        for workload in dataset['workloads']:
            values = []
            for engine in engines:
                cell = cells[(workload['key'], engine['target'])]
                if not cell['ops']:
                    values.append('excluded (%d)' % len(cell['excluded']))
                else:
                    values.append(numeric(cell['ops']['median'], 'ops') + (' †' if cell['client_limited'] else ''))
            lines.append('| %s | %s |' % (md(workload['name']), ' | '.join(values)))
        return '\n'.join(lines)
    lines = ['| Workload | Engine | Valid / planned | Throughput median [min, max], ops/s | p99 median [min, max], ms | Container memory peak median, MiB | Client-limited valid runs |', '| --- | --- | ---: | ---: | ---: | ---: | ---: |']
    planned = dataset['design']['repetitions']
    for workload in dataset['workloads']:
        for engine in dataset['engines']:
            cell = cells[(workload['key'], engine['target'])]
            values = []
            for metric in ('ops', 'p99'):
                stats = cell[metric]
                values.append('%s [%s, %s]' % tuple(numeric(stats[key], metric) for key in ('median', 'min', 'max')) if stats else 'excluded')
            lines.append('| %s | %s | %d / %d | %s | %s | %s | %d |' % (md(workload['name']), md(engine_label(dataset, engine, versions=True)), len(cell['included']), planned, values[0], values[1], numeric(cell['mem']['median'], 'mem') if cell['mem'] else '—', cell['client_limited']))
    return '\n'.join(lines)


def benchmark_ratio(cells):
    subject = cells.get(('get64-p1', 'eski-docker')) or cells.get(('get64-p1', 'eski'))
    reference = cells.get(('get64-p1', 'redis'))
    if not subject or not reference or not subject['ops'] or not reference['ops'] or reference['ops']['median'] <= 0:
        raise ValueError('GET 64 B pipeline 1 ratio needs valid Eski and Redis repetitions')
    return subject['ops']['median'] / reference['ops']['median'], bool(subject['client_limited'] or reference['client_limited'])


def badge(label, value, color):
    left = max(80, len(label) * 6.8 + 16)
    right = max(52, len(value) * 6.8 + 16)
    title = html.escape(label + ': ' + value, quote=True)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%.0f" height="22" role="img" aria-label="%s">\n'
            '<title>%s</title><rect width="%.0f" height="22" rx="3" fill="#4b5563"/>'
            '<path d="M%.0f 0h%.0fv22H%.0fz" fill="%s"/>'
            '<g fill="white" text-anchor="middle" font-family="Verdana,Arial,sans-serif" font-size="11">'
            '<text x="%.1f" y="15">%s</text><text x="%.1f" y="15">%s</text></g>\n</svg>\n') % (
                left+right, title, title, left+right, left, right, left, color, left/2, html.escape(label), left+right/2, html.escape(value))


def replace_blocks(readme, blocks):
    result = readme
    for name in BLOCKS:
        start = '<!-- BEGIN GENERATED ' + name + ' -->'
        end = '<!-- END GENERATED ' + name + ' -->'
        if result.count(start) != 1 or result.count(end) != 1 or result.index(start) >= result.index(end):
            raise ValueError('README requires one ordered marker pair for ' + name)
        first = result.index(start) + len(start)
        last = result.index(end)
        result = result[:first] + '\n\n' + blocks[name].strip() + '\n\n' + result[last:]
    return result


def render_outputs(commands, baseline, observed, dataset, readme):
    expected, preserved, regressions = preserved_tests(baseline, observed)
    cells = benchmark_cells(dataset)
    ratio, limited = benchmark_ratio(cells)
    command_count = len(commands)
    top_count = sum('|' not in name for name in commands)
    digest = hashlib.sha256(json.dumps(commands, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    conformance_block = ('The recorded gate preserves **%d / %d baseline passes** across %d compared units, with **%d regressions**. '
                         'The expanded recorded run has **%d passes, %d failures and %d skips** across %d units. '
                         'Its remaining failures include excluded execution features and compatibility gaps; see the [recorded results and explanations](docs/conformance.md).\n\n%s') % (
                             preserved, expected, len(baseline['units']), len(regressions), observed['totals']['passed'], observed['totals']['failed'], observed['totals']['skipped'], len(observed['units']), conformance_table(baseline))
    benchmark_block = ('Recorded medians from `bench/testbed/runs/comparison-v1`, using valid repetitions only. '
                       'These are measurements from one machine, not a claim about every workload or deployment.\n\n%s\n\n'
                       '† At least one included repetition was client limited. The observed GET 64 B pipeline 1 median throughput ratio '
                       'is **%.2fx Eski / Redis**%s. Client limits affect both measurements, so that ratio is not a guaranteed engine-speed ratio. '
                       'Excluded repetitions receive no inferred score. [Method, ranges, images and exclusions](docs/benchmarks.md).') % (
                           benchmark_table(dataset, cells, brief=True), ratio, ' (client limited)' if limited else '')
    commands_block = ('The running executable registers **%d top-level commands** and **%d commands including subcommands**. '
                      'Compatibility stubs remain subject to the exclusions above. '
                      '[Arguments and metadata summaries](docs/commands.md) come from `COMMAND DOCS`; every name below is cross-checked against `COMMAND LIST`.\n\n%s') % (
                          top_count, command_count, command_table(commands, compact=True))
    commands_page = ('# Command inventory\n\nGenerated from a temporary instance of the built executable using `COMMAND DOCS`, `COMMAND LIST` and `COMMAND COUNT`. '
                     'The inventory contains %d top-level commands and %d names including subcommands. Metadata describes the protocol surface; '
                     'the [command-group pages](README.md) and [conformance record](conformance.md) define implemented behavior and remaining gaps. '
                     'Lua evaluation has the scope documented in [scripting](scripting.md); compatibility entries do not provide executable function libraries, replication or clustering.\n\n'
                     'Regenerate with `python3 -I test/readme_tables.py`; verify with `python3 -I test/readme_tables.py --check`. '
                     'Use `--server HOST:PORT` to inspect an existing instance without starting one. The canonical command-metadata SHA256 is `%s`.\n\n%s\n') % (
                         top_count, command_count, digest, command_table(commands))
    conformance_page = ('# Conformance records\n\nGenerated from `test/conformance/baseline-redis.json` and `docs/data/conformance-redis.json`. '
                        'Both identify the Redis %s test suite, archive SHA256 `%s`, with tag filter `%s`. '
                        'The baseline records %d passes and %d failures in %d units. The expanded snapshot records %d passes, %d failures and %d skips in %d units. '
                        'The baseline gate preserves %d of %d baseline passes, with %d regressions.\n\n'
                        'A baseline PASS checks the preserved passing tests in its compared units. It does not claim that every selected upstream test passes. '
                        'Some upstream tests require excluded features, and others expose the compatibility gaps listed below. '
                        'A unit with zero passing tests does not establish coverage; external-server mode can omit blocks that require suite-managed servers.\n\n'
                        '## Reproduce and refresh\n\n'
                        'Build with `./build.sh`, then run `./test/conformance/run.sh --suite redis --baseline test/conformance/baseline-redis.json`. '
                        'Run `./test/conformance/run.sh --suite redis` without the baseline to apply the strict failure rule. '
                        'Refresh the public snapshot from an actual run with '
                        '`python3 -I test/readme_tables.py --record-conformance test/conformance/results/latest-redis.json`, '
                        'then run `python3 -I test/readme_tables.py --check`. The refresh keeps aggregate counts, exact failing test identities, '
                        'authored reasons and the baseline comparison, while omitting local paths, raw assertion code and stack traces. '
                        'The preserved snapshot was generated at `%s`; reruns can change timings and expose different outcomes.\n\n'
                        '## Baseline units\n\n%s\n\n## Expanded snapshot\n\n%s\n\n## Recorded failures\n\n%s\n') % (
                            baseline['suite']['tag'], baseline['suite']['sha256'], baseline['suite'].get('tags', ''), baseline['totals']['passed'], baseline['totals']['failed'], len(baseline['units']), observed['totals']['passed'], observed['totals']['failed'], observed['totals']['skipped'], len(observed['units']), preserved, expected, len(regressions), observed.get('generated_at', 'not recorded'), conformance_table(baseline), conformance_table(observed), failure_table(observed))
    method = dataset.get('design', {}).get('methodology', {})
    method_text = '\n\n'.join(str(method[key]) for key in sorted(method))
    identities = ['| Engine | Image reference | Measured image ID | Recorded version |', '| --- | --- | --- | --- |']
    for engine in dataset['engines']:
        identities.append('| %s | %s | %s | %s |' % (md(engine_label(dataset, engine, versions=True)), table_code(engine.get('reference', '')), table_code(engine.get('image_id', '')), md(engine.get('version', ''))))
    exclusions = ['| Workload | Engine | Repetition | Reason |', '| --- | --- | ---: | --- |']
    for workload in dataset['workloads']:
        for engine in dataset['engines']:
            for row in cells[(workload['key'], engine['target'])]['excluded']:
                exclusions.append('| %s | %s | %d | %s |' % (md(workload['name']), md(engine_label(dataset, engine)), row['repetition'], md('; '.join(row['reasons']))))
    fill_rows = ['| Engine | Stored keys | RSS bytes/key | Used bytes/key | Container peak bytes/key | Fill ops/s | p99 ms | Worst request ms |', '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for engine in (dataset.get('fill') or {}).get('engines', []):
        if engine.get('status') != 'valid':
            fill_rows.append('| %s | excluded | — | — | — | — | — | — |' % md(ENGINE_LABELS.get(engine.get('target'), engine.get('label', 'unknown'))))
        else:
            fill_rows.append('| %s | %s | %.2f | %.2f | %.2f | %s | %.3f | %.3f |' % (md(ENGINE_LABELS.get(engine['target'], engine['label'])), '{:,}'.format(engine['dbsize']), engine['bytes_per_key_rss'], engine['bytes_per_key_used'], engine['bytes_per_key_cgroup_peak'], numeric(engine['ops_per_sec'], 'ops'), engine['p99_ms'], engine['max_ms']))
    benchmark_page = ('# Recorded benchmark comparison\n\nGenerated from `bench/testbed/runs/comparison-v1/dataset.json`, schema `%s`. '
                      'The benchmark phase contains %d planned repetitions, %d valid, %d excluded and %d included client-limited measurements. '
                      'The medians and ranges below are recomputed from included benchmark rows; calibration and excluded rows do not enter them.\n\n'
                      '## Reproduce the tables\n\nRun `python3 -I test/readme_tables.py --benchmark-results bench/testbed/runs/comparison-v1` '
                      'and verify with `python3 -I test/readme_tables.py --check`. To render the recorded charts and report, run '
                      '`python3 -I bench/testbed/charts.py --dataset bench/testbed/runs/comparison-v1/dataset.json --out bench/testbed/runs/comparison-v1/charts` '
                      'and `python3 -I bench/testbed/page.py --dataset bench/testbed/runs/comparison-v1/dataset.json --out bench/testbed/runs/comparison-v1/report.html`. '
                      'A new physical experiment uses `bench/testbed/design.json` with the plan, install and collection tools described in [build-run-test.md](build-run-test.md). '
                      'It requires a dedicated machine satisfying those gates; generating tables does not launch that experiment. '
                      'The [recorded report](../bench/testbed/runs/comparison-v1/report.html), [dataset](../bench/testbed/runs/comparison-v1/dataset.json) '
                      'and collection receipts are committed together.\n\n'
                      '## Method and machine\n\nMachine: %s; %s RAM; server CPUs `%s`, client CPUs `%s`, controller CPUs `%s`.\n\n%s\n\n'
                      '## Engine identities\n\n%s\n\n## Valid benchmark measurements\n\n%s\n\n'
                      'Each p99 is a per-run percentile; the table takes the median of those percentiles and does not pool requests. '
                      'Container memory peak covers preload, warmup and timing, so it is not process RSS or live key memory. '
                      'Client-limited measurements remain included and annotated. Their observed throughput is limited by the load generator; '
                      'a ratio between two such observations is not a lower bound on the true ratio between the engines. '
                      'The badge reports only GET 64 B at pipeline 1: %.2fx observed Eski/Redis median throughput%s. '
                      'There is no overall cross-workload score.\n\n'
                      '## Excluded repetitions\n\n%s\n\nExcluded values have no median or badge score. '
                      'Each exclusion retains its recorded reason; client_limited is a separate annotation on included measurements.\n\n'
                      '## Fill measurement\n\nThe separate fill workload uses %s generated keys of %s bytes at pipeline %s. '
                      'The stored-key count in the receipt is retained as measured.\n\n%s\n') % (
                          dataset['schema'], dataset['counts']['planned'], dataset['counts']['valid'], dataset['counts']['excluded'], dataset['counts']['client_limited'],
                          dataset.get('machine', {}).get('cpu_model', 'not recorded'), numeric(dataset.get('machine', {}).get('mem_total_bytes', 0), 'mem')+' MiB',
                          ','.join(map(str, dataset.get('machine', {}).get('cpus', {}).get('server', []))), ','.join(map(str, dataset.get('machine', {}).get('cpus', {}).get('client', []))), ','.join(map(str, dataset.get('machine', {}).get('cpus', {}).get('control', []))),
                          method_text, '\n'.join(identities), benchmark_table(dataset, cells), ratio, ' (client limited)' if limited else '', '\n'.join(exclusions),
                          '{:,}'.format((dataset.get('fill') or {}).get('design', {}).get('keys', 0)), (dataset.get('fill') or {}).get('design', {}).get('data_size', 'not recorded'), (dataset.get('fill') or {}).get('design', {}).get('pipeline', 'not recorded'), '\n'.join(fill_rows))
    blocks = {'CONFORMANCE': conformance_block, 'BENCHMARKS': benchmark_block, 'COMMANDS': commands_block}
    updated_readme = replace_blocks(readme, blocks)
    if re.search(r'\b(?:Redis|Valkey|Dragonfly)\s+(?:v?\d|version)', updated_readme, re.I):
        raise ValueError('README must not name competitor server versions')
    return {'README.md': updated_readme, 'docs/commands.md': commands_page, 'docs/conformance.md': conformance_page,
            'docs/benchmarks.md': benchmark_page, 'docs/img/conformance.svg': badge('baseline passes', '%d/%d preserved' % (preserved, expected), '#2f855a' if not regressions else '#b45309'),
            'docs/img/benchmark-ratio.svg': badge('GET 64 B P1 Eski/Redis', '%.2fx observed%s' % (ratio, ', client limited' if limited else ''), '#2563a6')}


def update_outputs(root, outputs, check=False):
    changed = []
    for name, text in outputs.items():
        path = Path(root) / name
        if not path.is_file() or path.read_text() != text:
            changed.append(name)
    if check:
        for name in changed:
            print('stale: ' + name, file=sys.stderr)
        return 1 if changed else 0
    for name in changed:
        path = Path(root) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(outputs[name])
        print('wrote ' + name)
    return 0


def parser():
    result = argparse.ArgumentParser(description='Generate checked documentation from the live command inventory and recorded measurements.')
    result.add_argument('--root', type=Path, default=ROOT, help='checkout root; input/output paths are relative to it')
    result.add_argument('--server-binary', type=Path, default=Path('bin/eski'))
    result.add_argument('--server', metavar='HOST:PORT', help='inspect an existing server instead of starting a temporary one')
    result.add_argument('--baseline', type=Path, default=Path('test/conformance/baseline-redis.json'))
    result.add_argument('--observed-conformance', type=Path, default=Path('docs/data/conformance-redis.json'))
    result.add_argument('--record-conformance', type=Path, help='sanitize an actual run into the observed snapshot before generation')
    result.add_argument('--benchmark-results', type=Path, default=Path('bench/testbed/runs/comparison-v1'))
    result.add_argument('--check', action='store_true', help='exit 1 on drift without rewriting any output')
    return result


def main(argv=None):
    argument_parser = parser()
    args = argument_parser.parse_args(argv)
    if args.check and args.record_conformance:
        argument_parser.error('--check cannot be combined with --record-conformance')
    root = args.root.resolve()
    def resolve(path):
        return path.resolve() if path.is_absolute() else (root/path).resolve()
    try:
        baseline = validate_conformance(read_json(resolve(args.baseline)), 'baseline')
        observed_path = resolve(args.observed_conformance)
        observed = validate_conformance(read_json(resolve(args.record_conformance) if args.record_conformance else observed_path), 'observed conformance')
        if args.record_conformance:
            observed = validate_conformance(compact_summary(observed, baseline), 'observed conformance')
        benchmark_path = resolve(args.benchmark_results)
        if benchmark_path.is_dir():
            benchmark_path /= 'dataset.json'
        dataset = read_json(benchmark_path)
        benchmark_cells(dataset)
        preserved_tests(baseline, observed)
        readme = (root/'README.md').read_text()
        with server_connection(resolve(args.server_binary), args.server) as connection:
            commands = command_inventory(connection)
        outputs = render_outputs(commands, baseline, observed, dataset, readme)
        if args.record_conformance:
            try:
                relative = observed_path.relative_to(root)
            except ValueError as error:
                raise ValueError('observed snapshot output must be inside --root') from error
            outputs[str(relative)] = json.dumps(observed, indent=2, sort_keys=True)+'\n'
        code = update_outputs(root, outputs, args.check)
        if not code:
            print('documentation %s: %d registered command names' % ('is current' if args.check else 'generated', len(commands)))
        return code
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('readme_tables.py: ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
