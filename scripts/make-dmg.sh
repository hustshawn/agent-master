#!/bin/bash
# Packs build/AgentMaster.app into a drag-to-install disk image: the app next to a link to /Applications.
# Usage: scripts/make-dmg.sh <output.dmg>   (run scripts/bundle.sh first)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?usage: scripts/make-dmg.sh <output.dmg>}"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto build/AgentMaster.app "$STAGING/AgentMaster.app"   # ditto keeps the signature intact
ln -s /Applications "$STAGING/Applications"

rm -f "$OUT"
hdiutil create -volname AgentMaster -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
echo "Built $OUT"
