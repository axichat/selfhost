#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${AXICHAT_SELFHOST_CONFIG_FILE:-/etc/axichat/selfhost.env}"
STATE_DIR="${AXICHAT_SELFHOST_STATE_DIR:-/var/lib/axichat-selfhost}"
STATE_FILE="${STATE_DIR}/state.env"
STATE_JSON="${STATE_DIR}/state.json"

CHECKPOINT_WEBADMIN_DOMAIN_RC=40
CHECKPOINT_GLUE_API_TOKEN_RC=41

SCHEMA_VERSION=1
MODE=""
CURRENT_PHASE=""
COMPLETED_PHASES=""
DOMAIN=""
NO_EMAIL="0"
PUBLIC_TOKEN=""
GLUE_API_TOKEN=""
PROFILE="existing-server"
SSH_PUBKEY_FILE=""
ENABLE_SSH_LOCKDOWN="0"
SSH_LOCKDOWN_APPLIED="0"
ENABLE_FPUSH="0"
TURN_PUBLIC_IP=""
STALWART_SSH_HOST=""
STALWART_SSH_USER="root"
TUNNEL_LOCAL_PORT="18080"
WEBADMIN_REMOTE_PORT="8080"
PENDING_DNS="0"
PENDING_REVERSE_DNS="0"
UPDATED_AT=""

info() { printf '• %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo ./install.sh install --domain example.com --public-token YOUR_TOKEN [options]
  sudo ./install.sh install --domain example.com --no-email [options]
  sudo ./install.sh upgrade
  sudo ./install.sh doctor
  sudo ./install.sh verify
  sudo ./install.sh help

Most people want one of these:
  sudo ./install.sh install --domain example.com --public-token YOUR_TOKEN
  sudo ./install.sh install --domain example.com --no-email

If the installer pauses for a browser / DNS / hosting-provider step, keep it
open and follow the instructions it prints. If it gets interrupted, rerun the
same "install" command and it will continue from the saved phase.

Install options:
  --domain DOMAIN                 Required.
  --public-token TOKEN            Required unless --no-email is set.
                                  Shared email-glue client token, not an admin password.
  --no-email                      Skip Stalwart and email-glue.
  --glue-api-token TOKEN          Optional at install time.
  --profile fresh-server|existing-server
                                  Default: existing-server.
  --ssh-pubkey-file PATH          Passed to f5m.sh when profile=fresh-server.
  --enable-ssh-lockdown           Run l5m.sh after the install is fully completed.
  --enable-fpush                  Pre-answer the ejabberd installer with fpush enabled.
  --turn-public-ip IP             Pre-answer the ejabberd installer TURN IP prompt.
  --stalwart-ssh-host HOST        Host shown in the Webadmin tunnel instructions.
  --stalwart-ssh-user USER        SSH user shown in the Webadmin tunnel instructions.
  --tunnel-local-port PORT        Local laptop port used in SSH tunnel instructions.
  --webadmin-remote-port PORT     Server-local Stalwart Webadmin port. Default: 8080.
EOF
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root"
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

write_shell_var() {
  local key="$1"
  local value="$2"
  printf '%s=' "$key"
  printf '%q\n' "$value"
}

append_completed_phase() {
  local phase="$1"
  case " ${COMPLETED_PHASES} " in
    *" ${phase} "*) ;;
    *) COMPLETED_PHASES="${COMPLETED_PHASES:+${COMPLETED_PHASES} }${phase}" ;;
  esac
}

phase_completed() {
  local phase="$1"
  case " ${COMPLETED_PHASES} " in
    *" ${phase} "*) return 0 ;;
    *) return 1 ;;
  esac
}

have_public_token() {
  [[ "$NO_EMAIL" == "0" && -n "$PUBLIC_TOKEN" ]]
}

have_glue_api_token() {
  [[ "$NO_EMAIL" == "0" && -n "$GLUE_API_TOKEN" ]]
}

ensure_repo_layout() {
  [[ -x "${ROOT_DIR}/ejabberd/install.sh" ]] || die "missing ejabberd/install.sh"
  [[ -x "${ROOT_DIR}/stalwart/install.sh" ]] || die "missing stalwart/install.sh"
  [[ -x "${ROOT_DIR}/f5m.sh" ]] || die "missing f5m.sh"
  [[ -x "${ROOT_DIR}/l5m.sh" ]] || die "missing l5m.sh"
}

write_state_json() {
  local completed_json=""
  local first=1
  local phase
  for phase in ${COMPLETED_PHASES}; do
    if [[ $first -eq 0 ]]; then
      completed_json+=", "
    fi
    completed_json+="\"$(json_escape "$phase")\""
    first=0
  done

  local mode_json
  if [[ "$NO_EMAIL" == "1" ]]; then
    mode_json="xmpp-only"
  else
    mode_json="full"
  fi

  local public_present=false
  local glue_present=false
  local pending_dns=false
  local pending_reverse_dns=false
  local ssh_lockdown_applied=false
  [[ "$(have_public_token && echo 1 || echo 0)" == "1" ]] && public_present=true
  [[ "$(have_glue_api_token && echo 1 || echo 0)" == "1" ]] && glue_present=true
  [[ "$PENDING_DNS" == "1" ]] && pending_dns=true
  [[ "$PENDING_REVERSE_DNS" == "1" ]] && pending_reverse_dns=true
  [[ "$SSH_LOCKDOWN_APPLIED" == "1" ]] && ssh_lockdown_applied=true

  mkdir -p "$STATE_DIR"
  cat >"$STATE_JSON" <<EOF
{
  "schema_version": ${SCHEMA_VERSION},
  "mode": "$(json_escape "$mode_json")",
  "current_phase": "$(json_escape "$CURRENT_PHASE")",
  "completed_phases": [${completed_json}],
  "domain": "$(json_escape "$DOMAIN")",
  "profile": "$(json_escape "$PROFILE")",
  "pending_dns_records": ${pending_dns},
  "pending_reverse_dns": ${pending_reverse_dns},
  "ssh_lockdown_applied": ${ssh_lockdown_applied},
  "secret_presence": {
    "public_token": ${public_present},
    "glue_api_token": ${glue_present}
  },
  "updated_at": "$(json_escape "$UPDATED_AT")"
}
EOF
  chmod 0600 "$STATE_JSON"
}

