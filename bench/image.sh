#!/usr/bin/env bash
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BENCH_DIR")"
TAG="${ESKI_IMAGE_TAG:-eski:local}"
REVISION="${ESKI_REVISION:-unknown}"
JOBS="${ESKI_BUILD_JOBS:-2}"
MANIFEST="$BENCH_DIR/image.json"
EXPORT_DIR=""
EXTRACT=""
IMPORT=""
NO_CACHE=0
LABEL="eski-image=$$-$RANDOM"
WORK=""

usage() {
  cat <<EOF
usage: bench/image.sh [--tag NAME] [--revision REV] [--jobs N] [--no-cache] [--manifest FILE]
                      [--export DIR] [--extract FILE]
       bench/image.sh --import TAR [--tag NAME] [--manifest FILE]

Builds the Eski container image from this tree with docker build and the Dockerfile at the
repository root, then records the image id, the sha256 of the binary inside it, its version
string and the build info file into the manifest.

  --tag       image tag (default eski:local, or ESKI_IMAGE_TAG)
  --revision  source revision stamped into the image and the manifest (default unknown,
              or ESKI_REVISION)
  --jobs      compiler threads inside the build (default 2, or ESKI_BUILD_JOBS)
  --no-cache  build every stage again instead of reusing the build cache
  --manifest  manifest path (default bench/image.json)
  --export    also save the image to DIR/eski-<id>.tar and write DIR/eski-<id>.tar.sha256,
              for shipping to another machine; the manifest records both
  --extract   also copy the binary out of the image to FILE, so the native target of
              bench/run.sh can run the exact binary the image holds (ESKI_BIN=FILE)
  --import    on the receiving machine: check TAR against TAR.sha256, docker load it and,
              when the manifest exists, check that the loaded image id is the one it records
EOF
}

say() { printf '%s\n' "$*"; }
die() { printf 'image.sh: error: %s\n' "$*" >&2; exit 1; }

cleanup() {
  local leftovers
  leftovers=$(docker ps -aq --filter "label=$LABEL" 2>/dev/null || true)
  [ -n "$leftovers" ] && docker rm -f $leftovers >/dev/null 2>&1
  [ -n "$WORK" ] && rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) [ $# -ge 2 ] || die "--tag needs a value"; TAG=$2; shift ;;
    --tag=*) TAG=${1#--tag=} ;;
    --revision) [ $# -ge 2 ] || die "--revision needs a value"; REVISION=$2; shift ;;
    --revision=*) REVISION=${1#--revision=} ;;
    --jobs) [ $# -ge 2 ] || die "--jobs needs a value"; JOBS=$2; shift ;;
    --jobs=*) JOBS=${1#--jobs=} ;;
    --no-cache) NO_CACHE=1 ;;
    --manifest) [ $# -ge 2 ] || die "--manifest needs a value"; MANIFEST=$2; shift ;;
    --manifest=*) MANIFEST=${1#--manifest=} ;;
    --export) [ $# -ge 2 ] || die "--export needs a value"; EXPORT_DIR=$2; shift ;;
    --export=*) EXPORT_DIR=${1#--export=} ;;
    --extract) [ $# -ge 2 ] || die "--extract needs a value"; EXTRACT=$2; shift ;;
    --extract=*) EXTRACT=${1#--extract=} ;;
    --import) [ $# -ge 2 ] || die "--import needs a value"; IMPORT=$2; shift ;;
    --import=*) IMPORT=${1#--import=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

[[ "$TAG" =~ ^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]*)?$ ]] || die "invalid image tag: $TAG"
[[ "$REVISION" =~ ^[A-Za-z0-9._/-]+$ ]] || die "the revision may only contain letters, digits, '.', '_', '/' and '-'"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs needs a positive number"
if [ -n "$IMPORT" ] && { [ -n "$EXPORT_DIR" ] || [ -n "$EXTRACT" ] || [ "$NO_CACHE" = 1 ]; }; then
  die "--import cannot be combined with --export, --extract or --no-cache"
