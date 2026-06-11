#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project Peekaboo.xcodeproj -scheme Peekaboo -configuration Release \
  -derivedDataPath /tmp/peekaboo-dd build
