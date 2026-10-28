import argparse
import fnmatch
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone


ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
MARKER = re.compile(r"^\[(ok|err|skip|ignore|exception|ready|TIMEOUT|\d+/\d+ done)\]: ?(.*)$")
OK_ELAPSED = re.compile(r"^(.*) \(\d+ ms\)$")
ERR_HEAD = re.compile(r"^(.*) in (tests/\S+\.tcl)$")
IGNORE_SPLIT = re.compile(
    r"^(?:(.*): )?("
    r"Tag: none of the tags allowed"
    r"|Tag: \S+ denied"
    r"|Not supported[^:]*"
    r"|Other server path not provided"
    r"|large memory flag not provided"
    r"|TCL version is too low and does not support this"
    r")$"
)
CONTEXT_SUFFIX = re.compile(r"\s+\((?:context|detail): .*$")
UNKNOWN_COMMAND = re.compile(r"unknown command '([^']*)'", re.IGNORECASE)
UNKNOWN_SUBCOMMAND = re.compile(r"unknown subcommand '([^']*)'\. Try (\S+) HELP", re.IGNORECASE)
WRONG_ARITY = re.compile(r"wrong number of arguments for '([^']*)' command", re.IGNORECASE)
QUOTED = re.compile(r"'[^']*'")
NUMBER = re.compile(r"\b\d+\b")
SECTION_STARTS = (
    "Testing ",
    "The End",
    "Execution time of different units:",
    "Cleanup: ",
    "Starting test server at port",
    "Killing still running",
)
SUMMARY_SCHEMA = 2
SUITES = ("redis", "valkey")
SUITE_PREFIX = re.compile(r"^([A-Za-z0-9_.-]+):(?!:)(.*)$")


def strip_ansi(text):
    return ANSI.sub("", text)


def new_unit_result():
    return {
        "passed": 0,
        "failed": 0,
        "skipped": 0,
        "skipped_by_tag": 0,
        "errored": 0,
        "tests": {},
        "failures": [],
        "errors": [],
        "ended": False,
        "all_passed_banner": False,
        "final_failed_count": None,
        "timeout": False,
        "exception": False,
    }


def test_entry(result, name):
    entry = result["tests"].get(name)
    if entry is None:
        entry = {"passed": 0, "failed": 0, "skipped": 0}
        result["tests"][name] = entry
    return entry


def error_reason(details):
    lines = [line.rstrip() for line in details if line.strip()]
    if not lines:
        return ""
    raw = lines[0]
    first = raw.strip()
    if len(lines) > 1:
        second = lines[1].strip()
        if first and second.endswith(first) and 0 < len(second) - len(raw) <= 10:
            return second
    return CONTEXT_SUFFIX.sub("", first)


def reason_key(reason):
    sub = UNKNOWN_SUBCOMMAND.search(reason)
    if sub:
        return "unknown subcommand '%s %s'" % (sub.group(2).upper(), sub.group(1).lower())
    cmd = UNKNOWN_COMMAND.search(reason)
    if cmd:
        return "unknown command '%s'" % cmd.group(1).lower()
    arity = WRONG_ARITY.search(reason)
    if arity:
        return "wrong number of arguments for '%s'" % arity.group(1).lower()
    if reason.startswith("Executing test client: "):
        reason = reason[len("Executing test client: "):]
    key = QUOTED.sub("'...'", reason)
    key = NUMBER.sub("N", key)
    return key[:160]


def finish_err(result, block):
    if block is None:
        return
    head = block[0]
    details = block[1:]
    match = ERR_HEAD.match(head)
    if match:
        name = match.group(1)
        reason = error_reason(details)
        test_entry(result, name)["failed"] += 1
        result["failed"] += 1
        result["failures"].append({
            "test": name,
            "reason": reason,
            "message": "\n".join(details[:12]),
        })
    else:
        reason = error_reason(block)
        result["errored"] += 1
        result["errors"].append({
            "kind": "block",
            "reason": reason,
            "message": "\n".join(block[:12]),
        })


