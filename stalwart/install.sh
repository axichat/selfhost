#!/usr/bin/env bash
set -euo pipefail

: "${DOMAIN:?Set DOMAIN=example.com before running}"
STALWART_IMAGE="stalwartlabs/stalwart:v0.15.4"
STALWART_DIR="/var/lib/stalwart"
CERT_DIR="/var/lib/stalwart/certs"
EMAIL_GLUE_STATE="/var/lib/email-glue"
SECRETS_DIR="/root/stalwart-secrets"
STALWART_API="http://127.0.0.1:8080/api"
HTTP_READY="http://127.0.0.1:8080/healthz/ready"
REQUIRE_PUBLIC_TOKEN="1"
PUBLIC_TOKEN_OVERRIDE=""
PUBLIC_TOKEN_OVERRIDE_SET="0"
GLUE_API_TOKEN_OVERRIDE=""
GLUE_API_TOKEN_OVERRIDE_SET="0"
CHECKPOINT_MODE="0"
: "${SKIP_FIREWALL:=0}"
: "${SKIP_DNS_GUIDANCE:=0}"

CHECKPOINT_WEBADMIN_DOMAIN_RC=40
CHECKPOINT_GLUE_API_TOKEN_RC=41

usage() {
  cat <<'EOF'
Usage: install.sh [--public-token[=TOKEN]] [--no-public-token] [--glue-api-token=TOKEN] [--checkpoint-mode]

Options:
  --public-token[=TOKEN]  Require X-Client-Token / X-Auth-Token for email-glue.
                          This is the default if omitted.
                          - no TOKEN: reuse client_token.txt or auto-generate one.
                          - TOKEN set: use it and persist to client_token.txt.
  --no-public-token       Disable the public client token requirement.
                          Not recommended on an internet-reachable host.
  --glue-api-token=TOKEN  Use this Stalwart API key for email-glue and persist it.
                          If omitted, reuse glue_api_token.txt when valid, else prompt.
  --checkpoint-mode       Print manual instructions and exit instead of waiting for input.
  -h, --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-token)
      REQUIRE_PUBLIC_TOKEN="1"
      shift
      ;;
    --public-token=*)
      REQUIRE_PUBLIC_TOKEN="1"
      PUBLIC_TOKEN_OVERRIDE="${1#*=}"
      if [[ -n "$PUBLIC_TOKEN_OVERRIDE" ]]; then
        PUBLIC_TOKEN_OVERRIDE_SET="1"
      fi
      shift
      ;;
    --no-public-token)
      REQUIRE_PUBLIC_TOKEN="0"
      PUBLIC_TOKEN_OVERRIDE=""
      PUBLIC_TOKEN_OVERRIDE_SET="0"
      shift
      ;;
    --glue-api-token=*)
      GLUE_API_TOKEN_OVERRIDE="${1#*=}"
      if [[ -n "$GLUE_API_TOKEN_OVERRIDE" ]]; then
        GLUE_API_TOKEN_OVERRIDE_SET="1"
      fi
      shift
      ;;
    --checkpoint-mode)
      CHECKPOINT_MODE="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$PUBLIC_TOKEN_OVERRIDE_SET" == "1" && "$PUBLIC_TOKEN_OVERRIDE" == *$'\n'* ]]; then
  echo "ERROR: --public-token value must be single-line" >&2
  exit 1
fi
if [[ "$GLUE_API_TOKEN_OVERRIDE_SET" == "1" && "$GLUE_API_TOKEN_OVERRIDE" == *$'\n'* ]]; then
  echo "ERROR: --glue-api-token value must be single-line" >&2
  exit 1
fi

# ---- Manual Webadmin interaction settings (override via env) ----
: "${STALWART_SSH_HOST:=$DOMAIN}" # hostname or IP you ssh into (for tunnel instructions)
: "${STALWART_SSH_USER:=root}"    # ssh user for tunnel instructions
: "${TUNNEL_LOCAL_PORT:=18080}"   # local port on your laptop
: "${WEBADMIN_REMOTE_PORT:=8080}" # Stalwart Webadmin/API port on the server (localhost)

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "• %s\n" "$*"; }
warn() { printf "\033[33m%s\033[0m\n" "$*"; }