save_state() {
  UPDATED_AT="$(now_utc)"
  mkdir -p "$STATE_DIR"
  {
    write_shell_var "SCHEMA_VERSION" "$SCHEMA_VERSION"
    write_shell_var "CURRENT_PHASE" "$CURRENT_PHASE"
    write_shell_var "COMPLETED_PHASES" "$COMPLETED_PHASES"
    write_shell_var "DOMAIN" "$DOMAIN"
    write_shell_var "NO_EMAIL" "$NO_EMAIL"
    write_shell_var "PROFILE" "$PROFILE"
    write_shell_var "PENDING_DNS" "$PENDING_DNS"
    write_shell_var "PENDING_REVERSE_DNS" "$PENDING_REVERSE_DNS"
    write_shell_var "SSH_LOCKDOWN_APPLIED" "$SSH_LOCKDOWN_APPLIED"
    write_shell_var "UPDATED_AT" "$UPDATED_AT"
  } >"$STATE_FILE"
  chmod 0600 "$STATE_FILE"
  write_state_json
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "no state file at ${STATE_FILE}; run install first"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

save_config() {
  umask 077
  mkdir -p "$(dirname "$CONFIG_FILE")"
  {
    write_shell_var "DOMAIN" "$DOMAIN"
    write_shell_var "NO_EMAIL" "$NO_EMAIL"
    write_shell_var "PUBLIC_TOKEN" "$PUBLIC_TOKEN"
    write_shell_var "GLUE_API_TOKEN" "$GLUE_API_TOKEN"
    write_shell_var "PROFILE" "$PROFILE"
    write_shell_var "SSH_PUBKEY_FILE" "$SSH_PUBKEY_FILE"
    write_shell_var "ENABLE_SSH_LOCKDOWN" "$ENABLE_SSH_LOCKDOWN"
    write_shell_var "ENABLE_FPUSH" "$ENABLE_FPUSH"
    write_shell_var "TURN_PUBLIC_IP" "$TURN_PUBLIC_IP"
    write_shell_var "STALWART_SSH_HOST" "$STALWART_SSH_HOST"
    write_shell_var "STALWART_SSH_USER" "$STALWART_SSH_USER"
    write_shell_var "TUNNEL_LOCAL_PORT" "$TUNNEL_LOCAL_PORT"
    write_shell_var "WEBADMIN_REMOTE_PORT" "$WEBADMIN_REMOTE_PORT"
  } >"$CONFIG_FILE"
  chmod 0600 "$CONFIG_FILE"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "no config file at ${CONFIG_FILE}; run install first"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
}

resume_hint() {
  case "$CURRENT_PHASE" in
    checkpoint_webadmin_domain)
      printf 'rerun the same sudo ./install.sh install ... command\n'
      ;;
    checkpoint_glue_api_token)
      printf 'rerun the same sudo ./install.sh install ... command\n'
      ;;
    checkpoint_dns_records)
      printf 'rerun the same sudo ./install.sh install ... command\n'
      ;;
    checkpoint_reverse_dns)
      printf 'rerun the same sudo ./install.sh install ... command\n'
      ;;
    complete)
      printf 'sudo ./install.sh verify\n'
      ;;
    *)
      printf 'rerun the same sudo ./install.sh install ... command\n'
      ;;
  esac
}

print_tunnel_block() {
  local host user local_port remote_port
  host="${STALWART_SSH_HOST:-$DOMAIN}"
  user="${STALWART_SSH_USER:-root}"
  local_port="${TUNNEL_LOCAL_PORT:-18080}"
  remote_port="${WEBADMIN_REMOTE_PORT:-8080}"

  printf '1. On your laptop, start this SSH tunnel:\n'
  printf '   ssh -L %s:127.0.0.1:%s %s@%s\n' "$local_port" "$remote_port" "$user" "$host"
  printf '2. Open this URL in your browser:\n'
  printf '   http://127.0.0.1:%s/login\n' "$local_port"
}

print_saved_progress_block() {
  cat <<EOF
Saved progress:
  Config: ${CONFIG_FILE}
  State:  ${STATE_JSON}
If the script is interrupted, rerun the same install command.
EOF
}

saved_install_exists() {
  [[ -f "$CONFIG_FILE" || -f "$STATE_FILE" ]]
}

require_saved_install() {
  [[ -f "$CONFIG_FILE" && -f "$STATE_FILE" ]] && return 0
  die "no saved install was found.

Start with one of:
  sudo ./install.sh install --domain example.com --public-token YOUR_TOKEN
  sudo ./install.sh install --domain example.com --no-email"
}

load_saved_config_value() {
  local key="$1"
  (
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    case "$key" in
      DOMAIN) printf '%s' "${DOMAIN:-}" ;;
      NO_EMAIL) printf '%s' "${NO_EMAIL:-}" ;;
      PUBLIC_TOKEN) printf '%s' "${PUBLIC_TOKEN:-}" ;;
      PROFILE) printf '%s' "${PROFILE:-}" ;;
      SSH_PUBKEY_FILE) printf '%s' "${SSH_PUBKEY_FILE:-}" ;;
      ENABLE_SSH_LOCKDOWN) printf '%s' "${ENABLE_SSH_LOCKDOWN:-}" ;;
      ENABLE_FPUSH) printf '%s' "${ENABLE_FPUSH:-}" ;;
      TURN_PUBLIC_IP) printf '%s' "${TURN_PUBLIC_IP:-}" ;;
      STALWART_SSH_HOST) printf '%s' "${STALWART_SSH_HOST:-}" ;;
      STALWART_SSH_USER) printf '%s' "${STALWART_SSH_USER:-}" ;;
      TUNNEL_LOCAL_PORT) printf '%s' "${TUNNEL_LOCAL_PORT:-}" ;;
      WEBADMIN_REMOTE_PORT) printf '%s' "${WEBADMIN_REMOTE_PORT:-}" ;;
    esac
  )
}

