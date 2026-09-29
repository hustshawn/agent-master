#!/bin/bash
# Builds the web edition in release mode and collects it into one folder (and a tarball) to copy to a server:
#   agentmaster-server, agentmaster-hook (must stay next to each other) and the web UI's resource bundle.
# Runs on macOS or Linux; the result runs on the same OS and architecture it was built on. On Linux the Swift
# runtime is linked in, so the target machine does not need Swift installed.
# Usage: scripts/package-server.sh [output-dir]   (default: build/agentmaster-server-<os>-<arch>)
set -euo pipefail
cd "$(dirname "$0")/.."

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
OUT="${1:-build/agentmaster-server-$OS-$ARCH}"
FLAGS=(-c release)
[ "$OS" = linux ] && FLAGS+=(--static-swift-stdlib)

swift build "${FLAGS[@]}" --product agentmaster-server
swift build "${FLAGS[@]}" --product agentmaster-hook
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$BIN/agentmaster-server" "$BIN/agentmaster-hook" "$OUT/"
# SwiftPM names the bundle <package>_<target>: .bundle on macOS, .resources on Linux.
for bundle in "$BIN"/AgentMaster_AgentMasterServerKit.bundle "$BIN"/AgentMaster_AgentMasterServerKit.resources; do
    [ -e "$bundle" ] && cp -R "$bundle" "$OUT/"
done
[ "$OS" = darwin ] && codesign --force --sign - "$OUT/agentmaster-hook" "$OUT/agentmaster-server"

tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
echo "Built $OUT and $OUT.tar.gz"
