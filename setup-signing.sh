#!/bin/zsh
# Create a stable local code-signing identity, once, so that rebuilding this
# helper does NOT make macOS forget the permission you granted it.
#
# Why this exists, measured on this Mac:
#   * `security find-identity -v -p codesigning` reports no Apple identities.
#   * An ad-hoc signature's designated requirement pins the exact code hash,
#     which changes on every build, so every rebuild looked like a brand-new
#     app and the Accessibility grant was dropped.
#   * A self-signed certificate's designated requirement pins the CERTIFICATE
#     instead, which does not change. The grant then survives rebuilds.
#
# It needs no password, no admin rights, and does not have to be "trusted" in
# the system sense — codesign only needs the private key. Running it twice is
# harmless: it does nothing if the identity is already there.
set -e
NAME="K PTT Local Signing"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "signing identity already present: $NAME"
  exit 0
fi

echo "creating a local signing identity: $NAME"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/ext.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = K PTT Local Signing
O = constant K
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 7300 -nodes -config "$WORK/ext.cnf" >/dev/null 2>&1

# Legacy PKCS#12 algorithms: macOS's importer rejects OpenSSL 3's defaults.
openssl pkcs12 -export -out "$WORK/id.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout pass:kptt -name "$NAME" \
  -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -legacy >/dev/null 2>&1

# -A so codesign can use the key without asking for keychain permission.
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P kptt -A -T /usr/bin/codesign

security find-identity -p codesigning | grep "$NAME" || {
  echo "the identity did not import; the build will fall back to ad-hoc signing"
  exit 1
}
echo "done — rebuilds will now keep their permissions"