ensure_install_matches_saved_config() {
  saved_install_exists || return 1
  [[ -f "$CONFIG_FILE" && -f "$STATE_FILE" ]] || die "found partial saved install metadata.

Remove these if you intentionally want to start over:
  ${CONFIG_FILE}
  ${STATE_DIR}"

  local saved_domain saved_no_email saved_public_token saved_profile
  local saved_ssh_pubkey_file saved_enable_ssh_lockdown saved_enable_fpush saved_turn_public_ip
  local saved_stalwart_ssh_host saved_stalwart_ssh_user saved_tunnel_local_port saved_webadmin_remote_port

  saved_domain="$(load_saved_config_value DOMAIN)"
  saved_no_email="$(load_saved_config_value NO_EMAIL)"
  saved_public_token="$(load_saved_config_value PUBLIC_TOKEN)"
  saved_profile="$(load_saved_config_value PROFILE)"
  saved_ssh_pubkey_file="$(load_saved_config_value SSH_PUBKEY_FILE)"
  saved_enable_ssh_lockdown="$(load_saved_config_value ENABLE_SSH_LOCKDOWN)"
  saved_enable_fpush="$(load_saved_config_value ENABLE_FPUSH)"
  saved_turn_public_ip="$(load_saved_config_value TURN_PUBLIC_IP)"
  saved_stalwart_ssh_host="$(load_saved_config_value STALWART_SSH_HOST)"
  saved_stalwart_ssh_user="$(load_saved_config_value STALWART_SSH_USER)"
  saved_tunnel_local_port="$(load_saved_config_value TUNNEL_LOCAL_PORT)"
  saved_webadmin_remote_port="$(load_saved_config_value WEBADMIN_REMOTE_PORT)"

  [[ "$DOMAIN" == "$saved_domain" ]] || die "a saved install already exists for domain ${saved_domain}, not ${DOMAIN}.

If you intentionally want to start over from scratch, remove:
  ${CONFIG_FILE}
  ${STATE_DIR}"
  [[ "$NO_EMAIL" == "$saved_no_email" ]] || die "the saved install mode does not match this command"
  [[ "$PUBLIC_TOKEN" == "$saved_public_token" ]] || die "the saved public token does not match this command"
  [[ "$PROFILE" == "$saved_profile" ]] || die "the saved profile does not match this command"
  [[ "$SSH_PUBKEY_FILE" == "$saved_ssh_pubkey_file" ]] || die "the saved --ssh-pubkey-file does not match this command"
  [[ "$ENABLE_SSH_LOCKDOWN" == "$saved_enable_ssh_lockdown" ]] || die "the saved SSH-lockdown setting does not match this command"
  [[ "$ENABLE_FPUSH" == "$saved_enable_fpush" ]] || die "the saved fpush setting does not match this command"
  [[ "$TURN_PUBLIC_IP" == "$saved_turn_public_ip" ]] || die "the saved TURN public IP does not match this command"
  [[ "$STALWART_SSH_HOST" == "$saved_stalwart_ssh_host" ]] || die "the saved Stalwart SSH host does not match this command"
  [[ "$STALWART_SSH_USER" == "$saved_stalwart_ssh_user" ]] || die "the saved Stalwart SSH user does not match this command"
  [[ "$TUNNEL_LOCAL_PORT" == "$saved_tunnel_local_port" ]] || die "the saved tunnel local port does not match this command"
  [[ "$WEBADMIN_REMOTE_PORT" == "$saved_webadmin_remote_port" ]] || die "the saved Webadmin remote port does not match this command"

  return 0
}

domain_looks_plausible() {
  [[ "$1" == *.* ]] || return 1
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

detect_public_ipv4() {
  curl -4 --max-time 5 -fsS https://api.ipify.org 2>/dev/null || true
}

port_in_use_tcp() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
}

port_in_use_udp() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 1
  ss -lunH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
}

print_install_overview() {
  local heading="${1:-Install}"
  cat <<EOF
${heading} summary:
  Domain:  ${DOMAIN}
  Mode:    $([[ "$NO_EMAIL" == "1" ]] && printf 'xmpp-only (--no-email)' || printf 'full stack (xmpp + email)')
  Profile: ${PROFILE}
  Config:  ${CONFIG_FILE}
  State:   ${STATE_JSON}
EOF

  if [[ "$NO_EMAIL" == "0" ]]; then
    cat <<'EOF'
The public token is not your admin password. It is the shared token people will later use when talking to email-glue.

Later, the script will pause and tell you exactly when to:
  - open Stalwart Webadmin through an SSH tunnel from your laptop
  - copy DNS records from Webadmin into your DNS provider
  - set PTR / reverse DNS in your hosting provider panel
EOF
  else
    cat <<'EOF'
Email is disabled, so the script will only install ejabberd and skip all Stalwart / email steps.
EOF
  fi

  cat <<'EOF'
If the script pauses, keep it open and do the off-server step it printed.
If the script gets interrupted, rerun the same install command.
EOF
}

ensure_ufw_redirect() {
  local before_rules="/etc/ufw/before.rules"
  command -v ufw >/dev/null 2>&1 || die "ufw is required for firewall setup"
  [[ -f "$before_rules" ]] || die "missing ${before_rules}; ufw is not fully installed"

  python3 - <<'PY'
from pathlib import Path

path = Path("/etc/ufw/before.rules")
text = path.read_text()

marker = "# ejabberd port 80 redirect"
if marker in text:
    raise SystemExit(0)

block = """# ejabberd port 80 redirect
*nat
:PREROUTING ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 5280
-A OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-ports 5280
COMMIT
"""

if "*filter" in text:
    head, tail = text.split("*filter", 1)
    new_text = head.rstrip("\n") + "\n\n" + block + "\n*filter" + tail
else:
    new_text = text.rstrip("\n") + "\n\n" + block

path.write_text(new_text)
PY
}

