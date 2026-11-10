#!/usr/bin/env bash
set -uo pipefail

CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CONF_DIR/../.." && pwd)"
REDIS_TAG="8.10.3"
REDIS_SHA256="85ae62e175cc76f638015fa18cb384b549b6808a765425d9e9d47466f69532ea"
REDIS_URL="https://github.com/redis/redis/archive/refs/tags/${REDIS_TAG}.tar.gz"
REFERENCE_IMAGE="docker.io/library/redis@sha256:f245f4c83b84a9e9a0588da1c9456e579455310f0945d5db52cd2ba27f2000cc"
CLIENT_REQUIREMENT="redis==8.1.0 --hash=sha256:a4fe1aac3d3b3cc791d4b3d5931c5a956045dc951ee74d1c913ee3ac4d2ee9fb"
UNIT_PATH="modules/vector-sets"
UNIT_NAME="modules/vector-sets"
CACHE_DIR="$CONF_DIR/.vectorset"
TREE_NAME="redis-$REDIS_TAG"
TREE="$CACHE_DIR/$TREE_NAME"
UNIT_DIR="$TREE/$UNIT_PATH"
VENV="$CACHE_DIR/venv"
STAMP_VALUE="$REDIS_SHA256 $UNIT_PATH/test.py $UNIT_PATH/tests unit-only-v1"
RESULTS_DIR="$CONF_DIR/results"
PARSER="$CONF_DIR/parse_results.py"

port=""
server="$ROOT/bin/eski"
server_given=0
external=""
reference=0
baseline=""
extra_summary=""
exclusions="$CONF_DIR/vectorset-exclusions.json"
titles="$CONF_DIR/reference-vectorset.json"
python_given=""
unit_timeout=900
verbose=0

SERVER_PID=""
CONTAINER=""
UNIT_PID=""
TAIL_PID=""
ARCHIVE_TMP=""

usage() {
	cat <<EOF
usage: ./test/conformance/run.sh --suite vectorset [options]
       ./test/conformance/vectorset.sh [options]

Runs the vector set test unit of the Redis $REDIS_TAG source release against one
server and writes a JSON summary to test/conformance/results/latest-vectorset.json.
The release archive is downloaded at run time to a temporary file outside the
checkout, its SHA-256 is checked against $REDIS_SHA256,
and only $UNIT_PATH/test.py and $UNIT_PATH/tests are extracted into
test/conformance/.vectorset, which git ignores; the archive is then deleted and
nothing of it enters the repository. The unit's runner needs the redis Python
client, which is installed once into a virtual environment in the same ignored
folder from a pinned version and hash ($CLIENT_REQUIREMENT).

The runner connects to localhost on the primary port it is given and probes a
replica port; this script passes a free port where nothing listens as the
replica port, so the unit's replication test reports itself skipped. A server
started by this script runs with --save "" and --appendonly no, as the unit's
documentation asks, and with its working directory inside the run's log folder.

  --server PATH          server binary to start (default: bin/eski, built when missing)
  --port N               port for the server this script starts (default: a free port)
  --external HOST:PORT   test an already running server on 127.0.0.1 or localhost
  --reference            start the pinned reference image instead of Eski, capped at
                         2 GB of memory, maxmemory 1gb and a 64 MB client output buffer,
                         to validate the unit and the parser
  --baseline PATH        compare with a recorded summary; fail only on tests that passed
                         there and do not pass now. test/conformance/baseline-vectorset.json
                         holds the recorded Eski run, test/conformance/reference-vectorset.json
                         the recorded reference run
  --summary PATH         also write the JSON summary to PATH
  --exclusions PATH      tests that cannot pass by design, with reasons
                         (default: test/conformance/vectorset-exclusions.json)
  --titles PATH          recorded summary whose test titles anchor the parser
                         (default: test/conformance/reference-vectorset.json when present)
  --python PATH          Python interpreter that already has the redis client
  --unit-timeout SECS    hard time limit for the unit (default: $unit_timeout)
  --verbose              stream the unit output while it runs

Exit status: 0 when the run passes, 1 when it fails, 2 on a setup error.
Without --baseline the run fails when any test fails that the exclusions file does
not list. With --baseline it fails only when a test that passed in the baseline
does not pass now.
EOF
}

