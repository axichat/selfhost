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
- Optional env: `TURN_IPV4=1.2.3.4` to pre-answer the TURN IP prompt
- Interactive prompt: TURN public IPv4 if auto-detection fails

## Manual install outline

This manual path assumes you are intentionally bypassing the wrapper and taking responsibility for the ejabberd-specific steps yourself.

1. Install packages and repo key.

```bash
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg iproute2 \
  socat \
  sqlite3 imagemagick fonts-dejavu-core gsfonts

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
