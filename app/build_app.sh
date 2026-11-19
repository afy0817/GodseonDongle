#!/bin/sh
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: MIT
#
# Builds dist/GodseonDongle.app: the app, its VM image and its root helper, ad-hoc signed
# with the virtualization entitlement only (no Apple developer account needed).
#   ./app/build_app.sh [--install]     --install copies it to /Applications
# The VM image (dist/vm_assets) is built with Docker the first time, again when vm/ no longer
# matches the hash its manifest keeps, or always with GODSEON_REBUILD_VM=1 (=0 keeps it).

set -eu

# SwiftUI's macros (@State and friends) ship with Xcode, not with the Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ] &&
    [ "$(xcode-select -p 2>/dev/null)" = /Library/Developer/CommandLineTools ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    export DEVELOPER_DIR
fi

APP_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$APP_DIR/.." && pwd)
DIST=$ROOT/dist
ASSETS=$DIST/vm_assets
BUNDLE=$DIST/GodseonDongle.app
VERSION=${GODSEON_VERSION:-0.1.0}

REBUILD_VM=${GODSEON_REBUILD_VM:-}
if [ -z "$REBUILD_VM" ] && [ -f "$ASSETS/manifest.json" ]; then
    # The app and the VM scripts change together (kernel command line, control API).
    WANT=$(sh "$ROOT/vm/build.sh" --sources-hash)
    HAVE=$(plutil -extract sources raw -o - "$ASSETS/manifest.json" 2>/dev/null || true)
    if [ "$WANT" != "$HAVE" ]; then
        echo "dist/vm_assets comes from other vm/ sources (${HAVE:-unknown}, now $WANT); rebuilding it." \
            "GODSEON_REBUILD_VM=0 keeps it." >&2
        REBUILD_VM=1
    fi
fi
if [ ! -f "$ASSETS/initramfs-thrurndis-wifi" ] || [ "$REBUILD_VM" = 1 ]; then
    THRURNDIS_WIFI_VERSION="godseon-$VERSION" sh "$ROOT/vm/build.sh" "$ASSETS"
fi

swift build --package-path "$APP_DIR" -c release
BINARY=$(swift build --package-path "$APP_DIR" -c release --show-bin-path)/GodseonDongle

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/helper" "$BUNDLE/Contents/Resources/vm_assets"
cp "$BINARY" "$BUNDLE/Contents/MacOS/GodseonDongle"
cp "$APP_DIR/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"   # swift app/icon/make_icon.swift
cp -R "$APP_DIR/Resources/en.lproj" "$APP_DIR/Resources/ko.lproj" "$BUNDLE/Contents/Resources/"
for file in Image-lts initramfs-thrurndis-wifi manifest.json SHA256SUMS; do
    cp "$ASSETS/$file" "$BUNDLE/Contents/Resources/vm_assets/"
done
clang -fobjc-arc -O2 -Wall -mmacosx-version-min=14.0 -o "$BUNDLE/Contents/Resources/helper/godseon-dongled" \
    "$ROOT/helper/godseon-dongled.m" -framework Foundation -framework IOKit -framework IOUSBHost \
    -framework SystemConfiguration
cp "$ROOT/helper/install.sh" "$ROOT/helper/uninstall.sh" "$BUNDLE/Contents/Resources/helper/"
chmod 755 "$BUNDLE/Contents/Resources/helper/"*

cat >"$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.afy0817.GodseonDongle</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
    <key>CFBundleName</key><string>GodseonDongle</string>
    <key>CFBundleDisplayName</key><string>GodseonDongle</string>
    <key>CFBundleExecutable</key><string>GodseonDongle</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>MIT / GPL-2.0-or-later (VM scripts)</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Connects to the Wi-Fi control API inside the VM the app starts.</string>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
EOF

codesign --force --sign - --timestamp=none --entitlements "$APP_DIR/GodseonDongle.entitlements" "$BUNDLE"
codesign --verify --strict "$BUNDLE"
echo "built $BUNDLE"

if [ "${1:-}" = "--install" ]; then
    osascript -e 'tell application id "io.github.afy0817.GodseonDongle" to quit' >/dev/null 2>&1 || true
    sleep 2
    rm -rf /Applications/GodseonDongle.app
    cp -R "$BUNDLE" /Applications/GodseonDongle.app
    echo "installed /Applications/GodseonDongle.app"
fi
