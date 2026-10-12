#!/usr/bin/env bash
# Installs the launcher script, Ghostty config, and the "Herdr Devbox.app"
# wrapper from source. Safe to re-run — overwrites in place.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications/Herdr Devbox.app"
CONTENTS="$APP_DIR/Contents"

echo "→ Installing launcher script"
mkdir -p "$HOME/.local/bin"
cp "$SRC_DIR/herdr-devbox-launcher.sh" "$HOME/.local/bin/herdr-devbox-launcher.sh"
chmod +x "$HOME/.local/bin/herdr-devbox-launcher.sh"

echo "→ Installing Ghostty config"
mkdir -p "$HOME/.config/ghostty"
cp "$SRC_DIR/herdr-devbox-launch.conf" "$HOME/.config/ghostty/herdr-devbox-launch.conf"

echo "→ Building icon (.icns from icon/new_icon.png)"
ICONSET="$SRC_DIR/.build/icon.iconset"
ICNS="$SRC_DIR/.build/applet.icns"
rm -rf "$ICONSET"
mkdir -p "$ICONSET" "$SRC_DIR/.build"
for spec in "16 16" "32 16@2x" "32 32" "64 32@2x" "128 128" "256 128@2x" "256 256" "512 256@2x" "512 512" "1024 512@2x"; do
  set -- $spec
  size="$1"; name="$2"
  sips -z "$size" "$size" "$SRC_DIR/icon/new_icon.png" --out "$ICONSET/icon_${name}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICNS"

echo "→ Assembling Herdr Devbox.app"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$SRC_DIR/app/HerdrDevbox" "$CONTENTS/MacOS/HerdrDevbox"
chmod +x "$CONTENTS/MacOS/HerdrDevbox"
cp "$SRC_DIR/app/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp "$ICNS" "$CONTENTS/Resources/applet.icns"

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
touch "$APP_DIR"

echo "Installed:"
echo "  ~/.local/bin/herdr-devbox-launcher.sh"
echo "  ~/.config/ghostty/herdr-devbox-launch.conf"
echo "  $APP_DIR"
