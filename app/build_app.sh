#!/bin/sh
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: MIT
#
# Builds dist/GodseonDongle.app: the app, its VM image and its root helper, ad-hoc signed
# with the virtualization entitlement only (no Apple developer account needed).
#   ./app/build_app.sh [--install]     --install copies it to /Applications
#   ./app/build_app.sh --release       also fetches the VM image's corresponding source,
#                                      dist/vm_assets-sources.tar.gz, for the GitHub release
# The VM image is a GodseonDongle-VM release, pinned in vm-assets.env: vm_assets.zip is
# downloaded once into dist/cache and checked against its sha256. To bundle a local build
# instead (after ./build.sh in a GodseonDongle-VM checkout):
#   VM_ASSETS_DIR=../GodseonDongle-VM/dist/vm_assets ./app/build_app.sh

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
# The version the app shows: GODSEON_VERSION (the workflow passes the tag's), else the nearest v*
# tag HEAD descends from. The commit goes into Info.plist too, with -dirty for uncommitted changes.
if [ -z "${GODSEON_VERSION:-}" ]; then
    GODSEON_VERSION=$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)
fi
VERSION=${GODSEON_VERSION:-0.0.0}
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)
if [ -n "$COMMIT" ] && ! git -C "$ROOT" diff --quiet HEAD --; then
    COMMIT=$COMMIT-dirty
fi
COMMIT_KEY=""
if [ -n "$COMMIT" ]; then
    COMMIT_KEY="<key>GodseonCommit</key><string>$COMMIT</string>"
fi

# shellcheck source=../vm-assets.env
. "$ROOT/vm-assets.env"
sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
# fetch <url> <sha256> <file>: downloads into <file> unless it is there with that sha256
fetch() {
    if [ -f "$3" ] && [ "$(sha256 "$3")" = "$2" ]; then
        return 0
    fi
    mkdir -p "$(dirname "$3")"
    echo "downloading $1"
    curl -fL --retry 3 -o "$3.part" "$1"
    if [ "$(sha256 "$3.part")" != "$2" ]; then
        echo "$1 does not match its sha256 in vm-assets.env" >&2
        rm -f "$3.part"
        exit 1
    fi
    mv "$3.part" "$3"
}
if [ "${1:-}" = --release ] && [ -n "${VM_ASSETS_DIR:-}" ]; then
    echo "--release bundles the pinned GodseonDongle-VM release; unset VM_ASSETS_DIR" >&2
    exit 1
fi
if [ -n "${VM_ASSETS_DIR:-}" ]; then
    ASSETS=$(CDPATH='' cd -- "$VM_ASSETS_DIR" && pwd)
else
    fetch "$VM_ASSETS_URL" "$VM_ASSETS_SHA256" "$DIST/cache/vm_assets-$VM_ASSETS_VERSION.zip"
    rm -rf "$ASSETS"
    ditto -x -k "$DIST/cache/vm_assets-$VM_ASSETS_VERSION.zip" "$DIST"
fi
if [ ! -f "$ASSETS/initramfs-thrurndis-wifi" ] || [ ! -f "$ASSETS/manifest.json" ]; then
    echo "$ASSETS is not a GodseonDongle-VM image" >&2
    exit 1
fi
if [ ! -f "$ASSETS/compliance/SOURCE.md" ]; then
    echo "warning: $ASSETS has no license notices (a ./build.sh --quick image); do not distribute this app" >&2
fi
if [ "${1:-}" = --release ]; then
    # The app zip ships the GPL binaries of the VM image, so its release also carries their
    # source: the same file as the GodseonDongle-VM release (vm_assets/compliance/SOURCE.md).
    fetch "$VM_SOURCES_URL" "$VM_SOURCES_SHA256" "$DIST/vm_assets-sources.tar.gz"
fi

swift build --package-path "$APP_DIR" -c release
BINARY=$(swift build --package-path "$APP_DIR" -c release --show-bin-path)/GodseonDongle

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/helper"
cp "$BINARY" "$BUNDLE/Contents/MacOS/GodseonDongle"
cp "$APP_DIR/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"   # swift app/icon/make_icon.swift
cp -R "$APP_DIR/Resources/en.lproj" "$APP_DIR/Resources/ko.lproj" "$BUNDLE/Contents/Resources/"
cp "$ROOT/LICENSE" "$BUNDLE/Contents/Resources/LICENSE"   # the app's own license (MIT)
# The whole folder: compliance/ holds the license notices of what is in the image.
cp -R "$ASSETS" "$BUNDLE/Contents/Resources/vm_assets"
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
    $COMMIT_KEY
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 GodSeon. MIT License. The bundled Linux VM image comes with its own licenses: Contents/Resources/vm_assets/compliance.</string>
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
