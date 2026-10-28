import argparse
import fnmatch
import json
import math
import re
import shlex
import socket
import sys
import time
from collections import Counter
from pathlib import Path


class YamlError(ValueError):
    pass


NULL_WORDS = {"", "~", "null", "Null", "NULL"}
TRUE_WORDS = {"yes", "Yes", "YES", "true", "True", "TRUE", "on", "On", "ON"}
FALSE_WORDS = {"no", "No", "NO", "false", "False", "FALSE", "off", "Off", "OFF"}
INT_FORM = re.compile(r"[-+]?(?:0b[01_]+|0[0-7_]+|0|[1-9][0-9_]*|0x[0-9a-fA-F_]+)$")
FLOAT_FORM = re.compile(
    r"(?:[-+]?[0-9][0-9_]*\.[0-9_]*(?:[eE][-+][0-9]+)?"
    r"|\.[0-9][0-9_]*(?:[eE][-+][0-9]+)?"
    r"|[-+]?\.(?:inf|Inf|INF)"
    r"|\.(?:nan|NaN|NAN))$"
)
ESCAPES = {
    "0": "\0", "a": "\a", "b": "\b", "t": "\t", "\t": "\t", "n": "\n", "v": "\v", "f": "\f",
    "r": "\r", "e": "\x1b", " ": " ", '"': '"', "/": "/", "\\": "\\", "N": "\x85",
    "_": "\xa0", "L": " ", "P": " ",
}
HEX_ESCAPES = {"x": 2, "u": 4, "U": 8}
BLOCK_HEADER = re.compile(r"([|>])([-+1-9]{0,2})[ \t]*(?:#.*)?$")
KEY_COLON = re.compile(r":(?:[ \t]|$)")
COMMENT_START = re.compile(r"[ \t]#")


def resolve_plain(text):
    if text in NULL_WORDS:
        return None
    if text in TRUE_WORDS:
        return True
    if text in FALSE_WORDS:
        return False
    if INT_FORM.match(text):
        sign = -1 if text[0] == "-" else 1
        body = text.lstrip("+-").replace("_", "")
        if body.startswith("0b"):
            return sign * int(body[2:], 2)
        if body.startswith("0x"):
            return sign * int(body[2:], 16)
        if len(body) > 1 and body[0] == "0":
            return sign * int(body, 8)
        return sign * int(body)
    if FLOAT_FORM.match(text):
        low = text.lower().replace("_", "")
        if low.endswith(".inf"):
            return float("-inf") if low.startswith("-") else float("inf")
        if low.endswith(".nan"):
            return float("nan")
        return float(low)
    return text


def close_quote(s, quote, start=0):
    i = start
    n = len(s)
    while i < n:
        c = s[i]
        if quote == "'":
            if c == "'":
                if i + 1 < n and s[i + 1] == "'":
                    i += 2
                    continue
                return i
        else:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                return i
        i += 1
    return -1


def unescape(s, where):
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        if i + 1 >= n:
            raise YamlError(f"{where}: dangling backslash in a double quoted scalar")
        e = s[i + 1]
        if e in ESCAPES:
            out.append(ESCAPES[e])
            i += 2
            continue
        if e in HEX_ESCAPES:
            width = HEX_ESCAPES[e]
            digits = s[i + 2:i + 2 + width]
            if len(digits) != width or any(d not in "0123456789abcdefABCDEF" for d in digits):
                raise YamlError(f"{where}: bad \\{e} escape")
            out.append(chr(int(digits, 16)))
            i += 2 + width
            continue
        raise YamlError(f"{where}: unknown escape \\{e}")
    return "".join(out)


def unquote(raw, quote, where):
    if quote == "'":
        return raw.replace("''", "'")
    return unescape(raw, where)


def odd_backslashes(s):
    count = len(s) - len(s.rstrip("\\"))
    return count % 2 == 1


def fold_flow(segments, quote, where):
    last = len(segments) - 1
    pieces = []
    for k, seg in enumerate(segments):
        s = seg if k == 0 else seg.lstrip(" \t")
        escaped = False
        if k < last:
            if quote == '"' and odd_backslashes(s):
                s = s[:-1]
                escaped = True
            else:
                s = s.rstrip(" \t")
        pieces.append((s, escaped))
    out = []
    breaks = 0
    prev_escaped = False
    for k, (s, escaped) in enumerate(pieces):
        if k > 0 and k < last and s == "":
            breaks += 1
            continue
        if k > 0:
            if breaks:
                out.append("\n" * breaks)
            elif not prev_escaped:
                out.append(" ")
        out.append(unquote(s, quote, where))
        breaks = 0
        prev_escaped = escaped
    return "".join(out)


def fold_block(lines):
    out = []
    pending = 0
    prev_more = False
    first = True
    for line in lines:
        if line == "":
            pending += 1
            continue
        more = line[0] in " \t"
        if first:
            out.append("\n" * pending)
        elif more or prev_more:
            out.append("\n" * (pending + 1))
        elif pending:
            out.append("\n" * pending)
        else:
            out.append(" ")
        out.append(line)
        pending = 0
        prev_more = more
        first = False
    return "".join(out)


def flow_end(text):
    depth = 0
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c in "'\"":
            j = close_quote(text, c, i + 1)
            if j < 0:
                return -1
            i = j + 1
            continue
        if c in "[{":
            depth += 1
        elif c in "]}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


class FlowParser:
    def __init__(self, text, where):
        self.t = text
        self.i = 0
        self.where = where

    def fail(self, msg):
        raise YamlError(f"{self.where}: {msg} in flow collection")

    def peek(self):
        self.skip()
        return self.t[self.i] if self.i < len(self.t) else ""

    def skip(self):
        while self.i < len(self.t) and self.t[self.i] in " \t":
            self.i += 1

    def node(self):
        c = self.peek()
        if c == "[":
            return self.seq()
        if c == "{":
            return self.mapping()
        if c in "'\"":
            end = close_quote(self.t, c, self.i + 1)
            if end < 0:
                self.fail("unterminated quoted scalar")
            raw = self.t[self.i + 1:end]
            self.i = end + 1
            return unquote(raw, c, self.where)
        if c in "&*!|>%@`":
            self.fail(f"unsupported indicator {c!r}")
        start = self.i
        while self.i < len(self.t):
            c = self.t[self.i]
            if c in ",[]{}":
                break
            if c == ":" and (self.i + 1 >= len(self.t) or self.t[self.i + 1] in " ,[]{}"):
                break
            self.i += 1
        return resolve_plain(self.t[start:self.i].strip())

    def seq(self):
        self.i += 1
        out = []
        while True:
            if self.peek() == "]":
                self.i += 1
                return out
            out.append(self.node())
            c = self.peek()
            if c == ",":
                self.i += 1
                continue
            if c == "]":
                self.i += 1
                return out
            self.fail("expected ',' or ']'")

    def mapping(self):
        self.i += 1
        out = {}
        while True:
            if self.peek() == "}":
                self.i += 1
                return out
            key = self.node()
            value = None
            if self.peek() == ":":
                self.i += 1
                if self.peek() not in (",", "}"):
                    value = self.node()
            out[key] = value
            c = self.peek()
            if c == ",":
                self.i += 1
                continue
            if c == "}":
                self.i += 1
                return out
            self.fail("expected ',' or '}'")


