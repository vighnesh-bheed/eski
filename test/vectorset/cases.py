import random
import struct

COMMANDS = ["VADD", "VSIM", "VREM", "VCARD", "VDIM", "VEMB", "VLINKS", "VINFO", "VSETATTR", "VGETATTR", "VRANDMEMBER", "VISMEMBER", "VRANGE"]
SEED = 20261106
LUA_VSIM_SCORES = "return redis.call('VSIM', KEYS[1], 'VALUES', '2', '1', '0', 'WITHSCORES')"


def fp32(values):
    return struct.pack("<%df" % len(values), *values)


def raw(a):
    if isinstance(a, (bytes, dict)):
        return a
    if isinstance(a, int):
        return str(a).encode()
    return a.encode()


VSIM_VALUE_OPTIONS = {b"COUNT", b"EPSILON", b"EF", b"FILTER", b"FILTER-EF"}


def vsim_options(argv):
    form = argv[2].upper() if len(argv) > 2 else b""
    i = 4
    if form == b"VALUES" and len(argv) > 3:
        try:
            i = 4 + int(argv[3])
        except ValueError:
            i = 4
    flags = set()
    values = {}
    while i < len(argv):
        token = argv[i].upper()
        if token in VSIM_VALUE_OPTIONS:
            if i + 1 < len(argv):
                values[token] = argv[i + 1]
            i += 2
            continue
        flags.add(token)
        i += 1
    return flags, values


def auto_norm(argv):
    name = argv[0].upper()
    sub = argv[1].upper() if len(argv) > 1 else b""
    if name == b"VSIM":
        flags, _ = vsim_options(argv)
        return "exact" if b"TRUTH" in flags else "vsim"
    if name == b"VINFO":
        return "vinfo"
    if name == b"VLINKS":
        return "vlinks"
    if name == b"VRANDMEMBER":
        return "vrandmember"
    if name == b"MEMORY" and sub == b"USAGE":
        return "integer"
    if name == b"DEBUG" and sub == b"OBJECT":
        return "debug-object"
    if name == b"TTL":
        return "ttl"
    if name == b"SCAN":
        upper = [a.upper() for a in argv]
        if b"COUNT" in upper and int(argv[upper.index(b"COUNT") + 1]) >= 1000:
            return "scan"
        return "scan-partial"
    if name == b"INFO":
        return "type"
    if name == b"MODULE" and sub == b"LIST":
        return "module-list"
    if name == b"COMMAND" and sub == b"COUNT":
        return "integer"
    if name == b"COMMAND" and sub == b"LIST":
        return "sorted"
    if name == b"ACL" and sub == b"CAT" and len(argv) == 3 and argv[2].lower() in (b"read", b"write"):
        return "acl-listing"
    if name == b"DUMP":
        return "type"
    return "exact"


class Plan:
    def __init__(self):
        self.steps = []
        self.section = ""
        self.rng = random.Random(SEED)

    def step(self, kind, argv=None, proto=2, norm=None, note="", command=None, **extra):
        args = [raw(a) for a in argv] if argv is not None else None
        if norm is None and args:
            norm = auto_norm(args)
        entry = {"kind": kind, "section": self.section, "argv": args, "proto": proto, "norm": norm or "exact", "note": note}
        if command:
            entry["command"] = command
        elif args:
            entry["command"] = args[0].decode("latin1").upper()
        entry.update(extra)
        self.steps.append(entry)
        return entry

    def case(self, argv, note="", proto=2, norm=None, command=None, **extra):
        return self.step("case", argv, proto, norm, note, command, **extra)

    def both(self, argv, note="", norm=None, command=None, **extra):
        for p in (2, 3):
            self.case(argv, note, p, norm, command, **extra)

    def setup(self, argv, proto=2, norm=None, **extra):
        return self.step("setup", argv, proto, norm, **extra)

    def flush(self):
        self.setup(["FLUSHALL", "SYNC"])

    def load(self, key, n, dim, mode=None, extra=(), proto=2):
        cmds = []
        for i in range(n):
            vec = [self.rng.uniform(-1.0, 1.0) for _ in range(dim)]
            argv = ["VADD", key, "FP32", fp32(vec), "e%d" % i]
            if mode:
                argv.append(mode)
            argv.extend(extra)
            cmds.append([raw(a) for a in argv])
        for i in range(0, len(cmds), 200):
            self.steps.append({"kind": "pipeline", "section": self.section, "proto": proto, "commands": cmds[i:i + 200], "command": "VADD", "norm": "exact", "note": "load %s rows %d to %d" % (key, i, min(n, i + 200) - 1)})


def basic_set(plan, key, proto, mode=None):
    extra = [mode] if mode else []
    plan.setup(["VADD", key, "VALUES", "2", "1", "0", "a"] + extra, proto)
    plan.setup(["VADD", key, "VALUES", "2", "0", "1", "b"] + extra, proto)
    plan.setup(["VADD", key, "VALUES", "2", "1", "1", "c"] + extra, proto)
    plan.setup(["VADD", key, "VALUES", "2", "-1", "0", "d"] + extra, proto)


def attr_set(plan, key, proto):
    plan.setup(["VADD", key, "VALUES", "2", "1", "0", "a", "SETATTR", '{"n":1,"s":"x","b":true,"arr":[1,2],"o":{"k":5},"f":1.5}'], proto)
    plan.setup(["VADD", key, "VALUES", "2", "0", "1", "b", "SETATTR", '{"n":2,"s":"y","b":false}'], proto)
    plan.setup(["VADD", key, "VALUES", "2", "1", "1", "c", "SETATTR", '{"n":3,"s":"10"}'], proto)
    plan.setup(["VADD", key, "VALUES", "2", "-1", "0", "d"], proto)
    plan.setup(["VADD", key, "VALUES", "2", "0.5", "0.1", "e", "SETATTR", "notjson"], proto)


def sec_introspection(plan):
    plan.section = "introspection"
    plan.flush()
    for p in (2, 3):
        plan.case(["INFO", "server"], "server identity", p)
        plan.case(["MODULE", "LIST"], "module providing the vector set type", p)
        plan.case(["COMMAND", "LIST", "FILTERBY", "PATTERN", "V*"], "vector set command names", p)
        plan.case(["COMMAND", "COUNT"], "", p)
        for name in COMMANDS:
            plan.case(["COMMAND", "INFO", name], "arity, flags, first/last/step, ACL categories, tips, key specs, subcommands", p, command=name)
        for name in COMMANDS:
            plan.case(["COMMAND", "DOCS", name], "since, group, module and arguments tree, with the summary in Eski's own words left out", p, norm="docs-summary", command=name)
        plan.case(["COMMAND", "GETKEYS", "VADD", "k", "VALUES", "2", "1", "0", "e"], "", p, command="VADD")
        plan.case(["COMMAND", "GETKEYS", "VSIM", "k", "VALUES", "2", "1", "0"], "", p, command="VSIM")
        plan.case(["COMMAND", "GETKEYSANDFLAGS", "VADD", "k", "VALUES", "2", "1", "0", "e"], "", p, command="VADD")
        plan.case(["COMMAND", "GETKEYSANDFLAGS", "VSIM", "k", "VALUES", "2", "1", "0"], "", p, command="VSIM")
        plan.case(["ACL", "CAT", "vectorset"], "there is no vectorset ACL category", p)
    plan.step("acl-scan", None, 2, "exact", "no ACL category lists a vector set command", command="ACL")
    plan.case(["ACL", "CAT", "read"], "sample category listing: no vector set command appears", 2)
    plan.case(["ACL", "CAT", "write"], "sample category listing: no vector set command appears", 2)


