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

echo "==> Restoring system defaults (shortcuts + Dock space-follow; restarts the Dock)"
if [ -x "$BIN_DIR/noswoosh" ]; then
    "$BIN_DIR/noswoosh" teardown
else
    echo "    noswoosh binary missing — re-enable Ctrl+arrows in System Settings >"
    echo "    Keyboard > Keyboard Shortcuts > Mission Control, and run:"
    echo "    defaults delete com.apple.dock workspaces-auto-swoosh && killall Dock"
fi

echo "==> Removing binaries and source"
rm -f "$BIN_DIR/noswoosh" "$BIN_DIR/noswoosh.swift" "$BIN_DIR/noswoosh-ctrl-arrows"

echo
echo "Done. Optionally remove 'noswoosh' from"
echo "System Settings > Privacy & Security > Accessibility."
