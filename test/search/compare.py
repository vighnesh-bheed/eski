import argparse
import codecs
from collections import Counter, defaultdict
from contextlib import ExitStack, contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.append(str(HERE.parent / "vectorset"))
import fixtures

spec = importlib.util.spec_from_file_location("vector_wire", HERE.parent / "vectorset/compare.py")
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)

IMAGE = "docker.io/library/redis@sha256:f245f4c83b84a9e9a0588da1c9456e579455310f0945d5db52cd2ba27f2000cc"
COMMANDS = set(b"""
PING INFO MODULE COMMAND ACL CONFIG CLIENT SELECT FLUSHALL FLUSHDB EXISTS SET GET DEL HSET HDEL HGET
HPEXPIRE PEXPIRE RENAME COPY MULTI EXEC DISCARD EVAL JSON.GET JSON.SET JSON.DEL JSON.NUMINCRBY
FT.CREATE FT.SEARCH FT.AGGREGATE FT.HYBRID FT.INFO FT.DROPINDEX FT._LIST FT.EXPLAIN FT.EXPLAINCLI
FT.ALTER FT.PROFILE FT.TAGVALS FT.CURSOR FT.CONFIG FT.ALIASADD FT.ALIASDEL FT.ALIASUPDATE FT.DROP
FT._DROPINDEXIFX FT._CREATEIFNX FT.SUGLEN _FT.DEBUG
""".split())
SCRIPT_DIGESTS = {
    "6b78a00a0461380107f58226dea210833134b9e9af97c96678a14d764e76cc81",
    "b33d2bca097338ebe44b330e1adb18bc5d2aa24cf06f4ade6299046986dd8201",
    "9b7586dd616f50fbbda3dbfe92467e9d0a0dccc484cea78af1dc13f004f758f4",
    "419ade8d1975ac61d6fa59cd0c5c0c2fcf73c70ee72eea99f7e2430a2ebe3ba4",
}
INFO_SCRIPT_DIGESTS = {"b33d2bca097338ebe44b330e1adb18bc5d2aa24cf06f4ade6299046986dd8201"}
RESTRICTED = {
    b"ACL": {b"CAT"}, b"CONFIG": {b"GET"}, b"MODULE": {b"LIST"},
    b"CLIENT": {b"SETINFO", b"MAINT_NOTIFICATIONS"},
    b"FT.CONFIG": {b"GET", b"HELP"}, b"_FT.DEBUG": {b"DUMP_TERMS"},
}
QUERY_COMMANDS = {b"FT.SEARCH", b"FT.AGGREGATE", b"FT.HYBRID", b"FT.EXPLAIN", b"FT.EXPLAINCLI", b"FT.PROFILE"}
BOUNDED_OPTIONS = rb"\b(?:LIMIT|COUNT|KNN|K|WINDOW|MAX)\s+([+-]?[0-9]+(?:\.[0-9]+)?|\$[A-Za-z_][A-Za-z_0-9]*)(?:\s+([+-]?[0-9]+(?:\.[0-9]+)?))?"
NORMALIZATIONS = {
    "index-list-order": "FT._LIST returns an unordered inventory. The element types and every name must match.",
    "module-descriptors": "MODULE LIST includes different modules. Search and ReJSON names and versions must match.",
    "cursor-id": "Cursor ids are allocated independently. The cursor field, lifecycle and rows must match.",
    "hybrid-execution-time": "FT.HYBRID execution_time measures the current execution. All result rows and scores must match.",
    "projection-field-order": "Search projections are field dictionaries. The projected fields, wire types and result order must match.",
    "json-path-order": "JSON.GET with several paths returns an unordered path object. Each path and its exact JSON value must match.",
    "indexing-time": "FT.INFO total_indexing_time measures current indexing work. Counts, index schema and indexing state must match.",
}
KINDS = {
    b"+": "status", b"-": "error", b":": "integer", b"$": "bulk", b"*": "array", b"_": "null",
    b"#": "boolean", b",": "double", b"(": "bignum", b"!": "blob_error", b"=": "verbatim",
    b"%": "map", b"~": "set", b">": "push",
}