def sec_variants(plan):
    plan.section = "variants"
    for p in (2, 3):
        plan.flush()

        def r(argv, note="", norm=None, **extra):
            plan.case(argv, note, p, norm, **extra)

        r(["VADD", "v", "VALUES", "2", "1", "0", "a"], "new element, VALUES form")
        r(["VADD", "v", "FP32", fp32([0.0, 1.0]), "b"], "new element, FP32 little-endian blob")
        r(["VADD", "v", "VALUES", "2", "1", "1", "c", "CAS"], "CAS insert")
        r(["VADD", "v", "VALUES", "2", "-1", "0", "d", "EF", "500"], "EF build factor")
        r(["VADD", "v", "VALUES", "2", "0.5", "0.1", "e", "SETATTR", '{"k":1}'], "SETATTR at insert")
        r(["VADD", "v", "VALUES", "2", "0.5", "0.1", "f", "Q8"], "explicit Q8 on a Q8 set")
        r(["VADD", "v", "VALUES", "2", "0.5", "0.1", "g", "M", "16"], "M equal to the existing M")
        r(["VADD", "v", "VALUES", "2", "0.5", "0.1", "h", "CAS", "Q8", "EF", "300", "SETATTR", '{"h":true}', "M", "16"], "every optional token together")
        r(["VADD", "nq", "VALUES", "2", "1", "0", "a", "NOQUANT"], "NOQUANT set")
        r(["VADD", "bn", "VALUES", "2", "1", "0", "a", "BIN"], "BIN set")
        r(["VADD", "m8", "VALUES", "2", "1", "0", "a", "M", "8"], "M 8 set")
        r(["VADD", "m64", "VALUES", "2", "1", "0", "a", "M", "64"], "M 64 set")
        r(["VADD", "rd", "REDUCE", "3", "VALUES", "8", "1", "2", "3", "4", "5", "6", "7", "8", "a"], "REDUCE 3 from 8")
        r(["VADD", "rd", "REDUCE", "3", "FP32", fp32([8, 7, 6, 5, 4, 3, 2, 1]), "b"], "REDUCE with FP32")
        r(["VADD", "v", "VALUES", "2", "1", "0", "a"], "existing element, same vector: 0 / false")
        r(["VINFO", "v"], "default quantisation int8, hnsw-m 16")
        r(["VINFO", "nq"], "f32")
        r(["VINFO", "bn"], "bin")
        r(["VINFO", "m8"])
        r(["VINFO", "m64"])
        r(["VINFO", "rd"], "vector-dim 3, projection-input-dim 8")
        r(["VDIM", "v"])
        r(["VDIM", "rd"], "reduced dimension")
        r(["VCARD", "v"])
        r(["VCARD", "nokey"], "missing key 0")
        r(["VEMB", "v", "a"], "Q8 de-quantised")
        r(["VEMB", "v", "a", "RAW"], "Q8 raw: int8, blob, norm, range")
        r(["VEMB", "v", "e"], "Q8 de-quantised non-axis vector")
        r(["VEMB", "v", "e", "RAW"])
        r(["VEMB", "nq", "a"], "NOQUANT")
        r(["VEMB", "nq", "a", "RAW"], "NOQUANT raw: f32, blob, norm")
        r(["VEMB", "bn", "a"], "BIN de-quantised: +1/-1 components")
        r(["VEMB", "bn", "a", "RAW"], "BIN raw: bin, bit blob, norm")
        r(["VEMB", "rd", "a"], "projected vector has 3 components")
        r(["VEMB", "rd", "a", "RAW"])
        r(["VEMB", "v", "zz"], "unknown element null")
        r(["VEMB", "nokey", "a"], "missing key null")
        r(["VSIM", "v", "VALUES", "2", "1", "0"], "plain names, default COUNT")
        r(["VSIM", "v", "FP32", fp32([1.0, 0.0])], "FP32 query")
        r(["VSIM", "v", "ELE", "a"], "ELE query")
        r(["VSIM", "v", "ELE", "a", "WITHSCORES"], "WITHSCORES shape")
        r(["VSIM", "v", "ELE", "a", "WITHATTRIBS"], "WITHATTRIBS shape")
        r(["VSIM", "v", "ELE", "a", "WITHSCORES", "WITHATTRIBS"], "WITHSCORES WITHATTRIBS shape")
        r(["VSIM", "v", "ELE", "a", "WITHATTRIBS", "WITHSCORES"], "order of the two flags does not matter")
        r(["VSIM", "v", "ELE", "a", "COUNT", "2"], "COUNT")
        r(["VSIM", "v", "ELE", "a", "COUNT", "100", "WITHSCORES"], "COUNT above size returns whole set")
        r(["VSIM", "v", "ELE", "a", "EPSILON", "0.5", "WITHSCORES"], "EPSILON: scores at least 1 - 0.5")
        r(["VSIM", "v", "ELE", "a", "EF", "50"], "EF")
        r(["VSIM", "v", "ELE", "a", "FILTER", ".k == 1"], "FILTER")
        r(["VSIM", "v", "ELE", "a", "FILTER", ".k == 1", "FILTER-EF", "10"], "FILTER-EF")
        r(["VSIM", "v", "ELE", "a", "FILTER-EF", "10"], "FILTER-EF without FILTER is accepted")
        r(["VSIM", "v", "ELE", "a", "TRUTH", "WITHSCORES"], "TRUTH linear scan")
        r(["VSIM", "v", "ELE", "a", "NOTHREAD", "WITHSCORES"], "NOTHREAD")
        r(["VSIM", "v", "ELE", "a", "TRUTH", "NOTHREAD", "WITHSCORES", "WITHATTRIBS", "COUNT", "3", "EF", "10", "EPSILON", "0.9", "FILTER", "1 == 1", "FILTER-EF", "500"], "every option together")
        r(["VSIM", "nokey", "VALUES", "2", "1", "0"], "missing key empty array")
        r(["VSIM", "nokey", "ELE", "a", "WITHSCORES"], "missing key empty array even with WITHSCORES and unknown ELE")
        r(["VSIM", "rd", "VALUES", "8", "1", "2", "3", "4", "5", "6", "7", "8", "WITHSCORES"], "full-size query on a REDUCE set")
        r(["VSIM", "rd", "VALUES", "3", "1", "2", "3", "WITHSCORES"], "reduced-size query on a REDUCE set is accepted")
        r(["VSIM", "rd", "ELE", "a", "WITHSCORES"], "ELE query on a REDUCE set")
        r(["VSIM", "bn", "VALUES", "2", "1", "0", "WITHSCORES"], "BIN set score")
        r(["VSIM", "nq", "VALUES", "2", "1", "0", "WITHSCORES"], "NOQUANT set score")
        r(["VLINKS", "v", "a"], "small set, single layer or more")
        r(["VLINKS", "v", "a", "WITHSCORES"])
        r(["VLINKS", "v", "zz"], "unknown element null")
        r(["VLINKS", "nokey", "a"], "missing key null")
        r(["VSETATTR", "v", "a", '{"x":1}'], "set attribute")
        r(["VGETATTR", "v", "a"], "get attribute")
        r(["VSETATTR", "v", "a", ""], "empty string deletes")
        r(["VGETATTR", "v", "a"], "deleted attribute null")
        r(["VSETATTR", "v", "a", "not json"], "stored without validation")
        r(["VGETATTR", "v", "a"])
        r(["VSETATTR", "v", "zz", "{}"], "unknown element 0 / false")
        r(["VSETATTR", "nokey", "a", "{}"], "missing key 0 / false, key not created")
        r(["EXISTS", "nokey"], "VSETATTR did not create the key")
        r(["VGETATTR", "v", "zz"], "unknown element null")
        r(["VGETATTR", "nokey", "a"], "missing key null")
        r(["VGETATTR", "v", "b"], "element without attribute null")
        r(["VRANDMEMBER", "v"], "no count: one bulk")
        r(["VRANDMEMBER", "v", "2"], "positive count distinct")
        r(["VRANDMEMBER", "v", "-12"], "negative count with repeats")
        r(["VRANDMEMBER", "v", "100"], "count above size: whole set")
        r(["VRANDMEMBER", "v", "0"], "count 0 empty array")
        r(["VRANDMEMBER", "nokey"], "missing key null")
        r(["VRANDMEMBER", "nokey", "3"], "missing key with count empty array")
        r(["VRANDMEMBER", "nokey", "-3"], "missing key with negative count empty array")
        r(["VISMEMBER", "v", "a"], "present")
        r(["VISMEMBER", "v", "zz"], "absent")
        r(["VISMEMBER", "nokey", "a"], "missing key")
        r(["VRANGE", "v", "-", "+"], "whole lex range")
        r(["VRANGE", "v", "-", "+", "3"], "count")
        r(["VRANGE", "v", "-", "+", "0"], "count 0 empty")
        r(["VRANGE", "v", "-", "+", "-1"], "negative count means no limit")
        r(["VRANGE", "v", "[b", "[d"], "inclusive bounds")
        r(["VRANGE", "v", "(b", "(d"], "exclusive bounds")
        r(["VRANGE", "v", "[b", "+"])
        r(["VRANGE", "v", "-", "(c"])
        r(["VRANGE", "v", "[c", "[b"], "inverted range empty")
        r(["VRANGE", "nokey", "-", "+"], "missing key empty array")
        r(["VREM", "v", "zz"], "unknown element 0 / false")
        r(["VREM", "nokey", "a"], "missing key 0 / false")
        r(["VREM", "v", "h"], "removed 1 / true")
        r(["VCARD", "v"])
        r(["TYPE", "v"])
        r(["OBJECT", "ENCODING", "v"])
        r(["vadd", "lc", "values", "2", "1", "0", "a", "noquant", "ef", "100", "m", "16", "setattr", "{}", "cas"], "option tokens are case-insensitive")
        r(["vsim", "lc", "values", "2", "1", "0", "withscores", "withattribs", "count", "1", "ef", "5", "epsilon", "0.9", "filter", "1==1", "filter-ef", "5", "truth", "nothread"], "case-insensitive VSIM options")
        r(["VEMB", "lc", "a", "raw"], "lowercase RAW")
        r(["VLINKS", "lc", "a", "withscores"], "lowercase WITHSCORES")
        r(["VADD", "lc", "VALUES", "2", "0", "1", "", "NOQUANT"], "empty element name is allowed")
        r(["VISMEMBER", "lc", ""])
        r(["VRANGE", "lc", "-", "+"])


