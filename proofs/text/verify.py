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
SEED = 0x7E575EED
UCD_SHA256 = {'UnicodeData.txt': '2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c',
              'SpecialCasing.txt': 'efc25faf19de21b92c1194c111c932e03d2a5eaf18194e33f1156e96de4c9588'}
VOCABULARY = ROOT / 'src/stem_english/testdata/voc.txt'
STEMS = ROOT / 'src/stem_english/testdata/output.txt'
DEFAULT_STOP = ['a', 'is', 'the', 'an', 'and', 'are', 'as', 'at', 'be', 'but', 'by', 'for', 'if', 'in', 'into', 'it',
                'no', 'not', 'of', 'on', 'or', 'such', 'that', 'their', 'then', 'there', 'these', 'they', 'this', 'to',
                'was', 'will', 'with']
AREAS = {
    'classes': ['Classes'],
    'tokenizer': ['Tokenize'],
    'folding': ['Fold'],
    'stopwords': ['Stop'],
    'analysis': ['Analyze'],
}
ROW_AREAS = {'BC': 'classes', 'TK': 'tokenizer', 'FO': 'folding', 'LT': 'folding', 'EU': 'folding', 'TF': 'folding',
             'SB': 'stopwords', 'SQ': 'stopwords', 'SM': 'analysis', 'AN': 'analysis'}
PUNCT = bytes(b for b in range(33, 127) if not (48 <= b <= 57 or 65 <= b <= 90 or 97 <= b <= 122))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hexs(data):
    return bytes(data).hex() if data else '-'


def bit(v):
    return '1' if v else '0'


def is_alnum(b):
    return 48 <= b <= 57 or 65 <= b <= 90 or 97 <= b <= 122


def is_control(b):
    return b < 32 or b == 127


def is_separator(b):
    return b in (9, 32) or (33 <= b <= 126 and not is_alnum(b) and b not in (95, 92))


def is_dropped(b):
    return is_control(b) and b not in (0, 9)


def class_bits(b):
    term = 48 <= b <= 57 or 97 <= b <= 122 or b == 95 or b >= 128
    upper = 65 <= b <= 90
    flags = [term, upper, is_separator(b), is_dropped(b), b == 92, b == 0, b == 32 or 9 <= b <= 13,
             b != 0 and not term and not upper]
    return sum(1 << i for i, f in enumerate(flags) if f)


def tokens(src, keep_escaped_controls=False, nul_separates=False):
    out = []
    i, n = 0, len(src)
    while True:
        while i < n and (is_separator(src[i]) or (nul_separates and src[i] == 0)):
            i += 1
        if i >= n or src[i] == 0:
            return out
        start, j, buf, stop = i, i, [], False
        while j < n:
            b = src[j]
            if is_separator(b) or (nul_separates and b == 0):
                break
            if b == 0:
                stop = True
                break
            if is_dropped(b):
                j += 1
                continue
            if b == 92:
                if j + 1 >= n:
                    j += 1
                    break
                if src[j + 1] == 0:
                    j += 1
                    stop = True
                    break
                e = src[j + 1]
                j += 2
                if keep_escaped_controls or not is_control(e):
                    buf.append(e)
                continue
            buf.append(b)
            j += 1
        if buf:
            out.append((bytes(buf), start, j, start + len(buf)))
        if stop:
            return out
        i = j


def token_row(src, **variant):
    toks = tokens(src, **variant)
    return f'TK|{len(toks)}|' + (','.join(f'{hexs(t)}:{s}:{e}:{f}' for t, s, e, f in toks) or '-')


