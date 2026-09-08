#!/bin/bash
# Builds wander.app into build/. Pass --run to launch it afterwards.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${CONFIG:-release}
APP="build/wander.app"

swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)/Wander

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wander"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for asset in AppIcon.icns AppIcon-light.png AppIcon-dark.png themes.json; do
  [ -f "Resources/$asset" ] && cp "Resources/$asset" "$APP/Contents/Resources/$asset"
done
# Every theme's faces travel with the app; Fonts.register() picks them up.
rm -rf "$APP/Contents/Resources/Fonts"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
[ -d Resources/Icons ] && cp -R Resources/Icons "$APP/Contents/Resources/Icons"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signed with the same identity and team as Nook, with the hardened runtime.
# Falls back to an ad-hoc signature when no certificate is installed — enough
# for the app to keep its identity (and so its window position, defaults and
# any TCC grants) across rebuilds, but not enough to run on another machine.
TEAM=${DEVELOPMENT_TEAM:-52W73J6V95}
IDENTITY=${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep -m1 "Apple Development" | sed 's/.*"\(.*\)"/\1/')}

if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime \
    --entitlements Resources/Wander-macOS.entitlements \
    --sign "$IDENTITY" "$APP"
  echo "signed as $IDENTITY (team $TEAM)"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "no signing certificate found — signed ad-hoc"
fi

echo "built $APP"
if [ "${1:-}" = "--run" ]; then
  open "$APP"
fi