def as_bytes(value):
    if isinstance(value, bytes):
        return value
    if isinstance(value, (str, int)):
        return str(value).encode()
    raise TypeError("fixture arguments must be bytes, strings or integers")


def digest(value):
    return hashlib.sha256(value).hexdigest()


def guard(argv):
    if not argv or len(argv) > 1024 or sum(map(len, argv)) > 1_048_576:
        raise ValueError("fixture command exceeds argument limits")
    command = argv[0].upper()
    if command not in COMMANDS:
        raise ValueError("fixture command is outside the replay allowlist: %s" % wire.esc(command[:80]))
    if command in RESTRICTED and len(argv) >= 2 and argv[1].upper() not in RESTRICTED[command]:
        raise ValueError("fixture subcommand is outside the replay allowlist")
    if command == b"EVAL" and (len(argv) < 3 or digest(argv[1]) not in SCRIPT_DIGESTS or argv[2] != b"0"):
        raise ValueError("fixture script is outside the replay allowlist")
    if command not in QUERY_COMMANDS | {b"FT.CURSOR", b"FT.CREATE", b"FT._CREATEIFNX"}:
        return
    upper = [arg.upper() for arg in argv]
    params = {}
    for i, token in enumerate(upper[:-1]):
        if token == b"PARAMS" and argv[i + 1].isdigit():
            end = i + 2 + min(len(argv), int(argv[i + 1][:10]))
            params.update(zip(argv[i + 2:end:2], argv[i + 3:end:2]))
    if any(re.search(rb"\{\s*;", arg) for arg in argv):
        raise ValueError("fixture contains a blocked query attribute list")
    for match in re.finditer(BOUNDED_OPTIONS, b" ".join(argv), re.I):
        for token in filter(None, match.groups()):
            if token.startswith(b"$"):
                token = params.get(token[1:], b"")
            if re.fullmatch(rb"[+-]?[0-9]+(?:\.[0-9]+)?", token) and abs(float(token)) > 1000:
                raise ValueError("fixture query limit exceeds 1,000")


def capture_value(node):
    kind = KINDS[node.kind]
    value = node.value
    if node.kind == b"_":
        return {"type": "null"}
    if value is None:
        return {"type": "null_" + kind}
    if node.kind == b"%":
        value = [[capture_value(key), capture_value(item)] for key, item in zip(value[::2], value[1::2])]
    elif node.kind in (b"*", b"~", b">"):
        value = [capture_value(child) for child in value]
    elif node.kind == b":":
        value = int(value)
    elif node.kind == b"#":
        value = value == b"t"
    elif node.kind != b"$":
        value = value.decode()
    return {"type": kind, "value": value}


def children(node, *kinds):
    if node.kind not in kinds or node.value is None:
        return None
    return node.value


def fields(node):
    items = children(node, b"*", b"%")
    if items is None or len(items) % 2 or any(wire.text(key) is None for key in items[::2]):
        return None
    pairs = {wire.text(key): value for key, value in zip(items[::2], items[1::2])}
    return pairs if len(pairs) * 2 == len(items) else None


def cursor_field(node):
    items = children(node, b"*")
    if items is not None and len(items) == 2 and items[1].kind == b":" and int(items[1].value) >= 0:
        return items[1]
    return None


def array(kind, items):
    count = len(items) // 2 if kind == b"%" else len(items)
    return kind + b"%d\r\n" % count + b"".join(items)


def mask_numeric(node):
    value = wire.text(node)
    if value is None or not re.fullmatch(rb"[0-9]+(?:\.[0-9]+)?(?:e[+-]?[0-9]+)?", value, re.I):
        return node.raw
    if node.kind in (b":", b","):
        return node.kind + b"0\r\n"
    if node.kind == b"$":
        return b"$1\r\n0\r\n"
    return node.raw


