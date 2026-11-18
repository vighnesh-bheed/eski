import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compare


def node(raw):
    connection = object.__new__(compare.wire.Conn)
    connection.buf = bytearray(raw)
    connection.pos = 0
    result = connection.node()
    if connection.pos != len(raw):
        raise ValueError("test reply has trailing bytes")
    return result


def normalized(argv, raw):
    return compare.normalize(argv, node(raw))[0]


class Normalizations(unittest.TestCase):
    def test_index_order_only(self):
        argv = [b"FT._LIST"]
        left = b"*2\r\n$1\r\nb\r\n$1\r\na\r\n"
        right = b"*2\r\n$1\r\na\r\n$1\r\nb\r\n"
        self.assertEqual(normalized(argv, left), normalized(argv, right))
        self.assertNotEqual(normalized(argv, left), normalized(argv, right.replace(b"$1\r\nb", b"+b")))

    def test_search_preserves_hit_order_and_field_values(self):
        argv = [b"FT.SEARCH", b"idx", b"*", b"RETURN", b"2", b"n", b"t"]
        left = b"*3\r\n:1\r\n$3\r\nkey\r\n*4\r\n+n\r\n:1\r\n+t\r\n$1\r\na\r\n"
        right = b"*3\r\n:1\r\n$3\r\nkey\r\n*4\r\n+t\r\n$1\r\na\r\n+n\r\n:1\r\n"
        self.assertEqual(normalized(argv, left), normalized(argv, right))
        for changed in (right.replace(b":1", b":2"), right.replace(b"key", b"new"), right.replace(b"$1\r\na", b"+a")):
            self.assertNotEqual(normalized(argv, left), normalized(argv, changed))

    def test_json_path_order_preserves_exact_value_bytes(self):
        argv = [b"JSON.GET", b"key", b"$.a", b"$.b"]

        def bulk(value):
            return b"$%d\r\n%s\r\n" % (len(value), value)

        left = bulk(b'{"$.a":[1.0],"$.b":[{"x":"y"}]}')
        right = bulk(b'{"$.b":[{"x":"y"}],"$.a":[1.0]}')
        self.assertEqual(normalized(argv, left), normalized(argv, right))
        self.assertNotEqual(normalized(argv, left), normalized(argv, bulk(b'{"$.b":[{"x":"y"}],"$.a":[1]}')))

    def test_cursor_timing_and_numeric_state(self):
        argv = [b"FT.CURSOR", b"READ", b"i", b"42"]
        left = b"*2\r\n*1\r\n:0\r\n:42\r\n"
        self.assertEqual(normalized(argv, left), normalized(argv, left.replace(b":42", b":213")))
        self.assertNotEqual(normalized(argv, left), normalized(argv, left.replace(b":42", b":0")))
        hybrid = [b"FT.HYBRID"]
        left = b"%2\r\n+execution_time\r\n,0.2\r\n+total_results\r\n:1\r\n"
        self.assertEqual(normalized(hybrid, left), normalized(hybrid, left.replace(b",0.2", b",0.3")))
        self.assertNotEqual(normalized(hybrid, left), normalized(hybrid, left.replace(b":1", b":2")))

    def test_limits_are_enforced_before_sending(self):
        accepted = [b"FT.SEARCH", b"idx", b"*=>[KNN $k @v $q]", b"PARAMS", b"2", b"k", b"1000"]
        compare.guard(accepted)
        with self.assertRaisesRegex(ValueError, "exceeds 1,000"):
            compare.guard([*accepted[:-1], b"1001"])
        with self.assertRaisesRegex(ValueError, "exceeds 1,000"):
            compare.guard([b"FT.AGGREGATE", b"idx", b"*", b"LIMIT", b"0", b"1024"])
        with self.assertRaisesRegex(ValueError, "subcommand"):
            compare.guard([b"CONFIG", b"SET", b"dir", b"/"])
        with self.assertRaisesRegex(ValueError, "script"):
            compare.guard([b"EVAL", b"return 1", b"0"])

    def test_expected_differences_check_both_replies_and_staleness(self):
        a, b, c = b"+OK\r\n", b"-Not supported\r\n", b"-Another error\r\n"
        entry = ("unsupported", "The module is unavailable.", {"eski": compare.digest(b), "redis": compare.digest(a)})
        case_id = "test/resp2/one"
        for left, right, expected_status in ((b, a, "listed"), (c, a, "unexpected"),
                                              (b, c, "unexpected"), (b, b, "stale")):
            report = {"exact": 0, "cases": []}
            checked = compare.Comparison(report, {case_id: entry}, True)
            checked.result("test", case_id, [b"FT.SUGLEN"], node(left), node(right))
            self.assertEqual(report["cases"][0]["status"], expected_status)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(checked.finish(), expected_status != "listed")
        report = {"exact": 0, "cases": []}
        checked = compare.Comparison(report, {case_id: entry}, True)
        self.assertTrue(checked.finish())
        self.assertEqual(report["missing_expected"], [case_id])

    def test_outputs_reject_existing_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            receipt = path / "receipt"
            receipt.write_text("original")
            with self.assertRaisesRegex(ValueError, "empty"):
                compare.output_directory(path, "unused")
            self.assertEqual(receipt.read_text(), "original")


