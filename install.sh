#!/bin/bash
# noswoosh installer: builds from source, disables the system's animated
# Ctrl+arrow shortcuts, and installs a login LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"

BIN_DIR="$HOME/.local/bin"
LABEL="ax.max.noswoosh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/noswoosh.log"

if ! command -v swiftc >/dev/null; then
    echo "swiftc not found — install the Xcode Command Line Tools first:"
    echo "  xcode-select --install"
    exit 1
fi

echo "==> Building noswoosh"
swiftc noswoosh.swift -O -o noswoosh \
    -F /System/Library/PrivateFrameworks -framework SkyLight

# Opt-in: a stable Developer ID signature keeps the Accessibility grant across
# rebuilds (macOS ties it to the signing identity, not the binary hash).
if [ -n "${NOSWOOSH_SIGN_IDENTITY:-}" ]; then
    echo "==> Codesigning with $NOSWOOSH_SIGN_IDENTITY"
    codesign --force --options runtime --timestamp \
        --sign "$NOSWOOSH_SIGN_IDENTITY" noswoosh
fi

echo "==> Installing to $BIN_DIR"
mkdir -p "$BIN_DIR"
cp noswoosh noswoosh.swift "$BIN_DIR/"

echo "==> Configuring system (shortcuts + empty-desktop yank fix; restarts the Dock)"
"$BIN_DIR/noswoosh" setup

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
        <string>$BIN_DIR/noswoosh</string>
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
    > "+" > Cmd+Shift+G > $BIN_DIR/noswoosh

  Then restart the daemon:
    launchctl kickstart -k gui/\$(id -u)/$LABEL

  If the checkbox toggle doesn't take (log still says "waiting for
  Accessibility"), REMOVE the entry, restart the daemon to re-trigger the
  prompt, enable it, and restart once more.

Ctrl+Left / Ctrl+Right will then switch spaces instantly.
Log: $LOG
EOF
