#!/bin/sh
# Signs Readout.app inside-out: embedded frameworks first, then the
# Quick Look extension, then the app itself.
# usage: tools/sign.sh path/to/Readout.app IDENTITY
#   IDENTITY "-" signs ad hoc (no Developer ID); otherwise a "Developer ID Application: …" identity.
#
# Library validation under the hardened runtime requires every loaded
# framework to carry the SAME Team ID as the host app. An ad-hoc signature
# has no Team ID at all, so ANY embedded .framework or .dylib is refused by
# dyld at launch ("code signature identity mismatch"), which macOS reports
# as a "works with this version of macOS" incompatibility. (v1.0.0 crashed
# exactly this way via an ad-hoc-signed Sparkle framework; Sparkle has since
# been removed — do not re-add a bundled updater or any embedded framework
# without a Developer ID setup. A static link or Shipping the helper as a
# separate signed executable are the alternatives.)
set -eu
APP="$1"
ID="$2"

# Refuse configurations that can never launch: ad-hoc + hardened runtime +
# an embedded dynamic framework always dies in dyld library validation.
if [ "$ID" = "-" ]; then
  found=""
  for fw in "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$fw" ] || continue
    found="$found $fw"
  done
  if [ -n "$found" ]; then
    echo "FAIL: ad-hoc signing with embedded dynamic frameworks cannot launch:" >&2
    echo "  $found" >&2
    echo "Ad-hoc signatures have no Team ID, so dyld library validation under" >&2
    echo "the hardened runtime refuses to load them. Use a Developer ID" >&2
    echo "identity, or statically link instead of embedding a framework." >&2
    exit 1
  fi
fi

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