class Unicode:
    def __init__(self, directory):
        for name, wanted in UCD_SHA256.items():
            path = directory / name
            if not path.is_file() or digest(path) != wanted:
                raise AssertionError(f'{path} is missing or is not the pinned Unicode 17.0.0 file')
        self.paths = [directory / 'UnicodeData.txt', directory / 'SpecialCasing.txt']
        self.simple = {}
        for line in self.paths[0].read_text(encoding='utf-8').split('\n'):
            if not line.strip():
                continue
            fields = line.split(';')
            if len(fields) != 15:
                raise AssertionError('unexpected UnicodeData line ' + line)
            if fields[13]:
                self.simple[int(fields[0], 16)] = int(fields[13], 16)
        self.full = {}
        self.conditional = {}
        text = self.paths[1].read_text(encoding='utf-8')
        if not text.startswith('# SpecialCasing-17.0.0.txt'):
            raise AssertionError('SpecialCasing.txt is not version 17.0.0')
        for line in text.split('\n'):
            body = line.split('#', 1)[0].strip()
            if not body:
                continue
            fields = [f.strip() for f in body.split(';')]
            target = [int(x, 16) for x in fields[1].split()]
            if len(fields) > 4 and fields[4]:
                self.conditional.setdefault(int(fields[0], 16), target)
                continue
            self.full[int(fields[0], 16)] = target
        self.mapped = [cp for cp in sorted(set(self.simple) | set(self.full)) if self.low(cp) != [cp]]

    def low(self, cp, special=True):
        if special and cp in self.full:
            return self.full[cp]
        return [self.simple.get(cp, cp)]


def ascii_lower(b):
    return b + 32 if 65 <= b <= 90 else b


def src_byte(text, tail, i):
    if i < len(text):
        return text[i]
    j = i - len(text)
    return tail[j] if j < len(tail) else 0


def decode(text, tail, i):
    b0 = src_byte(text, tail, i)
    if b0 < 0x80:
        return b0, i + 1
    b1 = src_byte(text, tail, i + 1) & 0x3F
    if b0 < 0xE0:
        return (b0 & 0x1F) << 6 | b1, i + 2
    b2 = src_byte(text, tail, i + 2) & 0x3F
    if b0 < 0xF0:
        return (b0 & 0x0F) << 12 | b1 << 6 | b2, i + 3
    b3 = src_byte(text, tail, i + 3) & 0x3F
    return (b0 & 0x07) << 18 | b1 << 12 | b2 << 6 | b3, i + 4


def encode(cp):
    if cp < 0x80:
        return [cp]
    if cp < 0x800:
        return [0xC0 | cp >> 6, 0x80 | cp & 0x3F]
    if cp < 0x10000:
        return [0xE0 | cp >> 12, 0x80 | cp >> 6 & 0x3F, 0x80 | cp & 0x3F]
    return [0xF0 | cp >> 18 & 0x07, 0x80 | cp >> 12 & 0x3F, 0x80 | cp >> 6 & 0x3F, 0x80 | cp & 0x3F]


def fold(uni, text, tail, special=True):
    n = 0
    while n < len(text) and 0 < text[n] < 0x80:
        n += 1
    out = [ascii_lower(b) for b in text[:n]]
    if n == len(text) or text[n] == 0:
        return bytes(out)
    i = n
    while i < len(text):
        cp, i = decode(text, tail, i)
        if cp == 0:
            break
        if cp < 0x80:
            out.append(ascii_lower(cp))
            continue
        for c in uni.low(cp, special):
            out.extend(encode(c))
    return bytes(out)


def trie_form(term, truncate=True):
    units, stopped, out, i = 0, False, [], 0
    while i < len(term):
        cp, i = decode(term, b'', i)
        units += 1
        if stopped:
            continue
        u = cp & 0xFFFF if truncate else cp
        if u == 0:
            stopped = True
            continue
        out.extend(encode(u))
    return f'TF|{hexs(out)}|{bit(units <= 255)}|{units}'


def fnv(word):
    h = 2166136261
    for b in word:
        h = ((h ^ b) * 16777619) & 0xFFFFFFFF
    return h


def stop_table(words, sort=True):
    unique = []
    for w in (sorted(set(words)) if sort else words):
        if w not in unique:
            unique.append(w)
    size = 8
    while size < 2 * len(unique):
        size *= 2
    slots = [0] * size
    lengths, firsts = 0, 0
    for i, w in enumerate(unique):
        h = fnv(w) & (size - 1)
        while slots[h]:
            h = (h + 1) & (size - 1)
        slots[h] = i + 1
        lengths |= 1 << min(len(w), 63)
        if w:
            firsts |= 1 << w[0]
    return unique, size, slots, lengths, firsts


def stop_row(reg, words, reported, sort=True):
    unique, size, slots, lengths, firsts = stop_table(words, sort)
    listed = ','.join('.' if not w else w.hex() for w in unique) or '-'
    quarters = '.'.join(f'{(firsts >> (64 * i)) & ((1 << 64) - 1):016x}' for i in range(4))
    return f'SB|{reg}|{listed}|{size}|{",".join(map(str, slots))}|{lengths:016x}|{quarters}|{bit(reported)}'


