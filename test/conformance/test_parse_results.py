import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import parse_results as pr


PASSING_RUN = """Cleanup: may take some time... OK
Starting test server at port 21079
[ready]: 443643
Testing unit/expire
[ok]: EXPIRE - set timeouts multiple times (1 ms)
[ok]: EXPIRE - It should be still possible to read 'x' (0 ms)
[ignore]: Not supported on external server
[ok]: SET with EX with big integer should report an error (0 ms)
[ok]: GETEX use of PERSIST option should remove TTL after loadaof (12 ms)
[ignore]: Not supported on external server
[skip]: PERSIST can undo an EXPIRE
[ignore]: EXPIRE with big negative integer: Tag: needs:debug denied
[ok]: Redis should actively expire keys incrementally (1) (1003 ms)
[1/1 done]: unit/expire (11 seconds)

                   The End

Execution time of different units:
  11 seconds - unit/expire

\\o/ All tests passed without errors!

Cleanup: may take some time... OK
"""

FAILING_RUN = """Cleanup: may take some time... OK
Starting test server at port 21079
[ready]: 429771
Testing unit/keyspace
[ok]: DEL against a single item (1 ms)
[ok]: Vararg DEL (0 ms)
[err]: DEL against expired key in tests/unit/keyspace.tcl
command not allowed. If the enable-debug-command option is set to "local", you can run it from a local connection.
ERR DEBUG command not allowed. If the enable-debug-command option is set to "local", you can run it from a local connection.
    while executing
"[srv $level "client"] {*}$args"
    (procedure "r" line 7)
    invoked from within
"r debug set-active-expire 0"
    ("uplevel" body line 2)
    invoked from within
"uplevel 1 $code"
[ok]: KEYS with pattern (0 ms)
[err]: COPY basic usage for $type set in tests/unit/keyspace.tcl
Expected 'listpack' to be equal to 'intset' (context: type eval line 9 cmd {assert_equal listpack [r object encoding set1{t}]} proc ::test)
[ok]: COPY basic usage for $type set (2 ms)
[err]: COPY basic usage for $type set in tests/unit/keyspace.tcl
Expected 'OK' to match '*WRONGTYPE*' (context: type eval line 3 cmd {assert_match *WRONGTYPE* $e} proc ::test)
[err]: LPOS basic usage in tests/unit/keyspace.tcl
n command 'lpos', with args beginning with: 'mylist' 'a'
ERR unknown command 'lpos', with args beginning with: 'mylist' 'a'
    while executing
"r lpos mylist a"
[1/1 done]: unit/keyspace (3 seconds)

                   The End

Execution time of different units:
  3 seconds - unit/keyspace

!!! WARNING The following tests failed:

*** [err]: DEL against expired key in tests/unit/keyspace.tcl
command not allowed. If the enable-debug-command option is set to "local", you can run it from a local connection.
ERR DEBUG command not allowed.
*** [err]: COPY basic usage for $type set in tests/unit/keyspace.tcl
Expected 'listpack' to be equal to 'intset'
*** [err]: COPY basic usage for $type set in tests/unit/keyspace.tcl
Expected 'OK' to match '*WRONGTYPE*'
*** [err]: LPOS basic usage in tests/unit/keyspace.tcl
n command 'lpos', with args beginning with: 'mylist' 'a'
Cleanup: may take some time... OK
"""

EXCEPTION_RUN = """Cleanup: may take some time... OK
Starting test server at port 21079
[ready]: 428531
\x1b[1;37;49mTesting unit/keyspace\x1b[0m
[\x1b[0;31;49mexception\x1b[0m]: Executing test client: ERR unknown command 'function', with args beginning with: 'flush'.
ERR unknown command 'function', with args beginning with: 'flush'
    while executing
"[srv $level "client"] {*}$args"
    (procedure "r" line 7)
    invoked from within
"r function flush"
    (procedure "run_external_server_test" line 25)
    invoked from within
"test_client_main $::test_server_port "
"""

BLOCK_ERROR_RUN = """Starting test server at port 21079
[ready]: 1
Testing unit/type/hash
[ok]: HSET basic (0 ms)
[err]: n command 'hrandfield', with args beginning with: 'myhash'
ERR unknown command 'hrandfield', with args beginning with: 'myhash'
    while executing
"r hrandfield myhash"
    ("uplevel" body line 4)
    invoked from within
"uplevel 2 $code"
[1/1 done]: unit/type/hash (1 seconds)

                   The End

Execution time of different units:
  1 seconds - unit/type/hash

!!! WARNING The following tests failed:

*** [err]: n command 'hrandfield', with args beginning with: 'myhash'
ERR unknown command 'hrandfield', with args beginning with: 'myhash'
Cleanup: may take some time... OK
"""

