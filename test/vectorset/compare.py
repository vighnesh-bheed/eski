import argparse
import json
import os
import re
import socket
import sys
import threading
import time
from collections import OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cases

HOST = "127.0.0.1"
LOWER_COMMANDS = {c.lower().encode() for c in cases.COMMANDS}
VSIM_SCORE_FLAG = b"WITHSCORES"
VSIM_ATTR_FLAG = b"WITHATTRIBS"

NORMALISATIONS = OrderedDict([
    ("exact", ("the raw reply bytes", "every byte")),
    ("type", ("INFO server describes the server itself (version, build, process and clock fields; the main smoke sections compare INFO where it can match), and a DUMP payload is Eski's own serialization, restored later on the server that produced it",
              "the RESP type of the reply, or the exact bytes of a null or an error")),
    ("integer", ("the value is a size that differs by design: MEMORY USAGE (compared by test/vectorset/memory.py within a margin) and COMMAND COUNT (the reference image also loads the search, JSON, time series and probabilistic modules)",
                 "that the reply is an integer, or the exact bytes when it is anything else")),
    ("ttl", ("the remaining time to live read right after EXPIRE depends on the clock", "that the reply is a non-negative integer, or the exact bytes of -1, -2 and anything else")),
    ("sorted", ("COMMAND LIST order follows the server's command table hashing", "the multiset of names")),
    ("acl-listing", ("ACL CAT read and write list every command of the category, including the commands of the other modules in the reference image, and "
                     "Eski puts the vector set commands in the ordinary categories where the reference leaves them outside every category (" + cases.ACL_DIFFERENCE + ")",
                     "the vector set command names found in the listing: none on the reference, and exactly the commands of that category on Eski")),
    ("acl-scan", ("the deliberate category difference: " + cases.ACL_DIFFERENCE,
                  "every category that lists a vector set command, with the names it lists: none on the reference, and on Eski exactly read, write, fast and slow with their commands")),
    ("acl-metadata", ("the deliberate category and key flag difference: " + cases.ACL_DIFFERENCE,
                      "every other byte of the reply, with the ACL categories and the key flags each checked against the server's documented value: none and RW access update on the reference, "
                      "the command's two categories on Eski and RO access for the read commands")),
    ("acl-login", ("a login built from category rules is granted or denied the vector set commands by those categories on Eski and only by name or by +@all on the reference: " + cases.ACL_DIFFERENCE,
                   "for every vector set command run by a fresh connection authenticated as the login, whether it ran or was refused with NOPERM for the command or for the key, against the documented verdicts of each server; rules by name give the same verdicts on both")),
    ("module-list", ("the reference image loads five modules and Eski has no module interface; only the vector set entry can match",
                     "the complete name, ver, path and args entry of the vectorset module")),
    ("docs-summary", ("Eski words the COMMAND DOCS summaries of the vector set commands itself, so their text differs from the reference's by design",
                      "every other byte of the reply, with the summary checked to be a string in the same place")),
    ("debug-object", ("DEBUG OBJECT carries the object address, the serialized length (Eski uses its own serialization) and the LRU clock",
                      "the text with the address, serializedlength, lru and lru_seconds_idle values masked, so refcount and encoding still compare")),
    ("scan", ("SCAN order follows the hash table layout", "the cursor and the sorted key list of a complete scan")),
    ("scan-partial", ("a partial SCAN returns an implementation-dependent subset and cursor",
                      "the reply shape, that every returned key is a vector set and that no key repeats")),
    ("vinfo", ("max-level comes from random HNSW levels and vset-uid from a server-wide counter",
               "every other field, the field order and the value types")),
    ("vsim", ("the HNSW path orders tied scores by graph position, and when COUNT cuts a group of tied scores the members kept depend on the graph; TRUTH queries are compared exactly",
              "every name, score and attribute in order, with names sorted inside each group of equal scores and a cut tie group compared by size and score; scores of replies without WITHSCORES come from a probe of the same query WITHSCORES on the same server")),
    ("exec-vsim", ("an EXEC reply holding a VSIM reply inherits its tie order", "every reply of the transaction, with the VSIM reply canonicalised as for vsim")),
    ("vrandmember", ("VRANDMEMBER samples at random",
                     "the reply type and count, that every returned name is a member (checked with VISMEMBER on the same server), that a positive count returns distinct names, and the sorted names when the whole set is returned")),
    ("vlinks", ("neighbour order inside a layer and the number of layers above layer 0 come from the random graph",
                "the complete sorted layer 0 neighbour list with its scores, which on these small sets holds every other element")),
    ("vlinks-graph", ("on 300-element sets the neighbour lists themselves are graph dependent",
                      "the reply shape: an array of layers, each an array of names or of name and score pairs, or a map in RESP3")),
])