def parse_log(text):
    result = new_unit_result()
    pending = None
    exception = None
    in_end = False
    final_entries = []
    for raw in text.splitlines():
        line = strip_ansi(raw).rstrip("\r")
        if in_end:
            if line.startswith("*** "):
                final_entries.append([line[4:]])
            elif final_entries and line and not line.startswith(("Cleanup: ", "\\o/")):
                final_entries[-1].append(line)
            if "All tests passed without errors!" in line:
                result["all_passed_banner"] = True
            continue
        marker = MARKER.match(line)
        if marker is None:
            stripped = line.strip()
            if stripped == "The End" or line.startswith(SECTION_STARTS):
                finish_err(result, pending)
                pending = None
                if exception is not None:
                    result["errors"].append(exception)
                    exception = None
                if stripped == "The End":
                    result["ended"] = True
                    in_end = True
                continue
            if pending is not None:
                pending.append(line)
            elif exception is not None:
                exception["lines"].append(line)
            continue
        finish_err(result, pending)
        pending = None
        status, data = marker.group(1), marker.group(2)
        if status == "ok":
            elapsed = OK_ELAPSED.match(data)
            name = elapsed.group(1) if elapsed else data
            test_entry(result, name)["passed"] += 1
            result["passed"] += 1
        elif status == "err":
            pending = [data]
        elif status == "skip":
            test_entry(result, data)["skipped"] += 1
            result["skipped"] += 1
        elif status == "ignore":
            result["skipped"] += 1
            result["skipped_by_tag"] += 1
            split = IGNORE_SPLIT.match(data)
            if split and split.group(1):
                test_entry(result, split.group(1))["skipped"] += 1
        elif status == "exception":
            result["exception"] = True
            exception = {"kind": "exception", "lines": [data]}
        elif status == "TIMEOUT":
            result["timeout"] = True
    finish_err(result, pending)
    if exception is not None:
        result["errors"].append(exception)
    for error in result["errors"]:
        if "lines" in error:
            lines = error.pop("lines")
            error["reason"] = error_reason(lines)
            error["message"] = "\n".join(lines[:12])
    if result["exception"]:
        result["errored"] += 1
    if result["ended"]:
        result["final_failed_count"] = len(final_entries)
    for entry in final_entries:
        head = entry[0]
        if head.startswith("[TIMEOUT]: "):
            match = ERR_HEAD.match(head[len("[TIMEOUT]: "):])
            name = match.group(1) if match else head[len("[TIMEOUT]: "):]
            test_entry(result, name)["failed"] += 1
            result["failed"] += 1
            result["failures"].append({"test": name, "reason": "timeout", "message": head})
    if result["timeout"]:
        result["errored"] += 1
        result["errors"].append({"kind": "timeout", "reason": "suite reported no progress", "message": ""})
    return result


def canonical_unit(name):
    name = name.strip()
    if name.startswith("tests/"):
        name = name[len("tests/"):]
    if name.endswith(".tcl"):
        name = name[:-len(".tcl")]
    if name.startswith(("unit/", "integration/")):
        return name
    return "unit/" + name


def display_unit(canonical):
    if canonical.startswith("unit/"):
        return canonical[len("unit/"):]
    return canonical


def parse_known(text, suite=None):
    units = []
    tests = []
    problems = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        prefix = SUITE_PREFIX.match(line)
        if prefix:
            name = prefix.group(1)
            if name not in SUITES:
                problems.append("line %d: unknown suite prefix '%s:', expected one of %s" % (
                    number, name, ", ".join(s + ":" for s in SUITES)))
                continue
            line = prefix.group(2).strip()
            if not line:
                problems.append("line %d: '%s:' is not followed by a unit or test" % (number, name))
                continue
            if name != suite:
                continue
        if "::" in line:
            unit, name = line.split("::", 1)
            tests.append((canonical_unit(unit), name))
        else:
            units.append(canonical_unit(line))
    return {"units": units, "tests": tests, "problems": problems}


def read_known(path, suite=None):
    if not path or not os.path.exists(path):
        return {"units": [], "tests": [], "problems": []}
    with open(path, encoding="utf-8", errors="replace") as handle:
        return parse_known(handle.read(), suite)


def unit_is_known(known, canonical):
    return any(fnmatch.fnmatchcase(canonical, pattern) for pattern in known["units"])


def known_tests_for(known, canonical):
    return [name for pattern, name in known["tests"] if fnmatch.fnmatchcase(canonical, pattern)]


