import argparse
import fcntl
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from kernel_audit import audit as audit_kernel

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(__file__).resolve().parent
SEED = 0x0F7A11E5
CASE_FILES = ['src/ftquery/probe_cases_test.odin', 'src/ftquery/recorded_cases_test.odin']
SCHEMA_FILE = 'src/ftquery/schemas_test.odin'
STOP = {'a', 'is', 'the', 'an', 'and', 'are', 'as', 'at', 'be', 'but', 'by', 'for', 'if', 'in', 'into', 'it', 'no', 'not',
        'of', 'on', 'or', 'such', 'that', 'their', 'then', 'there', 'these', 'they', 'this', 'to', 'was', 'will', 'with'}
AREAS = {
    'lexer': ['Lexer'],
    'parser': ['Tree', 'Parser'],
    'reference': ['Facts'],
}
ROW_AREAS = {'QL': 'lexer', 'QP': 'parser', 'QR': 'reference'}
KIND_NAMES = {'end': 'End', 'term': 'Term', 'stop': 'Stopword', 'pre': 'Prefix', 'suf': 'Suffix', 'inf': 'Infix',
              'or': 'Or', 'minus': 'Minus', 'tilde': 'Tilde', 'lp': 'Lp', 'rp': 'Rp'}
PUNCT = {'(': 'lp', ')': 'rp', '|': 'or', '~': 'tilde', '-': 'minus'}
NESTING = 24


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def lower_run(q, i):
    j = i
    while j < len(q) and 'a' <= q[j] <= 'z':
        j += 1
    return j


def lex(q, stop_terms=False):
    toks, i, near, last = [], 0, '', 0
    while True:
        if i >= len(q):
            toks.append(('end', last, '', near))
            return toks
        c = q[i]
        if c in ' ,':
            i += 1
            continue
        if c in PUNCT:
            toks.append((PUNCT[c], i, '', near))
            last = i
            i += 1
            continue
        if c == '*':
            j = lower_run(q, i + 1)
            if j == i + 1:
                return None
            raw = q[i + 1:j]
            kind = 'inf' if j < len(q) and q[j] == '*' else 'suf'
            toks.append((kind, i, raw, raw))
            near, last, i = raw, i, j + 1 if kind == 'inf' else j
            continue
        if 'a' <= c <= 'z':
            j = lower_run(q, i)
            raw = q[i:j]
            if raw.startswith('inf') or raw == 'ismissing':
                return None
            if j < len(q) and q[j] == '*':
                toks.append(('pre', i, raw, raw))
                near, last, i = raw, i, j + 1
                continue
            toks.append(('stop' if raw in STOP and not stop_terms else 'term', i, raw, raw))
            near, last, i = raw, i, j
            continue
        return None


class Failure(Exception):
    def __init__(self, tok):
        super().__init__()
        self.pos, self.near = tok[1], tok[3]


def rule_power(d, rule):
    if d < 2:
        return {'none': 0, 'opt': 10, 'not': 20, 'and': 30, 'or': 40}[rule]
    return {'none': 0, 'or': 10, 'and': 20, 'not': 20, 'opt': 20}[rule]


def tok_power(d, kind, variant):
    if d < 2:
        return {'tilde': 10, 'minus': 20, 'term': 30, 'stop': 30, 'pre': 30, 'suf': 30, 'inf': 30, 'lp': 30, 'or': 40}.get(kind, 0)
    pattern = 20 if variant == 'patterns_as_terms' else 30
    return {'or': 10, 'term': 20, 'stop': 20, 'lp': 20, 'minus': 20, 'tilde': 20, 'pre': pattern, 'suf': pattern,
            'inf': pattern}.get(kind, 0)