ARITY_CASES = [["VADD"], ["VADD", "v"], ["VADD", "v", "VALUES"], ["VADD", "v", "VALUES", "2"], ["VADD", "v", "VALUES", "2", "1", "0"], ["VADD", "v", "FP32"],
               ["VSIM"], ["VSIM", "v"], ["VSIM", "v", "a"], ["VSIM", "v", "ELE"],
               ["VREM"], ["VREM", "v"], ["VREM", "v", "a", "b"],
               ["VCARD"], ["VCARD", "v", "x"],
               ["VDIM"], ["VDIM", "v", "x"],
               ["VEMB"], ["VEMB", "v"],
               ["VLINKS"], ["VLINKS", "v"], ["VLINKS", "v", "a", "WITHSCORES", "x"],
               ["VINFO"], ["VINFO", "v", "x"],
               ["VSETATTR"], ["VSETATTR", "v"], ["VSETATTR", "v", "a"], ["VSETATTR", "v", "a", "b", "c"],
               ["VGETATTR"], ["VGETATTR", "v"], ["VGETATTR", "v", "a", "b"],
               ["VRANDMEMBER"], ["VRANDMEMBER", "v", "1", "2"],
               ["VISMEMBER"], ["VISMEMBER", "v"], ["VISMEMBER", "v", "a", "b"],
               ["VRANGE"], ["VRANGE", "v"], ["VRANGE", "v", "-"], ["VRANGE", "v", "-", "+", "1", "2"]]

WRONGTYPE_CASES = [("VADD", ["VALUES", "2", "1", "0", "a"]), ("VSIM", ["ELE", "a"]), ("VREM", ["a"]), ("VCARD", []), ("VDIM", []), ("VEMB", ["a"]), ("VLINKS", ["a"]), ("VINFO", []), ("VSETATTR", ["a", "{}"]), ("VGETATTR", ["a"]), ("VRANDMEMBER", []), ("VRANDMEMBER", ["2"]), ("VISMEMBER", ["a"]), ("VRANGE", ["-", "+"])]

