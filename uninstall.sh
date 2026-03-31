#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${AXICHAT_SELFHOST_CONFIG_FILE:-/etc/axichat/selfhost.env}"
STATE_DIR="${AXICHAT_SELFHOST_STATE_DIR:-/var/lib/axichat-selfhost}"
STATE_FILE="${STATE_DIR}/state.env"
STATE_JSON="${STATE_DIR}/state.json"
LOCK_FILE="${AXICHAT_SELFHOST_LOCK_FILE:-/run/lock/axichat-selfhost.lock}"

ASSUME_YES="0"
PURGE_EJABBERD_PACKAGE="1"
DOMAIN_HINT="example.com"
LOCK_FD=""
EJABBERD_ACME_DIR="/var/lib/ejabberd/acme"
EJABBERD_ACME_BACKUP_DIR="/var/lib/axichat-selfhost-preserved/ejabberd-acme"
CERTS_MODE="ask"

info() { printf '• %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash ./uninstall.sh [options]

Default behavior:
  - stops and removes the Axichat self-host services
  - deletes the local app data, secrets, units, and wrapper state
  - removes the ejabberd port-80 forwarder service and any old redirect block this repo added
  - asks whether to purge ejabberd ACME account/certificate state
  - purges the ejabberd package so the next demo attempt starts cleanly

Options:
  --yes                    Do not ask for confirmation.
  --purge-certs            Also remove ejabberd ACME account/certificate state.
  --keep-certs             Preserve ejabberd ACME account/certificate state without asking.
  --keep-ejabberd-package  Keep the ejabberd package installed.
  -h, --help               Show this help.
EOF
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root"
}

release_install_lock() {
  [[ -n "${LOCK_FD}" ]] || return 0
  flock -u "${LOCK_FD}" >/dev/null 2>&1 || true
  eval "exec ${LOCK_FD}>&-"
  LOCK_FD=""
}

acquire_install_lock() {
  command -v flock >/dev/null 2>&1 || die "flock is required"
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec {LOCK_FD}> "$LOCK_FILE"
  flock -n "$LOCK_FD" || die "an install, upgrade, or uninstall is already running.

Stop it or wait for it to finish, then rerun uninstall."
  trap release_install_lock EXIT
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes)
        ASSUME_YES="1"
        shift
        ;;
      --keep-ejabberd-package)
        PURGE_EJABBERD_PACKAGE="0"
        shift
        ;;
      --purge-certs)
        CERTS_MODE="purge"
        shift
        ;;
      --keep-certs)
        CERTS_MODE="keep"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

load_saved_domain_hint() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    DOMAIN_HINT="${DOMAIN:-$DOMAIN_HINT}"
  fi
}

confirm_teardown() {
  if [[ "$ASSUME_YES" == "1" ]]; then
    return
  fi

  cat <<EOF
This will remove the local Axichat self-host install for ${DOMAIN_HINT}:
  - ejabberd, Stalwart, email-glue, and fpush services
  - local app data, secrets, wrapper config/state, and the ejabberd port-80 forwarder this repo added
  - ejabberd ACME account/certificate state at ${EJABBERD_ACME_DIR}$(
      case "$CERTS_MODE" in
        purge) printf ' (will be removed)' ;;
        keep) printf ' (will be preserved)' ;;
        *) printf ' (you will be asked)' ;;
      esac)
  - the ejabberd package itself$([[ "$PURGE_EJABBERD_PACKAGE" == "1" ]] && printf '' || printf ' (kept installed)')

This does NOT:
  - destroy the VPS
  - undo unrelated server-level changes you made outside this repo
  - remove generic allow-rules from your firewall
  - delete DNS/PTR records for you
EOF

  local answer
  read -r -p "Continue with uninstall? [y/N]: " answer || true
  answer="$(printf '%s' "${answer:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$answer" == "y" || "$answer" == "yes" ]] || die "uninstall cancelled"
}

decide_cert_cleanup() {
  if [[ "$CERTS_MODE" == "purge" || "$CERTS_MODE" == "keep" ]]; then
    return
  fi

  if [[ ! -d "$EJABBERD_ACME_DIR" ]]; then
    CERTS_MODE="purge"
    return
  fi

  cat <<EOF
ejabberd ACME account/certificate state was found at:
  ${EJABBERD_ACME_DIR}

Choose yes only if you really want a full certificate cleanup.
Choose no if you want future demo reruns to reuse the existing ACME state and avoid new TLS issuance.
EOF

  local answer
  read -r -p "Purge ejabberd ACME certificate/account state too? [y/N]: " answer || true
  answer="$(printf '%s' "${answer:-}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$answer" == "y" || "$answer" == "yes" ]]; then
    CERTS_MODE="purge"
  else
    CERTS_MODE="keep"
  fi
}

stop_disable_unit() {
  local unit
  for unit in "$@"; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  done
}

remove_file_if_present() {
  local path
  for path in "$@"; do
    [[ -e "$path" || -L "$path" ]] || continue
    rm -f "$path"
  done
}

remove_dir_if_present() {
  local path
  for path in "$@"; do
    [[ -e "$path" ]] || continue
    rm -rf "$path"
  done
}

remove_ufw_redirect_block() {
  local before_rules="/etc/ufw/before.rules"
  [[ -f "$before_rules" ]] || return 0
  command -v python3 >/dev/null 2>&1 || {
    warn "python3 is not available, so the ejabberd port-80 redirect block was not removed from ${before_rules}"
    return 0
  }

  python3 - <<'PY'
from pathlib import Path

path = Path("/etc/ufw/before.rules")
text = path.read_text()

block = """# ejabberd port 80 redirect
*nat
:PREROUTING ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 5280
-A OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-ports 5280
COMMIT
"""

if block not in text:
    raise SystemExit(0)

updated = text.replace("\n" + block + "\n", "\n")
updated = updated.replace(block + "\n", "")
updated = updated.replace("\n" + block, "\n")
updated = updated.replace(block, "")
path.write_text(updated)
PY
}

