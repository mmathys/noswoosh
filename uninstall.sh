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

echo "==> Removing binary and source"
rm -f "$BIN_DIR/spaceswitcher" "$BIN_DIR/spaceswitcher.swift"

echo "==> Re-enabling system animated Ctrl+arrow shortcuts (persisted)"
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 79 \
    '{enabled = 1; value = { parameters = (65535, 123, 8650752); type = standard; };}'
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 81 \
    '{enabled = 1; value = { parameters = (65535, 124, 8650752); type = standard; };}'

echo "==> Re-enabling them live"
if command -v swiftc >/dev/null; then
    swiftc tools/ctrl-arrows.swift -o /tmp/spaceswitcher-ctrl-arrows \
        && /tmp/spaceswitcher-ctrl-arrows on \
        || echo "    live enable failed — log out and back in to apply"
else
    echo "    swiftc not found — log out and back in to apply"
fi

echo
echo "Done. Optionally remove 'spaceswitcher' from"
echo "System Settings > Privacy & Security > Accessibility."
