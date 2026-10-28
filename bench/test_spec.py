import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import spec


CASE = """version: 0.4
name: memtier_benchmark-1Mkeys-hash-hgetall-50-fields
description: 'Runs memtier_benchmark, for a keyspace length of 1M keys
  pre-loading HASHes. It''s a test.'
dbconfig:
  configuration-parameters:
    save: '""'
    hash-max-listpack-entries: 512
  check:
    keyspacelen: 1000000
  preload_tool:
    run_image: redislabs/memtier_benchmark:edge
    tool: memtier_benchmark
    arguments: '"--data-size" "10" --command "HSET __key__ field:1 __data__"
      --command-key-pattern="P" --key-minimum=1 --key-maximum 1000000 -n allkeys
      -c 50 -t 4 --hide-histogram'
  resources:
    requests:
      memory: 2g
tested-groups:
- hash
tested-commands:
- hgetall
redis-topologies:
- oss-standalone
clientconfig:
  run_image: redislabs/memtier_benchmark:edge
  tool: memtier_benchmark
  arguments: --command "HGETALL __key__" --command-key-pattern="R" --key-minimum=1
    --key-maximum 1000000 --test-time 120 -c 50 -t 4 --hide-histogram
  resources:
    requests:
      cpus: '4'
      memory: 2g
priority: 96
"""

MULTI = """name: memtier_benchmark-Nclients-blpop
description: >
  Blocking list case. One producer
  and many consumers.
dbconfig:
  configuration-parameters:
    save: '""'
  check:
    keyspacelen: 0
# tested-commands lists every verb
tested-commands:
- lpush
- blpop
redis-topologies:
- oss-standalone
clientconfigs:
# producer
- run_image: redislabs/memtier_benchmark:edge
  tool: memtier_benchmark
  arguments: >-
    --data-size 32
    --command "LPUSH blpop:key:1 __data__"
    -c 1 -t 1 --test-time 125
  resources:
    requests:
      cpus: '1'
- run_image: redislabs/memtier_benchmark:edge
  tool: memtier_benchmark
  arguments: >-
    --command "BLPOP blpop:key:1 0"
    -c 25 -t 4 --test-time 120
  resources:
    requests:
      cpus: '4'
"""


def write_tree(cases):
    root = Path(tempfile.mkdtemp())
    suites = root / "redis_benchmarks_specification" / "test-suites"
    suites.mkdir(parents=True)
    for name, text in cases.items():
        (suites / name).write_text(text)
    return root


