#!/usr/bin/env bash
set -euo pipefail

: "${DOMAIN:?Set DOMAIN=example.com before running}"
DEST_DIR="/var/lib/stalwart/certs"
SECRETS_DIR="/root/stalwart-secrets"
STALWART_RELOAD_URL="http://127.0.0.1:8080/api/reload/certificate"

FULLCHAIN="$DEST_DIR/${DOMAIN}.fullchain.pem"
PRIVKEY="$DEST_DIR/${DOMAIN}.privkey.pem"

hash_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    sha256sum "$f" | awk '{print $1}'
  else
    echo ""
  fi
}

before_fc="$(hash_file "$FULLCHAIN")"
before_pk="$(hash_file "$PRIVKEY")"

/usr/local/bin/sync-ejabberd-cert.sh

after_fc="$(hash_file "$FULLCHAIN")"
after_pk="$(hash_file "$PRIVKEY")"

if [[ "$before_fc" != "$after_fc" || "$before_pk" != "$after_pk" ]]; then
  token_file="$SECRETS_DIR/glue_api_token.txt"
  if [[ ! -f "$token_file" ]]; then
    echo "ERROR: missing API token file: $token_file" >&2
    exit 1
  fi
  token="$(tr -d '\r\n' < "$token_file")"
  curl -fsS -X GET -H "Accept: application/json" -H "Authorization: Bearer $token" "$STALWART_RELOAD_URL" >/dev/null
fi
