#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/../.."

PORT="${ESKI_VSET_PORT:-6481}"
REF_PORT="${ESKI_VSET_REF_PORT:-6482}"
SERVER="${ESKI_VSET_SERVER:-bin/eski}"
EXTERNAL="${ESKI_VSET_EXTERNAL:-0}"
IMAGE="${ESKI_VSET_IMAGE:-docker.io/library/redis@sha256:f245f4c83b84a9e9a0588da1c9456e579455310f0945d5db52cd2ba27f2000cc}"
NAME="eski-vset-compare-$REF_PORT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eski-vset-compare.XXXXXX")"
SERVER_PID=""

cleanup() {
	if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill "$SERVER_PID" 2>/dev/null
		wait "$SERVER_PID" 2>/dev/null
	fi
	docker rm -f "$NAME" >/dev/null 2>&1
	if [ "${ESKI_VSET_KEEP:-0}" = "1" ]; then
		echo "kept work directory $WORK" >&2
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

ping_port() (
	exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1
	printf 'PING\r\n' >&3
	reply=""
	IFS= read -r -t 2 reply <&3 || exit 1
	[[ "$reply" == "+PONG"* ]]
) 2>/dev/null

wait_port() {
	for _ in $(seq 1 150); do
		if ping_port "$1"; then
			return 0
		fi
		sleep 0.1
	done
	return 1
}

if ping_port "$REF_PORT"; then
	echo "something already answers on the reference port $REF_PORT" >&2
	exit 2
fi
if [ "$EXTERNAL" != "1" ]; then
	if ping_port "$PORT"; then
		echo "something already answers on port $PORT; set ESKI_VSET_EXTERNAL=1 to compare that server" >&2
		exit 2
	fi
	if [ ! -x "$SERVER" ]; then
		echo "missing executable $SERVER; build it with ./build.sh release" >&2
		exit 2
	fi
	"$SERVER" --port "$PORT" --bind 127.0.0.1 --enable-debug-command yes --save "" --appendonly no --dir "$WORK" >"$WORK/eski.log" 2>&1 &
	SERVER_PID=$!
fi
if ! docker run -d --rm --name "$NAME" --network=host --memory 2g --memory-swap 2g "$IMAGE" redis-server --port "$REF_PORT" --bind 127.0.0.1 --protected-mode yes \
	--save "" --appendonly no --maxmemory 1gb --client-output-buffer-limit "normal 64mb 32mb 60" --enable-debug-command yes >/dev/null; then
	echo "could not start the reference container from $IMAGE" >&2
	exit 2
fi
if ! wait_port "$PORT"; then
	echo "Eski did not answer on port $PORT" >&2
	cat "$WORK/eski.log" >&2 2>/dev/null
	exit 2
fi
if ! wait_port "$REF_PORT"; then
	echo "the reference did not answer on port $REF_PORT" >&2
	exit 2
fi
python3 -I test/vectorset/compare.py "$PORT" "$REF_PORT" "$@"
rc=$?
if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
	echo "Eski exited during the comparison" >&2
	cat "$WORK/eski.log" >&2
	rc=1
fi
exit "$rc"
