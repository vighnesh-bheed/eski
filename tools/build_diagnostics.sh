#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-release}"
case "$mode" in release|address|thread|all) ;; *) echo 'usage: tools/build_diagnostics.sh [release|address|thread|all]' >&2; exit 2 ;; esac
DIAG_CC="${ESKI_DIAGNOSTICS_CC:-clang}"
DIAG_AR="${ESKI_DIAGNOSTICS_AR:-ar}"
for tool in "$DIAG_CC" "$DIAG_AR" sha256sum flock; do command -v "$tool" >/dev/null || { echo "diagnostics build tool missing: $tool" >&2; exit 1; }; done
DIAG_CC="$(command -v "$DIAG_CC")"
DIAG_AR="$(command -v "$DIAG_AR")"
common=(-std=c11 -fPIC -fvisibility=hidden -Wall -Wextra -Werror "-ffile-prefix-map=$PWD=." "-fdebug-prefix-map=$PWD=.")
if [ -n "${ESKI_DIAGNOSTICS_INCLUDE:-}" ]; then
 common+=("-I$ESKI_DIAGNOSTICS_INCLUDE")
elif [ -f .build/diagnostics/include/libunwind.h ]; then
 common+=("-I$PWD/.build/diagnostics/include")
fi
unwind_library="${ESKI_DIAGNOSTICS_UNWIND_LIBRARY:-$("$DIAG_CC" -print-file-name=libunwind.so.8)}"
[ -f "$unwind_library" ] || { echo 'libunwind8 runtime library missing' >&2; exit 1; }
mkdir -p .build/diagnostics
exec 8>.build/diagnostics/.lock
flock 8
ln -sfn "$(realpath "$unwind_library")" .build/diagnostics/libunwind.so
source=src/diagnostics_native/diagnostics.c
temporary=""
trap 'if [ -n "$temporary" ]; then rm -rf "$temporary"; fi' EXIT
build_mode() {
 local selected="$1" destination fingerprint
 local -a flags
 case "$selected" in
  release) flags=(-O2 -DNDEBUG) ;;
  address) flags=(-O1 -g -fno-omit-frame-pointer -fsanitize=address) ;;
  thread) flags=(-O1 -g -fno-omit-frame-pointer -fsanitize=thread) ;;
 esac
 fingerprint="$({ printf '%s\0' "$DIAG_CC" "$DIAG_AR" "$selected" "${common[@]}" "${flags[@]}"; "$DIAG_CC" --version; sha256sum tools/build_diagnostics.sh "$source" "$unwind_library"; "$DIAG_CC" "${common[@]}" -E "$source"; } | sha256sum | cut -d' ' -f1)"
 destination=".build/diagnostics/$selected"
 if [ -f "$destination/input.sha256" ] && [ "$(cat "$destination/input.sha256")" = "$fingerprint" ] && (cd "$destination" && sha256sum --check --strict --quiet archive.sha256); then echo "Diagnostics helper ready ($selected)"; return; fi
 temporary="$(mktemp -d ".build/diagnostics/.$selected.XXXXXX")"
 "$DIAG_CC" "${common[@]}" "${flags[@]}" -c "$source" -o "$temporary/diagnostics.o"
 "$DIAG_AR" rcsD "$temporary/libeski-diagnostics.a" "$temporary/diagnostics.o"
 printf '%s\n' "$fingerprint" > "$temporary/input.sha256"
 (cd "$temporary" && sha256sum libeski-diagnostics.a > archive.sha256)
 rm -rf "$destination"
 mv "$temporary" "$destination"
 temporary=""
 echo "Diagnostics helper built ($selected)"
}
if [ "$mode" = all ]; then for selected in release address thread; do build_mode "$selected"; done; else build_mode "$mode"; fi
