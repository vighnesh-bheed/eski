import argparse
import fcntl
import hashlib
import json
import os
import random
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from kernel_audit import audit as audit_kernel

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(__file__).resolve().parent
SEED = 0x1A8E15
NAME_MAX = 64
MARKING_MAX = 32768
LEVEL_LIMIT = 256
COMP_LIMIT = 256
LABEL_LIMIT = 65535
ID_NONE = 65535
U64_MAX = (1 << 64) - 1
BOTTOM = (0, frozenset())
AREAS = {
    'lattice': ['Lattice'],
    'marking': ['Marking'],
    'interning': ['Intern'],
    'persistence': ['Codec'],
    'visibility': ['Visibility'],
    'admission': ['Admission', 'Search'],
    'rules': ['Rules'],
    'counters': ['Counters'],
}
ROW_AREAS = {'L': 'lattice', 'CR': 'marking', 'CL': 'marking', 'CC': 'marking', 'M': 'marking', 'F': 'marking',
             'TR': 'interning', 'TI': 'interning', 'TF': 'interning', 'E': 'persistence', 'D': 'persistence',
             'V': 'visibility', 'VR': 'visibility', 'G': 'admission', 'B': 'admission', 'SU': 'rules', 'SR': 'rules', 'SW': 'rules',
             'SM': 'rules', 'SD': 'rules', 'NR': 'counters', 'NA': 'counters', 'NS': 'counters', 'NV': 'counters'}
NAME_PATTERN = re.compile(rb'[A-Z0-9][A-Z0-9_-]*( [A-Z0-9][A-Z0-9_-]*)*')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hexs(data):
    return data.hex() if data else '-'


def ids_text(ids):
    return ','.join(map(str, sorted(ids))) if ids else '-'


def label_text(label):
    return f'{label[0]}:{ids_text(label[1])}'


def dom(a, b):
    return b[0] <= a[0] and b[1] <= a[1]


def join(a, b):
    return (max(a[0], b[0]), a[1] | b[1])


def meet(a, b):
    return (min(a[0], b[0]), a[1] & b[1])


def normalise(raw):
    return b' '.join(w for w in re.split(rb'[ \t]', raw) if w).upper()


def canonical(name):
    return 0 < len(name) <= NAME_MAX and NAME_PATTERN.fullmatch(name) is not None


class Config:
    def __init__(self):
        self.levels, self.comps = [], []

    def add(self, kind, raw):
        names = self.levels if kind == 'CL' else self.comps
        if len(names) >= (LEVEL_LIMIT if kind == 'CL' else COMP_LIMIT):
            return 'toomanylevels' if kind == 'CL' else 'toomanycomps'
        n = normalise(raw)
        if len(n) > NAME_MAX:
            return 'toolong'
        if not n:
            return 'empty'
        if not canonical(n):
            return 'invalid'
        if n in self.levels or n in self.comps:
            return 'duplicate'
        names.append(n)
        return 'ok'

    def valid(self, label):
        return label[0] < len(self.levels) and all(c < len(self.comps) for c in label[1])

    def format(self, label):
        if not self.valid(label):
            return None
        text = self.levels[label[0]]
        if label[1]:
            text += b'//' + b'/'.join(self.comps[c] for c in sorted(label[1]))
        return text


def span(text, start, end):
    token = text[start:end]
    left = token.lstrip(b' \t')
    if not left:
        return start, 0
    return start + len(token) - len(left), len(left.rstrip(b' \t'))


def lookup(names, raw):
    want = normalise(raw)
    return names.index(want) if want in names else -1


def parse(cfg, text):
    if len(text) > MARKING_MAX:
        return None, ('toolong', MARKING_MAX, len(text) - MARKING_MAX)
    for i, b in enumerate(text):
        if not (b == 9 or 32 <= b <= 126):
            return None, ('invalidbyte', i, 1)
    parts = text.split(b'/')
    starts = [0]
    for part in parts[:-1]:
        starts.append(starts[-1] + len(part) + 1)
    at, n = span(text, 0, len(parts[0]))
    if n == 0:
        return None, ('empty' if len(parts) == 1 else 'emptylevel', at, 0)
    level = lookup(cfg.levels, parts[0])
    if level < 0:
        return None, ('unknownlevel', at, n)
    if len(parts) == 1:
        return (level, frozenset()), None
    if len(parts) == 2 or parts[1]:
        return None, ('badseparator', len(parts[0]), 1)
    comps = set()
    for i in range(2, len(parts)):
        at, n = span(text, starts[i], starts[i] + len(parts[i]))
        if n == 0:
            return None, ('emptycomp', at, 0)
        k = lookup(cfg.comps, parts[i])
        if k < 0:
            return None, ('unknowncomp', at, n)
        if k in comps:
            return None, ('dupcomp', at, n)
        comps.add(k)
    return (level, frozenset(comps)), None


