#!/bin/sh
# Notarizes one submission with an App Store Connect API key, then staples
# the ticket and validates it. Fails unless Apple's answer is "Accepted"
# (and prints Apple's log either way).
# usage: tools/notarize.sh SUBMISSION STAPLE_TARGET
#   SUBMISSION     a .zip of the app, or a signed .dmg
#   STAPLE_TARGET  the .app (for a zip) or the .dmg itself
# env: NOTARY_KEY_PATH (the .p8 file), NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID
set -eu
SUBMISSION="$1"
TARGET="$2"
: "${NOTARY_KEY_PATH:?}" "${NOTARY_API_KEY_ID:?}" "${NOTARY_API_ISSUER_ID:?}"

AUTH="--key $NOTARY_KEY_PATH --key-id $NOTARY_API_KEY_ID --issuer $NOTARY_API_ISSUER_ID"
RESULT="$(mktemp)"
# shellcheck disable=SC2086
xcrun notarytool submit "$SUBMISSION" $AUTH --wait --timeout 30m --output-format json > "$RESULT" || true
cat "$RESULT"
ID=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$RESULT" 2>/dev/null || true)
STATUS=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$RESULT" 2>/dev/null || true)
rm -f "$RESULT"
if [ -n "$ID" ]; then
  # shellcheck disable=SC2086
  xcrun notarytool log "$ID" $AUTH || true
fi
if [ "$STATUS" != "Accepted" ]; then
  echo "FAIL: notarization of $SUBMISSION: ${STATUS:-no answer} (submission ${ID:-none})"
  exit 1
fi
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
echo "OK: $TARGET notarized and stapled"
