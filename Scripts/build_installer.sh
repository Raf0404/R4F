#!/bin/bash
# Crea l'installer di R4F: build/R4F-<versione>.pkg
#   - /Library/Audio/Plug-Ins/HAL/R4FBUS.driver e R4FBOX.driver
#   - /Applications/R4F.app
#   - /Library/Application Support/R4F/MaxForLive (device per Live, copiato nella User Library dal postinstall)
# Non firmato con un certificato Developer ID: al primo avvio macOS chiede conferma (vedi README).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
OUT="$ROOT/build"
WORK="$OUT/pkgwork"
PKG="$OUT/R4F-$VERSION.pkg"
cd "$ROOT"

echo "→ driver"
Scripts/fetch_blackhole.sh >/dev/null
driver/build.sh >/dev/null 2>&1 || { driver/build.sh; exit 1; }
echo "→ app"
Scripts/build_app.sh --no-install | tail -1
echo "→ device per Live"
python3 -I device/build_device.py >/dev/null

rm -rf "$WORK"
mkdir -p "$WORK/root/Library/Audio/Plug-Ins/HAL" "$WORK/root/Applications" \
         "$WORK/root/Library/Application Support/R4F/MaxForLive" "$WORK/scripts" "$WORK/resources"
cp -R driver/build/R4FBUS.driver driver/build/R4FBOX.driver "$WORK/root/Library/Audio/Plug-Ins/HAL/"
cp -R build/R4F.app "$WORK/root/Applications/"
cp "device/build/R4F Out.amxd" device/livebus_out.js "$WORK/root/Library/Application Support/R4F/MaxForLive/"
cp installer/scripts/preinstall installer/scripts/postinstall "$WORK/scripts/"
chmod 755 "$WORK/scripts/"*
cp installer/resources/welcome.html installer/resources/conclusion.html "$WORK/resources/"
cp LICENSE "$WORK/resources/LICENSE.txt"
# niente attributi estesi (quarantena, metadati Finder) dentro il pacchetto, script compresi
xattr -cr "$WORK"

# l'app non deve essere "spostabile" altrove dall'Installer se ne esiste un'altra copia
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
i=0
while /usr/libexec/PlistBuddy -c "Print :$i" "$WORK/components.plist" >/dev/null 2>&1; do
    /usr/libexec/PlistBuddy -c "Delete :$i:BundleIsRelocatable" "$WORK/components.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :$i:BundleIsRelocatable bool false" "$WORK/components.plist"
    i=$((i + 1))
done

COPYFILE_DISABLE=1 pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" --scripts "$WORK/scripts" \
         --identifier local.r4f.pkg --version "$VERSION" --install-location / "$WORK/R4F-component.pkg" >/dev/null

cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>R4F $VERSION</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <license file="LICENSE.txt" mime-type="text/plain"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions><os-version min="13.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline><line choice="default"><line choice="local.r4f.pkg"/></line></choices-outline>
    <choice id="default"/>
    <choice id="local.r4f.pkg" visible="false"><pkg-ref id="local.r4f.pkg"/></choice>
    <pkg-ref id="local.r4f.pkg" version="$VERSION" onConclusion="none">R4F-component.pkg</pkg-ref>
</installer-gui-script>
XML

export COPYFILE_DISABLE=1   # niente file ._ nel pacchetto
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" "$PKG" >/dev/null
rm -rf "$WORK"
echo "ok: $PKG ($(du -h "$PKG" | cut -f1))"