ensure_firewall_dependencies() {
  local packages=()
  command -v python3 >/dev/null 2>&1 || packages+=("python3")
  command -v ufw >/dev/null 2>&1 || packages+=("ufw")

  if [[ ${#packages[@]} -gt 0 ]]; then
    info "Installing firewall dependencies: ${packages[*]}"
    apt-get update -y
    apt-get install -y "${packages[@]}"
  fi
}

detect_ssh_port() {
  local ssh_port=""
  if command -v sshd >/dev/null 2>&1; then
    ssh_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
  fi
  printf '%s\n' "${ssh_port:-22}"
}

apply_firewall_rules() {
  local ports_tcp=(5222 5223 5269 5443 5280 80)
  local ports_udp=(3478)
  local port
  local ssh_port
  local ufw_active="yes"

  if [[ "$NO_EMAIL" == "0" ]]; then
    ports_tcp+=(25 465 587 993 8443)
  fi

  ensure_firewall_dependencies
  if [[ -f /etc/default/ufw ]]; then
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw || true
  fi

  if ufw status 2>/dev/null | head -n1 | grep -qi "inactive"; then
    ufw_active="no"
  fi
  if [[ "$ufw_active" == "no" ]]; then
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
  fi

  ensure_ufw_redirect
  ssh_port="$(detect_ssh_port)"
  info "Preserving SSH access on tcp/${ssh_port}"
  ufw allow "${ssh_port}/tcp" >/dev/null 2>&1 || true

  for port in "${ports_tcp[@]}"; do
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  done
  for port in "${ports_udp[@]}"; do
    ufw allow "${port}/udp" >/dev/null 2>&1 || true
  done

  if [[ "$ufw_active" == "no" ]]; then
    ufw --force enable >/dev/null 2>&1 || true
  fi
  ufw reload >/dev/null 2>&1 || true
}

run_preflight_checks() {
  local mode="${1:-install}"
  local failed=0
  local tcp_ports=(80 5222 5223 5269 5443)
  local udp_ports=(3478)
  local port

  if [[ "$NO_EMAIL" == "0" ]]; then
    tcp_ports+=(25 465 587 993 8443 8080)
  fi

  if ! domain_looks_plausible "$DOMAIN"; then
    die "--domain must look like a real DNS name, for example example.com"
  fi

  if getent hosts "$DOMAIN" >/dev/null 2>&1; then
    local resolved
    resolved="$(getent ahosts "$DOMAIN" | awk '{print $1}' | sort -u | paste -sd ',' - | sed 's/,/, /g')"
    info "Domain ${DOMAIN} resolves on this server: ${resolved}"
  else
    die "${DOMAIN} does not resolve on this server yet.

Set the A / AAAA record first, wait for it to propagate, then rerun install."
  fi

  if [[ "$mode" == "install" ]]; then
    if command -v ss >/dev/null 2>&1; then
      for port in "${tcp_ports[@]}"; do
        if port_in_use_tcp "$port"; then
          warn "TCP port ${port} is already in use on this server"
          failed=1
        fi
      done
      for port in "${udp_ports[@]}"; do
        if port_in_use_udp "$port"; then
          warn "UDP port ${port} is already in use on this server"
          failed=1
        fi
      done
    else
      warn "ss is not installed, so local port-collision checks were skipped"
    fi
  else
    info "Upgrade mode: skipping local port-collision checks because the installed services are expected to already be listening"
  fi

  if [[ "$NO_EMAIL" == "0" ]]; then
    local public_ip
    public_ip="$(detect_public_ipv4)"
    if [[ -n "$public_ip" ]]; then
      info "Detected public IPv4: ${public_ip}"
      info "Later, set PTR / reverse DNS for ${public_ip} to ${DOMAIN}"
    else
      warn "Could not detect the public IPv4 automatically; you will need it later for PTR / reverse DNS"
    fi
  fi

  if [[ "$failed" -ne 0 ]]; then
    die "one or more required ports are already in use.

Stop the conflicting service first, then rerun install."
  fi
}

status_checkpoint_text() {
  case "$CURRENT_PHASE" in
    preflight)
      cat <<EOF
Status: preflight

The installer has started but has not finished its safety checks yet.
Next command:
  $(resume_hint)
EOF
      ;;
    host_setup)
      cat <<EOF
Status: host_setup

The install is in the host-setup phase.
If this phase was interrupted, continue it by rerunning the same install command:
  $(resume_hint)
EOF
      ;;
    firewall_setup)
      cat <<EOF
Status: firewall_setup

The install is applying local firewall and ACME port-forwarding rules.
If this phase was interrupted, continue it by rerunning the same install command:
  $(resume_hint)
EOF
      ;;
    ejabberd_install)
      cat <<EOF
Status: ejabberd_install

The install is at the ejabberd phase.
If ejabberd was interrupted or failed mid-run, continue with:
  $(resume_hint)
EOF
      ;;
    stalwart_install)
      cat <<EOF
Status: stalwart_install

The install is at the Stalwart phase.
If Stalwart was interrupted or failed mid-run, continue with:
  $(resume_hint)
EOF
      ;;
    checkpoint_webadmin_domain)
      cat <<EOF
Status: waiting_for_domain_creation

The install is paused safely. Do this from your laptop, then come back here.

Action required:
$(print_tunnel_block)
3. Keep that tunnel running while you use Webadmin.
4. Login with:
   Username: admin
   Password command: sudo cat /root/stalwart-secrets/fallback_admin_password.txt
5. Go to: Management -> Directory -> Domains
6. Click to create a new domain, then enter exactly:
   ${DOMAIN}
7. Make sure the new domain appears in the list.
8. Resume with:
   $(resume_hint)

$(print_saved_progress_block)
EOF
      ;;
    checkpoint_glue_api_token)
      cat <<EOF
Status: waiting_for_glue_api_token

The install is paused safely. Do this from your laptop, then come back here.

Action required:
$(print_tunnel_block)
3. Keep that tunnel running while you use Webadmin.
4. Login with:
   Username: admin
   Password command: sudo cat /root/stalwart-secrets/fallback_admin_password.txt
