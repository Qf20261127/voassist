#!/bin/bash
# 本地 Mac 一键出未签名 ipa（TrollStore 用）。需 Xcode 15+、xcodegen、ldid。
set -e
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || brew install xcodegen
command -v ldid >/dev/null || brew install ldid

xcodegen generate
xcodebuild -project VoAssist.xcodeproj -scheme VoAssist -sdk iphoneos -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" build

APP="build/Build/Products/Release-iphoneos/VoAssist.app"
rm -rf Payload VoAssist.ipa
mkdir -p Payload
cp -R "$APP" Payload/
APPEX=$(ls -d Payload/VoAssist.app/PlugIns/*.appex | head -1)
APP_BIN="Payload/VoAssist.app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' Payload/VoAssist.app/Info.plist)"
EXT_BIN="$APPEX/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APPEX/Info.plist")"
ldid -S App/VoAssist.entitlements "$APP_BIN"
ldid -S Extension/VoAssistVoice.entitlements "$EXT_BIN"
zip -qry VoAssist.ipa Payload
echo "完成：$(pwd)/VoAssist.ipa"