class ServerGone(Exception):
    pass


class Node:
    __slots__ = ("kind", "head", "value", "raw")

    def __init__(self, kind, head, value, raw):
        self.kind = kind
        self.head = head
        self.value = value
        self.raw = raw


def esc(b):
    out = []
    for ch in b:
        if ch == 13:
            out.append("\\r")
        elif ch == 10:
            out.append("\\n")
        elif ch == 92:
            out.append("\\\\")
        elif 32 <= ch < 127:
            out.append(chr(ch))
        else:
            out.append("\\x%02x" % ch)
    return "".join(out)


def encode(args):
    out = [b"*%d\r\n" % len(args)]
    for a in args:
        out.append(b"$%d\r\n%s\r\n" % (len(a), a))
    return b"".join(out)


class Conn:
    def __init__(self, port, proto, timeout, host=None):
        self.port = port
        self.proto = proto
        self.sock = socket.create_connection((host or HOST, port), timeout=5)
        self.sock.settimeout(timeout)
        self.buf = bytearray()
        self.pos = 0
        if proto == 3:
            self.call([b"HELLO", b"3"])

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def fill(self):
        try:
            chunk = self.sock.recv(1 << 20)
        except socket.timeout:
            raise ServerGone("no reply within the timeout")
        except OSError as e:
            raise ServerGone("connection error: %s" % e)
        if not chunk:
            raise ServerGone("connection closed by the server")
        if self.pos > (1 << 20):
            del self.buf[:self.pos]
            self.pos = 0
        self.buf += chunk

    def line(self):
        while True:
            j = self.buf.find(b"\r\n", self.pos)
            if j >= 0:
                out = bytes(self.buf[self.pos:j])
                self.pos = j + 2
                return out
            self.fill()

    def take(self, n):
        while len(self.buf) - self.pos < n:
            self.fill()
        out = bytes(self.buf[self.pos:self.pos + n])
        self.pos += n
        return out

    def node(self):
        start_raw = bytearray()
        head = self.line()
        start_raw += head + b"\r\n"
        kind = head[:1]
        if kind in (b"$", b"=", b"!"):
            n = int(head[1:])
            if n < 0:
                return Node(kind, head, None, bytes(start_raw))
            body = self.take(n + 2)
            return Node(kind, head, body[:-2], bytes(start_raw + body))
        if kind in (b"*", b"~", b">", b"%", b"|"):
            n = int(head[1:])
            if n < 0:
                return Node(kind, head, None, bytes(start_raw))
            if kind in (b"%", b"|"):
                n *= 2
            children = [self.node() for _ in range(n)]
            raw = bytes(start_raw) + b"".join(c.raw for c in children)
            if kind == b"|":
                inner = self.node()
                return Node(inner.kind, inner.head, inner.value, raw + inner.raw)
            return Node(kind, head, children, raw)
        if kind in (b"+", b"-", b":", b"_", b",", b"#", b"("):
            return Node(kind, head, head[1:], bytes(start_raw))
        raise ServerGone("unexpected reply type %r" % head[:40])

    def send(self, argv):
        try:
            self.sock.sendall(encode(argv))
        except OSError as e:
            raise ServerGone("send failed: %s" % e)

    def call(self, argv):
        self.send(argv)
        return self.node()

    def pipeline(self, cmds):
        try:
            self.sock.sendall(b"".join(encode(c) for c in cmds))
        except OSError as e:
            raise ServerGone("send failed: %s" % e)
        return [self.node() for _ in cmds]


def text(node):
    if node is None:
        return None
    if node.kind in (b"$", b"=", b"+", b",", b":", b"(") and node.value is not None:
        return node.value
    return None


def is_null(node):
    return node.kind == b"_" or (node.kind in (b"$", b"*") and node.value is None)


def is_error(node):
    return node.kind in (b"-", b"!")


def aggregate(node):
    return node.kind in (b"*", b"~", b"%") and node.value is not None


def pairs(node):
    items = node.value
    return [(items[i], items[i + 1]) for i in range(0, len(items) - 1, 2)]