5. Create an API key principal:
   Path: Management -> API Keys
   Name: email-glue
   Type: apiKey
   Roles: admin
6. Copy the secret value and save it now. Most admin UIs only show it once.
7. Resume with:
   $(resume_hint)

$(print_saved_progress_block)
EOF
      ;;
    checkpoint_dns_records)
      cat <<EOF
Status: waiting_for_dns_records

The install is paused safely. Do this from your laptop or DNS provider, then come back here.

Action required:
$(print_tunnel_block)
3. Keep that tunnel running while you use Webadmin.
4. Login with:
   Username: admin
   Password command: sudo cat /root/stalwart-secrets/fallback_admin_password.txt
5. Go to: Management -> Directory -> Domains -> ${DOMAIN} -> DNS Records
6. In your DNS provider, create every record Stalwart shows there.
   Use the names and values exactly as shown. Do not invent your own MX / SPF / DMARC / DKIM values.
7. DNS propagation can take time. After you have saved the records in your DNS provider, the install can continue.
8. Resume with:
   $(resume_hint)

$(print_saved_progress_block)
EOF
      ;;
    checkpoint_reverse_dns)
      local public_ip
      public_ip="$(detect_public_ipv4)"
      cat <<EOF
Status: waiting_for_reverse_dns

The install is paused safely. Do this in your hosting provider panel, then come back here.

Action required:
1. In your hosting or VPS provider control panel, find the server's public IPv4${public_ip:+. The installer detected: ${public_ip}}.
2. Look for a setting called PTR, reverse DNS, rDNS, or IP hostname.
3. Set that PTR / reverse-DNS record so the IP points to:
   ${DOMAIN}
4. Make sure the forward A / AAAA record for ${DOMAIN} points back to the same server.
5. Resume with:
   $(resume_hint)

$(print_saved_progress_block)
EOF
      ;;
    complete)
      cat <<EOF
Status: complete

The installer has finished its tracked phases.
Next commands:
  sudo ./install.sh verify
$([[ "$NO_EMAIL" == "0" ]] && printf '  sudo ./install.sh doctor\n')

Saved progress:
  Config: ${CONFIG_FILE}
  State:  ${STATE_JSON}
EOF
      ;;
    *)
      cat <<EOF
Status: ${CURRENT_PHASE}

Next command:
  $(resume_hint)
EOF
      ;;
  esac
}

require_debian() {
  [[ -r /etc/os-release ]] || die "missing /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "this installer is hardcoded for Debian; detected ID=${ID:-unknown}"
}

validate_install_args() {
  [[ -n "$DOMAIN" ]] || die "--domain is required.

Example:
  sudo ./install.sh install --domain example.com --public-token your-shared-token"
  [[ "$PROFILE" == "fresh-server" || "$PROFILE" == "existing-server" ]] || die "--profile must be fresh-server or existing-server"
  [[ "$NO_EMAIL" == "0" || "$NO_EMAIL" == "1" ]] || die "internal error: NO_EMAIL must be 0 or 1"
  [[ "$ENABLE_SSH_LOCKDOWN" == "0" || "$ENABLE_SSH_LOCKDOWN" == "1" ]] || die "internal error: ENABLE_SSH_LOCKDOWN must be 0 or 1"
  [[ "$ENABLE_FPUSH" == "0" || "$ENABLE_FPUSH" == "1" ]] || die "internal error: ENABLE_FPUSH must be 0 or 1"

  if [[ "$NO_EMAIL" == "1" ]]; then
    [[ -z "$PUBLIC_TOKEN" ]] || die "--public-token cannot be used with --no-email"
    [[ -z "$GLUE_API_TOKEN" ]] || die "--glue-api-token cannot be used with --no-email"
  else
    [[ -n "$PUBLIC_TOKEN" ]] || die "--public-token is required unless you pass --no-email.

Examples:
  sudo ./install.sh install --domain ${DOMAIN:-example.com} --public-token your-shared-token
  sudo ./install.sh install --domain ${DOMAIN:-example.com} --no-email"
  fi

  [[ "$DOMAIN" != *$'\n'* ]] || die "--domain must be single-line"
  [[ "$PUBLIC_TOKEN" != *$'\n'* ]] || die "--public-token must be single-line"
  [[ "$GLUE_API_TOKEN" != *$'\n'* ]] || die "--glue-api-token must be single-line"
  [[ "$TURN_PUBLIC_IP" != *$'\n'* ]] || die "--turn-public-ip must be single-line"
  [[ "$TUNNEL_LOCAL_PORT" =~ ^[0-9]+$ ]] || die "--tunnel-local-port must be numeric"
  [[ "$WEBADMIN_REMOTE_PORT" =~ ^[0-9]+$ ]] || die "--webadmin-remote-port must be numeric"

  if [[ "$NO_EMAIL" == "0" && "$PUBLIC_TOKEN" =~ [[:space:]] ]]; then
    warn "the public token contains whitespace; users will need to type it exactly"
  fi

  if [[ -z "$STALWART_SSH_HOST" ]]; then
    STALWART_SSH_HOST="$DOMAIN"
  fi
}