FILTERS = ['.n > 1', '.n >= 2 and .s == "y"', '.s == "x" or .n == 3', 'not .b', '!.b', '.b', '.b == 1', '.b == 0', '.b == true', '.n in [1,3]', '.s in ["x","y"]',
           '.n + 1 == 2', '.n - 1 == 0', '.n * 2 == 4', '.n / 2 == 0.5', '.n % 2 == 1', '.n ** 2 == 4', '(.n - 2) ** 2 < 1', '.n != 1', '.n < 2', '.n <= 2', '.n > 2', '.n >= 3',
           '.o.k == 5', '.o', '.arr', '.missing == 1', '.missing != 1', '!.missing', 'not .missing', '.missing or 1 == 1',
           '.s > 2', '.s == 10', '.s == "10"', '.n == "1"', '.n == "x"', '.s < .n', '.s + 1 == "x1"', '.s * 2 == 20',
           '.n', '.s', '(.n)', '1 == 1', '"a" == "a"', "'x' == .s", ".s == 'x'", '.f > 1.4', '.f == 1.5', '-.n == -1', '.n > 0 && .n < 2', '.n > 2 || .n < 2', '.n && .b', '.n || .b',
           '.arr in [1]', '1 in .arr', '.n in 1', '.n in []', '.n in ["1"]', '.n in [1, "x", 2]',
           '.n >', '.n > ', '(.n > 1', '.n > 1)', '.n >> 1', '.n = 1', '.n and', 'true', 'false', '.n == true', '..n == 1', '.', '', ' ', '.n ==== 1', '.n & .b', '.n | .b', 'foo', '1 +', '[1,2]', '.n in [1,', '.s == "x', '.n == 1 and', 'and .n == 1']


