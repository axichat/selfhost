![Axichat banner](assets/axichat_banner.png)

* * *

# Self-Host Quick Start

This directory installs the Axichat self-host stack on a Debian server you control.

- Default mode: `ejabberd` + `Stalwart` + `email-glue`
- Opt-out mode: `ejabberd` only with `--no-email`

The public entrypoint is the root [`install.sh`](install.sh).
If you are doing a normal self-host install, start here and stay here. You should not need prior ejabberd or Stalwart knowledge; the script pauses and tells you exactly what to do.
[`ejabberd/README.md`](ejabberd/README.md) and [`stalwart/README.md`](stalwart/README.md) are advanced/manual documents for troubleshooting, recovery, or direct component work.

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
- a domain that already points to the server
- control over your provider firewall / security group
- no other service already using the required ports

Ports you always need available:

- `80/tcp`
- `5222/tcp`, `5223/tcp`, `5269/tcp`, `5443/tcp`
- `3478/udp`

Extra ports if you are not using `--no-email`:

- `25/tcp`, `465/tcp`, `587/tcp`, `993/tcp`, `8443/tcp`

If you enable email, there are real off-server tasks after the server install:

- Stalwart Webadmin over an SSH tunnel
- copying DNS records from Webadmin into your DNS provider
- setting PTR / reverse DNS with your host or provider

PTR / reverse DNS is usually set in your VPS or hosting provider panel, not in your normal DNS zone editor.

For normal installs on common Linux servers (`amd64` and `arm64`), the repo now ships a bundled `email-glue` binary. You do not need Go installed on the server for those cases.

The installer tracks progress in:

- `/etc/axichat/selfhost.env`
- `/var/lib/axichat-selfhost/state.json`

## Install

1. Get this repo onto the server and enter the `selfhost` directory.

On the server, run:

```bash
curl -L https://gitlab.com/axichat/selfhost/-/archive/main/selfhost-main.tar.gz | tar -xzf -
cd selfhost-main
```

If you already have the repo on your laptop and want to upload it manually instead:

```bash
scp -r ./selfhost root@YOUR_SERVER_IP:~
ssh root@YOUR_SERVER_IP
cd ~/selfhost
```

2. Choose one of these entrypoints.

Full stack, recommended:

```bash
sudo ./install.sh install --domain example.com --public-token your-shared-token
```

Choose that public token yourself. It is the client-facing token people will need for `email-glue`, so it should be something you can remember and distribute. It is not your admin password and it is not an SMTP password.

XMPP only:

```bash
sudo ./install.sh install --domain example.com --no-email
```

Fresh dedicated host, with the initial hardening wrapper:

```bash
sudo ./install.sh install \
  --domain example.com \
  --public-token your-shared-token \
  --profile fresh-server \
  --ssh-pubkey-file ~/.ssh/id_ed25519.pub
```

3. Follow the guided checkpoints.

When the installer needs something off-server, it prints the exact steps and then waits for you in the same terminal. In the normal flow, you do not need to open the component readmes.
If the script gets interrupted, rerun the same `install` command and it will continue from the saved phase.

If you later pull a newer version of this repo and want to re-run the installed services with the same saved config, use:

```bash
sudo ./install.sh upgrade
```

`upgrade` re-runs the saved app/service configuration. It does not restart the initial fresh-server bootstrap flow.

Typical email checkpoints:

- create the Stalwart domain in Webadmin
- create the `email-glue` Stalwart API key
- copy DNS records from Webadmin into your DNS provider
- configure PTR / reverse DNS in your hosting provider panel

## Verify

```bash
sudo ./install.sh verify
sudo ./install.sh doctor
```

`verify` checks the local services and health endpoints. `doctor` adds higher-level checks and uses `dig` for DNS checks when it is available.
For email installs, `verify` is the immediate local check and `doctor` is the better follow-up after DNS and PTR have propagated.

For the full flag list, run:

```bash
./install.sh help
```

If you rerun the same `install` command after an interruption, the wrapper continues from the saved phase instead of starting over.

## Component Readmes

- [`ejabberd/README.md`](ejabberd/README.md): advanced/manual ejabberd path, fpush notes, and ejabberd-specific prompts
- [`stalwart/README.md`](stalwart/README.md): advanced/manual Stalwart path, Webadmin/API-key flow, direct script flags, and email-specific verification

Most users should only need those readmes for troubleshooting, manual recovery, or direct component debugging.

## Defaults

- mailbox quota is unlimited
- ejabberd upload limits are large
- message history is kept by default
- new email installs require a user-chosen public client token