parse_install_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        [[ $# -ge 2 ]] || die "--domain requires a value"
        DOMAIN="$2"
        shift 2
        ;;
      --domain=*)
        DOMAIN="${1#*=}"
        shift
        ;;
      --public-token)
        [[ $# -ge 2 ]] || die "--public-token requires a value"
        PUBLIC_TOKEN="$2"
        shift 2
        ;;
      --public-token=*)
        PUBLIC_TOKEN="${1#*=}"
        shift
        ;;
      --glue-api-token)
        [[ $# -ge 2 ]] || die "--glue-api-token requires a value"
        GLUE_API_TOKEN="$2"
        shift 2
        ;;
      --glue-api-token=*)
        GLUE_API_TOKEN="${1#*=}"
        shift
        ;;
      --no-email)
        NO_EMAIL="1"
        shift
        ;;
      --profile)
        [[ $# -ge 2 ]] || die "--profile requires a value"
        PROFILE="$2"
        shift 2
        ;;
      --profile=*)
        PROFILE="${1#*=}"
        shift
        ;;
      --ssh-pubkey-file)
        [[ $# -ge 2 ]] || die "--ssh-pubkey-file requires a value"
        SSH_PUBKEY_FILE="$2"
        shift 2
        ;;
      --ssh-pubkey-file=*)
        SSH_PUBKEY_FILE="${1#*=}"
        shift
        ;;
      --enable-ssh-lockdown)
        ENABLE_SSH_LOCKDOWN="1"
        shift
        ;;
      --enable-fpush)
        ENABLE_FPUSH="1"
        shift
        ;;
      --turn-public-ip)
        [[ $# -ge 2 ]] || die "--turn-public-ip requires a value"
        TURN_PUBLIC_IP="$2"
        shift 2
        ;;
      --turn-public-ip=*)
        TURN_PUBLIC_IP="${1#*=}"
        shift
        ;;
      --stalwart-ssh-host)
        [[ $# -ge 2 ]] || die "--stalwart-ssh-host requires a value"
        STALWART_SSH_HOST="$2"
        shift 2
        ;;
      --stalwart-ssh-host=*)
        STALWART_SSH_HOST="${1#*=}"
        shift
        ;;
      --stalwart-ssh-user)
        [[ $# -ge 2 ]] || die "--stalwart-ssh-user requires a value"
        STALWART_SSH_USER="$2"
        shift 2
        ;;
      --stalwart-ssh-user=*)
        STALWART_SSH_USER="${1#*=}"
        shift
        ;;
      --tunnel-local-port)
        [[ $# -ge 2 ]] || die "--tunnel-local-port requires a value"
        TUNNEL_LOCAL_PORT="$2"
        shift 2
        ;;
      --tunnel-local-port=*)
        TUNNEL_LOCAL_PORT="${1#*=}"
        shift
        ;;
      --webadmin-remote-port)
        [[ $# -ge 2 ]] || die "--webadmin-remote-port requires a value"
        WEBADMIN_REMOTE_PORT="$2"
        shift 2
        ;;
      --webadmin-remote-port=*)
        WEBADMIN_REMOTE_PORT="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown install option: $1"
        ;;
    esac
  done
}

run_preflight_phase() {
  CURRENT_PHASE="preflight"
  save_state
  need_root
  ensure_repo_layout
  require_debian
  print_install_overview "Install"
  run_preflight_checks install

  info "Using domain ${DOMAIN}"
  if [[ "$NO_EMAIL" == "1" ]]; then
    info "Email stack is disabled (--no-email)"
  else
    info "Email stack is enabled; your chosen public token was saved for later email-glue use"
    info "The script will wait in place and tell you exactly when it needs browser, DNS, or PTR work"
  fi
  info "Progress is saved automatically. If anything interrupts the install, rerun the same install command."

  append_completed_phase "preflight"
  CURRENT_PHASE="host_setup"
  save_state
}

run_upgrade_preflight() {
  need_root
  ensure_repo_layout
  require_debian
  print_install_overview "Upgrade"
  run_preflight_checks upgrade

  info "Re-running the saved configuration against the existing install"
  info "Upgrade mode skips the fresh-server bootstrap wrapper and keeps the saved install state if the rerun fails"
}

run_host_setup_phase() {
  CURRENT_PHASE="host_setup"
  save_state

  if [[ "$PROFILE" == "fresh-server" ]]; then
    info "Running fresh-server host setup via f5m.sh"
    if [[ -n "$SSH_PUBKEY_FILE" ]]; then
      SSH_USER=root SSH_PUBKEY_FILE="$SSH_PUBKEY_FILE" "$ROOT_DIR/f5m.sh"
    else
      SSH_USER=root "$ROOT_DIR/f5m.sh"
    fi
  else
    info "Skipping f5m.sh because profile=existing-server"
  fi

  append_completed_phase "host_setup"
  CURRENT_PHASE="firewall_setup"
  save_state
}

run_firewall_phase() {
  CURRENT_PHASE="firewall_setup"
  save_state
  info "Configuring local firewall rules in the root wrapper"
  info "This opens only the ports required for the selected install mode"
  apply_firewall_rules
  append_completed_phase "firewall_setup"
  CURRENT_PHASE="ejabberd_install"
  save_state
}

run_ejabberd_phase() {
  CURRENT_PHASE="ejabberd_install"
  save_state
  info "Installing ejabberd"
  info "ejabberd will ask you to choose the XMPP admin password"
  if [[ -n "$TURN_PUBLIC_IP" ]]; then
    info "TURN public IPv4 was preconfigured as ${TURN_PUBLIC_IP}"
  else
    info "If TURN auto-detection fails, the ejabberd installer may ask for the server's public IPv4"
  fi

  local fpush_answer="no"
  [[ "$ENABLE_FPUSH" == "1" ]] && fpush_answer="yes"

  if [[ -n "$TURN_PUBLIC_IP" ]]; then
    DOMAIN="$DOMAIN" ENABLE_FPUSH="$fpush_answer" TURN_IPV4="$TURN_PUBLIC_IP" SKIP_FIREWALL="1" SKIP_UFW_REDIRECT="1" "$ROOT_DIR/ejabberd/install.sh"
  else
    DOMAIN="$DOMAIN" ENABLE_FPUSH="$fpush_answer" SKIP_FIREWALL="1" SKIP_UFW_REDIRECT="1" "$ROOT_DIR/ejabberd/install.sh"
  fi

  append_completed_phase "ejabberd_install"
  if [[ "$NO_EMAIL" == "1" ]]; then
    PENDING_DNS="0"
    PENDING_REVERSE_DNS="0"
    CURRENT_PHASE="complete"
  else
    CURRENT_PHASE="stalwart_install"
  fi
  save_state
}

