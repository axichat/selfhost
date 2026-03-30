#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${AXICHAT_SELFHOST_CONFIG_FILE:-/etc/axichat/selfhost.env}"
STATE_DIR="${AXICHAT_SELFHOST_STATE_DIR:-/var/lib/axichat-selfhost}"
STATE_FILE="${STATE_DIR}/state.env"
STATE_JSON="${STATE_DIR}/state.json"
LOCK_FILE="${AXICHAT_SELFHOST_LOCK_FILE:-/run/lock/axichat-selfhost.lock}"

SCHEMA_VERSION=1
CURRENT_PHASE=""
COMPLETED_PHASES=""
DOMAIN=""
NO_EMAIL="0"
PUBLIC_TOKEN=""
GLUE_API_TOKEN=""
ENABLE_FPUSH="0"
TURN_PUBLIC_IP=""
STALWART_SSH_HOST=""
STALWART_SSH_USER="root"
TUNNEL_LOCAL_PORT="18080"
WEBADMIN_REMOTE_PORT="8080"
UPDATED_AT=""

ARG_DOMAIN_SET="0"
ARG_PUBLIC_TOKEN_SET="0"
ARG_GLUE_API_TOKEN_SET="0"
ARG_NO_EMAIL_SET="0"
ARG_ENABLE_FPUSH_SET="0"
ARG_TURN_PUBLIC_IP_SET="0"
ARG_STALWART_SSH_HOST_SET="0"
ARG_STALWART_SSH_USER_SET="0"
ARG_TUNNEL_LOCAL_PORT_SET="0"
ARG_WEBADMIN_REMOTE_PORT_SET="0"
LOCK_FD=""

