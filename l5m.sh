#!/usr/bin/env bash
set -euo pipefail

: "${SSH_PORT:=22}"
: "${SSH_USER:=root}"

need_root() { [[ "${EUID}" -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }; }

need_root

SSHD_CFG="/etc/ssh/sshd_config.d/99-hardening.conf"
if [[ ! -f "$SSHD_CFG" ]]; then
  touch "$SSHD_CFG"
  chmod 0644 "$SSHD_CFG"
fi

user_home() {
  if [[ "$SSH_USER" == "root" ]]; then
    echo "/root"
    return 0
  fi
  getent passwd "$SSH_USER" | cut -d: -f6
}

home_dir="$(user_home)"
if [[ -z "$home_dir" ]]; then
  echo "ERROR: user not found: ${SSH_USER}" >&2
  exit 1
fi

auth_keys="${home_dir}/.ssh/authorized_keys"
if [[ ! -s "$auth_keys" ]]; then
  echo "ERROR: ${auth_keys} is missing or empty. Add an SSH key before locking down." >&2
  exit 1
fi

set_sshd_kv() {
  local key="$1"
  local value="$2"
  if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$SSHD_CFG"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$SSHD_CFG"
  else
    echo "${key} ${value}" >> "$SSHD_CFG"
  fi
}

set_sshd_kv "PasswordAuthentication" "no"
set_sshd_kv "KbdInteractiveAuthentication" "no"
set_sshd_kv "ChallengeResponseAuthentication" "no"
set_sshd_kv "PubkeyAuthentication" "yes"

if [[ "$SSH_USER" == "root" ]]; then
  set_sshd_kv "PermitRootLogin" "prohibit-password"
else
  set_sshd_kv "PermitRootLogin" "no"
fi

ufw allow "${SSH_PORT}/tcp" || true

systemctl reload ssh || systemctl restart ssh

echo "Lockdown complete. SSH key auth required; password auth disabled."