def sec_errors(plan):
    plan.section = "errors"
    for p in (2, 3):
        plan.flush()

        def r(argv, note=""):
            plan.case(argv, note, p)

        basic_set(plan, "v", p)
        plan.setup(["SET", "s", "x"], p)
        plan.setup(["HSET", "h", "f", "v"], p)
        for argv in ARITY_CASES:
            r(argv, "arity")
        r(["VADD", "v", "VALUES", "2", "1"], "passes arity -5 but the vector is short")
        r(["VDIM", "nokey"], "missing key is an error for VDIM")
        r(["VINFO", "nokey"], "missing key null")
        r(["VSIM", "v", "ELE", "zz"], "unknown element")
        for name, argv in WRONGTYPE_CASES:
            r([name, "s"] + argv, "string key")
            r([name, "h"] + argv, "hash key")
        r(["VADD", "v", "VALUES", "3", "1", "0", "0", "e"], "dimension mismatch VALUES")
        r(["VADD", "v", "FP32", fp32([1, 0, 0]), "e"], "dimension mismatch FP32")
        r(["VADD", "v", "VALUES", "2", "1", "x", "e"], "non-numeric value")
        r(["VADD", "v", "VALUES", "2", "1", "e"], "fewer values than count")
        r(["VADD", "v", "VALUES", "2", "1", "0", "0", "e"], "more values than count: last value is taken as element")
        r(["VADD", "v", "VALUES", "0", "e"], "zero count")
        r(["VADD", "v", "VALUES", "-1", "e"], "negative count")
        r(["VADD", "v", "VALUES", "x", "1", "e"], "non-numeric count")
        r(["VADD", "v", "VALUES", "2", "nan", "0", "e"], "nan value")
        r(["VADD", "v", "VALUES", "2", "inf", "0", "e"], "inf value is accepted")
        r(["VADD", "v", "FP32", b"abc", "e"], "FP32 blob not a multiple of 4")
        r(["VADD", "v", "FP32", b"", "e"], "empty FP32 blob")
        r(["VADD", "v", "ELE", "a", "e"], "ELE is not a VADD vector form")
        r(["VADD", "v", "BOGUS", "2", "1", "0", "e"], "unknown vector form")
        r(["VADD", "v", "VALUES", "2", "1", "0", "e", "BIN"], "quantisation mismatch BIN on Q8")
        r(["VADD", "v", "VALUES", "2", "1", "0", "e", "NOQUANT"], "quantisation mismatch NOQUANT on Q8")
        plan.setup(["VADD", "b", "VALUES", "2", "1", "0", "a", "BIN"], p)
        r(["VADD", "b", "VALUES", "2", "1", "0", "e", "Q8"], "quantisation mismatch Q8 on BIN")
        r(["VADD", "b", "VALUES", "2", "1", "0", "e"], "no quantisation token on a BIN set: the implied default Q8 mismatches")
        r(["VADD", "b", "VALUES", "2", "1", "0", "e", "BIN"], "BIN set accepts only VADDs that repeat BIN")
        plan.setup(["VADD", "nqs", "VALUES", "2", "1", "0", "a", "NOQUANT"], p)
        r(["VADD", "nqs", "VALUES", "2", "0", "1", "e"], "no quantisation token on a NOQUANT set")
        r(["VADD", "nqs", "VALUES", "2", "0", "1", "e", "NOQUANT"], "NOQUANT repeated")
        plan.setup(["VADD", "m8s", "VALUES", "2", "1", "0", "a", "M", "8"], p)
        r(["VADD", "m8s", "VALUES", "2", "0", "1", "e"], "no M token on an M 8 set")
        r(["VADD", "m8s", "VALUES", "2", "0", "1", "e", "M", "8"], "M repeated")
        plan.setup(["VADD", "m16s", "VALUES", "2", "1", "0", "a", "M", "16"], p)
        r(["VADD", "m16s", "VALUES", "2", "0", "1", "e"], "no M token on an explicit M 16 set")
        r(["VADD", "v", "REDUCE", "1", "VALUES", "2", "1", "0", "e"], "REDUCE on an existing set without projection")
        plan.setup(["VADD", "rd", "REDUCE", "3", "VALUES", "8", "1", "2", "3", "4", "5", "6", "7", "8", "a"], p)
        r(["VADD", "rd", "VALUES", "8", "1", "1", "1", "1", "1", "1", "1", "1", "c"], "no REDUCE on a projected set")
        r(["VADD", "rd", "REDUCE", "4", "VALUES", "8", "1", "1", "1", "1", "1", "1", "1", "1", "c"], "different REDUCE on a projected set")
        r(["VADD", "rd", "REDUCE", "3", "VALUES", "3", "1", "1", "1", "c"], "input shorter than projection input")
        r(["VADD", "rd", "VALUES", "3", "1", "1", "1", "c"], "reduced-size input without REDUCE")
        r(["VADD", "rd2", "REDUCE", "10", "VALUES", "3", "1", "2", "3", "a"], "REDUCE above the input dimension")
        r(["VADD", "rd2", "REDUCE", "0", "VALUES", "3", "1", "2", "3", "a"], "REDUCE 0")
        r(["VADD", "rd2", "REDUCE", "x", "VALUES", "3", "1", "2", "3", "a"], "REDUCE non-numeric")
        r(["VADD", "rd2", "REDUCE", "VALUES", "3", "1", "2", "3", "a"], "REDUCE without dim")
        r(["VADD", "rd2", "VALUES", "3", "1", "2", "3", "a", "REDUCE", "2"], "REDUCE after element")
        r(["VADD", "rd2", "CAS", "VALUES", "3", "1", "2", "3", "a"], "CAS before vector")
        for val in ["0", "-1", "x", "99999999999", "1.5"]:
            r(["VADD", "v", "VALUES", "2", "1", "0", "e", "EF", val], "invalid EF")
        r(["VADD", "v", "VALUES", "2", "1", "0", "e", "EF"], "EF without value")
        for val in ["0", "1", "2", "-1", "x", "100000", "1.5"]:
            r(["VADD", "v", "VALUES", "2", "1", "0", "e", "M", val], "invalid M")
        r(["VADD", "v", "VALUES", "2", "1", "0", "e", "M"], "M without value")
        r(["VADD", "v", "VALUES", "2", "1", "0", "e", "M", "32"], "M different from existing set")
        r(["VADD", "m3", "VALUES", "2", "1", "0", "e", "M", "3"], "M 3 on a new set")
        r(["VADD", "m1024", "VALUES", "2", "1", "0", "e", "M", "1024"], "M 1024 on a new set")
        r(["VADD", "m1025", "VALUES", "2", "1", "0", "e", "M", "1025"], "M 1025 on a new set")
        r(["VADD", "ef1", "VALUES", "2", "1", "0", "e", "EF", "1"], "EF 1 on a new set")
        r(["VADD", "ef2", "VALUES", "2", "1", "0", "e", "EF", "1000000"], "EF 1000000 on a new set")
        r(["VADD", "ef3", "VALUES", "2", "1", "0", "e", "EF", "1000001"], "EF 1000001 on a new set")
        r(["VADD", "v", "VALUES", "2", "1", "0", "e", "BOGUS"], "unknown option after element")
        r(["VADD", "v", "VALUES", "2", "1", "0", "e", "SETATTR"], "SETATTR without value")
        r(["VADD", "v", "VALUES", "2", "1", "0", "e", "WITHSCORES"], "VSIM token given to VADD")
        r(["VADD", "d1", "VALUES", "2", "1", "0", "e", "Q8", "Q8"], "duplicate Q8 accepted")
        r(["VADD", "d2", "VALUES", "2", "1", "0", "e", "NOQUANT", "Q8"], "NOQUANT then Q8: last wins")
        r(["VINFO", "d2"])
        r(["VADD", "d3", "VALUES", "2", "1", "0", "e", "Q8", "BIN"], "Q8 then BIN: last wins")
        r(["VINFO", "d3"])
        r(["VADD", "d4", "VALUES", "2", "1", "0", "e", "BIN", "NOQUANT"], "BIN then NOQUANT: last wins")
        r(["VINFO", "d4"])
        r(["VADD", "d5", "VALUES", "2", "1", "0", "e", "CAS", "CAS"], "duplicate CAS accepted")
        r(["VADD", "d6", "VALUES", "2", "1", "0", "e", "EF", "10", "EF", "20"], "duplicate EF accepted")
        r(["VADD", "d7", "VALUES", "2", "1", "0", "e", "M", "8", "M", "4"], "duplicate M: last wins")
        r(["VINFO", "d7"])
        r(["VADD", "d8", "VALUES", "2", "1", "0", "e", "SETATTR", '{"a":1}', "SETATTR", '{"a":2}'], "duplicate SETATTR: last wins")
        r(["VGETATTR", "d8", "e"])
        r(["VADD", "d9", "VALUES", "2", "1", "0", "e", "SETATTR", "{bad"], "invalid JSON accepted at VADD")
        r(["VGETATTR", "d9", "e"])
        r(["VSIM", "v", "VALUES", "3", "1", "0", "0"], "query dimension mismatch")
        r(["VSIM", "v", "FP32", fp32([1, 0, 0])], "FP32 query dimension mismatch")
        r(["VSIM", "v", "FP32", b"abc"], "FP32 query bad length")
        r(["VSIM", "v", "VALUES", "2", "1", "x"], "non-numeric query value")
        r(["VSIM", "v", "VALUES", "2", "1"], "short VALUES query")
        r(["VSIM", "v", "VALUES", "0"], "zero VALUES query")
        r(["VSIM", "v", "VALUES", "2", "nan", "0"], "nan query")
        r(["VSIM", "v", "VALUES", "2", "inf", "0", "WITHSCORES"], "inf query accepted, degenerate scores")
        r(["VSIM", "v", "VALUES", "2", "0", "0", "WITHSCORES"], "zero query accepted, degenerate scores")
        r(["VSIM", "v", "BOGUS", "a"], "unknown vector form")
        r(["VSIM", "rd", "VALUES", "5", "1", "2", "3", "4", "5"], "neither reduced nor input size on a REDUCE set")
        for val in ["0", "-1", "x", "1.5"]:
            r(["VSIM", "v", "ELE", "a", "COUNT", val], "invalid COUNT")
        r(["VSIM", "v", "ELE", "a", "COUNT", "99999999999"], "huge COUNT accepted")
        r(["VSIM", "v", "ELE", "a", "COUNT"], "COUNT without value")
        for val in ["0", "-1", "x", "99999999999", "1.5"]:
            r(["VSIM", "v", "ELE", "a", "EF", val], "invalid EF")
        r(["VSIM", "v", "ELE", "a", "EF", "1000000"], "EF 1000000 accepted")
        r(["VSIM", "v", "ELE", "a", "EF", "1000001"], "EF 1000001")
        r(["VSIM", "v", "ELE", "a", "EF"], "EF without value")
        for val in ["0", "-0.1", "x", "nan"]:
            r(["VSIM", "v", "ELE", "a", "EPSILON", val], "invalid EPSILON")
        r(["VSIM", "v", "ELE", "a", "EPSILON", "1"], "EPSILON 1 accepted")
        r(["VSIM", "v", "ELE", "a", "EPSILON", "1.5"], "EPSILON above 1 accepted")
        r(["VSIM", "v", "ELE", "a", "EPSILON", "inf"], "EPSILON inf")
        r(["VSIM", "v", "ELE", "a", "EPSILON"], "EPSILON without value")
        for val in ["0", "-1", "x", "1.5"]:
            r(["VSIM", "v", "ELE", "a", "FILTER", "1 == 1", "FILTER-EF", val], "invalid FILTER-EF")
        r(["VSIM", "v", "ELE", "a", "FILTER"], "FILTER without expression")
        r(["VSIM", "v", "ELE", "a", "FILTER-EF"], "FILTER-EF without value")
        r(["VSIM", "v", "ELE", "a", "BOGUS"], "unknown option")
        r(["VSIM", "v", "ELE", "a", "WITHSCORES", "WITHSCORES"], "duplicate WITHSCORES accepted")
        r(["VSIM", "v", "ELE", "a", "COUNT", "2", "COUNT", "3"], "duplicate COUNT: last wins")
        r(["VSIM", "v", "ELE", "a", "TRUTH", "TRUTH"], "duplicate TRUTH accepted")
        plan.flush()
        attr_set(plan, "v", p)
        for f in FILTERS:
            r(["VSIM", "v", "VALUES", "2", "1", "0", "FILTER", f, "WITHATTRIBS"], "filter expression")
        r(["VSIM", "v", "VALUES", "2", "1", "0", "FILTER", "1 == 1"], "constant-true filter skips elements without attributes (d) but keeps invalid JSON (e)")
        r(["VSIM", "v", "VALUES", "2", "1", "0", "FILTER", ".n > 1", "FILTER", ".n > 2"], "duplicate FILTER: last wins")
        r(["VSETATTR", "v", "a", "{bad json"], "invalid JSON stored without validation")
        r(["VGETATTR", "v", "a"])
        r(["VSIM", "v", "VALUES", "2", "1", "0", "FILTER", ".n == 1"], "element a now has invalid JSON and never matches")
        r(["VRANDMEMBER", "v", "x"], "non-integer count")
        r(["VRANDMEMBER", "v", "1.5"], "non-integer count")
        r(["VRANDMEMBER", "v", "-0"], "-0 rejected")
        r(["VRANDMEMBER", "v", "99999999999"], "huge positive count is clamped to the set size")
        r(["VRANDMEMBER", "v", "-1000"], "negative count is honoured literally: 1000 elements with repeats")
        r(["VEMB", "v", "a", "BOGUS"], "VEMB unknown option")
        r(["VEMB", "v", "a", "RAW", "x"], "VEMB extra token")
        r(["VLINKS", "v", "a", "BOGUS"], "VLINKS unknown option")
        r(["VRANGE", "v", "a", "b"], "bare bounds without [ or (")
        r(["VRANGE", "v", "[a", "b"], "bad end bound")
        r(["VRANGE", "v", "+", "-"], "swapped infinities")
        r(["VRANGE", "v", "+", "+"], "+ as start")
        r(["VRANGE", "v", "-", "-"], "- as end")
        r(["VRANGE", "v", "[a", "-"], "- as end")
        r(["VRANGE", "v", "(", "("], "empty exclusive bounds")
        r(["VRANGE", "v", "[", "["], "empty inclusive bounds")
        r(["VRANGE", "v", "-", "+", "x"], "non-integer count")
        r(["VRANGE", "v", "-", "+", "1.5"], "non-integer count")
        r(["VRANGE", "v", "-", "+", "99999999999"], "huge count accepted")
        r(["VRANGE", "v", "-", "+", "-5"], "negative count means no limit")
        r(["VADD", "v", "VALUES", "2", "1", "0", "zz", "CAS", "SETATTR", '{"c":1}', "EF", "500", "M", "32"], "M mismatch is reported before insert")
        r(["VISMEMBER", "v", "zz"], "element was not inserted")