detect_ssh_port() {
  local ssh_port=""
  if command -v sshd >/dev/null 2>&1; then
    ssh_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
  fi
  printf '%s\n' "${ssh_port:-22}"
}


if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root" >&2
  exit 1
fi

# Avoid stale /usr/local Erlang wrappers shadowing system binaries during apt/dpkg hooks.
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
if [[ -x /usr/local/bin/erl ]]; then
  stale_erl_target="$(grep -Eo '/usr/local/erts-[^[:space:]]+/bin/erl' /usr/local/bin/erl | head -n1 || true)"
  if [[ -n "$stale_erl_target" && ! -x "$stale_erl_target" ]]; then
    disabled_erl="/usr/local/bin/erl.disabled.$(date +%s)"
    mv /usr/local/bin/erl "$disabled_erl"
    echo "Disabled stale /usr/local/bin/erl wrapper -> ${disabled_erl}"
  fi
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io curl jq openssl ca-certificates ufw

systemctl enable --now docker

if [[ "$SKIP_FIREWALL" == "1" ]]; then
  info "Skipping UFW rule changes because the root wrapper already manages them"
else
  if [[ -f /etc/default/ufw ]]; then
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw || true
  fi
  ufw_active="yes"
  if ufw status 2>/dev/null | head -n1 | grep -qi "inactive"; then
    ufw_active="no"
  fi
  if [[ "$ufw_active" == "no" ]]; then
    ufw default deny incoming || true
    ufw default allow outgoing || true
  fi
  ufw allow "$(detect_ssh_port)/tcp" || true
  ufw allow 25/tcp || true
  ufw allow 465/tcp || true
  ufw allow 587/tcp || true
  ufw allow 993/tcp || true
  ufw allow 8443/tcp || true
  if [[ "$ufw_active" == "no" ]]; then
    ufw --force enable || true
  fi
  ufw reload || true
fi


if ! id -u emailglue >/dev/null 2>&1; then
  useradd --system --home-dir "$EMAIL_GLUE_STATE" --create-home --shell /usr/sbin/nologin emailglue
fi

mkdir -p "$STALWART_DIR/etc" "$STALWART_DIR/data" "$CERT_DIR" "$EMAIL_GLUE_STATE" "$SECRETS_DIR" /etc/sysconfig

install -m 0755 "$(dirname "$0")/scripts/sync-ejabberd-cert.sh" /usr/local/bin/sync-ejabberd-cert.sh
install -m 0755 "$(dirname "$0")/scripts/update-stalwart-cert.sh" /usr/local/bin/update-stalwart-cert.sh

install -m 0644 "$(dirname "$0")/systemd/stalwart.service" /etc/systemd/system/stalwart.service
install -m 0644 "$(dirname "$0")/systemd/email-glue.service" /etc/systemd/system/email-glue.service
install -m 0644 "$(dirname "$0")/systemd/update-stalwart-cert.service" /etc/systemd/system/update-stalwart-cert.service
install -m 0644 "$(dirname "$0")/systemd/update-stalwart-cert.timer" /etc/systemd/system/update-stalwart-cert.timer

fallback_pw_file="$SECRETS_DIR/fallback_admin_password.txt"
if [[ -f "$fallback_pw_file" ]]; then
  FALLBACK_PASSWORD="$(tr -d '\r\n' < "$fallback_pw_file")"
else
  FALLBACK_PASSWORD="$(openssl rand -hex 16)"
  printf "%s\n" "$FALLBACK_PASSWORD" > "$fallback_pw_file"
  chmod 0600 "$fallback_pw_file"
fi
FALLBACK_HASH="$(printf "%s" "$FALLBACK_PASSWORD" | openssl passwd -6 -stdin)"