def stub_stem(w):
    if len(w) >= 3 and w[-3:] == b'ing':
        return w[:-3]
    if w and w[-1] == 115:
        return w[:-1]
    return w


def analysis_row(uni, src, stops, mode, min_stem, base, stems, variant=None):
    position, out = base, []
    for text, start, end, tail_from in tokens(src):
        f = fold(uni, text, src[tail_from:])
        if stops is not None and f in stops and (f or variant == 'empty_dropped'):
            if variant == 'stop_positions':
                position += 1
            continue
        position += 1
        out.append(f'{hexs(f)}:{position}:{start}:{end}:o')
        if mode == '-' or (len(f) < min_stem and variant != 'short_stemmed'):
            continue
        s = (stems.get(f, f) if variant else stems[f]) if mode == 'e' else stub_stem(f)
        if s != f:
            if variant == 'stem_advances':
                position += 1
            out.append(f'{hexs(b"+" + s)}:{position}:{start}:{end}:s')
    return f'AN|{position}|' + (','.join(out) or '-')


def lt_row(uni, block, special=True, conditional=False):
    entries = []
    for cp in range(block * 256, block * 256 + 256):
        seq = uni.conditional[cp] if conditional and cp in uni.conditional else uni.low(cp, special)
        if seq != [cp]:
            entries.append(f'{cp:x}:' + '.'.join(f'{c:x}' for c in seq))
    return f'LT|{block}|' + (','.join(entries) or '-')


def vocabulary():
    words = VOCABULARY.read_text(encoding='utf-8').split('\n')
    stems = STEMS.read_text(encoding='utf-8').split('\n')
    if len(words) != len(stems):
        raise AssertionError('vocabulary and stem lists differ in length')
    table = {}
    for w, s in zip(words, stems):
        if re.fullmatch(r'[a-z]+', w):
            table[w.encode()] = s.encode()
    return table


