#!/bin/sh
# Signs Readout.app inside-out: Sparkle XPC services and helpers first,
# then the framework, the Quick Look extension, and finally the app itself.
# usage: tools/sign.sh path/to/Readout.app IDENTITY
#   IDENTITY "-" signs ad hoc (no Developer ID); otherwise a "Developer ID Application: …" identity.
#
# Every nested executable must carry the SAME identity as the host app.
# A framework signed with one identity inside an app signed with another
# fails dyld library validation at launch ("code signature identity
# mismatch"), which macOS reports as a crash loading the framework.
set -eu
APP="$1"
ID="$2"

FLAGS="--force --options runtime"
if [ "$ID" != "-" ]; then FLAGS="$FLAGS --timestamp"; fi

sign() { codesign $FLAGS --sign "$ID" "$@"; }

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  if [ -L "$SPARKLE/Versions/Current" ]; then
    V="$SPARKLE/Versions/Current"
  elif [ -d "$SPARKLE/Versions/B" ]; then
    V="$SPARKLE/Versions/B"
  else
    V="$SPARKLE/Versions/A"
  fi
  # XPC services first (individually, never --deep: each keeps its own entitlements).
  for xpc in "$V/XPCServices/"*.xpc; do
    [ -e "$xpc" ] || continue
    case "$xpc" in
      *Downloader.xpc) sign --preserve-metadata=entitlements "$xpc" ;;
      *) sign "$xpc" ;;
    esac
  done
  # Helper executables shipped inside the framework.
  [ -f "$V/Autoupdate" ] && sign "$V/Autoupdate"
  [ -f "$V/fileop" ] && sign "$V/fileop"
  [ -d "$V/Updater.app" ] && sign "$V/Updater.app"
  # Then the framework bundle itself.
  sign "$SPARKLE"
fi

# Any other embedded frameworks or dylibs.
for fw in "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/Frameworks/*.dylib; do
  [ -e "$fw" ] || continue
  case "$fw" in *Sparkle.framework) continue ;; esac
  sign "$fw"
done

APPEX="$APP/Contents/PlugIns/ReadoutQuickLook.appex"
if [ -d "$APPEX" ]; then
  sign --entitlements "$(dirname "$0")/../QuickLook/QuickLook.entitlements" "$APPEX"
fi

# Main app last, without --deep so nested signatures are preserved.
sign --entitlements "$(dirname "$0")/../App/Readout.entitlements" "$APP"

# Verify: full seal plus per-component identity match against the host app.
codesign --verify --deep --strict --verbose=2 "$APP"
APP_ID="$(codesign -d --expect-hash 2>/dev/null -r - "$APP" 2>&1 | grep -o 'identifier "[^"]*"' | head -1 || true)"
for nested in "$APP/Contents/Frameworks/Sparkle.framework/Versions/"*/XPCServices/*.xpc \
             "$APP/Contents/Frameworks/Sparkle.framework" \
             "$APPEX" "$APP"; do
  [ -e "$nested" ] || continue
  got="$(codesign -dvv "$nested" 2>&1 | grep -E '^Authority=' | head -1 || true)"
  echo "signed: $nested -> ${got:-ad-hoc}"
done
echo "OK: $APP"
