# Self-Host Quick Start

This is the easiest way to run the stack on your own Debian server.

It is meant for a single machine that will run:

- `ejabberd` for XMPP/chat
- `Stalwart` for mail
- `email-glue` for the client-facing mail API

By default it keeps message history, allows larger uploads, gives mailboxes unlimited quota, and protects `email-glue` with a client token.

## Why Self-Host

- be independent
- have full control over your own email server
- provide a secure, private way to talk with family and friends
- avoid hosted storage limits
- avoid hosted rate limits
- control your own data
- use your own domain for all your email and XMPP messages

## What You Need

You need:

- a Debian server with `sudo` or root access
- a domain name that points to that server
- control over your provider firewall/security group

Only needed if you want to use `f5m.sh` and `l5m.sh`:

- an SSH public key on your laptop, usually `~/.ssh/id_ed25519.pub`

For this to work, the ports below must be:

- no other service on the machine is already using them
- your provider firewall/security group allows them

Ports:

- `22/tcp` for SSH if you administer the server over SSH
- `80/tcp` for Let's Encrypt
- `5222/tcp`, `5223/tcp`, `5269/tcp`, `5443/tcp` for ejabberd
- `25/tcp`, `465/tcp`, `587/tcp`, `993/tcp` for mail
- `3478/udp` for STUN/TURN

## Fastest Path

If this is a pretty fresh server, do this in order.

1. Copy this repo to the server and enter the self-host directory.

```bash
cd /path/to/production/variants/selfhost
```

2. Decide whether you want `f5m.sh`.

Use `f5m.sh` and later `l5m.sh` only if both are true:

- you are relatively inexperienced with Linux server security
- this is a fresh server dedicated to Axichat

If you already know the basics and/or this server already runs other services, skip `f5m.sh` and `l5m.sh`.

Do not run `f5m.sh` blindly on a shared or already-configured server. It does:

- `ufw --force reset`
- `ufw default deny incoming`
- only re-allows the configured SSH port at that moment

That can break unrelated services until you open their ports again.

If you want to install your SSH key while doing this:

```bash
sudo SSH_USER=root SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub ./f5m.sh
```

If you are already logged in as the final admin user and just want the defaults:

```bash
sudo ./f5m.sh
```

If you skip `f5m.sh`, that is fine. The real setup still works without either `f5m.sh` or `l5m.sh`.

3. If you ran `f5m.sh`, make sure SSH key login works before you continue.

Test a fresh SSH session from your laptop. Do not keep going until it works.

4. Export your domain name in the shell.

```bash
export DOMAIN=example.com
```

5. Install ejabberd.

```bash
cd ejabberd
sudo -E ./install.sh
cd ..
```

If you want the manual ejabberd steps or need more detail, see [`ejabberd/README.md`](ejabberd/README.md).

6. Install Stalwart and `email-glue`.

```bash
cd stalwart
sudo -E ./install.sh --public-token
cd ..
```

If you want the manual Stalwart steps or flag details, see [`stalwart/README.md`](stalwart/README.md).

Notes:

- The Stalwart installer may ask you to create the domain in Stalwart Webadmin.
- It may also ask for the Stalwart Admin API token that `email-glue` uses. This repo calls that the "glue API token".
- If that happens, just follow the tunnel instructions it prints. It already gives you the exact `ssh -L ...` command to run from your laptop.
- To create the glue API token manually in Webadmin: create an API key principal, name it `email-glue`, give it the `admin` role, generate/copy the secret, then either pass it with `--glue-api-token=TOKEN` or paste it when the installer prompts.
- The public `email-glue` client token is separate from the glue API token. By default `stalwart/install.sh` reuses `/root/stalwart-secrets/client_token.txt` or generates a new one. You can set it explicitly with `--public-token=TOKEN`, or disable that requirement with `--no-public-token` if you really intend to expose `8443` without the token gate.
- The Stalwart README has the same Webadmin/API-token flow written out more explicitly if you want it in one place: [`stalwart/README.md`](stalwart/README.md).

Recommended Stalwart invocations:

- Reuse or auto-generate the public client token, and prompt for the glue API token if needed:

```bash
cd stalwart
sudo -E ./install.sh --public-token
cd ..
```

- If you already have the Stalwart Admin API key for `email-glue`:

```bash
cd stalwart
sudo -E ./install.sh --public-token --glue-api-token=TOKEN
cd ..
```

- If you want to pin both tokens explicitly:

```bash
cd stalwart
sudo -E ./install.sh --public-token=CLIENT_TOKEN --glue-api-token=GLUE_API_TOKEN
cd ..
```

7. Optionally run `l5m.sh`.

```bash
sudo ./l5m.sh
```

That disables password SSH login. Only do this if you want these scripts managing your SSH setup.

If you already manage SSH yourself, skip `l5m.sh`.

## What Each Script Is For

