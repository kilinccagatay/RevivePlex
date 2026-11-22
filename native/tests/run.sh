#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm "$work/Info.plist" "$work/bundle" "$work/RevivePlex.o" "$work/host" "$work/incompatible-host" "$work/plex-test" 2>/dev/null || :; rmdir "$work"' EXIT

cat > "$work/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>99.8.7</string><key>CFBundleVersion</key><string>12345</string></dict></plist>
PLIST

xcrun --sdk macosx clang -DREVIVEPLEX_LIVE -fblocks -fno-objc-arc -Wno-cast-function-type-mismatch \
    -c "$here/../src/RevivePlex.m" -o "$work/RevivePlex.o"
xcrun --sdk macosx clang -bundle -DREVIVEPLEX_TEST -fobjc-arc -fblocks \
    "$work/RevivePlex.o" "$here/../src/Localization.m" "$here/../src/LiveLibrary.m" "$here/../src/PlexClient.m" "$here/../src/DirectPlay.m" "$here/../src/PlexLink.m" \
    -framework Foundation -o "$work/bundle"
xcrun --sdk macosx clang -fblocks -fno-objc-arc "$here/Host.m" -framework Foundation -o "$work/host"
python3 "$here/plex_fixture.py" "$work/host" "$work/bundle"
xcrun --sdk macosx clang -fblocks -fno-objc-arc -DWITHOUT_APPLIANCE_PROTOCOL \
    "$here/Host.m" -framework Foundation -o "$work/incompatible-host"
"$work/incompatible-host" "$work/bundle"
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    "$here/PlexClientTest.m" "$here/../src/PlexClient.m" "$here/../src/Localization.m" -framework Foundation -o "$work/plex-test"
python3 "$here/plex_fixture.py" "$work/plex-test"
