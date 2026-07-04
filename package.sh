#!/usr/bin/env bash
# Build the distributable .plasmoid archive for the KDE Store.
#
# A .plasmoid file is just a ZIP of the package *contents* with metadata.json at
# the archive root (NOT nested under a plasmoid/ directory). This script zips from
# inside ./plasmoid so that layout is guaranteed, names the archive after the
# version in metadata.json, and drops it in ./dist.
#
# Upload dist/*.plasmoid to https://store.kde.org — bump KPlugin.Version in
# plasmoid/metadata.json first, or the store will reject the re-upload as unchanged.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$REPO/plasmoid"
META="$PKG/metadata.json"

command -v zip     >/dev/null 2>&1 || { echo "error: 'zip' is not installed." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: 'python3' is not installed." >&2; exit 1; }
[ -f "$META" ] || { echo "error: $META not found." >&2; exit 1; }

version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["KPlugin"]["Version"])' "$META")"

dist="$REPO/dist"
out="$dist/kinesis-fn-mapper-$version.plasmoid"
mkdir -p "$dist"
rm -f "$out"

# -X strips extra file attributes; zip from inside the package so metadata.json is
# at the archive root. Excludes mirror the cruft categories in .gitignore.
( cd "$PKG" && zip -r -X "$out" . \
    -x '*.qmlc' '*.jsc' '*_qmlcache.qrc' '.git*' '*/__pycache__/*' '.DS_Store' >/dev/null )

echo "Produced dist/kinesis-fn-mapper-$version.plasmoid"
echo "Upload it to store.kde.org — remember to bump KPlugin.Version in plasmoid/metadata.json for each release."