def test_is_known(known, canonical, name):
    return name in known_tests_for(known, canonical)


def plan(tree, known, units):
    lines = []
    problems = ["known failures %s" % p for p in known.get("problems", [])]
    seen = set()
    for unit in units:
        if not unit.strip():
            continue
        canonical = canonical_unit(unit)
        if canonical in seen:
            continue
        seen.add(canonical)
        if not os.path.isfile(os.path.join(tree, "tests", canonical + ".tcl")):
            problems.append("unknown unit '%s': tests/%s.tcl does not exist in the pinned suite" % (unit, canonical))
            continue
        action = "skip" if unit_is_known(known, canonical) else "run"
        lines.append("%s\t%s\t%s" % (action, canonical, display_unit(canonical)))
        if action == "run":
            for name in known_tests_for(known, canonical):
                lines.append("test\t%s\t%s" % (canonical, name))
    return lines, problems


def read_meta(path):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.rstrip("\n")
            if not raw:
                continue
            fields = raw.split("\t")
            while len(fields) < 7:
                fields.append("")
            canonical, action, rc, seconds, log, crashed, killed = fields[:7]
            rows.append({
                "canonical": canonical,
                "action": action,
                "rc": int(rc) if rc.lstrip("-").isdigit() else None,
                "seconds": int(seconds) if seconds.isdigit() else 0,
                "log": log,
                "server_crashed": crashed == "1",
                "killed": killed == "1",
            })
    return rows


def relative(path, root):
    if not path:
        return path
    full = os.path.abspath(path)
    base = os.path.abspath(root)
    if full == base or full.startswith(base + os.sep):
        return os.path.relpath(full, base)
    return path


def unit_status(result, row):
    if row["action"] == "skip":
        return "out-of-scope"
    if row["server_crashed"]:
        return "server-crashed"
    if result["exception"]:
        return "exception"
    if result["timeout"] or row["killed"]:
        return "timeout"
    if not result["ended"]:
        return "incomplete"
    if result["failed"] or result["errored"]:
        return "failed"
    if result["passed"] == 0:
        return "all-skipped" if result["skipped"] else "empty"
    return "ok"


def build_unit(row, known, root):
    canonical = row["canonical"]
    if row["action"] == "skip":
        result = new_unit_result()
    else:
        try:
            with open(row["log"], encoding="utf-8", errors="replace") as handle:
                result = parse_log(handle.read())
        except OSError:
            result = new_unit_result()
            result["errors"].append({"kind": "missing-log", "reason": "no suite output was captured", "message": row["log"]})
            result["errored"] += 1
    status = unit_status(result, row)
    if status == "server-crashed":
        result["errored"] += 1
        result["errors"].append({"kind": "server-crashed", "reason": "the server exited during this unit", "message": ""})
    elif status == "incomplete":
        result["errored"] += 1
        result["errors"].append({"kind": "incomplete", "reason": "the suite ended without its final report", "message": ""})
    elif status == "timeout" and not result["timeout"]:
        result["errored"] += 1
        result["errors"].append({"kind": "timeout", "reason": "the unit hit the runner's hard timeout", "message": ""})
    failing = []
    for name, counts in result["tests"].items():
        if counts["failed"]:
            failing.append(name)
    warnings = []
    if result["final_failed_count"] is not None:
        expected = result["failed"] + sum(1 for e in result["errors"] if e["kind"] == "block")
        if result["final_failed_count"] != expected:
            warnings.append("parsed %d failures but the suite listed %d" % (expected, result["final_failed_count"]))
    return {
        "unit": canonical,
        "status": status,
        "passed": result["passed"],
        "failed": result["failed"],
        "skipped": result["skipped"],
        "skipped_by_tag": result["skipped_by_tag"],
        "errored": result["errored"],
        "seconds": row["seconds"],
        "suite_exit_code": row["rc"],
        "log": relative(row["log"], root) if row["action"] != "skip" else None,
        "failing_tests": failing,
        "known_failing_tests": [n for n in failing if test_is_known(known, canonical, n)],
        "failures": result["failures"],
        "errors": result["errors"],
        "warnings": warnings,
        "tests": result["tests"],
    }


