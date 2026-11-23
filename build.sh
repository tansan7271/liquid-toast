#!/bin/zsh
# Builds build/Liquid Toast.app with plain swiftc. Command Line Tools are enough; Xcode is not needed.
#   ./build.sh          build only
#   ./build.sh run      build, then (quit it if running and) open it from build/   — for development
#   ./build.sh install  build, move it to /Applications, and open it                — for everyday use
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Liquid Toast.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    -o "$APP/Contents/MacOS/LiquidToast" Sources/*.swift

# Sign with the project-local self-signed certificate if there is one, so the Accessibility permission
# survives rebuilds. Otherwise sign ad hoc; then macOS asks for the permission again after every build.
# Create the certificate once with ./setup-signing.sh.
KC="$PWD/.signing/liquidtoast-dev.keychain-db"
SIGNED=0
if [[ -f "$KC" ]]; then
    security unlock-keychain -p "$(cat "$PWD/.signing/password")" "$KC" 2>/dev/null || true
    ID=$(security find-identity -p codesigning "$KC" | awk '/Liquid Toast Local Dev/ {print $2; exit}')
    if [[ -n "$ID" ]] && codesign --force --keychain "$KC" --sign "$ID" "$APP" >/dev/null 2>&1; then
        SIGNED=1
    else
        echo "⚠️  Self-signing failed. Run ./setup-signing.sh again. Signing ad hoc instead."
    fi
fi
[[ $SIGNED == 1 ]] || codesign --force --sign - "$APP"
echo "✅ $APP"

if [[ "${1:-}" == "install" ]]; then
    DEST="/Applications/Liquid Toast.app"
    pkill -x LiquidToast 2>/dev/null && sleep 0.5 || true
    rm -rf "$DEST"
    mv "$APP" "$DEST"
    open "$DEST"
    echo "✅ Installed: $DEST"
fi

if [[ "${1:-}" == "run" ]]; then
    pkill -x LiquidToast 2>/dev/null && sleep 0.5 || true
    open "$APP"
fi