def rewrite(node, replacements):
    if node.kind not in (b"*", b"%") or not node.raw.startswith(node.kind):
        return node.raw
    items = [replacements.get(id(item), item.raw) for item in node.value]
    return array(node.kind, items)


def sort_pairs(node):
    if fields(node) is None or not node.raw.startswith(node.kind):
        return node.raw
    pairs = sorted(key.raw + value.raw for key, value in zip(node.value[::2], node.value[1::2]))
    return node.head + b"\r\n" + b"".join(pairs)


def search_projection(node):
    if node.kind == b"%":
        root = fields(node)
        if not root or b"results" not in root:
            return node.raw
        hits = root[b"results"]
        if children(hits, b"*") is None:
            return node.raw
        rows = {}
        for hit in hits.value:
            values = fields(hit)
            if values is None or b"extra_attributes" not in values:
                return node.raw
            projection = values[b"extra_attributes"]
            rows[id(hit)] = rewrite(hit, {id(projection): sort_pairs(projection)})
        return rewrite(node, {id(hits): rewrite(hits, rows)})
    items = children(node, b"*")
    if items and items[0].kind == b":" and len(items) % 2 == 1 and all(
        item.kind == b"$" and item.value is not None for item in items[1::2]
    ) and all(fields(item) is not None for item in items[2::2]):
        return rewrite(node, {id(item): sort_pairs(item) for item in items[2::2]})
    return node.raw


def json_path_object(node):
    if node.kind != b"$" or node.value is None or not node.value.startswith(b"{") or not node.value.endswith(b"}"):
        return node.raw
    text = node.value.decode("utf-8")
    decoder = json.JSONDecoder()
    position = 1
    spans = {}
    try:
        while position < len(text) - 1:
            key, colon = decoder.raw_decode(text, position)
            if not isinstance(key, str) or key in spans or text[colon:colon + 1] != ":":
                return node.raw
            _, end = decoder.raw_decode(text, colon + 1)
            spans[key] = text[position:end]
            if text[end:end + 1] == "}":
                break
            if text[end:end + 1] != ",":
                return node.raw
            position = end + 1
        else:
            return node.raw
    except ValueError:
        return node.raw
    if end != len(text) - 1:
        return node.raw
    value = ("{" + ",".join(spans[key] for key in sorted(spans)) + "}").encode()
    return b"$%d\r\n%s\r\n" % (len(value), value)


def timing_field(node, label):
    data = fields(node)
    if data is None or label not in data:
        return node.raw
    item = data[label]
    return rewrite(node, {id(item): mask_numeric(item)})



def normalize(argv, node):
    upper = [value.upper() for value in argv]
    command = upper[0]
    if command == b"FT._LIST":
        items = children(node, b"*", b"~")
        if items is not None and all(wire.text(item) is not None for item in items):
            return array(node.kind, sorted(item.raw for item in items)), "index-list-order"
    if upper[:2] == [b"MODULE", b"LIST"]:
        items = children(node, b"*")
        selected = []
        if items is not None:
            for item in items:
                data = fields(item)
                if data is None or b"name" not in data or b"ver" not in data:
                    break
                if wire.text(data[b"name"]) in (b"search", b"ReJSON"):
                    selected.append(array(item.kind, [b"$4\r\nname\r\n", data[b"name"].raw,
                                                       b"$3\r\nver\r\n", data[b"ver"].raw]))
            else:
                return array(node.kind, sorted(selected)), "module-descriptors"
    cursor_command = command == b"FT.AGGREGATE" and b"WITHCURSOR" in upper or upper[:2] == [b"FT.CURSOR", b"READ"]
    if cursor_command and (cursor := cursor_field(node)) is not None:
        if int(cursor.value):
            return array(node.kind, [node.value[0].raw, b":1\r\n"]), "cursor-id"
    if command == b"FT.HYBRID":
        return timing_field(node, b"execution_time"), "hybrid-execution-time"
    if command == b"EXEC" and children(node, b"*") is not None:
        timings = {id(item): timing_field(item, b"execution_time") for item in node.value
                   if (fields(item) or {}).keys() >= {b"results", b"total_results", b"execution_time"}}
        if timings:
            return rewrite(node, timings), "hybrid-execution-time"
    if command == b"FT.INFO" or command == b"EVAL" and len(argv) > 1 and digest(argv[1]) in INFO_SCRIPT_DIGESTS:
        return timing_field(node, b"total_indexing_time"), "indexing-time"
    if command == b"FT.SEARCH" and b"RETURN" in upper and not set(upper) & {b"WITHSCORES", b"WITHPAYLOADS", b"WITHSORTKEYS"}:
        return search_projection(node), "projection-field-order"
    if command == b"JSON.GET" and len(argv) > 3 and all(arg.startswith(b"$") for arg in argv[2:]):
        return json_path_object(node), "json-path-order"
    return node.raw, None


