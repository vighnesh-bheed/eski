#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
find src third_party/lua tools/build_lua.sh tools/source_digest.sh -type f -print0 \
    | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