class YamlReaderTest(unittest.TestCase):
    def test_full_case(self):
        doc = spec.load_yaml(CASE)
        self.assertEqual(doc["version"], 0.4)
        self.assertEqual(doc["priority"], 96)
        self.assertEqual(doc["description"], "Runs memtier_benchmark, for a keyspace length of 1M keys pre-loading HASHes. It's a test.")
        self.assertEqual(doc["dbconfig"]["configuration-parameters"], {"save": '""', "hash-max-listpack-entries": 512})
        self.assertEqual(doc["dbconfig"]["check"], {"keyspacelen": 1000000})
        self.assertTrue(doc["dbconfig"]["preload_tool"]["arguments"].startswith('"--data-size" "10" --command'))
        self.assertIn("-n allkeys -c 50", doc["dbconfig"]["preload_tool"]["arguments"])
        self.assertEqual(doc["tested-commands"], ["hgetall"])
        self.assertEqual(doc["clientconfig"]["arguments"],
                         '--command "HGETALL __key__" --command-key-pattern="R" --key-minimum=1 --key-maximum 1000000 --test-time 120 -c 50 -t 4 --hide-histogram')
        self.assertEqual(doc["clientconfig"]["resources"]["requests"]["cpus"], "4")

    def test_sequences_of_mappings_folded_and_comments(self):
        doc = spec.load_yaml(MULTI)
        self.assertEqual(doc["description"], "Blocking list case. One producer and many consumers.\n")
        self.assertEqual(doc["tested-commands"], ["lpush", "blpop"])
        self.assertEqual(len(doc["clientconfigs"]), 2)
        self.assertEqual(doc["clientconfigs"][0]["arguments"], '--data-size 32 --command "LPUSH blpop:key:1 __data__" -c 1 -t 1 --test-time 125')
        self.assertEqual(doc["clientconfigs"][1]["resources"], {"requests": {"cpus": "4"}})

    def test_scalar_resolution(self):
        doc = spec.load_yaml("a: 12\nb: -3\nc: 0x1f\nd: 017\ne: 1.5\nf: yes\ng: Off\nh: ~\ni:\nj: '12'\nk: 1_000\nl: 08\nm: .inf\nn: text # comment\n")
        self.assertEqual(doc, {"a": 12, "b": -3, "c": 31, "d": 15, "e": 1.5, "f": True, "g": False, "h": None, "i": None,
                               "j": "12", "k": 1000, "l": "08", "m": float("inf"), "n": "text"})

    def test_block_scalars_and_chomping(self):
        doc = spec.load_yaml("a: |\n  one\n   two\n\nb: |-\n  x\n  y\nc: |+\n  k\n\nd: >\n  p\n  q\n\n  r\n    s\n  t\ne: x\n")
        self.assertEqual(doc["a"], "one\n two\n")
        self.assertEqual(doc["b"], "x\ny")
        self.assertEqual(doc["c"], "k\n\n")
        self.assertEqual(doc["d"], "p q\nr\n  s\nt\n")
        self.assertEqual(doc["e"], "x")

    def test_block_scalar_at_end_without_newline(self):
        self.assertEqual(spec.load_yaml("run: |\n  poetry publish"), {"run": "poetry publish"})
        self.assertEqual(spec.load_yaml("run: |\n  poetry publish\n"), {"run": "poetry publish\n"})

    def test_quoted_scalars(self):
        doc = spec.load_yaml("a: 'it''s # not a comment'\nb: \"tab\\tquote\\\" \\u00e9\"\nc: 'x\n  y\n\n  z'\nd: \"a\\\n  b\"\n")
        self.assertEqual(doc["a"], "it's # not a comment")
        self.assertEqual(doc["b"], 'tab\tquote" \u00e9')
        self.assertEqual(doc["c"], "x y\nz")
        self.assertEqual(doc["d"], "ab")

    def test_nested_sequences_and_quoted_keys(self):
        doc = spec.load_yaml("init:\n- - SCRIPT\n  - LOAD\n  - return 1\n- '\"SET\" \"k\" \"v\"'\n'quoted key': 1\n")
        self.assertEqual(doc["init"], [["SCRIPT", "LOAD", "return 1"], '"SET" "k" "v"'])
        self.assertEqual(doc["quoted key"], 1)

    def test_flow_collections(self):
        doc = spec.load_yaml("a: [1, two, 'three, 3']\nb: {x: 1, y: [a, b]}\nc: [\n  p,\n  q]\n")
        self.assertEqual(doc, {"a": [1, "two", "three, 3"], "b": {"x": 1, "y": ["a", "b"]}, "c": ["p", "q"]})

    def test_errors(self):
        for text in ("a: 1\n   b: 2\n", "a: 'open\n", "a:\n\t- x\n", "a: &anchor 1\n", "a: x\n  b: y\n"):
            with self.assertRaises(spec.YamlError, msg=text):
                spec.load_yaml(text)


