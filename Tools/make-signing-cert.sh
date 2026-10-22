#!/bin/bash
# Creates "Swivel Local Signing", a self-signed code-signing certificate in your login keychain.
# Signing every build with the same certificate lets macOS keep Swivel's Accessibility and Screen
# Recording permissions across updates; an ad-hoc signature changes with every build.
set -euo pipefail
NAME="Swivel Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "\"$NAME\" already exists."
  exit 0
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cfg" <<CFG
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cfg" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# A throwaway password, only to carry the key into the keychain.
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASS"
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\"."
