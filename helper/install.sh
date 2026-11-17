#!/bin/sh
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: MIT
#
# Installs GodseonDongle's root helper (godseon-dongled) as a launchd daemon.
# Run as root (the app asks with an administrator prompt):
#   install.sh <godseon-dongled binary> <config-file>

set -eu

SOURCE=${1:?usage: install.sh <godseon-dongled> <config-file>}
CONFIG=${2:?usage: install.sh <godseon-dongled> <config-file>}
LABEL=io.github.afy0817.godseon-dongled
BIN=/usr/local/libexec/godseon-dongled
PLIST=/Library/LaunchDaemons/$LABEL.plist
LOG=/var/log/godseon-dongled.log

case "$CONFIG" in
    /Users/*/Library/Application\ Support/GodseonDongle/helper.conf) ;;
    *) echo "unexpected config path: $CONFIG" >&2; exit 1 ;;
esac

# An older copy releases the dongle and removes its routes on SIGTERM; wait for it to go,
# so the new one can take TCP 9408.
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "system/$LABEL" >/dev/null 2>&1 || break
        sleep 1
    done
fi

mkdir -p /usr/local/libexec
install -o root -g wheel -m 755 "$SOURCE" "$BIN"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>$CONFIG</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootstrap system "$PLIST"
echo "installed $LABEL"