TIMEOUT_RUN = """Starting test server at port 21079
[ready]: 1
Testing unit/type/list
[ok]: LPUSH basics (0 ms)
[TIMEOUT]: clients state report follows.
sock55d2 => (IN PROGRESS) BLPOP with a single empty list
Killing still running Valkey server 4242

                   The End

Execution time of different units:

!!! WARNING The following tests failed:

*** [TIMEOUT]: BLPOP with a single empty list in tests/unit/type/list.tcl
Cleanup: may take some time... OK
"""


def write(path, text):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


class ParseLogTests(unittest.TestCase):
    def test_passing_run_counts(self):
        result = pr.parse_log(PASSING_RUN)
        self.assertEqual(result["passed"], 5)
        self.assertEqual(result["failed"], 0)
        self.assertEqual(result["skipped"], 4)
        self.assertEqual(result["skipped_by_tag"], 3)
        self.assertEqual(result["errored"], 0)
        self.assertTrue(result["ended"])
        self.assertTrue(result["all_passed_banner"])
        self.assertEqual(result["final_failed_count"], 0)

    def test_ok_names_keep_inner_parentheses(self):
        result = pr.parse_log(PASSING_RUN)
        self.assertIn("Redis should actively expire keys incrementally (1)", result["tests"])
        self.assertIn("EXPIRE - It should be still possible to read 'x'", result["tests"])

    def test_skip_and_named_ignore_are_recorded_per_test(self):
        result = pr.parse_log(PASSING_RUN)
        self.assertEqual(result["tests"]["PERSIST can undo an EXPIRE"]["skipped"], 1)
        self.assertEqual(result["tests"]["EXPIRE with big negative integer"]["skipped"], 1)

    def test_failing_run_counts_and_names(self):
        result = pr.parse_log(FAILING_RUN)
        self.assertEqual(result["passed"], 4)
        self.assertEqual(result["failed"], 4)
        self.assertEqual(result["errored"], 0)
        self.assertEqual(result["final_failed_count"], 4)
        names = [f["test"] for f in result["failures"]]
        self.assertEqual(names, [
            "DEL against expired key",
            "COPY basic usage for $type set",
            "COPY basic usage for $type set",
            "LPOS basic usage",
        ])

    def test_duplicate_names_are_counted(self):
        result = pr.parse_log(FAILING_RUN)
        self.assertEqual(result["tests"]["COPY basic usage for $type set"], {"passed": 1, "failed": 2, "skipped": 0})

    def test_durable_errors_use_the_full_error_text(self):
        result = pr.parse_log(FAILING_RUN)
        reasons = {f["test"]: f["reason"] for f in result["failures"]}
        self.assertTrue(reasons["DEL against expired key"].startswith("ERR DEBUG command not allowed."))
        self.assertTrue(reasons["LPOS basic usage"].startswith("ERR unknown command 'lpos'"))

    def test_durable_error_cut_inside_a_word_boundary(self):
        details = [" error", "ERR syntax error", "    while executing", "\"r set foo new ifeq old\""]
        self.assertEqual(pr.error_reason(details), "ERR syntax error")

    def test_assertion_reason_drops_context(self):
        result = pr.parse_log(FAILING_RUN)
        reasons = [f["reason"] for f in result["failures"] if f["test"].startswith("COPY")]
        self.assertEqual(reasons, [
            "Expected 'listpack' to be equal to 'intset'",
            "Expected 'OK' to match '*WRONGTYPE*'",
        ])

    def test_exception_with_ansi_colours(self):
        result = pr.parse_log(EXCEPTION_RUN)
        self.assertTrue(result["exception"])
        self.assertFalse(result["ended"])
        self.assertEqual(result["passed"], 0)
        self.assertEqual(result["errored"], 1)
        self.assertEqual(len(result["errors"]), 1)
        error = result["errors"][0]
        self.assertEqual(error["kind"], "exception")
        self.assertIn("unknown command 'function'", error["reason"])
        self.assertIn("r function flush", error["message"])
        self.assertEqual(pr.reason_key(error["reason"]), "unknown command 'function'")

    def test_block_level_error_is_errored_not_failed(self):
        result = pr.parse_log(BLOCK_ERROR_RUN)
        self.assertEqual(result["passed"], 1)
        self.assertEqual(result["failed"], 0)
        self.assertEqual(result["errored"], 1)
        self.assertEqual(result["errors"][0]["kind"], "block")
        self.assertTrue(result["errors"][0]["reason"].startswith("ERR unknown command 'hrandfield'"))
        self.assertEqual(result["final_failed_count"], 1)

    def test_timeout_names_the_stuck_test(self):
        result = pr.parse_log(TIMEOUT_RUN)
        self.assertTrue(result["timeout"])
        self.assertEqual(result["passed"], 1)
        self.assertEqual(result["failed"], 1)
        self.assertEqual(result["tests"]["BLPOP with a single empty list"]["failed"], 1)
        self.assertEqual(result["failures"][0]["reason"], "timeout")
        self.assertEqual(result["errored"], 1)


