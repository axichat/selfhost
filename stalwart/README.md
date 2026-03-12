# Stalwart install

This folder installs Stalwart and `email-glue`. The main entry point is `install.sh`, and it expects `DOMAIN` to be set.

## Prereqs

- Debian host with systemd.
- Run as root.
- `DOMAIN` exported, for example:

```bash
export DOMAIN=example.com
```

- ejabberd already installed on the same host with a valid cert for `DOMAIN` because Stalwart reuses that cert.
- `openssl` available (installer uses it for password hashing and token generation).

## Quick command

```bash
./install.sh --public-token
```

Default behavior:

- reuses or generates a public client token for `email-glue`
- reuses `/root/stalwart-secrets/glue_api_token.txt` when valid
- otherwise pauses and tells you how to create the Stalwart Admin API key that `email-glue` uses

Recommended invocations:

- Recommended default:

```bash
./install.sh --public-token
```

- If you already created the Stalwart Admin API key for `email-glue`:

```bash
./install.sh --public-token --glue-api-token=TOKEN
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
- Requires `X-Client-Token` / `X-Auth-Token` for `email-glue`.
- This is the default if you omit the flag.
- Reuses `/root/stalwart-secrets/client_token.txt` if present, otherwise generates one.

- `--public-token=TOKEN`
- Same as `--public-token`, but persists the exact token value you provide to `/root/stalwart-secrets/client_token.txt`.

- `--no-public-token`
- Disables the public client-token requirement.
- Only do this if `8443` is not internet-reachable or you intentionally want that behavior.

- `--glue-api-token=TOKEN`
- Uses and persists this Stalwart Admin API key for `email-glue`.
- Without this flag, installer reuses `/root/stalwart-secrets/glue_api_token.txt` when valid.
- If the file is missing or invalid, the installer pauses and tells you how to create a new one in Webadmin.

## Stalwart Webadmin token flow

There are two different tokens in this setup:

- Glue API token:
- This is the Stalwart Admin API key that `email-glue` uses to create/delete/change mail users.
- It is stored at `/root/stalwart-secrets/glue_api_token.txt`.
- You can supply it up front with `--glue-api-token=TOKEN`, or create it in Webadmin when prompted.

- Public client token:
- This is the token remote clients send as `X-Client-Token` or `X-Auth-Token` to reach `email-glue` on `https://host:8443`.
- It is stored at `/root/stalwart-secrets/client_token.txt`.
- By default it is enabled and either reused or generated automatically.

If you need to create the glue API token manually, do this:

1. Run the installer until it prints the SSH tunnel command.
2. From your laptop, start the tunnel it shows.
3. Open `http://127.0.0.1:18080/login` or the tunneled port it printed.
4. Login as `admin` with the fallback password the installer printed or stored in `/root/stalwart-secrets/fallback_admin_password.txt`.
5. Create an API key principal:
6. Type: `apiKey`
7. Name: `email-glue`
8. Roles: `admin`
9. Generate/copy the secret value.
10. Either paste that secret when the installer prompts, or rerun with `--glue-api-token=TOKEN`.

## Installer environment overrides

These affect the Webadmin tunnel instructions printed by `install.sh`:

- `STALWART_SSH_HOST`
- Hostname/IP shown in the SSH tunnel command.
- Default: `$DOMAIN`

- `STALWART_SSH_USER`
- SSH user shown in the tunnel command.
- Default: `root`

- `TUNNEL_LOCAL_PORT`
- Local port on your laptop used in the tunnel instructions.
- Default: `18080`

- `WEBADMIN_REMOTE_PORT`
- Remote Stalwart Webadmin/API port on the server.
- Default: `8080`

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

## Re-run behavior

- Re-running does not wipe Stalwart data (`/var/lib/stalwart/data`).
- Installer rewrites config/unit/env files and restarts services.
- `email-glue` is restarted, so updated token settings apply immediately.
- Domain creation and DNS records are handled in Webadmin. If the domain does not exist yet, the installer pauses and tells you what to do.

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
