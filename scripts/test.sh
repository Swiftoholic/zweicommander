#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${ZWEI_BUILD_DIR:-$PROJECT_DIR/.build}"
swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_ROOT" --product CommanderCoreTests
BIN=$(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_ROOT" --show-bin-path)
"$BIN/CommanderCoreTests"
