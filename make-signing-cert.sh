#!/bin/zsh
# One-time setup: creates a self-signed "Record916 Signing" code-signing certificate in your
# login keychain. build.sh then signs with it, so the app's identity stays the same across
# rebuilds and macOS keeps the Screen Recording permission you grant.
set -e
if security find-certificate -c "Record916 Signing" >/dev/null 2>&1; then
  echo "Certificate already exists."; exit 0
fi
TMP=$(mktemp -d)
cat > "$TMP/cs.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Record916 Signing
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
openssl req -x509 -newkey rsa:2048 -sha256 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes -config "$TMP/cs.cnf" 2>/dev/null
# macOS's keychain importer only understands the older PKCS#12 encryption, so export with legacy
# algorithms (-legacy on OpenSSL 3; explicit PBE flags on LibreSSL / older OpenSSL).
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:r916 -name "Record916 Signing" 2>/dev/null \
|| openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:r916 -name "Record916 Signing"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P r916 -T /usr/bin/codesign -T /usr/bin/security
rm -rf "$TMP"
echo "Certificate created. Now run ./build.sh, open the app, and grant Screen Recording once."
