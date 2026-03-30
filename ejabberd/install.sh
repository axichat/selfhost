#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
: "${DOMAIN:?Set DOMAIN=example.com before running}"
ADMIN_USER="admin"
: "${EJABBERD_VERSION_PREFIX:=26.}"
: "${SKIP_FIREWALL:=0}"
FPUSH_COMMIT="42359ca"

CFG_SRC="${SCRIPT_DIR}/ejabberd.yml"
ACME_REDIRECT_UNIT_SRC="${SCRIPT_DIR}/systemd/ejabberd-acme-redirect.service"
ACME_REDIRECT_UNIT_DST="/etc/systemd/system/ejabberd-acme-redirect.service"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

on_err() {
  local rc=$?
  echo >&2
  echo "ERROR: install failed (exit $rc) at line ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2
  echo "Debug tips:" >&2
  echo "  - systemctl status ejabberd --no-pager" >&2
  echo "  - journalctl -u ejabberd -b --no-pager | tail -n 300" >&2
  echo "  - tail -n 300 /opt/ejabberd/logs/ejabberd.log 2>/dev/null || true" >&2
  echo "  - systemctl status fpush --no-pager" >&2
  echo "  - journalctl -u fpush -b --no-pager | tail -n 300" >&2
  exit $rc
}
trap on_err ERR

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

as_user() {
  # Run a login shell as a system user WITHOUT requiring sudo.
  # Usage: as_user fpush 'command...'
  local u="$1"
  shift
  runuser -u "$u" -- bash -lc "$*"
}

load_existing_fpush_settings() {
  python3 - <<'PY'
import json
import os
import shlex
import sys

path = "/opt/fpush/settings.json"
if not os.path.exists(path):
    raise SystemExit(1)

with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

component = data.get("component") or {}
push_modules = data.get("pushModules") or {}

module_name = ""
module = {}
for name, candidate in push_modules.items():
    if not isinstance(candidate, dict):
        continue
    if candidate.get("type") == "apple" or "apns" in candidate:
        module_name = name
        module = candidate
        break

apns = module.get("apns") or {}
values = {
    "FPUSH_SECRET": component.get("componentKey", ""),
    "APNS_NAME": module_name,
    "APNS_P12_DST": apns.get("certFilePath", ""),
    "APNS_P12_PASS": apns.get("certPassword", ""),
    "APNS_TOPIC": apns.get("topic", ""),
    "APNS_ENV": apns.get("environment", "production"),
}

required = ("FPUSH_SECRET", "APNS_NAME", "APNS_P12_DST", "APNS_TOPIC")
if any(not values[key] for key in required):
    raise SystemExit(1)

for key, value in values.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
}

has_domain_certificate() {
  "$EJABBERDCTL" list-certificates 2>/dev/null | awk -v d="${DOMAIN}" '$1==d{found=1} END{exit(found?0:1)}'
}

install_acme_redirect_service() {
  [[ -f "$ACME_REDIRECT_UNIT_SRC" ]] || die "Missing ${ACME_REDIRECT_UNIT_SRC}"
  command -v socat >/dev/null 2>&1 || die "socat is required for the ejabberd ACME port-80 forwarder"

  install -m 0644 "$ACME_REDIRECT_UNIT_SRC" "$ACME_REDIRECT_UNIT_DST"
  systemctl daemon-reload
  systemctl enable --now ejabberd-acme-redirect.service
}

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -f "$CFG_SRC" ]] || die "Missing ${CFG_SRC}. Put install.sh and ejabberd.yml in the same directory."

if [[ ! -r /etc/os-release ]]; then
  die "Cannot detect OS (missing /etc/os-release)."
fi
. /etc/os-release
if [[ "${ID:-}" != "debian" ]]; then
  die "This script is hardcoded for Debian. Detected: ID=${ID:-unknown} VERSION=${VERSION_ID:-unknown}"
fi

export DEBIAN_FRONTEND=noninteractive
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

apt-get update -y

apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg iproute2 python3

apt-get install -y --no-install-recommends \
  socat \
  sqlite3 imagemagick fonts-dejavu-core gsfonts \
  git build-essential pkg-config libssl-dev

curl -fsSL -o /etc/apt/sources.list.d/ejabberd.list https://repo.process-one.net/ejabberd.list
curl -fsSL -o /etc/apt/trusted.gpg.d/ejabberd.gpg https://repo.process-one.net/ejabberd.gpg
apt-get update -y

