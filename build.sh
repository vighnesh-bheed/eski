#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

usage() {
	echo "usage: ./build.sh [release|debug|sanitizer|check]" >&2
}

mode="${1:-release}"
case "$mode" in
	release|debug|sanitizer|check)
		;;
	*)
		usage
		exit 2
		;;
esac

ODIN="${ODIN:-}"
if [ -n "$ODIN" ]; then
	found="$(command -v "$ODIN" 2>/dev/null || true)"
	if [ -z "$found" ] || [ ! -x "$found" ]; then
		echo "ODIN is set to $ODIN but that is not an executable odin compiler" >&2
		exit 1
	fi
	ODIN="$found"
elif command -v odin >/dev/null 2>&1; then
	ODIN="$(command -v odin)"
elif [ -x "$HOME/odin/current/odin" ]; then
	ODIN="$HOME/odin/current/odin"
else
	echo "odin compiler not found; set ODIN, put odin on PATH or install it at $HOME/odin/current/odin" >&2
	exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
	echo "clang not found on PATH; odin links with clang, install it first" >&2
	exit 1
fi

has_sources() {
	compgen -G "$1/*.odin" >/dev/null
}

package_dirs() {
	local root dir
	if has_sources src; then
		echo src
	fi
	for root in src test bench; do
		if [ -d "$root" ]; then
			find "$root" -mindepth 1 -name '.*' -prune -o -type d -print | LC_ALL=C sort
		fi
	done | while IFS= read -r dir; do
		case "$dir" in
			test/storage|test/slab)
				continue
				;;
		esac
		if has_sources "$dir"; then
			echo "$dir"
		fi
	done
}

check_package() {
	local dir="$1"
	local entry="-no-entry-point"
	if grep -qsE '^main[[:space:]]*::[[:space:]]*proc' "$dir"/*.odin; then
		entry=""
	fi
	echo "check $dir"
	"$ODIN" check "$dir" -vet -strict-style -thread-count:2 $entry
}

scan_comments() {
	python3 -I - src test bench <<'PY'
import os
import sys


def comment_lines(text):
    found = []
    i = 0
    line = 1
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
        elif c == '"' or c == "'":
            i += 1
            while i < n and text[i] != c and text[i] != "\n":
                if text[i] == "\\" and i + 1 < n and text[i + 1] != "\n":
                    i += 1
                i += 1
            if i < n and text[i] == c:
                i += 1
        elif c == "`":
            i += 1
            while i < n and text[i] != "`":
                if text[i] == "\n":
                    line += 1
                i += 1
            i += 1
        elif text.startswith("//", i):
            found.append(line)
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            found.append(line)
            depth = 1
            i += 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth += 1
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    if text[i] == "\n":
                        line += 1
                    i += 1
        else:
            i += 1
    return found


total = 0
for root in sys.argv[1:]:
    for base, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for name in sorted(files):
            if not name.endswith(".odin"):
                continue
            path = os.path.join(base, name)
            with open(path, "rb") as handle:
                text = handle.read().decode("utf-8", "replace")
            for line in comment_lines(text):
                print(path + ":" + str(line))
                total += 1
if total:
    print(str(total) + " comment(s) found; source files carry no comments", file=sys.stderr)
    sys.exit(1)
PY
}

run_check() {
	local failed=0 count=0 dir
	if ! command -v python3 >/dev/null 2>&1; then
		echo "python3 not found on PATH; the comment check needs it" >&2
		exit 1
	fi
	if ! has_sources src; then
		echo "src is not present yet: it holds no .odin files, skipping the src package"
	fi
	while IFS= read -r dir; do
		count=$((count + 1))
		if ! check_package "$dir"; then
			echo "check failed: $dir" >&2
			failed=1
		fi
	done < <(package_dirs)
	if [ "$count" -eq 0 ]; then
		echo "no packages to check yet"
	fi
	echo "scan for comments in src, test and bench"
	if ! scan_comments; then
		failed=1
	fi
	if [ "$failed" -ne 0 ]; then
		echo "check failed" >&2
		exit 1
	fi
	echo "check passed ($count packages)"
}

if [ "$mode" = "check" ]; then
	run_check
	exit 0
fi

if ! has_sources src; then
	echo "src is not present yet: it holds no .odin files, nothing to build" >&2
	exit 1
fi

mkdir -p bin
case "$mode" in
	release)
		"$ODIN" build src -o:speed -out:bin/eski
		;;
	debug)
		"$ODIN" build src -debug -out:bin/eski
		;;
	sanitizer)
		"$ODIN" build src -debug -sanitize:address -out:bin/eski
		;;
esac
echo "built bin/eski ($mode)"