run_stalwart_phase() {
  CURRENT_PHASE="stalwart_install"
  save_state
  info "Installing Stalwart and email-glue"
  info "If Stalwart needs something from your browser, this install will wait for you and then continue"

  local args=("--public-token=${PUBLIC_TOKEN}")
  if [[ -n "$GLUE_API_TOKEN" ]]; then
    args+=("--glue-api-token=${GLUE_API_TOKEN}")
  fi

  DOMAIN="$DOMAIN" \
  STALWART_SSH_HOST="$STALWART_SSH_HOST" \
  STALWART_SSH_USER="$STALWART_SSH_USER" \
  TUNNEL_LOCAL_PORT="$TUNNEL_LOCAL_PORT" \
  WEBADMIN_REMOTE_PORT="$WEBADMIN_REMOTE_PORT" \
  SKIP_FIREWALL="1" \
  SKIP_DNS_GUIDANCE="1" \
  "$ROOT_DIR/stalwart/install.sh" "${args[@]}"

  append_completed_phase "stalwart_install"
  save_state
}

run_dns_checkpoint() {
  phase_completed "checkpoint_dns_records" && return 0
  CURRENT_PHASE="checkpoint_dns_records"
  PENDING_DNS="1"
  save_state

  cat <<EOF

DNS step:
1. Keep the Stalwart SSH tunnel available from your laptop.
2. Open:
   http://127.0.0.1:${TUNNEL_LOCAL_PORT}/login
3. Login with:
   Username: admin
   Password command: sudo cat /root/stalwart-secrets/fallback_admin_password.txt
4. Go to: Management -> Directory -> Domains -> ${DOMAIN} -> DNS Records
5. In your DNS provider, create every record Stalwart shows there.
   Use the names and values exactly as shown.

When you have saved the DNS records in your DNS provider, come back here.
EOF

  read -r -p "Press Enter after the DNS records have been created in your DNS provider..." _
  PENDING_DNS="0"
  append_completed_phase "checkpoint_dns_records"
  save_state
}

run_reverse_dns_checkpoint() {
  phase_completed "checkpoint_reverse_dns" && return 0
  CURRENT_PHASE="checkpoint_reverse_dns"
  PENDING_REVERSE_DNS="1"
  save_state

  local public_ip=""
  public_ip="$(detect_public_ipv4)"
  cat <<EOF

Reverse DNS step:
1. In your hosting or VPS provider panel, find the server's public IPv4${public_ip:+. Detected: ${public_ip}}.
2. Find the PTR / reverse DNS / rDNS setting for that IP.
3. Set the PTR / reverse DNS value to:
   ${DOMAIN}
4. Make sure the forward A / AAAA record for ${DOMAIN} points back to the same server.

When you have saved the PTR / reverse DNS change in your hosting provider, come back here.
EOF

  read -r -p "Press Enter after PTR / reverse DNS has been configured..." _
  PENDING_REVERSE_DNS="0"
  append_completed_phase "checkpoint_reverse_dns"
  save_state
}

run_optional_ssh_lockdown() {
  if [[ "$ENABLE_SSH_LOCKDOWN" == "1" && "$SSH_LOCKDOWN_APPLIED" == "0" ]]; then
    info "Running l5m.sh because --enable-ssh-lockdown was requested"
    "$ROOT_DIR/l5m.sh"
    SSH_LOCKDOWN_APPLIED="1"
  fi
}

finalize_install() {
  PENDING_DNS="0"
  PENDING_REVERSE_DNS="0"
  CURRENT_PHASE="complete"
  run_optional_ssh_lockdown
  save_state
  info "Install flow is complete"
  info "Run: sudo ./install.sh verify"
  if [[ "$NO_EMAIL" == "0" ]]; then
    info "After DNS and PTR have propagated, run: sudo ./install.sh doctor"
  fi
  info "Saved config: ${CONFIG_FILE}"
  info "Saved state:  ${STATE_JSON}"
}

advance_postinstall_checkpoints() {
  if [[ "$NO_EMAIL" == "1" ]]; then
    finalize_install
    return
  fi

  run_dns_checkpoint
  run_reverse_dns_checkpoint

  finalize_install
}

continue_install_from_state() {
  case "$CURRENT_PHASE" in
    preflight)
      run_preflight_phase
      run_host_setup_phase
      run_firewall_phase
      run_ejabberd_phase
      if [[ "$NO_EMAIL" == "1" ]]; then
        finalize_install
      else
        run_stalwart_phase
        advance_postinstall_checkpoints
      fi
      ;;
    host_setup)
      run_host_setup_phase
      run_firewall_phase
      run_ejabberd_phase
      if [[ "$NO_EMAIL" == "1" ]]; then
        finalize_install
      else
        run_stalwart_phase
        advance_postinstall_checkpoints
      fi
      ;;
    firewall_setup)
      run_firewall_phase
      run_ejabberd_phase
      if [[ "$NO_EMAIL" == "1" ]]; then
        finalize_install
      else
        run_stalwart_phase
        advance_postinstall_checkpoints
      fi
      ;;
    ejabberd_install)
      run_ejabberd_phase
      if [[ "$NO_EMAIL" == "1" ]]; then
        finalize_install
      else
        run_stalwart_phase
        advance_postinstall_checkpoints
      fi
      ;;
    checkpoint_webadmin_domain|checkpoint_glue_api_token|stalwart_install)
      run_stalwart_phase
      advance_postinstall_checkpoints
      ;;
    checkpoint_dns_records)
      run_dns_checkpoint
      run_reverse_dns_checkpoint
      finalize_install
      ;;
    checkpoint_reverse_dns)
      run_reverse_dns_checkpoint
      advance_postinstall_checkpoints
      ;;
    complete)
      info "Install is already complete"
      info "Run: sudo ./install.sh verify"
      ;;
    *)
      die "cannot continue from phase ${CURRENT_PHASE}"
      ;;
  esac
}

cmd_install() {
  parse_install_args "$@"
  need_root
  validate_install_args

  if ensure_install_matches_saved_config; then
    load_state
    info "Found saved install state at phase ${CURRENT_PHASE}; continuing the same install command"
    save_config
    continue_install_from_state
    return
  fi

  save_config

  CURRENT_PHASE="preflight"
  COMPLETED_PHASES=""
  PENDING_DNS="0"
  PENDING_REVERSE_DNS="0"
  SSH_LOCKDOWN_APPLIED="0"
  save_state

  continue_install_from_state
}

