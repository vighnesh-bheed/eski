#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-release}"
case "$mode" in
	release|address|thread|all) ;;
	*) printf 'usage: tools/build_lua.sh [release|address|thread|all]\n' >&2; exit 2 ;;
esac

LUA_CC="${ESKI_LUA_CC:-clang}"
LUA_AR="${ESKI_LUA_AR:-ar}"
for tool in "$LUA_CC" "$LUA_AR" sha256sum flock; do
	command -v "$tool" >/dev/null 2>&1 || { printf 'Lua dependency tool not found: %s\n' "$tool" >&2; exit 1; }
done
LUA_CC="$(command -v "$LUA_CC")"
LUA_AR="$(command -v "$LUA_AR")"
lua_root=third_party/lua
test -f "$lua_root/SHA256SUMS" || { printf 'vendored Lua checksum manifest is missing\n' >&2; exit 1; }
(cd "$lua_root" && sha256sum --check --strict --quiet SHA256SUMS)

core=(lapi lcode lctype ldebug ldo ldump lfunc lgc llex lmem lobject lopcodes lparser lstate lstring ltable ltm lundump lvm lzio)
libraries=(lauxlib lbaselib lmathlib lstrlib ltablib)
sources=()
for source in "${core[@]}" "${libraries[@]}"; do
	sources+=("$lua_root/vendor/lua-5.5.1/src/$source.c")
done
shopt -s nullglob
runtime_sources=("$lua_root"/runtime/*.c)
test "${#runtime_sources[@]}" -gt 0 || { printf 'Lua protection shim sources are missing\n' >&2; exit 1; }
sources+=("${runtime_sources[@]}")
common=(-std=c11 -fPIC -fvisibility=hidden -D_POSIX_C_SOURCE=200809L -DLUA_USE_POSIX -Wall -Wextra
        "-ffile-prefix-map=$PWD=." "-fdebug-prefix-map=$PWD=."
        "-I$lua_root/include" "-I$lua_root/runtime" "-I$lua_root/vendor/lua-5.5.1/src")
mkdir -p .build/lua
exec 9>.build/lua/.lock
flock 9
temporary=""
trap 'if [ -n "$temporary" ]; then rm -rf "$temporary"; fi' EXIT

build_mode() {
	local selected="$1" destination fingerprint source stem
	local -a flags objects
	case "$selected" in
		release) flags=(-O2 -DNDEBUG) ;;
		address) flags=(-O1 -g -fno-omit-frame-pointer -fsanitize=address) ;;
		thread) flags=(-O1 -g -fno-omit-frame-pointer -fsanitize=thread) ;;
	esac
	fingerprint="$({
		printf '%s\0' "$LUA_CC" "$LUA_AR" "$selected" "${common[@]}" "${flags[@]}"
		"$LUA_CC" --version
		"$LUA_AR" --version
		sha256sum tools/build_lua.sh
		find "$lua_root" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
	} | sha256sum | cut -d' ' -f1)"
	destination=".build/lua/$selected"
	if [ -f "$destination/input.sha256" ] && [ -f "$destination/libeslua-runtime.a" ] \
	   && [ "$(cat "$destination/input.sha256")" = "$fingerprint" ] \
	   && (cd "$destination" && sha256sum --check --strict --quiet archive.sha256); then
		printf 'Lua runtime ready (%s)\n' "$selected"
		return
	fi
	temporary="$(mktemp -d ".build/lua/.$selected.XXXXXX")"
	objects=()
	for source in "${sources[@]}"; do
		stem="${source//\//_}"
		stem="${stem%.c}"
		"$LUA_CC" "${common[@]}" "${flags[@]}" -c "$source" -o "$temporary/$stem.o"
		objects+=("$temporary/$stem.o")
	done
	"$LUA_AR" rcsD "$temporary/libeslua-runtime.a" "${objects[@]}"
	printf '%s\n' "$fingerprint" > "$temporary/input.sha256"
	(cd "$temporary" && sha256sum libeslua-runtime.a > archive.sha256)
	rm -f "$temporary"/*.o
	rm -rf "$destination"
	mv "$temporary" "$destination"
	temporary=""
	printf 'built Lua runtime (%s)\n' "$selected"
}

if [ "$mode" = all ]; then
	for selected in release address thread; do build_mode "$selected"; done
else
	build_mode "$mode"
fi
