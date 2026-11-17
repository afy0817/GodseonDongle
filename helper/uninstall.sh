#!/bin/sh
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: MIT
#
# Removes GodseonDongle's root helper. Run as root. The daemon releases the dongle and
# removes its routes when launchd stops it; routes left by a crashed daemon are removed here,
# but only while they still point at the VM it used (macOS deletes routes by destination).

LABEL=io.github.afy0817.godseon-dongled
BIN=/usr/local/libexec/godseon-dongled
PLIST=/Library/LaunchDaemons/$LABEL.plist
OWNED=/var/run/godseon-dongled.routes

launchctl bootout "system/$LABEL" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    sleep 1
done
if [ -f "$OWNED" ]; then
    while read -r cidr guest; do
        [ -n "$cidr" ] && [ -n "$guest" ] || continue
        route -n get -net "$cidr" 2>/dev/null | grep -q "gateway: $guest\$" &&
            route -n delete -net "$cidr" "$guest" >/dev/null 2>&1
    done <"$OWNED"
fi
rm -f "$PLIST" "$BIN" "$OWNED" /var/run/godseon-dongled.status
echo "removed $LABEL"