def is_dash(text):
    return text == "-" or text.startswith("- ") or text.startswith("-\t")


class Reader:
    def __init__(self, text):
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        self.final_break = text.endswith("\n")
        self.raw = text.split("\n")
        self.n = len(self.raw)
        self.ind = []
        self.txt = []
        for line in self.raw:
            body = line.lstrip(" ")
            self.ind.append(len(line) - len(body))
            self.txt.append(body.rstrip())

    def fail(self, i, msg):
        raise YamlError(f"line {i + 1}: {msg}")

    def skip(self, i):
        while i < self.n:
            t = self.txt[i]
            if t and not t.startswith("#"):
                if t.startswith("\t"):
                    self.fail(i, "tab used for indentation")
                return i
            i += 1
        return i

    def parse(self):
        i = self.skip(0)
        if i < self.n and self.ind[i] == 0 and self.txt[i] == "---":
            i = self.skip(i + 1)
        if i >= self.n:
            return None
        value, i = self.node(i, -1)
        i = self.skip(i)
        if i < self.n:
            self.fail(i, "unexpected content after the top level node")
        return value

    def key_split(self, i, t):
        if t[0] in "'\"":
            end = close_quote(t, t[0], 1)
            if end < 0:
                return None
            after = t[end + 1:]
            if after.startswith(":") and (len(after) == 1 or after[1] in " \t"):
                return unquote(t[1:end], t[0], f"line {i + 1}"), after[1:]
            return None
        if is_dash(t) or t[0] in "#[{|>&*!%@`?":
            return None
        m = KEY_COLON.search(t)
        if not m:
            return None
        c = COMMENT_START.search(t)
        if c and c.start() < m.start():
            return None
        return resolve_plain(t[:m.start()].rstrip()), t[m.start() + 1:]

    def node(self, i, parent):
        ind, t = self.ind[i], self.txt[i]
        if is_dash(t):
            return self.sequence(i, ind)
        if self.key_split(i, t) is not None:
            return self.mapping(i, ind)
        return self.scalar(i, t, parent)

    def sequence(self, i, ind):
        out = []
        while True:
            i = self.skip(i)
            if i >= self.n or self.ind[i] < ind:
                break
            if self.ind[i] > ind:
                self.fail(i, "bad indentation in a sequence")
            t = self.txt[i]
            if not is_dash(t):
                break
            rest = t[1:]
            body = rest.lstrip(" \t")
            if body == "" or body.startswith("#"):
                j = self.skip(i + 1)
                if j < self.n and self.ind[j] > ind:
                    value, i = self.node(j, ind)
                else:
                    value, i = None, i + 1
            else:
                self.ind[i] = ind + 1 + len(rest) - len(body)
                self.txt[i] = body
                value, i = self.node(i, ind)
            out.append(value)
        return out, i

    def mapping(self, i, ind):
        out = {}
        while True:
            i = self.skip(i)
            if i >= self.n or self.ind[i] < ind:
                break
            if self.ind[i] > ind:
                self.fail(i, "bad indentation in a mapping")
            t = self.txt[i]
            split = self.key_split(i, t)
            if split is None:
                if is_dash(t):
                    self.fail(i, "sequence entry where a mapping key was expected")
                self.fail(i, "expected a mapping key")
            key, rest = split
            value, i = self.value(i, rest, ind)
            out[key] = value
        return out, i

    def value(self, i, rest, ind):
        r = rest.strip()
        if r == "" or r.startswith("#"):
            j = self.skip(i + 1)
            if j < self.n and self.ind[j] > ind:
                return self.node(j, ind)
            if j < self.n and self.ind[j] == ind and is_dash(self.txt[j]):
                return self.sequence(j, ind)
            return None, i + 1
        return self.scalar(i, r, ind)

    def scalar(self, i, s, parent):
        c = s[0]
        if c in "|>":
            return self.block(i, s, parent)
        if c in "'\"":
            return self.quoted(i, s)
        if c in "[{":
            return self.flow(i, s)
        if c in "&*!%@`":
            self.fail(i, f"unsupported YAML indicator {c!r}")
        return self.plain(i, s, parent)

    def plain(self, i, s, parent):
        m = COMMENT_START.search(s)
        text = (s[:m.start()] if m else s).rstrip()
        parts = [text]
        j = i + 1
        last = i
        blanks = 0
        while j < self.n:
            t = self.txt[j]
            if t == "":
                blanks += 1
                j += 1
                continue
            if self.ind[j] <= parent or t.startswith("#"):
                break
            colon = KEY_COLON.search(t)
            m = COMMENT_START.search(t)
            if colon and not (m and m.start() < colon.start()):
                self.fail(j, "mapping value inside a plain scalar")
            line = (t[:m.start()] if m else t).strip()
            parts.append("\n" * blanks if blanks else " ")
            parts.append(line)
            blanks = 0
            last = j
            j += 1
            if m:
                break
        return resolve_plain("".join(parts)), last + 1

    def quoted(self, i, s):
        quote = s[0]
        segments = []
        cur = s[1:]
        j = i
        while True:
            end = close_quote(cur, quote)
            if end >= 0:
                segments.append(cur[:end])
                after = cur[end + 1:].strip()
                break
            segments.append(cur)
            j += 1
            if j >= self.n:
                self.fail(i, "unterminated quoted scalar")
            cur = self.raw[j]
        if after and not after.startswith("#"):
            self.fail(j, f"unexpected text after a quoted scalar: {after[:40]!r}")
        return fold_flow(segments, quote, f"line {i + 1}"), j + 1

    def block(self, i, s, parent):
        m = BLOCK_HEADER.match(s)
        if not m:
            self.fail(i, f"bad block scalar header {s!r}")
        style, flags = m.group(1), m.group(2)
        chomp = ""
        explicit = 0
        for f in flags:
            if f in "+-":
                if chomp:
                    self.fail(i, "two chomping indicators")
                chomp = f
            else:
                if explicit:
                    self.fail(i, "two indentation indicators")
                explicit = int(f)
        indent = max(parent, 0) + explicit if explicit else None
        lines = []
        last_line = -1
        j = i + 1
        while j < self.n:
            raw = self.raw[j]
            if raw.strip() == "":
                lines.append("")
                j += 1
                continue
            ind = len(raw) - len(raw.lstrip(" "))
            if indent is None:
                if ind <= parent:
                    break
                indent = ind
            if ind < indent:
                break
            lines.append(raw[indent:])
            last_line = j
            j += 1
        tail = "" if last_line == self.n - 1 and not self.final_break else "\n"
        end = len(lines)
        while end > 0 and lines[end - 1] == "":
            end -= 1
        content, trailing = lines[:end], lines[end:]
        text = "\n".join(content) if style == "|" else fold_block(content)
        if not content:
            value = "\n" * len(trailing) if chomp == "+" else ""
        elif chomp == "-":
            value = text
        elif chomp == "+":
            value = text + tail + "\n" * len(trailing)
        else:
            value = text + tail
        return value, j

    def flow(self, i, s):
        text = s
        j = i
        while True:
            end = flow_end(text)
            if end >= 0:
                break
            j += 1
            if j >= self.n:
                self.fail(i, "unterminated flow collection")
            text += " " + self.raw[j].strip()
        after = text[end + 1:].strip()
        if after and not after.startswith("#"):
            self.fail(j, "unexpected text after a flow collection")
        parser = FlowParser(text[:end + 1], f"line {i + 1}")
        value = parser.node()
        return value, j + 1