def reason_histogram(units):
    counter = Counter()
    where = {}
    for name, unit in units.items():
        for failure in unit["failures"]:
            key = reason_key(failure["reason"])
            counter[key] += 1
            where.setdefault(key, set()).add(name)
        for error in unit["errors"]:
            if error["kind"] in ("block", "exception"):
                key = reason_key(error["reason"])
                counter[key] += 1
                where.setdefault(key, set()).add(name)
    return [
        {"reason": key, "count": count, "units": sorted(where[key])}
        for key, count in counter.most_common(25)
    ]


def unexpected_failures(units, known):
    out = []
    for name, unit in units.items():
        if unit["status"] == "out-of-scope":
            continue
        for test in unit["failing_tests"]:
            if test not in unit["known_failing_tests"]:
                out.append("%s::%s" % (name, test))
        for error in unit["errors"]:
            out.append("%s::<%s> %s" % (name, error["kind"], error["reason"][:200]))
    return out


def suite_identity(summary):
    suite = summary.get("suite") if isinstance(summary, dict) else None
    if not isinstance(suite, dict):
        return None, None
    if suite.get("name"):
        return suite.get("name"), suite.get("tag")
    if suite.get("valkey_tag"):
        return "valkey", suite.get("valkey_tag")
    return None, None


def suite_label(name, tag):
    if not name:
        return "an unrecorded suite"
    if tag:
        return "the %s %s suite" % (name, tag)
    return "the %s suite" % name


def baseline_problem(baseline, baseline_path, name, tag):
    base_name, base_tag = suite_identity(baseline)
    if base_name is None:
        return ("baseline %s does not record which suite produced it; record a new one with "
                "run.sh --suite %s --summary <path>" % (baseline_path, name))
    if base_name != name:
        return ("baseline %s was recorded with %s and this run uses %s; summaries from different "
                "suites are never compared, pass a baseline recorded with --suite %s, such as "
                "test/conformance/baseline-%s.json" % (
                    baseline_path, suite_label(base_name, base_tag), suite_label(name, tag), name, name))
    return None


def compare_baseline(baseline, units):
    regressions = []
    improvements = []
    base_units = baseline.get("units", {})
    compared = []
    base_passed = 0
    for name, unit in units.items():
        if unit["status"] == "out-of-scope" or name not in base_units:
            continue
        compared.append(name)
        base_tests = base_units[name].get("tests", {})
        base_passed += base_units[name].get("passed", 0)
        for test, counts in base_tests.items():
            before = counts.get("passed", 0)
            if before <= 0:
                continue
            now = unit["tests"].get(test, {"passed": 0, "failed": 0, "skipped": 0})
            if now["passed"] < before:
                if now["failed"]:
                    state = "failed"
                elif now["skipped"]:
                    state = "skipped"
                else:
                    state = "not run"
                regressions.append({
                    "unit": name,
                    "test": test,
                    "baseline_passed": before,
                    "current_passed": now["passed"],
                    "now": state,
                })
        for test, counts in unit["tests"].items():
            before = base_tests.get(test, {}).get("passed", 0)
            if counts["passed"] > before:
                improvements.append("%s::%s" % (name, test))
    current_passed = sum(units[n]["passed"] for n in compared)
    return {
        "units_compared": compared,
        "baseline_passed": base_passed,
        "current_passed": current_passed,
        "regressions": regressions,
        "newly_passing": improvements,
    }


