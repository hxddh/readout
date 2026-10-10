#!/bin/sh
# Signs Readout.app inside-out: embedded frameworks first, then the
# Quick Look extension, then the app itself.
# usage: tools/sign.sh path/to/Readout.app IDENTITY
#   IDENTITY "-" signs ad hoc (no Developer ID); otherwise a "Developer ID Application: …" identity.
#
# Every nested executable must carry the SAME identity as the host app.
# A framework signed with one identity inside an app signed with another
# fails dyld library validation at launch ("code signature identity
# mismatch"), which macOS reports as "works with this version of macOS"
# incompatibility. (v1.0.0 crashed exactly this way via an ad-hoc-signed
# Sparkle framework; Sparkle has since been removed — do not re-add a
# bundled updater without a Developer ID setup.)
set -eu
APP="$1"
ID="$2"

FLAGS="--force --options runtime"
if [ "$ID" != "-" ]; then FLAGS="$FLAGS --timestamp"; fi

sign() { codesign $FLAGS --sign "$ID" "$@"; }

# Embedded frameworks or dylibs first (individually, never --deep).
for fw in "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/Frameworks/*.dylib; do
  [ -e "$fw" ] || continue
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
for nested in "$APP"/Contents/Frameworks/*.framework "$APPEX" "$APP"; do
  [ -e "$nested" ] || continue
  got="$(codesign -dvv "$nested" 2>&1 | grep -E '^Authority=' | head -1 || true)"
  echo "signed: $nested -> ${got:-ad-hoc}"
done
echo "OK: $APP"
