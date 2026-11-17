#!/bin/bash
# Builds the app and packs it into SystemRecorder.dmg (app + link to /Applications).
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
STAGE=$(mktemp -d)
cp -R SystemRecorder.app "$STAGE/"
ln -s /Applications "$STAGE/Programme"
# -ov overwrites an older SystemRecorder.dmg in this folder
hdiutil create -ov -volname SystemRecorder -srcfolder "$STAGE" -fs HFS+ -format UDZO SystemRecorder.dmg >/dev/null
codesign --force -s - SystemRecorder.dmg
lipo -archs SystemRecorder.app/Contents/MacOS/SystemRecorder
echo "Fertig: $(pwd)/SystemRecorder.dmg"
