#!/bin/zsh
# Builds a release CleanMac.app in ./dist.
# Signs with your Apple Development certificate when there is one, so macOS keeps
# Full Disk Access across rebuilds. Otherwise it falls back to an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product CleanMac
binary="$(swift build -c release --product CleanMac --show-bin-path)/CleanMac"

app="dist/CleanMac.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/CleanMac"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/*.lproj "$app/Contents/Resources/"

iconset="$(mktemp -d)/AppIcon.iconset"
swift scripts/make_icon.swift "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"

identity="$(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development:[^"]+)".*/\1/p' | head -1)"
codesign --force --sign "${identity:--}" "$app"
codesign --verify --strict "$app"
echo "簽署：${identity:-ad-hoc}"
echo "完成：$PWD/$app"