- `f5m.sh`: optional first-server hardening for beginners on a fresh Axichat-only host. Installs basic security packages, enables UFW and fail2ban, and keeps password SSH enabled for the first session so you do not lock yourself out too early.
- `ejabberd/install.sh`: installs and configures the XMPP server, requests TLS, sets up upload/captcha/websocket endpoints, and configures the firewall rules it needs on the server.
- `stalwart/install.sh`: installs Stalwart and `email-glue`, writes the service config, and guides you through the Stalwart Webadmin steps if the domain or API token is not ready yet.
- `l5m.sh`: optional final SSH lockdown. Disables password SSH once you know key login works.

## Script Inputs And Options

- `f5m.sh`
- Required: run as `root` or via `sudo`.
- Optional env:
- `SSH_USER`: account that should receive the SSH public key. Default: `root`.
- `SSH_PUBKEY_FILE`: path to a public key file to append to `authorized_keys`.
- `SSH_PUBKEY`: literal public key string to append to `authorized_keys`.
- `SSH_PORT`: SSH port to allow through UFW. Default: `22`.

- `l5m.sh`
- Required: run as `root` or via `sudo`.
- Optional env:
- `SSH_USER`: used to verify that `authorized_keys` exists before disabling password auth. Default: `root`.
- `SSH_PORT`: SSH port to keep allowed in UFW. Default: `22`.

- `ejabberd/install.sh`
- Required env: `DOMAIN=example.com`.
- Optional env:
- `EJABBERD_VERSION_PREFIX`: apt version prefix to install. Default: `26.`.
- Interactive prompts:
- `Enable fpush (XEP-0357) component? [y/N]`
- `Set fpush component secret for push.$DOMAIN` if fpush is enabled
- `Public IPv4 for TURN` if auto-detect fails
- APNS module name, `.p12` path, password, topic, and environment if fpush is enabled

- `stalwart/install.sh`
- Required env: `DOMAIN=example.com`.
- Available flags:
- `--glue-api-token=TOKEN`: supply the Stalwart Admin API key used by `email-glue`.
- `--public-token`: require the public client token for `email-glue`. This is the default behavior.
- `--public-token=TOKEN`: same as `--public-token`, but persist the exact token value you provide.
- `--no-public-token`: disable the public client token requirement. Not recommended on an internet-reachable host.
- Helpful env overrides:
- `STALWART_SSH_HOST`: host/IP shown in SSH tunnel instructions. Default: `$DOMAIN`.
- `STALWART_SSH_USER`: SSH user shown in tunnel instructions. Default: `root`.
- `TUNNEL_LOCAL_PORT`: local port used in SSH tunnel instructions. Default: `18080`.
- `WEBADMIN_REMOTE_PORT`: Stalwart Webadmin/API port on the server. Default: `8080`.
- The Stalwart README documents the glue token flow and the available runtime env keys for `email-glue`: [`stalwart/README.md`](stalwart/README.md).

## Existing Server Notes

This can live alongside other software, but you need to watch port conflicts and firewall rules.

Important limits:

- `f5m.sh` is not friendly to an already-tuned firewall because it resets UFW.
- `ejabberd/install.sh` requires port `80` to be free during setup. It aborts if something is already listening on `80`.
- `ejabberd` needs `5222`, `5223`, `5269`, `5443`, and `3478/udp`.
- `Stalwart` needs `25`, `465`, `587`, `993`, and `8443`.
- Your provider firewall/security group must allow those ports too, or the setup will still fail even if UFW is open on the server.

If some other service is already using those ports, fix that before you run the installers.

If you are adding this to an existing server, the safer path is usually:

1. Skip `f5m.sh`.
2. Review the service ports above.
3. Run the `ejabberd` and `stalwart` installers directly.
4. Adjust your firewall rules yourself.
5. Skip `l5m.sh` unless you specifically want its SSH settings.

## Quick Verify

After both installers finish, make sure the services are up:

```bash
sudo systemctl status ejabberd --no-pager
sudo systemctl status stalwart.service --no-pager
sudo systemctl status email-glue.service --no-pager
```

Quick health checks:

```bash
curl -fsS http://127.0.0.1:8080/healthz/ready
curl -fsS -X POST http://127.0.0.1:5281/api/status -H 'Content-Type: application/json' -d '{}'
curl -sk -H "X-Client-Token: $(sudo cat /root/stalwart-secrets/client_token.txt)" https://127.0.0.1:8443/health
```

If you ran `stalwart/install.sh --no-public-token`, you can omit the `X-Client-Token` header on the `8443` check.

## Where To Look Next

If an installer prompt is unclear or you want the manual steps:

- see [`ejabberd/README.md`](ejabberd/README.md)
- see [`stalwart/README.md`](stalwart/README.md)

## Defaults

This setup uses generous defaults:

- mailbox quota defaults to unlimited
- ejabberd upload limits are much larger
- message history is kept by default instead of being purged automatically
