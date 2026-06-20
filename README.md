![Axichat banner](https://axichat.github.io/axichat/readme-media/axichat_banner.png)

# Axichat Self-Host

- All you have to do is get a Debian VPS, point your domain at it, and run the installer.
- The installer does the server work.
- When it needs something outside the server, it tells you exactly what to do.
- If anything gets interrupted, just run the same command again.
- It continues where it left off.

## Watch First

- Watch the self-host tutorial before you start:

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
- Your own domain.
- A / AAAA record pointed at your server IP.
- If you want email, which is recommended, your VPS provider must allow `25/tcp`.
- [Netcup is a good option if you need a port-25-friendly VPS.](https://github.com/axichat/selfhost/issues/new?template=netcup-voucher.yml&title=Netcup%20voucher%20request)

## Install

- For chat and email, run this on the server:

  ```bash
  curl -L https://gitlab.com/axichat/selfhost/-/archive/main/selfhost-main.tar.gz | tar -xzf -
  cd selfhost-main
  sudo bash ./install.sh install --domain example.com --public-token your-shared-token
  ```

- For chat only, run this instead:

  ```bash
  curl -L https://gitlab.com/axichat/selfhost/-/archive/main/selfhost-main.tar.gz | tar -xzf -
  cd selfhost-main
  sudo bash ./install.sh install --domain example.com --no-email
  ```

- Replace `example.com` with your domain.
- Choose `your-shared-token` yourself.
- Give that token to people who should be allowed to create Axichat accounts on your server.
- Do not use an admin password as the public token.
- Then just follow the prompts.

## What The Installer Walks You Through

- Domain checks.
- Local port checks.
- UFW rules, if UFW is already active.
- VPS firewall guidance, if you still need to open ports outside the server.
- Stalwart Webadmin steps for email.
- DNS records for email.
- PTR / reverse DNS for email.
- Verification after install.

## What You Get

- Instant messaging (XMPP from ejabberd).
- Email (SMTP from Stalwart).
- File attachments.
- First-party push notifications for Android.
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
- ejabberd upload limits are large.
- Message history is kept by default.
- Email installs require a user-chosen public client token.
- Email installs enable Android mail notification hints through the Stalwart webhook.