def sec_semantics(plan):
    plan.section = "semantics"
    plan.flush()

    def r(argv, note="", p=2, norm=None, **extra):
        plan.case(argv, note, p, norm, **extra)

    pts = [("x", [1, 0, 0]), ("y", [0, 1, 0]), ("z", [1, 1, 1]), ("w", [-1, -1, 0])]
    for mode in ["NOQUANT", "Q8"]:
        for name, v in pts:
            plan.setup(["VADD", "sc_" + mode, "VALUES", "3"] + [str(a) for a in v] + [name, mode])
    r(["VSIM", "sc_NOQUANT", "VALUES", "3", "1", "2", "3", "WITHSCORES", "TRUTH"], "3D score probe, NOQUANT")
    r(["VSIM", "sc_NOQUANT", "VALUES", "3", "1", "2", "3", "WITHSCORES", "TRUTH"], "3D score probe, NOQUANT", 3)
    r(["VSIM", "sc_Q8", "VALUES", "3", "1", "2", "3", "WITHSCORES", "TRUTH"], "3D score probe, Q8 (quantisation shifts the values)")
    r(["VSIM", "sc_Q8", "VALUES", "3", "1", "2", "3", "WITHSCORES", "TRUTH"], "", 3)
    basic_set(plan, "sc2", 2, "NOQUANT")
    r(["VSIM", "sc2", "VALUES", "2", "1", "0", "WITHSCORES", "TRUTH"], "2D score probe, NOQUANT")
    basic_set(plan, "ln", 2, "NOQUANT")
    r(["VLINKS", "ln", "a", "WITHSCORES"], "VLINKS scores are float32 values printed as doubles")
    r(["VSIM", "ln", "ELE", "a", "WITHSCORES", "TRUTH"], "same pairs via VSIM carry the double-evaluated score")
    r(["VADD", "u", "VALUES", "2", "1", "0", "a"], "insert")
    r(["VADD", "u", "VALUES", "2", "0", "1", "a"], "existing element without CAS: reply 0, vector replaced")
    r(["VEMB", "u", "a"], "vector now (0,1)")
    r(["VADD", "u", "VALUES", "2", "1", "1", "a", "CAS"], "existing element with CAS: reply 0, vector replaced")
    r(["VEMB", "u", "a"], "vector now (1,1) normalised and de-normalised")
    r(["VADD", "u", "VALUES", "2", "1", "0", "a", "SETATTR", '{"k":1}'], "existing element with SETATTR: reply 0, attribute set")
    r(["VGETATTR", "u", "a"])
    r(["VADD", "u", "VALUES", "2", "1", "0", "a"], "update without SETATTR keeps the attribute")
    r(["VGETATTR", "u", "a"])
    r(["VADD", "u", "VALUES", "2", "1", "0", "a", "SETATTR", ""], "SETATTR empty string on update deletes the attribute")
    r(["VGETATTR", "u", "a"])
    r(["VINFO", "u"], "attributes-count after delete")
    for mode in ["NOQUANT", "Q8", "BIN"]:
        key = "q_" + mode
        for name, vals in [("a", ["0.1", "-0.2", "0.3", "0.4"]), ("b", ["1", "2", "3", "4"]), ("c", ["-1", "0", "0", "0"]), ("d", ["0", "0", "0", "0.001"])]:
            plan.setup(["VADD", key, "VALUES", "4"] + vals + [name, mode])
        for name in ["a", "b", "c", "d"]:
            r(["VEMB", key, name], "%s de-quantised" % mode)
            r(["VEMB", key, name, "RAW"], "%s raw" % mode)
            r(["VEMB", key, name, "RAW"], "%s raw" % mode, 3)
        r(["VSIM", key, "VALUES", "4", "0.1", "-0.2", "0.3", "0.4", "WITHSCORES", "TRUTH"], "%s scores for a known query" % mode)
        r(["VINFO", key])
    plan.setup(["VADD", "rd", "REDUCE", "3", "VALUES", "8", "1", "2", "3", "4", "5", "6", "7", "8", "a"])
    plan.setup(["VADD", "rd", "REDUCE", "3", "VALUES", "8", "8", "7", "6", "5", "4", "3", "2", "1", "b"])
    r(["VDIM", "rd"], "VDIM is the reduced dimension")
    r(["VINFO", "rd"], "projection-input-dim records the input dimension")
    r(["VEMB", "rd", "a"], "projected values follow the fixed projection")
    r(["VSIM", "rd", "VALUES", "8", "1", "2", "3", "4", "5", "6", "7", "8", "WITHSCORES"], "full-size query accepted and projected")
    r(["VSIM", "rd", "VALUES", "3", "1", "0", "0", "WITHSCORES"], "reduced-size query accepted and used as is")
    r(["VSIM", "rd", "VALUES", "5", "1", "2", "3", "4", "5"], "other sizes rejected")
    plan.setup(["VADD", "rde", "REDUCE", "3", "VALUES", "3", "1", "2", "3", "a"])
    r(["VINFO", "rde"], "REDUCE equal to the input dimension is accepted")
    plan.setup(["VADD", "em", "VALUES", "2", "1", "0", "a"])
    r(["VREM", "em", "a"], "removing the last element")
    r(["EXISTS", "em"], "key is deleted with the last element")
    r(["VCARD", "em"])
    r(["VSIM", "em", "VALUES", "2", "1", "0"], "VSIM on the now-missing key")
    r(["VINFO", "em"])
    for i in range(6):
        plan.setup(["VADD", "tie", "VALUES", "2", "0", "1", "t%d" % i, "NOQUANT"])
    plan.setup(["VADD", "tie", "VALUES", "2", "1", "0", "far", "NOQUANT"])
    r(["VSIM", "tie", "VALUES", "2", "0", "1", "WITHSCORES", "TRUTH"], "equal scores: TRUTH order is insertion order")
    r(["VSIM", "tie", "VALUES", "2", "0", "1", "WITHSCORES"], "equal scores: HNSW order is graph dependent")
    r(["VSIM", "tie", "VALUES", "2", "0", "1", "COUNT", "3", "TRUTH"], "COUNT cuts the tied prefix")
    attr_set(plan, "eps", 2)
    r(["VSIM", "eps", "VALUES", "2", "1", "0", "WITHSCORES", "TRUTH"], "scores: a 1, e 0.99029, c 0.853553, b 0.5, d 0")
    r(["VSIM", "eps", "VALUES", "2", "1", "0", "EPSILON", "0.5", "WITHSCORES", "TRUTH"], "b at exactly 0.5 is kept: threshold is inclusive (score >= 1 - epsilon)")
    r(["VSIM", "eps", "VALUES", "2", "1", "0", "EPSILON", "0.49999", "WITHSCORES", "TRUTH"], "b is dropped")
    r(["VSIM", "eps", "VALUES", "2", "1", "0", "EPSILON", "0.1464467", "WITHSCORES", "TRUTH"], "c at 0.8535533845 kept")
    r(["VSIM", "eps", "VALUES", "2", "1", "0", "EPSILON", "0.1464466", "WITHSCORES", "TRUTH"], "c dropped")
    r(["VSIM", "eps", "VALUES", "2", "1", "0", "EPSILON", "1", "WITHSCORES", "TRUTH"], "EPSILON 1 keeps everything including score 0")
    for i in range(100):
        plan.setup(["VADD", "cnt", "VALUES", "2", str(i), "1", "e%d" % i])
    r(["VSIM", "cnt", "VALUES", "2", "1", "1"], "default COUNT is 10")
    r(["VSIM", "cnt", "VALUES", "2", "1", "1", "TRUTH"], "default COUNT is 10 with TRUTH")
    r(["VSIM", "cnt", "VALUES", "2", "1", "1", "COUNT", "500"], "COUNT above size returns the whole set")
    r(["VSIM", "cnt", "VALUES", "2", "1", "1", "FILTER", "1 == 1"], "filter on a set without attributes returns nothing")
    plan.load("big", 300, 8)
    plan.load("bigm4", 300, 8, extra=["M", "4"])
    plan.load("bigq", 300, 8, mode="NOQUANT")
    for key in ["big", "bigm4"]:
        r(["VINFO", key])
        for ele in ["e0", "e1"]:
            r(["VLINKS", key, ele], norm="vlinks-graph")
            r(["VLINKS", key, ele, "WITHSCORES"], "", 2, norm="vlinks-graph")
            r(["VLINKS", key, ele, "WITHSCORES"], "", 3, norm="vlinks-graph")
    for mode in ["NOQUANT", "Q8", "BIN"]:
        for d in [8, 32, 300]:
            for n in [1, 100, 1000]:
                key = "m_%s_%d_%d" % (mode, d, n)
                plan.load(key, n, d, mode=mode)
                r(["TYPE", key])
                r(["OBJECT", "ENCODING", key])
                r(["MEMORY", "USAGE", key], "%s dim %d n %d" % (mode, d, n))
                r(["DEBUG", "OBJECT", key])
                if n == 1:
                    r(["VINFO", key])
                plan.setup(["DEL", key])
    plan.setup(["VADD", "dmp", "VALUES", "2", "1", "0", "a"])
    plan.setup(["DUMP", "dmp"], store="dump")
    r(["DEBUG", "OBJECT", "dmp"], "encoding raw, serializedlength")
    r(["OBJECT", "ENCODING", "dmp"])
    r(["OBJECT", "FREQ", "dmp"])
    r(["RESTORE", "dmp2", "0", {"stored": "dump"}], "DUMP payload restores on the server that produced it")
    r(["VCARD", "dmp2"])
    r(["VEMB", "dmp2", "a"])
    r(["COPY", "dmp", "dmp3"], "COPY is not supported for the module key")
    r(["RENAME", "dmp", "dmp4"], "RENAME works")
    r(["VCARD", "dmp4"])
    r(["EXPIRE", "dmp4", "100"], "expiry can be set")
    r(["TTL", "dmp4"])
    r(["PERSIST", "dmp4"])
    r(["MOVE", "dmp4", "1"], "MOVE works")
    r(["SELECT", "1"])
    r(["VCARD", "dmp4"])
    r(["SELECT", "0"])
    r(["SORT", "dmp2", "ALPHA"], "SORT does not accept the type")
    r(["SCAN", "0", "TYPE", "vectorset"], "SCAN TYPE filter")
    r(["SCAN", "0", "TYPE", "vectorset", "COUNT", "1000"])
    r(["WAIT", "0", "0"])


