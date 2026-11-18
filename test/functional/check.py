import argparse
from contextlib import nullcontext
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "test/search"))
from compare import free_port, load_expected, output_directory, reference_server

PYTHON = (sys.executable, "-IB")
MODES = ("labelled", "owners-shared", "owners-user", "owners-only-user")
FALLBACK = ("json-commands", "json-search")
CLIENT_STEPS = ("search-clients", "search-advanced-reference", "search-pipeline-reference")
PACKAGE_GROUPS = (("packages-debug", "debug", 7200), ("packages-sanitizer", "sanitizer", 14400),
                  ("packages-release", "release", 7200), ("packages-drivers", "drivers", 7200))
SCHEMA = "eski-functional-v2"


def relative(path):
    return ROOT / path


def sha256(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def stop_step(process):
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def copy_output(source, destination):
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=True)
    elif source.is_file():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    else:
        raise ValueError("earlier output %s is missing" % source)


class Run:
    def __init__(self, args, out, dry=False):
        self.args = args
        self.out = out
        self.dry = dry
        self.base = args.port_base
        self.ports = "%s-%s" % (self.base + 20, self.base + 39)
        self.binary = args.server or relative("bin/eski")
        self.rows = []
        self.planned = []
        self.selected = set(args.steps) if args.steps else None
        self.previous = None
        self.previous_rows = {}
        self.previous_server = None
        self.server_hash = None
        self.env = os.environ.copy()
        for name in ("ESKI_LABELLED_DIR", "ESKI_LABELLED_PRINT_LOGIN", "ESKI_SMOKE_LOGIN_RULES"):
            self.env.pop(name, None)
        overrides = {
            "ESKI_SMOKE_PORT": 4, "ESKI_SMOKE_REF_PORT": 5, "ESKI_SMOKE_MIGRATE_PORT": 5,
            "ESKI_SMOKE_MC_PORT": 11, "ESKI_SMOKE_MC_REF_PORT": 12, "ESKI_STORAGE_PORT": 13,
            "ESKI_HASH_IDLE_PORT": 14, "ESKI_SET_IDLE_PORT": 15, "ESKI_ZSET_IDLE_PORT": 16,
            "ESKI_SLAB_PORT": 17, "ESKI_SMOKE_VSET_REF_PORT": 18, "ESKI_VSET_PORT": 2,
            "ESKI_VSET_REF_PORT": 3,
        }
        self.env.update({key: str(self.base + offset) for key, offset in overrides.items()})
        self.env.update(ESKI_LABELLED_BINARY=str(self.binary), ESKI_TEST_BIN=str(self.binary),
                        ESKI_SMOKE_BINARY=str(self.binary), ESKI_VSET_SERVER=str(self.binary),
                        ESKI_SMOKE_KEYSPACE_THREADS="0", ESKI_SMOKE_EXTERNAL="0", ESKI_SMOKE_BENCH="0",
                        ESKI_VSET_EXTERNAL="0", ESKI_SMOKE_VSET="1", ESKI_SEARCH_PORTS=self.ports)

    def resume_from(self, previous):
        summary = json.loads((previous / "summary.json").read_text())
        if summary.get("profile") != self.args.profile:
            raise ValueError("the earlier output used the %s profile" % summary.get("profile"))
        self.previous = previous
        self.previous_server = summary.get("server_sha256")
        for row in summary.get("steps", []):
            if isinstance(row, dict) and isinstance(row.get("step"), str):
                self.previous_rows[row["step"]] = row

    def server_sha256(self):
        if self.server_hash is None and self.binary.is_file():
            self.server_hash = sha256(self.binary)
        return self.server_hash

    def portable(self, value, folder):
        return str(value).replace(str(folder), "{out}")

    def reusable(self, name, command, overrides, inputs, outputs):
        row = self.previous_rows.get(name)
        if row is None or row.get("exit_code") != 0 or not self.previous_server:
            return None
        if self.previous_server != self.server_sha256() or row.get("inputs", {}) != inputs:
            return None
        here = [self.portable(part, self.out) for part in command]
        there = [self.portable(part, self.previous) for part in row.get("command", [])]
        if here != there or row.get("outputs", []) != outputs:
            return None
        mine = {key: self.portable(value, self.out) for key, value in (overrides or {}).items()}
        theirs = {key: self.portable(value, self.previous) for key, value in row.get("environment", {}).items()}
        return row if mine == theirs else None

    def decide(self, name, command, overrides=None, inputs=None, outputs=()):
        if self.selected is not None and name not in self.selected:
            return "skip", None
        if self.dry:
            return "dry", None
        command = list(map(str, command))
        previous = self.reusable(name, command, overrides, inputs or {}, list(outputs)) if self.previous else None
        return ("reuse", previous) if previous else ("run", None)

    def step(self, name, command, seconds, overrides=None, validate=None, inputs=None, outputs=()):
        self.planned.append(name)
        command = list(map(str, command))
        action, previous = self.decide(name, command, overrides, inputs, outputs)
        if action == "skip":
            return None
        if action == "dry":
            self.rows.append({"step": name, "command": command, "timeout": seconds})
            return True
        log_path = self.out / (name + ".log")
        row = {"step": name, "log": log_path.name, "command": command, "environment": dict(overrides or {}),
               "inputs": dict(inputs or {}), "outputs": list(outputs), "timeout": seconds}
        self.rows.append(row)
        if action == "reuse":
            print("%s reused from %s" % (name, self.previous), flush=True)
            try:
                for item in [log_path.name, *previous.get("produced", [])]:
                    copy_output(self.previous / item, self.out / item)
                row["produced"] = list(previous.get("produced", []))
                if validate is not None:
                    validate()
                row.update(exit_code=0, seconds=previous.get("seconds"), reused_from=str(self.previous))
            except (OSError, ValueError, KeyError) as e:
                row.update(exit_code=2, error="reuse failed: %s" % e)
            self.save()
            return row["exit_code"] == 0
        print(name, flush=True)
        start = time.monotonic()
        try:
            with log_path.open("wb") as log:
                process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                           stdin=subprocess.DEVNULL, env=dict(self.env, **(overrides or {})),
                                           start_new_session=True)
                try:
                    rc = process.wait(timeout=seconds)
                finally:
                    stop_step(process)
            row["exit_code"] = rc
            if rc == 0 and validate is not None:
                validate()
        except KeyboardInterrupt:
            row.update(exit_code=130, error="interrupted")
            raise
        except (OSError, subprocess.TimeoutExpired, ValueError, KeyError) as e:
            row.update(exit_code=2, error=str(e))
        finally:
            row["seconds"] = round(time.monotonic() - start, 2)
            row["produced"] = [item for item in outputs if (self.out / item).exists()]
            self.save()
        print("%s exit %s" % (name, row["exit_code"]), flush=True)
        return row["exit_code"] == 0

    def summary(self, exit_code=None):
        planned = [name for name in self.planned if name not in FALLBACK]
        passed = {row["step"] for row in self.rows if row.get("exit_code") == 0}
        return {"schema": SCHEMA, "profile": self.args.profile, "server": str(self.binary),
                "server_sha256": self.server_hash, "exit_code": exit_code, "steps": self.rows,
                "planned": planned, "selected": sorted(self.selected) if self.selected is not None else None,
                "complete": bool(planned) and set(planned) <= passed,
                "resumed_from": str(self.previous) if self.previous else None}

    def save(self, exit_code=None):
        if self.dry:
            return
        path = self.out / "summary.json"
        pending = path.with_suffix(".tmp")
        pending.write_text(json.dumps(self.summary(exit_code), indent=2) + "\n")
        pending.replace(path)

    def suite(self, name, kind, baseline=None, units=None):
        summary = self.out / (name + ".json")
        command = [relative("test/conformance/run.sh"), "--suite", kind, "--server", self.binary,
                   "--port", self.base + 19, "--summary", summary, "--results-dir", self.out / (name + "-results")]
        if units:
            command += ["--units", units]
        if baseline:
            command += ["--baseline", baseline]

        def validate():
            result = json.loads(summary.read_text())
            if not result["units"] or not result["totals"]["passed"] or result["totals"]["errored"]:
                raise ValueError("suite summary contains unit errors or no passing tests")
            if any(unit["errors"] for unit in result["units"].values()):
                raise ValueError("suite summary contains unit errors")
            if baseline:
                previous = json.loads(baseline.read_text())
                names = {name for name, unit in previous["units"].items() if unit["status"] != "out-of-scope"}
                if set(result["baseline"]["units_compared"]) != names or result["baseline"]["regressions"]:
                    raise ValueError("suite summary has regressions or omits baseline units")
            if units and set(result["units"]) != {units}:
                raise ValueError("suite summary omits the requested unit")

        inputs = {"baseline": sha256(baseline)} if baseline and not self.dry else {}
        if self.step(name, command, 14400, validate=validate, inputs=inputs,
                     outputs=(summary.name, name + "-results")):
            return summary
        return None

    def compare(self, name, extra=(), inputs=None):
        return self.step(name, [relative("test/search/compare.sh"), "--server", self.binary,
                                "--port", self.base, "--reference-port", self.base + 1,
                                "--out", self.out / name, *extra], 1800, inputs=inputs, outputs=(name,))

    def capture_inputs(self):
        if self.dry:
            return {}
        return {"capture": sha256(self.args.capture), "observed": sha256(self.args.observed),
                "expected": sha256(self.args.expected)}

    def full(self):
        self.step("strict-check", [relative("build.sh"), "check"], 3600)
        if self.args.server is None and not self.step("release-build", [relative("build.sh"), "release"], 3600):
            return
        if not self.dry:
            if not self.binary.is_file() or not os.access(self.binary, os.X_OK):
                raise ValueError("missing executable server %s" % self.binary)
            self.server_hash = sha256(self.binary)
            (self.out / "server.sha256").write_text(self.server_hash + "\n")
            self.save()
        self.step("documentation", [*PYTHON, relative("test/readme_tables.py"), "--check",
                                    "--server-binary", self.binary], 300)
        conformance = self.suite("conformance-off", "redis", relative("test/conformance/baseline-redis.json"))
        vectors = self.suite("vectorset-off", "vectorset", relative("test/conformance/baseline-vectorset.json"))
        scripting = self.suite("scripting-off", "redis", units="scripting")
        self.step("smoke-off", [relative("test/smoke.sh")], 14400,
                  {"ESKI_SMOKE_FULL_DIR": str(self.out / "smoke-off-differences")}, outputs=("smoke-off-differences",))
        self.step("vector-replies-off", [relative("test/vectorset/compare.sh"), "--summary", self.out / "vector-replies-off.json"],
                  3600, outputs=("vector-replies-off.json",))
        for mode in MODES:
            command = [relative("test/labelled/run.sh"), "--mode", mode, "--out", self.out / mode, "compare", "smoke"]
            for name, reference in (("conformance", conformance), ("scripting", scripting), ("vectorset", vectors)):
                if reference:
                    command += ["--%s-reference" % name, reference, name]
            self.step(mode, command, 21600, outputs=(mode,))
        self.compare("search-smoke")
        self.compare("search-capture", ["--capture", self.args.capture, "--observed", self.args.observed,
                                        "--expected", self.args.expected], self.capture_inputs())
        packages = [self.step(name, [relative("test/run_packages.sh"), "--group", group], seconds)
                    for name, group, seconds in PACKAGE_GROUPS]
        if packages[-1] is False:
            for name in FALLBACK:
                self.step(name, [*PYTHON, relative("test/compatibility/%s.py" % name.replace("-", "_")),
                                 "--server", self.binary, "--ports", self.ports], 900)
        commands = {
            "search-clients": [*PYTHON, relative("test/compatibility/search_clients/run.py"),
                               "--server", self.binary, "--ports", self.ports, "--reference-port", self.base + 1,
                               "--modern-python", self.args.modern_python, "--llama-python", self.args.llama_python],
        }
        for name in ("search_advanced", "search_pipeline"):
            commands[name.replace("_", "-") + "-reference"] = [
                *PYTHON, relative("test/compatibility/%s.py" % name), "--server", self.binary,
                "--ports", self.ports, "--reference-port", self.base + 1]
        needed = [name for name in CLIENT_STEPS if self.decide(name, commands[name])[0] == "run"]
        try:
            with reference_server(self.base + 1, self.out / "client-reference") if needed else nullcontext():
                for name in CLIENT_STEPS:
                    self.step(name, commands[name], 900)
        except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as e:
            self.rows.append({"step": "client-reference", "exit_code": 2, "error": str(e)})
            self.save()

    def light(self):
        self.step("search-runner-tests", [*PYTHON, relative("test/search/test_compare.py")], 30)
        self.compare("search-smoke")


