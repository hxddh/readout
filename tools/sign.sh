#!/bin/sh
# Signs Readout.app inside-out (Sparkle helpers, Quick Look extension, app).
# usage: tools/sign.sh path/to/Readout.app IDENTITY
#   IDENTITY "-" signs ad hoc (no Developer ID); otherwise a "Developer ID Application: …" identity.
set -eu
APP="$1"
ID="$2"

FLAGS="--force --options runtime"
if [ "$ID" != "-" ]; then FLAGS="$FLAGS --timestamp"; fi

sign() { codesign $FLAGS --sign "$ID" "$@"; }

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  V="$SPARKLE/Versions/B"
  [ -d "$V" ] || V="$SPARKLE/Versions/Current"
  [ -d "$V/XPCServices/Installer.xpc" ] && sign "$V/XPCServices/Installer.xpc"
  [ -d "$V/XPCServices/Downloader.xpc" ] && sign --preserve-metadata=entitlements "$V/XPCServices/Downloader.xpc"
  [ -f "$V/Autoupdate" ] && sign "$V/Autoupdate"
  [ -d "$V/Updater.app" ] && sign "$V/Updater.app"
  sign "$SPARKLE"
fi

for fw in "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/Frameworks/*.dylib; do
  [ -e "$fw" ] || continue
  case "$fw" in *Sparkle.framework) continue ;; esac
  sign "$fw"
done

APPEX="$APP/Contents/PlugIns/ReadoutQuickLook.appex"
if [ -d "$APPEX" ]; then
  sign --entitlements "$(dirname "$0")/../QuickLook/QuickLook.entitlements" "$APPEX"
fi

sign --entitlements "$(dirname "$0")/../App/Readout.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