info() { printf '• %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
section() { printf '\n== %s ==\n' "$*"; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash ./install.sh install --domain example.com --public-token YOUR_TOKEN [options]
  sudo bash ./install.sh install --domain example.com --no-email [options]
  sudo bash ./install.sh upgrade
  sudo bash ./install.sh doctor
  sudo bash ./install.sh verify
  sudo bash ./install.sh help

Most people want one of these:
  sudo bash ./install.sh install --domain example.com --public-token YOUR_TOKEN
  sudo bash ./install.sh install --domain example.com --no-email

If the installer pauses for a browser / DNS / hosting-provider step, keep it
open and follow the instructions it prints. If it gets interrupted, rerun the
same "install" command and it will continue from the saved phase.

Install options:
  --domain DOMAIN                 Required.
  --public-token TOKEN            Required unless --no-email is set.
                                  Shared email-glue client token, not an admin password.
  --no-email                      Skip Stalwart and email-glue.
  --glue-api-token TOKEN          Optional at install time.
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
  flock -n "$LOCK_FD" || die "another install, upgrade, or uninstall is already running.

Wait for it to finish or stop it first, then rerun this command."
  trap release_install_lock EXIT
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
  [[ -f "${ROOT_DIR}/ejabberd/install.sh" ]] || die "missing ejabberd/install.sh"
  [[ -f "${ROOT_DIR}/stalwart/install.sh" ]] || die "missing stalwart/install.sh"
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
  [[ "$(have_public_token && echo 1 || echo 0)" == "1" ]] && public_present=true
  [[ "$(have_glue_api_token && echo 1 || echo 0)" == "1" ]] && glue_present=true

  mkdir -p "$STATE_DIR"
  cat >"$STATE_JSON" <<EOF
{
  "schema_version": ${SCHEMA_VERSION},
  "mode": "$(json_escape "$mode_json")",
  "current_phase": "$(json_escape "$CURRENT_PHASE")",
  "completed_phases": [${completed_json}],
  "domain": "$(json_escape "$DOMAIN")",
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
  mkdir -p "$(dirname "$CONFIG_FILE")"
  (
    umask 077
    {
      write_shell_var "DOMAIN" "$DOMAIN"
      write_shell_var "NO_EMAIL" "$NO_EMAIL"
      write_shell_var "PUBLIC_TOKEN" "$PUBLIC_TOKEN"
      write_shell_var "GLUE_API_TOKEN" "$GLUE_API_TOKEN"
      write_shell_var "ENABLE_FPUSH" "$ENABLE_FPUSH"
      write_shell_var "TURN_PUBLIC_IP" "$TURN_PUBLIC_IP"
      write_shell_var "STALWART_SSH_HOST" "$STALWART_SSH_HOST"
      write_shell_var "STALWART_SSH_USER" "$STALWART_SSH_USER"
      write_shell_var "TUNNEL_LOCAL_PORT" "$TUNNEL_LOCAL_PORT"
      write_shell_var "WEBADMIN_REMOTE_PORT" "$WEBADMIN_REMOTE_PORT"
    } >"$CONFIG_FILE"
  )
  chmod 0600 "$CONFIG_FILE"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "no config file at ${CONFIG_FILE}; run install first"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
}

saved_install_exists() {
  [[ -f "$CONFIG_FILE" || -f "$STATE_FILE" ]]
}

require_saved_install() {
  [[ -f "$CONFIG_FILE" && -f "$STATE_FILE" ]] && return 0
  die "no saved install was found.

Start with one of:
  sudo bash ./install.sh install --domain example.com --public-token YOUR_TOKEN
  sudo bash ./install.sh install --domain example.com --no-email"
}

validate_install_matches_saved_config() {
  local cli_domain="$1"
  local cli_no_email="$2"
  local cli_public_token="$3"
  local cli_glue_api_token="$4"
  local cli_enable_fpush="$5"
  local cli_turn_public_ip="$6"
  local cli_stalwart_ssh_host="$7"
  local cli_stalwart_ssh_user="$8"
  local cli_tunnel_local_port="$9"
  local cli_webadmin_remote_port="${10}"

  if [[ "$ARG_DOMAIN_SET" == "1" && "$cli_domain" != "$DOMAIN" ]]; then
    die "a saved install already exists for domain ${DOMAIN}, not ${cli_domain}.

If you intentionally want to start over from scratch, remove:
  ${CONFIG_FILE}
  ${STATE_DIR}"
  fi
  [[ "$ARG_NO_EMAIL_SET" != "1" || "$cli_no_email" == "$NO_EMAIL" ]] || die "the saved install mode does not match this command"
  [[ "$ARG_PUBLIC_TOKEN_SET" != "1" || "$cli_public_token" == "$PUBLIC_TOKEN" ]] || die "the saved public token does not match this command"
  [[ "$ARG_ENABLE_FPUSH_SET" != "1" || "$cli_enable_fpush" == "$ENABLE_FPUSH" ]] || die "the saved fpush setting does not match this command"
  [[ "$ARG_TURN_PUBLIC_IP_SET" != "1" || "$cli_turn_public_ip" == "$TURN_PUBLIC_IP" ]] || die "the saved TURN public IP does not match this command"
  [[ "$ARG_STALWART_SSH_HOST_SET" != "1" || "$cli_stalwart_ssh_host" == "$STALWART_SSH_HOST" ]] || die "the saved Stalwart SSH host does not match this command"
  [[ "$ARG_STALWART_SSH_USER_SET" != "1" || "$cli_stalwart_ssh_user" == "$STALWART_SSH_USER" ]] || die "the saved Stalwart SSH user does not match this command"
  [[ "$ARG_TUNNEL_LOCAL_PORT_SET" != "1" || "$cli_tunnel_local_port" == "$TUNNEL_LOCAL_PORT" ]] || die "the saved tunnel local port does not match this command"
  [[ "$ARG_WEBADMIN_REMOTE_PORT_SET" != "1" || "$cli_webadmin_remote_port" == "$WEBADMIN_REMOTE_PORT" ]] || die "the saved Webadmin remote port does not match this command"

  if [[ "$ARG_GLUE_API_TOKEN_SET" == "1" ]]; then
    GLUE_API_TOKEN="$cli_glue_api_token"
  fi
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
EOF

  if [[ "$NO_EMAIL" == "0" ]]; then
    cat <<'EOF'
The public token is not your admin password. It is the shared token people will later use when talking to email-glue.
EOF
  fi
}

apply_firewall_rules() {
  local ports_tcp=(5222 5223 5269 5443 80)
  local ports_udp=(3478)
  local port
  local ufw_active="yes"

  if [[ "$NO_EMAIL" == "0" ]]; then
    ports_tcp+=(25 465 587 993 8443)
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    info "UFW is not installed; not changing host firewall rules"
    info "Open the required app ports yourself in your provider firewall or host firewall"
    return 0
  fi

  if ufw status 2>/dev/null | head -n1 | grep -qi "inactive"; then
    ufw_active="no"
  fi
  if [[ "$ufw_active" == "no" ]]; then
    info "UFW is installed but inactive; not enabling it or changing global policy"
    info "Open the required app ports yourself if you want to use UFW"
    return 0
  fi

  info "UFW is active; adding app-specific allow rules only"

  for port in "${ports_tcp[@]}"; do
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  done
  for port in "${ports_udp[@]}"; do
    ufw allow "${port}/udp" >/dev/null 2>&1 || true
  done

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

require_debian() {
  [[ -r /etc/os-release ]] || die "missing /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "this installer is hardcoded for Debian; detected ID=${ID:-unknown}"
}

validate_install_args() {
  [[ -n "$DOMAIN" ]] || die "--domain is required.

Example:
  sudo bash ./install.sh install --domain example.com --public-token your-shared-token"
  [[ "$NO_EMAIL" == "0" || "$NO_EMAIL" == "1" ]] || die "internal error: NO_EMAIL must be 0 or 1"
  [[ "$ENABLE_FPUSH" == "0" || "$ENABLE_FPUSH" == "1" ]] || die "internal error: ENABLE_FPUSH must be 0 or 1"

  if [[ "$NO_EMAIL" == "1" ]]; then
    [[ -z "$PUBLIC_TOKEN" ]] || die "--public-token cannot be used with --no-email"
    [[ -z "$GLUE_API_TOKEN" ]] || die "--glue-api-token cannot be used with --no-email"
  else
    [[ -n "$PUBLIC_TOKEN" ]] || die "--public-token is required unless you pass --no-email.

Examples:
  sudo bash ./install.sh install --domain ${DOMAIN:-example.com} --public-token your-shared-token
  sudo bash ./install.sh install --domain ${DOMAIN:-example.com} --no-email"
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
        ARG_DOMAIN_SET="1"
        shift 2
        ;;
      --domain=*)
        DOMAIN="${1#*=}"
        ARG_DOMAIN_SET="1"
        shift
        ;;
      --public-token)
        [[ $# -ge 2 ]] || die "--public-token requires a value"
        PUBLIC_TOKEN="$2"
        ARG_PUBLIC_TOKEN_SET="1"
        shift 2
        ;;
      --public-token=*)
        PUBLIC_TOKEN="${1#*=}"
        ARG_PUBLIC_TOKEN_SET="1"
        shift
        ;;
      --glue-api-token)
        [[ $# -ge 2 ]] || die "--glue-api-token requires a value"
        GLUE_API_TOKEN="$2"
        ARG_GLUE_API_TOKEN_SET="1"
        shift 2
        ;;
      --glue-api-token=*)
        GLUE_API_TOKEN="${1#*=}"
        ARG_GLUE_API_TOKEN_SET="1"
        shift
        ;;
      --no-email)
        NO_EMAIL="1"
        ARG_NO_EMAIL_SET="1"
        shift
        ;;
      --enable-fpush)
        ENABLE_FPUSH="1"
        ARG_ENABLE_FPUSH_SET="1"
        shift
        ;;
      --turn-public-ip)
        [[ $# -ge 2 ]] || die "--turn-public-ip requires a value"
        TURN_PUBLIC_IP="$2"
        ARG_TURN_PUBLIC_IP_SET="1"
        shift 2
        ;;
      --turn-public-ip=*)
        TURN_PUBLIC_IP="${1#*=}"
        ARG_TURN_PUBLIC_IP_SET="1"
        shift
        ;;
      --stalwart-ssh-host)
        [[ $# -ge 2 ]] || die "--stalwart-ssh-host requires a value"
        STALWART_SSH_HOST="$2"
        ARG_STALWART_SSH_HOST_SET="1"
        shift 2
        ;;
      --stalwart-ssh-host=*)
        STALWART_SSH_HOST="${1#*=}"
        ARG_STALWART_SSH_HOST_SET="1"
        shift
        ;;
      --stalwart-ssh-user)
        [[ $# -ge 2 ]] || die "--stalwart-ssh-user requires a value"
        STALWART_SSH_USER="$2"
        ARG_STALWART_SSH_USER_SET="1"
        shift 2
        ;;
      --stalwart-ssh-user=*)
        STALWART_SSH_USER="${1#*=}"
        ARG_STALWART_SSH_USER_SET="1"
        shift
        ;;
      --tunnel-local-port)
        [[ $# -ge 2 ]] || die "--tunnel-local-port requires a value"
        TUNNEL_LOCAL_PORT="$2"
        ARG_TUNNEL_LOCAL_PORT_SET="1"
        shift 2
        ;;
      --tunnel-local-port=*)
        TUNNEL_LOCAL_PORT="${1#*=}"
        ARG_TUNNEL_LOCAL_PORT_SET="1"
        shift
        ;;
      --webadmin-remote-port)
        [[ $# -ge 2 ]] || die "--webadmin-remote-port requires a value"
        WEBADMIN_REMOTE_PORT="$2"
        ARG_WEBADMIN_REMOTE_PORT_SET="1"
        shift 2
        ;;
      --webadmin-remote-port=*)
        WEBADMIN_REMOTE_PORT="${1#*=}"
        ARG_WEBADMIN_REMOTE_PORT_SET="1"
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
  section "Preflight"
  print_install_overview "Install"
  run_preflight_checks install

  info "Using domain ${DOMAIN}"
  if [[ "$NO_EMAIL" == "1" ]]; then
    info "Email stack is disabled (--no-email)"
  else
    info "Email stack is enabled; your chosen public token was saved for later email-glue use"
  fi
  info "If this install needs browser, DNS, or PTR work, it will stop at that exact step and wait there"
  info "If anything interrupts the install, rerun the same install command"

  append_completed_phase "preflight"
  CURRENT_PHASE="firewall_setup"
  save_state
}

