#!/bin/bash
# Removes noswoosh and restores the system's animated Ctrl+arrow shortcuts.
set -euo pipefail
cd "$(dirname "$0")"

BIN_DIR="$HOME/.local/bin"
LABEL="ax.max.noswoosh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Stopping and removing LaunchAgent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "==> Re-enabling system animated Ctrl+arrow shortcuts (live + persisted)"
if [ -x "$BIN_DIR/noswoosh-ctrl-arrows" ]; then
    "$BIN_DIR/noswoosh-ctrl-arrows" on
elif command -v swiftc >/dev/null; then
    swiftc tools/ctrl-arrows.swift -o /tmp/noswoosh-ctrl-arrows
    /tmp/noswoosh-ctrl-arrows on
else
    echo "    re-enable manually in System Settings > Keyboard > Keyboard Shortcuts > Mission Control"
fi

echo "==> Restoring the Dock's default space-follow behavior (restarts the Dock)"
defaults delete com.apple.dock workspaces-auto-swoosh 2>/dev/null || true
killall Dock 2>/dev/null || true

echo "==> Removing binaries and source"
rm -f "$BIN_DIR/noswoosh" "$BIN_DIR/noswoosh.swift" "$BIN_DIR/noswoosh-ctrl-arrows"

echo
echo "Done. Optionally remove 'noswoosh' from"
echo "System Settings > Privacy & Security > Accessibility."