class ReasonKeyTests(unittest.TestCase):
    def test_unknown_command_is_lowercased(self):
        self.assertEqual(pr.reason_key("ERR unknown command 'LPUSH', with args beginning with: 'a'"), "unknown command 'lpush'")

    def test_unknown_subcommand(self):
        self.assertEqual(pr.reason_key("ERR unknown subcommand 'freq'. Try OBJECT HELP."), "unknown subcommand 'OBJECT freq'")

    def test_wrong_arity(self):
        self.assertEqual(pr.reason_key("ERR wrong number of arguments for 'set' command"), "wrong number of arguments for 'set'")

    def test_values_and_numbers_are_masked(self):
        self.assertEqual(pr.reason_key("Expected '12' to be equal to '7'"), "Expected '...' to be equal to '...'")


class KnownFailuresTests(unittest.TestCase):
    KNOWN = "scripting\n\ncluster/*\nintegration/*\nkeyspace::COPY for string can replace an existing key with REPLACE option\nunit/type/list::LPOS basic usage\n"

    def test_parse_known(self):
        known = pr.parse_known(self.KNOWN)
        self.assertEqual(known["units"], ["unit/scripting", "unit/cluster/*", "integration/*"])
        self.assertEqual(known["tests"], [
            ("unit/keyspace", "COPY for string can replace an existing key with REPLACE option"),
            ("unit/type/list", "LPOS basic usage"),
        ])

    def test_unit_matching_supports_globs(self):
        known = pr.parse_known(self.KNOWN)
        self.assertTrue(pr.unit_is_known(known, "unit/scripting"))
        self.assertTrue(pr.unit_is_known(known, "unit/cluster/slot-stats"))
        self.assertTrue(pr.unit_is_known(known, "integration/replication-2"))
        self.assertFalse(pr.unit_is_known(known, "unit/keyspace"))

    def test_known_tests(self):
        known = pr.parse_known(self.KNOWN)
        self.assertTrue(pr.test_is_known(known, "unit/type/list", "LPOS basic usage"))
        self.assertFalse(pr.test_is_known(known, "unit/type/list", "LPOS no match"))

    def test_canonical_names(self):
        self.assertEqual(pr.canonical_unit("keyspace"), "unit/keyspace")
        self.assertEqual(pr.canonical_unit("type/string"), "unit/type/string")
        self.assertEqual(pr.canonical_unit("unit/type/string"), "unit/type/string")
        self.assertEqual(pr.canonical_unit("tests/unit/info.tcl"), "unit/info")
        self.assertEqual(pr.canonical_unit("integration/rdb"), "integration/rdb")
        self.assertEqual(pr.display_unit("unit/type/string"), "type/string")
        self.assertEqual(pr.display_unit("integration/rdb"), "integration/rdb")

    def test_relative_paths_stay_absolute_outside_the_root(self):
        self.assertEqual(pr.relative("/repo/test/conformance/results/latest.json", "/repo"), "test/conformance/results/latest.json")
        self.assertEqual(pr.relative("/tmp/baseline.json", "/repo"), "/tmp/baseline.json")
        self.assertEqual(pr.relative("/repository/x.json", "/repo"), "/repository/x.json")

    def test_plan(self):
        with tempfile.TemporaryDirectory() as tree:
            for unit in ("unit/keyspace", "unit/scripting", "unit/type/list"):
                path = os.path.join(tree, "tests", unit + ".tcl")
                os.makedirs(os.path.dirname(path), exist_ok=True)
                write(path, "")
            known = pr.parse_known(self.KNOWN)
            lines, problems = pr.plan(tree, known, ["keyspace", "scripting", "type/list", "keyspace", "nope"])
            self.assertEqual(problems, ["unknown unit 'nope': tests/unit/nope.tcl does not exist in the pinned suite"])
            self.assertEqual(lines, [
                "run\tunit/keyspace\tkeyspace",
                "test\tunit/keyspace\tCOPY for string can replace an existing key with REPLACE option",
                "skip\tunit/scripting\tscripting",
                "run\tunit/type/list\ttype/list",
                "test\tunit/type/list\tLPOS basic usage",
            ])


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.logs = os.path.join(self.root, "logs")
        os.makedirs(self.logs)
        write(os.path.join(self.logs, "expire.log"), PASSING_RUN)
        write(os.path.join(self.logs, "keyspace.log"), FAILING_RUN)
        write(os.path.join(self.logs, "hash.log"), EXCEPTION_RUN)
        self.meta = os.path.join(self.logs, "units.tsv")
        write(self.meta, "".join([
            "unit/expire\trun\t0\t11\t%s\t0\t0\n" % os.path.join(self.logs, "expire.log"),
            "unit/keyspace\trun\t1\t3\t%s\t0\t0\n" % os.path.join(self.logs, "keyspace.log"),
            "unit/type/hash\trun\t1\t0\t%s\t0\t0\n" % os.path.join(self.logs, "hash.log"),
            "unit/scripting\tskip\t\t0\t\t0\t0\n",
        ]))
        self.rows = pr.read_meta(self.meta)
        self.info = {"tags": "-slow"}

    def tearDown(self):
        self.tmp.cleanup()

    def summary(self, known_text="scripting\n", baseline=None):
        return pr.build_summary(self.rows, pr.parse_known(known_text), self.root, self.info, baseline, "baseline.json")

    def test_units_and_totals(self):
        summary = self.summary()
        units = summary["units"]
        self.assertEqual(list(units), ["expire", "keyspace", "type/hash", "scripting"])
        self.assertEqual(units["expire"]["status"], "ok")
        self.assertEqual(units["keyspace"]["status"], "failed")
        self.assertEqual(units["type/hash"]["status"], "exception")
        self.assertEqual(units["scripting"]["status"], "out-of-scope")
        self.assertEqual(units["keyspace"]["log"], os.path.join("logs", "keyspace.log"))
        self.assertEqual(summary["totals"]["passed"], 9)
        self.assertEqual(summary["totals"]["failed"], 4)
        self.assertEqual(summary["totals"]["errored"], 1)
        self.assertEqual(summary["totals"]["units_run"], 3)
        self.assertEqual(summary["totals"]["units_out_of_scope"], 1)
        self.assertEqual(units["keyspace"]["warnings"], [])
        json.dumps(summary)

    def test_strict_mode_fails_on_unexpected(self):
        summary = self.summary()
        self.assertEqual(summary["mode"], "strict")
        self.assertEqual(summary["exit_code"], 1)
        self.assertIn("keyspace::LPOS basic usage", summary["unexpected_failures"])
        self.assertTrue(any(item.startswith("type/hash::<exception>") for item in summary["unexpected_failures"]))

    def test_strict_mode_ignores_known_tests(self):
        known = "scripting\nkeyspace::DEL against expired key\n"
        summary = self.summary(known)
        self.assertNotIn("keyspace::DEL against expired key", summary["unexpected_failures"])
        self.assertEqual(summary["units"]["keyspace"]["known_failing_tests"], ["DEL against expired key"])

    def test_strict_mode_passes_when_everything_passes(self):
        rows = [r for r in self.rows if r["canonical"] in ("unit/expire", "unit/scripting")]
        summary = pr.build_summary(rows, pr.parse_known("scripting\n"), self.root, self.info)
        self.assertEqual(summary["exit_code"], 0)

    def test_baseline_mode_without_regressions(self):
        baseline = json.loads(json.dumps(self.summary()))
        summary = self.summary(baseline=baseline)
        self.assertEqual(summary["mode"], "baseline")
        self.assertEqual(summary["baseline"]["regressions"], [])
        self.assertEqual(summary["exit_code"], 0)
        self.assertEqual(summary["baseline"]["baseline_passed"], summary["baseline"]["current_passed"])

    def test_baseline_mode_reports_a_test_that_stopped_passing(self):
        baseline = json.loads(json.dumps(self.summary()))
        baseline["units"]["keyspace"]["tests"]["LPOS basic usage"] = {"passed": 1, "failed": 0, "skipped": 0}
        baseline["units"]["type/hash"]["tests"]["HSET basic"] = {"passed": 1, "failed": 0, "skipped": 0}
        summary = self.summary(baseline=baseline)
        self.assertEqual(summary["exit_code"], 1)
        regressions = {(r["unit"], r["test"]): r["now"] for r in summary["baseline"]["regressions"]}
        self.assertEqual(regressions, {("keyspace", "LPOS basic usage"): "failed", ("type/hash", "HSET basic"): "not run"})

    def test_baseline_mode_catches_fewer_passes_of_a_repeated_name(self):
        baseline = json.loads(json.dumps(self.summary()))
        baseline["units"]["keyspace"]["tests"]["COPY basic usage for $type set"]["passed"] = 3
        summary = self.summary(baseline=baseline)
        self.assertEqual([r["test"] for r in summary["baseline"]["regressions"]], ["COPY basic usage for $type set"])

    def test_baseline_mode_reports_newly_passing(self):
        baseline = json.loads(json.dumps(self.summary()))
        baseline["units"]["expire"]["tests"]["Vararg DEL"] = {"passed": 0, "failed": 1, "skipped": 0}
        del baseline["units"]["expire"]["tests"]["EXPIRE - set timeouts multiple times"]
        summary = self.summary(baseline=baseline)
        self.assertEqual(summary["exit_code"], 0)
        self.assertIn("expire::EXPIRE - set timeouts multiple times", summary["baseline"]["newly_passing"])

    def test_baseline_ignores_units_not_run_now(self):
        baseline = json.loads(json.dumps(self.summary()))
        baseline["units"]["type/zset"] = {"passed": 5, "tests": {"ZADD basic": {"passed": 5, "failed": 0, "skipped": 0}}}
        summary = self.summary(baseline=baseline)
        self.assertEqual(summary["exit_code"], 0)
        self.assertNotIn("type/zset", summary["baseline"]["units_compared"])

    def test_unit_with_only_skips_is_all_skipped(self):
        path = os.path.join(self.logs, "auth.log")
        write(path, "Testing unit/auth\n[ignore]: Not supported on external server\n[1/1 done]: unit/auth (0 seconds)\n\n                   The End\n\n\\o/ All tests passed without errors!\n")
        rows = [{"canonical": "unit/auth", "action": "run", "rc": 0, "seconds": 0, "log": path, "server_crashed": False, "killed": False}]
        summary = pr.build_summary(rows, pr.parse_known(""), self.root, self.info)
        self.assertEqual(summary["units"]["auth"]["status"], "all-skipped")
        self.assertEqual(summary["units"]["auth"]["skipped"], 1)
        self.assertEqual(summary["exit_code"], 0)

    def test_server_crash_and_hard_timeout_are_errors(self):
        rows = pr.read_meta(self.meta)
        rows[0]["server_crashed"] = True
        rows[1]["killed"] = True
        summary = pr.build_summary(rows, pr.parse_known("scripting\n"), self.root, self.info)
        self.assertEqual(summary["units"]["expire"]["status"], "server-crashed")
        self.assertEqual(summary["units"]["keyspace"]["status"], "timeout")
        self.assertEqual(summary["exit_code"], 1)

    def test_render_report(self):
        summary = self.summary()
        text = pr.render_report(summary, "results/latest.json")
        self.assertIn("keyspace", text)
        self.assertIn("Mode: strict", text)
        self.assertIn("Result: FAIL (exit 1)", text)
        header = text.splitlines()[0].split()
        self.assertEqual(header, ["unit", "passed", "failed", "skipped", "errored", "status", "secs"])

    def test_summarize_command_writes_files(self):
        known = os.path.join(self.root, "known.txt")
        write(known, "scripting\n")
        out = os.path.join(self.root, "results", "summary.json")
        latest = os.path.join(self.root, "results", "latest.json")
        extra = os.path.join(self.root, "extra.json")
        devnull = open(os.devnull, "w")
        stdout = sys.stdout
        sys.stdout = devnull
        try:
            code = pr.main(["summarize", "--meta", self.meta, "--known", known, "--root", self.root,
                            "--out", out, "--latest", latest, "--extra", extra, "--tags=-slow"])
        finally:
            sys.stdout = stdout
            devnull.close()
        self.assertEqual(code, 1)
        for path in (out, latest, extra):
            with open(path, encoding="utf-8") as handle:
                data = json.load(handle)
            self.assertEqual(data["suite"]["tags"], "-slow")
            self.assertEqual(data["totals"]["passed"], 9)


