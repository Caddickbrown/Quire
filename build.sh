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
for asset in AppIcon.icns AppIcon-light.png AppIcon-dark.png; do
  [ -f "Resources/$asset" ] && cp "Resources/$asset" "$APP/Contents/Resources/$asset"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough for the app to keep its identity (and so its
# window position, defaults and any TCC grants) across rebuilds.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built $APP"
if [ "${1:-}" = "--run" ]; then
  open "$APP"
fi