def sec_notifications(plan):
    plan.section = "notifications"
    plan.flush()
    plan.setup(["CONFIG", "GET", "notify-keyspace-events"], store="notify")
    plan.case(["CONFIG", "SET", "notify-keyspace-events", "KEA"])
    plan.case(["CONFIG", "GET", "notify-keyspace-events"], "A already includes the module flag d")
    plan.step("subscribe", [b"PSUBSCRIBE", b"__key*__:*"], 2, "exact", "keyspace and keyevent subscriber", command="PSUBSCRIBE")
    probes = [(["VADD", "n", "VALUES", "2", "1", "0", "a"], "VADD new key"), (["VADD", "n", "VALUES", "2", "0", "1", "a"], "VADD update"), (["VADD", "n", "VALUES", "2", "0", "1", "b", "CAS"], "VADD CAS"),
              (["VADD", "n", "VALUES", "2", "0", "1", "c", "SETATTR", "{}"], "VADD SETATTR"), (["VSETATTR", "n", "a", "{}"], "VSETATTR"), (["VSETATTR", "n", "a", ""], "VSETATTR delete"), (["VREM", "n", "b"], "VREM"),
              (["VREM", "n", "c"], "VREM"), (["VREM", "n", "a"], "VREM last element deletes the key"), (["VADD", "n", "VALUES", "2", "1", "0", "a"], "VADD"), (["DEL", "n"], "DEL"),
              (["VADD", "n", "VALUES", "2", "1", "0", "a"], "VADD"), (["UNLINK", "n"], "UNLINK"), (["VADD", "n", "VALUES", "2", "1", "0", "a"], "VADD"), (["RENAME", "n", "n2"], "RENAME"), (["DEL", "n2"], "DEL")]
    for argv, tag in probes:
        plan.case(argv, "notification probe: " + tag)
        plan.step("events", None, 2, "exact", "events after " + tag, command=argv[0])
    plan.case(["VADD", "n", "VALUES", "2", "1", "0", "a"], "notification probe: VADD before expiry")
    plan.case(["PEXPIRE", "n", "40"], "notification probe: PEXPIRE")
    plan.step("sleep", None, 2, "exact", "let the key expire", seconds=0.3)
    plan.case(["EXISTS", "n"], "expired")
    plan.step("events", None, 2, "exact", "events after PEXPIRE 40, a wait and EXISTS", command="PEXPIRE")
    plan.case(["CONFIG", "SET", "notify-keyspace-events", {"stored": "notify", "field": 1}], "restore")
    plan.step("unsubscribe", None, 2, "exact", "close the subscriber", command="PSUBSCRIBE")


