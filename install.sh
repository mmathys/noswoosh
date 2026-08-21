#!/bin/bash
# spaceswitcher installer: builds from source, disables the system's animated
# Ctrl+arrow shortcuts, and installs a login LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"

BIN_DIR="$HOME/.local/bin"
LABEL="com.$USER.spaceswitcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/spaceswitcher.log"

if ! command -v swiftc >/dev/null; then
    echo "swiftc not found — install the Xcode Command Line Tools first:"
    echo "  xcode-select --install"
    exit 1
fi

echo "==> Building spaceswitcher"
swiftc spaceswitcher.swift -O -o spaceswitcher \
    -F /System/Library/PrivateFrameworks -framework SkyLight
swiftc tools/ctrl-arrows.swift -O -o spaceswitcher-ctrl-arrows

echo "==> Installing to $BIN_DIR"
mkdir -p "$BIN_DIR"
cp spaceswitcher spaceswitcher.swift spaceswitcher-ctrl-arrows "$BIN_DIR/"

echo "==> Disabling system animated Ctrl+arrow shortcuts (live + persisted)"
"$BIN_DIR/spaceswitcher-ctrl-arrows" off

echo "==> Installing LaunchAgent $LABEL"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/spaceswitcher</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

cat <<EOF

Done. One manual step remains:

  Grant Accessibility permission (macOS will prompt, or add it yourself):
  System Settings > Privacy & Security > Accessibility
    > "+" > Cmd+Shift+G > $BIN_DIR/spaceswitcher

  Then restart the daemon:
    launchctl kickstart -k gui/\$(id -u)/$LABEL

  If the checkbox toggle doesn't take (log still says "waiting for
  Accessibility"), REMOVE the entry, restart the daemon to re-trigger the
  prompt, enable it, and restart once more.

Ctrl+Left / Ctrl+Right will then switch spaces instantly.
Log: $LOG
EOF
