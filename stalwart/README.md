# Stalwart install (advanced / manual)

This is not the normal beginner install path.

Normal self-host usage goes through the root [`../install.sh`](../install.sh):

```bash
sudo ../install.sh install --domain example.com --public-token YOUR_TOKEN
```

If you are following the normal self-host flow, stop here and go back to [`../README.md`](../README.md).

In that normal root-wrapper flow, the installer waits in the same terminal for the Webadmin, DNS, and PTR steps. If it gets interrupted, rerun the same root `install` command.
That same root wrapper also owns `upgrade`, `verify`, `doctor`, `public-token`, and `uninstall`; this component script is only for direct/manual work.

This README covers direct use of [`./install.sh`](install.sh) and the email-specific details behind that wrapper. The component script still expects `DOMAIN` to be set.

## Prereqs

- Debian host with systemd.
- Run as root.
- `DOMAIN` exported, for example:

```bash
export DOMAIN=example.com
```

- ejabberd already installed on the same host with a valid cert for `DOMAIN` because Stalwart reuses that cert.
- `openssl` available (installer uses it for password hashing and token generation).
- For common server architectures (`amd64` and `arm64`), this repo now ships bundled Linux `email-glue` binaries.
- On other architectures, the script falls back to installing `golang-go` and building `email-glue` on the target host.
- If UFW is already active, the component script adds only the mail-specific UFW allow rules.
- If UFW is inactive or not installed, open the mail ports yourself. This repo does not enable or harden a host firewall for you.

## Direct component command

```bash
./install.sh --public-token=CLIENT_TOKEN
```

Default behavior:

- if you supply `--public-token=CLIENT_TOKEN`, that exact token is persisted for `email-glue`
- if you only pass bare `--public-token`, the component script reuses or generates a client token
- reuses `/root/stalwart-secrets/glue_api_token.txt` when valid
- otherwise pauses and tells you how to create the Stalwart Admin API key that `email-glue` uses
- waits in the same terminal for the Webadmin domain/API-key steps instead of exiting into a separate resume flow

This manual/component script does not enforce the same UX as the root wrapper:

- the root `../install.sh` requires you to choose `--public-token` explicitly unless you use `--no-email`
- the component `./install.sh` can still reuse or auto-generate the client token if you use bare `--public-token` or omit it

Recommended invocations:

- Recommended default:

```bash
./install.sh --public-token=CLIENT_TOKEN
```

- If you already created the Stalwart Admin API key for `email-glue`:

```bash
./install.sh --public-token=CLIENT_TOKEN --glue-api-token=TOKEN
```

- If you want to set both tokens explicitly:

```bash
./install.sh --public-token=CLIENT_TOKEN --glue-api-token=GLUE_API_TOKEN
```

## Flags

```bash
./install.sh [--public-token[=TOKEN]] [--no-public-token] [--glue-api-token=TOKEN]
```

- `--public-token`
  Requires `X-Client-Token` / `X-Auth-Token` for `email-glue`.
  This is the default if you omit the flag.
  Reuses `/root/stalwart-secrets/client_token.txt` if present, otherwise generates one.
  This is mainly for direct/manual component use; the root `../install.sh` flow expects you to choose the token explicitly.

- `--public-token=TOKEN`
  Same as `--public-token`, but persists the exact token value you provide to `/root/stalwart-secrets/client_token.txt`.

- `--no-public-token`
  Disables the public client-token requirement.
  Only do this if `8443` is not internet-reachable or you intentionally want that behavior.

- `--glue-api-token=TOKEN`
  Uses and persists this Stalwart Admin API key for `email-glue`.
  Without this flag, installer reuses `/root/stalwart-secrets/glue_api_token.txt` when valid.
  If the file is missing or invalid, the installer pauses and tells you how to create a new one in Webadmin.

## Stalwart Webadmin token flow

There are two different tokens in this setup:

- Glue API token:
  This is the Stalwart Admin API key that `email-glue` uses to create/delete/change mail users.
  It is stored at `/root/stalwart-secrets/glue_api_token.txt`.
  You can supply it up front with `--glue-api-token=TOKEN`, or create it in Webadmin when prompted.

- Public client token:
  This is the token remote clients send as `X-Client-Token` or `X-Auth-Token` to reach `email-glue` on `https://host:8443`.
  It is stored at `/root/stalwart-secrets/client_token.txt`.
  In the direct component flow it is enabled by default and either reused or generated automatically.
  In the normal root-wrapper flow you are expected to choose it explicitly.

If you need to create the glue API token manually, do this:

1. Run the installer until it prints the SSH tunnel command.
2. From another machine or in another terminal, start the tunnel it shows, or keep using the existing tunnel if it is still open.
3. If you are not already in Webadmin, open `http://127.0.0.1:18080/login` or the tunneled port it printed.
4. If you are not already logged in, login as `admin` with the fallback password the installer printed or stored in `/root/stalwart-secrets/fallback_admin_password.txt`.
5. Create an API key principal with these values:
   - Type: `apiKey`
   - Name: `email-glue`
   - Roles: `admin`