die() {
	echo "conformance: $*" >&2
	exit 2
}

abspath() {
	case "$1" in
		/*) printf '%s' "$1" ;;
		*) printf '%s/%s' "$PWD" "$1" ;;
	esac
}

need_value() {
	if [ $# -lt 2 ]; then
		die "missing value for $1"
	fi
}

while [ $# -gt 0 ]; do
	case "$1" in
		--server) need_value "$@"; server="$(abspath "$2")"; server_given=1; shift 2 ;;
		--port) need_value "$@"; port="$2"; shift 2 ;;
		--external) need_value "$@"; external="$2"; shift 2 ;;
		--reference) reference=1; shift ;;
		--baseline) need_value "$@"; baseline="$(abspath "$2")"; shift 2 ;;
		--summary) need_value "$@"; extra_summary="$(abspath "$2")"; shift 2 ;;
		--exclusions) need_value "$@"; exclusions="$(abspath "$2")"; shift 2 ;;
		--titles) need_value "$@"; titles="$(abspath "$2")"; shift 2 ;;
		--python) need_value "$@"; python_given="$2"; shift 2 ;;
		--unit-timeout) need_value "$@"; unit_timeout="$2"; shift 2 ;;
		--verbose) verbose=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "conformance: unknown option $1" >&2; usage >&2; exit 2 ;;
	esac
done

[ "$reference" = 0 ] || [ -z "$external" ] || die "--reference and --external cannot be combined"
case "$unit_timeout" in
	''|*[!0-9]*) die "--unit-timeout must be a number of seconds" ;;
esac
if [ -n "$port" ]; then
	case "$port" in
		*[!0-9]*) die "--port must be a number" ;;
	esac
fi
if [ -n "$baseline" ] && [ ! -f "$baseline" ]; then
	die "baseline $baseline does not exist"
fi
[ -f "$exclusions" ] || die "exclusions file $exclusions does not exist"
for tool in python3 curl tar timeout; do
	command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
if [ "$reference" = 1 ]; then
	command -v docker >/dev/null 2>&1 || die "--reference needs docker"
fi
if [ -n "$baseline" ]; then
	python3 -I "$PARSER" check-baseline --baseline "$baseline" --root "$ROOT" \
		--suite-name=vectorset "--suite-tag=$REDIS_TAG" || exit 2
fi

free_port() {
	python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

if [ -n "$external" ]; then
	host="${external%:*}"
	target_port="${external##*:}"
	case "$host" in
		127.0.0.1|localhost) ;;
		*) die "--external must name 127.0.0.1 or localhost, the unit's runner only connects to localhost" ;;
	esac
	case "$target_port" in
		''|*[!0-9]*) die "--external needs a numeric port" ;;
	esac
else
	host="127.0.0.1"
	if [ -z "$port" ]; then
		port="$(free_port)" || die "could not find a free port"
	fi
	target_port="$port"
fi

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

discard_archive() {
	if [ -n "$ARCHIVE_TMP" ]; then
		rm -f "$ARCHIVE_TMP"
		ARCHIVE_TMP=""
	fi
}

tree_holds_only_unit() {
	local extra
	[ -f "$UNIT_DIR/test.py" ] && [ -d "$UNIT_DIR/tests" ] || return 1
	extra="$(find "$TREE" -mindepth 1 \
		! -path "$TREE/modules" ! -path "$TREE/$UNIT_PATH" \
		! -path "$UNIT_DIR/test.py" ! -path "$UNIT_DIR/tests" ! -path "$UNIT_DIR/tests/*" \
		! -path "$UNIT_DIR/__pycache__" ! -path "$UNIT_DIR/__pycache__/*" -print -quit)"
	[ -z "$extra" ]
}

fetch_unit() {
	local stamp="$CACHE_DIR/$TREE_NAME.sha256" listing entry staging got
	if [ "$(cat "$stamp" 2>/dev/null)" = "$STAMP_VALUE" ] && tree_holds_only_unit; then
		return 0
	fi
	mkdir -p "$CACHE_DIR" || die "could not create $CACHE_DIR"
	ARCHIVE_TMP="$(mktemp "${TMPDIR:-/tmp}/eski-vectorset-XXXXXX")" || die "could not create a temporary file for the archive"
	echo "fetching Redis $REDIS_TAG from $REDIS_URL"
	curl --fail --location --silent --show-error --retry 3 --output "$ARCHIVE_TMP" "$REDIS_URL" || die "download of $REDIS_URL failed"
	got="$(sha256_of "$ARCHIVE_TMP")"
	[ "$got" = "$REDIS_SHA256" ] || die "sha256 mismatch for the Redis $REDIS_TAG archive: expected $REDIS_SHA256, got $got"
	listing="$(tar -tzf "$ARCHIVE_TMP")" || die "could not list the Redis $REDIS_TAG archive"
	while IFS= read -r entry; do
		case "$entry" in
			"$TREE_NAME/"*) ;;
			*) die "unexpected path $entry in the Redis $REDIS_TAG archive" ;;
		esac
		case "$entry" in
			*../*|*/..) die "unexpected path $entry in the Redis $REDIS_TAG archive" ;;
		esac
	done <<<"$listing"
	rm -rf "$CACHE_DIR"/extract.*
	staging="$(mktemp -d "$CACHE_DIR/extract.XXXXXX")" || die "could not create a staging directory"
	if ! tar -xzf "$ARCHIVE_TMP" -C "$staging" --no-same-owner "$TREE_NAME/$UNIT_PATH/test.py" "$TREE_NAME/$UNIT_PATH/tests"; then
		rm -rf "$staging"
		die "could not extract the vector set unit of the Redis $REDIS_TAG archive"
	fi
	discard_archive
	if [ ! -f "$staging/$TREE_NAME/$UNIT_PATH/test.py" ] || [ ! -d "$staging/$TREE_NAME/$UNIT_PATH/tests" ]; then
		rm -rf "$staging"
		die "the Redis $REDIS_TAG archive has no $UNIT_PATH/test.py and tests"
	fi
	rm -f "$stamp"
	rm -rf "$TREE"
	mv "$staging/$TREE_NAME" "$TREE" || die "could not move the unit into place"
	rmdir "$staging"
	tree_holds_only_unit || die "the extracted tree holds more than the vector set unit"
	printf '%s\n' "$STAMP_VALUE" >"$stamp"
}