def load_yaml(text):
    return Reader(text).parse()


CLIENT_TOOLS = ("memtier_benchmark", "redis-benchmark")
CONTAINER_COMMANDS = {
    "acl", "client", "cluster", "command", "config", "debug", "function", "latency", "memory",
    "module", "object", "pubsub", "script", "slowlog", "xgroup", "xinfo",
}
UNSAFE_PROBES = {
    "shutdown", "sync", "psync", "failover", "replicaof", "slaveof", "monitor",
    "debug|segfault", "debug|panic", "debug|restart", "debug|crash-and-recover", "debug|oom", "debug|assert",
}
ENDPOINT_OPTIONS = {
    "memtier_benchmark": {"-s", "--server", "-p", "--port", "-S", "--unix-socket", "--uri", "--json-out-file"},
    "redis-benchmark": {"-h", "-p", "-s", "-u"},
}
RB_VALUE_OPTIONS = {
    "-h", "-p", "-s", "-u", "-a", "-c", "-n", "-d", "-k", "-r", "-P", "-t", "--threads", "--dbnum", "--user",
    "--precision", "--seed", "--sni", "--cacert", "--cacertdir", "--cert", "--key", "--tls-ciphers",
    "--tls-ciphersuites",
}
RB_DEFAULT_TESTS = ["ping", "set", "get", "incr", "lpush", "rpush", "lpop", "rpop", "sadd", "hset", "spop", "zadd", "zpopmin", "lrange", "mset"]
SAFE_KEY = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*$")


def split_args(arguments):
    if arguments is None:
        return []
    if isinstance(arguments, list):
        return [str(a) for a in arguments]
    return shlex.split(str(arguments))


def client_configs(doc):
    many = doc.get("clientconfigs")
    if isinstance(many, list):
        return [c for c in many if isinstance(c, dict)]
    one = doc.get("clientconfig")
    return [one] if isinstance(one, dict) else []


def command_words(text):
    try:
        return shlex.split(text)
    except ValueError:
        return text.split()


def names_for(words):
    if not words:
        return set()
    top = str(words[0]).lower()
    out = {top}
    if top in CONTAINER_COMMANDS and len(words) > 1:
        out.add(f"{top}|{str(words[1]).lower()}")
    return out


def option_values(argv, names):
    out = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in names and i + 1 < len(argv):
            out.append(argv[i + 1])
            i += 2
            continue
        for n in names:
            if n.startswith("--") and a.startswith(n + "="):
                out.append(a[len(n) + 1:])
        i += 1
    return out


def memtier_commands(argv):
    commands = option_values(argv, {"--command"})
    if commands:
        out = set()
        for c in commands:
            out |= names_for(command_words(c))
        return out
    ratios = option_values(argv, {"--ratio"})
    ratio = ratios[-1] if ratios else "1:10"
    sets, _, gets = ratio.partition(":")
    out = set()
    if sets.strip() not in ("0", ""):
        out.add("set")
    if gets.strip() not in ("0", ""):
        out.add("get")
    return out or {"set", "get"}


def rb_command_part(argv):
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in RB_VALUE_OPTIONS:
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        return i
    return len(argv)


def rb_commands(argv):
    start = rb_command_part(argv)
    if start < len(argv):
        return names_for(argv[start:])
    tests = option_values(argv[:start], {"-t"})
    names = RB_DEFAULT_TESTS if not tests else [x.strip().lower() for x in tests[-1].split(",") if x.strip()]
    out = set()
    for name in names:
        if name.startswith("ping"):
            out.add("ping")
        else:
            out.add(re.sub(r"_\d+$", "", name))
    return out


def tool_commands(tool, argv):
    if tool == "memtier_benchmark":
        return memtier_commands(argv)
    if tool == "redis-benchmark":
        return rb_commands(argv)
    return set()


def init_command_lists(db):
    cmds = None
    for k, v in db.items():
        if "init_commands" in str(k):
            cmds = v
    if cmds is None:
        return []
    if isinstance(cmds, str):
        cmds = [cmds]
    out = []
    for c in cmds:
        if isinstance(c, list):
            out.append([str(x) for x in c])
        elif isinstance(c, str):
            out.append(shlex.split(c) if '"' in c else c.split())
        else:
            out.append([str(c)])
    return [c for c in out if c]


def init_lua_scripts(db):
    scripts = None
    for k, v in db.items():
        if "init_lua" in str(k):
            scripts = v
    if scripts is None:
        return []
    if isinstance(scripts, str):
        return [scripts]
    return [str(s) for s in scripts]


def keyspace_check(db):
    check = db.get("check")
    if not isinstance(check, dict):
        return None
    out = {}
    if "keyspacelen" in check:
        out["keyspacelen"] = int(check["keyspacelen"])
    if "keyspacelen_min" in check:
        out["keyspacelen_min"] = int(check["keyspacelen_min"])
    return out or None


def case_commands(doc):
    tested = sorted({str(c).strip().lower() for c in doc.get("tested-commands") or [] if str(c).strip()})
    db = doc.get("dbconfig") if isinstance(doc.get("dbconfig"), dict) else {}
    workload = set()
    configs = list(client_configs(doc))
    if isinstance(db.get("preload_tool"), dict):
        configs.append(db["preload_tool"])
    for cfg in configs:
        try:
            argv = split_args(cfg.get("arguments"))
        except ValueError:
            continue
        workload |= tool_commands(cfg.get("tool"), argv)
    for c in init_command_lists(db):
        workload |= names_for(c)
    if init_lua_scripts(db):
        workload.add("eval")
    return tested, sorted(workload)


