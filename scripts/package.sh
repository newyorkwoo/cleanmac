#!/bin/zsh
# Builds CleanMac.app and wraps it in dist/CleanMac.dmg. Pass --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build_app.sh

stage="$(mktemp -d)"
cp -R dist/CleanMac.app "$stage/"
ln -s /Applications "$stage/Applications"
rm -f dist/CleanMac.dmg
hdiutil create -quiet -volname CleanMac -srcfolder "$stage" -format UDZO dist/CleanMac.dmg
rm -rf "$stage"
hdiutil verify -quiet dist/CleanMac.dmg
echo "安裝映像：$PWD/dist/CleanMac.dmg"

if [[ "${1:-}" == "--install" ]]; then
    if pgrep -x CleanMac >/dev/null; then
        echo "請先結束 CleanMac 再安裝。" >&2
        exit 1
    fi
    rm -rf /Applications/CleanMac.app
    ditto dist/CleanMac.app /Applications/CleanMac.app
    echo "已安裝：/Applications/CleanMac.app"
fi
