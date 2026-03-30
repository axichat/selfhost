# ejabberd install (advanced / manual)

This is not the normal beginner install path.

Normal self-host usage goes through the root [`../install.sh`](../install.sh):

```bash
sudo ../install.sh install --domain example.com --public-token YOUR_TOKEN
sudo ../install.sh install --domain example.com --no-email
```

If you are following the normal self-host flow, stop here and go back to [`../README.md`](../README.md).

This README is only for direct/manual ejabberd work. This folder has the component installer and the `ejabberd.yml` it writes.

## Prereqs

- Debian host with systemd.
- DNS for your `DOMAIN` points to the server.
- TCP/80 inbound allowed at the provider firewall level too, not just locally.
- You are running as root.
- `DOMAIN` is exported in your shell (for example: `export DOMAIN=example.com`).

## Script inputs and prompts

- Required env: `DOMAIN=example.com`
- Optional env: `EJABBERD_VERSION_PREFIX=26.` to pin the apt version prefix
- Optional env: `ENABLE_FPUSH=yes|no` to pre-answer the fpush prompt
- Optional env: `TURN_IPV4=1.2.3.4` to pre-answer the TURN IP prompt
- Re-run behavior for `fpush`: if `/opt/fpush/settings.json` already exists and its APNS cert path is still valid, reruns reuse the saved fpush secret and APNS settings instead of asking for them again
- Interactive prompt: `Enable fpush (XEP-0357) component? [y/N]`
- Interactive prompt: fpush component secret if you enable fpush
- Interactive prompt: TURN public IPv4 if auto-detection fails
- Interactive prompt: APNS module name, `.p12` path, password, topic, and environment if you enable fpush

## Manual install outline

This manual path assumes you are intentionally bypassing the wrapper and taking responsibility for the ejabberd-specific steps yourself.

1. Install packages and repo key.

```bash
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg iproute2 python3 \
  socat \
  sqlite3 imagemagick fonts-dejavu-core gsfonts \
  git build-essential pkg-config libssl-dev

curl -fsSL -o /etc/apt/sources.list.d/ejabberd.list https://repo.process-one.net/ejabberd.list
curl -fsSL -o /etc/apt/trusted.gpg.d/ejabberd.gpg https://repo.process-one.net/ejabberd.gpg
apt-get update -y
apt-get install -y ejabberd
```

2. Ensure ejabberd directories exist and have correct ownership.

```bash
mkdir -p /opt/ejabberd/conf /opt/ejabberd/database /var/www/upload /var/lib/ejabberd
chown -R ejabberd:ejabberd /opt/ejabberd/database /var/www/upload /var/lib/ejabberd
chmod 750 /opt/ejabberd/database /var/www/upload
```

3. Prepare the config and place it in `/opt/ejabberd/conf/ejabberd.yml`.

- Copy `ejabberd.yml` from this directory.
- If you will use fpush, replace `__FPUSH_COMPONENT_SECRET__`.
- Replace `__TURN_IPV4__` (or disable TURN if you do not have a public IP).
- Set `captcha_cmd` to the installed path, typically `/opt/ejabberd-*/lib/captcha.sh`.

4. Enable and start ejabberd.

```bash
systemctl enable ejabberd
systemctl restart ejabberd
```

5. Install the bundled TCP/80 -> 5280 forwarder for ACME HTTP-01.

```bash
install -m 0644 systemd/ejabberd-acme-redirect.service /etc/systemd/system/ejabberd-acme-redirect.service
systemctl daemon-reload
systemctl enable --now ejabberd-acme-redirect.service
```

If port `80/tcp` is already in use by another service on the host, stop that service first. The forwarder needs to bind port 80 directly.

6. If UFW is already active on the host, add only the ejabberd app ports:

```bash
ufw allow 5222/tcp
ufw allow 5223/tcp
ufw allow 5269/tcp
ufw allow 5443/tcp
ufw allow 80/tcp
ufw allow 3478/udp
ufw reload
```

If UFW is inactive or not installed, this repo does not enable or configure it for you. Open the same ports using your existing firewall approach.

7. Register the admin account.

```bash
ejabberdctl register admin "$DOMAIN" <password>
```

8. Request a TLS certificate via ACME.

```bash
ejabberdctl request-certificate "$DOMAIN"
systemctl restart ejabberd
```

9. Install fpush (optional, APNS only).

If you enable it, the installer builds fpush from source and asks for:
- APNS .p12 path
- APNS topic (bundle id)
- APNS environment (production/sandbox)

On rerun or wrapper-driven `upgrade`, existing fpush installs reuse `/opt/fpush/settings.json` and the referenced APNS certificate file when they are still present. If you delete that file or move the `.p12`, the path becomes interactive again.

If you do this manually, follow the same steps as in `ejabberd/install.sh` under “Installing fpush”.

This is intentionally not part of the normal beginner path because it requires APNS credentials and extra Rust/fpush setup.

## Ports to allow (in your provider firewall)

- 5222/tcp (client STARTTLS)
- 5223/tcp (client TLS)
- 5269/tcp (server-to-server federation)
- 5443/tcp (web admin, websockets, upload, captcha)
- 80/tcp (ACME)
- 3478/udp (STUN/TURN)

Do not expose `5280/tcp` publicly. It is only for the local ACME handler behind the bundled port-80 forwarder.

## Notes

- Federation is enabled by `s2s_access: all` and port 5269.
- Stalwart reuses the ejabberd ACME cert via the cert sync script.
- This setup keeps message history by default. There is no automatic MAM purge timer.
