#!/bin/bash
# pochi build script — needs only the Xcode Command Line Tools (swiftc).
#   xcode-select --install
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Pochi.app"

echo "==> compiling"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/pochi" Sources/main.swift

echo "==> writing Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                <string>pochi</string>
  <key>CFBundleIdentifier</key>          <string>local.pochi</string>
  <key>CFBundleExecutable</key>          <string>pochi</string>
  <key>CFBundlePackageType</key>         <string>APPL</string>
  <key>CFBundleShortVersionString</key>  <string>0.1.0</string>
  <key>LSUIElement</key>                 <true/>
  <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

echo "==> done: $APP"
echo
echo "インストール（お好みで）:"
echo "  mkdir -p ~/bin"
echo "  ln -sf \"$PWD/$APP/Contents/MacOS/pochi\" ~/bin/pochi"
echo "  cp -n bin/* ~/bin/"
echo "  mkdir -p ~/.config/pochi && cp -n config.example.conf ~/.config/pochi/config.conf"
