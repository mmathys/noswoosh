#!/bin/bash
# Removes spaceswitcher and restores the system's animated Ctrl+arrow shortcuts.
set -euo pipefail
cd "$(dirname "$0")"

BIN_DIR="$HOME/.local/bin"
LABEL="com.$USER.spaceswitcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Stopping and removing LaunchAgent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "==> Re-enabling system animated Ctrl+arrow shortcuts (live + persisted)"
if [ -x "$BIN_DIR/spaceswitcher-ctrl-arrows" ]; then
    "$BIN_DIR/spaceswitcher-ctrl-arrows" on
elif command -v swiftc >/dev/null; then
    swiftc tools/ctrl-arrows.swift -o /tmp/spaceswitcher-ctrl-arrows
    /tmp/spaceswitcher-ctrl-arrows on
else
    echo "    re-enable manually in System Settings > Keyboard > Keyboard Shortcuts > Mission Control"
fi

echo "==> Removing binaries and source"
rm -f "$BIN_DIR/spaceswitcher" "$BIN_DIR/spaceswitcher.swift" "$BIN_DIR/spaceswitcher-ctrl-arrows"

echo
echo "Done. Optionally remove 'spaceswitcher' from"
echo "System Settings > Privacy & Security > Accessibility."