class Parser:
    def __init__(self, toks, d, variant=None):
        self.toks, self.at, self.d, self.variant = toks, 0, d, variant

    def peek(self):
        return self.toks[self.at]

    def adv(self):
        if self.toks[self.at][0] != 'end':
            self.at += 1

    def merge(self, kind, left, right):
        if left == ('null',):
            return right
        if right == ('null',):
            return left
        if left[0] == kind:
            return (kind, left[1] + [right])
        if self.d >= 2 and right[0] == kind and self.variant != 'no_right_merge':
            return (kind, right[1] + [left])
        return (kind, [left, right])

    def expr(self, rule):
        left = self.unary()
        rbp = rule_power(self.d, rule)
        while True:
            kind = self.peek()[0]
            if tok_power(self.d, kind, self.variant) <= rbp:
                return left
            if kind == 'or' and self.d >= 2:
                self.adv()
                result = self.merge('union', left, self.expr('or'))
                while self.peek()[0] == 'or':
                    self.adv()
                    result = self.merge('union', result, self.expr('or'))
                left = result
            elif kind == 'or':
                self.adv()
                left = self.merge('union', left, self.expr('or'))
            else:
                left = self.merge('inter', left, self.expr('and'))

    def unary(self):
        tok = self.peek()
        kind = tok[0]
        if kind == 'minus':
            self.adv()
            child = self.expr('not')
            if child == ('null',):
                return child
            if child[0] == 'not' and self.variant != 'keep_double_negation':
                return child[1]
            return ('not', child)
        if kind == 'tilde':
            self.adv()
            child = self.expr('opt')
            return child if child == ('null',) else ('opt', child)
        if kind == 'lp':
            self.adv()
            inner = self.expr('none')
            if self.peek()[0] != 'rp':
                raise Failure(self.peek())
            self.adv()
            return inner
        if kind == 'term':
            self.adv()
            if self.d < 2 and self.peek()[0] == 'term' and self.variant != 'no_term_groups':
                group = [('tok', tok[2])]
                while self.peek()[0] == 'term':
                    group.append(('tok', self.peek()[2]))
                    self.adv()
                return ('inter', group)
            return ('tok', tok[2])
        if kind == 'stop':
            self.adv()
            return ('null',)
        if kind in ('pre', 'suf', 'inf'):
            self.adv()
            return (kind, tok[2])
        raise Failure(tok)


def explain(node, depth=0):
    pad = '  ' * depth
    kind = node[0]
    if kind == 'null':
        return [pad + '<empty>']
    if kind == 'tok':
        return [pad + node[1]]
    if kind == 'pre':
        return [pad + 'PREFIX{' + node[1] + '*}']
    if kind == 'suf':
        return [pad + 'SUFFIX{*' + node[1] + '}']
    if kind == 'inf':
        return [pad + 'INFIX{*' + node[1] + '*}']
    head = {'union': 'UNION {', 'inter': 'INTERSECT {', 'not': 'NOT{', 'opt': 'OPTIONAL{'}[kind]
    children = node[1] if kind in ('union', 'inter') else [node[1]]
    lines = [pad + head]
    for c in children:
        lines.extend(explain(c, depth + 1))
    return lines + [pad + '}']


def outcome(q, d, variant=None):
    toks = lex(q, stop_terms=variant == 'stop_words_kept')
    if toks is None:
        return 'unsupported'
    if variant == 'end_at_length':
        toks[-1] = (toks[-1][0], len(q), toks[-1][2], toks[-1][3])
    if toks[0][0] == 'end':
        return 'ok|<empty>/'
    p = Parser(toks, d, variant)
    try:
        root = p.expr('none')
        if p.peek()[0] != 'end':
            raise Failure(p.peek())
    except Failure as e:
        return f'err|SEARCH_SYNTAX Syntax error at offset {e.pos} near {e.near}'
    return 'ok|' + ''.join(line + '/' for line in explain(root))


def lex_row(q):
    return 'QL|' + ','.join(f'{KIND_NAMES[k]}:{p}:{t}:{n}' for k, p, t, n in lex(q))


