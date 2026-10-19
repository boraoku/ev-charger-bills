#!/bin/bash
# Builds macOS release archives into dist/: universal, arm64 (Apple silicon) and x86_64 (Intel).
# Each zip holds the evcharge binary, a default evcharge.conf and the README.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(sed -n 's/.*EVCHARGE_VERSION *= *"\([^"]*\)".*/\1/p' src/evcharge.mm)
rm -rf dist && mkdir -p dist

build() {   # $1 = label, remaining = -arch flags
    local label=$1; shift
    local dir="dist/evcharge-$VERSION-macos-$label"
    mkdir -p "$dir"
    xcrun clang++ -std=c++17 -ObjC++ -fobjc-arc -O2 -Wall -Wno-unused-function \
        -mmacosx-version-min=12.0 "$@" src/evcharge.mm \
        -framework Foundation -framework PDFKit -framework Vision \
        -framework CoreGraphics -framework CoreText -lz -o "$dir/evcharge"
    codesign --force --sign - "$dir/evcharge"          # ad-hoc signature
    cp evcharge.conf README.md LICENSE "$dir/"
    (cd dist && zip -qr "evcharge-$VERSION-macos-$label.zip" "evcharge-$VERSION-macos-$label")
    echo "Built dist/evcharge-$VERSION-macos-$label.zip"
}

build universal -arch arm64 -arch x86_64
build arm64 -arch arm64
build x86_64 -arch x86_64
(cd dist && shasum -a 256 *.zip > SHA256SUMS.txt)
