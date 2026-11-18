import argparse
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "tools"))
import check
import rented_run


class FakeProcess:
    outcomes = {}
    launched = []

    def __init__(self, command, cwd=None, stdout=None, stderr=None, stdin=None, env=None, start_new_session=False):
        self.command = command
        name = Path(stdout.name).stem
        FakeProcess.launched.append(name)
        self.code = FakeProcess.outcomes.get(name, 0)
        outputs = {"--summary": None, "--out": None}
        for i, part in enumerate(command[:-1]):
            if part in outputs:
                outputs[part] = Path(command[i + 1])
        if outputs["--out"] is not None:
            outputs["--out"].mkdir(parents=True, exist_ok=True)
            (outputs["--out"] / "comparison.json").write_text("{}")

    def wait(self, timeout=None):
        return self.code

    def poll(self):
        return self.code


def arguments(folder, profile="full", **changes):
    folder = Path(folder)
    server = folder / "eski"
    if not server.exists():
        server.write_text("server")
        server.chmod(0o755)
    expected = folder / "expected.json"
    if not expected.exists():
        expected.write_text('{"categories": []}\n')
    for name in ("capture.py", "observed.json"):
        if not (folder / name).exists():
            (folder / name).write_text(name)
    values = dict(profile=profile, port_base=17840, steps=None, capture=folder / "capture.py",
                  observed=folder / "observed.json", expected=expected, modern_python=Path("/bin/true"),
                  llama_python=Path("/bin/true"), server=server)
    values.update(changes)
    return argparse.Namespace(**values)


class Steps(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        FakeProcess.outcomes, FakeProcess.launched = {}, []
        self.patches = [mock.patch.object(check.subprocess, "Popen", FakeProcess),
                        mock.patch.object(check, "reference_server", lambda port, folder: contextlib.nullcontext())]
        for patch in self.patches:
            patch.start()

    def tearDown(self):
        for patch in self.patches:
            patch.stop()
        self.folder.cleanup()

    def run_full(self, name, profile="full", resume=None, **changes):
        out = self.root / name
        out.mkdir()
        run = check.Run(arguments(self.root, profile, **changes), out)
        run.server_hash = check.sha256(run.binary)
        if resume:
            run.resume_from(resume)
        with contextlib.redirect_stdout(io.StringIO()):
            run.full() if profile == "full" else run.light()
        run.save(int(any(row.get("exit_code") for row in run.rows)))
        return run, json.loads((out / "summary.json").read_text())

    def test_the_run_requires_exactly_the_steps_the_full_profile_emits(self):
        run, summary = self.run_full("names")
        emitted = [row["step"] for row in summary["steps"]]
        self.assertEqual(emitted, rented_run.required_functional_steps("full"))
        self.assertEqual(emitted, check.profile_steps("full", True))
        self.assertEqual(summary["planned"], emitted)
        for row in summary["steps"]:
            row["exit_code"] = 0
        summary["complete"] = True
        verifier = rented_run.Run.verify_functional
        self.assertIs(verifier(None, summary, "full", {"eski": summary["server_sha256"]}), True)
        renamed = json.loads(json.dumps(summary))
        renamed["steps"][-1]["step"] = "search_pipeline-reference"
        self.assertIsNot(verifier(None, renamed, "full", {"eski": summary["server_sha256"]}), True)
        missing = json.loads(json.dumps(summary))
        del missing["steps"][3]
        self.assertIsNot(verifier(None, missing, "full", {"eski": summary["server_sha256"]}), True)

    def test_documentation_receives_the_binary_under_test(self):
        run, summary = self.run_full("documentation")
        row = next(row for row in summary["steps"] if row["step"] == "documentation")
        self.assertEqual(row["command"][-2:], ["--server-binary", str(self.root / "eski")])

    def test_resume_reuses_passed_steps_and_reruns_the_failed_one(self):
        FakeProcess.outcomes = {"vectorset-off": 1, "owners-user": 1}
        first, summary = self.run_full("first")
        self.assertFalse(summary["complete"])
        FakeProcess.outcomes, FakeProcess.launched = {}, []
        second, summary = self.run_full("second", resume=first.out)
        self.assertIn("owners-user", FakeProcess.launched)
        self.assertIn("vectorset-off", FakeProcess.launched)
        self.assertNotIn("smoke-off", FakeProcess.launched)
        reused = {row["step"] for row in summary["steps"] if row.get("reused_from")}
        self.assertIn("smoke-off", reused)
        self.assertTrue((second.out / "smoke-off.log").is_file())

    def test_a_changed_expected_file_reruns_only_the_capture_step(self):
        first, summary = self.run_full("first", steps=["search-smoke", "search-capture"])
        self.assertTrue(summary["complete"] is False and len(summary["steps"]) == 2)
        changed = self.root / "expected-2.json"
        changed.write_text('{"categories": [] }\n')
        FakeProcess.launched = []
        second, summary = self.run_full("second", resume=first.out, steps=["search-smoke", "search-capture"], expected=changed)
        self.assertEqual(FakeProcess.launched, ["search-capture"])
        self.assertEqual([row["step"] for row in summary["steps"] if row.get("reused_from")], ["search-smoke"])

    def test_a_different_server_reuses_nothing(self):
        first, summary = self.run_full("first", profile="light")
        (self.root / "eski").write_text("another build")
        FakeProcess.launched = []
        second, summary = self.run_full("second", profile="light", resume=first.out)
        self.assertEqual(FakeProcess.launched, ["search-runner-tests", "search-smoke"])

    def test_the_package_groups_cover_every_item_and_a_failed_one_reruns_alone(self):
        run, summary = self.run_full("groups")
        rows = {row["step"]: row["command"] for row in summary["steps"] if row["step"].startswith("packages")}
        self.assertEqual(list(rows), [name for name, group, seconds in check.PACKAGE_GROUPS])
        groups = {command[command.index("--group") + 1] for command in rows.values()}
        self.patches[0].stop()
        try:
            listing = check.subprocess.run(["bash", str(check.relative("test/run_packages.sh")), "--list"], capture_output=True,
                                           text=True, check=True).stdout.split("\n")
        finally:
            self.patches[0].start()
        self.assertEqual({line.split()[0] for line in listing if line}, groups)
        FakeProcess.outcomes, FakeProcess.launched = {"packages-drivers": 1}, []
        first, summary = self.run_full("first")
        FakeProcess.outcomes, FakeProcess.launched = {}, []
        self.run_full("second", resume=first.out)
        self.assertIn("packages-drivers", FakeProcess.launched)
        self.assertFalse({"packages-debug", "packages-sanitizer", "packages-release"} & set(FakeProcess.launched))

    def test_selected_steps_must_exist(self):
        self.assertIn("search-capture", check.profile_steps("full", True))
        self.assertNotIn("json-commands", check.profile_steps("full", True))


if __name__ == "__main__":
    unittest.main()
