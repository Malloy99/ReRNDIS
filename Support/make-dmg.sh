#!/bin/bash
# Builds the drag-to-install DMG: app on the left, /Applications on the right.
# Finder scripting writes the .DS_Store, so the layout step degrades gracefully
# where Finder automation is unavailable (CI).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$REPO/dist/dmg-root"
RW="$REPO/dist/ReRNDIS-rw.dmg"
OUT="$REPO/dist/ReRNDIS-dist.dmg"
VOLUME="/Volumes/ReRNDIS"

rm -rf "$STAGE" "$RW" "$OUT"
mkdir -p "$STAGE"
cp -R "$REPO/dist/ReRNDIS.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -fs HFS+ -volname ReRNDIS -srcfolder "$STAGE" -ov -quiet -format UDRW "$RW"
hdiutil detach "$VOLUME" -quiet 2>/dev/null || true
hdiutil attach "$RW" -nobrowse -quiet

if ! osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "ReRNDIS"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 104
    set text size of viewOptions to 13
    set position of item "ReRNDIS.app" of container window to {165, 185}
    set position of item "Applications" of container window to {495, 185}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo "warning: Finder layout scripting failed; shipping an unstyled DMG" >&2
fi

sync
for _ in 1 2 3 4 5; do
  hdiutil detach "$VOLUME" -quiet 2>/dev/null && break
  sleep 1
done
hdiutil convert "$RW" -quiet -format UDZO -o "$OUT"
rm -f "$RW"
rm -rf "$STAGE"
echo "$OUT ready"
