#!/bin/zsh
# Build products land in /tmp (outside the iCloud-synced repo); install to /Applications
# and re-register the Quick Look extension.
set -euo pipefail

APP="/tmp/peekaboo-dd/Build/Products/Release/Peekaboo.app"
DEST="/Applications/Peekaboo.app"

[[ -d "$APP" ]] || { echo "Build first: ./Scripts/build.sh" >&2; exit 1; }

rm -rf "$DEST"
ditto "$APP" "$DEST"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/PeekabooQuickLook.appex" 2>/dev/null || true
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

echo "Installed $DEST"
echo "Extension status:"
pluginkit -m -i com.kylebeggs.Peekaboo.QuickLook || echo "  (not yet registered — launch the app once)"
