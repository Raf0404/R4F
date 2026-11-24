#!/bin/bash
# Rimuove i driver di R4F e riavvia CoreAudio.
#   sudo driver/uninstall.sh          → R4F BUS + R4F BOX (+ eventuali vecchi LiveBus)
#   sudo driver/uninstall.sh bus|box
set -euo pipefail
HAL="/Library/Audio/Plug-Ins/HAL"
[[ $EUID -eq 0 ]] || { echo "serve sudo: sudo $0 ${1:-}" >&2; exit 1; }

case "${1:-all}" in
    bus) TARGETS=("$HAL/R4FBUS.driver") ;;
    box) TARGETS=("$HAL/R4FBOX.driver") ;;
    all) TARGETS=("$HAL/R4FBUS.driver" "$HAL/R4FBOX.driver" "$HAL"/LiveBus*.driver) ;;
    *) echo "uso: $0 [bus|box|all]" >&2; exit 1 ;;
esac

removed=0
for t in "${TARGETS[@]}"; do
    [[ -d "$t" ]] || continue
    rm -rf "$t"; echo "rimosso: $t"; removed=1
done
[[ $removed == 1 ]] || { echo "niente da rimuovere"; exit 0; }
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall -9 coreaudiod
echo "CoreAudio riavviato"
