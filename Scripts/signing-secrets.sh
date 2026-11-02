#!/usr/bin/env bash
# Puts the "Hackban Release" certificate into this repo's secrets for CI to sign releases with (see "Code signing"
# in the README). Export it first: Keychain Access → My Certificates → right-click Hackban Release → Export… → .p12.
#
#   ./Scripts/signing-secrets.sh ~/HackbanRelease.p12
#
# Asks for the export password without showing it, checks it opens the file before uploading anything, sets
# HACKBAN_SIGNING_P12 and HACKBAN_SIGNING_P12_PASSWORD by piping them to gh (gh's paste prompt can mangle what's
# pasted into it), then deletes the .p12.
set -euo pipefail

p12="${1:?usage: $0 <file.p12>}"
[[ -f "$p12" ]] || { echo "No file at $p12" >&2; exit 1; }

read -r -s -p "Export password for $(basename "$p12"): " P12_PASSWORD
echo
export P12_PASSWORD
if ! openssl pkcs12 -in "$p12" -noout -passin env:P12_PASSWORD 2>/dev/null; then
  echo "That password doesn't open $p12, so nothing was uploaded." >&2
  exit 1
fi

base64 -i "$p12" | gh secret set HACKBAN_SIGNING_P12
printf '%s' "$P12_PASSWORD" | gh secret set HACKBAN_SIGNING_P12_PASSWORD
rm "$p12"
echo "Set HACKBAN_SIGNING_P12 and HACKBAN_SIGNING_P12_PASSWORD, and deleted $p12."