class SuitePrefixTests(unittest.TestCase):
    KNOWN = (
        "scripting\n"
        "redis:aofrw\n"
        "valkey:commandlog\n"
        "expire::SET - use KEEPTTL option, TTL should not be removed after loadaof\n"
        "redis:expire::Redis should not propagate the read command on lazy expire\n"
        "valkey:expire::Server should not propagate the read command on lazy expire\n"
        "valkey:slowlog::SLOWLOG - the commands in script are recorded normally - is_eval: 0\n"
        "  valkey: bitops::BITCOUNT with just start  \n"
    )

    def test_unprefixed_entries_apply_to_every_suite(self):
        for suite in ("redis", "valkey"):
            known = pr.parse_known(self.KNOWN, suite)
            self.assertTrue(pr.unit_is_known(known, "unit/scripting"))
            self.assertTrue(pr.test_is_known(known, "unit/expire", "SET - use KEEPTTL option, TTL should not be removed after loadaof"))
            self.assertEqual(known["problems"], [])

    def test_redis_prefix_applies_to_the_redis_suite_only(self):
        known = pr.parse_known(self.KNOWN, "redis")
        self.assertEqual(known["units"], ["unit/scripting", "unit/aofrw"])
        self.assertEqual(pr.known_tests_for(known, "unit/expire"), [
            "SET - use KEEPTTL option, TTL should not be removed after loadaof",
            "Redis should not propagate the read command on lazy expire",
        ])
        self.assertEqual(pr.known_tests_for(known, "unit/bitops"), [])
        self.assertEqual(pr.known_tests_for(known, "unit/slowlog"), [])

    def test_valkey_prefix_applies_to_the_valkey_suite_only(self):
        known = pr.parse_known(self.KNOWN, "valkey")
        self.assertEqual(known["units"], ["unit/scripting", "unit/commandlog"])
        self.assertEqual(pr.known_tests_for(known, "unit/expire"), [
            "SET - use KEEPTTL option, TTL should not be removed after loadaof",
            "Server should not propagate the read command on lazy expire",
        ])
        self.assertEqual(pr.known_tests_for(known, "unit/bitops"), ["BITCOUNT with just start"])
        self.assertEqual(pr.known_tests_for(known, "unit/slowlog"), [
            "SLOWLOG - the commands in script are recorded normally - is_eval: 0",
        ])

    def test_prefixed_entries_need_a_suite(self):
        known = pr.parse_known(self.KNOWN)
        self.assertEqual(known["units"], ["unit/scripting"])
        self.assertEqual(len(known["tests"]), 1)

    def test_colons_in_unit_or_test_names_are_not_prefixes(self):
        known = pr.parse_known("tests/unit/info.tcl::a: b\nintrospection-2::x: y\nunit/type/list::LPOS: z\n", "redis")
        self.assertEqual(known["problems"], [])
        self.assertEqual(known["tests"], [
            ("unit/info", "a: b"),
            ("unit/introspection-2", "x: y"),
            ("unit/type/list", "LPOS: z"),
        ])

    def test_unknown_or_empty_prefix_is_a_problem(self):
        known = pr.parse_known("keyspace\nvalky:bitops::BITCOUNT with just start\nredis:\n", "valkey")
        self.assertEqual(known["units"], ["unit/keyspace"])
        self.assertEqual(len(known["problems"]), 2)
        self.assertIn("line 2: unknown suite prefix 'valky:'", known["problems"][0])
        self.assertIn("line 3: 'redis:' is not followed", known["problems"][1])

    def test_plan_rejects_a_bad_known_failures_file(self):
        with tempfile.TemporaryDirectory() as tree:
            path = os.path.join(tree, "tests", "unit", "keyspace.tcl")
            os.makedirs(os.path.dirname(path))
            write(path, "")
            lines, problems = pr.plan(tree, pr.parse_known("valky:keyspace\n", "redis"), ["keyspace"])
            self.assertEqual(lines, ["run\tunit/keyspace\tkeyspace"])
            self.assertEqual(len(problems), 1)
            self.assertTrue(problems[0].startswith("known failures line 1: unknown suite prefix"))

    def test_plan_command_filters_by_suite(self):
        with tempfile.TemporaryDirectory() as tree:
            for unit in ("unit/bitops", "unit/aofrw"):
                path = os.path.join(tree, "tests", unit + ".tcl")
                os.makedirs(os.path.dirname(path), exist_ok=True)
                write(path, "")
            known = os.path.join(tree, "known.txt")
            write(known, self.KNOWN)
            outputs = {}
            for suite in ("redis", "valkey"):
                out = os.path.join(tree, suite + ".out")
                stdout = sys.stdout
                with open(out, "w", encoding="utf-8") as handle:
                    sys.stdout = handle
                    try:
                        code = pr.main(["plan", "--tree", tree, "--known", known, "--units", "bitops,aofrw", "--suite", suite])
                    finally:
                        sys.stdout = stdout
                self.assertEqual(code, 0)
                with open(out, encoding="utf-8") as handle:
                    outputs[suite] = handle.read().splitlines()
            self.assertEqual(outputs["redis"], ["run\tunit/bitops\tbitops", "skip\tunit/aofrw\taofrw"])
            self.assertEqual(outputs["valkey"], [
                "run\tunit/bitops\tbitops",
                "test\tunit/bitops\tBITCOUNT with just start",
                "run\tunit/aofrw\taofrw",
            ])


