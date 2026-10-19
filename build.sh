#!/bin/bash
# Builds the standalone evcharge binary (universal arm64 + x86_64) into this folder.
# Needs only Xcode Command Line Tools (xcode-select --install). No Homebrew, no Python.
set -euo pipefail
cd "$(dirname "$0")"
xcrun clang++ -std=c++17 -ObjC++ -fobjc-arc -O2 -Wall -Wno-unused-function \
    -mmacosx-version-min=12.0 -arch arm64 -arch x86_64 \
    src/evcharge.mm \
    -framework Foundation -framework PDFKit -framework Vision \
    -framework CoreGraphics -framework CoreText -lz \
    -o evcharge
echo "Built: $(pwd)/evcharge"
