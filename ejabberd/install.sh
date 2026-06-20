#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
: "${DOMAIN:?Set DOMAIN=example.com before running}"
ADMIN_USER="admin"
: "${EJABBERD_VERSION_PREFIX:=26.}"
: "${SKIP_FIREWALL:=0}"

CFG_SRC="${SCRIPT_DIR}/ejabberd.yml"
ACME_REDIRECT_UNIT_SRC="${SCRIPT_DIR}/systemd/ejabberd-acme-redirect.service"
ACME_REDIRECT_UNIT_DST="/etc/systemd/system/ejabberd-acme-redirect.service"
LOG_DIR="/var/log/axichat-selfhost"
INSTALL_LOG="${LOG_DIR}/ejabberd-install.log"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

on_err() {
  local rc=$?
  echo >&2
  echo "ERROR: install failed (exit $rc) at line ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2
  echo "Debug tips:" >&2
  echo "  - tail -n 200 ${INSTALL_LOG}" >&2
  echo "  - systemctl status ejabberd --no-pager" >&2
  echo "  - journalctl -u ejabberd -b --no-pager | tail -n 300" >&2
  echo "  - tail -n 300 /opt/ejabberd/logs/ejabberd.log 2>/dev/null || true" >&2
  exit $rc
}
trap on_err ERR

has_domain_certificate() {
  "$EJABBERDCTL" list-certificates 2>/dev/null | awk -v d="${DOMAIN}" '$1==d{found=1} END{exit(found?0:1)}'
}

install_acme_redirect_service() {
  [[ -f "$ACME_REDIRECT_UNIT_SRC" ]] || die "Missing ${ACME_REDIRECT_UNIT_SRC}"
  command -v socat >/dev/null 2>&1 || die "socat is required for the ejabberd ACME port-80 forwarder"

  install -m 0644 "$ACME_REDIRECT_UNIT_SRC" "$ACME_REDIRECT_UNIT_DST"
  run_logged_step "Reloading systemd units for the ACME port-80 forwarder" systemctl daemon-reload
  run_logged_step "Starting the ACME port-80 forwarder" systemctl enable --now ejabberd-acme-redirect.service
}

run_logged_step() {
  local label="$1"
  shift

  echo "• ${label}"
  if "$@" >>"$INSTALL_LOG" 2>&1; then
    return 0
  fi

  local rc=$?
  echo "ERROR: ${label} failed. Full log: ${INSTALL_LOG}" >&2
  tail -n 80 "$INSTALL_LOG" >&2 || true
  exit "$rc"
}

log_step_output() {
  "$@" >>"$INSTALL_LOG" 2>&1 || true
}

reset_ejabberd_apt_repo_files() {
  rm -f /etc/apt/sources.list.d/ejabberd.list /etc/apt/trusted.gpg.d/ejabberd.gpg
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
mkdir -p "$LOG_DIR"
touch "$INSTALL_LOG"
chmod 0600 "$INSTALL_LOG"
{
  echo
  echo "==== $(date -u +"%Y-%m-%dT%H:%M:%SZ") ejabberd install for ${DOMAIN} ===="
} >>"$INSTALL_LOG"
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

reset_ejabberd_apt_repo_files
run_logged_step "Updating apt package lists" apt-get update -y

run_logged_step "Installing ejabberd base dependencies" apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg iproute2

run_logged_step "Installing ejabberd helper packages" apt-get install -y --no-install-recommends \
  socat \
  sqlite3 imagemagick fonts-dejavu-core gsfonts

run_logged_step "Fetching ejabberd apt repository list" curl -fsSL -o /etc/apt/sources.list.d/ejabberd.list https://repo.process-one.net/ejabberd.list
run_logged_step "Fetching ejabberd apt signing key" curl -fsSL -o /etc/apt/trusted.gpg.d/ejabberd.gpg https://repo.process-one.net/ejabberd.gpg
chmod 0644 /etc/apt/sources.list.d/ejabberd.list /etc/apt/trusted.gpg.d/ejabberd.gpg
run_logged_step "Refreshing apt package lists for ejabberd packages" apt-get update -y

avail_ver="$(apt-cache madison ejabberd | awk '{print $3}' | awk -v p="${EJABBERD_VERSION_PREFIX}" 'index($0,p)==1{print; exit}' || true)"
if [[ -z "$avail_ver" ]]; then
  echo "Available ejabberd versions in apt:" >&2
  apt-cache madison ejabberd >&2 || true
  die "ejabberd ${EJABBERD_VERSION_PREFIX} not found in apt sources."
fi

run_logged_step "Installing ejabberd ${avail_ver}" apt-get install -y "ejabberd=${avail_ver}"
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
rm -f /usr/local/bin/ejabberdctl
cat >/usr/local/bin/ejabberdctl <<EOF
#!/bin/sh
exec "${EJABBERDCTL}" "\$@"
EOF
chmod 0755 /usr/local/bin/ejabberdctl

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

TMP_CFG="$(mktemp)"
cp -f "$CFG_SRC" "$TMP_CFG"

CAPTCHA_PATH="$(ls -1 /opt/ejabberd-${EJABBERD_BASE_VER}/lib/captcha.sh 2>/dev/null | head -n 1 || true)"
if [[ -z "$CAPTCHA_PATH" ]]; then
  die "captcha.sh not found under /opt/ejabberd-${EJABBERD_BASE_VER}/lib/captcha.sh. Check ejabberd installation."
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

if [[ -n "${TURN_IPV4:-}" ]]; then
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
run_logged_step "Restarting ejabberd" systemctl restart ejabberd
log_step_output systemctl --no-pager --full status ejabberd

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
  run_logged_step "Requesting a Let's Encrypt certificate for ${DOMAIN}" "$EJABBERDCTL" request-certificate "$DOMAIN"
  run_logged_step "Restarting ejabberd after certificate request" systemctl restart ejabberd
  log_step_output systemctl --no-pager --full status ejabberd
fi

echo
echo "== Certificate selection for ${DOMAIN} =="
if ! "$EJABBERDCTL" list-certificates | awk -v d="${DOMAIN}" '$1==d{print; found=1} END{if(!found) exit 1}'; then
  die "No TLS certificate is currently listed for ${DOMAIN}.

The install cannot continue without a working ejabberd certificate because Stalwart reuses it.
If ACME was rate-limited or port 80 was not reachable, fix that first and rerun the installer."
fi

echo
echo "== Message retention =="
echo "No automatic MAM purge timer installed (full history retention by default)."

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
if [[ -n "${TURN_IPV4:-}" ]]; then
  echo "  - 3478/udp  (relay)"
fi
echo
echo "Local-only:"
echo "  - 5281/tcp  (HTTP API on 127.0.0.1)"
