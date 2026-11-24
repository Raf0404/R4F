#!/bin/bash
# Installa R4F BUS e/o R4F BOX in /Library/Audio/Plug-Ins/HAL e riavvia CoreAudio.
# Toglie anche i vecchi driver "LiveBus" (sostituiti da R4F BUS).
# Richiede la password di amministratore; l'audio di tutte le app si ferma per qualche secondo:
# chiudi la DAW prima di lanciarlo.
#
#   sudo driver/install.sh          → R4F BUS + R4F BOX
#   sudo driver/install.sh bus      → solo R4F BUS
#   sudo driver/install.sh box      → solo R4F BOX
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HAL="/Library/Audio/Plug-Ins/HAL"
[[ $EUID -eq 0 ]] || { echo "serve sudo: sudo $0 ${1:-}" >&2; exit 1; }

case "${1:-all}" in
    bus) NAMES=(R4FBUS) ;;
    box) NAMES=(R4FBOX) ;;
    all) NAMES=(R4FBUS R4FBOX) ;;
    *) echo "uso: $0 [bus|box|all]" >&2; exit 1 ;;
esac

for n in "${NAMES[@]}"; do
    SRC="$ROOT/driver/build/$n.driver"
    [[ -d "$SRC" ]] || { echo "manca $SRC: lancia prima driver/build.sh" >&2; exit 1; }
    codesign --verify "$SRC" || { echo "firma non valida in $SRC, ricompila" >&2; exit 1; }
done

for old in "$HAL"/LiveBus*.driver; do
    [[ -d "$old" ]] || continue
    rm -rf "$old"
    echo "rimosso il vecchio driver: $old"
done

for n in "${NAMES[@]}"; do
    rm -rf "$HAL/$n.driver"
    cp -R "$ROOT/driver/build/$n.driver" "$HAL/"
    chown -R root:wheel "$HAL/$n.driver"
    chmod -R go-w "$HAL/$n.driver"
    echo "installato: $HAL/$n.driver"
done

echo "riavvio CoreAudio…"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall -9 coreaudiod
sleep 3
LIST="$(system_profiler SPAudioDataType 2>/dev/null)"
for n in "${NAMES[@]}"; do
    disp="R4F ${n#R4F}"
    if grep -q "$disp:" <<<"$LIST"; then echo "ok: \"$disp\" è disponibile"; else echo "attenzione: \"$disp\" non compare ancora; riprova tra qualche secondo" >&2; fi
done
