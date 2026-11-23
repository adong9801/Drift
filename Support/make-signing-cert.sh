#!/bin/zsh
# Makes the self-signed "Drift Local Signing" certificate that build.sh signs
# with, in the login keychain. Run once per Mac. It keeps Drift's signature
# the same from one build to the next, so permissions granted to it survive a
# rebuild. It is not trusted by anyone else's Mac and is not a Developer ID.
#
# The first build after this shows a keychain prompt for codesign: enter the
# login password and choose Always Allow.
set -euo pipefail

NAME="Drift Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "already in the keychain: $NAME"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# The system's LibreSSL: its .p12 files are ones the keychain can read.
SSL=/usr/bin/openssl
PASS=$($SSL rand -hex 16)
$SSL req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
$SSL pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$PASS"
# Only codesign may use the key.
security import "$WORK/identity.p12" -k ~/Library/Keychains/login.keychain-db \
  -P "$PASS" -T /usr/bin/codesign
echo "made: $NAME"
