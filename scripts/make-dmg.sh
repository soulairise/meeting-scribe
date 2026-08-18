#!/bin/bash
# 배포용 DMG 를 만든다. (드래그해서 응용 프로그램에 넣는 형태)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/MeetingScribe.app/Contents/Info.plist)
DMG="build/MeetingScribe-$VERSION.dmg"
STAGE=$(mktemp -d)

cp -R build/MeetingScribe.app "$STAGE/"
ln -s /Applications "$STAGE/응용 프로그램"
cp docs/설치안내.txt "$STAGE/설치 방법 — 먼저 읽어주세요.txt" 2>/dev/null || true

rm -f "$DMG"
hdiutil create -volname "MeetingScribe" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "완료: $DMG  ($(du -h "$DMG" | cut -f1))"