def skeleton(node):
    if is_error(node):
        return node.raw
    if is_null(node):
        return b"null"
    if node.kind == b"%":
        parts = sorted({skeleton(k) + b"=>" + skeleton(v) for k, v in pairs(node)})
        return b"%[" + b"|".join(parts) + b"]"
    if aggregate(node):
        filled = [c for c in node.value if not (aggregate(c) and not c.value)]
        parts = sorted({skeleton(c) for c in filled})
        return node.kind + b"[" + b"|".join(parts) + b"]"
    return node.kind


class Context:
    def __init__(self, runner, step, conn):
        self.runner = runner
        self.step = step
        self.conn = conn
        self.role = runner.role

    def probe(self, argv):
        return self.conn.call(argv)


def norm_exact(node, ctx):
    return node.raw


def norm_type(node, ctx):
    if is_error(node) or is_null(node):
        return node.raw
    return b"<reply of type " + node.kind + b">"


def norm_integer(node, ctx):
    if node.kind == b":":
        return b"<integer>"
    return node.raw


def norm_ttl(node, ctx):
    if node.kind == b":" and not node.value.startswith(b"-"):
        return b"<remaining time to live>"
    return node.raw


def norm_sorted(node, ctx):
    if not aggregate(node):
        return node.raw
    return node.head + b"\r\n" + b"".join(sorted(c.raw for c in node.value))


def role(ctx):
    return getattr(ctx, "role", None) or ctx.runner.role


def documented(ctx, got, want, what):
    if got == want:
        return b"<" + what + b" as documented for each server>"
    return b"<" + what + b" on " + role(ctx).encode() + b": " + got + b">"


def vector_names(node):
    return sorted(c.value.lower() for c in node.value if text(c) is not None and c.value.lower() in LOWER_COMMANDS)


def norm_acl_listing(node, ctx):
    if not aggregate(node):
        return node.raw
    category = ctx.step["argv"][-1].decode("latin1").lower()
    want = [] if role(ctx) == "reference" else sorted(c.lower().encode() for c in cases.ACL_LISTINGS.get(category, []))
    hits = vector_names(node)
    return documented(ctx, b" ".join(hits), b" ".join(want), b"vector set commands in the " + category.encode() + b" listing")


def scan_listing(hits, ctx):
    if role(ctx) == "reference":
        want = []
    else:
        want = sorted(cat.encode() + b":" + c.lower().encode() for cat, names in cases.ACL_LISTINGS.items() for c in names)
    return documented(ctx, b" ".join(sorted(hits)), b" ".join(want), b"vector set commands in ACL categories")


def norm_acl_scan(node, ctx):
    return node.raw


def rebuild(node, subst):
    if id(node) in subst:
        return subst[id(node)]
    if aggregate(node) and node.kind in (b"*", b"~", b"%"):
        return node.head + b"\r\n" + b"".join(rebuild(c, subst) for c in node.value)
    return node.raw


def flag_texts(node):
    if not aggregate(node):
        return node.raw
    return b" ".join(sorted(text(c) or c.raw for c in node.value))


def key_flags_want(ctx, name):
    if role(ctx) == "reference" or name.upper() in cases.WRITE_COMMANDS:
        return [b"RW", b"access", b"update"]
    return [b"RO", b"access"]


def info_entry_check(entry, ctx, subst):
    name = text(entry.value[0]) or b""
    cats = entry.value[6]
    got = flag_texts(cats)
    want = [] if role(ctx) == "reference" else sorted(c.encode() for c in cases.ACL_CATEGORIES.get(name.decode("latin1").upper(), ()))
    subst[id(cats)] = documented(ctx, got, b" ".join(want), b"ACL categories")
    specs = entry.value[8]
    if aggregate(specs):
        for spec in specs.value:
            if not aggregate(spec):
                continue
            items = spec.value
            for i in range(0, len(items) - 1, 2):
                if text(items[i]) == b"flags":
                    flags = items[i + 1]
                    subst[id(flags)] = documented(ctx, flag_texts(flags), b" ".join(sorted(key_flags_want(ctx, name.decode("latin1")))), b"key flags")