reload_ufw() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw reload >/dev/null 2>&1 || true
}

teardown_services() {
  info "Stopping and disabling Axichat self-host services"
  stop_disable_unit \
    update-stalwart-cert.timer \
    update-stalwart-cert.service \
    email-glue.service \
    stalwart.service \
    fpush.service \
    ejabberd-acme-redirect.service \
    ejabberd

  if command -v docker >/dev/null 2>&1; then
    docker rm -f stalwart >/dev/null 2>&1 || true
  fi
}

teardown_systemd_units() {
  info "Removing app-specific systemd units and helper binaries"
  remove_file_if_present \
    /etc/systemd/system/stalwart.service \
    /etc/systemd/system/email-glue.service \
    /etc/systemd/system/update-stalwart-cert.service \
    /etc/systemd/system/update-stalwart-cert.timer \
    /etc/systemd/system/fpush.service \
    /etc/systemd/system/ejabberd-acme-redirect.service \
    /usr/local/bin/email-glue \
    /usr/local/bin/sync-ejabberd-cert.sh \
    /usr/local/bin/update-stalwart-cert.sh \
    /usr/local/bin/ejabberdctl \
    /etc/default/stalwart-domain \
    /etc/sysconfig/email-glue \
    /etc/profile.d/ejabberd.sh

  systemctl daemon-reload >/dev/null 2>&1 || true
}

teardown_data() {
  info "Removing local Axichat self-host data and secrets"
  remove_dir_if_present \
    /var/lib/stalwart \
    /var/lib/email-glue \
    /root/stalwart-secrets \
    /opt/fpush \
    /var/lib/fpush \
    /var/lib/ejabberd \
    /var/www/upload \
    /opt/ejabberd \
    "$STATE_DIR"

  remove_file_if_present "$CONFIG_FILE" "$STATE_FILE" "$STATE_JSON"

  if id -u emailglue >/dev/null 2>&1; then
    userdel -r emailglue >/dev/null 2>&1 || userdel emailglue >/dev/null 2>&1 || true
  fi
  if id -u fpush >/dev/null 2>&1; then
    userdel -r fpush >/dev/null 2>&1 || userdel fpush >/dev/null 2>&1 || true
  fi
}

backup_ejabberd_acme_state() {
  if [[ "$CERTS_MODE" != "keep" ]]; then
    remove_dir_if_present "$EJABBERD_ACME_BACKUP_DIR"
    return 0
  fi

  if [[ ! -d "$EJABBERD_ACME_DIR" ]]; then
    remove_dir_if_present "$EJABBERD_ACME_BACKUP_DIR"
    return 0
  fi

  info "Preserving ejabberd ACME account/certificate state"
  remove_dir_if_present "$EJABBERD_ACME_BACKUP_DIR"
  mkdir -p "$(dirname "$EJABBERD_ACME_BACKUP_DIR")"
  cp -a "$EJABBERD_ACME_DIR" "$EJABBERD_ACME_BACKUP_DIR"
}

restore_ejabberd_acme_state() {
  [[ "$CERTS_MODE" == "keep" ]] || return 0
  [[ -d "$EJABBERD_ACME_BACKUP_DIR" ]] || return 0

  info "Restoring ejabberd ACME account/certificate state"
  mkdir -p "$(dirname "$EJABBERD_ACME_DIR")"
  rm -rf "$EJABBERD_ACME_DIR"
  cp -a "$EJABBERD_ACME_BACKUP_DIR" "$EJABBERD_ACME_DIR"
  remove_dir_if_present "$EJABBERD_ACME_BACKUP_DIR"
}

teardown_ejabberd_package() {
  if [[ "$PURGE_EJABBERD_PACKAGE" != "1" ]]; then
    info "Keeping the ejabberd package installed"
    return
  fi

  info "Purging the ejabberd package and apt source entries"
  apt-mark unhold ejabberd >/dev/null 2>&1 || true
  apt-get purge -y ejabberd >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true
  remove_file_if_present \
    /etc/apt/sources.list.d/ejabberd.list \
    /etc/apt/trusted.gpg.d/ejabberd.gpg
  remove_dir_if_present /opt/ejabberd-*
}

teardown_firewall() {
  info "Removing the old ejabberd UFW redirect block if this repo added it"
  remove_ufw_redirect_block
  reload_ufw
}

print_offserver_checklist() {
  cat <<EOF

Off-server uninstall follow-up for ${DOMAIN_HINT}:
1. Delete the Stalwart mail records you added in your DNS provider:
   - MX
   - SPF TXT
   - DMARC TXT at _dmarc.${DOMAIN_HINT}
   - DKIM TXT/CNAME records shown by Stalwart Webadmin
2. Delete any A / AAAA records or XMPP-related records you pointed at this demo server.
3. Remove the PTR / reverse-DNS record in your hosting provider panel.
4. If this is a throwaway demo VPS, the cleanest reset is still deleting the server or reverting a snapshot.

Local uninstall is complete.
Only the off-server DNS and PTR cleanup is still manual.
EOF
}

main() {
  parse_args "$@"
  need_root
  acquire_install_lock
  load_saved_domain_hint
  confirm_teardown
  decide_cert_cleanup

  teardown_services
  backup_ejabberd_acme_state
  teardown_systemd_units
  teardown_data
  teardown_ejabberd_package
  restore_ejabberd_acme_state
  teardown_firewall

  info "Local uninstall is complete"
  print_offserver_checklist
}

main "$@"