def encode(cfg, table):
    if not table or table[0] != BOTTOM or not all(cfg.valid(l) for l in table):
        return None
    out = bytearray(b'ESLT\x01')
    for names in (cfg.levels, cfg.comps):
        out += struct.pack('<H', len(names))
        for n in names:
            out += bytes([len(n)]) + n
    out += struct.pack('<H', len(table))
    for level, comps in table:
        out += bytes([level]) + struct.pack('<H', len(comps)) + bytes(sorted(comps))
    return bytes(out)


class Truncated(Exception):
    pass


def decode(data):
    pos = 0

    def take(n):
        nonlocal pos
        if len(data) - pos < n:
            raise Truncated
        pos += n
        return data[pos - n:pos]

    try:
        if take(4) != b'ESLT':
            return 'badmagic', None
        if take(1)[0] != 1:
            return 'badversion', None
        cfg = Config()
        nlev = struct.unpack('<H', take(2))[0]
        if nlev == 0 or nlev > LEVEL_LIMIT:
            return 'badlevelcount', None
        for kind in ('levels', 'comps'):
            if kind == 'comps':
                ncomp = struct.unpack('<H', take(2))[0]
                if ncomp > COMP_LIMIT:
                    return 'badcompcount', None
            for _ in range(nlev if kind == 'levels' else ncomp):
                length = take(1)[0]
                name = bytes(take(length))
                if not canonical(name):
                    return 'badname', None
                if name in cfg.levels or name in cfg.comps:
                    return 'dupname', None
                getattr(cfg, kind).append(name)
        count = struct.unpack('<H', take(2))[0]
        if count == 0:
            return 'badlabelcount', None
        table, seen = [BOTTOM], {BOTTOM}
        for i in range(count):
            level = take(1)[0]
            if level >= nlev:
                return 'badlevel', None
            n = struct.unpack('<H', take(2))[0]
            if n > ncomp:
                return 'badcomp', None
            ids = list(take(n))
            if any(x >= ncomp for x in ids) or any(b <= a for a, b in zip(ids, ids[1:])):
                return 'badcomp', None
            label = (level, frozenset(ids))
            if i == 0:
                if label != BOTTOM:
                    return 'notbottom', None
                continue
            if label in seen:
                return 'duplabel', None
            seen.add(label)
            table.append(label)
        if pos != len(data):
            return 'trailing', None
        return 'ok', (cfg, table)
    except Truncated:
        return 'truncated', None


