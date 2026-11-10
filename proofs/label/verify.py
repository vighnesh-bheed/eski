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
sys.path.insert(0, str(Path(__file__).resolve().parent))
from kernel_audit import audit as audit_kernel
import arrival
import keys

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(__file__).resolve().parent
SEED = 0x1A8E15
NAME_MAX = 64
MARKING_MAX = 32768
LEVEL_LIMIT = 256
COMP_LIMIT = 256
TRUST_LIMIT = 256
LABEL_LIMIT = 65535
ID_NONE = 65535
U64_MAX = (1 << 64) - 1
BOTTOM = (0, frozenset(), 0)
AREAS = {
    'lattice': ['Lattice', 'Trust'],
    'marking': ['Marking', 'MarkingTrust'],
    'interning': ['Intern'],
    'persistence': ['Codec'],
    'visibility': ['Visibility'],
    'admission': ['Admission', 'Search'],
    'rules': ['Rules'],
    'counters': ['Counters'],
    'contexts': ['Contexts'],
    'arrival': ['Arrival'],
    'resolution': ['KeyModel'],
    'confinement': ['KeyReads'],
    'placement': ['KeyWrites'],
    'purge': ['KeyPurge'],
    'plain': ['KeyPlain'],
}
KEY_AREAS = ('resolution', 'confinement', 'placement', 'purge', 'plain')
ROW_AREAS = {'L': 'lattice', 'CR': 'marking', 'CL': 'marking', 'CC': 'marking', 'CT': 'marking', 'M': 'marking', 'F': 'marking',
             'TR': 'interning', 'TI': 'interning', 'TF': 'interning', 'E': 'persistence', 'D': 'persistence',
             'V': 'visibility', 'VR': 'visibility', 'G': 'admission', 'B': 'admission', 'SU': 'rules', 'SR': 'rules', 'SW': 'rules',
             'SM': 'rules', 'SD': 'rules', 'NR': 'counters', 'NA': 'counters', 'NS': 'counters', 'NV': 'counters',
             'AH': 'contexts', 'AQ': 'contexts', 'AW': 'contexts', 'AX': 'arrival', 'AU': 'arrival', 'AC': 'arrival',
             'AT': 'arrival', 'AO': 'arrival', 'AR': 'arrival', 'AS': 'arrival',
             'KO': 'resolution', 'KR': 'confinement', 'KW': 'placement', 'KH': 'purge', 'KP': 'plain'}
KEY_SEED = 0x6B3E7
ARRIVAL_SEED = 0xA2217
ARRIVAL_NOTES = ['created', 'create_full', 'dropped', 'swept', 'find_ok', 'find_expired', 'find_other_login',
                 'find_outside_ceiling', 'form_marking', 'form_marking_trust', 'form_marking_context', 'form_context',
                 'form_token', 'token_ok', 'token_cached', 'token_expired', 'token_rejected', 'token_outside_ceiling',
                 'token_context_ok', 'token_context_refused', 'session_set', 'session_denied', 'arrived_session',
                 'arrived_prefixed', 'arrived_in_multi', 'queued', 'exec_clean', 'exec_dirty', 'exec_abort_arrival',
                 'find_expired_boundary', 'token_expired_boundary', 'swept_several']
ARRIVAL_SEMANTIC = {'expired_handle_used': 'find_expired', 'other_login_handle_used': 'find_other_login',
                    'handle_above_clearance_used': 'find_outside_ceiling', 'expired_token_used': 'token_expired',
                    'token_above_clearance_used': 'token_outside_ceiling', 'token_context_mismatch_used': 'token_context_refused',
                    'per_command_bypassed': 'refused_per_command', 'require_token_bypassed': 'refused_token_only',
                    'transaction_label_ignored': 'refused_transaction', 'nested_prefix_accepted': 'refused_nested',
                    'context_label_mismatch_accepted': 'refused_mismatch', 'top_only_accepted': 'refused_top',
                    'persistence_accepted': 'refused_persist', 'subscribe_without_session': 'refused_session_needed',
                    'label_above_clearance_accepted': 'refused_invalid', 'session_for_per_command_login': 'session_denied',
                    'context_cap_ignored': 'create_full', 'cron_keeps_expired': 'swept_several', 'dirty_exec_runs': 'exec_dirty',
                    'boundary_handle_used': 'find_expired_boundary', 'boundary_token_used': 'token_expired_boundary'}
NAME_PATTERN = re.compile(rb'[A-Z0-9][A-Z0-9_-]*( [A-Z0-9][A-Z0-9_-]*)*')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hexs(data):
    return data.hex() if data else '-'


def ids_text(ids):
    return ','.join(map(str, sorted(ids))) if ids else '-'


def label_text(label):
    return f'{label[0]}:{ids_text(label[1])}:{label[2]}'


def dom(a, b):
    return b[0] <= a[0] and b[1] <= a[1] and a[2] <= b[2]


def join(a, b):
    return (max(a[0], b[0]), a[1] | b[1], min(a[2], b[2]))


def meet(a, b):
    return (min(a[0], b[0]), a[1] & b[1], max(a[2], b[2]))


def ceiling(c, l):
    return l[0] <= c[0] and l[1] <= c[1] and l[2] <= c[2]


def ceiling_session(c):
    return (c[0], c[1], 0)


def rcmp(a, b):
    for x, y in ((a[0], b[0]), (len(a[1]), len(b[1])), (a[2], b[2])):
        if x != y:
            return 1 if x > y else -1
    return 0