avail_ver="$(apt-cache madison ejabberd | awk '{print $3}' | awk -v p="${EJABBERD_VERSION_PREFIX}" 'index($0,p)==1{print; exit}' || true)"
if [[ -z "$avail_ver" ]]; then
  echo "Available ejabberd versions in apt:" >&2
  apt-cache madison ejabberd >&2 || true
  die "ejabberd ${EJABBERD_VERSION_PREFIX} not found in apt sources."
fi

apt-get install -y "ejabberd=${avail_ver}"
EJABBERD_BASE_VER="${avail_ver%%-*}"
EJABBERD_BASE_VER="${EJABBERD_BASE_VER%%+*}"
apt-mark hold ejabberd >/dev/null 2>&1 || true

EJABBERD_BIN_DIR="/opt/ejabberd-${EJABBERD_BASE_VER}/bin"
EJABBERDCTL="${EJABBERD_BIN_DIR}/ejabberdctl"
[[ -x "$EJABBERDCTL" ]] || die "Expected ejabberdctl at ${EJABBERDCTL}, but it is missing."
export PATH="${EJABBERD_BIN_DIR}:${PATH}"
cat >/etc/profile.d/ejabberd.sh <<EOF
export PATH=${EJABBERD_BIN_DIR}:\$PATH
EOF
chmod 0644 /etc/profile.d/ejabberd.sh
# Also expose ejabberdctl in a standard bin dir so non-login shells can use it.
ln -sfn "${EJABBERDCTL}" /usr/local/bin/ejabberdctl

mkdir -p /opt/ejabberd/conf /opt/ejabberd/database /var/www/upload /var/lib/ejabberd
chown -R ejabberd:ejabberd /opt/ejabberd/database /var/www/upload /var/lib/ejabberd
chmod 750 /opt/ejabberd/database /var/www/upload

SERVER_PEM="/opt/ejabberd/conf/server.pem"
if [[ ! -s "$SERVER_PEM" ]]; then
  echo "ERROR: ${SERVER_PEM} is missing or empty." >&2
  echo "This script (Option B) does NOT generate a fallback certificate." >&2
  echo "On ProcessOne packages, a default server.pem is usually present; if it's not, reinstall ejabberd or create one manually." >&2
  die "Missing TLS keypair file: ${SERVER_PEM}"
fi

echo
echo "== Secrets (will NOT be echoed) =="

FPUSH_REUSED_SETTINGS="0"
FPUSH_SECRET=""
APNS_NAME=""
APNS_P12_DST=""
APNS_P12_PASS=""
APNS_TOPIC=""
APNS_ENV=""

if [[ -n "${ENABLE_FPUSH:-}" ]]; then
  ENABLE_FPUSH="$(echo "${ENABLE_FPUSH:-}" | tr '[:upper:]' '[:lower:]')"
  echo "Enable fpush (XEP-0357) component? ${ENABLE_FPUSH} (preconfigured)"
else
  read -r -p "Enable fpush (XEP-0357) component? [y/N]: " ENABLE_FPUSH || true
  ENABLE_FPUSH="$(echo "${ENABLE_FPUSH:-}" | tr '[:upper:]' '[:lower:]')"
fi

if [[ "$ENABLE_FPUSH" == "y" || "$ENABLE_FPUSH" == "yes" ]]; then
  existing_fpush_settings="$(load_existing_fpush_settings 2>/dev/null || true)"
  if [[ -n "$existing_fpush_settings" ]]; then
    eval "$existing_fpush_settings"
  fi
  if [[ -n "$FPUSH_SECRET" && -n "$APNS_P12_DST" && -n "$APNS_TOPIC" && -f "$APNS_P12_DST" ]]; then
    FPUSH_REUSED_SETTINGS="1"
    echo "Reusing existing fpush component secret and APNS settings from /opt/fpush/settings.json"
  else
    while true; do
      read -r -s -p "Set fpush component secret for push.${DOMAIN}: " FPUSH_SECRET; echo
      [[ -n "$FPUSH_SECRET" ]] || { echo "Secret cannot be empty. Try again."; continue; }
      [[ "$FPUSH_SECRET" != *$'\n'* ]] || { echo "Secret must be single-line."; continue; }
      break
    done
  fi
fi

if [[ -n "${TURN_IPV4:-}" ]]; then
  echo "TURN public IPv4: ${TURN_IPV4} (preconfigured)"
else
  TURN_IPV4="$(curl -4 -fsS https://api.ipify.org || true)"
fi
if [[ -z "$TURN_IPV4" ]]; then
  read -r -p "Public IPv4 for TURN (optional; leave blank to disable TURN): " TURN_IPV4
fi

TMP_CFG="$(mktemp)"
cp -f "$CFG_SRC" "$TMP_CFG"

