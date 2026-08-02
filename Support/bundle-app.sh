#!/bin/bash
# Wraps the SwiftPM-built menu bar executable into ReRNDIS.app with an ad-hoc
# signature. Locally built bundles carry no quarantine, so Gatekeeper stays out
# of the picture. Usage: Support/bundle-app.sh [debug|release] [apple]
set -euo pipefail

CONFIG="${1:-release}"
LAYOUT="${2:-}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$LAYOUT" = "apple" ]; then
  BIN="$REPO/.build/apple/Products/Release/ReRNDISApp"
else
  BIN="$REPO/.build/$CONFIG/ReRNDISApp"
fi

if [ ! -f "$BIN" ]; then
  echo "app binary missing: build first (make build)" >&2
  exit 1
fi

APP="$REPO/dist/ReRNDIS.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO/Support/App-Info.plist" "$APP/Contents/Info.plist"
cp "$REPO/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/ReRNDIS"

# Localized strings live in the SwiftPM resource bundle, resolved at runtime
# from Contents/Resources. Shipping without it would strip every UI string.
RES_BUNDLE="$(dirname "$BIN")/ReRNDIS_ReRNDISApp.bundle"
if [ ! -d "$RES_BUNDLE" ]; then
  echo "resource bundle missing at $RES_BUNDLE" >&2
  exit 1
fi
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"

# Payload the app installs with an authorization prompt. Prefer universal
# binaries from dist/ when a `make dist` produced them.
PAYLOAD="$APP/Contents/Resources/Payload"
mkdir -p "$PAYLOAD"
for tool in ReRNDISDaemon rerndisctl; do
  if [ -f "$REPO/dist/ReRNDIS-dist/$tool" ]; then
    cp "$REPO/dist/ReRNDIS-dist/$tool" "$PAYLOAD/$tool"
  else
    cp "$REPO/.build/$CONFIG/$tool" "$PAYLOAD/$tool"
  fi
done
cp "$REPO/Support/be.zvz.rerndis.daemon.plist" "$PAYLOAD/"
cp "$REPO/Support/install.sh" "$REPO/Support/uninstall.sh" "$PAYLOAD/"
chmod +x "$PAYLOAD/install.sh" "$PAYLOAD/uninstall.sh" "$PAYLOAD/ReRNDISDaemon" "$PAYLOAD/rerndisctl"

codesign --force --deep --sign - "$APP"
echo "bundled $APP"