def corpus(uni):
    rng = random.Random(SEED)
    lines, expected = [], []
    stats = {kind: 0 for kind in ROW_AREAS}
    extra = {}

    def emit(line, row):
        lines.append(line)
        expected.append(row)
        stats[line.split(' ')[0]] += 1

    for b in range(256):
        emit(f'BC {b}', f'BC|{b}|{class_bits(b)}|{bit(is_control(b))}')

    letters = b'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_'
    controls = bytes(list(range(1, 9)) + list(range(10, 32)) + [127])
    special_cps = [0x130, 0x3A3, 0x1F88, 0x1E9E, 0x10400, 0x104B0, 0x1E900, 0x2C2F, 0xA7C0, 0x16E40, 0x10D50, 0x1C89,
                   0x212A, 0x2126, 0x0049, 0x0130, 0x03F4, 0x1E9E, 0x24B6, 0x10C80, 0xA77D]
    mapped = uni.mapped

    def piece():
        r = rng.randrange(100)
        if r < 40:
            return bytes([rng.choice(letters)])
        if r < 50:
            return bytes([rng.choice(b' \t')])
        if r < 60:
            return bytes([rng.choice(PUNCT)])
        if r < 66:
            return b'\\'
        if r < 72:
            return bytes([rng.choice(controls)])
        if r < 74:
            return b'\x00'
        if r < 80:
            return bytes([rng.randrange(0x80, 0x100)])
        if r < 92:
            return bytes(encode(rng.choice(mapped)))
        if r < 96:
            return bytes(encode(rng.choice(special_cps)))
        return bytes(encode(rng.randrange(0x80, 0x110000)))

    def source(lo, hi):
        return b''.join(piece() for _ in range(rng.randrange(lo, hi)))

    edge_sources = [b'', b' ', b'\t\t', b'a', b'a b', b'a\\', b'a\\\x00b', b'a\\ b', b'a\\\tb', b'a\\\x01b', b'\\\\', b'\\',
                    b'a\x00b c', b'\x01\x02', b'\x01a\x02', b'a_b', b'a-b', b'a\\-b', b'\xc3', b'\xc3 b', b'A\xc3\x89',
                    b'x\x7fy', b'  lead', b'trail  ', b'\\a\\b\\c', b'a\\\\\\', b'\x00', b'\x00abc', b'ab\\\x7fcd']
    for src in edge_sources:
        emit(f'TK {hexs(src)}', token_row(src))
    for _ in range(3000):
        src = source(0, 40)
        emit(f'TK {hexs(src)}', token_row(src))

    fold_edges = [(b'ABC', b''), (b'\xc4\xb0', b''), (b'I\xcc\x87', b''), (b'\xc3', b'\x89'), (b'A\xc3', b'\x89rest'),
                  (b'\xc0\x80x', b''), (b'x\xc0\x80y', b''), (b'\xc1\x81', b''), (b'\xf8\x80\x80\x80', b''),
                  (b'\xf0\x90\x90\x80', b''), (b'\xe2\x84\xaa', b''), (b'\xce\xa3', b''), (b'a\x00B', b''),
                  (b'\xe1\xbe\x88', b''), (b'\xe1\xba\x9e', b''), (b'\xff', b''), (b'\xef', b'\xbf'), (b'', b'tail')]
    for text, tail in fold_edges:
        emit(f'FO {hexs(text)} {hexs(tail)}', f'FO|{hexs(fold(uni, text, tail))}')
    for _ in range(3000):
        text = source(1, 24)
        tail = source(0, 6) if rng.randrange(3) else bytes(rng.randrange(0x80, 0xC0) for _ in range(rng.randrange(0, 4)))
        emit(f'FO {hexs(text)} {hexs(tail)}', f'FO|{hexs(fold(uni, text, tail))}')
    for cp in mapped:
        text = bytes(encode(cp))
        emit(f'FO {hexs(text)} -', f'FO|{hexs(fold(uni, text, b""))}')

    for block in range(0x2000):
        emit(f'LT {block}', lt_row(uni, block))
    extra['mapped_code_points'] = len(mapped)
    extra['unconditional_special_casing'] = len(uni.full)

    eu = [0, 1, 0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF, 0x110000, 0x1FFFFF, 0xD800, 0xDFFF, 0x130]
    eu += [rng.randrange(0x200000) for _ in range(1200)] + [rng.randrange(0x800) for _ in range(300)]
    for cp in eu:
        enc = encode(cp)
        dcp, nxt = decode(bytes(enc), b'', 0)
        emit(f'EU {cp}', f'EU|{hexs(enc)}|{dcp}|{nxt}')

    trie_edges = [b'', bytes(encode(0x1F600)), bytes(encode(0x10000)) + b'ab', b'a' * 255, b'a' * 256,
                  bytes(encode(0x20000)), b'\xc0\x80ab', b'\xf0\x9f\x98', b'\x80\x80', b'\xe2\x82']
    for term in trie_edges:
        emit(f'TF {hexs(term)}', trie_form(term))
    for _ in range(1000):
        r = rng.randrange(4)
        if r == 0:
            term = b''.join(bytes(encode(rng.choice([rng.randrange(0x10000, 0x110000), 0x10000 * rng.randrange(1, 17),
                                                     rng.randrange(0x80, 0x10000)]))) for _ in range(rng.randrange(1, 8)))
        elif r == 1:
            term = b''.join(bytes(encode(rng.randrange(0x61, 0x7B))) for _ in range(rng.randrange(250, 260)))
        elif r == 2:
            term = bytes(rng.randrange(256) for _ in range(rng.randrange(0, 12)))
        else:
            term = source(1, 20)
        emit(f'TF {hexs(term)}', trie_form(term))

    vocab = vocabulary()
    vocab_words = sorted(vocab)
    registers = {}
    pool = [w.encode() for w in DEFAULT_STOP] + [b''] + [w.encode() for w in rng.sample(['Hello', 'WORLD', 'Stop', 'stop',
            'Ab', 'ab', 'x', 'X', 'zz', 'Zebra', 'The', 'THE'], 8)]
    long_word = b'q' * 70

    def custom_word():
        r = rng.randrange(10)
        if r < 3:
            return rng.choice(pool)
        if r < 6:
            return bytes(rng.choice(letters) for _ in range(rng.randrange(1, 10)))
        if r < 8:
            return bytes(encode(rng.choice(mapped))) + bytes(rng.choice(letters) for _ in range(rng.randrange(0, 4)))
        if r < 9:
            return long_word + bytes([rng.choice(letters)]) * rng.randrange(0, 3)
        return rng.choice(vocab_words)

    def build_register(reg, mode):
        if mode == 'd':
            folded = [w.encode() for w in DEFAULT_STOP]
            emit(f'SB {reg} d', stop_row(reg, folded, False))
            registers[reg] = (set(folded), folded)
        elif mode == 'n':
            emit(f'SB {reg} n', stop_row(reg, [], True))
            registers[reg] = (set(), [])
        else:
            raw = [custom_word() for _ in range(rng.randrange(0, 40))]
            if raw and rng.randrange(3) == 0:
                raw.append(rng.choice(raw).upper())
            if rng.randrange(6) == 0:
                raw.append(b'')
            folded = [fold(uni, w, b'') for w in raw]
            listed = ','.join('.' if not w else w.hex() for w in raw) or '-'
            emit(f'SB {reg} c {listed}', stop_row(reg, folded, True))
            registers[reg] = (set(folded), folded)

    for session in range(90):
        reg = session % 8 if session < 8 else rng.randrange(8)
        mode = 'd' if session == 0 else 'n' if session == 1 else rng.choice('dnccccccc')
        build_register(reg, mode)
        members, folded = registers[reg]
        for _ in range(25):
            r = rng.randrange(6)
            if r < 2 and folded:
                term = rng.choice(folded)
            elif r == 2 and folded:
                w = rng.choice(folded)
                term = w[:-1] + bytes([rng.choice(letters)]) if w else b''
            elif r == 3:
                term = rng.choice([b'', long_word, b'q' * 64, b'Q' * 70, b'THE'])
            else:
                term = custom_word()
            emit(f'SQ {reg} {hexs(term)}', f'SQ|{bit(term in members)}|{bit(term in members)}|0|0')

    for reg in range(8):
        build_register(reg, 'c' if reg % 2 else 'd')
    empty_reg = 7
    raw = [b'', b'the', b'Run']
    emit(f'SB {empty_reg} c {",".join("." if not w else w.hex() for w in raw)}',
         stop_row(empty_reg, [fold(uni, w, b'') for w in raw], True))
    registers[empty_reg] = ({fold(uni, w, b'') for w in raw}, [fold(uni, w, b'') for w in raw])

    analysis = []
    needed = set()

    def vocab_token():
        w = rng.choice(vocab_words)
        r = rng.randrange(6)
        if r == 0:
            w = w.upper()
        elif r == 1:
            w = w[:1].upper() + w[1:]
        elif r == 2 and len(w) > 2:
            k = rng.randrange(1, len(w))
            w = w[:k] + bytes([rng.choice(controls)]) + w[k:]
        return w

    def english_text():
        parts = []
        for _ in range(rng.randrange(0, 12)):
            r = rng.randrange(8)
            if r < 5:
                parts.append(vocab_token())
            elif r < 7:
                parts.append(rng.choice(DEFAULT_STOP).encode())
            else:
                parts.append(rng.choice([b'ab', b'x', b'Go', b'\xc0\x80']))
            parts.append(rng.choice([b' ', b'  ', b'\t', b', ', b'. ', b'-', b'(', b'); ']))
        if rng.randrange(10) == 0:
            parts.append(b'\x00' + vocab_token())
        return b''.join(parts)

    for _ in range(2500):
        mode = rng.choice('ee-ss')
        reg = rng.choice(['-', '-'] + [str(r) for r in range(8)])
        min_stem = rng.choice([4, 4, 4, 0, 1, 3, 5, 8, 100])
        base = rng.choice([0, 0, 0, 1, 17, rng.randrange(1 << 20), 1 << 31])
        src = english_text() if mode == 'e' else source(0, 40) if rng.randrange(2) else english_text()
        stops = registers[int(reg)][0] if reg != '-' else None
        if mode == 'e':
            row_needed = set()
            for text, _, _, tail_from in tokens(src):
                f = fold(uni, text, src[tail_from:])
                if (stops is None or not f or f not in stops) and len(f) >= min_stem:
                    row_needed.add(f)
            if any(f not in vocab for f in row_needed):
                continue
            needed |= row_needed
        analysis.append((reg, mode, min_stem, base, src))
    for text in [b'ab \xc0\x80 cd', b'\xc0\x80', b'the Run running', b'\xc0\x80 the \xc0\x80']:
        analysis.append((str(empty_reg), 's', 4, 0, text))
    dictionary = sorted(needed | set(rng.sample(vocab_words, 2500)))
    for w in dictionary:
        emit(f'SM {w.hex()} {hexs(vocab[w])}', f'SM|{w.hex()}|{hexs(vocab[w])}')
    stems = {w: vocab[w] for w in dictionary}
    for reg, mode, min_stem, base, src in analysis:
        stops = registers[int(reg)][0] if reg != '-' else None
        emit(f'AN {reg} {mode} {min_stem} {base} {hexs(src)}', analysis_row(uni, src, stops, mode, min_stem, base, stems))
    extra['dictionary_words'] = len(dictionary)
    for kind, count in stats.items():
        if count == 0:
            raise AssertionError('corpus has no ' + kind + ' rows')
    return '\n'.join(lines) + '\n', expected, stats, extra, registers, stems