CAPTCHA_PATH="$(ls -1 /opt/ejabberd-${EJABBERD_BASE_VER}/lib/captcha.sh 2>/dev/null | head -n 1 || true)"
if [[ -z "$CAPTCHA_PATH" ]]; then
  die "captcha.sh not found under /opt/ejabberd-${EJABBERD_BASE_VER}/lib/captcha.sh. Check ejabberd installation."
fi

if [[ "$ENABLE_FPUSH" == "y" || "$ENABLE_FPUSH" == "yes" ]]; then
  FPUSH_SECRET_ESC="$FPUSH_SECRET"
  FPUSH_SECRET_ESC="${FPUSH_SECRET_ESC//\\/\\\\}"
  FPUSH_SECRET_ESC="${FPUSH_SECRET_ESC//&/\\&}"
  FPUSH_SECRET_ESC="${FPUSH_SECRET_ESC//|/\\|}"
  sed -i -e "s|__FPUSH_COMPONENT_SECRET__|${FPUSH_SECRET_ESC}|g" "$TMP_CFG"
else
  python3 - "$TMP_CFG" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
output = []
i = 0

while i < len(lines):
    line = lines[i]
    if line.strip() == "listen:":
        output.append(line)
        i += 1
        while i < len(lines):
            if lines[i].startswith("modules:"):
                break
            if not lines[i].startswith("  -"):
                output.append(lines[i])
                i += 1
                continue
            j = i + 1
            block_lines = [lines[i]]
            while j < len(lines):
                l = lines[j]
                if l.startswith("  -"):
                    break
                if not l.startswith(" ") and l != "":
                    break
                block_lines.append(l)
                j += 1
            if any(l.strip() == "port: 5347" for l in block_lines):
                i = j
                continue
            output.extend(block_lines)
            i = j
        continue
    output.append(line)
    i += 1

path.write_text("\n".join(output) + ("\n" if lines else ""))
PY
fi
DOMAIN_ESC="${DOMAIN//\\/\\\\}"
DOMAIN_ESC="${DOMAIN_ESC//&/\\&}"
DOMAIN_ESC="${DOMAIN_ESC//|/\\|}"
sed -i -e "s|__DOMAIN__|${DOMAIN_ESC}|g" "$TMP_CFG"
sed -i -e "s|@HOST@|${DOMAIN_ESC}|g" "$TMP_CFG"
sed -i -e "s|^captcha_cmd:.*$|captcha_cmd: ${CAPTCHA_PATH}|g" "$TMP_CFG"

if grep -q "@HOST@" "$TMP_CFG"; then
  echo "Rendered config still contains @HOST@ placeholders:" >&2
  grep -n "@HOST@" "$TMP_CFG" >&2 || true
  die "Template substitution failed for @HOST@."
fi

if [[ -n "$TURN_IPV4" ]]; then
  sed -i -e "s|__TURN_IPV4__|$TURN_IPV4|g" "$TMP_CFG"
else
  sed -i -e 's/^    use_turn: true$/    use_turn: false/' "$TMP_CFG"
  sed -i -e '/^    turn_ipv4_address:/d' "$TMP_CFG"
fi

install -o ejabberd -g ejabberd -m 640 "$TMP_CFG" /opt/ejabberd/conf/ejabberd.yml
rm -f "$TMP_CFG"

systemctl enable ejabberd >/dev/null 2>&1 || true

echo
echo "== Port 80 -> 5280 forwarding (ACME HTTP-01) =="
if ss -ltn '( sport = :80 )' | grep -q LISTEN; then
  if systemctl is-active --quiet ejabberd-acme-redirect.service; then
    echo "Port-80 forwarder already active."
  else
    die "Port 80 is already in use. Stop the service using port 80, then re-run."
  fi
else
  install_acme_redirect_service
fi

echo
echo "== Starting ejabberd =="
systemctl restart ejabberd
systemctl --no-pager --full status ejabberd | sed -n '1,25p' || true

echo
echo "== Firewall (best-effort) =="
if [[ "$SKIP_FIREWALL" == "1" ]]; then
  echo "Skipping UFW rule changes because the root wrapper already manages them."
elif command -v ufw >/dev/null 2>&1; then
  ufw_active="yes"
  if ufw status 2>/dev/null | head -n1 | grep -qi "inactive"; then
    ufw_active="no"
  fi
  if [[ "$ufw_active" == "no" ]]; then
    echo "ufw is installed but inactive; not enabling it or changing global policy."
    echo "Open the ejabberd ports yourself if you want to use UFW."
  else
    ufw allow 5222/tcp >/dev/null 2>&1 || true
    ufw allow 5223/tcp >/dev/null 2>&1 || true
    ufw allow 5269/tcp >/dev/null 2>&1 || true
    ufw allow 5443/tcp >/dev/null 2>&1 || true
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 3478/udp >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
    echo "Added app-specific ufw rules."
  fi
