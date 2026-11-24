#!/bin/bash
# Installa il device "R4F Out" (non serve sudo):
#   - R4F Out.amxd      → User Library di Live, Audio Effects > Max Audio Effect > R4F
#   - livebus_out.js    → ~/Documents/Max 9/Library/LiveBus (nel percorso di ricerca di Max)
# Il .js resta in un posto solo: due copie con lo stesso nome generano avvisi in Max.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
python3 -I "$ROOT/build_device.py"

LIB="${LIVE_USER_LIBRARY:-$HOME/Music/Ableton/User Library}"
DEV_DIR="$LIB/Presets/Audio Effects/Max Audio Effect/R4F"
JS_DIR="$HOME/Documents/Max 9/Library/LiveBus"
[[ -d "$LIB" ]] || { echo "User Library non trovata in '$LIB' (imposta LIVE_USER_LIBRARY)" >&2; exit 1; }

mkdir -p "$DEV_DIR" "$JS_DIR"
cp "$ROOT/build/R4F Out.amxd" "$DEV_DIR/"
cp "$ROOT/livebus_out.js" "$JS_DIR/"
echo "device:  $DEV_DIR/R4F Out.amxd"
echo "script:  $JS_DIR/livebus_out.js"
echo "In Live: Browser > Places > User Library > Presets > Audio Effects > Max Audio Effect > R4F."
echo "Se Live era aperto e il js era già caricato, rimuovi e rimetti il device per ricaricarlo."
