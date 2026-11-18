#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UV_VERSION="0.12.19"
CLIENT_PYTHON="3.12.14"
CHANGED=0

usage() {
	cat <<'USAGE'
usage: tools/host_setup.sh system USER | user [WORK] [--no-docker] | downloads | quiet | status

Prepares a Debian 13 host (Ubuntu 24.04 is checked too) for tools/rented_run.py.

  system USER   as root: installs the packages the build, the suites and the
                benchmark harness call, starts Docker and lets USER use it
  user [WORK]   as the operator: the pinned Odin build, the Lua and diagnostics
                archives, the two client environments, the archives the
                baseline plan reads, every image by digest and the conformance
                archives, fetched and verified; WORK holds the downloads and
                the environments (default ~/eski-host); --no-docker leaves out
                the images, and the conformance archives too unless native Tcl
                is installed
  downloads     as the operator: only the archives the baseline plan reads,
                into .build/downloads of this checkout, checked by SHA-256
  quiet         as root, then reboot: performance governor at every boot,
                SMT off and display drivers blacklisted on the kernel command
                line, package timers off, and perf allowed to record call
                graphs and resolve kernel symbols (kernel.perf_event_paranoid=1,
                kernel.kptr_restrict=0); do this before correctness starts
  status        prints what each part would still change, changing nothing

Every part can run again; it reports each change it makes and each state it
found already in place.
USAGE
}

say() { printf '%s\n' "$*"; }
changed() { CHANGED=1; say "changed: $*"; }
kept() { say "already: $*"; }
die() { say "host setup: $*" >&2; exit 1; }

os_id() {
	. /etc/os-release
	printf '%s %s\n' "$ID" "${VERSION_ID:-}"
}

dockerfile_arg() {
	sed -n "s/^ARG $1=//p" "$ROOT/Dockerfile" | head -n 1
}

packages() {
	local id version
	read -r id version < <(os_id)
	local common=(ca-certificates curl git jq tmux tar xz-utils coreutils util-linux iproute2 procps
		clang lld binutils libc6-dev libssl-dev libunwind-dev liblzma-dev openssl
		python3 python3-venv tcl8.6 docker.io lm-sensors)
	case "$id $version" in
		"debian 13"*) printf '%s\n' "${common[@]}" libclang-rt-19-dev linux-perf linux-cpupower ;;
		"ubuntu 24.04"*) printf '%s\n' "${common[@]}" libclang-rt-18-dev linux-tools-common linux-tools-generic ;;
		*) die "this script is written for Debian 13 and checked on Ubuntu 24.04, not $id $version" ;;
	esac
}

