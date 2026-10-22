#!/bin/bash
# Builds build/Swivel.app.
#   ./build.sh --test       run the layout tests first
#   ./build.sh --install    then copy it to /Applications and restart it
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

if [[ " $* " == *" --test "* ]]; then
  xcrun swiftc -O Sources/Layout.swift Tests/main.swift -o build/layout-tests
  build/layout-tests
fi

if [[ ! -f build/AppIcon.icns || Tools/make-icon.swift -nt build/AppIcon.icns ]]; then
  xcrun swiftc -O Tools/make-icon.swift -o build/make-icon
  rm -rf build/AppIcon.iconset
  build/make-icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

APP=build/Swivel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xcrun swiftc -O -module-name Swivel -target "$(uname -m)-apple-macos14.0" Sources/*.swift -o "$APP/Contents/MacOS/Swivel"
# macOS ties Accessibility and Screen Recording permissions to the signature. Signing every build with
# the same certificate (Tools/make-signing-cert.sh creates it) keeps them across updates; without it,
# fall back to an ad-hoc signature, which needs re-approving after each build.
IDENTITY="Swivel Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "No \"$IDENTITY\" certificate (run Tools/make-signing-cert.sh); signing ad-hoc."
  codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [[ " $* " == *" --install "* ]]; then
  pkill -f "Swivel.app/Contents/MacOS/Swivel" || true
  sleep 0.5
  rm -rf /Applications/Swivel.app
  cp -R "$APP" /Applications/Swivel.app
  open /Applications/Swivel.app
  echo "Installed /Applications/Swivel.app"
fi
