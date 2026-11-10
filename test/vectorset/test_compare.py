import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cases
import compare


def parse(data):
    conn = compare.Conn.__new__(compare.Conn)
    conn.buf = bytearray(data)
    conn.pos = 0
    conn.sock = None
    return conn.node()


class FakeContext:
    def __init__(self, argv, replies=None, **extra):
        self.step = {"argv": [cases.raw(a) for a in argv]}
        self.step.update(extra)
        self.replies = replies or {}
        self.probes = []

    def probe(self, argv):
        self.probes.append(argv)
        key = b" ".join(argv)
        for prefix, reply in self.replies.items():
            if key.startswith(prefix):
                return parse(reply)
        return parse(b"-ERR no canned reply\r\n")


def bulk(*names):
    return b"".join(b"$%d\r\n%s\r\n" % (len(n), n) for n in names)


class VsimTests(unittest.TestCase):
    def test_tied_names_are_sorted_with_scores_from_the_probe(self):
        probe = b"*8\r\n" + bulk(b"a", b"1", b"d", b"0.85", b"c", b"0.85", b"b", b"0.5")
        ctx = FakeContext(["VSIM", "k", "ELE", "a"], {b"VSIM k ELE a WITHSCORES COUNT 5": probe})
        one = compare.norm_vsim(parse(b"*4\r\n" + bulk(b"a", b"d", b"c", b"b")), ctx)
        two = compare.norm_vsim(parse(b"*4\r\n" + bulk(b"a", b"c", b"d", b"b")), ctx)
        self.assertEqual(one, two)
        self.assertNotEqual(one, compare.norm_vsim(parse(b"*4\r\n" + bulk(b"a", b"b", b"c", b"d")), ctx))

    def test_resp3_scores_come_from_the_map(self):
        reply_one = b"%3\r\n$1\r\na\r\n,1\r\n$1\r\nd\r\n,0.5\r\n$1\r\nc\r\n,0.5\r\n"
        reply_two = b"%3\r\n$1\r\na\r\n,1\r\n$1\r\nc\r\n,0.5\r\n$1\r\nd\r\n,0.5\r\n"
        ctx = FakeContext(["VSIM", "k", "VALUES", "2", "1", "0", "WITHSCORES"])
        self.assertEqual(compare.norm_vsim(parse(reply_one), ctx), compare.norm_vsim(parse(reply_two), ctx))
        self.assertEqual(ctx.probes, [])

    def test_a_cut_tie_group_compares_by_size_and_score(self):
        probe = b"*6\r\n" + bulk(b"x", b"1", b"y", b"1", b"z", b"1")
        ctx = FakeContext(["VSIM", "k", "ELE", "x", "COUNT", "2", "WITHSCORES"], {b"VSIM k ELE x COUNT 2 WITHSCORES WITHSCORES COUNT 3": probe})
        one = compare.norm_vsim(parse(b"*4\r\n" + bulk(b"x", b"1", b"y", b"1")), ctx)
        two = compare.norm_vsim(parse(b"*4\r\n" + bulk(b"z", b"1", b"x", b"1")), ctx)
        self.assertEqual(one, two)
        self.assertIn(b"<2 of a tie group at score 1>", one)

    def test_truth_and_errors_stay_exact(self):
        ctx = FakeContext(["VSIM", "k", "ELE", "a", "TRUTH"])
        raw = b"*2\r\n" + bulk(b"b", b"a")
        self.assertEqual(compare.norm_vsim(parse(raw), ctx), raw)
        error = b"-ERR element not found in set\r\n"
        self.assertEqual(compare.norm_vsim(parse(error), FakeContext(["VSIM", "k", "ELE", "zz"])), error)


