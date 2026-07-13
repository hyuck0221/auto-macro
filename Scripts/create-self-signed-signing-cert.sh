#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/.signing}"
P12_PATH="$OUTPUT_DIR/auto-macro-release-signing.p12"
CERT_PATH="$OUTPUT_DIR/auto-macro-release-signing.pem"
KEY_PATH="$OUTPUT_DIR/auto-macro-release-signing-key.pem"
PASSWORD_PATH="$OUTPUT_DIR/p12-password.txt"
BASE64_PATH="$OUTPUT_DIR/p12-base64.txt"

if [[ -e "$P12_PATH" || -e "$KEY_PATH" || -e "$PASSWORD_PATH" ]]; then
    echo "Signing material already exists in $OUTPUT_DIR; refusing to overwrite it." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"
PASSWORD="$(openssl rand -hex 32)"

openssl req -new -newkey rsa:3072 -x509 -sha256 -days 7300 -nodes \
    -subj '/CN=Auto Macro GitHub Release Signing/O=Auto Macro' \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=codeSigning' \
    -keyout "$KEY_PATH" \
    -out "$CERT_PATH" >/dev/null 2>&1

openssl pkcs12 -export -legacy \
    -inkey "$KEY_PATH" \
    -in "$CERT_PATH" \
    -passout "pass:$PASSWORD" \
    -out "$P12_PATH"

printf '%s' "$PASSWORD" > "$PASSWORD_PATH"
base64 < "$P12_PATH" > "$BASE64_PATH"
chmod 600 "$P12_PATH" "$CERT_PATH" "$KEY_PATH" "$PASSWORD_PATH" "$BASE64_PATH"

cat <<EOF
Created stable Auto Macro release signing material in:
  $OUTPUT_DIR

Keep this directory private and backed up. Never commit its contents.
After authenticating GitHub CLI, upload the two required repository secrets:

  gh secret set AUTO_MACRO_SIGNING_P12_BASE64 < "$BASE64_PATH"
  gh secret set AUTO_MACRO_SIGNING_P12_PASSWORD < "$PASSWORD_PATH"
EOF