def profile_steps(profile="full", server_given=True):
    args = argparse.Namespace(profile=profile, port_base=17840, steps=None, capture=Path("capture.py"),
                              observed=Path("observed.json"), expected=relative("test/search/expected.json"),
                              modern_python=Path("modern"), llama_python=Path("llama"),
                              server=Path("eski") if server_given else None)
    run = Run(args, Path("out"), dry=True)
    run.full() if profile == "full" else run.light()
    return [row["step"] for row in run.rows]


def interrupted(signum, frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description="Run Eski functional qualification with per-step logs.")
    parser.add_argument("--profile", choices=("light", "full"), default="light")
    parser.add_argument("--out", type=Path, help="empty output directory")
    parser.add_argument("--server", type=lambda name: Path(name).resolve(),
                        help="prebuilt Eski binary (without it, full builds the release)")
    parser.add_argument("--port-base", type=int, default=17840, help="first port of a free 40-port loopback range")
    parser.add_argument("--modern-python", type=lambda name: Path(os.path.abspath(name)))
    parser.add_argument("--llama-python", type=lambda name: Path(os.path.abspath(name)))
    parser.add_argument("--capture", type=lambda name: Path(name).resolve())
    parser.add_argument("--observed", type=lambda name: Path(name).resolve())
    parser.add_argument("--expected", type=lambda name: Path(name).resolve(), default=relative("test/search/expected.json"))
    parser.add_argument("--steps", type=lambda text: [name for name in text.split(",") if name],
                        help="comma-separated steps of the profile to run; the others are not run")
    parser.add_argument("--resume", type=lambda name: Path(name).resolve(),
                        help="earlier output directory whose passed steps are reused when the server binary and the step's inputs are the same")
    parser.add_argument("--list-steps", action="store_true", help="print the profile's step names as JSON and exit")
    args = parser.parse_args()
    if args.list_steps:
        print(json.dumps(profile_steps(args.profile, args.server is not None or args.profile == "light")))
        return 0
    if not 1024 <= args.port_base <= 65496:
        parser.error("--port-base must allow 40 non-privileged ports")
    if bool(args.capture) != bool(args.observed):
        parser.error("--capture and --observed go together")
    if args.steps:
        known = set(profile_steps(args.profile, args.server is not None or args.profile == "light"))
        unknown = sorted(set(args.steps) - known)
        if unknown:
            parser.error("unknown steps for the %s profile: %s" % (args.profile, ", ".join(unknown)))
    if args.resume and not (args.resume / "summary.json").is_file():
        parser.error("--resume needs an earlier output directory with summary.json")
    if args.profile == "full":
        if not (args.modern_python and args.llama_python and args.capture and args.observed):
            parser.error("full requires --modern-python, --llama-python, --capture and --observed")
        for interpreter in (args.modern_python, args.llama_python):
            if not interpreter.is_file() or not os.access(interpreter, os.X_OK):
                parser.error("missing executable client interpreter %s" % interpreter)
        for fixture in (args.capture, args.observed):
            if not fixture.is_file():
                parser.error("missing capture fixture %s" % fixture)
        try:
            load_expected(args.expected)
        except (OSError, ValueError, KeyError, TypeError) as e:
            parser.error("invalid expected differences: %s" % e)
    if args.profile == "light" and (args.capture or args.modern_python or args.llama_python):
        parser.error("capture and client inputs apply to the full profile")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        out = output_directory(args.out, "eski-functional-")
    except (OSError, ValueError) as e:
        parser.exit(2, "functional check: %s\n" % e)
    print("functional output %s" % out, flush=True)
    run = Run(args, out)
    rc = 2
    try:
        if args.server is not None and args.server.is_file():
            run.server_hash = sha256(args.server)
        if args.resume:
            run.resume_from(args.resume)
        for offset in range(2 if args.profile == "light" else 40):
            free_port(args.port_base + offset)
        if args.profile == "light":
            run.light()
        else:
            run.full()
        rc = int(not run.rows or any(row.get("exit_code", 2) for row in run.rows))
    except KeyboardInterrupt:
        rc = 130
        run.rows.append({"step": "functional-check", "exit_code": rc, "error": "interrupted"})
    except (OSError, ValueError, KeyError) as e:
        run.rows.append({"step": "functional-check", "exit_code": rc, "error": str(e)})
    finally:
        run.save(rc)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