run_upgrade_preflight() {
  need_root
  ensure_repo_layout
  require_debian
  section "Preflight"
  print_install_overview "Upgrade"
  run_preflight_checks upgrade

  info "Re-running the saved configuration against the existing install"
  info "Upgrade mode keeps the saved install state if the rerun fails"
}

run_firewall_phase() {
  CURRENT_PHASE="firewall_setup"
  save_state
  section "Firewall"
  info "Checking whether UFW is already active for app-specific allow rules"
  apply_firewall_rules
  append_completed_phase "firewall_setup"
  CURRENT_PHASE="ejabberd_install"
  save_state
}

run_ejabberd_phase() {
  CURRENT_PHASE="ejabberd_install"
  save_state
  section "ejabberd"
  info "Installing ejabberd"
  info "ejabberd will ask you to choose the XMPP admin password"
  if [[ -n "$TURN_PUBLIC_IP" ]]; then
    info "TURN public IPv4 was preconfigured as ${TURN_PUBLIC_IP}"
  else
    info "If TURN auto-detection fails, the ejabberd installer may ask for the server's public IPv4"
  fi

  local fpush_answer="no"
  [[ "$ENABLE_FPUSH" == "1" ]] && fpush_answer="yes"

  local -a env_args
  env_args=("DOMAIN=$DOMAIN" "ENABLE_FPUSH=$fpush_answer" "SKIP_FIREWALL=1")
  if [[ -n "$TURN_PUBLIC_IP" ]]; then
    env_args+=("TURN_IPV4=$TURN_PUBLIC_IP")
  fi

  env "${env_args[@]}" bash "$ROOT_DIR/ejabberd/install.sh"

  append_completed_phase "ejabberd_install"
  if [[ "$NO_EMAIL" == "1" ]]; then
    CURRENT_PHASE="complete"
  else
    CURRENT_PHASE="stalwart_install"
  fi
  save_state
}