else
  echo "ufw not installed; not changing host firewall rules."
fi

echo
echo "== Creating admin account =="
if "$EJABBERDCTL" registered_users "$DOMAIN" 2>/dev/null | grep -q "^${ADMIN_USER}$"; then
  echo "Admin user already exists: ${ADMIN_USER}@${DOMAIN} (skipping register)."
else
  while true; do
    read -r -s -p "Set password for ${ADMIN_USER}@${DOMAIN}: " ADMIN_PASS_1; echo
    read -r -s -p "Confirm password: " ADMIN_PASS_2; echo
    [[ "$ADMIN_PASS_1" == "$ADMIN_PASS_2" ]] || { echo "Passwords do not match. Try again."; continue; }
    [[ -n "$ADMIN_PASS_1" ]] || { echo "Password cannot be empty. Try again."; continue; }
    break
  done
  "$EJABBERDCTL" register "$ADMIN_USER" "$DOMAIN" "$ADMIN_PASS_1"
fi

unset ADMIN_PASS_1 ADMIN_PASS_2

echo
if has_domain_certificate; then
  echo "== Existing certificate found for ${DOMAIN}; skipping ACME request =="
else
  echo "== Requesting TLS certificate (Let's Encrypt) =="
  echo "NOTE: ACME requires inbound HTTP on port 80 (the bundled port-80 forwarder sends it to ejabberd port 5280)."
  echo "If this fails, confirm ${DOMAIN} resolves to this server and that inbound TCP/80 is allowed."
  "$EJABBERDCTL" request-certificate "$DOMAIN" || die "ACME certificate request failed."
  systemctl restart ejabberd
fi

echo
echo "== Certificate selection for ${DOMAIN} =="
if ! "$EJABBERDCTL" list-certificates | awk -v d="${DOMAIN}" '$1==d{print; found=1} END{if(!found) exit 1}'; then
  echo "WARNING: No certificate is currently listed for ${DOMAIN}."
fi

echo
echo "== Message retention =="
echo "No automatic MAM purge timer installed (full history retention by default)."

###############################################################################
# fpush install + config + service (optional)
###############################################################################
if [[ "$ENABLE_FPUSH" == "y" || "$ENABLE_FPUSH" == "yes" ]]; then
  echo
  echo "== Installing fpush and connecting as XMPP component =="

if ! id -u fpush >/dev/null 2>&1; then
  useradd --system --home /var/lib/fpush --create-home --shell /usr/sbin/nologin fpush
fi

mkdir -p /opt/fpush /opt/fpush/src /opt/fpush/creds
chown -R fpush:fpush /opt/fpush
chmod 750 /opt/fpush /opt/fpush/creds

echo
if [[ "$FPUSH_REUSED_SETTINGS" == "1" ]]; then
  ENABLE_APNS="yes"
  echo "Enable Apple APNS push module? yes (reusing existing settings)"
else
  read -r -p "Enable Apple APNS push module? [y/N]: " ENABLE_APNS || true
  ENABLE_APNS="$(echo "${ENABLE_APNS:-}" | tr '[:upper:]' '[:lower:]')"
fi

if [[ "$ENABLE_APNS" != "y" && "$ENABLE_APNS" != "yes" ]]; then
  die "APNS is required for fpush in this setup. Re-run and enable APNS."
fi

PUSH_MODULES_LINES=()

if [[ "$FPUSH_REUSED_SETTINGS" == "1" ]]; then
  echo "Reusing existing Apple APNS push module settings from /opt/fpush/settings.json"
else
  read -r -p "APNS module name (pushModule value) [apns]: " APNS_NAME || true
  APNS_NAME="${APNS_NAME:-apns}"

  read -r -p "Path to APNS .p12 certificate file: " APNS_P12_PATH
  [[ -f "$APNS_P12_PATH" ]] || die "APNS p12 file not found: $APNS_P12_PATH"

  read -r -s -p "APNS p12 password (can be empty if none): " APNS_P12_PASS; echo
  [[ "$APNS_P12_PASS" != *$'\n'* ]] || die "APNS password must be single-line."

  read -r -p "APNS topic (bundle id, e.g. com.example.app): " APNS_TOPIC
  [[ -n "$APNS_TOPIC" ]] || die "APNS topic cannot be empty."

  read -r -p "APNS environment [production/sandbox] (default production): " APNS_ENV || true
  APNS_ENV="${APNS_ENV:-production}"

  APNS_P12_DST="/opt/fpush/creds/apns_${APNS_NAME}.p12"
  install -o fpush -g fpush -m 600 "$APNS_P12_PATH" "$APNS_P12_DST"