def assess(doc, implemented, reference=None):
    reasons = []
    db = doc.get("dbconfig") if isinstance(doc.get("dbconfig"), dict) else {}
    topologies = [str(t) for t in doc.get("redis-topologies") or []]
    if topologies and "oss-standalone" not in topologies:
        reasons.append(f"runs only on {', '.join(topologies)}; the harness starts standalone servers")
    clients = client_configs(doc)
    if not clients:
        reasons.append("declares no clientconfig")
    for c in clients:
        if c.get("tool") not in CLIENT_TOOLS:
            reasons.append(f"client tool {c.get('tool')} is not memtier_benchmark or redis-benchmark")
    pre = db.get("preload_tool")
    if isinstance(pre, dict) and pre.get("tool") not in CLIENT_TOOLS:
        reasons.append(f"preload tool {pre.get('tool')} is not memtier_benchmark or redis-benchmark")
    for cfg in clients + ([pre] if isinstance(pre, dict) else []):
        try:
            split_args(cfg.get("arguments"))
        except ValueError as e:
            reasons.append(f"arguments cannot be split like a shell command line: {e}")
    if "dataset" in db:
        url = str(db.get("dataset"))
        form = "an RDB dataset" if url.lower().endswith(".rdb") else "a dataset"
        reasons.append(f"loads {form} from {url}, which the harness cannot replay into every target")
    if db.get("wait_for_bgsave") in (True, "true", "yes", 1):
        reasons.append("measures BGSAVE duration (dbconfig.wait_for_bgsave), which the official runner also skips")
    tested, workload = case_commands(doc)
    ignored = []
    if reference is not None:
        ignored = sorted(c for c in tested if c not in workload and c not in reference)
    required = (set(tested) - set(ignored)) | set(workload)
    missing = sorted(c for c in required if c not in implemented)
    if missing:
        reasons.append("eski lacks " + ", ".join(missing))
    return list(dict.fromkeys(reasons)), missing, tested, workload, ignored


def read_case_files(suites_dir):
    out = []
    for path in sorted(Path(suites_dir).glob("*.yml")):
        entry = {"file": path.name, "path": str(path), "doc": None, "error": None}
        try:
            doc = load_yaml(path.read_text(encoding="utf-8"))
            if not isinstance(doc, dict):
                raise YamlError("top level node is not a mapping")
            entry["doc"] = doc
        except (YamlError, UnicodeDecodeError, ValueError) as e:
            entry["error"] = str(e)
        out.append(entry)
    return out


def is_case(entry):
    if entry["file"] == "defaults.yml":
        return False
    return True


def suites_dir_of(tree):
    p = Path(tree)
    sub = p / "redis_benchmarks_specification" / "test-suites"
    return sub if sub.is_dir() else p


def assess_tree(tree, implemented, reference=None):
    entries = [e for e in read_case_files(suites_dir_of(tree)) if is_case(e)]
    seen = {}
    for e in entries:
        doc = e["doc"]
        if doc is None:
            e["name"] = Path(e["file"]).stem
            e["reasons"] = [f"could not parse: {e['error']}"]
            e["missing"] = []
            e["tested"] = []
            e["workload"] = []
            e["ignored"] = []
            e["memtier_based"] = False
            continue
        e["name"] = str(doc.get("name") or Path(e["file"]).stem)
        reasons, missing, tested, workload, ignored = assess(doc, implemented, reference)
        if e["name"] in seen:
            reasons.append(f"duplicates the test name of {seen[e['name']]}")
        seen.setdefault(e["name"], e["file"])
        e["reasons"] = reasons
        e["missing"] = missing
        e["tested"] = tested
        e["workload"] = workload
        e["ignored"] = ignored
        clients = client_configs(doc)
        e["memtier_based"] = bool(clients) and all(c.get("tool") == "memtier_benchmark" for c in clients)
        e["multi_client"] = len(clients) > 1
    return entries


def needed_commands(entries):
    out = set()
    for e in entries:
        out |= set(e.get("tested") or [])
        out |= set(e.get("workload") or [])
    return out


def parse_cpus(spec):
    out = []
    for part in str(spec).split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return out


def format_cpus(cores):
    cores = sorted(set(cores))
    parts = []
    i = 0
    while i < len(cores):
        j = i
        while j + 1 < len(cores) and cores[j + 1] == cores[j] + 1:
            j += 1
        parts.append(str(cores[i]) if i == j else f"{cores[i]}-{cores[j]}")
        i = j + 1
    return ",".join(parts)


def requested_cpus(cfg):
    try:
        value = float(((cfg.get("resources") or {}).get("requests") or {}).get("cpus"))
    except (TypeError, ValueError):
        return None
    if value <= 0:
        return None
    return max(1, math.ceil(value))


def client_cpusets(cfgs, cores):
    needs = [requested_cpus(c) for c in cfgs]
    if len(cfgs) == 1:
        n = needs[0] or len(cores)
        return [format_cpus(cores[:min(n, len(cores))])]
    if all(needs) and sum(needs) <= len(cores):
        out = []
        pos = 0
        for n in needs:
            out.append(format_cpus(cores[pos:pos + n]))
            pos += n
        return out
    return [format_cpus(cores)] * len(cfgs)


def strip_endpoint(argv, tool):
    opts = ENDPOINT_OPTIONS.get(tool, set())
    limit = rb_command_part(argv) if tool == "redis-benchmark" else len(argv)
    out = []
    removed = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if i < limit and a in opts:
            removed.extend(argv[i:i + 2])
            i += 2
            continue
        if i < limit and a.startswith("--") and a.split("=", 1)[0] in opts and "=" in a:
            removed.append(a)
            i += 1
            continue
        out.append(a)
        i += 1
    return out, removed


def test_time_slots(argv):
    slots = []
    for i, a in enumerate(argv):
        if a == "--test-time" and i + 1 < len(argv) and argv[i + 1].strip('"').isdigit():
            slots.append((i + 1, "", int(argv[i + 1].strip('"'))))
        elif a.startswith("--test-time=") and a[12:].strip('"').isdigit():
            slots.append((i, "--test-time=", int(a[12:].strip('"'))))
    return slots


def declared_test_time(argv):
    slots = test_time_slots(argv)
    return slots[-1][2] if slots else None


def with_test_time(argv, seconds):
    out = list(argv)
    for i, prefix, _ in test_time_slots(argv):
        out[i] = f"{prefix}{seconds}"
    return out


def memtier_run_count(argv):
    values = option_values(argv, {"--run-count", "-x"})
    try:
        return max(1, int(values[-1])) if values else 1
    except ValueError:
        return 1


def declared_timeout(cfg):
    value = cfg.get("timeout")
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
        return None
    return int(math.ceil(value))


def config_text(value):
    if value is True:
        return "yes"
    if value is False:
        return "no"
    if value is None:
        return ""
    return str(value)


def safe_key(name, taken):
    key = name if SAFE_KEY.match(name) else re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._-") or "case"
    base = key
    n = 2
    while key in taken:
        key = f"{base}-{n}"
        n += 1
    taken.add(key)
    return key


def tool_image(tool, cfg, opts):
    if tool == "memtier_benchmark":
        return opts.get("memtier_image") or str(cfg.get("run_image") or "") or opts.get("default_memtier_image", "")
    return opts.get("rb_image", "")