def norm_acl_metadata(node, ctx):
    if is_error(node) or is_null(node) or not aggregate(node):
        return node.raw
    argv = ctx.step["argv"]
    subst = {}
    if argv[1].upper() == b"INFO":
        for entry in node.value:
            if aggregate(entry) and len(entry.value) >= 10:
                info_entry_check(entry, ctx, subst)
    else:
        command = argv[2].decode("latin1")
        for pair in node.value:
            if aggregate(pair) and len(pair.value) == 2:
                flags = pair.value[1]
                subst[id(flags)] = documented(ctx, flag_texts(flags), b" ".join(sorted(key_flags_want(ctx, command))), b"key flags")
    return rebuild(node, subst)


def norm_acl_login(node, ctx):
    return node.raw


def norm_docs_summary(node, ctx):
    if not aggregate(node) or len(node.value) % 2:
        return node.raw
    out = [node.head, b"\r\n"]
    for i, child in enumerate(node.value):
        if i % 2 == 0 or not aggregate(child) or len(child.value) % 2:
            out.append(child.raw)
            continue
        out.append(child.head + b"\r\n")
        for j, field in enumerate(child.value):
            if j % 2 and text(child.value[j - 1]) == b"summary":
                out.append(b"<summary of type " + field.kind + b">")
            else:
                out.append(field.raw)
    return b"".join(out)


def norm_module_list(node, ctx):
    if not aggregate(node):
        return node.raw
    for entry in node.value:
        if not aggregate(entry):
            continue
        fields = pairs(entry) if entry.kind == b"%" else [(entry.value[i], entry.value[i + 1]) for i in range(0, len(entry.value) - 1, 2)]
        for k, v in fields:
            if text(k) == b"name" and text(v) == b"vectorset":
                return b"vectorset entry: " + entry.raw
    return b"<no vectorset module entry>"


DEBUG_MASKS = [(re.compile(rb"Value at:0x[0-9a-fA-F]+"), b"Value at:<address>"),
               (re.compile(rb"serializedlength:[0-9]+"), b"serializedlength:<n>"),
               (re.compile(rb"lru_seconds_idle:[0-9]+"), b"lru_seconds_idle:<n>"),
               (re.compile(rb"lru:[0-9]+"), b"lru:<n>")]


def norm_debug_object(node, ctx):
    if node.kind != b"+":
        return node.raw
    out = node.raw
    for pattern, repl in DEBUG_MASKS:
        out = pattern.sub(repl, out)
    return out


def scan_parts(node):
    if not aggregate(node) or len(node.value) != 2 or not aggregate(node.value[1]):
        return None, None
    return text(node.value[0]), [text(c) for c in node.value[1].value]


def norm_scan(node, ctx):
    cursor, keys = scan_parts(node)
    if cursor is None or any(k is None for k in keys):
        return node.raw
    if cursor != b"0":
        return b"<incomplete scan>"
    return b"cursor 0 keys " + b" ".join(esc(k).encode() for k in sorted(keys))


def norm_scan_partial(node, ctx):
    cursor, keys = scan_parts(node)
    if cursor is None or any(k is None for k in keys):
        return node.raw
    kinds = set()
    for k in keys:
        kinds.add(text(ctx.probe([b"TYPE", k])))
    duplicate = len(set(keys)) != len(keys)
    return b"scan page: keys of types [" + b" ".join(sorted(t or b"?" for t in kinds)) + b"]" + (b" with repeats" if duplicate else b"")


def norm_vinfo(node, ctx):
    if not aggregate(node):
        return node.raw
    if node.kind == b"%":
        items = pairs(node)
    else:
        if len(node.value) % 2:
            return node.raw
        items = [(node.value[i], node.value[i + 1]) for i in range(0, len(node.value), 2)]
    out = [node.head, b"\r\n"]
    for k, v in items:
        out.append(k.raw)
        if text(k) in (b"max-level", b"vset-uid"):
            out.append(b"<" + v.kind + b"masked>")
        else:
            out.append(v.raw)
    return b"".join(out)


def vsim_entries(node, flags):
    scores = VSIM_SCORE_FLAG in flags
    attrs = VSIM_ATTR_FLAG in flags
    entries = []
    if node.kind == b"%":
        for k, v in pairs(node):
            if text(k) is None:
                return None
            score = None
            if scores and attrs:
                if not aggregate(v) or len(v.value) != 2:
                    return None
                score = text(v.value[0])
            elif scores:
                score = text(v)
            entries.append((k.value, score, k.raw + v.raw))
        return entries
    if not aggregate(node):
        return None
    width = 1 + (1 if scores else 0) + (1 if attrs else 0)
    items = node.value
    if len(items) % width:
        return None
    for i in range(0, len(items), width):
        name = text(items[i])
        if name is None:
            return None
        score = text(items[i + 1]) if scores else None
        entries.append((name, score, b"".join(c.raw for c in items[i:i + width])))
    return entries