fi

PUSH_MODULES_LINES+=("    \"$(json_escape "$APNS_NAME")\": {")
PUSH_MODULES_LINES+=("      \"type\": \"apple\",")
PUSH_MODULES_LINES+=("      \"is_default_module\": true,")
PUSH_MODULES_LINES+=("      \"apns\": {")
PUSH_MODULES_LINES+=("        \"certFilePath\": \"$(json_escape "$APNS_P12_DST")\",")
PUSH_MODULES_LINES+=("        \"certPassword\": \"$(json_escape "$APNS_P12_PASS")\",")
PUSH_MODULES_LINES+=("        \"topic\": \"$(json_escape "$APNS_TOPIC")\",")
PUSH_MODULES_LINES+=("        \"environment\": \"$(json_escape "$APNS_ENV")\"")
PUSH_MODULES_LINES+=("      }")
PUSH_MODULES_LINES+=("    }")

echo
echo "== Building fpush from source (Rust) =="

if [[ ! -x /var/lib/fpush/.cargo/bin/cargo ]]; then
  as_user fpush 'curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal'
fi

if [[ ! -d /opt/fpush/src/.git ]]; then
  as_user fpush 'cd /opt/fpush && git clone --depth 1 https://github.com/monal-im/fpush.git src'
fi

as_user fpush "cd /opt/fpush/src && git fetch --depth 1 origin ${FPUSH_COMMIT} && git checkout --detach ${FPUSH_COMMIT} && git reset --hard ${FPUSH_COMMIT}"

as_user fpush 'cd /opt/fpush/src && /var/lib/fpush/.cargo/bin/cargo build --release'
install -o root -g root -m 0755 /opt/fpush/src/target/release/fpush /opt/fpush/fpush

echo
echo "== Writing /opt/fpush/settings.json =="

{
  echo "{"
  echo "  \"component\": {"
  echo "    \"componentHostname\": \"push.${DOMAIN}\","
  echo "    \"componentKey\": \"$(json_escape "$FPUSH_SECRET")\","
  echo "    \"serverHostname\": \"127.0.0.1\","
  echo "    \"serverPort\": 5347"
  echo "  },"
  echo "  \"pushModules\": {"
  printf '%s\n' "${PUSH_MODULES_LINES[@]}"
  echo "  },"
  echo "  \"timeout\": {"
  echo "    \"xmppconnectionError\": \"20s\""
  echo "  }"
  echo "}"
} >/opt/fpush/settings.json

chown fpush:fpush /opt/fpush/settings.json
chmod 600 /opt/fpush/settings.json

echo
echo "== Installing systemd service for fpush =="
cat >/etc/systemd/system/fpush.service <<'EOF'
[Unit]
Description=Fpush (XEP-0357 push app server)
After=network.target ejabberd.service
Requires=ejabberd.service

[Service]
Type=simple
User=fpush
Group=fpush
WorkingDirectory=/opt/fpush
Environment=RUST_LOG=info
ExecStart=/opt/fpush/fpush /opt/fpush/settings.json
Restart=on-failure
RestartSec=10
LimitNOFILE=131072

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now fpush
systemctl --no-pager --full status fpush | sed -n '1,30p' || true

unset ADMIN_PASS_1 ADMIN_PASS_2 FPUSH_SECRET APNS_P12_PASS
else
  unset ADMIN_PASS_1 ADMIN_PASS_2
fi

echo
echo "DONE."
echo "XMPP domain: ${DOMAIN}"
echo "Admin JID:   ${ADMIN_USER}@${DOMAIN}"
echo
echo "Ports (make sure your cloud firewall allows these):"
echo "  - 5222/tcp  (client STARTTLS required)"
echo "  - 5223/tcp  (client direct TLS)"
echo "  - 5269/tcp  (server-to-server federation)"
echo "  - 5443/tcp  (web admin, websockets, upload, captcha, web registration)"
echo "  - 5280/tcp  (internal-only HTTP for ACME challenge; do not expose it publicly)"
echo "  - 80/tcp    (must be open for ACME HTTP-01)"
echo "  - 3478/udp  (STUN/TURN)"
echo
echo "Local-only:"
echo "  - 5281/tcp  (HTTP API on 127.0.0.1)"
echo "  - 5347/tcp  (XMPP component socket for fpush on 127.0.0.1)"
