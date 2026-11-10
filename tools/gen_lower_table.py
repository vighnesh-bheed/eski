import os
import re
import sys

BLOCK_SHIFT = 8
BLOCK_SIZE = 1 << BLOCK_SHIFT
LIMIT = 0x20000
SPECIAL = 255
PER_LINE = 32


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(1)


def read_lines(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().split("\n")


def parse_unicode_data(path):
    lower = {}
    for line in read_lines(path):
        if not line.strip():
            continue
        fields = line.split(";")
        if len(fields) < 15:
            fail("unexpected UnicodeData.txt line: " + line)
        if fields[13]:
            lower[int(fields[0], 16)] = [int(fields[13], 16)]
    return lower


def parse_special_casing(path):
    version = None
    special = {}
    for line in read_lines(path):
        if version is None:
            found = re.match(r"#\s*SpecialCasing-(\d+\.\d+\.\d+)\.txt", line)
            if found:
                version = found.group(1)
        body = line.split("#", 1)[0].strip()
        if not body:
            continue
        fields = [field.strip() for field in body.split(";")]
        if len(fields) < 4:
            fail("unexpected SpecialCasing.txt line: " + line)
        if len(fields) > 4 and fields[4]:
            continue
        special[int(fields[0], 16)] = [int(value, 16) for value in fields[1].split()]
    if version is None:
        fail("SpecialCasing.txt carries no version header")
    return version, special


def full_lower(cp, lower, special):
    if cp in special:
        return special[cp]
    return lower.get(cp, [cp])


def numbers(values, indent):
    lines = []
    for start in range(0, len(values), PER_LINE):
        chunk = values[start:start + PER_LINE]
        lines.append(indent + ", ".join(str(value) for value in chunk) + ",")
    return "\n".join(lines)


def main():
    if len(sys.argv) != 3:
        fail("usage: python3 -I tools/gen_lower_table.py <ucd directory> <output .odin file>")
    ucd = sys.argv[1]
    output = sys.argv[2]
    lower = parse_unicode_data(os.path.join(ucd, "UnicodeData.txt"))
    version, special = parse_special_casing(os.path.join(ucd, "SpecialCasing.txt"))
    for cp in list(lower) + list(special):
        if cp >= LIMIT and full_lower(cp, lower, special) != [cp]:
            fail("lowercase mapping beyond the table limit: %04X" % cp)
    deltas = [0]
    delta_index = {0: 0}
    expansions = []
    blocks = [[0] * BLOCK_SIZE]
    block_index = {tuple(blocks[0]): 0}
    stage1 = []
    for block in range(LIMIT >> BLOCK_SHIFT):
        entries = []
        for low in range(BLOCK_SIZE):
            cp = (block << BLOCK_SHIFT) | low
            mapped = full_lower(cp, lower, special)
            if len(mapped) == 1:
                delta = mapped[0] - cp
                if delta not in delta_index:
                    delta_index[delta] = len(deltas)
                    deltas.append(delta)
                entries.append(delta_index[delta])
            else:
                expansions.append((cp, mapped))
                entries.append(SPECIAL)
        key = tuple(entries)
        if key not in block_index:
            block_index[key] = len(blocks)
            blocks.append(entries)
        stage1.append(block_index[key])
    if len(deltas) >= SPECIAL:
        fail("too many distinct deltas for a byte index: %d" % len(deltas))
    if len(blocks) > 256:
        fail("too many distinct blocks for a byte index: %d" % len(blocks))
    if any(len(seq) > 3 for _, seq in expansions):
        fail("an expansion is longer than three code points")
    stage2 = []
    for entries in blocks:
        stage2.extend(entries)
    mapped_count = 0
    for cp in range(LIMIT):
        if full_lower(cp, lower, special) != [cp]:
            mapped_count += 1
    out = []
    out.append("package text")
    out.append("")
    out.append("UNICODE_VERSION :: \"%s\"" % version)
    out.append("")
    out.append("LOWER_LIMIT :: 0x%X" % LIMIT)
    out.append("")
    out.append("LOWER_BLOCK_SHIFT :: %d" % BLOCK_SHIFT)
    out.append("")
    out.append("LOWER_SPECIAL :: %d" % SPECIAL)
    out.append("")
    out.append("LOWER_MAPPED :: %d" % mapped_count)
    out.append("")
    out.append("Lower_Expansion :: struct {")
    out.append("\tcp:    u32,")
    out.append("\tcount: u8,")
    out.append("\tseq:   [3]u32,")
    out.append("}")
    out.append("")
    out.append("@(rodata)")
    out.append("LOWER_STAGE1 := [%d]u8{" % len(stage1))
    out.append(numbers(stage1, "\t"))
    out.append("}")
    out.append("")
    out.append("@(rodata)")
    out.append("LOWER_STAGE2 := [%d]u8{" % len(stage2))
    out.append(numbers(stage2, "\t"))
    out.append("}")
    out.append("")
    out.append("@(rodata)")
    out.append("LOWER_DELTAS := [%d]i32{" % len(deltas))
    out.append(numbers(deltas, "\t"))
    out.append("}")
    out.append("")
    out.append("@(rodata)")
    out.append("LOWER_EXPANSIONS := [%d]Lower_Expansion{" % len(expansions))
    for cp, seq in expansions:
        padded = seq + [0] * (3 - len(seq))
        out.append("\t{0x%X, %d, {0x%X, 0x%X, 0x%X}}," % (cp, len(seq), padded[0], padded[1], padded[2]))
    out.append("}")
    out.append("")
    with open(output, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(out))
    sys.stdout.write("unicode %s: %d mapped code points, %d blocks, %d deltas, %d expansions\n" % (version, mapped_count, len(blocks), len(deltas), len(expansions)))


main()
