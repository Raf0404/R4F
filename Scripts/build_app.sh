#!/bin/bash
# Crea R4F.app (icona nella barra dei menu: R4F BUS + R4F BOX) e la installa in /Applications
# (o ~/Applications se /Applications non è scrivibile). Niente sudo.
#   Scripts/build_app.sh            → compila, assembla, firma ad-hoc, installa
#   Scripts/build_app.sh --no-install
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
cd "$ROOT"
swift build -c release 2>&1 | grep -E "error|Build complete" || true
BIN="$ROOT/.build/release/livebus"
[[ -x "$BIN" ]] || { echo "compilazione fallita" >&2; exit 1; }

APP="$ROOT/build/R4F.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/R4F"
cp -R "$ROOT/examples" "$APP/Contents/Resources/examples"
cp "$ROOT/assets/R4F.icns" "$APP/Contents/Resources/R4F.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>local.r4f.app</string>
	<key>CFBundleName</key><string>R4F</string>
	<key>CFBundleDisplayName</key><string>R4F</string>
	<key>CFBundleExecutable</key><string>R4F</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleIconFile</key><string>R4F</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>R4F legge R4F BUS, su cui suona la tua DAW, per mandarlo alle tue schede audio.</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key><string>local.r4f.app</string>
			<key>CFBundleURLSchemes</key><array><string>r4f</string><string>livebus</string></array>
		</dict>
	</array>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null
codesign --verify "$APP"
echo "ok: $APP"

[[ "${1:-}" == "--no-install" ]] && exit 0
DEST_DIR="/Applications"
[[ -w "$DEST_DIR" ]] || { DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; }
WAS_RUNNING=0
if pgrep -f "R4F.app/Contents/MacOS/R4F" >/dev/null || pgrep -f "LiveBus.app/Contents/MacOS/livebus" >/dev/null; then
    WAS_RUNNING=1
    echo "R4F/LiveBus è aperta: la chiudo per aggiornarla"
    osascript -e 'quit app id "local.r4f.app"' >/dev/null 2>&1 || true
    osascript -e 'quit app id "local.livebus.app"' >/dev/null 2>&1 || true
    sleep 1
    pkill -f "R4F.app/Contents/MacOS/R4F" || true
    pkill -f "LiveBus.app/Contents/MacOS/livebus" || true
fi
# la vecchia LiveBus.app è sostituita da R4F.app
for old in "/Applications/LiveBus.app" "$HOME/Applications/LiveBus.app"; do
    if [[ -d "$old" ]]; then rm -rf "$old"; echo "rimossa la vecchia $old"; fi
done
rm -rf "$DEST_DIR/R4F.app"
cp -R "$APP" "$DEST_DIR/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST_DIR/R4F.app"
echo "installata: $DEST_DIR/R4F.app  (URL r4f:// e livebus:// registrati)"
if [[ $WAS_RUNNING == 1 ]]; then
    open "$DEST_DIR/R4F.app"
    echo "R4F avviata"
fi
