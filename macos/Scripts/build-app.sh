#!/bin/bash
# Builds Distee.app without Xcode (Command Line Tools only).
#   Scripts/build-app.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIGURATION="${1:-release}"

echo "==> Building Distee ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product Distee
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

APP_DIR="build/Distee.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH/Distee" "$APP_DIR/Contents/MacOS/Distee"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# Ad-hoc signature with stable designated requirement to prevent Keychain prompts across builds
if codesign --force --sign - -i com.distee.agent -r='designated => identifier "com.distee.agent"' "$APP_DIR" >/dev/null 2>&1; then
    echo "==> Ad-hoc signed with stable identifier"
else
    echo "==> WARNING: ad-hoc signing failed; the app will still run locally"
fi

echo "==> Built $APP_DIR"
echo "    Launch:  open $APP_DIR"
echo "    Diagnose: $APP_DIR/Contents/MacOS/Distee --diagnose"
