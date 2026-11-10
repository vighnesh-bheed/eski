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
exec "$binary" "$@" "${extra[@]}" \
	--save "" --appendonly no --shutdown-on-sigterm default --shutdown-on-sigint default --memcached-port 0 \
	--label-levels "UNCLASSIFIED,CONFIDENTIAL,SECRET" --label-compartments "A,B" --label-trust-levels "WEB,VETTED" \
	--user default on nopass sanitize-payload "~*" "&*" "+@all" "clearance:*"