part_system() {
	local user="${1:-}" missing=() name
	[ "$(id -u)" = 0 ] || die "system runs as root"
	[ -n "$user" ] && id "$user" >/dev/null 2>&1 || die "system needs the operator's login name"
	while IFS= read -r name; do
		if dpkg-query -W -f='${Status}' "$name" 2>/dev/null | grep -q 'install ok installed'; then
			continue
		fi
		missing+=("$name")
	done < <(packages)
	if [ "${#missing[@]}" -gt 0 ]; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -q
		apt-get install -y -q --no-install-recommends "${missing[@]}"
		changed "installed ${missing[*]}"
	else
		kept "every package is installed"
	fi
	if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
		if ! systemctl is-active --quiet docker; then
			systemctl enable --now docker
			changed "Docker started and enabled"
		else
			kept "Docker is running"
		fi
	fi
	if id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
		kept "$user is in the docker group"
	else
		usermod -aG docker "$user"
		changed "$user added to the docker group (log in again)"
	fi
	if command -v loginctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
		if [ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" = yes ]; then
			kept "$user keeps user services after logout"
		else
			loginctl enable-linger "$user"
			changed "$user keeps user services after logout"
		fi
	fi
}

part_odin() {
	local work="$1" release sha archive target
	release="$(dockerfile_arg ODIN_RELEASE)"
	sha="$(dockerfile_arg ODIN_SHA256)"
	[ -n "$release" ] && [ -n "$sha" ] || die "the Dockerfile names no Odin release"
	target="$HOME/odin/$release"
	if [ -x "$target/odin" ] && [ "$(readlink "$HOME/odin/current" 2>/dev/null)" = "$target" ]; then
		kept "Odin $release at $target"
		return
	fi
	archive="$work/odin-linux-amd64-$release.tar.gz"
	if [ ! -f "$archive" ] || [ "$(sha256sum "$archive" | cut -d' ' -f1)" != "$sha" ]; then
		curl --fail --location --silent --show-error --retry 3 --output "$archive.part" \
			"https://github.com/odin-lang/Odin/releases/download/$release/odin-linux-amd64-$release.tar.gz"
		mv "$archive.part" "$archive"
	fi
	[ "$(sha256sum "$archive" | cut -d' ' -f1)" = "$sha" ] || die "the Odin archive does not match $sha"
	rm -rf "$target.part"
	mkdir -p "$target.part"
	tar -xzf "$archive" -C "$target.part" --strip-components=1 --no-same-owner
	rm -rf "$target"
	mv "$target.part" "$target"
	ln -sfn "$target" "$HOME/odin/current"
	changed "Odin $release verified by SHA-256 and installed at $target, linked from ~/odin/current"
}

part_archives() {
	ODIN="$HOME/odin/current/odin" bash "$ROOT/tools/build_lua.sh" all >/dev/null
	ODIN="$HOME/odin/current/odin" bash "$ROOT/tools/build_diagnostics.sh" all >/dev/null
	say "ready: Lua and diagnostics archives (release, address, thread) under .build"
}

part_clients() {
	local work="$1" uv name env
	uv="$work/uv/bin/uv"
	if [ ! -x "$uv" ] || [ "$("$uv" --version | cut -d' ' -f2)" != "$UV_VERSION" ]; then
		rm -rf "$work/uv"
		python3 -I -m venv "$work/uv"
		"$work/uv/bin/python3" -I -m pip install --quiet --disable-pip-version-check "uv==$UV_VERSION"
		changed "uv $UV_VERSION in $work/uv"
	else
		kept "uv $UV_VERSION"
	fi
	for name in modern llama; do
		env="$work/clients/$name"
		if [ -x "$env/bin/python" ] && "$env/bin/python" -I -c 'import platform,sys; sys.exit(platform.python_version() != sys.argv[1])' "$CLIENT_PYTHON" &&
			[ "$("$uv" pip freeze --python "$env/bin/python" 2>/dev/null | LC_ALL=C sort)" = "$(LC_ALL=C sort "$ROOT/test/compatibility/search_clients/requirements-$name.txt")" ]; then
			kept "$name client environment matches its lock file"
			continue
		fi
		rm -rf "$env"
		"$uv" python install --quiet "$CLIENT_PYTHON"
		"$uv" venv --quiet --python "$CLIENT_PYTHON" "$env"
		"$uv" pip sync --quiet --python "$env/bin/python" "$ROOT/test/compatibility/search_clients/requirements-$name.txt"
		[ "$("$uv" pip freeze --python "$env/bin/python" | LC_ALL=C sort)" = "$(LC_ALL=C sort "$ROOT/test/compatibility/search_clients/requirements-$name.txt")" ] ||
			die "the $name environment does not match its lock file"
		changed "$name client environment at $env (CPython $CLIENT_PYTHON, every package at its locked version)"
	done
}

part_images() {
	local image
	command -v docker >/dev/null 2>&1 || die "docker is not installed; run the system part first"
	while IFS= read -r image; do
		if docker image inspect "$image" >/dev/null 2>&1; then
			kept "image $image"
		else
			docker pull --quiet "$image" >/dev/null
			changed "pulled $image"
		fi
	done < <(python3 -IB "$ROOT/tools/rented_run.py" images)
}

caches_ready() {
	local tag vtag
	tag="$(sed -n 's/^REDIS_TAG="\(.*\)"$/\1/p' "$ROOT/test/conformance/run.sh" | head -n 1)"
	vtag="$(sed -n 's/^REDIS_TAG="\(.*\)"$/\1/p' "$ROOT/test/conformance/vectorset.sh" | head -n 1)"
	[ -n "$tag" ] && [ -n "$vtag" ] && [ -f "$ROOT/test/conformance/.redis/redis-$tag/tests/test_helper.tcl" ] &&
		[ -d "$ROOT/test/conformance/.vectorset/redis-$vtag" ] && [ -e "$ROOT/test/conformance/.vectorset/venv/bin/python3" ]
}

part_caches() {
	local work="$1" server="$work/eski-for-setup"
	if caches_ready; then
		kept "conformance archives are cached under test/conformance"
		return
	fi
	ODIN="$HOME/odin/current/odin" "$HOME/odin/current/odin" build "$ROOT/src" -o:speed -out:"$server" >/dev/null
	"$ROOT/test/conformance/run.sh" --suite redis --units info-command --server "$server" \
		--results-dir "$work/conformance-results" --summary "$work/conformance-fetch.json" >"$work/conformance-fetch.log" 2>&1 ||
		die "the Redis suite archive could not be fetched and verified; see $work/conformance-fetch.log"
	"$ROOT/test/conformance/run.sh" --suite vectorset --server "$server" \
		--results-dir "$work/vectorset-results" --summary "$work/vectorset-fetch.json" >"$work/vectorset-fetch.log" 2>&1 ||
		die "the vector set unit and its client could not be fetched and verified; see $work/vectorset-fetch.log"
	rm -f "$server"
	say "ready: conformance archives fetched, verified and cached under test/conformance"
}

part_downloads() {
	local sha url path target
	while read -r sha url path; do
		target="$ROOT/$path"
		if [ -f "$target" ] && [ "$(sha256sum "$target" | cut -d' ' -f1)" = "$sha" ]; then
			kept "$path verified by SHA-256"
			continue
		fi
		mkdir -p "$(dirname "$target")"
		curl --fail --location --silent --show-error --retry 3 --output "$target.part" "$url"
		[ "$(sha256sum "$target.part" | cut -d' ' -f1)" = "$sha" ] || { rm -f "$target.part"; die "$url does not match $sha"; }
		mv "$target.part" "$target"
		changed "$path fetched from $url and verified by SHA-256"
	done < <(python3 -IB "$ROOT/tools/rented_run.py" downloads)
}

native_tcl() {
	command -v tclsh8.6 >/dev/null 2>&1 || command -v tclsh9.0 >/dev/null 2>&1 || command -v tclsh8.5 >/dev/null 2>&1
}

part_user() {
	local work="$HOME/eski-host" docker=1
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--no-docker) docker=0 ;;
			*) work="$1" ;;
		esac
		shift
	done
	[ "$(id -u)" != 0 ] || die "user runs as the operator, not as root"
	mkdir -p "$work"
	work="$(cd "$work" && pwd)"
	part_odin "$work"
	part_archives
	part_clients "$work"
	part_downloads
	if [ "$docker" = 0 ]; then
		say "skipped: images (--no-docker)"
		if native_tcl; then
			part_caches "$work"
		else
			say "skipped: conformance archives (--no-docker and no native Tcl)"
		fi
	else
		part_images
		part_caches "$work"
	fi
	say "client interpreters: --modern-python $work/clients/modern/bin/python --llama-python $work/clients/llama/bin/python"
}