def build_summary(rows, known, root, info, baseline=None, baseline_path=None):
    units = {}
    for row in rows:
        units[display_unit(row["canonical"])] = build_unit(row, known, root)
    ran = [u for u in units.values() if u["status"] != "out-of-scope"]
    totals = {
        "units_run": len(ran),
        "units_out_of_scope": len(units) - len(ran),
        "passed": sum(u["passed"] for u in ran),
        "failed": sum(u["failed"] for u in ran),
        "skipped": sum(u["skipped"] for u in ran),
        "errored": sum(u["errored"] for u in ran),
        "known_failures": sum(len(u["known_failing_tests"]) for u in ran),
    }
    unexpected = unexpected_failures(units, known)
    summary = {
        "schema": SUMMARY_SCHEMA,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "suite": info,
        "units": units,
        "totals": totals,
        "failing_tests": ["%s::%s" % (n, t) for n, u in units.items() for t in u["failing_tests"]],
        "unexpected_failures": unexpected,
        "failure_reasons": reason_histogram(units),
    }
    if baseline is not None:
        comparison = compare_baseline(baseline, units)
        base_name, base_tag = suite_identity(baseline)
        comparison["path"] = baseline_path
        comparison["baseline_suite"] = {"name": base_name, "tag": base_tag}
        comparison["baseline_tags"] = baseline.get("suite", {}).get("tags")
        summary["mode"] = "baseline"
        summary["baseline"] = comparison
        exit_code = 1 if comparison["regressions"] else 0
    else:
        summary["mode"] = "strict"
        summary["baseline"] = None
        exit_code = 1 if unexpected else 0
    summary["exit_code"] = exit_code
    return summary


def render_table(summary):
    rows = [("unit", "passed", "failed", "skipped", "errored", "status", "secs")]
    for name, unit in summary["units"].items():
        rows.append((name, str(unit["passed"]), str(unit["failed"]), str(unit["skipped"]),
                     str(unit["errored"]), unit["status"], str(unit["seconds"])))
    totals = summary["totals"]
    rows.append(("total", str(totals["passed"]), str(totals["failed"]), str(totals["skipped"]),
                 str(totals["errored"]), "", ""))
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    out = []
    for index, row in enumerate(rows):
        cells = []
        for i, cell in enumerate(row):
            if i == 0 or i == 5:
                cells.append(cell.ljust(widths[i]))
            else:
                cells.append(cell.rjust(widths[i]))
        out.append("  ".join(cells).rstrip())
        if index == 0 or index == len(rows) - 2:
            out.append("  ".join("-" * w for w in widths))
    return "\n".join(out)


def render_report(summary, summary_path):
    name, tag = suite_identity(summary)
    lines = [render_table(summary), ""]
    sha = summary["suite"].get("sha256")
    lifted = summary["suite"].get("external_skip_lifted")
    lines.append("Suite: %s%s%s." % (
        suite_label(name, tag),
        ", tarball sha256 %s" % sha if sha else "",
        ", external:skip lifted at %s" % lifted if lifted else ""))
    totals = summary["totals"]
    lines.append("Pass count: %d passed, %d failed, %d skipped, %d errored across %d units (%d out of scope)." % (
        totals["passed"], totals["failed"], totals["skipped"], totals["errored"],
        totals["units_run"], totals["units_out_of_scope"]))
    reasons = summary["failure_reasons"][:10]
    if reasons:
        lines.append("")
        lines.append("Most common failure reasons:")
        for item in reasons:
            lines.append("  %5d  %s" % (item["count"], item["reason"]))
    lines.append("")
    if summary["mode"] == "baseline":
        comparison = summary["baseline"]
        base = comparison.get("baseline_suite") or {}
        lines.append("Mode: baseline. The run fails only when a test that passed in %s, recorded with %s, does not pass now." % (
            comparison["path"], suite_label(base.get("name"), base.get("tag"))))
        lines.append("Strict mode, used when --baseline is not given, fails on any failing test or unit error not listed in known-failures.txt.")
        if base.get("tag") != tag:
            lines.append("Warning: the baseline was recorded with %s %s and this run used %s %s." % (
                base.get("name"), base.get("tag"), name, tag))
        if comparison["baseline_tags"] != summary["suite"].get("tags"):
            lines.append("Warning: the baseline was recorded with tags %r and this run used %r." % (
                comparison["baseline_tags"], summary["suite"].get("tags")))
        lines.append("Compared units: %d. Baseline passed %d, now %d. Newly passing tests: %d. Regressions: %d." % (
            len(comparison["units_compared"]), comparison["baseline_passed"], comparison["current_passed"],
            len(comparison["newly_passing"]), len(comparison["regressions"])))
        for item in comparison["regressions"][:50]:
            lines.append("  REGRESSION %s::%s (passed %d before, %d now, %s)" % (
                item["unit"], item["test"], item["baseline_passed"], item["current_passed"], item["now"]))
    else:
        lines.append("Mode: strict. The run fails on any failing test or unit error not listed in known-failures.txt.")
        lines.append("Baseline mode, enabled with --baseline <summary.json>, fails only on tests that passed in the baseline and do not pass now.")
        unexpected = summary["unexpected_failures"]
        lines.append("Unexpected failures: %d." % len(unexpected))
        for item in unexpected[:20]:
            lines.append("  " + item)
        if len(unexpected) > 20:
            lines.append("  ... %d more in the summary file" % (len(unexpected) - 20))
    lines.append("Summary: %s" % summary_path)
    lines.append("Result: %s (exit %d)" % ("PASS" if summary["exit_code"] == 0 else "FAIL", summary["exit_code"]))
    return "\n".join(lines)


