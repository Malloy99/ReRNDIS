#!/bin/bash
# Removes the rerndisd LaunchDaemon and cleans leftover interfaces.
set -euo pipefail

if [ "$(id -u)" != 0 ]; then
  echo "run with sudo" >&2
  exit 1
fi

LABEL="be.zvz.rerndis.daemon"

launchctl bootout "system/$LABEL" 2>/dev/null || true
if [ -x "/Library/PrivilegedHelperTools/$LABEL" ]; then
  "/Library/PrivilegedHelperTools/$LABEL" cleanup || true
fi
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL" /usr/local/bin/rerndisctl
echo "removed $LABEL"