class SuiteIdentityTests(unittest.TestCase):
    REDIS = {"suite": {"name": "redis", "tag": "7.4.11", "sha256": "abc", "tags": "-needs:repl"}, "units": {}}
    VALKEY = {"suite": {"name": "valkey", "tag": "8.1.10", "sha256": "def", "tags": "-needs:repl"}, "units": {}}
    VALKEY_TAG_KEYS = {"suite": {"valkey_tag": "8.1.10", "valkey_sha256": "def", "tags": "-needs:repl"}, "units": {}}

    def test_identity(self):
        self.assertEqual(pr.suite_identity(self.REDIS), ("redis", "7.4.11"))
        self.assertEqual(pr.suite_identity(self.VALKEY), ("valkey", "8.1.10"))
        self.assertEqual(pr.suite_identity(self.VALKEY_TAG_KEYS), ("valkey", "8.1.10"))
        self.assertEqual(pr.suite_identity({"suite": {"tags": ""}}), (None, None))
        self.assertEqual(pr.suite_identity({}), (None, None))
        self.assertEqual(pr.suite_identity([]), (None, None))

    def test_same_suite_baseline_is_accepted(self):
        self.assertIsNone(pr.baseline_problem(self.REDIS, "b.json", "redis", "7.4.11"))
        self.assertIsNone(pr.baseline_problem(self.VALKEY, "b.json", "valkey", "8.1.10"))
        self.assertIsNone(pr.baseline_problem(self.VALKEY_TAG_KEYS, "b.json", "valkey", "8.1.10"))
        self.assertIsNone(pr.baseline_problem(self.REDIS, "b.json", "redis", "7.4.12"))

    def test_cross_suite_baseline_is_refused(self):
        problem = pr.baseline_problem(self.VALKEY, "baseline-valkey.json", "redis", "7.4.11")
        self.assertIn("baseline-valkey.json was recorded with the valkey 8.1.10 suite", problem)
        self.assertIn("this run uses the redis 7.4.11 suite", problem)
        self.assertIn("baseline-redis.json", problem)
        self.assertIsNotNone(pr.baseline_problem(self.VALKEY_TAG_KEYS, "b.json", "redis", "7.4.11"))
        self.assertIsNotNone(pr.baseline_problem(self.REDIS, "b.json", "valkey", "8.1.10"))

    def test_baseline_without_a_suite_is_refused(self):
        problem = pr.baseline_problem({"suite": {"tags": ""}, "units": {}}, "old.json", "redis", "7.4.11")
        self.assertIn("does not record which suite produced it", problem)


class SuiteSummaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        logs = os.path.join(self.root, "logs")
        os.makedirs(logs)
        write(os.path.join(logs, "expire.log"), PASSING_RUN)
        self.meta = os.path.join(logs, "units.tsv")
        write(self.meta, "unit/expire\trun\t0\t11\t%s\t0\t0\n" % os.path.join(logs, "expire.log"))
        self.known = os.path.join(self.root, "known.txt")
        write(self.known, "valkey:expire::PERSIST can undo an EXPIRE\n")
        self.results = os.path.join(self.root, "results")

    def tearDown(self):
        self.tmp.cleanup()

    def summarize(self, suite, tag, extra=()):
        latest = os.path.join(self.results, "latest-%s.json" % suite)
        args = ["summarize", "--meta", self.meta, "--known", self.known, "--root", self.root,
                "--out", os.path.join(self.results, "summary-%s.json" % suite), "--latest", latest,
                "--extra", os.path.join(self.results, "latest.json"),
                "--suite-name", suite, "--suite-tag", tag, "--suite-sha256", "f00d", "--suite-url", "https://example.invalid/x.tar.gz",
                "--tags=-needs:repl"] + list(extra)
        devnull = open(os.devnull, "w")
        stdout, stderr = sys.stdout, sys.stderr
        sys.stdout = sys.stderr = devnull
        try:
            code = pr.main(args)
        finally:
            sys.stdout, sys.stderr = stdout, stderr
            devnull.close()
        return code, latest

    def load(self, path):
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)

    def test_summary_records_the_suite(self):
        code, latest = self.summarize("redis", "7.4.11")
        self.assertEqual(code, 0)
        data = self.load(latest)
        self.assertEqual(data["schema"], 2)
        self.assertEqual(data["suite"]["name"], "redis")
        self.assertEqual(data["suite"]["tag"], "7.4.11")
        self.assertEqual(data["suite"]["sha256"], "f00d")
        self.assertEqual(data["suite"]["tags"], "-needs:repl")
        self.assertEqual(data["suite"]["external_skip_lifted"], "")
        self.assertEqual(self.load(os.path.join(self.results, "latest.json")), data)

    def test_summary_records_lifted_external_skips(self):
        code, latest = self.summarize("redis", "7.4.11", ["--external-skip-lifted", "tests/unit/type/hash-field-expire.tcl:59,886,998"])
        data = self.load(latest)
        self.assertEqual(data["suite"]["external_skip_lifted"], "tests/unit/type/hash-field-expire.tcl:59,886,998")
        text = pr.render_report(data, "latest-redis.json")
        self.assertIn("external:skip lifted at tests/unit/type/hash-field-expire.tcl:59,886,998.", text)

    def test_same_suite_baseline_compares(self):
        code, latest = self.summarize("redis", "7.4.11")
        baseline = os.path.join(self.root, "baseline-redis.json")
        os.replace(latest, baseline)
        code, latest = self.summarize("redis", "7.4.11", ["--baseline", baseline])
        self.assertEqual(code, 0)
        data = self.load(latest)
        self.assertEqual(data["mode"], "baseline")
        self.assertEqual(data["baseline"]["baseline_suite"], {"name": "redis", "tag": "7.4.11"})
        self.assertEqual(data["baseline"]["regressions"], [])

    def test_cross_suite_baseline_is_refused_without_writing(self):
        code, latest = self.summarize("valkey", "8.1.10")
        baseline = os.path.join(self.root, "baseline-valkey.json")
        os.replace(latest, baseline)
        os.remove(os.path.join(self.results, "latest.json"))
        code, latest = self.summarize("redis", "7.4.11", ["--baseline", baseline])
        self.assertEqual(code, 2)
        self.assertFalse(os.path.exists(latest))
        self.assertFalse(os.path.exists(os.path.join(self.results, "latest.json")))

    def test_check_baseline_command(self):
        baseline = os.path.join(self.root, "b.json")
        write(baseline, json.dumps(SuiteIdentityTests.VALKEY))
        devnull = open(os.devnull, "w")
        stderr = sys.stderr
        sys.stderr = devnull
        try:
            refused = pr.main(["check-baseline", "--baseline", baseline, "--root", self.root, "--suite-name", "redis", "--suite-tag", "7.4.11"])
            accepted = pr.main(["check-baseline", "--baseline", baseline, "--root", self.root, "--suite-name", "valkey", "--suite-tag", "8.1.10"])
            unreadable = pr.main(["check-baseline", "--baseline", baseline + ".missing", "--root", self.root, "--suite-name", "redis"])
        finally:
            sys.stderr = stderr
            devnull.close()
        self.assertEqual((refused, accepted, unreadable), (2, 0, 2))

    def test_prefixed_known_failures_follow_the_suite(self):
        log = os.path.join(self.root, "logs", "keyspace.log")
        write(log, FAILING_RUN)
        with open(self.meta, "a", encoding="utf-8") as handle:
            handle.write("unit/keyspace\trun\t1\t3\t%s\t0\t0\n" % log)
        write(self.known, "keyspace::DEL against expired key\nkeyspace::COPY basic usage for $type set\nvalkey:keyspace::LPOS basic usage\n")
        self.assertEqual(self.summarize("redis", "7.4.11")[0], 1)
        self.assertEqual(self.summarize("valkey", "8.1.10")[0], 0)
        redis = self.load(os.path.join(self.results, "latest-redis.json"))
        valkey = self.load(os.path.join(self.results, "latest-valkey.json"))
        self.assertEqual(redis["unexpected_failures"], ["keyspace::LPOS basic usage"])
        self.assertEqual(valkey["unexpected_failures"], [])
        self.assertEqual(valkey["units"]["keyspace"]["known_failing_tests"], [
            "DEL against expired key", "COPY basic usage for $type set", "LPOS basic usage"])
        self.assertEqual(self.load(os.path.join(self.results, "latest.json"))["suite"]["name"], "valkey")

    def test_report_names_the_suites(self):
        rows = pr.read_meta(self.meta)
        info = {"name": "redis", "tag": "7.4.11", "sha256": "f00d", "tags": "-needs:repl"}
        strict = pr.build_summary(rows, pr.parse_known("", "redis"), self.root, info)
        text = pr.render_report(strict, "results/latest-redis.json")
        self.assertIn("Suite: the redis 7.4.11 suite, tarball sha256 f00d.", text)
        self.assertEqual(text.splitlines()[0].split()[0], "unit")
        baseline = json.loads(json.dumps(strict))
        baseline["suite"]["tag"] = "7.4.10"
        compared = pr.build_summary(rows, pr.parse_known("", "redis"), self.root, info, baseline, "baseline-redis.json")
        text = pr.render_report(compared, "results/latest-redis.json")
        self.assertIn("passed in baseline-redis.json, recorded with the redis 7.4.10 suite, does not pass now", text)
        self.assertIn("Warning: the baseline was recorded with redis 7.4.10 and this run used redis 7.4.11.", text)

    def test_valkey_baseline_with_valkey_tag_keys_compares(self):
        rows = pr.read_meta(self.meta)
        info = {"name": "valkey", "tag": "8.1.10", "sha256": "def", "tags": "-needs:repl"}
        current = pr.build_summary(rows, pr.parse_known("", "valkey"), self.root, info)
        keyed = json.loads(json.dumps(current))
        keyed["suite"] = {"valkey_tag": "8.1.10", "valkey_sha256": "def", "tags": "-needs:repl"}
        compared = pr.build_summary(rows, pr.parse_known("", "valkey"), self.root, info, keyed, "baseline-valkey.json")
        self.assertEqual(compared["baseline"]["baseline_suite"], {"name": "valkey", "tag": "8.1.10"})
        self.assertEqual(compared["exit_code"], 0)
        text = pr.render_report(compared, "results/latest-valkey.json")
        self.assertNotIn("Warning", text)


if __name__ == "__main__":
    unittest.main()