def describe(raw):
    return {"bytes": len(raw), "sha256": digest(raw), "wire": wire.esc(raw[:2048])}


def recorded_reply(raw):
    connection = object.__new__(wire.Conn)
    connection.buf = bytearray(codecs.escape_decode(raw.encode())[0])
    connection.pos = 0

    def truncated():
        raise ValueError("recorded reply is incomplete")

    connection.fill = truncated
    reply = connection.node()
    if connection.pos != len(connection.buf):
        raise ValueError("recorded reply has trailing bytes")
    return reply


def load_expected(path):
    entries = {}
    data = json.loads(path.read_text())
    categories = set()
    for group in data["categories"]:
        category, reason = group["id"], group["reason"]
        if not category or not reason or category in categories:
            raise ValueError("expected difference categories need distinct ids and reasons")
        categories.add(category)
        for case_id, pair in group["cases"].items():
            if (case_id in entries or not re.fullmatch(r"(?:capture|smoke)/resp[23]/[^/]+", case_id)
                or set(pair) != {"eski", "redis"} or pair["eski"] == pair["redis"]):
                raise ValueError("duplicate or invalid expected case %s" % case_id)
            if any(not re.fullmatch(r"[a-f0-9]{64}", value) for value in pair.values()):
                raise ValueError("expected case %s needs two SHA-256 digests" % case_id)
            entries[case_id] = (category, reason, pair)
    return entries


class Comparison:
    def __init__(self, report, expected, require_expected):
        self.report = report
        self.expected = expected
        self.require_expected = require_expected
        self.seen = set()
        self.sections = defaultdict(Counter)
        self.normalizations = Counter()

    def result(self, section, case_id, argv, eski, redis, observed=None):
        if case_id in self.seen:
            raise ValueError("fixture repeated case id %s" % case_id)
        self.seen.add(case_id)
        actual, actual_rule = normalize(argv, eski)
        reference, reference_rule = normalize(argv, redis)
        for rule in set((actual_rule, reference_rule)) - {None}:
            self.normalizations[rule] += 1
        expected = self.expected.get(case_id)
        same = actual == reference
        status = "passed"
        if expected:
            hashes = {"eski": digest(actual), "redis": digest(reference)}
            status = "stale" if same else "listed" if hashes == expected[2] else "unexpected"
        elif not same:
            status = "unexpected"
        self.sections[section][status] += 1
        if eski.raw == redis.raw:
            self.report["exact"] += 1
        if observed is not None:
            key = "observed_exact" if wire.esc(redis.raw) == observed else "observed_changed"
            self.report[key] += 1
        row = {"section": section, "id": case_id, "status": status, "command": wire.esc(argv[0])}
        if expected:
            row.update(category=expected[0], reason=expected[1])
        if status != "passed" or observed is not None and key == "observed_changed":
            row.update(eski=describe(actual), redis=describe(reference),
                       argv=[wire.esc(arg[:160]) for arg in argv])
            if observed is not None and key == "observed_changed":
                row["recorded_redis"] = observed[:2048]
                try:
                    historical, historical_rule = normalize(argv, recorded_reply(observed))
                    row["observed_reason"] = ((reference_rule or historical_rule or "wire representation")
                                              if historical == reference else "unclassified")
                except (ValueError, wire.ServerGone):
                    row["observed_reason"] = "historical reply could not be parsed"
        if actual_rule or reference_rule:
            row["normalizations"] = sorted(set((actual_rule, reference_rule)) - {None})
        self.report["cases"].append(row)

    def finish(self):
        self.report["sections"] = {name: dict(counts) for name, counts in self.sections.items()}
        self.report["normalizations"] = dict(self.normalizations)
        missing = sorted(self.expected.keys() - self.seen) if self.require_expected else []
        self.report["missing_expected"] = missing
        for name, counts in self.sections.items():
            print(name, ", ".join("%s %s" % (counts[k], k) for k in ("passed", "listed", "unexpected", "stale")))
        return bool(missing or not self.seen or any(c["unexpected"] or c["stale"] for c in self.sections.values()))