cmdline_wants() {
	printf '%s\n' nosmt modprobe.blacklist=i915,xe,ast,amdgpu,radeon,nouveau,mgag200 transparent_hugepage=madvise
}

part_quiet() {
	local reboot=0 word grub=/etc/default/grub unit=/etc/systemd/system/eski-performance-governor.service timer
	[ "$(id -u)" = 0 ] || die "quiet runs as root"
	command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || die "quiet needs a host booted with systemd"
	command -v cpupower >/dev/null 2>&1 || die "cpupower is missing; run the system part first"
	if [ ! -f "$unit" ]; then
		printf '[Unit]\nDescription=performance CPU frequency governor for timed runs\n\n[Service]\nType=oneshot\nExecStart=%s frequency-set -g performance\n\n[Install]\nWantedBy=multi-user.target\n' \
			"$(command -v cpupower)" >"$unit"
		systemctl daemon-reload
		systemctl enable eski-performance-governor.service
		changed "the performance governor is set at every boot"
	else
		kept "the performance governor unit"
	fi
	cpupower frequency-set -g performance >/dev/null 2>&1 && say "now: performance governor on every CPU"
	for timer in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service; do
		if systemctl is-enabled --quiet "$timer" 2>/dev/null || systemctl is-active --quiet "$timer" 2>/dev/null; then
			systemctl disable --now "$timer" >/dev/null 2>&1 || true
			changed "$timer stopped and disabled"
		else
			kept "$timer is off"
		fi
	done
	part_perf
	[ -f "$grub" ] || die "$grub is missing; set the kernel command line by hand: $(cmdline_wants | tr '\n' ' ')"
	while IFS= read -r word; do
		if grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub" | grep -qw -- "$word"; then
			kept "kernel command line has $word"
		else
			sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 $word\"|" "$grub"
			changed "kernel command line gains $word"
			reboot=1
		fi
	done < <(cmdline_wants)
	if [ "$reboot" = 1 ]; then
		update-grub
		say "REBOOT NEEDED before correctness starts"
	elif ! grep -qw nosmt /proc/cmdline; then
		say "REBOOT NEEDED: the running kernel has not booted with the new command line"
	fi
}