config_template="$(dirname "$0")/config.toml"
if [[ ! -f "$config_template" ]]; then
  echo "ERROR: missing config template: $config_template" >&2
  exit 1
fi
escaped_fallback_hash="$(printf '%s' "$FALLBACK_HASH" | sed 's/[&|]/\\&/g')"
escaped_domain="$(printf '%s' "$DOMAIN" | sed 's/[&|]/\\&/g')"
sed -e "s|__FALLBACK_HASH__|$escaped_fallback_hash|" \
    -e "s|__DOMAIN__|$escaped_domain|g" \
    "$config_template" > "$STALWART_DIR/etc/config.toml"

/bin/echo "DOMAIN=$DOMAIN" > /etc/default/stalwart-domain
chmod 0644 /etc/default/stalwart-domain

/usr/local/bin/sync-ejabberd-cert.sh

systemctl daemon-reload
systemctl enable --now stalwart.service

for i in $(seq 1 60); do
  if curl -fsS "$HTTP_READY" >/dev/null 2>&1; then
    break
  fi
  sleep 1
  if [[ "$i" -eq 60 ]]; then
    echo "ERROR: stalwart did not become ready on $HTTP_READY" >&2
    journalctl -u stalwart.service --no-pager -n 200 >&2 || true
    exit 1
  fi
done

basic="admin:${FALLBACK_PASSWORD}"

domain_exists() {
  local domain_id
  domain_id="$(curl -fsS -u "$basic" "$STALWART_API/principal?types=domain&limit=1000" | jq -r --arg dom "$DOMAIN" '.data.items[]? | select(.name==$dom) | .id' | head -n1)"
  [[ -n "$domain_id" && "$domain_id" != "null" ]]
}

if ! domain_exists; then
  bold "MANUAL STEP: Create the domain in Stalwart Webadmin"
  echo
  cat <<EOF

Domain "${DOMAIN}" was not found.
Create it in Webadmin before continuing.

1) On YOUR LAPTOP, start an SSH tunnel:

   ssh -L ${TUNNEL_LOCAL_PORT}:127.0.0.1:${WEBADMIN_REMOTE_PORT} ${STALWART_SSH_USER}@${STALWART_SSH_HOST}

2) Open Webadmin:
   http://127.0.0.1:${TUNNEL_LOCAL_PORT}/login

3) Login:
   Username: admin
   Password: ${FALLBACK_PASSWORD}

4) Go to: Management → Directory → Domains
   - Create domain: ${DOMAIN}

EOF

  if [[ -z "${STALWART_SSH_HOST}" ]]; then
    warn "STALWART_SSH_HOST is not set. The tunnel command above will not work until you set it."
  fi

  if [[ "$CHECKPOINT_MODE" == "1" ]]; then
    exit "$CHECKPOINT_WEBADMIN_DOMAIN_RC"
  fi

  while true; do
    read -r -p "Press Enter after creating domain ${DOMAIN} in Webadmin..." _
    if domain_exists; then
      break
    fi
    warn "Domain ${DOMAIN} is still not found. Create it in Webadmin, then try again."
  done
fi

glue_token_file="$SECRETS_DIR/glue_api_token.txt"

glue_token_is_valid() {
  local token="$1"
  [[ -n "$token" ]] || return 1
  curl -fsS -H "Authorization: Bearer $token" "$STALWART_API/principal?limit=1" >/dev/null 2>&1
}

manual_prompt_for_glue_token() {
  bold "MANUAL STEP: Create an Admin API key in Stalwart Webadmin"
  echo
  cat <<EOF

This installer no longer tries to create API keys programmatically.
You will SSH-tunnel into Stalwart Webadmin, create an API key, then paste it back here.

1) On YOUR LAPTOP, start an SSH tunnel to reach the server-local Webadmin/API:

   ssh -L ${TUNNEL_LOCAL_PORT}:127.0.0.1:${WEBADMIN_REMOTE_PORT} ${STALWART_SSH_USER}@${STALWART_SSH_HOST}

   If STALWART_SSH_HOST is empty, set it and rerun, e.g.:
     STALWART_SSH_HOST=mail.example.com STALWART_SSH_USER=ubuntu ./install.sh

