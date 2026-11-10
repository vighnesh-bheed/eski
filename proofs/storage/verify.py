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
MAX = (1 << 63) - 1
MASK = (1 << 64) - 1


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def key_text(key):
    return f'{key:07d}' if key < 10 ** 7 else f'{key:012d}'


def key_hash(key):
    data = key_text(key).encode()
    n = len(data)
    assert 4 <= n <= 16
    q = (n >> 3) << 2
    word = lambda at: int.from_bytes(data[at:at + 4], 'little')
    a = (word(0) << 32) | word(q)
    b = (word(n - 4) << 32) | word(n - 4 - q)
    product = (a ^ 0x8BB84B93962EACC9) * b
    lo, hi = product & MASK, product >> 64
    product = (lo ^ 0x2D358DCCAA6C78A5 ^ len(data)) * (hi ^ 0x8BB84B93962EACC9)
    return ((product & MASK) ^ (product >> 64)) & MASK


WORD = 1 << 64
ROLE_HEAP = 4
HEAP_TABLE_MAX = 1024
SYNC_CAP = 1024


def home_of(h, groups):
    return (h * groups) >> 64


def probe(groups, home):
    span = 1
    while span < groups:
        span *= 2
    for step in range(span):
        group = (home + step * (step + 1) // 2) % span
        if group < groups:
            yield group


def grow_cap(cap):
    return max(cap + 16, (cap * 3 // 2 + 15) // 16 * 16)


def round_cap(n):
    return max(16, (n + 15) // 16 * 16)


def heap_table(heap, cap):
    return heap and 0 < cap <= HEAP_TABLE_MAX


def table_bytes(cap, heap=False):
    if cap == 0:
        return 0
    exact = (cap + 63) // 64 * 64 + cap * 18
    return exact if heap_table(heap, cap) else (exact + 4095) // 4096 * 4096


def mapped_bytes(cap, heap):
    return 0 if heap_table(heap, cap) else table_bytes(cap)


def key_form(heap, length, timed):
    if not timed and length <= 7:
        return 'i'
    if heap:
        return 'h'
    return 's' if length + (8 if timed else 0) <= 4096 else 'h'


def cell_bytes(heap, length, timed):
    if heap:
        return length + 16 if timed else 0 if length <= 7 else length + 8
    if timed:
        return length + 8 if length + 8 <= 4096 else length + 16
    return 0 if length <= 7 else length if length <= 4096 else length + 8


def group_floor(groups, g):
    return 0 if g == 0 or g >= groups else (g * WORD + groups - 1) // groups


def cell_text(cell, heap):
    if cell is None:
        return '-'
    if cell is False:
        return 'x'
    key, _, value, deadline, clock = cell
    form = key_form(heap, len(key_text(key)), bool(deadline))
    return f'{key}:{value}:{clock}:{form}' + (f't{deadline}' if deadline else 'u')


def table_text(slots, heap):
    live = sum(isinstance(c, tuple) for c in slots)
    tombs = sum(c is False for c in slots)
    cap = len(slots)
    kind = '-' if cap == 0 else 'h' if heap_table(heap, cap) else 'm'
    return (f'{cap},{live},{tombs},{cap - cap // 8 - live - tombs},{kind};' +
            ','.join(cell_text(c, heap) for c in slots))


def take_home(slots, home):
    groups = len(slots) // 16
    offered = []
    for g in probe(groups, home):
        group = slots[g * 16:(g + 1) * 16]
        offered.extend(c[0] for c in group if isinstance(c, tuple) and home_of(c[1], groups) == home)
        if any(c is None for c in group):
            break
    return offered


def corpus():
    rng = random.Random(0xE5A1506)
    lines, expected = [], []
    stats = {'table_operations': 0, 'accounting_operations': 0, 'scan_rounds': 0, 'scan_iterations': 0,
             'scan_keys_checked': 0, 'resizes': 0, 'growth_rule_resizes': 0, 'shrink_rule_resizes': 0,
             'non_power_of_two_tables': 0, 'partial_batches': 0, 'zero_budget_batches': 0, 'queries': 0,
             'deletions': 0, 'timed_insertions': 0, 'deadline_set': 0, 'deadline_cleared': 0,
             'deadline_rewritten': 0, 'same_home_and_tag_keys': 0, 'rollback_record_seed_failures': 0,
             'rejected_free_ownership_checks': 0, 'heap_role_operations': 0, 'heap_key_insertions': 0,
             'twelve_byte_insertions': 0, 'untimed_slab_key_insertions': 0, 'heap_tables': 0,
             'mapped_tables_under_heap_role': 0, 'crossings_to_mapped': 0, 'crossings_to_heap': 0,
             'production_begins': 0, 'production_make_rooms': 0, 'synchronous_migrations': 0,
             'short_timed_heap_hits': 0}
    src, dst, cursor, logical, role = [], [], -1, {}, 0
    tokens, limit, initialized = {}, 0, False
    scan = {'cursor': None, 'returned': set(), 'stable': None}

    def heap():
        return bool(role & ROLE_HEAP)

    def claim(slots, entry):
        groups = len(slots) // 16
        for group in probe(groups, home_of(entry[1], groups)):
            for i in range(group * 16, (group + 1) * 16):
                if not isinstance(slots[i], tuple):
                    slots[i] = entry
                    return
        raise AssertionError('invalid corpus destination capacity')

    def note_table(cap):
        if heap():
            stats['heap_tables' if heap_table(True, cap) else 'mapped_tables_under_heap_role'] += 1

    def allocate(cap):
        nonlocal dst, cursor
        assert cursor < 0 and cap % 16 == 0 and cap >= 16
        assert len(logical) <= cap * 7 // 8
        groups = cap // 16
        if groups & (groups - 1):
            stats['non_power_of_two_tables'] += 1
        if heap() and heap_table(True, len(src)) != heap_table(True, cap):
            stats['crossings_to_heap' if heap_table(True, cap) else 'crossings_to_mapped'] += 1
        note_table(cap)
        dst, cursor = [None] * cap, 0
        stats['resizes'] += 1

    def migrate(max_groups, want):
        nonlocal src, dst, cursor
        if want == 0 or max_groups == 0:
            stats['zero_budget_batches'] += 1
        if cursor >= 0:
            moved = visited = 0
            groups = len(src) // 16
            while cursor < groups and moved < want and visited < max_groups:
                occupied = [i for i in range(cursor * 16, (cursor + 1) * 16)
                            if isinstance(src[i], tuple)]
                chosen = occupied[:want - moved]
                for i in chosen:
                    claim(dst, src[i])
                    src[i] = False
                moved += len(chosen)
                if len(chosen) < len(occupied):
                    stats['partial_batches'] += 1
                    break
                cursor += 1
                visited += 1
            if cursor >= groups or not any(isinstance(c, tuple) for c in src):
                src, dst, cursor = dst, [], -1

    def begin(cap):
        sync = len(src) <= SYNC_CAP
        allocate(cap)
        if sync:
            stats['synchronous_migrations'] += 1
            migrate(MAX, MAX)
            assert cursor == -1

    def scan_round(at):
        if cursor < 0:
            groups = len(src) // 16
            home = home_of(at, groups)
            return take_home(src, home), group_floor(groups, home + 1)
        narrow, wide = (dst, src) if len(dst) // 16 < len(src) // 16 else (src, dst)
        home = home_of(at, len(narrow) // 16)
        following = group_floor(len(narrow) // 16, home + 1)
        offered = take_home(narrow, home)
        for g in range(home_of(at, len(wide) // 16), home_of((following - 1) % WORD, len(wide) // 16) + 1):
            offered.extend(take_home(wide, g))
        return offered, following

    def step(code, *args):
        nonlocal src, dst, cursor, logical, role, tokens, limit, initialized
        lines.append(' '.join(map(str, (code,) + args)))
        if code == 'R':
            src, dst, cursor, logical, role = [None] * args[0], [], -1, {}, args[1]
            groups = args[0] // 16
            if groups & (groups - 1):
                stats['non_power_of_two_tables'] += 1
            note_table(args[0])
            scan['cursor'] = None
            return
        if code == 'A':
            assert not tokens
            limit, initialized = args[0], bool(args[1])
            return
        if code in ('E', 'P', 'L', 'F', 'N', 'W', 'Z'):
            ok = False
            used = sum(tokens.values())
            if code in ('E', 'P'):
                ident, size = args
                assert ident not in tokens
                charge = size + 32 if code == 'P' else size
                valid = size > 0 and size <= MAX - 32 if code == 'P' else size >= 0
                ok = initialized and valid and charge <= limit - used
                if ok:
                    tokens[ident] = charge
            elif code in ('L', 'F'):
                ok = args[0] in tokens
                if ok:
                    del tokens[args[0]]
            elif code in ('W', 'Z'):
                assert args[0] in tokens
                stats['rejected_free_ownership_checks'] += 1
            else:
                assert used == 0
                stats['rollback_record_seed_failures'] += 1
            expected.append(f'K|{int(ok)}|{sum(tokens.values())}')
            stats['accounting_operations'] += 1
            return
        if code == 'S':
            assert args[0] == (scan['cursor'] or 0)
            offered, following = scan_round(args[0])
            if args[0] == 0:
                scan['returned'], scan['stable'] = set(), set(logical)
            scan['returned'].update(offered)
            scan['stable'] &= set(logical)
            if following == 0:
                assert scan['stable'] <= scan['returned'], 'scan missed a key present throughout'
                stats['scan_iterations'] += 1
                stats['scan_keys_checked'] += len(scan['stable'])
                scan['cursor'] = None
            else:
                assert following > args[0]
                scan['cursor'] = following
            expected.append(f'S|{",".join(map(str, offered))}|{following}')
            stats['scan_rounds'] += 1
            return
        reply = '0'
        if code in ('I', 'D', 'Q'):
            key, hashed = args[:2]
            assert hashed == key_hash(key)
            found = next(((bank, i) for bank in (src, dst) for i, c in enumerate(bank)
                          if isinstance(c, tuple) and c[0] == key), None)
            if found and heap() and len(key_text(key)) <= 7 and found[0][found[1]][3]:
                stats['short_timed_heap_hits'] += 1
            if code == 'I':
                entry = args
                reply = str(int(found is None))
                if found:
                    before = found[0][found[1]][3]
                    if before and entry[3]:
                        stats['deadline_rewritten'] += 1
                    elif entry[3]:
                        stats['deadline_set'] += 1
                    elif before:
                        stats['deadline_cleared'] += 1
                    found[0][found[1]] = entry
                else:
                    claim(dst if cursor >= 0 else src, entry)
                    length = len(key_text(key))
                    if entry[3]:
                        stats['timed_insertions'] += 1
                    if length == 12:
                        stats['twelve_byte_insertions'] += 1
                    form = key_form(heap(), length, bool(entry[3]))
                    if heap() and form == 'h':
                        stats['heap_key_insertions'] += 1
                    if form == 's' and not entry[3]:
                        stats['untimed_slab_key_insertions'] += 1
                logical[key] = entry
            elif code == 'D':
                stats['deletions'] += 1
                if found:
                    reply = '1'
                    bank, i = found
                    group = bank[(i // 16) * 16:(i // 16 + 1) * 16]
                    bank[i] = None if any(c is None for c in group) else False
                    del logical[key]
            else:
                reply = cell_text(logical[key], heap()) if key in logical else 'n'
                stats['queries'] += 1
        elif code == 'G':
            allocate(args[0])
        elif code == 'B':
            stats['production_begins'] += 1
            begin(args[0])
        elif code == 'O':
            stats['production_make_rooms'] += 1
            migrate(MAX, MAX)
            assert cursor == -1
            live = sum(isinstance(c, tuple) for c in src)
            begin(grow_cap(len(src)) if live > len(src) * 7 // 16 else len(src))
        elif code == 'U':
            live = sum(isinstance(c, tuple) for c in src)
            allocate(grow_cap(len(src)) if live > len(src) * 7 // 16 else len(src))
            stats['growth_rule_resizes'] += 1
        elif code == 'V':
            allocate(round_cap(sum(isinstance(c, tuple) for c in src) * 2))
            stats['shrink_rule_resizes'] += 1
        elif code == 'M':
            migrate(*args)
        else:
            raise AssertionError(code)
        physical = [c for c in src + dst if isinstance(c, tuple)]
        assert len(physical) == len(logical) and {e[0]: e for e in physical} == logical
        for bank in (src, dst):
            assert not bank or bank.count(None) > len(bank) // 8 - 1
        timed = sum(1 for e in physical if e[3])
        cells = sum(cell_bytes(heap(), len(key_text(e[0])), bool(e[3])) for e in physical)
        tables = table_bytes(len(src), heap()) + table_bytes(len(dst), heap())
        mapped = mapped_bytes(len(src), heap()) + mapped_bytes(len(dst), heap())
        expected.append(f'T|{reply}|{cursor}|{role}|{timed},{cells},{tables},{mapped}|'
                        f'{table_text(src, heap())}|{table_text(dst, heap())}')
        stats['table_operations'] += 1
        if heap():
            stats['heap_role_operations'] += 1

    def scan_step():
        step('S', scan['cursor'] or 0)

    def scan_all():
        while scan['cursor']:
            scan_step()

    def deadline(index, source):
        if index % 3 != 1:
            return 0
        return (1, (1 << 48) - 1)[index % 2] if index % 9 == 1 else source.randrange(1, 1 << 48)

    def scenario(index, start, role_bits, keys, source):
        step('R', start, role_bits)
        for position, key in enumerate(keys):
            step('I', key, key_hash(key), MASK if position % 3 == 0 else source.randrange(1 << 32),
                 deadline(position, source), 65535 if position % 5 == 0 else position)
        for key in keys[::7]:
            step('D', key, key_hash(key))
        for key in keys:
            step('Q', key, key_hash(key))
        scan_step()
        scan_all()
        step('U')
        step('M', 0, 1)
        step('M', 1, 0)
        for iteration in range(30):
            key = source.choice(keys)
            if iteration % 4 == 0:
                step('I', key, key_hash(key), iteration + 1, source.choice((0, iteration * 222 + 1)), iteration)
            elif iteration % 4 == 1:
                step('D', key, key_hash(key))
            elif iteration % 4 == 2:
                step('I', key, key_hash(key), iteration + 1, 0 if iteration % 8 == 2 else source.randrange(1, 1 << 48), iteration)
            step('M', 1 + iteration % 2, 1 + iteration % 5)
            scan_step()
            step('Q', key, key_hash(key))
        step('M', MAX, MAX)
        assert cursor == -1
        scan_all()
        for key in keys[1::3]:
            step('D', key, key_hash(key))
        step('V')
        scan_step()
        for _ in range(8):
            step('M', 1, 2)
            if scan['cursor']:
                scan_step()
        step('M', MAX, MAX)
        scan_all()
        step('G', 48 + 16 * (index % 6))
        scan_step()
        for _ in range(6):
            step('M', 1, 3)
            if scan['cursor']:
                scan_step()
        step('M', MAX, MAX)
        scan_all()
        for key in keys:
            step('Q', key, key_hash(key))

    collisions = {}
    for cap in (64, 80, 48):
        groups = cap // 16
        found = []
        for key in range(1, 400000):
            h = key_hash(key)
            if home_of(h, groups) == groups - 1 and h % 128 == 31:
                found.append(key)
                if len(found) == 40:
                    break
        assert len(found) == 40
        collisions[cap] = found
    stats['same_home_and_tag_keys'] = sum(map(len, collisions.values()))
    starts = (64, 80, 48, 96, 112, 144, 160, 208)
    for index in range(48):
        start = starts[index % len(starts)]
        keys = collisions[start] if index < 3 else rng.sample(range(1, 100000), 40)
        scenario(index, start, 0, keys, rng)
    step('R', 336, 0)
    keys = rng.sample(range(100000, 200000), 160)
    for index, key in enumerate(keys):
        step('I', key, key_hash(key), rng.randrange(1 << 64), deadline(index, rng), index % 65536)
    scan_step()
    scan_all()
    step('U')
    assert len(dst) == 512
    scan_step()
    for index in range(40):
        key = keys[index * 4]
        if index % 3 == 0:
            step('I', key, key_hash(key), index, 0 if index % 2 else index + 7, index)
        elif index % 3 == 1:
            step('D', key, key_hash(key))
        step('M', 1, 5)
        if scan['cursor']:
            scan_step()
    step('M', MAX, MAX)
    scan_all()
    for key in keys[1::4] + keys[2::4] + keys[3::4]:
        step('D', key, key_hash(key))
    step('V')
    scan_step()
    for _ in range(30):
        step('M', 1, 2)
        if scan['cursor']:
            scan_step()
    step('M', MAX, MAX)
    scan_all()
    for key in keys:
        step('Q', key, key_hash(key))
    for cap, other in ((16, 16), (32, 16), (48, 16), (64, 16), (80, 16), (128, 16), (208, 224), (224, 304),
                       (304, 1040), (1040, 4096), (4096, 1040)):
        step('R', cap, 0)
        step('G', other)
        step('M', 0, 0)
        assert cursor == -1
    next_id = 1
    for initialized_case in (0, 1):
        for budget in (0, 1, 32, 33, 64, 127, 1024, MAX):
            step('A', budget, initialized_case)
            for size in (-1, 0, 1, 31, 32, 33, min(budget, 4096), MAX - 32, MAX):
                for code in ('E', 'P'):
                    if code == 'P' and size > 4096 and size <= MAX - 32 and budget == MAX and initialized_case:
                        continue
                    ident = next_id
                    next_id += 1
                    step(code, ident, size)
                    if ident in tokens:
                        step('L' if code == 'E' else 'F', ident)
            assert not tokens
    for _ in range(12):
        step('A', 1024, 1)
        active = {}
        ident = next_id
        next_id += 1
        step('P', ident, 32)
        step('W', ident)
        step('Z', ident)
        step('F', ident)
        for _ in range(90):
            if active and rng.randrange(3) == 0:
                ident = rng.choice(list(active))
                step(active.pop(ident), ident)
            else:
                code = rng.choice(('E', 'P'))
                ident = next_id
                next_id += 1
                step(code, ident, rng.randrange(0, 500))
                if ident in tokens:
                    active[ident] = 'L' if code == 'E' else 'F'
        for ident, code in active.items():
            step(code, ident)
        step('N')
    roles = random.Random(0xE5A1507)
    long_keys = range(10 ** 11, 10 ** 11 + 10 ** 6)
    for index in range(24):
        role_bits = (12, 4, 0, 2)[index % 4]
        start = starts[index % len(starts)]
        short = roles.sample(range(1, 100000), 20)
        wide = roles.sample(long_keys, 20)
        keys = [key for pair in zip(short, wide) for key in pair]
        scenario(index, start, role_bits, keys, roles)
        step('O')
        for position, key in enumerate(keys[::3]):
            step('I', key, key_hash(key), position, deadline(position, roles), position)
        step('B', 48 + 16 * (index % 5))
        step('O')
        scan_step()
        scan_all()
    for role_bits, count in ((12, 310), (4, 304)):
        step('R', 688, role_bits)
        keys = [key for pair in zip(roles.sample(range(1, 100000), count // 2), roles.sample(long_keys, count // 2))
                for key in pair]
        for position, key in enumerate(keys):
            step('I', key, key_hash(key), roles.randrange(1 << 64), deadline(position, roles), position % 65536)
        step('O')
        assert len(src) == 1040 and cursor == -1
        for key in keys[::15]:
            step('Q', key, key_hash(key))
        for key in keys[:200]:
            step('D', key, key_hash(key))
        step('V')
        assert len(dst) == round_cap((count - 200) * 2) and cursor == 0
        scan_step()
        for iteration in range(30):
            key = roles.choice(keys)
            if iteration % 3 == 0:
                step('I', key, key_hash(key), iteration, deadline(iteration, roles), iteration)
            elif iteration % 3 == 1:
                step('D', key, key_hash(key))
            step('M', 1, 8)
            if scan['cursor']:
                scan_step()
        step('M', MAX, MAX)
        scan_all()
        step('G', 1040)
        for _ in range(4):
            step('M', 2, 16)
        step('M', MAX, MAX)
        step('B', 1024)
        assert cursor == 0
        scan_step()
        for _ in range(6):
            step('M', 4, 12)
            if scan['cursor']:
                scan_step()
        step('M', MAX, MAX)
        scan_all()
        step('B', 1040)
        assert cursor == -1 and len(src) == 1040
        step('O')
        assert cursor == 0 and len(dst) == 1040
        step('M', MAX, MAX)
        step('B', 1024)
        step('M', MAX, MAX)
        for key in keys:
            step('Q', key, key_hash(key))
    for cap, role_bits in ((1024, 12), (1040, 12), (16, 12), (1024, 4), (1024, 0), (16, 2)):
        step('R', cap, role_bits)
        step('B', 1040 if cap == 1024 else 16)
        step('O')
    wide = 10 ** 11 + 3
    for role_bits in (0, 12, 4):
        step('R', 16, role_bits)
        step('I', 1, key_hash(1), 7, 5, 0)
        step('Q', 1, key_hash(1))
        step('D', 1, key_hash(1))
        step('I', 1, key_hash(1), 8, 0, 1)
        step('I', 2, key_hash(2), 9, 0, 2)
        step('I', 2, key_hash(2), 9, 6, 3)
        step('Q', 2, key_hash(2))
        step('I', 2, key_hash(2), 10, 0, 4)
        step('Q', 2, key_hash(2))
        step('I', 2, key_hash(2), 11, 8, 5)
        step('D', 2, key_hash(2))
        step('I', wide, key_hash(wide), 10, 7, 4)
        step('Q', wide, key_hash(wide))
    stats['rows'] = len(expected)
    assert stats['table_operations'] > 5000 and stats['accounting_operations'] > 1000
    assert stats['partial_batches'] > 0 and stats['zero_budget_batches'] > 0
    assert stats['scan_iterations'] > 0 and stats['non_power_of_two_tables'] > 0
    assert len({row.split('|')[4].split(',')[2] for row in expected if row.startswith('T|')}) > 6
    assert min(stats['deadline_set'], stats['deadline_cleared'], stats['deadline_rewritten']) > 0
    assert min(stats['heap_key_insertions'], stats['twelve_byte_insertions'], stats['untimed_slab_key_insertions'],
               stats['crossings_to_mapped'], stats['crossings_to_heap'], stats['synchronous_migrations'],
               stats['short_timed_heap_hits']) > 0
    return '\n'.join(lines) + '\n', expected, stats


VALUE_LENGTHS = (0, 1, 7, 8, 44, 45, 100, 4096, 4097, 5000)
DOUBLING = 1 << 20


def fnv(data):
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & MASK
    return h


def value_corpus():
    lines, expected = [], []
    stats = {'value_operations': 0, 'empty_value_results': 0, 'empty_value_writes': 0, 'value_stores': 0,
             'value_appends': 0, 'value_ranges': 0, 'value_erasures': 0, 'value_moves': 0,
             'heap_value_reallocations': 0, 'empty_heap_values': 0, 'empty_blocks': 0, 'empty_block_reuses': 0}
    state = {'form': 'n', 'data': b'', 'cap': 0, 'objs': 0, 'heap': 0, 'ops': 0, 'empty': False}

    def release():
        if state['form'] == 'h':
            state['objs'] -= 1
            state['heap'] -= state['cap'] + 16
        state['form'], state['cap'], state['empty'] = 'n', 0, False

    def block(cap, empty=False):
        state['form'], state['cap'], state['empty'] = 'h', cap, empty
        state['objs'] += 1
        state['heap'] += cap + 16

    def resize(cap):
        state['heap'] += cap - state['cap']
        state['cap'], state['empty'] = cap, False
        stats['heap_value_reallocations'] += 1

    def loaded_cap():
        return {'n': 0, 'i': len(state['data']), 'h': state['cap']}[state['form']]

    def step(code, *args):
        lines.append(' '.join(map(str, (code,) + args)))
        if code == 'X':
            state.update(form='n', data=b'', cap=0, objs=0, heap=0, empty=False)
            return
        if code == 'E':
            release()
            state['data'] = b''
            stats['value_erasures'] += 1
        else:
            n = args[-1]
            data = bytes([97 + state['ops'] % 26]) * n
            state['ops'] += 1
            if n == 0:
                stats['empty_value_writes'] += 1
            if code == 'S':
                stats['value_stores'] += 1
                if n <= 7 and args[0] != 'r':
                    release()
                    state['form'] = 'i'
                elif state['form'] == 'h':
                    if state['empty'] and n <= 4096:
                        stats['empty_block_reuses'] += 1
                    if n <= 4096 and (state['empty'] or n > state['cap'] or state['cap'] > 2 * n + 64):
                        resize(max(n, 1))
                    elif n > 4096 and (n > state['cap'] or state['cap'] > 2 * n + 64):
                        resize(n)
                else:
                    release()
                    block(max(n, 1))
                state['data'] = data
            elif code == 'A':
                stats['value_appends'] += 1
                grown = len(state['data']) + n
                if state['form'] == 'h':
                    if grown > state['cap']:
                        resize(max(grown, state['cap'] * 2))
                else:
                    cap = max(grown, loaded_cap() * 2, 1)
                    release()
                    block(cap)
                state['data'] += data
            elif code == 'M':
                assert state['form'] == 'n'
                stats['value_moves'] += 1
                block(max(n, 1))
                state['data'] = data
            else:
                assert code == 'G'
                stats['value_ranges'] += 1
                off = args[0]
                held = state['data']
                room = loaded_cap()
                final = max(off + n, len(held))
                resized = final > room
                if resized:
                    room = final if room == 0 else final + DOUBLING if final >= DOUBLING else final * 2
                patched = bytearray(final)
                patched[:len(held)] = held
                patched[off:off + n] = data
                if state['form'] == 'h':
                    state['heap'] += max(room, final) - state['cap']
                    state['cap'] = max(room, final)
                    if resized:
                        state['empty'] = False
                else:
                    release()
                    block(max(room, final), final == 0)
                state['data'] = bytes(patched)
        empty_block = int(state['form'] == 'h' and state['empty'])
        if not state['data']:
            stats['empty_value_results'] += 1
            if state['form'] == 'h':
                stats['empty_heap_values'] += 1
        stats['empty_blocks'] += empty_block
        expected.append(f"V|{state['form']}|{len(state['data'])}|{loaded_cap()}|{state['objs']}|{state['heap']}|0|"
                        f"{empty_block}|{fnv(state['data']):x}")
        stats['value_operations'] += 1

    for role in (12, 4):
        step('X', role)
        for n in VALUE_LENGTHS:
            step('S', 'r', n)
            step('S', 'e', n)
        step('E')
        for a in VALUE_LENGTHS:
            for b in VALUE_LENGTHS:
                step('S', 'r', a)
                step('S', 'r', b)
        step('E')
        for code, *args in (('S', 'r', 0), ('S', 'r', 0), ('A', 0), ('A', 1), ('A', 0), ('A', 7), ('A', 100),
                            ('A', 4000), ('A', 200), ('A', 0), ('E',), ('A', 0), ('A', 0), ('E',), ('S', 'e', 0),
                            ('A', 0), ('S', 'r', 0), ('S', 'e', 0), ('A', 5), ('E',), ('G', 0, 5), ('G', 10, 3),
                            ('S', 'e', 3), ('G', 2, 4), ('G', 4096, 1), ('S', 'r', 0), ('G', 0, 1), ('E',),
                            ('S', 'e', 0), ('G', 0, 1), ('E',), ('S', 'r', 0), ('G', 3, 2), ('S', 'r', 0),
                            ('S', 'r', 100), ('S', 'r', 0), ('S', 'r', 64), ('S', 'r', 0), ('E',),
                            ('G', 0, 0), ('S', 'r', 0), ('S', 'r', 0), ('E',), ('S', 'e', 0), ('G', 0, 0), ('A', 0),
                            ('A', 3), ('E',), ('G', 0, 0), ('S', 'r', 2), ('E',), ('G', 0, 0), ('S', 'e', 0),
                            ('E',), ('G', 0, 0), ('G', 0, 0), ('S', 'r', 5000), ('E',), ('G', 0, 0), ('G', 4, 0),
                            ('E',), ('G', 0, 0), ('S', 'r', 45), ('E',)):
            step(code, *args)
        for n in VALUE_LENGTHS:
            step('M', n)
            step('S', 'r', 0)
            step('E')
            step('M', n)
            step('A', 1)
            step('E')
        for a in VALUE_LENGTHS:
            for b in (0, 1, 50, 4096):
                step('E')
                step('S', 'r' if a % 2 else 'e', a)
                step('A', b)
            for off, n in ((0, 1), (a, 1), (a + 10, 2), (0, a + 1)):
                step('E')
                step('S', 'e', a)
                step('G', off, n)
        step('E')
    assert min(stats['empty_value_writes'], stats['empty_value_results'], stats['heap_value_reallocations'],
               stats['empty_heap_values'], stats['empty_blocks'], stats['empty_block_reuses'], stats['value_moves']) > 0
    return '\n'.join(lines) + '\n', expected, stats


def compare(label, got, expected):
    rows = got.splitlines()
    if not expected or len(rows) != len(expected):
        raise AssertionError(f'{label}: row count {len(rows)} != {len(expected)}')
    for i, (a, b) in enumerate(zip(rows, expected)):
        if a != b:
            raise AssertionError(f'{label}: row {i}: {a!r} != {b!r}')


def source_gate():
    pinned = json.loads((PACKAGE / 'source-sha256.json').read_text())
    if len(pinned) < 7:
        raise AssertionError('missing source drift gates')
    for name, wanted in pinned.items():
        if digest(ROOT / name) != wanted:
            raise AssertionError(f'source changed: {name}; reconcile the contracts before updating the gate')
    return pinned


def audit_axioms(lake, env, output):
    return audit_kernel(lake, PACKAGE, output, env, "Storage")


def procedure(text, name, marker='::'):
    found = [m.start() for m in re.finditer(rf'^{name} {marker} ', text, re.M)]
    if len(found) != 1:
        raise AssertionError(f'expected one declaration of {name}')
    start = found[0]
    brace = text.index('{', start)
    depth, quoted, escaped = 1, False, False
    i = brace + 1
    while depth:
        c = text[i]
        if quoted:
            if escaped:
                escaped = False
            elif c == '\\':
                escaped = True
            elif c == '"':
                quoted = False
        elif c == '"':
            quoted = True
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
        i += 1
    return text[start:i] + '\n'


CONSTANTS = ('DB_ROLE_HEAP', 'DB_ROLE_OWNER', 'REHASH_SYNC_CAP', 'ENTRY_RING', 'BIG_STR_BYTES', 'STRING_DOUBLING_LIMIT')
PROCEDURES = ('Entry', 'mem_alloc', 'mem_free', 'key_store', 'key_store_heap', 'key_store_timed', 'key_store_timed_heap',
              'key_release', 'key_restore', 'key_set_deadline', 'db_locate', 'db_erase', 'db_rehash_swap',
              'db_rehash_groups', 'db_rehash_finish', 'db_rehash_start', 'table_alloc_for', 'db_rehash_begin',
              'db_drop_next', 'db_make_room', 'scan_take_home', 'scan_round', 'big_new', 'big_attach', 'val_release',
              'entry_load', 'entry_view', 'entry_store', 'entry_store_heap', 'entry_append', 'entry_append_heap',
              'entry_heap_open', 'entry_heap_close', 'string_grown_capacity', 'entry_setrange', 'db_move_heap')
SLAB_CONSTANTS = ('SLAB_UNIT', 'SLAB_MAX', 'SLAB_CLASSES')
SLAB_DECLARATIONS = (('slab_class_size', ':='), ('slab_class', '::'), ('slab_size_of', '::'))


def constant(text, name):
    found = re.findall(rf'^{name} :: [^\n]*$', text, re.M)
    if len(found) != 1:
        raise AssertionError(f'expected one declaration of {name}')
    return found[0] + '\n'


def overlay(output):
    target = output / 'overlay'
    target.mkdir(exist_ok=True)
    provenance = {}
    for name in ('table', 'hash'):
        original = ROOT / f'src/{name}.odin'
        shutil.copyfile(original, target / original.name)
        provenance[original.name] = {'source': f'src/{name}.odin', 'sha256': digest(original), 'whole_file': True}
    value = (ROOT / 'src/value.odin').read_text()
    prefix = value[:value.index('string_encoding_of ::')]
    (target / 'value_types.odin').write_text(prefix)
    provenance['value_types.odin'] = {'source': 'src/value.odin', 'sha256': hashlib.sha256(prefix.encode()).hexdigest(), 'whole_file': False, 'slice': [0, len(prefix.encode())]}
    source = (ROOT / 'src/store.odin').read_text()
    snippets = []
    for name in CONSTANTS:
        snippet = constant(source, name)
        snippets.append(snippet)
        provenance[name] = {'source': 'src/store.odin', 'sha256': hashlib.sha256(snippet.encode()).hexdigest(), 'whole_file': False, 'exact_constant': name}
    for name in PROCEDURES:
        snippet = procedure(source, name)
        snippets.append(snippet)
        provenance[name] = {'source': 'src/store.odin', 'sha256': hashlib.sha256(snippet.encode()).hexdigest(), 'whole_file': False, 'exact_procedure': name}
    slab = (ROOT / 'src/slab.odin').read_text()
    for name in SLAB_CONSTANTS:
        snippet = constant(slab, name)
        snippets.append(snippet)
        provenance[name] = {'source': 'src/slab.odin', 'sha256': hashlib.sha256(snippet.encode()).hexdigest(), 'whole_file': False, 'exact_constant': name}
    for name, marker in SLAB_DECLARATIONS:
        snippet = procedure(slab, name, marker)
        snippets.append(snippet)
        provenance[name] = {'source': 'src/slab.odin', 'sha256': hashlib.sha256(snippet.encode()).hexdigest(), 'whole_file': False, 'exact_procedure': name}
    template = (PACKAGE / 'bridge.odin').read_text().replace('@KEYSPACE@', os.path.relpath(ROOT / 'src/keyspace', target))
    (target / 'main.odin').write_text(template + '\n' + '\n'.join(snippets))
    (output / 'overlay-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    return target, provenance


def build(lean_bin, output):
    env = dict(os.environ, LEAN_NUM_THREADS='1')
    if lean_bin:
        env['PATH'] = str(lean_bin.resolve()) + os.pathsep + env.get('PATH', '')
    paths = {name: shutil.which(name, path=env.get('PATH')) for name in ('lean', 'lake', 'odin')}
    if not all(paths.values()):
        raise AssertionError('Lean, Lake and Odin required; use --lean-bin or LEAN_BIN_DIR')
    versions = {name: subprocess.run([paths[name], '--version' if name == 'lean' else 'version'],
                                   env=env, text=True, capture_output=True, check=True).stdout.strip()
                for name in ('lean', 'odin')}
    if not re.search(r'\bversion 4\.35\.0\b', versions['lean']):
        raise AssertionError('expected official pinned Lean 4.35.0')
    target, provenance = overlay(output)
    commands = [([paths['lake'], 'build'], PACKAGE),
                ([paths['odin'], 'build', str(target), '-out:' + str(output / 'odin_bridge'),
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
                raise AssertionError('build failed:\n' + logs[-1])
        axioms, kernel = audit_axioms(paths['lake'], env, output)
    binaries = {'lean': PACKAGE / '.lake/build/bin/storage_model', 'odin': output / 'odin_bridge'}
    return binaries, axioms, versions, provenance, {k: digest(Path(v)) for k, v in paths.items()}, kernel


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument('--lean-bin', type=Path, default=Path(os.environ['LEAN_BIN_DIR']) if 'LEAN_BIN_DIR' in os.environ else None)
    parser.add_argument('--output', type=Path, default=PACKAGE / '.build')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / 'receipt.json').unlink(missing_ok=True)
    os.nice(10)
    os.sched_setaffinity(0, {min(os.sched_getaffinity(0))})
    fingerprints = source_gate()
    binaries, axioms, versions, provenance, tools, kernel = build(args.lean_bin, output)
    trace, expected, stats = corpus()
    path = output / 'traces.txt'
    path.write_text(trace)
    results = {}
    for name, binary in binaries.items():
        result = subprocess.run([str(binary.resolve()), str(path)], text=True, capture_output=True, check=True)
        if result.stderr:
            raise AssertionError(f'{name}: unexpected stderr: {result.stderr}')
        compare(name, result.stdout, expected)
        (output / f'{name}-results.txt').write_text(result.stdout)
        results[name] = hashlib.sha256(result.stdout.encode()).hexdigest()
    value_trace, value_expected, value_stats = value_corpus()
    value_path = output / 'values.txt'
    value_path.write_text(value_trace)
    result = subprocess.run([str(binaries['odin'].resolve()), str(value_path), 'values'], text=True,
                            capture_output=True, check=True)
    if result.stderr:
        raise AssertionError(f'odin values: unexpected stderr: {result.stderr}')
    compare('odin values', result.stdout, value_expected)
    (output / 'odin-value-results.txt').write_text(result.stdout)
    results['odin_values'] = hashlib.sha256(result.stdout.encode()).hexdigest()
    negatives = []
    cases = {'empty': '', 'truncated': '\n'.join(expected[:-1]) + '\n', 'extra': '\n'.join(expected + [expected[0]]) + '\n'}
    for column in range(7):
        mutated = list(expected)
        cells = mutated[0].split('|')
        cells[column] = 'controlled-mutant'
        mutated[0] = '|'.join(cells)
        cases[f'table_column_{column}'] = '\n'.join(mutated) + '\n'

    def row_mutant(name, predicate, change):
        at = next(i for i, row in enumerate(expected) if predicate(row.split('|')))
        mutated = list(expected)
        cells = mutated[at].split('|')
        change(cells)
        assert '|'.join(cells) != expected[at]
        mutated[at] = '|'.join(cells)
        cases[name] = '\n'.join(mutated) + '\n'

    def heap_row(cells):
        return cells[0] == 'T' and cells[3] == '12' and ':h' in cells[5] and ',h;' in cells[5]

    def counter(field):
        def change(cells):
            values = cells[4].split(',')
            values[field] = str(int(values[field]) + 1)
            cells[4] = ','.join(values)
        return change

    for field, name in enumerate(('expires', 'cells', 'tables', 'mapped')):
        row_mutant(f'heap_counter_{name}', heap_row, counter(field))
    row_mutant('heap_role_value', heap_row, lambda cells: cells.__setitem__(3, '0'))
    row_mutant('heap_table_kind', heap_row, lambda cells: cells.__setitem__(5, cells[5].replace(',h;', ',m;', 1)))
    row_mutant('heap_key_form', heap_row, lambda cells: cells.__setitem__(5, cells[5].replace(':h', ':s', 1)))
    row_mutant('crossing_destination_kind', lambda cells: cells[0] == 'T' and cells[3] == '12' and
               ',h;' in cells[5] and ',m;' in cells[6],
               lambda cells: cells.__setitem__(6, cells[6].replace(',m;', ',h;', 1)))
    row_mutant('slab_key_form', lambda cells: cells[0] == 'T' and cells[3] == '0' and ':su' in cells[5],
               lambda cells: cells.__setitem__(5, cells[5].replace(':su', ':hu', 1)))
    row_mutant('old_matcher_query', lambda cells: cells[0] == 'T' and cells[3] in ('4', '12') and
               re.fullmatch(r'\d+:\d+:\d+:ht\d+', cells[1]) is not None and int(cells[1].split(':')[0]) < 10 ** 7,
               lambda cells: cells.__setitem__(1, 'n'))
    scan_row = next(i for i, row in enumerate(expected) if row.startswith('S|') and row.split('|')[1])
    for column in (1, 2):
        mutated = list(expected)
        cells = mutated[scan_row].split('|')
        cells[column] = 'controlled-mutant'
        mutated[scan_row] = '|'.join(cells)
        cases[f'scan_column_{column}'] = '\n'.join(mutated) + '\n'
    accounting_row = next(i for i, row in enumerate(expected) if row.startswith('K|'))
    for column in (1, 2):
        mutated = list(expected)
        cells = mutated[accounting_row].split('|')
        cells[column] = 'controlled-mutant'
        mutated[accounting_row] = '|'.join(cells)
        cases[f'accounting_column_{column}'] = '\n'.join(mutated) + '\n'
    value_cases = {}
    value_row = next(i for i, row in enumerate(value_expected) if row.startswith('V|h|0|'))
    for column in range(1, 9):
        mutated = list(value_expected)
        cells = mutated[value_row].split('|')
        cells[column] = 'controlled-mutant'
        mutated[value_row] = '|'.join(cells)
        value_cases[f'value_column_{column}'] = '\n'.join(mutated) + '\n'
    value_cases['value_truncated'] = '\n'.join(value_expected[:-1]) + '\n'
    for name, prefix, before, after in (('old_empty_charge', 'V|h|0|1|1|17|', 'V|h|0|1|1|17|', 'V|h|0|0|1|16|'),
                                        ('empty_block_flag', 'V|h|0|0|1|16|0|1|', '|0|1|', '|0|0|')):
        at = next(i for i, row in enumerate(value_expected) if row.startswith(prefix))
        mutated = list(value_expected)
        mutated[at] = mutated[at].replace(before, after, 1)
        assert mutated[at] != value_expected[at]
        value_cases[name] = '\n'.join(mutated) + '\n'
    for name, mutant in value_cases.items():
        try:
            compare(name, mutant, value_expected)
        except AssertionError:
            negatives.append(name)
        else:
            raise AssertionError('negative control accepted: ' + name)
    for name, mutant in cases.items():
        try:
            compare(name, mutant, expected)
        except AssertionError:
            negatives.append(name)
        else:
            raise AssertionError('negative control accepted: ' + name)
    accounting_names = {'Storage.' + n for module in ('Ledger', 'Cells')
                        for n in re.findall(r'^theorem\s+(\w+)', (PACKAGE / f'Storage/{module}.lean').read_text(), re.M)}
    area_evidence = {'1': {'theorems': sorted(set(axioms) - accounting_names),
                           'comparisons': stats['table_operations'] + stats['scan_rounds']},
                     '6': {'theorems': sorted(accounting_names),
                           'comparisons': stats['accounting_operations'] + stats['table_operations'] +
                           value_stats['value_operations']}}
    stats = {**stats, **value_stats, 'value_rows': len(value_expected)}
    receipt = {**stats, 'area_evidence': area_evidence, 'value_trace_sha256': hashlib.sha256(value_trace.encode()).hexdigest(), 'seed': '0xE5A1506', 'checked_theorem_axioms': axioms, 'kernel_inventory_sha256': digest(output / 'kernel-inventory.json'),
               'kernel_checked_theorems': len(kernel['theorem_axioms']),
               'source_sha256': fingerprints, 'versions': versions, 'tool_sha256': tools,
               'overlay_provenance': provenance, 'trace_sha256': hashlib.sha256(trace.encode()).hexdigest(),
               'results_sha256': results, 'executable_sha256': {n: digest(p) for n, p in binaries.items()},
               'proof_source_sha256': {str(p.relative_to(PACKAGE)): digest(p) for p in PACKAGE.rglob('*')
                                       if p.is_file() and '.lake' not in p.parts and '.build' not in p.parts and '__pycache__' not in p.parts},
               'negative_controls_rejected': negatives}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({**stats, 'theorems': len(axioms), 'receipt': str(output / 'receipt.json')}, indent=2))


if __name__ == '__main__':
    run()
