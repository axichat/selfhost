#!/usr/bin/env bash
set -euo pipefail

: "${DOMAIN:?Set DOMAIN=example.com before running}"
DEST_DIR="/var/lib/stalwart/certs"

mkdir -p "$DEST_DIR"

EJABBERDCTL=""
if command -v ejabberdctl >/dev/null 2>&1; then
  EJABBERDCTL="$(command -v ejabberdctl)"
elif [[ -x /opt/ejabberd/bin/ejabberdctl ]]; then
  EJABBERDCTL="/opt/ejabberd/bin/ejabberdctl"
else
  for candidate in /opt/ejabberd-*/bin/ejabberdctl; do
    if [[ -x "$candidate" ]]; then
      EJABBERDCTL="$candidate"
      break
    fi
  done
fi

if [[ -z "$EJABBERDCTL" ]]; then
  echo "ERROR: ejabberdctl not found in PATH or /opt/ejabberd-*/bin/ejabberdctl" >&2
  exit 1
fi

CERT_PATH="$("$EJABBERDCTL" list-certificates | awk -v d="$DOMAIN" '$1==d {print $2; exit}')"
if [[ -z "${CERT_PATH}" ]]; then
  echo "ERROR: no certificate for ${DOMAIN}" >&2
  exit 1
fi

SRC_PEM="$CERT_PATH"
if [[ ! -f "$SRC_PEM" ]]; then
  echo "ERROR: cert file missing: $SRC_PEM" >&2
  exit 1
fi

FULLCHAIN_OUT="$DEST_DIR/${DOMAIN}.fullchain.pem"
PRIVKEY_OUT="$DEST_DIR/${DOMAIN}.privkey.pem"

sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$SRC_PEM" > "$FULLCHAIN_OUT"

if grep -q "BEGIN RSA PRIVATE KEY" "$SRC_PEM"; then
  sed -n '/BEGIN RSA PRIVATE KEY/,/END RSA PRIVATE KEY/p' "$SRC_PEM" > "$PRIVKEY_OUT"
elif grep -q "BEGIN EC PRIVATE KEY" "$SRC_PEM"; then
  sed -n '/BEGIN EC PRIVATE KEY/,/END EC PRIVATE KEY/p' "$SRC_PEM" > "$PRIVKEY_OUT"
elif grep -q "BEGIN PRIVATE KEY" "$SRC_PEM"; then
  sed -n '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/p' "$SRC_PEM" > "$PRIVKEY_OUT"
else
  echo "ERROR: no private key in $SRC_PEM" >&2
  exit 1
fi

chown root:root "$FULLCHAIN_OUT"
chmod 0644 "$FULLCHAIN_OUT"

if getent group emailglue >/dev/null 2>&1; then
  chown root:emailglue "$PRIVKEY_OUT"
  chmod 0640 "$PRIVKEY_OUT"
else
  chown root:root "$PRIVKEY_OUT"
  chmod 0600 "$PRIVKEY_OUT"
fi

echo "OK"
