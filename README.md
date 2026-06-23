![Axichat banner](https://axichat.github.io/axichat/readme-media/axichat_banner.png)

# Axichat Self-Host

- Just run the install script.
- When it needs something done outside the server, it stops and tells you what to do.
- If the installer gets interrupted, just re-run the same install command and it will resume.

## Watch First

- We recommend you watch this guide before you start:

  <p align="center">
    <a href="https://youtu.be/szR-YuDeMOM">
      <img
        src="assets/youtube/axichat-selfhost-tutorial-thumbnail.png"
        alt="Watch the Axichat self-host tutorial on YouTube"
        width="720"
      />
    </a>
  </p>

## You Need

- Debian server, fresh install, root access.
- Your own domain with the A / AAAA record pointed at your server IP.
- If you want email, which is recommended, your VPS provider must allow mail traffic on `25/tcp`.
- [Netcup is a good option if you need a port-25-friendly VPS.](https://github.com/axichat/selfhost/issues/new?template=netcup-voucher.yml&title=Netcup%20voucher%20request)

## Install

> [!TIP]
> Replace `example.com` with your domain.
> Run as root. If you are already logged in as root, omit `sudo`.

> [!NOTE]
> If `curl` is missing on your fresh Debian server, run `apt-get update && apt-get install -y curl ca-certificates` first.

- For chat and email, run this on the server:

  ```bash
  curl -L https://gitlab.com/axichat/selfhost/-/archive/main/selfhost-main.tar.gz | tar -xzf -
  cd selfhost-main
  sudo bash ./install.sh install --domain example.com --public-token your-shared-token
  ```

- `--public-token` is required for email installs.
- Choose `your-shared-token` yourself.
- Do not use an admin password as the public token.
- Treat it like a shared invite code, not like public text to post online.
- It is for mitigating crawlers and unwanted registrations.
- You must give it to everyone who should be able to sign up so they can enter it in the app.

- For chat only, run this instead:

  ```bash
  curl -L https://gitlab.com/axichat/selfhost/-/archive/main/selfhost-main.tar.gz | tar -xzf -
  cd selfhost-main
  sudo bash ./install.sh install --domain example.com --no-email
  ```

- Then just follow the prompts.

## What The Installer Walks You Through

- Domain checks.
- Local port-collision checks.
- UFW rules, if UFW is already active.
- VPS firewall guidance, if you still need to open ports outside the server.
- ejabberd admin password setup.
- Let's Encrypt TLS certificate setup.
- Stalwart Webadmin domain and API-key steps for email.
- Stalwart webhook setup for Android mail notifications.
- DNS records for email.
- PTR / reverse DNS for email.
- Verification after install.

## What You Get With Chat And Email

- Instant messaging (XMPP from ejabberd).
- Email (SMTP/IMAP from Stalwart).
- File attachments.
- Android mail notification hints through XMPP.
- No iOS push for self-hosters yet.

## If You Already Have The Repo Locally

- Upload it:

  ```bash
  scp -r ./selfhost root@YOUR_SERVER_IP:~
  ```

- SSH into the server:

  ```bash
  ssh root@YOUR_SERVER_IP
  ```

- Run the installer:

  ```bash
  cd ~/selfhost
  sudo bash ./install.sh install --domain example.com --public-token your-shared-token
  ```

## Verify

- Check local services:

  ```bash
  sudo bash ./install.sh verify
  ```

- Check DNS, PTR, and higher-level health:

  ```bash
  sudo bash ./install.sh doctor
  ```

- Run `verify` right after install.
- Run `doctor` after DNS and PTR have had time to propagate.
- `doctor` checks DNS details when `dig` is installed.

## Upgrade

- Pull the newer repo version.
- Then just run:

  ```bash
  sudo bash ./install.sh upgrade
  ```

- `upgrade` reuses your saved install config.
- `upgrade` does not start over from scratch.
- Do not rerun `install` after a completed install; it will only tell you the saved install is complete.

## Public Token

- Public-token commands only apply to email installs.

- Show the token clients should enter:

  ```bash
  sudo bash ./install.sh public-token show
  ```

- Change it without reinstalling:

  ```bash
  sudo bash ./install.sh public-token set new-shared-token
  ```

- `public-token set` updates the saved config.
- It also updates the email service.
- If the email service is already installed, it restarts it.

## Uninstall Or Start Over

- Remove the local Axichat install:

  ```bash
  sudo bash ./uninstall.sh --yes
  ```

- The uninstall removes the local app stack.
- It prints the DNS and PTR cleanup you still need to do outside the server.
- Keep ejabberd ACME certificate state if you plan to reinstall on the same server.
- Purge cert state only when you want a cleaner reset.
- `--yes` skips the uninstall confirmation, but cert cleanup still asks unless you pass `--keep-certs` or `--purge-certs`.
- See every uninstall flag:

  ```bash
  bash ./uninstall.sh help
  ```

## Mail Notifications

- Email installs enable Android mail notification hints by default.
- Stalwart sends new-mail events into the Axichat email bridge.
- The bridge sends an XMPP marker from `mail-notify@DOMAIN`.
- A connected Android client treats that marker as an email sync and local notification hint.
- This does not use `fpush`, APNS, FCM, or XEP-0357 push.
- The marker is not a chat message.
- Clients must not render it as normal chat.
- If Android does not have a live XMPP connection, this is not reliable native OS background push.
- iOS push is not available for self-hosters yet.

- Troubleshoot it:

  ```bash
  journalctl -u email-glue.service -b --no-pager | tail -n 200
  journalctl -u ejabberd -b --no-pager | tail -n 200
  curl -sk -X POST https://127.0.0.1:8443/hooks/stalwart/events
  ```

- The unauthenticated hook request should return `401`.

## Netcup Voucher

- Netcup has worked well for us for email hosting because it allows port `25/tcp`.
- [Open a Netcup voucher request issue](https://github.com/axichat/selfhost/issues/new?template=netcup-voucher.yml&title=Netcup%20voucher%20request) if you want an affiliate voucher.

## Advanced Docs

- Most admins do not need these for a normal install.
- Use [`ejabberd/README.md`](ejabberd/README.md) for direct ejabberd work.
- Use [`stalwart/README.md`](stalwart/README.md) for direct Stalwart or email-specific debugging.

## Defaults

- Mailbox quota is unlimited.
- ejabberd file uploads allow up to 10 GB.
- Message history is kept by default.
- Email installs require a user-chosen public client token.
- Email installs enable Android mail notification hints through the Stalwart webhook.