class ApplicabilityTest(unittest.TestCase):
    def test_tested_and_workload_commands(self):
        doc = spec.load_yaml(CASE)
        reasons, missing, tested, workload, ignored = spec.assess(doc, {"hgetall", "hset"})
        self.assertEqual((reasons, missing), ([], []))
        self.assertEqual(tested, ["hgetall"])
        self.assertEqual(workload, ["hgetall", "hset"])
        reasons, missing, _, _, _ = spec.assess(doc, {"hgetall"})
        self.assertEqual(missing, ["hset"])
        self.assertEqual(reasons, ["eski lacks hset"])

    def test_memtier_default_commands_follow_the_ratio(self):
        self.assertEqual(spec.memtier_commands(["--ratio=1:0", "-c", "1"]), {"set"})
        self.assertEqual(spec.memtier_commands(["--ratio", "0:1"]), {"get"})
        self.assertEqual(spec.memtier_commands([]), {"set", "get"})
        self.assertEqual(spec.memtier_commands(["--command=CLIENT LIST", "--command", "INFO everything"]), {"client", "client|list", "info"})

    def test_redis_benchmark_commands(self):
        self.assertEqual(spec.rb_commands(["-t", "set,lpush,ping_inline,lrange_100", "-c", "50"]), {"set", "lpush", "ping", "lrange"})
        self.assertEqual(spec.rb_commands(["-n", "10", "SADD", "k", "v"]), {"sadd"})

    def test_other_reasons(self):
        doc = spec.load_yaml(CASE)
        doc["redis-topologies"] = ["oss-cluster-3-primaries"]
        doc["dbconfig"]["dataset"] = "https://example.invalid/dump.rdb"
        doc["dbconfig"]["wait_for_bgsave"] = True
        doc["clientconfig"]["tool"] = "pubsub-sub-bench"
        reasons, _, _, _, _ = spec.assess(doc, {"hgetall", "hset"})
        kinds = sorted(spec.reason_kind(r) for r in reasons)
        self.assertEqual(kinds, ["bgsave duration", "client tool", "dataset", "topology"])

    def test_init_lua_needs_eval(self):
        doc = spec.load_yaml(CASE)
        doc["dbconfig"]["init_lua"] = "return 1"
        _, missing, _, _, _ = spec.assess(doc, {"hgetall", "hset"})
        self.assertEqual(missing, ["eval"])

    def test_typo_in_tested_commands_is_ignored_only_with_a_reference(self):
        doc = spec.load_yaml(CASE)
        doc["tested-commands"] = ["hgetall", "setx"]
        _, missing, _, _, ignored = spec.assess(doc, {"hgetall", "hset"})
        self.assertEqual((missing, ignored), (["setx"], []))
        _, missing, _, _, ignored = spec.assess(doc, {"hgetall", "hset"}, {"hgetall", "hset", "setex"})
        self.assertEqual((missing, ignored), ([], ["setx"]))
        doc["tested-commands"] = ["hgetall", "hgetex"]
        doc["clientconfig"]["arguments"] = '--command "HGETEX __key__ FIELDS 1 f" --test-time 10'
        _, missing, _, _, ignored = spec.assess(doc, {"hgetall", "hset"}, {"hgetall", "hset"})
        self.assertEqual((missing, ignored), (["hgetex"], []))

    def test_init_commands_forms(self):
        db = {"init_commands": ['"SADD" "s" "a b"', "SET k v", ["SCRIPT", "LOAD", "return 1"]]}
        self.assertEqual(spec.init_command_lists(db), [["SADD", "s", "a b"], ["SET", "k", "v"], ["SCRIPT", "LOAD", "return 1"]])
        self.assertEqual(spec.init_command_lists({"init_commands": "PING"}), [["PING"]])


