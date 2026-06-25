#!/usr/bin/env bash
# Create a stable, self-signed code-signing identity named "AP Kiwi Local Signing"
# in the login keychain. Shared across all ap.kiwi apps (RuneCtrl, Squeak, ...).
# Run ONCE per machine; every project's build script picks it up automatically.
#
# Why: ad-hoc signing (codesign --sign -) changes the code hash on every build, so
# macOS invalidates Accessibility / TCC grants each rebuild. A stable signing
# certificate makes the system key on the certificate instead, so grants persist
# across rebuilds — grant once, never again.
#
# After running this, the first build that switches an app from ad-hoc to this
# identity changes that app's designated requirement, so you reset + re-grant any
# TCC permission ONE more time for that app; every rebuild after that keeps it.
#
# You will be asked for your login password once (to trust the cert for signing).
set -euo pipefail

SIGN_ID="AP Kiwi Local Signing"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "✅  '$SIGN_ID' already exists. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cs.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = AP Kiwi Local Signing
O = ap.kiwi
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

echo "▶ generating self-signed code-signing cert..."
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/cs.key" -out "$WORK/cs.crt" -config "$WORK/cs.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -out "$WORK/cs.p12" \
  -inkey "$WORK/cs.key" -in "$WORK/cs.crt" -passout pass:apkiwi -name "$SIGN_ID"

echo "▶ importing into login keychain (codesign access)..."
security import "$WORK/cs.p12" -k "$LOGIN_KC" -P apkiwi -A -T /usr/bin/codesign

echo "▶ trusting the cert for code signing (approve the password prompt)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KC" "$WORK/cs.crt"

echo "=== code-signing identities now available ==="
security find-identity -p codesigning -v
echo "✅  Done. Builds will sign with '$SIGN_ID'."
