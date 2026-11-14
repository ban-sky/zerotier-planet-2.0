## Introduction

Run your own **ZeroTier planet** and **ztncui network controller** in Docker. This app
packages [docker-zerotier-planet 2.0](https://github.com/ban-sky/zerotier-planet-2.0)
with ZeroTier One 1.16.2, TLS and the hardened defaults enabled out of the box.

## At a glance

| Item | Value |
| --- | --- |
| Default image | `docker.io/lonelyx/zerotier-planet:<version>` (no leading `v`) |
| Alternative | `ghcr.io/ban-sky/zerotier-planet:<version>` (identical content) |
| App directory | `/opt/1panel/apps/zerotier-planet` |
| Data | `data/config`, `data/dist`, `data/one` |
| Admin UI | `https://<server-ip>:<https-port>` (self-signed) |
| Initial password | `/app/config/admin-password` inside the container |

## Features

- Generates the planet and moon on first start; clients join with your custom planet.
- Random admin password on first boot, forced change at first sign-in, file deleted afterwards.
- HTTPS by default for the admin UI and the file server (self-signed ECDSA P-256); planet
  downloads use `Authorization: Bearer`, so the key never appears in a URL.
- Simplified Chinese and English UI, Chinese by default, switcher in the top bar.
- Two-step verification (TOTP) or a passkey (WebAuthn) — pick one, each can be enabled
  per account.
- ZeroTier brand mark in the icon and the UI.

## Install

1. Fill in the form: `IP_ADDR4` is required (the public IPv4 clients connect to),
   `IP_ADDR6` is optional, and the three ports can stay at their defaults.
2. Install and wait for the container to report "running".
3. Open `https://<server-ip>:<https-port>`, sign in with the initial password, change it.

| Field | Meaning |
| --- | --- |
| `IP_ADDR4` | Public IPv4, required; written into the planet's `stableEndpoints` |
| `IP_ADDR6` | Public IPv6, optional; leave empty to publish IPv4 endpoints only |
| `PANEL_APP_PORT_ZT` | ZeroTier service port (UDP), default 9994 |
| `PANEL_APP_PORT_HTTPS` | Admin UI port (TCP), default 3443 |
| `PANEL_APP_PORT_FILE` | planet / moon download port (TCP), default 3000 |

## Initial password

The password is generated on first boot, is **never written to the log** and never shown in
the UI. Any of these works:

- In the app terminal: `cat /app/config/admin-password`
- On the host: `sudo find /opt/1panel/apps -maxdepth 6 -name admin-password -exec cat {} \;`
- Inside the container: `docker exec <container> cat /app/config/admin-password`

The first sign-in forces a password change and the file is deleted once that is done. If the
password is lost later, delete `data/config/ztncui-passwd` and restart the container to
generate a fresh one (this replaces the existing admin password).

## Automatic updates (cron job)

One block, run it directly or paste it into **Cron job → Shell script**. It walks
jsDelivr, githack, ghfast.top and gh-proxy.com before falling back to GitHub, so a
mainland server does not stall on `raw.githubusercontent.com`:

```bash
ok=0
for u in \
  "https://cdn.jsdelivr.net/gh/ban-sky/zerotier-planet-2.0@main/scripts/1panel-scheduled-update.sh" \
  "https://fastly.jsdelivr.net/gh/ban-sky/zerotier-planet-2.0@main/scripts/1panel-scheduled-update.sh" \
  "https://rawcdn.githack.com/ban-sky/zerotier-planet-2.0/main/scripts/1panel-scheduled-update.sh" \
  "https://ghfast.top/https://raw.githubusercontent.com/ban-sky/zerotier-planet-2.0/main/scripts/1panel-scheduled-update.sh" \
  "https://gh-proxy.com/https://raw.githubusercontent.com/ban-sky/zerotier-planet-2.0/main/scripts/1panel-scheduled-update.sh" \
  "https://raw.githubusercontent.com/ban-sky/zerotier-planet-2.0/main/scripts/1panel-scheduled-update.sh"
do
  curl -fsSL --connect-timeout 8 --max-time 60 "$u" -o /tmp/ztp-update.sh || continue
  sudo bash /tmp/ztp-update.sh --quiet
  ok=$?
  break
done
[ "$ok" = 0 ] || echo "update failed: every mirror is unreachable" >&2
```

Manual control (the script also ships as a release asset):

```bash
sudo ./1panel-scheduled-update.sh --dry-run                # show what it would do
sudo ./1panel-scheduled-update.sh --quiet                  # pick the fastest channel
sudo ./1panel-scheduled-update.sh --source cdn --quiet     # jsDelivr only, best in CN
sudo ./1panel-scheduled-update.sh --mirror https://ghfast.top/ --quiet
sudo ./1panel-scheduled-update.sh --no-restart --quiet     # package only
```

Following [okxlin/appstore](https://github.com/okxlin/appstore), the script syncs the app
package into `/opt/1panel/resource/apps/local/`; refresh the app store to see the new
version, and the installed instance is restarted by default. Every request gives up after
8 seconds and switches channel, so it never hangs retrying. Full options are in the
[project README](https://github.com/ban-sky/zerotier-planet-2.0#cron-job-follow-new-releases-automatically).

## Ports

| Port | Protocol | Purpose |
| --- | --- | --- |
| 9994 | UDP | ZeroTier service port, must be open in the firewall |
| 3443 | TCP | Admin UI (HTTPS) |
| 3000 | TCP | planet / moon download (HTTPS, key required) |

## Troubleshooting

- **Certificate warning**: expected with the self-signed certificate; accept it, import the
  certificate, or put a trusted one on a reverse proxy.
- **"Request origin rejected" on sign-in**: usually a reverse proxy. Pass `Host` and
  `X-Forwarded-Host` through, or add the domain to the `ALLOWED_ORIGINS` environment variable.
- **Passkeys do not work**: WebAuthn only accepts a domain plus a trusted certificate. On a
  bare IP the page warns but still lets you try; most browsers refuse. Fall back to TOTP or
  password-only login.
- **The store still shows the old version**: refresh the app store once; if it persists, rerun
  the script with `--source cdn`.
