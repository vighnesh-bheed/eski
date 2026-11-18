import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "test/search"))
from compare import free_port, load_expected, output_directory, reference_server

PYTHON = (sys.executable, "-IB")
MODES = ("labelled", "owners-shared", "owners-user", "owners-only-user")


def relative(path):
    return ROOT / path


def stop_step(process):
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=12)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


class Run:
    def __init__(self, args, out):
        self.args = args
        self.out = out
        self.base = args.port_base
        self.ports = "%s-%s" % (self.base + 20, self.base + 39)
        self.binary = args.server or relative("bin/eski")
        self.rows = []
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

    def step(self, name, command, seconds, overrides=None, validate=None):
        log_path = self.out / (name + ".log")
        print(name, flush=True)
        start = time.monotonic()
        row = {"step": name, "log": log_path.name}
        self.rows.append(row)
        try:
            with log_path.open("wb") as log:
                process = subprocess.Popen(list(map(str, command)), cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                           env=dict(self.env, **(overrides or {})), start_new_session=True)
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
            self.save()
        print("%s exit %s" % (name, row["exit_code"]), flush=True)
        return row["exit_code"] == 0

    def save(self, exit_code=None):
        path = self.out / "summary.json"
        pending = path.with_suffix(".tmp")
        pending.write_text(json.dumps({"profile": self.args.profile, "server": str(self.binary),
                                       "exit_code": exit_code, "steps": self.rows}, indent=2) + "\n")
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

        if self.step(name, command, 14400, validate=validate):
            return summary
        return None

    def compare(self, name, extra=()):
        return self.step(name, [relative("test/search/compare.sh"), "--server", self.binary,
                                "--port", self.base, "--reference-port", self.base + 1,
                                "--out", self.out / name, *extra], 1800)

    def full(self):
        self.step("strict-check", [relative("build.sh"), "check"], 3600)
        self.step("documentation", [*PYTHON, relative("test/readme_tables.py"), "--check"], 90)
        if self.args.server is None and not self.step("release-build", [relative("build.sh"), "release"], 3600):
            return
        if not self.binary.is_file() or not os.access(self.binary, os.X_OK):
            raise ValueError("missing executable server %s" % self.binary)
        (self.out / "server.sha256").write_text(hashlib.sha256(self.binary.read_bytes()).hexdigest() + "\n")
        conformance = self.suite("conformance-off", "redis", relative("test/conformance/baseline-redis.json"))
        vectors = self.suite("vectorset-off", "vectorset", relative("test/conformance/baseline-vectorset.json"))
        scripting = self.suite("scripting-off", "redis", units="scripting")
        self.step("smoke-off", [relative("test/smoke.sh")], 14400,
                  {"ESKI_SMOKE_FULL_DIR": str(self.out / "smoke-off-differences")})
        self.step("vector-replies-off", [relative("test/vectorset/compare.sh"), "--summary", self.out / "vector-replies-off.json"], 3600)
        for mode in MODES:
            command = [relative("test/labelled/run.sh"), "--mode", mode, "--out", self.out / mode, "compare", "smoke"]
            for name, reference in (("conformance", conformance), ("scripting", scripting), ("vectorset", vectors)):
                if reference:
                    command += ["--%s-reference" % name, reference, name]
            self.step(mode, command, 21600)
        self.compare("search-smoke")
        self.compare("search-capture", ["--capture", self.args.capture, "--observed", self.args.observed,
                                        "--expected", self.args.expected])
        packages_ok = self.step("packages", [relative("test/run_packages.sh")], 28800)
        if not packages_ok:
            for name in ("json_commands", "json_search"):
                self.step(name, [*PYTHON, relative("test/compatibility/%s.py" % name),
                                 "--server", self.binary, "--ports", self.ports], 900)
        try:
            with reference_server(self.base + 1, self.out / "client-reference"):
                self.step("search-clients", [*PYTHON, relative("test/compatibility/search_clients/run.py"),
                          "--server", self.binary, "--ports", self.ports, "--reference-port", self.base + 1,
                          "--modern-python", self.args.modern_python, "--llama-python", self.args.llama_python], 900)
                for name in ("search_advanced", "search_pipeline"):
                    self.step(name + "-reference", [*PYTHON, relative("test/compatibility/%s.py" % name),
                              "--server", self.binary, "--ports", self.ports, "--reference-port", self.base + 1], 900)
        except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as e:
            self.rows.append({"step": "client-reference", "exit_code": 2, "error": str(e)})
            self.save()


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
    args = parser.parse_args()
    if not 1024 <= args.port_base <= 65496:
        parser.error("--port-base must allow 40 non-privileged ports")
    if bool(args.capture) != bool(args.observed):
        parser.error("--capture and --observed go together")
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
        for offset in range(2 if args.profile == "light" else 40):
            free_port(args.port_base + offset)
        if args.profile == "light":
            run.step("search-runner-tests", [*PYTHON, relative("test/search/test_compare.py")], 30)
            run.compare("search-smoke")
        else:
            run.full()
        rc = int(not run.rows or any(row.get("exit_code", 2) for row in run.rows))
    except KeyboardInterrupt:
        rc = 130
        run.rows.append({"step": "functional-check", "exit_code": rc, "error": "interrupted"})
    except (OSError, ValueError) as e:
        run.rows.append({"step": "functional-check", "exit_code": rc, "error": str(e)})
    finally:
        run.save(rc)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
