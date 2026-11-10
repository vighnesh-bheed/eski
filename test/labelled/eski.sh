#!/usr/bin/env bash
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
binary="${ESKI_LABELLED_BINARY:-$root/bin/eski}"
extra=()
if [ -n "${ESKI_LABELLED_KEYSPACE_THREADS:-}" ]; then
	extra=(--keyspace-threads "$ESKI_LABELLED_KEYSPACE_THREADS")
fi
if [ "${ESKI_LABELLED_MODE:-on}" = off ]; then
	exec "$binary" "$@" "${extra[@]}"
fi
if [ -n "${ESKI_LABELLED_DIR:-}" ] && { [ $# -eq 0 ] || [ "${1#--}" != "$1" ]; }; then
	own_dir=1
	for a in "$@"; do
		if [ "$a" = "--dir" ]; then
			own_dir=0
		fi
	done
	if [ "$own_dir" = 1 ]; then
		binary="$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"
		cd "$ESKI_LABELLED_DIR" || exit 1
	fi
fi
exec "$binary" "$@" "${extra[@]}" \
	--save "" --appendonly no --shutdown-on-sigterm default --shutdown-on-sigint default --memcached-port 0 \
	--label-levels "UNCLASSIFIED,CONFIDENTIAL,SECRET" --label-compartments "A,B" --label-trust-levels "WEB,VETTED" \
	--user default on nopass sanitize-payload "~*" "&*" "+@all" "clearance:*"