run_stalwart_phase() {
  CURRENT_PHASE="stalwart_install"
  save_state
  section "Stalwart"
  info "Installing Stalwart and email-glue"
  info "If browser work is needed, the install will stop at that exact step and wait for you"

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
  bash "$ROOT_DIR/stalwart/install.sh" "${args[@]}"

  append_completed_phase "stalwart_install"
  save_state
}

run_dns_checkpoint() {
  phase_completed "checkpoint_dns_records" && return 0
  CURRENT_PHASE="checkpoint_dns_records"
  save_state

  section "DNS"
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
  append_completed_phase "checkpoint_dns_records"
  save_state
}

run_reverse_dns_checkpoint() {
  phase_completed "checkpoint_reverse_dns" && return 0
  CURRENT_PHASE="checkpoint_reverse_dns"
  save_state

  local public_ip=""
  public_ip="$(detect_public_ipv4)"
  section "Reverse DNS"
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
  append_completed_phase "checkpoint_reverse_dns"
  save_state
}

finalize_install() {
  CURRENT_PHASE="complete"
  save_state
  section "Done"
  info "Install flow is complete"
  info "Run: sudo bash ./install.sh verify"
  if [[ "$NO_EMAIL" == "0" ]]; then
    info "After DNS and PTR have propagated, run: sudo bash ./install.sh doctor"
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
      info "Skipping the removed host-setup phase from an older installer state"
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
      info "Run: sudo bash ./install.sh verify"
      ;;
    *)
      die "cannot continue from phase ${CURRENT_PHASE}"
      ;;
  esac
}