perf_settings() {
	printf '%s\n' 'kernel.perf_event_paranoid = 1' 'kernel.kptr_restrict = 0'
}

part_perf() {
	local file=/etc/sysctl.d/60-eski-perf.conf
	if [ -f "$file" ] && [ "$(cat "$file")" = "$(perf_settings)" ]; then
		kept "$file"
	else
		perf_settings >"$file"
		changed "$file lets perf record call graphs and resolve kernel symbols at every boot"
	fi
	if [ "$(cat /proc/sys/kernel/perf_event_paranoid)" = 1 ] && [ "$(cat /proc/sys/kernel/kptr_restrict)" = 0 ]; then
		kept "perf settings are in effect"
	else
		sysctl -q -p "$file"
		changed "perf settings applied now"
	fi
}

part_status() {
	local name missing=()
	while IFS= read -r name; do
		dpkg-query -W -f='${Status}' "$name" 2>/dev/null | grep -q 'install ok installed' || missing+=("$name")
	done < <(packages)
	say "packages missing: ${missing[*]:-none}"
	say "odin: $("$HOME/odin/current/odin" version 2>/dev/null || echo missing)"
	say "kernel command line: $(cat /proc/cmdline)"
	say "governor of cpu0: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo not exposed)"
	say "SMT: $(cat /sys/devices/system/cpu/smt/control 2>/dev/null || echo unknown)"
	say "perf: kernel.perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown) kernel.kptr_restrict=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo unknown), wanted 1 and 0"
	while read -r sha url path; do
		if [ -f "$ROOT/$path" ] && [ "$(sha256sum "$ROOT/$path" | cut -d' ' -f1)" = "$sha" ]; then
			say "download $path: cached and verified"
		else
			say "download $path: missing; tools/host_setup.sh downloads fetches it"
		fi
	done < <(python3 -IB "$ROOT/tools/rented_run.py" downloads)
}

case "${1:-}" in
	system) shift; part_system "$@" ;;
	user) shift; part_user "$@" ;;
	downloads) part_downloads ;;
	quiet) part_quiet ;;
	status) part_status ;;
	-h|--help|help) usage ;;
	*) usage >&2; exit 2 ;;
esac
if [ "$CHANGED" = 0 ]; then
	say "nothing changed"
fi
