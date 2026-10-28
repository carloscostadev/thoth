#!/bin/bash
# Renders the README screenshots from synthetic data (never ~/.claude).
# Usage: scripts/screenshots/capture.sh [output-dir]   (default: a temporary directory)
# Writes <light|dark>/{overview,trends,projects,overview-globex}.png at 2x. Needs a Retina
# display and Screen Recording permission for the terminal: the popover window shows on screen
# for about 30 s per appearance.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT="${1:-$(mktemp -d)}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# The app's sources minus its @main entry point, the test suite's synthetic history generator
# and the harness.
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources/Thoth -name '*.swift' ! -name ThothApp.swift)
swiftc -O -swift-version 5 -o "$BUILD/thoth-screenshots" "${SOURCES[@]}" \
    Tests/ThothTests/Support/SyntheticHistory.swift scripts/screenshots/main.swift

for mode in light dark; do
    mkdir -p "$OUT/$mode"
    "$BUILD/thoth-screenshots" "$mode" "$OUT/$mode"
done
echo "Screenshots in $OUT"
