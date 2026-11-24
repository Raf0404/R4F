#!/bin/bash
# Compila i driver virtuali di R4F (256 canali, universali arm64+x86_64, firmati ad-hoc), senza Xcode.
#
#   driver/build.sh          → R4F BUS e R4F BOX
#   driver/build.sh bus      → solo R4F BUS  (il bus su cui suona la DAW; l'app lo smista alle schede)
#   driver/build.sh box      → solo R4F BOX  (scheda virtuale tra programmi, con matrice interna)
#
# Risultato: driver/build/R4FBUS.driver, driver/build/R4FBOX.driver
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BH="$ROOT/vendor/BlackHole"
[[ -f "$BH/BlackHole/BlackHole.c" ]] || { echo "manca vendor/BlackHole (git clone --branch v0.7.2 https://github.com/ExistentialAudio/BlackHole.git vendor/BlackHole)" >&2; exit 1; }
VERSION="$(cat "$ROOT/driver/VERSION")"
CH=256
OUT="$ROOT/driver/build"
mkdir -p "$OUT"

build() {
    local kind="$1"            # bus | box
    local NAME DISPLAY SRC BUNDLE_ID
    if [[ "$kind" == "bus" ]]; then
        NAME="R4FBUS"; DISPLAY="R4F BUS"; SRC="$BH/BlackHole/BlackHole.c"
    else
        NAME="R4FBOX"; DISPLAY="R4F BOX"
        python3 -I "$ROOT/driver/r4fbox/make_source.py" >/dev/null
        SRC="$ROOT/driver/r4fbox/R4FBox.c"
    fi
    BUNDLE_ID="local.r4f.$kind"
    local BNDL="$OUT/$NAME.driver"

    # UUID della factory: stabile per driver, così una reinstallazione non lascia doppioni
    local UUID_FILE="$ROOT/driver/factory-uuid-$kind.txt"
    [[ -f "$UUID_FILE" ]] || uuidgen | tr 'A-Z' 'a-z' > "$UUID_FILE"
    local UUID; UUID="$(cat "$UUID_FILE")"

    rm -rf "$BNDL"
    mkdir -p "$BNDL/Contents/MacOS" "$BNDL/Contents/Resources"
    clang -bundle -Os -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
      -Wno-unused-parameter -Wno-deprecated-declarations -Wno-four-char-constants -Wno-format-extra-args \
      -DkNumber_Of_Channels="$CH" \
      -DkHas_Driver_Name_Format=false \
      -DkDriver_Name="\"$DISPLAY\"" \
      -DkDevice_Name="\"$DISPLAY\"" \
      -DkDevice2_Name="\"$DISPLAY Mirror\"" \
      -DkPlugIn_BundleID="\"$BUNDLE_ID\"" \
      -DkPlugIn_Icon='"R4F.icns"' \
      -DkManufacturer_Name='"R4F (based on BlackHole, GPL-3.0)"' \
      -DkEnableVolumeControl=false \
      -DkCanBeDefaultSystemDevice=false \
      -DkSampleRates='44100,48000,88200,96000' \
      -framework CoreAudio -framework CoreFoundation -framework Accelerate \
      -o "$BNDL/Contents/MacOS/$NAME" "$SRC"

    sed -e "s/\${EXECUTABLE_NAME}/$NAME/" \
        -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" \
        -e "s/\${PRODUCT_NAME}/$NAME/" \
        -e "s/\$(MARKETING_VERSION)/$VERSION/" \
        -e "s/e395c745-4eea-4d94-bb92-46224221047c/$UUID/g" \
        "$BH/BlackHole/BlackHole.plist" > "$BNDL/Contents/Info.plist"
    plutil -lint -s "$BNDL/Contents/Info.plist"

    # GPL-3: licenza e provenienza dentro il bundle; il sorgente è in vendor/BlackHole e driver/
    cp "$ROOT/assets/R4F.icns" "$BNDL/Contents/Resources/R4F.icns"   # icona in Configurazione MIDI Audio
    cp "$BH/LICENSE" "$BNDL/Contents/Resources/LICENSE-BlackHole.txt"
    {
        echo "$DISPLAY $VERSION — $CH canali"
        echo "Basato su BlackHole v$(cat "$BH/VERSION") (https://github.com/ExistentialAudio/BlackHole), GPL-3.0."
        if [[ "$kind" == "box" ]]; then
            echo "Modifiche al sorgente: matrice uscite→ingressi (proprietà 'r4fm'), vedi driver/r4fbox/make_source.py."
        else
            echo "Sorgente non modificato: solo costanti di compilazione (vedi driver/build.sh)."
        fi
    } > "$BNDL/Contents/Resources/SOURCE.txt"

    codesign --force --sign - "$BNDL" 2>/dev/null
    codesign --verify "$BNDL"
    echo "ok: $BNDL ($(lipo -archs "$BNDL/Contents/MacOS/$NAME"))"
}

case "${1:-all}" in
    bus) build bus ;;
    box) build box ;;
    all) build bus; build box ;;
    *) echo "uso: $0 [bus|box|all]" >&2; exit 1 ;;
esac