def sec_lua(plan):
    plan.section = "lua"
    plan.flush()
    plan.setup(["VADD", "lk", "VALUES", "2", "1", "0", "a"])
    plan.setup(["VADD", "lk", "VALUES", "2", "0", "1", "b", "SETATTR", '{"q":1}'])
    inner_values = ["VSIM", "lk", "VALUES", "2", "1", "0", "WITHSCORES"]
    inner_ele = ["VSIM", "lk", "ELE", "a", "WITHSCORES", "WITHATTRIBS"]
    plan.both(["EVAL", LUA_VSIM_SCORES, "1", "lk"], "RESP2 flat array from Lua in both client protocols", norm="vsim", command="VSIM", inner=[raw(a) for a in inner_values])
    plan.both(["EVAL", "redis.setresp(3); " + LUA_VSIM_SCORES, "1", "lk"], "setresp(3) yields a map to the RESP3 client, flattened for RESP2", norm="vsim", command="VSIM", inner=[raw(a) for a in inner_values])
    plan.both(["EVAL", "return redis.call('VSIM', KEYS[1], 'ELE', 'a', 'WITHSCORES', 'WITHATTRIBS')", "1", "lk"], "", norm="vsim", command="VSIM", inner=[raw(a) for a in inner_ele])
    plan.both(["EVAL", "redis.setresp(3); return redis.call('VSIM', KEYS[1], 'ELE', 'a', 'WITHSCORES', 'WITHATTRIBS')", "1", "lk"], "", norm="exact", command="VSIM")
    plan.both(["EVAL", "return redis.call('VADD', KEYS[1], 'VALUES', '2', '1', '1', ARGV[1])", "1", "lk", "c"], "second run returns 0 because the element exists", command="VADD")
    plan.both(["EVAL", "redis.setresp(3); return redis.call('VADD', KEYS[1], 'VALUES', '2', '1', '1', ARGV[1])", "1", "lk", "d"], "", command="VADD")
    plan.both(["EVAL", "return redis.call('VINFO', KEYS[1])", "1", "lk"], "", norm="vinfo", command="VINFO")
    plan.both(["EVAL", "return redis.call('VEMB', KEYS[1], 'a')", "1", "lk"], "", command="VEMB")
    plan.both(["EVAL", "redis.setresp(3); return redis.call('VEMB', KEYS[1], 'a')", "1", "lk"], "", command="VEMB")
    plan.both(["EVAL", "return redis.pcall('VSIM', KEYS[1], 'ELE', 'zz')", "1", "lk"], "error propagates", command="VSIM")
    plan.both(["EVAL", "return redis.call('VISMEMBER', KEYS[1], 'a')", "1", "lk"], "", command="VISMEMBER")
    plan.both(["EVAL", "redis.setresp(3); return redis.call('VISMEMBER', KEYS[1], 'a')", "1", "lk"], "", command="VISMEMBER")
    plan.both(["EVAL", "return redis.call('VSIM', KEYS[1], 'ELE', 'a', 'NOTHREAD')", "1", "lk"], "", norm="vsim", command="VSIM", inner=[b"VSIM", b"lk", b"ELE", b"a", b"NOTHREAD"])
    plan.both(["EVAL", "return redis.call('VSIM', KEYS[1], 'ELE', 'a')", "1", "lk"], "threaded VSIM inside a script", norm="vsim", command="VSIM", inner=[b"VSIM", b"lk", b"ELE", b"a"])
    plan.both(["EVAL", "return redis.call('VRANDMEMBER', KEYS[1], '-2')", "1", "lk"], "", norm="vrandmember", command="VRANDMEMBER", inner=[b"VRANDMEMBER", b"lk", b"-2"])
    plan.both(["EVAL", "return redis.call('VRANGE', KEYS[1], '-', '+')", "1", "lk"], "", command="VRANGE")
    for p in (2, 3):
        name = "m%d" % p
        plan.case(["MULTI"], "", p)
        plan.case(["VADD", "lk", "VALUES", "2", "1", "0", name], "", p, norm="exact")
        plan.case(["VSIM", "lk", "ELE", name, "WITHSCORES"], "", p, norm="exact")
        plan.case(["VISMEMBER", "lk", name], "", p)
        plan.case(["EXEC"], "transaction replies", p, norm="exec-vsim", command="EXEC", inner=[b"VSIM", b"lk", b"ELE", raw(name), b"WITHSCORES"], position=1)


SECTIONS = [("introspection", sec_introspection), ("variants", sec_variants), ("errors", sec_errors), ("semantics", sec_semantics), ("notifications", sec_notifications), ("lua", sec_lua)]


def sec_prepare(plan):
    plan.section = "prepare"
    plan.setup(["CONFIG", "SET", "notify-keyspace-events", ""])
    plan.setup(["CONFIG", "SET", "maxmemory-policy", "noeviction"])


def build(sections=None):
    plan = Plan()
    sec_prepare(plan)
    for name, fn in SECTIONS:
        if sections and name not in sections:
            continue
        fn(plan)
    plan.section = "end"
    plan.flush()
    return plan.steps