def bulk(value):
    return b"$%d\r\n%s\r\n" % (len(value), value)


def flat(*items):
    return b"*%d\r\n" % len(items) + b"".join(items)


class ReferenceRepeatability(unittest.TestCase):
    def same(self, argv, left, right):
        self.assertEqual(normalized(argv, left), normalized(argv, right))

    def differ(self, argv, left, right):
        self.assertNotEqual(normalized(argv, left), normalized(argv, right))

    def test_command_inventories_ignore_order_only(self):
        argv = [b"COMMAND", b"LIST", b"FILTERBY", b"PATTERN", b"FT.*"]
        left, right = flat(bulk(b"FT.A"), bulk(b"FT.B")), flat(bulk(b"FT.B"), bulk(b"FT.A"))
        self.same(argv, left, right)
        self.differ(argv, left, flat(bulk(b"FT.B"), bulk(b"FT.C")))
        self.same([b"ACL", b"CAT", b"search"], left, right)

    def test_subcommand_entries_ignore_order_only(self):
        def info(*subcommands):
            entry = flat(bulk(b"ft.cursor"), b":-2\r\n", flat(), b":0\r\n", b":0\r\n", b":0\r\n", flat(), flat(), flat(),
                         flat(*subcommands))
            return flat(entry)
        one, two = flat(bulk(b"ft.cursor|read")), flat(bulk(b"ft.cursor|del"))
        self.same([b"COMMAND", b"INFO", b"FT.CURSOR"], info(one, two), info(two, one))
        self.differ([b"COMMAND", b"INFO", b"FT.CURSOR"], info(one, two), info(one, one))

    def test_index_figures_keep_names_types_and_non_numbers(self):
        argv = [b"FT.INFO", b"idx"]
        left = flat(bulk(b"num_docs"), b":3\r\n", bulk(b"inverted_sz_mb"), bulk(b"0.25"), bulk(b"gc_stats"),
                    flat(bulk(b"bytes_collected"), b":10\r\n"))
        right = left.replace(b"$4\r\n0.25", b"$4\r\n0.75").replace(b":10\r\n", b":99\r\n")
        self.same(argv, left, right)
        self.differ(argv, left, left.replace(b":3\r\n", b":4\r\n"))
        self.differ(argv, left, left.replace(b"$4\r\n0.25", b"$3\r\nnan"))

    def test_profile_masks_times_and_keeps_counters(self):
        argv = [b"FT.PROFILE", b"idx", b"SEARCH", b"QUERY", b"x"]
        left = flat(flat(b":1\r\n"), flat(bulk(b"Total profile time"), bulk(b"0.5"), bulk(b"Results processed"), b":1\r\n"))
        self.same(argv, left, left.replace(b"0.5", b"0.9"))
        self.differ(argv, left, left.replace(b"processed\r\n:1", b"processed\r\n:2"))

    def test_tolist_and_unsorted_groups_ignore_member_order(self):
        argv = [b"FT.AGGREGATE", b"idx", b"*", b"GROUPBY", b"1", b"@c", b"REDUCE", b"TOLIST", b"1", b"@y", b"AS", b"ys"]
        row = lambda *years: flat(bulk(b"c"), bulk(b"a"), bulk(b"ys"), flat(*map(bulk, years)))
        self.same(argv, flat(b":1\r\n", row(b"1", b"2")), flat(b":1\r\n", row(b"2", b"1")))
        self.differ(argv, flat(b":1\r\n", row(b"1", b"2")), flat(b":1\r\n", row(b"1", b"3")))
        groups = [b"FT.AGGREGATE", b"idx", b"*", b"GROUPBY", b"1", b"@c"]
        one, two = flat(bulk(b"c"), bulk(b"a")), flat(bulk(b"c"), bulk(b"b"))
        self.same(groups, flat(b":2\r\n", one, two), flat(b":2\r\n", two, one))
        self.differ(groups + [b"SORTBY", b"2", b"@c", b"ASC"], flat(b":2\r\n", one, two), flat(b":2\r\n", two, one))

    def test_distance_ties_reorder_only_equal_distances(self):
        argv = [b"FT.SEARCH", b"idx", b"*=>[KNN 3 @v $q AS d]", b"SORTBY", b"d", b"RETURN", b"1", b"d"]
        hit = lambda key, d: bulk(key) + flat(bulk(b"d"), bulk(d))
        reply = lambda *hits: b"*%d\r\n:%d\r\n" % (len(hits) * 2 + 1, len(hits)) + b"".join(hits)
        self.same(argv, reply(hit(b"a", b"1"), hit(b"b", b"1"), hit(b"c", b"2")),
                  reply(hit(b"b", b"1"), hit(b"a", b"1"), hit(b"c", b"2")))
        self.differ(argv, reply(hit(b"a", b"1"), hit(b"b", b"2")), reply(hit(b"b", b"2"), hit(b"a", b"1")))

    def test_hybrid_cursor_ids_are_masked(self):
        argv = [b"FT.HYBRID", b"idx", b"SEARCH", b"x", b"VSIM", b"@v", b"$q", b"WITHCURSOR"]
        left = flat(bulk(b"SEARCH"), b":12\r\n", bulk(b"VSIM"), b":34\r\n")
        self.same(argv, left, left.replace(b":12", b":56"))
        self.differ(argv, left, left.replace(b":34", b":0"))

    def test_unrepeatable_cases_never_pass_and_lost_replies_never_excuse(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "expected.json"
            path.write_text('{"categories": [{"id": "race", "reason": "a race on the reference", "unrepeatable": true,'
                            ' "cases": ["capture/resp2/7"]}]}')
            expected = compare.load_expected(path)
            path.write_text('{"categories": [{"id": "race", "reason": "r", "unrepeatable": false, "cases": ["capture/resp2/7"]}]}')
            with self.assertRaises(ValueError):
                compare.load_expected(path)
        for left, right, status in ((b"+A\r\n", b"+B\r\n", "unrepeatable"), (b"+A\r\n", b"+A\r\n", "passed")):
            report = {"exact": 0, "cases": []}
            checked = compare.Comparison(report, expected, True)
            checked.result("race", "capture/resp2/7", [b"FT.SEARCH"], node(left), node(right))
            self.assertEqual(report["cases"][0]["status"], status)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(checked.finish())
        a, b = b"+OK\r\n", b"-ERR x\r\n"
        entry = ("listed", "reviewed", {"eski": compare.digest(b""), "redis": compare.digest(a)})
        report = {"exact": 0, "cases": []}
        checked = compare.Comparison(report, {"capture/resp2/8": entry}, True)
        checked.lost = "no reply within the timeout"
        checked.result("s", "capture/resp2/8", [b"FT.PROFILE"], compare.wire.Node(b"-", b"", None, b""), node(a))
        self.assertEqual(report["cases"][0]["status"], "unexpected")
        self.assertEqual(report["lost_replies"], 1)


if __name__ == "__main__":
    unittest.main()