class Model:
    def __init__(self):
        self.cfg = Config()
        self.table = [BOTTOM]
        self.index = {BOTTOM: 0}
        self.reader = BOTTOM
        self.words = [1]
        self.built = 1
        self.counts, self.total = [], 0
        self.subject = (BOTTOM, BOTTOM)

    def visible(self, i):
        return i < self.built and (self.words[i // 64] >> (i % 64)) & 1 == 1

    def vis_row(self):
        return f'V|{self.built}|' + (','.join(f'{w:x}' for w in self.words) if self.words else '-')

    def rebuild(self, reader):
        self.reader, self.words, self.built = reader, [], 0
        self.refresh()

    def refresh(self):
        n = len(self.table)
        if n <= self.built:
            return
        self.words += [0] * ((n + 63) // 64 - len(self.words))
        for i in range(self.built, n):
            if dom(self.reader, self.table[i]):
                self.words[i // 64] |= 1 << (i % 64)
        self.built = n

    def gate(self, labels, slot):
        return slot < len(labels) and self.visible(labels[slot])

    def reset_table(self):
        self.table, self.index = [BOTTOM], {BOTTOM: 0}


def word_hex(n):
    return f'{n:x}'


def label_token(label):
    return label_text(label)


def corpus():
    rng = random.Random(SEED)
    lines, expected = [], []
    stats = {kind: 0 for kind in ROW_AREAS}
    extra = {'config_rejections': 0, 'parse_accepted': 0, 'parse_errors': {}, 'decode_errors': {}, 'decode_accepted': 0,
             'intern_repeats': 0, 'refresh_growths': 0, 'stale_slots': 0, 'gate_slots': 0, 'brute_cases_with_hidden': 0,
             'write_verdicts': {}, 'counter_overflows': 0, 'counter_underflows': 0, 'long_markings': 0}
    m = Model()

    def emit(line, row):
        lines.append(line)
        expected.append(row)
        stats[line.split(' ')[0]] += 1

    def random_label(levels, comps, picks=4):
        level = rng.randrange(levels) if levels else 0
        k = rng.randrange(picks + 1) if comps else 0
        return (level, frozenset(rng.randrange(comps) for _ in range(k)))

    for _ in range(1500):
        a = random_label(256, 256, 20)
        b = random_label(256, 256, 20) if rng.randrange(5) else (rng.randrange(a[0] + 1), frozenset(x for x in a[1] if rng.randrange(2)))
        emit(f'L {label_token(a)} {label_token(b)}', f'L|{int(dom(a, b))}|{int(dom(b, a))}|{label_text(join(a, b))}|{label_text(meet(a, b))}')
    full = (255, frozenset(range(256)))
    for a, b in ((BOTTOM, BOTTOM), (BOTTOM, full), (full, full), ((3, frozenset({0, 63, 64, 127, 128, 255})), (3, frozenset({63, 128}))),
                 ((7, frozenset()), (7, frozenset({200})))):
        emit(f'L {label_token(a)} {label_token(b)}', f'L|{int(dom(a, b))}|{int(dom(b, a))}|{label_text(join(a, b))}|{label_text(meet(a, b))}')

    def config_line(kind, raw):
        result = m.cfg.add(kind, raw)
        if result != 'ok':
            extra['config_rejections'] += 1
        names = m.cfg.levels if kind == 'CL' else m.cfg.comps
        last = hexs(names[-1]) if result == 'ok' else '-'
        emit(f'{kind} {hexs(raw)}', f'{kind}|{result}|{len(m.cfg.levels)}|{len(m.cfg.comps)}|{last}')

    def reset_config():
        m.cfg = Config()
        emit('CR', 'CR')

    def marking_line(text):
        if len(text) > MARKING_MAX:
            extra['long_markings'] += 1
        label, err = parse(m.cfg, text)
        if err:
            extra['parse_errors'][err[0]] = extra['parse_errors'].get(err[0], 0) + 1
            emit(f'M {hexs(text)}', f'M|{err[0]}|{err[1]}|{err[2]}')
        else:
            extra['parse_accepted'] += 1
            emit(f'M {hexs(text)}', f'M|ok|{label_text(label)}|{hexs(m.cfg.format(label))}')

    def format_line(label):
        text = m.cfg.format(label)
        emit(f'F {label_token(label)}', 'F|invalid' if text is None else f'F|{hexs(text)}')

    pieces = [b'UNCLASSIFIED', b'confidential', b'Secret', b'TOP SECRET', b'top  secret', b'TOP\tSECRET', b'SI', b'tk',
              b'HCS', b'G', b'NOFORN', b'NoForn', b'XYZ', b'S I', b'/', b'//', b'//', b'//', b'///', b' ', b'  ', b'\t',
              b'\x00', b'\n', b'\x7f', b'\xff', b'-', b'_', b'a']

    def fuzz_marking():
        return b''.join(rng.choice(pieces) for _ in range(rng.randrange(9)))

    def structured_marking():
        out = rng.choice(pieces[:6])
        if rng.randrange(4) == 0:
            return out
        out += rng.choice([b'//', b'//', b'//', b'/', b' //', b'// '])
        for i in range(1 + rng.randrange(4)):
            if i:
                out += rng.choice([b'/', b'/', b'/', b'//', b' / '])
            out += rng.choice(pieces[6:13])
        return out

    def mutate_marking(text):
        data = bytearray(text)
        for _ in range(1 + rng.randrange(3)):
            choice = rng.randrange(5)
            if choice == 0 and data:
                data[rng.randrange(len(data))] ^= 0x20
            elif choice == 1:
                data.insert(rng.randrange(len(data) + 1), rng.choice(b' \t/'))
            elif choice == 2 and data:
                del data[rng.randrange(len(data))]
            elif choice == 3 and data:
                data[rng.randrange(len(data))] = rng.randrange(256)
            else:
                data += rng.choice([b'/', b'//', b' '])
        return bytes(data)

    reset_config()
    for raw in (b'Unclassified', b'  confidential ', b'Secret', b'top \t  secret', b'TOP SECRET', b'_LOW', b'TOP SECRET'):
        config_line('CL', raw)
    for raw in (b'si', b'TK', b'hcs', b'G', b'NoForn', b'SI', b'secret', b'A/B', b'CAF\xc3\x89', b'A.B', b'A\nB', b'', b' \t ',
                b'X' * 65, b'A' + b' ' * 20 + b'B' * 62, b'-', b'_x_', b'si-g', b'hcs_p', b'A -B', b'9X'):
        config_line('CC', raw)
    for _ in range(4000):
        marking_line(fuzz_marking())
    for _ in range(3000):
        marking_line(structured_marking())
    for _ in range(1500):
        marking_line(mutate_marking(m.cfg.format(random_label(len(m.cfg.levels), len(m.cfg.comps), 6))))
    for text in (b'', b' \t ', b'//SI', b'  //SI', b'SECRT', b'  SECRT  //SI', b'SECRET/SI', b'SECRET/', b'SECRET / /SI',
                 b'SECRET//', b'SECRET// ', b'SECRET//SI/', b'SECRET///SI', b'SECRET//SI//TK', b'SECRET//SI/ XYZ /TK',
                 b'SECRET//SI/si', b'SECRET//TK/ tk ', b'SECRET\x00', b'SECRET//S\nI', b' ' * (MARKING_MAX + 1),
                 b' ' * MARKING_MAX, b'SECRET//' + b'SI/' * 10000 + b'TK'):
        marking_line(text)
    for _ in range(400):
        format_line(random_label(len(m.cfg.levels) + 2, len(m.cfg.comps) + 3, 4))

    reset_config()
    for i in range(LEVEL_LIMIT + 1):
        config_line('CL', f'L{i}'.encode())
    for i in range(COMP_LIMIT + 1):
        config_line('CC', f'c{i}'.encode())
    for _ in range(600):
        label = random_label(256, 256, 40)
        marking_line(m.cfg.format(label))
        if rng.randrange(2):
            marking_line(mutate_marking(m.cfg.format(label)))
    marking_line(m.cfg.format((255, frozenset(range(256)))))
    for _ in range(200):
        format_line(random_label(256, 256, 30))

    alphabet = b'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_ \t.!/'
    reset_config()
    for kind, count in (('CL', 30), ('CC', 70)):
        for _ in range(count):
            config_line(kind, bytes(rng.choice(alphabet) for _ in range(rng.randrange(0, 12))))
    for _ in range(1500):
        if m.cfg.levels and rng.randrange(3):
            label = random_label(len(m.cfg.levels), len(m.cfg.comps), 5)
            text = m.cfg.format(label)
            marking_line(mutate_marking(text) if rng.randrange(2) else text)
        else:
            marking_line(bytes(rng.choice(alphabet) for _ in range(rng.randrange(0, 30))))

    reset_config()
    for text in (b'SECRET', b'', b'//X', b'A//B'):
        marking_line(text)
    format_line(BOTTOM)

    reset_config()
    for raw in (b'UNCLASSIFIED', b'CONFIDENTIAL', b'SECRET', b'TOP SECRET'):
        config_line('CL', raw)
    for raw in (b'SI', b'TK', b'HCS', b'G', b'NOFORN', b'ORCON', b'RELIDO', b'FVEY'):
        config_line('CC', raw)

    def reset_table():
        m.reset_table()
        emit('TR', 'TR|1')

    def intern_line(label):
        if label in m.index:
            extra['intern_repeats'] += 1
            row = f'TI|ok|{m.index[label]}|{len(m.table)}'
        elif len(m.table) >= LABEL_LIMIT:
            row = f'TI|full|-|{len(m.table)}'
        else:
            m.index[label] = len(m.table)
            m.table.append(label)
            row = f'TI|ok|{m.index[label]}|{len(m.table)}'
        emit(f'TI {label_token(label)}', row)

    def find_line(label):
        emit(f'TF {label_token(label)}', f'TF|{m.index[label]}' if label in m.index else 'TF|-')

    def vis_line(reader):
        m.rebuild(reader)
        emit(f'V {label_token(reader)}', m.vis_row())

    def refresh_line():
        if len(m.table) > m.built:
            extra['refresh_growths'] += 1
        m.refresh()
        emit('VR', m.vis_row())

    reset_table()
    vis_line(BOTTOM)
    for _ in range(2500):
        label = random_label(6, 12, 3)
        intern_line(label)
        if rng.randrange(6) == 0:
            find_line(random_label(6, 12, 3))
    for label in list(m.table)[:50]:
        find_line(label)

    def encode_line():
        data = encode(m.cfg, m.table)
        emit('E', 'E|invalid' if data is None else f'E|{hexs(data)}')
        return data

    def decode_line(data):
        result, value = decode(data)
        extra['decode_errors'][result] = extra['decode_errors'].get(result, 0) + 1
        if result == 'ok':
            extra['decode_accepted'] += 1
            cfg, table = value
            emit(f'D {hexs(data)}', f'D|ok|{len(cfg.levels)}|{len(cfg.comps)}|{len(table)}|{hexs(encode(cfg, table))}')
        else:
            emit(f'D {hexs(data)}', f'D|{result}')

    def mutate_bytes(data):
        out = bytearray(data)
        for _ in range(1 + rng.randrange(3)):
            choice = rng.randrange(4)
            if choice == 0 and out:
                out[rng.randrange(len(out))] = rng.randrange(256)
            elif choice == 1 and out:
                out[rng.randrange(len(out))] ^= 1 << rng.randrange(8)
            elif choice == 2 and out:
                del out[rng.randrange(len(out))]
            else:
                out.insert(rng.randrange(len(out) + 1), rng.randrange(256))
        return bytes(out)

    encode_line()
    reset_table()
    for _ in range(40):
        intern_line(random_label(len(m.cfg.levels), len(m.cfg.comps), 3))
    good = encode_line()
    decode_line(good)
    for cut in range(len(good)):
        decode_line(good[:cut])
    decode_line(good + b'\x00')
    for _ in range(2500):
        decode_line(mutate_bytes(good))
    small_cfg, m.cfg = m.cfg, Config()
    reset_config()
    for raw in (b'LOW', b'HIGH'):
        config_line('CL', raw)
    for raw in (b'A', b'B'):
        config_line('CC', raw)
    reset_table()
    intern_line((1, frozenset({0, 1})))
    tiny = encode_line()
    for at in range(len(tiny)):
        for value in (0, 1, 2, 3, 0x20, 0x41, 0xFF):
            data = bytearray(tiny)
            data[at] = value
            decode_line(bytes(data))
    crafted = [b'ESLT\x01\x02\x00\x03LOW\x04HIGH\x02\x00\x01A\x01B\x03\x00\x00\x00\x00\x01\x02\x00\x00\x01\x01\x02\x00\x00\x01',
               b'ESLT\x01\x01\x00\x01A\x01\x00\x01A\x01\x00\x00\x00\x00',
               b'ESLT\x01\x01\x00\x01A\x01\x00\x01B\x02\x00\x00\x00\x00\x00\x00\x00',
               b'ESLT\x01\x00\x00', b'ESLT\x01\x00\x01', b'ESLT\x01\x01\x01', b'ESL', b'ESLX', b'ESLT', b'',
               b'ESLT\x01\x01\x00\x01A\x01\x01']
    for data in crafted:
        decode_line(data)
    reset_table()
    intern_line((2, frozenset()))
    encode_line()
    m.cfg = small_cfg
    reset_config()
    for raw in [b'UNCLASSIFIED', b'CONFIDENTIAL', b'SECRET', b'TOP SECRET']:
        config_line('CL', raw)
    for raw in [b'SI', b'TK', b'HCS', b'G', b'NOFORN', b'ORCON', b'RELIDO', b'FVEY']:
        config_line('CC', raw)
    reset_table()
    for _ in range(300):
        intern_line(random_label(4, 8, 3))
    big = encode_line()
    decode_line(big)
    for _ in range(300):
        decode_line(mutate_bytes(big))

    reset_table()
    vis_line(BOTTOM)
    readers = [BOTTOM, (2, frozenset({0, 1})), (3, frozenset(range(8))), (1, frozenset({2})), (3, frozenset())]
    for step in range(60):
        for _ in range(rng.randrange(1, 40)):
            intern_line(random_label(4, 8, 3))
        if step % 7 == 0:
            vis_line(rng.choice(readers))
        refresh_line()
        if rng.randrange(3) == 0:
            refresh_line()
    for reader in readers:
        vis_line(reader)
    reset_table()
    for i in range(1, 700):
        intern_line((i % 4, frozenset(c for c in range(8) if (i >> c) & 1)))
    for reader in readers:
        vis_line(reader)
        for _ in range(3):
            for _ in range(rng.randrange(0, 70)):
                intern_line(random_label(4, 8, 4))
            refresh_line()

    reset_table()
    vis_line((2, frozenset(range(0, 16, 2))))
    for grow in (1, 62, 1, 1, 63, 64, 65, 127, 128, 129, 1, 200, 300, 500, 700, 3, 61):
        for _ in range(grow):
            intern_line(random_label(4, 16, 5))
        refresh_line()
        refresh_line()
    for _ in range(40):
        vis_line(random_label(4, 16, 12) if rng.randrange(4) else (3, frozenset(range(16))))
        for _ in range(rng.randrange(0, 3)):
            for _ in range(rng.randrange(1, 90)):
                intern_line(random_label(4, 16, 5))
            refresh_line()

    def gate_line():
        n = len(m.table)
        labels = [rng.randrange(n + 5) if rng.randrange(8) else rng.choice([ID_NONE, n, n + 1, 0])
                  for _ in range(rng.randrange(0, 60))]
        spec = ''.join(rng.choice('pfmn') for _ in range(rng.randrange(0, len(labels) + 3)))
        slots = range(len(labels) + 3)
        gate = [m.gate(labels, s) for s in slots]
        for s in slots:
            extra['gate_slots'] += 1
            if s < len(labels) and labels[s] >= m.built:
                extra['stale_slots'] += 1
        filt = [g and s < len(spec) and spec[s] == 'p' for s, g in zip(slots, gate)]
        emit(f'G {ids_text_raw(labels)} {spec or "-"}',
             'G|' + ''.join('1' if x else '0' for x in gate) + '|' + ''.join('1' if x else '0' for x in filt) + '|' +
             '0' * len(gate) + '|' + ''.join('1' if x else '0' for x in gate))

    def brute_line():
        n = len(m.table)
        count = rng.randrange(0, 64)
        points = [rng.randrange(-40, 41) for _ in range(count)]
        for i in range(count):
            if i and rng.randrange(6) == 0:
                points[i] = points[rng.randrange(i)]
        shown = [i for i in range(n) if m.visible(i)]
        labels = [rng.choice(shown) if shown and rng.randrange(2) else rng.randrange(n) for _ in range(count)]
        k = rng.randrange(0, 13)
        q = rng.randrange(-50, 51)
        visible = [s for s in range(count) if m.gate(labels, s)]
        if len(visible) < count:
            extra['brute_cases_with_hidden'] += 1
        best = sorted(((points[s] - q) ** 2, s) for s in visible)[:k]
        emit(f'B {k} {q} {",".join(map(str, points)) or "-"} {ids_text_raw(labels)}',
             'B|' + (','.join(f'{s}:{d}' for d, s in best) or '-'))

    for reader in readers:
        vis_line(reader)
        for _ in range(400):
            gate_line()
        for _ in range(80):
            brute_line()
    for _ in range(30):
        intern_line(random_label(4, 8, 4))
    for _ in range(100):
        gate_line()
    refresh_line()
    for _ in range(100):
        gate_line()

    def subject_line(clearance, session):
        if dom(clearance, session):
            m.subject = (clearance, session)
            row = f'SU|1|{label_text(meet(session, clearance))}'
        else:
            m.subject = (clearance, clearance)
            row = f'SU|0|{label_text(clearance)}'
        emit(f'SU {label_token(clearance)} {label_token(session)}', row)

    def rule_lines(label):
        clearance, session = m.subject
        read = dom(meet(session, clearance), label)
        emit(f'SR {label_token(label)}', f'SR|{int(read)}')
        if not dom(clearance, label):
            verdict = 'above'
        elif not dom(label, session):
            verdict = 'down'
        else:
            verdict = 'allowed'
        extra['write_verdicts'][verdict] = extra['write_verdicts'].get(verdict, 0) + 1
        emit(f'SW {label_token(label)}', f'SW|{verdict}')
        if not read:
            modify = 'hidden'
        elif not dom(label, session):
            modify = 'down'
        else:
            modify = 'allowed'
        emit(f'SM {label_token(label)}', f'SM|{modify}')

    for _ in range(400):
        clearance = random_label(4, 6, 4)
        if rng.randrange(4):
            session = (rng.randrange(clearance[0] + 1), frozenset(x for x in clearance[1] if rng.randrange(2)))
        else:
            session = random_label(4, 6, 3)
        subject_line(clearance, session)
        clearance, session = m.subject
        emit('SD', f'SD|{label_text(session)}|allowed')
        for _ in range(4):
            label = random_label(4, 6, 3) if rng.randrange(3) else rng.choice([session, clearance, BOTTOM, join(session, (0, frozenset({5})))])
            rule_lines(label)

    def counter_line(kind, ident, delta):
        if ident == ID_NONE:
            result = 'invalid'
        elif kind == 'NA':
            if delta > U64_MAX - m.total:
                result = 'overflow'
                extra['counter_overflows'] += 1
            else:
                m.counts += [0] * (ident + 1 - len(m.counts))
                m.counts[ident] += delta
                m.total += delta
                result = 'ok'
        else:
            if ident >= len(m.counts):
                result = 'ok' if delta == 0 else 'underflow'
            elif m.counts[ident] < delta:
                result = 'underflow'
            else:
                m.counts[ident] -= delta
                m.total -= delta
                result = 'ok'
            if result == 'underflow':
                extra['counter_underflows'] += 1
        emit(f'{kind} {ident} {delta}', f'{kind}|{result}|{m.total}')

    def visible_total_line():
        total = sum(m.counts[i] for i in range(min(len(m.counts), m.built)) if m.visible(i))
        emit('NV', f'NV|{total}|' + (','.join(map(str, m.counts)) if m.counts else '-'))

    def counters_reset():
        m.counts, m.total = [], 0
        emit('NR', 'NR')

    counters_reset()
    for reader in readers:
        vis_line(reader)
        for _ in range(500):
            ident = rng.randrange(len(m.table) + 3) if rng.randrange(20) else ID_NONE
            if rng.randrange(3):
                counter_line('NA', ident, rng.randrange(50))
            else:
                counter_line('NS', ident, rng.randrange(60))
            if rng.randrange(8) == 0:
                visible_total_line()
        visible_total_line()
    counters_reset()
    counter_line('NA', 3, U64_MAX - 5)
    counter_line('NA', 9, 6)
    counter_line('NA', 9, 5)
    counter_line('NA', 0, 1)
    visible_total_line()
    counter_line('NS', 3, U64_MAX - 5)
    counter_line('NS', 200, 0)
    counter_line('NS', 200, 1)
    visible_total_line()
    vis_line((3, frozenset(range(8))))
    visible_total_line()
    for kind, count in stats.items():
        if count == 0:
            raise AssertionError('corpus has no ' + kind + ' rows')
    return '\n'.join(lines) + '\n', expected, stats, extra


def ids_text_raw(ids):
    return ','.join(map(str, ids)) if ids else '-'


def compare(label, got, want):
    rows = got.splitlines()
    if not want or len(rows) != len(want):
        raise AssertionError(f'{label}: {len(rows)} rows, expected {len(want)}')
    for i, (a, b) in enumerate(zip(rows, want)):
        if a != b:
            raise AssertionError(f'{label}: row {i}: {a[:200]!r} != {b[:200]!r}')


def check_fingerprints():
    pinned = json.loads((PACKAGE / 'source-sha256.json').read_text())
    if len(pinned) < 10:
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
        axioms, kernel = audit_kernel(Path(lake), PACKAGE, output, env, 'Labels')
    versions = {'lean': version.strip(), 'odin': odin_version.strip()}
    tools = {name: digest(Path(path)) for name, path in (('lean', lean), ('lake', lake), ('odin', odin))}
    return PACKAGE / '.lake/build/bin/label_model', output / 'odin_bridge', axioms, kernel, versions, tools


def first_row(expected, prefix, accept):
    return next((i for i, row in enumerate(expected) if row.startswith(prefix) and accept(row)), None)


def negative_controls(expected):
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

    def flip_first_zero(bits):
        i = bits.index('0')
        return bits[:i] + '1' + bits[i + 1:]

    def gate_tail(row):
        cells = row.split('|')
        cells[1] = cells[1][:-1] + '1'
        return '|'.join(cells)

    def filter_overreach(row):
        cells = row.split('|')
        i = next(j for j, (g, f) in enumerate(zip(cells[1], cells[2])) if g == '0')
        cells[2] = cells[2][:i] + '1' + cells[2][i + 1:]
        return '|'.join(cells)

    def visibility_extra(row):
        cells = row.split('|')
        words = cells[2].split(',')
        value = int(words[-1], 16)
        position = next(p for p in range(64) if not (value >> p) & 1)
        words[-1] = f'{value | (1 << position):x}'
        cells[2] = ','.join(words)
        return '|'.join(cells)

    semantic = {
        'join_is_intersection': ('L|', lambda r: r.split('|')[3] != r.split('|')[4],
                                 lambda r: '|'.join(r.split('|')[:3] + [r.split('|')[4], r.split('|')[4]])),
        'dominance_reversed': ('L|', lambda r: r.split('|')[1] != r.split('|')[2],
                               lambda r: '|'.join([r.split('|')[0], r.split('|')[2], r.split('|')[1]] + r.split('|')[3:])),
        'parse_accepts_unknown': ('M|unknowncomp', lambda r: True, lambda r: 'M|ok|0:-|' + '00'),
        'canonical_order_swapped': ('M|ok|', lambda r: '2f' in r.split('|')[3][len(r.split('|')[3]) // 2:] and r.split('|')[2].count(',') >= 1,
                                    lambda r: '|'.join(r.split('|')[:3] + [r.split('|')[3][::-1]])),
        'intern_reuses_id': ('TI|ok|', lambda r: r.split('|')[2] != '0' and r.split('|')[2] == str(int(r.split('|')[3]) - 1),
                             lambda r: '|'.join(r.split('|')[:2] + ['0'] + r.split('|')[3:])),
        'decode_accepts_trailing': ('D|trailing', lambda r: True, lambda r: 'D|ok|1|0|1|-'),
        'decode_accepts_duplicate_label': ('D|duplabel', lambda r: True, lambda r: 'D|ok|1|0|1|-'),
        'visibility_extra_bit': ('V|', lambda r: r.split('|')[2] != '-' and int(r.split('|')[2].split(',')[-1], 16) != (1 << 64) - 1,
                                 visibility_extra),
        'gate_reads_past_end': ('G|', lambda r: len(r.split('|')[1]) > 0, gate_tail),
        'filter_ignores_label': ('G|', lambda r: '0' in r.split('|')[1], filter_overreach),
        'brute_returns_hidden': ('B|', lambda r: r != 'B|-', lambda r: r + ',999:0'),
        'write_down_allowed': ('SW|down', lambda r: True, lambda r: 'SW|allowed'),
        'write_above_clearance': ('SW|above', lambda r: True, lambda r: 'SW|allowed'),
        'read_up': ('SR|0', lambda r: True, lambda r: 'SR|1'),
        'modify_hidden_reported': ('SM|hidden', lambda r: True, lambda r: 'SM|down'),
        'visible_total_includes_hidden': ('NV|', lambda r: r.split('|')[2] != '-',
                                          lambda r: '|'.join([r.split('|')[0], str(int(r.split('|')[1]) + 1)] + r.split('|')[2:])),
        'counter_wraps': ('NA|overflow', lambda r: True, lambda r: r.replace('NA|overflow', 'NA|ok', 1)),
    }
    for name, (prefix, accept, mutate) in semantic.items():
        index = first_row(expected, prefix, lambda row: accept(row) and mutate(row) != row)
        if index is None:
            raise AssertionError('no row for semantic negative control ' + name)
        mutated = list(expected)
        mutated[index] = mutate(expected[index])
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
    rejected = negative_controls(expected)
    modules = {module: set(re.findall(r'^theorem\s+(\w+)', (PACKAGE / f'Labels/{module}.lean').read_text(), re.M))
               for files in AREAS.values() for module in files}
    comparisons = {area: sum(count for kind, count in stats.items() if ROW_AREAS[kind] == area) for area in AREAS}
    if any(not comparisons[area] for area in AREAS):
        raise AssertionError('every area needs comparison rows')
    area_evidence = {area: {'theorems': sorted(name for name in axioms
                                               if name.removeprefix('Labels.') in set().union(*(modules[m] for m in files))),
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