def compare(label, got, want):
    rows = got.splitlines()
    if not want or len(rows) != len(want):
        raise AssertionError(f'{label}: {len(rows)} rows, expected {len(want)}')
    for i, (a, b) in enumerate(zip(rows, want)):
        if a != b:
            raise AssertionError(f'{label}: row {i}: {a[:300]!r} != {b[:300]!r}')


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
        axioms, kernel = audit_kernel(Path(lake), PACKAGE, output, env, 'Texts')
    versions = {'lean': version.strip(), 'odin': odin_version.strip()}
    tools = {name: digest(Path(path)) for name, path in (('lean', lean), ('lake', lake), ('odin', odin))}
    return PACKAGE / '.lake/build/bin/text_model', output / 'odin_bridge', axioms, kernel, versions, tools


def negative_controls(uni, lines, expected, registers, stems):
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

    def fields(i):
        return lines[i].split(' ')

    def cell(row, k):
        return row.split('|')[k]

    def with_cell(row, k, value):
        c = row.split('|')
        c[k] = value
        return '|'.join(c)

    def src_of(i):
        return bytes.fromhex(fields(i)[1]) if fields(i)[1] != '-' else b''

    def fold_args(i):
        f = fields(i)
        return (bytes.fromhex(f[1]) if f[1] != '-' else b''), (bytes.fromhex(f[2]) if f[2] != '-' else b'')

    def analysis_variant(i, variant):
        reg, mode, min_stem, base, text = fields(i)[1:]
        src = bytes.fromhex(text) if text != '-' else b''
        stops = registers_at[i] if reg != '-' else None
        return analysis_row(uni, src, stops, mode, int(min_stem), int(base), stems, variant)

    registers_at = {}
    current = {}
    for i, line in enumerate(lines):
        f = line.split(' ')
        if f[0] == 'SB':
            current[int(f[1])] = {b'' if x == '.' else bytes.fromhex(x) for x in cell(expected[i], 2).split(',') if x != '-'}
        elif f[0] == 'AN' and f[1] != '-':
            registers_at[i] = current[int(f[1])]

    semantic = {
        'escaped_controls_kept': ('TK ', lambda i: token_row(src_of(i), keep_escaped_controls=True)),
        'nul_separates': ('TK ', lambda i: token_row(src_of(i), nul_separates=True)),
        'fold_ignores_tail': ('FO ', lambda i: f'FO|{hexs(fold(uni, fold_args(i)[0], b""))}'),
        'fold_simple_casing_only': ('FO ', lambda i: f'FO|{hexs(fold(uni, *fold_args(i), special=False))}'),
        'table_simple_casing_only': ('LT ', lambda i: lt_row(uni, int(fields(i)[1]), special=False)),
        'table_conditional_casing': ('LT ', lambda i: lt_row(uni, int(fields(i)[1]), conditional=True)),
        'trie_keeps_supplementary': ('TF ', lambda i: trie_form(src_of(i), truncate=False)),
        'stop_words_unsorted': ('SB ', lambda i: stop_row(int(fields(i)[1]),
                                                          [b'' if x == '.' else fold(uni, bytes.fromhex(x), b'')
                                                           for x in fields(i)[3].split(',') if x != '-'] if fields(i)[2] == 'c'
                                                          else [w.encode() for w in DEFAULT_STOP] if fields(i)[2] == 'd' else [],
                                                          fields(i)[2] != 'd', sort=False)),
        'query_drops_non_plain': ('SQ ', lambda i: with_cell(expected[i], 4, cell(expected[i], 1))),
        'query_ignores_no_stop_words': ('SQ ', lambda i: with_cell(expected[i], 3, cell(expected[i], 1))),
        'short_words_stemmed': ('AN ', lambda i: analysis_variant(i, 'short_stemmed')),
        'stem_takes_position': ('AN ', lambda i: analysis_variant(i, 'stem_advances')),
        'stop_words_take_positions': ('AN ', lambda i: analysis_variant(i, 'stop_positions')),
        'empty_terms_dropped': ('AN ', lambda i: analysis_variant(i, 'empty_dropped')),
    }
    for name, (prefix, mutate) in semantic.items():
        index = next((i for i, line in enumerate(lines) if line.startswith(prefix) and mutate(i) != expected[i]), None)
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
    parser.add_argument('--ucd', type=Path, default=ROOT / 'third_party' / 'unicode' / 'ucd-17.0.0')
    parser.add_argument('--output', type=Path, default=PACKAGE / '.build')
    args = parser.parse_args()
    if not all((args.ucd / name).is_file() for name in UCD_SHA256):
        raise AssertionError('the Unicode 17.0.0 UnicodeData.txt and SpecialCasing.txt are needed in ' + str(args.ucd))
    args.output.mkdir(parents=True, exist_ok=True)
    output = args.output.resolve()
    (output / 'receipt.json').unlink(missing_ok=True)
    if hasattr(os, 'sched_getaffinity'):
        os.sched_setaffinity(0, {min(os.sched_getaffinity(0))})
    if hasattr(os, 'nice'):
        os.nice(10)
    fingerprints = check_fingerprints()
    uni = Unicode(args.ucd.resolve())
    lean_model, odin_bridge, axioms, kernel, versions, tools = build(output, args.lean_bin, args.odin)
    trace, expected, stats, extra, registers, stems = corpus(uni)
    lines = trace.splitlines()
    path = output / 'cases.txt'
    path.write_text(trace)
    results = {}
    for name, command in (('lean', [str(lean_model.resolve()), str(path)] + [str(p) for p in uni.paths]),
                          ('odin', [str(odin_bridge.resolve()), str(path)])):
        result = subprocess.run(command, text=True, capture_output=True)
        if result.returncode or result.stderr:
            raise AssertionError(f'{name}: exit {result.returncode}, stderr: {result.stderr[-2000:]}')
        (output / f'{name}-results.txt').write_text(result.stdout)
        compare(name, result.stdout, expected)
        results[name] = hashlib.sha256(result.stdout.encode()).hexdigest()
    if results['lean'] != results['odin']:
        raise AssertionError('Lean oracle and Odin rows differ')
    rejected = negative_controls(uni, lines, expected, registers, stems)
    modules = {module: set(re.findall(r"^theorem\s+([\w']+)", (PACKAGE / f'Texts/{module}.lean').read_text(), re.M))
               for files in AREAS.values() for module in files}
    comparisons = {area: sum(count for kind, count in stats.items() if ROW_AREAS[kind] == area) for area in AREAS}
    if any(not comparisons[area] for area in AREAS):
        raise AssertionError('every area needs comparison rows')
    area_evidence = {area: {'theorems': sorted(name for name in axioms
                                               if name.removeprefix('Texts.') in set().union(*(modules[m] for m in files))),
                            'comparisons': comparisons[area]}
                     for area, files in AREAS.items()}
    if any(not evidence['theorems'] for evidence in area_evidence.values()):
        raise AssertionError('every area needs named theorems in the manifest')
    receipt = {'rows': stats, 'details': extra, 'total_rows': len(expected), 'seed': hex(SEED),
               'toolchain': (PACKAGE / 'lean-toolchain').read_text().strip(),
               'area_evidence': area_evidence, 'checked_theorem_axioms': axioms,
               'kernel_inventory_sha256': digest(output / 'kernel-inventory.json'),
               'kernel_checked_theorems': len(kernel['theorem_axioms']),
               'source_sha256': fingerprints, 'unicode_sha256': UCD_SHA256, 'versions': versions, 'tool_sha256': tools,
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