fi

absolute() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$PWD/$1" ;;
  esac
}

MANIFEST=$(absolute "$MANIFEST")
[ -n "$EXPORT_DIR" ] && EXPORT_DIR=$(absolute "$EXPORT_DIR")
[ -n "$EXTRACT" ] && EXTRACT=$(absolute "$EXTRACT")
[ -n "$IMPORT" ] && IMPORT=$(absolute "$IMPORT")

for c in docker python3 sha256sum; do
  command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
done
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eski-image.XXXXXX")

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

info_value() {
  sed -n "s/^$1=//p" "$2" | head -n 1
}

source_digest() {
  (cd "$ROOT_DIR" && find src -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
}

import_image() {
  local tar=$IMPORT sum expected got loaded id want
  [ -f "$tar" ] || die "archive not found: $tar"
  sum="$tar.sha256"
  [ -f "$sum" ] || die "checksum file not found: $sum"
  expected=$(cut -d' ' -f1 "$sum" | head -n 1)
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "$sum does not hold a sha256"
  got=$(sha256_of "$tar")
  [ "$got" = "$expected" ] || die "sha256 mismatch for $tar: expected $expected, got $got"
  say "archive   $tar (sha256 $got, verified)"
  loaded=$(docker load --input "$tar") || die "docker load failed for $tar"
  printf '%s\n' "$loaded"
  id=$(docker image inspect --format '{{.Id}}' "$TAG" 2>/dev/null) || die "the archive did not provide $TAG"
  if [ -f "$MANIFEST" ]; then
    want=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("image_id") or "")' "$MANIFEST")
    [ "$id" = "$want" ] || die "loaded $TAG is $id but $MANIFEST records $want"
    say "manifest  $MANIFEST matches"
  fi
  say "image     $TAG $id"
}

if [ -n "$IMPORT" ]; then
  import_image
  exit 0
fi

[ -f "$ROOT_DIR/Dockerfile" ] || die "no Dockerfile at $ROOT_DIR"
SOURCE_SHA=$(source_digest)
SOURCE_VERSION=$(sed -n 's/^VERSION :: "\([0-9A-Za-z.+-]*\)"$/\1/p' "$ROOT_DIR/src/main.odin" | head -n 1)
[ -n "$SOURCE_VERSION" ] || die "cannot read the VERSION constant from $ROOT_DIR/src/main.odin"
build=(docker build --file "$ROOT_DIR/Dockerfile" --tag "$TAG" --iidfile "$WORK/iid"
  --provenance=false --sbom=false
  --build-arg "SOURCE_REVISION=$REVISION" --build-arg "BUILD_JOBS=$JOBS" --build-arg "ESKI_VERSION=$SOURCE_VERSION")