class PlanTest(unittest.TestCase):
    def test_strip_endpoint(self):
        argv = ["-s", "10.0.0.1", "--port=6379", "--json-out-file", "x.json", "-c", "5"]
        self.assertEqual(spec.strip_endpoint(argv, "memtier_benchmark"), (["-c", "5"], ["-s", "10.0.0.1", "--port=6379", "--json-out-file", "x.json"]))
        argv = ["-h", "h", "-p", "1", "-n", "5", "SET", "-p", "x"]
        self.assertEqual(spec.strip_endpoint(argv, "redis-benchmark")[0], ["-n", "5", "SET", "-p", "x"])

    def test_test_time_substitution(self):
        argv = ["--test-time", "180", "-c", "1", "--test-time=90"]
        self.assertEqual(spec.declared_test_time(argv), 90)
        self.assertEqual(spec.with_test_time(argv, 5), ["--test-time", "5", "-c", "1", "--test-time=5"])
        self.assertIsNone(spec.declared_test_time(["-n", "allkeys"]))

    def test_cpusets(self):
        cores = spec.parse_cpus("4-13")
        self.assertEqual(spec.client_cpusets([{"resources": {"requests": {"cpus": "4"}}}], cores), ["4-7"])
        self.assertEqual(spec.client_cpusets([{"resources": {"requests": {"cpus": "16"}}}], cores), ["4-13"])
        two = [{"resources": {"requests": {"cpus": "1"}}}, {"resources": {"requests": {"cpus": "4"}}}]
        self.assertEqual(spec.client_cpusets(two, cores), ["4", "5-8"])
        self.assertEqual(spec.client_cpusets([{}, {}], cores), ["4-13", "4-13"])
        self.assertEqual(spec.format_cpus([1, 2, 3, 7, 9, 10]), "1-3,7,9-10")

    def test_spec_plan(self):
        broken = "name: broken\ndescription: 'unterminated\n"
        tree = write_tree({"defaults.yml": "exporter:\n  x: 1\n", "a.yml": CASE, "b.yml": MULTI, "c.yml": broken})
        probe = {"method": "probe", "implemented": ["hgetall", "hset", "lpush", "blpop"]}
        opts = {"client_cpus": "4-13", "quick_cap": 5, "release": "vtest"}
        items, meta = spec.spec_plan(tree, probe, opts)
        self.assertEqual(meta["case_files"], 3)
        self.assertEqual(len(meta["parse_failures"]), 1)
        self.assertEqual([i["name"] for i in items], ["memtier_benchmark-1Mkeys-hash-hgetall-50-fields", "memtier_benchmark-Nclients-blpop"])
        one, multi = items
        self.assertEqual(one["config"], [["hash-max-listpack-entries", "512"]])
        self.assertEqual(one["check"], {"keyspacelen": 1000000})
        self.assertEqual(one["clients"][0]["cpus"], "4-7")
        self.assertEqual(one["clients"][0]["test_time"], 5)
        self.assertIn("--test-time", one["clients"][0]["argv"])
        self.assertEqual(one["preload"]["argv"][:2], ["--data-size", "10"])
        self.assertTrue(one["info"]["test_time_capped"])
        self.assertEqual([c["test_time"] for c in multi["clients"]], [10, 5])
        self.assertEqual([c["cpus"] for c in multi["clients"]], ["4", "5-8"])
        self.assertEqual([s["name"] for s in meta["skipped"]], ["c"])
        probe["implemented"] = ["hgetall"]
        items, meta = spec.spec_plan(tree, probe, dict(opts, select=["*hgetall*", "*blpop"]))
        self.assertEqual(items, [])
        self.assertEqual(meta["skipped_by_missing_command"], {"blpop": 1, "hset": 1, "lpush": 1})
        self.assertEqual(meta["only_blocker"], {"hset": 1})

    def test_target_skip(self):
        item = {"required_commands": ["hexpire", "hset"], "skip_targets": {"eski": "eski lacks lpush"}}
        self.assertEqual(spec.target_skip(item, "eski", {}), "eski lacks lpush")
        self.assertEqual(spec.target_skip(item, "valkey", {"method": "command_list", "missing": ["hexpire"]}), "valkey lacks hexpire")
        self.assertEqual(spec.target_skip(item, "redis", {"method": "command_list", "missing": []}), "")
        self.assertEqual(spec.target_skip(item, "redis", {}), "")

    def test_shell_output_round_trips(self):
        tree = write_tree({"a.yml": CASE})
        items, meta = spec.spec_plan(tree, {"method": "probe", "implemented": ["hgetall", "hset"]}, {"client_cpus": "0-3"})
        plan = Path(tempfile.mkdtemp()) / "plan.json"
        plan.write_text(json.dumps({"items": items, "suites": {"spec": meta}}))
        out = []
        real = sys.stdout
        try:
            import io
            sys.stdout = io.StringIO()
            spec.main(["shell", "--plan", str(plan), "--index", "0", "--target", "redis"])
            out = sys.stdout.getvalue()
        finally:
            sys.stdout = real
        self.assertIn("local IT_KEY=memtier_benchmark-1Mkeys-hash-hgetall-50-fields", out)
        self.assertIn("local -a IT_CLIENT_ARGV_0=(--command 'HGETALL __key__' --command-key-pattern=R", out)
        self.assertIn("local IT_SKIP=''", out)


if __name__ == "__main__":
    unittest.main()