def write_json(path, data):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=True)
        handle.write("\n")
    os.replace(tmp, path)


def cmd_plan(args):
    known = read_known(args.known, args.suite)
    lines, problems = plan(args.tree, known, args.units.split(","))
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 2
    for line in lines:
        print(line)
    return 0


def load_baseline(path, root, name, tag):
    try:
        with open(path, encoding="utf-8") as handle:
            baseline = json.load(handle)
    except (OSError, ValueError) as exc:
        return None, "could not read baseline %s: %s" % (path, exc)
    problem = baseline_problem(baseline, relative(path, root), name, tag)
    if problem:
        return None, problem
    return baseline, None


def cmd_check_baseline(args):
    _, problem = load_baseline(args.baseline, args.root, args.suite_name, args.suite_tag)
    if problem:
        print("conformance: %s" % problem, file=sys.stderr)
        return 2
    return 0


def cmd_summarize(args):
    known = read_known(args.known, args.suite_name)
    rows = read_meta(args.meta)
    baseline = None
    if args.baseline:
        baseline, problem = load_baseline(args.baseline, args.root, args.suite_name, args.suite_tag)
        if problem:
            print("conformance: %s" % problem, file=sys.stderr)
            return 2
    info = {
        "name": args.suite_name,
        "tag": args.suite_tag,
        "sha256": args.suite_sha256,
        "url": args.suite_url,
        "external_skip_lifted": args.external_skip_lifted,
        "tags": args.tags,
        "server": args.server,
        "tcl": args.tcl,
        "known_failures": relative(args.known, args.root),
    }
    summary = build_summary(rows, known, args.root, info, baseline, relative(args.baseline, args.root) if args.baseline else None)
    for path in [args.out, args.latest] + (args.extra or []):
        write_json(path, summary)
    print(render_report(summary, relative(args.latest, args.root)))
    return summary["exit_code"]


def main(argv=None):
    parser = argparse.ArgumentParser(prog="parse_results.py")
    sub = parser.add_subparsers(dest="command", required=True)
    p_plan = sub.add_parser("plan")
    p_plan.add_argument("--tree", required=True)
    p_plan.add_argument("--known", required=True)
    p_plan.add_argument("--units", required=True)
    p_plan.add_argument("--suite", choices=SUITES, required=True)
    p_plan.set_defaults(func=cmd_plan)
    p_check = sub.add_parser("check-baseline")
    p_check.add_argument("--baseline", required=True)
    p_check.add_argument("--root", required=True)
    p_check.add_argument("--suite-name", choices=SUITES, required=True)
    p_check.add_argument("--suite-tag", default="")
    p_check.set_defaults(func=cmd_check_baseline)
    p_sum = sub.add_parser("summarize")
    p_sum.add_argument("--meta", required=True)
    p_sum.add_argument("--known", required=True)
    p_sum.add_argument("--root", required=True)
    p_sum.add_argument("--out", required=True)
    p_sum.add_argument("--latest", required=True)
    p_sum.add_argument("--extra", action="append")
    p_sum.add_argument("--baseline")
    p_sum.add_argument("--suite-name", choices=SUITES)
    p_sum.add_argument("--suite-tag", default="")
    p_sum.add_argument("--suite-sha256", default="")
    p_sum.add_argument("--suite-url", default="")
    p_sum.add_argument("--external-skip-lifted", default="")
    p_sum.add_argument("--tags", default="")
    p_sum.add_argument("--server", default="")
    p_sum.add_argument("--tcl", default="")
    p_sum.set_defaults(func=cmd_summarize)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