class Connection:
    def __init__(self, replay, protocol):
        self.replay = replay
        self.proto = protocol
        self.aliases = {}
        self.ends = []
        for port in replay.ports:
            conn = wire.Conn(port, 2, 5)
            replay.stack.callback(conn.close)
            if protocol == 3 and conn.call([b"HELLO", b"3"]).kind != b"%":
                raise ValueError("server refused RESP3")
            self.ends.append(conn)

    def validate(self, argv):
        if self.replay.remaining <= 0:
            raise ValueError("fixture exceeded the command budget")
        self.replay.remaining -= 1
        argv = list(map(as_bytes, argv))
        guard(argv)
        return argv

    def send(self, argv):
        argv = self.validate(argv)
        candidate = argv
        if argv[:1] == [b"FT.CURSOR"] and len(argv) >= 4:
            if replacement := self.aliases.get((argv[2], argv[3])):
                candidate = argv[:3] + [replacement] + argv[4:]
        redis = self.ends[1].call(argv)
        eski = self.ends[0].call(candidate)
        if (argv[0] == b"FT.AGGREGATE" and b"WITHCURSOR" in argv or argv[:2] == [b"FT.CURSOR", b"READ"]):
            ref_cursor, actual_cursor = cursor_field(redis), cursor_field(eski)
            if ref_cursor is not None and actual_cursor is not None and int(ref_cursor.value) and int(actual_cursor.value):
                key = argv[1] if argv[0] == b"FT.AGGREGATE" else argv[2]
                self.aliases[(key, ref_cursor.value)] = actual_cursor.value
        return argv, eski, redis

    def case(self, section, case_id, *argv, observed=None):
        argv, eski, redis = self.send(argv)
        self.replay.comparison.result(section, "%s/resp%s/%s" % (self.replay.fixture, self.proto, case_id),
                                      argv, eski, redis, observed)
        result = cursor_field(redis)
        return result.value if result is not None else None

    def cmd(self, *argv):
        _, _, redis = self.send(argv)
        return capture_value(redis), redis.raw

    def pipeline(self, commands):
        commands = [self.validate(command) for command in commands]
        if len(commands) > 200 or any(command[0].upper() != b"HSET" for command in commands):
            raise ValueError("capture setup pipelines must contain at most 200 HSET commands")
        reference = self.ends[1].pipeline(commands)
        candidate = self.ends[0].pipeline(commands)
        if [node.raw for node in candidate] != [node.raw for node in reference]:
            raise ValueError("a capture setup pipeline produced different HSET replies")
        return [capture_value(node) for node in reference]


