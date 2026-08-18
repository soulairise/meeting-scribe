#!/bin/bash
# 설치 가능한 MeetingScribe.app 을 만든다.
#
# GUI 앱 안에 CLI 도구(AudioCapture, Transcribe)와 템플릿을 함께 넣는다.
# GUI가 자식 프로세스를 띄우면 TCC 권한 주체가 앱이 되므로,
# 마이크·시스템 오디오 권한을 앱 이름으로 한 번만 승인하면 된다.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/MeetingScribe.app"
PB=/usr/libexec/PlistBuddy

echo "▶ 빌드"
swift build -c "$CONFIG" >/dev/null
BIN=$(swift build -c "$CONFIG" --show-bin-path)

echo "▶ 번들 구성"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/templates"

cp "$BIN/MeetingScribeApp" "$APP/Contents/MacOS/MeetingScribe"
cp "$BIN/AudioCapture" "$BIN/Transcribe" "$APP/Contents/Resources/bin/"
cp templates/*.md templates/*.txt "$APP/Contents/Resources/templates/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MeetingScribe</string>
  <key>CFBundleDisplayName</key><string>MeetingScribe</string>
  <key>CFBundleIdentifier</key><string>kr.soulmat.meetingscribe</string>
  <key>CFBundleExecutable</key><string>MeetingScribe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.3</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>회의 음성을 녹음하고 전사하기 위해 마이크를 사용합니다.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>온라인 회의 상대방의 음성을 기록하기 위해 시스템 오디오를 녹음합니다.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>녹음된 회의 음성을 텍스트로 변환하기 위해 음성 인식을 사용합니다.</string>
</dict>
</plist>
PLIST

echo "▶ 서명"
# 자식 CLI 부터 서명하고 마지막에 번들 전체를 서명한다.
codesign --force --sign - "$APP/Contents/Resources/bin/AudioCapture"
codesign --force --sign - "$APP/Contents/Resources/bin/Transcribe"
codesign --force --sign - "$APP"

echo "완료: $APP"