cmd_resume() {
  die "resume is no longer needed.

Run the same install command again instead, for example:
  sudo ./install.sh install --domain example.com --public-token YOUR_TOKEN"
}

cmd_upgrade() {
  need_root
  require_saved_install
  load_config
  load_state

  [[ "$CURRENT_PHASE" == "complete" ]] || die "the saved install is not complete yet.

Rerun the same install command again instead."

  local backup_state
  local backup_json
  backup_state="$(mktemp)"
  backup_json="$(mktemp)"
  cp "$STATE_FILE" "$backup_state"
  cp "$STATE_JSON" "$backup_json"

  info "Re-running the installed services with the saved configuration"
  if (
    run_upgrade_preflight
    run_firewall_phase
    run_ejabberd_phase
    if [[ "$NO_EMAIL" == "1" ]]; then
      finalize_install
    else
      run_stalwart_phase
      finalize_install
    fi
  ); then
    rm -f "$backup_state" "$backup_json"
    return 0
  fi

  cp "$backup_state" "$STATE_FILE"
  cp "$backup_json" "$STATE_JSON"
  rm -f "$backup_state" "$backup_json"
  info "Upgrade failed; restored the saved install state"
  return 1
}

cmd_status() {
  need_root
  require_saved_install
  load_config
  load_state
  status_checkpoint_text
}

check_active_service() {
  local svc="$1"
  if systemctl is-active --quiet "$svc"; then
    printf 'PASS: service %s is active\n' "$svc"
    return 0
  fi
  printf 'FAIL: service %s is not active\n' "$svc"
  return 1
}

check_http() {
  local label="$1"
  local url="$2"
  shift 2
  if curl -fsS "$@" "$url" >/dev/null 2>&1; then
    printf 'PASS: %s\n' "$label"
    return 0
  fi
  printf 'FAIL: %s\n' "$label"
  return 1
}

cmd_verify() {
  need_root
  require_saved_install
  load_config

  local failed=0

  check_active_service "ejabberd" || failed=1
  check_http "ejabberd local API responds" "http://127.0.0.1:5281/api/status" -X POST -H "Content-Type: application/json" -d '{}' || failed=1

  if [[ "$NO_EMAIL" == "0" ]]; then
    check_active_service "stalwart.service" || failed=1
    check_active_service "email-glue.service" || failed=1
    check_http "Stalwart ready endpoint responds" "http://127.0.0.1:8080/healthz/ready" || failed=1
    check_http "email-glue health responds" "https://127.0.0.1:8443/health" -k -H "X-Client-Token: ${PUBLIC_TOKEN}" || failed=1
  fi

  return "$failed"
}

maybe_dig() {
  command -v dig >/dev/null 2>&1
}

cmd_doctor() {
  need_root
  require_saved_install
  load_config
  load_state

  local failed=0
  local warned=0

  printf 'Config: domain=%s mode=%s profile=%s phase=%s\n' \
    "$DOMAIN" \
    "$([[ "$NO_EMAIL" == "1" ]] && echo xmpp-only || echo full)" \
    "$PROFILE" \
    "$CURRENT_PHASE"

  cmd_verify || failed=1

  if getent hosts "$DOMAIN" >/dev/null 2>&1; then
    printf 'PASS: %s resolves via getent\n' "$DOMAIN"
  else
    printf 'FAIL: %s does not resolve via getent\n' "$DOMAIN"
    failed=1
  fi

  if maybe_dig; then
    if [[ "$NO_EMAIL" == "0" ]]; then
      if dig +short MX "$DOMAIN" | grep -q .; then
        printf 'PASS: MX record exists for %s\n' "$DOMAIN"
      else
        printf 'WARN: MX record not found for %s. Copy the DNS records from Stalwart Webadmin and wait for propagation.\n' "$DOMAIN"
        warned=1
      fi

      if dig +short TXT "$DOMAIN" | grep -q 'v=spf1'; then
        printf 'PASS: SPF record exists for %s\n' "$DOMAIN"
      else
        printf 'WARN: SPF record not found for %s. Copy the DNS records from Stalwart Webadmin and wait for propagation.\n' "$DOMAIN"
        warned=1
      fi

      if dig +short TXT "_dmarc.${DOMAIN}" | grep -q 'v=DMARC1'; then
        printf 'PASS: DMARC record exists for _dmarc.%s\n' "$DOMAIN"
      else
        printf 'WARN: DMARC record not found for _dmarc.%s. Copy the DNS records from Stalwart Webadmin and wait for propagation.\n' "$DOMAIN"
        warned=1
      fi

      local public_ip=""
      public_ip="$(detect_public_ipv4)"
      if [[ -n "$public_ip" ]]; then
        if dig +short -x "$public_ip" | grep -q .; then
          printf 'PASS: PTR record exists for %s\n' "$public_ip"
        else
          printf 'WARN: PTR record not found for %s. Set PTR / reverse DNS in your hosting provider panel, not your normal DNS zone.\n' "$public_ip"
          warned=1
        fi
      else
        printf 'WARN: could not determine the public IPv4 for PTR checking\n'
        warned=1
      fi
    fi
  else
    printf 'WARN: dig is not installed, so DNS-specific checks were skipped. Install dnsutils for richer DNS checks.\n'
    warned=1
  fi

  if [[ "$CURRENT_PHASE" != "complete" ]]; then
        printf 'WARN: install flow is still waiting at phase %s. Rerun the same install command to continue.\n' "$CURRENT_PHASE"
    warned=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    exit 1
  fi
  [[ "$warned" -eq 0 ]] || return 0
}

main() {
  local cmd="${1:-help}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$cmd" in
    install)
      cmd_install "$@"
      ;;
    resume)
      cmd_resume "$@"
      ;;
    upgrade)
      cmd_upgrade
      ;;
    status)
      cmd_status
      ;;
    doctor)
      cmd_doctor
      ;;
    verify)
      cmd_verify
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      die "unknown command: ${cmd}"
      ;;
  esac
}

main "$@"
