#!/bin/zsh
# Runs the unit tests (plain assertions, no XCTest).
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
swiftc -swift-version 5 -o build/Tests \
  Tests/main.swift Sources/WindowMatching.swift Sources/AXActionResult.swift Sources/LayoutRefresh.swift Sources/UpdateCheck.swift -framework Cocoa
exec ./build/Tests