class OtherNormalisationTests(unittest.TestCase):
    def test_vinfo_masks_level_and_uid_only(self):
        raw = b"*6\r\n+size\r\n:4\r\n+max-level\r\n:2\r\n+vset-uid\r\n:9\r\n"
        other = b"*6\r\n+size\r\n:4\r\n+max-level\r\n:0\r\n+vset-uid\r\n:1\r\n"
        self.assertEqual(compare.norm_vinfo(parse(raw), None), compare.norm_vinfo(parse(other), None))
        self.assertNotEqual(compare.norm_vinfo(parse(raw), None), compare.norm_vinfo(parse(raw.replace(b":4", b":5")), None))

    def test_vlinks_keeps_the_sorted_last_layer(self):
        ctx = FakeContext(["VLINKS", "k", "a", "WITHSCORES"])
        one = b"*2\r\n*2\r\n" + bulk(b"c", b"0.5") + b"*4\r\n" + bulk(b"c", b"0.5", b"b", b"1")
        two = b"*1\r\n*4\r\n" + bulk(b"b", b"1", b"c", b"0.5")
        self.assertEqual(compare.norm_vlinks(parse(one), ctx), compare.norm_vlinks(parse(two), ctx))

    def test_skeleton_ignores_empty_layers(self):
        one = parse(b"*2\r\n*0\r\n*1\r\n" + bulk(b"a"))
        two = parse(b"*1\r\n*2\r\n" + bulk(b"a", b"b"))
        self.assertEqual(compare.skeleton(one), compare.skeleton(two))

    def test_vrandmember_checks_membership_and_count(self):
        ctx = FakeContext(["VRANDMEMBER", "k", "-3"], {b"VISMEMBER k a": b":1\r\n", b"VISMEMBER k b": b":0\r\n"})
        self.assertEqual(compare.norm_vrandmember(parse(b"*3\r\n" + bulk(b"a", b"a", b"a")), ctx), b"*3 members")
        self.assertEqual(compare.norm_vrandmember(parse(b"*3\r\n" + bulk(b"a", b"b", b"a")), ctx), b"*3 with a non-member")

    def test_debug_object_masks_volatile_fields(self):
        one = b"+Value at:0x7f01 refcount:1 encoding:raw serializedlength:63 lru:15 lru_seconds_idle:0\r\n"
        two = b"+Value at:0x5555 refcount:1 encoding:raw serializedlength:9 lru:99 lru_seconds_idle:3\r\n"
        self.assertEqual(compare.norm_debug_object(parse(one), None), compare.norm_debug_object(parse(two), None))
        self.assertNotEqual(compare.norm_debug_object(parse(one), None), compare.norm_debug_object(parse(one.replace(b"raw", b"int")), None))

    def test_plan_reproduces_every_captured_case_count(self):
        steps = cases.build()
        captured = [s for s in steps if s["kind"] == "case"]
        self.assertEqual(len(captured), 1193)
        self.assertEqual(sum(1 for s in captured if s["proto"] == 2), 709)
        self.assertEqual(sum(1 for s in captured if s["proto"] == 3), 484)
        self.assertTrue(set(s["norm"] for s in steps) <= set(compare.NORMALISERS))
        self.assertTrue(set(compare.NORMALISERS) <= set(compare.NORMALISATIONS))


class DocsSummaryTests(unittest.TestCase):
    def reply(self, summary, since=b"8.0.0", proto=2):
        fields = bulk(b"summary", summary, b"since", since, b"group", b"module", b"module", b"vectorset")
        if proto == 3:
            return parse(b"%1\r\n" + bulk(b"VCARD") + b"%4\r\n" + fields)
        return parse(b"*2\r\n" + bulk(b"VCARD") + b"*8\r\n" + fields)

    def test_only_the_summary_text_is_left_out(self):
        ctx = FakeContext(["COMMAND", "DOCS", "VCARD"])
        for proto in (2, 3):
            ours = compare.norm_docs_summary(self.reply(b"Counts the elements.", proto=proto), ctx)
            self.assertEqual(ours, compare.norm_docs_summary(self.reply(b"Another wording", proto=proto), ctx))
            self.assertNotEqual(ours, compare.norm_docs_summary(self.reply(b"Counts the elements.", b"8.2.0", proto), ctx))
        missing = parse(b"*2\r\n" + bulk(b"VCARD") + b"*6\r\n" + bulk(b"since", b"8.0.0", b"group", b"module", b"module", b"vectorset"))
        self.assertNotEqual(compare.norm_docs_summary(missing, ctx), compare.norm_docs_summary(self.reply(b"Counts the elements."), ctx))
        error = b"-ERR unknown command\r\n"
        self.assertEqual(compare.norm_docs_summary(parse(error), ctx), error)


if __name__ == "__main__":
    unittest.main()