prepare_python() {
	local stamp="$VENV/eski-requirement"
	if [ -n "$python_given" ]; then
		PY="$python_given"
	else
		PY="$VENV/bin/python3"
		if [ ! -x "$PY" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$CLIENT_REQUIREMENT" ]; then
			rm -rf "$VENV"
			echo "installing the redis Python client into $VENV"
			python3 -I -m venv "$VENV" || die "could not create a virtual environment in $VENV"
			printf '%s\n' "$CLIENT_REQUIREMENT" >"$CACHE_DIR/requirement.txt"
			"$PY" -I -m pip install --quiet --disable-pip-version-check --no-deps --require-hashes --only-binary :all: \
				-r "$CACHE_DIR/requirement.txt" || die "could not install $CLIENT_REQUIREMENT"
			printf '%s\n' "$CLIENT_REQUIREMENT" >"$stamp"
		fi
	fi
	"$PY" -I -c 'import redis' 2>/dev/null || die "$PY cannot import the redis client"
	RUNNER_DESC="python $("$PY" -I -c 'import platform; print(platform.python_version())') with redis-py $("$PY" -I -c 'import redis; print(redis.__version__)')"
}

ping_server() (
	exec 3<>"/dev/tcp/$1/$2" || exit 1
	printf 'PING\r\n' >&3
	reply=""
	IFS= read -r -t 2 reply <&3 || exit 1
	[[ "$reply" == "+PONG"* ]]
) 2>/dev/null

wait_ping() {
	for _ in $(seq 1 150); do
		if ping_server "$host" "$target_port"; then
			return 0
		fi
		if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
			return 1
		fi
		sleep 0.1
	done
	return 1
}

start_eski() {
	if ping_server "$host" "$port"; then
		die "something already answers PING on port $port"
	fi
	mkdir -p "$LOG_DIR/server-dir" || die "could not create the server directory"
	"$server" --port "$port" --bind 127.0.0.1 --enable-debug-command yes --enable-protected-configs yes \
		--save "" --appendonly no --dir "$LOG_DIR/server-dir" >>"$LOG_DIR/server.log" 2>&1 </dev/null &
	SERVER_PID=$!
	if ! wait_ping; then
		echo "conformance: the server did not answer PING on port $port, log follows" >&2
		cat "$LOG_DIR/server.log" >&2
		exit 2
	fi
}

start_reference() {
	if ping_server "$host" "$port"; then
		die "something already answers PING on port $port"
	fi
	CONTAINER="eski-vset-conformance-$$"
	docker run -d --rm --name "$CONTAINER" --network=host --memory 2g --memory-swap 2g "$REFERENCE_IMAGE" \
		redis-server --port "$port" --bind 127.0.0.1 --protected-mode yes --save "" --appendonly no \
		--maxmemory 1gb --client-output-buffer-limit "normal 64mb 32mb 60" --enable-debug-command yes \
		>"$LOG_DIR/container.id" 2>"$LOG_DIR/container.log" || die "could not start the reference container from $REFERENCE_IMAGE"
	wait_ping || die "the reference container never answered PING on port $port"
}

stop_server() {
	local pid="$SERVER_PID"
	SERVER_PID=""
	if [ -n "$pid" ]; then
		kill "$pid" 2>/dev/null
		for _ in $(seq 1 50); do
			kill -0 "$pid" 2>/dev/null || break
			sleep 0.1
		done
		kill -9 "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
	fi
	if [ -n "$CONTAINER" ]; then
		docker logs "$CONTAINER" >>"$LOG_DIR/container.log" 2>&1
		docker rm -f "$CONTAINER" >/dev/null 2>&1
		CONTAINER=""
	fi
	return 0
}

stop_unit() {
	if [ -n "$UNIT_PID" ]; then
		kill -TERM -- "-$UNIT_PID" 2>/dev/null || kill -TERM "$UNIT_PID" 2>/dev/null
		wait "$UNIT_PID" 2>/dev/null
		UNIT_PID=""
	fi
	if [ -n "$TAIL_PID" ]; then
		kill "$TAIL_PID" 2>/dev/null
		wait "$TAIL_PID" 2>/dev/null
		TAIL_PID=""
	fi
	return 0
}

cleanup() {
	stop_unit
	stop_server
	discard_archive
}

on_signal() {
	trap '' PIPE
	trap - INT TERM HUP
	cleanup
	echo "conformance: interrupted, stopped the unit and the server" >&2
	exit 130
}

trap on_signal INT TERM HUP PIPE
trap cleanup EXIT

fetch_unit
prepare_python

mkdir -p "$RESULTS_DIR" || die "could not create $RESULTS_DIR"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="$RESULTS_DIR/logs-vectorset-$stamp"
suffix=1
while [ -e "$LOG_DIR" ]; do
	suffix=$((suffix + 1))
	LOG_DIR="$RESULTS_DIR/logs-vectorset-$stamp-$suffix"
done
if [ "$suffix" -gt 1 ]; then
	stamp="$stamp-$suffix"
fi
mkdir -p "$LOG_DIR" || die "could not create $LOG_DIR"
META="$LOG_DIR/units.tsv"
: >"$META"
: >"$LOG_DIR/server.log"

if [ -n "$external" ]; then
	ping_server "$host" "$target_port" || die "no server answers PING at $host:$target_port"
	server_desc="external $host:$target_port"
elif [ "$reference" = 1 ]; then
	start_reference
	server_desc="reference $REFERENCE_IMAGE on $host:$target_port, capped at 2g memory, maxmemory 1gb"
else
	if [ ! -x "$server" ]; then
		if [ "$server_given" = 1 ]; then
			die "server binary $server is not executable"
		fi
		echo "bin/eski is missing, building it"
		"$ROOT/build.sh" || die "build failed"
	fi
	start_eski
	server_desc="${server#"$ROOT"/} on $host:$target_port"
fi

replica_port="$(free_port)" || die "could not find a free replica port"
while [ "$replica_port" = "$target_port" ]; do
	replica_port="$(free_port)" || die "could not find a free replica port"
done

echo "Redis $REDIS_TAG vector set unit, $RUNNER_DESC, server $server_desc, replica port $replica_port left closed"
log="$LOG_DIR/vector-sets.log"
printf '%-8s %-22s ' "[1/1]" "$UNIT_NAME"
if [ "$verbose" = 1 ]; then
	echo
fi
started="$(date +%s)"
(cd "$UNIT_DIR" && exec env TERM=dumb timeout -k 10 "$unit_timeout" "$PY" -B -E -s -u test.py \
	--primary-port "$target_port" --replica-port "$replica_port") >"$log" 2>&1 </dev/null &
UNIT_PID=$!
if [ "$verbose" = 1 ]; then
	tail -n +1 -f --pid="$UNIT_PID" "$log" &
	TAIL_PID=$!
fi
wait "$UNIT_PID"
rc=$?
UNIT_PID=""
if [ -n "$TAIL_PID" ]; then
	wait "$TAIL_PID" 2>/dev/null
	TAIL_PID=""
fi
seconds=$(($(date +%s) - started))
killed=0
if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
	killed=1
fi
crashed=0
if ! ping_server "$host" "$target_port"; then
	crashed=1
	echo "the server stopped answering during the unit" >>"$LOG_DIR/server.log"
fi
stop_server
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$UNIT_NAME" "run" "$rc" "$seconds" "$log" "$crashed" "$killed" >>"$META"
ok_count="$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -c -E ': OK \([0-9.]+s\)$|^OK \([0-9.]+s\)$')"
err_count="$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -c -E ': ERR \([0-9.]+s\)$|^ERR \([0-9.]+s\)$')"
note=""
if [ "$killed" = 1 ]; then
	note=", killed after ${unit_timeout}s"
fi
if [ "$crashed" = 1 ]; then
	note="$note, server died"
fi
printf '%s ok, %s err%s (%ss)\n' "${ok_count:-0}" "${err_count:-0}" "$note" "$seconds"

summary_args=(summarize --meta "$META" --known "$CONF_DIR/known-failures.txt" --root "$ROOT"
	--out "$RESULTS_DIR/summary-vectorset-$stamp.json" --latest "$RESULTS_DIR/latest-vectorset.json"
	"--suite-name=vectorset" "--suite-tag=$REDIS_TAG" "--suite-sha256=$REDIS_SHA256" "--suite-url=$REDIS_URL"
	"--server=$server_desc" "--runner=$RUNNER_DESC" "--extracted=$UNIT_PATH/test.py $UNIT_PATH/tests"
	--exclusions "$exclusions")
if [ -f "$titles" ]; then
	summary_args+=(--titles "$titles")
fi
if [ -n "$extra_summary" ]; then
	summary_args+=(--extra "$extra_summary")
fi
if [ -n "$baseline" ]; then
	summary_args+=(--baseline "$baseline")
fi
echo
python3 -I "$PARSER" "${summary_args[@]}"
exit $?
