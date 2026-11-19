#!/bin/sh
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds dist/vm_assets/{Image-lts,initramfs-thrurndis-wifi} in an Alpine aarch64
# container (Docker Desktop on Apple Silicon runs it natively).
#   ./vm/build.sh [output-dir]
#   ./vm/build.sh --sources-hash     prints the hash of vm/ that the image's manifest keeps

set -eu

VM_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Every file under vm/; app/build_app.sh rebuilds an image whose manifest has another hash.
sources_hash() {
    (cd "$VM_DIR" && find . -type f ! -path '*/__pycache__/*' ! -name '.*' | LC_ALL=C sort |
        xargs shasum -a 256) | shasum -a 256 | cut -c1-16
}
if [ "${1:-}" = --sources-hash ]; then
    sources_hash
    exit 0
fi
OUT=${1:-$VM_DIR/../dist/vm_assets}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:edge}
VERSION=${THRURNDIS_WIFI_VERSION:-$(date +%Y%m%d.%H%M)}

mkdir -p "$OUT"
OUT=$(CDPATH='' cd -- "$OUT" && pwd)

# Firmware packages named in drivers.conf (pkg=a,b) go into the builder image.
FIRMWARE_PACKAGES=$(grep -v '^[[:space:]]*#' "$VM_DIR/drivers.conf" |
    sed -n 's/.*[[:space:]]pkg=\([^[:space:]]*\).*/\1/p' | tr ',' '\n' | sort -u | tr '\n' ' ')
case "$FIRMWARE_PACKAGES" in
    *[!a-z0-9_.\ -]*) echo "drivers.conf: invalid firmware package name in: $FIRMWARE_PACKAGES" >&2; exit 1 ;;
esac

# THRURNDIS_WIFI_BUILDER_PULL=1 refreshes the cached kernel/firmware packages.
docker build --platform linux/arm64 --build-arg ALPINE_IMAGE="$ALPINE_IMAGE" \
    --build-arg FIRMWARE_PACKAGES="$FIRMWARE_PACKAGES" \
    ${THRURNDIS_WIFI_BUILDER_PULL:+--pull --no-cache} -t thrurndis-wifi-builder "$VM_DIR/builder"

# Downloaded kernel sources (rtw88, see vm/kernel) are kept here between builds.
CACHE=${GODSEON_BUILD_CACHE:-$VM_DIR/../dist/cache}
mkdir -p "$CACHE"
CACHE=$(CDPATH='' cd -- "$CACHE" && pwd)

docker run --rm --platform linux/arm64 \
    -v "$VM_DIR:/src:ro" -v "$OUT:/out" -v "$CACHE:/cache" thrurndis-wifi-builder \
    python3 /src/builder/build_assets.py --src /src --out /out --cache /cache --version "$VERSION" \
    --sources "$(sources_hash)" \
    ${GODSEON_RTW88_PATCHES:+$( [ "$GODSEON_RTW88_PATCHES" = 0 ] && echo --no-kernel-patches)}

echo "VM assets: $OUT"
