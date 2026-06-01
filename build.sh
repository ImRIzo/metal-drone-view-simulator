#!/bin/bash
set -e

cd "$(dirname "$0")"

OUTPUT="./droneview-simulator"
SOURCES="Sources/main.swift"

FRAMEWORKS=(
    -framework Metal
    -framework MetalKit
    -framework AppKit
    -framework QuartzCore
    -framework Foundation
)

echo "🔨 Building droneview-simulator..."
echo "   Source: $SOURCES"
echo "   Output: $OUTPUT"

swiftc \
    -o "$OUTPUT" \
    "$SOURCES" \
    "${FRAMEWORKS[@]}" \
    -O \
    -swift-version 5

echo "✅ Build complete: $OUTPUT"
echo ""
echo "Run with: ./droneview-simulator"