def case_item(entry, opts, cores, taken):
    doc = entry["doc"]
    db = doc.get("dbconfig") if isinstance(doc.get("dbconfig"), dict) else {}
    cfgs = client_configs(doc)
    declared = [declared_test_time(split_args(c.get("arguments"))) for c in cfgs]
    known = [t for t in declared if t is not None]
    base = min(known) if known else None
    cap = opts.get("quick_cap")
    cpusets = client_cpusets(cfgs, cores)
    clients = []
    for idx, cfg in enumerate(cfgs):
        tool = cfg.get("tool")
        argv, removed = strip_endpoint(split_args(cfg.get("arguments")), tool)
        t = declared[idx]
        used = t
        if t is not None and cap:
            used = min(t, cap + (t - base))
            argv = with_test_time(argv, used)
        added = []
        if tool == "redis-benchmark" and "--csv" not in argv:
            argv = ["--csv"] + argv
            added.append("--csv")
        runs = memtier_run_count(argv) if tool == "memtier_benchmark" else 1
        clients.append({
            "tool": tool,
            "image": tool_image(tool, cfg, opts),
            "argv": argv,
            "cpus": cpusets[idx],
            "requested_cpus": requested_cpus(cfg),
            "timeout": used * runs + 120 if used is not None else opts.get("client_timeout", 1800),
            "declared_test_time": t,
            "test_time": used,
            "removed": removed,
            "added": added,
        })
    preload = None
    pre = db.get("preload_tool")
    if isinstance(pre, dict):
        tool = pre.get("tool")
        argv, removed = strip_endpoint(split_args(pre.get("arguments")), tool)
        union = sorted({c for s in cpusets for c in parse_cpus(s)})
        preload = {
            "tool": tool,
            "image": tool_image(tool, pre, opts),
            "argv": argv,
            "cpus": format_cpus(union),
            "timeout": declared_timeout(pre) or opts.get("preload_timeout", 3600),
            "removed": removed,
        }
    config = []
    params = db.get("configuration-parameters")
    if isinstance(params, dict):
        for k, v in params.items():
            if str(k) == "save":
                continue
            config.append([str(k), config_text(v)])
    measured = clients[-1]
    return {
        "suite": "spec",
        "name": entry["name"],
        "key": safe_key(entry["name"], taken),
        "display": entry["name"],
        "fresh_server": True,
        "flush_each_run": False,
        "runs": 1,
        "config": config,
        "preload": preload,
        "init_commands": init_command_lists(db),
        "init_lua": init_lua_scripts(db),
        "check": keyspace_check(db),
        "clients": clients,
        "required_commands": sorted((set(entry["tested"]) - set(entry["ignored"])) | set(entry["workload"])),
        "info": {
            "file": entry["file"],
            "tested_commands": entry["tested"],
            "ignored_tested_commands": entry["ignored"],
            "tested_groups": [str(g) for g in doc.get("tested-groups") or []],
            "priority": doc.get("priority"),
            "dataset_name": db.get("dataset_name"),
            "declared_test_time_s": measured["declared_test_time"],
            "test_time_s": measured["test_time"],
            "test_time_capped": measured["declared_test_time"] != measured["test_time"],
            "clients": len(clients),
        },
    }


def match_any(name, file, patterns):
    stem = Path(file).stem
    return any(fnmatch.fnmatchcase(name, p) or fnmatch.fnmatchcase(stem, p) for p in patterns)


def missing_groups(skipped):
    blocked = Counter()
    only = Counter()
    for s in skipped:
        miss = s.get("missing_commands") or []
        for c in miss:
            blocked[c] += 1
        if len(miss) == 1 and len(s.get("reasons") or []) == 1:
            only[miss[0]] += 1
    return blocked, only


def reason_kind(reason):
    if reason.startswith("eski lacks"):
        return "missing commands"
    if reason.startswith("runs only on"):
        return "topology"
    if reason.startswith("client tool") or reason.startswith("preload tool"):
        return "client tool"
    if reason.startswith("loads "):
        return "dataset"
    if reason.startswith("measures BGSAVE"):
        return "bgsave duration"
    if reason.startswith("could not parse"):
        return "parse failure"
    return "other"


def spec_plan(tree, probe, opts, reference=None):
    implemented = set(probe.get("implemented") or [])
    known = set(reference.get("implemented") or []) if reference and reference.get("method") else None
    entries = assess_tree(tree, implemented, known)
    patterns = [p for p in (opts.get("select") or []) if p]
    if patterns:
        unmatched = [p for p in patterns if not any(match_any(e["name"], e["file"], [p]) for e in entries)]
        if unmatched:
            raise SystemExit(f"spec.py: no specification case matches {', '.join(unmatched)}")
        chosen = [e for e in entries if match_any(e["name"], e["file"], patterns)]
    else:
        chosen = entries
    cores = parse_cpus(opts.get("client_cpus") or "0")
    taken = set()
    items = []
    skipped = []
    for e in chosen:
        if e["reasons"]:
            skipped.append({
                "name": e["name"],
                "file": e["file"],
                "reason": "; ".join(e["reasons"]),
                "reasons": e["reasons"],
                "missing_commands": e["missing"],
            })
            continue
        items.append(case_item(e, opts, cores, taken))
    blocked, only = missing_groups(skipped)
    ignored = Counter(c for e in chosen for c in e.get("ignored") or [])
    meta = {
        "release": opts.get("release"),
        "sha256": opts.get("sha256"),
        "url": opts.get("url"),
        "tree": str(tree),
        "case_files": len(entries),
        "parse_failures": [{"file": e["file"], "error": e["error"]} for e in entries if e["doc"] is None],
        "memtier_based": sum(1 for e in entries if e.get("memtier_based")),
        "applicable": sum(1 for e in entries if not e["reasons"]),
        "selection": patterns,
        "selected": len(chosen),
        "planned": len(items),
        "skipped": skipped,
        "skipped_by_missing_command": dict(sorted(blocked.items(), key=lambda kv: (-kv[1], kv[0]))),
        "only_blocker": dict(sorted(only.items(), key=lambda kv: (-kv[1], kv[0]))),
        "quick_test_time_cap_s": opts.get("quick_cap") or None,
        "applicability": (
            "a case runs when eski implements every command in tested-commands and every command its preload, init and client "
            "steps send; it then runs on every target. A tested-commands name the case never sends and the reference server "
            "does not know either is treated as a typo in the specification and ignored"
        ),
        "ignored_tested_commands": dict(sorted(ignored.items())),
        "reference": {k: (reference or {}).get(k) for k in ("method", "server")} if reference else None,
        "probe": {k: probe.get(k) for k in ("method", "server", "missing", "unprobed")},
    }
    return items, meta


def apply_probe(items, probe):
    implemented = set(probe.get("implemented") or [])
    for item in items:
        if item.get("applicability") != "per_target":
            continue
        missing = sorted(c for c in item.get("required_commands") or [] if c not in implemented)
        if missing and probe.get("method"):
            item.setdefault("skip_targets", {})["eski"] = "eski lacks " + ", ".join(missing)


