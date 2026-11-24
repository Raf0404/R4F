#!/bin/bash
# Scarica il sorgente di BlackHole (GPL-3.0) nella versione usata dai driver R4F.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/BlackHole"
TAG="v0.7.2"
if [[ -f "$DEST/BlackHole/BlackHole.c" ]]; then echo "già presente: $DEST"; exit 0; fi
mkdir -p "$ROOT/vendor"
git clone --depth 1 --branch "$TAG" -q https://github.com/ExistentialAudio/BlackHole.git "$DEST"
echo "ok: BlackHole $TAG in $DEST"
