#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

appiconset="App/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size Design/app-icon.svg -o "$appiconset/app-icon-${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) Design/app-icon.svg -o "$appiconset/app-icon-${size}@2x.png"
done

iconset="$(mktemp -d)/MarkdownDocument.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size Design/document-icon.svg -o "$iconset/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) Design/document-icon.svg -o "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o App/Resources/MarkdownDocument.icns
rm -rf "$(dirname "$iconset")"