def validate_item(item, where):
    for field in ("suite", "name", "key", "clients"):
        if field not in item:
            raise SystemExit(f"spec.py: {where} has no {field}")
    if not SAFE_KEY.match(item["key"]):
        raise SystemExit(f"spec.py: {where} key {item['key']!r} is not usable as a file name")
    if not item["clients"]:
        raise SystemExit(f"spec.py: {where} has no clients")
    for c in item["clients"]:
        if c.get("tool") not in CLIENT_TOOLS:
            raise SystemExit(f"spec.py: {where} uses unsupported tool {c.get('tool')}")


class RespError:
    def __init__(self, message):
        self.message = message

    def __repr__(self):
        return f"RespError({self.message!r})"


class Resp:
    def __init__(self, host, port, timeout):
        self.sock = socket.create_connection((host, int(port)), timeout=timeout)
        self.buf = bytearray()

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def call(self, *args):
        parts = [b"*%d\r\n" % len(args)]
        for a in args:
            b = a if isinstance(a, bytes) else str(a).encode("utf-8")
            parts.append(b"$%d\r\n%s\r\n" % (len(b), b))
        self.sock.sendall(b"".join(parts))
        return self.read()

    def fill(self):
        chunk = self.sock.recv(1 << 16)
        if not chunk:
            raise ConnectionError("connection closed by the server")
        self.buf += chunk

    def line(self):
        while True:
            i = self.buf.find(b"\r\n")
            if i >= 0:
                out = bytes(self.buf[:i])
                del self.buf[:i + 2]
                return out
            self.fill()

    def exact(self, n):
        while len(self.buf) < n:
            self.fill()
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

    def read(self):
        line = self.line()
        kind, rest = line[:1], line[1:]
        if kind == b"+":
            return rest.decode("utf-8", "replace")
        if kind == b"-":
            return RespError(rest.decode("utf-8", "replace"))
        if kind in (b":", b"("):
            return int(rest)
        if kind in (b"$", b"="):
            n = int(rest)
            if n < 0:
                return None
            return self.exact(n + 2)[:-2]
        if kind in (b"*", b"~", b">"):
            n = int(rest)
            if n < 0:
                return None
            return [self.read() for _ in range(n)]
        if kind == b"%":
            out = []
            for _ in range(int(rest)):
                out.append((self.read(), self.read()))
            return out
        if kind == b"_":
            return None
        if kind == b",":
            return float(rest)
        if kind == b"#":
            return rest == b"t"
        raise ConnectionError(f"unexpected RESP type {kind!r}")