def unescape(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\'}.get(s[i + 1], '\\' + s[i + 1]))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return ''.join(out)


def recorded_cases():
    custom = set()
    for line in (ROOT / SCHEMA_FILE).read_text().split('\n'):
        m = re.match(r'^\t\{"(\w+)", (true|false),', line)
        if m and m.group(2) == 'true':
            custom.add(m.group(1))
    pattern = re.compile(r'^\t\{(\d+), "(\w+)", "((?:[^"\\]|\\.)*)", (\d+), (true|false), "([^"]*)", \{([^}]*)\}, '
                         r'"((?:[^"\\]|\\.)*)", (true|false), (true|false)\},$')
    cases, seen = [], set()
    for name in CASE_FILES:
        for line in (ROOT / name).read_text().split('\n'):
            m = pattern.match(line)
            if not m:
                continue
            _, index, query, dialect, verbatim, _, params, want, is_error, _ = m.groups()
            query, want = unescape(query), unescape(want)
            if verbatim != 'true' or params.strip() or index in custom or not re.fullmatch(r'[a-z |~()*,-]*', query):
                continue
            if lex(query) is None or (query, int(dialect)) in seen or sum(query.count(c) for c in '(-~|') > NESTING:
                continue
            seen.add((query, int(dialect)))
            text = ('err|' + want) if is_error == 'true' else 'ok|' + want.replace('\n', '/')
            cases.append((query, int(dialect), text))
    return cases


def corpus():
    rng = random.Random(SEED)
    lines, expected = [], []
    stats = {kind: 0 for kind in ROW_AREAS}
    extra = {}

    def emit(line, row):
        lines.append(line)
        expected.append(row)
        stats[line.split(' ')[0]] += 1

    words = ['x', 'y', 'z', 'q', 'hello', 'world', 'redis', 'fox', 'dog', 'run', 'ab', 'zz', 'quick', 'brown']
    stops = sorted(STOP)

    def word():
        r = rng.randrange(10)
        if r < 6:
            return rng.choice(words)
        if r < 8:
            return rng.choice(stops)
        return ''.join(rng.choice('bcdeghjklmopqrsuvwxyz') for _ in range(rng.randrange(1, 5)))

    def atom():
        r = rng.randrange(12)
        if r < 8:
            return word()
        if r < 10:
            return word() + '*'
        if r < 11:
            return '*' + word()
        return '*' + word() + '*'

    def build(depth):
        r = rng.randrange(10)
        if depth <= 0 or r < 3:
            return atom()
        if r < 5:
            return ' '.join(build(depth - 1) for _ in range(rng.randrange(2, 4)))
        if r < 7:
            return rng.choice([' | ', '|', ' |']).join(build(depth - 1) for _ in range(rng.randrange(2, 4)))
        if r < 8:
            return '-' + build(depth - 1)
        if r < 9:
            return '~' + build(depth - 1)
        return '(' + build(depth - 1) + ')'

    def noisy(q):
        out = []
        for c in q:
            r = rng.randrange(60)
            if r == 0:
                out.append(rng.choice(['(', ')', '|', '-', '~']))
            elif r == 1:
                continue
            elif r == 2:
                out.append(',')
            out.append(c)
        return ''.join(out)

    queries = ['', ' ', 'x', 'the', 'x y', '-x y', '~x y', 'x | y z', 'x y | z', 'x | y | z', 'x (y z)', '(x y) z', '-x y*',
               'x the y', '--x', '---x', 'x -(y | z)', '*xy* *z q*', '(x', 'x )', 'x |', '| x', '-', '~', '()', '(x))',
               'x,y', 'x-y', 'x~y', 'x|y', '-(x)', '~(x | y)', 'the | x', 'x | the', '-the', '~the', '(the)', 'x* y*',
               'x y z q', '-x -y', '~x ~y z', 'x | -y', 'x | ~y', '(x | y) (z | q)', 'x (y | z) q']
    for _ in range(4000):
        q = build(rng.randrange(1, 5))
        queries.append(noisy(q) if rng.randrange(4) == 0 else q)
    kept = 0
    for q in queries:
        if lex(q) is None:
            continue
        kept += 1
        for d in (1, 2) if rng.randrange(5) else (1, 2, 3):
            emit(f'QP {d} {q.encode().hex() or "-"}', 'QP|' + outcome(q, d))
        if rng.randrange(4) == 0:
            emit(f'QL 2 {q.encode().hex() or "-"}', lex_row(q))
    extra['generated_queries'] = kept
    recorded = recorded_cases()
    disagreements = []
    for q, d, want in recorded:
        got = outcome(q, d)
        if got != want:
            disagreements.append((q, d, want, got))
        emit(f'QR {d} {q.encode().hex() or "-"}', 'QR|' + want)
    if disagreements:
        raise AssertionError('model disagrees with recorded reference: ' + repr(disagreements[:5]))
    extra['recorded_reference_cases'] = len(recorded)
    for kind, count in stats.items():
        if count == 0:
            raise AssertionError('corpus has no ' + kind + ' rows')
    return '\n'.join(lines) + '\n', expected, stats, extra


def compare(label, got, want):
    rows = got.splitlines()
    if not want or len(rows) != len(want):
        raise AssertionError(f'{label}: {len(rows)} rows, expected {len(want)}')
    for i, (a, b) in enumerate(zip(rows, want)):
        if a != b:
            raise AssertionError(f'{label}: row {i}: {a[:300]!r} != {b[:300]!r}')


def check_fingerprints():
    pinned = json.loads((PACKAGE / 'source-sha256.json').read_text())
    if len(pinned) < 8:
        raise AssertionError('missing source drift gates')
    for name, wanted in pinned.items():
        if digest(ROOT / name) != wanted:
            raise AssertionError(f'source changed: {name}; reconcile the model before updating its gate')
    return pinned


def find_odin(env, explicit):
    candidates = [explicit, os.environ.get('ODIN'), shutil.which('odin', path=env.get('PATH')),
                  str(Path.home() / 'odin/current/odin')]
    for c in candidates:
        if c and Path(c).is_file() and os.access(c, os.X_OK):
            return str(Path(c).resolve())
    raise AssertionError('Odin compiler not found; use --odin, ODIN, PATH or ~/odin/current/odin')


def build(output, lean_bin, odin_path):
    env = dict(os.environ, LEAN_NUM_THREADS='1')
    if lean_bin:
        env['PATH'] = str(lean_bin.resolve()) + os.pathsep + env.get('PATH', '')
    lake = shutil.which('lake', path=env.get('PATH'))
    lean = shutil.which('lean', path=env.get('PATH'))
    if not lake or not lean:
        raise AssertionError('Lean 4.35.0 and Lake must be available; use --lean-bin or LEAN_BIN_DIR')
    odin = find_odin(env, odin_path)
    version = subprocess.run([lean, '--version'], cwd=PACKAGE, env=env, text=True, capture_output=True, check=True).stdout
    if not re.search(r'\bversion 4\.35\.0\b', version):
        raise AssertionError(f'expected pinned Lean 4.35.0: {version}')
    odin_version = subprocess.run([odin, 'version'], env=env, text=True, capture_output=True, check=True).stdout
    commands = [([lake, 'build'], PACKAGE),
                ([odin, 'build', str(PACKAGE / 'bridge.odin'), '-file', '-out:' + str(output / 'odin_bridge'),
                  '-thread-count:2', '-vet', '-strict-style'], ROOT)]
    lock = ROOT / '.build/proofs/compiler.lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    logs = []
    with lock.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        for command, cwd in commands:
            result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
            logs.append(result.stdout + result.stderr)
            (output / 'build.txt').write_text('\n'.join(logs))
            if result.returncode:
                raise AssertionError(f'build failed; see {output / "build.txt"}\n{logs[-1][-4000:]}')
        axioms, kernel = audit_kernel(Path(lake), PACKAGE, output, env, 'Queries')
    versions = {'lean': version.strip(), 'odin': odin_version.strip()}
    tools = {name: digest(Path(path)) for name, path in (('lean', lean), ('lake', lake), ('odin', odin))}
    return PACKAGE / '.lake/build/bin/query_model', output / 'odin_bridge', axioms, kernel, versions, tools


def negative_controls(lines, expected):
    cases = {'empty': '', 'truncated': '\n'.join(expected[:-1]) + '\n',
             'extra': '\n'.join(expected + [expected[0]]) + '\n'}
    kinds = {}
    for i, row in enumerate(expected):
        kinds.setdefault(row.split('|')[0], i)
    for kind, i in sorted(kinds.items()):
        cells = expected[i].split('|')
        for column in range(1, len(cells)):
            mutated = list(expected)
            mutant = list(cells)
            mutant[column] = 'controlled-mutant'
            mutated[i] = '|'.join(mutant)
            cases[f'{kind}_column_{column}'] = '\n'.join(mutated) + '\n'

    def query_of(i):
        f = lines[i].split(' ')
        return (bytes.fromhex(f[2]).decode() if f[2] != '-' else ''), int(f[1])

    semantic = {}
    for variant in ('no_right_merge', 'no_term_groups', 'patterns_as_terms', 'keep_double_negation', 'stop_words_kept',
                    'end_at_length'):
        semantic[variant] = lambda i, v=variant: lines[i].split(' ')[0] + '|' + outcome(*query_of(i), variant=v)
    for name, mutate in semantic.items():
        index = next((i for i, line in enumerate(lines) if line.startswith(('QP ', 'QR ')) and mutate(i) != expected[i]), None)
        if index is None:
            raise AssertionError('no row for semantic negative control ' + name)
        mutated = list(expected)
        mutated[index] = mutate(index)
        cases['semantic_' + name] = '\n'.join(mutated) + '\n'
    rejected = []
    for name, mutant in cases.items():
        try:
            compare(name, mutant, expected)
        except AssertionError:
            rejected.append(name)
        else:
            raise AssertionError('negative control accepted: ' + name)
    return rejected


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument('--lean-bin', type=Path, default=Path(os.environ['LEAN_BIN_DIR']) if 'LEAN_BIN_DIR' in os.environ else None)
    parser.add_argument('--odin', default=None)
    parser.add_argument('--output', type=Path, default=PACKAGE / '.build')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    output = args.output.resolve()
    (output / 'receipt.json').unlink(missing_ok=True)
    if hasattr(os, 'sched_getaffinity'):
        os.sched_setaffinity(0, {min(os.sched_getaffinity(0))})
    if hasattr(os, 'nice'):
        os.nice(10)
    fingerprints = check_fingerprints()
    lean_model, odin_bridge, axioms, kernel, versions, tools = build(output, args.lean_bin, args.odin)
    trace, expected, stats, extra = corpus()
    lines = trace.splitlines()
    path = output / 'cases.txt'
    path.write_text(trace)
    results = {}
    for name, binary in (('lean', lean_model), ('odin', odin_bridge)):
        result = subprocess.run([str(binary.resolve()), str(path)], text=True, capture_output=True)
        if result.returncode or result.stderr:
            raise AssertionError(f'{name}: exit {result.returncode}, stderr: {result.stderr[-2000:]}')
        (output / f'{name}-results.txt').write_text(result.stdout)
        compare(name, result.stdout, expected)
        results[name] = hashlib.sha256(result.stdout.encode()).hexdigest()
    if results['lean'] != results['odin']:
        raise AssertionError('Lean oracle and Odin rows differ')
    rejected = negative_controls(lines, expected)
    modules = {module: set(re.findall(r"^theorem\s+([\w']+)", (PACKAGE / f'Queries/{module}.lean').read_text(), re.M))
               for files in AREAS.values() for module in files}
    comparisons = {area: sum(count for kind, count in stats.items() if ROW_AREAS[kind] == area) for area in AREAS}
    if any(not comparisons[area] for area in AREAS):
        raise AssertionError('every area needs comparison rows')
    area_evidence = {area: {'theorems': sorted(name for name in axioms
                                               if name.removeprefix('Queries.') in set().union(*(modules[m] for m in files))),
                            'comparisons': comparisons[area]}
                     for area, files in AREAS.items()}
    if any(not evidence['theorems'] for evidence in area_evidence.values()):
        raise AssertionError('every area needs named theorems in the manifest')
    receipt = {'rows': stats, 'details': extra, 'total_rows': len(expected), 'seed': hex(SEED),
               'toolchain': (PACKAGE / 'lean-toolchain').read_text().strip(),
               'area_evidence': area_evidence, 'checked_theorem_axioms': axioms,
               'kernel_inventory_sha256': digest(output / 'kernel-inventory.json'),
               'kernel_checked_theorems': len(kernel['theorem_axioms']),
               'source_sha256': fingerprints, 'versions': versions, 'tool_sha256': tools,
               'trace_sha256': hashlib.sha256(trace.encode()).hexdigest(), 'results_sha256': results,
               'executable_sha256': {'lean': digest(lean_model), 'odin': digest(odin_bridge)},
               'proof_source_sha256': {str(p.relative_to(PACKAGE)): digest(p) for p in sorted(PACKAGE.rglob('*'))
                                       if p.is_file() and not {'.lake', '.build', '__pycache__'} & set(p.parts)},
               'negative_controls_rejected': rejected,
               'odin_correspondence': 'finite implementation comparisons; no verified translation'}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    summary = {'rows': stats, 'details': extra, 'total_rows': len(expected), 'theorems': len(axioms),
               'kernel_checked_theorems': receipt['kernel_checked_theorems'],
               'negative_controls_rejected': len(rejected), 'receipt': str(output / 'receipt.json')}
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    run()
