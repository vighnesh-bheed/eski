import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
WORKER = '''#!{python}
import sys
case, seed, steps, variant = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
for step in range(steps):
    print("OBS %d visible" % step)
if (seed, case) in {failing}:
    print("FAIL property case=%s seed=%d" % (case, seed))
    sys.exit(3)
print("END PASS case=%s seed=%d" % (case, seed))
'''


class Virtual(unittest.TestCase):
    def run_virtual(self, failing, *extra):
        folder = Path(self.folder.name)
        worker = folder / ("worker-%d" % len(list(folder.iterdir())))
        worker.write_text(WORKER.format(python=sys.executable, failing=repr(set(failing))))
        worker.chmod(0o755)
        out = folder / (worker.name + "-out")
        result = subprocess.run([sys.executable, "-IB", str(HERE / "exercise.py"), "virtual", "--binary", str(worker),
                                 "--out", str(out), "--first-seed", "3", "--seeds", "4", "--steps", "2", *extra],
                                capture_output=True, text=True, timeout=120)
        return result.returncode, json.loads((out / "summary.json").read_text())

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.folder.cleanup()

    def test_every_failing_seed_is_reported_with_what_a_replay_needs(self):
        code, summary = self.run_virtual([(3, "disk"), (5, "owners"), (5, "network")])
        self.assertEqual(code, 1)
        self.assertEqual(summary["failed_seeds"], [3, 5])
        self.assertEqual(summary["completed_seeds"], 2)
        self.assertEqual([(row["seed"], row["case"], row["variant"]) for row in summary["failures"]],
                         [(3, "disk", "base"), (5, "network", "base"), (5, "owners", "base")])
        row = summary["failures"][0]
        self.assertEqual(row["steps"], 2)
        self.assertEqual(row["trace"], "3-disk-base.trace")
        self.assertEqual(row["replay"][1:], ["disk", "3", "2", "base"])
        self.assertRegex(summary["sha256"], "^[0-9a-f]{64}$")

    def test_a_clean_run_completes_every_seed(self):
        code, summary = self.run_virtual([])
        self.assertEqual((code, summary["completed_seeds"], summary["failures"]), (0, 4, []))

    def test_the_failure_limit_stops_early_and_says_so(self):
        code, summary = self.run_virtual([(3, "disk"), (4, "disk"), (5, "disk")], "--max-failures", "2")
        self.assertEqual(code, 1)
        self.assertEqual(summary["failed_seeds"], [3, 4])
        self.assertIn("stopped after 2", summary["stopped_early"])


if __name__ == "__main__":
    unittest.main()
