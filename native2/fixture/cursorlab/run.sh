#!/bin/sh
# Builds the cursor lab and opens it. Pass --build to build without opening.
set -e
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../../.build/cursorlab"
mkdir -p "$(dirname "$out")"
xcrun swiftc -O -swift-version 6 "$here/Motion.swift" "$here/main.swift" -o "$out"
[ "$1" = "--build" ] && exit 0
pkill -x cursorlab 2>/dev/null || true
exec "$out"
