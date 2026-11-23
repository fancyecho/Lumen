#!/bin/bash
# Run interactively as the owner of the login keychain.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="Lumen Local Signing"
keychain="$(/usr/bin/security login-keychain -d user | sed -E 's/^[[:space:]]*"(.+)"$/\1/')"

if [[ ! -f "$keychain" ]]; then
  echo "The login keychain could not be located." >&2
  exit 1
fi
if [[ -n "$("$ROOT/Tools/configure-signing.sh" --find-local "$keychain")" ]]; then
  echo "$NAME already exists in the login keychain."
  exit 0
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/lumen-signing.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/certificate.cnf" <<'CONF'
[req]
distinguished_name = name
prompt = no
x509_extensions = signing
[name]
CN = Lumen Local Signing
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
CONF
/usr/bin/openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
  -config "$scratch/certificate.cnf" -keyout "$scratch/key.pem" -out "$scratch/certificate.pem"
/usr/bin/openssl rand -hex 24 > "$scratch/passphrase"
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$scratch/key.pem" -in "$scratch/certificate.pem" \
  -out "$scratch/identity.p12" -passout "file:$scratch/passphrase"
/usr/bin/security import "$scratch/identity.p12" -k "$keychain" -f pkcs12 \
  -P "$(cat "$scratch/passphrase")" -T /usr/bin/codesign
echo "Created $NAME. Run xcodegen generate before the next Xcode build."