class Replay:
    def __init__(self, ports, comparison, fixture, stack):
        self.ports = ports
        self.comparison = comparison
        self.fixture = fixture
        self.stack = stack
        self.remaining = 20000
        self.connections = {}

    def connection(self, protocol):
        if protocol not in self.connections:
            self.connections[protocol] = Connection(self, protocol)
        return self.connections[protocol]

    def reset(self):
        conns = self.connection(2).ends
        for conn in conns:
            if conn.call([b"SELECT", b"0"]).raw != b"+OK\r\n":
                raise ValueError("could not reset the database selection")
            if conn.call([b"FLUSHALL", b"SYNC"]).raw != b"+OK\r\n":
                raise ValueError("could not clear the disposable database")
            indexes = children(conn.call([b"FT._LIST"]), b"*", b"~")
            if indexes is None:
                raise ValueError("could not list indexes on the disposable database")
            for name in indexes:
                if not wire.text(name) or conn.call([b"FT.DROPINDEX", wire.text(name)]).raw != b"+OK\r\n":
                    raise ValueError("could not clear an index on the disposable database")
        for connection in self.connections.values():
            connection.aliases.clear()

    def wait_indexed(self, index, require_candidate=True):
        end = time.monotonic() + 10
        pending = list(self.connection(2).ends)
        while pending and time.monotonic() < end:
            for conn in list(pending):
                result = fields(conn.call([b"FT.INFO", as_bytes(index)]))
                if result is not None and wire.text(result.get(b"indexing")) == b"0" and wire.text(result.get(b"percent_indexed")) == b"1":
                    pending.remove(conn)
                elif result is None and not require_candidate and conn is self.connection(2).ends[0]:
                    pending.remove(conn)
            if pending:
                time.sleep(0.02)
        if pending:
            raise ValueError("index %s did not finish its initial scan" % index)


def private_capture(replay, source, observed_path, selected):
    catalog = json.loads(observed_path.read_text())["cases"]
    by_section = defaultdict(list)
    for i, row in enumerate(catalog, 1):
        if row["id"] != i or row["proto"] not in (2, 3) or not row["argv"]:
            raise ValueError("invalid recorded case at position %d" % i)
        by_section[row["section"]].append(row)
    spec = importlib.util.spec_from_file_location("search_capture_fixture", source)
    if spec is None or spec.loader is None:
        raise ValueError("the capture must be readable as a Python module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    chosen = selected or module.SECTIONS
    if len(set(chosen)) != len(chosen) or set(chosen) - set(module.SECTIONS):
        raise ValueError("capture sections are %s" % ", ".join(module.SECTIONS))
    if {"aggregate", "hybrid_variants"} & set(chosen) and "variants" not in chosen:
        raise ValueError("aggregate and hybrid_variants require the variants section")
    chosen = [name for name in module.SECTIONS if name in chosen]
    module.Conn = replay.connection
    positions = Counter()

    class Capture(module.Capture):
        def flush(self):
            replay.reset()

        def wait_indexed(self, index, limit=10.0):
            replay.wait_indexed(index, require_candidate=False)

        def rec(self, argv, note="", proto=2, nondeterministic=False, conn=None, command=None):
            args = list(map(as_bytes, argv))
            observed = by_section[self.section]
            position = positions[self.section]
            if position >= len(observed):
                raise ValueError("more live cases than recorded in %s" % self.section)
            recorded = observed[position]
            positions[self.section] += 1
            shown = [wire.esc(arg) for arg in args]
            previous = recorded["argv"]
            if args[:2] in ([b"FT.CURSOR", b"READ"], [b"FT.CURSOR", b"DEL"]) and len(args) >= 4:
                connection = conn or self.conns[proto]
                if (args[2], args[3]) in connection.aliases and len(previous) >= 4:
                    shown[3] = previous[3]
            if recorded["proto"] != proto or shown != previous:
                raise ValueError("live capture diverged from recorded argv or protocol at case %s" % recorded["id"])
            args, eski, redis = (conn or self.conns[proto]).send(args)
            replay.comparison.result(self.section, "capture/resp%s/%s" % (proto, recorded["id"]),
                                     args, eski, redis, recorded["raw"])
            return capture_value(redis)

    capture = Capture()
    for name in chosen:
        getattr(module, "sec_" + name)(capture)
    if not positions:
        raise ValueError("no captured cases replayed")
    for section in positions:
        if positions[section] != len(by_section[section]):
            raise ValueError("fewer live cases than recorded in %s" % section)
    if not selected and len(replay.comparison.seen) != len(catalog):
        raise ValueError("the full capture did not replay its recorded catalog")


def free_port(port):
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("127.0.0.1", port))