2) Open Webadmin in your browser (via the tunnel):
   http://127.0.0.1:${TUNNEL_LOCAL_PORT}/login

3) Login using the fallback admin credentials created by this installer:
   Username: admin
   Password: ${FALLBACK_PASSWORD}

4) In Webadmin, create an API key principal:
   - Navigate to: Management (or Directory) → API Keys  (or Access Control → Principals → API Keys)
   - Click: Create / + / New
   - Type: apiKey
   - Name: email-glue
   - Roles: admin  (fastest; you can reduce permissions later)
   - Secrets: click Add/Generate secret, then COPY the secret value
   - Save

5) Return to this terminal and paste the secret when prompted.

EOF

  if [[ -z "${STALWART_SSH_HOST}" ]]; then
    warn "STALWART_SSH_HOST is not set. The tunnel command above will not work until you set it."
  fi

  if [[ "$CHECKPOINT_MODE" == "1" ]]; then
    exit "$CHECKPOINT_GLUE_API_TOKEN_RC"
  fi

  while true; do
    echo
    read -rsp "Paste the API key secret for \"email-glue\" (input hidden): " GLUE_API_TOKEN
    echo
    if [[ -z "${GLUE_API_TOKEN}" ]]; then
      warn "API key cannot be empty. Try again."
      continue
    fi
    if ! glue_token_is_valid "$GLUE_API_TOKEN"; then
      warn "API key validation failed. Check key/permissions, then try again."
      continue
    fi
    break
  done
}

if [[ "$GLUE_API_TOKEN_OVERRIDE_SET" == "1" ]]; then
  GLUE_API_TOKEN="$GLUE_API_TOKEN_OVERRIDE"
  if ! glue_token_is_valid "$GLUE_API_TOKEN"; then
    echo "ERROR: --glue-api-token value failed validation against Stalwart API." >&2
    exit 1
  fi
  printf "%s\n" "$GLUE_API_TOKEN" > "$glue_token_file"
  chmod 0600 "$glue_token_file"
elif [[ -s "$glue_token_file" ]]; then
  GLUE_API_TOKEN="$(tr -d '\r\n' < "$glue_token_file")"
  if glue_token_is_valid "$GLUE_API_TOKEN"; then
    info "Reusing existing glue API token from $glue_token_file"
  else
    warn "Existing glue API token failed validation. Prompting for a new token."
    manual_prompt_for_glue_token
    printf "%s\n" "$GLUE_API_TOKEN" > "$glue_token_file"
    chmod 0600 "$glue_token_file"
  fi
else
  manual_prompt_for_glue_token
  printf "%s\n" "$GLUE_API_TOKEN" > "$glue_token_file"
  chmod 0600 "$glue_token_file"
fi

client_token_file="$SECRETS_DIR/client_token.txt"
if [[ "$REQUIRE_PUBLIC_TOKEN" == "1" ]]; then
  if [[ "$PUBLIC_TOKEN_OVERRIDE_SET" == "1" ]]; then
    CLIENT_TOKEN="$PUBLIC_TOKEN_OVERRIDE"
    printf "%s\n" "$CLIENT_TOKEN" > "$client_token_file"
    chmod 0600 "$client_token_file"
  elif [[ -f "$client_token_file" ]]; then
    CLIENT_TOKEN="$(tr -d '\r\n' < "$client_token_file")"
  else
    CLIENT_TOKEN="$(openssl rand -hex 32)"
    printf "%s\n" "$CLIENT_TOKEN" > "$client_token_file"
    chmod 0600 "$client_token_file"
  fi
fi