def vsim_count(values):
    raw_count = values.get(b"COUNT")
    if raw_count is None:
        return 10
    try:
        return int(raw_count)
    except ValueError:
        return None


def canonical_vsim(node, argv, ctx):
    if is_error(node) or is_null(node):
        return node.raw
    flags, values = cases.vsim_options(argv)
    if b"TRUTH" in flags:
        return node.raw
    entries = vsim_entries(node, flags)
    if entries is None:
        return node.raw
    if not entries:
        return node.raw
    count = vsim_count(values)
    have_scores = VSIM_SCORE_FLAG in flags
    need_probe = not have_scores or (count is not None and len(entries) >= count)
    next_score = None
    if need_probe:
        probe_argv = list(argv) + [VSIM_SCORE_FLAG, b"COUNT", b"%d" % (len(entries) + 1)]
        reply = ctx.probe(probe_argv)
        probe_flags, _ = cases.vsim_options(probe_argv)
        probed = vsim_entries(reply, probe_flags)
        if probed is None:
            return b"<score probe failed> " + node.raw
        lookup = {name: score for name, score, _ in probed}
        names = {name for name, _, _ in entries}
        if not have_scores:
            filled = []
            for name, _, part in entries:
                if name not in lookup:
                    return b"<score probe misses an element> " + node.raw
                filled.append((name, lookup[name], part))
            entries = filled
        for name, score, _ in probed:
            if name not in names:
                next_score = score
                break
    groups = []
    for entry in entries:
        if groups and groups[-1][0][1] == entry[1]:
            groups[-1].append(entry)
        else:
            groups.append([entry])
    truncated = count is not None and len(entries) >= count and next_score is not None and next_score == entries[-1][1]
    out = [node.head, b"\r\n"]
    for gi, group in enumerate(groups):
        if truncated and gi == len(groups) - 1:
            out.append(b"<%d of a tie group at score %s>" % (len(group), group[0][1]))
            continue
        for _, _, part in sorted(group, key=lambda e: e[0]):
            out.append(part)
    return b"".join(out)


def norm_vsim(node, ctx):
    argv = ctx.step.get("inner") or ctx.step["argv"]
    return canonical_vsim(node, argv, ctx)


def norm_exec_vsim(node, ctx):
    if not aggregate(node):
        return node.raw
    position = ctx.step.get("position", 1)
    out = [node.head, b"\r\n"]
    for i, child in enumerate(node.value):
        if i == position:
            out.append(b"<vsim>" + canonical_vsim(child, ctx.step["inner"], ctx))
        else:
            out.append(child.raw)
    return b"".join(out)


def member(ctx, key, name):
    reply = ctx.probe([b"VISMEMBER", key, name])
    return reply.kind in (b":", b"#") and reply.value in (b"1", b"t")


def norm_vrandmember(node, ctx):
    argv = ctx.step.get("inner") or ctx.step["argv"]
    if is_error(node) or is_null(node):
        return node.raw
    key = argv[1]
    if len(argv) < 3:
        name = text(node)
        if name is None or node.kind != b"$":
            return node.raw
        return b"<one member>" if member(ctx, key, name) else b"<not a member: " + name + b">"
    try:
        count = int(argv[2])
    except ValueError:
        return node.raw
    if not aggregate(node) or node.kind != b"*":
        return node.raw
    names = [text(c) for c in node.value]
    if any(n is None for n in names):
        return node.raw
    distinct = sorted(set(names))
    valid = all(member(ctx, key, n) for n in distinct)
    out = b"*%d" % len(names)
    out += b" members" if valid else b" with a non-member"
    if count > 0:
        out += b" distinct" if len(distinct) == len(names) else b" with repeats"
        card = ctx.probe([b"VCARD", key])
        if card.kind == b":" and int(card.value) == len(names):
            out += b" whole set " + b" ".join(esc(n).encode() for n in distinct)
    return out


def vlinks_layer_entries(layer, scored):
    if layer.kind == b"%":
        return sorted(k.raw + v.raw for k, v in pairs(layer))
    if not aggregate(layer):
        return None
    if scored:
        items = layer.value
        if len(items) % 2:
            return None
        return sorted(items[i].raw + items[i + 1].raw for i in range(0, len(items), 2))
    return sorted(c.raw for c in layer.value)


