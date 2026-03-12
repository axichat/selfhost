# ejabberd install (manual steps)

This folder has the `ejabberd` installer and the `ejabberd.yml` it writes. If the script fits your setup, use it. If you want to do it by hand, the outline below is the rough path.

## Prereqs

- Debian host with systemd.
- DNS for your `DOMAIN` points to the server.
- TCP/80 inbound allowed at the provider firewall level too, not just locally.
- You are running as root.
- `DOMAIN` is exported in your shell (for example: `export DOMAIN=example.com`).

## Script inputs and prompts

- Required env: `DOMAIN=example.com`
- Optional env: `EJABBERD_VERSION_PREFIX=26.` to pin the apt version prefix
- Interactive prompts:
- `Enable fpush (XEP-0357) component? [y/N]`
- fpush component secret if you enable fpush
- TURN public IPv4 if auto-detection fails
- APNS module name, `.p12` path, password, topic, and environment if you enable fpush

## Manual install outline

Run `./f5m.sh` first only if you actually want it. Otherwise just do the steps below.

1) Install packages and repo key.

```bash
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg iproute2 python3 ufw \
  sqlite3 imagemagick fonts-dejavu-core gsfonts \
  git build-essential pkg-config libssl-dev

curl -fsSL -o /etc/apt/sources.list.d/ejabberd.list https://repo.process-one.net/ejabberd.list
curl -fsSL -o /etc/apt/trusted.gpg.d/ejabberd.gpg https://repo.process-one.net/ejabberd.gpg
apt-get update -y
apt-get install -y ejabberd
```

2) Ensure ejabberd directories exist and have correct ownership.

```bash
mkdir -p /opt/ejabberd/conf /opt/ejabberd/database /var/www/upload /var/lib/ejabberd
chown -R ejabberd:ejabberd /opt/ejabberd/database /var/www/upload /var/lib/ejabberd
chmod 750 /opt/ejabberd/database /var/www/upload
```

3) Prepare the config and place it in `/opt/ejabberd/conf/ejabberd.yml`.

- Copy `ejabberd.yml` from this directory.
- If you will use fpush, replace `__FPUSH_COMPONENT_SECRET__`.
- Replace `__TURN_IPV4__` (or disable TURN if you do not have a public IP).
- Set `captcha_cmd` to the installed path, typically:
  - `/opt/ejabberd/lib/ejabberd-*/priv/bin/captcha.sh`

4) Enable and start ejabberd.

```bash
systemctl enable ejabberd
systemctl restart ejabberd
```

5) Forward TCP/80 to 5280 (ACME HTTP-01) via UFW NAT.

```bash
sudo python3 - <<'PY'
from pathlib import Path

path = Path("/etc/ufw/before.rules")
text = path.read_text()
marker = "# ejabberd port 80 redirect"
if marker not in text:
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
        text = head.rstrip("\n") + "\n\n" + block + "\n*filter" + tail
    else:
        text = text.rstrip("\n") + "\n\n" + block
    path.write_text(text)
PY
ufw reload
```

6) UFW firewall (same approach as stalwart):

```bash
if [[ -f /etc/default/ufw ]]; then
  sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
fi
ufw default deny incoming
ufw default allow outgoing
ufw allow 5222/tcp
ufw allow 5223/tcp
ufw allow 5269/tcp
ufw allow 5443/tcp
ufw allow 5280/tcp
ufw allow 80/tcp
ufw allow 3478/udp
ufw --force enable
ufw reload
```

7) Register the admin account.

```bash
ejabberdctl register admin "$DOMAIN" <password>
```

8) Request a TLS certificate via ACME.

```bash
ejabberdctl request-certificate "$DOMAIN"
systemctl restart ejabberd
```

9) Install fpush (optional, APNS only).

If you enable it, the installer builds fpush from source and asks for:
- APNS .p12 path
- APNS topic (bundle id)
- APNS environment (production/sandbox)

If you do this manually, follow the same steps as in `ejabberd/install.sh` under “Installing fpush”.

## Ports to allow (in your provider firewall)

- 5222/tcp (client STARTTLS)
- 5223/tcp (client TLS)
- 5269/tcp (server-to-server federation)
- 5443/tcp (web admin, websockets, upload, captcha)
- 80/tcp (ACME)
- 3478/udp (STUN/TURN)
## Notes

- Federation is enabled by `s2s_access: all` and port 5269.
- Stalwart reuses the ejabberd ACME cert via the cert sync script.
- This setup keeps message history by default. There is no automatic MAM purge timer.