cmd_install() {
  parse_install_args "$@"
  need_root
  acquire_install_lock

  if saved_install_exists; then
    [[ -f "$CONFIG_FILE" && -f "$STATE_FILE" ]] || die "found partial saved install metadata.

Remove these if you intentionally want to start over:
  ${CONFIG_FILE}
  ${STATE_DIR}"

    local cli_domain="$DOMAIN"
    local cli_no_email="$NO_EMAIL"
    local cli_public_token="$PUBLIC_TOKEN"
    local cli_glue_api_token="$GLUE_API_TOKEN"
    local cli_enable_fpush="$ENABLE_FPUSH"
    local cli_turn_public_ip="$TURN_PUBLIC_IP"
    local cli_stalwart_ssh_host="$STALWART_SSH_HOST"
    local cli_stalwart_ssh_user="$STALWART_SSH_USER"
    local cli_tunnel_local_port="$TUNNEL_LOCAL_PORT"
    local cli_webadmin_remote_port="$WEBADMIN_REMOTE_PORT"

    load_config
    validate_install_matches_saved_config \
      "$cli_domain" \
      "$cli_no_email" \
      "$cli_public_token" \
      "$cli_glue_api_token" \
      "$cli_enable_fpush" \
      "$cli_turn_public_ip" \
      "$cli_stalwart_ssh_host" \
      "$cli_stalwart_ssh_user" \
      "$cli_tunnel_local_port" \
      "$cli_webadmin_remote_port"

    validate_install_args
    load_state
    info "Continuing saved install from phase ${CURRENT_PHASE}"
    save_config
    continue_install_from_state
    return
  fi

  validate_install_args
  save_config

  CURRENT_PHASE="preflight"
  COMPLETED_PHASES=""
  save_state

  continue_install_from_state
}

cmd_upgrade() {
  need_root
  acquire_install_lock
  require_saved_install
  load_config
  load_state

  [[ "$CURRENT_PHASE" == "complete" ]] || die "the saved install is not complete yet.

Rerun the same install command again instead."

  if [[ "$ENABLE_FPUSH" == "1" && ! -f /opt/fpush/settings.json ]]; then
    die "upgrade cannot safely rerun the fpush path because /opt/fpush/settings.json is missing.

Either restore the existing fpush settings first or rerun ejabberd/install.sh manually."
  fi

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

normalize_dns_name() {
  local name="${1:-}"
  name="${name%.}"
  printf '%s\n' "${name,,}"
}

cmd_doctor() {
  need_root
  require_saved_install
  load_config
  load_state

  local failed=0
  local warned=0

  printf 'Config: domain=%s mode=%s phase=%s\n' \
    "$DOMAIN" \
    "$([[ "$NO_EMAIL" == "1" ]] && echo xmpp-only || echo full)" \
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
      local normalized_domain mx_targets mx_targets_normalized ptr_target public_ip
      normalized_domain="$(normalize_dns_name "$DOMAIN")"

      mx_targets="$(dig +short MX "$DOMAIN" | awk '{$1=""; sub(/^ /,""); print $0}')"
      mx_targets_normalized="$(printf '%s\n' "$mx_targets" | while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        normalize_dns_name "$target"
      done)"
      if [[ -z "$mx_targets" ]]; then
        printf 'WARN: MX record not found for %s. Copy the DNS records from Stalwart Webadmin and wait for propagation.\n' "$DOMAIN"
        warned=1
      elif printf '%s\n' "$mx_targets_normalized" | grep -Fxq "$normalized_domain"; then
        printf 'PASS: MX record points to %s\n' "$DOMAIN"
      else
        printf 'WARN: MX records exist for %s, but they do not point to %s. Check the values shown in Stalwart Webadmin.\n' "$DOMAIN" "$DOMAIN"
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

      public_ip="$(detect_public_ipv4)"
      if [[ -n "$public_ip" ]]; then
        ptr_target="$(dig +short -x "$public_ip" | head -n1)"
        if [[ -z "$ptr_target" ]]; then
          printf 'WARN: PTR record not found for %s. Set PTR / reverse DNS in your hosting provider panel, not your normal DNS zone.\n' "$public_ip"
          warned=1
        elif [[ "$(normalize_dns_name "$ptr_target")" == "$normalized_domain" ]]; then
          printf 'PASS: PTR record points to %s\n' "$DOMAIN"
        else
          printf 'WARN: PTR record for %s points to %s, not %s. Fix PTR / reverse DNS in your hosting provider panel.\n' "$public_ip" "$(normalize_dns_name "$ptr_target")" "$DOMAIN"
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
    upgrade)
      cmd_upgrade
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
