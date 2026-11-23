#!/bin/zsh
# Optional, run once. Creates a self-signed code signing certificate in a separate keychain inside .signing/
# (your login keychain is not touched). With a signature that stays the same across builds, the Accessibility
# permission survives rebuilds.
set -euo pipefail
umask 077   # the private key and the password file are readable only by you
cd "$(dirname "$0")"
mkdir -p .signing && cd .signing
NAME="Liquid Toast Local Dev"
KC="$PWD/liquidtoast-dev.keychain-db"
if [[ -f "$KC" ]]; then
  if [[ -f password ]] && security find-identity -p codesigning "$KC" | grep -q "$NAME"; then
    echo "Already set up: $KC"; exit 0
  fi
  # A half-made keychain from an earlier run: remove it and start over
  security delete-keychain "$KC" 2>/dev/null || rm -f "$KC"
fi
trap 'rm -f key.pem id.p12' EXIT   # never leave the private key file behind, even on failure
# A random password just for this keychain, kept in .signing/password (build.sh reads it)
PW=$(openssl rand -hex 16)
print -r -- "$PW" > password
cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
# The macOS keychain can't read OpenSSL 3's default PKCS12 format, hence -legacy
# (the LibreSSL that ships with macOS has no such option and already uses the old format)
LEGACY=()
openssl pkcs12 -help 2>&1 | grep -q -- -legacy && LEGACY=(-legacy)
openssl pkcs12 -export $LEGACY -inkey key.pem -in cert.pem -out id.p12 -passout "pass:$PW" -name "$NAME"
security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
security import id.p12 -k "$KC" -P "$PW" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
security find-identity -p codesigning "$KC"