def stop_process(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def wait_server(port, process=None):
    until = time.monotonic() + 15
    while time.monotonic() < until:
        if process is not None and process.poll() is not None:
            raise ValueError("Eski exited before answering PING")
        try:
            conn = wire.Conn(port, 2, 1)
            try:
                if conn.call([b"PING"]).raw == b"+PONG\r\n":
                    return
            finally:
                conn.close()
        except (OSError, wire.ServerGone):
            pass
        time.sleep(0.05)
    raise ValueError("server did not answer PING on loopback port %s" % port)


def verify_reference(port):
    conn = wire.Conn(port, 2, 5)
    try:
        info = conn.call([b"INFO", b"server"])
        if info.kind != b"$" or b"redis_version:8.10.3" not in info.value.splitlines():
            raise ValueError("the reference must be Redis 8.10.3")
        reply = conn.call([b"MODULE", b"LIST"])
        modules = children(reply, b"*")
        versions = {}
        for module in modules or []:
            entries = fields(module)
            if entries is None or b"name" not in entries or b"ver" not in entries:
                raise ValueError("reference returned invalid module metadata")
            versions[wire.text(entries[b"name"])] = entries[b"ver"].raw
        if versions.get(b"search") != b":81001\r\n" or versions.get(b"ReJSON") != b":81000\r\n":
            raise ValueError("reference Search and JSON module versions do not match the pinned image")
    finally:
        conn.close()


def remove_reference(id_file, log, timeout=10):
    if id_file.is_file():
        container = id_file.read_text().strip()
        if re.fullmatch(r"[a-f0-9]{64}", container):
            try:
                with log.open("wb") as output:
                    subprocess.run(["docker", "logs", container], stdout=output, stderr=subprocess.STDOUT, timeout=5)
            finally:
                subprocess.run(["docker", "rm", "-f", container], stdout=subprocess.DEVNULL, check=True, timeout=timeout)


@contextmanager
def reference_server(port, folder, cpus=None, cleanup_timeout=10):
    folder.mkdir()
    id_file = folder / "container.id"
    affinity = ["--cpuset-cpus", cpus] if cpus else []
    try:
        free_port(port)
        with (folder / "startup.log").open("wb") as log:
            subprocess.run(["docker", "run", "--pull=never", "-d", "--name", "eski-search-%s-%s" % (port, os.getpid()),
                            "--cidfile", id_file, "--network", "host", "--memory", "2g", "--memory-swap", "2g", *affinity,
                            "--tmpfs", "/data:rw,size=128m", IMAGE, "redis-server", "--port", str(port),
                            "--bind", "127.0.0.1", "--protected-mode", "yes", "--dir", "/data", "--save", "",
                            "--appendonly", "no", "--maxmemory", "1gb",
                            "--client-output-buffer-limit", "normal 64mb 32mb 60"],
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
        wait_server(port)
        verify_reference(port)
        yield
    finally:
        remove_reference(id_file, folder / "server.log", timeout=cleanup_timeout)


@contextmanager
def eski_server(port, folder, binary):
    folder.mkdir()
    with (folder / "server.log").open("wb") as log:
        process = None
        try:
            free_port(port)
            process = subprocess.Popen([binary, "--bind", "127.0.0.1", "--port", str(port),
                                        "--dir", folder, "--save", "", "--appendonly", "no", "--memcached-port", "0"],
                                       cwd=folder, stdout=log, stderr=subprocess.STDOUT)
            wait_server(port, process)
            yield
            if process is not None and process.poll() is not None:
                raise ValueError("Eski exited during comparison")
        finally:
            if process is not None:
                stop_process(process)


def output_directory(path, prefix):
    if path is None:
        return Path(tempfile.mkdtemp(prefix=prefix))
    path = path.resolve()
    path.mkdir(parents=True, exist_ok=True)
    if any(path.iterdir()):
        raise ValueError("output directory must be empty: %s" % path)
    return path


def interrupted(signum, frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description="Compare live search and JSON replies on disposable loopback servers.")
    parser.add_argument("--server", type=Path, default=Path(os.getenv("ESKI_SEARCH_SERVER", ROOT / "bin/eski")))
    parser.add_argument("--port", type=int, default=os.getenv("ESKI_SEARCH_PORT", "6483"))
    parser.add_argument("--reference-port", type=int, default=os.getenv("ESKI_SEARCH_REF_PORT", "6484"))
    parser.add_argument("--redis-self", action="store_true", help="start pinned Redis at both endpoints")
    parser.add_argument("--capture", type=Path, help="trusted executable Python search capture")
    parser.add_argument("--observed", type=Path, help="recorded JSON matching --capture")
    parser.add_argument("--sections", help="comma-separated section function names from --capture")
    parser.add_argument("--protocol", choices=(2, 3), type=int, help="run only one protocol of the tracked fixture")
    parser.add_argument("--expected", type=Path, default=HERE / "expected.json", help="expected difference manifest")
    parser.add_argument("--out", type=Path, help="empty directory for reports and server logs")
    args = parser.parse_args()
    if bool(args.capture) != bool(args.observed) or args.sections and not args.capture or args.capture and args.protocol:
        parser.error("--capture and --observed go together, --sections requires them, and --protocol is for the tracked fixture")
    if not 1024 <= args.port <= 65535 or not 1024 <= args.reference_port <= 65535 or args.port == args.reference_port:
        parser.error("choose two distinct non-privileged loopback ports")
    try:
        expected = load_expected(args.expected)
        out = output_directory(args.out, "eski-search-")
    except (ValueError, OSError, KeyError) as e:
        parser.exit(2, "search comparison: %s\n" % e)
    signal.signal(signal.SIGTERM, interrupted)
    print("search comparison output %s" % out, flush=True)
    report = {"cases": [], "exact": 0, "observed_exact": 0, "observed_changed": 0, "rules": NORMALIZATIONS,
              "reference_image": IMAGE}
    fixture = "capture" if args.capture else "smoke"
    expected = {key: value for key, value in expected.items() if key.startswith(fixture + "/")}
    comparison = Comparison(report, expected if not args.redis_self else {}, not (args.sections or args.protocol))
    rc = 2
    try:
        with ExitStack() as stack:
            stack.enter_context(reference_server(args.reference_port, out / "redis"))
            if args.redis_self:
                stack.enter_context(reference_server(args.port, out / "eski"))
            else:
                stack.enter_context(eski_server(args.port, out / "eski", args.server.resolve()))
            replay = Replay((args.port, args.reference_port), comparison, fixture, stack)
            if args.capture:
                private_capture(replay, args.capture.resolve(), args.observed, args.sections.split(",") if args.sections else None)
            else:
                fixtures.smoke(replay, [args.protocol] if args.protocol else (2, 3))
        rc = int(comparison.finish())
    except (ValueError, OSError, wire.ServerGone, subprocess.SubprocessError, KeyError, TypeError, IndexError, KeyboardInterrupt) as e:
        report["error"] = str(e) or type(e).__name__
        print("search comparison:", report["error"], file=sys.stderr)
        comparison.finish()
    finally:
        report["exit_code"] = rc
        (out / "comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
