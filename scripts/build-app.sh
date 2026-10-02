#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

swift build -c release

app="build/Tampa.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Tampa "$app/Contents/MacOS/Tampa"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"

if [ "${1:-}" = "install" ]; then
    pkill -x Tampa || true
    rm -rf "$HOME/Applications/Tampa.app"
    mkdir -p "$HOME/Applications"
    cp -R "$app" "$HOME/Applications/Tampa.app"
    open "$HOME/Applications/Tampa.app"
    echo "Instalado em ~/Applications/Tampa.app"
else
    echo "Gerado em $app"
fi
