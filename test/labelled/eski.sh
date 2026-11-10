#!/usr/bin/env bash
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
binary="${ESKI_LABELLED_BINARY:-$root/bin/eski}"
extra=()
if [ -n "${ESKI_LABELLED_KEYSPACE_THREADS:-}" ]; then
	extra=(--keyspace-threads "$ESKI_LABELLED_KEYSPACE_THREADS")
fi
scheme=(--label-levels "UNCLASSIFIED,CONFIDENTIAL,SECRET" --label-compartments "A,B" --label-trust-levels "WEB,VETTED")
owners=()
case "${ESKI_LABELLED_MODE:-on}" in
	off)
		exec "$binary" "$@" "${extra[@]}"
		;;
	on|labelled)
		login=("clearance:*")
		;;
	owners-shared)
		owners=(--owners yes)
		login=("clearance:*" owner-operator)
		;;
	owners-user)
		owners=(--owners yes)
		login=(owner:suite-user owner-operator "clearance:*")
		;;
	owners-only-user)
		scheme=()
		owners=(--owners yes)
		login=(owner:suite-user owner-operator)
		;;
	*)
		echo "labelled: unknown ESKI_LABELLED_MODE ${ESKI_LABELLED_MODE}" >&2
		exit 2
		;;
esac
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
	"${owners[@]}" "${scheme[@]}" \
	--user default on nopass sanitize-payload "~*" "&*" "+@all" "${login[@]}"
