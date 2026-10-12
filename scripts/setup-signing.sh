#!/usr/bin/env bash
# Create a stable, self-signed code-signing identity ("Inkline Dev") in the
# login keychain so Accessibility/TCC grants survive rebuilds.
#
# With ad-hoc signing (codesign -s -) the code hash changes on every build and
# macOS drops the Accessibility permission. A persistent signing identity gives
# the app a stable Designated Requirement, so you grant Accessibility once.
#
# Idempotent: re-running is a no-op if the identity already exists.
set -euo pipefail

IDENTITY="Inkline Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✅ Code-signing identity \"$IDENTITY\" already present. Nothing to do."
    exit 0
fi

echo "==> Creating self-signed code-signing identity \"$IDENTITY\"…"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = Inkline Dev
[ v3 ]
basicConstraints = critical, CA:FALSE
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" 2>/dev/null

# -legacy: OpenSSL 3.x defaults to a PKCS12 MAC (SHA-256) that Apple's
# `security` tool can't verify; legacy mode uses the SHA-1 MAC it understands.
openssl pkcs12 -export -legacy -out "$WORK/id.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout pass:inkline 2>/dev/null

# Import the cert + private key. -A lets /usr/bin/codesign use the key without
# a per-use authorization prompt.
echo "==> Importing into login keychain…"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P inkline -A -T /usr/bin/codesign

# Trust the cert for code signing (this step may ask for your login password).
echo "==> Trusting the certificate for code signing (approve the prompt if asked)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" \
    || echo "   (could not auto-trust; codesign should still find the identity)"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✅ Done. \"$IDENTITY\" is ready."
    echo "   Next: run ./run.sh, then grant Accessibility once — it will persist."
else
    echo "⚠️  Identity created but not showing as valid yet. Try opening Keychain"
    echo "    Access and setting the \"Inkline Dev\" cert's trust to 'Always Trust'"
    echo "    for Code Signing, then re-run ./run.sh."
fi
