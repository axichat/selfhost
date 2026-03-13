![Axichat banner](https://raw.githubusercontent.com/axichat/axichat/master/metadata/en-US/images/axichat_banner.png)

* * *

# Self-Host Quick Start

This directory installs the Axichat stack:

- `ejabberd` for XMPP/chat
- `Stalwart` for mail
- `email-glue` for the client-facing mail API

Use this on a Debian server you control. The detailed docs live here:

- [`ejabberd/README.md`](ejabberd/README.md)
- [`stalwart/README.md`](stalwart/README.md)

## Why Self-Host

- be independent
- have full control over your own email server
- provide a secure, private way to talk with family and friends
- avoid hosted storage limits
- avoid hosted rate limits
- control your own data
- use your own domain for all your email and XMPP messages

## Before You Start

- Debian host with `sudo` or root access
- a domain that points to the server
- control over your provider firewall/security group
- no other service already using the required ports

Ports you need available:

- `80/tcp`
- `5222/tcp`, `5223/tcp`, `5269/tcp`, `5443/tcp`
- `25/tcp`, `465/tcp`, `587/tcp`, `993/tcp`
- `3478/udp`

Optional, only if you want `f5m.sh` / `l5m.sh` managing SSH:

- an SSH public key on your laptop, usually `~/.ssh/id_ed25519.pub`

## Install

1. Copy or clone this directory to the server, then enter the `selfhost` directory.

```bash
cd selfhost
```

2. Optional: run `f5m.sh` on a fresh dedicated host.

Skip this if the server already has other services or you already manage SSH/firewall yourself.

```bash
sudo SSH_USER=root SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub ./f5m.sh
```

3. Export your domain.

```bash
export DOMAIN=example.com
```

4. Install ejabberd.

```bash
cd ejabberd
sudo -E ./install.sh
cd ..
```

For ejabberd-specific details, see [`ejabberd/README.md`](ejabberd/README.md).
That README covers installer inputs/prompts, manual installation, and ejabberd-specific ports/notes.

5. Install Stalwart and `email-glue`.

Recommended:

```bash
cd stalwart
sudo -E ./install.sh --public-token
cd ..
```

If you already created the Stalwart Admin API key for `email-glue`:

```bash
cd stalwart
sudo -E ./install.sh --public-token --glue-api-token=TOKEN
cd ..
```

The Stalwart installer may pause for Webadmin steps such as creating the domain or the glue API token.
For Stalwart-specific details, see [`stalwart/README.md`](stalwart/README.md).
That README covers the glue API token flow, the public client token, all flags, env overrides, rerun behavior, and verification.

6. Optional: lock SSH down after you confirm key login works.

```bash
sudo ./l5m.sh
```

## Verify

```bash
sudo systemctl status ejabberd --no-pager
sudo systemctl status stalwart.service --no-pager
sudo systemctl status email-glue.service --no-pager
curl -fsS http://127.0.0.1:8080/healthz/ready
curl -fsS -X POST http://127.0.0.1:5281/api/status -H 'Content-Type: application/json' -d '{}'
curl -sk -H "X-Client-Token: $(sudo cat /root/stalwart-secrets/client_token.txt)" https://127.0.0.1:8443/health
```

If you ran `stalwart/install.sh --no-public-token`, omit the `X-Client-Token` header on the `8443` check.

## More Detail

- For ejabberd setup and manual steps: [`ejabberd/README.md`](ejabberd/README.md)
- For Stalwart, `email-glue`, tokens, flags, and Webadmin steps: [`stalwart/README.md`](stalwart/README.md)

## Defaults

- mailbox quota is unlimited
- ejabberd upload limits are large
- message history is kept by default
- `email-glue` requires a public client token by default