def lattice_row(a, b):
    return (f'L|{int(dom(a, b))}|{int(dom(b, a))}|{label_text(join(a, b))}|{label_text(meet(a, b))}|'
            f'{int(ceiling(a, b))}|{int(ceiling(b, a))}|{rcmp(a, b)}')


def normalise(raw):
    return b' '.join(w for w in re.split(rb'[ \t]', raw) if w).upper()


def canonical(name):
    return 0 < len(name) <= NAME_MAX and NAME_PATTERN.fullmatch(name) is not None


class Config:
    def __init__(self):
        self.levels, self.comps, self.trusts = [], [], []

    def counts(self):
        return f'{len(self.levels)}|{len(self.comps)}|{len(self.trusts)}'

    def add(self, kind, raw):
        names = {'CL': self.levels, 'CC': self.comps, 'CT': self.trusts}[kind]
        limit = {'CL': LEVEL_LIMIT, 'CC': COMP_LIMIT, 'CT': TRUST_LIMIT}[kind]
        if len(names) >= limit:
            return {'CL': 'toomanylevels', 'CC': 'toomanycomps', 'CT': 'toomanytrusts'}[kind]
        n = normalise(raw)
        if len(n) > NAME_MAX:
            return 'toolong'
        if not n:
            return 'empty'
        if not canonical(n):
            return 'invalid'
        if (n in self.trusts) if kind == 'CT' else (n in self.levels or n in self.comps):
            return 'duplicate'
        names.append(n)
        return 'ok'

    def valid(self, label):
        return label[0] < len(self.levels) and all(c < len(self.comps) for c in label[1]) and label[2] < max(1, len(self.trusts))

    def format(self, label):
        if not self.valid(label):
            return None
        text = self.levels[label[0]]
        if label[1]:
            text += b'//' + b'/'.join(self.comps[c] for c in sorted(label[1]))
        if label[2]:
            text += b';' + self.trusts[label[2]]
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
    secrecy, semi, tail = text.partition(b';')
    label, err = parse_secrecy(cfg, secrecy, bool(semi))
    if err:
        return None, err
    if not semi:
        return label + (0,), None
    at, n = span(text, len(secrecy) + 1, len(text))
    if n == 0:
        return None, ('emptytrust', at, 0)
    trust = lookup(cfg.trusts, tail)
    if trust < 0:
        return None, ('unknowntrust', at, n)
    return label + (trust,), None


