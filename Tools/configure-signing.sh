#!/bin/bash
# Resolve the local signing identity for XcodeGen without changing any keychain settings.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="Lumen Local Signing"

if [[ "${1:-}" == --find-local ]]; then
  /usr/bin/security find-identity -p codesigning "${@:2}" 2>/dev/null | awk -v name="$NAME" '
    index($0, "\"" name "\"") && $0 !~ /CERT_EXPIRED|CERT_NOT_VALID_YET/ && !seen[$2]++ { print $2 }
  '
  exit
fi

identity="${LUMEN_CODE_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  # security lists some usable self-signed identities under Matching, rather than Valid.
  identities="$("$0" --find-local || true)"
  if [[ "$identities" == *$'\n'* ]]; then
    echo "Multiple Lumen signing identities. Set LUMEN_CODE_SIGN_IDENTITY to the intended fingerprint." >&2
    exit 1
  fi
  identity="${identities:--}"
fi
if [[ "$identity" != - && ! "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo "LUMEN_CODE_SIGN_IDENTITY must be a 40-character certificate fingerprint or -." >&2
  exit 1
fi
mkdir -p "$ROOT/build"
config="$(mktemp "$ROOT/build/.LocalSigning.XXXXXX")"
trap 'rm -f "$config"' EXIT
printf 'LUMEN_CODE_SIGN_IDENTITY = %s\n' "$identity" > "$config"
if ! cmp -s "$config" "$ROOT/build/LocalSigning.xcconfig"; then
  mv -f "$config" "$ROOT/build/LocalSigning.xcconfig"
fi
