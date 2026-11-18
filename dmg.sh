#!/bin/bash
# Builds the app and packs it into Tapedeck.dmg: the shared DMG look of Moe's apps (moe-apps skill, "DMG window") –
# 660 × 400 window, app left, link to /Applications ("Programme") right, background from scripts/make-dmg-background.swift.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VOL=Tapedeck
STAGE=$(mktemp -d)
RW="$(mktemp -d)/rw.dmg"
cp -R Tapedeck.app "$STAGE/"
ln -s /Applications "$STAGE/Programme"
mkdir "$STAGE/.background"
swift scripts/make-dmg-background.swift AppIcon.png "$STAGE/bg.png" 1
swift scripts/make-dmg-background.swift AppIcon.png "$STAGE/bg@2x.png" 2
tiffutil -cathidpicheck "$STAGE/bg.png" "$STAGE/bg@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null
mv "$STAGE/bg.png" "$STAGE/bg@2x.png" "$(dirname "$RW")/"
# never eject someone else's volume, and Finder's disk "Tapedeck" below must be ours
if ls /Volumes | grep -Eq "^$VOL( [0-9]+)?\$"; then echo "Ein Volume \"$VOL\" ist eingebunden – erst auswerfen" >&2; exit 1; fi
hdiutil create -quiet -volname $VOL -srcfolder "$STAGE" -fs HFS+ -format UDRW "$RW"
hdiutil attach -quiet -noautoopen -mountpoint "/Volumes/$VOL" "$RW"
# window layout is stored by Finder in .DS_Store (needs Finder automation for the terminal once)
osascript <<'OSA' || echo "Warnung: Fensterlayout nicht gesetzt (Finder-Automation verweigert?)" >&2
tell application "Finder"
  repeat 20 times -- Finder sees a fresh image only after a moment
    if exists disk "Tapedeck" then exit repeat
    delay 0.5
  end repeat
  tell disk "Tapedeck"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set background picture of opts to file ".background:background.tiff"
    set position of item "Tapedeck.app" of container window to {170, 188}
    set position of item "Programme" of container window to {490, 188}
    set bounds of container window to {200, 120, 860, 548}   -- 400 pt content + 28 pt title bar
    update without registering applications
    delay 2
    close
    -- Finder writes the window size to .DS_Store only reliably after a second open/close
    open
    delay 1
    close
  end tell
end tell
OSA
sync
# Finder or Spotlight may still hold the volume for a moment
hdiutil detach "/Volumes/$VOL" -quiet || { sleep 2; hdiutil detach "/Volumes/$VOL" -quiet -force; }
# -ov overwrites an older Tapedeck.dmg in this folder
hdiutil convert -quiet -ov "$RW" -format UDZO -imagekey zlib-level=9 -o Tapedeck.dmg
codesign --force -s - Tapedeck.dmg
lipo -archs Tapedeck.app/Contents/MacOS/Tapedeck
# update zip for the in-app updater, signed with the key in this Mac's Keychain (scripts/update-key.swift);
# the app only installs zips whose .sig matches the public key in updater.swift
VERSION=$(defaults read "$PWD/Tapedeck.app/Contents/Info" TapedeckRelease)
ZIP="Tapedeck-$VERSION.zip"
ditto -c -k --keepParent Tapedeck.app "$ZIP"
if PUB=$(swift scripts/update-key.swift public 2>/dev/null) && grep -q "\"$PUB\"" updater.swift \
   && swift scripts/update-key.swift sign "$ZIP"; then
  echo "Fertig: $(pwd)/Tapedeck.dmg, $ZIP (+ .sig) – für ein Release alle drei hochladen (DMG als Tapedeck-$VERSION.dmg)"
else
  echo "Fertig: $(pwd)/Tapedeck.dmg – $ZIP NICHT SIGNIERT, die App installiert es nicht als Update" >&2
fi
