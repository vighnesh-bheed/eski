import json
import os
from pathlib import Path
import re
import sys


WORK_BRANCH = re.compile(r"(?:feature|task|chore|bugfix)/[a-z0-9]+(?:-[a-z0-9]+)*")
HOTFIX_BRANCH = re.compile(r"hotfix/[a-z0-9]+(?:-[a-z0-9]+)*")
DECORATION = re.compile(
    r"^\s*(?:#{1,6}\s|[-+*]\s|\d+[.)]\s|>\s?|\|.*\|\s*$)"
    r"|^\s*(?:={3,}|-{3,}|\*{3,}|_{3,}|~{3,})\s*$"
    r"|^\s*[A-Za-z][A-Za-z0-9 /&_-]{0,60}:\s*$"
    r"|`|\*\*|__"
    r"|(?<!\w)[*_][^\s*_][^\n]*?[*_](?!\w)"
    r"|!?\[[^\]\n]*\]\([^\n)]*\)"
    r"|\[[^\]\n]+\]\[[^\]\n]*\]"
    r"|</?[A-Za-z][^>]*>",
    re.MULTILINE,
)
ATTRIBUTION = re.compile(
    r"co-authored-by\s*:|generated with (?:claude(?: code)?|codex)",
    re.IGNORECASE,
)


def body_errors(body):
    if not isinstance(body, str) or not body.strip():
        return ["The body must explain the change and its purpose in plain prose."]
    errors = []
    words = len(body.split())
    if words > 500:
        errors.append(f"The body contains {words} words; the maximum is 500.")
    if DECORATION.search(body):
        errors.append("Use plain prose without headings, section labels or Markdown decoration.")
    if ATTRIBUTION.search(body):
        errors.append("Remove generated-by footers and attribution trailers.")
    return errors


def branch_errors(pull_request):
    base = pull_request.get("base", {})
    head = pull_request.get("head", {})
    base_ref = base.get("ref", "")
    head_ref = head.get("ref", "")
    base_repo = (base.get("repo") or {}).get("full_name", "").casefold()
    head_repo = (head.get("repo") or {}).get("full_name", "").casefold()
    same_repo = bool(base_repo) and base_repo == head_repo
    if base_ref == "main" and same_repo and head_ref == "stage":
        return []
    if base_ref == "stage" and same_repo:
        if head_ref == "dev" or HOTFIX_BRANCH.fullmatch(head_ref):
            return []
    if base_ref == "dev":
        if WORK_BRANCH.fullmatch(head_ref) or (same_repo and head_ref == "stage"):
            return []
    return [
        "Target dev from feature/, task/, chore/ or bugfix/ branches. "
        "Promote dev to stage and stage to main within this repository. "
        "Hotfixes target stage; stage may synchronize back into dev."
    ]


def event_errors(event):
    if "pull_request" in event:
        pull_request = event["pull_request"]
        return body_errors(pull_request.get("body")) + branch_errors(pull_request)
    if "issue" in event and "pull_request" not in event["issue"]:
        return body_errors(event["issue"].get("body"))
    return []


def main():
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if not event_path:
        print("GITHUB_EVENT_PATH must point to a GitHub event file.", file=sys.stderr)
        return 1
    try:
        event = json.loads(Path(event_path).read_text())
    except (OSError, json.JSONDecodeError):
        print("The GitHub event file could not be read.", file=sys.stderr)
        return 1
    errors = event_errors(event)
    for error in errors:
        print(error, file=sys.stderr)
    if not errors:
        print("Repository policy passed.")
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