[ "$NO_CACHE" = 1 ] && build+=(--no-cache)
say "building  $TAG from $ROOT_DIR"
"${build[@]}" "$ROOT_DIR" >&2 || die "docker build failed"
ID=$(cat "$WORK/iid")
[ "$(docker image inspect --format '{{.Id}}' "$TAG")" = "$ID" ] || die "$TAG does not point at the image just built ($ID)"
HEX=${ID#sha256:}

CID=$(docker create --label "$LABEL" "$ID") || die "docker create failed for $ID"
docker cp "$CID:/usr/local/bin/eski" "$WORK/eski" >/dev/null || die "cannot copy the binary out of $ID"
docker cp "$CID:/usr/share/doc/eski/build-info.txt" "$WORK/build-info.txt" >/dev/null || die "cannot copy the build info out of $ID"
docker rm "$CID" >/dev/null
BIN_SHA=$(sha256_of "$WORK/eski")
VERSION=$(docker run --rm --label "$LABEL" "$ID" -v) || die "the image does not print its version"
VERSION=${VERSION%%$'\r'}

[ "$(info_value binary_sha256 "$WORK/build-info.txt")" = "$BIN_SHA" ] || die "the binary in $ID does not match the sha256 its build info records"
[ "$(info_value version "$WORK/build-info.txt")" = "$VERSION" ] || die "the image prints '$VERSION' but its build info records '$(info_value version "$WORK/build-info.txt")'"
[ "$(info_value source_sha256 "$WORK/build-info.txt")" = "$SOURCE_SHA" ] || die "the image was built from a source tree other than $ROOT_DIR/src (the tree changed during the build?)"

ARCHIVE=""
ARCHIVE_SHA=""
if [ -n "$EXPORT_DIR" ]; then
  mkdir -p "$EXPORT_DIR" || die "cannot create $EXPORT_DIR"
  ARCHIVE="$EXPORT_DIR/eski-${HEX:0:12}.tar"
  say "exporting $TAG to $ARCHIVE"
  docker save --output "$ARCHIVE.part" "$TAG" || die "docker save failed"
  mv -f "$ARCHIVE.part" "$ARCHIVE"
  chmod 0644 "$ARCHIVE"
  ARCHIVE_SHA=$(sha256_of "$ARCHIVE")
  printf '%s  %s\n' "$ARCHIVE_SHA" "$(basename "$ARCHIVE")" >"$ARCHIVE.sha256"
fi

if [ -n "$EXTRACT" ]; then
  mkdir -p "$(dirname "$EXTRACT")" || die "cannot create the directory of $EXTRACT"
  install -m 0755 "$WORK/eski" "$EXTRACT" || die "cannot write $EXTRACT"
fi

mkdir -p "$(dirname "$MANIFEST")" || die "cannot create the directory of $MANIFEST"
python3 -I - "$MANIFEST" "$TAG" "$ID" "$BIN_SHA" "$VERSION" "$WORK/build-info.txt" "$REVISION" \
  "$ARCHIVE" "$ARCHIVE_SHA" "$EXTRACT" "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)" \
  "$(date -Iseconds)" "$(docker image inspect --format '{{.Size}}' "$ID")" <<'PY'
import json
import os
import sys
from pathlib import Path

(manifest, tag, image_id, binary_sha, version, info_path, revision, archive, archive_sha,
 extracted, docker_version, built_at, size) = sys.argv[1:14]
text = Path(info_path).read_text()
info = {}
packages = {}
for line in text.splitlines():
    if "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key.startswith("package."):
        packages[key[len("package."):]] = value
    else:
        info[key] = value
data = {
    "image": tag,
    "image_id": image_id,
    "image_size_bytes": int(size) if size.isdigit() else None,
    "built_at": built_at,
    "docker_version": docker_version,
    "source_revision": revision,
    "source_sha256": info.get("source_sha256"),
    "binary": {"path": info.get("binary_path"), "sha256": binary_sha, "version": version},
    "build": {
        "flags": info.get("build_flags"),
        "check_flags": info.get("check_flags"),
        "odin_version": info.get("odin_version"),
        "odin_release": info.get("odin_release"),
        "odin_archive_sha256": info.get("odin_archive_sha256"),
        "base_image": info.get("base_image"),
        "ubuntu_snapshot": info.get("ubuntu_snapshot"),
        "ca_certificates_sha256": info.get("ca_certificates_sha256"),
        "packages": packages,
    },
    "build_info": text,
    "archive": {"path": archive, "sha256": archive_sha} if archive else None,
    "extracted_binary": extracted or None,
}
tmp = Path(manifest + ".tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n")
os.replace(tmp, manifest)
PY

say "image     $TAG $ID"
say "binary    sha256 $BIN_SHA ($VERSION)"
say "source    sha256 $SOURCE_SHA, revision $REVISION"
[ -n "$ARCHIVE" ] && say "archive   $ARCHIVE sha256 $ARCHIVE_SHA"
[ -n "$EXTRACT" ] && say "extracted $EXTRACT"
say "manifest  $MANIFEST"
exit 0
