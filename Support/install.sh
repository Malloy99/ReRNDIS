#!/bin/bash
# Installs rerndisd as a LaunchDaemon. Run from the repo root: sudo Support/install.sh [debug|release]
set -euo pipefail

if [ "$(id -u)" != 0 ]; then
  echo "run with sudo" >&2
  exit 1
fi

LABEL="be.zvz.rerndis.daemon"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Distribution zip layout: binaries and plist sit next to this script.
if [ -f "$HERE/ReRNDISDaemon" ] && [ -f "$HERE/$LABEL.plist" ]; then
  BIN="$HERE/ReRNDISDaemon"
  PLIST_SRC="$HERE/$LABEL.plist"
else
  CONFIG="${1:-release}"
  REPO="$(cd "$HERE/.." && pwd)"
  BIN="$REPO/.build/$CONFIG/ReRNDISDaemon"
  PLIST_SRC="$REPO/Support/$LABEL.plist"
fi

if [ ! -f "$BIN" ]; then
  echo "daemon binary missing: build first (make build)" >&2
  exit 1
fi

launchctl bootout "system/$LABEL" 2>/dev/null || true
# Wait for the old instance to drain: bootstrapping too early fails with EIO.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl print "system/$LABEL" >/dev/null 2>&1 || break
  sleep 1
done

install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$BIN" "/Library/PrivilegedHelperTools/$LABEL"
install -o root -g wheel -m 644 "$PLIST_SRC" "/Library/LaunchDaemons/$LABEL.plist"

CTL="$(dirname "$BIN")/rerndisctl"
if [ -f "$CTL" ]; then
  install -d -o root -g wheel -m 755 /usr/local/bin
  install -o root -g wheel -m 755 "$CTL" /usr/local/bin/rerndisctl
fi

bootstrapped=0
for _ in 1 2 3 4 5; do
  if launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist"; then
    bootstrapped=1
    break
  fi
  sleep 2
done
if [ "$bootstrapped" != 1 ]; then
  echo "bootstrap failed after retries" >&2
  exit 1
fi
launchctl kickstart -k "system/$LABEL"
echo "installed and started $LABEL"
