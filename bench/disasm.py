import argparse
import collections
import difflib
import re
import subprocess
import sys

HOT = ('db_find_in', 'db_upsert_in', 'db_remove_in', 'table_find_slow', 'entry_store', 'entry_append', 'entry_assign', 'key_store',
       'key_set_deadline', 'entry_heap_close', 'entry_object_attach', 'val_release', 'db_erase', 'db_expire_scan', 'db_rehash_groups',
       'table_detach', 'lazyfree_run', 'cmd_get', 'cmd_set')


def symbols(binary):
    out = subprocess.run(['nm', '--defined-only', binary], capture_output=True, text=True, check=True).stdout
    names = set()
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1] in ('t', 'T'):
            names.add(parts[2])
    return names


def resolve(names, short):
    if short in names:
        return short
    if 'main::' + short in names:
        return 'main::' + short
    found = sorted(n for n in names if n.endswith('::' + short))
    return found[0] if found else None


def disassemble(binary, symbol):
    out = subprocess.run(['objdump', '-d', '--no-show-raw-insn', '-M', 'att', '--disassemble=' + symbol, binary],
                         capture_output=True, text=True, check=True).stdout
    lines = []
    inside = False
    for line in out.splitlines():
        if line.endswith('>:') and '<' + symbol + '>' in line:
            inside = True
            continue
        if inside:
            if not line.strip():
                if lines:
                    break
                continue
            m = re.match(r'\s*[0-9a-f]+:\s*(.*)$', line)
            if m:
                lines.append(m.group(1).strip())
    return lines


def normalise(ins):
    ins = re.sub(r'#.*$', '', ins).strip()
    ins = re.sub(r'\b[0-9a-f]+ <([^>+]+)(\+0x[0-9a-f]+)?>', r'<\1>', ins)
    ins = re.sub(r'-?0x[0-9a-f]+\(', 'D(', ins)
    ins = re.sub(r'\$-?0x[0-9a-f]+', '$I', ins)
    return ins


class Pair:
    def __init__(self, a, b):
        self.a = a
        self.b = b
        self.names = (symbols(a), symbols(b))

    def code(self, short):
        sa = resolve(self.names[0], short)
        sb = resolve(self.names[1], short)
        return (disassemble(self.a, sa) if sa else None), (disassemble(self.b, sb) if sb else None)


def compare(pair, procs):
    for p in procs:
        a, b = pair.code(p)
        if a is None or b is None:
            print('%-24s %s' % (p, 'absent in ' + ' and '.join(n for n, x in (('A', a), ('B', b)) if x is None)))
            continue
        na = [normalise(x) for x in a]
        nb = [normalise(x) for x in b]
        shape = na == nb
        changed = 0
        if not shape:
            sm = difflib.SequenceMatcher(a=na, b=nb, autojunk=False)
            changed = sum(max(i2 - i1, j2 - j1) for tag, i1, i2, j1, j2 in sm.get_opcodes() if tag != 'equal')
        displaced = sum(1 for x, y in zip(a, b) if x != y) if shape else -1
        print('%-24s A=%5d B=%5d same_shape=%-5s identical=%-5s displacement_changes=%d changed_instructions=%d' % (
            p, len(a), len(b), shape, a == b, displaced, changed))


def diff(pair, proc, context):
    a, b = pair.code(proc)
    if a is None or b is None:
        raise SystemExit('%s is absent in one of the binaries' % proc)
    sm = difflib.SequenceMatcher(a=[normalise(x) for x in a], b=[normalise(x) for x in b], autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            continue
        print('--- %s A[%d:%d] B[%d:%d]' % (tag, i1, i2, j1, j2))
        for x in a[max(i1 - context, 0):i2 + context]:
            print('  A  ' + x)
        for x in b[max(j1 - context, 0):j2 + context]:
            print('  B  ' + x)


def net(pair, procs):
    for p in procs:
        a, b = pair.code(p)
        if a is None or b is None:
            print('%s: absent in one of the binaries' % p)
            continue
        ca = collections.Counter(normalise(x) for x in a)
        cb = collections.Counter(normalise(x) for x in b)
        added = cb - ca
        removed = ca - cb
        print('%s: %d -> %d instructions; added %d, removed %d' % (p, len(a), len(b), sum(added.values()), sum(removed.values())))
        for ins, n in sorted(added.items()):
            print('   + %d x %s' % (n, ins))
        for ins, n in sorted(removed.items()):
            print('   - %d x %s' % (n, ins))


def main():
    ap = argparse.ArgumentParser(description='Compare the machine code of procedures between two Eski binaries. Load does not '
                                 'affect it, so it judges a hot-path change while timing is not trusted.')
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name in ('compare', 'net'):
        p = sub.add_parser(name)
        p.add_argument('a')
        p.add_argument('b')
        p.add_argument('procs', nargs='*', help='procedure names (default: the store and command hot paths)')
    p = sub.add_parser('diff')
    p.add_argument('a')
    p.add_argument('b')
    p.add_argument('proc')
    p.add_argument('--context', type=int, default=2)
    args = ap.parse_args()
    pair = Pair(args.a, args.b)
    if args.cmd == 'compare':
        compare(pair, args.procs or HOT)
    elif args.cmd == 'net':
        net(pair, args.procs or HOT)
    else:
        diff(pair, args.proc, args.context)


if __name__ == '__main__':
    sys.exit(main())