def parse_secrecy(cfg, text, suffixed):
    parts = text.split(b'/')
    starts = [0]
    for part in parts[:-1]:
        starts.append(starts[-1] + len(part) + 1)
    at, n = span(text, 0, len(parts[0]))
    if n == 0:
        return None, ('empty' if len(parts) == 1 and not suffixed else 'emptylevel', at, 0)
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
    out = bytearray(b'ESLT\x02')
    for names in (cfg.levels, cfg.comps, cfg.trusts):
        out += struct.pack('<H', len(names))
        for n in names:
            out += bytes([len(n)]) + n
    out += struct.pack('<H', len(table))
    for level, comps, trust in table:
        out += bytes([level, trust]) + struct.pack('<H', len(comps)) + bytes(sorted(comps))
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
        version = take(1)[0]
        if version not in (1, 2):
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
        ntrust = 0
        if version == 2:
            ntrust = struct.unpack('<H', take(2))[0]
            if ntrust > TRUST_LIMIT:
                return 'badtrustcount', None
            for _ in range(ntrust):
                length = take(1)[0]
                name = bytes(take(length))
                if not canonical(name):
                    return 'badname', None
                if name in cfg.trusts:
                    return 'dupname', None
                cfg.trusts.append(name)
        count = struct.unpack('<H', take(2))[0]
        if count == 0:
            return 'badlabelcount', None
        table, seen = [BOTTOM], {BOTTOM}
        for i in range(count):
            level = take(1)[0]
            if level >= nlev:
                return 'badlevel', None
            trust = 0
            if version == 2:
                trust = take(1)[0]
                if trust >= max(1, ntrust):
                    return 'badtrust', None
            n = struct.unpack('<H', take(2))[0]
            if n > ncomp:
                return 'badcomp', None
            ids = list(take(n))
            if any(x >= ncomp for x in ids) or any(b <= a for a, b in zip(ids, ids[1:])):
                return 'badcomp', None
            label = (level, frozenset(ids), trust)
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
    stats = {kind: 0 for kind, area in ROW_AREAS.items() if area not in ('contexts', 'arrival') + KEY_AREAS}
    extra = {'config_rejections': 0, 'parse_accepted': 0, 'parse_errors': {}, 'decode_errors': {}, 'decode_accepted': 0,
             'intern_repeats': 0, 'refresh_growths': 0, 'stale_slots': 0, 'gate_slots': 0, 'brute_cases_with_hidden': 0,
             'write_verdicts': {}, 'counter_overflows': 0, 'counter_underflows': 0, 'long_markings': 0}
    m = Model()

    def emit(line, row):
        lines.append(line)
        expected.append(row)
        stats[line.split(' ')[0]] += 1

    def random_label(levels, comps, picks=4, trusts=1):
        level = rng.randrange(levels) if levels else 0
        k = rng.randrange(picks + 1) if comps else 0
        label = (level, frozenset(rng.randrange(comps) for _ in range(k)))
        return label + (rng.randrange(trusts) if trusts > 1 else 0,)

    for _ in range(1500):
        a = random_label(256, 256, 20, rng.choice([1, 3, 256]))
        if rng.randrange(5):
            b = random_label(256, 256, 20, rng.choice([1, 3, 256]))
        else:
            b = (rng.randrange(a[0] + 1), frozenset(x for x in a[1] if rng.randrange(2)),
                 rng.randrange(a[2], 256) if rng.randrange(2) else rng.randrange(a[2] + 1))
        emit(f'L {label_token(a)} {label_token(b)}', lattice_row(a, b))
    full = (255, frozenset(range(256)), 0)
    trusted_full = (255, frozenset(range(256)), 255)
    for a, b in ((BOTTOM, BOTTOM), (BOTTOM, full), (full, full), (full, trusted_full), (trusted_full, full),
                 ((0, frozenset(), 1), BOTTOM), (BOTTOM, (0, frozenset(), 1)),
                 ((3, frozenset({0, 63, 64, 127, 128, 255}), 2), (3, frozenset({63, 128}), 2)),
                 ((7, frozenset(), 0), (7, frozenset({200}), 0)), ((4, frozenset({1, 2}), 1), (4, frozenset({3, 5}), 1)),
                 ((4, frozenset({1, 2}), 1), (4, frozenset({3, 5}), 2))):
        emit(f'L {label_token(a)} {label_token(b)}', lattice_row(a, b))

    def config_line(kind, raw):
        result = m.cfg.add(kind, raw)
        if result != 'ok':
            extra['config_rejections'] += 1
        names = {'CL': m.cfg.levels, 'CC': m.cfg.comps, 'CT': m.cfg.trusts}[kind]
        last = hexs(names[-1]) if result == 'ok' else '-'
        emit(f'{kind} {hexs(raw)}', f'{kind}|{result}|{m.cfg.counts()}|{last}')

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
              b'\x00', b'\n', b'\x7f', b'\xff', b'-', b'_', b'a', b';', b';', b' ; ', b'web', b'Vetted', b'TRUSTED']

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
        if rng.randrange(3) == 0:
            out += rng.choice([b';', b' ; ', b';']) + rng.choice([b'web', b'Vetted', b'TRUSTED', b'trusty', b'', b'SI'])
        return out

    def mutate_marking(text):
        data = bytearray(text)
        for _ in range(1 + rng.randrange(3)):
            choice = rng.randrange(5)
            if choice == 0 and data:
                data[rng.randrange(len(data))] ^= 0x20
            elif choice == 1:
                data.insert(rng.randrange(len(data) + 1), rng.choice(b' \t/;'))
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
    for raw in (b'web', b' vetted ', b'Trusted', b'TRUSTED', b'SECRET', b'si', b'A;B', b'', b'X' * 65, b'_t', b'OPEN\tWEB'):
        config_line('CT', raw)
    for _ in range(4000):
        marking_line(fuzz_marking())
    for _ in range(3000):
        marking_line(structured_marking())
    for _ in range(1500):
        marking_line(mutate_marking(m.cfg.format(random_label(len(m.cfg.levels), len(m.cfg.comps), 6, len(m.cfg.trusts)))))
    for text in (b'', b' \t ', b'//SI', b'  //SI', b'SECRT', b'  SECRT  //SI', b'SECRET/SI', b'SECRET/', b'SECRET / /SI',
                 b'SECRET//', b'SECRET// ', b'SECRET//SI/', b'SECRET///SI', b'SECRET//SI//TK', b'SECRET//SI/ XYZ /TK',
                 b'SECRET//SI/si', b'SECRET//TK/ tk ', b'SECRET\x00', b'SECRET//S\nI', b' ' * (MARKING_MAX + 1),
                 b' ' * MARKING_MAX, b'SECRET//' + b'SI/' * 10000 + b'TK', b'SECRET;TRUSTED', b'SECRET//SI ; vetted ',
                 b'SECRET;', b'SECRET; \t', b';TRUSTED', b' ;TRUSTED', b'SECRET;TRUSTY', b'SECRET; trusted;web',
                 b'SECRET;TRUSTED//SI', b'SECRET//;WEB', b'SECRT;WEB', b';', b'SECRET;SECRET', b'SECRET//SI/TK;open web'):
        marking_line(text)
    for _ in range(400):
        format_line(random_label(len(m.cfg.levels) + 2, len(m.cfg.comps) + 3, 4, len(m.cfg.trusts) + 2))

    reset_config()
    for i in range(LEVEL_LIMIT + 1):
        config_line('CL', f'L{i}'.encode())
    for i in range(COMP_LIMIT + 1):
        config_line('CC', f'c{i}'.encode())
    for i in range(TRUST_LIMIT + 1):
        config_line('CT', f't{i}'.encode())
    for _ in range(600):
        label = random_label(256, 256, 40, 256)
        marking_line(m.cfg.format(label))
        if rng.randrange(2):
            marking_line(mutate_marking(m.cfg.format(label)))
    marking_line(m.cfg.format((255, frozenset(range(256)), 255)))
    for _ in range(200):
        format_line(random_label(256, 256, 30, 256))

    alphabet = b'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_ \t.!/;'
    reset_config()
    for kind, count in (('CL', 30), ('CC', 70), ('CT', 20)):
        for _ in range(count):
            config_line(kind, bytes(rng.choice(alphabet) for _ in range(rng.randrange(0, 12))))
    for _ in range(1500):
        if m.cfg.levels and rng.randrange(3):
            label = random_label(len(m.cfg.levels), len(m.cfg.comps), 5, len(m.cfg.trusts))
            text = m.cfg.format(label)
            marking_line(mutate_marking(text) if rng.randrange(2) else text)
        else:
            marking_line(bytes(rng.choice(alphabet) for _ in range(rng.randrange(0, 30))))

    reset_config()
    for text in (b'SECRET', b'', b'//X', b'A//B', b'A;B'):
        marking_line(text)
    format_line(BOTTOM)
    format_line((0, frozenset(), 1))

    reset_config()
    for raw in (b'UNCLASSIFIED', b'CONFIDENTIAL', b'SECRET', b'TOP SECRET'):
        config_line('CL', raw)
    for raw in (b'SI', b'TK', b'HCS', b'G', b'NOFORN', b'ORCON', b'RELIDO', b'FVEY'):
        config_line('CC', raw)
    for raw in (b'WEB', b'VETTED', b'TRUSTED'):
        config_line('CT', raw)

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
        label = random_label(6, 12, 3, 3)
        intern_line(label)
        if rng.randrange(6) == 0:
            find_line(random_label(6, 12, 3, 3))
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
            emit(f'D {hexs(data)}', f'D|ok|{cfg.counts()}|{len(table)}|{hexs(encode(cfg, table))}')
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
        intern_line(random_label(len(m.cfg.levels), len(m.cfg.comps), 3, len(m.cfg.trusts)))
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
    for raw in (b'LO', b'LP'):
        config_line('CT', raw)
    reset_table()
    intern_line((1, frozenset({0, 1}), 1))
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
               b'ESLT\x01\x01\x00\x01A\x01\x01',
               b'ESLT\x01\x02\x00\x03LOW\x04HIGH\x02\x00\x01A\x01B\x02\x00\x00\x00\x00\x01\x02\x00\x00\x01',
               b'ESLT\x02\x01\x00\x01A\x00\x00\x01\x00\x01A\x01\x00\x00\x00\x00\x00',
               b'ESLT\x02\x01\x00\x01A\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x01\x00\x00',
               b'ESLT\x02\x01\x00\x01A\x00\x00\x01\x01', b'ESLT\x02\x01\x00\x01A\x00\x00\x01',
               b'ESLT\x02\x01\x00\x01A\x00\x00\x01\x00\x01A\x01\x00\x00\x00',
               b'ESLT\x02\x01\x00\x01A\x00\x00\x02\x00\x01A\x01a\x01\x00\x00\x00\x00\x00',
               b'ESLT\x02\x01\x00\x01A\x00\x00\x02\x00\x01X\x01X\x01\x00\x00\x00\x00\x00',
               b'ESLT\x03\x01\x00\x01A\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00']
    for data in crafted:
        decode_line(data)
    reset_table()
    intern_line((2, frozenset(), 0))
    encode_line()
    reset_table()
    intern_line((0, frozenset(), 3))
    encode_line()
    m.cfg = small_cfg
    reset_config()
    for raw in [b'UNCLASSIFIED', b'CONFIDENTIAL', b'SECRET', b'TOP SECRET']:
        config_line('CL', raw)
    for raw in [b'SI', b'TK', b'HCS', b'G', b'NOFORN', b'ORCON', b'RELIDO', b'FVEY']:
        config_line('CC', raw)
    for raw in [b'WEB', b'VETTED', b'TRUSTED']:
        config_line('CT', raw)
    reset_table()
    for _ in range(300):
        intern_line(random_label(4, 8, 3, 3))
    big = encode_line()
    decode_line(big)
    for _ in range(300):
        decode_line(mutate_bytes(big))

    reset_table()
    vis_line(BOTTOM)
    readers = [BOTTOM, (2, frozenset({0, 1}), 0), (3, frozenset(range(8)), 0), (1, frozenset({2}), 0), (3, frozenset(), 0),
               (3, frozenset(range(8)), 1), (2, frozenset({0, 1}), 2)]
    for step in range(60):
        for _ in range(rng.randrange(1, 40)):
            intern_line(random_label(4, 8, 3, 3))
        if step % 7 == 0:
            vis_line(rng.choice(readers))
        refresh_line()
        if rng.randrange(3) == 0:
            refresh_line()
    for reader in readers:
        vis_line(reader)
    reset_table()
    for i in range(1, 700):
        intern_line((i % 4, frozenset(c for c in range(8) if (i >> c) & 1), (i >> 8) % 3))
    for reader in readers:
        vis_line(reader)
        for _ in range(3):
            for _ in range(rng.randrange(0, 70)):
                intern_line(random_label(4, 8, 4, 3))
            refresh_line()

    reset_table()
    vis_line((2, frozenset(range(0, 16, 2)), 1))
    for grow in (1, 62, 1, 1, 63, 64, 65, 127, 128, 129, 1, 200, 300, 500, 700, 3, 61):
        for _ in range(grow):
            intern_line(random_label(4, 16, 5, 3))
        refresh_line()
        refresh_line()
    for _ in range(40):
        vis_line(random_label(4, 16, 12, 3) if rng.randrange(4) else (3, frozenset(range(16)), 0))
        for _ in range(rng.randrange(0, 3)):
            for _ in range(rng.randrange(1, 90)):
                intern_line(random_label(4, 16, 5, 3))
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
        intern_line(random_label(4, 8, 4, 3))
    for _ in range(100):
        gate_line()
    refresh_line()
    for _ in range(100):
        gate_line()

    def subject_line(clearance, session):
        if ceiling(clearance, session):
            m.subject = (clearance, session)
            row = f'SU|1|{label_text(session)}'
        else:
            m.subject = (clearance, ceiling_session(clearance))
            row = f'SU|0|{label_text(ceiling_session(clearance))}'
        emit(f'SU {label_token(clearance)} {label_token(session)}', row)

    def rule_lines(label):
        clearance, session = m.subject
        read = ceiling(clearance, session) and dom(session, label)
        emit(f'SR {label_token(label)}', f'SR|{int(read)}')
        if not ceiling(clearance, label):
            verdict = 'above'
        elif label != session:
            verdict = 'notsession'
        else:
            verdict = 'allowed'
        extra['write_verdicts'][verdict] = extra['write_verdicts'].get(verdict, 0) + 1
        emit(f'SW {label_token(label)}', f'SW|{verdict}')
        if not read:
            modify = 'hidden'
        elif label != session:
            modify = 'notsession'
        else:
            modify = 'allowed'
        emit(f'SM {label_token(label)}', f'SM|{modify}')

    for _ in range(400):
        clearance = random_label(4, 6, 4, 3)
        if rng.randrange(4):
            session = (rng.randrange(clearance[0] + 1), frozenset(x for x in clearance[1] if rng.randrange(2)),
                       rng.randrange(clearance[2] + 1))
        else:
            session = random_label(4, 6, 3, 3)
        subject_line(clearance, session)
        clearance, session = m.subject
        emit('SD', f'SD|{label_text(session)}|allowed')
        for _ in range(4):
            label = random_label(4, 6, 3, 3) if rng.randrange(3) else rng.choice(
                [session, clearance, BOTTOM, join(session, (0, frozenset({5}), 2)), (session[0], session[1], (session[2] + 1) % 3)])
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
    vis_line((3, frozenset(range(8)), 0))
    visible_total_line()
    vis_line((3, frozenset(range(8)), 1))
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