def text_of(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    if isinstance(value, RespError):
        return "-" + value.message
    return str(value)


def wait_ready(host, port, seconds):
    deadline = time.monotonic() + seconds
    last = ""
    while time.monotonic() < deadline:
        try:
            conn = Resp(host, port, 2)
            try:
                if conn.call("PING") == "PONG":
                    return
            finally:
                conn.close()
        except OSError as e:
            last = str(e)
        time.sleep(0.1)
    raise SystemExit(f"spec.py: no PONG from {host}:{port} within {seconds}s ({last})")


def probe_one(host, port, argv, timeout):
    try:
        conn = Resp(host, port, timeout)
    except OSError as e:
        raise SystemExit(f"spec.py: the probe server stopped answering before {' '.join(argv)}: {e}")
    try:
        reply = conn.call(*argv)
    except socket.timeout:
        return True, "no reply within the probe timeout"
    except (ConnectionError, OSError) as e:
        return True, f"connection closed: {e}"
    finally:
        conn.close()
    if isinstance(reply, RespError):
        msg = reply.message
        if msg.startswith("ERR unknown command"):
            return False, msg
        if len(argv) > 1 and msg.startswith("ERR unknown subcommand '"):
            return False, msg
        return True, msg
    return True, text_of(reply)[:120] if not isinstance(reply, list) else f"array of {len(reply)}"


def server_name(host, port):
    try:
        conn = Resp(host, port, 5)
        info = text_of(conn.call("INFO", "server"))
        conn.close()
    except OSError:
        return None
    fields = dict(line.split(":", 1) for line in info.splitlines() if ":" in line)
    for k in ("eski_version", "valkey_version", "dragonfly_version", "redis_version"):
        if k in fields:
            return f"{k.split('_')[0]} {fields[k].strip()}"
    return None


def probe(host, port, names, timeout):
    listed = None
    conn = Resp(host, port, timeout)
    try:
        reply = conn.call("COMMAND", "LIST")
    finally:
        conn.close()
    if isinstance(reply, list) and reply:
        listed = {text_of(x).lower() for x in reply}
    implemented, missing, unprobed = [], [], []
    replies = {}
    for name in sorted(set(names)):
        top, _, sub = name.partition("|")
        if name in UNSAFE_PROBES or top in UNSAFE_PROBES:
            unprobed.append(name)
            continue
        if listed is not None and not sub:
            (implemented if name in listed else missing).append(name)
            continue
        if sub and (top in missing or (listed is not None and top not in listed)):
            missing.append(name)
            continue
        ok, detail = probe_one(host, port, [top.upper()] + ([sub.upper()] if sub else []), timeout)
        replies[name] = detail
        (implemented if ok else missing).append(name)
    return {
        "method": "command_list" if listed is not None else "probe",
        "method_detail": (
            "COMMAND LIST returned the command table"
            if listed is not None
            else "COMMAND LIST returned an empty array, so every command was sent bare (subcommands as CMD SUB) on a throwaway server; "
            "an 'ERR unknown command' or 'ERR unknown subcommand' reply marks it missing, any other reply marks it implemented"
        ),
        "server": server_name(host, port),
        "implemented": implemented,
        "missing": missing,
        "unprobed": unprobed,
        "replies": replies,
    }


def load_json(path, default=None):
    p = Path(path)
    if not p.is_file():
        return default
    return json.loads(p.read_text())


def write_json(path, data):
    p = Path(path)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(p)


def plan_items(plan):
    return plan.get("items") or []


def load_item(plan_path, index):
    plan = load_json(plan_path)
    if plan is None:
        raise SystemExit(f"spec.py: plan {plan_path} does not exist")
    items = plan_items(plan)
    if index < 0 or index >= len(items):
        raise SystemExit(f"spec.py: plan has no item {index}")
    return items[index]


def keyspace_size(conn):
    info = text_of(conn.call("INFO", "keyspace"))
    total = 0
    for m in re.finditer(r"^db\d+:keys=(\d+)", info, re.M):
        total += int(m.group(1))
    return total


def cmd_probe(a):
    names = set()
    if a.tree:
        names |= needed_commands(assess_tree(a.tree, set()))
    for extra in a.extra or []:
        for item in plan_items(load_json(extra, {})):
            names |= set(item.get("required_commands") or [])
    wait_ready(a.host, a.port, a.wait)
    result = probe(a.host, a.port, names, a.timeout)
    write_json(a.out, result)
    print(f"probed {len(names)} commands on {result.get('server') or 'the server'} by {result['method']}: "
          f"{len(result['implemented'])} implemented, {len(result['missing'])} missing, {len(result['unprobed'])} not probed")
    return 0


def cmd_plan(a):
    probe_data = load_json(a.probe, {}) if a.probe else {}
    reference = load_json(a.reference, {}) if a.reference else None
    items = []
    suites = {}
    opts = {
        "release": a.release,
        "sha256": a.sha256,
        "url": a.url,
        "select": [p.strip() for p in (a.select or "").split(",") if p.strip()],
        "quick_cap": a.quick_cap,
        "client_cpus": a.client_cpus,
        "memtier_image": a.memtier_image,
        "default_memtier_image": a.default_memtier_image,
        "rb_image": a.rb_image,
        "client_timeout": a.client_timeout,
        "preload_timeout": a.preload_timeout,
    }
    if a.tree:
        if not probe_data.get("method"):
            raise SystemExit("spec.py: specification cases need a probe of eski's commands (--probe)")
        spec_items, meta = spec_plan(a.tree, probe_data, opts, reference)
        items.extend(spec_items)
        suites["spec"] = meta
    for extra in a.extra or []:
        data = load_json(extra)
        if data is None:
            raise SystemExit(f"spec.py: plan {extra} does not exist")
        extra_items = plan_items(data)
        apply_probe(extra_items, probe_data)
        items.extend(extra_items)
        for name, meta in (data.get("suites") or {}).items():
            suites[name] = meta
    keys = set()
    for n, item in enumerate(items):
        validate_item(item, f"item {n}")
        if item["key"] in keys:
            raise SystemExit(f"spec.py: duplicate item key {item['key']}")
        keys.add(item["key"])
    if probe_data:
        for meta in suites.values():
            meta.setdefault("probe", {k: probe_data.get(k) for k in ("method", "server", "missing", "unprobed")})
    write_json(a.out, {"items": items, "suites": suites})
    return 0


def print_inventory(meta, applicable_names):
    print(f"specification {meta.get('release') or '?'}  {meta.get('tree')}")
    if meta.get("sha256"):
        print(f"sha256        {meta['sha256']}")
    probe_meta = meta.get("probe") or {}
    print(f"eski probe   {probe_meta.get('server') or '?'} via {probe_meta.get('method') or '?'}")
    ref = meta.get("reference") or {}
    if ref:
        print(f"reference     {ref.get('server') or '?'} via {ref.get('method') or '?'}")
    if meta.get("ignored_tested_commands"):
        print("ignored       " + ", ".join(f"{c} ({n} cases)" for c, n in meta["ignored_tested_commands"].items())
              + ": listed in tested-commands, never sent, unknown to the reference")
    print(f"case files    {meta['case_files']} (defaults.yml excluded), parse failures {len(meta['parse_failures'])}")
    for f in meta["parse_failures"]:
        print(f"  could not parse {f['file']}: {f['error']}")
    print(f"memtier based {meta['memtier_based']}")
    print(f"applicable    {meta['applicable']}")
    if meta.get("selection"):
        print(f"selected      {meta['selected']} by {', '.join(meta['selection'])}, planned {meta['planned']}")
    skipped = meta["skipped"]
    print(f"skipped       {len(skipped)}")
    kinds = Counter()
    for s in skipped:
        for r in s.get("reasons") or [s["reason"]]:
            kinds[reason_kind(r)] += 1
    print("  by reason (a case can have several): " + ", ".join(f"{k} {v}" for k, v in kinds.most_common()))
    print("  by missing command (cases blocked / cases where it is the only blocker):")
    only = meta.get("only_blocker") or {}
    for c, n in (meta.get("skipped_by_missing_command") or {}).items():
        print(f"    {c:<22} {n:>4} {only.get(c, 0):>4}")
    print()
    print("applicable cases:")
    for name in applicable_names:
        print(f"  {name}")
    print()
    print("skipped cases:")
    for s in sorted(skipped, key=lambda s: s["name"]):
        print(f"  {s['name']}: {s['reason']}")


def cmd_inventory(a):
    probe_data = load_json(a.probe, {})
    if not probe_data.get("method"):
        raise SystemExit("spec.py: inventory needs a probe file")
    reference = load_json(a.reference, {}) if a.reference else None
    opts = {"release": a.release, "sha256": a.sha256, "url": a.url, "client_cpus": "0", "select": []}
    items, meta = spec_plan(a.tree, probe_data, opts, reference)
    print_inventory(meta, [i["name"] for i in items])
    if a.json:
        write_json(a.json, {"items": items, "suites": {"spec": meta}})
    return 0


def target_skip(item, target, target_probe):
    explicit = (item.get("skip_targets") or {}).get(target)
    if explicit:
        return explicit
    if not target_probe.get("method"):
        return ""
    absent = set(target_probe.get("missing") or []) | set(target_probe.get("unprobed") or [])
    missing = sorted(c for c in item.get("required_commands") or [] if c in absent)
    if missing:
        return f"{target} lacks " + ", ".join(missing)
    return ""


def cmd_describe(a):
    plan = load_json(a.plan, {})
    items = plan_items(plan)
    parts = []
    by_suite = Counter(i["suite"] for i in items)
    spec = (plan.get("suites") or {}).get("spec")
    if spec is not None:
        cap = spec.get("quick_test_time_cap_s")
        planned = by_suite.get("spec", 0)
        text = f"specification {spec.get('release')}: {planned} case{'' if planned == 1 else 's'} planned, {len(spec.get('skipped') or [])} skipped"
        if spec.get("selection"):
            text += f" (selection {', '.join(spec['selection'])})"
        if cap:
            text += f", test time capped at {cap} s"
        declared = sum((i["info"].get("test_time_s") or 0) for i in items if i["suite"] == "spec")
        span = f"{declared / 3600:.1f} h" if declared >= 3600 else f"{declared / 60:.0f} min"
        text += f", {span} of client test time per target before preloads"
        parts.append(text)
    for suite, n in sorted(by_suite.items()):
        if suite != "spec":
            parts.append(f"{suite}: {n} items")
    print("; ".join(parts) if parts else "empty plan")
    return 0


def cmd_shell(a):
    q = shlex.quote
    plan = load_json(a.plan)
    items = plan_items(plan)
    if a.summary:
        images = sorted({c.get("image") for i in items for c in i["clients"] if c.get("image")} |
                        {(i.get("preload") or {}).get("image") for i in items if (i.get("preload") or {}).get("image")})
        print(f"PLAN_COUNT={len(items)}")
        print("PLAN_IMAGES=(" + " ".join(q(x) for x in images) + ")")
        return 0
    item = load_item(a.plan, a.index)
    lines = []

    def scalar(name, value):
        lines.append(f"local {name}={q(str(value))}")

    def array(name, values):
        lines.append(f"local -a {name}=(" + " ".join(q(str(v)) for v in values) + ")")

    scalar("IT_NAME", item["name"])
    scalar("IT_KEY", item["key"])
    scalar("IT_SUITE", item["suite"])
    scalar("IT_FRESH", 1 if item.get("fresh_server") else 0)
    scalar("IT_RUNS", int(item.get("runs") or 1))
    scalar("IT_FLUSH_EACH_RUN", 1 if item.get("flush_each_run") else 0)
    scalar("IT_SKIP", target_skip(item, a.target, load_json(a.target_probe, {}) if a.target_probe else {}))
    has_setup = item.get("config") or item.get("init_commands") or item.get("init_lua") or item.get("check")
    scalar("IT_SETUP", 1 if has_setup else 0)
    array("IT_SERVER_ARGS", (item.get("server_args") or {}).get(a.target, []))
    pre = item.get("preload") or {}
    scalar("IT_PRELOAD_TOOL", pre.get("tool", ""))
    scalar("IT_PRELOAD_IMAGE", pre.get("image", ""))
    scalar("IT_PRELOAD_CPUS", pre.get("cpus", ""))
    scalar("IT_PRELOAD_TIMEOUT", pre.get("timeout", ""))
    array("IT_PRELOAD_ARGV", pre.get("argv", []))
    clients = item["clients"]
    scalar("IT_CLIENTS", len(clients))
    array("IT_CLIENT_TOOL", [c["tool"] for c in clients])
    array("IT_CLIENT_IMAGE", [c.get("image", "") for c in clients])
    array("IT_CLIENT_CPUS", [c.get("cpus", "") for c in clients])
    array("IT_CLIENT_TIMEOUT", [c.get("timeout", "") for c in clients])
    for k, c in enumerate(clients):
        array(f"IT_CLIENT_ARGV_{k}", c["argv"])
    print("\n".join(lines))
    return 0


def cmd_configure(a):
    item = load_item(a.plan, a.index)
    out = {}
    applied, rejected = {}, {}
    if item.get("config"):
        conn = Resp(a.host, a.port, 30)
        try:
            for k, v in item["config"]:
                reply = conn.call("CONFIG", "SET", k, v)
                if isinstance(reply, RespError):
                    rejected[k] = reply.message
                else:
                    applied[k] = v
        finally:
            conn.close()
    out["config_applied"] = applied
    out["config_rejected"] = rejected
    write_json(a.out, out)
    return 0


def cmd_seed(a):
    item = load_item(a.plan, a.index)
    out = load_json(a.out, {})
    conn = Resp(a.host, a.port, a.timeout)
    failure = None
    try:
        errors = []
        sent = 0
        for argv in item.get("init_commands") or []:
            reply = conn.call(*argv)
            sent += 1
            if isinstance(reply, RespError):
                errors.append({"command": " ".join(argv)[:200], "error": reply.message})
                if a.target in ("redis", "valkey") and failure is None:
                    failure = f"init command {' '.join(argv)[:80]} failed: {reply.message}"
        lua_errors = []
        for script in item.get("init_lua") or []:
            reply = conn.call("EVAL", script, "0")
            if isinstance(reply, RespError):
                lua_errors.append(reply.message)
        if sent or item.get("init_lua"):
            out["init"] = {"commands": sent, "errors": errors, "lua_scripts": len(item.get("init_lua") or []), "lua_errors": lua_errors}
        check = item.get("check")
        if check and failure is None:
            start = time.monotonic()
            attempt = 0
            found = keyspace_size(conn)
            while True:
                ok = ("keyspacelen" in check and found == check["keyspacelen"]) or (
                    "keyspacelen_min" in check and found >= check["keyspacelen_min"])
                if ok or time.monotonic() - start >= a.check_timeout:
                    break
                time.sleep(min(2 ** attempt, max(0.0, a.check_timeout - (time.monotonic() - start))))
                attempt += 1
                found = keyspace_size(conn)
            out["keyspace"] = dict(check, found=found, ok=ok, seconds=round(time.monotonic() - start, 1))
            if not ok:
                want = check.get("keyspacelen", check.get("keyspacelen_min"))
                op = "exactly" if "keyspacelen" in check else "at least"
                failure = f"keyspace check failed: expected {op} {want} keys after the preload, found {found}"
    finally:
        conn.close()
    write_json(a.out, out)
    if failure:
        print(failure)
        return 1
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Plan and prepare the Redis benchmarks specification cases for bench/run.sh.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("probe")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--tree")
    p.add_argument("--extra", action="append")
    p.add_argument("--out", required=True)
    p.add_argument("--wait", type=float, default=15)
    p.add_argument("--timeout", type=float, default=2)
    p.set_defaults(func=cmd_probe)

    p = sub.add_parser("plan")
    p.add_argument("--probe")
    p.add_argument("--reference")
    p.add_argument("--tree")
    p.add_argument("--extra", action="append")
    p.add_argument("--out", required=True)
    p.add_argument("--release")
    p.add_argument("--sha256")
    p.add_argument("--url")
    p.add_argument("--select", default="")
    p.add_argument("--quick-cap", type=int, default=0)
    p.add_argument("--client-cpus", default="0")
    p.add_argument("--memtier-image", default="")
    p.add_argument("--default-memtier-image", default="")
    p.add_argument("--rb-image", default="")
    p.add_argument("--client-timeout", type=int, default=1800)
    p.add_argument("--preload-timeout", type=int, default=3600)
    p.set_defaults(func=cmd_plan)

    p = sub.add_parser("inventory")
    p.add_argument("--tree", required=True)
    p.add_argument("--probe", required=True)
    p.add_argument("--reference")
    p.add_argument("--release")
    p.add_argument("--sha256")
    p.add_argument("--url")
    p.add_argument("--json")
    p.set_defaults(func=cmd_inventory)

    p = sub.add_parser("shell")
    p.add_argument("--plan", required=True)
    p.add_argument("--index", type=int, default=-1)
    p.add_argument("--target", default="")
    p.add_argument("--target-probe")
    p.add_argument("--summary", action="store_true")
    p.set_defaults(func=cmd_shell)

    p = sub.add_parser("describe")
    p.add_argument("--plan", required=True)
    p.set_defaults(func=cmd_describe)

    for name, func in (("configure", cmd_configure), ("seed", cmd_seed)):
        p = sub.add_parser(name)
        p.add_argument("--plan", required=True)
        p.add_argument("--index", type=int, required=True)
        p.add_argument("--target", required=True)
        p.add_argument("--host", default="127.0.0.1")
        p.add_argument("--port", type=int, required=True)
        p.add_argument("--out", required=True)
        p.add_argument("--timeout", type=float, default=600)
        p.add_argument("--check-timeout", type=float, default=60)
        p.set_defaults(func=func)

    a = ap.parse_args(argv)
    try:
        return a.func(a)
    except (OSError, ConnectionError) as e:
        print(f"spec.py {a.cmd}: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