def norm_vlinks(node, ctx):
    if is_error(node) or is_null(node) or not aggregate(node):
        return node.raw
    if not node.value:
        return node.raw
    scored = any(a.upper() == VSIM_SCORE_FLAG for a in ctx.step["argv"][3:])
    entries = vlinks_layer_entries(node.value[-1], scored)
    if entries is None:
        return node.raw
    return b"layer 0: " + node.value[-1].kind + b"%d " % len(entries) + b"".join(entries)


def norm_vlinks_graph(node, ctx):
    if is_error(node) or is_null(node):
        return node.raw
    return b"shape " + skeleton(node)


NORMALISERS = {
    "exact": norm_exact,
    "type": norm_type,
    "integer": norm_integer,
    "ttl": norm_ttl,
    "sorted": norm_sorted,
    "acl-listing": norm_acl_listing,
    "acl-scan": norm_acl_scan,
    "acl-metadata": norm_acl_metadata,
    "acl-login": norm_acl_login,
    "module-list": norm_module_list,
    "docs-summary": norm_docs_summary,
    "debug-object": norm_debug_object,
    "scan": norm_scan,
    "scan-partial": norm_scan_partial,
    "vinfo": norm_vinfo,
    "vsim": norm_vsim,
    "exec-vsim": norm_exec_vsim,
    "vrandmember": norm_vrandmember,
    "vlinks": norm_vlinks,
    "vlinks-graph": norm_vlinks_graph,
}


def resolve_argv(argv, stored):
    out = []
    for a in argv:
        if isinstance(a, dict):
            node = stored.get(a["stored"])
            if node is None:
                out.append(b"<missing stored value>")
                continue
            if "field" in a:
                if aggregate(node) and len(node.value) > a["field"]:
                    node = node.value[a["field"]]
                elif node.kind == b"%" and node.value:
                    node = node.value[1]
            value = text(node)
            out.append(value if value is not None else b"")
        else:
            out.append(a)
    return out


class Runner:
    def __init__(self, port, timeout, role="eski"):
        self.port = port
        self.role = role
        self.timeout = timeout
        self.conns = {}
        self.sub = None
        self.stored = {}
        self.gone = None

    def conn(self, proto):
        if self.gone:
            raise ServerGone(self.gone)
        c = self.conns.get(proto)
        if c is None:
            try:
                c = Conn(self.port, proto, self.timeout)
            except ServerGone as e:
                self.gone = str(e)
                raise
            except OSError as e:
                self.gone = "cannot connect: %s" % e
                raise ServerGone(self.gone)
            self.conns[proto] = c
        return c

    def drop(self, why):
        for c in self.conns.values():
            c.close()
        self.conns = {}
        if self.sub is not None:
            self.sub.close()
            self.sub = None
        if self.gone is None:
            try:
                probe = socket.create_connection((HOST, self.port), timeout=2)
                probe.close()
            except OSError:
                self.gone = why + "; the server no longer accepts connections"
        if "no reply within the timeout" in why:
            self.gone = why

    def run_step(self, step):
        kind = step["kind"]
        if kind == "sleep":
            time.sleep(step["seconds"])
            return None
        if kind == "subscribe":
            if self.gone:
                raise ServerGone(self.gone)
            try:
                self.sub = Conn(self.port, 2, self.timeout)
            except OSError as e:
                raise ServerGone("cannot connect: %s" % e)
            self.sub.send(step["argv"])
            return self.sub.node().raw
        if kind == "unsubscribe":
            if self.sub is not None:
                self.sub.close()
                self.sub = None
            return None
        if kind == "events":
            if self.sub is None:
                return b"<no subscriber>"
            self.sub.send([b"PING"])
            out = []
            while True:
                node = self.sub.node()
                if aggregate(node) and node.value and text(node.value[0]) in (b"pong", b"PONG"):
                    break
                if node.kind == b"+" and node.value == b"PONG":
                    break
                out.append(node.raw)
            return b"events: " + b"".join(out)
        conn = self.conn(step["proto"])
        if kind == "pipeline":
            return b"".join(n.raw for n in conn.pipeline(step["commands"]))
        if kind == "acl-scan":
            cats = conn.call([b"ACL", b"CAT"])
            if not aggregate(cats):
                return cats.raw
            hits = []
            for cat in cats.value:
                name = text(cat)
                if name is None:
                    continue
                listing = conn.call([b"ACL", b"CAT", name])
                if aggregate(listing):
                    for c in listing.value:
                        t = text(c)
                        if t is not None and t.lower() in LOWER_COMMANDS:
                            hits.append(name + b":" + t.lower())
            return scan_listing(hits, Context(self, step, conn))
        if kind == "login":
            return self.login(step)
        argv = resolve_argv(step["argv"], self.stored)
        node = conn.call(argv)
        if step.get("store"):
            self.stored[step["store"]] = node
        return NORMALISERS[step["norm"]](node, Context(self, step, conn))

    def login(self, step):
        try:
            c = Conn(self.port, step["proto"], self.timeout)
        except OSError as e:
            raise ServerGone("cannot connect: %s" % e)
        try:
            auth = c.call([b"AUTH", step["user"], step["password"]])
            if is_error(auth) or text(auth) != b"OK":
                return b"<" + step["user"] + b" could not authenticate: " + auth.raw + b">"
            verdicts = []
            for argv in step["commands"]:
                reply = c.call(argv)
                if is_error(reply) and reply.value.startswith(b"NOPERM"):
                    verdicts.append("NOPERM key" if b"access a key" in reply.value else "NOPERM command")
                else:
                    verdicts.append("ran")
        finally:
            c.close()
        got = " ".join(verdicts).encode()
        want = " ".join(step["expect"][self.role]).encode()
        if got == want:
            return b"login " + step["user"] + b": verdicts as documented for each server"
        return b"login " + step["user"] + b" on " + self.role.encode() + b": " + got

    def run(self, steps, results):
        for i, step in enumerate(steps):
            if self.gone and step["kind"] not in ("sleep",):
                results[i] = (None, self.gone)
                continue
            try:
                results[i] = (self.run_step(step), None)
            except ServerGone as e:
                self.drop(str(e))
                results[i] = (None, str(e))
            except (ValueError, IndexError) as e:
                self.drop("unparsable reply: %s" % e)
                results[i] = (None, "unparsable reply: %s" % e)
            except Exception as e:
                results[i] = (None, "harness error: %r" % e)
        self.drop("finished")