cat > /etc/sysconfig/email-glue <<EOF
EMAIL_DOMAIN=$DOMAIN
STALWART_API_TOKEN=$GLUE_API_TOKEN
EMAIL_GLUE_REQUIRE_CLIENT_TOKEN=$REQUIRE_PUBLIC_TOKEN
EMAIL_GLUE_DEFAULT_QUOTA_BYTES=0
EOF
if [[ "$REQUIRE_PUBLIC_TOKEN" == "1" ]]; then
  cat >> /etc/sysconfig/email-glue <<EOF
EMAIL_GLUE_CLIENT_TOKEN=$CLIENT_TOKEN
EOF
fi
chmod 0600 /etc/sysconfig/email-glue

EMAIL_GLUE_PREBUILT_DIR="$(dirname "$0")/email-glue/prebuilt"
EMAIL_GLUE_TARGET="/usr/local/bin/email-glue"

detect_email_glue_arch() {
  if command -v dpkg >/dev/null 2>&1; then
    case "$(dpkg --print-architecture)" in
      amd64) printf 'amd64\n' ;;
      arm64) printf 'arm64\n' ;;
      *) printf 'unsupported\n' ;;
    esac
    return
  fi

  case "$(uname -m)" in
    x86_64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) printf 'unsupported\n' ;;
  esac
}

install_email_glue_binary() {
  local arch source
  arch="$(detect_email_glue_arch)"
  source="${EMAIL_GLUE_PREBUILT_DIR}/email-glue-linux-${arch}"

  if [[ "$arch" != "unsupported" && -x "$source" ]]; then
    info "Installing bundled email-glue binary for linux/${arch}"
    install -m 0755 "$source" "$EMAIL_GLUE_TARGET"
    return
  fi

  warn "No bundled email-glue binary is available for this architecture. Falling back to a local Go build."
  apt-get install -y golang-go
  (
    cd "$(dirname "$0")/email-glue"
    go build -o "$EMAIL_GLUE_TARGET" ./...
  )
}

install_email_glue_binary

systemctl enable --now email-glue.service
systemctl restart email-glue.service >/dev/null 2>&1 || true
systemctl enable --now update-stalwart-cert.timer


if [[ "$SKIP_DNS_GUIDANCE" != "1" ]]; then
  bold "MANUAL STEP: Configure DNS (DKIM / DMARC / SPF / MX) in your registrar"
  cat <<EOF

This installer no longer fetches DNS records programmatically.
Copy the generated DNS records from Webadmin and paste them into your DNS provider/registrar.
Webadmin/API runs on server-local port ${WEBADMIN_REMOTE_PORT} (default 8080).

1) In Webadmin (same tunnel as above):
   http://127.0.0.1:${TUNNEL_LOCAL_PORT}/login

2) Go to: Management → Directory → Domains
   - Ensure the domain "${DOMAIN}" exists.

3) Open the DNS records view for the domain:
   - Find "${DOMAIN}" in the list
   - Click the actions menu (⋯ / three dots)
   - Click "DNS Records" / "View DNS records"

4) Add the records shown at your DNS provider. Typically this includes:
   - MX record(s)
   - SPF TXT record (v=spf1 …)
   - DMARC TXT record at _dmarc.${DOMAIN}
   - DKIM TXT record(s) at <selector>._domainkey.${DOMAIN}
   - Any other records shown (SRV, MTA-STS, TLS-RPT, etc. if enabled)

Notes:
• If you already have SPF/DMARC/DKIM, MERGE carefully instead of overwriting.
• SPF must be a single TXT record per hostname.

EOF
fi

echo "OK"
echo "fallback_admin_password=$FALLBACK_PASSWORD"
echo "glue_api_token_file=$glue_token_file"
if [[ "$REQUIRE_PUBLIC_TOKEN" == "1" ]]; then
  echo "client_token_file=$client_token_file"
  echo "client_token_header=X-Client-Token"
else
  echo "client_token_file=disabled"
fi
echo "dns_records_note=Copy DNS records from Webadmin → Domains → (⋯) → DNS Records"