6. Open the `Authentication` tab and copy the secret value shown there before you save changes. It will not be shown again afterward.
7. Save changes.
8. Either paste that secret when the installer prompts, or rerun with `--glue-api-token=TOKEN`.

## DNS records from Webadmin

For the normal guided setup, use `DOMAIN` itself as the mail host. You do not need `mail.DOMAIN` records unless you intentionally want MX to point there instead.

Start with the required mail records:

- MX
- DKIM
- DMARC
- the SPF TXT record for `DOMAIN` itself

Optional records can be added later:

- TLSA / DANE
- SRV / autoconfig / autodiscover
- MTA-STS, TLS-RPT, and similar convenience/security records

SPF rule:

- publish at most one SPF TXT record per hostname
- the one you should always publish first is the SPF TXT for `DOMAIN` itself
- if Stalwart shows multiple SPF TXT rows for the same hostname, merge them into one SPF TXT record
- example: merge `v=spf1 a ra=postmaster -all` and `v=spf1 mx ra=postmaster -all` into `v=spf1 a mx ra=postmaster -all`
- only add another SPF TXT if it is for a different hostname that you intentionally use

## Installer environment overrides

These affect the Webadmin tunnel instructions printed by `install.sh`:

- `STALWART_SSH_HOST`
  Hostname/IP shown in the SSH tunnel command.
  Default: `$DOMAIN`

- `STALWART_SSH_USER`
  SSH user shown in the tunnel command.
  Default: `root`

- `TUNNEL_LOCAL_PORT`
  Local port used in the tunnel instructions.
  Default: `18080`

- `WEBADMIN_REMOTE_PORT`
  Remote Stalwart Webadmin/API port on the server.
  Default: `8080`

## email-glue runtime environment

`install.sh` writes `/etc/sysconfig/email-glue`. The service also supports these keys there if you want to adjust them later:

- `EMAIL_DOMAIN`
- `STALWART_API`
- `STALWART_API_TOKEN`
- `EMAIL_GLUE_DEFAULT_QUOTA_BYTES`
- `EMAIL_GLUE_LISTEN`
- `EMAIL_GLUE_CERT_FILE`
- `EMAIL_GLUE_KEY_FILE`
- `EMAIL_GLUE_REQUIRE_CLIENT_TOKEN`
- `EMAIL_GLUE_CLIENT_TOKEN`
- `EMAIL_GLUE_CLIENT_TOKEN_FILE`

Defaults used by the installer/runtime:

- `STALWART_API=http://127.0.0.1:8080/api`
- `EMAIL_GLUE_DEFAULT_QUOTA_BYTES=0`
- `EMAIL_GLUE_LISTEN=0.0.0.0:8443`
- `EMAIL_GLUE_CERT_FILE=/var/lib/stalwart/certs/$DOMAIN.fullchain.pem`
- `EMAIL_GLUE_KEY_FILE=/var/lib/stalwart/certs/$DOMAIN.privkey.pem`

## Build and packaging note

- This repo now ships bundled `email-glue` binaries for `linux/amd64` and `linux/arm64`.
- `stalwart/install.sh` installs the bundled binary when one matches the server architecture.
- On unsupported architectures, `stalwart/install.sh` falls back to installing `golang-go` and running `go build` on the target host.
- If you are using the normal guided flow, the root wrapper still ends up using this same component behavior underneath.

## Re-run behavior

- Re-running does not wipe Stalwart data (`/var/lib/stalwart/data`).
- Installer rewrites config/unit/env files and restarts services.
- `email-glue` is restarted, so updated token settings apply immediately.
- Domain creation and DNS records are handled in Webadmin. If the domain does not exist yet, the installer pauses and tells you what to do.
- In the normal root-wrapper flow, `sudo bash ./install.sh upgrade` reuses the saved wrapper config and re-runs this component underneath.

## Key files written

- `/root/stalwart-secrets/fallback_admin_password.txt`
- `/root/stalwart-secrets/glue_api_token.txt`
- `/root/stalwart-secrets/client_token.txt` when the public token is enabled
- `/etc/sysconfig/email-glue`

## Quick verification

```bash
systemctl status stalwart.service --no-pager
systemctl status email-glue.service --no-pager
curl -fsS http://127.0.0.1:8080/healthz/ready
curl -sk -H "X-Client-Token: $(sudo cat /root/stalwart-secrets/client_token.txt)" https://127.0.0.1:8443/health
```

If you ran `./install.sh --no-public-token`, omit the `X-Client-Token` header on the `8443` check.

## Notes

- Stalwart runs in Docker via `systemd/stalwart.service`.
- `email-glue` uses cert/key from `/var/lib/stalwart/certs`.
- Mailboxes default to unlimited quota because this setup sets `EMAIL_GLUE_DEFAULT_QUOTA_BYTES=0`.
- DNS records are managed from Stalwart Webadmin in this workflow.
