#!/usr/bin/env bash
set -euo pipefail

# ---- Debian "first 5 minutes" security (SSH key auth) ----
# Examples:
#   sudo ./f5m.sh
#   sudo SSH_USER=deploy SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub ./f5m.sh
#
: "${SSH_PORT:=22}"
: "${SSH_USER:=root}"
: "${SSH_PUBKEY:=}"            # optional: literal public key string
: "${SSH_PUBKEY_FILE:=}"       # optional: path to public key file

need_root() { [[ "${EUID}" -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }; }

user_home() {
  if [[ "$SSH_USER" == "root" ]]; then
    echo "/root"
    return 0
  fi
  getent passwd "$SSH_USER" | cut -d: -f6
}

install_ssh_pubkey() {
  local home_dir
  home_dir="$(user_home)"
  if [[ -z "$home_dir" ]]; then
    echo "ERROR: user not found: ${SSH_USER}"
    exit 1
  fi

  local auth_keys="${home_dir}/.ssh/authorized_keys"
  local key="${SSH_PUBKEY}"
  if [[ -z "$key" && -n "${SSH_PUBKEY_FILE}" ]]; then
    if [[ -f "${SSH_PUBKEY_FILE}" ]]; then
      key="$(cat "${SSH_PUBKEY_FILE}")"
    else
      echo "WARN: SSH_PUBKEY_FILE not found: ${SSH_PUBKEY_FILE}"
    fi
  fi
  if [[ -z "$key" ]]; then
    if [[ -s "$auth_keys" ]]; then
      echo "Using existing SSH public key(s) in ${auth_keys}."
    else
      echo "NOTE: No SSH public key provided and ${auth_keys} is empty/missing. Add one before running ./l5m.sh."
    fi
    return 0
  fi

  install -d -m 0700 -o "$SSH_USER" -g "$SSH_USER" "${home_dir}/.ssh"
  touch "$auth_keys"
  chmod 0600 "$auth_keys"
  chown "$SSH_USER":"$SSH_USER" "$auth_keys"

  if ! grep -Fqx "$key" "$auth_keys"; then
    echo "$key" >> "$auth_keys"
  fi
}

svc_reload() {
  # Debian typically uses "ssh"; some distros use "sshd"
  systemctl reload ssh  >/dev/null 2>&1 && return 0
  systemctl reload sshd >/dev/null 2>&1 && return 0
  return 1
}

svc_restart() {
  systemctl restart ssh  >/dev/null 2>&1 && return 0
  systemctl restart sshd >/dev/null 2>&1 && return 0
  return 1
}

svc_enable_now() {
  systemctl enable --now "$1" >/dev/null 2>&1 || true
}

need_root
export DEBIAN_FRONTEND=noninteractive

echo "[1/6] Packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  ufw fail2ban unattended-upgrades ca-certificates curl gnupg

# Ensure admin binaries under sbin are reachable in future login shells.
cat > /etc/profile.d/10-admin-path.sh <<'EOF'
case ":$PATH:" in
  *:/usr/sbin:*) ;;
  *) export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH" ;;
esac
EOF
chmod 0644 /etc/profile.d/10-admin-path.sh

# Keep ufw reachable even from shells that omit /usr/sbin.
if [[ -x /usr/sbin/ufw ]]; then
  ln -sfn /usr/sbin/ufw /usr/local/bin/ufw
fi

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-storage.conf <<'EOF2'
[Journal]
SystemMaxUse=1G
SystemKeepFree=200M
RuntimeMaxUse=256M
RuntimeKeepFree=50M
EOF2
systemctl restart systemd-journald || true

echo "[2/6] Unattended upgrades"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF2'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF2
# (On Debian, apt systemd timers handle the periodic runs; enabling this service is harmless.)
svc_enable_now unattended-upgrades

echo "[3/6] SSH setup (key auth; keep password auth for now)"
install_ssh_pubkey
install -d -m 0755 /etc/ssh/sshd_config.d
permit_root_login="no"
if [[ "$SSH_USER" == "root" ]]; then
  permit_root_login="prohibit-password"
fi
cat >/etc/ssh/sshd_config.d/99-hardening.conf <<EOF2
# Loaded late (99-*) so it overrides earlier snippets.
PermitRootLogin ${permit_root_login}
PubkeyAuthentication yes
PasswordAuthentication yes

# Allow SSH tunneling/port-forwarding (requested)
AllowTcpForwarding yes
PermitTunnel yes
X11Forwarding no

ClientAliveInterval 300
ClientAliveCountMax 2
EOF2

svc_reload || svc_restart || true

echo "[4/6] UFW firewall: default deny; allow SSH on all interfaces"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow "${SSH_PORT}/tcp"
echo "NOTE: After confirming SSH key access, disable password auth with ./l5m.sh."

ufw --force enable
svc_enable_now ufw

echo "[5/6] fail2ban"
svc_enable_now fail2ban

echo "[6/6] Summary"
echo "Done."
echo "Checks:"
echo "  ufw status verbose"
echo "  systemctl status ssh --no-pager 2>/dev/null || systemctl status sshd --no-pager"
echo
echo "Next: ensure ${SSH_USER} can login with SSH key auth, then run ./l5m.sh to disable password auth."
