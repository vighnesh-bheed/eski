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


if __name__ == "__main__":
    unittest.main()