def label(step, index):
    argv = step.get("argv")
    if step["kind"] == "pipeline":
        shown = step["note"]
    elif step["kind"] in ("events", "subscribe", "unsubscribe", "acl-scan", "login", "sleep"):
        shown = step["note"]
    else:
        parts = []
        for a in argv:
            if isinstance(a, dict):
                parts.append("<stored %s>" % a["stored"])
            else:
                s = esc(a)
                parts.append(s if len(s) <= 40 else s[:32] + "...(%d bytes)" % len(a))
        shown = " ".join(parts)
        if len(shown) > 160:
            shown = shown[:150] + "..."
    return "%s %s RESP%d #%d %s" % (step["section"], step["kind"], step["proto"], index, shown)


def show(b):
    if b is None:
        return "None"
    s = esc(b)
    if len(s) > 220:
        return s[:200] + "...(%d bytes)" % len(b)
    return s


def first_difference(a, b):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return n


def compare(eski_port, ref_port, steps, timeout):
    eski = [None] * len(steps)
    ref = [None] * len(steps)
    threads = [threading.Thread(target=Runner(eski_port, timeout, "eski").run, args=(steps, eski)),
               threading.Thread(target=Runner(ref_port, timeout, "reference").run, args=(steps, ref))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return eski, ref


def report(steps, eski, ref, out, summary_path=None, quiet=False):
    passed = failed = 0
    table = OrderedDict()
    records = []
    reference_problems = 0
    for i, step in enumerate(steps):
        if step["kind"] in ("sleep", "unsubscribe"):
            continue
        e, e_err = eski[i] or (None, "no result")
        r, r_err = ref[i] or (None, "no result")
        name = label(step, i + 1)
        key = (step["kind"] if step["kind"] != "case" else "case", step.get("command", "?"), step["proto"])
        row = table.setdefault(key, [0, 0])
        if r_err is not None:
            reference_problems += 1
        ok = e_err is None and r_err is None and e == r
        if ok:
            passed += 1
            row[0] += 1
            if not quiet:
                out.write("PASS %s\n" % name)
        else:
            failed += 1
            row[1] += 1
            if e_err is not None or r_err is not None:
                detail = "eski=%s redis=%s" % ("<%s>" % e_err if e_err else show(e), "<%s>" % r_err if r_err else show(r))
            else:
                at = first_difference(e, r)
                detail = "first difference at byte %d eski=%s redis=%s" % (at, show(e), show(r))
            out.write("FAIL %s %s\n" % (name, detail))
        records.append({"index": i + 1, "section": step["section"], "kind": step["kind"], "command": step.get("command"), "proto": step["proto"],
                        "norm": step["norm"], "label": name, "ok": ok, "eski_error": e_err, "reference_error": r_err})
    out.write("vector set comparison by step kind, command and protocol (passed/failed):\n")
    for (kind, command, proto), (p, f) in sorted(table.items(), key=lambda kv: (kv[0][0] != "case", kv[0][0], kv[0][1], kv[0][2])):
        out.write("  %-8s %-16s RESP%d %5d %5d\n" % (kind, command, proto, p, f))
    captured = [r for r in records if r["kind"] == "case"]
    out.write("captured cases: %d passed, %d failed; other steps: %d passed, %d failed\n" % (
        sum(1 for r in captured if r["ok"]), sum(1 for r in captured if not r["ok"]),
        sum(1 for r in records if r["kind"] != "case" and r["ok"]), sum(1 for r in records if r["kind"] != "case" and not r["ok"])))
    if reference_problems:
        out.write("reference problems: %d steps did not complete on the reference server\n" % reference_problems)
    if summary_path:
        with open(summary_path, "w", encoding="utf-8") as handle:
            json.dump({"passed": passed, "failed": failed, "reference_problems": reference_problems, "steps": records}, handle, indent=1)
            handle.write("\n")
    out.write("passed: %d failed: %d\n" % (passed, failed))
    return failed == 0 and reference_problems == 0


def list_plan(steps, out):
    counts = OrderedDict()
    for step in steps:
        if step["kind"] != "case":
            continue
        key = (step.get("command"), step["proto"])
        counts[key] = counts.get(key, 0) + 1
    total = 0
    for (command, proto), n in sorted(counts.items()):
        out.write("%-16s RESP%d %4d\n" % (command, proto, n))
        total += n
    out.write("captured cases: %d, steps: %d\n" % (total, len(steps)))
    usage = OrderedDict()
    for step in steps:
        usage[step["norm"]] = usage.get(step["norm"], 0) + 1
    for norm, n in usage.items():
        out.write("normalisation %-13s used by %4d steps\n" % (norm, n))


def list_normalisations(steps, out):
    usage = {}
    for step in steps:
        usage.setdefault(step["norm"], set()).add(step.get("command", "?"))
    for name, (reason, kept) in NORMALISATIONS.items():
        out.write("%s\n  reason: %s\n  still compared: %s\n  used for: %s\n" % (name, reason, kept, ", ".join(sorted(usage.get(name, ())))))


def main(argv=None):
    parser = argparse.ArgumentParser(prog="compare.py", description="Replay the captured vector set cases against Eski and the pinned reference server and compare the replies byte for byte in RESP2 and RESP3.")
    parser.add_argument("eski_port", type=int, nargs="?")
    parser.add_argument("reference_port", type=int, nargs="?")
    parser.add_argument("--sections", default="", help="comma-separated sections: " + ",".join(n for n, _ in cases.SECTIONS))
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait for one reply")
    parser.add_argument("--summary", help="write a JSON record of every step to this path")
    parser.add_argument("--list", action="store_true", help="print the case counts by command and protocol and exit")
    parser.add_argument("--normalisations", action="store_true", help="print every normalisation with its reason and exit")
    parser.add_argument("--quiet", action="store_true", help="print only failing steps and the summary")
    args = parser.parse_args(argv)
    sections = [s for s in args.sections.split(",") if s]
    unknown = [s for s in sections if s not in dict(cases.SECTIONS)]
    if unknown:
        parser.error("unknown section %s" % ", ".join(unknown))
    steps = cases.build(sections or None)
    if args.list:
        list_plan(steps, sys.stdout)
        return 0
    if args.normalisations:
        list_normalisations(steps, sys.stdout)
        return 0
    if args.eski_port is None or args.reference_port is None:
        parser.error("the Eski port and the reference port are required")
    eski, ref = compare(args.eski_port, args.reference_port, steps, args.timeout)
    ok = report(steps, eski, ref, sys.stdout, args.summary, args.quiet)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