LINK_INPUTS = ['.build/diagnostics/release/libeski-diagnostics.a', '.build/diagnostics/libunwind.so',
               '.build/lua/release/libeslua-runtime.a']


def overlay(output, bridge='arrival_bridge.odin', name='overlay'):
    root = output / name
    if root.exists():
        shutil.rmtree(root)
    shutil.copytree(ROOT / 'src', root / 'src')
    (root / 'src/main.odin').unlink()
    for path in (root / 'src').glob('*_test.odin'):
        path.unlink()
    shutil.copyfile(PACKAGE / bridge, root / 'src/proof_bridge.odin')
    (root / '.build').symlink_to(ROOT / '.build', target_is_directory=True)
    copied = {str(p.relative_to(root)): digest(p) for p in sorted((root / 'src').rglob('*')) if p.is_file()}
    for path, sha in copied.items():
        if path != 'src/proof_bridge.odin' and sha != digest(ROOT / path):
            raise AssertionError('overlay source identity failure')
    (output / f'{name}-sha256.json').write_text(json.dumps(copied, indent=2) + '\n')
    return root


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
    link_hashes = {name: digest(ROOT / name) for name in LINK_INPUTS}
    root = overlay(output)
    key_root = overlay(output, 'key_bridge.odin', 'overlay-keys')
    commands = [([lake, 'build'], PACKAGE),
                ([odin, 'build', str(PACKAGE / 'bridge.odin'), '-file', '-out:' + str(output / 'odin_bridge'),
                  '-thread-count:2', '-vet', '-strict-style'], ROOT),
                ([odin, 'build', str(root / 'src'), '-out:' + str(output / 'arrival_bridge'),
                  '-thread-count:2', '-vet', '-strict-style'], ROOT),
                ([odin, 'build', str(key_root / 'src'), '-out:' + str(output / 'key_bridge'),
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
    if any(digest(ROOT / name) != sha for name, sha in link_hashes.items()):
        raise AssertionError('prebuilt native inputs changed during check')
    versions = {'lean': version.strip(), 'odin': odin_version.strip()}
    tools = {name: digest(Path(path)) for name, path in (('lean', lean), ('lake', lake), ('odin', odin))}
    return (PACKAGE / '.lake/build/bin/label_model', output / 'odin_bridge', output / 'arrival_bridge',
            output / 'key_bridge', axioms, kernel, versions, tools, link_hashes)


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
        'parse_accepts_unknown': ('M|unknowncomp', lambda r: True, lambda r: 'M|ok|0:-:0|' + '00'),
        'parse_drops_trust': ('M|ok|', lambda r: not r.split('|')[2].endswith(':0'),
                              lambda r: '|'.join(r.split('|')[:2] + [r.split('|')[2].rsplit(':', 1)[0] + ':0'] + r.split('|')[3:])),
        'parse_accepts_unknown_trust': ('M|unknowntrust', lambda r: True, lambda r: 'M|ok|0:-:0|' + '00'),
        'trust_not_reversed': ('L|', lambda r: r.split('|')[3].rsplit(':', 1)[1] != r.split('|')[4].rsplit(':', 1)[1],
                               lambda r: '|'.join(r.split('|')[:3] + [r.split('|')[4], r.split('|')[3]] + r.split('|')[5:])),
        'ceiling_is_dominance': ('L|', lambda r: r.split('|')[1] != r.split('|')[5],
                                 lambda r: '|'.join(r.split('|')[:5] + [r.split('|')[1]] + r.split('|')[6:])),
        'resolution_reversed': ('L|', lambda r: r.split('|')[7] != '0',
                                lambda r: '|'.join(r.split('|')[:7] + [str(-int(r.split('|')[7]))])),
        'decode_accepts_bad_trust': ('D|badtrust', lambda r: True, lambda r: 'D|ok|1|0|0|1|-'),
        'canonical_order_swapped': ('M|ok|', lambda r: '2f' in r.split('|')[3][len(r.split('|')[3]) // 2:] and r.split('|')[2].count(',') >= 1,
                                    lambda r: '|'.join(r.split('|')[:3] + [r.split('|')[3][::-1]])),
        'intern_reuses_id': ('TI|ok|', lambda r: r.split('|')[2] != '0' and r.split('|')[2] == str(int(r.split('|')[3]) - 1),
                             lambda r: '|'.join(r.split('|')[:2] + ['0'] + r.split('|')[3:])),
        'decode_accepts_trailing': ('D|trailing', lambda r: True, lambda r: 'D|ok|1|0|0|1|-'),
        'decode_accepts_duplicate_label': ('D|duplabel', lambda r: True, lambda r: 'D|ok|1|0|0|1|-'),
        'visibility_extra_bit': ('V|', lambda r: r.split('|')[2] != '-' and int(r.split('|')[2].split(',')[-1], 16) != (1 << 64) - 1,
                                 visibility_extra),
        'gate_reads_past_end': ('G|', lambda r: len(r.split('|')[1]) > 0, gate_tail),
        'filter_ignores_label': ('G|', lambda r: '0' in r.split('|')[1], filter_overreach),
        'brute_returns_hidden': ('B|', lambda r: r != 'B|-', lambda r: r + ',999:0'),
        'write_elsewhere_allowed': ('SW|notsession', lambda r: True, lambda r: 'SW|allowed'),
        'write_above_clearance': ('SW|above', lambda r: True, lambda r: 'SW|allowed'),
        'read_up': ('SR|0', lambda r: True, lambda r: 'SR|1'),
        'modify_hidden_reported': ('SM|hidden', lambda r: True, lambda r: 'SM|notsession'),
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


def arrival_controls(expected, marks):
    cases = {'arrival_empty': '', 'arrival_truncated': '\n'.join(expected[:-1]) + '\n',
             'arrival_extra': '\n'.join(expected + [expected[0]]) + '\n'}
    kinds = {}
    for i, row in enumerate(expected):
        kind = row.split('|')[0]
        if kind not in kinds or row.count('|') > expected[kinds[kind]].count('|'):
            kinds[kind] = i
    for kind, i in sorted(kinds.items()):
        cells = expected[i].split('|')
        for column in range(1, len(cells)):
            mutant = list(cells)
            mutant[column] = 'controlled-mutant'
            mutated = list(expected)
            mutated[i] = '|'.join(mutant)
            cases[f'arrival_{kind}_column_{column}'] = '\n'.join(mutated) + '\n'

    def accepted(row):
        cells = row.split('|')
        if cells[0] == 'AQ':
            return 'AQ|h0|' + cells[2]
        if cells[0] == 'AW':
            return f'AW|{int(cells[1]) + 1}'
        if cells[1].startswith('no:'):
            return '|'.join([cells[0], 'ok:0:-:0:1:-', 'OK'] + cells[-2:])
        return '|'.join([cells[0], cells[1], 'exec' if cells[2].startswith('EXECABORT') else 'OK'] + cells[-2:])

    for name, event in ARRIVAL_SEMANTIC.items():
        if event not in marks:
            raise AssertionError('no row for semantic negative control ' + name)
        i = marks[event]
        mutated = list(expected)
        mutated[i] = accepted(expected[i])
        if mutated[i] == expected[i]:
            raise AssertionError('semantic negative control does not change its row: ' + name)
        cases['arrival_semantic_' + name] = '\n'.join(mutated) + '\n'
    rejected = []
    for name, mutant in cases.items():
        try:
            compare(name, mutant, expected)
        except AssertionError:
            rejected.append(name)
        else:
            raise AssertionError('negative control accepted: ' + name)
    return rejected


def key_run(bridge, lines, path):
    path.write_text('\n'.join(lines) + '\n')
    result = subprocess.run([str(bridge), str(path)], text=True, capture_output=True)
    if result.returncode or result.stderr:
        raise AssertionError(f'key bridge: exit {result.returncode}, stderr: {result.stderr[-2000:]}')
    return result.stdout.splitlines()


def key_match(got, want):
    return want is None or (got in want if isinstance(want, set) else got == want)


def key_compare(label, got, want):
    if len(got) != len(want):
        raise AssertionError(f'{label}: {len(got)} rows, expected {len(want)}')
    for i, (a, b) in enumerate(zip(got, want)):
        if not key_match(a, b):
            raise AssertionError(f'{label}: row {i}: {a[:200]!r} != {str(b)[:200]!r}')


def key_evidence(bridge, lean_model, output):
    rng = random.Random(KEY_SEED)
    sessions = keys.corpus(rng, 77, 48, 170)
    stats = {'KO': 0, 'KR': 0, 'KW': 0, 'KH': 0, 'KP': 0}
    detail = {'sessions': 0, 'rows': 0, 'randomkey_rows': 0, 'notes': {}, 'commands': {}}
    real = []
    work = output / 'keys'
    work.mkdir(exist_ok=True)
    hashes = []
    for k, (lines, rows, cmds, notes) in enumerate(sessions):
        got = key_run(bridge, lines, work / f'session-{k}.txt')
        if got[0] != 'S|3|1':
            raise AssertionError('key bridge did not start labelled: ' + got[0])
        key_compare(f'key session {k}', got[1:], rows)
        hashes.append(hashlib.sha256('\n'.join(got).encode()).hexdigest())
        real.append(got[1:])
        detail['sessions'] += 1
        for (lab, cmd, args), row in zip(cmds, rows):
            if cmd == 'T':
                continue
            stats[keys.row_kind(cmd)] += 1
            detail['rows'] += 1
            detail['commands'][cmd] = detail['commands'].get(cmd, 0) + 1
            if isinstance(row, set):
                detail['randomkey_rows'] += 1
        for name, n in notes.items():
            detail['notes'][name] = detail['notes'].get(name, 0) + n
    missing = [n for n in keys.NOTES if not detail['notes'].get(n)]
    if missing:
        raise AssertionError('key corpus misses ' + ', '.join(missing))
    rlines, rrows = keys.resolution_trace(sessions)
    rpath = work / 'resolution-cases.txt'
    rpath.write_text('\n'.join(rlines) + '\n')
    result = subprocess.run([str(lean_model.resolve()), str(rpath)], text=True, capture_output=True)
    if result.returncode or result.stderr:
        raise AssertionError(f'lean key resolution: exit {result.returncode}, stderr: {result.stderr[-2000:]}')
    compare('lean key resolution', result.stdout, rrows)
    queried = [r for r in rrows if r.startswith('KQ|')]
    if len(queried) != stats['KO']:
        raise AssertionError('Lean resolution rows do not cover every LABEL OF row')
    detail['lean_resolution_rows'] = len(rrows)
    detail['lean_resolution_queries'] = len(queried)
    twins = keys.twin_corpus(random.Random(KEY_SEED ^ 0x7), 77, 30)
    detail['twin_pairs'] = detail['twin_hidden'] = detail['twin_raw_rows'] = 0
    for k, (base, twin, observer) in enumerate(twins):
        la = [keys.scheme_line(77, True)] + [keys.raw_line(*c) for c in base]
        lb = [keys.scheme_line(77, True)] + [keys.raw_line(*c) for c in twin]
        oa = key_run(bridge, la, work / f'twin-{k}-base.txt')[1:]
        ob = key_run(bridge, lb, work / f'twin-{k}-hidden.txt')[1:]
        key_compare(f'twin {k} base', oa, keys.twin_rows(base))
        key_compare(f'twin {k} hidden', ob, keys.twin_rows(twin))
        j = 0
        for i, c in enumerate(twin):
            if j < len(base) and c is base[j]:
                if c[0] is not None and keys.sees(observer, c[0]):
                    if oa[j] != ob[i]:
                        raise AssertionError(f'twin {k}: a hidden command changed a visible reply at row {j}')
                    stats['KH'] += 1
                    if c[1] in ('RAWSCAN', 'RANDOMKEY'):
                        detail['twin_raw_rows'] += 1
                j += 1
        if j != len(base):
            raise AssertionError('twin merge lost base commands')
        detail['twin_pairs'] += 1
        detail['twin_hidden'] += len(twin) - len(base)
    p10 = random.Random(KEY_SEED ^ 0x10)
    detail['p10_runs'] = 0
    for k in range(6):
        writes, reads = keys.p10_commands(p10)
        plain_rows, _ = keys.simulate(writes + reads, labelled=False)
        body = [keys.row_line(l, c, a, labelled=False) for l, c, a in writes + reads]
        plain = key_run(bridge, [f'S L0,L1 - - 77 0'] + body, work / f'p10-{k}-plain.txt')
        single = key_run(bridge, [f'S L0 - - 77 1'] + body, work / f'p10-{k}-single.txt')
        if plain[0] != 'S|2|0' or single[0] != 'S|1|0':
            raise AssertionError('P10 runs did not configure the expected schemes')
        key_compare(f'p10 {k} plain', plain[1:], plain_rows)
        if single[1:] != plain[1:]:
            raise AssertionError('single-level scheme replies differ from labels-off replies')
        n = len(reads)
        bottom = [keys.row_line((0, 0, 0), c, a) for _, c, a in reads]
        upper = [keys.row_line((1, 0, 0), c, a) for _, c, a in reads]
        applied = key_run(bridge, [f'S L0,L1 - - 77 0'] + body + ['A'] + bottom + upper, work / f'p10-{k}-applied.txt')
        if applied[1 + len(body)] != 'A|1':
            raise AssertionError('P10 run did not switch labels on')
        plain_reads = plain[1 + len(writes):]
        names = {r for r in plain_reads}
        for block in (applied[2 + len(body):2 + len(body) + n], applied[2 + len(body) + n:]):
            for i, (_, cmd, _) in enumerate(reads):
                if cmd == 'RANDOMKEY':
                    if not key_match(block[i], plain_rows[len(writes) + i]):
                        raise AssertionError(f'P10 RANDOMKEY row {i} returned an unknown name')
                elif block[i] != plain_reads[i]:
                    raise AssertionError(f'P10 row {i} {cmd}: {plain_reads[i][:200]} != {block[i][:200]}')
        stats['KP'] += len(body) * 2 + 2 * n
        detail['p10_runs'] += 1
        del names
    mutants = {}
    for name, fn in keys.mutants().items():
        differing = 0
        for (lines, rows, cmds, _), got in zip(sessions, real):
            mrows, _ = keys.simulate(cmds, mutant=fn)
            differing += sum(1 for a, b in zip(got, mrows) if not key_match(a, b))
        if not differing:
            raise AssertionError('key model mutant accepted: ' + name)
        mutants['key_' + name] = differing
    seen = {}
    for k, (lines, rows, cmds, _) in enumerate(sessions):
        for i, (lab, cmd, args) in enumerate(cmds):
            if cmd != 'T' and cmd not in seen:
                seen[cmd] = (k, i)
    for cmd, (k, i) in sorted(seen.items()):
        mutated = list(real[k])
        mutated[i] = mutated[i] + 'controlled-mutant'
        try:
            key_compare('key control', mutated, sessions[k][1])
        except AssertionError:
            mutants['key_row_' + cmd.lower()] = 1
        else:
            raise AssertionError('key row control accepted: ' + cmd)
    detail['sessions_sha256'] = hashlib.sha256('\n'.join(hashes).encode()).hexdigest()
    return stats, detail, mutants


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
    lean_model, odin_bridge, arrival_bridge, key_bridge, axioms, kernel, versions, tools, link_hashes = build(
        output, args.lean_bin, args.odin)
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
    helpers = {'Config': Config, 'parse': parse, 'lookup': lookup, 'label_text': label_text, 'hexs': hexs}
    atrace, aexpected, astats, anotes, marks = arrival.corpus(helpers, ARRIVAL_SEED)
    missing = [note for note in ARRIVAL_NOTES if not anotes.get(note)]
    if missing:
        raise AssertionError('arrival corpus misses ' + ', '.join(missing))
    apath = output / 'arrival-cases.txt'
    apath.write_text(atrace)
    for name, binary in (('lean', lean_model), ('odin', arrival_bridge)):
        result = subprocess.run([str(binary.resolve()), str(apath)], text=True, capture_output=True)
        if result.returncode or result.stderr:
            raise AssertionError(f'arrival {name}: exit {result.returncode}, stderr: {result.stderr[-2000:]}')
        (output / f'arrival-{name}-results.txt').write_text(result.stdout)
        compare('arrival ' + name, result.stdout, aexpected)
        results['arrival_' + name] = hashlib.sha256(result.stdout.encode()).hexdigest()
    if results['arrival_lean'] != results['arrival_odin']:
        raise AssertionError('Lean oracle and Odin arrival rows differ')
    if set(stats) & set(astats) or set(astats) != {k for k, a in ROW_AREAS.items() if a in ('contexts', 'arrival')}:
        raise AssertionError('arrival row kinds overlap the label rows or miss a kind')
    stats.update(astats)
    extra['arrival'] = anotes
    kstats, kdetail, kmutants = key_evidence(key_bridge, lean_model, output)
    stats.update(kstats)
    extra['keys'] = kdetail
    extra['key_mutants'] = kmutants
    rejected = negative_controls(expected) + arrival_controls(aexpected, marks) + sorted(kmutants)
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
    receipt = {'rows': stats, 'details': extra, 'total_rows': len(expected) + len(aexpected) + sum(kstats.values()), 'seed': hex(SEED),
               'arrival_seed': hex(ARRIVAL_SEED), 'link_input_sha256': link_hashes,
               'overlay_manifest_sha256': digest(output / 'overlay-sha256.json'),
               'key_overlay_manifest_sha256': digest(output / 'overlay-keys-sha256.json'), 'key_seed': hex(KEY_SEED),
               'toolchain': (PACKAGE / 'lean-toolchain').read_text().strip(),
               'area_evidence': area_evidence, 'checked_theorem_axioms': axioms,
               'kernel_inventory_sha256': digest(output / 'kernel-inventory.json'),
               'kernel_checked_theorems': len(kernel['theorem_axioms']),
               'source_sha256': fingerprints, 'versions': versions, 'tool_sha256': tools,
               'trace_sha256': hashlib.sha256(trace.encode()).hexdigest(),
               'arrival_trace_sha256': hashlib.sha256(atrace.encode()).hexdigest(), 'results_sha256': results,
               'executable_sha256': {'lean': digest(lean_model), 'odin': digest(odin_bridge),
                                     'arrival_odin': digest(arrival_bridge), 'key_odin': digest(key_bridge)},
               'proof_source_sha256': {str(p.relative_to(PACKAGE)): digest(p) for p in sorted(PACKAGE.rglob('*'))
                                       if p.is_file() and not {'.lake', '.build', '__pycache__'} & set(p.parts)},
               'negative_controls_rejected': rejected,
               'odin_correspondence': 'finite implementation comparisons; no verified translation'}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    summary = {'rows': stats, 'details': extra, 'total_rows': len(expected) + len(aexpected) + sum(kstats.values()), 'theorems': len(axioms),
               'kernel_checked_theorems': receipt['kernel_checked_theorems'],
               'negative_controls_rejected': len(rejected), 'receipt': str(output / 'receipt.json')}
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    run()
